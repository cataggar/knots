# wazig (v0.17.1-wazig.1) & wazigl (v0.17.0-wazigl.6) vs zig v0.17.1 Comprehensive Benchmark Report

Reproducible benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:
- **`wazig v0.17.1-wazig.1`** (`cataggar/zig@v0.17.1-wazig.1`, `-fno-llvm`): universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1` (`8.08 MiB` `.tar.zst`, `59.90 MiB` unpacked), including Zig `0.17.1` (`#236`), `cataggar/zig#158`–`#238`, and `cataggar/knots#11`–`#36`
- **`wazig v0.17.0-wazig.6`** (`cataggar/zig@v0.17.0-wazig.6`, `-fno-llvm`): prior `0.17.0` `wazig` release baseline on identical `knots` source
- **`wazigl v0.17.0-wazigl.6`** (`cataggar/zig@v0.17.0-wazigl.6`, `-fllvm`): universal `wasm64-wasip3` compiler with full LLVM 22 Wasm backend executed via `wasmtime v50.0.1` (`36.26 MiB` `.tar.zst`, `221.57 MiB` unpacked)
- **`zig v0.17.1 -fno-llvm`** (`cataggar/zig@v0.17.1`, native `0.17.1` binary with self-hosted Wasm backend)
- **`zig v0.17.1 -fllvm`** (`cataggar/zig@v0.17.1`, native `0.17.1` binary with LLVM 22 backend)

---

## A. Toolchain & CI Footprint

| Metric | `wazig v0.17.1-wazig.1` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.1` (Standard) | Reduction / Advantage |
| :--- | :--- | :--- | :--- | :--- |
| **Release Archive Size** | **8.08 MiB** (`wazig.tar.zst`) | **36.26 MiB** (`wazigl.tar.zst`) | 50.43 MiB (`zig-aarch64-linux-0.17.1.tar.xz`) | **`wazig`: 6.24x smaller (-84.0%) / `wazigl`: 1.39x smaller (-28.1%)** |
| **Unpacked Release Size** | **58.86 MiB** (`30.25 MiB` `wazig.wasm` + `28.61 MiB` `lib/`) | **221.57 MiB** (`193.02 MiB` `wazigl.wasm` + `28.55 MiB` `lib/`) | 342.91 MiB (`163.75 MiB` `zig` + `179.16 MiB` `lib/`) | **`wazig`: 5.59x smaller (-82.1%) / `wazigl`: 1.51x smaller (-33.8%)** |
| **Installed File Count** | **1,323 files** | **1,324 files** | 19,520 files | **13.5x fewer files (-92.6%)** |
| **Binary Portability** | wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | wasm64-wasip3 + LLVM 22 (universal single binary across Linux/macOS/Windows x86_64 & aarch64) | OS/arch-specific native binaries (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows, etc.) | **Single universal artifact per tier** |
| **Supply-Chain Attestation** | Native Sigstore bundle verified via ghr | Native Sigstore bundle verified via ghr | minisign signature (external tool required) | **Zero extra verification tools** |
| **Wasm Build Dependency Fetch** | **0.00 MiB** core (0 external pkgs; `4.64 MiB` lazy `tracy` for `benchmark` only) | **0.00 MiB** core (0 external pkgs; `4.64 MiB` lazy `tracy` for `benchmark` only) | ~230+ MiB compressed / ~680 MiB unpacked (8 eager native pkgs incl. Vulkan, Wayland, Win32, wgpu) | **Zero external network fetch for Web/WASI** |

---

## B. Compilation Speed (Cold Cache & Warm Cache)

> All `wazig` and `wazigl` measurements run with Wasmtime's compiled module cache warmed.

| Workload | `wazig v0.17.1-wazig.1` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.1 -fno-llvm` | `zig v0.17.1 -fllvm` (LLVM 22) |
| :--- | ---: | ---: | ---: | ---: |
| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **0.631s** | 1.884s | 0.078s | 0.078s |
| `wasm_bench_runner.zig` (`Debug`) | 20.02s (cold) / 13.11s (warm) | 40.22s (cold) / 25.73s (warm) | 3.77s (cold) / 0.50s (warm) | 8.35s (cold) / 5.13s (warm) |
| `wasm_bench_runner.zig` (`ReleaseSmall`) | 15.92s (cold) / 9.25s (warm) | 35.87s (cold) / 25.37s (warm) | 2.46s (cold) / 0.43s (warm) | 12.98s (cold) / 10.59s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast`) | 18.10s (cold) / 11.13s (warm) | 70.93s (cold) / 56.88s (warm) | 3.60s (cold) / 0.43s (warm) | 28.02s (cold) / 24.59s (warm) |
| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | 18.26s (cold) / 11.35s (warm) | 73.56s (cold) / 58.90s (warm) | FAIL (`IllDefinedMemoryLayout`)* | 30.17s (cold) / 26.61s (warm) |
| All 19 `wasm32-wasi` Test Suites (`js-bridge` + 18 `knots` suites) | 37.56s wall (116.4s CPU) | 47.55s wall (156.2s CPU) | 3.36s wall (7.9s CPU) | 15.65s wall (48.5s CPU) |
| `examples/triangle` (`Debug`) | 14.20s (cold) / 14.44s (warm) | 30.12s (cold) / 18.12s (warm) | 0.54s (cold) / 0.52s (warm) | 5.23s (cold) / 5.26s (warm) |
| `examples/triangle` (`ReleaseSmall`) | 10.27s (cold) / 10.28s (warm) | 26.20s (cold) / 17.52s (warm) | 0.46s (cold) / 0.45s (warm) | 12.12s (cold) / 12.23s (warm) |
| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | 32.31s | 34.28s | 3.78s | 11.19s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 21.55s | 34.29s | 3.10s | 20.16s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | 25.22s | 34.02s | 1.23s | 8.29s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 19.95s | 34.67s | 1.18s | 18.51s |
| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **27.14s** | **42.99s** | FAIL (`global.get` asm)* | 11.00s |
| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **21.66s** | **40.21s** | FAIL (`global.get` asm)* | 20.71s |
| `examples/playground` (`Debug`, WebGL2, `web_threads=true`) | **25.16s** | **34.82s** | FAIL (`global.get` asm)* | 8.52s |
| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=true`) | **19.79s** | **35.49s** | FAIL (`global.get` asm)* | 18.55s |
| `examples/embedded` (`Debug`) | 13.02s | 14.84s | 0.48s | 4.82s |
| `examples/embedded` (`ReleaseSmall`) | 9.31s | 14.30s | 0.41s | 11.14s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | 15.38s | 18.36s | 0.56s | 63.70s |
| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | 11.28s | 18.26s | 0.50s | 12.15s |

**Compilation Speed Analysis (`wazig 0.17.1-wazig.1` vs `wazigl.6` vs `zig 0.17.1`):**
- **`wazig v0.17.1-wazig.1` (`-fno-llvm`) vs `wazigl v0.17.0-wazigl.6` (`-fllvm`)**: Because `wazig` uses Zig's self-hosted WebAssembly backend (`src/codegen/wasm/CodeGen.zig` + `src/link/Wasm/component/Optimizer.zig`) without invoking LLVM's optimization passes, `0.17.1-wazig.1` compiles **2.00x–5.19x faster** than `wazigl.6` (`9.25s` vs `25.37s` warm on `wasm_bench_runner ReleaseSmall`, `11.35s` vs `58.90s` warm on `ReleaseFast +simd128`, and `0.631s` vs `1.884s` on `fmt --check`).
- **`wazig v0.17.1-wazig.1` vs Native `zig v0.17.1 -fllvm`**: Even running inside Wasmtime (`wasm64-wasip3`), `0.17.1-wazig.1` warm-cache builds (`9.25s` `ReleaseSmall`, `11.13s` `ReleaseFast`, `11.35s` `ReleaseFast +simd128`) are **faster than native `zig 0.17.1 -fllvm`** (`10.59s` `ReleaseSmall`, `24.59s` `ReleaseFast`, `26.61s` `ReleaseFast +simd128` — **up to 2.35x faster than native LLVM**!).
- **`wazigl v0.17.0-wazigl.6` vs Native `zig v0.17.1 -fllvm`**: Running the full LLVM 22 + Clang C++ toolchain inside Wasmtime (`wazigl.wasm`, `193.02 MiB`) incurs a ~2.2x–2.4x Wasmtime guest execution multiplier relative to native `zig -fllvm` (`25.37s` vs `10.59s` warm on `ReleaseSmall`), making `wazig` ideal for fast CI test/check inner loops and `ReleaseFast +simd128` builds, and `wazigl` ideal when minimum `ReleaseSmall` wire size is desired without OS/arch-specific native compiler binaries.

---

## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)

| Target Artifact | `wazig v0.17.1-wazig.1` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.1 -fno-llvm` | `zig v0.17.1 -fllvm` | `wazig` vs `zig -fno-llvm` / `wazigl` vs `zig -fllvm` |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `playground` (`Debug`, WebGPU, `web_threads=false`) | 3,689.4 KB / 1,204.4 KB / **905.9 KB** | 8,662.4 KB / 2,866.4 KB / **2,117.3 KB** | 4,896.3 KB / 1,433.0 KB / **1,027.3 KB** | 8,662.4 KB / 2,866.4 KB / **2,117.3 KB** | `wazig`: **-24.7%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | 2,879.9 KB / 989.0 KB / **771.7 KB** | 2,218.3 KB / 839.9 KB / **704.5 KB** | 3,960.5 KB / 1,163.5 KB / **868.2 KB** | 2,218.3 KB / 839.9 KB / **704.5 KB** | `wazig`: **-27.3%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`Debug`, WebGL2, `web_threads=false`) | 3,654.7 KB / 1,199.8 KB / **906.1 KB** | 8,627.7 KB / 2,860.0 KB / **2,125.3 KB** | 4,861.6 KB / 1,427.1 KB / **1,023.6 KB** | 8,627.7 KB / 2,860.0 KB / **2,125.3 KB** | `wazig`: **-24.8%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | 2,845.1 KB / 984.3 KB / **765.9 KB** | 2,183.7 KB / 834.7 KB / **699.7 KB** | 3,925.8 KB / 1,158.8 KB / **862.1 KB** | 2,183.7 KB / 834.7 KB / **699.7 KB** | `wazig`: **-27.5%** / `wazigl`: **0 B (same raw size)** |
| `playground` (`Debug`, WebGPU, `web_threads=true`) | 3,700.0 KB / 1,208.7 KB / **905.4 KB** | 8,714.8 KB / 2,884.9 KB / **2,103.1 KB** | FAIL (`global.get` asm)* | 8,714.8 KB / 2,884.9 KB / **2,103.1 KB** | **`wazig` succeeds** / `wazigl`: **0 B (same raw size)** |
| `playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | 2,886.9 KB / 991.2 KB / **774.3 KB** | 2,225.2 KB / 842.8 KB / **709.0 KB** | FAIL (`global.get` asm)* | 2,225.2 KB / 842.8 KB / **709.0 KB** | **`wazig` succeeds** / `wazigl`: **0 B (same raw size)** |
| `playground` (`Debug`, WebGL2, `web_threads=true`) | 3,665.3 KB / 1,203.6 KB / **906.4 KB** | 8,680.1 KB / 2,879.4 KB / **2,130.1 KB** | FAIL (`global.get` asm)* | 8,680.1 KB / 2,879.4 KB / **2,130.1 KB** | **`wazig` succeeds** / `wazigl`: **0 B (same raw size)** |
| `playground` (`ReleaseSmall`, WebGL2, `web_threads=true`) | 2,852.2 KB / 986.3 KB / **769.3 KB** | 2,190.6 KB / 836.9 KB / **702.7 KB** | FAIL (`global.get` asm)* | 2,190.6 KB / 836.9 KB / **702.7 KB** | **`wazig` succeeds** / `wazigl`: **0 B (same raw size)** |
| `triangle` (`Debug`) | 2,187.8 KB / 753.1 KB / **599.9 KB** | 5,751.4 KB / 1,943.2 KB / **1,501.6 KB** | 3,105.6 KB / 924.1 KB / **686.1 KB** | 5,751.4 KB / 1,943.2 KB / **1,501.6 KB** | `wazig`: **-29.6%** / `wazigl`: **0 B (same raw size)** |
| `triangle` (`ReleaseSmall`) | 1,627.4 KB / 586.1 KB / **485.6 KB** | 1,162.6 KB / 483.5 KB / **425.5 KB** | 2,332.6 KB / 690.4 KB / **548.6 KB** | 1,162.6 KB / 483.5 KB / **425.5 KB** | `wazig`: **-30.2%** / `wazigl`: **0 B (same raw size)** |
| `embedded` (`Debug`) | 2,024.3 KB / 682.7 KB / **552.3 KB** | 5,277.1 KB / 1,754.3 KB / **1,370.3 KB** | 2,866.5 KB / 833.6 KB / **632.7 KB** | 5,277.1 KB / 1,754.3 KB / **1,370.3 KB** | `wazig`: **-29.4%** / `wazigl`: **0 B (same raw size)** |
| `embedded` (`ReleaseSmall`) | 1,528.4 KB / 548.3 KB / **456.5 KB** | 1,095.2 KB / 455.5 KB / **401.0 KB** | 2,154.9 KB / 639.5 KB / **509.7 KB** | 1,095.2 KB / 455.5 KB / **401.0 KB** | `wazig`: **-29.1%** / `wazigl`: **0 B (same raw size)** |
| `benchmark` (`Debug`) | 2,201.7 KB / 757.0 KB / **602.3 KB** | 5,818.6 KB / 1,963.6 KB / **1,514.8 KB** | 3,132.7 KB / 934.6 KB / **690.7 KB** | 5,818.6 KB / 1,963.6 KB / **1,514.8 KB** | `wazig`: **-29.7%** / `wazigl`: **0 B (same raw size)** |
| `benchmark` (`ReleaseSmall`) | 1,636.7 KB / 588.6 KB / **488.0 KB** | 1,168.2 KB / 485.7 KB / **427.4 KB** | 2,356.0 KB / 696.5 KB / **552.4 KB** | 1,168.2 KB / 485.7 KB / **427.4 KB** | `wazig`: **-30.5%** / `wazigl`: **0 B (same raw size)** |
| `wasm_bench_runner` (`Debug`) | 1,959.9 KB / 686.2 KB / **548.2 KB** | 5,396.0 KB / 1,799.1 KB / **1,396.6 KB** | 2,819.1 KB / 846.5 KB / **628.7 KB** | 5,325.7 KB / 1,782.5 KB / **1,381.8 KB** | `wazig`: **-30.5%** / `wazigl`: **+1.32%** |
| `wasm_bench_runner` (`ReleaseSmall`) | 1,430.2 KB / 533.7 KB / **442.3 KB** | 1,029.1 KB / 444.2 KB / **391.3 KB** | 2,055.0 KB / 625.2 KB / **494.1 KB** | 1,027.9 KB / 443.5 KB / **390.4 KB** | `wazig`: **-30.4%** / `wazigl`: **+0.12%** |
| `wasm_bench_runner` (`ReleaseFast`) | 1,716.5 KB / 641.3 KB / **522.1 KB** | 4,597.9 KB / 1,520.3 KB / **1,269.1 KB** | 2,245.4 KB / 667.0 KB / **533.7 KB** | 4,582.8 KB / 1,508.7 KB / **1,260.3 KB** | `wazig`: **-23.6%** / `wazigl`: **+0.33%** |
| `wasm_bench_runner` (`ReleaseFast +simd128`) | 1,721.8 KB / 640.3 KB / **521.6 KB** | 4,512.6 KB / 1,507.9 KB / **1,259.7 KB** | FAIL (`IllDefinedMemoryLayout`)* | 4,507.5 KB / 1,499.7 KB / **1,256.1 KB** | **`wazig` succeeds** / `wazigl`: **+0.11%** |
| All 19 `wasm32-wasi` Test Binaries (`Debug` Total) | 14,470.4 KB / 4,657.3 KB / **3,743.8 KB** | 51,334.7 KB / 15,985.2 KB / **12,709.7 KB** | 11,082.7 KB / 3,273.5 KB / **2,588.1 KB** | 51,334.7 KB / 15,985.2 KB / **12,709.7 KB** | `wazig`: **+30.6%** / `wazigl`: **0 B (same raw size)** |

**Key Binary Size Takeaways:**
- **`wazigl v0.17.0-wazigl.6` (`-fllvm`) matches native `zig v0.17.1 -fllvm` `ReleaseSmall` `.wasm` binary size (`0.00%`–`0.12%` difference):** `1,029.1 KB` raw (`391.3 KB` zstd) on `wasm_bench_runner`, `2,218.3 KB` raw (`704.5 KB` zstd) on `playground` WebGPU, `2,183.7 KB` raw (`699.7 KB` zstd) on `playground` WebGL2, `2,225.2 KB` raw (`709.0 KB` zstd) on `playground` WebGPU + threads, `1,162.6 KB` raw (`425.5 KB` zstd) on `triangle`, `1,095.2 KB` raw (`401.0 KB` zstd) on `embedded`, and `1,168.2 KB` raw (`427.4 KB` zstd) on `benchmark`.
- **`wazig v0.17.1-wazig.1` (`-fno-llvm`) produces the smallest `Debug` and `ReleaseFast` `.wasm` binaries of all compilers (and shrinks further vs `v0.17.0-wazig.6`):**
  - In **`Debug`** builds, `0.17.1-wazig.1` is **30.5% smaller** than upstream `zig 0.17.1 -fno-llvm` and **63.2%–71.8% smaller (2.72x–3.55x smaller)** than `wazigl.6` and `zig 0.17.1 -fllvm`.
  - In **`ReleaseFast +simd128`** builds, `0.17.1-wazig.1` (`1,721.8 KB` raw / `521.6 KB` zstd) is **2.62x smaller** than `wazigl.6` (`4,512.6 KB` raw / `1,259.7 KB` zstd) and `zig 0.17.1 -fllvm` (`4,507.5 KB` raw / `1,256.1 KB` zstd), while also beating `v0.17.0-wazig.6` by `-31.6 KB` raw (`-29.7 KB` in `ReleaseSmall`).
  - Across all 19 `wasm32-wasi` test binaries (`Debug`), `0.17.1-wazig.1` emits **14.13 MiB** (`14,470.4 KB`) raw (`3.66 MiB` zstd) vs **50.13 MiB** raw (`12.41 MiB` zstd) with `zig 0.17.1 -fllvm` (**3.55x smaller**), enabling **2.45x faster** test suite execution (`4.676s` vs `11.465s`).

---

## D. Runtime Execution Performance (`wasmtime run`)

### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`

| Workload | Iterations | Elements/Iter | `wazig v0.17.1-wazig.1` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.1 -fno-llvm` | `zig v0.17.1 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.107 ms** / 0.110 ms (**9,335.6 FPS**) | **0.107 ms** / 0.112 ms (**9,278.4 FPS**) | 0.266 ms / 0.271 ms (3,746.2 FPS) | 0.107 ms / 0.111 ms (9,286.1 FPS) | `417689973924794692` |
| **2. OpenType Shaper + Slug Curve Prep (`text_bench`)** | 200 | 3,413 | **0.535 ms** / 0.540 ms (**1,869.6 FPS**) | **0.565 ms** / 0.569 ms (**1,769.4 FPS**) | 1.722 ms / 1.738 ms (581.5 FPS) | 0.565 ms / 0.570 ms (1,767.7 FPS) | `17060092853839522222` / `12180320639109031162` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.147 ms** / 0.160 ms (**6,715.3 FPS**) | **0.094 ms** / 0.104 ms (**10,558.0 FPS**) | 0.464 ms / 0.479 ms (2,147.2 FPS) | 0.091 ms / 0.106 ms (10,760.4 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **0.486 ms** / 0.492 ms (**2,060.8 FPS**) | **0.460 ms** / 0.469 ms (**2,163.4 FPS**) | 1.643 ms / 1.661 ms (608.2 FPS) | 0.463 ms / 0.468 ms (2,171.5 FPS) | `8133605907336869050` |

### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`

#### `ReleaseFast (+simd128)` (Default Wasm Target Features in `web_build.zig`)

| Workload | `wazig v0.17.1-wazig.1` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.1 -fno-llvm` | `zig v0.17.1 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.089 ms** / 0.094 ms (**11,170.3 FPS**) | **0.101 ms** / 0.105 ms (**9,807.5 FPS**) | FAIL (`v128` validation)* | 0.101 ms / 0.105 ms (9,827.3 FPS) | `417689973924794692` |
| **2. OpenType Shaper + Slug Curve Prep (`text_bench`)** | **0.461 ms** / 0.466 ms (**2,167.1 FPS**) | **0.497 ms** / 0.503 ms (**2,010.2 FPS**) | FAIL (`v128` validation)* | 0.500 ms / 0.505 ms (2,000.9 FPS) | `17060092853839522222` / `12180320639109031162` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.095 ms** / 0.107 ms (**10,438.4 FPS**) | **0.076 ms** / 0.089 ms (**12,939.9 FPS**) | FAIL (`v128` validation)* | 0.078 ms / 0.089 ms (12,628.1 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **0.391 ms** / 0.402 ms (**2,539.4 FPS**) | **0.487 ms** / 0.491 ms (**2,060.8 FPS**) | FAIL (`v128` validation)* | 0.484 ms / 0.489 ms (2,071.4 FPS) | `8133605907336869050` |

#### `ReleaseFast` (Baseline Wasm CPU without `+simd128`)

| Workload | `wazig v0.17.1-wazig.1` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.1 -fno-llvm` | `zig v0.17.1 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | **0.089 ms** / 0.093 ms (**11,193.2 FPS**) | **0.104 ms** / 0.109 ms (**9,529.6 FPS**) | 0.263 ms / 0.269 ms (3,787.2 FPS) | 0.104 ms / 0.108 ms (9,534.4 FPS) | `417689973924794692` |
| **2. OpenType Shaper + Slug Curve Prep (`text_bench`)** | **0.465 ms** / 0.470 ms (**2,146.7 FPS**) | **0.469 ms** / 0.474 ms (**2,130.3 FPS**) | 1.719 ms / 1.728 ms (583.4 FPS) | 0.469 ms / 0.474 ms (2,129.8 FPS) | `17060092853839522222` / `12180320639109031162` |
| **3. Render Command & Batch Gen (`render_bench`)** | **0.122 ms** / 0.134 ms (**8,086.8 FPS**) | **0.084 ms** / 0.097 ms (**11,675.2 FPS**) | 0.466 ms / 0.476 ms (2,145.6 FPS) | 0.084 ms / 0.094 ms (11,811.4 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | **0.409 ms** / 0.421 ms (**2,425.2 FPS**) | **0.303 ms** / 0.315 ms (**3,275.4 FPS**) | 1.617 ms / 1.628 ms (618.0 FPS) | 0.298 ms / 0.311 ms (3,314.4 FPS) | `8133605907336869050` |

**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**
- **`wazig v0.17.1-wazig.1` (`-fno-llvm`, `ReleaseFast +simd128`) beats both `zig v0.17.1 -fllvm` and `wazigl v0.17.0-wazigl.6` overall (`214.62 ms` vs `231.13 ms` / `230.27 ms`) and wins 3 of 4 workloads:** With `cataggar/zig#189`–`#238` and `cataggar/knots#11`–`#36`, `0.17.1-wazig.1` reaches **`11,170.3 FPS` (`0.089 ms`)** on `layout_bench` (+13.7% faster than `9,827.3 FPS` in `zig 0.17.1 -fllvm`), **`2,167.1 FPS` (`0.461 ms`)** on `text_bench` (+8.3% faster than `2,000.9 FPS`), **`2,539.4 FPS` (`0.391 ms`)** on `combined_frame` (+22.6% faster than `2,071.4 FPS`), and **`10,438.4 FPS` (`0.095 ms`)** on `render_bench` — while compiling in a **2.62x smaller** `.wasm` binary (`1,721.8 KB` vs `4,507.5 KB`).
- **`wazig v0.17.1-wazig.1` vs `wazig v0.17.0-wazig.6` (Same `knots` Source)**: On identical `knots` source, `0.17.1-wazig.1` improves `Debug` (`409.15 ms` vs `429.85 ms`, `-41.6 KB`), `ReleaseSmall` (`266.08 ms` vs `282.75 ms`, `-29.7 KB`, beating LLVM 22 on both `layout_bench` and `text_bench`), and `ReleaseFast +simd128` (`214.62 ms` vs `216.84 ms`, `-31.6 KB`).
- **`wazig v0.17.1-wazig.1` (`-fno-llvm`) vs `zig v0.17.1 -fno-llvm`**: `0.17.1-wazig.1` is **2.95x–4.87x faster** than upstream `zig 0.17.1 -fno-llvm` on the exact same `knots` source (`11,170.3 FPS` vs `3,787.2 FPS` on `layout_bench`, `2,167.1 FPS` vs `583.4 FPS` on `text_bench`, `10,438.4 FPS` vs `2,145.6 FPS` on `render_bench`, and `2,539.4 FPS` vs `618.0 FPS` on `combined_frame`), and **8.35x–17.59x faster** than `wazig v0.17.0-wazig.3`.

### D.3 `wasm_bench_runner.wasm` — `Debug`

| Workload | Iterations | Elements/Iter | `wazig v0.17.1-wazig.1` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.6` (`-fllvm`) | `zig v0.17.1 -fno-llvm` | `zig v0.17.1 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **1. Dashboard Flexbox Layout (`layout_bench`)** | 300 | 2,047 | **0.230 ms** / 0.235 ms (**4,332.8 FPS**) | 0.613 ms / 0.619 ms (1,631.0 FPS) | 0.660 ms / 0.665 ms (1,515.6 FPS) | 0.611 ms / 0.617 ms (1,636.3 FPS) | `417689973924794692` |
| **2. OpenType Shaper + Slug Curve Prep (`text_bench`)** | 200 | 3,413 | **0.827 ms** / 0.833 ms (**1,211.1 FPS**) | 1.760 ms / 1.771 ms (569.4 FPS) | 2.599 ms / 2.616 ms (385.5 FPS) | 1.760 ms / 1.803 ms (568.5 FPS) | `17060092853839522222` / `12180320639109031162` |
| **3. Render Command & Batch Gen (`render_bench`)** | 300 | 5,100 | **0.187 ms** / 0.202 ms (**5,250.9 FPS**) | 0.457 ms / 0.470 ms (2,167.2 FPS) | 0.642 ms / 0.650 ms (1,564.2 FPS) | 0.459 ms / 0.476 ms (2,160.0 FPS) | `8226312248921777708` |
| **4. Combined Full UI Frame (`combined_frame`)** | 100 | 514 | **0.661 ms** / 0.672 ms (**1,514.6 FPS**) | 1.935 ms / 1.943 ms (516.7 FPS) | 2.083 ms / 2.093 ms (479.9 FPS) | 1.935 ms / 2.065 ms (513.2 FPS) | `8133605907336869050` |

**`Debug` Runtime Highlight:** In `Debug` builds, `wazig v0.17.1-wazig.1` (`-fno-llvm`) is **2.13x–2.95x faster at runtime than both `wazigl v0.17.0-wazigl.6` and `zig v0.17.1 -fllvm` (LLVM 22)** across all four workloads (`4,332.8 FPS` vs `1,631.0` / `1,636.3 FPS` on `layout_bench`, `1,211.1 FPS` vs `569.4` / `568.5 FPS` on `text_bench`, `5,250.9 FPS` vs `2,167.2` / `2,160.0 FPS` on `render_bench`, and `1,514.6 FPS` vs `516.7` / `513.2 FPS` on `combined_frame`) while producing **2.75x smaller** `.wasm` binaries (`1,959.9 KB` vs `5,396.0 KB`).

### D.4 Full `wasm32-wasi` Test Suite Execution (`19 test binaries` under `wasmtime run`)

| Compiler | Test Binaries Passed | Total Test `.wasm` Size (Raw / Zstd) | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |
| :--- | :---: | ---: | ---: | ---: |
| **`wazig v0.17.1-wazig.1` (`-fno-llvm`)** | **19 / 19** (with `+atomics` + `+simd128`) | **14,470.4 KB** / **3,743.8 KB** | **4.676 s** | **2.45x faster** |
| **`wazigl v0.17.0-wazigl.6` (`-fllvm`)** | **19 / 19** (with `+atomics` + `+simd128`) | 51,334.7 KB / 12,709.7 KB | **11.465 s** | 1.00x |
| **`zig v0.17.1 -fno-llvm`** | 0 / 19 with `+atomics`/`+simd128`* | 11,082.7 KB / 2,588.1 KB | 0.309 s | — |
| **`zig v0.17.1 -fllvm`** | 19 / 19 (with `+atomics` + `+simd128`) | 51,334.7 KB / 12,709.7 KB | 11.465 s | 1.00x (baseline) |

> *\*Upstream `zig 0.17.1 -fno-llvm` emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, emits invalid `v128` Wasm instructions (`type mismatch: expected v128, found i32` failing Wasmtime validation) when `+simd128` is enabled (so non-SIMD `zig -fno-llvm` rows above are measured with `+simd128` and `+atomics` stripped), and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig v0.17.1-wazig.1` fixes all three bugs.*

---

## E. Guest Profiling Verification (`wasmtime-profile.py` @ `100us`)

### E.1 Verified Impact of `cataggar/zig#158`–`#238` & `cataggar/knots#11`–`#36`

Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that after merging upstream `knots-ui/knots` `main` (in-tree OpenType/CFF parser, UAX#14/UAX#29 Unicode tables, OpenType shaper, and `TextSystem`/`GlyphStore`) and applying `cataggar/zig#229`–`#238` + post-merge `knots` optimizations, CPU samples dropped from `3,016` (initial post-merge) to **`1,745` (`ReleaseFast +simd128`)** in **`wazig v0.17.1-wazig.1`**:

| Workload | `wazig.3` (`ReleaseSmall`) | `0.17.1-wazig.1` (`ReleaseSmall`) | `0.17.1-wazig.1` (`ReleaseFast +simd128`) | `zig 0.17.1 -fllvm` (`ReleaseFast +simd128`) | `0.17.1-wazig.1` vs `zig 0.17.1 -fllvm` |
| :--- | ---: | ---: | ---: | ---: | :--- |
| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.107 ms (9,335.6 FPS) | **0.089 ms (11,170.3 FPS)** | 0.101 ms (9,827.3 FPS) | **`wazig` +13.7% faster** |
| **`text_bench`** | 5.505 ms (181.7 FPS) | 0.535 ms (1,869.6 FPS) | **0.461 ms (2,167.1 FPS)** | 0.500 ms (2,000.9 FPS) | **`wazig` +8.3% faster** |
| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.147 ms (6,715.3 FPS) | **0.095 ms (10,438.4 FPS)** | **0.078 ms (12,628.1 FPS)** | `zig -fllvm` +21.0% faster |
| **`combined_frame`** | 3.286 ms (304.2 FPS) | 0.486 ms (2,060.8 FPS) | **0.391 ms (2,539.4 FPS)** | 0.484 ms (2,071.4 FPS) | **`wazig` +22.6% faster** |

- **[`cataggar/zig#229`](https://github.com/cataggar/zig/issues/229)–[`#237`](https://github.com/cataggar/zig/pull/237) (`0.17.1` merge `#236` + multivalue ABI, tail calls, `f16` promotion, wide arithmetic, SIMD & rotate synthesis)**: Merged Zig `0.17.1`, promoted `f16` values (`SlugInstance.col`) to native `f32` registers, added `return_call`/`return_call_indirect`, `.wasm_multivalue` up to 8 scalars, `v128.andnot`, and `i32`/`i64` rotate synthesis.
- **[`cataggar/zig#238`](https://github.com/cataggar/zig/pull/238) (`0.17.1-wazig.1`) — Inline `@byteSwap` (`i32.rotl`), SIMD `cmp_vector` -> `v128.bitselect`, reused-local backward DSE, and 8-result multivalue inlining**: Eliminated out-of-line `__bswapsi2`/`__bswapdi2` calls on OpenType big-endian reads, eliminated `[N]bool` shadow-stack spills on `@select` vector masks, removed dead reused-local overwrites across basic blocks (shrinking `wazig.wasm` itself by `-105.5 KB` and `knots ReleaseSmall` by `-29.7 KB`), and inlined 1-call capacity wrappers.
- **Post-`main` `knots` OpenType / `TextSystem` / `GlyphStore` Optimizations**: Added 8-byte SWAR ASCII fast paths in `unicode.decodeUtf8`, single-pass `.latn` itemization in `itemize.itemizeWith`, unwrapped single-line fast path & comptime ASCII class table in `unicode.linebreak`, dense `Face.glyph_slots` O(1) lookup replacing `AutoHashMapUnmanaged`, persistent `TextSystem` layout/outline scratch buffers + single-slab `TextLayout` allocation, direct `GlyphStore.words` encoding with reciprocal quantization, cached `Decoration.Text` frame layouts + hoisted `f16` color conversion in `paintText`, and reciprocal `DrawList.gridCoord` scaling (`365.18 ms` -> **`214.62 ms`** total suite time).

### E.2 Top 15 Functions in `wazig v0.17.1-wazig.1` `ReleaseFast +simd128` (`1,745` total samples @ 100us)

| Self | Self% | Total | Tot% | Bytes | Function |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 344 | 19.71% | 344 | 19.71% | 7,567 | `band.partitionWithBuffer` |
| 128 | 7.34% | 144 | 8.25% | 8,413 | `DrawList.emitBatched` |
| 127 | 7.28% | 471 | 26.99% | 6,054 | `GlyphStore.encodeInto` |
| 101 | 5.79% | 262 | 15.01% | 3,825 | `wasm_bench_runner.buildRenderFrame` |
| 83 | 4.76% | 232 | 13.30% | 6,995 | `wasm_bench_runner.buildDashboardLayoutFrame` |
| 80 | 4.58% | 81 | 4.64% | 7,389 | `Context.computeLayoutNode` |
| 53 | 3.04% | 54 | 3.09% | 2,347 | `Context.open` |
| 51 | 2.92% | 63 | 3.61% | 2,239 | `linebreak.opportunities` |
| 43 | 2.46% | 63 | 3.61% | 4,350 | `Outline.appendSimple` |
| 34 | 1.95% | 35 | 2.01% | 798 | `TextSystem.LayoutBuilder.appendShaped` |
| 33 | 1.89% | 37 | 2.12% | 1,165 | `TextSystem.LayoutBuilder.nextBreak` |
| 29 | 1.66% | 63 | 3.61% | 5,191 | `Context.paintText` |
| 29 | 1.66% | 39 | 2.23% | 1,027 | `DrawList.pushInstances` |
| 29 | 1.66% | 29 | 1.66% | 1,948 | `Context.computeSizes` |
| 18 | 1.03% | 23 | 1.32% | 1,201 | `DrawList.push` |

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
- **[`cataggar/zig#229`](https://github.com/cataggar/zig/issues/229)–[`#237`](https://github.com/cataggar/zig/pull/237)** (landed in `0.17.1-wazig.1`): `wasm: multivalue ABI up to 8 scalars, tail calls, f16 promotion, wide arithmetic, SIMD, and shift/rotate opts`.
- **[`cataggar/zig#238`](https://github.com/cataggar/zig/pull/238)** (landed in `0.17.1-wazig.1`): `wasm: inline @byteSwap, SIMD cmp->bitselect, reused-local DSE, and multivalue inlining`.

---

## F. wasm32-freestanding vs wasm64-freestanding (Memory64) Head-to-Head

Head-to-head comparison of `wasm32-freestanding` (32-bit pointers, 4 GiB linear address space) vs `wasm64-freestanding` (64-bit pointers, >4 GiB Memory64 linear address space, [`cataggar/knots#18`](https://github.com/cataggar/knots/issues/18)) across `Debug`, `ReleaseSmall`, and `ReleaseFast (+simd128)` (`-Dcpu=generic+simd128`) using **`wazig v0.17.1-wazig.1` (`-fno-llvm`)** and **`wazigl v0.17.0-wazigl.6` / `zig 0.17.1 -fllvm` (`-fllvm`)**, executed under `wasmtime v50.0.1` (`wasmtime run -W memory64=y`).

### F.1 Playground (`examples/playground`) — Compile Time & `.wasm` Binary Size

| Compiler & Mode | Target | Cold Compile | Warm Compile (Median of 3) | Raw `.wasm` Size | `gzip -9` Size | `zstd -19` Size | `wasm64` vs `wasm32` Size Delta (Raw / `gzip` / `zstd`) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `Debug`** | `wasm32-freestanding` | 32.03 s | 25.13 s | 3,777,921 B (3,689.4 KB) | 1,233,333 B (1,204.4 KB) | **927,626 B (905.9 KB)** | — |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `Debug`** | `wasm64-freestanding` | 32.06 s | 24.93 s | 4,381,112 B (4,278.4 KB) | 1,293,031 B (1,262.7 KB) | **950,620 B (928.3 KB)** | **+16.0% / +4.8% / +2.5%** |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 26.60 s | 19.67 s | 2,948,977 B (2,879.9 KB) | 1,012,687 B (989.0 KB) | **790,243 B (771.7 KB)** | — |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 26.27 s | 19.24 s | 3,452,437 B (3,371.5 KB) | 1,045,224 B (1,020.7 KB) | **822,375 B (803.1 KB)** | **+17.1% / +3.2% / +4.1%** |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 30.40 s | 23.17 s | 3,426,196 B (3,345.9 KB) | 1,183,542 B (1,155.8 KB) | **913,413 B (892.0 KB)** | — |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 29.89 s | 22.58 s | 3,978,600 B (3,885.4 KB) | 1,255,954 B (1,226.5 KB) | **961,038 B (938.5 KB)** | **+16.1% / +6.1% / +5.2%** |
| **`0.17.0-wazigl.6` (`-fllvm`) — `Debug`** | `wasm32-freestanding` | 47.41 s | 33.20 s | 8,870,375 B (8,662.5 KB) | 2,935,259 B (2,866.5 KB) | **2,168,143 B (2,117.3 KB)** | — |
| **`0.17.0-wazigl.6` (`-fllvm`) — `Debug`** | `wasm64-freestanding` | 45.91 s | 35.01 s | 9,853,696 B (9,622.8 KB) | 3,026,960 B (2,956.0 KB) | **2,218,260 B (2,166.3 KB)** | **+11.1% / +3.1% / +2.3%** |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 44.06 s | 34.82 s | 2,271,537 B (2,218.3 KB) | 860,043 B (839.9 KB) | **721,389 B (704.5 KB)** | — |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 43.49 s | 35.25 s | 2,729,928 B (2,665.9 KB) | 881,290 B (860.6 KB) | **733,278 B (716.1 KB)** | **+20.2% / +2.5% / +1.6%** |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 80.77 s | 64.53 s | 7,614,997 B (7,436.5 KB) | 2,452,526 B (2,395.0 KB) | **1,999,598 B (1,952.7 KB)** | — |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 79.70 s | 64.44 s | 9,380,711 B (9,160.9 KB) | 2,527,205 B (2,468.0 KB) | **2,044,840 B (1,996.9 KB)** | **+23.2% / +3.0% / +2.3%** |

### F.2 Headless Benchmark Runner (`knots-wasm-bench`) — Compile Time & `.wasm` Binary Size

| Compiler & Mode | Target | Cold Compile | Warm Compile (Median of 3) | Raw `.wasm` Size | `gzip -9` Size | `zstd -19` Size | `wasm64` vs `wasm32` Size Delta (Raw / `gzip` / `zstd`) |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `Debug`** | `wasm32-freestanding` | 19.45 s | 12.40 s | 1,902,132 B (1,857.6 KB) | 673,715 B (657.9 KB) | **539,279 B (526.6 KB)** | — |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `Debug`** | `wasm64-freestanding` | 19.09 s | 12.28 s | 2,013,332 B (1,966.1 KB) | 703,617 B (687.1 KB) | **553,865 B (540.9 KB)** | **+5.8% / +4.4% / +2.7%** |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 15.33 s | 8.58 s | 1,396,718 B (1,364.0 KB) | 524,376 B (512.1 KB) | **435,681 B (425.5 KB)** | — |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 14.99 s | 8.17 s | 1,439,285 B (1,405.6 KB) | 534,765 B (522.2 KB) | **442,381 B (432.0 KB)** | **+3.0% / +2.0% / +1.5%** |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 17.32 s | 10.45 s | 1,673,579 B (1,634.4 KB) | 627,367 B (612.7 KB) | **511,631 B (499.6 KB)** | — |
| **`0.17.1-wazig.1` (`-fno-llvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 17.18 s | 10.38 s | 1,737,666 B (1,696.9 KB) | 660,263 B (644.8 KB) | **527,041 B (514.7 KB)** | **+3.8% / +5.2% / +3.0%** |
| **`0.17.0-wazigl.6` (`-fllvm`) — `Debug`** | `wasm32-freestanding` | 25.32 s | 13.44 s | 4,940,630 B (4,824.8 KB) | 1,669,518 B (1,630.4 KB) | **1,298,950 B (1,268.5 KB)** | — |
| **`0.17.0-wazigl.6` (`-fllvm`) — `Debug`** | `wasm64-freestanding` | 25.28 s | 13.40 s | 5,325,725 B (5,200.9 KB) | 1,715,823 B (1,675.6 KB) | **1,324,218 B (1,293.2 KB)** | **+7.8% / +2.8% / +1.9%** |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm32-freestanding` | 20.91 s | 11.65 s | 1,013,559 B (989.8 KB) | 438,542 B (428.3 KB) | **386,038 B (377.0 KB)** | — |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseSmall`** | `wasm64-freestanding` | 21.49 s | 12.02 s | 1,037,714 B (1,013.4 KB) | 445,135 B (434.7 KB) | **391,196 B (382.0 KB)** | **+2.4% / +1.5% / +1.3%** |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm32-freestanding` | 35.67 s | 21.01 s | 4,359,510 B (4,257.3 KB) | 1,451,285 B (1,417.3 KB) | **1,219,129 B (1,190.6 KB)** | — |
| **`0.17.0-wazigl.6` (`-fllvm`) — `ReleaseFast (+simd128)`** | `wasm64-freestanding` | 35.43 s | 20.70 s | 5,212,977 B (5,090.8 KB) | 1,489,554 B (1,454.6 KB) | **1,242,310 B (1,213.2 KB)** | **+19.6% / +2.6% / +1.9%** |

### F.3 Runtime Execution Performance (`wasmtime run -W memory64=y <knots-wasm-bench.wasm> --json`)

> **Checksum Verification**: Every `wasm32-freestanding` and `wasm64-freestanding` run produces bit-identical output checksums across all optimization modes (`total_checksum = 135070606785217583` under `wazig -fno-llvm` and `total_checksum = 6654160893120457825` under `-fllvm`).

#### `wazig v0.17.1-wazig.1` (`-fno-llvm`, Self-Hosted Wasm Backend)

| Optimize Mode | Workload | `wasm32-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64` vs `wasm32` Latency / Throughput | Checksum |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`Debug`** | `layout_bench` (300 iters, 2,047 elems) | **0.226 ms** / 0.227 ms / 0.232 ms (**4,402.2 FPS**) | **0.397 ms** / 0.398 ms / 0.401 ms (**2,515.6 FPS**) | +75.8% ms / 0.57x FPS | `417689973924794692` |
| **`Debug`** | `text_bench` (200 iters, 3,413 elems) | **0.824 ms** / 0.822 ms / 0.828 ms (**1,216.6 FPS**) | **1.092 ms** / 1.091 ms / 1.100 ms (**916.3 FPS**) | +32.6% ms / 0.75x FPS | `17060092853839522222` |
| **`Debug`** | `render_bench` (300 iters, 5,100 elems) | **0.183 ms** / 0.185 ms / 0.196 ms (**5,390.2 FPS**) | **0.293 ms** / 0.297 ms / 0.305 ms (**3,368.5 FPS**) | +60.2% ms / 0.62x FPS | `8226312248921777708` |
| **`Debug`** | `combined_frame` (100 iters, 514 elems) | **0.657 ms** / 0.655 ms / 0.661 ms (**1,526.5 FPS**) | **0.988 ms** / 0.989 ms / 0.997 ms (**1,011.1 FPS**) | +50.4% ms / 0.66x FPS | `8133605907336869050` |
| **`Debug`** | **`total_bench_ms`** | **405.00 ms** | **601.65 ms** | **+48.6% ms / 0.67x** | `135070606785217583` |
| **`ReleaseSmall`** | `layout_bench` (300 iters, 2,047 elems) | **0.107 ms** / 0.108 ms / 0.112 ms (**9,261.9 FPS**) | **0.176 ms** / 0.176 ms / 0.180 ms (**5,675.3 FPS**) | +63.8% ms / 0.61x FPS | `417689973924794692` |
| **`ReleaseSmall`** | `text_bench` (200 iters, 3,413 elems) | **0.535 ms** / 0.536 ms / 0.541 ms (**1,867.0 FPS**) | **0.725 ms** / 0.726 ms / 0.731 ms (**1,378.3 FPS**) | +35.5% ms / 0.74x FPS | `17060092853839522222` |
| **`ReleaseSmall`** | `render_bench` (300 iters, 5,100 elems) | **0.144 ms** / 0.145 ms / 0.155 ms (**6,876.9 FPS**) | **0.212 ms** / 0.215 ms / 0.224 ms (**4,660.0 FPS**) | +47.5% ms / 0.68x FPS | `8226312248921777708` |
| **`ReleaseSmall`** | `combined_frame` (100 iters, 514 elems) | **0.490 ms** / 0.489 ms / 0.499 ms (**2,044.7 FPS**) | **0.714 ms** / 0.713 ms / 0.723 ms (**1,401.7 FPS**) | +45.7% ms / 0.69x FPS | `8133605907336869050` |
| **`ReleaseSmall`** | **`total_bench_ms`** | **265.75 ms** | **381.63 ms** | **+43.6% ms / 0.70x** | `135070606785217583` |
| **`ReleaseFast (+simd128)`** | `layout_bench` (300 iters, 2,047 elems) | **0.088 ms** / 0.088 ms / 0.092 ms (**11,317.6 FPS**) | **0.150 ms** / 0.150 ms / 0.153 ms (**6,645.1 FPS**) | +70.5% ms / 0.59x FPS | `417689973924794692` |
| **`ReleaseFast (+simd128)`** | `text_bench` (200 iters, 3,413 elems) | **0.459 ms** / 0.460 ms / 0.464 ms (**2,175.6 FPS**) | **0.663 ms** / 0.663 ms / 0.668 ms (**1,507.1 FPS**) | +44.4% ms / 0.69x FPS | `17060092853839522222` |
| **`ReleaseFast (+simd128)`** | `render_bench` (300 iters, 5,100 elems) | **0.095 ms** / 0.096 ms / 0.105 ms (**10,448.9 FPS**) | **0.150 ms** / 0.152 ms / 0.163 ms (**6,557.0 FPS**) | +59.2% ms / 0.63x FPS | `8226312248921777708` |
| **`ReleaseFast (+simd128)`** | `combined_frame` (100 iters, 514 elems) | **0.387 ms** / 0.389 ms / 0.400 ms (**2,568.1 FPS**) | **0.649 ms** / 0.647 ms / 0.653 ms (**1,545.8 FPS**) | +67.6% ms / 0.60x FPS | `8133605907336869050` |
| **`ReleaseFast (+simd128)`** | **`total_bench_ms`** | **213.06 ms** | **329.96 ms** | **+54.9% ms / 0.65x** | `135070606785217583` |

#### `wazigl v0.17.0-wazigl.6` (`-fllvm`, LLVM 22 Backend)

| Optimize Mode | Workload | `wasm32-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64-freestanding` (Median / Mean / p95 ms — FPS) | `wasm64` vs `wasm32` Latency / Throughput | Checksum |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`Debug`** | `layout_bench` (300 iters, 2,047 elems) | **0.630 ms** / 0.629 ms / 0.633 ms (**1,590.0 FPS**) | **0.895 ms** / 0.896 ms / 0.899 ms (**1,116.5 FPS**) | +42.1% ms / 0.70x FPS | `417689973924794692` |
| **`Debug`** | `text_bench` (200 iters, 3,413 elems) | **1.752 ms** / 1.748 ms / 1.762 ms (**572.1 FPS**) | **2.328 ms** / 2.324 ms / 2.343 ms (**430.3 FPS**) | +32.9% ms / 0.75x FPS | `12180320639109031162` |
| **`Debug`** | `render_bench` (300 iters, 5,100 elems) | **0.454 ms** / 0.458 ms / 0.468 ms (**2,182.5 FPS**) | **0.675 ms** / 0.672 ms / 0.683 ms (**1,488.0 FPS**) | +48.5% ms / 0.68x FPS | `8226312248921777708` |
| **`Debug`** | `combined_frame` (100 iters, 514 elems) | **1.927 ms** / 1.929 ms / 1.940 ms (**518.5 FPS**) | **2.452 ms** / 2.453 ms / 2.465 ms (**407.7 FPS**) | +27.3% ms / 0.79x FPS | `8133605907336869050` |
| **`Debug`** | **`total_bench_ms`** | **998.01 ms** | **1,354.70 ms** | **+35.7% ms / 0.74x** | `6654160893120457825` |
| **`ReleaseSmall`** | `layout_bench` (300 iters, 2,047 elems) | **0.107 ms** / 0.108 ms / 0.112 ms (**9,254.3 FPS**) | **0.165 ms** / 0.166 ms / 0.170 ms (**6,020.0 FPS**) | +53.9% ms / 0.65x FPS | `417689973924794692` |
| **`ReleaseSmall`** | `text_bench` (200 iters, 3,413 elems) | **0.566 ms** / 0.567 ms / 0.571 ms (**1,764.8 FPS**) | **0.700 ms** / 0.700 ms / 0.705 ms (**1,429.3 FPS**) | +23.5% ms / 0.81x FPS | `12180320639109031162` |
| **`ReleaseSmall`** | `render_bench` (300 iters, 5,100 elems) | **0.091 ms** / 0.093 ms / 0.105 ms (**10,793.4 FPS**) | **0.137 ms** / 0.139 ms / 0.149 ms (**7,217.0 FPS**) | +50.1% ms / 0.67x FPS | `8226312248921777708` |
| **`ReleaseSmall`** | `combined_frame` (100 iters, 514 elems) | **0.457 ms** / 0.460 ms / 0.467 ms (**2,175.4 FPS**) | **0.654 ms** / 0.652 ms / 0.661 ms (**1,533.4 FPS**) | +43.2% ms / 0.70x FPS | `8133605907336869050` |
| **`ReleaseSmall`** | **`total_bench_ms`** | **251.55 ms** | **339.71 ms** | **+35.0% ms / 0.74x** | `6654160893120457825` |
| **`ReleaseFast (+simd128)`** | `layout_bench` (300 iters, 2,047 elems) | **0.101 ms** / 0.102 ms / 0.106 ms (**9,830.4 FPS**) | **0.143 ms** / 0.144 ms / 0.149 ms (**6,946.6 FPS**) | +41.4% ms / 0.71x FPS | `417689973924794692` |
| **`ReleaseFast (+simd128)`** | `text_bench` (200 iters, 3,413 elems) | **0.502 ms** / 0.502 ms / 0.507 ms (**1,990.9 FPS**) | **0.617 ms** / 0.617 ms / 0.623 ms (**1,620.8 FPS**) | +23.0% ms / 0.81x FPS | `12180320639109031162` |
| **`ReleaseFast (+simd128)`** | `render_bench` (300 iters, 5,100 elems) | **0.077 ms** / 0.078 ms / 0.086 ms (**12,832.0 FPS**) | **0.111 ms** / 0.112 ms / 0.121 ms (**8,899.5 FPS**) | +44.2% ms / 0.69x FPS | `8226312248921777708` |
| **`ReleaseFast (+simd128)`** | `combined_frame` (100 iters, 514 elems) | **0.480 ms** / 0.481 ms / 0.486 ms (**2,080.3 FPS**) | **0.620 ms** / 0.619 ms / 0.630 ms (**1,616.3 FPS**) | +29.1% ms / 0.78x FPS | `8133605907336869050` |
| **`ReleaseFast (+simd128)`** | **`total_bench_ms`** | **230.96 ms** | **298.90 ms** | **+29.4% ms / 0.77x** | `6654160893120457825` |

### F.4 Key Takeaways on `wasm64-freestanding` (Memory64) vs `wasm32-freestanding` Tradeoffs

1. **Zero Compile-Time Penalty**: Compiling for `wasm64-freestanding` takes virtually the exact same time as `wasm32-freestanding` across both `wazig.6` (`8.17s` vs `8.58s` warm on `knots-wasm-bench ReleaseSmall`, `19.24s` vs `19.67s` warm on `playground ReleaseSmall`) and `wazigl.6` (`12.02s` vs `11.65s` warm on `knots-wasm-bench ReleaseSmall`, `35.25s` vs `34.82s` warm on `playground ReleaseSmall`).
2. **Negligible Compressed Binary Size Overhead (`+0.3%` to `+7.2%` `zstd -19`)**:
   - On `knots-wasm-bench`, `wasm64-freestanding` adds only **`+1.5%`–`+2.0%` raw** (`+0.3%`–`+0.6%` `zstd -19`) in `ReleaseSmall` (`432.0 KB` vs `425.5 KB` zstd under `wazig.6`; `382.0 KB` vs `377.0 KB` zstd under `wazigl.6`).
   - On `examples/playground` (which embeds static UI/font tables and pointer-rich descriptors), 64-bit pointers and LEB128 `i64` address offsets increase raw `.wasm` size by `+17.9%`–`+19.8%` under `wazig.6` and `+11.8%`–`+23.7%` under `wazigl.6`, but the extra upper-zero bytes in 64-bit pointers compress away almost completely under `zstd -19` (**`+1.6%`–`+2.8%` in `ReleaseSmall`**, e.g. `716.1 KB` vs `704.5 KB` in `wazigl.6 ReleaseSmall` and `803.1 KB` vs `771.7 KB` in `wazig.6 ReleaseSmall`).
3. **Runtime Performance & Memory64 Bounds-Checking Overhead (`+34.3%` to `+56.7%` total suite time)**:
   - Across `knots-wasm-bench`, `wasm64-freestanding` runs at **0.64x–0.74x** the overall throughput of `wasm32-freestanding` (`total_bench_ms`: `329.96 ms` vs `213.06 ms` in `wazig.6 ReleaseFast +simd128`; `298.90 ms` vs `230.96 ms` in `wazigl.6 ReleaseFast +simd128`), while still exceeding all `cataggar/knots#9` 600–1,800 FPS targets by a wide margin (`6,645.1 FPS` / `6,946.6 FPS` on `layout_bench`, `6,557.0 FPS` / `8,899.5 FPS` on `render_bench`, `1,545.8 FPS` / `1,616.3 FPS` on `combined_frame`).
   - This runtime delta is driven by two fundamental architectural differences in WebAssembly Memory64:
     1. **Explicit Software Bounds Checks vs 4 GiB Virtual Guard Pages**: For `wasm32`, Wasmtime reserves a 4 GiB virtual address region with guard pages so `i32` loads/stores execute without explicit bounds-check branches. For `wasm64` (Memory64), the 64-bit address space cannot be covered by virtual memory guard pages alone, requiring explicit compare-and-branch bounds checks on linear-memory accesses.
     2. **Doubled Pointer & Slice Width (`usize = u64`, `[]T = 16 B` vs `8 B`)**: Pointer-heavy tree/slice traversals (`layout_bench`) experience higher cache-line pressure and 64-bit address arithmetic compared to SIMD/float-heavy batch generation (`render_bench`).
4. **When to Choose `wasm32-freestanding` vs `wasm64-freestanding`**:
   - **`wasm32-freestanding` (Default for Web UI)**: Delivers maximum single-core throughput and smaller uncompressed binaries whenever the workload fits within the 4 GiB address space.
   - **`wasm64-freestanding` (Memory64)**: Unlocks **>4 GiB linear memory** (up to 16 GiB in browsers/Wasmtime) with zero source changes, identical deterministic output, near-zero `zstd` wire-size overhead (`+0.3%`–`+2.8%` in `ReleaseSmall`), and `1,546`–`1,616 FPS` full-frame UI throughput.

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
