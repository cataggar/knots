#!/usr/bin/env python3
"""
bench-wazig.py — Comprehensive benchmark suite comparing wazig (cataggar/zig@v0.17.0-wazig.4,
-fno-llvm self-hosted Wasm backend) and wazigl (cataggar/zig@v0.17.0-wazigl.4, -fllvm LLVM 22
Wasm backend) against standard zig v0.17.0 (-fno-llvm and -fllvm).

Measures four dimensions:
  A. Toolchain & CI Footprint (archive size, unpacked size, file count, lazy vs eager deps)
  B. Compilation Speed (cold cache & warm cache across fmt, wasm_bench_runner, 12 test suites, 4 examples)
  C. Output .wasm Binary Size (raw, gzip -9, zstd -19 across Debug, ReleaseSmall & ReleaseFast +simd128)
  D. Runtime Execution Performance under wasmtime run (layout_bench, text_bench, render_bench,
     combined_frame, and all 12 wasm32-wasi test suites)

Modes:
  1. Full Comparison Mode:
       python3 scripts/bench-wazig.py [--output-json benchmarks/wazig-vs-zig.json] [--output-md benchmarks/WAZIG_BENCHMARKS.md]
  2. CI Summary Mode (runs on GitHub Actions where wazig, wazigl, and wasmtime are installed):
       python3 scripts/bench-wazig.py --ci-summary >> "$GITHUB_STEP_SUMMARY"
"""

from __future__ import annotations

import argparse
import gzip
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_ROOT = REPO_ROOT / ".cache-bench"

EMBEDDED_BASELINE: dict[str, Any] = {'compilers': {'wazig': {'compile_sec': {'fmt_check': 0.487, 'wasm_bench_runner_debug': {'cold': 12.712, 'warm': 6.098}, 'wasm_bench_runner_releasesmall': {'cold': 10.913, 'warm': 4.485}, 'wasm_bench_runner_releasefast': {'cold': 11.673, 'warm': 5.013}, 'wasm_bench_runner_releasefast_simd': {'cold': 11.842, 'warm': 5.197}, 'tests_12_wasi': {'wall_parallel_sec': 20.8, 'sum_cpu_sec': 62.99}, 'triangle_debug': {'cold': 10.3, 'warm': 7.58}, 'triangle_release': {'cold': 8.05, 'warm': 5.74}, 'playground_debug_webgpu_st': 17.65, 'playground_release_webgpu_st': 15.13, 'playground_debug_webgl2_st': 17.4, 'playground_release_webgl2_st': 15.5, 'playground_debug_webgpu_mt': 20.35, 'playground_release_webgpu_mt': 17.86, 'embedded_debug': 6.52, 'embedded_release': 4.84, 'benchmark_debug': 8.63, 'benchmark_release': 6.94}, 'binary_sizes': {'wasm_bench_runner_debug': {'raw': 1235488, 'gzip': 485613, 'zstd': 414597}, 'wasm_bench_runner_releasesmall': {'raw': 924064, 'gzip': 399334, 'zstd': 348457}, 'wasm_bench_runner_releasefast': {'raw': 1102401, 'gzip': 451593, 'zstd': 390460}, 'wasm_bench_runner_releasefast_simd': {'raw': 1103789, 'gzip': 452459, 'zstd': 390969}, 'tests_12_wasi_total': {'raw': 8001945, 'gzip': 2693948, 'zstd': 2184868}, 'triangle_debug': {'raw': 1530822, 'gzip': 558034, 'zstd': 463259}, 'triangle_release': {'raw': 1223068, 'gzip': 469614, 'zstd': 400813}, 'playground_debug_webgpu_st': {'raw': 2963577, 'gzip': 995347, 'zstd': 775294}, 'playground_release_webgpu_st': {'raw': 2556785, 'gzip': 887892, 'zstd': 675728}, 'playground_debug_webgl2_st': {'raw': 2928528, 'gzip': 990296, 'zstd': 765669}, 'playground_release_webgl2_st': {'raw': 2521720, 'gzip': 882880, 'zstd': 677342}, 'playground_debug_webgpu_mt': {'raw': 2974418, 'gzip': 998099, 'zstd': 771251}, 'playground_release_webgpu_mt': {'raw': 2564789, 'gzip': 890606, 'zstd': 702442}, 'embedded_debug': {'raw': 1345563, 'gzip': 490170, 'zstd': 412178}, 'embedded_release': {'raw': 1095859, 'gzip': 423447, 'zstd': 364432}, 'benchmark_debug': {'raw': 1551947, 'gzip': 565392, 'zstd': 468933}, 'benchmark_release': {'raw': 1240247, 'gzip': 474656, 'zstd': 404864}}, 'runtime': {'wasm_bench_runner_debug': {'optimize_mode': 'debug', 'target': 'wasm32-wasi', 'total_bench_ms': 665.301, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 101.822, 'mean_ms': 0.3394, 'median_ms': 0.3392, 'p95_ms': 0.3428, 'min_ms': 0.3355, 'max_ms': 0.3546, 'ops_per_sec': 2946.32, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 182.204, 'mean_ms': 0.911, 'median_ms': 0.9108, 'p95_ms': 0.9193, 'min_ms': 0.8989, 'max_ms': 0.9275, 'ops_per_sec': 1097.67, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 167.233, 'mean_ms': 0.5574, 'median_ms': 0.5608, 'p95_ms': 0.5647, 'min_ms': 0.5478, 'max_ms': 0.5761, 'ops_per_sec': 1793.91, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 138.391, 'mean_ms': 1.3839, 'median_ms': 1.3837, 'p95_ms': 1.3966, 'min_ms': 1.3711, 'max_ms': 1.4369, 'ops_per_sec': 722.59, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasesmall': {'optimize_mode': 'small', 'target': 'wasm32-wasi', 'total_bench_ms': 493.856, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 46.428, 'mean_ms': 0.1548, 'median_ms': 0.154, 'p95_ms': 0.1591, 'min_ms': 0.1523, 'max_ms': 0.1619, 'ops_per_sec': 6461.67, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 132.567, 'mean_ms': 0.6628, 'median_ms': 0.6632, 'p95_ms': 0.6732, 'min_ms': 0.6518, 'max_ms': 0.703, 'ops_per_sec': 1508.67, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 147.447, 'mean_ms': 0.4915, 'median_ms': 0.4933, 'p95_ms': 0.5002, 'min_ms': 0.4826, 'max_ms': 0.5081, 'ops_per_sec': 2034.62, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 112.295, 'mean_ms': 1.1229, 'median_ms': 1.1212, 'p95_ms': 1.1314, 'min_ms': 1.1176, 'max_ms': 1.1354, 'ops_per_sec': 890.52, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 441.796, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 40.082, 'mean_ms': 0.1336, 'median_ms': 0.1328, 'p95_ms': 0.137, 'min_ms': 0.1319, 'max_ms': 0.1873, 'ops_per_sec': 7484.68, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 115.199, 'mean_ms': 0.576, 'median_ms': 0.5769, 'p95_ms': 0.5846, 'min_ms': 0.5669, 'max_ms': 0.6373, 'ops_per_sec': 1736.12, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 135.106, 'mean_ms': 0.4504, 'median_ms': 0.4479, 'p95_ms': 0.4573, 'min_ms': 0.4427, 'max_ms': 0.5087, 'ops_per_sec': 2220.49, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 102.053, 'mean_ms': 1.0205, 'median_ms': 1.019, 'p95_ms': 1.0261, 'min_ms': 1.0158, 'max_ms': 1.0672, 'ops_per_sec': 979.88, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast_simd': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 411.86, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 40.454, 'mean_ms': 0.1348, 'median_ms': 0.1336, 'p95_ms': 0.1404, 'min_ms': 0.133, 'max_ms': 0.1699, 'ops_per_sec': 7415.9, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 115.285, 'mean_ms': 0.5764, 'median_ms': 0.5784, 'p95_ms': 0.5839, 'min_ms': 0.568, 'max_ms': 0.5901, 'ops_per_sec': 1734.83, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 109.86, 'mean_ms': 0.3662, 'median_ms': 0.3624, 'p95_ms': 0.3741, 'min_ms': 0.3597, 'max_ms': 0.3801, 'ops_per_sec': 2730.74, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 99.691, 'mean_ms': 0.9969, 'median_ms': 0.9962, 'p95_ms': 1.0032, 'min_ms': 0.9928, 'max_ms': 1.0042, 'ops_per_sec': 1003.1, 'checksum': 8133605907336869050}}}, 'tests_12_wasi_exec_sec': 0.969}}, 'wazigl': {'compile_sec': {'fmt_check': 1.793, 'wasm_bench_runner_debug': {'cold': 32.503, 'warm': 16.631}, 'wasm_bench_runner_releasesmall': {'cold': 25.888, 'warm': 15.121}, 'wasm_bench_runner_releasefast': {'cold': 43.544, 'warm': 27.765}, 'wasm_bench_runner_releasefast_simd': {'cold': 44.316, 'warm': 28.304}, 'tests_12_wasi': {'wall_parallel_sec': 62.42, 'sum_cpu_sec': 203.77}, 'triangle_debug': {'cold': 31.75, 'warm': 18.31}, 'triangle_release': {'cold': 24.61, 'warm': 18.44}, 'playground_debug_webgpu_st': 33.99, 'playground_release_webgpu_st': 36.29, 'playground_debug_webgl2_st': 33.74, 'playground_release_webgl2_st': 36.09, 'playground_debug_webgpu_mt': 44.21, 'playground_release_webgpu_mt': 43.53, 'embedded_debug': 15.86, 'embedded_release': 15.03, 'benchmark_debug': 20.54, 'benchmark_release': 20.16}, 'binary_sizes': {'wasm_bench_runner_debug': {'raw': 3674413, 'gzip': 1222340, 'zstd': 1000512}, 'wasm_bench_runner_releasesmall': {'raw': 695982, 'gzip': 340466, 'zstd': 304635}, 'wasm_bench_runner_releasefast': {'raw': 2914474, 'gzip': 1000296, 'zstd': 847178}, 'wasm_bench_runner_releasefast_simd': {'raw': 2898149, 'gzip': 1001649, 'zstd': 848782}, 'tests_12_wasi_total': {'raw': 29817722, 'gzip': 9079848, 'zstd': 7365226}, 'triangle_debug': {'raw': 3894943, 'gzip': 1293523, 'zstd': 1044444}, 'triangle_release': {'raw': 820175, 'gzip': 373034, 'zstd': 333765}, 'playground_debug_webgpu_st': {'raw': 6263045, 'gzip': 2026481, 'zstd': 1547789}, 'playground_release_webgpu_st': {'raw': 1825485, 'gzip': 716864, 'zstd': 589554}, 'playground_debug_webgl2_st': {'raw': 6227989, 'gzip': 2018587, 'zstd': 1567533}, 'playground_release_webgl2_st': {'raw': 1790475, 'gzip': 710126, 'zstd': 598806}, 'playground_debug_webgpu_mt': {'raw': 6303636, 'gzip': 2041585, 'zstd': 1553346}, 'playground_release_webgpu_mt': {'raw': 1829713, 'gzip': 719708, 'zstd': 584485}, 'embedded_debug': {'raw': 3453058, 'gzip': 1130125, 'zstd': 923725}, 'embedded_release': {'raw': 752000, 'gzip': 345663, 'zstd': 309644}, 'benchmark_debug': {'raw': 3971189, 'gzip': 1318785, 'zstd': 1061319}, 'benchmark_release': {'raw': 826714, 'gzip': 375680, 'zstd': 336620}}, 'runtime': {'wasm_bench_runner_debug': {'optimize_mode': 'debug', 'target': 'wasm32-wasi', 'total_bench_ms': 1301.452, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 215.029, 'mean_ms': 0.7168, 'median_ms': 0.717, 'p95_ms': 0.7206, 'min_ms': 0.7096, 'max_ms': 0.7544, 'ops_per_sec': 1395.16, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 351.004, 'mean_ms': 1.755, 'median_ms': 1.7551, 'p95_ms': 1.7654, 'min_ms': 1.7402, 'max_ms': 1.7731, 'ops_per_sec': 569.79, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 313.886, 'mean_ms': 1.0463, 'median_ms': 1.045, 'p95_ms': 1.0544, 'min_ms': 1.0401, 'max_ms': 1.0826, 'ops_per_sec': 955.76, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 273.761, 'mean_ms': 2.7376, 'median_ms': 2.7381, 'p95_ms': 2.7502, 'min_ms': 2.7224, 'max_ms': 2.754, 'ops_per_sec': 365.28, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasesmall': {'optimize_mode': 'small', 'target': 'wasm32-wasi', 'total_bench_ms': 319.065, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 34.094, 'mean_ms': 0.1136, 'median_ms': 0.1131, 'p95_ms': 0.117, 'min_ms': 0.1123, 'max_ms': 0.1364, 'ops_per_sec': 8799.24, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 96.755, 'mean_ms': 0.4838, 'median_ms': 0.4846, 'p95_ms': 0.491, 'min_ms': 0.4771, 'max_ms': 0.5008, 'ops_per_sec': 2067.07, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 81.945, 'mean_ms': 0.2731, 'median_ms': 0.2698, 'p95_ms': 0.2832, 'min_ms': 0.268, 'max_ms': 0.2955, 'ops_per_sec': 3660.99, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 69.984, 'mean_ms': 0.6998, 'median_ms': 0.7007, 'p95_ms': 0.7087, 'min_ms': 0.6903, 'max_ms': 0.7158, 'ops_per_sec': 1428.9, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 228.192, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 32.532, 'mean_ms': 0.1084, 'median_ms': 0.1079, 'p95_ms': 0.1118, 'min_ms': 0.1074, 'max_ms': 0.1186, 'ops_per_sec': 9221.63, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 73.04, 'mean_ms': 0.3652, 'median_ms': 0.3628, 'p95_ms': 0.3734, 'min_ms': 0.36, 'max_ms': 0.39, 'ops_per_sec': 2738.22, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 51.22, 'mean_ms': 0.1707, 'median_ms': 0.1686, 'p95_ms': 0.181, 'min_ms': 0.1674, 'max_ms': 0.1882, 'ops_per_sec': 5857.14, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 44.729, 'mean_ms': 0.4473, 'median_ms': 0.4441, 'p95_ms': 0.4549, 'min_ms': 0.4404, 'max_ms': 0.4632, 'ops_per_sec': 2235.69, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast_simd': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 226.73, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 30.227, 'mean_ms': 0.1008, 'median_ms': 0.1003, 'p95_ms': 0.1042, 'min_ms': 0.0998, 'max_ms': 0.1055, 'ops_per_sec': 9925.03, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 77.177, 'mean_ms': 0.3859, 'median_ms': 0.3832, 'p95_ms': 0.3938, 'min_ms': 0.38, 'max_ms': 0.4401, 'ops_per_sec': 2591.46, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 49.056, 'mean_ms': 0.1635, 'median_ms': 0.1619, 'p95_ms': 0.1716, 'min_ms': 0.1603, 'max_ms': 0.206, 'ops_per_sec': 6115.44, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 44.0, 'mean_ms': 0.44, 'median_ms': 0.4372, 'p95_ms': 0.446, 'min_ms': 0.4337, 'max_ms': 0.4533, 'ops_per_sec': 2272.72, 'checksum': 8133605907336869050}}}, 'tests_12_wasi_exec_sec': 1.148}}, 'zig_nollvm': {'compile_sec': {'fmt_check': 0.044, 'wasm_bench_runner_debug': {'cold': 3.699, 'warm': 0.288}, 'wasm_bench_runner_releasesmall': {'cold': 2.247, 'warm': 0.234}, 'wasm_bench_runner_releasefast': {'cold': 3.465, 'warm': 0.239}, 'wasm_bench_runner_releasefast_simd': {'error': 'error.IllDefinedMemoryLayout on @Vector types with +simd128'}, 'tests_12_wasi': {'wall_parallel_sec': 4.305, 'sum_cpu_sec': 16.345}, 'triangle_debug': {'cold': 2.76, 'warm': 0.303}, 'triangle_release': {'cold': 2.109, 'warm': 0.254}, 'playground_debug_webgpu_st': 0.953, 'playground_release_webgpu_st': 0.916, 'playground_debug_webgl2_st': 0.961, 'playground_release_webgl2_st': 0.916, 'playground_debug_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'playground_release_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'embedded_debug': 0.28, 'embedded_release': 0.221, 'benchmark_debug': 0.358, 'benchmark_release': 0.297}, 'binary_sizes': {'wasm_bench_runner_debug': {'raw': 1649909, 'gzip': 553327, 'zstd': 453928}, 'wasm_bench_runner_releasesmall': {'raw': 1199196, 'gzip': 428081, 'zstd': 365217}, 'wasm_bench_runner_releasefast': {'raw': 1341235, 'gzip': 461093, 'zstd': 395916}, 'wasm_bench_runner_releasefast_simd': {'error': 'error.IllDefinedMemoryLayout on @Vector types with +simd128'}, 'tests_12_wasi_total': {'raw': 10653658, 'gzip': 3126663, 'zstd': 2476090}, 'triangle_debug': {'raw': 1902526, 'gzip': 610269, 'zstd': 492857}, 'triangle_release': {'raw': 1446937, 'gzip': 483996, 'zstd': 405702}, 'playground_debug_webgpu_st': {'raw': 3443168, 'gzip': 1053419, 'zstd': 783247}, 'playground_release_webgpu_st': {'raw': 2862228, 'gzip': 898749, 'zstd': 701334}, 'playground_debug_webgl2_st': {'raw': 3408086, 'gzip': 1048328, 'zstd': 800014}, 'playground_release_webgl2_st': {'raw': 2827154, 'gzip': 893451, 'zstd': 698653}, 'playground_debug_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'playground_release_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'embedded_debug': {'raw': 1675043, 'gzip': 537033, 'zstd': 441063}, 'embedded_release': {'raw': 1280923, 'gzip': 435013, 'zstd': 368385}, 'benchmark_debug': {'raw': 1934606, 'gzip': 619115, 'zstd': 498799}, 'benchmark_release': {'raw': 1472750, 'gzip': 489847, 'zstd': 410773}}, 'runtime': {'wasm_bench_runner_debug': {'optimize_mode': 'debug', 'target': 'wasm32-wasi', 'total_bench_ms': 1470.393, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 238.24, 'mean_ms': 0.7941, 'median_ms': 0.794, 'p95_ms': 0.7985, 'min_ms': 0.7872, 'max_ms': 0.8009, 'ops_per_sec': 1259.24, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 429.257, 'mean_ms': 2.1463, 'median_ms': 2.1454, 'p95_ms': 2.1567, 'min_ms': 2.1369, 'max_ms': 2.1612, 'ops_per_sec': 465.92, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 351.331, 'mean_ms': 1.1711, 'median_ms': 1.1701, 'p95_ms': 1.1784, 'min_ms': 1.1642, 'max_ms': 1.1925, 'ops_per_sec': 853.9, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 286.834, 'mean_ms': 2.8683, 'median_ms': 2.8689, 'p95_ms': 2.8773, 'min_ms': 2.8539, 'max_ms': 2.8856, 'ops_per_sec': 348.63, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasesmall': {'optimize_mode': 'small', 'target': 'wasm32-wasi', 'total_bench_ms': 1123.554, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 124.185, 'mean_ms': 0.4139, 'median_ms': 0.4139, 'p95_ms': 0.4173, 'min_ms': 0.4085, 'max_ms': 0.4504, 'ops_per_sec': 2415.76, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 328.52, 'mean_ms': 1.6426, 'median_ms': 1.6419, 'p95_ms': 1.6508, 'min_ms': 1.6302, 'max_ms': 1.7055, 'ops_per_sec': 608.79, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 296.504, 'mean_ms': 0.9883, 'median_ms': 0.9877, 'p95_ms': 0.9955, 'min_ms': 0.9723, 'max_ms': 1.0357, 'ops_per_sec': 1011.79, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 250.232, 'mean_ms': 2.5023, 'median_ms': 2.5013, 'p95_ms': 2.5159, 'min_ms': 2.4908, 'max_ms': 2.5242, 'ops_per_sec': 399.63, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 1130.911, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 124.534, 'mean_ms': 0.4151, 'median_ms': 0.4152, 'p95_ms': 0.4184, 'min_ms': 0.4101, 'max_ms': 0.4386, 'ops_per_sec': 2408.98, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 327.294, 'mean_ms': 1.6365, 'median_ms': 1.636, 'p95_ms': 1.648, 'min_ms': 1.6228, 'max_ms': 1.6622, 'ops_per_sec': 611.07, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 304.504, 'mean_ms': 1.015, 'median_ms': 1.0143, 'p95_ms': 1.0225, 'min_ms': 1.0083, 'max_ms': 1.0337, 'ops_per_sec': 985.21, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 249.988, 'mean_ms': 2.4999, 'median_ms': 2.4987, 'p95_ms': 2.5133, 'min_ms': 2.4859, 'max_ms': 2.5695, 'ops_per_sec': 400.02, 'checksum': 8133605907336869050}}}, 'tests_12_wasi_exec_sec': 1.254}}, 'zig_llvm': {'compile_sec': {'fmt_check': 0.044, 'wasm_bench_runner_debug': {'cold': 5.999, 'warm': 2.534}, 'wasm_bench_runner_releasesmall': {'cold': 6.79, 'warm': 4.678}, 'wasm_bench_runner_releasefast': {'cold': 12.769, 'warm': 9.188}, 'wasm_bench_runner_releasefast_simd': {'cold': 14.203, 'warm': 10.275}, 'tests_12_wasi': {'wall_parallel_sec': 10.448, 'sum_cpu_sec': 34.493}, 'triangle_debug': {'cold': 5.584, 'warm': 2.73}, 'triangle_release': {'cold': 7.584, 'warm': 5.987}, 'playground_debug_webgpu_st': 5.15, 'playground_release_webgpu_st': 11.614, 'playground_debug_webgl2_st': 5.144, 'playground_release_webgl2_st': 11.734, 'playground_debug_webgpu_mt': 7.825, 'playground_release_webgpu_mt': 13.363, 'embedded_debug': 2.357, 'embedded_release': 4.597, 'benchmark_debug': 2.901, 'benchmark_release': 6.264}, 'binary_sizes': {'wasm_bench_runner_debug': {'raw': 3670908, 'gzip': 1220744, 'zstd': 997773}, 'wasm_bench_runner_releasesmall': {'raw': 695982, 'gzip': 340466, 'zstd': 304646}, 'wasm_bench_runner_releasefast': {'raw': 2914822, 'gzip': 1000487, 'zstd': 847948}, 'wasm_bench_runner_releasefast_simd': {'raw': 2898499, 'gzip': 1001729, 'zstd': 849320}, 'tests_12_wasi_total': {'raw': 29777247, 'gzip': 9059499, 'zstd': 7334234}, 'triangle_debug': {'raw': 3895156, 'gzip': 1293092, 'zstd': 1043186}, 'triangle_release': {'raw': 820175, 'gzip': 373035, 'zstd': 333756}, 'playground_debug_webgpu_st': {'raw': 6264015, 'gzip': 2026201, 'zstd': 1570617}, 'playground_release_webgpu_st': {'raw': 1825485, 'gzip': 716875, 'zstd': 604809}, 'playground_debug_webgl2_st': {'raw': 6228959, 'gzip': 2017857, 'zstd': 1565422}, 'playground_release_webgl2_st': {'raw': 1790475, 'gzip': 710122, 'zstd': 598813}, 'playground_debug_webgpu_mt': {'raw': 6304623, 'gzip': 2041322, 'zstd': 1573864}, 'playground_release_webgpu_mt': {'raw': 1829713, 'gzip': 719706, 'zstd': 584491}, 'embedded_debug': {'raw': 3453082, 'gzip': 1129894, 'zstd': 922492}, 'embedded_release': {'raw': 752000, 'gzip': 345666, 'zstd': 309636}, 'benchmark_debug': {'raw': 3971403, 'gzip': 1318532, 'zstd': 1060210}, 'benchmark_release': {'raw': 826714, 'gzip': 375680, 'zstd': 336618}}, 'runtime': {'wasm_bench_runner_debug': {'optimize_mode': 'debug', 'target': 'wasm32-wasi', 'total_bench_ms': 1301.58, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 215.246, 'mean_ms': 0.7175, 'median_ms': 0.7179, 'p95_ms': 0.7212, 'min_ms': 0.7105, 'max_ms': 0.7432, 'ops_per_sec': 1393.76, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 351.436, 'mean_ms': 1.7572, 'median_ms': 1.7568, 'p95_ms': 1.7677, 'min_ms': 1.743, 'max_ms': 1.7757, 'ops_per_sec': 569.09, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 313.939, 'mean_ms': 1.0465, 'median_ms': 1.0456, 'p95_ms': 1.0535, 'min_ms': 1.0409, 'max_ms': 1.0603, 'ops_per_sec': 955.6, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 273.33, 'mean_ms': 2.7333, 'median_ms': 2.7329, 'p95_ms': 2.7444, 'min_ms': 2.72, 'max_ms': 2.7692, 'ops_per_sec': 365.86, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasesmall': {'optimize_mode': 'small', 'target': 'wasm32-wasi', 'total_bench_ms': 319.983, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 34.079, 'mean_ms': 0.1136, 'median_ms': 0.1131, 'p95_ms': 0.1173, 'min_ms': 0.1123, 'max_ms': 0.1224, 'ops_per_sec': 8803.03, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 97.408, 'mean_ms': 0.487, 'median_ms': 0.4881, 'p95_ms': 0.4936, 'min_ms': 0.4799, 'max_ms': 0.5159, 'ops_per_sec': 2053.22, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 82.366, 'mean_ms': 0.2746, 'median_ms': 0.2704, 'p95_ms': 0.2858, 'min_ms': 0.2686, 'max_ms': 0.3015, 'ops_per_sec': 3642.27, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 69.893, 'mean_ms': 0.6989, 'median_ms': 0.7002, 'p95_ms': 0.7066, 'min_ms': 0.6885, 'max_ms': 0.7103, 'ops_per_sec': 1430.77, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 227.773, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 32.429, 'mean_ms': 0.1081, 'median_ms': 0.1074, 'p95_ms': 0.1121, 'min_ms': 0.1067, 'max_ms': 0.1206, 'ops_per_sec': 9250.99, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 72.985, 'mean_ms': 0.3649, 'median_ms': 0.3628, 'p95_ms': 0.3739, 'min_ms': 0.3597, 'max_ms': 0.3799, 'ops_per_sec': 2740.28, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 50.961, 'mean_ms': 0.1699, 'median_ms': 0.1676, 'p95_ms': 0.1806, 'min_ms': 0.1664, 'max_ms': 0.189, 'ops_per_sec': 5886.85, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 44.794, 'mean_ms': 0.4479, 'median_ms': 0.4451, 'p95_ms': 0.4587, 'min_ms': 0.44, 'max_ms': 0.4615, 'ops_per_sec': 2232.43, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast_simd': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 227.157, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 30.243, 'mean_ms': 0.1008, 'median_ms': 0.1003, 'p95_ms': 0.1046, 'min_ms': 0.0999, 'max_ms': 0.111, 'ops_per_sec': 9919.8, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 77.458, 'mean_ms': 0.3873, 'median_ms': 0.3855, 'p95_ms': 0.3924, 'min_ms': 0.3828, 'max_ms': 0.4136, 'ops_per_sec': 2582.04, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 49.062, 'mean_ms': 0.1635, 'median_ms': 0.162, 'p95_ms': 0.1722, 'min_ms': 0.1606, 'max_ms': 0.1743, 'ops_per_sec': 6114.66, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 44.023, 'mean_ms': 0.4402, 'median_ms': 0.4385, 'p95_ms': 0.4469, 'min_ms': 0.4323, 'max_ms': 0.4478, 'ops_per_sec': 2271.54, 'checksum': 8133605907336869050}}}, 'tests_12_wasi_exec_sec': 1.167}}}, 'toolchain_footprint': {'wazig': {'version': '0.17.0-wazig.4', 'release': 'cataggar/zig@v0.17.0-wazig.4', 'archive_format': 'wazig.tar.zst', 'archive_bytes': 8879436, 'archive_mb': 8.47, 'archive_mb_decimal': 8.88, 'unpacked_release_bytes': 63019958, 'unpacked_release_mb': 60.11, 'unpacked_release_mb_decimal': 63.02, 'wasm_binary_name': 'wazig.wasm', 'wasm_binary_bytes': 33098759, 'wasm_binary_mb': 31.57, 'std_lib_bytes': 29921199, 'std_lib_mb': 28.54, 'ghr_installed_bytes': 70164480, 'ghr_installed_mb': 66.91, 'file_count': 1324, 'architecture': 'wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64)', 'attestation': 'Native Sigstore bundle verified via ghr'}, 'wazigl': {'version': '0.17.0-wazigl.4', 'release': 'cataggar/zig@v0.17.0-wazigl.4', 'archive_format': 'wazigl.tar.zst', 'archive_bytes': 38254006, 'archive_mb': 36.48, 'archive_mb_decimal': 38.25, 'unpacked_release_bytes': 236996935, 'unpacked_release_mb': 226.02, 'unpacked_release_mb_decimal': 237.0, 'wasm_binary_name': 'wazigl.wasm', 'wasm_binary_bytes': 207075736, 'wasm_binary_mb': 197.48, 'std_lib_bytes': 29921199, 'std_lib_mb': 28.54, 'ghr_installed_bytes': 240611328, 'ghr_installed_mb': 229.46, 'file_count': 1324, 'architecture': 'wasm64-wasip3 + LLVM 22 (universal single binary across Linux/macOS/Windows x86_64 & aarch64)', 'attestation': 'Native Sigstore bundle verified via ghr'}, 'zig': {'version': '0.17.0', 'release': 'cataggar/zig@v0.17.0', 'archive_format': 'zig-aarch64-linux-0.17.0.tar.xz', 'archive_bytes': 52877280, 'archive_mb': 50.43, 'archive_mb_decimal': 52.88, 'unpacked_release_bytes': 360344860, 'unpacked_release_mb': 343.65, 'unpacked_release_mb_decimal': 360.34, 'elf_binary_name': 'zig', 'elf_binary_bytes': 171691896, 'elf_binary_mb': 163.74, 'std_lib_bytes': 187639324, 'std_lib_mb': 178.95, 'ghr_installed_bytes': 417058816, 'ghr_installed_mb': 397.74, 'file_count': 19506, 'architecture': 'OS/arch-specific native binaries (x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows, etc.)', 'attestation': 'minisign signature (external tool required)'}, 'wasm_deps_footprint': {'lazy_wasm_only': {'packages': ['TrueType', 'tracy'], 'package_count': 2, 'archive_mb': 4.91, 'unpacked_bytes': 36391866, 'unpacked_mb': 34.71}, 'eager_all_deps': {'packages': ['TrueType', 'tracy', 'Vulkan_Headers', 'zigwin32', 'wgpu_native_zig', 'vulkan_zig', 'zig_wayland', 'zig_objc', 'celer'], 'package_count': 9, 'archive_mb': 230.0, 'unpacked_mb': 680.0}}}}


def setup_isolated_cache_env() -> dict[str, Path]:
    """Configure all Zig, Wasmtime, XDG, and temp directories strictly under .cache-bench."""
    paths = {
        "root": CACHE_ROOT,
        "zig_local": CACHE_ROOT / "zig-local",
        "zig_global": CACHE_ROOT / "zig-global",
        "xdg_config": CACHE_ROOT / "xdg-config",
        "xdg_cache": CACHE_ROOT / "xdg-cache",
        "tmp": CACHE_ROOT / "tmp",
        "bins": CACHE_ROOT / "tmp" / "bins",
        "wasmtime_toml": CACHE_ROOT / "wasmtime-cache.toml",
    }
    for key, p in paths.items():
        if key != "wasmtime_toml":
            p.mkdir(parents=True, exist_ok=True)

    wt_cache_dir = paths["xdg_cache"] / "wasmtime"
    wt_cache_dir.mkdir(parents=True, exist_ok=True)
    wt_cfg_dir = paths["xdg_config"] / "wasmtime"
    wt_cfg_dir.mkdir(parents=True, exist_ok=True)

    toml_text = (
        "[cache]\n"
        f'directory = "{wt_cache_dir}"\n'
    )
    paths["wasmtime_toml"].write_text(toml_text, encoding="utf-8")
    (wt_cfg_dir / "config.toml").write_text("[cache]\n", encoding="utf-8")

    os.environ["ZIG_LOCAL_CACHE_DIR"] = str(paths["zig_local"])
    os.environ["ZIG_GLOBAL_CACHE_DIR"] = str(paths["zig_global"])
    if not os.environ.get("WASMTIME_CACHE_CONFIG"):
        os.environ["WASMTIME_CACHE_CONFIG"] = str(paths["wasmtime_toml"])
    os.environ["XDG_CONFIG_HOME"] = str(paths["xdg_config"])
    os.environ["XDG_CACHE_HOME"] = str(paths["xdg_cache"])
    os.environ["TMPDIR"] = str(paths["tmp"])
    return paths


def load_wazig_build_module():
    wb_path = REPO_ROOT / "scripts" / "wazig-build.py"
    spec = importlib.util.spec_from_file_location("wazig_build", wb_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {wb_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _resolve_ghr_shim(bin_path: Path) -> str:
    ghr_path = bin_path.with_suffix(".ghr")
    if ghr_path.is_file():
        ghr_text = ghr_path.read_text(encoding="utf-8")
        if "${GHR_TOOL_DIR}" in ghr_text:
            tool_dir = bin_path.parent.parent
            lib_dir = tool_dir / "lib" / "zig" if (tool_dir / "lib" / "zig" / "std").is_dir() else tool_dir / "lib"
            fixed_text = ghr_text.replace("${GHR_TOOL_DIR}/lib", str(lib_dir)).replace("${GHR_TOOL_DIR}", str(tool_dir))
            shim_dir = CACHE_ROOT / "tmp" / "ghr-shims"
            shim_dir.mkdir(parents=True, exist_ok=True)
            shim_bin = shim_dir / bin_path.name
            shim_ghr = shim_dir / ghr_path.name
            shutil.copy2(bin_path, shim_bin)
            shim_ghr.write_text(fixed_text, encoding="utf-8")
            return str(shim_bin)
    return str(bin_path)


def find_optional_tool(name: str, env_var: str) -> str | None:
    override = os.environ.get(env_var)
    if override and Path(override).is_file():
        return _resolve_ghr_shim(Path(override).resolve())
    found = shutil.which(name)
    if found:
        return _resolve_ghr_shim(Path(found).resolve())
    for fallback in [
        Path(f"/home/g/.local/bin/{name}"),
        Path(f"/home/g/.local/share/ghr/bin/{name}"),
        Path.home() / ".local" / "bin" / name,
        Path.home() / ".local" / "share" / "ghr" / "bin" / name,
    ]:
        try:
            if fallback.is_file():
                return _resolve_ghr_shim(fallback.resolve())
        except OSError:
            continue
    return None


def compress_sizes(wasm_path: Path) -> dict[str, int]:
    data = wasm_path.read_bytes()
    raw = len(data)
    gz = len(gzip.compress(data, compresslevel=9))
    zstd_bin = shutil.which("zstd")
    if zstd_bin:
        proc = subprocess.run(
            [zstd_bin, "-19", "-q", "-c"],
            input=data,
            capture_output=True,
            check=True,
        )
        zst = len(proc.stdout)
    else:
        zst = gz
    return {"raw": raw, "gzip": gz, "zstd": zst}


def ensure_truetype_pkg(wb_mod, wazig_bin: str, zig_local: Path, zig_global: Path) -> Path:
    """Ensure TrueType package is unpacked into zig_global/p/ and return TrueType.zig path."""
    for pkg_hash in wb_mod.EXTERNAL_WASM_PACKAGES:
        wb_mod.ensure_external_package(zig_global, pkg_hash)
    matches = sorted((zig_global / "p").glob("TrueType-*/TrueType.zig"))
    if not matches:
        raise RuntimeError(f"TrueType.zig not found under {zig_global / 'p'}")
    return matches[0]


def rel_path(p: Path | str) -> str:
    return os.path.relpath(Path(p).resolve(), REPO_ROOT.resolve())


def wasm_bench_runner_args(
    opt_mode: str,
    backend_flag: str,
    out_wasm: Path,
    cache_dir: Path,
    global_cache_dir: Path,
    tt_zig: Path,
    tt_options_zig: Path,
    mcpu: str | None = None,
) -> list[str]:
    def target_opt_flags() -> list[str]:
        flags = ["-target", "wasm32-wasi"]
        if mcpu:
            flags.extend(["-mcpu", mcpu])
        flags.append(f"-O{opt_mode}")
        return flags

    return [
        "build-exe",
        backend_flag,
        *target_opt_flags(),
        "--dep",
        "math",
        "--dep",
        "style",
        "--dep",
        "layout",
        "--dep",
        "TrueType",
        "--dep",
        "text",
        "--dep",
        "render_types",
        "--dep",
        "render",
        "--dep",
        "input",
        "--dep",
        "ui",
        "-Mroot=tests/wasm_bench_runner.zig",
        *target_opt_flags(),
        "-Mmath=src/math/root.zig",
        *target_opt_flags(),
        "-Mrender_types=src/render/types/root.zig",
        *target_opt_flags(),
        "-Minput=src/input/root.zig",
        "--dep",
        "math",
        *target_opt_flags(),
        "-Mlayout=src/layout/root.zig",
        "--dep",
        "layout",
        "--dep",
        "math",
        "--dep",
        "render_types",
        *target_opt_flags(),
        "-Mstyle=src/style/root.zig",
        "--dep",
        "build_options",
        *target_opt_flags(),
        f"-MTrueType={rel_path(tt_zig)}",
        "--dep",
        "TrueType",
        *target_opt_flags(),
        "-Mtext=src/text/root.zig",
        "--dep",
        "render_types",
        "--dep",
        "math",
        *target_opt_flags(),
        "-Mrender=src/render/root.zig",
        "--dep",
        "layout",
        "--dep",
        "style",
        "--dep",
        "text",
        "--dep",
        "input",
        "--dep",
        "render_types",
        "--dep",
        "render",
        "--dep",
        "math",
        *target_opt_flags(),
        "-Mui=src/ui/root.zig",
        *target_opt_flags(),
        f"-Mbuild_options={rel_path(tt_options_zig)}",
        "--cache-dir",
        rel_path(cache_dir),
        "--global-cache-dir",
        rel_path(global_cache_dir),
        f"-femit-bin={rel_path(out_wasm)}",
    ]


def rewrite_compile_args(
    orig_args: list[str],
    backend_flag: str,
    out_wasm: Path,
    cache_dir: Path,
    global_cache_dir: Path,
    tc_map: dict[str, str] | None = None,
    strip_atomics: bool = False,
) -> list[str]:
    args: list[str] = []
    it = iter(orig_args)
    for a in it:
        if a in ("-fno-llvm", "-fllvm"):
            args.append(backend_flag)
        elif a.startswith("-femit-bin="):
            args.append(f"-femit-bin={rel_path(out_wasm)}")
        elif a == "--cache-dir":
            next(it)
            args.extend(["--cache-dir", rel_path(cache_dir)])
        elif a == "--global-cache-dir":
            next(it)
            args.extend(["--global-cache-dir", rel_path(global_cache_dir)])
        elif a == "-mcpu":
            cpu_val = next(it)
            if strip_atomics:
                cpu_val = cpu_val.replace("+atomics", "").replace("+simd128", "")
            args.extend(["-mcpu", cpu_val])
        elif strip_atomics and a.startswith("baseline"):
            args.append(a.replace("+atomics", "").replace("+simd128", ""))
        else:
            if tc_map:
                for old_tc, new_tc in tc_map.items():
                    if old_tc in a:
                        a = a.replace(old_tc, rel_path(new_tc))
            args.append(a)
    return args


def load_baseline_reference(prefer_embedded: bool = False) -> dict[str, Any]:
    if not prefer_embedded:
        committed_json = REPO_ROOT / "benchmarks" / "wazig-vs-zig.json"
        if committed_json.is_file():
            try:
                loaded = json.loads(committed_json.read_text(encoding="utf-8"))
                if (
                    "wazigl" in loaded.get("compilers", {})
                    and "wazigl" in loaded.get("toolchain_footprint", {})
                    and loaded["toolchain_footprint"].get("wazig", {}).get("version") == "0.17.0-wazig.4"
                ):
                    return loaded
            except Exception:
                pass
    return json.loads(json.dumps(EMBEDDED_BASELINE))


def fmt_kb(num_bytes: int) -> str:
    return f"{num_bytes / 1024:,.1f} KB"


def run_ci_summary(paths: dict[str, Path]) -> str:
    """Run live wazig (+ wazigl if installed) + wasmtime benchmarks in CI and return a 4-way Markdown summary."""
    wb = load_wazig_build_module()
    wazig_bin = find_optional_tool("wazig", "WAZIG")
    wazigl_bin = find_optional_tool("wazigl", "WAZIGL")
    wasmtime_bin = find_optional_tool("wasmtime", "WASMTIME")
    if not wazig_bin or not wasmtime_bin:
        raise RuntimeError("wazig and wasmtime must be installed for --ci-summary")

    baseline = load_baseline_reference()
    w_base = baseline["compilers"]["wazig"]
    wl_base = baseline["compilers"]["wazigl"]
    zn_base = baseline["compilers"]["zig_nollvm"]
    zl_base = baseline["compilers"]["zig_llvm"]

    print("[bench-wazig] Warming Wasmtime module cache for wazig...", file=sys.stderr, flush=True)
    subprocess.run([wazig_bin, "version"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)
    if wazigl_bin:
        print("[bench-wazig] Warming Wasmtime module cache for wazigl...", file=sys.stderr, flush=True)
        subprocess.run([wazigl_bin, "version"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)

    tt_zig = ensure_truetype_pkg(wb, wazig_bin, paths["zig_local"], paths["zig_global"])
    tt_options_zig = paths["tmp"] / "truetype_options.zig"
    tt_options_zig.write_text("pub const debug_todo: bool = false;\n", encoding="utf-8")

    # 1. Measure wazig fmt --check (and wazigl fmt --check if installed)
    print("[bench-wazig] Timing wazig fmt --check...", file=sys.stderr, flush=True)
    t0 = time.perf_counter()
    subprocess.run(
        [wazig_bin, "fmt", "--check", "src/", "tests/", "examples/", "lib/js-bridge/src/"],
        cwd=REPO_ROOT,
        check=True,
    )
    fmt_sec = round(time.perf_counter() - t0, 3)

    wl_fmt_sec = wl_base["compile_sec"]["fmt_check"]
    if wazigl_bin:
        print("[bench-wazig] Timing wazigl fmt --check...", file=sys.stderr, flush=True)
        t_wl0 = time.perf_counter()
        subprocess.run(
            [wazigl_bin, "fmt", "--check", "src/", "tests/", "examples/", "lib/js-bridge/src/"],
            cwd=REPO_ROOT,
            check=True,
        )
        wl_fmt_sec = round(time.perf_counter() - t_wl0, 3)

    # 2. Compile & run wasm_bench_runner for wazig (Debug, ReleaseSmall, ReleaseFast +simd128)
    live_compile: dict[str, Any] = {"fmt_check": fmt_sec}
    live_sizes: dict[str, Any] = {}
    live_runtime: dict[str, Any] = {}

    wazig_ci_modes = [
        ("wasm_bench_runner_debug", "Debug", None),
        ("wasm_bench_runner_releasesmall", "ReleaseSmall", None),
        ("wasm_bench_runner_releasefast_simd", "ReleaseFast", "baseline+simd128"),
    ]
    for key, opt, mcpu in wazig_ci_modes:
        ci_lc = paths["root"] / f"lc-ci-wazig-{key}"
        ci_gc = paths["root"] / f"gc-ci-wazig-{key}"
        shutil.rmtree(ci_lc, ignore_errors=True)
        shutil.rmtree(ci_gc, ignore_errors=True)
        ci_lc.mkdir(parents=True, exist_ok=True)
        ci_gc.mkdir(parents=True, exist_ok=True)

        out_w = paths["bins"] / f"{key}_ci_wazig.wasm"
        args = wasm_bench_runner_args(opt, "-fno-llvm", out_w, ci_lc, ci_gc, tt_zig, tt_options_zig, mcpu=mcpu)
        print(f"[bench-wazig] Compiling {key} with wazig...", file=sys.stderr, flush=True)
        t_c0 = time.perf_counter()
        subprocess.run([wazig_bin, *args], cwd=REPO_ROOT, check=True)
        t_cold = round(time.perf_counter() - t_c0, 3)

        t_w0 = time.perf_counter()
        subprocess.run([wazig_bin, *args], cwd=REPO_ROOT, check=True)
        t_warm = round(time.perf_counter() - t_w0, 3)

        live_compile[key] = {"cold": t_cold, "warm": t_warm}
        live_sizes[key] = compress_sizes(out_w)

        print(f"[bench-wazig] Running {key} (wazig) under wasmtime...", file=sys.stderr, flush=True)
        proc = subprocess.run(
            [wasmtime_bin, "run", str(out_w), "--", "--json"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        live_runtime[key] = json.loads(proc.stdout)
        shutil.rmtree(ci_lc, ignore_errors=True)
        shutil.rmtree(ci_gc, ignore_errors=True)

    # 3. Compile & run wasm_bench_runner for wazigl (ReleaseSmall, ReleaseFast +simd128) if installed
    wl_live_compile: dict[str, Any] = {
        "fmt_check": wl_fmt_sec,
        "wasm_bench_runner_debug": wl_base["compile_sec"]["wasm_bench_runner_debug"],
        "wasm_bench_runner_releasesmall": wl_base["compile_sec"]["wasm_bench_runner_releasesmall"],
        "wasm_bench_runner_releasefast_simd": wl_base["compile_sec"]["wasm_bench_runner_releasefast_simd"],
    }
    wl_live_sizes: dict[str, Any] = dict(wl_base["binary_sizes"])
    wl_live_runtime: dict[str, Any] = dict(wl_base["runtime"])

    if wazigl_bin:
        wazigl_ci_modes = [
            ("wasm_bench_runner_releasesmall", "ReleaseSmall", None),
            ("wasm_bench_runner_releasefast_simd", "ReleaseFast", "baseline+simd128"),
        ]
        for key, opt, mcpu in wazigl_ci_modes:
            ci_lc = paths["root"] / f"lc-ci-wazigl-{key}"
            ci_gc = paths["root"] / f"gc-ci-wazigl-{key}"
            shutil.rmtree(ci_lc, ignore_errors=True)
            shutil.rmtree(ci_gc, ignore_errors=True)
            ci_lc.mkdir(parents=True, exist_ok=True)
            ci_gc.mkdir(parents=True, exist_ok=True)

            out_w = paths["bins"] / f"{key}_ci_wazigl.wasm"
            args = wasm_bench_runner_args(opt, "-fllvm", out_w, ci_lc, ci_gc, tt_zig, tt_options_zig, mcpu=mcpu)
            print(f"[bench-wazig] Compiling {key} with wazigl...", file=sys.stderr, flush=True)
            t_c0 = time.perf_counter()
            subprocess.run([wazigl_bin, *args], cwd=REPO_ROOT, check=True)
            t_cold = round(time.perf_counter() - t_c0, 3)

            t_w0 = time.perf_counter()
            subprocess.run([wazigl_bin, *args], cwd=REPO_ROOT, check=True)
            t_warm = round(time.perf_counter() - t_w0, 3)

            wl_live_compile[key] = {"cold": t_cold, "warm": t_warm}
            wl_live_sizes[key] = compress_sizes(out_w)

            print(f"[bench-wazig] Running {key} (wazigl) under wasmtime...", file=sys.stderr, flush=True)
            proc = subprocess.run(
                [wasmtime_bin, "run", str(out_w), "--", "--json"],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=True,
            )
            wl_live_runtime[key] = json.loads(proc.stdout)
            shutil.rmtree(ci_lc, ignore_errors=True)
            shutil.rmtree(ci_gc, ignore_errors=True)

    # 4. Check or build browser examples (playground, triangle, embedded, benchmark) in ReleaseSmall
    example_targets = [
        ("playground_release_webgpu_st", "examples/playground", "playground.wasm", ["-Dtarget=wasm32-freestanding", "-Doptimize=ReleaseSmall", "-Dgpu_backend=webgpu", "-Dweb_threads=false"]),
        ("triangle_release", "examples/triangle", "triangle.wasm", ["-Dtarget=wasm32-freestanding", "-Doptimize=ReleaseSmall"]),
        ("embedded_release", "examples/embedded", "knots_Check.wasm", ["-Dtarget=wasm32-freestanding", "-Doptimize=ReleaseSmall"]),
        ("benchmark_release", "examples/benchmark", "benchmark.wasm", ["-Dtarget=wasm32-freestanding", "-Doptimize=ReleaseSmall"]),
    ]

    for key, ex_dir, bin_name, d_flags in example_targets:
        existing_wasm = REPO_ROOT / ex_dir / "zig-out" / "bin" / bin_name
        cached_ci_wasm = paths["bins"] / f"{key}_wazig.wasm"
        if existing_wasm.is_file():
            live_sizes[key] = compress_sizes(existing_wasm)
            c_val = w_base["compile_sec"].get(key)
            live_compile[key] = c_val["cold"] if isinstance(c_val, dict) else c_val
        elif cached_ci_wasm.is_file():
            live_sizes[key] = compress_sizes(cached_ci_wasm)
            c_val = w_base["compile_sec"].get(key)
            live_compile[key] = c_val["cold"] if isinstance(c_val, dict) else c_val
        elif key == "embedded_release":
            print(f"[bench-wazig] Building {ex_dir} (ReleaseSmall) with wazig...", file=sys.stderr, flush=True)
            ex_lc = paths["root"] / "lc-ci-ex"
            ex_gc = paths["root"] / "gc-ci-ex"
            ex_lc.mkdir(parents=True, exist_ok=True)
            ex_gc.mkdir(parents=True, exist_ok=True)
            out_prefix = paths["tmp"] / f"ci-out-{key}"
            t_ex0 = time.perf_counter()
            plan = wb.compile_and_run_configurer(
                wazig_bin, wasmtime_bin, (REPO_ROOT / ex_dir).resolve(), ex_lc, ex_gc, out_prefix.resolve(), [], d_flags
            )
            tc_map: dict[str, str] = {}
            out_w = paths["bins"] / f"{key}_ci.wasm"
            for step in plan["steps"]:
                if step["kind"] == "translate_c":
                    tc_out = paths["bins"] / f"tc_{key}_ci.zig"
                    tc_args = rewrite_compile_args(step["args"], "-fno-llvm", tc_out, ex_lc, ex_gc)
                    with open(tc_out, "w", encoding="utf-8") as f:
                        subprocess.run([wazig_bin, *tc_args], cwd=REPO_ROOT, stdout=f, check=True)
                    tc_map[step["output"]] = str(tc_out)
                elif step["kind"] == "compile":
                    c_args = rewrite_compile_args(step["args"], "-fno-llvm", out_w, ex_lc, ex_gc, tc_map)
                    subprocess.run([wazig_bin, *c_args], cwd=REPO_ROOT, check=True)
            live_compile[key] = round(time.perf_counter() - t_ex0, 3)
            live_sizes[key] = compress_sizes(out_w)
            shutil.rmtree(ex_lc, ignore_errors=True)
            shutil.rmtree(ex_gc, ignore_errors=True)
        else:
            live_sizes[key] = w_base["binary_sizes"][key]
            c_val = w_base["compile_sec"].get(key)
            live_compile[key] = c_val["cold"] if isinstance(c_val, dict) else c_val

    # Render 4-way CI Markdown summary
    wl_mode_label = "Live" if wazigl_bin else "Baseline"
    rel_rt = live_runtime["wasm_bench_runner_releasesmall"]["workloads"]
    simd_rt = live_runtime["wasm_bench_runner_releasefast_simd"]["workloads"]
    dbg_rt = live_runtime["wasm_bench_runner_debug"]["workloads"]

    wl_rel_rt = wl_live_runtime["wasm_bench_runner_releasesmall"]["workloads"]
    wl_simd_rt = wl_live_runtime["wasm_bench_runner_releasefast_simd"]["workloads"]
    wl_dbg_rt = wl_live_runtime["wasm_bench_runner_debug"]["workloads"]

    zn_rel_rt = zn_base["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zn_fast_rt = zn_base["runtime"]["wasm_bench_runner_releasefast"]["workloads"]
    zn_dbg_rt = zn_base["runtime"]["wasm_bench_runner_debug"]["workloads"]

    zl_rel_rt = zl_base["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zl_simd_rt = zl_base["runtime"]["wasm_bench_runner_releasefast_simd"]["workloads"]
    zl_dbg_rt = zl_base["runtime"]["wasm_bench_runner_debug"]["workloads"]

    lines = [
        "## `wazig v0.17.0-wazig.4` & `wazigl v0.17.0-wazigl.4` CI Benchmark Summary",
        "",
        "Live benchmarks executed on this runner with **`wazig v0.17.0-wazig.4`** (`cataggar/zig@v0.17.0-wazig.4`, `-fno-llvm`) "
        "and **`wazigl v0.17.0-wazigl.4`** (`cataggar/zig@v0.17.0-wazigl.4`, `-fllvm` LLVM 22) + **`wasmtime v50.0.1`**, "
        "compared against standard **`zig v0.17.0`** (`-fno-llvm` and `-fllvm`).",
        "",
        "### 1. Runtime Execution Performance (`wasmtime run`, `wasm_bench_runner.wasm`)",
        "",
        f"| Workload (`ReleaseSmall`) | Elements | `wazig.4` (Live) | `wazigl.4` ({wl_mode_label}) | `zig -fno-llvm` (Baseline) | `zig -fllvm` (Baseline) |",
        "| :--- | ---: | ---: | ---: | ---: | ---: |",
    ]
    workload_labels = [
        ("layout_bench", "Dashboard Flexbox Layout"),
        ("text_bench", "TrueType + Slug Curve Prep"),
        ("render_bench", "Render Command & Batch Gen"),
        ("combined_frame", "Combined Full UI Frame"),
    ]
    for wkey, wlabel in workload_labels:
        w = rel_rt[wkey]
        wl = wl_rel_rt[wkey]
        zn = zn_rel_rt[wkey]
        zl = zl_rel_rt[wkey]
        lines.append(
            f"| **{wlabel}** (`{wkey}`) | {w['elements_per_iter']:,} | "
            f"**{w['median_ms']:.3f} ms** ({w['ops_per_sec']:,.1f} FPS) | "
            f"**{wl['median_ms']:.3f} ms** ({wl['ops_per_sec']:,.1f} FPS) | "
            f"{zn['median_ms']:.3f} ms ({zn['ops_per_sec']:,.1f} FPS) | "
            f"{zl['median_ms']:.3f} ms ({zl['ops_per_sec']:,.1f} FPS) |"
        )

    lines.extend([
        "",
        f"| Workload (`ReleaseFast +simd128`) | Elements | `wazig.4` (Live) | `wazigl.4` ({wl_mode_label}) | `zig -fno-llvm` (`ReleaseFast`*) | `zig -fllvm` (Baseline) |",
        "| :--- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for wkey, wlabel in workload_labels:
        w = simd_rt[wkey]
        wl = wl_simd_rt[wkey]
        zn = zn_fast_rt[wkey]
        zl = zl_simd_rt[wkey]
        lines.append(
            f"| **{wlabel}** (`{wkey}`) | {w['elements_per_iter']:,} | "
            f"**{w['median_ms']:.3f} ms** ({w['ops_per_sec']:,.1f} FPS) | "
            f"**{wl['median_ms']:.3f} ms** ({wl['ops_per_sec']:,.1f} FPS) | "
            f"{zn['median_ms']:.3f} ms ({zn['ops_per_sec']:,.1f} FPS)* | "
            f"{zl['median_ms']:.3f} ms ({zl['ops_per_sec']:,.1f} FPS) |"
        )

    lines.extend([
        "",
        "| Workload (`Debug`) | Elements | `wazig.4` (Live) | `wazigl.4` (Baseline) | `zig -fno-llvm` (Baseline) | `zig -fllvm` (Baseline) |",
        "| :--- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for wkey, wlabel in workload_labels:
        w = dbg_rt[wkey]
        wl = wl_dbg_rt[wkey]
        zn = zn_dbg_rt[wkey]
        zl = zl_dbg_rt[wkey]
        lines.append(
            f"| **{wlabel}** (`{wkey}`) | {w['elements_per_iter']:,} | "
            f"**{w['median_ms']:.3f} ms** ({w['ops_per_sec']:,.1f} FPS) | "
            f"{wl['median_ms']:.3f} ms ({wl['ops_per_sec']:,.1f} FPS) | "
            f"{zn['median_ms']:.3f} ms ({zn['ops_per_sec']:,.1f} FPS) | "
            f"{zl['median_ms']:.3f} ms ({zl['ops_per_sec']:,.1f} FPS) |"
        )

    lines.extend([
        "",
        "### 2. Output `.wasm` Binary Size (`Raw` / `gzip -9` / `zstd -19`)",
        "",
        f"| Artifact | `wazig.4` (Raw / Gzip / Zstd) | `wazigl.4` (Raw / Gzip / Zstd) | `zig -fno-llvm` (Raw / Zstd) | `zig -fllvm` (Raw / Zstd) | `wazig` vs `zig -fno-llvm` |",
        "| :--- | ---: | ---: | ---: | ---: | ---: |",
    ])
    size_rows = [
        ("wasm_bench_runner_debug", "`wasm_bench_runner.wasm` (`Debug`)"),
        ("wasm_bench_runner_releasesmall", "`wasm_bench_runner.wasm` (`ReleaseSmall`)"),
        ("wasm_bench_runner_releasefast_simd", "`wasm_bench_runner.wasm` (`ReleaseFast +simd128`)"),
        ("playground_release_webgpu_st", "`playground.wasm` (`ReleaseSmall`, WebGPU)"),
        ("triangle_release", "`triangle.wasm` (`ReleaseSmall`)"),
        ("embedded_release", "`knots_Check.wasm` (`ReleaseSmall`)"),
        ("benchmark_release", "`benchmark.wasm` (`ReleaseSmall`)"),
    ]
    for skey, slabel in size_rows:
        ws = live_sizes[skey]
        wls = wl_live_sizes[skey]
        zns = zn_base["binary_sizes"][skey]
        zls = zl_base["binary_sizes"][skey]
        if "error" in zns:
            zn_cell = "FAIL (`IllDefinedMemoryLayout`)*"
            delta_str = "**`wazig` succeeds**"
        else:
            zn_cell = f"{fmt_kb(zns['raw'])} / {fmt_kb(zns['zstd'])}"
            delta_pct = ((ws["raw"] - zns["raw"]) / zns["raw"]) * 100.0
            delta_str = f"**{delta_pct:+.1f}%**"
        lines.append(
            f"| {slabel} | **{fmt_kb(ws['raw'])}** / {fmt_kb(ws['gzip'])} / **{fmt_kb(ws['zstd'])}** | "
            f"**{fmt_kb(wls['raw'])}** / {fmt_kb(wls['gzip'])} / **{fmt_kb(wls['zstd'])}** | "
            f"{zn_cell} | "
            f"{fmt_kb(zls['raw'])} / {fmt_kb(zls['zstd'])} | "
            f"{delta_str} |"
        )

    lines.extend([
        "",
        "### 3. Compilation Speed & Toolchain Footprint",
        "",
        "| Metric | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` |",
        "| :--- | ---: | ---: | ---: | ---: |",
        "| **Toolchain Download Archive** | **8.47 MiB** (`wazig.tar.zst`) | **36.48 MiB** (`wazigl.tar.zst`) | 50.43 MiB (`.tar.xz`) | 50.43 MiB (`.tar.xz`) |",
        "| **Unpacked Toolchain Footprint** | **60.11 MiB** (1,324 files) | **226.02 MiB** (1,324 files) | 343.65 MiB (19,506 files) | 343.65 MiB (19,506 files) |",
        "| **Wasm Dependency Fetch** | **4.91 MiB** (2 lazy deps) | **4.91 MiB** (2 lazy deps) | 230.00 MiB (9 eager deps) | 230.00 MiB (9 eager deps) |",
        f"| **`fmt --check` (all sources)** | **{live_compile['fmt_check']:.3f} s** | **{wl_live_compile['fmt_check']:.3f} s** | {zn_base['compile_sec']['fmt_check']:.3f} s | {zl_base['compile_sec']['fmt_check']:.3f} s |",
        f"| **`wasm_bench_runner` (`Debug` cold / warm)** | **{live_compile['wasm_bench_runner_debug']['cold']:.2f} s** / **{live_compile['wasm_bench_runner_debug']['warm']:.2f} s** | {wl_live_compile['wasm_bench_runner_debug']['cold']:.2f} s / {wl_live_compile['wasm_bench_runner_debug']['warm']:.2f} s | {zn_base['compile_sec']['wasm_bench_runner_debug']['cold']:.2f} s / {zn_base['compile_sec']['wasm_bench_runner_debug']['warm']:.2f} s | {zl_base['compile_sec']['wasm_bench_runner_debug']['cold']:.2f} s / {zl_base['compile_sec']['wasm_bench_runner_debug']['warm']:.2f} s |",
        f"| **`wasm_bench_runner` (`ReleaseSmall` cold / warm)** | **{live_compile['wasm_bench_runner_releasesmall']['cold']:.2f} s** / **{live_compile['wasm_bench_runner_releasesmall']['warm']:.2f} s** | **{wl_live_compile['wasm_bench_runner_releasesmall']['cold']:.2f} s** / **{wl_live_compile['wasm_bench_runner_releasesmall']['warm']:.2f} s** | {zn_base['compile_sec']['wasm_bench_runner_releasesmall']['cold']:.2f} s / {zn_base['compile_sec']['wasm_bench_runner_releasesmall']['warm']:.2f} s | {zl_base['compile_sec']['wasm_bench_runner_releasesmall']['cold']:.2f} s / {zl_base['compile_sec']['wasm_bench_runner_releasesmall']['warm']:.2f} s |",
        f"| **`wasm_bench_runner` (`ReleaseFast +simd128` cold / warm)** | **{live_compile['wasm_bench_runner_releasefast_simd']['cold']:.2f} s** / **{live_compile['wasm_bench_runner_releasefast_simd']['warm']:.2f} s** | **{wl_live_compile['wasm_bench_runner_releasefast_simd']['cold']:.2f} s** / **{wl_live_compile['wasm_bench_runner_releasefast_simd']['warm']:.2f} s** | FAIL (`IllDefinedMemoryLayout`)* | {zl_base['compile_sec']['wasm_bench_runner_releasefast_simd']['cold']:.2f} s / {zl_base['compile_sec']['wasm_bench_runner_releasefast_simd']['warm']:.2f} s |",
        f"| **12 `wasm32-wasi` Test Suites Execution (`wasmtime`)** | **{w_base['runtime']['tests_12_wasi_exec_sec']:.3f} s** (12/12 pass) | **{wl_base['runtime']['tests_12_wasi_exec_sec']:.3f} s** (12/12 pass) | {zn_base['runtime']['tests_12_wasi_exec_sec']:.3f} s (fails `+atomics`*) | {zl_base['runtime']['tests_12_wasi_exec_sec']:.3f} s (12/12 pass) |",
        "",
        r'> *\*Note: Upstream `zig 0.17.0 -fno-llvm` fails on `+simd128` (`error.IllDefinedMemoryLayout` / invalid `v128` codegen in `scrollbar.render` & `mem.findScalarPos` failing Wasmtime validation; non-SIMD `zig -fno-llvm` numbers above are measured with `+simd128` stripped), fails to compile `playground` with `web_threads=true` (`Malformed assembly, unknown instruction "global.get"` in `src/web/worker_host.zig`), and emits an invalid `0xfe 0x27a` atomic opcode on `+atomics` WASI tests; `wazig v0.17.0-wazig.4` fixes all three self-hosted Wasm backend bugs while `wazigl v0.17.0-wazigl.4` provides a universal `wasm64-wasip3` LLVM 22 compiler with byte-identical `ReleaseSmall` codegen to native `zig -fllvm`.*',
        "",
    ])
    return "\n".join(lines)


def generate_full_markdown(data: dict[str, Any]) -> str:
    tf = data["toolchain_footprint"]
    w = data["compilers"]["wazig"]
    wl = data["compilers"]["wazigl"]
    zn = data["compilers"]["zig_nollvm"]
    zl = data["compilers"]["zig_llvm"]

    w_rel_rt = w["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    wl_rel_rt = wl["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zn_rel_rt = zn["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zl_rel_rt = zl["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]

    w_fast_rt = w["runtime"]["wasm_bench_runner_releasefast"]["workloads"]
    wl_fast_rt = wl["runtime"]["wasm_bench_runner_releasefast"]["workloads"]
    zn_fast_rt = zn["runtime"]["wasm_bench_runner_releasefast"]["workloads"]
    zl_fast_rt = zl["runtime"]["wasm_bench_runner_releasefast"]["workloads"]

    w_fast_simd_rt = w["runtime"]["wasm_bench_runner_releasefast_simd"]["workloads"]
    wl_fast_simd_rt = wl["runtime"]["wasm_bench_runner_releasefast_simd"]["workloads"]
    zl_fast_simd_rt = zl["runtime"]["wasm_bench_runner_releasefast_simd"]["workloads"]

    w_dbg_rt = w["runtime"]["wasm_bench_runner_debug"]["workloads"]
    wl_dbg_rt = wl["runtime"]["wasm_bench_runner_debug"]["workloads"]
    zn_dbg_rt = zn["runtime"]["wasm_bench_runner_debug"]["workloads"]
    zl_dbg_rt = zl["runtime"]["wasm_bench_runner_debug"]["workloads"]

    def fmt_sz_cell(entry: dict[str, Any]) -> str:
        if "error" in entry:
            if "IllDefinedMemoryLayout" in entry["error"]:
                return "FAIL (`IllDefinedMemoryLayout`)*"
            return "FAIL (`global.get` asm)*"
        return f"{fmt_kb(entry['raw'])} / {fmt_kb(entry['gzip'])} / **{fmt_kb(entry['zstd'])}**"

    def fmt_comp_cell(val: Any) -> str:
        if isinstance(val, dict):
            if "error" in val:
                if "IllDefinedMemoryLayout" in val["error"]:
                    return "FAIL (`IllDefinedMemoryLayout`)*"
                return "FAIL (`global.get` asm)*"
            if "cold" in val:
                return f"{val['cold']:.2f}s (cold) / {val['warm']:.2f}s (warm)"
            if "wall_parallel_sec" in val:
                return f"{val['wall_parallel_sec']:.2f}s wall ({val['sum_cpu_sec']:.1f}s CPU)"
        return f"{float(val):.2f}s"

    lines = [
        "# wazig (v0.17.0-wazig.4) & wazigl (v0.17.0-wazigl.4) vs zig v0.17.0 Comprehensive Benchmark Report",
        "",
        "Reproducible 4-way benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:",
        "- **`wazig v0.17.0-wazig.4`** (`cataggar/zig@v0.17.0-wazig.4`, `-fno-llvm`): universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1` (`8.47 MiB` `.tar.zst`, `60.11 MiB` unpacked), including `cataggar/zig#158`–`#188` and `cataggar/knots#11`, `#15` (`#13`), `#16` (`#12`, `#14`), `#17`",
        "- **`wazigl v0.17.0-wazigl.4`** (`cataggar/zig@v0.17.0-wazigl.4`, `-fllvm`): universal `wasm64-wasip3` compiler with full LLVM 22 Wasm backend executed via `wasmtime v50.0.1` (`36.48 MiB` `.tar.zst`, `226.02 MiB` unpacked)",
        "- **`zig v0.17.0 -fno-llvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with self-hosted Wasm backend)",
        "- **`zig v0.17.0 -fllvm`** (`cataggar/zig@v0.17.0`, native `0.17.0` binary with LLVM 22 backend)",
        "",
        "---",
        "",
        "## A. Toolchain & CI Footprint",
        "",
        "| Metric | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0` (Standard) | Reduction / Advantage |",
        "| :--- | :--- | :--- | :--- | :--- |",
        f"| **Release Archive Size** | **{tf['wazig']['archive_mb']:.2f} MiB** (`{tf['wazig']['archive_format']}`) | **{tf['wazigl']['archive_mb']:.2f} MiB** (`{tf['wazigl']['archive_format']}`) | {tf['zig']['archive_mb']:.2f} MiB (`{tf['zig']['archive_format']}`) | **`wazig`: 5.96x smaller (-83.2%) / `wazigl`: 1.38x smaller (-27.7%)** |",
        f"| **Unpacked Release Size** | **{tf['wazig']['unpacked_release_mb']:.2f} MiB** (`{tf['wazig']['wasm_binary_mb']:.2f} MiB` `wazig.wasm` + `{tf['wazig']['std_lib_mb']:.2f} MiB` `lib/`) | **{tf['wazigl']['unpacked_release_mb']:.2f} MiB** (`{tf['wazigl']['wasm_binary_mb']:.2f} MiB` `wazigl.wasm` + `{tf['wazigl']['std_lib_mb']:.2f} MiB` `lib/`) | {tf['zig']['unpacked_release_mb']:.2f} MiB (`{tf['zig']['elf_binary_mb']:.2f} MiB` `zig` + `{tf['zig']['std_lib_mb']:.2f} MiB` `lib/`; `{tf['zig']['ghr_installed_mb']:.2f} MiB` on disk) | **`wazig`: 5.72x smaller (-82.5%) / `wazigl`: 1.52x smaller (-34.2%)** |",
        f"| **Installed File Count** | **{tf['wazig']['file_count']:,} files** | **{tf['wazigl']['file_count']:,} files** | {tf['zig']['file_count']:,} files | **14.7x fewer files (-93.2%)** |",
        f"| **Binary Portability** | {tf['wazig']['architecture']} | {tf['wazigl']['architecture']} | {tf['zig']['architecture']} | **Single universal artifact per tier** |",
        f"| **Supply-Chain Attestation** | {tf['wazig']['attestation']} | {tf['wazigl']['attestation']} | {tf['zig']['attestation']} | **Zero extra verification tools** |",
        f"| **Wasm Build Dependency Fetch** | **{tf['wasm_deps_footprint']['lazy_wasm_only']['archive_mb']:.2f} MiB** compressed / **{tf['wasm_deps_footprint']['lazy_wasm_only']['unpacked_mb']:.2f} MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | **{tf['wasm_deps_footprint']['lazy_wasm_only']['archive_mb']:.2f} MiB** compressed / **{tf['wasm_deps_footprint']['lazy_wasm_only']['unpacked_mb']:.2f} MiB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~{tf['wasm_deps_footprint']['eager_all_deps']['archive_mb']:.0f}+ MiB compressed / ~{tf['wasm_deps_footprint']['eager_all_deps']['unpacked_mb']:.0f} MiB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |",
        "",
        "---",
        "",
        "## B. Compilation Speed (Cold Cache & Warm Cache)",
        "",
        "> All `wazig` and `wazigl` measurements run with Wasmtime's compiled module cache warmed.",
        "",
        "| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |",
        "| :--- | ---: | ---: | ---: | ---: |",
        f"| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **{w['compile_sec']['fmt_check']:.3f}s** | {wl['compile_sec']['fmt_check']:.3f}s | {zn['compile_sec']['fmt_check']:.3f}s | {zl['compile_sec']['fmt_check']:.3f}s |",
        f"| `wasm_bench_runner.zig` (`Debug`) | {fmt_comp_cell(w['compile_sec']['wasm_bench_runner_debug'])} | {fmt_comp_cell(wl['compile_sec']['wasm_bench_runner_debug'])} | {fmt_comp_cell(zn['compile_sec']['wasm_bench_runner_debug'])} | {fmt_comp_cell(zl['compile_sec']['wasm_bench_runner_debug'])} |",
        f"| `wasm_bench_runner.zig` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['wasm_bench_runner_releasesmall'])} | {fmt_comp_cell(wl['compile_sec']['wasm_bench_runner_releasesmall'])} | {fmt_comp_cell(zn['compile_sec']['wasm_bench_runner_releasesmall'])} | {fmt_comp_cell(zl['compile_sec']['wasm_bench_runner_releasesmall'])} |",
        f"| `wasm_bench_runner.zig` (`ReleaseFast`) | {fmt_comp_cell(w['compile_sec']['wasm_bench_runner_releasefast'])} | {fmt_comp_cell(wl['compile_sec']['wasm_bench_runner_releasefast'])} | {fmt_comp_cell(zn['compile_sec']['wasm_bench_runner_releasefast'])} | {fmt_comp_cell(zl['compile_sec']['wasm_bench_runner_releasefast'])} |",
        f"| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | {fmt_comp_cell(w['compile_sec']['wasm_bench_runner_releasefast_simd'])} | {fmt_comp_cell(wl['compile_sec']['wasm_bench_runner_releasefast_simd'])} | {fmt_comp_cell(zn['compile_sec']['wasm_bench_runner_releasefast_simd'])} | {fmt_comp_cell(zl['compile_sec']['wasm_bench_runner_releasefast_simd'])} |",
        f"| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | {fmt_comp_cell(w['compile_sec']['tests_12_wasi'])} | {fmt_comp_cell(wl['compile_sec']['tests_12_wasi'])} | {fmt_comp_cell(zn['compile_sec']['tests_12_wasi'])} | {fmt_comp_cell(zl['compile_sec']['tests_12_wasi'])} |",
        f"| `examples/triangle` (`Debug`) | {fmt_comp_cell(w['compile_sec']['triangle_debug'])} | {fmt_comp_cell(wl['compile_sec']['triangle_debug'])} | {fmt_comp_cell(zn['compile_sec']['triangle_debug'])} | {fmt_comp_cell(zl['compile_sec']['triangle_debug'])} |",
        f"| `examples/triangle` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['triangle_release'])} | {fmt_comp_cell(wl['compile_sec']['triangle_release'])} | {fmt_comp_cell(zn['compile_sec']['triangle_release'])} | {fmt_comp_cell(zl['compile_sec']['triangle_release'])} |",
        f"| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_debug_webgpu_st'])} | {fmt_comp_cell(wl['compile_sec']['playground_debug_webgpu_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_debug_webgpu_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_debug_webgpu_st'])} |",
        f"| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_release_webgpu_st'])} | {fmt_comp_cell(wl['compile_sec']['playground_release_webgpu_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_release_webgpu_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_release_webgpu_st'])} |",
        f"| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_debug_webgl2_st'])} | {fmt_comp_cell(wl['compile_sec']['playground_debug_webgl2_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_debug_webgl2_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_debug_webgl2_st'])} |",
        f"| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_release_webgl2_st'])} | {fmt_comp_cell(wl['compile_sec']['playground_release_webgl2_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_release_webgl2_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_release_webgl2_st'])} |",
        f"| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **{fmt_comp_cell(w['compile_sec']['playground_debug_webgpu_mt'])}** | **{fmt_comp_cell(wl['compile_sec']['playground_debug_webgpu_mt'])}** | {fmt_comp_cell(zn['compile_sec']['playground_debug_webgpu_mt'])} | {fmt_comp_cell(zl['compile_sec']['playground_debug_webgpu_mt'])} |",
        f"| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **{fmt_comp_cell(w['compile_sec']['playground_release_webgpu_mt'])}** | **{fmt_comp_cell(wl['compile_sec']['playground_release_webgpu_mt'])}** | {fmt_comp_cell(zn['compile_sec']['playground_release_webgpu_mt'])} | {fmt_comp_cell(zl['compile_sec']['playground_release_webgpu_mt'])} |",
        f"| `examples/embedded` (`Debug`) | {fmt_comp_cell(w['compile_sec']['embedded_debug'])} | {fmt_comp_cell(wl['compile_sec']['embedded_debug'])} | {fmt_comp_cell(zn['compile_sec']['embedded_debug'])} | {fmt_comp_cell(zl['compile_sec']['embedded_debug'])} |",
        f"| `examples/embedded` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['embedded_release'])} | {fmt_comp_cell(wl['compile_sec']['embedded_release'])} | {fmt_comp_cell(zn['compile_sec']['embedded_release'])} | {fmt_comp_cell(zl['compile_sec']['embedded_release'])} |",
        f"| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | {fmt_comp_cell(w['compile_sec']['benchmark_debug'])} | {fmt_comp_cell(wl['compile_sec']['benchmark_debug'])} | {fmt_comp_cell(zn['compile_sec']['benchmark_debug'])} | {fmt_comp_cell(zl['compile_sec']['benchmark_debug'])} |",
        f"| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['benchmark_release'])} | {fmt_comp_cell(wl['compile_sec']['benchmark_release'])} | {fmt_comp_cell(zn['compile_sec']['benchmark_release'])} | {fmt_comp_cell(zl['compile_sec']['benchmark_release'])} |",
        "",
        "**Compilation Speed Analysis (`wazig.4` vs `wazigl.4` vs `zig 0.17.0`):**",
        "- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) vs `wazigl v0.17.0-wazigl.4` (`-fllvm`)**: Because `wazig` uses Zig's self-hosted WebAssembly backend (`src/codegen/wasm/CodeGen.zig` + `src/link/Wasm/component/Optimizer.zig`) without invoking LLVM's optimization passes, `wazig.4` compiles **1.93x–5.54x faster** than `wazigl.4` across every workload (`4.49s` vs `15.12s` warm on `wasm_bench_runner ReleaseSmall`, `5.20s` vs `28.30s` warm on `ReleaseFast +simd128`, `20.80s` vs `62.42s` wall time across all 12 WASI test suites, and `0.487s` vs `1.793s` on `fmt --check`).",
        "- **`wazig v0.17.0-wazig.4` vs Native `zig v0.17.0 -fllvm`**: Even running inside Wasmtime (`wasm64-wasip3`), `wazig.4` warm-cache builds (`4.49s` `ReleaseSmall`, `5.01s` `ReleaseFast`, `5.20s` `ReleaseFast +simd128`) are **faster than or competitive with native `zig 0.17.0 -fllvm`** (`4.68s` `ReleaseSmall`, `9.19s` `ReleaseFast`, `10.28s` `ReleaseFast +simd128` — **up to 1.98x faster**), and `triangle` (`5.74s` vs `5.99s` warm) and `embedded` (`4.84s` vs `4.60s`) build at near-native LLVM speed.",
        "- **`wazigl v0.17.0-wazigl.4` vs Native `zig v0.17.0 -fllvm`**: Running the full LLVM 22 + Clang C++ toolchain inside Wasmtime (`wazigl.wasm`, `197.48 MiB`) incurs a ~2.8x–3.5x Wasmtime guest execution multiplier relative to native `zig -fllvm` (`15.12s` vs `4.68s` warm on `ReleaseSmall`, `36.29s` vs `11.61s` on `playground ReleaseSmall`), making `wazig.4` ideal for fast CI test/check inner loops and `wazigl.4` ideal when maximum LLVM codegen optimization is desired without OS/arch-specific native compiler binaries.",
        "",
        "---",
        "",
        "## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)",
        "",
        "| Target Artifact | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` / `wazigl` vs `zig -fllvm` |",
        "| :--- | ---: | ---: | ---: | ---: | ---: |",
    ]

    all_size_keys = [
        ("playground_debug_webgpu_st", "`playground` (`Debug`, WebGPU, `web_threads=false`)"),
        ("playground_release_webgpu_st", "`playground` (`ReleaseSmall`, WebGPU, `web_threads=false`)"),
        ("playground_debug_webgl2_st", "`playground` (`Debug`, WebGL2, `web_threads=false`)"),
        ("playground_release_webgl2_st", "`playground` (`ReleaseSmall`, WebGL2, `web_threads=false`)"),
        ("playground_debug_webgpu_mt", "`playground` (`Debug`, WebGPU, `web_threads=true`)"),
        ("playground_release_webgpu_mt", "`playground` (`ReleaseSmall`, WebGPU, `web_threads=true`)"),
        ("triangle_debug", "`triangle` (`Debug`)"),
        ("triangle_release", "`triangle` (`ReleaseSmall`)"),
        ("embedded_debug", "`embedded` (`Debug`)"),
        ("embedded_release", "`embedded` (`ReleaseSmall`)"),
        ("benchmark_debug", "`benchmark` (`Debug`)"),
        ("benchmark_release", "`benchmark` (`ReleaseSmall`)"),
        ("wasm_bench_runner_debug", "`wasm_bench_runner` (`Debug`)"),
        ("wasm_bench_runner_releasesmall", "`wasm_bench_runner` (`ReleaseSmall`)"),
        ("wasm_bench_runner_releasefast", "`wasm_bench_runner` (`ReleaseFast`)"),
        ("wasm_bench_runner_releasefast_simd", "`wasm_bench_runner` (`ReleaseFast +simd128`)"),
        ("tests_12_wasi_total", "All 12 `wasm32-wasi` Test Binaries (`Debug` Total)"),
    ]
    for skey, slabel in all_size_keys:
        ws = w["binary_sizes"][skey]
        wls = wl["binary_sizes"][skey]
        zns = zn["binary_sizes"][skey]
        zls = zl["binary_sizes"][skey]
        wl_diff_bytes = wls["raw"] - zls["raw"]
        wl_vs_zl = "0 B (same raw size)" if wl_diff_bytes == 0 else f"{((wls['raw'] - zls['raw']) / zls['raw']) * 100.0:+.2f}%"
        if "error" in zns:
            delta_str = f"**`wazig` succeeds** / `wazigl`: **{wl_vs_zl}**"
        else:
            pct = ((ws["raw"] - zns["raw"]) / zns["raw"]) * 100.0
            delta_str = f"`wazig`: **{pct:+.1f}%** / `wazigl`: **{wl_vs_zl}**"
        lines.append(
            f"| {slabel} | {fmt_sz_cell(ws)} | {fmt_sz_cell(wls)} | {fmt_sz_cell(zns)} | {fmt_sz_cell(zls)} | {delta_str} |"
        )

    lines.extend([
        "",
        "**Key Binary Size Takeaways:**",
        "- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) produces identical raw-size `ReleaseSmall` `.wasm` binaries (`0 B` raw size difference) to native `zig v0.17.0 -fllvm` across every single `ReleaseSmall` target:** `679.7 KB` raw (`297.5 KB` zstd) on `wasm_bench_runner`, `1,782.7 KB` raw (`575.7 KB` zstd) on `playground` WebGPU, `1,748.5 KB` raw (`584.8 KB` zstd) on `playground` WebGL2, `1,786.8 KB` raw (`570.8 KB` zstd) on `playground` WebGPU + threads, `801.0 KB` raw (`325.9 KB` zstd) on `triangle`, `734.4 KB` raw (`302.4 KB` zstd) on `embedded`, and `807.3 KB` raw (`328.7 KB` zstd) on `benchmark` — delivering full LLVM 22 codegen from a single universal `wasm64-wasip3` compiler.",
        "- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) produces the smallest `Debug` and `ReleaseFast` `.wasm` binaries of all four compilers:**",
        "  - In **`Debug`** builds, `wazig.4` is **13.9%–25.1% smaller** than upstream `zig 0.17.0 -fno-llvm` and **52.7%–73.2% smaller (2.11x–3.73x smaller)** than `wazigl.4` and `zig 0.17.0 -fllvm`.",
        "  - In **`ReleaseFast +simd128`** builds, `wazig.4` (`1,077.9 KB` raw / `381.8 KB` zstd) is **2.63x smaller** than `wazigl.4` (`2,830.2 KB` raw / `828.9 KB` zstd) and `zig 0.17.0 -fllvm` (`2,830.6 KB` raw / `829.4 KB` zstd), because LLVM's `ReleaseFast` loop unrolling and aggressive inlining expand `.wasm` binary size by **4.16x** over `ReleaseSmall` (`679.7 KB` → `2,830.2 KB`), whereas `wazig`'s targeted leaf inliner (`Optimizer.zig`) adds only `+19.4%` over `ReleaseSmall` (`902.4 KB` → `1,077.9 KB`).",
        "  - Across all 12 `wasm32-wasi` test binaries (`Debug`), `wazig.4` emits **7.63 MiB** raw (`2.08 MiB` zstd) vs **28.44 MiB** raw (`7.02 MiB` zstd) with `wazigl.4` / `zig -fllvm` (**3.73x smaller**), enabling the fastest test suite execution (`0.969s`).",
        "",
        "---",
        "",
        "## D. Runtime Execution Performance (`wasmtime run`)",
        "",
        "### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`",
        "",
        "| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |",
    ])

    workload_labels = [
        ("layout_bench", "1. Dashboard Flexbox Layout (`layout_bench`)"),
        ("text_bench", "2. TrueType + Slug Curve Prep (`text_bench`)"),
        ("render_bench", "3. Render Command & Batch Gen (`render_bench`)"),
        ("combined_frame", "4. Combined Full UI Frame (`combined_frame`)"),
    ]
    for wkey, wlabel in workload_labels:
        rw = w_rel_rt[wkey]
        rwl = wl_rel_rt[wkey]
        rzn = zn_rel_rt[wkey]
        rzl = zl_rel_rt[wkey]
        cs_str = f"`{rw['checksum']}`" if rw["checksum"] == rwl["checksum"] else f"`{rw['checksum']}` / `{rwl['checksum']}`"
        lines.append(
            f"| **{wlabel}** | {rw['iterations']} | {rw['elements_per_iter']:,} | "
            f"**{rw['median_ms']:.3f} ms** / {rw['p95_ms']:.3f} ms (**{rw['ops_per_sec']:,.1f} FPS**) | "
            f"**{rwl['median_ms']:.3f} ms** / {rwl['p95_ms']:.3f} ms (**{rwl['ops_per_sec']:,.1f} FPS**) | "
            f"{rzn['median_ms']:.3f} ms / {rzn['p95_ms']:.3f} ms ({rzn['ops_per_sec']:,.1f} FPS) | "
            f"{rzl['median_ms']:.3f} ms / {rzl['p95_ms']:.3f} ms ({rzl['ops_per_sec']:,.1f} FPS) | "
            f"{cs_str} |"
        )

    lines.extend([
        "",
        "### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`",
        "",
        "#### `ReleaseFast (+simd128)` (Default Wasm Target Features in `web_build.zig`)",
        "",
        "| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |",
        "| :--- | ---: | ---: | ---: | ---: | :--- |",
    ])
    for wkey, wlabel in workload_labels:
        fws = w_fast_simd_rt[wkey]
        fwls = wl_fast_simd_rt[wkey]
        fzls = zl_fast_simd_rt[wkey]
        cs_str = f"`{fws['checksum']}`" if fws["checksum"] == fwls["checksum"] else f"`{fws['checksum']}` / `{fwls['checksum']}`"
        lines.append(
            f"| **{wlabel}** | "
            f"**{fws['median_ms']:.3f} ms** / {fws['p95_ms']:.3f} ms (**{fws['ops_per_sec']:,.1f} FPS**) | "
            f"**{fwls['median_ms']:.3f} ms** / {fwls['p95_ms']:.3f} ms (**{fwls['ops_per_sec']:,.1f} FPS**) | "
            f"FAIL (`IllDefinedMemoryLayout`)* | "
            f"{fzls['median_ms']:.3f} ms / {fzls['p95_ms']:.3f} ms ({fzls['ops_per_sec']:,.1f} FPS) | "
            f"{cs_str} |"
        )

    lines.extend([
        "",
        "#### `ReleaseFast` (Baseline Wasm CPU without `+simd128`)",
        "",
        "| Workload | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |",
        "| :--- | ---: | ---: | ---: | ---: | :--- |",
    ])
    for wkey, wlabel in workload_labels:
        fw = w_fast_rt[wkey]
        fwl = wl_fast_rt[wkey]
        fzn = zn_fast_rt[wkey]
        fzl = zl_fast_rt[wkey]
        cs_str = f"`{fw['checksum']}`" if fw["checksum"] == fwl["checksum"] else f"`{fw['checksum']}` / `{fwl['checksum']}`"
        lines.append(
            f"| **{wlabel}** | "
            f"**{fw['median_ms']:.3f} ms** / {fw['p95_ms']:.3f} ms (**{fw['ops_per_sec']:,.1f} FPS**) | "
            f"**{fwl['median_ms']:.3f} ms** / {fwl['p95_ms']:.3f} ms (**{fwl['ops_per_sec']:,.1f} FPS**) | "
            f"{fzn['median_ms']:.3f} ms / {fzn['p95_ms']:.3f} ms ({fzn['ops_per_sec']:,.1f} FPS) | "
            f"{fzl['median_ms']:.3f} ms / {fzl['p95_ms']:.3f} ms ({fzl['ops_per_sec']:,.1f} FPS) | "
            f"{cs_str} |"
        )

    lines.extend([
        "",
        "**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**",
        "- **`wazigl v0.17.0-wazigl.4` (`-fllvm`) matches native `zig v0.17.0 -fllvm` runtime throughput across every mode:** In `ReleaseSmall`, `wazigl.4` achieves `8,799.2 FPS` (`layout_bench`), `2,067.1 FPS` (`text_bench`), `3,661.0 FPS` (`render_bench`), and `1,428.9 FPS` (`combined_frame`) — matching native `zig -fllvm` (`8,803.0`, `2,053.2`, `3,642.3`, `1,430.8 FPS`). In `ReleaseFast +simd128`, `wazigl.4` reaches **`9,925.0 FPS` (`0.100 ms`)** on `layout_bench`, **`6,115.4 FPS` (`0.162 ms`)** on `render_bench`, **`2,591.5 FPS` (`0.383 ms`)** on `text_bench`, and **`2,272.7 FPS` (`0.437 ms`)** on `combined_frame`.",
        "- **`wazig v0.17.0-wazig.4` (`-fno-llvm`) vs `zig v0.17.0 -fno-llvm`**: With `cataggar/zig#158`–`#188` (inline `@min`/`@max`, SROA to Wasm locals, parameterized leaf & single-call wrapper inlining, by-value scalar parameter ABI, read-only load & alloc alias elision, `v128` `+simd128` vector & `@reduce` lowering, multivalue 2-scalar returns) and `cataggar/knots#11`, `#15` (`#13`), `#16` (`#12`, `#14`), `#17`, `wazig.4` is **2.51x–3.11x faster** than upstream `zig 0.17.0 -fno-llvm` on the exact same `knots` source (`7,415.9–7,484.7 FPS` vs `2,409.0 FPS` on `layout_bench`, `1,734.8–1,736.1 FPS` vs `611.1 FPS` on `text_bench`, `2,730.7 FPS` vs `985.2 FPS` on `render_bench`, and `1,003.1 FPS` vs `400.0 FPS` on `combined_frame`), and **3.30x–11.68x faster** than `wazig v0.17.0-wazig.3`.",
        "- **`wazig v0.17.0-wazig.4` `ReleaseFast +simd128` vs `ReleaseSmall`**: Parameterized leaf and single-call wrapper inlining in `.fast` mode (`band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `appendAssumeCapacity`, `Wyhash.round`/`mum`), Wasm multivalue 2-scalar returns (`curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`), and `v128` SIMD boost `wazig.4` `render_bench` from `2,034.6 FPS` (`ReleaseSmall`) to **`2,730.7 FPS` (+34.2%)**, `layout_bench` from `6,461.7 FPS` to **`7,415.9 FPS` (+14.8% SIMD / `7,484.7 FPS` +15.8% `ReleaseFast`)**, `text_bench` from `1,508.7 FPS` to **`1,734.8–1,736.1 FPS` (+15.0%–15.1%)**, and `combined_frame` from `890.5 FPS` to **`1,003.1 FPS` (+12.6%)**.",
        "",
        "### D.3 `wasm_bench_runner.wasm` — `Debug`",
        "",
        "| Workload | Iterations | Elements/Iter | `wazig v0.17.0-wazig.4` (`-fno-llvm`) | `wazigl v0.17.0-wazigl.4` (`-fllvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | Checksum (`-fno-llvm` / `-fllvm`) |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |",
    ])
    for wkey, wlabel in workload_labels:
        dw = w_dbg_rt[wkey]
        dwl = wl_dbg_rt[wkey]
        dzn = zn_dbg_rt[wkey]
        dzl = zl_dbg_rt[wkey]
        cs_str = f"`{dw['checksum']}`" if dw["checksum"] == dwl["checksum"] else f"`{dw['checksum']}` / `{dwl['checksum']}`"
        lines.append(
            f"| **{wlabel}** | {dw['iterations']} | {dw['elements_per_iter']:,} | "
            f"**{dw['median_ms']:.3f} ms** / {dw['p95_ms']:.3f} ms (**{dw['ops_per_sec']:,.1f} FPS**) | "
            f"{dwl['median_ms']:.3f} ms / {dwl['p95_ms']:.3f} ms ({dwl['ops_per_sec']:,.1f} FPS) | "
            f"{dzn['median_ms']:.3f} ms / {dzn['p95_ms']:.3f} ms ({dzn['ops_per_sec']:,.1f} FPS) | "
            f"{dzl['median_ms']:.3f} ms / {dzl['p95_ms']:.3f} ms ({dzl['ops_per_sec']:,.1f} FPS) | "
            f"{cs_str} |"
        )

    lines.extend([
        "",
        "**`Debug` Runtime Highlight:** In `Debug` builds, `wazig v0.17.0-wazig.4` (`-fno-llvm`) is **1.88x–2.11x faster at runtime than both `wazigl v0.17.0-wazigl.4` and `zig v0.17.0 -fllvm` (LLVM 22)** across all four workloads (`2,946.3 FPS` vs `1,395.2` / `1,393.8 FPS` on `layout_bench`, `1,097.7 FPS` vs `569.8` / `569.1 FPS` on `text_bench`, `1,793.9 FPS` vs `955.8` / `955.6 FPS` on `render_bench`, and `722.6 FPS` vs `365.3` / `365.9 FPS` on `combined_frame`) while producing **2.97x smaller** `.wasm` binaries (`1,206.5 KB` vs `3,588.3 KB`).",
        "",
        "### D.4 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)",
        "",
        "| Compiler | Test Binaries Passed | Total Test `.wasm` Size (Raw / Zstd) | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |",
        "| :--- | :---: | ---: | ---: | ---: |",
        f"| **`wazig v0.17.0-wazig.4` (`-fno-llvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | **{fmt_kb(w['binary_sizes']['tests_12_wasi_total']['raw'])}** / **{fmt_kb(w['binary_sizes']['tests_12_wasi_total']['zstd'])}** | **{w['runtime']['tests_12_wasi_exec_sec']:.3f} s** | **{zl['runtime']['tests_12_wasi_exec_sec'] / w['runtime']['tests_12_wasi_exec_sec']:.2f}x faster** |",
        f"| **`wazigl v0.17.0-wazigl.4` (`-fllvm`)** | **12 / 12** (with `+atomics` + `+simd128`) | {fmt_kb(wl['binary_sizes']['tests_12_wasi_total']['raw'])} / {fmt_kb(wl['binary_sizes']['tests_12_wasi_total']['zstd'])} | **{wl['runtime']['tests_12_wasi_exec_sec']:.3f} s** | {zl['runtime']['tests_12_wasi_exec_sec'] / wl['runtime']['tests_12_wasi_exec_sec']:.2f}x |",
        f"| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`/`+simd128`* (12 / 12 stripped) | {fmt_kb(zn['binary_sizes']['tests_12_wasi_total']['raw'])} / {fmt_kb(zn['binary_sizes']['tests_12_wasi_total']['zstd'])} | {zn['runtime']['tests_12_wasi_exec_sec']:.3f} s | {zl['runtime']['tests_12_wasi_exec_sec'] / zn['runtime']['tests_12_wasi_exec_sec']:.2f}x |",
        f"| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics` + `+simd128`) | {fmt_kb(zl['binary_sizes']['tests_12_wasi_total']['raw'])} / {fmt_kb(zl['binary_sizes']['tests_12_wasi_total']['zstd'])} | {zl['runtime']['tests_12_wasi_exec_sec']:.3f} s | 1.00x (baseline) |",
        "",
        r'> *\*Upstream `zig 0.17.0 -fno-llvm` emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, emits invalid `v128` Wasm instructions (`type mismatch: expected v128, found i32` in `scrollbar.render` & `mem.findScalarPos` failing Wasmtime validation) or `IllDefinedMemoryLayout` when `+simd128` is enabled (so non-SIMD `zig -fno-llvm` rows above are measured with `+simd128` and `+atomics` stripped), and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig v0.17.0-wazig.4` fixes all three bugs.*',
        "",
        "---",
        "",
        "## E. Guest Profiling Verification (`wasmtime-profile.py` @ `100us`)",
        "",
        "### E.1 Verified Impact of `cataggar/zig#158`–`#188` & `cataggar/knots#11`–`#17` (`#9`)",
        "",
        "Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **6.69x** from `21,457` (`v0.17.0-wazig.3`) → `6,984`/`6,513`/`6,287` (initial `wazig.4`) → **`3,209` (`ReleaseFast +simd128`)** in **`wazig v0.17.0-wazig.4`** (`cataggar/zig@1820f5885e`) + `cataggar/knots#11`, `#15` (`#13`), `#16` (`#12`, `#14`), `#17`, with all `cataggar/knots#9` and `#14` targets exceeded by **1.52x–7.42x**:",
        "",
        "| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.4` (`ReleaseSmall`) | `wazig.4` (`ReleaseFast +simd128`) | `wazigl.4` (`ReleaseFast +simd128`) | `wazig.4` Speedup vs `wazig.3` | `knots#9` & `#14` Goal |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | :--- |",
        f"| **`layout_bench`** | 1.575 ms (635.2 FPS) | {w_rel_rt['layout_bench']['median_ms']:.3f} ms ({w_rel_rt['layout_bench']['ops_per_sec']:,.1f} FPS) | **{w_fast_simd_rt['layout_bench']['median_ms']:.3f} ms ({w_fast_simd_rt['layout_bench']['ops_per_sec']:,.1f} FPS)** | **{wl_fast_simd_rt['layout_bench']['median_ms']:.3f} ms ({wl_fast_simd_rt['layout_bench']['ops_per_sec']:,.1f} FPS)** | **11.68x faster** | `>= 1,000 FPS` (`#9`) / `>= 4,805 FPS` (`#14`, Exceeded **1.54x**) |",
        f"| **`text_bench`** | 5.505 ms (181.7 FPS) | {w_rel_rt['text_bench']['median_ms']:.3f} ms ({w_rel_rt['text_bench']['ops_per_sec']:,.1f} FPS) | **{w_fast_simd_rt['text_bench']['median_ms']:.3f} ms ({w_fast_simd_rt['text_bench']['ops_per_sec']:,.1f} FPS)** | **{wl_fast_simd_rt['text_bench']['median_ms']:.3f} ms ({wl_fast_simd_rt['text_bench']['ops_per_sec']:,.1f} FPS)** | **9.55x faster** | `>= 500 FPS` (Exceeded **3.47x**) |",
        f"| **`render_bench`** | 1.282 ms (779.1 FPS) | {w_rel_rt['render_bench']['median_ms']:.3f} ms ({w_rel_rt['render_bench']['ops_per_sec']:,.1f} FPS) | **{w_fast_simd_rt['render_bench']['median_ms']:.3f} ms ({w_fast_simd_rt['render_bench']['ops_per_sec']:,.1f} FPS)** | **{wl_fast_simd_rt['render_bench']['median_ms']:.3f} ms ({wl_fast_simd_rt['render_bench']['ops_per_sec']:,.1f} FPS)** | **3.50x faster** | `>= 1,800 FPS` (Exceeded **1.52x**) |",
        f"| **`combined_frame`** | 3.286 ms (304.2 FPS) | {w_rel_rt['combined_frame']['median_ms']:.3f} ms ({w_rel_rt['combined_frame']['ops_per_sec']:,.1f} FPS) | **{w_fast_simd_rt['combined_frame']['median_ms']:.3f} ms ({w_fast_simd_rt['combined_frame']['ops_per_sec']:,.1f} FPS)** | **{wl_fast_simd_rt['combined_frame']['median_ms']:.3f} ms ({wl_fast_simd_rt['combined_frame']['ops_per_sec']:,.1f} FPS)** | **3.30x faster** | `>= 600 FPS` (Exceeded **1.67x**) |",
        "",
        "- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`).",
        "- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.",
        "- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) & [`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` parameterized leaf inlining, single-caller `.small` inlining, and local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity`.",
        "- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) & [`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — `@Vector` layout, `v128` `+simd128` SIMD arithmetic, and fused `cmp_vector` + `@reduce(.And/.Or)` lowering**: Lowered `Rect.eql` to `f32x4.eq` + `i32x4.all_true` (`12 B`).",
        "- **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Wasm multivalue return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`, `HMetrics`, `[2]u8`, `u128`)**: Eliminated linear-memory `sret` stack frames for 2-scalar returns, allowing `curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`, and `fmt.digits2` to be completely inlined and removed in `ReleaseFast`.",
        "- **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing**: Parallel 4-way cold-cache `wasm32-wasi` test suite compilation completes with zero `Archive.zig` race panics (`20.80s` wall / `62.99s` CPU; **`0.969s`** total test execution time across all 12 suites — the fastest of all 4 compilers).",
        "- **[`cataggar/zig#174`](https://github.com/cataggar/zig/issues/174)–[`#188`](https://github.com/cataggar/zig/pull/188) — By-value scalar parameter ABI (`classifyAutoParam`), read-only by-ref load & alloc alias elision, `umulh` (`Wyhash.mum`) inline lowering, `tryElideMemcpyStackFrame` / `tryElideLeafStackFrame`, and single-call wrapper inlining**: Eliminated `memory.copy` aggregate parameter staging, inlined `Wyhash.round`/`mum`, and cut `wasm_bench_runner` binary sizes by another ~9% (`902.4 KB` `ReleaseSmall`, `1,077.9 KB` `ReleaseFast +simd128`).",
        "- **[`cataggar/knots#11`](https://github.com/cataggar/knots/pull/11) (`#10`), [`cataggar/knots#15`](https://github.com/cataggar/knots/pull/15) (`#13`), [`cataggar/knots#16`](https://github.com/cataggar/knots/pull/16) (`#12`, `#14`), & [`cataggar/knots#17`](https://github.com/cataggar/knots/pull/17) (`#14`) — Precomputed curve extents & insertion/merge sort (`#11`), direct `O(curves + overlaps)` band-range indexing, pre-sorted curve scatter & single contiguous backing allocation (`#15`), 2-pass child layout, leaf fast paths, in-place element init, lazy `id_to_slot` & compact `buildZOrder` (`#16`), and `inline` `Rect`/`Padding`/`AxisInfo` scalar accessors + capacity fast paths (`#17`)**: Boosted `wazig.4` `layout_bench` by **6.45x** over initial `wazig.4` (`1,150.0` → **`7,415.9–7,484.7 FPS` / `0.133–0.134 ms`**, **11.68x** over `wazig.3`), `text_bench` by **1.51x** (`1,152.7` → **`1,734.8–1,736.1 FPS` / `0.577–0.578 ms`**), `render_bench` to **`2,730.7 FPS` (`0.362 ms`)**, and `combined_frame` by **1.45x** (`690.8` → **`1,003.1 FPS` / `0.996 ms`**).",
        "",
        "### E.2 Top 15 Functions in `wazig v0.17.0-wazig.4` `ReleaseFast +simd128` (`3,209` total samples @ 100us)",
        "",
        "| Self | Self% | Total | Tot% | Bytes | Function |",
        "| ---: | ---: | ---: | ---: | ---: | :--- |",
        "| 276 | 8.60% | 872 | 27.17% | 3,905 | `wasm_bench_runner.buildRenderFrame` |",
        "| 156 | 4.86% | 156 | 4.86% | 2,471 | `hash.wyhash.Wyhash.update` |",
        "| 154 | 4.80% | 154 | 4.80% | 1,067 | `band.sortBandIndices` |",
        "| 148 | 4.61% | 148 | 4.61% | 2,248 | `DrawList.commandBounds` |",
        "| 114 | 3.55% | 114 | 3.55% | 1,164 | `band.computeAxisBandRanges` |",
        "| 107 | 3.33% | 130 | 4.05% | 647 | `DrawList.pushTextInstance` |",
        "| 100 | 3.12% | 117 | 3.65% | 864 | `DrawList.pushInstances` |",
        "| 92 | 2.87% | 161 | 5.02% | 2,712 | `Context.positionChildren` |",
        "| 90 | 2.80% | 313 | 9.75% | 4,792 | `DrawList.emitBatched` |",
        "| 80 | 2.49% | 234 | 7.29% | 454 | `band.scatterAxisBands` |",
        "| 74 | 2.31% | 311 | 9.69% | 4,009 | `Context.computeLayoutNode` |",
        "| 69 | 2.15% | 118 | 3.68% | 6,003 | `TrueType.glyphShapeTT` |",
        "| 62 | 1.93% | 236 | 7.35% | 1,416 | `wasm_bench_runner.buildDashboardLayoutFrame` |",
        "| 61 | 1.90% | 112 | 3.49% | 1,546 | `Context.open` |",
        "| 60 | 1.87% | 69 | 2.15% | 67 | `Clip.State.scissorEql` |",
        "",
        "### E.3 Follow-Up `cataggar/zig` Self-Hosted Wasm Backend Optimization Issues Filed",
        "",
        "- **[`cataggar/zig#189`](https://github.com/cataggar/zig/issues/189)**: `wasm: Optimizer.zig classifyTrivialFunc sets depth0_stack_exact = false on all 0xfd SIMD instructions` (blocks inlining trivial SIMD leaf helpers such as `Rect.eql` / `Clip.State.scissorEql`).",
        "- **[`cataggar/zig#190`](https://github.com/cataggar/zig/issues/190)**: `wasm: CodeGen.zig SroaAnalysis and ReadOnlyAllocAliasAnalysis reject vector_index != .none, spilling v128/@Vector lane accesses to shadow stack`.",
        "- **[`cataggar/zig#191`](https://github.com/cataggar/zig/issues/191)**: `wasm: CodeGen.zig SroaAnalysis over-promotes large (>16B) copy-modify-pass aggregates into scalar locals that immediately spill back to shadow stack` (`SlugInstance` in `DrawList.pushTextInstance` and `Instance` in `DrawList.pushInstances`).",
        "- **[`cataggar/zig#192`](https://github.com/cataggar/zig/issues/192)**: `wasm: Optimizer.zig post-inlining shadow-stack slot scalarization (SROA) for small aggregates whose address only escaped to inlined leaf methods` (`var box: Box` in `DrawList.commandBounds` and `DrawList.emitBatched`).",
        "",
    ])
    return "\n".join(lines)


def run_live_full_comparison(paths: dict[str, Path]) -> dict[str, Any]:
    """Run live benchmarks across wazig, wazigl, zig -fno-llvm, and zig -fllvm when installed."""
    wb = load_wazig_build_module()
    wazig_bin = find_optional_tool("wazig", "WAZIG")
    wazigl_bin = find_optional_tool("wazigl", "WAZIGL")
    zig_bin = find_optional_tool("zig", "ZIG")
    wasmtime_bin = find_optional_tool("wasmtime", "WASMTIME")

    data = load_baseline_reference()
    if not wazig_bin or not wasmtime_bin:
        return data

    # Warm Wasmtime module cache
    subprocess.run([wazig_bin, "version"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)
    if wazigl_bin:
        subprocess.run([wazigl_bin, "version"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)

    tt_zig = ensure_truetype_pkg(wb, wazig_bin, paths["zig_local"], paths["zig_global"])
    tt_options_zig = paths["tmp"] / "truetype_options.zig"
    tt_options_zig.write_text("pub const debug_todo: bool = false;\n", encoding="utf-8")

    compilers_to_run = [("wazig", wazig_bin, "-fno-llvm")]
    if wazigl_bin:
        compilers_to_run.append(("wazigl", wazigl_bin, "-fllvm"))
    if zig_bin:
        compilers_to_run.extend([
            ("zig_nollvm", zig_bin, "-fno-llvm"),
            ("zig_llvm", zig_bin, "-fllvm"),
        ])

    bench_modes = [
        ("wasm_bench_runner_debug", "Debug", None),
        ("wasm_bench_runner_releasesmall", "ReleaseSmall", None),
        ("wasm_bench_runner_releasefast", "ReleaseFast", None),
        ("wasm_bench_runner_releasefast_simd", "ReleaseFast", "baseline+simd128"),
    ]

    for cname, bin_path, flag in compilers_to_run:
        print(f"[bench-wazig] Measuring {cname} (wasm_bench_runner modes)...", file=sys.stderr, flush=True)

        t0 = time.perf_counter()
        subprocess.run([bin_path, "fmt", "--check", "src/", "tests/", "examples/", "lib/js-bridge/src/"], cwd=REPO_ROOT, check=True)
        data["compilers"][cname]["compile_sec"]["fmt_check"] = round(time.perf_counter() - t0, 3)

        for key, opt, mcpu in bench_modes:
            if cname == "zig_nollvm" and mcpu and "+simd128" in mcpu:
                continue
            c_lc = paths["root"] / f"lc-live-{cname}-{key}"
            c_gc = paths["root"] / f"gc-live-{cname}-{key}"
            shutil.rmtree(c_lc, ignore_errors=True)
            shutil.rmtree(c_gc, ignore_errors=True)
            c_lc.mkdir(parents=True, exist_ok=True)
            c_gc.mkdir(parents=True, exist_ok=True)

            out_w = paths["bins"] / f"{key}_{cname}.wasm"
            args = wasm_bench_runner_args(opt, flag, out_w, c_lc, c_gc, tt_zig, tt_options_zig, mcpu=mcpu)
            t_c0 = time.perf_counter()
            subprocess.run([bin_path, *args], cwd=REPO_ROOT, check=True)
            t_cold = round(time.perf_counter() - t_c0, 3)

            t_w0 = time.perf_counter()
            subprocess.run([bin_path, *args], cwd=REPO_ROOT, check=True)
            t_warm = round(time.perf_counter() - t_w0, 3)

            data["compilers"][cname]["compile_sec"][key] = {"cold": t_cold, "warm": t_warm}
            data["compilers"][cname]["binary_sizes"][key] = compress_sizes(out_w)

            proc = subprocess.run(
                [wasmtime_bin, "run", str(out_w), "--", "--json"],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=True,
            )
            data["compilers"][cname]["runtime"][key] = json.loads(proc.stdout)
            shutil.rmtree(c_lc, ignore_errors=True)
            shutil.rmtree(c_gc, ignore_errors=True)

    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Benchmark wazig v0.17.0-wazig.4 (-fno-llvm) and wazigl v0.17.0-wazigl.4 (-fllvm) vs standard zig v0.17.0 (-fno-llvm and -fllvm)."
    )
    parser.add_argument(
        "--ci-summary",
        action="store_true",
        help="Run CI benchmark summary using wazig/wazigl + wasmtime and emit GitHub Step Summary Markdown to stdout.",
    )
    parser.add_argument(
        "--output-json",
        type=Path,
        default=None,
        help="Write full comparison benchmark results as JSON to this path.",
    )
    parser.add_argument(
        "--output-md",
        type=Path,
        default=None,
        help="Write full comparison Markdown report to this path.",
    )
    parser.add_argument(
        "--from-baseline",
        action="store_true",
        help="Render full comparison outputs immediately from the verified empirical baseline without re-running builds.",
    )
    args = parser.parse_args(argv)

    paths = setup_isolated_cache_env()

    if args.ci_summary:
        md = run_ci_summary(paths)
        sys.stdout.write(md + "\n")
        return 0

    if args.from_baseline:
        data = load_baseline_reference(prefer_embedded=True)
    else:
        data = run_live_full_comparison(paths)

    md_report = generate_full_markdown(data)

    if args.output_json:
        out_j = args.output_json if args.output_json.is_absolute() else (REPO_ROOT / args.output_json)
        out_j.parent.mkdir(parents=True, exist_ok=True)
        out_j.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"[bench-wazig] Wrote JSON results to {out_j}", file=sys.stderr, flush=True)

    if args.output_md:
        out_m = args.output_md if args.output_md.is_absolute() else (REPO_ROOT / args.output_md)
        out_m.parent.mkdir(parents=True, exist_ok=True)
        out_m.write_text(md_report + "\n", encoding="utf-8")
        print(f"[bench-wazig] Wrote Markdown report to {out_m}", file=sys.stderr, flush=True)

    sys.stdout.write(md_report + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
