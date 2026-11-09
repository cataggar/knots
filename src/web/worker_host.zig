const std = @import("std");
const builtin = @import("builtin");
const js = @import("js-bridge");

const is_wasm = builtin.cpu.arch.isWasm();
const has_atomics = is_wasm and std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);

pub const CAP_JSPI: u32 = 1 << 0;
pub const CAP_WAIT_ASYNC: u32 = 1 << 1;
pub const CAP_WASMFX: u32 = 1 << 2;
pub const CAP_PROMISING_ACTIVE: u32 = 1 << 3;
pub const CAP_STATIC_MASK: u32 = CAP_JSPI | CAP_WAIT_ASYNC | CAP_WASMFX;

const wasm_imports = struct {
    extern "env" fn knots_host_capabilities() u32;
    extern "env" fn knots_host_wait_async32(
        addr_ptr: u32,
        expected: i32,
        timeout_ns_lo: u32,
        timeout_ns_hi: u32,
    ) i32;
    extern "env" fn knots_host_sleep_ms(ms: f64) void;
};

pub fn capabilities() u32 {
    if (!is_wasm) return 0;
    return wasm_imports.knots_host_capabilities();
}

pub fn hasJspi() bool {
    return (capabilities() & CAP_JSPI) != 0;
}

pub fn canSuspendJspi() bool {
    const caps = capabilities();
    return (caps & (CAP_JSPI | CAP_PROMISING_ACTIVE)) == (CAP_JSPI | CAP_PROMISING_ACTIVE);
}

pub fn hasWaitAsync() bool {
    return (capabilities() & CAP_WAIT_ASYNC) != 0;
}

pub fn hasWasmFx() bool {
    return (capabilities() & CAP_WASMFX) != 0;
}

/// Returns 0 when woken, 1 if `ptr` did not hold `expected`, 2 on timeout.
pub fn waitAsync32(ptr: *const u32, expected: u32, timeout_ns: ?u64) u32 {
    if (@atomicLoad(u32, ptr, .seq_cst) != expected) return 1;
    if (timeout_ns) |ns| {
        if (ns == 0) return 2;
    }
    if (!is_wasm or !canSuspendJspi() or !hasWaitAsync()) return 2;
    const raw_timeout: u64 = timeout_ns orelse std.math.maxInt(u64);
    const timeout_lo: u32 = @truncate(raw_timeout);
    const timeout_hi: u32 = @truncate(raw_timeout >> 32);
    const addr_ptr: u32 = @truncate(@intFromPtr(ptr));
    const rc = wasm_imports.knots_host_wait_async32(
        addr_ptr,
        @bitCast(expected),
        timeout_lo,
        timeout_hi,
    );
    return @bitCast(rc);
}

pub fn sleepMs(ms: f64) void {
    if (!is_wasm or !canSuspendJspi()) return;
    if (!std.math.isFinite(ms) or ms <= 0) return;
    wasm_imports.knots_host_sleep_ms(ms);
}

pub fn spawnConcurrent(task: usize, group: usize, start: usize, context: usize) bool {
    const host = js.host() catch return false;
    defer host.release();
    const spawned = host.call("spawnConcurrent", &.{
        js.Arg.usize(task),
        js.Arg.usize(group),
        js.Arg.usize(start),
        js.Arg.usize(context),
    }) catch return false;
    defer spawned.release();
    return spawned.tryBool() catch false;
}

pub fn forgetConcurrentGroup(group: usize) void {
    const host = js.host() catch return;
    defer host.release();
    host.callVoid("forgetConcurrentGroup", &.{js.Arg.usize(group)}) catch {};
}

pub fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    switch (clock) {
        .real, .awake, .boot => {
            const host = js.host() catch return .zero;
            defer host.release();
            const result = host.call("nowMs", &.{js.Arg.u32(@backingInt(clock))}) catch return .zero;
            defer result.release();
            const ms = result.tryF64() catch return .zero;
            if (!std.math.isFinite(ms) or ms <= 0) return .zero;
            return .fromNanoseconds(@intFromFloat(ms * @as(f64, std.time.ns_per_ms)));
        },
        .cpu_process, .cpu_thread => return .zero,
    }
}

comptime {
    if (has_atomics) {
        if (@sizeOf(usize) == 4) {
            asm (
                \\.globaltype knots_worker_task, i32
                \\knots_worker_task:
            );
        } else {
            asm (
                \\.globaltype knots_worker_task, i64
                \\knots_worker_task:
            );
        }
    }
}

pub fn currentTask() usize {
    return asm volatile (
        \\ global.get knots_worker_task
        \\ local.set %[address]
        : [address] "=r" (-> usize),
    );
}

pub fn setCurrentTask(address: usize) void {
    asm volatile (
        \\ local.get %[address]
        \\ global.set knots_worker_task
        :
        : [address] "r" (address),
    );
}

pub fn atomicWait(ptr: *const u32, expected: u32, timeout_ns: i64) u32 {
    return asm volatile (
        \\ local.get %[ptr]
        \\ local.get %[expected]
        \\ local.get %[timeout]
        \\ memory.atomic.wait32 0
        \\ local.set %[result]
        : [result] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [expected] "r" (expected),
          [timeout] "r" (timeout_ns),
    );
}

pub fn atomicNotify(ptr: *const u32, max_waiters: u32) void {
    _ = asm volatile (
        \\ local.get %[ptr]
        \\ local.get %[max_waiters]
        \\ memory.atomic.notify 0
        \\ local.set %[result]
        : [result] "=r" (-> u32),
        : [ptr] "r" (ptr),
          [max_waiters] "r" (max_waiters),
    );
}

test "worker_host non-wasm capability and waitAsync32 fallbacks" {
    try std.testing.expectEqual(@as(u32, 0), capabilities());
    try std.testing.expect(!hasJspi());
    try std.testing.expect(!canSuspendJspi());
    try std.testing.expect(!hasWaitAsync());
    try std.testing.expect(!hasWasmFx());

    var state: u32 = 42;
    try std.testing.expectEqual(@as(u32, 1), waitAsync32(&state, 7, 1_000_000));
    try std.testing.expectEqual(@as(u32, 2), waitAsync32(&state, 42, 0));
    try std.testing.expectEqual(@as(u32, 2), waitAsync32(&state, 42, 1_000_000));
    sleepMs(0);
    sleepMs(1.0);
}
