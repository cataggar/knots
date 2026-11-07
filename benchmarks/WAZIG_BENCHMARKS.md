# wazig (v0.17.0-wazig.4) & wazigl (v0.17.0-wazigl.4) vs zig v0.17.0 Comprehensive Benchmark Report

Reproducible 4-way benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig v0.17.0-wazig.4`** (`cataggar/zig@v0.17.0-wazig.4`, `-fno-llvm`): universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1` (`8.47 MiB` `.tar.zst`, `60.11 MiB` unpacked), including `cataggar/zig#158`–`#188` and `cataggar/knots#11`, `#15` (`#13`), `#16` (`#12`, `#14`), `#17`
- **`wazigl v0.17.0-wazigl.4`** (`cataggar/zig@v0.17.0-wazigl.4`, `-fllvm`): universal `wasm64-wasip3` compiler with full LLVM 22 Wasm backend executed via `wasmtime v50.0.1` (`36.48 MiB` `.tar.zst`, `226.02 MiB` unpacked)
- **`zig v0.17.0 -fno-llvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with self-hosted Wasm backend)
- **`zig v0.17.0 -fllvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with LLVM 22 backend)

---

## A. Toolchain & CI Footprint

| Metric | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0` (Standard) | Reduction / Advantage |
| :--- | :--- | :--- | :--- | :--- |
| **Release Archive Size** | **8.47 MiB** (`wazig.tar.zst`) | **36.48 MiB** (`wazigl.tar.zst`) | 50.43 MiB (`zig-aarch64-linux-0.17.0.tar.xz`) | **`wazig`: 5.96x smaller (-83.2%) / `wazigl`: 1.38x smaller (-27.7%)** |
| **Unpacked Release Size** | **60.11 MiB** (`31.57 MiB` `wazig.wasm` + `28.54 MiB` `lib/`) | **226.02 MiB** (`197.48 MiB` `wazigl.wasm` + `28.54 MiB` `lib/`) | 343.65 MiB (`163.74 MiB` `zig` + `178.95 MiB` `lib/`; `397.74 MiB` on disk) | **`wazig`: 5.72x smaller (-82.5%) / `wazigl`: 1.52x smaller (-34.2%)** |
| **Installed File Count** | **1,324 files** | **1,324 files** | 19,506 files | **14.7x fewer files (-93.2%)** |
| **Binary Portability** | wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | wasm64-wasip3 + LLVM 22 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | OS/arch-specific native binaries (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows, etc.) | **Single universal artifact per tier** |
| **Supply-Chain Attestation** | Native Sigstore bundle verified via ghr | Native Sigstore bundle verified via ghr | minisign signature (external tool required) | **Zero extra verification tools** |
| **Wasm Build Dependency Fetch** | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~230+ MiB compressed / ~680 MiB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |

---

## B. Compilation Speed (Cold Cache & Warm Cache)

> All `wazig` and `wazigl` measurements run with Wasmtime's compiled module cache warmed.

| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |
| :--- | ---: | ---: | ---: | ---: |
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.487s** | 1.793s | 0.044s | 0.044s |
| `wasm_bench_runner.zig` (`Debug`) | 12.71s (cold) / 6.10s (warm) | 32.50s (cold) / 16.63s (warm) | 3.70s (cold) / 0.29s (warm) | 6.00s (cold) / 2.53s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 10.91s (cold) / 4.49s (warm) | 25.89s (cold) / 15.12s (warm) | 2.25s (cold) / 0.23s (warm) | 6.79s (cold) / 4.68s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast`) | 11.67s (cold) / 5.01s (warm) | 43.54s (cold) / 27.77s (warm) | 3.46s (cold) / 0.24s (warm) | 12.77s (cold) / 9.19s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | 11.84s (cold) / 5.20s (warm) | 44.32s (cold) / 28.30s (warm) | FAIL (`IllDefinedMemoryLayout`)* | 14.20s (cold) / 10.28s (warm) |
| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | 20.80s wall (63.0s CPU) | 62.42s wall (203.8s CPU) | 4.30s wall (16.3s CPU) | 10.45s wall (34.5s CPU) |
| `examples/triangle` (`Debug`) | 10.30s (cold) / 7.58s (warm) | 31.75s (cold) / 18.31s (warm) | 2.76s (cold) / 0.30s (warm) | 5.58s (cold) / 2.73s (warm) |
| `examples/triangle` (`ReleaseSmall`) | 8.05s (cold) / 5.74s (warm) | 24.61s (cold) / 18.44s (warm) | 2.11s (cold) / 0.25s (warm) | 7.58s (cold) / 5.99s (warm) |
| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | 17.65s | 33.99s | 0.95s | 5.15s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 15.13s | 36.29s | 0.92s | 11.61s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | 17.40s | 33.74s | 0.96s | 5.14s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 15.50s | 36.09s | 0.92s | 11.73s |
| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **20.35s** | **44.21s** | FAIL (`global.get` asm)* | 7.83s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **17.86s** | **43.53s** | FAIL (`global.get` asm)* | 13.36s |
| `examples/embedded` (`Debug`) | 6.52s | 15.86s | 0.28s | 2.36s |
| `examples/embedded` (`ReleaseSmall`) | 4.84s | 15.03s | 0.22s | 4.60s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | 8.63s | 20.54s | 0.36s | 2.90s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | 6.94s | 20.16s | 0.30s | 6.26s |

**Compilation Speed Analysis (`wazig.4` vs `wazigl.4` vs `zig 0.17.0`):**
- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) vs `wazigl v0.17.0-wazigl.4` (`-fllvm`)**: Because `wazig` uses Zig's self-hosted WebAssembly backend (`src/codegen/wasm/CodeGen.zig` + `src/link/Wasm/component/Optimizer.zig`) without invoking LLVM's optimization passes, `wazig.4` compiles **1.93x–5.54x faster** than `wazigl.4` across every workload (`4.49s` vs `15.12s` warm on `wasm_bench_runner ReleaseSmall`, `5.20s` vs `28.30s` warm on `ReleaseFast +simd128`, `20.80s` vs `62.42s` wall time across all 12 WASI test suites, and `0.487s` vs `1.793s` on `fmt --check`).
- **`wazig v0.17.0-wazig.4` vs Native `zig v0.17.0 -fllvm`**: Even running inside Wasmtime (`wasm64-wasip3`), `wazig.4` warm-cache builds (`4.49s` `ReleaseSmall`, `5.01s` `ReleaseFast`, `5.20s` `ReleaseFast +simd128`) are **faster than or competitive with native `zig 0.17.0 -fllvm`** (`4.68s` `ReleaseSmall`, `9.19s` `ReleaseFast`, `10.28s` `ReleaseFast +simd128` — **up to 1.98x faster**), and `triangle` (`5.74s` vs `5.99s` warm) and `embedded` (`4.84s` vs `4.60s`) build at near-native LLVM speed.
- **`wazigl v0.17.0-wazigl.4` vs Native `zig v0.17.0 -fllvm`**: Running the full LLVM 22 + Clang C++ toolchain inside Wasmtime (`wazigl.wasm`, `197.48 MiB`) incurs a ~2.8x–3.5x Wasmtime guest execution multiplier relative to native `zig -fllvm` (`15.12s` vs `4.68s` warm on `ReleaseSmall`, `36.29s` vs `11.61s` on `playground ReleaseSmall`), making `wazig.4` ideal for fast CI test/check inner loops and `wazigl.4` ideal when maximum LLVM codegen optimization is desired without OS/arch-specific native compiler binaries.

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` / `wazigl` vs `zig -fllvm` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 2,894.1 KB / 972.0 KB / **757.1 KB** | 6,116.3 KB / 1,979.0 KB / **1,511.5 KB** | 3,362.5 KB / 1,028.7 KB / **764.9 KB** | 6,117.2 KB / 1,978.7 KB / **1,533.8 KB** | `wazig`: **-13.9%** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,496.9 KB / 867.1 KB / **659.9 KB** | 1,782.7 KB / 700.1 KB / **575.7 KB** | 2,795.1 KB / 877.7 KB / **684.9 KB** | 1,782.7 KB / 700.1 KB / **590.6 KB** | `wazig`: **-10.7%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 2,859.9 KB / 967.1 KB / **747.7 KB** | 6,082.0 KB / 1,971.3 KB / **1,530.8 KB** | 3,328.2 KB / 1,023.8 KB / **781.3 KB** | 6,083.0 KB / 1,970.6 KB / **1,528.7 KB** | `wazig`: **-14.1%** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,462.6 KB / 862.2 KB / **661.5 KB** | 1,748.5 KB / 693.5 KB / **584.8 KB** | 2,760.9 KB / 872.5 KB / **682.3 KB** | 1,748.5 KB / 693.5 KB / **584.8 KB** | `wazig`: **-10.8%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 2,904.7 KB / 974.7 KB / **753.2 KB** | 6,155.9 KB / 1,993.7 KB / **1,516.9 KB** | FAIL (`global.get` asm)* | 6,156.9 KB / 1,993.5 KB / **1,537.0 KB** | **`wazig` succeeds** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,504.7 KB / 869.7 KB / **686.0 KB** | 1,786.8 KB / 702.8 KB / **570.8 KB** | FAIL (`global.get` asm)* | 1,786.8 KB / 702.8 KB / **570.8 KB** | **`wazig` succeeds** / `wazigl`: **0 B (same raw size)** |
| `triangle` (`Debug`) | 1,494.9 KB / 545.0 KB / **452.4 KB** | 3,803.7 KB / 1,263.2 KB / **1,020.0 KB** | 1,857.9 KB / 596.0 KB / **481.3 KB** | 3,803.9 KB / 1,262.8 KB / **1,018.7 KB** | `wazig`: **-19.5%** / `wazigl`: **-0.01%** |
| `triangle` (`ReleaseSmall`) | 1,194.4 KB / 458.6 KB / **391.4 KB** | 801.0 KB / 364.3 KB / **325.9 KB** | 1,413.0 KB / 472.7 KB / **396.2 KB** | 801.0 KB / 364.3 KB / **325.9 KB** | `wazig`: **-15.5%** / `wazigl`: **0 B (same raw size)** |
| `embedded` (`Debug`) | 1,314.0 KB / 478.7 KB / **402.5 KB** | 3,372.1 KB / 1,103.6 KB / **902.1 KB** | 1,635.8 KB / 524.4 KB / **430.7 KB** | 3,372.2 KB / 1,103.4 KB / **900.9 KB** | `wazig`: **-19.7%** / `wazigl`: **-0.00%** |
| `embedded` (`ReleaseSmall`) | 1,070.2 KB / 413.5 KB / **355.9 KB** | 734.4 KB / 337.6 KB / **302.4 KB** | 1,250.9 KB / 424.8 KB / **359.8 KB** | 734.4 KB / 337.6 KB / **302.4 KB** | `wazig`: **-14.4%** / `wazigl`: **0 B (same raw size)** |
| `benchmark` (`Debug`) | 1,515.6 KB / 552.1 KB / **457.9 KB** | 3,878.1 KB / 1,287.9 KB / **1,036.4 KB** | 1,889.3 KB / 604.6 KB / **487.1 KB** | 3,878.3 KB / 1,287.6 KB / **1,035.4 KB** | `wazig`: **-19.8%** / `wazigl`: **-0.01%** |
| `benchmark` (`ReleaseSmall`) | 1,211.2 KB / 463.5 KB / **395.4 KB** | 807.3 KB / 366.9 KB / **328.7 KB** | 1,438.2 KB / 478.4 KB / **401.1 KB** | 807.3 KB / 366.9 KB / **328.7 KB** | `wazig`: **-15.8%** / `wazigl`: **0 B (same raw size)** |
| `wasm_bench_runner` (`Debug`) | 1,206.5 KB / 474.2 KB / **404.9 KB** | 3,588.3 KB / 1,193.7 KB / **977.1 KB** | 1,611.2 KB / 540.4 KB / **443.3 KB** | 3,584.9 KB / 1,192.1 KB / **974.4 KB** | `wazig`: **-25.1%** / `wazigl`: **+0.10%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 902.4 KB / 390.0 KB / **340.3 KB** | 679.7 KB / 332.5 KB / **297.5 KB** | 1,171.1 KB / 418.0 KB / **356.7 KB** | 679.7 KB / 332.5 KB / **297.5 KB** | `wazig`: **-22.9%** / `wazigl`: **0 B (same raw size)** |
| `wasm_bench_runner` (`ReleaseFast`) | 1,076.6 KB / 441.0 KB / **381.3 KB** | 2,846.2 KB / 976.9 KB / **827.3 KB** | 1,309.8 KB / 450.3 KB / **386.6 KB** | 2,846.5 KB / 977.0 KB / **828.1 KB** | `wazig`: **-17.8%** / `wazigl`: **-0.01%** |
| `wasm_bench_runner` (`ReleaseFast +simd128`) | 1,077.9 KB / 441.9 KB / **381.8 KB** | 2,830.2 KB / 978.2 KB / **828.9 KB** | FAIL (`IllDefinedMemoryLayout`)* | 2,830.6 KB / 978.3 KB / **829.4 KB** | **`wazig` succeeds** / `wazigl`: **-0.01%** |
| All 12 `wasm32-wasi` Test Binaries (`Debug` Total) | 7,814.4 KB / 2,630.8 KB / **2,133.7 KB** | 29,118.9 KB / 8,867.0 KB / **7,192.6 KB** | 10,404.0 KB / 3,053.4 KB / **2,418.1 KB** | 29,079.3 KB / 8,847.2 KB / **7,162.3 KB** | `wazig`: **-24.9%** / `wazigl`: **+0.14%** |

**Key Binary Size Takeaways:**
- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) produces identical raw-size `ReleaseSmall` `.wasm` binaries (`0 B` raw size difference) to native `zig v0.17.0 -fllvm` across every single `ReleaseSmall` target:** `679.7 KB` raw (`297.5 KB` zstd) on `wasm_bench_runner`, `1,782.7 KB` raw (`575.7 KB` zstd) on `playground` WebGPU, `1,748.5 KB` raw (`584.8 KB` zstd) on `playground` WebGL2, `1,786.8 KB` raw (`570.8 KB` zstd) on `playground` WebGPU + threads, `801.0 KB` raw (`325.9 KB` zstd) on `triangle`, `734.4 KB` raw (`302.4 KB` zstd) on `embedded`, and `807.3 KB` raw (`328.7 KB` zstd) on `benchmark` — delivering full LLVM 22 codegen from a single universal `wasm64-wasip3` compiler.
- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) produces the smallest `Debug` and `ReleaseFast` `.wasm` binaries of all four compilers:**
  - In **`Debug`** builds, `wazig.4` is **13.9%–25.1% smaller** than upstream `zig 0.17.0 -fno-llvm` and **52.7%–73.2% smaller (2.11x–3.73x smaller)** than `wazigl.4` and `zig 0.17.0 -fllvm`.
  - In **`ReleaseFast +simd128`** builds, `wazig.4` (`1,077.9 KB` raw / `381.8 KB` zstd) is **2.63x smaller** than `wazigl.4` (`2,830.2 KB` raw / `828.9 KB` zstd) and `zig 0.17.0 -fllvm` (`2,830.6 KB` raw / `829.4 KB` zstd), because LLVM's `ReleaseFast` loop unrolling and aggressive inlining expand `.wasm` binary size by **4.16x** over `ReleaseSmall` (`679.7 KB` → `2,830.2 KB`), whereas `wazig`'s targeted leaf inliner (`Optimizer.zig`) adds only `+19.4%` over `ReleaseSmall` (`902.4 KB` → `1,077.9 KB`).
  - Across all 12 `wasm32-wasi` test binaries (`Debug`), `wazig.4` emits **7.63 MiB** raw (`2.08 MiB` zstd) vs **28.44 MiB** raw (`7.02 MiB` zstd) with `wazigl.4` / `zig -fllvm` (**3.73x smaller**), enabling the fastest test suite execution (`0.969s`).

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.154 ms** / 0.159 ms (**6,461.7 FPS**) | **0.113 ms** / 0.117 ms (**8,799.2 FPS**) | 0.414 ms / 0.417 ms (2,415.8 FPS) | 0.113 ms / 0.117 ms (8,803.0 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.663 ms** / 0.673 ms (**1,508.7 FPS**) | **0.485 ms** / 0.491 ms (**2,067.1 FPS**) | 1.642 ms / 1.651 ms (608.8 FPS) | 0.488 ms / 0.494 ms (2,053.2 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.493 ms** / 0.500 ms (**2,034.6 FPS**) | **0.270 ms** / 0.283 ms (**3,661.0 FPS**) | 0.988 ms / 0.996 ms (1,011.8 FPS) | 0.270 ms / 0.286 ms (3,642.3 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.121 ms** / 1.131 ms (**890.5 FPS**) | **0.701 ms** / 0.709 ms (**1,428.9 FPS**) | 2.501 ms / 2.516 ms (399.6 FPS) | 0.700 ms / 0.707 ms (1,430.8 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`

#### `ReleaseFast (+simd128)` (Default Wasm Target Features in `web_build.zig`)

| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.134 ms** / 0.140 ms (**7,415.9 FPS**) | **0.100 ms** / 0.104 ms (**9,925.0 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.100 ms / 0.105 ms (9,919.8 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.578 ms** / 0.584 ms (**1,734.8 FPS**) | **0.383 ms** / 0.394 ms (**2,591.5 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.386 ms / 0.392 ms (2,582.0 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.362 ms** / 0.374 ms (**2,730.7 FPS**) | **0.162 ms** / 0.172 ms (**6,115.4 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.162 ms / 0.172 ms (6,114.7 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **0.996 ms** / 1.003 ms (**1,003.1 FPS**) | **0.437 ms** / 0.446 ms (**2,272.7 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.439 ms / 0.447 ms (2,271.5 FPS) | `8133605907336869050` |

#### `ReleaseFast` (Baseline Wasm CPU without `+simd128`)

| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.133 ms** / 0.137 ms (**7,484.7 FPS**) | **0.108 ms** / 0.112 ms (**9,221.6 FPS**) | 0.415 ms / 0.418 ms (2,409.0 FPS) | 0.107 ms / 0.112 ms (9,251.0 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.577 ms** / 0.585 ms (**1,736.1 FPS**) | **0.363 ms** / 0.373 ms (**2,738.2 FPS**) | 1.636 ms / 1.648 ms (611.1 FPS) | 0.363 ms / 0.374 ms (2,740.3 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.448 ms** / 0.457 ms (**2,220.5 FPS**) | **0.169 ms** / 0.181 ms (**5,857.1 FPS**) | 1.014 ms / 1.022 ms (985.2 FPS) | 0.168 ms / 0.181 ms (5,886.9 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **1.019 ms** / 1.026 ms (**979.9 FPS**) | **0.444 ms** / 0.455 ms (**2,235.7 FPS**) | 2.499 ms / 2.513 ms (400.0 FPS) | 0.445 ms / 0.459 ms (2,232.4 FPS) | `8133605907336869050` |

**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**
- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) matches native `zig v0.17.0 -fllvm` runtime throughput across every mode:** In `ReleaseSmall`, `wazigl.4` achieves `8,799.2 FPS` (`layout_bench`), `2,067.1 FPS` (`text_bench`), `3,661.0 FPS` (`render_bench`), and `1,428.9 FPS` (`combined_frame`) — matching native `zig -fllvm` (`8,803.0`, `2,053.2`, `3,642.3`, `1,430.8 FPS`). In `ReleaseFast +simd128`, `wazigl.4` reaches **`9,925.0 FPS` (`0.100 ms`)** on `layout_bench`, **`6,115.4 FPS` (`0.162 ms`)** on `render_bench`, **`2,591.5 FPS` (`0.383 ms`)** on `text_bench`, and **`2,272.7 FPS` (`0.437 ms`)** on `combined_frame`.
- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) vs `zig v0.17.0 -fno-llvm`**: With `cataggar/zig#158`–`#188` (inline `@min`/`@max`, SROA to Wasm locals, parameterized leaf & single-call wrapper inlining, by-value scalar parameter ABI, read-only load & alloc alias elision, `v128` `+simd128` vector & `@reduce` lowering, multivalue 2-scalar returns) and `cataggar/knots#11`, `#15` (`#13`), `#16` (`#12`, `#14`), `#17`, `wazig.4` is **2.51x–3.11x faster** than upstream `zig 0.17.0 -fno-llvm` on the exact same `knots` source (`7,415.9–7,484.7 FPS` vs `2,409.0 FPS` on `layout_bench`, `1,734.8–1,736.1 FPS` vs `611.1 FPS` on `text_bench`, `2,730.7 FPS` vs `985.2 FPS` on `render_bench`, and `1,003.1 FPS` vs `400.0 FPS` on `combined_frame`), and **3.30x–11.68x faster** than `wazig v0.17.0-wazig.3`.
- **`wazig v0.17.0-wazig.4` `ReleaseFast +simd128` vs `ReleaseSmall`**: Parameterized leaf and single-call wrapper inlining in `.fast` mode (`band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `appendAssumeCapacity`, `Wyhash.round`/`mum`), Wasm multivalue 2-scalar returns (`curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`), and `v128` SIMD boost `wazig.4` `render_bench` from `2,034.6 FPS` (`ReleaseSmall`) to **`2,730.7 FPS` (+34.2%)**, `layout_bench` from `6,461.7 FPS` to **`7,415.9 FPS` (+14.8% SIMD / `7,484.7 FPS` +15.8% `ReleaseFast`)**, `text_bench` from `1,508.7 FPS` to **`1,734.8–1,736.1 FPS` (+15.0%–15.1%)**, and `combined_frame` from `890.5 FPS` to **`1,003.1 FPS` (+12.6%)**.

### D.3 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.339 ms** / 0.343 ms (**2,946.3 FPS**) | 0.717 ms / 0.721 ms (1,395.2 FPS) | 0.794 ms / 0.798 ms (1,259.2 FPS) | 0.718 ms / 0.721 ms (1,393.8 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.911 ms** / 0.919 ms (**1,097.7 FPS**) | 1.755 ms / 1.765 ms (569.8 FPS) | 2.145 ms / 2.157 ms (465.9 FPS) | 1.757 ms / 1.768 ms (569.1 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.561 ms** / 0.565 ms (**1,793.9 FPS**) | 1.045 ms / 1.054 ms (955.8 FPS) | 1.170 ms / 1.178 ms (853.9 FPS) | 1.046 ms / 1.054 ms (955.6 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.384 ms** / 1.397 ms (**722.6 FPS**) | 2.738 ms / 2.750 ms (365.3 FPS) | 2.869 ms / 2.877 ms (348.6 FPS) | 2.733 ms / 2.744 ms (365.9 FPS) | `8133605907336869050` |

**`Debug` Runtime Highlight:** In `Debug` builds, `wazig v0.17.0-wazig.4` (`-fno-llvm`) is **1.88x–2.11x faster at runtime than both `wazigl v0.17.0-wazigl.4` and `zig v0.17.0 -fllvm` (LLVM 22)** across all four workloads (`2,946.3 FPS` vs `1,395.2` / `1,393.8 FPS` on `layout_bench`, `1,097.7 FPS` vs `569.8` / `569.1 FPS` on `text_bench`, `1,793.9 FPS` vs `955.8` / `955.6 FPS` on `render_bench`, and `722.6 FPS` vs `365.3` / `365.9 FPS` on `combined_frame`) while producing **2.97x smaller** `.wasm` binaries (`1,206.5 KB` vs `3,588.3 KB`).

### D.4 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)

| Compiler | Test Binaries Passed | Total Test `.wasm` Size (Raw / Zstd) | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |
| :--- | :---: | ---: | ---: | ---: |
| **`wazig v0.17.0-wazig.4` (`-fno-llvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | **7,814.4 KB** / **2,133.7 KB** | **0.969 s** | **1.20x faster** |
| **`wazigl v0.17.0-wazigl.4` (`-fllvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | 29,118.9 KB / 7,192.6 KB | **1.148 s** | 1.02x |
| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`/`+simd128`* (12 / 12 stripped) | 10,404.0 KB / 2,418.1 KB | 1.254 s | 0.93x |
| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics` + `+simd128`) | 29,079.3 KB / 7,162.3 KB | 1.167 s | 1.00x (baseline) |

> *\*Upstream `zig 0.17.0 -fno-llvm` emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, emits invalid `v128` Wasm instructions (`type mismatch: expected v128, found i32` in `scrollbar.render` & `mem.findScalarPos` failing Wasmtime validation) or `IllDefinedMemoryLayout` when `+simd128` is enabled (so non-SIMD `zig -fno-llvm` rows above are measured with `+simd128` and `+atomics` stripped), and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig v0.17.0-wazig.4` fixes all three bugs.*

---

## E. Guest Profiling Verification (`wasmtime-profile.py` @ `100us`)

### E.1 Verified Impact of `cataggar/zig#158`–`#188` & `cataggar/knots#11`–`#17` (`#9`)

Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **6.69x** from `21,457` (`v0.17.0-wazig.3`) → `6,984`/`6,513`/`6,287` (initial `wazig.4`) → **`3,209` (`ReleaseFast +simd128`)** in **`wazig v0.17.0-wazig.4`** (`cataggar/zig@1820f5885e`) + `cataggar/knots#11`, `#15` (`#13`), `#16` (`#12`, `#14`), `#17`, with all `cataggar/knots#9` and `#14` targets exceeded by **1.52x–7.42x**:

| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.4` (`ReleaseSmall`) | `wazig.4` (`ReleaseFast +simd128`) | `wazigl.4` (`ReleaseFast +simd128`) | `wazig.4` Speedup vs `wazig.3` | `knots#9` & `#14` Goal |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.154 ms (6,461.7 FPS) | **0.134 ms (7,415.9 FPS)** | **0.100 ms (9,925.0 FPS)** | **11.68x faster** | `>= 1,000 FPS` (`#9`) / `>= 4,805 FPS` (`#14`, Exceeded **1.54x**) |
| **`text_bench`** | 5.505 ms (181.7 FPS) | 0.663 ms (1,508.7 FPS) | **0.578 ms (1,734.8 FPS)** | **0.383 ms (2,591.5 FPS)** | **9.55x faster** | `>= 500 FPS` (Exceeded **3.47x**) |
| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.493 ms (2,034.6 FPS) | **0.362 ms (2,730.7 FPS)** | **0.162 ms (6,115.4 FPS)** | **3.50x faster** | `>= 1,800 FPS` (Exceeded **1.52x**) |
| **`combined_frame`** | 3.286 ms (304.2 FPS) | 1.121 ms (890.5 FPS) | **0.996 ms (1,003.1 FPS)** | **0.437 ms (2,272.7 FPS)** | **3.30x faster** | `>= 600 FPS` (Exceeded **1.67x**) |

- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`).
- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.
- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) & [`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` parameterized leaf inlining, single-caller `.small` inlining, and local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity`.
- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) & [`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — `@Vector` layout, `v128` `+simd128` SIMD arithmetic, and fused `cmp_vector` + `@reduce(.And/.Or)` lowering**: Lowered `Rect.eql` to `f32x4.eq` + `i32x4.all_true` (`12 B`).
- **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Wasm multivalue return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`, `HMetrics`, `[2]u8`, `u128`)**: Eliminated linear-memory `sret` stack frames for 2-scalar returns, allowing `curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`, and `fmt.digits2` to be completely inlined and removed in `ReleaseFast`.
- **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing**: Parallel 4-way cold-cache `wasm32-wasi` test suite compilation completes with zero `Archive.zig` race panics (`20.80s` wall / `62.99s` CPU; **`0.969s`** total test execution time across all 12 suites — the fastest of all 4 compilers).
- **[`cataggar/zig#174`](https://github.com/cataggar/zig/issues/174)–[`#188`](https://github.com/cataggar/zig/pull/188) — By-value scalar parameter ABI (`classifyAutoParam`), read-only by-ref load & alloc alias elision, `umulh` (`Wyhash.mum`) inline lowering, `tryElideMemcpyStackFrame` / `tryElideLeafStackFrame`, and single-call wrapper inlining**: Eliminated `memory.copy` aggregate parameter staging, inlined `Wyhash.round`/`mum`, and cut `wasm_bench_runner` binary sizes by another ~9% (`902.4 KB` `ReleaseSmall`, `1,077.9 KB` `ReleaseFast +simd128`).
- **[`cataggar/knots#11`](https://github.com/cataggar/knots/pull/11) (`#10`), [`cataggar/knots#15`](https://github.com/cataggar/knots/pull/15) (`#13`), [`cataggar/knots#16`](https://github.com/cataggar/knots/pull/16) (`#12`, `#14`), & [`cataggar/knots#17`](https://github.com/cataggar/knots/pull/17) (`#14`) — Precomputed curve extents & insertion/merge sort (`#11`), direct `O(curves + overlaps)` band-range indexing, pre-sorted curve scatter & single contiguous backing allocation (`#15`), 2-pass child layout, leaf fast paths, in-place element init, lazy `id_to_slot` & compact `buildZOrder` (`#16`), and `inline` `Rect`/`Padding`/`AxisInfo` scalar accessors + capacity fast paths (`#17`)**: Boosted `wazig.4` `layout_bench` by **6.45x** over initial `wazig.4` (`1,150.0` → **`7,415.9–7,484.7 FPS` / `0.133–0.134 ms`**, **11.68x** over `wazig.3`), `text_bench` by **1.51x** (`1,152.7` → **`1,734.8–1,736.1 FPS` / `0.577–0.578 ms`**), `render_bench` to **`2,730.7 FPS` (`0.362 ms`)**, and `combined_frame` by **1.45x** (`690.8` → **`1,003.1 FPS` / `0.996 ms`**).

### E.2 Top 15 Functions in `wazig v0.17.0-wazig.4` `ReleaseFast +simd128` (`3,209` total samples @ 100us)

| Self | Self% | Total | Tot% | Bytes | Function |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 276 | 8.60% | 872 | 27.17% | 3,905 | `wasm_bench_runner.buildRenderFrame` |
| 156 | 4.86% | 156 | 4.86% | 2,471 | `hash.wyhash.Wyhash.update` |
| 154 | 4.80% | 154 | 4.80% | 1,067 | `band.sortBandIndices` |
| 148 | 4.61% | 148 | 4.61% | 2,248 | `DrawList.commandBounds` |
| 114 | 3.55% | 114 | 3.55% | 1,164 | `band.computeAxisBandRanges` |
| 107 | 3.33% | 130 | 4.05% | 647 | `DrawList.pushTextInstance` |
| 100 | 3.12% | 117 | 3.65% | 864 | `DrawList.pushInstances` |
| 92 | 2.87% | 161 | 5.02% | 2,712 | `Context.positionChildren` |
| 90 | 2.80% | 313 | 9.75% | 4,792 | `DrawList.emitBatched` |
| 80 | 2.49% | 234 | 7.29% | 454 | `band.scatterAxisBands` |
| 74 | 2.31% | 311 | 9.69% | 4,009 | `Context.computeLayoutNode` |
| 69 | 2.15% | 118 | 3.68% | 6,003 | `TrueType.glyphShapeTT` |
| 62 | 1.93% | 236 | 7.35% | 1,416 | `wasm_bench_runner.buildDashboardLayoutFrame` |
| 61 | 1.90% | 112 | 3.49% | 1,546 | `Context.open` |
| 60 | 1.87% | 69 | 2.15% | 67 | `Clip.State.scissorEql` |

### E.3 Follow-Up `cataggar/zig` Self-Hosted Wasm Backend Optimization Issues Filed

- **[`cataggar/zig#189`](https://github.com/cataggar/zig/issues/189)**: `wasm: Optimizer.zig classifyTrivialFunc sets depth0_stack_exact = false on all 0xfd SIMD instructions` (blocks inlining trivial SIMD leaf helpers such as `Rect.eql` / `Clip.State.scissorEql`).
- **[`cataggar/zig#190`](https://github.com/cataggar/zig/issues/190)**: `wasm: CodeGen.zig SroaAnalysis and ReadOnlyAllocAliasAnalysis reject vector_index != .none, spilling v128/@Vector lane accesses to shadow stack`.
- **[`cataggar/zig#191`](https://github.com/cataggar/zig/issues/191)**: `wasm: CodeGen.zig SroaAnalysis over-promotes large (>16B) copy-modify-pass aggregates into scalar locals that immediately spill back to shadow stack` (`SlugInstance` in `DrawList.pushTextInstance` and `Instance` in `DrawList.pushInstances`).
- **[`cataggar/zig#192`](https://github.com/cataggar/zig/issues/192)**: `wasm: Optimizer.zig post-inlining shadow-stack slot scalarization (SROA) for small aggregates whose address only escaped to inlined leaf methods` (`var box: Box` in `DrawList.commandBounds` and `DrawList.emitBatched`).

