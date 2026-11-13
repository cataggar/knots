const std = @import("std");
const builtin = @import("builtin");
pub const worker_host = @import("worker_host");
pub const WorkerRuntime = @import("WorkerRuntime.zig");
pub const Runtime = WorkerRuntime;
pub const ShardedAllocator = WorkerRuntime.ShardedAllocator;

pub const allocator: std.mem.Allocator = WorkerRuntime.allocator();
pub const poll = WorkerRuntime.poll;
pub const pollGroup = WorkerRuntime.pollGroup;
pub const runningCount = WorkerRuntime.runningCount;
pub const queuedTasks = WorkerRuntime.queuedTasks;
pub const activeWorkers = WorkerRuntime.activeWorkers;
pub const currentWorkerId = WorkerRuntime.currentWorkerId;

pub fn pollFuture(comptime T: type, future: *std.Io.Future(T)) ?T {
    const any_future = future.any_future orelse return future.result;
    const state: *FutureState = @ptrCast(@alignCast(any_future));
    if (!WorkerRuntime.pollGroup(&state.group)) return null;
    state.finish(@ptrCast(&future.result));
    future.any_future = null;
    return future.result;
}

pub fn install(table: *std.Io.VTable) void {
    comptime exportWorkerSymbols();
    table.async = futureAsync;
    table.concurrent = futureConcurrent;
    table.await = futureAwait;
    table.cancel = futureCancel;
    table.groupAsync = groupAsync;
    table.groupConcurrent = groupConcurrent;
    table.recancel = recancel;
    table.swapCancelProtection = swapCancelProtection;
    table.checkCancel = checkCancel;
    table.sleep = sleep;
    table.groupAwait = groupAwait;
    table.groupCancel = groupCancel;
    table.futexWait = futexWait;
    table.futexWaitUncancelable = futexWaitUncancelable;
    table.futexWake = futexWake;
}

const clock: std.Io = .{ .userdata = null, .vtable = &clock_vtable };
const clock_vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.now = worker_host.now;
    break :blk table;
};

const FutureState = struct {
    group: std.Io.Group = .init,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,

    fn run(context: *const anyopaque) void {
        const self: *FutureState = @as(*const *FutureState, @ptrCast(@alignCast(context))).*;
        self.start(self.context.ptr, self.result.ptr);
    }

    fn finish(self: *FutureState, result: []u8) void {
        @memcpy(result, self.result);
        if (self.result.len > 0) allocator.rawFree(self.result, self.result_alignment, @returnAddress());
        if (self.context.len > 0) allocator.rawFree(self.context, self.context_alignment, @returnAddress());
        allocator.destroy(self);
    }
};

fn futureConcurrent(
    _: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) std.Io.ConcurrentError!*std.Io.AnyFuture {
    const state = allocator.create(FutureState) catch return error.ConcurrencyUnavailable;
    errdefer allocator.destroy(state);
    const result: []u8 = if (result_len == 0) &.{} else (allocator.rawAlloc(result_len, result_alignment, @returnAddress()) orelse
        return error.ConcurrencyUnavailable)[0..result_len];
    errdefer if (result.len > 0) allocator.rawFree(result, result_alignment, @returnAddress());
    @memset(result, 0);
    const context_copy: []u8 = if (context.len == 0) &.{} else (allocator.rawAlloc(context.len, context_alignment, @returnAddress()) orelse
        return error.ConcurrencyUnavailable)[0..context.len];
    errdefer if (context_copy.len > 0) allocator.rawFree(context_copy, context_alignment, @returnAddress());
    @memcpy(context_copy, context);
    state.* = .{
        .result = result,
        .result_alignment = result_alignment,
        .context = context_copy,
        .context_alignment = context_alignment,
        .start = start,
    };
    try Runtime.concurrent(&state.group, std.mem.asBytes(&state), .of(*FutureState), FutureState.run);
    return @ptrCast(state);
}

fn futureAsync(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*std.Io.AnyFuture {
    return futureConcurrent(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        start(context.ptr, result.ptr);
        return null;
    };
}

fn futureAwait(_: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
    const state: *FutureState = @ptrCast(@alignCast(any_future));
    if (state.group.token.load(.acquire)) |token| Runtime.await(&state.group, token) catch {};
    state.finish(result);
}

fn futureCancel(_: ?*anyopaque, any_future: *std.Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
    const state: *FutureState = @ptrCast(@alignCast(any_future));
    if (state.group.token.load(.acquire)) |token| Runtime.cancel(&state.group, token);
    state.finish(result);
}

fn groupConcurrent(
    _: ?*anyopaque,
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) std.Io.ConcurrentError!void {
    try Runtime.concurrent(group, context, context_alignment, start);
}

fn groupAsync(
    userdata: ?*anyopaque,
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    groupConcurrent(userdata, group, context, context_alignment, start) catch start(context.ptr);
}

fn groupAwait(_: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) std.Io.Cancelable!void {
    try Runtime.await(group, token);
}

fn groupCancel(_: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) void {
    Runtime.cancel(group, token);
}

fn recancel(_: ?*anyopaque) void {
    Runtime.recancel();
}

fn swapCancelProtection(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
    return Runtime.swapCancelProtection(new);
}

fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {
    if (Runtime.isCanceled()) return error.Canceled;
}

fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    if (Runtime.cancelAddress()) |cancel_ptr| {
        const deadline = timeout.toDeadline(clock);
        while (true) {
            try checkCancel(null);
            const timeout_ns = waitNanoseconds(deadline.toDurationFromNow(clock));
            if (timeout_ns == 0) return;
            if (Runtime.atomicWait(cancel_ptr, 0, timeout_ns) == 2) return;
        }
    }
    const timeout_ns = waitNanoseconds(timeout.toDurationFromNow(clock));
    if (timeout_ns == 0) return;
    if (worker_host.canSuspendJspi() and timeout_ns > 0) {
        const ms = @as(f64, @floatFromInt(timeout_ns)) / @as(f64, std.time.ns_per_ms);
        worker_host.sleepMs(ms);
        return;
    }
    var dummy: u32 = 0;
    _ = Runtime.atomicWait(&dummy, 0, timeout_ns);
}

pub fn singleThreadSleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const duration = timeout.toDurationFromNow(clock) orelse return;
    const ns: i64 = @intCast(std.math.clamp(duration.raw.nanoseconds, 0, std.math.maxInt(i64)));
    if (ns <= 0) return;
    if (worker_host.canSuspendJspi()) {
        const ms = @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
        worker_host.sleepMs(ms);
        return;
    }
    const start_ns = worker_host.now(null, .awake).nanoseconds;
    if (start_ns <= 0) return;
    const deadline_ns = start_ns + @as(i96, ns);
    while (true) {
        const current_ns = worker_host.now(null, .awake).nanoseconds;
        if (current_ns <= 0 or current_ns >= deadline_ns) break;
        std.atomic.spinLoopHint();
    }
}

pub fn singleThreadFutexWait(_: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    if (@atomicLoad(u32, ptr, .acquire) != expected) return;
    const timeout_ns = waitNanoseconds(timeout.toDurationFromNow(clock));
    if (timeout_ns == 0) return;
    if (worker_host.canSuspendJspi() and worker_host.hasWaitAsync()) {
        const timeout_opt: ?u64 = if (timeout_ns < 0) null else @intCast(timeout_ns);
        _ = worker_host.waitAsync32(ptr, expected, timeout_opt);
    }
}

pub fn singleThreadFutexWaitUncancelable(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
    if (@atomicLoad(u32, ptr, .acquire) != expected) return;
    if (worker_host.canSuspendJspi() and worker_host.hasWaitAsync()) {
        _ = worker_host.waitAsync32(ptr, expected, null);
    }
}

fn futexWait(_: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    try checkCancel(null);
    Runtime.beginWait(ptr);
    defer Runtime.endWait();
    try checkCancel(null);
    _ = Runtime.atomicWait(ptr, expected, waitNanoseconds(timeout.toDurationFromNow(clock)));
    try checkCancel(null);
}

/// -1 waits without a timeout, 0 means the time is up.
fn waitNanoseconds(remaining: ?std.Io.Clock.Duration) i64 {
    const duration = remaining orelse return -1;
    return @intCast(std.math.clamp(duration.raw.nanoseconds, 0, std.math.maxInt(i64)));
}

fn futexWaitUncancelable(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = Runtime.atomicWait(ptr, expected, -1);
}

fn futexWake(_: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    Runtime.atomicNotify(ptr, max_waiters);
}

fn exportWorkerSymbols() void {
    const export_cc: std.builtin.CallingConvention = if (builtin.cpu.arch.isWasm()) .{ .wasm_mvp = .{} } else .c;
    const exports = struct {
        fn run(start: usize, context: usize, task: *Runtime.Task) callconv(export_cc) void {
            Runtime.run(start, context, task);
        }

        fn complete(task: *Runtime.Task) callconv(export_cc) void {
            Runtime.complete(task);
        }

        fn release(task: *Runtime.Task) callconv(export_cc) void {
            Runtime.release(task);
        }

        fn abort(task: *Runtime.Task) callconv(export_cc) void {
            Runtime.abort(task);
        }

        fn stackAlloc() callconv(export_cc) usize {
            return Runtime.allocateStack();
        }

        fn stackFree(stack_top: usize) callconv(export_cc) void {
            Runtime.freeStack(stack_top);
        }

        fn loop(worker_id: u32) callconv(export_cc) void {
            Runtime.workerLoop(worker_id);
        }

        fn poll(max_tasks: u32) callconv(export_cc) u32 {
            return @intCast(@min(Runtime.poll(max_tasks), std.math.maxInt(u32)));
        }

        fn wakeAll() callconv(export_cc) void {
            Runtime.wakeAllWorkers();
        }

        fn ackComplete() callconv(export_cc) void {
            Runtime.ackComplete();
        }

        fn currentTask() callconv(export_cc) usize {
            return if (Runtime.currentTask()) |task| @intFromPtr(task) else 0;
        }

        fn setMaxWorkers(max_workers: u32) callconv(export_cc) void {
            Runtime.setMaxWorkers(max_workers);
        }
    };
    @export(&exports.run, .{ .name = "knots_worker_run" });
    @export(&exports.complete, .{ .name = "knots_worker_complete" });
    @export(&exports.release, .{ .name = "knots_worker_release" });
    @export(&exports.abort, .{ .name = "knots_worker_abort" });
    @export(&exports.stackAlloc, .{ .name = "knots_worker_stack_alloc" });
    @export(&exports.stackFree, .{ .name = "knots_worker_stack_free" });
    @export(&exports.loop, .{ .name = "knots_worker_loop" });
    @export(&exports.poll, .{ .name = "knots_worker_poll" });
    @export(&exports.wakeAll, .{ .name = "knots_worker_wake_all" });
    @export(&exports.ackComplete, .{ .name = "knots_worker_ack_complete" });
    @export(&exports.currentTask, .{ .name = "knots_worker_current_task" });
    @export(&exports.setMaxWorkers, .{ .name = "knots_worker_set_max_workers" });
}

test {
    _ = ShardedAllocator;
    _ = worker_host;
}

test "packed worker_id and 64-byte aligned Task pointer in knots_worker_task" {
    defer {
        WorkerRuntime.setCurrentTask(null);
        WorkerRuntime.setCurrentWorkerId(0);
    }

    var state: WorkerRuntime.State = .{};
    var task_a: WorkerRuntime.Task = .{ .state = &state };
    var task_b: WorkerRuntime.Task = .{ .state = &state };

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&task_a) & 0x3f);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&task_b) & 0x3f);

    WorkerRuntime.setCurrentWorkerId(17);
    try std.testing.expectEqual(@as(u32, 17), WorkerRuntime.currentWorkerId());
    try std.testing.expectEqual(@as(?*WorkerRuntime.Task, null), WorkerRuntime.currentTask());

    WorkerRuntime.setCurrentTask(&task_a);
    try std.testing.expectEqual(@as(u32, 17), WorkerRuntime.currentWorkerId());
    try std.testing.expectEqual(@as(?*WorkerRuntime.Task, &task_a), WorkerRuntime.currentTask());

    WorkerRuntime.setCurrentWorkerId(63);
    try std.testing.expectEqual(@as(u32, 63), WorkerRuntime.currentWorkerId());
    try std.testing.expectEqual(@as(?*WorkerRuntime.Task, &task_a), WorkerRuntime.currentTask());

    WorkerRuntime.setCurrentTask(&task_b);
    try std.testing.expectEqual(@as(u32, 63), WorkerRuntime.currentWorkerId());
    try std.testing.expectEqual(@as(?*WorkerRuntime.Task, &task_b), WorkerRuntime.currentTask());
}

test "multi-worker sharded allocator routing via setCurrentWorkerId and threads.allocator" {
    defer {
        WorkerRuntime.setCurrentTask(null);
        WorkerRuntime.setCurrentWorkerId(0);
        ShardedAllocator.flushGlobalShards();
    }

    ShardedAllocator.flushGlobalShards();
    const global_pool = ShardedAllocator.globalPool();
    const class_32 = ShardedAllocator.classIndex(24, .@"1").?;
    const class_128 = ShardedAllocator.classIndex(96, .@"1").?;

    var buffers: [16][]u8 = undefined;
    var wid: u32 = 1;
    while (wid <= 16) : (wid += 1) {
        WorkerRuntime.setCurrentWorkerId(wid);
        try std.testing.expectEqual(wid, currentWorkerId());

        var buf = try allocator.alloc(u8, 24);
        @memset(buf, @intCast(wid));
        // Batch refill of 4 for 32B class leaves 3 cached in the worker's shard (wid % 16)
        try std.testing.expectEqual(@as(u16, 3), global_pool.cachedCount(wid, class_32));

        // Same-class resize and remap succeed in place
        const orig_ptr = buf.ptr;
        try std.testing.expect(allocator.resize(buf, 32));
        buf = buf.ptr[0..32];
        const remapped = allocator.remap(buf, 20);
        try std.testing.expect(remapped != null);
        try std.testing.expectEqual(orig_ptr, remapped.?.ptr);
        buffers[wid - 1] = remapped.?;
    }

    // Cross-worker free: allocate on worker 2, free on worker 11, and reuse on worker 11
    WorkerRuntime.setCurrentWorkerId(2);
    const cross_slice = try allocator.alloc(u8, 96);
    const cross_ptr = cross_slice.ptr;
    try std.testing.expectEqual(@as(u16, 3), global_pool.cachedCount(2, class_128));

    WorkerRuntime.setCurrentWorkerId(11);
    try std.testing.expectEqual(@as(u16, 0), global_pool.cachedCount(11, class_128));
    allocator.free(cross_slice);
    try std.testing.expectEqual(@as(u16, 1), global_pool.cachedCount(11, class_128));

    const reused = try allocator.alloc(u8, 128);
    try std.testing.expectEqual(cross_ptr, reused.ptr);
    allocator.free(reused);

    // Free all per-worker buffers on rotated worker IDs and flush global shards
    for (buffers, 0..) |buf, idx| {
        const free_wid: u32 = @intCast(((idx + 5) % 16) + 1);
        WorkerRuntime.setCurrentWorkerId(free_wid);
        allocator.free(buf);
    }

    ShardedAllocator.flushGlobalShards();
    for (0..ShardedAllocator.num_shards) |shard_idx| {
        try std.testing.expectEqual(@as(u16, 0), global_pool.cachedCount(shard_idx, class_32));
        try std.testing.expectEqual(@as(u16, 0), global_pool.cachedCount(shard_idx, class_128));
    }
}

test "futex work queue ring buffer and overflow preserve FIFO order" {
    const total = WorkerRuntime.queue_capacity + 40;
    var state: WorkerRuntime.State = .{};
    var tasks: [total]WorkerRuntime.Task = undefined;

    for (&tasks) |*t| {
        t.* = .{ .state = &state };
        WorkerRuntime.enqueueForTesting(t);
    }
    try std.testing.expectEqual(total, WorkerRuntime.queuedTasks());

    for (&tasks) |*expected| {
        const popped = WorkerRuntime.tryPopForTesting();
        try std.testing.expectEqual(@as(?*WorkerRuntime.Task, expected), popped);
    }
    try std.testing.expectEqual(@as(usize, 0), WorkerRuntime.queuedTasks());
    try std.testing.expectEqual(@as(?*WorkerRuntime.Task, null), WorkerRuntime.tryPopForTesting());
}

test "workerLoop drains queued tasks, coalesces notifyComplete, and pollGroup/pollFuture complete non-blockingly" {
    var vtable = std.Io.failing.vtable.*;
    install(&vtable);
    const test_io: std.Io = .{ .userdata = null, .vtable = &vtable };

    const Harness = struct {
        var notify_calls: u32 = 0;
        var sum: std.atomic.Value(u32) = .init(0);

        fn onNotifyComplete() void {
            notify_calls += 1;
        }

        fn onAtomicWait(_: *const u32, _: u32, _: i64) u32 {
            WorkerRuntime.requestShutdown();
            return 0;
        }

        fn addTask(val: u32) void {
            _ = sum.fetchAdd(val, .acq_rel);
        }

        fn computeSquare(val: u32) u32 {
            return val * val;
        }
    };

    Harness.notify_calls = 0;
    Harness.sum.store(0, .release);
    worker_host.notify_complete_hook = &Harness.onNotifyComplete;
    worker_host.atomic_wait_hook = &Harness.onAtomicWait;
    defer {
        worker_host.notify_complete_hook = null;
        worker_host.atomic_wait_hook = null;
        worker_host.spawn_concurrent_hook = null;
        WorkerRuntime.resetShutdown();
        WorkerRuntime.setCurrentTask(null);
        WorkerRuntime.setCurrentWorkerId(0);
    }

    _ = poll(0);

    var group: std.Io.Group = .init;

    const EnqueueSpawn = struct {
        fn onSpawn(task_addr: usize, _: usize, _: usize, _: usize) bool {
            const task: *WorkerRuntime.Task = @ptrFromInt(task_addr);
            WorkerRuntime.enqueueTask(task);
            return true;
        }
    };
    worker_host.spawn_concurrent_hook = &EnqueueSpawn.onSpawn;

    try group.concurrent(test_io, Harness.addTask, .{10});
    try group.concurrent(test_io, Harness.addTask, .{20});
    try group.concurrent(test_io, Harness.addTask, .{30});

    var future = try test_io.concurrent(Harness.computeSquare, .{9});

    try std.testing.expectEqual(@as(usize, 3), runningCount(&group));
    try std.testing.expect(!pollGroup(&group));
    try std.testing.expectEqual(@as(?u32, null), pollFuture(u32, &future));

    WorkerRuntime.resetShutdown();
    WorkerRuntime.workerLoop(3);

    // Coalesced notification fired only once while notify_pending was 1
    try std.testing.expectEqual(@as(u32, 1), Harness.notify_calls);
    try std.testing.expectEqual(@as(u32, 60), Harness.sum.load(.acquire));

    const completed = poll(0);
    try std.testing.expectEqual(@as(usize, 4), completed);
    try std.testing.expect(pollGroup(&group));
    try std.testing.expectEqual(@as(usize, 0), runningCount(&group));
    try std.testing.expectEqual(@as(?u32, 81), pollFuture(u32, &future));
    // Polling an already-resolved future returns the cached result idempotently
    try std.testing.expectEqual(@as(?u32, 81), pollFuture(u32, &future));
}

test "non-blocking poll(max_tasks), pollGroup, pollFuture, and runningCount step-by-step lifecycle" {
    var vtable = std.Io.failing.vtable.*;
    install(&vtable);
    const test_io: std.Io = .{ .userdata = null, .vtable = &vtable };

    const StepHarness = struct {
        var acc: std.atomic.Value(u32) = .init(0);

        fn onSpawn(task_addr: usize, _: usize, _: usize, _: usize) bool {
            const task: *WorkerRuntime.Task = @ptrFromInt(task_addr);
            WorkerRuntime.enqueueTask(task);
            return true;
        }

        fn addVal(v: u32) void {
            _ = acc.fetchAdd(v, .acq_rel);
        }

        fn computeCube(v: u32) u32 {
            return v * v * v;
        }
    };

    StepHarness.acc.store(0, .release);
    worker_host.spawn_concurrent_hook = &StepHarness.onSpawn;
    defer {
        worker_host.spawn_concurrent_hook = null;
        WorkerRuntime.setCurrentTask(null);
        WorkerRuntime.setCurrentWorkerId(0);
    }

    _ = poll(0);

    var group: std.Io.Group = .init;
    try std.testing.expectEqual(@as(usize, 0), runningCount(&group));
    try std.testing.expect(pollGroup(&group));

    try group.concurrent(test_io, StepHarness.addVal, .{1});
    try group.concurrent(test_io, StepHarness.addVal, .{2});
    try group.concurrent(test_io, StepHarness.addVal, .{4});
    var future = try test_io.concurrent(StepHarness.computeCube, .{5});

    try std.testing.expectEqual(@as(usize, 4), queuedTasks());
    try std.testing.expectEqual(@as(usize, 3), runningCount(&group));
    try std.testing.expect(!pollGroup(&group));
    try std.testing.expectEqual(@as(?u32, null), pollFuture(u32, &future));

    // Drain 2 of the 3 group tasks
    try std.testing.expectEqual(@as(usize, 2), poll(2));
    try std.testing.expectEqual(@as(u32, 3), StepHarness.acc.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queuedTasks());
    try std.testing.expectEqual(@as(usize, 1), runningCount(&group));
    try std.testing.expect(!pollGroup(&group));
    try std.testing.expectEqual(@as(?u32, null), pollFuture(u32, &future));

    // Drain the final group task; future is still queued
    try std.testing.expectEqual(@as(usize, 1), poll(1));
    try std.testing.expectEqual(@as(u32, 7), StepHarness.acc.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), queuedTasks());
    try std.testing.expectEqual(@as(usize, 0), runningCount(&group));
    try std.testing.expect(pollGroup(&group));
    try std.testing.expectEqual(@as(?u32, null), pollFuture(u32, &future));

    // Drain the queued future task
    try std.testing.expectEqual(@as(usize, 1), poll(4));
    try std.testing.expectEqual(@as(usize, 0), queuedTasks());
    try std.testing.expectEqual(@as(?u32, 125), pollFuture(u32, &future));
}

test "waitForTasks work-helping drains queued tasks and nested group/future await preserves currentTask" {
    var vtable = std.Io.failing.vtable.*;
    install(&vtable);
    const test_io: std.Io = .{ .userdata = null, .vtable = &vtable };

    const Helper = struct {
        var total: std.atomic.Value(u32) = .init(0);
        var nested_task_preserved: std.atomic.Value(u32) = .init(0);

        fn onSpawn(task_addr: usize, _: usize, _: usize, _: usize) bool {
            const task: *WorkerRuntime.Task = @ptrFromInt(task_addr);
            WorkerRuntime.enqueueTask(task);
            return true;
        }

        fn leafWork(val: u32) void {
            _ = total.fetchAdd(val, .acq_rel);
        }

        fn leafMul(a: u32, b: u32) u32 {
            return a * b;
        }

        fn nestedSpawner(io: std.Io, base: u32) void {
            const self_task = WorkerRuntime.currentTask();
            const self_wid = WorkerRuntime.currentWorkerId();

            var inner_group: std.Io.Group = .init;
            inner_group.concurrent(io, leafWork, .{base}) catch unreachable;
            inner_group.concurrent(io, leafWork, .{base * 2}) catch unreachable;
            var inner_future = io.concurrent(leafMul, .{ base, 3 }) catch unreachable;

            inner_group.await(io) catch unreachable;
            const mul_res = inner_future.await(io);
            _ = total.fetchAdd(mul_res, .acq_rel);

            if (self_task != null and
                WorkerRuntime.currentTask() == self_task and
                WorkerRuntime.currentWorkerId() == self_wid)
            {
                _ = nested_task_preserved.fetchAdd(1, .acq_rel);
            }
        }
    };

    Helper.total.store(0, .release);
    Helper.nested_task_preserved.store(0, .release);
    worker_host.spawn_concurrent_hook = &Helper.onSpawn;
    defer {
        worker_host.spawn_concurrent_hook = null;
        WorkerRuntime.setCurrentTask(null);
        WorkerRuntime.setCurrentWorkerId(0);
    }

    var outer_state: WorkerRuntime.State = .{};
    var outer_task: WorkerRuntime.Task = .{ .state = &outer_state };
    WorkerRuntime.setCurrentWorkerId(5);
    WorkerRuntime.setCurrentTask(&outer_task);

    var group: std.Io.Group = .init;
    try group.concurrent(test_io, Helper.leafWork, .{7});
    try group.concurrent(test_io, Helper.nestedSpawner, .{ test_io, 10 });
    var top_future = try test_io.concurrent(Helper.leafMul, .{ 6, 7 });

    try group.await(test_io);
    const future_val = top_future.await(test_io);

    // 7 + (10 + 20 + 30) = 67
    try std.testing.expectEqual(@as(u32, 67), Helper.total.load(.acquire));
    try std.testing.expectEqual(@as(u32, 42), future_val);
    try std.testing.expectEqual(@as(u32, 1), Helper.nested_task_preserved.load(.acquire));
    try std.testing.expectEqual(@as(u32, 5), WorkerRuntime.currentWorkerId());
    try std.testing.expectEqual(@as(?*WorkerRuntime.Task, &outer_task), WorkerRuntime.currentTask());
}

test "group.cancel and future.cancel run queued tasks with canceled flag so checkCancel returns error.Canceled" {
    var vtable = std.Io.failing.vtable.*;
    install(&vtable);
    const test_io: std.Io = .{ .userdata = null, .vtable = &vtable };

    const CancelHarness = struct {
        var executed: std.atomic.Value(u32) = .init(0);
        var observed_cancel_error: std.atomic.Value(u32) = .init(0);

        fn onSpawn(task_addr: usize, _: usize, _: usize, _: usize) bool {
            const task: *WorkerRuntime.Task = @ptrFromInt(task_addr);
            WorkerRuntime.enqueueTask(task);
            return true;
        }

        fn cancelableGroupTask(io: std.Io, val: u32) std.Io.Cancelable!void {
            io.checkCancel() catch |err| switch (err) {
                error.Canceled => {
                    _ = observed_cancel_error.fetchAdd(1, .acq_rel);
                    return error.Canceled;
                },
            };
            _ = executed.fetchAdd(val, .acq_rel);
        }

        fn canceledFutureWork(io: std.Io, val: u32) std.Io.Cancelable!u32 {
            try io.checkCancel();
            _ = executed.fetchAdd(val, .acq_rel);
            return val;
        }

        fn selfCancelingTask(io: std.Io) void {
            if (WorkerRuntime.currentTask()) |task| {
                task.canceled.store(1, .release);
            }
            io.checkCancel() catch |err| switch (err) {
                error.Canceled => {
                    _ = observed_cancel_error.fetchAdd(1, .acq_rel);
                    return;
                },
            };
        }
    };

    CancelHarness.executed.store(0, .release);
    CancelHarness.observed_cancel_error.store(0, .release);
    worker_host.spawn_concurrent_hook = &CancelHarness.onSpawn;
    defer {
        worker_host.spawn_concurrent_hook = null;
        WorkerRuntime.setCurrentTask(null);
        WorkerRuntime.setCurrentWorkerId(0);
    }

    var group: std.Io.Group = .init;
    try group.concurrent(test_io, CancelHarness.cancelableGroupTask, .{ test_io, 10 });
    try group.concurrent(test_io, CancelHarness.cancelableGroupTask, .{ test_io, 20 });
    try group.concurrent(test_io, CancelHarness.cancelableGroupTask, .{ test_io, 30 });
    try std.testing.expectEqual(@as(usize, 3), runningCount(&group));
    try std.testing.expectEqual(@as(usize, 3), queuedTasks());

    group.cancel(test_io);
    try std.testing.expectEqual(@as(usize, 0), runningCount(&group));
    try std.testing.expectEqual(@as(usize, 0), queuedTasks());
    try std.testing.expectEqual(@as(u32, 0), CancelHarness.executed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), CancelHarness.observed_cancel_error.load(.acquire));

    var future = try test_io.concurrent(CancelHarness.canceledFutureWork, .{ test_io, 99 });
    try std.testing.expectEqual(@as(usize, 1), queuedTasks());
    try std.testing.expectError(error.Canceled, future.cancel(test_io));
    try std.testing.expectEqual(@as(usize, 0), queuedTasks());
    try std.testing.expectEqual(@as(u32, 0), CancelHarness.executed.load(.acquire));

    // Also verify checkCancel inside a running task when canceled is set
    var active_group: std.Io.Group = .init;
    try active_group.concurrent(test_io, CancelHarness.selfCancelingTask, .{test_io});
    try active_group.await(test_io);
    try std.testing.expectEqual(@as(u32, 4), CancelHarness.observed_cancel_error.load(.acquire));
}
