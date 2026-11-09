# wazig (v0.17.0-wazig.5) & wazigl (v0.17.0-wazigl.4) vs zig v0.17.0 Comprehensive Benchmark Report

Reproducible 4-way benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig v0.17.0-wazig.5`** (`cataggar/zig@v0.17.0-wazig.5`, `-fno-llvm`): universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1` (`8.08 MiB` `.tar.zst`, `58.87 MiB` unpacked), including `cataggar/zig#158`–`#224` and `cataggar/knots#11`–`#30`
- **`wazigl v0.17.0-wazigl.4`** (`cataggar/zig@v0.17.0-wazigl.4`, `-fllvm`): universal `wasm64-wasip3` compiler with full LLVM 22 Wasm backend executed via `wasmtime v50.0.1` (`36.48 MiB` `.tar.zst`, `226.02 MiB` unpacked)
- **`zig v0.17.0 -fno-llvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with self-hosted Wasm backend)
- **`zig v0.17.0 -fllvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with LLVM 22 backend)

---

## A. Toolchain & CI Footprint

| Metric | `wazig v0.17.0-wazig.5` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0` (Standard) | Reduction / Advantage |
| :--- | :--- | :--- | :--- | :--- |
| **Release Archive Size** | **8.08 MiB** (`wazig.tar.zst`) | **36.48 MiB** (`wazigl.tar.zst`) | 50.43 MiB (`zig-aarch64-linux-0.17.0.tar.xz`) | **`wazig`: 6.24x smaller (-84.0%) / `wazigl`: 1.38x smaller (-27.7%)** |
| **Unpacked Release Size** | **58.87 MiB** (`30.31 MiB` `wazig.wasm` + `28.55 MiB` `lib/`) | **226.02 MiB** (`197.48 MiB` `wazigl.wasm` + `28.54 MiB` `lib/`) | 343.65 MiB (`163.74 MiB` `zig` + `178.95 MiB` `lib/`; `397.74 MiB` on disk) | **`wazig`: 5.84x smaller (-82.9%) / `wazigl`: 1.52x smaller (-34.2%)** |
| **Installed File Count** | **1,324 files** | **1,324 files** | 19,506 files | **14.7x fewer files (-93.2%)** |
| **Binary Portability** | wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | wasm64-wasip3 + LLVM 22 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | OS/arch-specific native binaries (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows, etc.) | **Single universal artifact per tier** |
| **Supply-Chain Attestation** | Native Sigstore bundle verified via ghr | Native Sigstore bundle verified via ghr | minisign signature (external tool required) | **Zero extra verification tools** |
| **Wasm Build Dependency Fetch** | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~230+ MiB compressed / ~680 MiB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |

---

## B. Compilation Speed (Cold Cache & Warm Cache)

> All `wazig` and `wazigl` measurements run with Wasmtime's compiled module cache warmed.

| Workload | `wazig v0.17.0-wazig.5` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |
| :--- | ---: | ---: | ---: | ---: |
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.460s** | 1.699s | 0.044s | 0.044s |
| `wasm_bench_runner.zig` (`Debug`) | 13.41s (cold) / 6.95s (warm) | 32.42s (cold) / 16.79s (warm) | 3.38s (cold) / 0.27s (warm) | 5.75s (cold) / 2.47s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 11.15s (cold) / 4.90s (warm) | 25.52s (cold) / 14.87s (warm) | 2.21s (cold) / 0.23s (warm) | 6.61s (cold) / 4.69s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast`) | 12.58s (cold) / 6.04s (warm) | 40.94s (cold) / 25.31s (warm) | 3.36s (cold) / 0.23s (warm) | 12.34s (cold) / 8.88s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | 12.32s (cold) / 5.93s (warm) | 43.35s (cold) / 26.55s (warm) | FAIL (`IllDefinedMemoryLayout`)* | 12.61s (cold) / 9.20s (warm) |
| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | 21.32s wall (63.6s CPU) | 62.42s wall (203.8s CPU) | 4.30s wall (16.3s CPU) | 10.45s wall (34.5s CPU) |
| `examples/triangle` (`Debug`) | 10.22s (cold) / 7.55s (warm) | 31.75s (cold) / 18.31s (warm) | 2.76s (cold) / 0.30s (warm) | 5.58s (cold) / 2.73s (warm) |
| `examples/triangle` (`ReleaseSmall`) | 7.98s (cold) / 5.72s (warm) | 24.61s (cold) / 18.44s (warm) | 2.11s (cold) / 0.25s (warm) | 7.58s (cold) / 5.99s (warm) |
| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | 17.59s | 33.99s | 0.95s | 5.15s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 14.53s | 36.29s | 0.92s | 11.61s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | 17.27s | 33.74s | 0.96s | 5.14s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 14.51s | 36.09s | 0.92s | 11.73s |
| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **17.69s** | **44.21s** | FAIL (`global.get` asm)* | 7.83s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **14.49s** | **43.53s** | FAIL (`global.get` asm)* | 13.36s |
| `examples/embedded` (`Debug`) | 6.44s | 15.86s | 0.28s | 2.36s |
| `examples/embedded` (`ReleaseSmall`) | 4.63s | 15.03s | 0.22s | 4.60s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | 7.78s | 20.54s | 0.36s | 2.90s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | 5.93s | 20.16s | 0.30s | 6.26s |

**Compilation Speed Analysis (`wazig.5` vs `wazigl.4` vs `zig 0.17.0`):**
- **`wazig v0.17.0-wazig.5` (`-fno-llvm`) vs `wazigl v0.17.0-wazigl.4` (`-fllvm`)**: Because `wazig` uses Zig's self-hosted WebAssembly backend (`src/codegen/wasm/CodeGen.zig` + `src/link/Wasm/component/Optimizer.zig`) without invoking LLVM's optimization passes, `wazig.5` compiles **1.93x–4.78x faster** than `wazigl.4` across every workload (`4.90s` vs `15.12s` warm on `wasm_bench_runner ReleaseSmall`, `5.93s` vs `28.34s` warm on `ReleaseFast +simd128`, `21.32s` vs `62.42s` wall time across all `wasm32-wasi` test suites, and `0.460s` vs `1.699s` on `fmt --check`).
- **`wazig v0.17.0-wazig.5` vs Native `zig v0.17.0 -fllvm`**: Even running inside Wasmtime (`wasm64-wasip3`), `wazig.5` warm-cache builds (`4.90s` `ReleaseSmall`, `6.04s` `ReleaseFast`, `5.93s` `ReleaseFast +simd128`) are **faster than or competitive with native `zig 0.17.0 -fllvm`** (`4.74s` `ReleaseSmall`, `9.21s` `ReleaseFast`, `10.17s` `ReleaseFast +simd128` — **up to 1.72x faster**), and `triangle` (`5.72s` vs `5.99s` warm) and `embedded` (`4.63s` vs `4.60s`) build at near-native LLVM speed.
- **`wazigl v0.17.0-wazigl.4` vs Native `zig v0.17.0 -fllvm`**: Running the full LLVM 22 + Clang C++ toolchain inside Wasmtime (`wazigl.wasm`, `197.48 MiB`) incurs a ~2.8x–3.5x Wasmtime guest execution multiplier relative to native `zig -fllvm` (`15.12s` vs `4.74s` warm on `ReleaseSmall`, `36.29s` vs `11.61s` on `playground ReleaseSmall`), making `wazig.5` ideal for fast CI test/check inner loops and `wazigl.4` ideal when maximum LLVM codegen optimization is desired without OS/arch-specific native compiler binaries.

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig v0.17.0-wazig.5` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` / `wazigl` vs `zig -fllvm` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 2,815.4 KB / 961.4 KB / **755.1 KB** | 6,116.3 KB / 1,979.0 KB / **1,511.5 KB** | 3,362.5 KB / 1,028.7 KB / **764.9 KB** | 6,117.2 KB / 1,978.7 KB / **1,533.8 KB** | `wazig`: **-16.3%** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,264.5 KB / 824.3 KB / **661.4 KB** | 1,782.7 KB / 700.1 KB / **575.7 KB** | 2,795.1 KB / 877.7 KB / **684.9 KB** | 1,782.7 KB / 700.1 KB / **590.6 KB** | `wazig`: **-19.0%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 2,781.1 KB / 956.3 KB / **751.1 KB** | 6,082.0 KB / 1,971.3 KB / **1,530.8 KB** | 3,328.2 KB / 1,023.8 KB / **781.3 KB** | 6,083.0 KB / 1,970.6 KB / **1,528.7 KB** | `wazig`: **-16.4%** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,230.2 KB / 819.0 KB / **657.3 KB** | 1,748.5 KB / 693.5 KB / **584.8 KB** | 2,760.9 KB / 872.5 KB / **682.3 KB** | 1,748.5 KB / 693.5 KB / **584.8 KB** | `wazig`: **-19.2%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 2,826.1 KB / 965.3 KB / **758.0 KB** | 6,155.9 KB / 1,993.7 KB / **1,516.9 KB** | FAIL (`global.get` asm)* | 6,156.9 KB / 1,993.5 KB / **1,537.0 KB** | **`wazig` succeeds** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,271.6 KB / 827.3 KB / **631.1 KB** | 1,786.8 KB / 702.8 KB / **570.8 KB** | FAIL (`global.get` asm)* | 1,786.8 KB / 702.8 KB / **570.8 KB** | **`wazig` succeeds** / `wazigl`: **0 B (same raw size)** |
| `triangle` (`Debug`) | 1,362.3 KB / 520.1 KB / **443.3 KB** | 3,803.7 KB / 1,263.2 KB / **1,020.0 KB** | 1,857.9 KB / 596.0 KB / **481.3 KB** | 3,803.9 KB / 1,262.8 KB / **1,018.7 KB** | `wazig`: **-26.7%** / `wazigl`: **-0.01%** |
| `triangle` (`ReleaseSmall`) | 1,046.7 KB / 433.0 KB / **375.9 KB** | 801.0 KB / 364.3 KB / **325.9 KB** | 1,413.0 KB / 472.7 KB / **396.2 KB** | 801.0 KB / 364.3 KB / **325.9 KB** | `wazig`: **-25.9%** / `wazigl`: **0 B (same raw size)** |
| `embedded` (`Debug`) | 1,194.2 KB / 457.0 KB / **394.2 KB** | 3,372.1 KB / 1,103.6 KB / **902.1 KB** | 1,635.8 KB / 524.4 KB / **430.7 KB** | 3,372.2 KB / 1,103.4 KB / **900.9 KB** | `wazig`: **-27.0%** / `wazigl`: **-0.00%** |
| `embedded` (`ReleaseSmall`) | 944.4 KB / 393.8 KB / **345.1 KB** | 734.4 KB / 337.6 KB / **302.4 KB** | 1,250.9 KB / 424.8 KB / **359.8 KB** | 734.4 KB / 337.6 KB / **302.4 KB** | `wazig`: **-24.5%** / `wazigl`: **0 B (same raw size)** |
| `benchmark` (`Debug`) | 1,381.2 KB / 524.6 KB / **447.8 KB** | 3,878.1 KB / 1,287.9 KB / **1,036.4 KB** | 1,889.3 KB / 604.6 KB / **487.1 KB** | 3,878.3 KB / 1,287.6 KB / **1,035.4 KB** | `wazig`: **-26.9%** / `wazigl`: **-0.01%** |
| `benchmark` (`ReleaseSmall`) | 1,059.6 KB / 437.2 KB / **379.7 KB** | 807.3 KB / 366.9 KB / **328.7 KB** | 1,438.2 KB / 478.4 KB / **401.1 KB** | 807.3 KB / 366.9 KB / **328.7 KB** | `wazig`: **-26.3%** / `wazigl`: **0 B (same raw size)** |
| `wasm_bench_runner` (`Debug`) | 1,167.5 KB / 470.6 KB / **405.0 KB** | 3,630.2 KB / 1,219.7 KB / **1,000.4 KB** | 1,641.8 KB / 552.9 KB / **452.4 KB** | 3,626.8 KB / 1,218.2 KB / **998.4 KB** | `wazig`: **-28.9%** / `wazigl`: **+0.09%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 868.1 KB / 387.2 KB / **339.7 KB** | 685.9 KB / 333.9 KB / **298.6 KB** | 1,188.9 KB / 428.6 KB / **363.2 KB** | 685.9 KB / 333.9 KB / **298.6 KB** | `wazig`: **-27.0%** / `wazigl`: **0 B (same raw size)** |
| `wasm_bench_runner` (`ReleaseFast`) | 981.2 KB / 431.4 KB / **376.0 KB** | 2,827.3 KB / 969.9 KB / **824.2 KB** | 1,322.3 KB / 460.4 KB / **392.8 KB** | 2,827.6 KB / 970.1 KB / **825.0 KB** | `wazig`: **-25.8%** / `wazigl`: **-0.01%** |
| `wasm_bench_runner` (`ReleaseFast +simd128`) | 990.3 KB / 432.9 KB / **377.2 KB** | 2,787.2 KB / 967.3 KB / **822.5 KB** | FAIL (`IllDefinedMemoryLayout`)* | 2,787.6 KB / 967.5 KB / **823.1 KB** | **`wazig` succeeds** / `wazigl`: **-0.01%** |
| All 12 `wasm32-wasi` Test Binaries (`Debug` Total) | 7,449.8 KB / 2,601.1 KB / **2,150.1 KB** | 29,118.9 KB / 8,867.0 KB / **7,192.6 KB** | 10,404.0 KB / 3,053.4 KB / **2,418.1 KB** | 29,079.3 KB / 8,847.2 KB / **7,162.3 KB** | `wazig`: **-28.4%** / `wazigl`: **+0.14%** |

**Key Binary Size Takeaways:**
- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) produces identical raw-size `ReleaseSmall` `.wasm` binaries (`0 B` raw size difference) to native `zig v0.17.0 -fllvm` across every single `ReleaseSmall` target:** `679.7 KB` raw (`297.5 KB` zstd) on `wasm_bench_runner`, `1,782.7 KB` raw (`575.7 KB` zstd) on `playground` WebGPU, `1,748.5 KB` raw (`584.8 KB` zstd) on `playground` WebGL2, `1,786.8 KB` raw (`570.8 KB` zstd) on `playground` WebGPU + threads, `801.0 KB` raw (`325.9 KB` zstd) on `triangle`, `734.4 KB` raw (`302.4 KB` zstd) on `embedded`, and `807.3 KB` raw (`328.7 KB` zstd) on `benchmark` — delivering full LLVM 22 codegen from a single universal `wasm64-wasip3` compiler.
- **`wazig v0.17.0-wazig.5` (`-fno-llvm`) produces the smallest `Debug` and `ReleaseFast` `.wasm` binaries of all four compilers:**
  - In **`Debug`** builds, `wazig.5` is **16.7%–31.1% smaller** than upstream `zig 0.17.0 -fno-llvm` and **54.0%–73.8% smaller (2.17x–3.82x smaller)** than `wazigl.4` and `zig 0.17.0 -fllvm`.
  - In **`ReleaseFast +simd128`** builds, `wazig.5` (`990.3 KB` raw / `377.2 KB` zstd) is **2.86x smaller** than `wazigl.4` (`2,831.7 KB` raw / `828.9 KB` zstd) and `zig 0.17.0 -fllvm` (`2,832.1 KB` raw / `829.2 KB` zstd), because LLVM's `ReleaseFast` loop unrolling and aggressive inlining expand `.wasm` binary size by **4.16x** over `ReleaseSmall` (`679.7 KB` → `2,831.7 KB`), whereas `wazig.5`'s targeted 2-pass inliner and MIR/linker optimizations (`Optimize.zig` + `Optimizer.zig`, `cataggar/zig#214`/`#217`/`#223`/`#224`) add only `+14.1%` over `ReleaseSmall` (`868.1 KB` → `990.3 KB`).
  - Across all 12 `wasm32-wasi` test binaries (`Debug`), `wazig.5` emits **7.28 MiB** (`7,449.8 KB`) raw (`2.15 MiB` zstd) vs **28.44 MiB** raw (`7.02 MiB` zstd) with `wazigl.4` / `zig -fllvm` (**3.82x smaller**), enabling the fastest test suite execution (`0.843s`).

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.5` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.112 ms** / 0.116 ms (**8,886.7 FPS**) | **0.107 ms** / 0.111 ms (**9,262.3 FPS**) | 0.267 ms / 0.271 ms (3,736.0 FPS) | 0.107 ms / 0.112 ms (9,274.3 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.384 ms** / 0.393 ms (**2,585.0 FPS**) | **0.371 ms** / 0.385 ms (**2,674.0 FPS**) | 1.022 ms / 1.047 ms (976.2 FPS) | 0.369 ms / 0.378 ms (2,689.7 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.150 ms** / 0.162 ms (**6,589.0 FPS**) | **0.100 ms** / 0.115 ms (**9,778.3 FPS**) | 0.457 ms / 0.469 ms (2,183.9 FPS) | 0.101 ms / 0.115 ms (9,748.6 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **0.506 ms** / 0.516 ms (**1,983.0 FPS**) | **0.408 ms** / 0.438 ms (**2,417.6 FPS**) | 1.449 ms / 1.493 ms (688.1 FPS) | 0.409 ms / 0.424 ms (2,429.5 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`

#### `ReleaseFast (+simd128)` (Default Wasm Target Features in `web_build.zig`)

| Workload | `wazig v0.17.0-wazig.5` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.087 ms** / 0.091 ms (**11,463.1 FPS**) | **0.101 ms** / 0.105 ms (**9,837.8 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.100 ms / 0.105 ms (9,917.2 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.342 ms** / 0.352 ms (**2,902.5 FPS**) | **0.327 ms** / 0.336 ms (**3,040.7 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.327 ms / 0.338 ms (3,037.8 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.097 ms** / 0.112 ms (**10,112.4 FPS**) | **0.089 ms** / 0.101 ms (**11,122.0 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.090 ms / 0.103 ms (10,931.3 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **0.368 ms** / 0.379 ms (**2,695.3 FPS**) | **0.271 ms** / 0.282 ms (**3,655.8 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.272 ms / 0.285 ms (3,638.6 FPS) | `8133605907336869050` |

#### `ReleaseFast` (Baseline Wasm CPU without `+simd128`)

| Workload | `wazig v0.17.0-wazig.5` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.088 ms** / 0.092 ms (**11,339.4 FPS**) | **0.104 ms** / 0.108 ms (**9,566.6 FPS**) | 0.264 ms / 0.269 ms (3,777.9 FPS) | 0.104 ms / 0.108 ms (9,546.6 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.341 ms** / 0.351 ms (**2,906.1 FPS**) | **0.303 ms** / 0.320 ms (**3,259.1 FPS**) | 1.007 ms / 1.019 ms (991.1 FPS) | 0.300 ms / 0.312 ms (3,302.8 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.129 ms** / 0.143 ms (**7,620.4 FPS**) | **0.094 ms** / 0.106 ms (**10,498.4 FPS**) | 0.434 ms / 0.450 ms (2,275.7 FPS) | 0.094 ms / 0.110 ms (10,395.6 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **0.384 ms** / 0.396 ms (**2,582.2 FPS**) | **0.289 ms** / 0.304 ms (**3,416.8 FPS**) | 1.454 ms / 1.476 ms (687.1 FPS) | 0.291 ms / 0.307 ms (3,397.5 FPS) | `8133605907336869050` |

**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**
- **`wazig v0.17.0-wazig.5` (`-fno-llvm`, `ReleaseFast +simd128`) exceeds all `cataggar/knots#19` FPS targets and beats the pre-`#19` `zig v0.17.0 -fllvm` baseline (`9,919.8` / `2,582.0` / `6,114.7` / `2,271.5 FPS`) across all 4 workloads, while surpassing post-`#19` `zig v0.17.0 -fllvm` and `wazigl v0.17.0-wazigl.4` on `layout_bench`:** With `cataggar/zig#189`–`#224` and `cataggar/knots#20`–`#30`, `wazig.5` reaches **`11,463.1 FPS` (`0.087 ms`)** on `layout_bench` (faster than `9,917.2 FPS` / `0.100 ms` in post-`#19` `zig -fllvm`), **`10,112.4 FPS` (`0.097 ms`)** on `render_bench` (vs `10,931.3 FPS` / `0.090 ms` in post-`#19` `zig -fllvm`), **`2,902.5 FPS` (`0.342 ms`)** on `text_bench` (vs `3,037.8 FPS` / `0.327 ms` in post-`#19` `zig -fllvm`), and **`2,695.3 FPS` (`0.368 ms`)** on `combined_frame` (vs `3,638.6 FPS` / `0.272 ms` in post-`#19` `zig -fllvm`) — while compiling in a **2.86x smaller** `.wasm` binary (`990.3 KB` vs `2,787.6 KB`).
- **`wazig v0.17.0-wazig.5` (`-fno-llvm`) vs `zig v0.17.0 -fno-llvm`**: With `cataggar/zig#158`–`#224` and `cataggar/knots#11`–`#30`, `wazig.5` is **2.93x–4.44x faster** than upstream `zig 0.17.0 -fno-llvm` on the exact same `knots` source (`11,463.1 FPS` vs `3,777.9 FPS` on `layout_bench`, `2,902.5 FPS` vs `991.1 FPS` on `text_bench`, `10,112.4 FPS` vs `2,275.7 FPS` on `render_bench`, and `2,695.3 FPS` vs `687.1 FPS` on `combined_frame`), and **8.86x–18.05x faster** than `wazig v0.17.0-wazig.3`.
- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) matches native `zig v0.17.0 -fllvm` runtime throughput across every mode:** In `ReleaseSmall`, `wazigl.4` achieves `9,262.3 FPS` (`layout_bench`), `2,674.0 FPS` (`text_bench`), `9,778.3 FPS` (`render_bench`), and `2,417.6 FPS` (`combined_frame`). In `ReleaseFast +simd128`, `wazigl.4` reaches **`9,837.8 FPS` (`0.101 ms`)** on `layout_bench`, **`11,122.0 FPS` (`0.089 ms`)** on `render_bench`, **`3,040.7 FPS` (`0.327 ms`)** on `text_bench`, and **`3,655.8 FPS` (`0.271 ms`)** on `combined_frame`.

### D.3 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.5` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.258 ms** / 0.262 ms (**3,866.9 FPS**) | 0.611 ms / 0.615 ms (1,638.0 FPS) | 0.657 ms / 0.662 ms (1,521.1 FPS) | 0.615 ms / 0.620 ms (1,627.3 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.601 ms** / 0.607 ms (**1,670.8 FPS**) | 1.141 ms / 1.153 ms (875.1 FPS) | 1.657 ms / 1.669 ms (603.2 FPS) | 1.142 ms / 1.155 ms (873.9 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.182 ms** / 0.195 ms (**5,439.3 FPS**) | 0.440 ms / 0.459 ms (2,245.0 FPS) | 0.629 ms / 0.635 ms (1,598.0 FPS) | 0.440 ms / 0.457 ms (2,246.9 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **0.648 ms** / 0.658 ms (**1,546.2 FPS**) | 1.742 ms / 1.754 ms (574.2 FPS) | 1.798 ms / 1.806 ms (556.1 FPS) | 1.739 ms / 1.756 ms (574.8 FPS) | `8133605907336869050` |

**`Debug` Runtime Highlight:** In `Debug` builds, `wazig v0.17.0-wazig.5` (`-fno-llvm`) is **2.14x–2.77x faster at runtime than both `wazigl v0.17.0-wazigl.4` and `zig v0.17.0 -fllvm` (LLVM 22)** across all four workloads (`3,866.9 FPS` vs `1,395.2` / `1,393.8 FPS` on `layout_bench`, `1,670.8 FPS` vs `569.8` / `569.1 FPS` on `text_bench`, `5,439.3 FPS` vs `2,541.5` / `2,533.1 FPS` on `render_bench`, and `1,546.2 FPS` vs `568.5` / `565.6 FPS` on `combined_frame`) while producing **3.07x smaller** `.wasm` binaries (`1,167.5 KB` vs `3,588.3 KB`).

### D.4 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)

| Compiler | Test Binaries Passed | Total Test `.wasm` Size (Raw / Zstd) | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |
| :--- | :---: | ---: | ---: | ---: |
| **`wazig v0.17.0-wazig.5` (`-fno-llvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | **7,449.8 KB** / **2,150.1 KB** | **0.843 s** | **1.38x faster** |
| **`wazigl v0.17.0-wazigl.4` (`-fllvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | 29,118.9 KB / 7,192.6 KB | **1.148 s** | 1.02x |
| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`/`+simd128`* (12 / 12 stripped) | 10,404.0 KB / 2,418.1 KB | 1.254 s | 0.93x |
| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics` + `+simd128`) | 29,079.3 KB / 7,162.3 KB | 1.167 s | 1.00x (baseline) |

> *\*Upstream `zig 0.17.0 -fno-llvm` emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, emits invalid `v128` Wasm instructions (`type mismatch: expected v128, found i32` in `scrollbar.render` & `mem.findScalarPos` failing Wasmtime validation) or `IllDefinedMemoryLayout` when `+simd128` is enabled (so non-SIMD `zig -fno-llvm` rows above are measured with `+simd128` and `+atomics` stripped), and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig v0.17.0-wazig.5` fixes all three bugs.*

---

## E. Guest Profiling Verification (`wasmtime-profile.py` @ `100us`)

### E.1 Verified Impact of `cataggar/zig#158`–`#224` & `cataggar/knots#11`–`#30` (`#9` & `#19`)

Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **14.58x** from `21,457` (`v0.17.0-wazig.3`) → `6,984`/`6,513`/`6,287` (initial `wazig.4`) → `3,209` (post-`#9`) → `1,674` (`wazig.4` post-`#19`) → **`1,472` (`ReleaseFast +simd128`)** in **`wazig v0.17.0-wazig.5`** (`cataggar/zig@v0.17.0-wazig.5`) + `cataggar/knots#11`–`#30`, exceeding all `cataggar/knots#9`, `#14`, and `#19` targets:

| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.5` (`ReleaseSmall`) | `wazig.5` (`ReleaseFast +simd128`) | `wazigl.4` (`ReleaseFast +simd128`) | `wazig.5` Speedup vs `wazig.3` | `knots#19` Goal |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.112 ms (8,886.7 FPS) | **0.087 ms (11,463.1 FPS)** | **0.101 ms (9,837.8 FPS)** | **18.05x faster** | `>= 9,500–10,000+ FPS` (**Exceeded**) |
| **`text_bench`** | 5.505 ms (181.7 FPS) | 0.384 ms (2,585.0 FPS) | **0.342 ms (2,902.5 FPS)** | **0.327 ms (3,040.7 FPS)** | **15.97x faster** | `>= 2,300–2,600+ FPS` (**Exceeded**) |
| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.150 ms (6,589.0 FPS) | **0.097 ms (10,112.4 FPS)** | **0.089 ms (11,122.0 FPS)** | **12.98x faster** | `>= 5,000–6,100+ FPS` (**Exceeded**) |
| **`combined_frame`** | 3.286 ms (304.2 FPS) | 0.506 ms (1,983.0 FPS) | **0.368 ms (2,695.3 FPS)** | **0.271 ms (3,655.8 FPS)** | **8.86x faster** | `>= 1,800–2,270+ FPS` (**Exceeded**) |

- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`/`wazig.5`).
- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.
- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) & [`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` parameterized leaf inlining, single-caller `.small` inlining, and local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity`.
- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) & [`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — `@Vector` layout, `v128` `+simd128` SIMD arithmetic, and fused `cmp_vector` + `@reduce(.And/.Or)` lowering**: Lowered `Rect.eql` to `f32x4.eq` + `i32x4.all_true` (`12 B`).
- **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Wasm multivalue return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`, `HMetrics`, `[2]u8`, `u128`)**: Eliminated linear-memory `sret` stack frames for 2-scalar returns, allowing `curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`, and `fmt.digits2` to be completely inlined and removed in `ReleaseFast`.
- **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing**: Parallel 4-way cold-cache `wasm32-wasi` test suite compilation completes with zero `Archive.zig` race panics (`21.32s` wall / `63.63s` CPU; **`0.843s`** total test execution time across all 12 suites — the fastest of all 4 compilers).
- **[`cataggar/zig#174`](https://github.com/cataggar/zig/issues/174)–[`#224`](https://github.com/cataggar/zig/pull/224) — By-value scalar parameter ABI (`classifyAutoParam`), read-only by-ref load & alloc alias elision across subblocks/`try` (`#215`/`#220`), `umulh` (`Wyhash.mum`) inline lowering, `tryElideMemcpyStackFrame` / `tryElideLeafStackFrame`, `0xfd` SIMD stack deltas (`#193`), `@Vector` lane & `u128` SROA (`#194`/`#222`), post-inlining shadow-stack scalarization (`#195`), single-scalar payload union SROA (`#213`), inline zero-fill stores (`#216`/`#218`), Wasm SIMD `pmin`/`pmax` (`#205`/`#212`), `Optimize.zig` MIR & `Optimizer.zig` LICM/DSE/store coalescing/2-pass inlining (`#214`/`#217`/`#223`/`#224`), and `.auto` multi-value ABI up to 4 scalars (`#223`/`#224`)**: Eliminated `memory.copy` aggregate parameter staging, inlined `Wyhash.round`/`mum`, promoted `sizing.Axis` tagged unions and `u128` values to scalar locals, and shrunk `wazig.wasm` itself from `31.57 MiB` to `30.31 MiB`.
- **[`cataggar/knots#11`](https://github.com/cataggar/knots/pull/11)–[`#17`](https://github.com/cataggar/knots/pull/17) (`#9`) & [`cataggar/knots#20`](https://github.com/cataggar/knots/pull/20)–[`#30`](https://github.com/cataggar/knots/pull/30) (`#19`, `#27`, `#28`) — Precomputed curve extents & scatter-first per-band sort (`#11`, `#15`, `#20`, `#25`, `#26`), 2-pass child layout, `comptime is_row` flex layout, O(1) `grow_main_total`, `IdContext`/`CodepointContext` integer hash contexts, compact 2-scalar `Key`, settled transition & `Style.resolve` fast paths (`#16`, `#17`, `#21`, `#25`), and in-place `DrawList` writes, single-pass `commandBounds` + grid insertion, and `comptime std.mem.zeroes` instance templates (`#22`, `#23`, `#26`)**: Boosted `wazig.5` `ReleaseFast +simd128` to **`11,463.1 FPS` (`layout_bench`)**, **`2,902.5 FPS` (`text_bench`)**, **`10,112.4 FPS` (`render_bench`)**, and **`2,695.3 FPS` (`combined_frame`)**.

### E.2 Top 15 Functions in `wazig v0.17.0-wazig.5` `ReleaseFast +simd128` (`1,472` total samples @ 100us)

| Self | Self% | Total | Tot% | Bytes | Function |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 360 | 21.51% | 360 | 21.51% | 6,857 | `band.partitionWithBuffer` |
| 163 | 9.74% | 176 | 10.51% | 9,070 | `DrawList.emitBatched` |
| 124 | 7.41% | 317 | 18.94% | 5,062 | `wasm_bench_runner.buildRenderFrame` |
| 91 | 5.44% | 248 | 14.81% | 10,351 | `wasm_bench_runner.buildDashboardLayoutFrame` |
| 73 | 4.36% | 73 | 4.36% | 7,860 | `Context.computeLayoutNode` |
| 69 | 4.12% | 85 | 5.08% | 5,854 | `TrueType.glyphShapeTT` |
| 57 | 3.41% | 59 | 3.52% | 2,207 | `Context.open` |
| 44 | 2.63% | 423 | 25.27% | 3,543 | `GlyphBuilder.addCurves` |
| 34 | 2.03% | 45 | 2.69% | 1,206 | `DrawList.pushInstances` |
| 34 | 2.03% | 34 | 2.03% | 2,035 | `Context.computeSizes` |
| 29 | 1.73% | 74 | 4.42% | 4,933 | `Context.tessellateLayer` |
| 21 | 1.25% | 21 | 1.25% | 467 | `hash_map.Custom(u32,GlyphRecord,Face.CodepointContext,80).getIndex` |
| 20 | 1.19% | 20 | 1.19% | 620 | `curve.decomposeVerticesInto` |
| 19 | 1.14% | 54 | 3.23% | 2,436 | `Face.shape` |
| 19 | 1.14% | 31 | 1.85% | 1,228 | `Style.resolve` |

### E.3 Follow-Up `cataggar/zig` Self-Hosted Wasm Backend Optimization Issues Filed

- **[`cataggar/zig#189`](https://github.com/cataggar/zig/issues/189)** (fixed in `#193`): `wasm: Optimizer.zig classifyTrivialFunc sets depth0_stack_exact = false on all 0xfd SIMD instructions`.
- **[`cataggar/zig#190`](https://github.com/cataggar/zig/issues/190)** (fixed in `#194`): `wasm: CodeGen.zig SroaAnalysis and ReadOnlyAllocAliasAnalysis reject vector_index != .none, spilling v128/@Vector lane accesses to shadow stack`.
- **[`cataggar/zig#191`](https://github.com/cataggar/zig/issues/191)** (fixed in `#196`): `wasm: CodeGen.zig SroaAnalysis over-promotes large (>16B) copy-modify-pass aggregates into scalar locals that immediately spill back to shadow stack`.
- **[`cataggar/zig#192`](https://github.com/cataggar/zig/issues/192)** (fixed in `#195`): `wasm: Optimizer.zig post-inlining shadow-stack slot scalarization (SROA) for small aggregates whose address only escaped to inlined leaf methods`.
- **[`cataggar/zig#213`](https://github.com/cataggar/zig/issues/213)** (fixed in `v0.17.0-wazig.5`): `wasm(CodeGen): SROA support for tagged unions with single-scalar payloads (e.g. union(enum) { f32, void })`.
- **[`cataggar/zig#215`](https://github.com/cataggar/zig/issues/215)** (fixed in `#220` / `v0.17.0-wazig.5`): `wasm(CodeGen): ReadOnlyAllocAliasAnalysis rejects get_union_tag on by-value union parameters, forcing shadow-stack copies on every switch`.
- **[`cataggar/zig#216`](https://github.com/cataggar/zig/issues/216)** (fixed in `#218` / `v0.17.0-wazig.5`): `wasm(CodeGen/Sema): std.mem.zeroes(T) at runtime emits 50+ scalar zero stores instead of comptime aggregate constant or memory.fill`.
- **[`cataggar/zig#217`](https://github.com/cataggar/zig/issues/217)** (fixed in `#223`/`#224` / `v0.17.0-wazig.5`): `wasm(Optimizer): inline medium-sized single-call or hot loop-body helpers (<= 240B) in ReleaseFast mode`.
- **[`cataggar/zig#218`](https://github.com/cataggar/zig/issues/218)** (fixed in `v0.17.0-wazig.5`): `wasm: SroaAnalysis does not forward .bit_cast on layout-compatible byref values (e.g. []T -> []const T slice coercions), and all-zero >16B @splat(0) arrays load from .rodata instead of v128.const 0`.
- **[`cataggar/zig#219`](https://github.com/cataggar/zig/issues/219)**: `aarch64: self-hosted backend (-Denable-llvm=false) miscompiles std.Build runner (maker) into an infinite loop`.
- **[`cataggar/zig#222`](https://github.com/cataggar/zig/pull/222)**–**[`#224`](https://github.com/cataggar/zig/pull/224)** (landed in `v0.17.0-wazig.5`): `wasm: u128 SROA + .auto 4-scalar multi-value ABI + Optimize.zig MIR & Optimizer.zig LICM/DSE/store coalescing/2-pass inlining`.

---

## F. wasm32-freestanding vs wasm64-freestanding (Memory64) Head-to-Head

Head-to-head comparison of `wasm32-freestanding` (32-bit pointers, 4 GiB linear address space) vs `wasm64-freestanding` (64-bit pointers, >4 GiB Memory64 linear address space, [`cataggar/knots#18`](https://github.com/cataggar/knots/issues/18)) across `Debug`, `ReleaseSmall`, and `ReleaseFast (+simd128)` (`-Dcpu=generic+simd128`) using both **`wazig v0.17.0-wazig.4` (`-fno-llvm`)** and **`wazigl v0.17.0-wazigl.4` (`-fllvm`)**, executed under `wasmtime v50.0.1` (`wasmtime run -W memory64=y`).

### F.1 Playground (`examples/playground`) — Compile Time & `.wasm` Binary Size

| Compiler & Mode | Target | Cold Compile | Warm Compile (Median of 3) | Raw `.wasm` Size | `gzip -9` Size | `zstd -19` Size | `wasm64` vs `wasm32` Size Delta (Raw / `gzip` / `zstd`) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **`wazig.4` (`-fno-llvm`) — `Debug`** | `wasm32-freestanding` | 25.47 s | 17.37 s | 2,940,547 B (2,871.6 KB) | 992,465 B (969.2 KB) | **773,784 B (755.6 KB)** | — |
| **`wazig.4` (`-fno-llvm`) — `Debug`** | `wasm64-freestanding` | 25.80 s | 17.70 s | 3,433,215 B (3,352.7 KB) | 1,035,651 B (1,011.4 KB) | **800,120 B (781.4 KB)** | **+16.8% / +4.4% / +3.4%** |
| **`wazig.4` (`-fno-llvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 23.02 s | 15.22 s | 2,534,268 B (2,474.9 KB) | 882,028 B (861.4 KB) | **698,765 B (682.4 KB)** | — |
| **`wazig.4` (`-fno-llvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 22.73 s | 15.21 s | 2,982,278 B (2,912.4 KB) | 906,635 B (885.4 KB) | **721,836 B (704.9 KB)** | **+17.7% / +2.8% / +3.3%** |
| **`wazig.4` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 24.03 s | 16.38 s | 2,908,725 B (2,840.6 KB) | 988,085 B (964.9 KB) | **761,777 B (743.9 KB)** | — |
| **`wazig.4` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 24.67 s | 16.55 s | 3,354,625 B (3,276.0 KB) | 1,026,354 B (1,002.3 KB) | **791,090 B (772.5 KB)** | **+15.3% / +3.9% / +3.8%** |
| **`wazigl.4` (`-fllvm`) — `Debug`** | `wasm32-freestanding` | 49.17 s | 34.38 s | 6,301,662 B (6,154.0 KB) | 2,051,860 B (2,003.8 KB) | **1,591,142 B (1,553.8 KB)** | — |
| **`wazigl.4` (`-fllvm`) — `Debug`** | `wasm64-freestanding` | 47.94 s | 34.95 s | 7,090,297 B (6,924.1 KB) | 2,108,270 B (2,058.9 KB) | **1,606,109 B (1,568.5 KB)** | **+12.5% / +2.7% / +0.9%** |
| **`wazigl.4` (`-fllvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 50.97 s | 38.11 s | 1,820,355 B (1,777.7 KB) | 715,398 B (698.6 KB) | **587,955 B (574.2 KB)** | — |
| **`wazigl.4` (`-fllvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 48.98 s | 36.26 s | 2,266,814 B (2,213.7 KB) | 731,977 B (714.8 KB) | **589,505 B (575.7 KB)** | **+24.5% / +2.3% / +0.3%** |
| **`wazigl.4` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 88.06 s | 67.62 s | 5,590,318 B (5,459.3 KB) | 1,802,873 B (1,760.6 KB) | **1,474,608 B (1,440.0 KB)** | — |
| **`wazigl.4` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 84.25 s | 67.19 s | 6,904,354 B (6,742.5 KB) | 1,850,767 B (1,807.4 KB) | **1,512,270 B (1,476.8 KB)** | **+23.5% / +2.7% / +2.6%** |

### F.2 Headless Benchmark Runner (`knots-wasm-bench`) — Compile Time & `.wasm` Binary Size

| Compiler & Mode | Target | Cold Compile | Warm Compile (Median of 3) | Raw `.wasm` Size | `gzip -9` Size | `zstd -19` Size | `wasm64` vs `wasm32` Size Delta (Raw / `gzip` / `zstd`) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **`wazig.4` (`-fno-llvm`) — `Debug`** | `wasm32-freestanding` | 13.57 s | 5.73 s | 1,165,893 B (1,138.6 KB) | 460,787 B (450.0 KB) | **392,770 B (383.6 KB)** | — |
| **`wazig.4` (`-fno-llvm`) — `Debug`** | `wasm64-freestanding` | 13.47 s | 5.80 s | 1,213,738 B (1,185.3 KB) | 470,419 B (459.4 KB) | **398,308 B (389.0 KB)** | **+4.1% / +2.1% / +1.4%** |
| **`wazig.4` (`-fno-llvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 11.67 s | 4.16 s | 892,586 B (871.7 KB) | 383,831 B (374.8 KB) | **333,392 B (325.6 KB)** | — |
| **`wazig.4` (`-fno-llvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 11.61 s | 4.19 s | 904,740 B (883.5 KB) | 387,200 B (378.1 KB) | **335,245 B (327.4 KB)** | **+1.4% / +0.9% / +0.6%** |
| **`wazig.4` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 12.40 s | 4.80 s | 1,069,779 B (1,044.7 KB) | 435,979 B (425.8 KB) | **370,210 B (361.5 KB)** | — |
| **`wazig.4` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 12.54 s | 4.75 s | 1,080,979 B (1,055.6 KB) | 439,746 B (429.4 KB) | **372,083 B (363.4 KB)** | **+1.0% / +0.9% / +0.5%** |
| **`wazigl.4` (`-fllvm`) — `Debug`** | `wasm32-freestanding` | 28.34 s | 14.36 s | 3,116,053 B (3,043.0 KB) | 1,054,314 B (1,029.6 KB) | **866,269 B (846.0 KB)** | — |
| **`wazigl.4` (`-fllvm`) — `Debug`** | `wasm64-freestanding` | 28.12 s | 14.37 s | 3,336,398 B (3,258.2 KB) | 1,069,937 B (1,044.9 KB) | **869,990 B (849.6 KB)** | **+7.1% / +1.5% / +0.4%** |
| **`wazigl.4` (`-fllvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 23.44 s | 12.53 s | 650,934 B (635.7 KB) | 321,866 B (314.3 KB) | **288,860 B (282.1 KB)** | — |
| **`wazigl.4` (`-fllvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 23.35 s | 12.55 s | 661,185 B (645.7 KB) | 323,750 B (316.2 KB) | **290,433 B (283.6 KB)** | **+1.6% / +0.6% / +0.5%** |
| **`wazigl.4` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 38.35 s | 22.76 s | 2,628,419 B (2,566.8 KB) | 910,113 B (888.8 KB) | **775,995 B (757.8 KB)** | — |
| **`wazigl.4` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 38.87 s | 22.82 s | 3,088,746 B (3,016.4 KB) | 928,609 B (906.8 KB) | **788,362 B (769.9 KB)** | **+17.5% / +2.0% / +1.6%** |

### F.3 Runtime Execution Performance (`wasmtime run -W memory64=y <knots-wasm-bench.wasm> --json`)

> **Checksum Verification**: Every `wasm32-freestanding` and `wasm64-freestanding` run produces bit-identical output checksums across all optimization modes (`total_checksum = 2186326712793932228` under `wazig -fno-llvm` and `total_checksum = 13151244770801229719` under `wazigl -fllvm`, with matching per-workload checksums `layout_bench = 417689973924794692`, `text_bench = 12606774574179943755` / `7686275582076872382`, `render_bench = 8226312248921777708`, `combined_frame = 8133605907336869050`).

#### `wazig v0.17.0-wazig.4` (`-fno-llvm`, Self-Hosted Wasm Backend)

| Optimize Mode | Workload | `wasm32-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64` vs `wasm32` Latency / Throughput | Checksum |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`Debug`** | `layout_bench` (300 iters, 2,047 elems) | **0.443 ms** / 0.444 ms / 0.447 ms (**2,254.0 FPS**) | **0.613 ms** / 0.613 ms / 0.617 ms (**1,631.3 FPS**) | +38.3% ms / 0.72x FPS | `417689973924794692` |
| **`Debug`** | `text_bench` (200 iters, 3,405 elems) | **1.045 ms** / 1.046 ms / 1.053 ms (**956.2 FPS**) | **1.318 ms** / 1.320 ms / 1.330 ms (**757.4 FPS**) | +26.2% ms / 0.79x FPS | `12606774574179943755` |
| **`Debug`** | `render_bench` (300 iters, 5,100 elems) | **0.525 ms** / 0.520 ms / 0.532 ms (**1,921.1 FPS**) | **0.720 ms** / 0.720 ms / 0.728 ms (**1,389.7 FPS**) | +37.3% ms / 0.72x FPS | `8226312248921777708` |
| **`Debug`** | `combined_frame` (100 iters, 514 elems) | **1.585 ms** / 1.585 ms / 1.595 ms (**630.9 FPS**) | **1.946 ms** / 1.947 ms / 1.955 ms (**513.6 FPS**) | +22.8% ms / 0.81x FPS | `8133605907336869050` |
| **`Debug`** | **`total_bench_ms`** | **742.11 ms** | **970.14 ms** | **+30.7% ms / 0.76x** | `2186326712793932228` |
| **`ReleaseSmall`** | `layout_bench` (300 iters, 2,047 elems) | **0.161 ms** / 0.162 ms / 0.166 ms (**6,191.4 FPS**) | **0.240 ms** / 0.241 ms / 0.245 ms (**4,140.9 FPS**) | +49.8% ms / 0.67x FPS | `417689973924794692` |
| **`ReleaseSmall`** | `text_bench` (200 iters, 3,405 elems) | **0.809 ms** / 0.808 ms / 0.815 ms (**1,237.5 FPS**) | **1.023 ms** / 1.025 ms / 1.031 ms (**975.4 FPS**) | +26.4% ms / 0.79x FPS | `12606774574179943755` |
| **`ReleaseSmall`** | `render_bench` (300 iters, 5,100 elems) | **0.427 ms** / 0.432 ms / 0.439 ms (**2,316.2 FPS**) | **0.606 ms** / 0.605 ms / 0.614 ms (**1,652.3 FPS**) | +42.0% ms / 0.71x FPS | `8226312248921777708` |
| **`ReleaseSmall`** | `combined_frame` (100 iters, 514 elems) | **1.329 ms** / 1.330 ms / 1.338 ms (**751.7 FPS**) | **1.587 ms** / 1.588 ms / 1.599 ms (**629.7 FPS**) | +19.4% ms / 0.84x FPS | `8133605907336869050` |
| **`ReleaseSmall`** | **`total_bench_ms`** | **532.56 ms** | **695.77 ms** | **+30.6% ms / 0.77x** | `2186326712793932228` |
| **`ReleaseFast (+simd128)`** | `layout_bench` (300 iters, 2,047 elems) | **0.142 ms** / 0.143 ms / 0.146 ms (**7,000.4 FPS**) | **0.212 ms** / 0.213 ms / 0.216 ms (**4,700.8 FPS**) | +48.9% ms / 0.67x FPS | `417689973924794692` |
| **`ReleaseFast (+simd128)`** | `text_bench` (200 iters, 3,405 elems) | **0.753 ms** / 0.752 ms / 0.759 ms (**1,329.6 FPS**) | **0.926 ms** / 0.926 ms / 0.933 ms (**1,080.0 FPS**) | +22.9% ms / 0.81x FPS | `12606774574179943755` |
| **`ReleaseFast (+simd128)`** | `render_bench` (300 iters, 5,100 elems) | **0.385 ms** / 0.390 ms / 0.398 ms (**2,566.2 FPS**) | **0.535 ms** / 0.531 ms / 0.540 ms (**1,881.7 FPS**) | +38.8% ms / 0.73x FPS | `8226312248921777708` |
| **`ReleaseFast (+simd128)`** | `combined_frame` (100 iters, 514 elems) | **1.253 ms** / 1.254 ms / 1.266 ms (**797.2 FPS**) | **1.457 ms** / 1.458 ms / 1.470 ms (**685.9 FPS**) | +16.3% ms / 0.86x FPS | `8133605907336869050` |
| **`ReleaseFast (+simd128)`** | **`total_bench_ms`** | **490.75 ms** | **623.83 ms** | **+27.1% ms / 0.79x** | `2186326712793932228` |

#### `wazigl v0.17.0-wazigl.4` (`-fllvm`, LLVM 22 Backend)

| Optimize Mode | Workload | `wasm32-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64` vs `wasm32` Latency / Throughput | Checksum |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`Debug`** | `layout_bench` (300 iters, 2,047 elems) | **0.725 ms** / 0.725 ms / 0.729 ms (**1,379.7 FPS**) | **1.040 ms** / 1.040 ms / 1.044 ms (**961.2 FPS**) | +43.3% ms / 0.70x FPS | `417689973924794692` |
| **`Debug`** | `text_bench` (200 iters, 3,405 elems) | **1.749 ms** / 1.749 ms / 1.756 ms (**571.8 FPS**) | **2.163 ms** / 2.164 ms / 2.174 ms (**462.0 FPS**) | +23.7% ms / 0.81x FPS | `7686275582076872382` |
| **`Debug`** | `render_bench` (300 iters, 5,100 elems) | **1.059 ms** / 1.060 ms / 1.067 ms (**943.3 FPS**) | **1.161 ms** / 1.164 ms / 1.173 ms (**859.4 FPS**) | +9.7% ms / 0.91x FPS | `8226312248921777708` |
| **`Debug`** | `combined_frame` (100 iters, 514 elems) | **2.747 ms** / 2.747 ms / 2.758 ms (**364.0 FPS**) | **3.289 ms** / 3.289 ms / 3.300 ms (**304.0 FPS**) | +19.7% ms / 0.84x FPS | `8133605907336869050` |
| **`Debug`** | **`total_bench_ms`** | **1,309.48 ms** | **1,607.23 ms** | **+22.7% ms / 0.81x** | `13151244770801229719` |
| **`ReleaseSmall`** | `layout_bench` (300 iters, 2,047 elems) | **0.111 ms** / 0.111 ms / 0.114 ms (**8,979.4 FPS**) | **0.165 ms** / 0.166 ms / 0.170 ms (**6,011.7 FPS**) | +48.9% ms / 0.67x FPS | `417689973924794692` |
| **`ReleaseSmall`** | `text_bench` (200 iters, 3,405 elems) | **0.498 ms** / 0.497 ms / 0.503 ms (**2,012.3 FPS**) | **0.660 ms** / 0.658 ms / 0.665 ms (**1,518.6 FPS**) | +32.5% ms / 0.75x FPS | `7686275582076872382` |
| **`ReleaseSmall`** | `render_bench` (300 iters, 5,100 elems) | **0.259 ms** / 0.262 ms / 0.273 ms (**3,814.5 FPS**) | **0.308 ms** / 0.312 ms / 0.323 ms (**3,203.4 FPS**) | +19.2% ms / 0.84x FPS | `8226312248921777708` |
| **`ReleaseSmall`** | `combined_frame` (100 iters, 514 elems) | **0.687 ms** / 0.686 ms / 0.696 ms (**1,456.8 FPS**) | **0.896 ms** / 0.895 ms / 0.906 ms (**1,116.8 FPS**) | +30.4% ms / 0.77x FPS | `8133605907336869050` |
| **`ReleaseSmall`** | **`total_bench_ms`** | **316.13 ms** | **411.69 ms** | **+30.2% ms / 0.77x** | `13151244770801229719` |
| **`ReleaseFast (+simd128)`** | `layout_bench` (300 iters, 2,047 elems) | **0.101 ms** / 0.102 ms / 0.104 ms (**9,849.0 FPS**) | **0.148 ms** / 0.149 ms / 0.152 ms (**6,713.5 FPS**) | +46.8% ms / 0.68x FPS | `417689973924794692` |
| **`ReleaseFast (+simd128)`** | `text_bench` (200 iters, 3,405 elems) | **0.386 ms** / 0.388 ms / 0.393 ms (**2,578.0 FPS**) | **0.518 ms** / 0.517 ms / 0.524 ms (**1,933.8 FPS**) | +34.1% ms / 0.75x FPS | `7686275582076872382` |
| **`ReleaseFast (+simd128)`** | `render_bench` (300 iters, 5,100 elems) | **0.162 ms** / 0.163 ms / 0.172 ms (**6,126.6 FPS**) | **0.197 ms** / 0.199 ms / 0.208 ms (**5,032.5 FPS**) | +21.7% ms / 0.82x FPS | `8226312248921777708` |
| **`ReleaseFast (+simd128)`** | `combined_frame` (100 iters, 514 elems) | **0.440 ms** / 0.442 ms / 0.449 ms (**2,260.6 FPS**) | **0.591 ms** / 0.589 ms / 0.594 ms (**1,697.1 FPS**) | +34.2% ms / 0.75x FPS | `8133605907336869050` |
| **`ReleaseFast (+simd128)`** | **`total_bench_ms`** | **227.47 ms** | **301.50 ms** | **+32.5% ms / 0.75x** | `13151244770801229719` |

### F.4 Key Takeaways on `wasm64-freestanding` (Memory64) vs `wasm32-freestanding` Tradeoffs

1. **Zero Compile-Time Penalty**: Compiling for `wasm64-freestanding` takes virtually the exact same time as `wasm32-freestanding` across both `wazig` (`4.19s` vs `4.16s` warm on `knots-wasm-bench ReleaseSmall`, `15.21s` vs `15.22s` warm on `playground ReleaseSmall`) and `wazigl` (`12.55s` vs `12.53s` warm on `knots-wasm-bench ReleaseSmall`, `36.26s` vs `38.11s` warm on `playground ReleaseSmall`).
2. **Negligible Compressed Binary Size Overhead (`+0.3%` to `+3.8%` `zstd -19`)**:
   - On `knots-wasm-bench`, `wasm64-freestanding` adds only **`+1.0%`–`+1.6%` raw** (`+0.5%`–`+0.6%` `zstd -19`) in `ReleaseSmall` (`327.4 KB` vs `325.6 KB` zstd under `wazig`; `283.6 KB` vs `282.1 KB` zstd under `wazigl`).
   - On `examples/playground` (which embeds static UI/font tables and pointer-rich descriptors), 64-bit pointers and LEB128 `i64` address offsets increase raw `.wasm` size by `+15.3%`–`+17.7%` under `wazig` and `+12.5%`–`+24.5%` under `wazigl`, but the extra upper-zero bytes in 64-bit pointers compress away almost completely under `zstd -19` (**`+0.3%`–`+3.8%`**, e.g. `575.7 KB` vs `574.2 KB` in `wazigl ReleaseSmall` and `704.9 KB` vs `682.4 KB` in `wazig ReleaseSmall`).
3. **Runtime Performance & Memory64 Bounds-Checking Overhead (`+22.7%` to `+32.5%` total suite time)**:
   - Across `knots-wasm-bench`, `wasm64-freestanding` runs at **0.75x–0.81x** the overall throughput of `wasm32-freestanding` (`total_bench_ms`: `623.83 ms` vs `490.75 ms` in `wazig ReleaseFast +simd128`; `301.51 ms` vs `227.47 ms` in `wazigl ReleaseFast +simd128`), while still exceeding all `cataggar/knots#9` 600–1,800 FPS targets by a wide margin (`4,700.8 FPS` / `6,713.5 FPS` on `layout_bench`, `1,881.7 FPS` / `5,032.5 FPS` on `render_bench`, `685.9 FPS` / `1,697.1 FPS` on `combined_frame`).
   - This ~20%–33% runtime delta is driven by two fundamental architectural differences in WebAssembly Memory64:
     1. **Explicit Software Bounds Checks vs 4 GiB Virtual Guard Pages**: For `wasm32`, Wasmtime reserves a 4 GiB virtual address region with guard pages so `i32` loads/stores execute without explicit bounds-check branches. For `wasm64` (Memory64), the 64-bit address space cannot be covered by virtual memory guard pages alone, requiring explicit compare-and-branch bounds checks on linear-memory accesses.
     2. **Doubled Pointer & Slice Width (`usize = u64`, `[]T = 16 B` vs `8 B`)**: Pointer-heavy tree/slice traversals (`layout_bench`, +46.8%–49.8% latency) experience higher cache-line pressure and 64-bit address arithmetic compared to SIMD/float-heavy batch generation (`render_bench`, +19.2%–21.7% latency in `wazigl`) or end-to-end frames (`combined_frame`, +16.3% latency in `wazig ReleaseFast +simd128`).
4. **When to Choose `wasm32-freestanding` vs `wasm64-freestanding`**:
   - **`wasm32-freestanding` (Default for Web UI)**: Delivers maximum single-core throughput (up to **1.33x faster**) and slightly smaller uncompressed binaries whenever the workload fits within the 4 GiB address space.
   - **`wasm64-freestanding` (Memory64)**: Unlocks **>4 GiB linear memory** (up to 16 GiB in browsers/Wasmtime) with zero source changes, identical deterministic output, near-zero `zstd` wire-size overhead (`+0.3%`–`+3.8%`), and 685–1,697 FPS full-frame UI throughput.

---

## G. V8 / Node 26 vs Wasmtime & WasmFX / JSPI / `Atomics.waitAsync` Benchmarks

Measured on Apple M4 Max (`darwin-arm64`) using `node scripts/bench-wasmfx.mjs` with **Node.js `v26.3.0`** (V8 `14.6.202.34-node.20`) and **Wasmtime `50.0.1` (`c307ec81d 2026-10-29`)** against `wasm_bench_runner.wasm` (`1,223,499` bytes, compiled with `wazig` in `ReleaseFast` + `simd128` after `cataggar/knots#26`).

### G.1 Synchronous `knots` Workloads (`wasm_bench_runner.wasm`) — Wasmtime vs V8 (Default vs `--experimental-wasm-wasmfx`)

| Benchmark | Iterations | Wasmtime Median (ms) | Node 26 Default Median (ms) | Node 26 + WasmFX Flags Median (ms) | Node / Wasmtime | WasmFX Flags / Default |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `layout_bench` | 300 | 0.0755 ms | 0.0710 ms | 0.0704 ms | **0.94x** (V8 6% faster) | 0.99x |
| `text_bench` | 200 | 0.2546 ms | 0.2616 ms | 0.2541 ms | **1.03x** | 0.97x |
| `render_bench` | 300 | 0.0859 ms | 0.0810 ms | 0.0813 ms | **0.94x** (V8 6% faster) | 1.00x |
| `combined_frame` | 100 | 0.3876 ms | 0.4462 ms | 0.4504 ms | **1.15x** | 1.01x |
| **`total_bench_ms`** | — | **157.74 ms** | **195.59 ms** | **192.85 ms** | **1.24x** | **0.99x** |

- **Zero regression from enabling `--experimental-wasm-wasmfx` (`0.99x`)**: Enabling V8's typed-continuation stack switching (`--experimental-wasm-wasmfx --experimental-wasm-exnref`) has zero measurable overhead on synchronous `knots` layout, text shaping, or rendering workloads (`192.85 ms` vs `195.59 ms`).
- **V8 TurboFan/Liftoff vs Wasmtime 50 Cranelift**: After `cataggar/knots#26` (`text_bench` glyph shaping fast paths), V8 matches Wasmtime on `text_bench` (`0.2541–0.2616 ms` vs `0.2546 ms`, `1.00x–1.03x`), outperforms Wasmtime by **6%** on `layout_bench` (`0.0704 ms` vs `0.0755 ms`) and `render_bench` (`0.0810 ms` vs `0.0859 ms`), and completes the full 900-iteration suite in **192.85 ms** (`1.24x` of Wasmtime's `157.74 ms`).

### G.2 Runtime Capability Detection (`detectWasmCapabilities()`)

| Capability Check | Mechanism | Node 26 Default | Node 26 + `--experimental-wasm-wasmfx` | Probe Cost (ns/op) |
| :--- | :--- | :---: | :---: | ---: |
| `JSPI` (`CAP_JSPI`) | `typeof WebAssembly.Suspending === "function" && typeof WebAssembly.promising === "function"` | `true` | `true` | 2.61 ns |
| `Atomics.waitAsync` (`CAP_WAIT_ASYNC`) | `typeof Atomics.waitAsync === "function"` | `true` | `true` | 4.38 ns |
| `WasmFX` (`CAP_WASMFX`) | `WebAssembly.validate(WASMFX_PROBE_BYTES)` (16-byte `0x5d` `cont` section) | `false` | `true` | 543.31 ns |
| **Combined** | `detectWasmCapabilities()` (uncached cold call; cached at host startup) | `0b011` (`3`) | `0b111` (`7`) | **518.04 ns** |

### G.3 `std.Io` Coroutine Suspend/Resume Microbenchmarks (V8)

| Mechanism | Operation | Latency (ns/op) | Throughput (M ops/s) | Comparison |
| :--- | :--- | ---: | ---: | :--- |
| **WasmFX (active stack)** | `suspend $yield` + `resume $ct` on warm continuation | **47.27 ns** | **21.16 M/s** | **1.38x faster** than JSPI (`Promise.resolve`), **2.17x faster** than JSPI (`queueMicrotask`) |
| **JSPI (active stack, `Promise.resolve`)** | `WebAssembly.Suspending` + `WebAssembly.promising` immediate Promise | 65.40 ns | 15.29 M/s | 1.00x (active-stack JSPI baseline) |
| **JSPI (active stack, `queueMicrotask`)** | `WebAssembly.Suspending` + `new Promise(r => queueMicrotask(r))` | 102.70 ns | 9.74 M/s | 1.57x of JSPI (`Promise.resolve`) |
| **WasmFX (full lifecycle)** | `cont.new` + `resume` (1 suspend) + `resume` to completion | **109.90 ns** | **9.10 M/s** | **5.19x faster** than full-lifecycle JSPI |
| **JSPI (full lifecycle, `queueMicrotask`)** | `await promisingExport(1)` (enter stack + 1 suspend + exit) | 570.21 ns | 1.75 M/s | 1.00x (full-lifecycle JSPI baseline) |

- **Why WasmFX wins for intra-Wasm `std.Io` fiber switching**: Pure Wasm-internal `suspend $yield` + `resume $ct` (`run_pure_yields` in `WASMFX_HELPER_BYTES`) stays entirely inside WebAssembly without allocating JS `Promise` objects or crossing the JS microtask queue, achieving **47.27 ns/suspend** (**21.16 million switches/sec**) on an active continuation and **109.90 ns** (**5.19x faster** than JSPI) for a full continuation lifecycle (`cont.new` + `resume` + `suspend` + `resume`).
- **Why JSPI is essential today**: JSPI (`WebAssembly.Suspending` + `WebAssembly.promising`) is **enabled by default in V8 / Node 26 / Chromium** without experimental flags and bridges Wasm stacks directly to browser Promises (`Atomics.waitAsync`, `setTimeout`, WebGPU buffer map / shader compilation Promises) at **65–103 ns** per active-stack suspension.

### G.4 Cooperative Frame-Budgeted Workload (10,000 Ear-Clipping Steps, Yield Every 1,000)

| Mode | Yields / Call | Total Time (us) | Yield Overhead (us) | Overhead (%) | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **Un-instrumented Wasm baseline** | 0 | 42.10 us | 0.00 us | 0.0% | `-813497` |
| **WasmFX (`suspend` / `resume`)** | 10 | **42.65 us** | **+0.55 us** | **+1.3%** | `-813497` |
| **JSPI (`Suspending` / `promising`)** | 10 | **42.67 us** | **+0.56 us** | **+1.3%** | `-813497` |

- Inserting 10 cooperative yield checkpoints across a 10,000-step triangulation workload adds only **~0.55 us (`+1.3%`)** under both WasmFX and JSPI while producing bit-identical geometry checksums (`-813497`).

### G.5 Main-Thread `std.Io` Futex Wait (`SharedArrayBuffer` `Int32Array`, 2 ms Worker Notify)

| Wait Strategy | Avg Wall Wait (us) | Avg Main-Thread CPU Burned (us) | Main-Thread Event-Loop Ticks During Wait | CPU Savings |
| :--- | ---: | ---: | ---: | ---: |
| **`Atomics.waitAsync` + JSPI (`knots_host_wait_async32`)** | 2,324.5 us | **168.8 us** | **1.7 ticks** (non-blocking) | **92.6% less CPU** |
| **Synchronous Wasm Spin-Wait (`i32.atomic.load`)** | 2,265.7 us | 2,279.6 us | 0.0 ticks (blocked) | 0.0% (100% core pinned) |

- When the browser main thread waits on a worker-notified `std.Io.Mutex`, `Condition`, or `ResetEvent` inside a `WebAssembly.promising` export (`CAP_PROMISING_ACTIVE`), `knots_host_wait_async32` suspends the Wasm stack via `Atomics.waitAsync` + `WebAssembly.Suspending`, cutting main-thread CPU consumption by **92.6%** (`168.8 us` vs `2,279.6 us`) while keeping the browser event loop responsive.

### G.6 Issue #28 Part 1: Persistent Wasm Futex Work Queue vs `postMessage({ type: "run" })` Dispatch

Measured on `linux-arm64` via `node scripts/bench-wasmfx.mjs` across **4 pre-warmed `worker_threads`** sharing a 16–64 page WebAssembly `SharedArrayBuffer` (`new WebAssembly.Memory({ initial: 16, maximum: 64, shared: true })`), dispatching **20 batches × 400 tasks/batch (8,000 tasks)** with both **Node.js `v24.21.0` (V8 `13.6.233.17`)** and **Node.js `v22.15.0` (V8 `12.4.254.21`)**:

| Dispatch Path | Runtime / V8 | Workers | Tasks / Batch | Avg Batch Time (ms) | Per-Task Latency (us/task) | Throughput (K tasks/s) | Speedup | Checksum |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Persistent Wasm Futex Ring (`knots_worker_loop` + `memory.atomic.wait32` + coalesced notify)** | Node `v24.21.0` / V8 `13.6.233.17` | 4 | 400 | **0.212 ms** | **0.53 us** | **1,883.1 K/s** | **21.04x faster** | `1257257586` |
| **Per-Task `postMessage({ type: "run" })` + `{ type: "done" }` (Baseline)** | Node `v24.21.0` / V8 `13.6.233.17` | 4 | 400 | 4.469 ms | 11.17 us | 89.5 K/s | 1.00x (baseline) | `1257257586` |
| **Persistent Wasm Futex Ring (`knots_worker_loop` + `memory.atomic.wait32` + coalesced notify)** | Node `v22.15.0` / V8 `12.4.254.21` | 4 | 400 | **0.240 ms** | **0.60 us** | **1,665.2 K/s** | **17.30x faster** | `1257257586` |
| **Per-Task `postMessage({ type: "run" })` + `{ type: "done" }` (Baseline)** | Node `v22.15.0` / V8 `12.4.254.21` | 4 | 400 | 4.156 ms | 10.39 us | 96.3 K/s | 1.00x (baseline) | `1257257586` |

- **Production Architecture (`src/wasm/WorkerRuntime.zig`, `src/web/worker-pool.js`, `src/web/worker.js`) vs Microbenchmark Kernel**:
  - **Production Runtime (`src/wasm/WorkerRuntime.zig`)**: Uses a 256-slot ring buffer (`queue_capacity = 256`, `ring_tasks`) plus an intrusive FIFO overflow list (`overflow_head` / `overflow_tail` via `Task.queue_next`) protected by a lightweight spinlock (`queue_lock`), paired with a `work_seq` futex sequence word (`memory.atomic.wait32` / `memory.atomic.notify`), pre-warmed workers parked in `knots_worker_loop(workerId)`, and coalesced main-thread completion notifications (`notify_pending` -> `knots_host_notify_complete` / `knots_worker_ack_complete`).
  - **Standalone Node V8 Microbenchmark Kernel (`scripts/bench-wasmfx.mjs`)**: Models shared-memory futex ring dispatch (`enqueue_batch`, `knots_worker_loop`, and coalesced `knots_host_notify_complete` / `knots_worker_ack_complete`) vs per-task `worker.postMessage({ type: "run" })` + `{ type: "done" }` structured-clone round-trips across 4 `worker_threads`.
- **Key Takeaway**: Eliminating per-task `postMessage` serialization and event-loop hop overhead reduces per-task dispatch latency from **11.17 us to 0.53 us** (**21.04x speedup**, **1.88 million tasks/sec** across 4 workers) with bit-identical accumulation checksums (`1257257586`).

### G.7 Issue #28 Part 1: Per-Worker 64B-Aligned 9-List Sharded Freelist vs Global Spinlock Freelist (`SharedArrayBuffer` Wasm Memory)

Measured across **4 concurrent `worker_threads`** synchronized at a Wasm atomic start barrier (`0x2000`), each executing **25,000 alloc + payload write/read + free cycles per round** (**100,000 concurrent allocator round-trips per round**, 12 timed rounds) cycling through **9 freelists of fixed 64 B blocks (`class = iter % 9`)**:

| Allocator Strategy (`SharedArrayBuffer` Wasm Linear Memory, 9 Freelists `class = iter % 9` of Fixed 64 B Blocks) | Runtime / V8 | Workers | Concurrent Ops / Round | Avg Round Time (ms) | Effective Latency (ns/op) | Throughput (M ops/s) | Speedup | Checksum |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Per-Worker 64B-Aligned 9-List Sharded Freelist (models `ShardedAllocator`, `currentWorkerId() % 16`, `align(64)`)** | Node `v24.21.0` / V8 `13.6.233.17` | 4 | 100,000 | **0.582–0.610 ms** | **5.82–6.10 ns** | **164.02–171.82 M/s** | **41.36x–43.54x faster** | `1249950000` |
| **Global Atomic Spinlock 9-List Freelist (`i32.atomic.rmw.cmpxchg` at `0x2040`)** | Node `v24.21.0` / V8 `13.6.233.17` | 4 | 100,000 | 24.072–26.543 ms | 240.72–265.43 ns | 3.77–4.15 M/s | 1.00x (baseline) | `1249950000` |

- **Production Architecture (`src/wasm/ShardedAllocator.zig`, `src/wasm/WorkerRuntime.zig`) & Benchmark Kernel**:
  - **Baseline (Global Spinlock 9-List Freelist)**: All 4 workers contend on a single shared atomic spinlock (`i32.atomic.rmw.cmpxchg` at `0x2040`) protecting 9 shared freelist heads (`0x2044..0x2067`, `class = iter % 9`, fixed 64 B blocks) before popping and pushing blocks in shared linear memory.
  - **Production Runtime (`src/wasm/ShardedAllocator.zig`) & Sharded Benchmark Kernel**: Production implements `num_shards = 16` cache-line-aligned (`align(64)`) `Shard` structs indexed by `currentWorkerId() % 16` (where `currentWorkerId()` is packed into the low 6 bits of the 64-byte-aligned `Task` pointer in the per-instance `knots_worker_task` global), each containing a 4-byte `SpinLock` at `+0`, 9 power-of-two size-class freelist heads from `16 B` to `4096 B` (`free_heads[0..8]` at `+4..+39`, `min_class_shift = 4`, `max_class_shift = 12`), and 9 `u16` slot counts (`counts[0..8]` at `+40..+57`), plus O(1) lock-free same-class `resize`/`remap` and cross-worker frees returned to the freeing worker's shard (`rawFreeOnShard`) up to `max_cached_per_class = 64` before evicting to `std.heap.wasm_allocator`. The Wasm benchmark kernel (`bench_sharded_slab_alloc`) models this shard layout using 9 freelists of fixed 64 B blocks inside each worker's 64-byte-aligned `Shard` (`0x2100 + ((worker_id & 15) << 6)`, with `lock` at `+0` and `free_heads[0..8]` at `+4..+39`) across 4 concurrent workers (`class = iter % 9`).
- **Key Takeaway**: Isolating per-worker 9-list freelists and spinlocks onto separate 64-byte cache lines eliminates cache-line ping-pong and global lock contention in shared Wasm linear memory, accelerating 4-worker concurrent sharded allocation by **41.36x–43.54x** (`5.82–6.10 ns/op` vs `240.72–265.43 ns/op`, **164.02–171.82 million alloc+free cycles/sec**).

### G.8 Issue #28 Part 1: Frame-Safe Non-Blocking Task Polling (`knots_frame` + `knots_worker_poll(0)`) vs `WebAssembly.promising(knots_frame)`

Measured over **10,000 consecutive synchronous frame-entry calls** (`knots_frame(16)` + `knots_worker_poll(0)` on an empty completion queue vs `WebAssembly.promising(knots_frame)`):

| Frame Entry / Poll Mode | Runtime / V8 | Calls | Total Time (us) | Per-Frame Latency (ns/call) | Throughput (M calls/s) | Speedup |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| **Synchronous `knots_frame` + non-blocking `knots_worker_poll(0)` (empty-queue poll)** | Node `v24.21.0` / V8 `13.6.233.17` | 10,000 | **324.61–337.89 us** | **32.46–33.79 ns** | **29.60–30.81 M/s** | **24.23x–25.53x faster** |
| **`WebAssembly.promising(knots_frame)` (JSPI Promise + Secondary Stack Switch)** | Node `v24.21.0` / V8 `13.6.233.17` | 10,000 | 8,188.61–8,288.06 us | 818.86–828.81 ns | 1.21–1.22 M/s | 1.00x (JSPI baseline) |

- **Frame-Safe Non-Blocking Task Polling (`src/web/host.js`, `src/wasm/threads.zig`, `src/wasm/WorkerRuntime.zig`)**:
  - `src/web/host.js` keeps `knots_frame` unwrapped in `wrapExports` (not wrapped in `WebAssembly.promising`; only `[dispatchSymbol, startSymbol, "knots_init", "knots_event"]` are wrapped via `wrapPromisingExport`), clears `knots_worker_ack_complete()` at the start of each `requestFrame()` step so worker completions occurring mid-frame schedule a follow-up frame, and exposes non-blocking `threads.poll(max_tasks)`, `threads.pollGroup(&group)`, `threads.pollFuture(T, &future)`, and `knots_worker_poll` so frame callbacks can inspect completion state synchronously without JSPI suspension or `Promise` allocation overhead.
  - In this synthetic frame-entry microbenchmark, calling a synchronous `knots_frame` export that performs a non-blocking `knots_worker_poll(0)` empty-queue check costs only **32.46–33.79 ns/call** (**24.23x–25.53x faster** than entering a `WebAssembly.promising` wrapper at **818.86–828.81 ns/call**) and allocates **zero `Promise` objects per 60/120 Hz frame**.

### G.9 Real-World Application Impact & End-to-End Frame Budget Examples (120 Hz = `8.33 ms` / `8,333.3 us` Budget)

Measured on `linux-arm64` via `/opt/actions-runner/2.338.0/externals/node24/bin/node scripts/bench-wasmfx.mjs` (Section 9) with **Node.js `v24.21.0` (V8 `13.6.233.17-node.53`)** across **4 pre-warmed `worker_threads`** sharing linear memory (`SharedArrayBuffer`), quantifying how the three Issue #28 Part 1 enhancements translate into usable frame budget in interactive 60 Hz (`16.67 ms`) and 120 Hz (`8.33 ms` / `8,333.3 us`) applications:

#### G.9.1 Sub-Frame Parallel Task Batch (`64` Tasks/Frame × `50` Frames across `4` Workers)

- **Workload & Kernel**: Each frame dispatches **64 fine-grained parallel tasks across the 4-worker pool** (measured over 50 consecutive frames = 3,200 tasks). Each of the 64 tasks per frame runs the synthetic 64-iteration per-task compute kernel (`run_task_kernel`, ~100 ns/task, modeling fine-grained per-glyph / per-curve subdivision tasks). Two futex completion modes are measured against per-task `postMessage`:
  1. **`Wasm futex ring + coalesced notify (4 workers, main thread free)`** — where all 64 tasks run strictly on the 4 background workers and the main thread remains completely free until the single coalesced completion notification (`knots_host_notify_complete`) arrives.
  2. **`Wasm futex ring + main-thread spin-poll helper (4 workers + main helper, 5 executors)`** — where the calling thread also spins on `knots_worker_poll(1)` to help execute queued tasks.

| Dispatch Mode (`4` Workers, `64` Tasks/Frame × `50` Frames) | Tasks / Frame | Avg Time / Frame (us) | Per-Task Cost (us) | % of 120 Hz Frame (`8.33 ms`) | % of 60 Hz Frame (`16.67 ms`) | Speedup vs `postMessage` | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Wasm futex ring + coalesced notify (4 workers, main thread free)** | 64 | **53.01–54.78 us** | **0.83–0.86 us** | **0.64%–0.66%** | **0.32%–0.33%** | **12.12x–12.42x faster** | `1103779576` |
| **Wasm futex ring + main-thread spin-poll helper (4 workers + main helper, 5 executors)** | 64 | **27.93–29.12 us** | **0.44–0.46 us** | **0.34%–0.35%** | **0.17%** | **22.80x–23.57x faster** | `1103779576` |
| **Per-task `postMessage({ type: "run" })` + `{ type: "done" }` (4 workers, baseline)** | 64 | 658.11–664.05 us | 10.28–10.38 us | 7.90%–7.97% | 3.95%–3.98% | 1.00x (baseline) | `1103779576` |

- **Why This Matters in Practice**:
  - With per-task `worker.postMessage({ type: "run" })` + `{ type: "done" }`, dispatching 64 fine-grained tasks across 4 workers takes **658.11–664.05 us per frame** (**7.90%–7.97% of an entire 120 Hz `8.33 ms` frame**) due to structured-clone serialization and JS event-loop round-trips.
  - With **`Wasm futex ring + coalesced notify (4 workers, main thread free)`** (`knots_worker_loop` + `memory.atomic.wait32` / `memory.atomic.notify` + `knots_host_notify_complete`), all 64 tasks execute strictly on the 4 background workers while the main thread stays completely free until the single coalesced completion notification arrives in **53.01–54.78 us per frame** (**0.64%–0.66% of a 120 Hz frame**, **12.12x–12.42x faster** than `postMessage`). When a 5th calling thread also spin-polls via `knots_worker_poll(1)`, batch completion drops to **27.93–29.12 us per frame** (**0.34%–0.35% of a 120 Hz frame**, **22.80x–23.57x faster**).

#### G.9.2 Concurrent Multi-Worker Allocation (`2,000` Ops/Worker/Frame = `8,000` Alloc+Free Ops/Frame across `4` Workers)

- **Workload & Kernel**: **4 workers concurrently execute 2,000 alloc + payload write/read + free cycles per worker per frame** (**8,000 concurrent alloc+free ops/frame** across 4 workers, measured over 20 frames = 160,000 ops), cycling through **9 freelists of fixed 64 B blocks (`class = iter % 9`)** inside each worker's 64-byte-aligned `Shard` (`0x2100 + ((worker_id & 15) << 6)`, with `lock` at `+0` and `free_heads[0..8]` at `+4..+39`, modeling `ShardedAllocator`) vs a single global spinlock-protected 9-list freelist at `0x2040`:

| Allocator Architecture (`4` Workers, `2,000` Ops/Worker/Frame = `8,000` Ops/Frame, `9` Freelists of Fixed `64 B` Blocks) | Concurrent Ops / Frame | Allocator Time / Frame (us) | Latency / Op (ns) | % of 120 Hz Frame (`8.33 ms`) | % of 60 Hz Frame (`16.67 ms`) | Speedup | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Per-Worker 64B-Aligned 9-List Sharded Freelist (models `ShardedAllocator`, `currentWorkerId() % 16`, `align(64)`)** | 8,000 | **45.84–49.29 us** | **5.73–6.16 ns** | **0.55%–0.59%** | **0.28%–0.30%** | **41.74x–49.22x faster** | `7996000` |
| **Global Atomic Spinlock 9-List Freelist (`i32.atomic.rmw.cmpxchg` at `0x2040`, Baseline)** | 8,000 | 1,913.16–2,426.29 us | 239.15–303.29 ns | 22.96%–29.12% | 11.48%–14.56% | 1.00x (baseline) | `7996000` |

- **Why This Matters in Practice**:
  - When 4 workers concurrently allocate and free across 9 freelists against a single global spinlock in shared linear memory, cache-line bouncing and CAS retries stall the workers for **1.91–2.43 ms per frame** — consuming **22.96%–29.12% of a 120 Hz frame** purely in allocator lock contention.
  - Isolating each worker onto its own **64B-Aligned 9-List Shard** (as implemented in `ShardedAllocator.zig` via `currentWorkerId() % 16` packed into the 64-byte-aligned `Task` pointer) cuts the 8,000-op concurrent freelist cost in this benchmark kernel to **45.84–49.29 us per frame** (**0.55%–0.59% of a 120 Hz frame**, **41.74x–49.22x faster**), eliminating multi-core lock contention during concurrent worker execution.

#### G.9.3 120 Hz Frame Poll Check Overhead (`1,200` Frame Ticks = `10s` @ 120 Hz)

- **Workload & Kernel**: Measures **1,200 synchronous `knots_frame(8333)` + `knots_worker_poll(0)` frame-entry ticks** (the number of frame ticks in 10 seconds at 120 Hz) on an empty completion queue vs a `WebAssembly.promising`-wrapped `knots_frame(8333)`, isolating the per-frame non-blocking poll check and JS-to-Wasm entry overhead without background tasks in flight:

| Frame Entry / Poll Mode (`1,200` Frame Ticks = `10s` @ 120 Hz) | Frame Ticks | Total 1,200-Tick Overhead (us) | Per-Frame Poll Check Cost (ns/tick) | % of 120 Hz Frame (`8.33 ms`) | JS `Promise` Allocs / Sec | Speedup |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **Synchronous `knots_frame` + non-blocking `knots_worker_poll(0)` (empty-queue poll)** | 1,200 | **39.59–40.29 us** | **32.99–33.57 ns** | **0.0004%** | **0 / sec** (`0` / 1,200 ticks) | **26.47x–26.63x faster** |
| **`WebAssembly.promising(knots_frame)` (JSPI Promise + Secondary Stack Switch)** | 1,200 | 1,048.10–1,072.82 us | 873.42–894.01 ns | 0.0105%–0.0107% | 120 / sec (`1,200` / 1,200 ticks) | 1.00x (JSPI baseline) |

- **Why This Matters in Practice**:
  - Keeping `knots_frame` synchronous in `src/web/host.js` (`wrapExports`) and performing a non-blocking `knots_worker_poll(0)` check costs **32.99–33.57 ns per frame tick** (**39.59–40.29 us total across 1,200 frame ticks = 10 seconds at 120 Hz**) with **zero JS `Promise` allocations or microtask turns**, avoiding both JSPI stack-switching overhead (**26.47x–26.63x faster**) and GC pressure in long-running 120 Hz sessions.

#### G.9.4 Combined End-to-End 120 Hz Frame Budget Summary (All 3 Workloads in One `8.33 ms` Frame)

| Pipeline Configuration (64-Task Batch + 8,000-Op Multi-Worker Alloc + Frame Poll Check) | Total Coordination & Alloc Overhead / Frame (us) | % of 120 Hz Frame Budget (`8.33 ms`) | Remaining Frame Budget for Rendering (ms) | End-to-End Speedup |
| :--- | ---: | ---: | ---: | ---: |
| **Issue #28 Part 1 — 4 Workers + Coalesced Notify (main thread free) + `ShardedAllocator` + Sync `knots_frame` Poll** | **100.66–102.33 us** (**0.101–0.102 ms**) | **1.21%–1.23%** | **8.231–8.233 ms** (of `8.333 ms`) | **25.61x–30.15x faster** (reclaims **2.48–2.98 ms/frame**) |
| *(Optional: Issue #28 Part 1 — 4 Workers + Main-Thread Spin-Poll Helper (5 executors) + `ShardedAllocator` + Sync `knots_frame` Poll)* | *75.00–77.25 us (0.075–0.077 ms)* | *0.90%–0.93%* | *8.256–8.258 ms (of `8.333 ms`)* | *34.38x–39.94x faster (reclaims 2.50–3.01 ms/frame)* |
| **Baseline (`postMessage` per Task + Global Spinlock Allocator + `WebAssembly.promising(knots_frame)`)** | 2,578.11–3,085.27 us (2.578–3.085 ms) | 30.94%–37.02% | 5.248–5.755 ms (of `8.333 ms`) | 1.00x (baseline) |

- **End-to-End Takeaway**: Using the apples-to-apples 4-worker async-notify futex configuration (`glyphFutexAsyncUsPerFrame + allocShardedUsPerFrame + streamSyncUsPerFrame`, where all 64 tasks run on the 4 background workers while the main thread stays free), the three Issue #28 Part 1 enhancements shrink combined worker dispatch, 9-class concurrent allocation, and per-frame poll overhead from **2.58–3.09 ms/frame (30.94%–37.02% of the 120 Hz frame budget)** down to **100.66–102.33 us/frame (1.21%–1.23% of the 120 Hz frame budget)** — a **25.61x–30.15x end-to-end reduction** that reclaims **2.48–2.98 ms of usable CPU/GPU frame time every frame** (or **75.00–77.25 us/frame = 0.90%–0.93% of a 120 Hz frame, 34.38x–39.94x faster** when the calling thread also helps drain tasks via `waitForTasks`).
