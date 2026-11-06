# `wazig` (`v0.17.0-wazig.4` Candidate) vs `zig v0.17.0` Comprehensive Benchmark Report

Reproducible benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig` (`v0.17.0-wazig.4` candidate, `cataggar/zig@b23f3693b9`)** (universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1`, including `cataggar/zig#158`, `#159`, `#163`, `#164`, `#168`, `#169`, `#170`, `#171` and `cataggar/knots#10` / `#11`)
- **`zig v0.17.0 -fno-llvm`** (`0.17.0-dev.27+0dd99239c`, native `x86_64-linux` binary with self-hosted Wasm backend)
- **`zig v0.17.0 -fllvm`** (`0.17.0-dev.27+0dd99239c`, native `x86_64-linux` binary with LLVM 22 backend)

---

## A. Toolchain & CI Footprint

| Metric | `wazig` (`wasm64-wasip3`) | `zig v0.17.0` (Standard) | Reduction / Advantage |
| :--- | :--- | :--- | :--- |
| **Release Archive Size** | **8.45 MB** (`wazig.tar.zst`) | 51.20 MB (`tar.xz`) | **6.06x smaller download (-83.5%)** |
| **Unpacked Release Size** | **40.4 MB** (`21.1 MB` `wazig.wasm` + `19.3 MB` Wasm `lib/`) | 265.0 MB (`360.3 MB` in `ghr` store) | **6.56x–8.92x smaller on disk (-84.8%)** |
| **Installed File Count** | **1,324 files** | 19,505 files | **14.7x fewer files** |
| **Binary Portability** | wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | OS/arch-specific native binaries (x86_64-linux, aarch64-macos, x86_64-windows, etc.) | **Single universal artifact** |
| **Supply-Chain Attestation** | Native Sigstore bundle verified via ghr | minisign signature (external tool required) | **Zero extra verification tools** |
| **Wasm Build Dependency Fetch** | **4.91 MB** compressed / **34.7 MB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~230+ MB compressed / ~680 MB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |

---

## B. Compilation Speed (Cold Cache & Warm Cache)

> All `wazig` measurements run with Wasmtime's compiled module cache warmed (`wazig version` startup `0.26s`).

| Workload | `wazig` (`-fno-llvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |
| :--- | ---: | ---: | ---: |
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.569s** | 0.044s | 0.044s |
| `wasm_bench_runner.zig` (`Debug`) | 14.68s (cold) / 6.86s (warm) | 3.81s (cold) / 0.29s (warm) | 6.33s (cold) / 2.73s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 13.06s (cold) / 5.17s (warm) | 2.19s (cold) / 0.25s (warm) | 7.44s (cold) / 5.33s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast`) | 13.91s (cold) / 5.73s (warm) | 3.62s (cold) / 0.25s (warm) | 14.05s (cold) / 10.67s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | 13.53s (cold) / 5.74s (warm) | FAIL (`IllDefinedMemoryLayout`)* | 14.05s (cold) / 10.67s (warm) |
| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | 18.78s wall (57.4s CPU) | 9.78s wall (43.5s CPU) | 14.73s wall (63.9s CPU) |
| `examples/triangle` (`Debug`) | 10.22s (cold) / 7.53s (warm) | 2.96s (cold) / 0.31s (warm) | 5.73s (cold) / 3.12s (warm) |
| `examples/triangle` (`ReleaseSmall`) | 8.51s (cold) / 5.74s (warm) | 2.23s (cold) / 0.27s (warm) | 8.56s (cold) / 6.43s (warm) |
| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | 18.06s | 1.29s | 5.94s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 15.90s | 1.24s | 13.81s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | 18.04s | 1.26s | 5.80s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 15.70s | 1.27s | 13.45s |
| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **20.86s** | FAIL (`global.get` asm) | 8.74s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **18.08s** | FAIL (`global.get` asm) | 16.35s |
| `examples/embedded` (`Debug`) | 6.95s | 0.48s | 2.85s |
| `examples/embedded` (`ReleaseSmall`) | 5.28s | 0.39s | 5.94s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | 9.21s | 0.49s | 3.36s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | 7.47s | 0.41s | 7.29s |

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig` (`-fno-llvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` (Raw) |
| :--- | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 2,891.7 KB / 970.3 KB / **755.9 KB** | 3,403.3 KB / 1,038.7 KB / **787.9 KB** | 6,161.3 KB / 1,996.2 KB / **1,503.3 KB** | **-15.0%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,496.4 KB / 865.4 KB / **682.1 KB** | 2,817.7 KB / 884.6 KB / **691.0 KB** | 1,805.0 KB / 708.7 KB / **579.2 KB** | **-11.4%** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 2,857.5 KB / 965.3 KB / **752.0 KB** | 3,369.1 KB / 1,033.5 KB / **790.4 KB** | 6,127.1 KB / 1,991.4 KB / **1,508.9 KB** | **-15.2%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,462.1 KB / 860.5 KB / **678.2 KB** | 2,783.4 KB / 879.0 KB / **687.8 KB** | 1,770.9 KB / 702.3 KB / **589.7 KB** | **-11.5%** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 2,902.3 KB / 973.3 KB / **759.5 KB** | FAIL (`global.get` asm) | 6,201.0 KB / 2,010.6 KB / **1,543.6 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,504.2 KB / 868.0 KB / **668.4 KB** | FAIL (`global.get` asm) | 1,809.2 KB / 710.6 KB / **599.2 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| `triangle` (`Debug`) | 1,495.2 KB / 543.3 KB / **451.6 KB** | 1,902.0 KB / 606.4 KB / **490.1 KB** | 3,860.4 KB / 1,288.5 KB / **1,037.4 KB** | **-21.4%** |
| `triangle` (`ReleaseSmall`) | 1,195.1 KB / 457.8 KB / **390.6 KB** | 1,437.4 KB / 479.3 KB / **401.4 KB** | 813.8 KB / 369.4 KB / **330.3 KB** | **-16.9%** |
| `embedded` (`Debug`) | 1,314.2 KB / 477.8 KB / **401.6 KB** | 1,679.8 KB / 536.6 KB / **439.1 KB** | 3,428.7 KB / 1,127.5 KB / **918.8 KB** | **-21.8%** |
| `embedded` (`ReleaseSmall`) | 1,070.7 KB / 412.7 KB / **355.3 KB** | 1,275.2 KB / 431.6 KB / **365.3 KB** | 746.3 KB / 342.0 KB / **306.3 KB** | **-16.0%** |
| `benchmark` (`Debug`) | 1,515.8 KB / 551.2 KB / **457.0 KB** | 1,933.3 KB / 618.4 KB / **496.8 KB** | 3,934.9 KB / 1,308.7 KB / **1,053.7 KB** | **-21.6%** |
| `benchmark` (`ReleaseSmall`) | 1,211.8 KB / 462.7 KB / **394.7 KB** | 1,462.6 KB / 485.2 KB / **406.6 KB** | 821.0 KB / 372.3 KB / **332.9 KB** | **-17.1%** |
| `wasm_bench_runner` (`Debug`) | 1,286.9 KB / 485.4 KB / **411.3 KB** | 1,680.7 KB / 552.5 KB / **450.2 KB** | 3,621.0 KB / 1,198.5 KB / **979.2 KB** | **-23.4%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 980.9 KB / 404.3 KB / **348.5 KB** | 1,210.5 KB / 424.1 KB / **360.8 KB** | 690.6 KB / 336.0 KB / **301.0 KB** | **-19.0%** |
| `wasm_bench_runner` (`ReleaseFast`) | 1,205.2 KB / 471.7 KB / **396.1 KB** | 1,349.4 KB / 457.4 KB / **390.9 KB** | 3,032.3 KB / 1,023.7 KB / **865.0 KB** | **-10.7%** |
| `wasm_bench_runner` (`ReleaseFast +simd128`) | 1,208.1 KB / 473.6 KB / **398.0 KB** | FAIL (`IllDefinedMemoryLayout`)* | 3,032.3 KB / 1,023.7 KB / **865.0 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| All 12 `wasm32-wasi` Test Binaries (`Debug` Total) | 7,759.0 KB / 2,602.7 KB / **2,112.1 KB** | 10,571.0 KB / 3,102.5 KB / **2,450.9 KB** | 29,179.1 KB / 8,887.1 KB / **7,196.1 KB** | **-26.6%** |

**Key Binary Size Takeaways:**
- In **`Debug`** builds, `wazig` produces the **smallest `.wasm` binaries of all three compilers** — **14.8%–23.4% smaller** than upstream `zig 0.17.0 -fno-llvm` and **53.1%–65.3% smaller (2.13x–2.88x smaller)** than `zig 0.17.0 -fllvm`.
- In **`ReleaseSmall`** builds, `wazig` is **11.1%–19.0% smaller** than upstream `zig 0.17.0 -fno-llvm` across all targets (`980.9 KB` raw / `348.5 KB` zstd on `wasm_bench_runner.wasm` vs `1,210.5 KB` raw on `zig -fno-llvm`).
- Across all 12 `wasm32-wasi` test binaries, `wazig` emits **7.58 MB** raw (`2.06 MB` zstd) vs **28.50 MB** raw (`7.03 MB` zstd) with `zig -fllvm`, cutting Wasmtime JIT compile + test execution time by **11.49x** (`0.931s` vs `10.699s`, and **3.31x faster** than `25bcd82e14`'s `3.078s`).

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.955 ms** / 0.960 ms (**1,046.9 FPS**) | 1.540 ms / 1.544 ms (649.6 FPS) | 0.291 ms / 0.295 ms (3,422.1 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **0.931 ms** / 0.938 ms (**1,073.9 FPS**) | 3.615 ms / 3.634 ms (276.5 FPS) | 1.177 ms / 1.185 ms (848.6 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.518 ms** / 0.523 ms (**1,944.6 FPS**) | 1.023 ms / 1.032 ms (976.5 FPS) | 0.269 ms / 0.283 ms (3,666.7 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.556 ms** / 1.569 ms (**642.5 FPS**) | 2.774 ms / 2.786 ms (360.4 FPS) | 0.747 ms / 0.759 ms (1,341.3 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`

| Workload | `wazig` `ReleaseFast` (Median / FPS) | `wazig` `ReleaseFast +simd128` (Median / FPS) | `zig -fno-llvm` `ReleaseFast` (Median / FPS) | `zig -fllvm` `ReleaseFast` (Median / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.873 ms** (**1,146.2 FPS**) | **0.870 ms** (**1,150.3 FPS**) | 1.542 ms (648.6 FPS) | 0.208 ms (4,771.1 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **0.857 ms** (**1,168.1 FPS**) | **0.851 ms** (**1,175.1 FPS**) | 3.614 ms (276.6 FPS) | 0.890 ms (1,123.8 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.478 ms** (**2,096.8 FPS**) | **0.402 ms** (**2,455.9 FPS**) | 1.020 ms (979.5 FPS) | 0.167 ms (5,900.2 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **1.478 ms** (**676.4 FPS**) | **1.447 ms** (**690.7 FPS**) | 2.777 ms (359.4 FPS) | 0.489 ms (2,053.5 FPS) | `8133605907336869050` |

**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**
- **`wazig` vs `zig 0.17.0 -fno-llvm` & `zig 0.17.0 -fllvm`**: With inline `@min`/`@max` (`cataggar/zig#158`), SROA to Wasm locals (`cataggar/zig#159`), parameterized leaf inlining (`cataggar/zig#163`, `#169`), `v128` `+simd128` vector & `@reduce` lowering (`cataggar/zig#164`, `#168`), multivalue 2-scalar returns (`cataggar/zig#170`), and `band.fillBands` curve extent precomputation (`cataggar/knots#10` / `#11`), `wazig` is now **1.77x–4.25x faster** than upstream `zig 0.17.0 -fno-llvm` across all four workloads (and **1.81x–6.47x faster** than `wazig v0.17.0-wazig.3`). On `text_bench`, `wazig` (`1,073.9 FPS` in `ReleaseSmall`, `1,168.1 FPS` in `ReleaseFast`, **`1,175.1 FPS`** in `ReleaseFast +simd128`) **outperforms `zig 0.17.0 -fllvm` (LLVM 22)** in both `ReleaseSmall` (`848.6 FPS`, **1.27x faster**) and `ReleaseFast` (`1,123.8 FPS`, **1.05x faster**).
- **`ReleaseFast +simd128` vs `ReleaseSmall`**: Parameterized leaf inlining in `.fast` mode (`band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `appendAssumeCapacity`), Wasm multivalue 2-scalar returns (`curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`), and `v128` SIMD (`Rect.eql` and `Clip.State.scissorEql` lowered to `f32x4.eq` + `i32x4.all_true` and completely inlined into `DrawList.keyMatches` / `DrawList.lastCmdMatches`) boosts `render_bench` from `1,944.6 FPS` (`ReleaseSmall`) to **`2,455.9 FPS` (+26.3%)**, `layout_bench` from `1,046.9 FPS` to **`1,150.3 FPS` (+9.9%)**, `text_bench` from `1,073.9 FPS` to **`1,175.1 FPS` (+9.4%)**, and `combined_frame` from `642.5 FPS` to **`690.7 FPS` (+7.5%)**.
- **`zig -fllvm` (LLVM 22)**: `ReleaseFast` increases `combined_frame` throughput from `1,341.3 FPS` (`0.747 ms`) to `2,053.5 FPS` (`0.487 ms`, `+53.1%`), but explodes `.wasm` binary size by **4.39x** (`3,032.3 KB` raw / `865.0 KB` zstd vs `690.6 KB` raw / `301.0 KB` zstd in `ReleaseSmall` — making `-fllvm ReleaseFast` **2.52x larger** than `wazig ReleaseFast` and **3.09x larger** than `wazig ReleaseSmall`).

### D.3 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **1.056 ms** / 1.063 ms (**945.8 FPS**) | 1.625 ms / 1.629 ms (615.6 FPS) | 1.621 ms / 1.627 ms (616.6 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **1.165 ms** / 1.178 ms (**856.8 FPS**) | 5.125 ms / 5.154 ms (195.0 FPS) | 4.408 ms / 4.438 ms (226.7 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.606 ms** / 0.614 ms (**1,660.4 FPS**) | 1.165 ms / 1.175 ms (857.1 FPS) | 1.044 ms / 1.053 ms (956.5 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.786 ms** / 1.797 ms (**559.8 FPS**) | 3.055 ms / 3.068 ms (327.2 FPS) | 2.960 ms / 3.024 ms (337.1 FPS) | `8133605907336869050` |

**`Debug` Runtime Highlight:** In `Debug` builds, `wazig` is now **1.53x–3.78x faster at runtime than `zig 0.17.0 -fllvm` (LLVM 22)** across all four workloads (`945.8 FPS` vs `616.6 FPS` on `layout_bench`, `856.8 FPS` vs `226.7 FPS` on `text_bench`, `1,660.4 FPS` vs `956.5 FPS` on `render_bench`, and `559.8 FPS` vs `337.1 FPS` on `combined_frame`) while producing **2.81x smaller** `.wasm` binaries (`1,286.9 KB` vs `3,621.0 KB`).

### D.4 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)

| Compiler | Test Binaries Passed | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |
| :--- | :---: | ---: | ---: |
| **`wazig` (`-fno-llvm`)** | **12 / 12** (with `+atomics`) | **0.931 s** | **11.49x faster** |
| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`* (12 / 12 without `+atomics`) | 4.798 s | 2.23x faster |
| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics`) | 10.699 s | 1.00x (baseline) |

> *\*Upstream `zig 0.17.0 -fno-llvm` (`0.17.0-dev.27+0dd99239c`) emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, panics with `IllDefinedMemoryLayout` on `@Vector` types with `+simd128`, and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig` fixes all three bugs.*

---

## E. Guest Profiling Verification (`wasmtime-profile.py` @ `100us`)

### E.1 Verified Impact of `cataggar/zig#158`–`#171` & `cataggar/knots#10` (`#11`, `#9`)

Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **3.41x** from `21,457` (`v0.17.0-wazig.3`) → `7,777` (`25bcd82e14`) → **`6,984` (`ReleaseSmall`) / `6,513` (`ReleaseFast`) / `6,287` (`ReleaseFast +simd128`)** in `cataggar/zig@b23f3693b9` + `cataggar/knots#10` (`#11`), with all `cataggar/knots#9` targets met or exceeded:

| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.4` (`25bcd82e14`, `ReleaseFast +simd128`) | `wazig.4` (`b23f3693b9`, `ReleaseSmall`) | `wazig.4` (`b23f3693b9`, `ReleaseFast +simd128`) | Speedup vs `wazig.3` | `knots#9` Goal |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.865 ms (1,156.6 FPS) | 0.955 ms (1,046.9 FPS) | **0.870 ms (1,150.3 FPS)** | **1.81x faster** | `>= 1,000 FPS` (Achieved) |
| **`text_bench`** | 5.505 ms (181.7 FPS) | 1.830 ms (546.3 FPS) | 0.931 ms (1,073.9 FPS) | **0.851 ms (1,175.1 FPS)** | **6.47x faster** | `>= 500 FPS` (Exceeded **2.35x**) |
| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.417 ms (2,373.8 FPS) | 0.518 ms (1,944.6 FPS) | **0.402 ms (2,455.9 FPS)** | **3.15x faster** | `>= 1,800 FPS` (Achieved) |
| **`combined_frame`** | 3.286 ms (304.2 FPS) | 1.446 ms (690.8 FPS) | 1.556 ms (642.5 FPS) | **1.447 ms (690.7 FPS)** | **2.27x faster** | `>= 600 FPS` (Achieved) |

- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`).
- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.
- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) & [`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` parameterized leaf inlining, single-caller `.small` inlining, and local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity`, and reduced `ReleaseSmall` binary size by **-11.2%** (`1,104.5 KB` → `980.9 KB`).
- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) & [`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — `@Vector` layout, `v128` `+simd128` SIMD arithmetic, and fused `cmp_vector` + `@reduce(.And/.Or)` lowering**: `Rect.eql` and `Clip.State.scissorEql` in `ReleaseFast +simd128` are now **both `0` bytes and `0` samples** — lowered to `f32x4.eq` + `i32x4.all_true` and completely inlined into `DrawList.keyMatches` and `DrawList.lastCmdMatches`, accelerating `render_bench` to **`2,455.9 FPS` (`0.402 ms`)**.
- **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Wasm multivalue return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`, `HMetrics`, `[2]u8`, `u128`)**: Eliminated linear-memory `sret` stack frames for 2-scalar returns, allowing `curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`, and `fmt.digits2` to be completely inlined and removed in `ReleaseFast`.
- **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing**: Parallel 4-way cold-cache `wasm32-wasi` test suite compilation completes with zero `Archive.zig` race panics (`18.78s` wall / `57.41s` CPU; **`0.931s`** total test execution time across all 12 suites — **3.31x faster** than `25bcd82e14`'s `3.078s` and **11.49x faster** than `zig -fllvm`'s `10.699s`).
- **[`cataggar/knots#10`](https://github.com/cataggar/knots/issues/10) ([`cataggar/knots#11`](https://github.com/cataggar/knots/pull/11)) — Precomputed per-curve extents & insertion sort in `src/text/band.zig`**: `band.fillBands` inclusive samples dropped **3.25x–3.72x** (`1,951` / `25.09%` → `525` / `7.50%` in `ReleaseSmall`, `578` / `8.87%` in `ReleaseFast`, `601` / `9.56%` in `ReleaseFast +simd128`), and `std.sort.block` (`sort.block.swap`, `16.4 KB` bytecode, `8.83%` runtime) is **completely eliminated (`0` bytes, `0` samples)**, more than doubling `text_bench` throughput (`546.3 FPS` → **`1,175.1 FPS`**, beating `zig -fllvm` LLVM 22 `ReleaseFast`).

### E.2 Top 15 Functions in `ReleaseFast +simd128` (`6,287` total samples @ 100us)

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

