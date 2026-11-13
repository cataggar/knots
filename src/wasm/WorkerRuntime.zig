const std = @import("std");
const worker_host = @import("worker_host");
pub const ShardedAllocator = @import("ShardedAllocator.zig");

const Allocator = std.mem.Allocator;
pub const SpinLock = ShardedAllocator.SpinLock;

const stack_size = 1024 * 1024;
const worker_id_mask: usize = 0x3f;
pub const queue_capacity: usize = 256;

pub fn allocator() Allocator {
    return ShardedAllocator.allocator(&currentWorkerId);
}

pub fn currentWorkerId() u32 {
    return @intCast(worker_host.currentTask() & worker_id_mask);
}

pub fn setCurrentWorkerId(worker_id: u32) void {
    const raw = worker_host.currentTask();
    const task_bits = raw & ~worker_id_mask;
    worker_host.setCurrentTask(task_bits | (@as(usize, worker_id) & worker_id_mask));
}

pub fn currentTask() ?*Task {
    const raw = worker_host.currentTask() & ~worker_id_mask;
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

pub fn setCurrentTask(task: ?*Task) void {
    const id_bits = worker_host.currentTask() & worker_id_mask;
    const task_bits = if (task) |ptr| @intFromPtr(ptr) else 0;
    std.debug.assert((task_bits & worker_id_mask) == 0);
    worker_host.setCurrentTask(task_bits | id_bits);
}

pub const State = struct {
    lock: SpinLock = .{},
    running: std.atomic.Value(usize) = .init(0),
    canceled: std.atomic.Value(u32) = .init(0),
    tasks: ?*Task = null,
};

pub const Task = struct {
    queue_next: ?*Task align(64) = null,
    state: *State,
    prev: ?*Task = null,
    next: ?*Task = null,
    start: ?*const fn (*const anyopaque) void = null,
    context: []u8 = &.{},
    context_alignment: std.mem.Alignment = .@"1",
    canceled: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    detached: std.atomic.Value(u32) = .init(0),
    cancel_protection: std.atomic.Value(u32) = .init(@backingInt(std.Io.CancelProtection.unblocked)),
    waiting_on: std.atomic.Value(usize) = .init(0),
};

var queue_lock: SpinLock = .{};
var ring_tasks: [queue_capacity]?*Task = @splat(null);
var ring_head: usize = 0;
var ring_count: usize = 0;
var overflow_head: ?*Task = null;
var overflow_tail: ?*Task = null;

var work_seq: std.atomic.Value(u32) = .init(0);
var queued_count: std.atomic.Value(usize) = .init(0);
var parked_workers: std.atomic.Value(u32) = .init(0);
var ready_workers: std.atomic.Value(u32) = .init(0);
var ready_worker_masks: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) };
var configured_max_workers: std.atomic.Value(u32) = .init(0);
var pool_at_capacity: std.atomic.Value(u32) = .init(0);
var shutdown_requested: std.atomic.Value(u32) = .init(0);
var completion_seq: std.atomic.Value(u32) = .init(0);
var last_polled_seq: std.atomic.Value(u32) = .init(0);
var notify_pending: std.atomic.Value(u32) = .init(0);

pub fn setMaxWorkers(max_workers: u32) void {
    configured_max_workers.store(max_workers, .release);
    pool_at_capacity.store(0, .release);
    shutdown_requested.store(0, .release);
}

pub fn enqueueTask(task: *Task) void {
    task.queue_next = null;
    {
        queue_lock.lock();
        defer queue_lock.unlock();
        if (ring_count < queue_capacity) {
            const tail = (ring_head + ring_count) % queue_capacity;
            ring_tasks[tail] = task;
            ring_count += 1;
        } else {
            if (overflow_tail) |tail| {
                tail.queue_next = task;
            } else {
                overflow_head = task;
            }
            overflow_tail = task;
        }
        _ = queued_count.fetchAdd(1, .release);
        _ = work_seq.fetchAdd(1, .acq_rel);
    }
    if (parked_workers.load(.acquire) > 0) {
        worker_host.atomicNotify(@ptrCast(&work_seq.raw), 1);
    }
}

pub fn tryPopTask() ?*Task {
    if (queued_count.load(.acquire) == 0) return null;
    queue_lock.lock();
    defer queue_lock.unlock();
    if (ring_count == 0) return null;
    const task = ring_tasks[ring_head].?;
    ring_tasks[ring_head] = null;
    ring_head = (ring_head + 1) % queue_capacity;
    ring_count -= 1;
    if (overflow_head) |overflow| {
        const next_overflow = overflow.queue_next;
        overflow.queue_next = null;
        overflow_head = next_overflow;
        if (next_overflow == null) {
            overflow_tail = null;
        }
        const tail = (ring_head + ring_count) % queue_capacity;
        ring_tasks[tail] = overflow;
        ring_count += 1;
    }
    _ = queued_count.fetchSub(1, .release);
    return task;
}

pub fn enqueueForTesting(task: *Task) void {
    enqueueTask(task);
}

pub fn tryPopForTesting() ?*Task {
    return tryPopTask();
}

fn linkTask(state: *State, task: *Task) void {
    state.lock.lock();
    defer state.lock.unlock();
    task.prev = null;
    task.next = state.tasks;
    if (state.tasks) |head| head.prev = task;
    state.tasks = task;
    if (state.canceled.load(.acquire) != 0) {
        task.canceled.store(1, .release);
    }
}

fn unlinkTask(state: *State, task: *Task) bool {
    state.lock.lock();
    defer state.lock.unlock();
    if (task.detached.swap(1, .acq_rel) != 0) return false;
    if (task.prev) |prev| {
        prev.next = task.next;
    } else if (state.tasks == task) {
        state.tasks = task.next;
    }
    if (task.next) |next| {
        next.prev = task.prev;
    }
    task.prev = null;
    task.next = null;
    return true;
}

fn requestCancelAll(state: *State) void {
    state.canceled.store(1, .release);
    state.lock.lock();
    defer state.lock.unlock();
    var task = state.tasks;
    while (task) |current| : (task = current.next) {
        current.canceled.store(1, .release);
        atomicNotify(&current.canceled.raw, 1);
        const wait_address = current.waiting_on.load(.acquire);
        if (wait_address != 0) atomicNotify(@ptrFromInt(wait_address), 1);
    }
}

fn createTask(
    state: *State,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (*const anyopaque) void,
) std.Io.ConcurrentError!*Task {
    const alloc = allocator();
    const task_slice = alloc.alignedAlloc(Task, .fromByteUnits(64), 1) catch
        return error.ConcurrencyUnavailable;
    const task = &task_slice[0];
    errdefer alloc.free(task_slice);

    const alignment = context_alignment.max(.of(u128));
    const context_copy: []u8 = if (context.len == 0)
        &.{}
    else blk: {
        const context_ptr = alloc.rawAlloc(context.len, alignment, @returnAddress()) orelse
            return error.ConcurrencyUnavailable;
        const slice = context_ptr[0..context.len];
        @memcpy(slice, context);
        break :blk slice;
    };

    task.* = .{
        .state = state,
        .start = start,
        .context = context_copy,
        .context_alignment = alignment,
    };
    return task;
}

fn completeAndDestroyTask(task: *Task) void {
    const state = task.state;
    const was_unfinished = task.finished.swap(1, .acq_rel) == 0;
    if (unlinkTask(state, task)) {
        destroyTask(task);
    }
    if (was_unfinished) {
        const prev_running = state.running.fetchSub(1, .acq_rel);
        _ = completion_seq.fetchAdd(1, .acq_rel);
        if (prev_running == 1) {
            worker_host.atomicNotify(@ptrCast(&completion_seq.raw), std.math.maxInt(u32));
        }
        if (currentWorkerId() != 0 and notify_pending.swap(1, .acq_rel) == 0) {
            worker_host.notifyComplete();
        }
    }
}

fn executeQueuedTask(task: *Task) void {
    if (task.start) |start_fn| {
        run(@intFromPtr(start_fn), @intFromPtr(task.context.ptr), task);
    }
    completeAndDestroyTask(task);
}

pub fn workerLoop(worker_id: u32) void {
    const masked_id: u32 = @intCast(@as(usize, worker_id) & worker_id_mask);
    const effective_id: u32 = if (masked_id == 0) 1 else masked_id;
    setCurrentWorkerId(effective_id);
    setCurrentTask(null);

    const mask_idx: usize = @intCast((effective_id >> 5) & 1);
    const worker_bit: u32 = @as(u32, 1) << @intCast(effective_id & 31);
    if ((ready_worker_masks[mask_idx].fetchOr(worker_bit, .acq_rel) & worker_bit) == 0) {
        _ = ready_workers.fetchAdd(1, .acq_rel);
    }
    defer {
        pool_at_capacity.store(0, .release);
        if ((ready_worker_masks[mask_idx].fetchAnd(~worker_bit, .acq_rel) & worker_bit) != 0) {
            _ = ready_workers.fetchSub(1, .acq_rel);
        }
    }

    while (shutdown_requested.load(.acquire) == 0) {
        while (tryPopTask()) |task| {
            executeQueuedTask(task);
            if (shutdown_requested.load(.acquire) != 0) return;
        }

        const seq = work_seq.load(.acquire);
        if (queued_count.load(.acquire) != 0 or shutdown_requested.load(.acquire) != 0) continue;

        {
            _ = parked_workers.fetchAdd(1, .acq_rel);
            defer _ = parked_workers.fetchSub(1, .acq_rel);
            if (queued_count.load(.acquire) == 0 and shutdown_requested.load(.acquire) == 0) {
                _ = worker_host.atomicWait(@ptrCast(&work_seq.raw), @bitCast(seq), -1);
            }
        }
    }
}

pub fn requestShutdown() void {
    shutdown_requested.store(1, .release);
    _ = work_seq.fetchAdd(1, .acq_rel);
    worker_host.atomicNotify(@ptrCast(&work_seq.raw), std.math.maxInt(u32));
}

pub fn wakeAllWorkers() void {
    requestShutdown();
}

pub fn resetShutdown() void {
    shutdown_requested.store(0, .release);
    pool_at_capacity.store(0, .release);
    configured_max_workers.store(0, .release);
}

pub fn ackComplete() void {
    notify_pending.store(0, .release);
}

pub fn poll(max_tasks: usize) usize {
    notify_pending.store(0, .release);
    var ran: usize = 0;
    while (ran < max_tasks) : (ran += 1) {
        const task = tryPopTask() orelse break;
        executeQueuedTask(task);
    }
    const cur = completion_seq.load(.acquire);
    const prev = last_polled_seq.swap(cur, .acq_rel);
    return @as(usize, cur -% prev);
}

pub fn pollGroup(group: *std.Io.Group) bool {
    const state = stateFromGroup(group) orelse return true;
    if (state.running.load(.acquire) != 0) return false;
    destroyState(group, state);
    return true;
}

pub fn runningCount(group: *const std.Io.Group) usize {
    const state = stateFromGroup(group) orelse return 0;
    return state.running.load(.acquire);
}

pub fn queuedTasks() usize {
    return queued_count.load(.acquire);
}

pub fn activeWorkers() u32 {
    return ready_workers.load(.acquire);
}

pub fn concurrent(
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (*const anyopaque) void,
) std.Io.ConcurrentError!void {
    const state = stateFor(group) catch return error.ConcurrencyUnavailable;
    const task = try createTask(state, context, context_alignment, start);

    _ = state.running.fetchAdd(1, .acq_rel);
    linkTask(state, task);

    const task_addr = @intFromPtr(task);
    const state_addr = @intFromPtr(state);
    const start_addr = @intFromPtr(start);
    const context_addr = @intFromPtr(task.context.ptr);

    const max_w = configured_max_workers.load(.acquire);
    const ready_w = ready_workers.load(.acquire);
    if (worker_host.spawn_concurrent_hook == null and (ready_w > 0 or max_w > 0)) {
        enqueueTask(task);
        if (currentWorkerId() == 0 and
            pool_at_capacity.load(.acquire) == 0 and
            (ready_w == 0 or (max_w > ready_w and queued_count.load(.acquire) > parked_workers.load(.acquire))))
        {
            if (!worker_host.spawnConcurrent(task_addr, state_addr, start_addr, context_addr)) {
                pool_at_capacity.store(1, .release);
            }
        }
        return;
    }

    if (!worker_host.spawnConcurrent(task_addr, state_addr, start_addr, context_addr)) {
        if (unlinkTask(state, task)) destroyTask(task);
        _ = state.running.fetchSub(1, .acq_rel);
        return error.ConcurrencyUnavailable;
    }
}

fn stateFromGroup(group: *const std.Io.Group) ?*State {
    const token = group.token.load(.acquire) orelse return null;
    return @ptrCast(@alignCast(token));
}

fn stateFor(group: *std.Io.Group) Allocator.Error!*State {
    if (group.token.load(.acquire)) |token| return @ptrCast(@alignCast(token));
    const state = try allocator().create(State);
    state.* = .{};
    if (group.token.cmpxchgStrong(null, state, .acq_rel, .acquire)) |existing| {
        allocator().destroy(state);
        return @ptrCast(@alignCast(existing.?));
    }
    return state;
}

pub fn await(group: *std.Io.Group, token: *anyopaque) std.Io.Cancelable!void {
    const state: *State = @ptrCast(@alignCast(token));
    waitForTasks(state);
    destroyState(group, state);
}

pub fn cancel(group: *std.Io.Group, token: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(token));
    requestCancelAll(state);
    waitForTasks(state);
    destroyState(group, state);
}

fn waitForTasks(state: *State) void {
    while (true) {
        if (state.running.load(.acquire) == 0) break;
        if (currentWorkerId() != 0 or ready_workers.load(.acquire) == 0) {
            if (tryPopTask()) |task| {
                executeQueuedTask(task);
                continue;
            }
        }
        const seq = completion_seq.load(.acquire);
        if (state.running.load(.acquire) == 0) break;
        if (currentWorkerId() == 0) {
            if (worker_host.canSuspendJspi() and worker_host.hasWaitAsync()) {
                _ = worker_host.waitAsync32(@ptrCast(&completion_seq.raw), seq, 1_000_000);
                continue;
            }
            std.atomic.spinLoopHint();
        } else {
            _ = worker_host.atomicWait(@ptrCast(&completion_seq.raw), seq, 1_000_000);
        }
    }
}

fn destroyState(group: *std.Io.Group, state: *State) void {
    if (worker_host.spawn_concurrent_hook != null or
        (ready_workers.load(.acquire) == 0 and configured_max_workers.load(.acquire) == 0))
    {
        worker_host.forgetConcurrentGroup(@intFromPtr(state));
    }

    while (true) {
        state.lock.lock();
        const current = state.tasks orelse {
            state.lock.unlock();
            break;
        };
        state.tasks = current.next;
        if (state.tasks) |next| next.prev = null;
        current.prev = null;
        current.next = null;
        const should_destroy = current.detached.swap(1, .acq_rel) == 0;
        state.lock.unlock();
        if (should_destroy) {
            destroyTask(current);
        }
    }
    allocator().destroy(state);
    group.token.store(null, .release);
}

fn destroyTask(task: *Task) void {
    const alloc = allocator();
    if (task.context.len > 0) {
        alloc.rawFree(task.context, task.context_alignment, @returnAddress());
    }
    const task_slice: []align(64) Task = @as([*]align(64) Task, @ptrCast(@alignCast(task)))[0..1];
    alloc.free(task_slice);
}

pub fn allocateStack() usize {
    const stack = allocator().alignedAlloc(u8, .of(u128), stack_size) catch return 0;
    return @intFromPtr(stack.ptr + stack.len);
}

pub fn freeStack(stack_top: usize) void {
    if (stack_top == 0) return;
    const stack: [*]align(16) u8 = @ptrFromInt(stack_top - stack_size);
    const memory: []align(16) u8 = stack[0..stack_size];
    allocator().free(memory);
}

pub fn release(task: *Task) void {
    const state = task.state;
    if (unlinkTask(state, task)) {
        destroyTask(task);
    }
}

pub fn run(start_address: usize, context_address: usize, task: *Task) void {
    const prev_task = currentTask();
    setCurrentTask(task);
    defer setCurrentTask(prev_task);

    const start: *const fn (*const anyopaque) void =
        @ptrFromInt(start_address);
    const context: *const anyopaque =
        @ptrFromInt(context_address);

    start(context);
}

pub fn complete(task: *Task) void {
    const state = task.state;
    if (task.finished.swap(1, .acq_rel) == 0) {
        const prev_running = state.running.fetchSub(1, .acq_rel);
        _ = completion_seq.fetchAdd(1, .acq_rel);
        if (prev_running == 1) {
            atomicNotify(@ptrCast(&completion_seq.raw), std.math.maxInt(u32));
        }
    }
}

pub fn abort(task: *Task) void {
    if (currentTask() == task) {
        setCurrentTask(null);
    }
    const state = task.state;
    state.canceled.store(1, .release);
    const was_unfinished = task.finished.swap(1, .acq_rel) == 0;
    if (unlinkTask(state, task)) {
        destroyTask(task);
    }
    if (was_unfinished) {
        const prev_running = state.running.fetchSub(1, .acq_rel);
        _ = completion_seq.fetchAdd(1, .acq_rel);
        if (prev_running == 1) {
            atomicNotify(@ptrCast(&completion_seq.raw), std.math.maxInt(u32));
        }
        if (currentWorkerId() != 0 and notify_pending.swap(1, .acq_rel) == 0) {
            worker_host.notifyComplete();
        }
    }
}

pub fn isCanceled() bool {
    const task = currentTask() orelse return false;
    if (task.cancel_protection.load(.acquire) != @backingInt(std.Io.CancelProtection.unblocked)) return false;
    return task.canceled.swap(0, .acq_rel) != 0;
}

pub fn recancel() void {
    const task = currentTask() orelse return;
    task.canceled.store(1, .release);
}

pub fn swapCancelProtection(new: std.Io.CancelProtection) std.Io.CancelProtection {
    const task = currentTask() orelse return .unblocked;
    return @fromBackingInt(@intCast(task.cancel_protection.swap(@backingInt(new), .acq_rel)));
}

pub fn cancelAddress() ?*const u32 {
    const task = currentTask() orelse return null;
    return &task.canceled.raw;
}

pub fn beginWait(ptr: *const u32) void {
    const task = currentTask() orelse return;
    task.waiting_on.store(@intFromPtr(ptr), .release);
}

pub fn endWait() void {
    const task = currentTask() orelse return;
    task.waiting_on.store(0, .release);
}

/// Returns 0 when woken, 1 if `ptr` did not hold `expected`, 2 on timeout.
pub fn atomicWait(ptr: *const u32, expected: u32, timeout_ns: i64) u32 {
    if (currentWorkerId() == 0) {
        if (@atomicLoad(u32, ptr, .acquire) != expected) return 1;
        if (timeout_ns == 0) return 2;
        if (worker_host.canSuspendJspi() and worker_host.hasWaitAsync()) {
            const timeout_opt: ?u64 = if (timeout_ns < 0) null else @intCast(timeout_ns);
            return worker_host.waitAsync32(ptr, expected, timeout_opt);
        }
        const deadline_ns: ?i96 = if (timeout_ns > 0) blk: {
            const start_ns = worker_host.now(null, .awake).nanoseconds;
            break :blk if (start_ns > 0) start_ns + @as(i96, timeout_ns) else null;
        } else null;
        while (@atomicLoad(u32, ptr, .acquire) == expected) {
            if (deadline_ns) |deadline| {
                const current_ns = worker_host.now(null, .awake).nanoseconds;
                if (current_ns > 0 and current_ns >= deadline) return 2;
            }
            std.atomic.spinLoopHint();
        }
        return 0;
    }
    return worker_host.atomicWait(ptr, expected, timeout_ns);
}

pub fn atomicNotify(ptr: *const u32, max_waiters: u32) void {
    worker_host.atomicNotify(ptr, max_waiters);
}
