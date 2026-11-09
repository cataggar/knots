#!/usr/bin/env node
/**
 * Reproducible V8 / Node.js vs Wasmtime benchmark suite for knots:
 *   1. Builds `tests/wasm_bench_runner.zig` (`wasm32-wasi`, `generic+simd128`, `ReleaseFast`)
 *      using `wazig` (or `zig`), or uses an existing binary via `--wasm <path>`.
 *   2. Runs the 4 synchronous knots benchmarks (`layout_bench`, `text_bench`,
 *      `render_bench`, `combined_frame`) across:
 *        - `wasmtime run` (if available in PATH)
 *        - `node` (default V8 flags, via `node:wasi` with the `fd_pwrite` ESPIPE shim)
 *        - `node --experimental-wasm-wasmfx --experimental-wasm-growable-stacks`
 *   3. Benchmarks runtime capability detection (`detectWasmCapabilities()`):
 *        - `JSPI` (`WebAssembly.Suspending` / `WebAssembly.promising`)
 *        - `Atomics.waitAsync`
 *        - `WasmFX` (`WebAssembly.validate` on the 16-byte `0x5d` `cont` probe module)
 *   4. Benchmarks `std.Io` coroutine / cooperative frame-budget yield & futex wait in V8:
 *        - WasmFX continuation suspend/resume (active stack vs full `cont.new` per op)
 *        - JSPI suspend/resume (`Promise.resolve()` vs `queueMicrotask`)
 *        - Cooperative frame-budgeted polygon triangulation loop (10,000 steps, yield every 1,000)
 *        - Main-thread `std.Io` futex wait (`Atomics.waitAsync` + JSPI vs spin-wait on `SharedArrayBuffer`)
 *   5. Benchmarks Issue #28 Part 1 Shared-Linear-Memory Worker Pool Enhancements:
 *        - Persistent Wasm Futex Work Queue: production `src/wasm/WorkerRuntime.zig` uses a 256-slot ring buffer
 *          + intrusive FIFO overflow list protected by `queue_lock`, a `work_seq` futex sequence word
 *          (`memory.atomic.wait32` / `memory.atomic.notify`), pre-warmed workers parked in `knots_worker_loop(workerId)`,
 *          and coalesced main-thread completion notifications (`notify_pending` -> `knots_host_notify_complete` /
 *          `knots_worker_ack_complete`); the standalone Node V8 microbenchmark kernel models shared-memory futex
 *          ring dispatch vs per-task `worker.postMessage({ type: "run" })` round-trips across 4 `worker_threads`
 *        - Per-Worker Sharded Slab Allocator: production `src/wasm/ShardedAllocator.zig` implements `num_shards = 16`
 *          cache-line-aligned (`align(64)`) shards indexed by `currentWorkerId() % 16` (packed into the low 6 bits of
 *          the 64-byte-aligned `Task` pointer in `knots_worker_task`), with 9 power-of-two size classes (`16 B..4096 B`,
 *          `min_class_shift = 4`, `max_class_shift = 12`), per-shard spinlocks, O(1) lock-free same-class `resize`/`remap`,
 *          and cross-worker frees returned to the freeing worker's shard up to `max_cached_per_class = 64` before evicting
 *          to `std.heap.wasm_allocator`
 *        - Frame-Safe Non-Blocking Task Polling: `src/web/host.js` keeps `knots_frame` unwrapped in `wrapExports`
 *          (not wrapped in `WebAssembly.promising`) and exposes non-blocking `threads.poll(max_tasks)`,
 *          `threads.pollGroup(&group)`, `threads.pollFuture(T, &future)`, and `knots_worker_poll` vs
 *          `WebAssembly.promising(knots_frame)`
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";

process.removeAllListeners("warning");
const { WASI } = await import("node:wasi");

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(SCRIPT_PATH);
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..");

const SYNC_BENCHMARKS = [
  "layout_bench",
  "text_bench",
  "render_bench",
  "combined_frame",
];

/**
 * Minimal 16-byte WebAssembly binary that declares:
 *   (type $ft (func))
 *   (type $ct (cont $ft))  ;; 0x5d = cont type constructor
 */
export const WASMFX_PROBE_BYTES = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x06, 0x02, 0x60, 0x00, 0x00, 0x5d, 0x00,
]);

/**
 * Compiled from WAT (via `wasm-tools parse`):
 * Exports:
 *   - `bench_active_yield(n: i32) -> i32`:
 *       Allocates one continuation with `cont.new` and suspends/resumes `n` times
 *       on the active continuation stack.
 *   - `bench_full_cont(n: i32) -> i32`:
 *       Loops `n` times, each iteration executing `cont.new` + `resume` (1 suspend) +
 *       `resume` to completion.
 *   - `triangulate_baseline(n: i32) -> i32`:
 *       Runs `n` iterations of a deterministic ear-clipping / cross-product kernel
 *       with no yield instrumentation.
 *   - `triangulate_wasmfx(n: i32, interval: i32) -> i32`:
 *       Runs the same `n`-iteration triangulation kernel inside a WasmFX continuation,
 *       executing `suspend $yield` every `interval` iterations.
 */
const WASMFX_BENCH_MODULE_BASE64 =
  "AGFzbQEAAAABEQRgAABdAGABfwF/YAJ/fwF/AwgHAAAAAgICAw0DAQAABhEDfwFBAAt/AUHoBwt/" +
  "AUEACwdUBBJiZW5jaF9hY3RpdmVfeWllbGQAAw9iZW5jaF9mdWxsX2NvbnQABBR0cmlhbmd1bGF0" +
  "ZV9iYXNlbGluZQAFEnRyaWFuZ3VsYXRlX3dhc21meAAGCQcBAwADAAECCvADBx4BAn8jACEBA0Ag" +
  "ACABSQRA4gAgAEEBaiEADAELCwsEAOIAC6IBAQx/IwAhASMBIQNBASEEA0AgACABSQRAIABBEWxB" +
  "/wdxIQUgAEEfbEH/B3EhBiAEQQ1sQf8HcSEHIABBL2xB/wdxIQggBSAIakH/B3EhCSAGIAdqQf8H" +
  "cSEKIAcgBWsgCiAGa2wgCCAGayAJIAVrbGshCyAEIAsgAGpzIQQgAEEBaiEAIAJBAWohAiACIANP" +
  "BEBBACEC4gALDAELCyAEJAILMgIBYwEBfyAAJADSAOABIQEDQAJAAmQBIAHjAQEAAAAMAQshASAC" +
  "QQFqIQIMAQsLIAILQAMBfwFjAQF/A0AgASAASQRA0gHgASECAmQBIALjAQEAAAAACyECIALjAQAg" +
  "A0EBaiEDIAFBAWohAQwBCwsgAwuDAQEJf0EBIQIDQCABIABJBEAgAUERbEH/B3EhAyABQR9sQf8H" +
  "cSEEIAJBDWxB/wdxIQUgAUEvbEH/B3EhBiADIAZqQf8HcSEHIAQgBWpB/wdxIQggBSADayAIIARr" +
  "bCAGIARrIAcgA2tsayEJIAIgCSABanMhAiABQQFqIQEMAQsLIAILLQEBYwEgACQAIAEkAdIC4AEh" +
  "AgNAAkACZAEgAuMBAQAAAAwBCyECDAELCyMCCwD+AgRuYW1lATUDABF5aWVsZF9sb29wX3dvcmtl" +
  "cgETc2luZ2xlX3lpZWxkX3dvcmtlcgIKdHJpX3dvcmtlcgKoAQYAAgABaQEBbgIMAAFpAQFuAgRz" +
  "dGVwAwhpbnRlcnZhbAQDYWNjBQJheAYCYXkHAmJ4CAJieQkCY3gKAmN5CwVjcm9zcwMDAAFuAQFr" +
  "AgdyZXN1bWVzBAQAAW4BAWkCAWsDB3Jlc3VtZXMFCgABbgEBaQIDYWNjAwJheAQCYXkFAmJ4BgJi" +
  "eQcCY3gIAmN5CQVjcm9zcwYDAAFuAQhpbnRlcnZhbAIBawNVBgABAAFsAgEAAWwDAwAFZHJpdmUB" +
  "BGRvbmUCCG9uX3lpZWxkBAIABW91dGVyAghvbl95aWVsZAUBAAFsBgMABWRyaXZlAQRkb25lAghv" +
  "bl95aWVsZAQJAgACZnQBAmN0BykDAA10YXJnZXRfeWllbGRzAQ55aWVsZF9pbnRlcnZhbAIHdHJp" +
  "X2FjYwsIAQAFeWllbGQ=";

/**
 * Compiled from WAT (via `wasm-tools parse`):
 * Imports:
 *   - `env.memory` (shared 1..1 pages)
 *   - `env.host_yield: () -> void`
 *   - `env.host_wait_async: (ptr: i32, expected: i32) -> void`
 * Exports:
 *   - `bench_jspi_yield(n: i32) -> i32`
 *   - `triangulate_baseline(n: i32) -> i32`
 *   - `triangulate_jspi(n: i32, interval: i32) -> i32`
 *   - `futex_wait_jspi(ptr: i32, expected: i32) -> i32`
 *   - `futex_spin_wait(ptr: i32, expected: i32) -> i32`
 */
const JSPI_BENCH_MODULE_BASE64 =
  "AGFzbQEAAAABFARgAABgAn9/AGABfwF/YAJ/fwF/AjcDA2VudgZtZW1vcnkCAwEBA2Vudgpob3N0" +
  "X3lpZWxkAAADZW52D2hvc3Rfd2FpdF9hc3luYwABAwYFAgIDAwMHYgUQYmVuY2hfanNwaV95aWVs" +
  "ZAACFHRyaWFuZ3VsYXRlX2Jhc2VsaW5lAAMQdHJpYW5ndWxhdGVfanNwaQAED2Z1dGV4X3dhaXRf" +
  "anNwaQAFD2Z1dGV4X3NwaW5fd2FpdAAGCvwCBRwBAX8DQCABIABJBEAQACABQQFqIQEMAQsLIAEL" +
  "gwEBCX9BASECA0AgASAASQRAIAFBEWxB/wdxIQMgAUEfbEH/B3EhBCACQQ1sQf8HcSEFIAFBL2xB" +
  "/wdxIQYgAyAGakH/B3EhByAEIAVqQf8HcSEIIAUgA2sgCCAEa2wgBiAEayAHIANrbGshCSACIAkg" +
  "AWpzIQIgAUEBaiEBDAELCyACC5gBAQp/QQEhBANAIAIgAEkEQCACQRFsQf8HcSEFIAJBH2xB/wdx" +
  "IQYgBEENbEH/B3EhByACQS9sQf8HcSEIIAUgCGpB/wdxIQkgBiAHakH/B3EhCiAHIAVrIAogBmts" +
  "IAggBmsgCSAFa2xrIQsgBCALIAJqcyEEIAJBAWohAiADQQFqIQMgAyABTwRAQQAhAxAACwwBCwsg" +
  "BAsfAANAIAD+EAIAIAFGBEAgACABEAEMAQsLIAD+EAIACx4BAX8DQCAA/hACACABRgRAIAJBAWoh" +
  "AgwBCwsgAgsA3gEEbmFtZQEeAgAKaG9zdF95aWVsZAEPaG9zdF93YWl0X2FzeW5jApoBBQICAAFu" +
  "AQFpAwoAAW4BAWkCA2FjYwMCYXgEAmF5BQJieAYCYnkHAmN4CAJjeQkFY3Jvc3MEDAABbgEIaW50" +
  "ZXJ2YWwCAWkDBHN0ZXAEA2FjYwUCYXgGAmF5BwJieAgCYnkJAmN4CgJjeQsFY3Jvc3MFAgADcHRy" +
  "AQhleHBlY3RlZAYDAANwdHIBCGV4cGVjdGVkAgVzcGlucwMaBQIBAAFsAwEAAWwEAQABbAUBAAF3" +
  "BgEAAXc=";

/**
 * Compiled from WAT (via `wat2wasm --enable-threads --debug-names`):
 * Imports:
 *   - `env.memory` (shared 16..64 pages)
 *   - `env.knots_host_notify_complete: () -> void`
 * Exports:
 *   - `reset_queue_state: () -> void`
 *   - `reset_batch_stats: () -> void`
 *   - `knots_worker_run_one: (arg: i32) -> i32`
 *   - `enqueue_batch: (count: i32, base_arg: i32) -> void`
 *   - `knots_worker_loop: (worker_id: i32) -> void`
 *   - `knots_worker_wake_all: () -> void`
 *   - `knots_worker_ack_complete: () -> void`
 *   - `knots_worker_poll: (max_tasks: i32) -> i32`
 *   - `knots_frame: (dt_us: i32) -> i32`
 *   - `init_global_freelist: (num_blocks: i32) -> void`
 *   - `init_sharded_freelists: (num_workers: i32, blocks_per_worker: i32) -> void`
 *   - `bench_global_lock_alloc: (worker_id: i32, iterations: i32, expected_workers: i32) -> i32`
 *   - `bench_sharded_slab_alloc: (worker_id: i32, iterations: i32, expected_workers: i32) -> i32`
 */
const WORKER_POOL_BENCH_MODULE_BASE64 =
  "AGFzbQEAAAABHQZgAABgAX8AYAF/AX9gAn9/AGAAAX9gA39/fwF/AjECA2VudgZtZW1vcnkCAxBA" +
  "A2Vudhprbm90c19ob3N0X25vdGlmeV9jb21wbGV0ZQAAAxIRAQEAAAIDBAABAAACAgEDBQUHnwIN" +
  "EXJlc2V0X3F1ZXVlX3N0YXRlAAMRcmVzZXRfYmF0Y2hfc3RhdHMABBRrbm90c193b3JrZXJfcnVu" +
  "X29uZQAFDWVucXVldWVfYmF0Y2gABhFrbm90c193b3JrZXJfbG9vcAAJFWtub3RzX3dvcmtlcl93" +
  "YWtlX2FsbAAKGWtub3RzX3dvcmtlcl9hY2tfY29tcGxldGUACxFrbm90c193b3JrZXJfcG9sbAAM" +
  "C2tub3RzX2ZyYW1lAA0UaW5pdF9nbG9iYWxfZnJlZWxpc3QADhZpbml0X3NoYXJkZWRfZnJlZWxp" +
  "c3RzAA8XYmVuY2hfZ2xvYmFsX2xvY2tfYWxsb2MAEBhiZW5jaF9zaGFyZGVkX3NsYWJfYWxsb2MA" +
  "EQqsCxEXAAJAA0AgAEEAQQH+SAIARQ0BDAALCwsKACAAQQD+FwIACycBAX9BACEAAkADQCAAQYAG" +
  "Tw0BIABBAP4XAgAgAEEEaiEADAALCwsvAEHAA0EA/hcCAEGABEEA/hcCAEHABEEA/hcCAEGABUEA" +
  "/hcCAEHABUEA/hcCAAtRAQJ/IABBAXIhAkEAIQECQANAIAFBwABPDQEgAiACIAFqQbHz3fF5bHMh" +
  "AiACQQd3QZX4qfoHaiECIAFBAWohAQwACwtBgAUgAv4eAgAaIAILnwEBBH9BwARBAP4XAgBBgAMg" +
  "AP4eAgAaQQAQAUHAACgCACEDQcQAKAIAIQRBACECAkADQCACIABPDQEgAyAEakH/A3EhBUGACCAF" +
  "QQJ0aiABIAJqNgIAIARBAWohBCACQQFqIQIMAAsLQcQAIAQ2AgBBwAEgAP4eAgAaQYABQQH+HgIA" +
  "GkEAEAJBgAL+EAIAQQBLBEBBgAEgAP4AAgAaCwtrAQN/QcAB/hACAEUEQEF/DwtBABABQcQAKAIA" +
  "IQEgAUUEQEEAEAJBfw8LQcAAKAIAIQBBgAggAEECdGooAgAhAkHAACAAQQFqQf8DcTYCAEHEACAB" +
  "QQFrNgIAQcABQQH+JQIAGkEAEAIgAgs6AQF/QcADQQH+HgIAGkGAA0EB/iUCACEAIABBAUYEQEGA" +
  "A0F//gACABpBwARBAf5BAgBFBEAQAAsLC5MBAQJ/AkADQEHAAv4QAgBBAEcNAQJAA0AQByEBIAFB" +
  "AEgNASABEAUaEAhBwAL+EAIAQQBHDQMMAAsLQYAB/hACACECQcAB/hACAEEARw0AQcAC/hACAEEA" +
  "Rw0AQYACQQH+HgIAGkHAAf4QAgBFQcAC/hACAEVxBEBBgAEgAkJ//gECABoLQYACQQH+JQIAGgwA" +
  "CwsLHwBBwAJBAf4XAgBBgAFBAf4eAgAaQYABQX/+AAIAGgsLAEHABEEA/hcCAAtSAQR/QcAEQQD+" +
  "FwIAQQAhAQJAA0AgASAATw0BEAchAiACQQBIDQEgAhAFGhAIIAFBAWohAQwACwtBwAP+EAIAIQNB" +
  "gAQgA/5BAgAhBCADIARrCxkBAX9BABAMIQFBwAUgACABav4eAgAaIAELVgEDf0GAwABBAP4XAgBB" +
  "wMAAQQD+FwIAQQAhAkEAIQECQANAIAEgAE8NAUGAgAEgAUEGdGohAyADIAI2AgAgAyECIAFBAWoh" +
  "AQwACwtBxMAAIAI2AgALkgEBBn9BgMAAQQD+FwIAQQEhAgJAA0AgAiAASw0BQYDCACACQQZ0aiEE" +
  "IARBAP4XAgBBACEFIAJBAWsgAWwhB0EAIQMCQANAIAMgAU8NAUGAgAEgByADakEGdGohBiAGIAU2" +
  "AgAgBiEFIANBAWohAwwACwsgBEEEaiAFNgIAIARBCGogATYCACACQQFqIQIMAAsLC6QBAQR/QYDA" +
  "AEEB/h4CABoCQANAQYDAAP4QAgAgAk8NAQwACwtBACEGQQAhAwJAA0AgAyABTw0BQcDAABABQcTA" +
  "ACgCACEEIAQoAgAhBUHEwAAgBTYCAEHAwAAQAiAEQQhqIAMgAHM2AgAgBiAEQQhqKAIAaiEGQcDA" +
  "ABABIARBxMAAKAIANgIAQcTAACAENgIAQcDAABACIANBAWohAwwACwsgBgvVAQEFf0GAwgAgAEEP" +
  "cUEGdGohBEGAwABBAf4eAgAaAkADQEGAwAD+EAIAIAJPDQEMAAsLQQAhB0EAIQMCQANAIAMgAU8N" +
  "ASAEEAEgBEEEaigCACEFIAUoAgAhBiAEQQRqIAY2AgAgBEEIaiAEQQhqKAIAQQFrNgIAIAQQAiAF" +
  "QQhqIAMgAHM2AgAgByAFQQhqKAIAaiEHIAQQASAFIARBBGooAgA2AgAgBEEEaiAFNgIAIARBCGog" +
  "BEEIaigCAEEBajYCACAEEAIgA0EBaiEDDAALCyAHCwCdBARuYW1lAWwHABprbm90c19ob3N0X25v" +
  "dGlmeV9jb21wbGV0ZQEEbG9jawIGdW5sb2NrBQ9ydW5fdGFza19rZXJuZWwHDHRyeV9wb3BfdGFz" +
  "awgNY29tcGxldGVfdGFzawwRa25vdHNfd29ya2VyX3BvbGwCpwMSAAABAQAEYWRkcgIBAARhZGRy" +
  "AwEABGFkZHIEAAUDAANhcmcBAWkCA2FjYwYGAAVjb3VudAEIYmFzZV9hcmcCAWkDBGhlYWQEBnJj" +
  "b3VudAUEdGFpbAcDAARoZWFkAQZyY291bnQCA2FyZwgBAARwcmV2CQMACXdvcmtlcl9pZAEDYXJn" +
  "AgNzZXEKAAsADAUACW1heF90YXNrcwEDcmFuAgNhcmcDA2N1cgQEcHJldg0CAAVkdF91cwEJY29t" +
  "cGxldGVkDgQACm51bV9ibG9ja3MBAWkCBGhlYWQDA2Jsaw8IAAtudW1fd29ya2VycwERYmxvY2tz" +
  "X3Blcl93b3JrZXICAXcDAWkEBXNoYXJkBQRoZWFkBgNibGsHCGJhc2VfaWR4EAcACXdvcmtlcl9p" +
  "ZAEKaXRlcmF0aW9ucwIQZXhwZWN0ZWRfd29ya2VycwMBaQQDYmxrBQRuZXh0BgNhY2MRCAAJd29y" +
  "a2VyX2lkAQppdGVyYXRpb25zAhBleHBlY3RlZF93b3JrZXJzAwFpBAVzaGFyZAUDYmxrBgRuZXh0" +
  "BwNhY2M=";

export function detectWasmCapabilities() {
  const jspi =
    typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function";
  const waitAsync =
    typeof Atomics !== "undefined" && typeof Atomics.waitAsync === "function";
  const wasmfx = WebAssembly.validate(WASMFX_PROBE_BYTES);
  return { jspi, waitAsync, wasmfx };
}

function parseArgs(argv) {
  const opts = {
    wasm: null,
    json: false,
    internalWasmfxChild: false,
    internalDefaultNodeChild: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--wasm" && i + 1 < argv.length) {
      opts.wasm = argv[++i];
    } else if (arg.startsWith("--wasm=")) {
      opts.wasm = arg.slice("--wasm=".length);
    } else if (arg === "--json") {
      opts.json = true;
    } else if (arg === "--internal-wasmfx-child") {
      opts.internalWasmfxChild = true;
    } else if (arg === "--internal-default-node-child") {
      opts.internalDefaultNodeChild = true;
    } else if (arg === "--help" || arg === "-h") {
      console.log(
        "Usage: node scripts/bench-wasmfx.mjs [--wasm <path>] [--json]",
      );
      process.exit(0);
    }
  }
  return opts;
}

function findExecutable(name) {
  const pathEnv = process.env.PATH || "";
  const dirs = [
    ...pathEnv.split(path.delimiter),
    path.join(os.homedir(), ".local", "bin"),
  ];
  for (const dir of dirs) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // continue
    }
  }
  return null;
}

function ensureWasmtimeEnv(workDir) {
  const env = { ...process.env };
  const existingToml = path.join(REPO_ROOT, ".zig-global-cache", "wasmtime-cache.toml");
  if (!env.WASMTIME_CACHE_CONFIG) {
    if (fs.existsSync(existingToml)) {
      env.WASMTIME_CACHE_CONFIG = existingToml;
    } else {
      const wtCacheDir = path.join(workDir, "wasmtime-cache");
      fs.mkdirSync(wtCacheDir, { recursive: true });
      const wtToml = path.join(workDir, "wasmtime-cache.toml");
      fs.writeFileSync(
        wtToml,
        `[cache]\nenabled = true\ndirectory = "${wtCacheDir}"\n`,
        "utf8",
      );
      env.WASMTIME_CACHE_CONFIG = wtToml;
    }
  }
  const xdgCache = path.join(workDir, "xdg-cache");
  fs.mkdirSync(xdgCache, { recursive: true });
  env.XDG_CACHE_HOME = xdgCache;
  return env;
}

function resolveCompiler() {
  if (process.env.WAZIG_BIN && fs.existsSync(process.env.WAZIG_BIN)) {
    return { bin: process.env.WAZIG_BIN, kind: "wazig" };
  }
  const wazigInPath = findExecutable("wazig");
  if (wazigInPath) {
    return { bin: wazigInPath, kind: "wazig" };
  }
  const siblingWazig = path.resolve(REPO_ROOT, "../wazig/zig-out/bin/wazig");
  if (fs.existsSync(siblingWazig)) {
    return { bin: siblingWazig, kind: "wazig" };
  }
  const zigInPath = findExecutable("zig");
  if (zigInPath) {
    return { bin: zigInPath, kind: "zig" };
  }
  throw new Error("Neither `wazig` nor `zig` was found in PATH.");
}

function resolveTrueTypeZig(workDir) {
  const findInRoot = (cacheRoot) => {
    if (!cacheRoot || !fs.existsSync(cacheRoot)) return null;
    for (const entry of fs.readdirSync(cacheRoot).sort()) {
      if (!entry.startsWith("TrueType-")) continue;
      for (const rel of ["TrueType.zig", path.join("src", "TrueType.zig")]) {
        const candidate = path.join(cacheRoot, entry, rel);
        if (fs.existsSync(candidate)) return candidate;
      }
    }
    return null;
  };

  const localHit = findInRoot(path.join(REPO_ROOT, ".zig-global-cache", "p"));
  if (localHit) {
    return path.relative(REPO_ROOT, localHit);
  }
  const externalRoots = [
    process.env.ZIG_GLOBAL_CACHE_DIR
      ? path.join(process.env.ZIG_GLOBAL_CACHE_DIR, "p")
      : null,
    path.resolve(REPO_ROOT, "..", "..", "zig-global-cache", "p"),
    path.resolve(REPO_ROOT, "..", ".zig-global-cache", "p"),
    path.resolve(REPO_ROOT, "..", "knots", ".zig-global-cache", "p"),
  ];
  for (const root of externalRoots) {
    const hit = findInRoot(root);
    if (hit) {
      const staged = path.join(workDir, "TrueType.zig");
      fs.copyFileSync(hit, staged);
      return path.relative(REPO_ROOT, staged);
    }
  }
  throw new Error(
    "Could not locate unpacked TrueType.zig in .zig-global-cache/p or ZIG_GLOBAL_CACHE_DIR.",
  );
}

function buildWasmBenchRunner() {
  const workDir = path.join(REPO_ROOT, ".tmp", "bench-wasmfx");
  const localCacheDir = path.join(workDir, "zig-local");
  const globalCacheDir = path.join(workDir, "zig-global");
  fs.mkdirSync(localCacheDir, { recursive: true });
  fs.mkdirSync(globalCacheDir, { recursive: true });

  const buildOptionsPath = path.join(workDir, "truetype_options.zig");
  fs.writeFileSync(buildOptionsPath, "pub const debug_todo: bool = false;\n", "utf8");

  const relTrueType = resolveTrueTypeZig(workDir);
  const relBuildOptions = path.relative(REPO_ROOT, buildOptionsPath);
  const relOutput = path.relative(
    REPO_ROOT,
    path.join(workDir, "wasm_bench_runner.wasm"),
  );
  const relLocalCache = path.relative(REPO_ROOT, localCacheDir);
  const relGlobalCache = path.relative(REPO_ROOT, globalCacheDir);

  const compiler = resolveCompiler();
  const targetOptFlags = [
    "-target",
    "wasm32-wasi",
    "-mcpu",
    "generic+simd128",
    "-OReleaseFast",
  ];
  const args = [
    "build-exe",
    "-fno-llvm",
    ...targetOptFlags,
    "--dep", "math",
    "--dep", "style",
    "--dep", "layout",
    "--dep", "TrueType",
    "--dep", "text",
    "--dep", "render_types",
    "--dep", "render",
    "--dep", "input",
    "--dep", "ui",
    "-Mroot=tests/wasm_bench_runner.zig",
    ...targetOptFlags,
    "-Mmath=src/math/root.zig",
    ...targetOptFlags,
    "-Mrender_types=src/render/types/root.zig",
    ...targetOptFlags,
    "-Minput=src/input/root.zig",
    "--dep", "math",
    ...targetOptFlags,
    "-Mlayout=src/layout/root.zig",
    "--dep", "layout",
    "--dep", "math",
    "--dep", "render_types",
    ...targetOptFlags,
    "-Mstyle=src/style/root.zig",
    "--dep", "build_options",
    ...targetOptFlags,
    `-MTrueType=${relTrueType}`,
    "--dep", "TrueType",
    ...targetOptFlags,
    "-Mtext=src/text/root.zig",
    "--dep", "render_types",
    "--dep", "math",
    ...targetOptFlags,
    "-Mrender=src/render/root.zig",
    "--dep", "layout",
    "--dep", "style",
    "--dep", "text",
    "--dep", "input",
    "--dep", "render_types",
    "--dep", "render",
    "--dep", "math",
    ...targetOptFlags,
    "-Mui=src/ui/root.zig",
    ...targetOptFlags,
    `-Mbuild_options=${relBuildOptions}`,
    "--cache-dir",
    relLocalCache,
    "--global-cache-dir",
    relGlobalCache,
    `-femit-bin=${relOutput}`,
  ];

  const env = ensureWasmtimeEnv(workDir);
  const t0 = performance.now();
  const res = spawnSync(compiler.bin, args, {
    cwd: REPO_ROOT,
    encoding: "utf8",
    env,
  });
  const compileMs = performance.now() - t0;
  if (res.status !== 0) {
    throw new Error(
      `Failed to compile wasm_bench_runner.wasm with ${compiler.kind}:\n${res.stderr || res.stdout}`,
    );
  }
  const absOutput = path.join(REPO_ROOT, relOutput);
  const sizeBytes = fs.statSync(absOutput).size;
  return {
    wasmPath: absOutput,
    compilerKind: compiler.kind,
    compileMs,
    sizeBytes,
  };
}

/**
 * Runs `wasm_bench_runner.wasm` in-process using `node:wasi`.
 * Applies the `fd_pwrite` shim returning `70` (`WASI_ESPIPE`) on stdout/stderr so
 * Zig 0.17 `std.Io.File.stdout().writer()` falls back to `fd_write`.
 */
function runAllSyncBenchmarksInNode(wasmPath) {
  const wasmBytes = fs.readFileSync(wasmPath);
  const wasmModule = new WebAssembly.Module(wasmBytes);
  const stdoutChunks = [];
  const wasi = new WASI({
    version: "preview1",
    args: ["wasm_bench_runner.wasm"],
    env: {},
    returnOnExit: true,
  });

  const importObject = wasi.getImportObject();
  const preview1 = importObject.wasi_snapshot_preview1;
  const origPwrite = preview1.fd_pwrite.bind(preview1);
  const origWrite = preview1.fd_write.bind(preview1);

  let memoryRef = null;
  preview1.fd_pwrite = (fd, iovsPtr, iovsLen, offset, nwrittenPtr) => {
    if (fd === 1 || fd === 2) {
      return 70; // WASI_ESPIPE -> forces Zig 0.17 std.Io.File.Writer into streaming fd_write mode
    }
    return origPwrite(fd, iovsPtr, iovsLen, offset, nwrittenPtr);
  };

  preview1.fd_write = (fd, iovsPtr, iovsLen, nwrittenPtr) => {
    if ((fd === 1 || fd === 2) && memoryRef) {
      const view = new DataView(memoryRef.buffer);
      const bytes = new Uint8Array(memoryRef.buffer);
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovsPtr + i * 8, true);
        const len = view.getUint32(iovsPtr + i * 8 + 4, true);
        if (fd === 1 && len > 0) {
          stdoutChunks.push(Buffer.from(bytes.subarray(ptr, ptr + len)));
        }
        total += len;
      }
      view.setUint32(nwrittenPtr, total, true);
      return 0;
    }
    return origWrite(fd, iovsPtr, iovsLen, nwrittenPtr);
  };

  const instance = new WebAssembly.Instance(wasmModule, importObject);
  memoryRef = instance.exports.memory;
  const exitCode = wasi.start(instance);
  if (exitCode !== 0) {
    throw new Error(`wasm_bench_runner exited with code ${exitCode}`);
  }

  const rawText = Buffer.concat(stdoutChunks).toString("utf8").trim();
  const parsed = JSON.parse(rawText);
  if (!parsed.workloads) {
    throw new Error(`Unexpected benchmark output: ${rawText}`);
  }
  return parsed;
}

function runAllSyncBenchmarksInWasmtime(wasmPath) {
  const wasmtimeBin = findExecutable("wasmtime");
  if (!wasmtimeBin) {
    return null;
  }
  const res = spawnSync(wasmtimeBin, ["run", wasmPath], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
  if (res.status !== 0) {
    throw new Error(`wasmtime failed:\n${res.stderr || res.stdout}`);
  }
  const parsed = JSON.parse(res.stdout.trim());
  if (!parsed.workloads) {
    throw new Error(`Unexpected wasmtime benchmark output: ${res.stdout}`);
  }
  return parsed;
}

function benchmarkCapabilityDetection(iterations = 200000) {
  // Warmup
  for (let i = 0; i < 5000; i++) {
    detectWasmCapabilities();
  }

  let sink = 0;
  const tJspi0 = performance.now();
  for (let i = 0; i < iterations; i++) {
    const ok =
      typeof WebAssembly.Suspending === "function" &&
      typeof WebAssembly.promising === "function";
    sink ^= ok ? 1 : 0;
  }
  const jspiNsPerOp = ((performance.now() - tJspi0) * 1e6) / iterations;

  const tWait0 = performance.now();
  for (let i = 0; i < iterations; i++) {
    const ok =
      typeof Atomics !== "undefined" && typeof Atomics.waitAsync === "function";
    sink ^= ok ? 1 : 0;
  }
  const waitAsyncNsPerOp = ((performance.now() - tWait0) * 1e6) / iterations;

  const wasmfxIters = 50000;
  const tFx0 = performance.now();
  for (let i = 0; i < wasmfxIters; i++) {
    const ok = WebAssembly.validate(WASMFX_PROBE_BYTES);
    sink ^= ok ? 1 : 0;
  }
  const wasmfxNsPerOp = ((performance.now() - tFx0) * 1e6) / wasmfxIters;

  const tAll0 = performance.now();
  for (let i = 0; i < wasmfxIters; i++) {
    const caps = detectWasmCapabilities();
    sink ^= caps.jspi ? 1 : 0;
  }
  const combinedNsPerOp = ((performance.now() - tAll0) * 1e6) / wasmfxIters;

  return {
    capabilities: detectWasmCapabilities(),
    jspiNsPerOp,
    waitAsyncNsPerOp,
    wasmfxNsPerOp,
    combinedNsPerOp,
    sink,
  };
}

async function runMicrobenchmarks() {
  const caps = detectWasmCapabilities();
  const jspiBytes = Buffer.from(JSPI_BENCH_MODULE_BASE64, "base64");
  const jspiModule = new WebAssembly.Module(jspiBytes);

  const sharedMem = new WebAssembly.Memory({
    initial: 1,
    maximum: 1,
    shared: true,
  });
  const sharedI32 = new Int32Array(sharedMem.buffer);

  // 1. JSPI with Promise.resolve() (when WebAssembly.Suspending / promising are available)
  const hasJspi = caps.jspi;
  const yieldResolvedImport = hasJspi
    ? new WebAssembly.Suspending(() => Promise.resolve())
    : () => {};
  const waitAsyncImport = hasJspi
    ? new WebAssembly.Suspending((byteOffset, expected) => {
        const res = Atomics.waitAsync(sharedI32, byteOffset >> 2, expected);
        return res.async ? res.value : Promise.resolve(res.value);
      })
    : () => {};

  const instResolved = new WebAssembly.Instance(jspiModule, {
    env: {
      memory: sharedMem,
      host_yield: yieldResolvedImport,
      host_wait_async: waitAsyncImport,
    },
  });

  // 2. JSPI with queueMicrotask
  const yieldMicrotaskImport = hasJspi
    ? new WebAssembly.Suspending(
        () => new Promise((resolve) => queueMicrotask(resolve)),
      )
    : () => {};
  const instMicrotask = new WebAssembly.Instance(jspiModule, {
    env: {
      memory: sharedMem,
      host_yield: yieldMicrotaskImport,
      host_wait_async: waitAsyncImport,
    },
  });

  const jspiYieldResolved = hasJspi
    ? WebAssembly.promising(instResolved.exports.bench_jspi_yield)
    : null;
  const jspiYieldMicrotask = hasJspi
    ? WebAssembly.promising(instMicrotask.exports.bench_jspi_yield)
    : null;
  const triangulateBaseline = instResolved.exports.triangulate_baseline;
  const triangulateJspi = hasJspi
    ? WebAssembly.promising(instResolved.exports.triangulate_jspi)
    : null;
  const futexWaitJspi = hasJspi
    ? WebAssembly.promising(instResolved.exports.futex_wait_jspi)
    : null;
  const futexSpinWait = instResolved.exports.futex_spin_wait;

  let jspiResolvedNsPerOp = null;
  let jspiMicrotaskNsPerOp = null;
  let jspiFullCallNsPerOp = null;

  if (hasJspi) {
    // Warmup JSPI
    await jspiYieldResolved(2000);
    await jspiYieldMicrotask(2000);

    const jspiOps = 50000;
    const tJspiRes0 = performance.now();
    await jspiYieldResolved(jspiOps);
    jspiResolvedNsPerOp = ((performance.now() - tJspiRes0) * 1e6) / jspiOps;

    const tJspiMic0 = performance.now();
    await jspiYieldMicrotask(jspiOps);
    jspiMicrotaskNsPerOp = ((performance.now() - tJspiMic0) * 1e6) / jspiOps;

    const jspiFullOps = 20000;
    const tJspiFull0 = performance.now();
    for (let i = 0; i < jspiFullOps; i++) {
      await jspiYieldMicrotask(1);
    }
    jspiFullCallNsPerOp = ((performance.now() - tJspiFull0) * 1e6) / jspiFullOps;
  }

  // WasmFX continuation benchmarks (if enabled in this V8 process)
  let wasmfxActiveNsPerOp = null;
  let wasmfxFullContNsPerOp = null;
  let wasmfxInstance = null;

  if (caps.wasmfx) {
    try {
      const fxBytes = Buffer.from(WASMFX_BENCH_MODULE_BASE64, "base64");
      const fxMod = new WebAssembly.Module(fxBytes);
      wasmfxInstance = new WebAssembly.Instance(fxMod);

      // Warmup WasmFX
      wasmfxInstance.exports.bench_active_yield(10000);
      wasmfxInstance.exports.bench_full_cont(5000);

      const fxActiveOps = 500000;
      const tFxAct0 = performance.now();
      wasmfxInstance.exports.bench_active_yield(fxActiveOps);
      wasmfxActiveNsPerOp = ((performance.now() - tFxAct0) * 1e6) / fxActiveOps;

      const fxFullOps = 100000;
      const tFxFull0 = performance.now();
      wasmfxInstance.exports.bench_full_cont(fxFullOps);
      wasmfxFullContNsPerOp = ((performance.now() - tFxFull0) * 1e6) / fxFullOps;
    } catch {
      wasmfxInstance = null;
    }
  }

  // 3. Cooperative frame-budgeted geometry/triangulation loop (10,000 iterations, yield every 1,000)
  const triSteps = 10000;
  const yieldInterval = 1000;
  const triRuns = 400;

  // Warmup triangulation
  for (let i = 0; i < 30; i++) {
    triangulateBaseline(triSteps);
    if (triangulateJspi) {
      await triangulateJspi(triSteps, yieldInterval);
    }
    if (wasmfxInstance) {
      wasmfxInstance.exports.triangulate_wasmfx(triSteps, yieldInterval);
    }
  }

  let expectedChecksum = triangulateBaseline(triSteps);
  const tTriBase0 = performance.now();
  for (let i = 0; i < triRuns; i++) {
    const c = triangulateBaseline(triSteps);
    if (c !== expectedChecksum) throw new Error("Checksum mismatch in baseline");
  }
  const triBaselineUs = ((performance.now() - tTriBase0) * 1000) / triRuns;

  let triWasmfxUs = null;
  if (wasmfxInstance) {
    const tTriFx0 = performance.now();
    for (let i = 0; i < triRuns; i++) {
      const c = wasmfxInstance.exports.triangulate_wasmfx(
        triSteps,
        yieldInterval,
      );
      if (c !== expectedChecksum) throw new Error("Checksum mismatch in WasmFX");
    }
    triWasmfxUs = ((performance.now() - tTriFx0) * 1000) / triRuns;
  }

  let triJspiUs = null;
  if (triangulateJspi) {
    const tTriJspi0 = performance.now();
    for (let i = 0; i < triRuns; i++) {
      const c = await triangulateJspi(triSteps, yieldInterval);
      if (c !== expectedChecksum) throw new Error("Checksum mismatch in JSPI");
    }
    triJspiUs = ((performance.now() - tTriJspi0) * 1000) / triRuns;
  }

  // 4. Main-thread std.Io futex wait (Atomics.waitAsync + JSPI vs spin-wait on SharedArrayBuffer)
  const futexRounds = 12;
  const notifyDelayMs = 2;

  const workerCode = `
    const { parentPort, workerData } = require("node:worker_threads");
    const i32 = new Int32Array(workerData.sharedBuffer);
    parentPort.on("message", (msg) => {
      if (msg.cmd === "notify_after") {
        setTimeout(() => {
          Atomics.store(i32, 2, Math.trunc(performance.now() * 1000));
          Atomics.store(i32, 0, 1);
          Atomics.notify(i32, 0, 1);
        }, msg.delayMs);
      } else if (msg.cmd === "exit") {
        process.exit(0);
      }
    });
  `;

  const notifier = new Worker(workerCode, {
    eval: true,
    workerData: { sharedBuffer: sharedMem.buffer },
  });

  try {
    // Warmup both paths
    if (futexWaitJspi) {
      Atomics.store(sharedI32, 0, 0);
      notifier.postMessage({ cmd: "notify_after", delayMs: 1 });
      await futexWaitJspi(0, 0);
    }

    Atomics.store(sharedI32, 0, 0);
    notifier.postMessage({ cmd: "notify_after", delayMs: 1 });
    futexSpinWait(0, 0);

    // Measure Atomics.waitAsync + JSPI
    let jspiWallTotalUs = 0;
    let jspiCpuTotalUs = 0;
    let jspiWakeLatencyTotalUs = 0;
    let jspiEventLoopTicks = 0;

    if (futexWaitJspi) {
      for (let r = 0; r < futexRounds; r++) {
        Atomics.store(sharedI32, 0, 0);
        const tickTimer = setInterval(() => {
          jspiEventLoopTicks++;
        }, 0);
        notifier.postMessage({ cmd: "notify_after", delayMs: notifyDelayMs });
        const cpu0 = process.cpuUsage();
        const wall0 = performance.now();
        await futexWaitJspi(0, 0);
        const wallUs = (performance.now() - wall0) * 1000;
        const cpuDelta = process.cpuUsage(cpu0);
        const wakeNowUs = Math.trunc(performance.now() * 1000);
        const notifySentUs = Atomics.load(sharedI32, 2);
        clearInterval(tickTimer);

        jspiWallTotalUs += wallUs;
        jspiCpuTotalUs += cpuDelta.user + cpuDelta.system;
        jspiWakeLatencyTotalUs += Math.max(0, wakeNowUs - notifySentUs);
      }
    }

    // Measure synchronous Wasm spin-wait
    let spinWallTotalUs = 0;
    let spinCpuTotalUs = 0;
    let spinWakeLatencyTotalUs = 0;
    let spinEventLoopTicks = 0;
    let totalSpinIterations = 0;

    for (let r = 0; r < futexRounds; r++) {
      Atomics.store(sharedI32, 0, 0);
      const tickTimer = setInterval(() => {
        spinEventLoopTicks++;
      }, 0);
      notifier.postMessage({ cmd: "notify_after", delayMs: notifyDelayMs });
      const cpu0 = process.cpuUsage();
      const wall0 = performance.now();
      const spins = futexSpinWait(0, 0);
      const wallUs = (performance.now() - wall0) * 1000;
      const cpuDelta = process.cpuUsage(cpu0);
      const wakeNowUs = Math.trunc(performance.now() * 1000);
      const notifySentUs = Atomics.load(sharedI32, 2);
      clearInterval(tickTimer);

      totalSpinIterations += spins >>> 0;
      spinWallTotalUs += wallUs;
      spinCpuTotalUs += cpuDelta.user + cpuDelta.system;
      spinWakeLatencyTotalUs += Math.max(0, wakeNowUs - notifySentUs);
    }

    const workerPool = await runWorkerPoolBenchmarks();

    return {
      suspension: {
        wasmfxActiveNsPerOp,
        wasmfxFullContNsPerOp,
        jspiResolvedNsPerOp,
        jspiMicrotaskNsPerOp,
        jspiFullCallNsPerOp,
        activeSpeedupVsJspiResolved:
          wasmfxActiveNsPerOp != null && jspiResolvedNsPerOp != null
            ? jspiResolvedNsPerOp / wasmfxActiveNsPerOp
            : null,
        activeSpeedupVsJspiMicrotask:
          wasmfxActiveNsPerOp != null && jspiMicrotaskNsPerOp != null
            ? jspiMicrotaskNsPerOp / wasmfxActiveNsPerOp
            : null,
        fullContSpeedupVsJspiFullCall:
          wasmfxFullContNsPerOp != null && jspiFullCallNsPerOp != null
            ? jspiFullCallNsPerOp / wasmfxFullContNsPerOp
            : null,
      },
      triangulation: {
        steps: triSteps,
        yieldInterval,
        yieldsPerCall: triSteps / yieldInterval,
        checksum: expectedChecksum,
        baselineUs: triBaselineUs,
        wasmfxUs: triWasmfxUs,
        jspiUs: triJspiUs,
        wasmfxOverheadPct:
          triWasmfxUs != null
            ? ((triWasmfxUs - triBaselineUs) / triBaselineUs) * 100
            : null,
        jspiOverheadPct:
          triJspiUs != null
            ? ((triJspiUs - triBaselineUs) / triBaselineUs) * 100
            : null,
      },
      futexWait: {
        rounds: futexRounds,
        notifyDelayMs,
        waitAsyncJspi: {
          avgWallUs: jspiWallTotalUs / futexRounds,
          avgCpuUs: jspiCpuTotalUs / futexRounds,
          avgWakeLatencyUs: jspiWakeLatencyTotalUs / futexRounds,
          eventLoopTicksPerWait: jspiEventLoopTicks / futexRounds,
        },
        spinWait: {
          avgWallUs: spinWallTotalUs / futexRounds,
          avgCpuUs: spinCpuTotalUs / futexRounds,
          avgWakeLatencyUs: spinWakeLatencyTotalUs / futexRounds,
          eventLoopTicksPerWait: spinEventLoopTicks / futexRounds,
          avgSpinLoads: totalSpinIterations / futexRounds,
        },
      },
      workerPool,
      futexWorkQueue: workerPool.futexWorkQueue,
      shardedAllocator: workerPool.shardedAllocator,
      framePolling: workerPool.framePolling,
    };
  } finally {
    notifier.postMessage({ cmd: "exit" });
    await notifier.terminate();
  }
}

async function runWorkerPoolBenchmarks() {
  const numWorkers = 4;
  const tasksPerBatch = 400;
  const batchRounds = 20;

  const wpBytes = Buffer.from(WORKER_POOL_BENCH_MODULE_BASE64, "base64");
  const wasmModule = new WebAssembly.Module(wpBytes);

  const sharedMem = new WebAssembly.Memory({
    initial: 16,
    maximum: 64,
    shared: true,
  });
  const sharedI32 = new Int32Array(sharedMem.buffer);

  const mainInstance = new WebAssembly.Instance(wasmModule, {
    env: {
      memory: sharedMem,
      knots_host_notify_complete: () => {},
    },
  });
  const exports = mainInstance.exports;

  // --- Benchmark 4a: Baseline per-task postMessage({ type: "run" }) dispatch ---
  const postMsgWorkerCode = `
    const { parentPort, workerData } = require("node:worker_threads");
    const inst = new WebAssembly.Instance(workerData.wasmModule, {
      env: {
        memory: workerData.sharedMem,
        knots_host_notify_complete: () => {},
      },
    });
    const runOne = inst.exports.knots_worker_run_one;
    parentPort.postMessage({ type: "ready" });
    parentPort.on("message", (msg) => {
      if (msg.type === "run") {
        runOne(msg.arg);
        parentPort.postMessage({ type: "done", task: msg.task });
      } else if (msg.type === "exit") {
        process.exit(0);
      }
    });
  `;

  const pmWorkers = [];
  await Promise.all(
    Array.from({ length: numWorkers }, (_, idx) => {
      return new Promise((resolve, reject) => {
        const w = new Worker(postMsgWorkerCode, {
          eval: true,
          workerData: { wasmModule, sharedMem },
        });
        const entry = { worker: w, id: idx + 1, busy: false };
        pmWorkers.push(entry);
        w.once("message", (m) => {
          if (m.type === "ready") resolve();
        });
        w.once("error", reject);
      });
    }),
  );

  function dispatchPostMessageBatch(count, baseArg) {
    return new Promise((resolve) => {
      let nextIdx = 0;
      let remaining = count;
      const pumpWorker = (entry) => {
        if (nextIdx < count) {
          const idx = nextIdx++;
          entry.busy = true;
          entry.worker.postMessage({
            type: "run",
            task: idx,
            arg: baseArg + idx,
          });
        } else {
          entry.busy = false;
        }
      };
      for (const entry of pmWorkers) {
        entry.worker.removeAllListeners("message");
        entry.worker.on("message", (msg) => {
          if (msg.type === "done") {
            remaining--;
            if (remaining === 0) {
              resolve();
              return;
            }
            pumpWorker(entry);
          }
        });
      }
      for (const entry of pmWorkers) {
        pumpWorker(entry);
      }
    });
  }

  let pmTotalMs = 0;
  let pmAccum = 0;
  try {
    exports.reset_queue_state();
    for (let r = 0; r < 3; r++) {
      await dispatchPostMessageBatch(tasksPerBatch, r * tasksPerBatch);
    }

    exports.reset_batch_stats();
    const tPm0 = performance.now();
    for (let r = 0; r < batchRounds; r++) {
      await dispatchPostMessageBatch(tasksPerBatch, r * tasksPerBatch);
    }
    pmTotalMs = performance.now() - tPm0;
    pmAccum = Atomics.load(sharedI32, 0x0280 >> 2);
  } finally {
    await Promise.all(
      pmWorkers.map(async (e) => {
        e.worker.postMessage({ type: "exit" });
        await e.worker.terminate();
      }),
    );
  }

  // --- Benchmark 4b: Persistent Wasm Futex Work Queue (`knots_worker_loop` + coalesced completion) ---
  const futexWorkerCode = `
    const { parentPort, workerData } = require("node:worker_threads");
    const inst = new WebAssembly.Instance(workerData.wasmModule, {
      env: {
        memory: workerData.sharedMem,
        knots_host_notify_complete: () => {
          parentPort.postMessage({ type: "complete" });
        },
      },
    });
    parentPort.postMessage({ type: "ready" });
    parentPort.on("message", (msg) => {
      if (msg.type === "park") {
        inst.exports.knots_worker_loop(msg.workerId);
        parentPort.postMessage({ type: "exited" });
      }
    });
  `;

  exports.reset_queue_state();
  let onBatchComplete = null;
  const futexWorkers = [];
  await Promise.all(
    Array.from({ length: numWorkers }, (_, idx) => {
      return new Promise((resolve, reject) => {
        const w = new Worker(futexWorkerCode, {
          eval: true,
          workerData: { wasmModule, sharedMem },
        });
        const workerId = idx + 1;
        w.on("message", (msg) => {
          if (msg.type === "ready") {
            w.postMessage({ type: "park", workerId });
            resolve();
          } else if (msg.type === "complete") {
            exports.knots_worker_ack_complete();
            if (onBatchComplete) {
              const cb = onBatchComplete;
              onBatchComplete = null;
              cb();
            }
          }
        });
        w.once("error", reject);
        futexWorkers.push(w);
      });
    }),
  );

  let fqTotalMs = 0;
  let fqAccum = 0;
  try {
    while (Atomics.load(sharedI32, 0x0100 >> 2) < numWorkers) {
      await new Promise((r) => setTimeout(r, 1));
    }

    const dispatchFutexBatch = (count, baseArg) =>
      new Promise((resolve) => {
        onBatchComplete = resolve;
        exports.enqueue_batch(count, baseArg);
      });

    for (let r = 0; r < 3; r++) {
      await dispatchFutexBatch(tasksPerBatch, r * tasksPerBatch);
    }

    exports.reset_batch_stats();
    const tFq0 = performance.now();
    for (let r = 0; r < batchRounds; r++) {
      await dispatchFutexBatch(tasksPerBatch, r * tasksPerBatch);
    }
    fqTotalMs = performance.now() - tFq0;
    fqAccum = Atomics.load(sharedI32, 0x0280 >> 2);
    if (fqAccum !== pmAccum) {
      throw new Error(
        `Worker queue checksum mismatch: futex=${fqAccum} vs postMessage=${pmAccum}`,
      );
    }
  } finally {
    exports.knots_worker_wake_all();
    await Promise.all(futexWorkers.map((w) => w.terminate()));
  }

  // --- Benchmark 5: Per-Worker Sharded Slab Allocator vs Global Spinlock Allocator ---
  const allocWorkerCode = `
    const { parentPort, workerData } = require("node:worker_threads");
    const inst = new WebAssembly.Instance(workerData.wasmModule, {
      env: {
        memory: workerData.sharedMem,
        knots_host_notify_complete: () => {},
      },
    });
    parentPort.postMessage({ type: "ready" });
    parentPort.on("message", (msg) => {
      if (msg.type === "global_lock") {
        const t0 = performance.now();
        const checksum = inst.exports.bench_global_lock_alloc(
          msg.workerId,
          msg.iterations,
          msg.expectedWorkers,
        );
        const elapsedMs = performance.now() - t0;
        parentPort.postMessage({ type: "alloc_done", checksum, elapsedMs });
      } else if (msg.type === "sharded_slab") {
        const t0 = performance.now();
        const checksum = inst.exports.bench_sharded_slab_alloc(
          msg.workerId,
          msg.iterations,
          msg.expectedWorkers,
        );
        const elapsedMs = performance.now() - t0;
        parentPort.postMessage({ type: "alloc_done", checksum, elapsedMs });
      } else if (msg.type === "exit") {
        process.exit(0);
      }
    });
  `;

  const allocWorkers = [];
  await Promise.all(
    Array.from({ length: numWorkers }, (_, idx) => {
      return new Promise((resolve, reject) => {
        const w = new Worker(allocWorkerCode, {
          eval: true,
          workerData: { wasmModule, sharedMem },
        });
        allocWorkers.push({ worker: w, workerId: idx + 1 });
        w.once("message", (m) => {
          if (m.type === "ready") resolve();
        });
        w.once("error", reject);
      });
    }),
  );

  let globalKernelTotalMs = 0;
  let shardedKernelTotalMs = 0;
  let globalChecksum = 0;
  let shardedChecksum = 0;
  const allocItersPerWorker = 25000;
  const allocRounds = 12;

  try {
    const runAllocRound = async (mode, iterationsPerWorker) => {
      if (mode === "global_lock") {
        exports.init_global_freelist(64);
      } else {
        exports.init_sharded_freelists(numWorkers, 16);
      }
      const results = await Promise.all(
        allocWorkers.map(
          ({ worker, workerId }) =>
            new Promise((resolve) => {
              worker.once("message", (msg) => {
                if (msg.type === "alloc_done") resolve(msg);
              });
              worker.postMessage({
                type: mode,
                workerId,
                iterations: iterationsPerWorker,
                expectedWorkers: numWorkers,
              });
            }),
        ),
      );
      const maxWorkerKernelMs = Math.max(...results.map((r) => r.elapsedMs));
      const checksum = results.reduce((acc, r) => (acc + r.checksum) | 0, 0);
      return { maxWorkerKernelMs, checksum };
    };

    for (let r = 0; r < 3; r++) {
      await runAllocRound("global_lock", 5000);
      await runAllocRound("sharded_slab", 5000);
    }

    for (let r = 0; r < allocRounds; r++) {
      const g = await runAllocRound("global_lock", allocItersPerWorker);
      const s = await runAllocRound("sharded_slab", allocItersPerWorker);
      globalKernelTotalMs += g.maxWorkerKernelMs;
      shardedKernelTotalMs += s.maxWorkerKernelMs;
      globalChecksum = g.checksum;
      shardedChecksum = s.checksum;
    }

    if (globalChecksum !== shardedChecksum) {
      throw new Error(
        `Allocator checksum mismatch: sharded=${shardedChecksum} vs global=${globalChecksum}`,
      );
    }
  } finally {
    await Promise.all(
      allocWorkers.map(async ({ worker }) => {
        worker.postMessage({ type: "exit" });
        await worker.terminate();
      }),
    );
  }

  // --- Benchmark 6: Frame-Safe Synchronous `knots_frame` + `knots_worker_poll(0)` vs `WebAssembly.promising(knots_frame)` ---
  const frameCalls = 10000;
  const syncFrame = exports.knots_frame;
  const promisingFrame =
    typeof WebAssembly.promising === "function"
      ? WebAssembly.promising(exports.knots_frame)
      : null;

  for (let i = 0; i < 2000; i++) {
    syncFrame(16);
    if (promisingFrame) {
      await promisingFrame(16);
    }
  }

  let syncSink = 0;
  const tSyncFrame0 = performance.now();
  for (let i = 0; i < frameCalls; i++) {
    syncSink = (syncSink + syncFrame(16)) | 0;
  }
  const syncFrameTotalUs = (performance.now() - tSyncFrame0) * 1000;
  const syncFrameNsPerCall = (syncFrameTotalUs * 1000) / frameCalls;

  let promisingFrameTotalUs = null;
  let promisingFrameNsPerCall = null;
  let promSink = 0;
  if (promisingFrame) {
    const tPromFrame0 = performance.now();
    for (let i = 0; i < frameCalls; i++) {
      promSink = (promSink + (await promisingFrame(16))) | 0;
    }
    promisingFrameTotalUs = (performance.now() - tPromFrame0) * 1000;
    promisingFrameNsPerCall = (promisingFrameTotalUs * 1000) / frameCalls;
  }

  const totalTasksDispatched = batchRounds * tasksPerBatch;
  const postMessageBatchMs = pmTotalMs / batchRounds;
  const postMessageUsPerTask = (pmTotalMs * 1000) / totalTasksDispatched;
  const futexRingBatchMs = fqTotalMs / batchRounds;
  const futexRingUsPerTask = (fqTotalMs * 1000) / totalTasksDispatched;

  const totalAllocOpsPerRound = numWorkers * allocItersPerWorker;
  const globalLockAvgMs = globalKernelTotalMs / allocRounds;
  const globalLockNsPerOp = (globalLockAvgMs * 1e6) / totalAllocOpsPerRound;
  const shardedSlabAvgMs = shardedKernelTotalMs / allocRounds;
  const shardedSlabNsPerOp = (shardedSlabAvgMs * 1e6) / totalAllocOpsPerRound;

  return {
    futexWorkQueue: {
      numWorkers,
      tasksPerBatch,
      batchRounds,
      totalTasks: totalTasksDispatched,
      postMessageBatchMs,
      postMessageUsPerTask,
      postMessageKTasksPerSec: tasksPerBatch / postMessageBatchMs,
      futexRingBatchMs,
      futexRingUsPerTask,
      futexRingKTasksPerSec: tasksPerBatch / futexRingBatchMs,
      speedup: pmTotalMs / fqTotalMs,
      checksum: fqAccum,
    },
    shardedAllocator: {
      numWorkers,
      itersPerWorker: allocItersPerWorker,
      totalOpsPerRound: totalAllocOpsPerRound,
      rounds: allocRounds,
      globalLockAvgMs,
      globalLockNsPerOp,
      globalLockMOpsPerSec: 1000 / globalLockNsPerOp,
      shardedSlabAvgMs,
      shardedSlabNsPerOp,
      shardedSlabMOpsPerSec: 1000 / shardedSlabNsPerOp,
      speedup: globalKernelTotalMs / shardedKernelTotalMs,
      checksum: shardedChecksum,
    },
    framePolling: {
      frameCalls,
      syncFrameTotalUs,
      syncFrameNsPerCall,
      syncFrameMCallsPerSec: 1000 / syncFrameNsPerCall,
      promisingFrameTotalUs,
      promisingFrameNsPerCall,
      promisingFrameMCallsPerSec:
        promisingFrameNsPerCall != null ? 1000 / promisingFrameNsPerCall : null,
      speedup:
        promisingFrameNsPerCall != null
          ? promisingFrameNsPerCall / syncFrameNsPerCall
          : null,
      sink: syncSink ^ promSink,
    },
  };
}

function getWasmtimeVersion() {
  const bin = findExecutable("wasmtime");
  if (!bin) return null;
  const res = spawnSync(bin, ["--version"], { encoding: "utf8" });
  return res.status === 0 ? res.stdout.trim() : null;
}

function formatNum(n, digits = 2) {
  if (n == null || Number.isNaN(n)) return "n/a";
  return Number(n).toFixed(digits);
}

function renderMarkdownReport(report) {
  const lines = [];
  lines.push("# V8 / Node 26 vs Wasmtime & WasmFX / JSPI Benchmark Results");
  lines.push("");
  lines.push("## Environment");
  lines.push("");
  lines.push(`- **Node.js**: \`${report.environment.nodeVersion}\` (V8 \`${report.environment.v8Version}\`)`);
  lines.push(`- **Wasmtime**: \`${report.environment.wasmtimeVersion || "not installed"}\``);
  lines.push(`- **Platform**: \`${report.environment.platform}-${report.environment.arch}\``);
  if (report.build && report.build.compilerKind) {
    lines.push(
      `- **Wasm artifact**: \`wasm_bench_runner.wasm\` (${report.build.sizeBytes.toLocaleString()} bytes, built with \`${report.build.compilerKind}\` in ${formatNum(report.build.compileMs, 0)} ms)`,
    );
  }
  lines.push("");

  lines.push("## 1. Synchronous `knots` Workloads (`wasm_bench_runner.wasm`)");
  lines.push("");
  lines.push(
    "| Benchmark | Iterations | Wasmtime Median (ms) | Node Default Median (ms) | Node + WasmFX Flags Median (ms) | Node / Wasmtime | WasmFX Flags / Default |",
  );
  lines.push(
    "|---|---:|---:|---:|---:|---:|---:|",
  );

  for (const name of SYNC_BENCHMARKS) {
    const wt = report.syncBenchmarks.wasmtime?.workloads?.[name];
    const nd = report.syncBenchmarks.nodeDefault.workloads[name];
    const fx = report.syncBenchmarks.nodeWasmfx.workloads[name];
    const wtMs = wt ? wt.median_ms : null;
    const ndMs = nd.median_ms;
    const fxMs = fx.median_ms;
    const ndVsWt = wtMs ? `${formatNum(ndMs / wtMs, 2)}x` : "n/a";
    const fxVsNd = `${formatNum(fxMs / ndMs, 2)}x`;
    lines.push(
      `| \`${name}\` | ${nd.iterations} | ${wtMs != null ? formatNum(wtMs, 4) : "n/a"} | ${formatNum(ndMs, 4)} | ${formatNum(fxMs, 4)} | ${ndVsWt} | ${fxVsNd} |`,
    );
  }
  if (report.syncBenchmarks.wasmtime) {
    lines.push(
      `| **\`total_bench_ms\`** | — | **${formatNum(report.syncBenchmarks.wasmtime.total_bench_ms, 2)} ms** | **${formatNum(report.syncBenchmarks.nodeDefault.total_bench_ms, 2)} ms** | **${formatNum(report.syncBenchmarks.nodeWasmfx.total_bench_ms, 2)} ms** | **${formatNum(report.syncBenchmarks.nodeDefault.total_bench_ms / report.syncBenchmarks.wasmtime.total_bench_ms, 2)}x** | **${formatNum(report.syncBenchmarks.nodeWasmfx.total_bench_ms / report.syncBenchmarks.nodeDefault.total_bench_ms, 2)}x** |`,
    );
  }
  lines.push("");

  lines.push("## 2. Runtime Capability Detection (`detectWasmCapabilities()`)");
  lines.push("");
  lines.push(
    "| Capability Check | Mechanism | Node Default | Node + `--experimental-wasm-wasmfx` | Probe Cost (ns/op) |",
  );
  lines.push("|---|---|:---:|:---:|---:|");
  const capDef = report.capabilityDetection.nodeDefault;
  const capFx = report.capabilityDetection.nodeWasmfx;
  lines.push(
    `| \`JSPI\` | \`typeof WebAssembly.Suspending === "function" && typeof WebAssembly.promising === "function"\` | \`${capDef.capabilities.jspi}\` | \`${capFx.capabilities.jspi}\` | ${formatNum(capFx.jspiNsPerOp, 2)} ns |`,
  );
  lines.push(
    `| \`Atomics.waitAsync\` | \`typeof Atomics.waitAsync === "function"\` | \`${capDef.capabilities.waitAsync}\` | \`${capFx.capabilities.waitAsync}\` | ${formatNum(capFx.waitAsyncNsPerOp, 2)} ns |`,
  );
  lines.push(
    `| \`WasmFX\` | \`WebAssembly.validate(WASMFX_PROBE_BYTES)\` (16-byte \`0x5d\` \`cont\` section) | \`${capDef.capabilities.wasmfx}\` | \`${capFx.capabilities.wasmfx}\` | ${formatNum(capFx.wasmfxNsPerOp, 2)} ns |`,
  );
  lines.push(
    `| **Combined** | \`detectWasmCapabilities()\` (uncached cold call) | — | — | ${formatNum(capFx.combinedNsPerOp, 2)} ns |`,
  );
  lines.push("");

  lines.push("## 3. `std.Io` Coroutine Suspend/Resume Microbenchmarks (V8)");
  lines.push("");
  const susp = report.microbenchmarks.suspension;
  lines.push(
    "| Mechanism | Operation | Latency (ns/op) | Throughput (M ops/s) | Comparison |",
  );
  lines.push("|---|---|---:|---:|---:|");
  lines.push(
    `| **WasmFX (active stack)** | \`suspend $yield\` + \`resume $ct\` on warm continuation | ${susp.wasmfxActiveNsPerOp != null ? `${formatNum(susp.wasmfxActiveNsPerOp, 2)} ns` : "n/a"} | ${susp.wasmfxActiveNsPerOp != null ? `${formatNum(1000 / susp.wasmfxActiveNsPerOp, 2)} M/s` : "n/a"} | ${susp.activeSpeedupVsJspiResolved != null ? `**${formatNum(susp.activeSpeedupVsJspiResolved, 2)}x faster** than JSPI (\`Promise.resolve\`), **${formatNum(susp.activeSpeedupVsJspiMicrotask, 2)}x faster** than JSPI (\`queueMicrotask\`)` : "n/a (requires V8 14+ WasmFX opcodes)"} |`,
  );
  lines.push(
    `| **JSPI (active stack, \`Promise.resolve\`)** | \`WebAssembly.Suspending\` + \`WebAssembly.promising\` immediate Promise | ${susp.jspiResolvedNsPerOp != null ? `${formatNum(susp.jspiResolvedNsPerOp, 2)} ns` : "n/a"} | ${susp.jspiResolvedNsPerOp != null ? `${formatNum(1000 / susp.jspiResolvedNsPerOp, 2)} M/s` : "n/a"} | 1.00x (active-stack JSPI baseline) |`,
  );
  lines.push(
    `| **JSPI (active stack, \`queueMicrotask\`)** | \`WebAssembly.Suspending\` + \`new Promise(r => queueMicrotask(r))\` | ${susp.jspiMicrotaskNsPerOp != null ? `${formatNum(susp.jspiMicrotaskNsPerOp, 2)} ns` : "n/a"} | ${susp.jspiMicrotaskNsPerOp != null ? `${formatNum(1000 / susp.jspiMicrotaskNsPerOp, 2)} M/s` : "n/a"} | ${susp.jspiMicrotaskNsPerOp != null && susp.jspiResolvedNsPerOp != null ? `${formatNum(susp.jspiMicrotaskNsPerOp / susp.jspiResolvedNsPerOp, 2)}x of JSPI (\`Promise.resolve\`)` : "n/a"} |`,
  );
  lines.push(
    `| **WasmFX (full lifecycle)** | \`cont.new\` + \`resume\` (1 suspend) + \`resume\` to completion | ${susp.wasmfxFullContNsPerOp != null ? `${formatNum(susp.wasmfxFullContNsPerOp, 2)} ns` : "n/a"} | ${susp.wasmfxFullContNsPerOp != null ? `${formatNum(1000 / susp.wasmfxFullContNsPerOp, 2)} M/s` : "n/a"} | ${susp.fullContSpeedupVsJspiFullCall != null ? `**${formatNum(susp.fullContSpeedupVsJspiFullCall, 2)}x faster** than full-lifecycle JSPI` : "n/a (requires V8 14+ WasmFX opcodes)"} |`,
  );
  lines.push(
    `| **JSPI (full lifecycle, \`queueMicrotask\`)** | \`await promisingExport(1)\` (enter stack + 1 suspend + exit) | ${susp.jspiFullCallNsPerOp != null ? `${formatNum(susp.jspiFullCallNsPerOp, 2)} ns` : "n/a"} | ${susp.jspiFullCallNsPerOp != null ? `${formatNum(1000 / susp.jspiFullCallNsPerOp, 2)} M/s` : "n/a"} | 1.00x (full-lifecycle JSPI baseline) |`,
  );
  lines.push("");

  lines.push(
    "## 4. Cooperative Frame-Budgeted Polygon Triangulation (10,000 steps, yield every 1,000)",
  );
  lines.push("");
  const tri = report.microbenchmarks.triangulation;
  lines.push(
    "| Mode | Yields / Call | Total Time (us) | Yield Overhead (us) | Overhead (%) | Checksum |",
  );
  lines.push("|---|---:|---:|---:|---:|---:|");
  lines.push(
    `| **Un-instrumented Wasm baseline** | 0 | ${formatNum(tri.baselineUs, 2)} us | 0.00 us | 0.0% | \`${tri.checksum}\` |`,
  );
  lines.push(
    `| **WasmFX (\`suspend\` / \`resume\`)** | ${tri.yieldsPerCall} | ${tri.wasmfxUs != null ? `${formatNum(tri.wasmfxUs, 2)} us` : "n/a"} | ${tri.wasmfxUs != null ? `+${formatNum(tri.wasmfxUs - tri.baselineUs, 2)} us` : "n/a"} | ${tri.wasmfxOverheadPct != null ? `+${formatNum(tri.wasmfxOverheadPct, 1)}%` : "n/a"} | \`${tri.checksum}\` |`,
  );
  lines.push(
    `| **JSPI (\`Suspending\` / \`promising\`)** | ${tri.yieldsPerCall} | ${tri.jspiUs != null ? `${formatNum(tri.jspiUs, 2)} us` : "n/a"} | ${tri.jspiUs != null ? `+${formatNum(tri.jspiUs - tri.baselineUs, 2)} us` : "n/a"} | ${tri.jspiOverheadPct != null ? `+${formatNum(tri.jspiOverheadPct, 1)}%` : "n/a"} | \`${tri.checksum}\` |`,
  );
  lines.push("");

  lines.push(
    "## 5. Main-Thread `std.Io` Futex Wait (`SharedArrayBuffer` `Int32Array`, 2 ms Worker Notify)",
  );
  lines.push("");
  const fw = report.microbenchmarks.futexWait;
  lines.push(
    "| Wait Strategy | Avg Wall Wait (us) | Avg Main-Thread CPU Burned (us) | Main-Thread Event-Loop Ticks During Wait | CPU Savings |",
  );
  lines.push("|---|---:|---:|---:|---:|");
  const cpuSavedPct =
    fw.waitAsyncJspi.avgCpuUs > 0
      ? ((fw.spinWait.avgCpuUs - fw.waitAsyncJspi.avgCpuUs) /
          fw.spinWait.avgCpuUs) *
        100
      : null;
  lines.push(
    `| **\`Atomics.waitAsync\` + JSPI** | ${formatNum(fw.waitAsyncJspi.avgWallUs, 1)} us | **${formatNum(fw.waitAsyncJspi.avgCpuUs, 1)} us** | ${formatNum(fw.waitAsyncJspi.eventLoopTicksPerWait, 1)} ticks (non-blocking) | **${formatNum(cpuSavedPct, 1)}% less CPU** |`,
  );
  lines.push(
    `| **Synchronous Wasm Spin-Wait (\`i32.atomic.load\`)** | ${formatNum(fw.spinWait.avgWallUs, 1)} us | ${formatNum(fw.spinWait.avgCpuUs, 1)} us | ${formatNum(fw.spinWait.eventLoopTicksPerWait, 1)} ticks (blocked) | 0.0% (100% core pinned) |`,
  );
  lines.push("");

  const wp = report.workerPoolBenchmarks || report.microbenchmarks.workerPool;
  if (wp) {
    const fq = wp.futexWorkQueue;
    lines.push(
      `## 6. Issue #28 Part 1: Persistent Wasm Futex Work Queue vs \`postMessage({ type: "run" })\` Dispatch (${fq.numWorkers} Workers, ${fq.tasksPerBatch} Tasks/Batch)`,
    );
    lines.push("");
    lines.push(
      "| Dispatch Path | Workers | Tasks / Batch | Avg Batch Time (ms) | Per-Task Latency (us/task) | Throughput (K tasks/s) | Speedup | Checksum |",
    );
    lines.push("|---|---:|---:|---:|---:|---:|---:|---:|");
    lines.push(
      `| **Persistent Wasm Futex Ring (\`knots_worker_loop\` + \`memory.atomic.wait32\` + coalesced notify)** | ${fq.numWorkers} | ${fq.tasksPerBatch} | **${formatNum(fq.futexRingBatchMs, 3)} ms** | **${formatNum(fq.futexRingUsPerTask, 2)} us** | **${formatNum(fq.futexRingKTasksPerSec, 1)} K/s** | **${formatNum(fq.speedup, 2)}x faster** | \`${fq.checksum}\` |`,
    );
    lines.push(
      `| **Per-Task \`postMessage({ type: "run" })\` + \`{ type: "done" }\` (Baseline)** | ${fq.numWorkers} | ${fq.tasksPerBatch} | ${formatNum(fq.postMessageBatchMs, 3)} ms | ${formatNum(fq.postMessageUsPerTask, 2)} us | ${formatNum(fq.postMessageKTasksPerSec, 1)} K/s | 1.00x (baseline) | \`${fq.checksum}\` |`,
    );
    lines.push("");
    lines.push(
      "- **Production Runtime (`src/wasm/WorkerRuntime.zig`) vs Standalone V8 Microbenchmark Kernel**: Production uses a 256-slot ring buffer + intrusive FIFO overflow list protected by a lightweight spinlock (`queue_lock`), a `work_seq` futex sequence word (`memory.atomic.wait32` / `memory.atomic.notify`), pre-warmed workers parked in `knots_worker_loop(workerId)`, and coalesced main-thread completion notifications (`notify_pending` -> `knots_host_notify_complete` / `knots_worker_ack_complete`), while the standalone Node V8 microbenchmark kernel models shared-memory futex ring dispatch vs per-task `worker.postMessage({ type: \"run\" })` round-trips.",
    );
    lines.push("");

    const sa = wp.shardedAllocator;
    lines.push(
      `## 7. Issue #28 Part 1: Per-Worker 64B-Aligned Sharded Slab Allocator vs Global Spinlock Allocator (${sa.numWorkers} Workers, ${sa.itersPerWorker.toLocaleString()} Alloc+Free/Worker)`,
    );
    lines.push("");
    lines.push(
      "| Allocator Strategy (`SharedArrayBuffer` Wasm Linear Memory) | Workers | Concurrent Ops / Round | Avg Round Time (ms) | Effective Latency (ns/op) | Throughput (M ops/s) | Speedup | Checksum |",
    );
    lines.push("|---|---:|---:|---:|---:|---:|---:|---:|");
    lines.push(
      `| **Per-Worker 64B-Aligned Sharded Slab (\`ShardedAllocator\`, \`currentWorkerId() % 16\`, \`align(64)\`)** | ${sa.numWorkers} | ${sa.totalOpsPerRound.toLocaleString()} | **${formatNum(sa.shardedSlabAvgMs, 3)} ms** | **${formatNum(sa.shardedSlabNsPerOp, 2)} ns** | **${formatNum(sa.shardedSlabMOpsPerSec, 2)} M/s** | **${formatNum(sa.speedup, 2)}x faster** | \`${sa.checksum}\` |`,
    );
    lines.push(
      `| **Global Atomic Spinlock Freelist (\`i32.atomic.rmw.cmpxchg\`)** | ${sa.numWorkers} | ${sa.totalOpsPerRound.toLocaleString()} | ${formatNum(sa.globalLockAvgMs, 3)} ms | ${formatNum(sa.globalLockNsPerOp, 2)} ns | ${formatNum(sa.globalLockMOpsPerSec, 2)} M/s | 1.00x (baseline) | \`${sa.checksum}\` |`,
    );
    lines.push("");
    lines.push(
      "- **Production Runtime (`src/wasm/ShardedAllocator.zig`)**: Implements `num_shards = 16` cache-line-aligned (`align(64)`) shards indexed by `currentWorkerId() % 16` (packed into the low 6 bits of the 64-byte-aligned `Task` pointer in `knots_worker_task`), with 9 power-of-two size classes from `16 B` to `4096 B` (`min_class_shift = 4`, `max_class_shift = 12`), per-shard spinlocks, O(1) lock-free same-class `resize`/`remap`, and cross-worker frees returned to the freeing worker's shard up to `max_cached_per_class = 64` before evicting to `std.heap.wasm_allocator`.",
    );
    lines.push("");

    const fp = wp.framePolling;
    lines.push(
      `## 8. Issue #28 Part 1: Frame-Safe Non-Blocking Task Polling (\`knots_frame\` + \`knots_worker_poll(0)\`) vs \`WebAssembly.promising(knots_frame)\` (${fp.frameCalls.toLocaleString()} Calls)`,
    );
    lines.push("");
    lines.push(
      "| Frame Entry / Poll Mode | Calls | Total Time (us) | Per-Frame Latency (ns/call) | Throughput (M calls/s) | Speedup |",
    );
    lines.push("|---|---:|---:|---:|---:|---:|");
    lines.push(
      `| **Synchronous \`knots_frame\` + non-blocking \`knots_worker_poll(0)\`** | ${fp.frameCalls.toLocaleString()} | **${formatNum(fp.syncFrameTotalUs, 2)} us** | **${formatNum(fp.syncFrameNsPerCall, 2)} ns** | **${formatNum(fp.syncFrameMCallsPerSec, 2)} M/s** | **${fp.speedup != null ? `${formatNum(fp.speedup, 2)}x faster` : "1.00x"}** |`,
    );
    lines.push(
      `| **\`WebAssembly.promising(knots_frame)\` (JSPI Promise + Stack Switch)** | ${fp.frameCalls.toLocaleString()} | ${formatNum(fp.promisingFrameTotalUs, 2)} us | ${formatNum(fp.promisingFrameNsPerCall, 2)} ns | ${formatNum(fp.promisingFrameMCallsPerSec, 2)} M/s | ${fp.speedup != null ? "1.00x (JSPI baseline)" : "n/a (JSPI unavailable)"} |`,
    );
    lines.push("");
    lines.push(
      "- **Frame-Safe Non-Blocking Task Polling (`src/web/host.js`, `src/wasm/threads.zig`)**: `src/web/host.js` keeps `knots_frame` unwrapped in `wrapExports` (not wrapped in `WebAssembly.promising`) and exposes non-blocking `threads.poll(max_tasks)`, `threads.pollGroup(&group)`, `threads.pollFuture(T, &future)`, and `knots_worker_poll` so frame callbacks can drain and inspect completed background tasks synchronously without JSPI suspension or `Promise` allocation overhead.",
    );
  }

  return lines.join("\n");
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.internalWasmfxChild) {
    const syncNodeWasmfx = runAllSyncBenchmarksInNode(opts.wasm);
    const capWasmfx = benchmarkCapabilityDetection();
    const micro = await runMicrobenchmarks();
    process.stdout.write(
      JSON.stringify({ syncNodeWasmfx, capWasmfx, micro }) + "\n",
    );
    return;
  }

  if (opts.internalDefaultNodeChild) {
    const syncNodeDefault = runAllSyncBenchmarksInNode(opts.wasm);
    const capDefault = benchmarkCapabilityDetection();
    process.stdout.write(
      JSON.stringify({ syncNodeDefault, capDefault }) + "\n",
    );
    return;
  }

  const buildInfo = opts.wasm
    ? {
        wasmPath: path.resolve(opts.wasm),
        compilerKind: null,
        compileMs: 0,
        sizeBytes: fs.statSync(path.resolve(opts.wasm)).size,
        tempDir: null,
      }
    : {
        ...buildWasmBenchRunner(),
        tempDir: path.join(REPO_ROOT, ".tmp", "bench-wasmfx"),
      };

  try {
    const currentCaps = detectWasmCapabilities();
    let syncNodeDefault;
    let capDefault;
    let syncNodeWasmfx;
    let capWasmfx;
    let micro;

    if (!currentCaps.wasmfx) {
      syncNodeDefault = runAllSyncBenchmarksInNode(buildInfo.wasmPath);
      capDefault = benchmarkCapabilityDetection();

      const childRes = spawnSync(
        process.execPath,
        [
          "--experimental-wasm-wasmfx",
          "--experimental-wasm-growable-stacks",
          SCRIPT_PATH,
          "--internal-wasmfx-child",
          "--wasm",
          buildInfo.wasmPath,
        ],
        { cwd: REPO_ROOT, encoding: "utf8" },
      );
      if (childRes.status === 0) {
        const parsedChild = JSON.parse(childRes.stdout.trim());
        syncNodeWasmfx = parsedChild.syncNodeWasmfx;
        capWasmfx = parsedChild.capWasmfx;
        micro = parsedChild.micro;
      } else {
        // Fallback for older Node/V8 builds (e.g. Node 22 / V8 12.4) that lack --experimental-wasm-wasmfx
        syncNodeWasmfx = syncNodeDefault;
        capWasmfx = capDefault;
        micro = await runMicrobenchmarks();
      }
    } else {
      syncNodeWasmfx = runAllSyncBenchmarksInNode(buildInfo.wasmPath);
      capWasmfx = benchmarkCapabilityDetection();
      micro = await runMicrobenchmarks();

      const filteredExecArgv = process.execArgv.filter(
        (flag) =>
          flag !== "--experimental-wasm-wasmfx" &&
          flag !== "--experimental-wasm-growable-stacks",
      );
      const childRes = spawnSync(
        process.execPath,
        [
          ...filteredExecArgv,
          SCRIPT_PATH,
          "--internal-default-node-child",
          "--wasm",
          buildInfo.wasmPath,
        ],
        { cwd: REPO_ROOT, encoding: "utf8", env: { ...process.env, NODE_OPTIONS: "" } },
      );
      if (childRes.status !== 0) {
        throw new Error(
          `Default Node child process failed:\n${childRes.stderr || childRes.stdout}`,
        );
      }
      const parsedChild = JSON.parse(childRes.stdout.trim());
      syncNodeDefault = parsedChild.syncNodeDefault;
      capDefault = parsedChild.capDefault;
    }

    const syncWasmtime = runAllSyncBenchmarksInWasmtime(buildInfo.wasmPath);

    const report = {
      environment: {
        nodeVersion: process.version,
        v8Version: process.versions.v8,
        wasmtimeVersion: getWasmtimeVersion(),
        platform: process.platform,
        arch: process.arch,
      },
      build: {
        compilerKind: buildInfo.compilerKind,
        compileMs: buildInfo.compileMs,
        sizeBytes: buildInfo.sizeBytes,
      },
      syncBenchmarks: {
        wasmtime: syncWasmtime,
        nodeDefault: syncNodeDefault,
        nodeWasmfx: syncNodeWasmfx,
      },
      capabilityDetection: {
        nodeDefault: capDefault,
        nodeWasmfx: capWasmfx,
      },
      microbenchmarks: micro,
      workerPoolBenchmarks: micro.workerPool,
    };

    if (opts.json) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(renderMarkdownReport(report));
    }
  } finally {
    if (buildInfo.tempDir) {
      fs.rmSync(buildInfo.tempDir, { recursive: true, force: true });
      const parentCacheDir = path.dirname(buildInfo.tempDir);
      try {
        if (fs.readdirSync(parentCacheDir).length === 0) {
          fs.rmdirSync(parentCacheDir);
        }
      } catch {
        // ignore
      }
    }
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_PATH) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
