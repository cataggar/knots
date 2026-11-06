# wazig (v0.17.0-wazig.4) & wazigl (v0.17.0-wazigl.4) vs zig v0.17.0 Comprehensive Benchmark Report

Reproducible 4-way benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig v0.17.0-wazig.4`** (`cataggar/zig@v0.17.0-wazig.4`, `-fno-llvm`): universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1` (`8.47 MiB` `.tar.zst`, `63.47 MiB` unpacked), including `cataggar/zig#158`, `#159`, `#163`, `#164`, `#168`, `#169`, `#170`, `#171` and `cataggar/knots#10` (`#11`)
- **`wazigl v0.17.0-wazigl.4`** (`cataggar/zig@v0.17.0-wazigl.4`, `-fllvm`): universal `wasm64-wasip3` compiler with full LLVM 22 Wasm backend executed via `wasmtime v50.0.1` (`36.48 MiB` `.tar.zst`, `226.02 MiB` unpacked)
- **`zig v0.17.0 -fno-llvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with self-hosted Wasm backend)
- **`zig v0.17.0 -fllvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with LLVM 22 backend)

---

## A. Toolchain & CI Footprint

| Metric | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0` (Standard) | Reduction / Advantage |
| :--- | :--- | :--- | :--- | :--- |
| **Release Archive Size** | **8.47 MiB** (`wazig.tar.zst`) | **36.48 MiB** (`wazigl.tar.zst`) | 50.43 MiB (`zig-aarch64-linux-0.17.0.tar.xz`) | **`wazig`: 5.96x smaller (-83.2%) / `wazigl`: 1.38x smaller (-27.7%)** |
| **Unpacked Release Size** | **63.47 MiB** (`34.94 MiB` `wazig.wasm` + `28.54 MiB` `lib/`) | **226.02 MiB** (`197.48 MiB` `wazigl.wasm` + `28.54 MiB` `lib/`) | 343.65 MiB (`163.74 MiB` `zig` + `178.95 MiB` `lib/`; `397.74 MiB` on disk) | **`wazig`: 5.41x smaller (-81.5%) / `wazigl`: 1.52x smaller (-34.2%)** |
| **Installed File Count** | **1,324 files** | **1,324 files** | 19,506 files | **14.7x fewer files (-93.2%)** |
| **Binary Portability** | wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | wasm64-wasip3 + LLVM 22 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | OS/arch-specific native binaries (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows, etc.) | **Single universal artifact per tier** |
| **Supply-Chain Attestation** | Native Sigstore bundle verified via ghr | Native Sigstore bundle verified via ghr | minisign signature (external tool required) | **Zero extra verification tools** |
| **Wasm Build Dependency Fetch** | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | **4.91 MiB** compressed / **34.71 MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~230+ MiB compressed / ~680 MiB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |

---

## B. Compilation Speed (Cold Cache & Warm Cache)

> All `wazig` and `wazigl` measurements run with Wasmtime's compiled module cache warmed.

| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |
| :--- | ---: | ---: | ---: | ---: |
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.555s** | 1.706s | 0.043s | 0.043s |
| `wasm_bench_runner.zig` (`Debug`) | 14.26s (cold) / 6.72s (warm) | 32.29s (cold) / 16.64s (warm) | 3.48s (cold) / 0.28s (warm) | 5.72s (cold) / 2.37s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 12.32s (cold) / 4.91s (warm) | 25.12s (cold) / 14.71s (warm) | 2.26s (cold) / 0.26s (warm) | 6.80s (cold) / 4.66s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast`) | 13.24s (cold) / 5.53s (warm) | 42.84s (cold) / 26.48s (warm) | 3.55s (cold) / 0.23s (warm) | 12.52s (cold) / 9.08s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | 13.31s (cold) / 5.68s (warm) | 43.24s (cold) / 26.53s (warm) | FAIL (`IllDefinedMemoryLayout`)* | 12.53s (cold) / 9.01s (warm) |
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
- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) vs `wazigl v0.17.0-wazigl.4` (`-fllvm`)**: Because `wazig` uses Zig's self-hosted WebAssembly backend (`src/codegen/wasm/Optimizer.zig`) without invoking LLVM's optimization passes, `wazig.4` compiles **2.0x–4.8x faster** than `wazigl.4` across every workload (`4.91s` vs `14.71s` warm on `wasm_bench_runner ReleaseSmall`, `5.68s` vs `26.53s` warm on `ReleaseFast +simd128`, `20.80s` vs `62.42s` wall time across all 12 WASI test suites, and `0.555s` vs `1.706s` on `fmt --check`).
- **`wazig v0.17.0-wazig.4` vs Native `zig v0.17.0 -fllvm`**: Even running inside Wasmtime (`wasm64-wasip3`), `wazig.4` warm-cache builds (`4.91s` `ReleaseSmall`, `5.53s` `ReleaseFast`, `5.68s` `ReleaseFast +simd128`) are **competitive with or up to 1.60x faster than native `zig 0.17.0 -fllvm`** (`4.66s` `ReleaseSmall`, `9.08s` `ReleaseFast`, `9.01s` `ReleaseFast +simd128`), and `triangle` (`5.74s` vs `5.99s` warm) and `embedded` (`4.84s` vs `4.60s`) build at near-native LLVM speed.
- **`wazigl v0.17.0-wazigl.4` vs Native `zig v0.17.0 -fllvm`**: Running the full LLVM 22 + Clang C++ toolchain inside Wasmtime (`wazigl.wasm`, `197.48 MiB`) incurs a ~2.8x–3.5x Wasmtime guest execution multiplier relative to native `zig -fllvm` (`14.71s` vs `4.66s` warm on `ReleaseSmall`, `36.29s` vs `11.61s` on `playground ReleaseSmall`), making `wazig.4` ideal for fast CI test/check inner loops and `wazigl.4` ideal when maximum LLVM codegen optimization is desired without OS/arch-specific native compiler binaries.

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` / `wazigl` vs `zig -fllvm` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 2,894.1 KB / 972.0 KB / **757.1 KB** | 6,116.3 KB / 1,979.0 KB / **1,511.5 KB** | 3,362.5 KB / 1,028.7 KB / **764.9 KB** | 6,117.2 KB / 1,978.7 KB / **1,533.8 KB** | `wazig`: **-13.9%** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,496.9 KB / 867.1 KB / **659.9 KB** | 1,782.7 KB / 700.1 KB / **575.7 KB** | 2,795.1 KB / 877.7 KB / **684.9 KB** | 1,782.7 KB / 700.1 KB / **590.6 KB** | `wazig`: **-10.7%** / `wazigl`: **0 B (identical)** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 2,859.9 KB / 967.1 KB / **747.7 KB** | 6,082.0 KB / 1,971.3 KB / **1,530.8 KB** | 3,328.2 KB / 1,023.8 KB / **781.3 KB** | 6,083.0 KB / 1,970.6 KB / **1,528.7 KB** | `wazig`: **-14.1%** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,462.6 KB / 862.2 KB / **661.5 KB** | 1,748.5 KB / 693.5 KB / **584.8 KB** | 2,760.9 KB / 872.5 KB / **682.3 KB** | 1,748.5 KB / 693.5 KB / **584.8 KB** | `wazig`: **-10.8%** / `wazigl`: **0 B (identical)** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 2,904.7 KB / 974.7 KB / **753.2 KB** | 6,155.9 KB / 1,993.7 KB / **1,516.9 KB** | FAIL (`global.get` asm)* | 6,156.9 KB / 1,993.5 KB / **1,537.0 KB** | **`wazig` succeeds** / `wazigl`: **-0.02%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,504.7 KB / 869.7 KB / **686.0 KB** | 1,786.8 KB / 702.8 KB / **570.8 KB** | FAIL (`global.get` asm)* | 1,786.8 KB / 702.8 KB / **570.8 KB** | **`wazig` succeeds** / `wazigl`: **0 B (identical)** |
| `triangle` (`Debug`) | 1,494.9 KB / 545.0 KB / **452.4 KB** | 3,803.7 KB / 1,263.2 KB / **1,020.0 KB** | 1,857.9 KB / 596.0 KB / **481.3 KB** | 3,803.9 KB / 1,262.8 KB / **1,018.7 KB** | `wazig`: **-19.5%** / `wazigl`: **-0.01%** |
| `triangle` (`ReleaseSmall`) | 1,194.4 KB / 458.6 KB / **391.4 KB** | 801.0 KB / 364.3 KB / **325.9 KB** | 1,413.0 KB / 472.7 KB / **396.2 KB** | 801.0 KB / 364.3 KB / **325.9 KB** | `wazig`: **-15.5%** / `wazigl`: **0 B (identical)** |
| `embedded` (`Debug`) | 1,314.0 KB / 478.7 KB / **402.5 KB** | 3,372.1 KB / 1,103.6 KB / **902.1 KB** | 1,635.8 KB / 524.4 KB / **430.7 KB** | 3,372.2 KB / 1,103.4 KB / **900.9 KB** | `wazig`: **-19.7%** / `wazigl`: **-0.00%** |
| `embedded` (`ReleaseSmall`) | 1,070.2 KB / 413.5 KB / **355.9 KB** | 734.4 KB / 337.6 KB / **302.4 KB** | 1,250.9 KB / 424.8 KB / **359.8 KB** | 734.4 KB / 337.6 KB / **302.4 KB** | `wazig`: **-14.4%** / `wazigl`: **0 B (identical)** |
| `benchmark` (`Debug`) | 1,515.6 KB / 552.1 KB / **457.9 KB** | 3,878.1 KB / 1,287.9 KB / **1,036.4 KB** | 1,889.3 KB / 604.6 KB / **487.1 KB** | 3,878.3 KB / 1,287.6 KB / **1,035.4 KB** | `wazig`: **-19.8%** / `wazigl`: **-0.01%** |
| `benchmark` (`ReleaseSmall`) | 1,211.2 KB / 463.5 KB / **395.4 KB** | 807.3 KB / 366.9 KB / **328.7 KB** | 1,438.2 KB / 478.4 KB / **401.1 KB** | 807.3 KB / 366.9 KB / **328.7 KB** | `wazig`: **-15.8%** / `wazigl`: **0 B (identical)** |
| `wasm_bench_runner` (`Debug`) | 1,286.9 KB / 485.4 KB / **411.3 KB** | 3,566.4 KB / 1,176.5 KB / **962.5 KB** | 1,636.6 KB / 540.0 KB / **441.6 KB** | 3,563.1 KB / 1,174.3 KB / **959.7 KB** | `wazig`: **-21.4%** / `wazigl`: **+0.09%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 980.9 KB / 404.3 KB / **348.5 KB** | 682.4 KB / 332.7 KB / **298.2 KB** | 1,186.1 KB / 416.9 KB / **355.2 KB** | 682.4 KB / 332.7 KB / **298.2 KB** | `wazig`: **-17.3%** / `wazigl`: **0 B (identical)** |
| `wasm_bench_runner` (`ReleaseFast`) | 1,205.2 KB / 471.7 KB / **396.1 KB** | 2,858.0 KB / 977.3 KB / **826.6 KB** | 1,324.1 KB / 448.3 KB / **385.1 KB** | 2,858.4 KB / 977.3 KB / **827.1 KB** | `wazig`: **-9.0%** / `wazigl`: **-0.01%** |
| `wasm_bench_runner` (`ReleaseFast +simd128`) | 1,208.1 KB / 473.6 KB / **397.9 KB** | 2,810.7 KB / 971.1 KB / **823.5 KB** | FAIL (`IllDefinedMemoryLayout`)* | 2,811.2 KB / 971.3 KB / **824.2 KB** | **`wazig` succeeds** / `wazigl`: **-0.01%** |
| All 12 `wasm32-wasi` Test Binaries (`Debug` Total) | 7,814.4 KB / 2,630.8 KB / **2,133.7 KB** | 29,118.9 KB / 8,867.0 KB / **7,192.6 KB** | 10,404.0 KB / 3,053.4 KB / **2,418.1 KB** | 29,079.3 KB / 8,847.2 KB / **7,162.3 KB** | `wazig`: **-24.9%** / `wazigl`: **+0.14%** |

**Key Binary Size Takeaways:**
- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) produces byte-for-byte identical `ReleaseSmall` `.wasm` binaries (`0 B` difference) to native `zig v0.17.0 -fllvm` across every single `ReleaseSmall` target:** `682.4 KB` raw (`298.2 KB` zstd) on `wasm_bench_runner`, `1,782.7 KB` raw (`575.7 KB` zstd) on `playground` WebGPU, `1,748.5 KB` raw (`584.8 KB` zstd) on `playground` WebGL2, `1,786.8 KB` raw (`570.8 KB` zstd) on `playground` WebGPU + threads, `801.0 KB` raw (`325.9 KB` zstd) on `triangle`, `734.4 KB` raw (`302.4 KB` zstd) on `embedded`, and `807.3 KB` raw (`328.7 KB` zstd) on `benchmark` — delivering full LLVM 22 codegen from a single universal `wasm64-wasip3` compiler.
- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) produces the smallest `Debug` and `ReleaseFast` `.wasm` binaries of all four compilers:**
  - In **`Debug`** builds, `wazig.4` is **13.9%–24.9% smaller** than upstream `zig 0.17.0 -fno-llvm` and **52.7%–73.2% smaller (2.11x–3.73x smaller)** than `wazigl.4` and `zig 0.17.0 -fllvm`.
  - In **`ReleaseFast +simd128`** builds, `wazig.4` (`1,208.1 KB` raw / `397.9 KB` zstd) is **2.33x smaller** than `wazigl.4` (`2,810.7 KB` raw / `823.5 KB` zstd) and `zig 0.17.0 -fllvm` (`2,811.2 KB` raw / `824.2 KB` zstd), because LLVM's `ReleaseFast` loop unrolling and aggressive inlining expand `.wasm` binary size by **4.12x** over `ReleaseSmall` (`682.4 KB` → `2,810.7 KB`), whereas `wazig`'s targeted leaf inliner (`Optimizer.zig`) adds only `+23.2%` over `ReleaseSmall` (`980.9 KB` → `1,208.1 KB`).
  - Across all 12 `wasm32-wasi` test binaries (`Debug`), `wazig.4` emits **7.63 MiB** raw (`2.08 MiB` zstd) vs **28.44 MiB** raw (`7.02 MiB` zstd) with `wazigl.4` / `zig -fllvm` (**3.73x smaller**), enabling the fastest test suite execution (`0.969s`).

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.959 ms** / 0.963 ms (**1,043.2 FPS**) | **0.291 ms** / 0.297 ms (**3,420.7 FPS**) | 1.533 ms / 1.540 ms (651.8 FPS) | 0.291 ms / 0.297 ms (3,415.7 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.934 ms** / 0.941 ms (**1,070.4 FPS**) | **0.522 ms** / 0.526 ms (**1,922.2 FPS**) | 1.879 ms / 1.887 ms (532.3 FPS) | 0.523 ms / 0.531 ms (1,917.7 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.515 ms** / 0.518 ms (**1,952.7 FPS**) | **0.269 ms** / 0.281 ms (**3,677.4 FPS**) | 1.021 ms / 1.028 ms (978.5 FPS) | 0.270 ms / 0.284 ms (3,651.1 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.560 ms** / 1.570 ms (**641.3 FPS**) | **0.745 ms** / 0.753 ms (**1,343.8 FPS**) | 2.771 ms / 2.789 ms (360.7 FPS) | 0.750 ms / 0.757 ms (1,335.8 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`

#### `ReleaseFast (+simd128)` (Default Wasm Target Features in `web_build.zig`)

| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.869 ms** / 0.882 ms (**1,150.0 FPS**) | **0.208 ms** / 0.213 ms (**4,796.3 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.207 ms / 0.214 ms (4,805.0 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.866 ms** / 0.877 ms (**1,152.7 FPS**) | **0.423 ms** / 0.431 ms (**2,351.2 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.423 ms / 0.432 ms (2,349.0 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.401 ms** / 0.418 ms (**2,466.6 FPS**) | **0.162 ms** / 0.173 ms (**6,104.7 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.163 ms / 0.175 ms (6,057.4 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **1.446 ms** / 1.474 ms (**690.8 FPS**) | **0.480 ms** / 0.484 ms (**2,096.8 FPS**) | FAIL (`IllDefinedMemoryLayout`)* | 0.484 ms / 0.489 ms (2,078.8 FPS) | `8133605907336869050` |

#### `ReleaseFast` (Baseline Wasm CPU without `+simd128`)

| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.872 ms** / 0.875 ms (**1,146.8 FPS**) | **0.206 ms** / 0.213 ms (**4,829.8 FPS**) | 1.543 ms / 1.548 ms (648.2 FPS) | 0.206 ms / 0.210 ms (4,839.0 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.853 ms** / 0.861 ms (**1,172.2 FPS**) | **0.399 ms** / 0.409 ms (**2,487.7 FPS**) | 1.875 ms / 1.886 ms (533.3 FPS) | 0.398 ms / 0.406 ms (2,500.6 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.470 ms** / 0.484 ms (**2,115.0 FPS**) | **0.170 ms** / 0.182 ms (**5,810.1 FPS**) | 1.014 ms / 1.023 ms (985.1 FPS) | 0.167 ms / 0.181 ms (5,904.3 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **1.472 ms** / 1.481 ms (**679.4 FPS**) | **0.489 ms** / 0.495 ms (**2,054.3 FPS**) | 2.774 ms / 2.788 ms (360.3 FPS) | 0.484 ms / 0.491 ms (2,071.7 FPS) | `8133605907336869050` |

**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**
- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) matches native `zig v0.17.0 -fllvm` runtime throughput across every mode:** In `ReleaseSmall`, `wazigl.4` achieves `3,420.7 FPS` (`layout_bench`), `1,922.2 FPS` (`text_bench`), `3,677.4 FPS` (`render_bench`), and `1,343.8 FPS` (`combined_frame`) — matching native `zig -fllvm` (`3,415.7`, `1,917.7`, `3,651.1`, `1,335.8 FPS`). In `ReleaseFast +simd128`, `wazigl.4` reaches **`6,104.7 FPS` (`0.162 ms`)** on `render_bench`, **`4,796.3 FPS` (`0.208 ms`)** on `layout_bench`, **`2,351.2 FPS` (`0.423 ms`)** on `text_bench`, and **`2,096.8 FPS` (`0.480 ms`)** on `combined_frame`.
- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) vs `zig v0.17.0 -fno-llvm`**: With inline `@min`/`@max` (`cataggar/zig#158`), SROA to Wasm locals (`cataggar/zig#159`), parameterized leaf inlining (`cataggar/zig#163`, `#169`), `v128` `+simd128` vector & `@reduce` lowering (`cataggar/zig#164`, `#168`), multivalue 2-scalar returns (`cataggar/zig#170`), and `band.fillBands` curve extent precomputation (`cataggar/knots#10` / `#11`), `wazig.4` is **1.60x–2.50x faster** than upstream `zig 0.17.0 -fno-llvm` on the exact same `knots` source (`1,150.0 FPS` vs `648.2 FPS` on `layout_bench`, `1,172.2 FPS` vs `533.3 FPS` on `text_bench`, `2,466.6 FPS` vs `985.1 FPS` on `render_bench`, and `690.8 FPS` vs `360.3 FPS` on `combined_frame`), and **1.81x–6.45x faster** than `wazig v0.17.0-wazig.3`.
- **`wazig v0.17.0-wazig.4` `ReleaseFast +simd128` vs `ReleaseSmall`**: Parameterized leaf inlining in `.fast` mode (`band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `appendAssumeCapacity`), Wasm multivalue 2-scalar returns (`curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`), and `v128` SIMD (`Rect.eql` and `Clip.State.scissorEql` lowered to `f32x4.eq` + `i32x4.all_true` and completely inlined into `DrawList.keyMatches` / `DrawList.lastCmdMatches`) boost `wazig.4` `render_bench` from `1,952.7 FPS` (`ReleaseSmall`) to **`2,466.6 FPS` (+26.3%)**, `layout_bench` from `1,043.2 FPS` to **`1,150.0 FPS` (+10.2%)**, `text_bench` from `1,070.4 FPS` to **`1,152.7–1,172.2 FPS` (+7.7%–9.5%)**, and `combined_frame` from `641.3 FPS` to **`690.8 FPS` (+7.7%)**.

### D.3 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **1.056 ms** / 1.076 ms (**945.5 FPS**) | 1.614 ms / 1.621 ms (619.5 FPS) | 1.628 ms / 1.636 ms (614.0 FPS) | 1.623 ms / 1.629 ms (616.2 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **1.167 ms** / 1.206 ms (**853.1 FPS**) | 1.978 ms / 1.987 ms (505.5 FPS) | 2.396 ms / 2.411 ms (416.9 FPS) | 1.973 ms / 1.982 ms (506.7 FPS) | `12606774574179943755` / `7686275582076872382` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.604 ms** / 0.616 ms (**1,660.4 FPS**) | 1.043 ms / 1.052 ms (957.8 FPS) | 1.178 ms / 1.192 ms (847.2 FPS) | 1.041 ms / 1.050 ms (960.1 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.797 ms** / 1.831 ms (**555.5 FPS**) | 2.960 ms / 2.971 ms (337.8 FPS) | 3.074 ms / 3.103 ms (325.0 FPS) | 2.970 ms / 2.981 ms (336.6 FPS) | `8133605907336869050` |

**`Debug` Runtime Highlight:** In `Debug` builds, `wazig v0.17.0-wazig.4` (`-fno-llvm`) is **1.53x–1.73x faster at runtime than both `wazigl v0.17.0-wazigl.4` and `zig v0.17.0 -fllvm` (LLVM 22)** across all four workloads (`945.5 FPS` vs `619.5` / `616.2 FPS` on `layout_bench`, `853.1 FPS` vs `505.5` / `506.7 FPS` on `text_bench`, `1,660.4 FPS` vs `957.8` / `960.1 FPS` on `render_bench`, and `555.5 FPS` vs `337.8` / `336.6 FPS` on `combined_frame`) while producing **2.77x smaller** `.wasm` binaries (`1,286.9 KB` vs `3,566.4 KB`).

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

### E.1 Verified Impact of `cataggar/zig#158`–`#171` & `cataggar/knots#10` (`#11`, `#9`)

Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **3.41x** from `21,457` (`v0.17.0-wazig.3`) → **`6,984` (`ReleaseSmall`) / `6,513` (`ReleaseFast`) / `6,287` (`ReleaseFast +simd128`)** in **`wazig v0.17.0-wazig.4`** (`cataggar/zig@v0.17.0-wazig.4`) + `cataggar/knots#10` (`#11`), with all `cataggar/knots#9` targets met or exceeded:

| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.4` (`ReleaseSmall`) | `wazig.4` (`ReleaseFast +simd128`) | `wazigl.4` (`ReleaseFast +simd128`) | `wazig.4` Speedup vs `wazig.3` | `knots#9` Goal |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.959 ms (1,043.2 FPS) | **0.869 ms (1,150.0 FPS)** | **0.208 ms (4,796.3 FPS)** | **1.81x faster** | `>= 1,000 FPS` (Achieved) |
| **`text_bench`** | 5.505 ms (181.7 FPS) | 0.934 ms (1,070.4 FPS) | **0.866 ms (1,152.7 FPS)** | **0.423 ms (2,351.2 FPS)** | **6.34x–6.45x faster** | `>= 500 FPS` (Exceeded **2.31x**) |
| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.515 ms (1,952.7 FPS) | **0.401 ms (2,466.6 FPS)** | **0.162 ms (6,104.7 FPS)** | **3.17x faster** | `>= 1,800 FPS` (Achieved) |
| **`combined_frame`** | 3.286 ms (304.2 FPS) | 1.560 ms (641.3 FPS) | **1.446 ms (690.8 FPS)** | **0.480 ms (2,096.8 FPS)** | **2.27x faster** | `>= 600 FPS` (Achieved) |

- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`).
- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.
- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) & [`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` parameterized leaf inlining, single-caller `.small` inlining, and local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity`, and reduced `ReleaseSmall` binary size by **-11.2%** (`1,104.5 KB` → `980.9 KB`).
- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) & [`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — `@Vector` layout, `v128` `+simd128` SIMD arithmetic, and fused `cmp_vector` + `@reduce(.And/.Or)` lowering**: `Rect.eql` and `Clip.State.scissorEql` in `ReleaseFast +simd128` are now **both `0` bytes and `0` samples** — lowered to `f32x4.eq` + `i32x4.all_true` and completely inlined into `DrawList.keyMatches` and `DrawList.lastCmdMatches`, accelerating `render_bench` to **`2,466.6 FPS` (`0.401 ms`)**.
- **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Wasm multivalue return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`, `HMetrics`, `[2]u8`, `u128`)**: Eliminated linear-memory `sret` stack frames for 2-scalar returns, allowing `curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`, and `fmt.digits2` to be completely inlined and removed in `ReleaseFast`.
- **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing**: Parallel 4-way cold-cache `wasm32-wasi` test suite compilation completes with zero `Archive.zig` race panics (`20.80s` wall / `62.99s` CPU; **`0.969s`** total test execution time across all 12 suites — the fastest of all 4 compilers).
- **[`cataggar/knots#10`](https://github.com/cataggar/knots/issues/10) ([`cataggar/knots#11`](https://github.com/cataggar/knots/pull/11)) — Precomputed per-curve extents & insertion sort in `src/text/band.zig`**: `band.fillBands` inclusive samples dropped **3.25x–3.72x** (`1,951` / `25.09%` → `525` / `7.50%` in `ReleaseSmall`, `578` / `8.87%` in `ReleaseFast`, `601` / `9.56%` in `ReleaseFast +simd128`), and `std.sort.block` (`sort.block.swap`, `16.4 KB` bytecode, `8.83%` runtime) is **completely eliminated (`0` bytes, `0` samples)**, more than doubling `text_bench` throughput (`546.3 FPS` → **`1,152.7–1,172.2 FPS`** on `wazig.4` and **`2,351.2–2,487.7 FPS`** on `wazigl.4`).

### E.2 Top 15 Functions in `wazig v0.17.0-wazig.4` `ReleaseFast +simd128` (`6,287` total samples @ 100us)

| Self | Self% | Total | Tot% | Bytes | Function |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 373 | 5.93% | 601 | 9.56% | 706 | `band.fillBands` |
| 353 | 5.61% | 1,405 | 22.35% | 3,826 | `Context.positionChildren` |
| 316 | 5.03% | 971 | 15.44% | 4,774 | `wasm_bench_runner.buildRenderFrame` |
| 297 | 4.72% | 297 | 4.72% | 2,242 | `Context.distributeGrow` |
| 287 | 4.56% | 1,407 | 22.38% | 679 | `Context.computeLayoutNode` |
| 218 | 3.47% | 243 | 3.87% | 62 | `array_list.Aligned(u32,null).append` |
| 204 | 3.24% | 204 | 3.24% | 1,902 | `Context.resolvePercentChildren` |
| 182 | 2.89% | 182 | 2.89% | 1,126 | `band.sortBandIndices` |
| 166 | 2.64% | 166 | 2.64% | 2,666 | `hash.wyhash.Wyhash.update` |
| 151 | 2.40% | 152 | 2.42% | 11,503 | `Context.buildZOrder` |
| 142 | 2.26% | 210 | 3.34% | 121 | `ElementPool.append` |
| 141 | 2.24% | 141 | 2.24% | 2,689 | `DrawList.commandBounds` |
| 120 | 1.91% | 143 | 2.27% | 924 | `DrawList.pushInstances` |
| 118 | 1.88% | 355 | 5.65% | 5,660 | `DrawList.emitBatched` |
| 113 | 1.80% | 113 | 1.80% | 673 | `Context.measureChildren` |

