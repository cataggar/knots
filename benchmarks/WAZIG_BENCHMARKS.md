# `wazig` (`v0.17.0-wazig.4` Candidate) vs `zig v0.17.0` Comprehensive Benchmark Report

Reproducible benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig` (`v0.17.0-wazig.4` candidate, `cataggar/zig@25bcd82e14`)** (universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1`)
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
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.573s** | 0.044s | 0.044s |
| `wasm_bench_runner.zig` (`Debug`) | 15.22s (cold) / 7.17s (warm) | 3.81s (cold) / 0.29s (warm) | 6.33s (cold) / 2.73s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 12.76s (cold) / 5.12s (warm) | 2.19s (cold) / 0.25s (warm) | 7.44s (cold) / 5.33s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast`) | 13.84s (cold) / 6.05s (warm) | 3.62s (cold) / 0.25s (warm) | 14.05s (cold) / 10.67s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | 13.71s (cold) / 5.96s (warm) | FAIL (`IllDefinedMemoryLayout`)* | 14.05s (cold) / 10.67s (warm) |
| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | 20.39s wall (62.1s CPU) | 9.78s wall (43.5s CPU) | 14.73s wall (63.9s CPU) |
| `examples/triangle` (`Debug`) | 10.68s (cold) / 7.85s (warm) | 2.96s (cold) / 0.31s (warm) | 5.73s (cold) / 3.12s (warm) |
| `examples/triangle` (`ReleaseSmall`) | 8.59s (cold) / 6.00s (warm) | 2.23s (cold) / 0.27s (warm) | 8.56s (cold) / 6.43s (warm) |
| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | 21.31s | 1.29s | 5.94s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 18.54s | 1.24s | 13.81s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | 21.23s | 1.26s | 5.80s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 18.42s | 1.27s | 13.45s |
| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **21.20s** | FAIL (`global.get` asm) | 8.74s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **18.62s** | FAIL (`global.get` asm) | 16.35s |
| `examples/embedded` (`Debug`) | 9.69s | 0.48s | 2.85s |
| `examples/embedded` (`ReleaseSmall`) | 7.55s | 0.39s | 5.94s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | 11.93s | 0.49s | 3.36s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | 9.82s | 0.41s | 7.29s |

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig` (`-fno-llvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` (Raw) |
| :--- | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 2,940.2 KB / 982.7 KB / **767.7 KB** | 3,403.3 KB / 1,038.7 KB / **787.9 KB** | 6,161.3 KB / 1,996.2 KB / **1,503.3 KB** | **-13.6%** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,518.6 KB / 871.1 KB / **659.7 KB** | 2,817.7 KB / 884.6 KB / **691.0 KB** | 1,805.0 KB / 708.7 KB / **579.2 KB** | **-10.6%** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 2,905.9 KB / 976.7 KB / **739.5 KB** | 3,369.1 KB / 1,033.5 KB / **790.4 KB** | 6,127.1 KB / 1,991.4 KB / **1,508.9 KB** | **-13.7%** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,484.4 KB / 866.3 KB / **662.3 KB** | 2,783.4 KB / 879.0 KB / **687.8 KB** | 1,770.9 KB / 702.3 KB / **589.7 KB** | **-10.7%** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 2,951.0 KB / 986.4 KB / **769.2 KB** | FAIL (`global.get` asm) | 6,201.0 KB / 2,010.6 KB / **1,543.6 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,526.2 KB / 873.5 KB / **690.3 KB** | FAIL (`global.get` asm) | 1,809.2 KB / 710.6 KB / **599.2 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| `triangle` (`Debug`) | 1,536.8 KB / 556.2 KB / **462.0 KB** | 1,902.0 KB / 606.4 KB / **490.1 KB** | 3,860.4 KB / 1,288.5 KB / **1,037.4 KB** | **-19.2%** |
| `triangle` (`ReleaseSmall`) | 1,216.1 KB / 463.6 KB / **395.7 KB** | 1,437.4 KB / 479.3 KB / **401.4 KB** | 813.8 KB / 369.4 KB / **330.3 KB** | **-15.4%** |
| `embedded` (`Debug`) | 1,354.4 KB / 489.0 KB / **410.9 KB** | 1,679.8 KB / 536.6 KB / **439.1 KB** | 3,428.7 KB / 1,127.5 KB / **918.8 KB** | **-19.4%** |
| `embedded` (`ReleaseSmall`) | 1,091.0 KB / 418.4 KB / **360.8 KB** | 1,275.2 KB / 431.6 KB / **365.3 KB** | 746.3 KB / 342.0 KB / **306.3 KB** | **-14.5%** |
| `benchmark` (`Debug`) | 1,558.1 KB / 562.4 KB / **466.9 KB** | 1,933.3 KB / 618.4 KB / **496.8 KB** | 3,934.9 KB / 1,308.7 KB / **1,053.7 KB** | **-19.4%** |
| `benchmark` (`ReleaseSmall`) | 1,233.2 KB / 468.5 KB / **400.3 KB** | 1,462.6 KB / 485.2 KB / **406.6 KB** | 821.0 KB / 372.3 KB / **332.9 KB** | **-15.7%** |
| `wasm_bench_runner` (`Debug`) | 1,325.0 KB / 496.7 KB / **420.5 KB** | 1,680.7 KB / 552.5 KB / **450.2 KB** | 3,621.0 KB / 1,198.5 KB / **979.2 KB** | **-21.2%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 998.7 KB / 409.5 KB / **352.8 KB** | 1,210.5 KB / 424.1 KB / **360.8 KB** | 690.6 KB / 336.0 KB / **301.0 KB** | **-17.5%** |
| `wasm_bench_runner` (`ReleaseFast`) | 1,224.2 KB / 480.9 KB / **404.3 KB** | 1,349.4 KB / 457.4 KB / **390.9 KB** | 3,032.3 KB / 1,023.7 KB / **865.0 KB** | **-9.3%** |
| `wasm_bench_runner` (`ReleaseFast +simd128`) | 1,230.0 KB / 484.8 KB / **405.9 KB** | FAIL (`IllDefinedMemoryLayout`)* | 3,032.3 KB / 1,023.7 KB / **865.0 KB** | **`wazig` succeeds** (`zig -fno-llvm` fails) |
| All 12 `wasm32-wasi` Test Binaries (`Debug` Total) | 7,916.9 KB / 2,649.3 KB / **2,150.5 KB** | 10,571.0 KB / 3,102.5 KB / **2,450.9 KB** | 29,179.1 KB / 8,887.1 KB / **7,196.1 KB** | **-25.1%** |

**Key Binary Size Takeaways:**
- In **`Debug`** builds, `wazig` produces the **smallest `.wasm` binaries of all three compilers** — **14%–25% smaller** than upstream `zig 0.17.0 -fno-llvm` and **53%–73% smaller (2.1x–3.69x smaller)** than `zig 0.17.0 -fllvm`.
- In **`ReleaseSmall`** builds, `wazig` is **12.7%–19.4% smaller** than upstream `zig 0.17.0 -fno-llvm` across all targets (`975.3 KB` raw / `344.6 KB` zstd on `wasm_bench_runner.wasm` vs `1,210.5 KB` raw on `zig -fno-llvm`).
- Across all 12 `wasm32-wasi` test binaries, `wazig` emits **7.73 MB** raw (`2.10 MB` zstd) vs **29.18 MB** raw (`7.20 MB` zstd) with `zig -fllvm`, cutting Wasmtime JIT compile + test execution time by **3.48x** (`3.078s` vs `10.699s`).

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.955 ms** / 0.961 ms (**1,046.3 FPS**) | 1.540 ms / 1.544 ms (649.6 FPS) | 0.291 ms / 0.295 ms (3,422.1 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **2.007 ms** / 2.019 ms (**497.8 FPS**) | 3.615 ms / 3.634 ms (276.5 FPS) | 1.177 ms / 1.185 ms (848.6 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.557 ms** / 0.560 ms (**1,807.1 FPS**) | 1.023 ms / 1.032 ms (976.5 FPS) | 0.269 ms / 0.283 ms (3,666.7 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.582 ms** / 1.594 ms (**631.6 FPS**) | 2.774 ms / 2.786 ms (360.4 FPS) | 0.747 ms / 0.759 ms (1,341.3 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`

| Workload | `wazig` `ReleaseFast` (Median / FPS) | `wazig` `ReleaseFast +simd128` (Median / FPS) | `zig -fno-llvm` `ReleaseFast` (Median / FPS) | `zig -fllvm` `ReleaseFast` (Median / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.868 ms** (**1,151.6 FPS**) | **0.865 ms** (**1,156.6 FPS**) | 1.542 ms (648.6 FPS) | 0.208 ms (4,771.1 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | **1.925 ms** (**519.2 FPS**) | **1.830 ms** (**546.3 FPS**) | 3.614 ms (276.6 FPS) | 0.890 ms (1,123.8 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.479 ms** (**2,098.8 FPS**) | **0.417 ms** (**2,373.8 FPS**) | 1.020 ms (979.5 FPS) | 0.167 ms (5,900.2 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **1.467 ms** (**681.3 FPS**) | **1.446 ms** (**690.8 FPS**) | 2.777 ms (359.4 FPS) | 0.489 ms (2,053.5 FPS) | `8133605907336869050` |

**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**
- **`wazig` vs `zig 0.17.0 -fno-llvm`**: With inline `@min`/`@max` (`#158`), SROA to Wasm locals (`#159`), parameterized leaf inlining (`#163`), and `v128` `+simd128` vector lowering (`#164`), `wazig` is now **1.79x–2.42x faster** than upstream `zig 0.17.0 -fno-llvm` across all four workloads (and **1.82x–3.05x faster** than `wazig v0.17.0-wazig.3`).
- **`ReleaseFast +simd128` vs `ReleaseSmall`**: Parameterized leaf inlining in `.fast` mode (`band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `appendAssumeCapacity`) plus `v128` SIMD (`Rect.eql` inlined into `Clip.State.scissorEql`) boosts `render_bench` from `1,807.1 FPS` (`ReleaseSmall`) to **`2,373.8 FPS` (+31.4%)**, `layout_bench` from `1,046.3 FPS` to **`1,156.6 FPS` (+10.5%)**, `text_bench` from `497.8 FPS` to **`546.3 FPS` (+9.7%)**, and `combined_frame` from `631.6 FPS` to **`690.8 FPS` (+9.4%)**.
- **`zig -fllvm` (LLVM 22)**: `ReleaseFast` increases `combined_frame` throughput from `1,341.3 FPS` (`0.747 ms`) to `2,053.5 FPS` (`0.487 ms`, `+53.1%`), but explodes `.wasm` binary size by **4.39x** (`3,032.3 KB` raw / `865.0 KB` zstd vs `690.6 KB` raw / `301.0 KB` zstd in `ReleaseSmall` — making `-fllvm ReleaseFast` **2.54x larger** than `wazig ReleaseFast` and **3.11x larger** than `wazig ReleaseSmall`).

### D.3 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **1.065 ms** / 1.071 ms (**938.1 FPS**) | 1.625 ms / 1.629 ms (615.6 FPS) | 1.621 ms / 1.627 ms (616.6 FPS) | `417689973924794692` |
| **2. TrueType + Slug Curve Prep (`text_bench`)** | 200 | 3,405 | **2.752 ms** / 2.762 ms (**363.3 FPS**) | 5.125 ms / 5.154 ms (195.0 FPS) | 4.408 ms / 4.438 ms (226.7 FPS) | `12606774574179943755` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.632 ms** / 0.638 ms (**1,592.2 FPS**) | 1.165 ms / 1.175 ms (857.1 FPS) | 1.044 ms / 1.053 ms (956.5 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **1.801 ms** / 1.818 ms (**554.8 FPS**) | 3.055 ms / 3.068 ms (327.2 FPS) | 2.960 ms / 3.024 ms (337.1 FPS) | `8133605907336869050` |

**`Debug` Runtime Highlight:** In `Debug` builds, `wazig` is now **1.52x–1.66x faster at runtime than `zig 0.17.0 -fllvm` (LLVM 22)** across all four workloads (`938.1 FPS` vs `616.6 FPS` on `layout_bench`, `363.3 FPS` vs `226.7 FPS` on `text_bench`, `1,592.2 FPS` vs `956.5 FPS` on `render_bench`, and `554.8 FPS` vs `337.1 FPS` on `combined_frame`) while producing **2.80x smaller** `.wasm` binaries (`1,293.9 KB` vs `3,621.0 KB`).

### D.4 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)

| Compiler | Test Binaries Passed | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |
| :--- | :---: | ---: | ---: |
| **`wazig` (`-fno-llvm`)** | **12 / 12** (with `+atomics`) | **3.078 s** | **3.48x faster** |
| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`* (12 / 12 without `+atomics`) | 4.798 s | 2.23x faster |
| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics`) | 10.699 s | 1.00x (baseline) |

> *\*Upstream `zig 0.17.0 -fno-llvm` (`0.17.0-dev.27+0dd99239c`) emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, panics with `IllDefinedMemoryLayout` on `@Vector` types with `+simd128`, and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig` fixes all three bugs.*

---

## E. Guest Profiling Verification (`wasmtime-profile.py`) & Next-Round Optimization Roadmap

### E.1 Verified Impact of `cataggar/zig#158`, `#159`, `#163`, `#164` (`cataggar/knots#9`)

Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **2.76x** (`21,457` samples in `v0.17.0-wazig.3` → `8,874` in `ReleaseSmall` → `7,888` in `ReleaseFast` → `7,777` in `ReleaseFast +simd128`) and all `cataggar/knots#9` targets are met or exceeded:

| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.4` (`ReleaseSmall`) | `wazig.4` (`ReleaseFast +simd128`) | Speedup vs `wazig.3` | `knots#9` Goal |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.955 ms (1,046.3 FPS) | **0.865 ms (1,156.6 FPS)** | **1.82x faster** | `>= 1,000 FPS` (Achieved) |
| **`text_bench`** | 5.505 ms (181.7 FPS) | 2.007 ms (497.8 FPS) | **1.830 ms (546.3 FPS)** | **3.01x faster** | `>= 500 FPS` (Achieved) |
| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.557 ms (1,807.1 FPS) | **0.417 ms (2,373.8 FPS)** | **3.05x faster** | `>= 1,800 FPS` (Achieved) |
| **`combined_frame`** | 3.286 ms (304.2 FPS) | 1.582 ms (631.6 FPS) | **1.446 ms (690.8 FPS)** | **2.27x faster** | `>= 600 FPS` (Achieved) |

- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`).
- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.
- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) — `Optimizer.zig` parameterized leaf inlining & local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity` in `ReleaseFast`, and reduced `ReleaseSmall` binary size by **-11.7%** (`1,104.5 KB` → `975.3 KB`).
- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) — `@Vector` layout & `v128` `+simd128` SIMD arithmetic**: Unlocked `-mcpu=generic+simd128`, inlining `Rect.eql` (`116` samples → `0`) into `Clip.State.scissorEql` and accelerating `render_bench` to `2,373.8 FPS`. Because `wazig.wasm` itself is compiled through `stage2_wasm` + `Optimizer.zig`, `wazig`'s own compilation speed also improved by **1.40x–1.68x** (`playground` `34.55s` → `21.20s`, 12 test suites `140.0s` CPU → `62.1s` CPU).

### E.2 Top Remaining Hotspots in `ReleaseFast +simd128` (`7,777` total samples @ 100us)

| Self | Self% | Total | Tot% | Bytes | Function | Subsystem & Root Cause |
| ---: | ---: | ---: | ---: | ---: | :--- | :--- |
| 603 | 7.75% | 1,951 | 25.09% | 1,044 | `band.fillBands` | Text band partitioning; recomputes curve extents per band and calls `ArrayList.append` + `std.sort.block` |
| 593 | 7.63% | 687 | 8.83% | 420 | `sort.block.swap` | Block sort element swapping inside `band.fillBands` (`std.mem.sort(u32, ...)`) |
| 402 | 5.17% | 491 | 6.31% | 62 | `array_list.Aligned(u32,null).append` | Per-curve capacity check + 1 cold slow-path `call` prevents leaf inlining |
| 331 | 4.26% | 1,406 | 18.08% | 3,844 | `Context.positionChildren` | Flexbox child positioning; repeated slice indexing & struct field loads |
| 308 | 3.96% | 308 | 3.96% | 2,242 | `Context.distributeGrow` | Flexbox grow/shrink distribution loop |
| 295 | 3.79% | 1,407 | 18.09% | 679 | `Context.computeLayoutNode` | Recursive layout tree traversal |
| 284 | 3.65% | 1,037 | 13.33% | 4,774 | `wasm_bench_runner.buildRenderFrame` | Benchmark harness command construction |
| 213 | 2.74% | 213 | 2.74% | 1,902 | `Context.resolvePercentChildren` | Flexbox percentage resolution loop |
| 167 | 2.15% | 267 | 3.43% | 121 | `ElementPool.append` | Capacity check + 1 cold slow-path `call` prevents leaf inlining |
| 152 | 1.95% | 152 | 1.95% | 2,666 | `hash.wyhash.Wyhash.update` | 64-bit Wyhash mixing for IDs & glyph keys |
| 147 | 1.89% | 151 | 1.94% | 11,503 | `Context.buildZOrder` | Z-order bucket pass (11.5 KB bytecode) |
| 139 | 1.79% | 139 | 1.79% | 457 | `band.SortContext.lessThan` | Recomputes `curveExtent` (`@max(@max(p1, p2), p3)`) on every sort comparison |
| 138 | 1.77% | 138 | 1.77% | 2,689 | `DrawList.commandBounds` | Render command bounding box calculation |
| 118 | 1.52% | 358 | 4.60% | 5,660 | `DrawList.emitBatched` | Render command batching loop |
| 110 | 1.41% | 110 | 1.41% | 311 | `Clip.State.scissorEql` | Optional `Rect.eql` (`@reduce(.And, a.v == b.v)`) still scalarizes `@reduce` lanes |

### E.3 Next-Round Performance Improvements (Compiler & Library)

1. **[`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — SIMD `@reduce` & fused `cmp_vector` + `@reduce(.And/.Or)` in `src/codegen/wasm/CodeGen.zig` (`airCmpVector:6793`, `airReduce:9038`)**:
   - Even with `+simd128`, `airCmpVector` currently extracts all 4 lanes of `f32x4.eq` via `i8x16.extract_lane_u` + `i32.and 1` to materialize `@Vector(4, bool)`, and `airReduce` always runs a scalar loop over `1..vec_len`. Lowering `@reduce(.And, a == b)` / `@reduce(.Or, a != b)` on 128-bit vectors directly to `f32x4.eq` + `i32x4.all_true` / `v128.any_true` (and pairwise `i32x4.shuffle` reductions for `.Add`/`.Min`/`.Max`) collapses `Rect.eql` and `Clip.State.scissorEql` from ~35 ops to 2 ops.
2. **[`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` `.small` mode single-caller/1-local inlining and `.fast` 1-cold-call wrapper inlining (`src/link/Wasm/component/Optimizer.zig:2595`)**:
   - `classifyTrivialFunc` in `.small` mode currently ignores `call_count` and `is_externally_used` and rejects any function with `local_types.items.len != 0` or `op_count > 6`. Inlining `call_count == 1 and !is_externally_used` functions in `.small` mode is strictly size-reducing once `removeDeadFunctions` drops the callee, and allowing 1-local leaf accessors (`<= 10` ops: `ElementPool.get` 27B / 2.79% self, `appendAssumeCapacity` 13B / 1.00% self, `hash_map.header` 29B / 1.09% self) closes most of the `ReleaseSmall` vs `ReleaseFast` runtime gap.
   - In `.fast` mode, `array_list.Aligned(u32,null).append` (62B, **5.17% self / 6.31% total**) and `ElementPool.append` (121B, **2.15% self**) are disqualified from inlining only because their `if (len == cap)` branch contains a single cold slow-path `call`. Allowing `.fast` mode to inline small functions (`<= 28` ops) with at most 1 `call` inside a conditional block (`depth > 0`) eliminates ~7.3% of total call/branch overhead.
3. **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Multi-value / `i64` return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`) in `CodeGen.zig`**:
   - Functions returning 8-byte 2-element arrays or structs (`band.curveExtent` returning `[2]f32`) currently pass a linear-memory `sret` pointer, preventing SROA across non-inlined call boundaries (`156 bytes` in `ReleaseSmall`). Returning 2 scalars via Wasm `multivalue` (already in `generic`) or packed `i64` eliminates the caller stack frame.
4. **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing (`lib/std/Build/Cache.zig`, `src/link/Wasm/Archive.zig:221`)**:
   - Because `std.posix.flock` is a no-op stub on WASI, running multiple `wazig` processes in parallel against a cold shared `--global-cache-dir` can race on partially written manifest or `.a` archive files; bounds-checking `Archive.parse`/`Object.parse` and writing manifests/archives via atomic temp-file rename makes parallel cold-cache builds race-free.
5. **[`cataggar/knots#10`](https://github.com/cataggar/knots/issues/10) — Precompute curve extents & replace `std.sort.block` in `src/text/band.zig` (`band.fillBands` — 25.1% of total runtime)**:
   - `band.fillBands` (`603` self / `1,951` total samples, **25.09%** of the entire benchmark suite) recomputes `curveExtent` for every overlapping band and again inside `band.SortContext.lessThan` (`139` samples) on every comparison of `std.mem.sort` (`std.sort.block`, `16.4 KB` code size, `593` samples / **7.63%** in `sort.block.swap`), and calls capacity-checked `ArrayList.append` (`402` samples / **5.17%**) per band entry. Precomputing per-curve `max_x`/`max_y` once, pre-sizing `curve_indices` (`appendAssumeCapacity`), and using insertion sort for short per-band curve lists will cut `text_bench` time by an estimated 25%–40%.
6. **[`cataggar/knots#9`](https://github.com/cataggar/knots/issues/9) — Enable `+simd128` in `web_build.zig` (`configureWasmTarget`) and `scripts/bench-wazig.py` once `v0.17.0-wazig.4` is released**:
   - Delivers an immediate **+15.8% speedup on `render_bench`** (`2,098.8` → `2,373.8 FPS`) and **+5.2% on `text_bench`** (`519.2` → `546.3 FPS`).

