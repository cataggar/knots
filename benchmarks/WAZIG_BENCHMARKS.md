# `wazig v0.17.0-wazig.3` vs `zig v0.17.0` Comprehensive Benchmark Report

Reproducible benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig v0.17.0-wazig.3`** (`cataggar/zig@v0.17.0-wazig.3`, universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1`)
- **`zig v0.17.0 -fno-llvm`** (`0.17.0-dev.27+0dd99239c`, native `x86_64-linux` binary with self-hosted Wasm backend)
- **`zig v0.17.0 -fllvm`** (`0.17.0-dev.27+0dd99239c`, native `x86_64-linux` binary with LLVM 22 backend)

---

## A. Toolchain & CI Footprint

| Metric | `wazig v0.17.0-wazig.3` | `zig v0.17.0` (Standard) | Reduction / Advantage |
| :--- | :--- | :--- | :--- |
| **Release Archive Size** | **8.45 MB** (`wazig.tar.zst`) | 51.20 MB (`tar.xz`) | **6.06x smaller download (-83.5%)** |
| **Unpacked Release Size** | **40.4 MB** (`21.1 MB` `wazig.wasm` + `19.3 MB` Wasm `lib/`) | 265.0 MB (`360.3 MB` in `ghr` store) | **6.56x–8.92x smaller on disk (-84.8%)** |
| **Installed File Count** | **1,324 files** | 19,505 files | **14.7x fewer files** |
| **Binary Portability** | wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | OS/arch-specific native binaries (x86_64-linux, aarch64-macos, x86_64-windows, etc.) | **Single universal artifact** |
| **Supply-Chain Attestation** | Native Sigstore bundle verified via ghr | minisign signature (external tool required) | **Zero extra verification tools** |
| **Wasm Build Dependency Fetch** | **4.91 MB** compressed / **34.7 MB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~230+ MB compressed / ~680 MB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |

---

## B. Compilation Speed (Cold Cache & Warm Cache)

> All `wazig` measurements run with Wasmtime's compiled module cache warmed (`wazig version` startup `0.31s`).

| Workload | `wazig v0.17.0-wazig.3` (`-fno-llvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |
| :--- | ---: | ---: | ---: |
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.913s** | 0.044s | 0.044s |
| `wasm_bench_runner.zig` (`Debug`) | 25.10s (cold) / 10.27s (warm) | 3.81s (cold) / 0.29s (warm) | 6.33s (cold) / 2.73s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 11.80s (cold) / 7.84s (warm) | 2.19s (cold) / 0.25s (warm) | 7.44s (cold) / 5.33s (warm) |
| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | 34.16s wall (140.0s CPU) | 9.78s wall (43.5s CPU) | 14.73s wall (63.9s CPU) |
| `examples/triangle` (`Debug`) | 15.97s (cold) / 11.49s (warm) | 2.96s (cold) / 0.31s (warm) | 5.73s (cold) / 3.12s (warm) |
| `examples/triangle` (`ReleaseSmall`) | 12.96s (cold) / 9.07s (warm) | 2.23s (cold) / 0.27s (warm) | 8.56s (cold) / 6.43s (warm) |
| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | 29.85s | 1.29s | 5.94s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 27.16s | 1.24s | 13.81s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | 30.00s | 1.26s | 5.80s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 27.28s | 1.27s | 13.45s |
| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **34.55s** | FAIL (`global.get` asm) | 8.74s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **31.28s** | FAIL (`global.get` asm) | 16.35s |
| `examples/embedded` (`Debug`) | 10.01s | 0.48s | 2.85s |
| `examples/embedded` (`ReleaseSmall`) | 7.78s | 0.39s | 5.94s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | 13.80s | 0.49s | 3.36s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | 11.35s | 0.41s | 7.29s |

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig v0.17.0-wazig.3` | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` (Raw) |
| :--- | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 3,158.1 KB / 999.2 KB / **748.1 KB** | 3,403.3 KB / 1,038.7 KB / **787.9 KB** | 6,161.3 KB / 1,996.2 KB / **1,503.3 KB** | **-7.2%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,661.4 KB / 866.0 KB / **681.0 KB** | 2,817.7 KB / 884.6 KB / **691.0 KB** | 1,805.0 KB / 708.7 KB / **579.2 KB** | **-5.5%** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 3,123.9 KB / 994.2 KB / **769.0 KB** | 3,369.1 KB / 1,033.5 KB / **790.4 KB** | 6,127.1 KB / 1,991.4 KB / **1,508.9 KB** | **-7.3%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,627.2 KB / 861.2 KB / **677.5 KB** | 2,783.4 KB / 879.0 KB / **687.8 KB** | 1,770.9 KB / 702.3 KB / **589.7 KB** | **-5.6%** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 3,170.8 KB / 1,003.4 KB / **774.3 KB** | FAIL (`global.get` asm) | 6,201.0 KB / 2,010.6 KB / **1,543.6 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,670.9 KB / 868.6 KB / **691.0 KB** | FAIL (`global.get` asm) | 1,809.2 KB / 710.6 KB / **599.2 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| `triangle` (`Debug`) | 1,700.8 KB / 574.6 KB / **469.6 KB** | 1,902.0 KB / 606.4 KB / **490.1 KB** | 3,860.4 KB / 1,288.5 KB / **1,037.4 KB** | **-10.6%** |
| `triangle` (`ReleaseSmall`) | 1,321.3 KB / 465.6 KB / **395.4 KB** | 1,437.4 KB / 479.3 KB / **401.4 KB** | 813.8 KB / 369.4 KB / **330.3 KB** | **-8.1%** |
| `embedded` (`Debug`) | 1,492.1 KB / 504.2 KB / **417.0 KB** | 1,679.8 KB / 536.6 KB / **439.1 KB** | 3,428.7 KB / 1,127.5 KB / **918.8 KB** | **-11.2%** |
| `embedded` (`ReleaseSmall`) | 1,176.9 KB / 420.3 KB / **360.4 KB** | 1,275.2 KB / 431.6 KB / **365.3 KB** | 746.3 KB / 342.0 KB / **306.3 KB** | **-7.7%** |
| `benchmark` (`Debug`) | 1,725.7 KB / 583.7 KB / **474.8 KB** | 1,933.3 KB / 618.4 KB / **496.8 KB** | 3,934.9 KB / 1,308.7 KB / **1,053.7 KB** | **-10.7%** |
| `benchmark` (`ReleaseSmall`) | 1,340.9 KB / 470.5 KB / **398.8 KB** | 1,462.6 KB / 485.2 KB / **406.6 KB** | 821.0 KB / 372.3 KB / **332.9 KB** | **-8.3%** |
| `wasm_bench_runner` (`Debug`) | 1,491.7 KB / 519.9 KB / **432.0 KB** | 1,680.7 KB / 552.5 KB / **450.2 KB** | 3,621.0 KB / 1,198.5 KB / **979.2 KB** | **-11.2%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 1,104.5 KB / 413.2 KB / **355.5 KB** | 1,210.5 KB / 424.1 KB / **360.8 KB** | 690.6 KB / 336.0 KB / **301.0 KB** | **-8.8%** |
| All 12 `wasm32-wasi` Test Binaries (`Debug` Total) | 8,982.0 KB / 2,807.4 KB / **2,242.8 KB** | 10,571.0 KB / 3,102.5 KB / **2,450.9 KB** | 29,179.1 KB / 8,887.1 KB / **7,196.1 KB** | **-15.0%** |

**Key Binary Size Takeaways:**
- In **`Debug`** builds, `wazig v0.17.0-wazig.3` produces the **smallest `.wasm` binaries of all three compilers** — **7%–15% smaller** than upstream `zig 0.17.0 -fno-llvm` and **49%–69% smaller (2x–3.25x smaller)** than `zig 0.17.0 -fllvm`.
- Across all 12 `wasm32-wasi` test binaries, `wazig` emits **9.20 MB** raw (`2.30 MB` zstd) vs **29.88 MB** raw (`7.92 MB` zstd) with `zig -fllvm`, cutting Wasmtime JIT compile time during `test` runs by **2.66x**.

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **1.575 ms** / 1.579 ms (**635.2 FPS**) | 1.540 ms / 1.544 ms (649.6 FPS) | 0.291 ms / 0.295 ms (3,422.1 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **5.505 ms** / 5.519 ms (**181.7 FPS**) | 3.615 ms / 3.634 ms (276.5 FPS) | 1.177 ms / 1.185 ms (848.6 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **1.282 ms** / 1.294 ms (**779.1 FPS**) | 1.023 ms / 1.032 ms (976.5 FPS) | 0.269 ms / 0.283 ms (3,666.7 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **3.286 ms** / 3.303 ms (**304.2 FPS**) | 2.774 ms / 2.786 ms (360.4 FPS) | 0.747 ms / 0.759 ms (1,341.3 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **1.683 ms** / 1.692 ms (**593.8 FPS**) | 1.625 ms / 1.629 ms (615.6 FPS) | 1.621 ms / 1.627 ms (616.6 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **7.921 ms** / 7.986 ms (**126.1 FPS**) | 5.125 ms / 5.154 ms (195.0 FPS) | 4.408 ms / 4.438 ms (226.7 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **1.403 ms** / 1.417 ms (**711.9 FPS**) | 1.165 ms / 1.175 ms (857.1 FPS) | 1.044 ms / 1.053 ms (956.5 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **3.561 ms** / 3.625 ms (**280.4 FPS**) | 3.055 ms / 3.068 ms (327.2 FPS) | 2.960 ms / 3.024 ms (337.1 FPS) | `8133605907336869050` |

### D.3 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)

| Compiler | Test Binaries Passed | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |
| :--- | :---: | ---: | ---: |
| **`wazig v0.17.0-wazig.3` (`-fno-llvm`)** | **12 / 12** (with `+atomics`) | **4.020 s** | **2.66x faster** |
| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`* (12 / 12 without `+atomics`) | 4.798 s | 2.23x faster |
| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics`) | 10.699 s | 1.00x (baseline) |

> *\*Upstream `zig 0.17.0 -fno-llvm` (`0.17.0-dev.27+0dd99239c`) emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig v0.17.0-wazig.3` fixes both bugs.*

