#!/usr/bin/env python3
"""
Self-contained build & test runner for knots using wazig/wazigl + wasmtime (no native zig needed).

Compiles the target build.zig + tools/wazig_configurer.zig into configurer.wasm via wazig
(or wazigl when WAZIG=wazigl is set), runs configurer.wasm via wasmtime to evaluate the
real std.Build graph and materialize Step.Options / Step.WriteFile outputs, and executes
emitted translate-c, compile (-fno-llvm for wazig, -fllvm for wazigl), install, and
test-run steps via wazig/wazigl and wasmtime.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent

EXTERNAL_WASM_PACKAGES = {
    "TrueType-1.0.0-Ne-mWFx1AQAk8u43nEzx-W3oPUGaXnuLNFa2jTStHFjj": {
        "archive_url": "https://codeberg.org/andrewrk/TrueType/archive/c90d976877f1dbd4014f6fa4da30139f41df366b.tar.gz",
        "git_url": "https://codeberg.org/andrewrk/TrueType.git",
        "git_rev": "c90d976877f1dbd4014f6fa4da30139f41df366b",
    },
    "N-V-__8AAOncKwEm1F9c5LrT7HMNmRMYX8-fAoqpc6YyTu9X": {
        "archive_url": "https://github.com/wolfpld/tracy/archive/refs/tags/v0.13.1.tar.gz",
        "git_url": "https://github.com/wolfpld/tracy.git",
        "git_rev": "v0.13.1",
    },
}


def find_tool(name: str, env_var: str) -> str:
    if os.environ.get(env_var):
        return os.environ[env_var]
    found = shutil.which(name)
    if found:
        return found
    ghr_candidate = Path.home() / ".local" / "share" / "ghr" / "bin" / name
    if ghr_candidate.exists():
        return str(ghr_candidate)
    raise SystemExit(f"error: required tool '{name}' not found on PATH")


def ensure_wasmtime_cache(cache_base: Path) -> None:
    if os.environ.get("WASMTIME_CACHE_CONFIG"):
        return
    wt_cache_dir = cache_base / "wasmtime-cache"
    wt_cache_dir.mkdir(parents=True, exist_ok=True)
    wt_toml = cache_base / "wasmtime-cache.toml"
    if not wt_toml.exists():
        wt_toml.write_text(
            f'[cache]\nenabled = true\ndirectory = "{wt_cache_dir}"\n',
            encoding="utf-8",
        )
    os.environ["WASMTIME_CACHE_CONFIG"] = str(wt_toml)


def ensure_external_package(global_cache: Path, pkg_hash: str) -> Path:
    pkg_dir = global_cache / "p" / pkg_hash
    if pkg_dir.exists() and any(pkg_dir.iterdir()):
        return pkg_dir

    # Also check if already present in any existing local cache under /d
    for candidate_base in [
        REPO_ROOT / ".zig-global-cache" / "p" / pkg_hash,
        Path("/d/knots/.zig-global-cache/p") / pkg_hash,
        Path("/d/zig-global-cache/p") / pkg_hash,
        Path("/d/zig/.zig-global-cache/p") / pkg_hash,
    ]:
        if candidate_base.exists() and any(candidate_base.iterdir()):
            pkg_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(candidate_base, pkg_dir, dirs_exist_ok=True)
            return pkg_dir

    info = EXTERNAL_WASM_PACKAGES.get(pkg_hash)
    if not info:
        raise SystemExit(f"error: unknown external package hash {pkg_hash}")

    tmp_dir = global_cache / "tmp_fetch" / pkg_hash
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tar_path = tmp_dir / "pkg.tar.gz"

    try:
        with urllib.request.urlopen(info["archive_url"], timeout=20) as resp:
            tar_path.write_bytes(resp.read())
        extract_dir = tmp_dir / "extracted"
        extract_dir.mkdir(parents=True, exist_ok=True)
        with tarfile.open(tar_path, "r:gz") as tf:
            tf.extractall(extract_dir)
        entries = [p for p in extract_dir.iterdir() if p.is_dir()]
        src_root = entries[0] if len(entries) == 1 else extract_dir
        pkg_dir.parent.mkdir(parents=True, exist_ok=True)
        if pkg_dir.exists():
            shutil.rmtree(pkg_dir)
        shutil.move(str(src_root), str(pkg_dir))
    except Exception:
        clone_dir = tmp_dir / "clone"
        if clone_dir.exists():
            shutil.rmtree(clone_dir)
        subprocess.run(
            ["git", "clone", "--quiet", info["git_url"], str(clone_dir)],
            check=True,
            timeout=60,
        )
        subprocess.run(
            ["git", "-C", str(clone_dir), "checkout", "--quiet", info["git_rev"]],
            check=True,
            timeout=30,
        )
        shutil.rmtree(clone_dir / ".git", ignore_errors=True)
        pkg_dir.parent.mkdir(parents=True, exist_ok=True)
        if pkg_dir.exists():
            shutil.rmtree(pkg_dir)
        shutil.move(str(clone_dir), str(pkg_dir))
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    return pkg_dir


def parse_zon_dependencies(zon_path: Path) -> list[dict[str, Any]]:
    if not zon_path.exists():
        return []
    text = zon_path.read_text(encoding="utf-8")
    m = re.search(r"\.dependencies\s*=\s*\.\{(.*?)\n    \},", text, re.S)
    if not m:
        return []
    body = m.group(1)
    deps: list[dict[str, Any]] = []
    for entry_match in re.finditer(r"\.([A-Za-z0-9_]+)\s*=\s*\.\{(.*?)\},", body, re.S):
        name = entry_match.group(1)
        fields = entry_match.group(2)
        path_m = re.search(r'\.path\s*=\s*"([^"]+)"', fields)
        hash_m = re.search(r'\.hash\s*=\s*"([^"]+)"', fields)
        lazy_m = re.search(r"\.lazy\s*=\s*true", fields)
        deps.append(
            {
                "name": name,
                "path": path_m.group(1) if path_m else None,
                "hash": hash_m.group(1) if hash_m else None,
                "lazy": bool(lazy_m),
            }
        )
    return deps


def rel_from_repo(target: Path) -> str:
    rel = os.path.relpath(target.resolve(), REPO_ROOT.resolve())
    return "." if rel == "." else rel.replace("\\", "/")


def zig_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def build_package_graph(
    build_root: Path, global_cache: Path
) -> tuple[dict[str, dict[str, Any]], list[tuple[str, str]]]:
    packages: dict[str, dict[str, Any]] = {}

    def visit_dir(pkg_dir: Path) -> list[tuple[str, str]]:
        zon_deps = parse_zon_dependencies(pkg_dir / "build.zig.zon")
        resolved_pairs: list[tuple[str, str]] = []
        for d in zon_deps:
            name = d["name"]
            if d["path"] is not None:
                dep_dir = (pkg_dir / d["path"]).resolve()
                pkg_id = f"local_{name}_{hashlib.sha256(str(dep_dir).encode()).hexdigest()[:12]}"
                resolved_pairs.append((name, pkg_id))
                if pkg_id not in packages:
                    if d["lazy"]:
                        packages[pkg_id] = {
                            "available": False,
                            "lazy": True,
                        }
                    else:
                        packages[pkg_id] = {
                            "available": True,
                            "lazy": False,
                            "build_root": rel_from_repo(dep_dir),
                            "abs_root": dep_dir,
                            "has_build_zig": (dep_dir / "build.zig").exists(),
                            "deps": [],
                        }
                        packages[pkg_id]["deps"] = visit_dir(dep_dir)
            else:
                pkg_id = d["hash"]
                resolved_pairs.append((name, pkg_id))
                if pkg_id not in packages:
                    if d["lazy"]:
                        packages[pkg_id] = {
                            "available": False,
                            "lazy": True,
                        }
                    else:
                        dep_dir = ensure_external_package(global_cache, pkg_id)
                        packages[pkg_id] = {
                            "available": True,
                            "lazy": False,
                            "build_root": rel_from_repo(dep_dir),
                            "abs_root": dep_dir,
                            "has_build_zig": (dep_dir / "build.zig").exists(),
                            "deps": [],
                        }
                        packages[pkg_id]["deps"] = visit_dir(dep_dir)
        return resolved_pairs

    root_deps = visit_dir(build_root)
    return packages, root_deps


def generate_dependencies_zig(
    packages: dict[str, dict[str, Any]], root_deps: list[tuple[str, str]]
) -> str:
    lines = ["pub const packages = struct {"]
    for pkg_id in sorted(packages.keys()):
        info = packages[pkg_id]
        lines.append(f'    pub const @"{zig_escape(pkg_id)}" = struct {{')
        if not info["available"]:
            lines.append("        pub const available = false;")
            lines.append("    };")
            continue
        if info.get("lazy"):
            lines.append("        pub const available = true;")
        lines.append(f'        pub const build_root = "{zig_escape(info["build_root"])}";')
        if info["has_build_zig"]:
            lines.append(f'        pub const build_zig = @import("{zig_escape(pkg_id)}");')
        if info["deps"]:
            lines.append("        pub const deps: []const struct { []const u8, []const u8 } = &.{")
            for dep_name, dep_id in info["deps"]:
                lines.append(f'            .{{ "{zig_escape(dep_name)}", "{zig_escape(dep_id)}" }},')
            lines.append("        };")
        else:
            lines.append("        pub const deps: []const struct { []const u8, []const u8 } = &.{};")
        lines.append("    };")
    lines.append("};")
    lines.append("pub const root_deps: []const struct { []const u8, []const u8 } = &.{")
    for dep_name, dep_id in root_deps:
        lines.append(f'    .{{ "{zig_escape(dep_name)}", "{zig_escape(dep_id)}" }},')
    lines.append("};")
    return "\n".join(lines) + "\n"


def compile_and_run_configurer(
    wazig: str,
    wasmtime: str,
    build_root: Path,
    local_cache: Path,
    global_cache: Path,
    install_prefix: Path,
    steps: list[str],
    d_options: list[str],
) -> dict[str, Any]:
    packages, root_deps = build_package_graph(build_root, global_cache)
    deps_zig_src = generate_dependencies_zig(packages, root_deps)

    wazig_meta_dir = local_cache / "wazig_configurer"
    wazig_meta_dir.mkdir(parents=True, exist_ok=True)
    deps_zig_path = wazig_meta_dir / "dependencies.zig"
    deps_zig_path.write_text(deps_zig_src, encoding="utf-8")

    configurer_src = REPO_ROOT / "tools" / "wazig_configurer.zig"
    root_build_zig = build_root / "build.zig"

    # Compute digest of configurer inputs so repeat runs reuse configurer.wasm
    h = hashlib.sha256()
    h.update(configurer_src.read_bytes())
    h.update(root_build_zig.read_bytes())
    h.update(deps_zig_src.encode("utf-8"))
    for pkg_id in sorted(packages.keys()):
        info = packages[pkg_id]
        if info["available"] and info["has_build_zig"]:
            bz = info["abs_root"] / "build.zig"
            h.update(bz.read_bytes())
            wb = info["abs_root"] / "web_build.zig"
            if wb.exists():
                h.update(wb.read_bytes())
    configurer_wasm = wazig_meta_dir / f"configurer_{h.hexdigest()[:16]}.wasm"

    if not configurer_wasm.exists():
        cmd = [
            wazig,
            "build-exe",
            "-fno-llvm",
            "-ODebug",
            "-target",
            "wasm32-wasi",
            f"-femit-bin={rel_from_repo(configurer_wasm)}",
            "--dep",
            "@build",
            "--dep",
            "@dependencies",
            f"-Mroot={rel_from_repo(configurer_src)}",
        ]
        # Add --dep for @build (any root_deps that have build.zig, e.g., knots)
        for dep_name, dep_id in root_deps:
            info = packages[dep_id]
            if info["available"] and info["has_build_zig"]:
                cmd.extend(["--dep", f"{dep_name}={dep_id}"])
        cmd.append(f"-M@build={rel_from_repo(root_build_zig)}")

        # Add --dep for @dependencies (all available packages with build.zig)
        for pkg_id in sorted(packages.keys()):
            info = packages[pkg_id]
            if info["available"] and info["has_build_zig"]:
                cmd.extend(["--dep", pkg_id])
        cmd.append(f"-M@dependencies={rel_from_repo(deps_zig_path)}")

        # Define each package build.zig module
        for pkg_id in sorted(packages.keys()):
            info = packages[pkg_id]
            if info["available"] and info["has_build_zig"]:
                for sub_name, sub_id in info["deps"]:
                    sub_info = packages[sub_id]
                    if sub_info["available"] and sub_info["has_build_zig"]:
                        cmd.extend(["--dep", f"{sub_name}={sub_id}"])
                bz_rel = rel_from_repo(info["abs_root"] / "build.zig")
                cmd.append(f"-M{pkg_id}={bz_rel}")

        cmd.extend(
            [
                "--cache-dir",
                rel_from_repo(local_cache),
                "--global-cache-dir",
                rel_from_repo(global_cache),
            ]
        )
        subprocess.run(cmd, cwd=REPO_ROOT, check=True)

    run_cmd = [
        wasmtime,
        "run",
        "--dir=.",
        rel_from_repo(configurer_wasm),
        "--zig",
        wazig,
        "--build-root",
        rel_from_repo(build_root),
        "--cache-root",
        rel_from_repo(local_cache),
        "--global-cache-root",
        rel_from_repo(global_cache),
        "--prefix",
        rel_from_repo(install_prefix),
    ]
    for s in steps:
        run_cmd.extend(["--step", s])
    run_cmd.extend(d_options)

    proc = subprocess.run(
        run_cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    if proc.stderr:
        sys.stderr.write(proc.stderr)

    return json.loads(proc.stdout)


def main(argv: list[str]) -> int:
    wazig = find_tool("wazig", "WAZIG")
    wasmtime = find_tool("wasmtime", "WASMTIME")

    local_cache = Path(
        os.environ.get("ZIG_LOCAL_CACHE_DIR", str(REPO_ROOT / ".zig-cache"))
    ).resolve()
    if not local_cache.is_relative_to(REPO_ROOT):
        local_cache = (REPO_ROOT / ".zig-cache").resolve()

    global_cache = Path(
        os.environ.get("ZIG_GLOBAL_CACHE_DIR", str(REPO_ROOT / ".zig-global-cache"))
    ).resolve()
    if not global_cache.is_relative_to(REPO_ROOT):
        global_cache = (REPO_ROOT / ".zig-global-cache").resolve()

    local_cache.mkdir(parents=True, exist_ok=True)
    global_cache.mkdir(parents=True, exist_ok=True)
    ensure_wasmtime_cache(global_cache)

    # Support `./wazig-build fmt [--check] ...`
    if argv and argv[0] == "fmt":
        proc = subprocess.run([wazig, *argv], cwd=REPO_ROOT)
        return proc.returncode

    build_root = REPO_ROOT
    install_prefix: Path | None = None
    steps: list[str] = []
    d_options: list[str] = []
    run_extra_args: list[str] = []
    use_wasmtime = False
    verbose = False

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            run_extra_args = argv[i + 1 :]
            break
        elif arg == "--build-root":
            i += 1
            build_root = (REPO_ROOT / argv[i]).resolve()
        elif arg.startswith("--build-root="):
            build_root = (REPO_ROOT / arg.split("=", 1)[1]).resolve()
        elif arg in ("--prefix", "-p"):
            i += 1
            install_prefix = (REPO_ROOT / argv[i]).resolve()
        elif arg.startswith("--prefix="):
            install_prefix = (REPO_ROOT / arg.split("=", 1)[1]).resolve()
        elif arg in ("--cache-dir",):
            i += 1
            local_cache = (REPO_ROOT / argv[i]).resolve()
        elif arg in ("--global-cache-dir",):
            i += 1
            global_cache = (REPO_ROOT / argv[i]).resolve()
        elif arg == "-fwasmtime":
            use_wasmtime = True
        elif arg in ("--verbose", "-v"):
            verbose = True
        elif arg.startswith("-D"):
            d_options.append(arg)
        elif arg.startswith("-j"):
            pass
        elif arg.startswith("-"):
            pass
        else:
            steps.append(arg)
        i += 1

    if install_prefix is None:
        install_prefix = build_root / "zig-out"

    # Default target to wasm32-wasi if not specified
    if not any(opt.startswith("-Dtarget=") for opt in d_options):
        d_options.append("-Dtarget=wasm32-wasi")

    plan = compile_and_run_configurer(
        wazig=wazig,
        wasmtime=wasmtime,
        build_root=build_root,
        local_cache=local_cache,
        global_cache=global_cache,
        install_prefix=install_prefix,
        steps=steps,
        d_options=d_options,
    )

    for step in plan.get("steps", []):
        kind = step["kind"]
        if kind == "translate_c":
            out_file = REPO_ROOT / step["output"]
            out_file.parent.mkdir(parents=True, exist_ok=True)
            cmd = [wazig, *step["args"]]
            if verbose:
                print("+", " ".join(cmd), f"> {step['output']}", file=sys.stderr)
            with open(out_file, "w", encoding="utf-8") as f:
                subprocess.run(cmd, cwd=REPO_ROOT, stdout=f, check=True)
        elif kind == "compile":
            out_file = REPO_ROOT / step["output"]
            out_file.parent.mkdir(parents=True, exist_ok=True)
            cmd = [wazig, *step["args"]]
            if verbose:
                print("+", " ".join(cmd), file=sys.stderr)
            subprocess.run(cmd, cwd=REPO_ROOT, check=True)
        elif kind == "install_file":
            src = REPO_ROOT / step["src"]
            dest = REPO_ROOT / step["dest"]
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
        elif kind == "run":
            if use_wasmtime or any(s in ("test", "bench", "wasm-bench") for s in steps):
                wt_cmd = [
                    wasmtime,
                    "run",
                    "-W",
                    "memory64=y",
                    "--dir=.",
                    "-Sinherit-env",
                    *step["args"],
                    *run_extra_args,
                ]
                if verbose:
                    print("+", " ".join(wt_cmd), file=sys.stderr)
                subprocess.run(wt_cmd, cwd=REPO_ROOT, check=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
