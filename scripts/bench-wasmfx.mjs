#!/usr/bin/env node
/**
 * Reproducible V8 / Node.js vs Wasmtime benchmark suite for knots:
 *   1. Builds `tests/wasm_bench_runner.zig` (`wasm32-wasi`, `generic+simd128`, `ReleaseFast`)
 *      using `wazig` (or `zig`), or uses an existing binary via `--wasm <path>`.
 *   2. Runs the 4 synchronous knots benchmarks (`layout_bench`, `text_bench`,
 *      `render_bench`, `combined_frame`) across:
 *        - `wasmtime run` (if available in PATH)
 *        - `node` (default V8 flags, via `node:wasi` with the `fd_pwrite` ESPIPE shim)
 *        - `node --experimental-wasm-wasmfx --experimental-wasm-growable-stacks`
 *   3. Benchmarks runtime capability detection (`detectWasmCapabilities()`):
 *        - `JSPI` (`WebAssembly.Suspending` / `WebAssembly.promising`)
 *        - `Atomics.waitAsync`
 *        - `WasmFX` (`WebAssembly.validate` on the 16-byte `0x5d` `cont` probe module)
 *   4. Benchmarks `std.Io` coroutine / cooperative frame-budget yield & futex wait in V8:
 *        - WasmFX continuation suspend/resume (active stack vs full `cont.new` per op)
 *        - JSPI suspend/resume (`Promise.resolve()` vs `queueMicrotask`)
 *        - Cooperative frame-budgeted polygon triangulation loop (10,000 steps, yield every 1,000)
 *        - Main-thread `std.Io` futex wait (`Atomics.waitAsync` + JSPI vs spin-wait on `SharedArrayBuffer`)
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";

process.removeAllListeners("warning");
const { WASI } = await import("node:wasi");

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(SCRIPT_PATH);
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..");

const SYNC_BENCHMARKS = [
  "layout_bench",
  "text_bench",
  "render_bench",
  "combined_frame",
];

/**
 * Minimal 16-byte WebAssembly binary that declares:
 *   (type $ft (func))
 *   (type $ct (cont $ft))  ;; 0x5d = cont type constructor
 */
export const WASMFX_PROBE_BYTES = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x06, 0x02, 0x60, 0x00, 0x00, 0x5d, 0x00,
]);

/**
 * Compiled from WAT (via `wasm-tools parse`):
 * Exports:
 *   - `bench_active_yield(n: i32) -> i32`:
 *       Allocates one continuation with `cont.new` and suspends/resumes `n` times
 *       on the active continuation stack.
 *   - `bench_full_cont(n: i32) -> i32`:
 *       Loops `n` times, each iteration executing `cont.new` + `resume` (1 suspend) +
 *       `resume` to completion.
 *   - `triangulate_baseline(n: i32) -> i32`:
 *       Runs `n` iterations of a deterministic ear-clipping / cross-product kernel
 *       with no yield instrumentation.
 *   - `triangulate_wasmfx(n: i32, interval: i32) -> i32`:
 *       Runs the same `n`-iteration triangulation kernel inside a WasmFX continuation,
 *       executing `suspend $yield` every `interval` iterations.
 */
const WASMFX_BENCH_MODULE_BASE64 =
  "AGFzbQEAAAABEQRgAABdAGABfwF/YAJ/fwF/AwgHAAAAAgICAw0DAQAABhEDfwFBAAt/AUHoBwt/" +
  "AUEACwdUBBJiZW5jaF9hY3RpdmVfeWllbGQAAw9iZW5jaF9mdWxsX2NvbnQABBR0cmlhbmd1bGF0" +
  "ZV9iYXNlbGluZQAFEnRyaWFuZ3VsYXRlX3dhc21meAAGCQcBAwADAAECCvADBx4BAn8jACEBA0Ag" +
  "ACABSQRA4gAgAEEBaiEADAELCwsEAOIAC6IBAQx/IwAhASMBIQNBASEEA0AgACABSQRAIABBEWxB" +
  "/wdxIQUgAEEfbEH/B3EhBiAEQQ1sQf8HcSEHIABBL2xB/wdxIQggBSAIakH/B3EhCSAGIAdqQf8H" +
  "cSEKIAcgBWsgCiAGa2wgCCAGayAJIAVrbGshCyAEIAsgAGpzIQQgAEEBaiEAIAJBAWohAiACIANP" +
  "BEBBACEC4gALDAELCyAEJAILMgIBYwEBfyAAJADSAOABIQEDQAJAAmQBIAHjAQEAAAAMAQshASAC" +
  "QQFqIQIMAQsLIAILQAMBfwFjAQF/A0AgASAASQRA0gHgASECAmQBIALjAQEAAAAACyECIALjAQAg" +
  "A0EBaiEDIAFBAWohAQwBCwsgAwuDAQEJf0EBIQIDQCABIABJBEAgAUERbEH/B3EhAyABQR9sQf8H" +
  "cSEEIAJBDWxB/wdxIQUgAUEvbEH/B3EhBiADIAZqQf8HcSEHIAQgBWpB/wdxIQggBSADayAIIARr" +
  "bCAGIARrIAcgA2tsayEJIAIgCSABanMhAiABQQFqIQEMAQsLIAILLQEBYwEgACQAIAEkAdIC4AEh" +
  "AgNAAkACZAEgAuMBAQAAAAwBCyECDAELCyMCCwD+AgRuYW1lATUDABF5aWVsZF9sb29wX3dvcmtl" +
  "cgETc2luZ2xlX3lpZWxkX3dvcmtlcgIKdHJpX3dvcmtlcgKoAQYAAgABaQEBbgIMAAFpAQFuAgRz" +
  "dGVwAwhpbnRlcnZhbAQDYWNjBQJheAYCYXkHAmJ4CAJieQkCY3gKAmN5CwVjcm9zcwMDAAFuAQFr" +
  "AgdyZXN1bWVzBAQAAW4BAWkCAWsDB3Jlc3VtZXMFCgABbgEBaQIDYWNjAwJheAQCYXkFAmJ4BgJi" +
  "eQcCY3gIAmN5CQVjcm9zcwYDAAFuAQhpbnRlcnZhbAIBawNVBgABAAFsAgEAAWwDAwAFZHJpdmUB" +
  "BGRvbmUCCG9uX3lpZWxkBAIABW91dGVyAghvbl95aWVsZAUBAAFsBgMABWRyaXZlAQRkb25lAghv" +
  "bl95aWVsZAQJAgACZnQBAmN0BykDAA10YXJnZXRfeWllbGRzAQ55aWVsZF9pbnRlcnZhbAIHdHJp" +
  "X2FjYwsIAQAFeWllbGQ=";

/**
 * Compiled from WAT (via `wasm-tools parse`):
 * Imports:
 *   - `env.memory` (shared 1..1 pages)
 *   - `env.host_yield: () -> void`
 *   - `env.host_wait_async: (ptr: i32, expected: i32) -> void`
 * Exports:
 *   - `bench_jspi_yield(n: i32) -> i32`
 *   - `triangulate_baseline(n: i32) -> i32`
 *   - `triangulate_jspi(n: i32, interval: i32) -> i32`
 *   - `futex_wait_jspi(ptr: i32, expected: i32) -> i32`
 *   - `futex_spin_wait(ptr: i32, expected: i32) -> i32`
 */
const JSPI_BENCH_MODULE_BASE64 =
  "AGFzbQEAAAABFARgAABgAn9/AGABfwF/YAJ/fwF/AjcDA2VudgZtZW1vcnkCAwEBA2Vudgpob3N0" +
  "X3lpZWxkAAADZW52D2hvc3Rfd2FpdF9hc3luYwABAwYFAgIDAwMHYgUQYmVuY2hfanNwaV95aWVs" +
  "ZAACFHRyaWFuZ3VsYXRlX2Jhc2VsaW5lAAMQdHJpYW5ndWxhdGVfanNwaQAED2Z1dGV4X3dhaXRf" +
  "anNwaQAFD2Z1dGV4X3NwaW5fd2FpdAAGCvwCBRwBAX8DQCABIABJBEAQACABQQFqIQEMAQsLIAEL" +
  "gwEBCX9BASECA0AgASAASQRAIAFBEWxB/wdxIQMgAUEfbEH/B3EhBCACQQ1sQf8HcSEFIAFBL2xB" +
  "/wdxIQYgAyAGakH/B3EhByAEIAVqQf8HcSEIIAUgA2sgCCAEa2wgBiAEayAHIANrbGshCSACIAkg" +
  "AWpzIQIgAUEBaiEBDAELCyACC5gBAQp/QQEhBANAIAIgAEkEQCACQRFsQf8HcSEFIAJBH2xB/wdx" +
  "IQYgBEENbEH/B3EhByACQS9sQf8HcSEIIAUgCGpB/wdxIQkgBiAHakH/B3EhCiAHIAVrIAogBmts" +
  "IAggBmsgCSAFa2xrIQsgBCALIAJqcyEEIAJBAWohAiADQQFqIQMgAyABTwRAQQAhAxAACwwBCwsg" +
  "BAsfAANAIAD+EAIAIAFGBEAgACABEAEMAQsLIAD+EAIACx4BAX8DQCAA/hACACABRgRAIAJBAWoh" +
  "AgwBCwsgAgsA3gEEbmFtZQEeAgAKaG9zdF95aWVsZAEPaG9zdF93YWl0X2FzeW5jApoBBQICAAFu" +
  "AQFpAwoAAW4BAWkCA2FjYwMCYXgEAmF5BQJieAYCYnkHAmN4CAJjeQkFY3Jvc3MEDAABbgEIaW50" +
  "ZXJ2YWwCAWkDBHN0ZXAEA2FjYwUCYXgGAmF5BwJieAgCYnkJAmN4CgJjeQsFY3Jvc3MFAgADcHRy" +
  "AQhleHBlY3RlZAYDAANwdHIBCGV4cGVjdGVkAgVzcGlucwMaBQIBAAFsAwEAAWwEAQABbAUBAAF3" +
  "BgEAAXc=";

export function detectWasmCapabilities() {
  const jspi =
    typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function";
  const waitAsync =
    typeof Atomics !== "undefined" && typeof Atomics.waitAsync === "function";
  const wasmfx = WebAssembly.validate(WASMFX_PROBE_BYTES);
  return { jspi, waitAsync, wasmfx };
}

function parseArgs(argv) {
  const opts = {
    wasm: null,
    json: false,
    internalWasmfxChild: false,
    internalDefaultNodeChild: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--wasm" && i + 1 < argv.length) {
      opts.wasm = argv[++i];
    } else if (arg.startsWith("--wasm=")) {
      opts.wasm = arg.slice("--wasm=".length);
    } else if (arg === "--json") {
      opts.json = true;
    } else if (arg === "--internal-wasmfx-child") {
      opts.internalWasmfxChild = true;
    } else if (arg === "--internal-default-node-child") {
      opts.internalDefaultNodeChild = true;
    } else if (arg === "--help" || arg === "-h") {
      console.log(
        "Usage: node scripts/bench-wasmfx.mjs [--wasm <path>] [--json]",
      );
      process.exit(0);
    }
  }
  return opts;
}

function findExecutable(name) {
  const pathEnv = process.env.PATH || "";
  const dirs = pathEnv.split(path.delimiter);
  for (const dir of dirs) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // continue
    }
  }
  return null;
}

function resolveCompiler() {
  if (process.env.WAZIG_BIN && fs.existsSync(process.env.WAZIG_BIN)) {
    return { bin: process.env.WAZIG_BIN, kind: "wazig" };
  }
  const wazigInPath = findExecutable("wazig");
  if (wazigInPath) {
    return { bin: wazigInPath, kind: "wazig" };
  }
  const siblingWazig = path.resolve(REPO_ROOT, "../wazig/zig-out/bin/wazig");
  if (fs.existsSync(siblingWazig)) {
    return { bin: siblingWazig, kind: "wazig" };
  }
  const zigInPath = findExecutable("zig");
  if (zigInPath) {
    return { bin: zigInPath, kind: "zig" };
  }
  throw new Error("Neither `wazig` nor `zig` was found in PATH.");
}

function resolveTrueTypeZig(workDir) {
  const findInRoot = (cacheRoot) => {
    if (!fs.existsSync(cacheRoot)) return null;
    for (const entry of fs.readdirSync(cacheRoot).sort()) {
      if (!entry.startsWith("TrueType-")) continue;
      for (const rel of ["TrueType.zig", path.join("src", "TrueType.zig")]) {
        const candidate = path.join(cacheRoot, entry, rel);
        if (fs.existsSync(candidate)) return candidate;
      }
    }
    return null;
  };

  const localHit = findInRoot(path.join(REPO_ROOT, ".zig-global-cache", "p"));
  if (localHit) {
    return path.relative(REPO_ROOT, localHit);
  }
  const homeHit = findInRoot(path.join(os.homedir(), ".cache", "zig", "p"));
  if (homeHit) {
    const staged = path.join(workDir, "TrueType.zig");
    fs.copyFileSync(homeHit, staged);
    return path.relative(REPO_ROOT, staged);
  }
  throw new Error(
    "Could not locate unpacked TrueType.zig in .zig-global-cache/p or ~/.cache/zig/p.",
  );
}

function buildWasmBenchRunner() {
  const workDir = path.join(REPO_ROOT, ".cache-bench", "wasmfx");
  const localCacheDir = path.join(workDir, "zig-local");
  const globalCacheDir = path.join(REPO_ROOT, ".zig-global-cache");
  fs.mkdirSync(localCacheDir, { recursive: true });
  fs.mkdirSync(globalCacheDir, { recursive: true });

  const buildOptionsPath = path.join(workDir, "truetype_options.zig");
  fs.writeFileSync(buildOptionsPath, "pub const debug_todo: bool = false;\n", "utf8");

  const relTrueType = resolveTrueTypeZig(workDir);
  const relBuildOptions = path.relative(REPO_ROOT, buildOptionsPath);
  const relOutput = path.relative(
    REPO_ROOT,
    path.join(workDir, "wasm_bench_runner.wasm"),
  );
  const relLocalCache = path.relative(REPO_ROOT, localCacheDir);
  const relGlobalCache = path.relative(REPO_ROOT, globalCacheDir);

  const compiler = resolveCompiler();
  const targetOptFlags = [
    "-target",
    "wasm32-wasi",
    "-mcpu",
    "generic+simd128",
    "-OReleaseFast",
  ];
  const args = [
    "build-exe",
    "-fno-llvm",
    ...targetOptFlags,
    "--dep", "math",
    "--dep", "style",
    "--dep", "layout",
    "--dep", "TrueType",
    "--dep", "text",
    "--dep", "render_types",
    "--dep", "render",
    "--dep", "input",
    "--dep", "ui",
    "-Mroot=tests/wasm_bench_runner.zig",
    ...targetOptFlags,
    "-Mmath=src/math/root.zig",
    ...targetOptFlags,
    "-Mrender_types=src/render/types/root.zig",
    ...targetOptFlags,
    "-Minput=src/input/root.zig",
    "--dep", "math",
    ...targetOptFlags,
    "-Mlayout=src/layout/root.zig",
    "--dep", "layout",
    "--dep", "math",
    "--dep", "render_types",
    ...targetOptFlags,
    "-Mstyle=src/style/root.zig",
    "--dep", "build_options",
    ...targetOptFlags,
    `-MTrueType=${relTrueType}`,
    "--dep", "TrueType",
    ...targetOptFlags,
    "-Mtext=src/text/root.zig",
    "--dep", "render_types",
    "--dep", "math",
    ...targetOptFlags,
    "-Mrender=src/render/root.zig",
    "--dep", "layout",
    "--dep", "style",
    "--dep", "text",
    "--dep", "input",
    "--dep", "render_types",
    "--dep", "render",
    "--dep", "math",
    ...targetOptFlags,
    "-Mui=src/ui/root.zig",
    ...targetOptFlags,
    `-Mbuild_options=${relBuildOptions}`,
    "--cache-dir",
    relLocalCache,
    "--global-cache-dir",
    relGlobalCache,
    `-femit-bin=${relOutput}`,
  ];

  const t0 = performance.now();
  const res = spawnSync(compiler.bin, args, {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
  const compileMs = performance.now() - t0;
  if (res.status !== 0) {
    throw new Error(
      `Failed to compile wasm_bench_runner.wasm with ${compiler.kind}:\n${res.stderr || res.stdout}`,
    );
  }
  const absOutput = path.join(REPO_ROOT, relOutput);
  const sizeBytes = fs.statSync(absOutput).size;
  return {
    wasmPath: absOutput,
    compilerKind: compiler.kind,
    compileMs,
    sizeBytes,
  };
}

/**
 * Runs `wasm_bench_runner.wasm` in-process using `node:wasi`.
 * Applies the `fd_pwrite` shim returning `70` (`WASI_ESPIPE`) on stdout/stderr so
 * Zig 0.17 `std.Io.File.stdout().writer()` falls back to `fd_write`.
 */
function runAllSyncBenchmarksInNode(wasmPath) {
  const wasmBytes = fs.readFileSync(wasmPath);
  const wasmModule = new WebAssembly.Module(wasmBytes);
  const stdoutChunks = [];
  const wasi = new WASI({
    version: "preview1",
    args: ["wasm_bench_runner.wasm"],
    env: {},
    returnOnExit: true,
  });

  const importObject = wasi.getImportObject();
  const preview1 = importObject.wasi_snapshot_preview1;
  const origPwrite = preview1.fd_pwrite.bind(preview1);
  const origWrite = preview1.fd_write.bind(preview1);

  let memoryRef = null;
  preview1.fd_pwrite = (fd, iovsPtr, iovsLen, offset, nwrittenPtr) => {
    if (fd === 1 || fd === 2) {
      return 70; // WASI_ESPIPE -> forces Zig 0.17 std.Io.File.Writer into streaming fd_write mode
    }
    return origPwrite(fd, iovsPtr, iovsLen, offset, nwrittenPtr);
  };

  preview1.fd_write = (fd, iovsPtr, iovsLen, nwrittenPtr) => {
    if ((fd === 1 || fd === 2) && memoryRef) {
      const view = new DataView(memoryRef.buffer);
      const bytes = new Uint8Array(memoryRef.buffer);
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovsPtr + i * 8, true);
        const len = view.getUint32(iovsPtr + i * 8 + 4, true);
        if (fd === 1 && len > 0) {
          stdoutChunks.push(Buffer.from(bytes.subarray(ptr, ptr + len)));
        }
        total += len;
      }
      view.setUint32(nwrittenPtr, total, true);
      return 0;
    }
    return origWrite(fd, iovsPtr, iovsLen, nwrittenPtr);
  };

  const instance = new WebAssembly.Instance(wasmModule, importObject);
  memoryRef = instance.exports.memory;
  const exitCode = wasi.start(instance);
  if (exitCode !== 0) {
    throw new Error(`wasm_bench_runner exited with code ${exitCode}`);
  }

  const rawText = Buffer.concat(stdoutChunks).toString("utf8").trim();
  const parsed = JSON.parse(rawText);
  if (!parsed.workloads) {
    throw new Error(`Unexpected benchmark output: ${rawText}`);
  }
  return parsed;
}

function runAllSyncBenchmarksInWasmtime(wasmPath) {
  const wasmtimeBin = findExecutable("wasmtime");
  if (!wasmtimeBin) {
    return null;
  }
  const res = spawnSync(wasmtimeBin, ["run", wasmPath], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
  if (res.status !== 0) {
    throw new Error(`wasmtime failed:\n${res.stderr || res.stdout}`);
  }
  const parsed = JSON.parse(res.stdout.trim());
  if (!parsed.workloads) {
    throw new Error(`Unexpected wasmtime benchmark output: ${res.stdout}`);
  }
  return parsed;
}

function benchmarkCapabilityDetection(iterations = 200000) {
  // Warmup
  for (let i = 0; i < 5000; i++) {
    detectWasmCapabilities();
  }

  let sink = 0;
  const tJspi0 = performance.now();
  for (let i = 0; i < iterations; i++) {
    const ok =
      typeof WebAssembly.Suspending === "function" &&
      typeof WebAssembly.promising === "function";
    sink ^= ok ? 1 : 0;
  }
  const jspiNsPerOp = ((performance.now() - tJspi0) * 1e6) / iterations;

  const tWait0 = performance.now();
  for (let i = 0; i < iterations; i++) {
    const ok =
      typeof Atomics !== "undefined" && typeof Atomics.waitAsync === "function";
    sink ^= ok ? 1 : 0;
  }
  const waitAsyncNsPerOp = ((performance.now() - tWait0) * 1e6) / iterations;

  const wasmfxIters = 50000;
  const tFx0 = performance.now();
  for (let i = 0; i < wasmfxIters; i++) {
    const ok = WebAssembly.validate(WASMFX_PROBE_BYTES);
    sink ^= ok ? 1 : 0;
  }
  const wasmfxNsPerOp = ((performance.now() - tFx0) * 1e6) / wasmfxIters;

  const tAll0 = performance.now();
  for (let i = 0; i < wasmfxIters; i++) {
    const caps = detectWasmCapabilities();
    sink ^= caps.jspi ? 1 : 0;
  }
  const combinedNsPerOp = ((performance.now() - tAll0) * 1e6) / wasmfxIters;

  return {
    capabilities: detectWasmCapabilities(),
    jspiNsPerOp,
    waitAsyncNsPerOp,
    wasmfxNsPerOp,
    combinedNsPerOp,
    sink,
  };
}

async function runMicrobenchmarks() {
  const caps = detectWasmCapabilities();
  const jspiBytes = Buffer.from(JSPI_BENCH_MODULE_BASE64, "base64");
  const jspiModule = new WebAssembly.Module(jspiBytes);

  const sharedMem = new WebAssembly.Memory({
    initial: 1,
    maximum: 1,
    shared: true,
  });
  const sharedI32 = new Int32Array(sharedMem.buffer);

  // 1. JSPI with Promise.resolve()
  const yieldResolvedImport = new WebAssembly.Suspending(() => Promise.resolve());
  const waitAsyncImport = new WebAssembly.Suspending((byteOffset, expected) => {
    const res = Atomics.waitAsync(sharedI32, byteOffset >> 2, expected);
    return res.async ? res.value : Promise.resolve(res.value);
  });

  const instResolved = new WebAssembly.Instance(jspiModule, {
    env: {
      memory: sharedMem,
      host_yield: yieldResolvedImport,
      host_wait_async: waitAsyncImport,
    },
  });

  // 2. JSPI with queueMicrotask
  const yieldMicrotaskImport = new WebAssembly.Suspending(
    () => new Promise((resolve) => queueMicrotask(resolve)),
  );
  const instMicrotask = new WebAssembly.Instance(jspiModule, {
    env: {
      memory: sharedMem,
      host_yield: yieldMicrotaskImport,
      host_wait_async: waitAsyncImport,
    },
  });

  const jspiYieldResolved = WebAssembly.promising(
    instResolved.exports.bench_jspi_yield,
  );
  const jspiYieldMicrotask = WebAssembly.promising(
    instMicrotask.exports.bench_jspi_yield,
  );
  const triangulateBaseline = instResolved.exports.triangulate_baseline;
  const triangulateJspi = WebAssembly.promising(
    instResolved.exports.triangulate_jspi,
  );
  const futexWaitJspi = WebAssembly.promising(
    instResolved.exports.futex_wait_jspi,
  );
  const futexSpinWait = instResolved.exports.futex_spin_wait;

  // Warmup JSPI
  await jspiYieldResolved(2000);
  await jspiYieldMicrotask(2000);

  const jspiOps = 50000;
  const tJspiRes0 = performance.now();
  await jspiYieldResolved(jspiOps);
  const jspiResolvedNsPerOp = ((performance.now() - tJspiRes0) * 1e6) / jspiOps;

  const tJspiMic0 = performance.now();
  await jspiYieldMicrotask(jspiOps);
  const jspiMicrotaskNsPerOp = ((performance.now() - tJspiMic0) * 1e6) / jspiOps;

  const jspiFullOps = 20000;
  const tJspiFull0 = performance.now();
  for (let i = 0; i < jspiFullOps; i++) {
    await jspiYieldMicrotask(1);
  }
  const jspiFullCallNsPerOp =
    ((performance.now() - tJspiFull0) * 1e6) / jspiFullOps;

  // WasmFX continuation benchmarks (if enabled in this V8 process)
  let wasmfxActiveNsPerOp = null;
  let wasmfxFullContNsPerOp = null;
  let wasmfxInstance = null;

  if (caps.wasmfx) {
    const fxBytes = Buffer.from(WASMFX_BENCH_MODULE_BASE64, "base64");
    const fxMod = new WebAssembly.Module(fxBytes);
    wasmfxInstance = new WebAssembly.Instance(fxMod);

    // Warmup WasmFX
    wasmfxInstance.exports.bench_active_yield(10000);
    wasmfxInstance.exports.bench_full_cont(5000);

    const fxActiveOps = 500000;
    const tFxAct0 = performance.now();
    wasmfxInstance.exports.bench_active_yield(fxActiveOps);
    wasmfxActiveNsPerOp = ((performance.now() - tFxAct0) * 1e6) / fxActiveOps;

    const fxFullOps = 100000;
    const tFxFull0 = performance.now();
    wasmfxInstance.exports.bench_full_cont(fxFullOps);
    wasmfxFullContNsPerOp = ((performance.now() - tFxFull0) * 1e6) / fxFullOps;
  }

  // 3. Cooperative frame-budgeted geometry/triangulation loop (10,000 iterations, yield every 1,000)
  const triSteps = 10000;
  const yieldInterval = 1000;
  const triRuns = 400;

  // Warmup triangulation
  for (let i = 0; i < 30; i++) {
    triangulateBaseline(triSteps);
    await triangulateJspi(triSteps, yieldInterval);
    if (wasmfxInstance) {
      wasmfxInstance.exports.triangulate_wasmfx(triSteps, yieldInterval);
    }
  }

  let expectedChecksum = triangulateBaseline(triSteps);
  const tTriBase0 = performance.now();
  for (let i = 0; i < triRuns; i++) {
    const c = triangulateBaseline(triSteps);
    if (c !== expectedChecksum) throw new Error("Checksum mismatch in baseline");
  }
  const triBaselineUs = ((performance.now() - tTriBase0) * 1000) / triRuns;

  let triWasmfxUs = null;
  if (wasmfxInstance) {
    const tTriFx0 = performance.now();
    for (let i = 0; i < triRuns; i++) {
      const c = wasmfxInstance.exports.triangulate_wasmfx(
        triSteps,
        yieldInterval,
      );
      if (c !== expectedChecksum) throw new Error("Checksum mismatch in WasmFX");
    }
    triWasmfxUs = ((performance.now() - tTriFx0) * 1000) / triRuns;
  }

  const tTriJspi0 = performance.now();
  for (let i = 0; i < triRuns; i++) {
    const c = await triangulateJspi(triSteps, yieldInterval);
    if (c !== expectedChecksum) throw new Error("Checksum mismatch in JSPI");
  }
  const triJspiUs = ((performance.now() - tTriJspi0) * 1000) / triRuns;

  // 4. Main-thread std.Io futex wait (Atomics.waitAsync + JSPI vs spin-wait on SharedArrayBuffer)
  const futexRounds = 12;
  const notifyDelayMs = 2;

  const workerCode = `
    const { parentPort, workerData } = require("node:worker_threads");
    const i32 = new Int32Array(workerData.sharedBuffer);
    parentPort.on("message", (msg) => {
      if (msg.cmd === "notify_after") {
        setTimeout(() => {
          Atomics.store(i32, 2, Math.trunc(performance.now() * 1000));
          Atomics.store(i32, 0, 1);
          Atomics.notify(i32, 0, 1);
        }, msg.delayMs);
      } else if (msg.cmd === "exit") {
        process.exit(0);
      }
    });
  `;

  const notifier = new Worker(workerCode, {
    eval: true,
    workerData: { sharedBuffer: sharedMem.buffer },
  });

  try {
    // Warmup both paths
    Atomics.store(sharedI32, 0, 0);
    notifier.postMessage({ cmd: "notify_after", delayMs: 1 });
    await futexWaitJspi(0, 0);

    Atomics.store(sharedI32, 0, 0);
    notifier.postMessage({ cmd: "notify_after", delayMs: 1 });
    futexSpinWait(0, 0);

    // Measure Atomics.waitAsync + JSPI
    let jspiWallTotalUs = 0;
    let jspiCpuTotalUs = 0;
    let jspiWakeLatencyTotalUs = 0;
    let jspiEventLoopTicks = 0;

    for (let r = 0; r < futexRounds; r++) {
      Atomics.store(sharedI32, 0, 0);
      const tickTimer = setInterval(() => {
        jspiEventLoopTicks++;
      }, 0);
      notifier.postMessage({ cmd: "notify_after", delayMs: notifyDelayMs });
      const cpu0 = process.cpuUsage();
      const wall0 = performance.now();
      await futexWaitJspi(0, 0);
      const wallUs = (performance.now() - wall0) * 1000;
      const cpuDelta = process.cpuUsage(cpu0);
      const wakeNowUs = Math.trunc(performance.now() * 1000);
      const notifySentUs = Atomics.load(sharedI32, 2);
      clearInterval(tickTimer);

      jspiWallTotalUs += wallUs;
      jspiCpuTotalUs += cpuDelta.user + cpuDelta.system;
      jspiWakeLatencyTotalUs += Math.max(0, wakeNowUs - notifySentUs);
    }

    // Measure synchronous Wasm spin-wait
    let spinWallTotalUs = 0;
    let spinCpuTotalUs = 0;
    let spinWakeLatencyTotalUs = 0;
    let spinEventLoopTicks = 0;
    let totalSpinIterations = 0;

    for (let r = 0; r < futexRounds; r++) {
      Atomics.store(sharedI32, 0, 0);
      const tickTimer = setInterval(() => {
        spinEventLoopTicks++;
      }, 0);
      notifier.postMessage({ cmd: "notify_after", delayMs: notifyDelayMs });
      const cpu0 = process.cpuUsage();
      const wall0 = performance.now();
      const spins = futexSpinWait(0, 0);
      const wallUs = (performance.now() - wall0) * 1000;
      const cpuDelta = process.cpuUsage(cpu0);
      const wakeNowUs = Math.trunc(performance.now() * 1000);
      const notifySentUs = Atomics.load(sharedI32, 2);
      clearInterval(tickTimer);

      totalSpinIterations += spins >>> 0;
      spinWallTotalUs += wallUs;
      spinCpuTotalUs += cpuDelta.user + cpuDelta.system;
      spinWakeLatencyTotalUs += Math.max(0, wakeNowUs - notifySentUs);
    }

    return {
      suspension: {
        wasmfxActiveNsPerOp,
        wasmfxFullContNsPerOp,
        jspiResolvedNsPerOp,
        jspiMicrotaskNsPerOp,
        jspiFullCallNsPerOp,
        activeSpeedupVsJspiResolved:
          wasmfxActiveNsPerOp != null
            ? jspiResolvedNsPerOp / wasmfxActiveNsPerOp
            : null,
        activeSpeedupVsJspiMicrotask:
          wasmfxActiveNsPerOp != null
            ? jspiMicrotaskNsPerOp / wasmfxActiveNsPerOp
            : null,
        fullContSpeedupVsJspiFullCall:
          wasmfxFullContNsPerOp != null
            ? jspiFullCallNsPerOp / wasmfxFullContNsPerOp
            : null,
      },
      triangulation: {
        steps: triSteps,
        yieldInterval,
        yieldsPerCall: triSteps / yieldInterval,
        checksum: expectedChecksum,
        baselineUs: triBaselineUs,
        wasmfxUs: triWasmfxUs,
        jspiUs: triJspiUs,
        wasmfxOverheadPct:
          triWasmfxUs != null
            ? ((triWasmfxUs - triBaselineUs) / triBaselineUs) * 100
            : null,
        jspiOverheadPct: ((triJspiUs - triBaselineUs) / triBaselineUs) * 100,
      },
      futexWait: {
        rounds: futexRounds,
        notifyDelayMs,
        waitAsyncJspi: {
          avgWallUs: jspiWallTotalUs / futexRounds,
          avgCpuUs: jspiCpuTotalUs / futexRounds,
          avgWakeLatencyUs: jspiWakeLatencyTotalUs / futexRounds,
          eventLoopTicksPerWait: jspiEventLoopTicks / futexRounds,
        },
        spinWait: {
          avgWallUs: spinWallTotalUs / futexRounds,
          avgCpuUs: spinCpuTotalUs / futexRounds,
          avgWakeLatencyUs: spinWakeLatencyTotalUs / futexRounds,
          eventLoopTicksPerWait: spinEventLoopTicks / futexRounds,
          avgSpinLoads: totalSpinIterations / futexRounds,
        },
      },
    };
  } finally {
    notifier.postMessage({ cmd: "exit" });
    await notifier.terminate();
  }
}

function getWasmtimeVersion() {
  const bin = findExecutable("wasmtime");
  if (!bin) return null;
  const res = spawnSync(bin, ["--version"], { encoding: "utf8" });
  return res.status === 0 ? res.stdout.trim() : null;
}

function formatNum(n, digits = 2) {
  if (n == null || Number.isNaN(n)) return "n/a";
  return Number(n).toFixed(digits);
}

function renderMarkdownReport(report) {
  const lines = [];
  lines.push("# V8 / Node 26 vs Wasmtime & WasmFX / JSPI Benchmark Results");
  lines.push("");
  lines.push("## Environment");
  lines.push("");
  lines.push(`- **Node.js**: \`${report.environment.nodeVersion}\` (V8 \`${report.environment.v8Version}\`)`);
  lines.push(`- **Wasmtime**: \`${report.environment.wasmtimeVersion || "not installed"}\``);
  lines.push(`- **Platform**: \`${report.environment.platform}-${report.environment.arch}\``);
  if (report.build && report.build.compilerKind) {
    lines.push(
      `- **Wasm artifact**: \`wasm_bench_runner.wasm\` (${report.build.sizeBytes.toLocaleString()} bytes, built with \`${report.build.compilerKind}\` in ${formatNum(report.build.compileMs, 0)} ms)`,
    );
  }
  lines.push("");

  lines.push("## 1. Synchronous `knots` Workloads (`wasm_bench_runner.wasm`)");
  lines.push("");
  lines.push(
    "| Benchmark | Iterations | Wasmtime Median (ms) | Node Default Median (ms) | Node + WasmFX Flags Median (ms) | Node / Wasmtime | WasmFX Flags / Default |",
  );
  lines.push(
    "|---|---:|---:|---:|---:|---:|---:|",
  );

  for (const name of SYNC_BENCHMARKS) {
    const wt = report.syncBenchmarks.wasmtime?.workloads?.[name];
    const nd = report.syncBenchmarks.nodeDefault.workloads[name];
    const fx = report.syncBenchmarks.nodeWasmfx.workloads[name];
    const wtMs = wt ? wt.median_ms : null;
    const ndMs = nd.median_ms;
    const fxMs = fx.median_ms;
    const ndVsWt = wtMs ? `${formatNum(ndMs / wtMs, 2)}x` : "n/a";
    const fxVsNd = `${formatNum(fxMs / ndMs, 2)}x`;
    lines.push(
      `| \`${name}\` | ${nd.iterations} | ${wtMs != null ? formatNum(wtMs, 4) : "n/a"} | ${formatNum(ndMs, 4)} | ${formatNum(fxMs, 4)} | ${ndVsWt} | ${fxVsNd} |`,
    );
  }
  if (report.syncBenchmarks.wasmtime) {
    lines.push(
      `| **\`total_bench_ms\`** | — | **${formatNum(report.syncBenchmarks.wasmtime.total_bench_ms, 2)} ms** | **${formatNum(report.syncBenchmarks.nodeDefault.total_bench_ms, 2)} ms** | **${formatNum(report.syncBenchmarks.nodeWasmfx.total_bench_ms, 2)} ms** | **${formatNum(report.syncBenchmarks.nodeDefault.total_bench_ms / report.syncBenchmarks.wasmtime.total_bench_ms, 2)}x** | **${formatNum(report.syncBenchmarks.nodeWasmfx.total_bench_ms / report.syncBenchmarks.nodeDefault.total_bench_ms, 2)}x** |`,
    );
  }
  lines.push("");

  lines.push("## 2. Runtime Capability Detection (`detectWasmCapabilities()`)");
  lines.push("");
  lines.push(
    "| Capability Check | Mechanism | Node Default | Node + `--experimental-wasm-wasmfx` | Probe Cost (ns/op) |",
  );
  lines.push("|---|---|:---:|:---:|---:|");
  const capDef = report.capabilityDetection.nodeDefault;
  const capFx = report.capabilityDetection.nodeWasmfx;
  lines.push(
    `| \`JSPI\` | \`typeof WebAssembly.Suspending === "function" && typeof WebAssembly.promising === "function"\` | \`${capDef.capabilities.jspi}\` | \`${capFx.capabilities.jspi}\` | ${formatNum(capFx.jspiNsPerOp, 2)} ns |`,
  );
  lines.push(
    `| \`Atomics.waitAsync\` | \`typeof Atomics.waitAsync === "function"\` | \`${capDef.capabilities.waitAsync}\` | \`${capFx.capabilities.waitAsync}\` | ${formatNum(capFx.waitAsyncNsPerOp, 2)} ns |`,
  );
  lines.push(
    `| \`WasmFX\` | \`WebAssembly.validate(WASMFX_PROBE_BYTES)\` (16-byte \`0x5d\` \`cont\` section) | \`${capDef.capabilities.wasmfx}\` | \`${capFx.capabilities.wasmfx}\` | ${formatNum(capFx.wasmfxNsPerOp, 2)} ns |`,
  );
  lines.push(
    `| **Combined** | \`detectWasmCapabilities()\` (uncached cold call) | — | — | ${formatNum(capFx.combinedNsPerOp, 2)} ns |`,
  );
  lines.push("");

  lines.push("## 3. `std.Io` Coroutine Suspend/Resume Microbenchmarks (V8)");
  lines.push("");
  const susp = report.microbenchmarks.suspension;
  lines.push(
    "| Mechanism | Operation | Latency (ns/op) | Throughput (M ops/s) | Comparison |",
  );
  lines.push("|---|---|---:|---:|---:|");
  lines.push(
    `| **WasmFX (active stack)** | \`suspend $yield\` + \`resume $ct\` on warm continuation | ${formatNum(susp.wasmfxActiveNsPerOp, 2)} ns | ${formatNum(1000 / susp.wasmfxActiveNsPerOp, 2)} M/s | **${formatNum(susp.activeSpeedupVsJspiResolved, 2)}x faster** than JSPI (\`Promise.resolve\`), **${formatNum(susp.activeSpeedupVsJspiMicrotask, 2)}x faster** than JSPI (\`queueMicrotask\`) |`,
  );
  lines.push(
    `| **JSPI (active stack, \`Promise.resolve\`)** | \`WebAssembly.Suspending\` + \`WebAssembly.promising\` immediate Promise | ${formatNum(susp.jspiResolvedNsPerOp, 2)} ns | ${formatNum(1000 / susp.jspiResolvedNsPerOp, 2)} M/s | 1.00x (active-stack JSPI baseline) |`,
  );
  lines.push(
    `| **JSPI (active stack, \`queueMicrotask\`)** | \`WebAssembly.Suspending\` + \`new Promise(r => queueMicrotask(r))\` | ${formatNum(susp.jspiMicrotaskNsPerOp, 2)} ns | ${formatNum(1000 / susp.jspiMicrotaskNsPerOp, 2)} M/s | ${formatNum(susp.jspiMicrotaskNsPerOp / susp.jspiResolvedNsPerOp, 2)}x of JSPI (\`Promise.resolve\`) |`,
  );
  lines.push(
    `| **WasmFX (full lifecycle)** | \`cont.new\` + \`resume\` (1 suspend) + \`resume\` to completion | ${formatNum(susp.wasmfxFullContNsPerOp, 2)} ns | ${formatNum(1000 / susp.wasmfxFullContNsPerOp, 2)} M/s | **${formatNum(susp.fullContSpeedupVsJspiFullCall, 2)}x faster** than full-lifecycle JSPI |`,
  );
  lines.push(
    `| **JSPI (full lifecycle, \`queueMicrotask\`)** | \`await promisingExport(1)\` (enter stack + 1 suspend + exit) | ${formatNum(susp.jspiFullCallNsPerOp, 2)} ns | ${formatNum(1000 / susp.jspiFullCallNsPerOp, 2)} M/s | 1.00x (full-lifecycle JSPI baseline) |`,
  );
  lines.push("");

  lines.push(
    "## 4. Cooperative Frame-Budgeted Polygon Triangulation (10,000 steps, yield every 1,000)",
  );
  lines.push("");
  const tri = report.microbenchmarks.triangulation;
  lines.push(
    "| Mode | Yields / Call | Total Time (us) | Yield Overhead (us) | Overhead (%) | Checksum |",
  );
  lines.push("|---|---:|---:|---:|---:|---:|");
  lines.push(
    `| **Un-instrumented Wasm baseline** | 0 | ${formatNum(tri.baselineUs, 2)} us | 0.00 us | 0.0% | \`${tri.checksum}\` |`,
  );
  lines.push(
    `| **WasmFX (\`suspend\` / \`resume\`)** | ${tri.yieldsPerCall} | ${formatNum(tri.wasmfxUs, 2)} us | +${formatNum(tri.wasmfxUs - tri.baselineUs, 2)} us | +${formatNum(tri.wasmfxOverheadPct, 1)}% | \`${tri.checksum}\` |`,
  );
  lines.push(
    `| **JSPI (\`Suspending\` / \`promising\`)** | ${tri.yieldsPerCall} | ${formatNum(tri.jspiUs, 2)} us | +${formatNum(tri.jspiUs - tri.baselineUs, 2)} us | +${formatNum(tri.jspiOverheadPct, 1)}% | \`${tri.checksum}\` |`,
  );
  lines.push("");

  lines.push(
    "## 5. Main-Thread `std.Io` Futex Wait (`SharedArrayBuffer` `Int32Array`, 2 ms Worker Notify)",
  );
  lines.push("");
  const fw = report.microbenchmarks.futexWait;
  lines.push(
    "| Wait Strategy | Avg Wall Wait (us) | Avg Main-Thread CPU Burned (us) | Main-Thread Event-Loop Ticks During Wait | CPU Savings |",
  );
  lines.push("|---|---:|---:|---:|---:|");
  const cpuSavedPct =
    ((fw.spinWait.avgCpuUs - fw.waitAsyncJspi.avgCpuUs) /
      fw.spinWait.avgCpuUs) *
    100;
  lines.push(
    `| **\`Atomics.waitAsync\` + JSPI** | ${formatNum(fw.waitAsyncJspi.avgWallUs, 1)} us | **${formatNum(fw.waitAsyncJspi.avgCpuUs, 1)} us** | ${formatNum(fw.waitAsyncJspi.eventLoopTicksPerWait, 1)} ticks (non-blocking) | **${formatNum(cpuSavedPct, 1)}% less CPU** |`,
  );
  lines.push(
    `| **Synchronous Wasm Spin-Wait (\`i32.atomic.load\`)** | ${formatNum(fw.spinWait.avgWallUs, 1)} us | ${formatNum(fw.spinWait.avgCpuUs, 1)} us | ${formatNum(fw.spinWait.eventLoopTicksPerWait, 1)} ticks (blocked) | 0.0% (100% core pinned) |`,
  );

  return lines.join("\n");
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.internalWasmfxChild) {
    const syncNodeWasmfx = runAllSyncBenchmarksInNode(opts.wasm);
    const capWasmfx = benchmarkCapabilityDetection();
    const micro = await runMicrobenchmarks();
    process.stdout.write(
      JSON.stringify({ syncNodeWasmfx, capWasmfx, micro }) + "\n",
    );
    return;
  }

  if (opts.internalDefaultNodeChild) {
    const syncNodeDefault = runAllSyncBenchmarksInNode(opts.wasm);
    const capDefault = benchmarkCapabilityDetection();
    process.stdout.write(
      JSON.stringify({ syncNodeDefault, capDefault }) + "\n",
    );
    return;
  }

  const buildInfo = opts.wasm
    ? {
        wasmPath: path.resolve(opts.wasm),
        compilerKind: null,
        compileMs: 0,
        sizeBytes: fs.statSync(path.resolve(opts.wasm)).size,
        tempDir: null,
      }
    : {
        ...buildWasmBenchRunner(),
        tempDir: path.join(REPO_ROOT, ".cache-bench", "wasmfx"),
      };

  try {
    const currentCaps = detectWasmCapabilities();
    let syncNodeDefault;
    let capDefault;
    let syncNodeWasmfx;
    let capWasmfx;
    let micro;

    if (!currentCaps.wasmfx) {
      syncNodeDefault = runAllSyncBenchmarksInNode(buildInfo.wasmPath);
      capDefault = benchmarkCapabilityDetection();

      const childRes = spawnSync(
        process.execPath,
        [
          "--experimental-wasm-wasmfx",
          "--experimental-wasm-growable-stacks",
          SCRIPT_PATH,
          "--internal-wasmfx-child",
          "--wasm",
          buildInfo.wasmPath,
        ],
        { cwd: REPO_ROOT, encoding: "utf8" },
      );
      if (childRes.status !== 0) {
        throw new Error(
          `WasmFX child process failed:\n${childRes.stderr || childRes.stdout}`,
        );
      }
      const parsedChild = JSON.parse(childRes.stdout.trim());
      syncNodeWasmfx = parsedChild.syncNodeWasmfx;
      capWasmfx = parsedChild.capWasmfx;
      micro = parsedChild.micro;
    } else {
      syncNodeWasmfx = runAllSyncBenchmarksInNode(buildInfo.wasmPath);
      capWasmfx = benchmarkCapabilityDetection();
      micro = await runMicrobenchmarks();

      const filteredExecArgv = process.execArgv.filter(
        (flag) =>
          flag !== "--experimental-wasm-wasmfx" &&
          flag !== "--experimental-wasm-growable-stacks",
      );
      const childRes = spawnSync(
        process.execPath,
        [
          ...filteredExecArgv,
          SCRIPT_PATH,
          "--internal-default-node-child",
          "--wasm",
          buildInfo.wasmPath,
        ],
        { cwd: REPO_ROOT, encoding: "utf8", env: { ...process.env, NODE_OPTIONS: "" } },
      );
      if (childRes.status !== 0) {
        throw new Error(
          `Default Node child process failed:\n${childRes.stderr || childRes.stdout}`,
        );
      }
      const parsedChild = JSON.parse(childRes.stdout.trim());
      syncNodeDefault = parsedChild.syncNodeDefault;
      capDefault = parsedChild.capDefault;
    }

    const syncWasmtime = runAllSyncBenchmarksInWasmtime(buildInfo.wasmPath);

    const report = {
      environment: {
        nodeVersion: process.version,
        v8Version: process.versions.v8,
        wasmtimeVersion: getWasmtimeVersion(),
        platform: process.platform,
        arch: process.arch,
      },
      build: {
        compilerKind: buildInfo.compilerKind,
        compileMs: buildInfo.compileMs,
        sizeBytes: buildInfo.sizeBytes,
      },
      syncBenchmarks: {
        wasmtime: syncWasmtime,
        nodeDefault: syncNodeDefault,
        nodeWasmfx: syncNodeWasmfx,
      },
      capabilityDetection: {
        nodeDefault: capDefault,
        nodeWasmfx: capWasmfx,
      },
      microbenchmarks: micro,
    };

    if (opts.json) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(renderMarkdownReport(report));
    }
  } finally {
    if (buildInfo.tempDir) {
      fs.rmSync(buildInfo.tempDir, { recursive: true, force: true });
      const parentCacheDir = path.dirname(buildInfo.tempDir);
      try {
        if (fs.readdirSync(parentCacheDir).length === 0) {
          fs.rmdirSync(parentCacheDir);
        }
      } catch {
        // ignore
      }
    }
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_PATH) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
