# wazig (v0.17.0-wazig.6) & wazigl (v0.17.0-wazigl.6) vs zig v0.17.0 Comprehensive Benchmark Report

Reproducible 4-way benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig v0.17.0-wazig.6`** (`cataggar/zig@v0.17.0-wazig.6`, `-fno-llvm`): universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1` (`8.08 MiB` `.tar.zst`, `58.87 MiB` unpacked), including `cataggar/zig#158`–`#224` and `cataggar/knots#11`–`#30`
- **`wazigl v0.17.0-wazigl.6`** (`cataggar/zig@v0.17.0-wazigl.6`, `-fllvm`): universal `wasm64-wasip3` compiler with full LLVM 22 Wasm backend executed via `wasmtime v50.0.1` (`36.26 MiB` `.tar.zst`, `221.57 MiB` unpacked)
- **`zig v0.17.0 -fno-llvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with self-hosted Wasm backend)
- **`zig v0.17.0 -fllvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with LLVM 22 backend)

---

## A. Toolchain & CI Footprint

| Metric | `wazig v0.17.0-wazig.6` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.0` (Standard) | Reduction / Advantage |
| :--- | :--- | :--- | :--- | :--- |
| **Release Archive Size** | **8.08 MiB** (`wazig.tar.zst`) | **36.26 MiB** (`wazigl.tar.zst`) | 50.43 MiB (`zig-aarch64-linux-0.17.0.tar.xz`) | **`wazig`: 6.24x smaller (-84.0%) / `wazigl`: 1.39x smaller (-28.1%)** |
| **Unpacked Release Size** | **58.87 MiB** (`30.31 MiB` `wazig.wasm` + `28.55 MiB` `lib/`) | **221.57 MiB** (`193.02 MiB` `wazigl.wasm` + `28.55 MiB` `lib/`) | 343.65 MiB (`163.74 MiB` `zig` + `178.95 MiB` `lib/`; `397.74 MiB` on disk) | **`wazig`: 5.84x smaller (-82.9%) / `wazigl`: 1.55x smaller (-35.5%)** |
| **Installed File Count** | **1,324 files** | **1,324 files** | 19,506 files | **14.7x fewer files (-93.2%)** |
| **Binary Portability** | wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | wasm64-wasip3 + LLVM 22 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | OS/arch-specific native binaries (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows, etc.) | **Single universal artifact per tier** |
| **Supply-Chain Attestation** | Native Sigstore bundle verified via ghr | Native Sigstore bundle verified via ghr | minisign signature (external tool required) | **Zero extra verification tools** |
| **Wasm Build Dependency Fetch** | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~230+ MiB compressed / ~680 MiB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |

---

## B. Compilation Speed (Cold Cache & Warm Cache)

> All `wazig` and `wazigl` measurements run with Wasmtime's compiled module cache warmed.

| Workload | `wazig v0.17.0-wazig.6` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |
| :--- | ---: | ---: | ---: | ---: |
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.460s** | 1.620s | 0.050s | 0.050s |
| `wasm_bench_runner.zig` (`Debug`) | 13.07s (cold) / 6.72s (warm) | 30.14s (cold) / 15.83s (warm) | 3.54s (cold) / 0.29s (warm) | 5.97s (cold) / 2.62s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 10.99s (cold) / 4.83s (warm) | 23.11s (cold) / 13.68s (warm) | 2.38s (cold) / 0.23s (warm) | 6.82s (cold) / 4.73s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast`) | 12.19s (cold) / 5.89s (warm) | 39.92s (cold) / 25.42s (warm) | 3.59s (cold) / 0.24s (warm) | 12.48s (cold) / 8.84s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | 12.31s (cold) / 5.85s (warm) | 40.19s (cold) / 26.14s (warm) | FAIL (`IllDefinedMemoryLayout`)* | 13.07s (cold) / 9.78s (warm) |
| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | 18.92s wall (58.9s CPU) | 47.55s wall (156.2s CPU) | 3.36s wall (7.9s CPU) | 8.31s wall (26.5s CPU) |
| `examples/triangle` (`Debug`) | 14.06s (cold) / 7.50s (warm) | 30.12s (cold) / 18.12s (warm) | 2.81s (cold) / 0.31s (warm) | 5.61s (cold) / 2.91s (warm) |
| `examples/triangle` (`ReleaseSmall`) | 11.82s (cold) / 5.58s (warm) | 26.20s (cold) / 17.52s (warm) | 2.32s (cold) / 0.26s (warm) | 8.39s (cold) / 6.09s (warm) |
| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | 17.36s | 34.28s | 1.01s | 5.49s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 14.43s | 34.29s | 0.96s | 12.46s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | 17.70s | 34.02s | 1.01s | 5.71s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 14.86s | 34.67s | 0.96s | 12.37s |
| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **19.94s** | **42.99s** | FAIL (`global.get` asm)* | 8.22s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **16.87s** | **40.21s** | FAIL (`global.get` asm)* | 14.69s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=true`) | **17.86s** | **34.82s** | FAIL (`global.get` asm)* | 5.62s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=true`) | **14.93s** | **35.49s** | FAIL (`global.get` asm)* | 12.88s |
| `examples/embedded` (`Debug`) | 6.34s | 14.84s | 0.26s | 2.41s |
| `examples/embedded` (`ReleaseSmall`) | 4.62s | 14.30s | 0.21s | 5.06s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | 7.79s | 18.36s | 0.33s | 3.06s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | 5.91s | 18.26s | 0.28s | 6.63s |

**Compilation Speed Analysis (`wazig.6` vs `wazigl.6` vs `zig 0.17.0`):**
- **`wazig v0.17.0-wazig.6` (`-fno-llvm`) vs `wazigl v0.17.0-wazigl.6` (`-fllvm`)**: Because `wazig` uses Zig's self-hosted WebAssembly backend (`src/codegen/wasm/CodeGen.zig` + `src/link/Wasm/component/Optimizer.zig`) without invoking LLVM's optimization passes, `wazig.6` compiles **1.92x–4.47x faster** than `wazigl.6` across every workload (`4.83s` vs `13.68s` warm on `wasm_bench_runner ReleaseSmall`, `5.85s` vs `26.14s` warm on `ReleaseFast +simd128`, `18.92s` vs `47.55s` wall time across all `wasm32-wasi` test suites, and `0.460s` vs `1.620s` on `fmt --check`).
- **`wazig v0.17.0-wazig.6` vs Native `zig v0.17.0 -fllvm`**: Even running inside Wasmtime (`wasm64-wasip3`), `wazig.6` warm-cache builds (`4.83s` `ReleaseSmall`, `5.89s` `ReleaseFast`, `5.85s` `ReleaseFast +simd128`) are **faster than or competitive with native `zig 0.17.0 -fllvm`** (`4.73s` `ReleaseSmall`, `8.84s` `ReleaseFast`, `9.78s` `ReleaseFast +simd128` — **up to 1.67x faster**), and `triangle` (`5.58s` vs `6.09s` warm) and `embedded` (`4.62s` vs `5.06s` warm) build faster than native LLVM.
- **`wazigl v0.17.0-wazigl.6` vs Native `zig v0.17.0 -fllvm`**: Running the full LLVM 22 + Clang C++ toolchain inside Wasmtime (`wazigl.wasm`, `193.02 MiB`) incurs a ~2.7x–2.9x Wasmtime guest execution multiplier relative to native `zig -fllvm` (`13.68s` vs `4.73s` warm on `ReleaseSmall`, `34.29s` vs `12.46s` warm on `playground ReleaseSmall`), making `wazig.6` ideal for fast CI test/check inner loops and `wazigl.6` ideal when maximum LLVM codegen optimization is desired without OS/arch-specific native compiler binaries.

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig v0.17.0-wazig.6` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` / `wazigl` vs `zig -fllvm` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 2,815.5 KB / 961.4 KB / **755.3 KB** | 6,655.5 KB / 2,199.1 KB / **1,682.6 KB** | 3,579.0 KB / 1,096.2 KB / **828.8 KB** | 6,662.8 KB / 2,200.0 KB / **1,676.1 KB** | `wazig`: **-21.3%** / `wazigl`: **-0.11%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,264.6 KB / 824.3 KB / **662.3 KB** | 1,819.9 KB / 710.2 KB / **597.0 KB** | 2,982.5 KB / 934.1 KB / **717.0 KB** | 1,820.2 KB / 710.1 KB / **595.2 KB** | `wazig`: **-24.1%** / `wazigl`: **-0.02%** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 2,781.2 KB / 956.4 KB / **750.7 KB** | 6,621.3 KB / 2,193.7 KB / **1,680.6 KB** | 3,544.7 KB / 1,090.8 KB / **824.8 KB** | 6,628.6 KB / 2,194.6 KB / **1,637.6 KB** | `wazig`: **-21.5%** / `wazigl`: **-0.11%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,230.3 KB / 819.0 KB / **658.2 KB** | 1,785.7 KB / 704.8 KB / **584.2 KB** | 2,948.2 KB / 929.4 KB / **714.6 KB** | 1,786.0 KB / 704.8 KB / **597.0 KB** | `wazig`: **-24.4%** / `wazigl`: **-0.02%** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 2,826.2 KB / 965.4 KB / **757.7 KB** | 6,708.1 KB / 2,222.1 KB / **1,698.7 KB** | FAIL (`global.get` asm)* | 6,715.4 KB / 2,222.9 KB / **1,696.7 KB** | **`wazig` succeeds** / `wazigl`: **-0.11%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,271.7 KB / 827.3 KB / **663.6 KB** | 1,826.8 KB / 712.5 KB / **556.0 KB** | FAIL (`global.get` asm)* | 1,827.1 KB / 712.4 KB / **589.3 KB** | **`wazig` succeeds** / `wazigl`: **-0.02%** |
| `playground` (`Debug`, WebGL2, `web_threads=true`) | 2,791.9 KB / 960.7 KB / **753.1 KB** | 6,673.9 KB / 2,214.9 KB / **1,655.1 KB** | FAIL (`global.get` asm)* | 6,681.2 KB / 2,215.7 KB / **1,696.9 KB** | **`wazig` succeeds** / `wazigl`: **-0.11%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=true`) | 2,237.4 KB / 821.5 KB / **659.7 KB** | 1,792.6 KB / 707.2 KB / **600.2 KB** | FAIL (`global.get` asm)* | 1,792.9 KB / 707.1 KB / **596.4 KB** | **`wazig` succeeds** / `wazigl`: **-0.02%** |
| `triangle` (`Debug`) | 1,362.3 KB / 520.1 KB / **443.3 KB** | 3,891.0 KB / 1,319.2 KB / **1,067.8 KB** | 1,877.5 KB / 610.6 KB / **496.0 KB** | 3,895.2 KB / 1,319.6 KB / **1,066.6 KB** | `wazig`: **-27.4%** / `wazigl`: **-0.11%** |
| `triangle` (`ReleaseSmall`) | 1,046.7 KB / 433.0 KB / **375.9 KB** | 803.3 KB / 365.7 KB / **327.4 KB** | 1,428.3 KB / 483.7 KB / **406.8 KB** | 803.4 KB / 365.8 KB / **327.2 KB** | `wazig`: **-26.7%** / `wazigl`: **-0.02%** |
| `embedded` (`Debug`) | 1,194.2 KB / 457.0 KB / **394.2 KB** | 3,419.3 KB / 1,139.9 KB / **935.7 KB** | 1,639.7 KB / 538.3 KB / **441.5 KB** | 3,422.6 KB / 1,139.9 KB / **934.6 KB** | `wazig`: **-27.2%** / `wazigl`: **-0.10%** |
| `embedded` (`ReleaseSmall`) | 944.4 KB / 393.8 KB / **345.1 KB** | 735.3 KB / 338.1 KB / **303.0 KB** | 1,252.2 KB / 433.5 KB / **368.4 KB** | 735.4 KB / 338.1 KB / **303.2 KB** | `wazig`: **-24.6%** / `wazigl`: **-0.01%** |
| `benchmark` (`Debug`) | 1,381.2 KB / 524.6 KB / **447.8 KB** | 3,970.7 KB / 1,344.8 KB / **1,085.3 KB** | 1,911.3 KB / 623.3 KB / **502.6 KB** | 3,974.9 KB / 1,345.3 KB / **1,084.6 KB** | `wazig`: **-27.7%** / `wazigl`: **-0.11%** |
| `benchmark` (`ReleaseSmall`) | 1,059.6 KB / 437.2 KB / **379.7 KB** | 809.8 KB / 368.5 KB / **330.0 KB** | 1,455.6 KB / 491.9 KB / **412.3 KB** | 809.9 KB / 368.5 KB / **329.9 KB** | `wazig`: **-27.2%** / `wazigl`: **-0.02%** |
| `wasm_bench_runner` (`Debug`) | 1,167.5 KB / 470.6 KB / **405.0 KB** | 3,626.7 KB / 1,219.3 KB / **1,000.5 KB** | 1,641.8 KB / 552.9 KB / **452.4 KB** | 3,626.8 KB / 1,218.3 KB / **998.4 KB** | `wazig`: **-28.9%** / `wazigl`: **-0.00%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 868.1 KB / 387.2 KB / **339.7 KB** | 685.8 KB / 334.0 KB / **298.5 KB** | 1,188.9 KB / 428.6 KB / **363.2 KB** | 685.9 KB / 333.9 KB / **298.6 KB** | `wazig`: **-27.0%** / `wazigl`: **-0.01%** |
| `wasm_bench_runner` (`ReleaseFast`) | 981.2 KB / 431.4 KB / **376.0 KB** | 2,815.4 KB / 966.7 KB / **821.4 KB** | 1,322.3 KB / 460.4 KB / **392.8 KB** | 2,827.7 KB / 970.1 KB / **825.0 KB** | `wazig`: **-25.8%** / `wazigl`: **-0.44%** |
| `wasm_bench_runner` (`ReleaseFast +simd128`) | 990.3 KB / 432.9 KB / **377.2 KB** | 2,775.6 KB / 964.5 KB / **820.3 KB** | FAIL (`IllDefinedMemoryLayout`)* | 2,787.6 KB / 967.5 KB / **823.1 KB** | **`wazig` succeeds** / `wazigl`: **-0.43%** |
| All 12 `wasm32-wasi` Test Binaries (`Debug` Total) | 7,449.9 KB / 2,601.2 KB / **2,150.1 KB** | 31,527.0 KB / 9,715.6 KB / **7,882.4 KB** | 11,082.7 KB / 3,273.5 KB / **2,588.1 KB** | 31,496.1 KB / 9,697.5 KB / **7,853.7 KB** | `wazig`: **-32.8%** / `wazigl`: **+0.10%** |

**Key Binary Size Takeaways:**
- **`wazigl v0.17.0-wazigl.6` (`-fllvm`) produces near-identical `ReleaseSmall` `.wasm` binaries (`0.00%`–`0.02%` raw size difference) to native `zig v0.17.0 -fllvm` across every single `ReleaseSmall` target:** `685.8 KB` raw (`298.5 KB` zstd) on `wasm_bench_runner`, `1,819.9 KB` raw (`597.0 KB` zstd) on `playground` WebGPU, `1,785.7 KB` raw (`584.2 KB` zstd) on `playground` WebGL2, `1,826.8 KB` raw (`556.0 KB` zstd) on `playground` WebGPU + threads, `803.3 KB` raw (`327.4 KB` zstd) on `triangle`, `735.3 KB` raw (`303.0 KB` zstd) on `embedded`, and `809.8 KB` raw (`330.0 KB` zstd) on `benchmark` — delivering full LLVM 22 codegen from a single universal `wasm64-wasip3` compiler.
- **`wazig v0.17.0-wazig.6` (`-fno-llvm`) produces the smallest `Debug` and `ReleaseFast` `.wasm` binaries of all four compilers:**
  - In **`Debug`** builds, `wazig.6` is **21.3%–32.8% smaller** than upstream `zig 0.17.0 -fno-llvm` and **57.7%–76.4% smaller (2.36x–4.23x smaller)** than `wazigl.6` and `zig 0.17.0 -fllvm`.
  - In **`ReleaseFast +simd128`** builds, `wazig.6` (`990.3 KB` raw / `377.2 KB` zstd) is **2.80x smaller** than `wazigl.6` (`2,775.6 KB` raw / `820.3 KB` zstd) and `zig 0.17.0 -fllvm` (`2,787.6 KB` raw / `823.1 KB` zstd), because LLVM's `ReleaseFast` loop unrolling and aggressive inlining expand `.wasm` binary size by **4.05x** over `ReleaseSmall` (`685.8 KB` → `2,775.6 KB`), whereas `wazig.6`'s targeted 2-pass inliner and MIR/linker optimizations (`Optimize.zig` + `Optimizer.zig`, `cataggar/zig#214`/`#217`/`#223`/`#224`) add only `+14.1%` over `ReleaseSmall` (`868.1 KB` → `990.3 KB`).
  - Across all 12 `wasm32-wasi` test binaries (`Debug`), `wazig.6` emits **7.28 MiB** (`7,449.9 KB`) raw (`2.10 MiB` zstd) vs **30.79 MiB** raw (`7.70 MiB` zstd) with `wazigl.6` / `zig -fllvm` (**4.23x smaller**), enabling the fastest test suite execution (`0.226s`).

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.6` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.112 ms** / 0.116 ms (**8,864.0 FPS**) | **0.108 ms** / 0.112 ms (**9,234.3 FPS**) | 0.266 ms / 0.270 ms (3,750.2 FPS) | 0.108 ms / 0.112 ms (9,245.2 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.385 ms** / 0.395 ms (**2,576.0 FPS**) | **0.367 ms** / 0.374 ms (**2,714.0 FPS**) | 1.012 ms / 1.108 ms (974.3 FPS) | 0.371 ms / 0.379 ms (2,679.8 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.153 ms** / 0.168 ms (**6,425.3 FPS**) | **0.101 ms** / 0.115 ms (**9,743.3 FPS**) | 0.457 ms / 0.532 ms (2,145.7 FPS) | 0.100 ms / 0.115 ms (9,805.5 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **0.507 ms** / 0.514 ms (**1,982.1 FPS**) | **0.404 ms** / 0.416 ms (**2,454.0 FPS**) | 1.515 ms / 1.602 ms (664.3 FPS) | 0.406 ms / 0.422 ms (2,439.3 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`

#### `ReleaseFast (+simd128)` (Default Wasm Target Features in `web_build.zig`)

| Workload | `wazig v0.17.0-wazig.6` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.087 ms** / 0.091 ms (**11,476.1 FPS**) | **0.100 ms** / 0.104 ms (**9,942.6 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.100 ms / 0.104 ms (9,900.6 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.342 ms** / 0.350 ms (**2,904.5 FPS**) | **0.329 ms** / 0.339 ms (**3,021.4 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.327 ms / 0.335 ms (3,040.7 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.099 ms** / 0.110 ms (**10,005.1 FPS**) | **0.091 ms** / 0.104 ms (**10,769.5 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.089 ms / 0.102 ms (11,035.0 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **0.367 ms** / 0.378 ms (**2,702.4 FPS**) | **0.270 ms** / 0.282 ms (**3,662.0 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.270 ms / 0.281 ms (3,664.8 FPS) | `8133605907336869050` |

#### `ReleaseFast` (Baseline Wasm CPU without `+simd128`)

| Workload | `wazig v0.17.0-wazig.6` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.088 ms** / 0.091 ms (**11,357.3 FPS**) | **0.104 ms** / 0.107 ms (**9,579.1 FPS**) | 0.263 ms / 0.268 ms (3,783.5 FPS) | 0.104 ms / 0.108 ms (9,543.0 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.341 ms** / 0.348 ms (**2,915.8 FPS**) | **0.301 ms** / 0.312 ms (**3,300.6 FPS**) | 1.007 ms / 1.015 ms (992.4 FPS) | 0.302 ms / 0.314 ms (3,275.0 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.128 ms** / 0.138 ms (**7,720.1 FPS**) | **0.092 ms** / 0.105 ms (**10,712.6 FPS**) | 0.434 ms / 0.450 ms (2,277.6 FPS) | 0.095 ms / 0.108 ms (10,382.9 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **0.382 ms** / 0.392 ms (**2,602.3 FPS**) | **0.292 ms** / 0.304 ms (**3,389.2 FPS**) | 1.445 ms / 1.458 ms (692.0 FPS) | 0.294 ms / 0.305 ms (3,364.2 FPS) | `8133605907336869050` |

**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**
- **`wazig v0.17.0-wazig.6` (`-fno-llvm`, `ReleaseFast +simd128`) exceeds all `cataggar/knots#19` FPS targets and beats the pre-`#19` `zig v0.17.0 -fllvm` baseline (`9,919.8` / `2,582.0` / `6,114.7` / `2,271.5 FPS`) across all 4 workloads, while surpassing post-`#19` `zig v0.17.0 -fllvm` and `wazigl v0.17.0-wazigl.6` on `layout_bench`:** With `cataggar/zig#189`–`#224` and `cataggar/knots#20`–`#30`, `wazig.6` reaches **`11,476.1 FPS` (`0.087 ms`)** on `layout_bench` (faster than `9,900.6 FPS` / `0.100 ms` in post-`#19` `zig -fllvm`), **`10,005.1 FPS` (`0.099 ms`)** on `render_bench` (vs `11,035.0 FPS` / `0.089 ms` in post-`#19` `zig -fllvm`), **`2,904.5 FPS` (`0.342 ms`)** on `text_bench` (vs `3,040.7 FPS` / `0.327 ms` in post-`#19` `zig -fllvm`), and **`2,702.4 FPS` (`0.367 ms`)** on `combined_frame` (vs `3,664.8 FPS` / `0.270 ms` in post-`#19` `zig -fllvm`) — while compiling in a **2.81x smaller** `.wasm` binary (`990.3 KB` vs `2,787.6 KB`).
- **`wazig v0.17.0-wazig.6` (`-fno-llvm`) vs `zig v0.17.0 -fno-llvm`**: With `cataggar/zig#158`–`#224` and `cataggar/knots#11`–`#30`, `wazig.6` is **2.93x–4.39x faster** than upstream `zig 0.17.0 -fno-llvm` on the exact same `knots` source (`11,476.1 FPS` vs `3,783.5 FPS` on `layout_bench`, `2,904.5 FPS` vs `992.4 FPS` on `text_bench`, `10,005.1 FPS` vs `2,277.6 FPS` on `render_bench`, and `2,702.4 FPS` vs `692.0 FPS` on `combined_frame`), and **8.88x–18.07x faster** than `wazig v0.17.0-wazig.3`.
- **`wazigl v0.17.0-wazigl.6` (`-fllvm`) matches native `zig v0.17.0 -fllvm` runtime throughput across every mode:** In `ReleaseSmall`, `wazigl.6` achieves `9,234.3 FPS` (`layout_bench`), `2,714.0 FPS` (`text_bench`), `9,743.3 FPS` (`render_bench`), and `2,454.0 FPS` (`combined_frame`). In `ReleaseFast +simd128`, `wazigl.6` reaches **`9,942.6 FPS` (`0.100 ms`)** on `layout_bench`, **`10,769.5 FPS` (`0.091 ms`)** on `render_bench`, **`3,021.4 FPS` (`0.329 ms`)** on `text_bench`, and **`3,662.0 FPS` (`0.270 ms`)** on `combined_frame`.

### D.3 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.6` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.256 ms** / 0.262 ms (**3,880.9 FPS**) | 0.615 ms / 0.622 ms (1,627.4 FPS) | 0.659 ms / 0.667 ms (1,516.9 FPS) | 0.615 ms / 0.618 ms (1,628.5 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.597 ms** / 0.602 ms (**1,681.8 FPS**) | 1.141 ms / 1.160 ms (874.0 FPS) | 1.662 ms / 1.683 ms (600.7 FPS) | 1.142 ms / 1.153 ms (874.1 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.180 ms** / 0.195 ms (**5,459.8 FPS**) | 0.443 ms / 0.455 ms (2,241.7 FPS) | 0.629 ms / 0.642 ms (1,595.2 FPS) | 0.443 ms / 0.459 ms (2,231.1 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **0.649 ms** / 0.659 ms (**1,542.8 FPS**) | 1.736 ms / 1.748 ms (576.0 FPS) | 1.778 ms / 1.797 ms (561.7 FPS) | 1.740 ms / 1.750 ms (574.8 FPS) | `8133605907336869050` |

**`Debug` Runtime Highlight:** In `Debug` builds, `wazig v0.17.0-wazig.6` (`-fno-llvm`) is **1.92x–2.68x faster at runtime than both `wazigl v0.17.0-wazigl.6` and `zig v0.17.0 -fllvm` (LLVM 22)** across all four workloads (`3,880.9 FPS` vs `1,627.4` / `1,628.5 FPS` on `layout_bench`, `1,681.8 FPS` vs `874.0` / `874.1 FPS` on `text_bench`, `5,459.8 FPS` vs `2,241.7` / `2,231.1 FPS` on `render_bench`, and `1,542.8 FPS` vs `576.0` / `574.8 FPS` on `combined_frame`) while producing **3.11x smaller** `.wasm` binaries (`1,167.5 KB` vs `3,626.7 KB`).

### D.4 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)

| Compiler | Test Binaries Passed | Total Test `.wasm` Size (Raw / Zstd) | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |
| :--- | :---: | ---: | ---: | ---: |
| **`wazig v0.17.0-wazig.6` (`-fno-llvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | **7,449.9 KB** / **2,150.1 KB** | **0.226 s** | **1.62x faster** |
| **`wazigl v0.17.0-wazigl.6` (`-fllvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | 31,527.0 KB / 7,882.4 KB | **0.343 s** | 1.06x |
| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`/`+simd128`* (12 / 12 stripped) | 11,082.7 KB / 2,588.1 KB | 0.309 s | 1.18x |
| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics` + `+simd128`) | 31,496.1 KB / 7,853.7 KB | 0.365 s | 1.00x (baseline) |

> *\*Upstream `zig 0.17.0 -fno-llvm` emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, emits invalid `v128` Wasm instructions (`type mismatch: expected v128, found i32` in `scrollbar.render` & `mem.findScalarPos` failing Wasmtime validation) or `IllDefinedMemoryLayout` when `+simd128` is enabled (so non-SIMD `zig -fno-llvm` rows above are measured with `+simd128` and `+atomics` stripped), and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig v0.17.0-wazig.6` fixes all three bugs.*

---

## E. Guest Profiling Verification (`wasmtime-profile.py` @ `100us`)

### E.1 Verified Impact of `cataggar/zig#158`–`#224` & `cataggar/knots#11`–`#30` (`#9` & `#19`)

Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **14.34x** from `21,457` (`v0.17.0-wazig.3`) → `6,984`/`6,513`/`6,287` (initial `wazig.4`) → `3,209` (post-`#9`) → `1,674` (`wazig.4` post-`#19`) → **`1,496` (`ReleaseFast +simd128`)** in **`wazig v0.17.0-wazig.6`** (`cataggar/zig@v0.17.0-wazig.6`) + `cataggar/knots#11`–`#33`, exceeding all `cataggar/knots#9`, `#14`, and `#19` targets:

| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.6` (`ReleaseSmall`) | `wazig.6` (`ReleaseFast +simd128`) | `wazigl.6` (`ReleaseFast +simd128`) | `wazig.6` Speedup vs `wazig.3` | `knots#19` Goal |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.112 ms (8,864.0 FPS) | **0.087 ms (11,476.1 FPS)** | **0.100 ms (9,942.6 FPS)** | **18.07x faster** | `>= 9,500–10,000+ FPS` (**Exceeded**) |
| **`text_bench`** | 5.505 ms (181.7 FPS) | 0.385 ms (2,576.0 FPS) | **0.342 ms (2,904.5 FPS)** | **0.329 ms (3,021.4 FPS)** | **15.99x faster** | `>= 2,300–2,600+ FPS` (**Exceeded**) |
| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.153 ms (6,425.3 FPS) | **0.099 ms (10,005.1 FPS)** | **0.091 ms (10,769.5 FPS)** | **12.84x faster** | `>= 5,000–6,100+ FPS` (**Exceeded**) |
| **`combined_frame`** | 3.286 ms (304.2 FPS) | 0.507 ms (1,982.1 FPS) | **0.367 ms (2,702.4 FPS)** | **0.270 ms (3,662.0 FPS)** | **8.88x faster** | `>= 1,800–2,270+ FPS` (**Exceeded**) |

- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`/`wazig.6`).
- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.
- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) & [`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` parameterized leaf inlining, single-caller `.small` inlining, and local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity`.
- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) & [`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — `@Vector` layout, `v128` `+simd128` SIMD arithmetic, and fused `cmp_vector` + `@reduce(.And/.Or)` lowering**: Lowered `Rect.eql` to `f32x4.eq` + `i32x4.all_true` (`12 B`).
- **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Wasm multivalue return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`, `HMetrics`, `[2]u8`, `u128`)**: Eliminated linear-memory `sret` stack frames for 2-scalar returns, allowing `curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`, and `fmt.digits2` to be completely inlined and removed in `ReleaseFast`.
- **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing**: Parallel 4-way `wasm32-wasi` test suite compilation completes with zero `Archive.zig` race panics (`18.92s` wall / `58.92s` CPU; **`0.226s`** total test execution time across all 12 suites — the fastest of all 4 compilers).
- **[`cataggar/zig#174`](https://github.com/cataggar/zig/issues/174)–[`#224`](https://github.com/cataggar/zig/pull/224) — By-value scalar parameter ABI (`classifyAutoParam`), read-only by-ref load & alloc alias elision across subblocks/`try` (`#215`/`#220`), `umulh` (`Wyhash.mum`) inline lowering, `tryElideMemcpyStackFrame` / `tryElideLeafStackFrame`, `0xfd` SIMD stack deltas (`#193`), `@Vector` lane & `u128` SROA (`#194`/`#222`), post-inlining shadow-stack scalarization (`#195`), single-scalar payload union SROA (`#213`), inline zero-fill stores (`#216`/`#218`), Wasm SIMD `pmin`/`pmax` (`#205`/`#212`), `Optimize.zig` MIR & `Optimizer.zig` LICM/DSE/store coalescing/2-pass inlining (`#214`/`#217`/`#223`/`#224`), and `.auto` multi-value ABI up to 4 scalars (`#223`/`#224`)**: Eliminated `memory.copy` aggregate parameter staging, inlined `Wyhash.round`/`mum`, promoted `sizing.Axis` tagged unions and `u128` values to scalar locals, and shrunk `wazig.wasm` itself from `31.57 MiB` to `30.31 MiB`.
- **[`cataggar/knots#11`](https://github.com/cataggar/knots/pull/11)–[`#17`](https://github.com/cataggar/knots/pull/17) (`#9`) & [`cataggar/knots#20`](https://github.com/cataggar/knots/pull/20)–[`#33`](https://github.com/cataggar/knots/pull/33) (`#19`, `#27`, `#28`) — Precomputed curve extents & scatter-first per-band sort (`#11`, `#15`, `#20`, `#25`, `#26`), 2-pass child layout, `comptime is_row` flex layout, O(1) `grow_main_total`, `IdContext`/`CodepointContext` integer hash contexts, compact 2-scalar `Key`, settled transition & `Style.resolve` fast paths (`#16`, `#17`, `#21`, `#25`), and in-place `DrawList` writes, single-pass `commandBounds` + grid insertion, and `comptime std.mem.zeroes` instance templates (`#22`, `#23`, `#26`)**: Boosted `wazig.6` `ReleaseFast +simd128` to **`11,476.1 FPS` (`layout_bench`)**, **`2,904.5 FPS` (`text_bench`)**, **`10,005.1 FPS` (`render_bench`)**, and **`2,702.4 FPS` (`combined_frame`)**.

### E.2 Top 15 Functions in `wazig v0.17.0-wazig.6` `ReleaseFast +simd128` (`1,496` total samples @ 100us)

| Self | Self% | Total | Tot% | Bytes | Function |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 327 | 21.86% | 327 | 21.86% | 7,336 | `band.partitionWithBuffer` |
| 156 | 10.43% | 166 | 11.10% | 8,696 | `DrawList.emitBatched` |
| 107 | 7.15% | 276 | 18.45% | 4,113 | `wasm_bench_runner.buildRenderFrame` |
| 93 | 6.22% | 227 | 15.17% | 7,060 | `wasm_bench_runner.buildDashboardLayoutFrame` |
| 91 | 6.08% | 91 | 6.08% | 7,445 | `Context.computeLayoutNode` |
| 79 | 5.28% | 94 | 6.28% | 5,830 | `TrueType.glyphShapeTT` |
| 41 | 2.74% | 42 | 2.81% | 2,059 | `Context.open` |
| 40 | 2.67% | 374 | 25.00% | 3,996 | `GlyphBuilder.addCurves` |
| 30 | 2.01% | 36 | 2.41% | 1,051 | `DrawList.pushInstances` |
| 30 | 2.01% | 30 | 2.01% | 1,971 | `Context.computeSizes` |
| 27 | 1.80% | 43 | 2.87% | 1,607 | `Face.buildWrappedLines` |
| 24 | 1.60% | 45 | 3.01% | 5,563 | `Context.tessellateLayer` |
| 20 | 1.34% | 20 | 1.34% | 584 | `curve.decomposeVerticesInto` |
| 18 | 1.20% | 45 | 3.01% | 2,950 | `Face.shape` |
| 17 | 1.14% | 25 | 1.67% | 1,226 | `DrawList.push` |

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
- **[`cataggar/zig#226`](https://github.com/cataggar/zig/issues/226)** (fixed in [`#227`](https://github.com/cataggar/zig/pull/227) / `v0.17.0-wazig.6` & `v0.17.0-wazigl.6`): `wasm(Optimizer): cache moduleUsesSimd per module to avoid O(functions * body_len) rescans on non-SIMD modules`.

---

## F. wasm32-freestanding vs wasm64-freestanding (Memory64) Head-to-Head

Head-to-head comparison of `wasm32-freestanding` (32-bit pointers, 4 GiB linear address space) vs `wasm64-freestanding` (64-bit pointers, >4 GiB Memory64 linear address space, [`cataggar/knots#18`](https://github.com/cataggar/knots/issues/18)) across `Debug`, `ReleaseSmall`, and `ReleaseFast (+simd128)` (`-Dcpu=generic+simd128`) using both **`wazig v0.17.0-wazig.6` (`-fno-llvm`)** and **`wazigl v0.17.0-wazigl.6` (`-fllvm`)**, executed under `wasmtime v50.0.1` (`wasmtime run -W memory64=y`).

### F.1 Playground (`examples/playground`) — Compile Time & `.wasm` Binary Size

| Compiler & Mode | Target | Cold Compile | Warm Compile (Median of 3) | Raw `.wasm` Size | `gzip -9` Size | `zstd -19` Size | `wasm64` vs `wasm32` Size Delta (Raw / `gzip` / `zstd`) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **`wazig.6` (`-fno-llvm`) — `Debug`** | `wasm32-freestanding` | 23.71 s | 17.32 s | 2,883,073 B (2,815.5 KB) | 984,494 B (961.4 KB) | **773,408 B (755.3 KB)** | — |
| **`wazig.6` (`-fno-llvm`) — `Debug`** | `wasm64-freestanding` | 23.84 s | 17.32 s | 3,399,932 B (3,320.2 KB) | 1,026,419 B (1,002.4 KB) | **795,633 B (777.0 KB)** | **+17.9% / +4.3% / +2.9%** |
| **`wazig.6` (`-fno-llvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 20.76 s | 14.48 s | 2,318,951 B (2,264.6 KB) | 844,111 B (824.3 KB) | **678,177 B (662.3 KB)** | — |
| **`wazig.6` (`-fno-llvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 20.76 s | 14.24 s | 2,777,405 B (2,712.3 KB) | 866,324 B (846.0 KB) | **697,163 B (680.8 KB)** | **+19.8% / +2.6% / +2.8%** |
| **`wazig.6` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 23.44 s | 16.91 s | 2,584,919 B (2,524.3 KB) | 940,042 B (918.0 KB) | **721,350 B (704.4 KB)** | — |
| **`wazig.6` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 23.32 s | 16.68 s | 3,085,347 B (3,013.0 KB) | 984,785 B (961.7 KB) | **773,635 B (755.5 KB)** | **+19.4% / +4.8% / +7.2%** |
| **`wazigl.6` (`-fllvm`) — `Debug`** | `wasm32-freestanding` | 47.41 s | 33.20 s | 6,815,199 B (6,655.5 KB) | 2,251,860 B (2,199.1 KB) | **1,722,987 B (1,682.6 KB)** | — |
| **`wazigl.6` (`-fllvm`) — `Debug`** | `wasm64-freestanding` | 45.91 s | 35.01 s | 7,622,249 B (7,443.6 KB) | 2,308,175 B (2,254.1 KB) | **1,744,305 B (1,703.4 KB)** | **+11.8% / +2.5% / +1.2%** |
| **`wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 44.06 s | 34.82 s | 1,863,575 B (1,819.9 KB) | 727,202 B (710.2 KB) | **611,317 B (597.0 KB)** | — |
| **`wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 43.49 s | 35.25 s | 2,305,932 B (2,251.9 KB) | 743,499 B (726.1 KB) | **621,345 B (606.8 KB)** | **+23.7% / +2.2% / +1.6%** |
| **`wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 80.77 s | 64.53 s | 5,564,726 B (5,434.3 KB) | 1,809,242 B (1,766.8 KB) | **1,479,127 B (1,444.5 KB)** | — |
| **`wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 79.70 s | 64.44 s | 6,863,594 B (6,702.7 KB) | 1,855,905 B (1,812.4 KB) | **1,517,890 B (1,482.3 KB)** | **+23.3% / +2.6% / +2.6%** |

### F.2 Headless Benchmark Runner (`knots-wasm-bench`) — Compile Time & `.wasm` Binary Size

| Compiler & Mode | Target | Cold Compile | Warm Compile (Median of 3) | Raw `.wasm` Size | `gzip -9` Size | `zstd -19` Size | `wasm64` vs `wasm32` Size Delta (Raw / `gzip` / `zstd`) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **`wazig.6` (`-fno-llvm`) — `Debug`** | `wasm32-freestanding` | 12.14 s | 5.79 s | 1,084,332 B (1,058.9 KB) | 449,936 B (439.4 KB) | **389,506 B (380.4 KB)** | — |
| **`wazig.6` (`-fno-llvm`) — `Debug`** | `wasm64-freestanding` | 12.16 s | 5.81 s | 1,136,092 B (1,109.5 KB) | 459,145 B (448.4 KB) | **394,429 B (385.2 KB)** | **+4.8% / +2.0% / +1.3%** |
| **`wazig.6` (`-fno-llvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 10.13 s | 4.05 s | 809,703 B (790.7 KB) | 370,167 B (361.5 KB) | **326,232 B (318.6 KB)** | — |
| **`wazig.6` (`-fno-llvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 10.12 s | 3.97 s | 825,814 B (806.5 KB) | 372,956 B (364.2 KB) | **327,361 B (319.7 KB)** | **+2.0% / +0.8% / +0.3%** |
| **`wazig.6` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 11.35 s | 4.97 s | 912,972 B (891.6 KB) | 410,161 B (400.5 KB) | **359,353 B (350.9 KB)** | — |
| **`wazig.6` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 11.30 s | 4.84 s | 939,633 B (917.6 KB) | 417,246 B (407.5 KB) | **363,727 B (355.2 KB)** | **+2.9% / +1.7% / +1.2%** |
| **`wazigl.6` (`-fllvm`) — `Debug`** | `wasm32-freestanding` | 25.32 s | 13.44 s | 3,153,625 B (3,079.7 KB) | 1,083,039 B (1,057.7 KB) | **890,150 B (869.3 KB)** | — |
| **`wazigl.6` (`-fllvm`) — `Debug`** | `wasm64-freestanding` | 25.28 s | 13.40 s | 3,377,709 B (3,298.5 KB) | 1,098,010 B (1,072.3 KB) | **892,968 B (872.0 KB)** | **+7.1% / +1.4% / +0.3%** |
| **`wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 20.91 s | 11.65 s | 657,922 B (642.5 KB) | 323,529 B (315.9 KB) | **290,394 B (283.6 KB)** | — |
| **`wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 21.49 s | 12.02 s | 667,539 B (651.9 KB) | 325,390 B (317.8 KB) | **292,144 B (285.3 KB)** | **+1.5% / +0.6% / +0.6%** |
| **`wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 35.67 s | 21.01 s | 2,577,979 B (2,517.6 KB) | 899,386 B (878.3 KB) | **768,447 B (750.4 KB)** | — |
| **`wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 35.43 s | 20.70 s | 3,035,902 B (2,964.7 KB) | 919,334 B (897.8 KB) | **782,510 B (764.2 KB)** | **+17.8% / +2.2% / +1.8%** |

### F.3 Runtime Execution Performance (`wasmtime run -W memory64=y <knots-wasm-bench.wasm> --json`)

> **Checksum Verification**: Every `wasm32-freestanding` and `wasm64-freestanding` run produces bit-identical output checksums across all optimization modes (`total_checksum = 2186326712793932228` under `wazig -fno-llvm` and `total_checksum = 13151244770801229719` under `wazigl -fllvm`, with matching per-workload checksums `layout_bench = 417689973924794692`, `text_bench = 12606774574179943755` / `7686275582076872382`, `render_bench = 8226312248921777708`, `combined_frame = 8133605907336869050`).

#### `wazig v0.17.0-wazig.6` (`-fno-llvm`, Self-Hosted Wasm Backend)

| Optimize Mode | Workload | `wasm32-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64` vs `wasm32` Latency / Throughput | Checksum |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`Debug`** | `layout_bench` (300 iters, 2,047 elems) | **0.250 ms** / 0.251 ms / 0.255 ms (**3,983.2 FPS**) | **0.429 ms** / 0.430 ms / 0.432 ms (**2,326.5 FPS**) | +71.5% ms / 0.58x FPS | `417689973924794692` |
| **`Debug`** | `text_bench` (200 iters, 3,405 elems) | **0.592 ms** / 0.590 ms / 0.595 ms (**1,693.9 FPS**) | **0.812 ms** / 0.811 ms / 0.817 ms (**1,233.0 FPS**) | +37.0% ms / 0.73x FPS | `12606774574179943755` |
| **`Debug`** | `render_bench` (300 iters, 5,100 elems) | **0.155 ms** / 0.157 ms / 0.168 ms (**6,353.2 FPS**) | **0.230 ms** / 0.233 ms / 0.243 ms (**4,293.1 FPS**) | +48.1% ms / 0.68x FPS | `8226312248921777708` |
| **`Debug`** | `combined_frame` (100 iters, 514 elems) | **0.632 ms** / 0.630 ms / 0.638 ms (**1,586.4 FPS**) | **0.950 ms** / 0.952 ms / 0.958 ms (**1,051.0 FPS**) | +50.2% ms / 0.66x FPS | `8133605907336869050` |
| **`Debug`** | **`total_bench_ms`** | **344.92 ms** | **518.10 ms** | **+50.2% ms / 0.67x** | `2186326712793932228` |
| **`ReleaseSmall`** | `layout_bench` (300 iters, 2,047 elems) | **0.112 ms** / 0.112 ms / 0.116 ms (**8,912.6 FPS**) | **0.171 ms** / 0.171 ms / 0.175 ms (**5,836.4 FPS**) | +52.8% ms / 0.65x FPS | `417689973924794692` |
| **`ReleaseSmall`** | `text_bench` (200 iters, 3,405 elems) | **0.381 ms** / 0.383 ms / 0.389 ms (**2,609.5 FPS**) | **0.532 ms** / 0.530 ms / 0.536 ms (**1,885.3 FPS**) | +39.8% ms / 0.72x FPS | `12606774574179943755` |
| **`ReleaseSmall`** | `render_bench` (300 iters, 5,100 elems) | **0.114 ms** / 0.115 ms / 0.126 ms (**8,663.5 FPS**) | **0.157 ms** / 0.159 ms / 0.170 ms (**6,277.8 FPS**) | +37.8% ms / 0.72x FPS | `8226312248921777708` |
| **`ReleaseSmall`** | `combined_frame` (100 iters, 514 elems) | **0.487 ms** / 0.485 ms / 0.491 ms (**2,062.7 FPS**) | **0.688 ms** / 0.687 ms / 0.698 ms (**1,455.2 FPS**) | +41.4% ms / 0.71x FPS | `8133605907336869050` |
| **`ReleaseSmall`** | **`total_bench_ms`** | **219.50 ms** | **310.49 ms** | **+41.4% ms / 0.71x** | `2186326712793932228` |
| **`ReleaseFast (+simd128)`** | `layout_bench` (300 iters, 2,047 elems) | **0.086 ms** / 0.087 ms / 0.090 ms (**11,533.5 FPS**) | **0.151 ms** / 0.151 ms / 0.155 ms (**6,603.8 FPS**) | +74.6% ms / 0.57x FPS | `417689973924794692` |
| **`ReleaseFast (+simd128)`** | `text_bench` (200 iters, 3,405 elems) | **0.340 ms** / 0.343 ms / 0.349 ms (**2,918.5 FPS**) | **0.507 ms** / 0.505 ms / 0.512 ms (**1,979.2 FPS**) | +48.9% ms / 0.68x FPS | `12606774574179943755` |
| **`ReleaseFast (+simd128)`** | `render_bench` (300 iters, 5,100 elems) | **0.099 ms** / 0.100 ms / 0.112 ms (**9,959.3 FPS**) | **0.153 ms** / 0.155 ms / 0.165 ms (**6,447.9 FPS**) | +54.6% ms / 0.65x FPS | `8226312248921777708` |
| **`ReleaseFast (+simd128)`** | `combined_frame` (100 iters, 514 elems) | **0.367 ms** / 0.369 ms / 0.377 ms (**2,707.4 FPS**) | **0.609 ms** / 0.607 ms / 0.617 ms (**1,647.2 FPS**) | +66.1% ms / 0.61x FPS | `8133605907336869050` |
| **`ReleaseFast (+simd128)`** | **`total_bench_ms`** | **183.29 ms** | **287.25 ms** | **+56.7% ms / 0.64x** | `2186326712793932228` |

#### `wazigl v0.17.0-wazigl.6` (`-fllvm`, LLVM 22 Backend)

| Optimize Mode | Workload | `wasm32-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64` vs `wasm32` Latency / Throughput | Checksum |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`Debug`** | `layout_bench` (300 iters, 2,047 elems) | **0.628 ms** / 0.628 ms / 0.632 ms (**1,592.9 FPS**) | **0.893 ms** / 0.894 ms / 0.897 ms (**1,119.1 FPS**) | +42.1% ms / 0.70x FPS | `417689973924794692` |
| **`Debug`** | `text_bench` (200 iters, 3,405 elems) | **1.142 ms** / 1.143 ms / 1.152 ms (**874.6 FPS**) | **1.524 ms** / 1.524 ms / 1.534 ms (**656.0 FPS**) | +33.4% ms / 0.75x FPS | `7686275582076872382` |
| **`Debug`** | `render_bench` (300 iters, 5,100 elems) | **0.435 ms** / 0.440 ms / 0.450 ms (**2,273.0 FPS**) | **0.629 ms** / 0.625 ms / 0.637 ms (**1,600.3 FPS**) | +44.4% ms / 0.70x FPS | `8226312248921777708` |
| **`Debug`** | `combined_frame` (100 iters, 514 elems) | **1.738 ms** / 1.739 ms / 1.749 ms (**575.1 FPS**) | **2.215 ms** / 2.215 ms / 2.224 ms (**451.5 FPS**) | +27.4% ms / 0.79x FPS | `8133605907336869050` |
| **`Debug`** | **`total_bench_ms`** | **820.17 ms** | **1,113.40 ms** | **+35.8% ms / 0.74x** | `13151244770801229719` |
| **`ReleaseSmall`** | `layout_bench` (300 iters, 2,047 elems) | **0.110 ms** / 0.110 ms / 0.113 ms (**9,079.9 FPS**) | **0.155 ms** / 0.156 ms / 0.159 ms (**6,419.7 FPS**) | +41.5% ms / 0.71x FPS | `417689973924794692` |
| **`ReleaseSmall`** | `text_bench` (200 iters, 3,405 elems) | **0.390 ms** / 0.392 ms / 0.399 ms (**2,549.1 FPS**) | **0.502 ms** / 0.502 ms / 0.508 ms (**1,991.8 FPS**) | +28.9% ms / 0.78x FPS | `7686275582076872382` |
| **`ReleaseSmall`** | `render_bench` (300 iters, 5,100 elems) | **0.092 ms** / 0.094 ms / 0.105 ms (**10,687.6 FPS**) | **0.126 ms** / 0.128 ms / 0.139 ms (**7,820.7 FPS**) | +36.8% ms / 0.73x FPS | `8226312248921777708` |
| **`ReleaseSmall`** | `combined_frame` (100 iters, 514 elems) | **0.390 ms** / 0.393 ms / 0.404 ms (**2,542.6 FPS**) | **0.554 ms** / 0.552 ms / 0.558 ms (**1,810.2 FPS**) | +42.1% ms / 0.71x FPS | `8133605907336869050` |
| **`ReleaseSmall`** | **`total_bench_ms`** | **203.10 ms** | **272.92 ms** | **+34.4% ms / 0.74x** | `13151244770801229719` |
| **`ReleaseFast (+simd128)`** | `layout_bench` (300 iters, 2,047 elems) | **0.101 ms** / 0.102 ms / 0.105 ms (**9,832.1 FPS**) | **0.144 ms** / 0.144 ms / 0.147 ms (**6,940.2 FPS**) | +41.9% ms / 0.71x FPS | `417689973924794692` |
| **`ReleaseFast (+simd128)`** | `text_bench` (200 iters, 3,405 elems) | **0.328 ms** / 0.329 ms / 0.335 ms (**3,037.6 FPS**) | **0.430 ms** / 0.431 ms / 0.438 ms (**2,321.0 FPS**) | +31.4% ms / 0.76x FPS | `7686275582076872382` |
| **`ReleaseFast (+simd128)`** | `render_bench` (300 iters, 5,100 elems) | **0.086 ms** / 0.088 ms / 0.100 ms (**11,395.6 FPS**) | **0.121 ms** / 0.122 ms / 0.131 ms (**8,180.7 FPS**) | +39.9% ms / 0.72x FPS | `8226312248921777708` |
| **`ReleaseFast (+simd128)`** | `combined_frame` (100 iters, 514 elems) | **0.270 ms** / 0.272 ms / 0.283 ms (**3,671.1 FPS**) | **0.401 ms** / 0.405 ms / 0.415 ms (**2,467.9 FPS**) | +48.6% ms / 0.67x FPS | `8133605907336869050` |
| **`ReleaseFast (+simd128)`** | **`total_bench_ms`** | **170.15 ms** | **234.25 ms** | **+37.7% ms / 0.73x** | `13151244770801229719` |

### F.4 Key Takeaways on `wasm64-freestanding` (Memory64) vs `wasm32-freestanding` Tradeoffs

1. **Zero Compile-Time Penalty**: Compiling for `wasm64-freestanding` takes virtually the exact same time as `wasm32-freestanding` across both `wazig.6` (`3.97s` vs `4.05s` warm on `knots-wasm-bench ReleaseSmall`, `14.24s` vs `14.48s` warm on `playground ReleaseSmall`) and `wazigl.6` (`12.02s` vs `11.65s` warm on `knots-wasm-bench ReleaseSmall`, `35.25s` vs `34.82s` warm on `playground ReleaseSmall`).
2. **Negligible Compressed Binary Size Overhead (`+0.3%` to `+7.2%` `zstd -19`)**:
   - On `knots-wasm-bench`, `wasm64-freestanding` adds only **`+1.5%`–`+2.0%` raw** (`+0.3%`–`+0.6%` `zstd -19`) in `ReleaseSmall` (`319.7 KB` vs `318.6 KB` zstd under `wazig.6`; `285.3 KB` vs `283.6 KB` zstd under `wazigl.6`).
   - On `examples/playground` (which embeds static UI/font tables and pointer-rich descriptors), 64-bit pointers and LEB128 `i64` address offsets increase raw `.wasm` size by `+17.9%`–`+19.8%` under `wazig.6` and `+11.8%`–`+23.7%` under `wazigl.6`, but the extra upper-zero bytes in 64-bit pointers compress away almost completely under `zstd -19` (**`+1.6%`–`+2.8%` in `ReleaseSmall`**, e.g. `606.8 KB` vs `597.0 KB` in `wazigl.6 ReleaseSmall` and `680.8 KB` vs `662.3 KB` in `wazig.6 ReleaseSmall`).
3. **Runtime Performance & Memory64 Bounds-Checking Overhead (`+34.3%` to `+56.7%` total suite time)**:
   - Across `knots-wasm-bench`, `wasm64-freestanding` runs at **0.64x–0.74x** the overall throughput of `wasm32-freestanding` (`total_bench_ms`: `287.25 ms` vs `183.29 ms` in `wazig.6 ReleaseFast +simd128`; `234.25 ms` vs `170.15 ms` in `wazigl.6 ReleaseFast +simd128`), while still exceeding all `cataggar/knots#9` 600–1,800 FPS targets by a wide margin (`6,603.8 FPS` / `6,940.2 FPS` on `layout_bench`, `6,447.9 FPS` / `8,180.7 FPS` on `render_bench`, `1,647.2 FPS` / `2,467.9 FPS` on `combined_frame`).
   - This runtime delta is driven by two fundamental architectural differences in WebAssembly Memory64:
     1. **Explicit Software Bounds Checks vs 4 GiB Virtual Guard Pages**: For `wasm32`, Wasmtime reserves a 4 GiB virtual address region with guard pages so `i32` loads/stores execute without explicit bounds-check branches. For `wasm64` (Memory64), the 64-bit address space cannot be covered by virtual memory guard pages alone, requiring explicit compare-and-branch bounds checks on linear-memory accesses.
     2. **Doubled Pointer & Slice Width (`usize = u64`, `[]T = 16 B` vs `8 B`)**: Pointer-heavy tree/slice traversals (`layout_bench`) experience higher cache-line pressure and 64-bit address arithmetic compared to SIMD/float-heavy batch generation (`render_bench`).
4. **When to Choose `wasm32-freestanding` vs `wasm64-freestanding`**:
   - **`wasm32-freestanding` (Default for Web UI)**: Delivers maximum single-core throughput and smaller uncompressed binaries whenever the workload fits within the 4 GiB address space.
   - **`wasm64-freestanding` (Memory64)**: Unlocks **>4 GiB linear memory** (up to 16 GiB in browsers/Wasmtime) with zero source changes, identical deterministic output, near-zero `zstd` wire-size overhead (`+0.3%`–`+2.8%` in `ReleaseSmall`), and `1,647`–`2,468 FPS` full-frame UI throughput.

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
