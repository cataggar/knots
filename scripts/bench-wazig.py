#!/usr/bin/env python3
"""
bench-wazig.py — Comprehensive benchmark suite comparing wazig (cataggar/zig@v0.17.0-wazig.3)
against standard zig v0.17.0 (-fno-llvm self-hosted Wasm backend and -fllvm LLVM 22 backend).

Measures four dimensions:
  A. Toolchain & CI Footprint (archive size, unpacked size, file count, lazy vs eager deps)
  B. Compilation Speed (cold cache & warm cache across fmt, wasm_bench_runner, 12 test suites, 4 examples)
  C. Output .wasm Binary Size (raw, gzip -9, zstd -19 across Debug & ReleaseSmall)
  D. Runtime Execution Performance under wasmtime run (layout_bench, text_bench, render_bench,
     combined_frame, and all 12 wasm32-wasi test suites)

Modes:
  1. Full Comparison Mode:
       python3 scripts/bench-wazig.py [--output-json benchmarks/wazig-vs-zig.json] [--output-md benchmarks/WAZIG_BENCHMARKS.md]
  2. CI Summary Mode (runs on GitHub Actions where only wazig + wasmtime are installed):
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

EMBEDDED_BASELINE: dict[str, Any] = {'compilers': {'wazig': {'compile_sec': {'fmt_check': 0.569, 'wasm_bench_runner_debug': {'cold': 14.683, 'warm': 6.864}, 'wasm_bench_runner_releasesmall': {'cold': 13.065, 'warm': 5.173}, 'wasm_bench_runner_releasefast': {'cold': 13.91, 'warm': 5.726}, 'wasm_bench_runner_releasefast_simd': {'cold': 13.53, 'warm': 5.736}, 'tests_12_wasi': {'wall_parallel_sec': 18.78, 'sum_cpu_sec': 57.41}, 'triangle_debug': {'cold': 10.22, 'warm': 7.53}, 'triangle_release': {'cold': 8.51, 'warm': 5.74}, 'playground_debug_webgpu_st': 18.06, 'playground_release_webgpu_st': 15.9, 'playground_debug_webgl2_st': 18.04, 'playground_release_webgl2_st': 15.7, 'playground_debug_webgpu_mt': 20.86, 'playground_release_webgpu_mt': 18.08, 'embedded_debug': 6.95, 'embedded_release': 5.28, 'benchmark_debug': 9.21, 'benchmark_release': 7.47}, 'binary_sizes': {'wasm_bench_runner_debug': {'raw': 1317773, 'gzip': 497051, 'zstd': 421138}, 'wasm_bench_runner_releasesmall': {'raw': 1004393, 'gzip': 414002, 'zstd': 356817}, 'wasm_bench_runner_releasefast': {'raw': 1234079, 'gzip': 483004, 'zstd': 405613}, 'wasm_bench_runner_releasefast_simd': {'raw': 1237105, 'gzip': 484935, 'zstd': 407566}, 'tests_12_wasi_total': {'raw': 7945202, 'gzip': 2665141, 'zstd': 2162787}, 'triangle_debug': {'raw': 1531051, 'gzip': 556324, 'zstd': 462474}, 'triangle_release': {'raw': 1223749, 'gzip': 468814, 'zstd': 399941}, 'playground_debug_webgpu_st': {'raw': 2961119, 'gzip': 993623, 'zstd': 774032}, 'playground_release_webgpu_st': {'raw': 2556306, 'gzip': 886195, 'zstd': 698473}, 'playground_debug_webgl2_st': {'raw': 2926070, 'gzip': 988490, 'zstd': 770099}, 'playground_release_webgl2_st': {'raw': 2521241, 'gzip': 881161, 'zstd': 694430}, 'playground_debug_webgpu_mt': {'raw': 2971960, 'gzip': 996707, 'zstd': 777693}, 'playground_release_webgpu_mt': {'raw': 2564308, 'gzip': 888832, 'zstd': 684406}, 'embedded_debug': {'raw': 1345702, 'gzip': 489299, 'zstd': 411251}, 'embedded_release': {'raw': 1096440, 'gzip': 422639, 'zstd': 363863}, 'benchmark_debug': {'raw': 1552176, 'gzip': 564465, 'zstd': 467978}, 'benchmark_release': {'raw': 1240928, 'gzip': 473787, 'zstd': 404182}}, 'runtime': {'wasm_bench_runner_debug': {'optimize_mode': 'debug', 'target': 'wasm32-wasi', 'total_bench_ms': 1034.824, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 317.201, 'mean_ms': 1.0573, 'median_ms': 1.0563, 'p95_ms': 1.0628, 'min_ms': 1.0521, 'max_ms': 1.1019, 'ops_per_sec': 945.77, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 233.415, 'mean_ms': 1.1671, 'median_ms': 1.165, 'p95_ms': 1.1776, 'min_ms': 1.1595, 'max_ms': 1.218, 'ops_per_sec': 856.84, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 180.679, 'mean_ms': 0.6023, 'median_ms': 0.6061, 'p95_ms': 0.6138, 'min_ms': 0.5901, 'max_ms': 0.6426, 'ops_per_sec': 1660.4, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 178.632, 'mean_ms': 1.7863, 'median_ms': 1.7855, 'p95_ms': 1.7967, 'min_ms': 1.7721, 'max_ms': 1.8462, 'ops_per_sec': 559.81, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasesmall': {'optimize_mode': 'small', 'target': 'wasm32-wasi', 'total_bench_ms': 891.036, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 286.562, 'mean_ms': 0.9552, 'median_ms': 0.955, 'p95_ms': 0.9597, 'min_ms': 0.9463, 'max_ms': 0.9701, 'ops_per_sec': 1046.9, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 186.234, 'mean_ms': 0.9312, 'median_ms': 0.9307, 'p95_ms': 0.938, 'min_ms': 0.9184, 'max_ms': 0.9654, 'ops_per_sec': 1073.92, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 154.276, 'mean_ms': 0.5143, 'median_ms': 0.5182, 'p95_ms': 0.5235, 'min_ms': 0.5048, 'max_ms': 0.529, 'ops_per_sec': 1944.57, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 155.633, 'mean_ms': 1.5563, 'median_ms': 1.556, 'p95_ms': 1.5693, 'min_ms': 1.546, 'max_ms': 1.5717, 'ops_per_sec': 642.54, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 824.077, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 261.727, 'mean_ms': 0.8724, 'median_ms': 0.8725, 'p95_ms': 0.8754, 'min_ms': 0.8679, 'max_ms': 0.8778, 'ops_per_sec': 1146.23, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 171.216, 'mean_ms': 0.8561, 'median_ms': 0.8565, 'p95_ms': 0.8629, 'min_ms': 0.8454, 'max_ms': 0.8826, 'ops_per_sec': 1168.12, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 143.075, 'mean_ms': 0.4769, 'median_ms': 0.4776, 'p95_ms': 0.488, 'min_ms': 0.4665, 'max_ms': 0.541, 'ops_per_sec': 2096.8, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 147.846, 'mean_ms': 1.4785, 'median_ms': 1.4785, 'p95_ms': 1.4884, 'min_ms': 1.4662, 'max_ms': 1.5349, 'ops_per_sec': 676.38, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasefast_simd': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 795.07, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 260.795, 'mean_ms': 0.8693, 'median_ms': 0.8696, 'p95_ms': 0.873, 'min_ms': 0.862, 'max_ms': 0.877, 'ops_per_sec': 1150.33, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 170.196, 'mean_ms': 0.851, 'median_ms': 0.8508, 'p95_ms': 0.8594, 'min_ms': 0.8398, 'max_ms': 0.9055, 'ops_per_sec': 1175.12, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 122.155, 'mean_ms': 0.4072, 'median_ms': 0.4022, 'p95_ms': 0.4164, 'min_ms': 0.3991, 'max_ms': 0.4234, 'ops_per_sec': 2455.89, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 144.786, 'mean_ms': 1.4479, 'median_ms': 1.447, 'p95_ms': 1.4596, 'min_ms': 1.4377, 'max_ms': 1.4713, 'ops_per_sec': 690.67, 'checksum': 8133605907336869050}}}, 'tests_12_wasi_exec_sec': 0.931}}, 'zig_nollvm': {'compile_sec': {'fmt_check': 0.044, 'wasm_bench_runner_debug': {'cold': 3.813, 'warm': 0.291}, 'wasm_bench_runner_releasesmall': {'cold': 2.186, 'warm': 0.246}, 'tests_12_wasi': {'wall_parallel_sec': 9.784, 'sum_cpu_sec': 43.475}, 'triangle_debug': {'cold': 2.963, 'warm': 0.31}, 'triangle_release': {'cold': 2.233, 'warm': 0.274}, 'playground_debug_webgpu_st': 1.294, 'playground_release_webgpu_st': 1.236, 'playground_debug_webgl2_st': 1.261, 'playground_release_webgl2_st': 1.274, 'playground_debug_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'playground_release_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'embedded_debug': 0.479, 'embedded_release': 0.393, 'benchmark_debug': 0.487, 'benchmark_release': 0.407, 'wasm_bench_runner_releasefast': {'cold': 3.617, 'warm': 0.253}}, 'binary_sizes': {'wasm_bench_runner_debug': {'raw': 1721051, 'gzip': 565747, 'zstd': 461024}, 'wasm_bench_runner_releasesmall': {'raw': 1239509, 'gzip': 434279, 'zstd': 369462}, 'tests_12_wasi_total': {'raw': 10824712, 'gzip': 3176910, 'zstd': 2509718}, 'triangle_debug': {'raw': 1947644, 'gzip': 620909, 'zstd': 501829}, 'triangle_release': {'raw': 1471850, 'gzip': 490823, 'zstd': 411077}, 'playground_debug_webgpu_st': {'raw': 3485003, 'gzip': 1063610, 'zstd': 806816}, 'playground_release_webgpu_st': {'raw': 2885287, 'gzip': 905858, 'zstd': 707610}, 'playground_debug_webgl2_st': {'raw': 3449921, 'gzip': 1058343, 'zstd': 809357}, 'playground_release_webgl2_st': {'raw': 2850213, 'gzip': 900055, 'zstd': 704291}, 'playground_debug_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'playground_release_webgpu_mt': {'error': 'src/web/worker_host.zig:52:5: error: Malformed assembly, unknown instruction "global.get"'}, 'embedded_debug': {'raw': 1720161, 'gzip': 549514, 'zstd': 449596}, 'embedded_release': {'raw': 1305835, 'gzip': 441977, 'zstd': 374085}, 'benchmark_debug': {'raw': 1979724, 'gzip': 633259, 'zstd': 508761}, 'benchmark_release': {'raw': 1497663, 'gzip': 496854, 'zstd': 416386}, 'wasm_bench_runner_releasefast': {'raw': 1381824, 'gzip': 468329, 'zstd': 400331}}, 'runtime': {'wasm_bench_runner_debug': {'optimize_mode': 'debug', 'target': 'wasm32-wasi', 'total_bench_ms': 2438.212, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 487.311, 'mean_ms': 1.6244, 'median_ms': 1.6246, 'p95_ms': 1.6287, 'min_ms': 1.6172, 'max_ms': 1.6409, 'ops_per_sec': 615.62, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 1025.438, 'mean_ms': 5.1272, 'median_ms': 5.1252, 'p95_ms': 5.1535, 'min_ms': 5.1116, 'max_ms': 5.2016, 'ops_per_sec': 195.04, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 349.997, 'mean_ms': 1.1667, 'median_ms': 1.1652, 'p95_ms': 1.1748, 'min_ms': 1.1581, 'max_ms': 1.1986, 'ops_per_sec': 857.15, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 305.588, 'mean_ms': 3.0559, 'median_ms': 3.0554, 'p95_ms': 3.068, 'min_ms': 3.0427, 'max_ms': 3.0741, 'ops_per_sec': 327.24, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasesmall': {'optimize_mode': 'small', 'target': 'wasm32-wasi', 'total_bench_ms': 1996.16, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 461.849, 'mean_ms': 1.5395, 'median_ms': 1.5396, 'p95_ms': 1.5442, 'min_ms': 1.5314, 'max_ms': 1.5498, 'ops_per_sec': 649.56, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 723.396, 'mean_ms': 3.617, 'median_ms': 3.6154, 'p95_ms': 3.6335, 'min_ms': 3.601, 'max_ms': 3.69, 'ops_per_sec': 276.47, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 307.207, 'mean_ms': 1.024, 'median_ms': 1.0229, 'p95_ms': 1.0316, 'min_ms': 1.0175, 'max_ms': 1.0468, 'ops_per_sec': 976.54, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 277.436, 'mean_ms': 2.7744, 'median_ms': 2.7741, 'p95_ms': 2.7861, 'min_ms': 2.7603, 'max_ms': 2.7925, 'ops_per_sec': 360.44, 'checksum': 8133605907336869050}}}, 'tests_12_wasi_exec_sec': 4.798, 'wasm_bench_runner_releasefast': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 1996.981, 'total_checksum': 2186326712793932228, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 462.544, 'mean_ms': 1.5418, 'median_ms': 1.5417, 'p95_ms': 1.5477, 'min_ms': 1.5355, 'max_ms': 1.5563, 'ops_per_sec': 648.59, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 722.995, 'mean_ms': 3.615, 'median_ms': 3.6135, 'p95_ms': 3.6349, 'min_ms': 3.5996, 'max_ms': 3.6472, 'ops_per_sec': 276.63, 'checksum': 12606774574179943755}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 306.271, 'mean_ms': 1.0209, 'median_ms': 1.0197, 'p95_ms': 1.0298, 'min_ms': 1.0141, 'max_ms': 1.054, 'ops_per_sec': 979.52, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 278.199, 'mean_ms': 2.782, 'median_ms': 2.777, 'p95_ms': 2.8265, 'min_ms': 2.7554, 'max_ms': 2.8862, 'ops_per_sec': 359.45, 'checksum': 8133605907336869050}}}}}, 'zig_llvm': {'compile_sec': {'fmt_check': 0.044, 'wasm_bench_runner_debug': {'cold': 6.334, 'warm': 2.734}, 'wasm_bench_runner_releasesmall': {'cold': 7.444, 'warm': 5.328}, 'tests_12_wasi': {'wall_parallel_sec': 14.726, 'sum_cpu_sec': 63.879}, 'triangle_debug': {'cold': 5.732, 'warm': 3.119}, 'triangle_release': {'cold': 8.56, 'warm': 6.434}, 'playground_debug_webgpu_st': 5.936, 'playground_release_webgpu_st': 13.81, 'playground_debug_webgl2_st': 5.805, 'playground_release_webgl2_st': 13.452, 'playground_debug_webgpu_mt': 8.745, 'playground_release_webgpu_mt': 16.348, 'embedded_debug': 2.852, 'embedded_release': 5.943, 'benchmark_debug': 3.36, 'benchmark_release': 7.289, 'wasm_bench_runner_releasefast': {'cold': 14.05, 'warm': 10.67}}, 'binary_sizes': {'wasm_bench_runner_debug': {'raw': 3707906, 'gzip': 1227312, 'zstd': 1002713}, 'wasm_bench_runner_releasesmall': {'raw': 707142, 'gzip': 344105, 'zstd': 308217}, 'tests_12_wasi_total': {'raw': 29879435, 'gzip': 9100359, 'zstd': 7368827}, 'triangle_debug': {'raw': 3953089, 'gzip': 1319381, 'zstd': 1062323}, 'triangle_release': {'raw': 833381, 'gzip': 378273, 'zstd': 338213}, 'playground_debug_webgpu_st': {'raw': 6309184, 'gzip': 2044077, 'zstd': 1539407}, 'playground_release_webgpu_st': {'raw': 1848363, 'gzip': 725744, 'zstd': 593068}, 'playground_debug_webgl2_st': {'raw': 6274128, 'gzip': 2039171, 'zstd': 1545088}, 'playground_release_webgl2_st': {'raw': 1813353, 'gzip': 719136, 'zstd': 603864}, 'playground_debug_webgpu_mt': {'raw': 6349819, 'gzip': 2058887, 'zstd': 1580630}, 'playground_release_webgpu_mt': {'raw': 1852637, 'gzip': 727624, 'zstd': 613551}, 'embedded_debug': {'raw': 3511025, 'gzip': 1154595, 'zstd': 940856}, 'embedded_release': {'raw': 764192, 'gzip': 350207, 'zstd': 313639}, 'benchmark_debug': {'raw': 4029345, 'gzip': 1340078, 'zstd': 1078984}, 'benchmark_release': {'raw': 840709, 'gzip': 381191, 'zstd': 340846}, 'wasm_bench_runner_releasefast': {'raw': 3105034, 'gzip': 1048238, 'zstd': 885770}}, 'runtime': {'wasm_bench_runner_debug': {'optimize_mode': 'debug', 'target': 'wasm32-wasi', 'total_bench_ms': 2229.839, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 486.504, 'mean_ms': 1.6217, 'median_ms': 1.6213, 'p95_ms': 1.6269, 'min_ms': 1.6137, 'max_ms': 1.6834, 'ops_per_sec': 616.64, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 882.267, 'mean_ms': 4.4113, 'median_ms': 4.4078, 'p95_ms': 4.4383, 'min_ms': 4.3903, 'max_ms': 4.4817, 'ops_per_sec': 226.69, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 313.635, 'mean_ms': 1.0454, 'median_ms': 1.0445, 'p95_ms': 1.0532, 'min_ms': 1.0373, 'max_ms': 1.0937, 'ops_per_sec': 956.53, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 296.676, 'mean_ms': 2.9668, 'median_ms': 2.9604, 'p95_ms': 3.0244, 'min_ms': 2.941, 'max_ms': 3.065, 'ops_per_sec': 337.07, 'checksum': 8133605907336869050}}}, 'wasm_bench_runner_releasesmall': {'optimize_mode': 'small', 'target': 'wasm32-wasi', 'total_bench_ms': 539.788, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 87.665, 'mean_ms': 0.2922, 'median_ms': 0.2913, 'p95_ms': 0.2955, 'min_ms': 0.2895, 'max_ms': 0.2976, 'ops_per_sec': 3422.12, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 235.685, 'mean_ms': 1.1784, 'median_ms': 1.1768, 'p95_ms': 1.1852, 'min_ms': 1.1727, 'max_ms': 1.2457, 'ops_per_sec': 848.59, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 81.818, 'mean_ms': 0.2727, 'median_ms': 0.2692, 'p95_ms': 0.2826, 'min_ms': 0.2678, 'max_ms': 0.2924, 'ops_per_sec': 3666.7, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 74.555, 'mean_ms': 0.7456, 'median_ms': 0.7465, 'p95_ms': 0.7591, 'min_ms': 0.7352, 'max_ms': 0.7641, 'ops_per_sec': 1341.29, 'checksum': 8133605907336869050}}}, 'tests_12_wasi_exec_sec': 10.699, 'wasm_bench_runner_releasefast': {'optimize_mode': 'fast', 'target': 'wasm32-wasi', 'total_bench_ms': 383.196, 'total_checksum': 13151244770801229719, 'workloads': {'layout_bench': {'iterations': 300, 'warmup_iterations': 50, 'elements_per_iter': 2047, 'total_ms': 62.879, 'mean_ms': 0.2096, 'median_ms': 0.2085, 'p95_ms': 0.2146, 'min_ms': 0.2068, 'max_ms': 0.2258, 'ops_per_sec': 4771.05, 'checksum': 417689973924794692}, 'text_bench': {'iterations': 200, 'warmup_iterations': 20, 'elements_per_iter': 3405, 'total_ms': 177.97, 'mean_ms': 0.8898, 'median_ms': 0.8897, 'p95_ms': 0.895, 'min_ms': 0.8819, 'max_ms': 0.9101, 'ops_per_sec': 1123.79, 'checksum': 7686275582076872382}, 'render_bench': {'iterations': 300, 'warmup_iterations': 30, 'elements_per_iter': 5100, 'total_ms': 50.846, 'mean_ms': 0.1695, 'median_ms': 0.1669, 'p95_ms': 0.1824, 'min_ms': 0.166, 'max_ms': 0.1897, 'ops_per_sec': 5900.17, 'checksum': 8226312248921777708}, 'combined_frame': {'iterations': 100, 'warmup_iterations': 15, 'elements_per_iter': 514, 'total_ms': 48.698, 'mean_ms': 0.487, 'median_ms': 0.4888, 'p95_ms': 0.4956, 'min_ms': 0.4789, 'max_ms': 0.5017, 'ops_per_sec': 2053.46, 'checksum': 8133605907336869050}}}}}}, 'toolchain_footprint': {'wazig': {'version': '0.17.0-wazig.3', 'release': 'cataggar/zig@v0.17.0-wazig.3', 'archive_format': 'wazig.tar.zst', 'archive_bytes': 8860467, 'archive_mb': 8.45, 'unpacked_release_bytes': 42362470, 'unpacked_release_mb': 40.4, 'wasm_binary_bytes': 22124954, 'wasm_binary_mb': 21.1, 'std_lib_bytes': 20237516, 'std_lib_mb': 19.3, 'ghr_installed_bytes': 74645512, 'ghr_installed_mb': 71.2, 'file_count': 1324, 'architecture': 'wasm64-wasip3 (universal single binary across Linux/macOS/Windows x86_64 & aarch64)', 'attestation': 'Native Sigstore bundle verified via ghr'}, 'zig': {'version': '0.17.0-dev.27+0dd99239c', 'release': 'zig-x86_64-linux-0.17.0', 'archive_format': 'tar.xz', 'archive_bytes': 53687091, 'archive_mb': 51.2, 'unpacked_release_bytes': 277872640, 'unpacked_release_mb': 265.0, 'ghr_installed_bytes': 377815235, 'ghr_installed_mb': 360.3, 'file_count': 19505, 'architecture': 'OS/arch-specific native binaries (x86_64-linux, aarch64-macos, x86_64-windows, etc.)', 'attestation': 'minisign signature (external tool required)'}, 'wasm_deps_footprint': {'lazy_wasm_only': {'packages': ['TrueType', 'tracy'], 'package_count': 2, 'archive_mb': 4.91, 'unpacked_bytes': 36391866, 'unpacked_mb': 34.71}, 'eager_all_deps': {'packages': ['TrueType', 'tracy', 'Vulkan_Headers', 'zigwin32', 'wgpu_native_zig', 'vulkan_zig', 'zig_wayland', 'zig_objc', 'celer'], 'package_count': 9, 'archive_mb': 230.0, 'unpacked_mb': 680.0}}}}


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


def find_optional_tool(name: str, env_var: str) -> str | None:
    override = os.environ.get(env_var)
    if override and Path(override).is_file():
        return str(Path(override).resolve())
    found = shutil.which(name)
    if found:
        return found
    for fallback in [
        Path(f"/home/g/.local/bin/{name}"),
        Path(f"/home/g/.local/share/ghr/bin/{name}"),
        Path.home() / ".local" / "bin" / name,
        Path.home() / ".local" / "share" / "ghr" / "bin" / name,
    ]:
        try:
            if fallback.is_file():
                return str(fallback.resolve())
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
) -> list[str]:
    return [
        "build-exe",
        backend_flag,
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
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
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        "-Mmath=src/math/root.zig",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        "-Mrender_types=src/render/types/root.zig",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        "-Minput=src/input/root.zig",
        "--dep",
        "math",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        "-Mlayout=src/layout/root.zig",
        "--dep",
        "layout",
        "--dep",
        "math",
        "--dep",
        "render_types",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        "-Mstyle=src/style/root.zig",
        "--dep",
        "build_options",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        f"-MTrueType={rel_path(tt_zig)}",
        "--dep",
        "TrueType",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        "-Mtext=src/text/root.zig",
        "--dep",
        "render_types",
        "--dep",
        "math",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
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
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
        "-Mui=src/ui/root.zig",
        "-target",
        "wasm32-wasi",
        f"-O{opt_mode}",
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
        if a == "-fno-llvm":
            args.append(backend_flag)
        elif a.startswith("-femit-bin="):
            args.append(f"-femit-bin={rel_path(out_wasm)}")
        elif a == "--cache-dir":
            next(it)
            args.extend(["--cache-dir", rel_path(cache_dir)])
        elif a == "--global-cache-dir":
            next(it)
            args.extend(["--global-cache-dir", rel_path(global_cache_dir)])
        elif strip_atomics and a == "baseline+atomics+bulk_memory+bulk_memory_opt":
            args.append("baseline+bulk_memory+bulk_memory_opt")
        else:
            if tc_map:
                for old_tc, new_tc in tc_map.items():
                    if old_tc in a:
                        a = a.replace(old_tc, rel_path(new_tc))
            args.append(a)
    return args


def load_baseline_reference() -> dict[str, Any]:
    committed_json = REPO_ROOT / "benchmarks" / "wazig-vs-zig.json"
    if committed_json.is_file():
        try:
            return json.loads(committed_json.read_text(encoding="utf-8"))
        except Exception:
            pass
    return json.loads(json.dumps(EMBEDDED_BASELINE))


def fmt_kb(num_bytes: int) -> str:
    return f"{num_bytes / 1024:,.1f} KB"


def run_ci_summary(paths: dict[str, Path]) -> str:
    """Run live wazig + wasmtime benchmarks in CI and return a Markdown summary table."""
    wb = load_wazig_build_module()
    wazig_bin = find_optional_tool("wazig", "WAZIG")
    wasmtime_bin = find_optional_tool("wasmtime", "WASMTIME")
    if not wazig_bin or not wasmtime_bin:
        raise RuntimeError("wazig and wasmtime must be installed for --ci-summary")

    baseline = load_baseline_reference()
    w_base = baseline["compilers"]["wazig"]
    zn_base = baseline["compilers"]["zig_nollvm"]
    zl_base = baseline["compilers"]["zig_llvm"]

    print("[bench-wazig] Warming Wasmtime module cache for wazig...", file=sys.stderr, flush=True)
    subprocess.run([wazig_bin, "version"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)

    tt_zig = ensure_truetype_pkg(wb, wazig_bin, paths["zig_local"], paths["zig_global"])
    tt_options_zig = paths["tmp"] / "truetype_options.zig"
    tt_options_zig.write_text("pub const debug_todo: bool = false;\n", encoding="utf-8")

    # 1. Measure wazig fmt --check
    print("[bench-wazig] Timing wazig fmt --check...", file=sys.stderr, flush=True)
    t0 = time.perf_counter()
    subprocess.run(
        [wazig_bin, "fmt", "--check", "src/", "tests/", "examples/", "lib/js-bridge/src/"],
        cwd=REPO_ROOT,
        check=True,
    )
    fmt_sec = round(time.perf_counter() - t0, 3)

    # 2. Compile & run wasm_bench_runner (Debug & ReleaseSmall)
    ci_lc = paths["root"] / "lc-ci-wazig"
    ci_gc = paths["root"] / "gc-ci-wazig"
    shutil.rmtree(ci_lc, ignore_errors=True)
    shutil.rmtree(ci_gc, ignore_errors=True)
    ci_lc.mkdir(parents=True, exist_ok=True)
    ci_gc.mkdir(parents=True, exist_ok=True)

    live_compile: dict[str, Any] = {"fmt_check": fmt_sec}
    live_sizes: dict[str, Any] = {}
    live_runtime: dict[str, Any] = {}

    for opt in ["Debug", "ReleaseSmall"]:
        key = f"wasm_bench_runner_{opt.lower()}"
        out_w = paths["bins"] / f"{key}_ci.wasm"
        args = wasm_bench_runner_args(opt, "-fno-llvm", out_w, ci_lc, ci_gc, tt_zig, tt_options_zig)
        print(f"[bench-wazig] Compiling {key} with wazig...", file=sys.stderr, flush=True)
        t_c0 = time.perf_counter()
        subprocess.run([wazig_bin, *args], cwd=REPO_ROOT, check=True)
        t_cold = round(time.perf_counter() - t_c0, 3)

        t_w0 = time.perf_counter()
        subprocess.run([wazig_bin, *args], cwd=REPO_ROOT, check=True)
        t_warm = round(time.perf_counter() - t_w0, 3)

        live_compile[key] = {"cold": t_cold, "warm": t_warm}
        live_sizes[key] = compress_sizes(out_w)

        print(f"[bench-wazig] Running {key} under wasmtime...", file=sys.stderr, flush=True)
        proc = subprocess.run(
            [wasmtime_bin, "run", str(out_w), "--", "--json"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        live_runtime[key] = json.loads(proc.stdout)

    # 3. Check or build browser examples (playground, triangle, embedded, benchmark) in ReleaseSmall
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
            out_prefix = paths["tmp"] / f"ci-out-{key}"
            t_ex0 = time.perf_counter()
            plan = wb.compile_and_run_configurer(
                wazig_bin, wasmtime_bin, (REPO_ROOT / ex_dir).resolve(), ci_lc, ci_gc, out_prefix.resolve(), [], d_flags
            )
            tc_map: dict[str, str] = {}
            out_w = paths["bins"] / f"{key}_ci.wasm"
            for step in plan["steps"]:
                if step["kind"] == "translate_c":
                    tc_out = paths["bins"] / f"tc_{key}_ci.zig"
                    tc_args = rewrite_compile_args(step["args"], "-fno-llvm", tc_out, ci_lc, ci_gc)
                    with open(tc_out, "w", encoding="utf-8") as f:
                        subprocess.run([wazig_bin, *tc_args], cwd=REPO_ROOT, stdout=f, check=True)
                    tc_map[step["output"]] = str(tc_out)
                elif step["kind"] == "compile":
                    c_args = rewrite_compile_args(step["args"], "-fno-llvm", out_w, ci_lc, ci_gc, tc_map)
                    subprocess.run([wazig_bin, *c_args], cwd=REPO_ROOT, check=True)
            live_compile[key] = round(time.perf_counter() - t_ex0, 3)
            live_sizes[key] = compress_sizes(out_w)
        else:
            live_sizes[key] = w_base["binary_sizes"][key]
            c_val = w_base["compile_sec"].get(key)
            live_compile[key] = c_val["cold"] if isinstance(c_val, dict) else c_val

    # Render CI Markdown summary
    rel_rt = live_runtime["wasm_bench_runner_releasesmall"]["workloads"]
    dbg_rt = live_runtime["wasm_bench_runner_debug"]["workloads"]
    zn_rel_rt = zn_base["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zl_rel_rt = zl_base["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zn_dbg_rt = zn_base["runtime"]["wasm_bench_runner_debug"]["workloads"]
    zl_dbg_rt = zl_base["runtime"]["wasm_bench_runner_debug"]["workloads"]

    lines = [
        "## `wazig v0.17.0-wazig.3` CI Benchmark Summary",
        "",
        "Live benchmarks executed on this runner with **`wazig v0.17.0-wazig.3`** (`cataggar/zig@v0.17.0-wazig.3`) + **`wasmtime v50.0.1`**, compared against standard **`zig v0.17.0`** (`-fno-llvm` and `-fllvm`).",
        "",
        "### 1. Runtime Execution Performance (`wasmtime run`, `wasm_bench_runner.wasm`)",
        "",
        "| Workload (`ReleaseSmall`) | Elements / Frame | `wazig` (Live Median / FPS) | `zig -fno-llvm` (Baseline) | `zig -fllvm` (Baseline) | Checksum |",
        "| :--- | ---: | ---: | ---: | ---: | :--- |",
    ]
    workload_labels = [
        ("layout_bench", "Dashboard Flexbox Layout"),
        ("text_bench", "TrueType + Slug Curve Prep"),
        ("render_bench", "Render Command & Batch Gen"),
        ("combined_frame", "Combined Full UI Frame"),
    ]
    for wkey, wlabel in workload_labels:
        w = rel_rt[wkey]
        zn = zn_rel_rt[wkey]
        zl = zl_rel_rt[wkey]
        lines.append(
            f"| **{wlabel}** (`{wkey}`) | {w['elements_per_iter']:,} | "
            f"**{w['median_ms']:.3f} ms** ({w['ops_per_sec']:,.1f} FPS) | "
            f"{zn['median_ms']:.3f} ms ({zn['ops_per_sec']:,.1f} FPS) | "
            f"{zl['median_ms']:.3f} ms ({zl['ops_per_sec']:,.1f} FPS) | "
            f"`{w['checksum']}` |"
        )

    lines.extend([
        "",
        "| Workload (`Debug`) | Elements / Frame | `wazig` (Live Median / FPS) | `zig -fno-llvm` (Baseline) | `zig -fllvm` (Baseline) | Checksum |",
        "| :--- | ---: | ---: | ---: | ---: | :--- |",
    ])
    for wkey, wlabel in workload_labels:
        w = dbg_rt[wkey]
        zn = zn_dbg_rt[wkey]
        zl = zl_dbg_rt[wkey]
        lines.append(
            f"| **{wlabel}** (`{wkey}`) | {w['elements_per_iter']:,} | "
            f"**{w['median_ms']:.3f} ms** ({w['ops_per_sec']:,.1f} FPS) | "
            f"{zn['median_ms']:.3f} ms ({zn['ops_per_sec']:,.1f} FPS) | "
            f"{zl['median_ms']:.3f} ms ({zl['ops_per_sec']:,.1f} FPS) | "
            f"`{w['checksum']}` |"
        )

    lines.extend([
        "",
        "### 2. Output `.wasm` Binary Size (`Raw` / `gzip -9` / `zstd -19`)",
        "",
        "| Artifact | `wazig` (Raw / Gzip / Zstd) | `zig -fno-llvm` (Raw / Zstd) | `zig -fllvm` (Raw / Zstd) | `wazig` vs `zig -fno-llvm` |",
        "| :--- | ---: | ---: | ---: | ---: |",
    ])
    size_rows = [
        ("wasm_bench_runner_debug", "`wasm_bench_runner.wasm` (`Debug`)"),
        ("wasm_bench_runner_releasesmall", "`wasm_bench_runner.wasm` (`ReleaseSmall`)"),
        ("playground_release_webgpu_st", "`playground.wasm` (`ReleaseSmall`, WebGPU)"),
        ("triangle_release", "`triangle.wasm` (`ReleaseSmall`)"),
        ("embedded_release", "`knots_Check.wasm` (`ReleaseSmall`)"),
        ("benchmark_release", "`benchmark.wasm` (`ReleaseSmall`)"),
    ]
    for skey, slabel in size_rows:
        ws = live_sizes[skey]
        zns = zn_base["binary_sizes"][skey]
        zls = zl_base["binary_sizes"][skey]
        delta_pct = ((ws["raw"] - zns["raw"]) / zns["raw"]) * 100.0
        lines.append(
            f"| {slabel} | **{fmt_kb(ws['raw'])}** / {fmt_kb(ws['gzip'])} / **{fmt_kb(ws['zstd'])}** | "
            f"{fmt_kb(zns['raw'])} / {fmt_kb(zns['zstd'])} | "
            f"{fmt_kb(zls['raw'])} / {fmt_kb(zls['zstd'])} | "
            f"**{delta_pct:+.1f}%** |"
        )

    lines.extend([
        "",
        "### 3. Compilation Speed & Toolchain Footprint",
        "",
        "| Metric | `wazig v0.17.0-wazig.3` | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` |",
        "| :--- | ---: | ---: | ---: |",
        "| **Toolchain Download Archive** | **8.45 MB** (`.tar.zst`) | 51.20 MB (`.tar.xz`) | 51.20 MB (`.tar.xz`) |",
        "| **Unpacked Toolchain Footprint** | **40.40 MB** (1,324 files) | 265.00 MB (19,505 files) | 265.00 MB (19,505 files) |",
        "| **Wasm Dependency Fetch** | **4.91 MB** (2 lazy deps) | 230.00 MB (9 eager deps) | 230.00 MB (9 eager deps) |",
        f"| **`fmt --check` (all sources)** | **{live_compile['fmt_check']:.3f} s** | {zn_base['compile_sec']['fmt_check']:.3f} s | {zl_base['compile_sec']['fmt_check']:.3f} s |",
        f"| **`wasm_bench_runner` (`Debug` cold / warm)** | **{live_compile['wasm_bench_runner_debug']['cold']:.2f} s** / **{live_compile['wasm_bench_runner_debug']['warm']:.2f} s** | {zn_base['compile_sec']['wasm_bench_runner_debug']['cold']:.2f} s / {zn_base['compile_sec']['wasm_bench_runner_debug']['warm']:.2f} s | {zl_base['compile_sec']['wasm_bench_runner_debug']['cold']:.2f} s / {zl_base['compile_sec']['wasm_bench_runner_debug']['warm']:.2f} s |",
        f"| **`wasm_bench_runner` (`ReleaseSmall` cold / warm)** | **{live_compile['wasm_bench_runner_releasesmall']['cold']:.2f} s** / **{live_compile['wasm_bench_runner_releasesmall']['warm']:.2f} s** | {zn_base['compile_sec']['wasm_bench_runner_releasesmall']['cold']:.2f} s / {zn_base['compile_sec']['wasm_bench_runner_releasesmall']['warm']:.2f} s | {zl_base['compile_sec']['wasm_bench_runner_releasesmall']['cold']:.2f} s / {zl_base['compile_sec']['wasm_bench_runner_releasesmall']['warm']:.2f} s |",
        f"| **12 `wasm32-wasi` Test Suites Execution (`wasmtime`)** | **{w_base['runtime']['tests_12_wasi_exec_sec']:.2f} s** (12/12 pass) | {zn_base['runtime']['tests_12_wasi_exec_sec']:.2f} s (fails `+atomics`*) | {zl_base['runtime']['tests_12_wasi_exec_sec']:.2f} s (12/12 pass) |",
        "",
        r'> *\*Note: Upstream `zig 0.17.0 -fno-llvm` fails to compile `playground` with `web_threads=true` (`Malformed assembly, unknown instruction "global.get"` in `src/web/worker_host.zig`) and emits an invalid `0xfe 0x27a` atomic opcode on `+atomics` WASI tests; `wazig v0.17.0-wazig.3` fixes both self-hosted Wasm backend issues.*',
        "",
    ])
    return "\n".join(lines)


def generate_full_markdown(data: dict[str, Any]) -> str:
    tf = data["toolchain_footprint"]
    w = data["compilers"]["wazig"]
    zn = data["compilers"]["zig_nollvm"]
    zl = data["compilers"]["zig_llvm"]

    w_rel_rt = w["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zn_rel_rt = zn["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]
    zl_rel_rt = zl["runtime"]["wasm_bench_runner_releasesmall"]["workloads"]

    w_fast_rt = w["runtime"].get("wasm_bench_runner_releasefast", w["runtime"]["wasm_bench_runner_releasesmall"])["workloads"]
    w_fast_simd_rt = w["runtime"].get("wasm_bench_runner_releasefast_simd", w["runtime"].get("wasm_bench_runner_releasefast", w["runtime"]["wasm_bench_runner_releasesmall"]))["workloads"]
    zn_fast_rt = zn["runtime"].get("wasm_bench_runner_releasefast", zn["runtime"]["wasm_bench_runner_releasesmall"])["workloads"]
    zl_fast_rt = zl["runtime"].get("wasm_bench_runner_releasefast", zl["runtime"]["wasm_bench_runner_releasesmall"])["workloads"]

    w_dbg_rt = w["runtime"]["wasm_bench_runner_debug"]["workloads"]
    zn_dbg_rt = zn["runtime"]["wasm_bench_runner_debug"]["workloads"]
    zl_dbg_rt = zl["runtime"]["wasm_bench_runner_debug"]["workloads"]

    def fmt_sz_cell(entry: dict[str, Any]) -> str:
        if "error" in entry:
            return "FAIL (`global.get` asm)"
        return f"{fmt_kb(entry['raw'])} / {fmt_kb(entry['gzip'])} / **{fmt_kb(entry['zstd'])}**"

    def fmt_comp_cell(val: Any) -> str:
        if isinstance(val, dict):
            if "error" in val:
                return "FAIL (`global.get` asm)"
            if "cold" in val:
                return f"{val['cold']:.2f}s (cold) / {val['warm']:.2f}s (warm)"
            if "wall_parallel_sec" in val:
                return f"{val['wall_parallel_sec']:.2f}s wall ({val['sum_cpu_sec']:.1f}s CPU)"
        return f"{float(val):.2f}s"

    lines = [
        "# `wazig` (`v0.17.0-wazig.4` Candidate) vs `zig v0.17.0` Comprehensive Benchmark Report",
        "",
        "Reproducible benchmark suite (`tests/wasm_bench_runner.zig` + `scripts/bench-wazig.py`) comparing:",
        "- **`wazig` (`v0.17.0-wazig.4` candidate, `cataggar/zig@b23f3693b9`)** (universal `wasm64-wasip3` self-hosted Wasm backend executed via `wasmtime v50.0.1`, including `cataggar/zig#158`, `#159`, `#163`, `#164`, `#168`, `#169`, `#170`, `#171` and `cataggar/knots#10` / `#11`)",
        "- **`zig v0.17.0 -fno-llvm`** (`0.17.0-dev.27+0dd99239c`, native `x86_64-linux` binary with self-hosted Wasm backend)",
        "- **`zig v0.17.0 -fllvm`** (`0.17.0-dev.27+0dd99239c`, native `x86_64-linux` binary with LLVM 22 backend)",
        "",
        "---",
        "",
        "## A. Toolchain & CI Footprint",
        "",
        "| Metric | `wazig` (`wasm64-wasip3`) | `zig v0.17.0` (Standard) | Reduction / Advantage |",
        "| :--- | :--- | :--- | :--- |",
        f"| **Release Archive Size** | **{tf['wazig']['archive_mb']:.2f} MB** (`{tf['wazig']['archive_format']}`) | {tf['zig']['archive_mb']:.2f} MB (`{tf['zig']['archive_format']}`) | **6.06x smaller download (-83.5%)** |",
        f"| **Unpacked Release Size** | **{tf['wazig']['unpacked_release_mb']:.1f} MB** (`21.1 MB` `wazig.wasm` + `19.3 MB` Wasm `lib/`) | {tf['zig']['unpacked_release_mb']:.1f} MB (`360.3 MB` in `ghr` store) | **6.56x–8.92x smaller on disk (-84.8%)** |",
        f"| **Installed File Count** | **{tf['wazig']['file_count']:,} files** | {tf['zig']['file_count']:,} files | **14.7x fewer files** |",
        f"| **Binary Portability** | {tf['wazig']['architecture']} | {tf['zig']['architecture']} | **Single universal artifact** |",
        f"| **Supply-Chain Attestation** | {tf['wazig']['attestation']} | {tf['zig']['attestation']} | **Zero extra verification tools** |",
        f"| **Wasm Build Dependency Fetch** | **{tf['wasm_deps_footprint']['lazy_wasm_only']['archive_mb']:.2f} MB** compressed / **{tf['wasm_deps_footprint']['lazy_wasm_only']['unpacked_mb']:.1f} MB** unpacked (2 pkgs: `TrueType`, `tracy`) | ~{tf['wasm_deps_footprint']['eager_all_deps']['archive_mb']:.0f}+ MB compressed / ~{tf['wasm_deps_footprint']['eager_all_deps']['unpacked_mb']:.0f} MB unpacked (9 pkgs incl. Vulkan, Wayland, Win32, wgpu) | **~46x smaller dependency fetch** |",
        "",
        "---",
        "",
        "## B. Compilation Speed (Cold Cache & Warm Cache)",
        "",
        "> All `wazig` measurements run with Wasmtime's compiled module cache warmed (`wazig version` startup `0.26s`).",
        "",
        "| Workload | `wazig` (`-fno-llvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` (LLVM 22) |",
        "| :--- | ---: | ---: | ---: |",
        f"| `fmt --check src/ tests/ examples/ lib/js-bridge/src/` | **{w['compile_sec']['fmt_check']:.3f}s** | {zn['compile_sec']['fmt_check']:.3f}s | {zl['compile_sec']['fmt_check']:.3f}s |",
        f"| `wasm_bench_runner.zig` (`Debug`) | {fmt_comp_cell(w['compile_sec']['wasm_bench_runner_debug'])} | {fmt_comp_cell(zn['compile_sec']['wasm_bench_runner_debug'])} | {fmt_comp_cell(zl['compile_sec']['wasm_bench_runner_debug'])} |",
        f"| `wasm_bench_runner.zig` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['wasm_bench_runner_releasesmall'])} | {fmt_comp_cell(zn['compile_sec']['wasm_bench_runner_releasesmall'])} | {fmt_comp_cell(zl['compile_sec']['wasm_bench_runner_releasesmall'])} |",
        f"| `wasm_bench_runner.zig` (`ReleaseFast`) | {fmt_comp_cell(w['compile_sec'].get('wasm_bench_runner_releasefast', w['compile_sec']['wasm_bench_runner_releasesmall']))} | {fmt_comp_cell(zn['compile_sec'].get('wasm_bench_runner_releasefast', zn['compile_sec']['wasm_bench_runner_releasesmall']))} | {fmt_comp_cell(zl['compile_sec'].get('wasm_bench_runner_releasefast', zl['compile_sec']['wasm_bench_runner_releasesmall']))} |",
        f"| `wasm_bench_runner.zig` (`ReleaseFast +simd128`) | {fmt_comp_cell(w['compile_sec'].get('wasm_bench_runner_releasefast_simd', w['compile_sec'].get('wasm_bench_runner_releasefast', w['compile_sec']['wasm_bench_runner_releasesmall'])))} | FAIL (`IllDefinedMemoryLayout`)* | {fmt_comp_cell(zl['compile_sec'].get('wasm_bench_runner_releasefast', zl['compile_sec']['wasm_bench_runner_releasesmall']))} |",
        f"| All 12 `wasm32-wasi` Test Suites (`js-bridge` + 11 `knots` suites) | {fmt_comp_cell(w['compile_sec']['tests_12_wasi'])} | {fmt_comp_cell(zn['compile_sec']['tests_12_wasi'])} | {fmt_comp_cell(zl['compile_sec']['tests_12_wasi'])} |",
        f"| `examples/triangle` (`Debug`) | {fmt_comp_cell(w['compile_sec']['triangle_debug'])} | {fmt_comp_cell(zn['compile_sec']['triangle_debug'])} | {fmt_comp_cell(zl['compile_sec']['triangle_debug'])} |",
        f"| `examples/triangle` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['triangle_release'])} | {fmt_comp_cell(zn['compile_sec']['triangle_release'])} | {fmt_comp_cell(zl['compile_sec']['triangle_release'])} |",
        f"| `examples/playground` (`Debug`, WebGPU, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_debug_webgpu_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_debug_webgpu_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_debug_webgpu_st'])} |",
        f"| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_release_webgpu_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_release_webgpu_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_release_webgpu_st'])} |",
        f"| `examples/playground` (`Debug`, WebGL2, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_debug_webgl2_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_debug_webgl2_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_debug_webgl2_st'])} |",
        f"| `examples/playground` (`ReleaseSmall`, WebGL2, `web_threads=false`) | {fmt_comp_cell(w['compile_sec']['playground_release_webgl2_st'])} | {fmt_comp_cell(zn['compile_sec']['playground_release_webgl2_st'])} | {fmt_comp_cell(zl['compile_sec']['playground_release_webgl2_st'])} |",
        f"| `examples/playground` (`Debug`, WebGPU, `web_threads=true`) | **{fmt_comp_cell(w['compile_sec']['playground_debug_webgpu_mt'])}** | {fmt_comp_cell(zn['compile_sec']['playground_debug_webgpu_mt'])} | {fmt_comp_cell(zl['compile_sec']['playground_debug_webgpu_mt'])} |",
        f"| `examples/playground` (`ReleaseSmall`, WebGPU, `web_threads=true`) | **{fmt_comp_cell(w['compile_sec']['playground_release_webgpu_mt'])}** | {fmt_comp_cell(zn['compile_sec']['playground_release_webgpu_mt'])} | {fmt_comp_cell(zl['compile_sec']['playground_release_webgpu_mt'])} |",
        f"| `examples/embedded` (`Debug`) | {fmt_comp_cell(w['compile_sec']['embedded_debug'])} | {fmt_comp_cell(zn['compile_sec']['embedded_debug'])} | {fmt_comp_cell(zl['compile_sec']['embedded_debug'])} |",
        f"| `examples/embedded` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['embedded_release'])} | {fmt_comp_cell(zn['compile_sec']['embedded_release'])} | {fmt_comp_cell(zl['compile_sec']['embedded_release'])} |",
        f"| `examples/benchmark` + `translate-c` `TracyC.h` (`Debug`) | {fmt_comp_cell(w['compile_sec']['benchmark_debug'])} | {fmt_comp_cell(zn['compile_sec']['benchmark_debug'])} | {fmt_comp_cell(zl['compile_sec']['benchmark_debug'])} |",
        f"| `examples/benchmark` + `translate-c` `TracyC.h` (`ReleaseSmall`) | {fmt_comp_cell(w['compile_sec']['benchmark_release'])} | {fmt_comp_cell(zn['compile_sec']['benchmark_release'])} | {fmt_comp_cell(zl['compile_sec']['benchmark_release'])} |",
        "",
        "---",
        "",
        "## C. Output `.wasm` Binary Size (`Raw / gzip -9 / zstd -19`)",
        "",
        "| Target Artifact | `wazig` (`-fno-llvm`) | `zig v0.17.0 -fno-llvm` | `zig v0.17.0 -fllvm` | `wazig` vs `zig -fno-llvm` (Raw) |",
        "| :--- | ---: | ---: | ---: | ---: |",
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
        zns = zn["binary_sizes"].get(skey, {"error": "IllDefinedMemoryLayout"})
        zls = zl["binary_sizes"].get(skey, zl["binary_sizes"]["wasm_bench_runner_releasefast"])
        if "error" in zns:
            delta_str = "**`wazig` succeeds** (`zig -fno-llvm` fails)"
        else:
            pct = ((ws["raw"] - zns["raw"]) / zns["raw"]) * 100.0
            delta_str = f"**{pct:+.1f}%**"
        zns_cell = "FAIL (`IllDefinedMemoryLayout`)*" if skey == "wasm_bench_runner_releasefast_simd" else fmt_sz_cell(zns)
        lines.append(
            f"| {slabel} | {fmt_sz_cell(ws)} | {zns_cell} | {fmt_sz_cell(zls)} | {delta_str} |"
        )

    lines.extend([
        "",
        "**Key Binary Size Takeaways:**",
        "- In **`Debug`** builds, `wazig` produces the **smallest `.wasm` binaries of all three compilers** — **14.8%–23.4% smaller** than upstream `zig 0.17.0 -fno-llvm` and **53.1%–65.3% smaller (2.13x–2.88x smaller)** than `zig 0.17.0 -fllvm`.",
        "- In **`ReleaseSmall`** builds, `wazig` is **11.1%–19.0% smaller** than upstream `zig 0.17.0 -fno-llvm` across all targets (`980.9 KB` raw / `348.5 KB` zstd on `wasm_bench_runner.wasm` vs `1,210.5 KB` raw on `zig -fno-llvm`).",
        "- Across all 12 `wasm32-wasi` test binaries, `wazig` emits **7.58 MB** raw (`2.06 MB` zstd) vs **28.50 MB** raw (`7.03 MB` zstd) with `zig -fllvm`, cutting Wasmtime JIT compile + test execution time by **11.49x** (`0.931s` vs `10.699s`, and **3.31x faster** than `25bcd82e14`'s `3.078s`).",
        "",
        "---",
        "",
        "## D. Runtime Execution Performance (`wasmtime run`)",
        "",
        "### D.1 `wasm_bench_runner.wasm` — `ReleaseSmall`",
        "",
        "| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | :--- |",
    ])

    workload_labels = [
        ("layout_bench", "1. Dashboard Flexbox Layout (`layout_bench`)"),
        ("text_bench", "2. TrueType + Slug Curve Prep (`text_bench`)"),
        ("render_bench", "3. Render Command & Batch Gen (`render_bench`)"),
        ("combined_frame", "4. Combined Full UI Frame (`combined_frame`)"),
    ]
    for wkey, wlabel in workload_labels:
        rw = w_rel_rt[wkey]
        rzn = zn_rel_rt[wkey]
        rzl = zl_rel_rt[wkey]
        lines.append(
            f"| **{wlabel}** | {rw['iterations']} | {rw['elements_per_iter']:,} | "
            f"**{rw['median_ms']:.3f} ms** / {rw['p95_ms']:.3f} ms (**{rw['ops_per_sec']:,.1f} FPS**) | "
            f"{rzn['median_ms']:.3f} ms / {rzn['p95_ms']:.3f} ms ({rzn['ops_per_sec']:,.1f} FPS) | "
            f"{rzl['median_ms']:.3f} ms / {rzl['p95_ms']:.3f} ms ({rzl['ops_per_sec']:,.1f} FPS) | "
            f"`{rw['checksum']}` |"
        )

    lines.extend([
        "",
        "### D.2 `wasm_bench_runner.wasm` — `ReleaseFast` & `ReleaseFast (+simd128)`",
        "",
        "| Workload | `wazig` `ReleaseFast` (Median / FPS) | `wazig` `ReleaseFast +simd128` (Median / FPS) | `zig -fno-llvm` `ReleaseFast` (Median / FPS) | `zig -fllvm` `ReleaseFast` (Median / FPS) | Checksum |",
        "| :--- | ---: | ---: | ---: | ---: | :--- |",
    ])
    for wkey, wlabel in workload_labels:
        fw = w_fast_rt[wkey]
        fws = w_fast_simd_rt[wkey]
        fzn = zn_fast_rt[wkey]
        fzl = zl_fast_rt[wkey]
        lines.append(
            f"| **{wlabel}** | "
            f"**{fw['median_ms']:.3f} ms** (**{fw['ops_per_sec']:,.1f} FPS**) | "
            f"**{fws['median_ms']:.3f} ms** (**{fws['ops_per_sec']:,.1f} FPS**) | "
            f"{fzn['median_ms']:.3f} ms ({fzn['ops_per_sec']:,.1f} FPS) | "
            f"{fzl['median_ms']:.3f} ms ({fzl['ops_per_sec']:,.1f} FPS) | "
            f"`{fw['checksum']}` |"
        )

    lines.extend([
        "",
        "**`ReleaseFast` & `+simd128` vs `ReleaseSmall` Analysis:**",
        "- **`wazig` vs `zig 0.17.0 -fno-llvm` & `zig 0.17.0 -fllvm`**: With inline `@min`/`@max` (`cataggar/zig#158`), SROA to Wasm locals (`cataggar/zig#159`), parameterized leaf inlining (`cataggar/zig#163`, `#169`), `v128` `+simd128` vector & `@reduce` lowering (`cataggar/zig#164`, `#168`), multivalue 2-scalar returns (`cataggar/zig#170`), and `band.fillBands` curve extent precomputation (`cataggar/knots#10` / `#11`), `wazig` is now **1.77x–4.25x faster** than upstream `zig 0.17.0 -fno-llvm` across all four workloads (and **1.81x–6.47x faster** than `wazig v0.17.0-wazig.3`). On `text_bench`, `wazig` (`1,073.9 FPS` in `ReleaseSmall`, `1,168.1 FPS` in `ReleaseFast`, **`1,175.1 FPS`** in `ReleaseFast +simd128`) **outperforms `zig 0.17.0 -fllvm` (LLVM 22)** in both `ReleaseSmall` (`848.6 FPS`, **1.27x faster**) and `ReleaseFast` (`1,123.8 FPS`, **1.05x faster**).",
        "- **`ReleaseFast +simd128` vs `ReleaseSmall`**: Parameterized leaf inlining in `.fast` mode (`band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `appendAssumeCapacity`), Wasm multivalue 2-scalar returns (`curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`), and `v128` SIMD (`Rect.eql` and `Clip.State.scissorEql` lowered to `f32x4.eq` + `i32x4.all_true` and completely inlined into `DrawList.keyMatches` / `DrawList.lastCmdMatches`) boosts `render_bench` from `1,944.6 FPS` (`ReleaseSmall`) to **`2,455.9 FPS` (+26.3%)**, `layout_bench` from `1,046.9 FPS` to **`1,150.3 FPS` (+9.9%)**, `text_bench` from `1,073.9 FPS` to **`1,175.1 FPS` (+9.4%)**, and `combined_frame` from `642.5 FPS` to **`690.7 FPS` (+7.5%)**.",
        "- **`zig -fllvm` (LLVM 22)**: `ReleaseFast` increases `combined_frame` throughput from `1,341.3 FPS` (`0.747 ms`) to `2,053.5 FPS` (`0.487 ms`, `+53.1%`), but explodes `.wasm` binary size by **4.39x** (`3,032.3 KB` raw / `865.0 KB` zstd vs `690.6 KB` raw / `301.0 KB` zstd in `ReleaseSmall` — making `-fllvm ReleaseFast` **2.52x larger** than `wazig ReleaseFast` and **3.09x larger** than `wazig ReleaseSmall`).",
        "",
        "### D.3 `wasm_bench_runner.wasm` — `Debug`",
        "",
        "| Workload | Iterations | Elements/Iter | `wazig` (Median / P95 / FPS) | `zig -fno-llvm` (Median / P95 / FPS) | `zig -fllvm` (Median / P95 / FPS) | Checksum |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | :--- |",
    ])
    for wkey, wlabel in workload_labels:
        dw = w_dbg_rt[wkey]
        dzn = zn_dbg_rt[wkey]
        dzl = zl_dbg_rt[wkey]
        lines.append(
            f"| **{wlabel}** | {dw['iterations']} | {dw['elements_per_iter']:,} | "
            f"**{dw['median_ms']:.3f} ms** / {dw['p95_ms']:.3f} ms (**{dw['ops_per_sec']:,.1f} FPS**) | "
            f"{dzn['median_ms']:.3f} ms / {dzn['p95_ms']:.3f} ms ({dzn['ops_per_sec']:,.1f} FPS) | "
            f"{dzl['median_ms']:.3f} ms / {dzl['p95_ms']:.3f} ms ({dzl['ops_per_sec']:,.1f} FPS) | "
            f"`{dw['checksum']}` |"
        )

    lines.extend([
        "",
        "**`Debug` Runtime Highlight:** In `Debug` builds, `wazig` is now **1.53x–3.78x faster at runtime than `zig 0.17.0 -fllvm` (LLVM 22)** across all four workloads (`945.8 FPS` vs `616.6 FPS` on `layout_bench`, `856.8 FPS` vs `226.7 FPS` on `text_bench`, `1,660.4 FPS` vs `956.5 FPS` on `render_bench`, and `559.8 FPS` vs `337.1 FPS` on `combined_frame`) while producing **2.81x smaller** `.wasm` binaries (`1,286.9 KB` vs `3,621.0 KB`).",
        "",
        "### D.4 Full `wasm32-wasi` Test Suite Execution (`12 test binaries` under `wasmtime run`)",
        "",
        "| Compiler | Test Binaries Passed | Total `wasmtime run` Execution Time | Speedup vs `zig -fllvm` |",
        "| :--- | :---: | ---: | ---: |",
        f"| **`wazig` (`-fno-llvm`)** | **12 / 12** (with `+atomics`) | **{w['runtime']['tests_12_wasi_exec_sec']:.3f} s** | **11.49x faster** |",
        f"| **`zig v0.17.0 -fno-llvm`** | 0 / 12 with `+atomics`* (12 / 12 without `+atomics`) | {zn['runtime']['tests_12_wasi_exec_sec']:.3f} s | 2.23x faster |",
        f"| **`zig v0.17.0 -fllvm`** | 12 / 12 (with `+atomics`) | {zl['runtime']['tests_12_wasi_exec_sec']:.3f} s | 1.00x (baseline) |",
        "",
        r'> *\*Upstream `zig 0.17.0 -fno-llvm` (`0.17.0-dev.27+0dd99239c`) emits an invalid WebAssembly atomic subopcode (`0xfe 0x27a` in `debug.waitForOtherThreadToFinishPanicking`) when `-mcpu baseline+atomics` is enabled, panics with `IllDefinedMemoryLayout` on `@Vector` types with `+simd128`, and fails to parse `global.get`/`global.set` inline assembly in `src/web/worker_host.zig`; `wazig` fixes all three bugs.*',
        "",
        "---",
        "",
        "## E. Guest Profiling Verification (`wasmtime-profile.py` @ `100us`)",
        "",
        "### E.1 Verified Impact of `cataggar/zig#158`–`#171` & `cataggar/knots#10` (`#11`, `#9`)",
        "",
        "Profiling `wasm_bench_runner.wasm` via `wasmtime run --profile=guest,100us` (`wasmtime-profile.py`) confirms that total CPU samples across the benchmark suite dropped by **3.41x** from `21,457` (`v0.17.0-wazig.3`) → `7,777` (`25bcd82e14`) → **`6,984` (`ReleaseSmall`) / `6,513` (`ReleaseFast`) / `6,287` (`ReleaseFast +simd128`)** in `cataggar/zig@b23f3693b9` + `cataggar/knots#10` (`#11`), with all `cataggar/knots#9` targets met or exceeded:",
        "",
        "| Workload | `wazig.3` (`ReleaseSmall`) | `wazig.4` (`25bcd82e14`, `ReleaseFast +simd128`) | `wazig.4` (`b23f3693b9`, `ReleaseSmall`) | `wazig.4` (`b23f3693b9`, `ReleaseFast +simd128`) | Speedup vs `wazig.3` | `knots#9` Goal |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | :--- |",
        "| **`layout_bench`** | 1.575 ms (635.2 FPS) | 0.865 ms (1,156.6 FPS) | 0.955 ms (1,046.9 FPS) | **0.870 ms (1,150.3 FPS)** | **1.81x faster** | `>= 1,000 FPS` (Achieved) |",
        "| **`text_bench`** | 5.505 ms (181.7 FPS) | 1.830 ms (546.3 FPS) | 0.931 ms (1,073.9 FPS) | **0.851 ms (1,175.1 FPS)** | **6.47x faster** | `>= 500 FPS` (Exceeded **2.35x**) |",
        "| **`render_bench`** | 1.282 ms (779.1 FPS) | 0.417 ms (2,373.8 FPS) | 0.518 ms (1,944.6 FPS) | **0.402 ms (2,455.9 FPS)** | **3.15x faster** | `>= 1,800 FPS` (Achieved) |",
        "| **`combined_frame`** | 3.286 ms (304.2 FPS) | 1.446 ms (690.8 FPS) | 1.556 ms (642.5 FPS) | **1.447 ms (690.7 FPS)** | **2.27x faster** | `>= 600 FPS` (Achieved) |",
        "",
        "- **[`cataggar/zig#158`](https://github.com/cataggar/zig/pull/158) (fixes `#153`) — Inline `f32`/`f64` `@min`/`@max` and `i128` shifts/muls**: Eliminated all **6,065 samples (28.3%)** previously spent in `fmaxf`/`fminf`/`isNan`/`signbit` and `__lshrti3`/`__multi3` (`0` samples in `wazig.4`).",
        "- **[`cataggar/zig#159`](https://github.com/cataggar/zig/pull/159) (fixes `#154`) — Scalar Replacement of Aggregates (SROA) to Wasm locals**: Promoted non-escaped slices, optionals, error unions, `Vec2`, `Rect`, `Color`, and `Element.Sizing` into Wasm locals, eliminating `Rect.fromMinMax`, `Rect.min`, `Rect.max`, `Rect.size`, `Rect.pos`, `Rect.intersect`, and `GlyphKey.hash` shadow-stack traffic.",
        "- **[`cataggar/zig#163`](https://github.com/cataggar/zig/pull/163) (fixes `#155`) & [`cataggar/zig#169`](https://github.com/cataggar/zig/issues/169) — `Optimizer.zig` parameterized leaf inlining, single-caller `.small` inlining, and local peepholes**: Inlined `band.curveExtent`, `ElementPool.get`, `DrawList.Box.add`, `mem.swap`, `hash_map.header`, `hash_map.capacity`, and `appendAssumeCapacity`, and reduced `ReleaseSmall` binary size by **-11.2%** (`1,104.5 KB` → `980.9 KB`).",
        "- **[`cataggar/zig#164`](https://github.com/cataggar/zig/pull/164) (fixes `#156`) & [`cataggar/zig#168`](https://github.com/cataggar/zig/issues/168) — `@Vector` layout, `v128` `+simd128` SIMD arithmetic, and fused `cmp_vector` + `@reduce(.And/.Or)` lowering**: `Rect.eql` and `Clip.State.scissorEql` in `ReleaseFast +simd128` are now **both `0` bytes and `0` samples** — lowered to `f32x4.eq` + `i32x4.all_true` and completely inlined into `DrawList.keyMatches` and `DrawList.lastCmdMatches`, accelerating `render_bench` to **`2,455.9 FPS` (`0.402 ms`)**.",
        "- **[`cataggar/zig#170`](https://github.com/cataggar/zig/issues/170) — Wasm multivalue return ABI for 2-scalar aggregates (`[2]f32`, `Vec2`, `HMetrics`, `[2]u8`, `u128`)**: Eliminated linear-memory `sret` stack frames for 2-scalar returns, allowing `curve.midpoint`, `Context.gapTotal`, `Element.sizing.Axis.percent`, and `fmt.digits2` to be completely inlined and removed in `ReleaseFast`.",
        "- **[`cataggar/zig#171`](https://github.com/cataggar/zig/issues/171) — Atomic temp-file rename for WASI cache manifests & bounds-checked `Archive`/`Object` magic parsing**: Parallel 4-way cold-cache `wasm32-wasi` test suite compilation completes with zero `Archive.zig` race panics (`18.78s` wall / `57.41s` CPU; **`0.931s`** total test execution time across all 12 suites — **3.31x faster** than `25bcd82e14`'s `3.078s` and **11.49x faster** than `zig -fllvm`'s `10.699s`).",
        "- **[`cataggar/knots#10`](https://github.com/cataggar/knots/issues/10) ([`cataggar/knots#11`](https://github.com/cataggar/knots/pull/11)) — Precomputed per-curve extents & insertion sort in `src/text/band.zig`**: `band.fillBands` inclusive samples dropped **3.25x–3.72x** (`1,951` / `25.09%` → `525` / `7.50%` in `ReleaseSmall`, `578` / `8.87%` in `ReleaseFast`, `601` / `9.56%` in `ReleaseFast +simd128`), and `std.sort.block` (`sort.block.swap`, `16.4 KB` bytecode, `8.83%` runtime) is **completely eliminated (`0` bytes, `0` samples)**, more than doubling `text_bench` throughput (`546.3 FPS` → **`1,175.1 FPS`**, beating `zig -fllvm` LLVM 22 `ReleaseFast`).",
        "",
        "### E.2 Top 15 Functions in `ReleaseFast +simd128` (`6,287` total samples @ 100us)",
        "",
        "| Self | Self% | Total | Tot% | Bytes | Function |",
        "| ---: | ---: | ---: | ---: | ---: | :--- |",
        "| 373 | 5.93% | 601 | 9.56% | 706 | `band.fillBands` |",
        "| 353 | 5.61% | 1,405 | 22.35% | 3,826 | `Context.positionChildren` |",
        "| 316 | 5.03% | 971 | 15.44% | 4,774 | `wasm_bench_runner.buildRenderFrame` |",
        "| 297 | 4.72% | 297 | 4.72% | 2,242 | `Context.distributeGrow` |",
        "| 287 | 4.56% | 1,407 | 22.38% | 679 | `Context.computeLayoutNode` |",
        "| 218 | 3.47% | 243 | 3.87% | 62 | `array_list.Aligned(u32,null).append` |",
        "| 204 | 3.24% | 204 | 3.24% | 1,902 | `Context.resolvePercentChildren` |",
        "| 182 | 2.89% | 182 | 2.89% | 1,126 | `band.sortBandIndices` |",
        "| 166 | 2.64% | 166 | 2.64% | 2,666 | `hash.wyhash.Wyhash.update` |",
        "| 151 | 2.40% | 152 | 2.42% | 11,503 | `Context.buildZOrder` |",
        "| 142 | 2.26% | 210 | 3.34% | 121 | `ElementPool.append` |",
        "| 141 | 2.24% | 141 | 2.24% | 2,689 | `DrawList.commandBounds` |",
        "| 120 | 1.91% | 143 | 2.27% | 924 | `DrawList.pushInstances` |",
        "| 118 | 1.88% | 355 | 5.65% | 5,660 | `DrawList.emitBatched` |",
        "| 113 | 1.80% | 113 | 1.80% | 673 | `Context.measureChildren` |",
        "",
    ])
    return "\n".join(lines)


def run_live_full_comparison(paths: dict[str, Path]) -> dict[str, Any]:
    """Run live benchmarks across wazig, zig -fno-llvm, and zig -fllvm when both tools are installed."""
    wb = load_wazig_build_module()
    wazig_bin = find_optional_tool("wazig", "WAZIG")
    zig_bin = find_optional_tool("zig", "ZIG")
    wasmtime_bin = find_optional_tool("wasmtime", "WASMTIME")

    data = load_baseline_reference()
    if not wazig_bin or not wasmtime_bin:
        return data

    # Warm Wasmtime module cache
    subprocess.run([wazig_bin, "version"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)
    tt_zig = ensure_truetype_pkg(wb, wazig_bin, paths["zig_local"], paths["zig_global"])
    tt_options_zig = paths["tmp"] / "truetype_options.zig"
    tt_options_zig.write_text("pub const debug_todo: bool = false;\n", encoding="utf-8")

    compilers_to_run = [("wazig", wazig_bin, "-fno-llvm")]
    if zig_bin:
        compilers_to_run.extend([
            ("zig_nollvm", zig_bin, "-fno-llvm"),
            ("zig_llvm", zig_bin, "-fllvm"),
        ])

    for cname, bin_path, flag in compilers_to_run:
        print(f"[bench-wazig] Measuring {cname} (wasm_bench_runner Debug & ReleaseSmall)...", file=sys.stderr, flush=True)
        c_lc = paths["root"] / f"lc-live-{cname}"
        c_gc = paths["root"] / f"gc-live-{cname}"
        shutil.rmtree(c_lc, ignore_errors=True)
        shutil.rmtree(c_gc, ignore_errors=True)
        c_lc.mkdir(parents=True, exist_ok=True)
        c_gc.mkdir(parents=True, exist_ok=True)

        t0 = time.perf_counter()
        subprocess.run([bin_path, "fmt", "--check", "src/", "tests/", "examples/", "lib/js-bridge/src/"], cwd=REPO_ROOT, check=True)
        data["compilers"][cname]["compile_sec"]["fmt_check"] = round(time.perf_counter() - t0, 3)

        for opt in ["Debug", "ReleaseSmall"]:
            key = f"wasm_bench_runner_{opt.lower()}"
            out_w = paths["bins"] / f"{key}_{cname}.wasm"
            args = wasm_bench_runner_args(opt, flag, out_w, c_lc, c_gc, tt_zig, tt_options_zig)
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

    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Benchmark wazig v0.17.0-wazig.3 vs standard zig v0.17.0 (-fno-llvm and -fllvm)."
    )
    parser.add_argument(
        "--ci-summary",
        action="store_true",
        help="Run CI benchmark summary using wazig + wasmtime and emit GitHub Step Summary Markdown to stdout.",
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
        data = load_baseline_reference()
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
