const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Playground = @import("../Playground.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;

const glyph_task_count: usize = 64;
const glyph_curves_per_task: usize = 32;
const alloc_worker_tasks: usize = 32;
const alloc_ops_per_task: usize = 256;
const alloc_ops_per_batch: usize = alloc_worker_tasks * alloc_ops_per_task;
const stream_chunk_count: u32 = 16;

const section_card: ui.Style = .{
    .width = .grow(),
    .padding = .all(12),
    .direction = .column,
    .gap = 8,
    .background = .muted,
    .radius = .md,
    .border_width = .all(1),
    .border_color = .toned,
};

const action_button: ui.Style = .{
    .width = .fixed(176),
    .height = .fixed(34),
};

const AsyncDispatch = @This();

pending: usize = 0,
wakeups: usize = 0,

glyph_pending: usize = 0,
glyph_batches: usize = 0,
glyph_last_us: u64 = 0,
glyph_last_includes_dispatch: bool = false,
glyph_checksum: u32 = 0,

alloc_pending: usize = 0,
alloc_batches: usize = 0,
alloc_total_ops: usize = 0,
alloc_last_us: u64 = 0,
alloc_last_includes_dispatch: bool = false,
alloc_checksum: u32 = 0,

stream_group: std.Io.Group = .init,
stream_active: bool = false,
stream_target_chunks: u32 = stream_chunk_count,
stream_chunks_done: std.atomic.Value(u32) = .init(0),
stream_checksum: std.atomic.Value(u32) = .init(0),
stream_runs: usize = 0,
frames_rendered: usize = 0,

pub fn tick(self: *AsyncDispatch) bool {
    if (knots.platform.is_wasm and self.stream_active) {
        if (knots.wasm.pollGroup(&self.stream_group)) {
            self.stream_active = false;
            self.stream_runs += 1;
        }
        return true;
    }
    return self.stream_active;
}

pub fn render(self: *AsyncDispatch, app: *knots.App, frame: *ui.Frame) !void {
    @setEvalBranchQuota(4000);
    const arena = frame.arena();

    if (self.stream_active) {
        self.frames_rendered += 1;
    }
    _ = self.tick();
    if (self.stream_active) {
        frame.requestRedraw();
    }

    // 1. Sub-Frame Parallel Glyph/Bezier Batch (Futex Work Queue)
    const glyph_card = Rect{ .key = .src(@src()), .style = &section_card };
    _ = try glyph_card.open(frame);
    try frame.e(Text{
        .content = "1. Sub-Frame Parallel Glyph/Bezier Batch (Futex Work Queue)",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm },
    });
    const glyph_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12, .@"align" = .center } };
    _ = try glyph_row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "glyph batch x64",
        .style = &action_button,
    })).clicked) try self.glyphBatch64(app, frame);
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "batches completed: {d}", .{self.glyph_batches}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = if (self.glyph_pending > 0) .warning else .text },
        },
        Text{
            .content = try std.fmt.allocPrint(
                arena,
                "last batch time (us): {d}{s}",
                .{ self.glyph_last_us, if (self.glyph_last_includes_dispatch) " (incl. dispatch)" else "" },
            ),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .info },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "glyph checksum: 0x{x:0>8}", .{self.glyph_checksum}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try glyph_row.close(frame);
    try frame.e(Text{
        .content = "64 parallel tasks subdivide quadratic Bezier contours and compute Slug glyph band bounds inside a single 60/120 Hz frame budget.",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true },
    });
    try glyph_card.close(frame);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });

    // 2. Concurrent Multi-Worker Heap Allocation (Sharded Slab Allocator)
    const alloc_card = Rect{ .key = .src(@src()), .style = &section_card };
    _ = try alloc_card.open(frame);
    try frame.e(Text{
        .content = "2. Concurrent Multi-Worker Heap Allocation (Sharded Slab Allocator)",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm },
    });
    const alloc_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12, .@"align" = .center } };
    _ = try alloc_row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "sharded alloc x32",
        .style = &action_button,
    })).clicked) try self.shardedAlloc32(app, frame);
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "alloc batches: {d}", .{self.alloc_batches}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = if (self.alloc_pending > 0) .warning else .text },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "total alloc+free ops: {d} (8,192 ops/batch)", .{self.alloc_total_ops}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .text },
        },
        Text{
            .content = try std.fmt.allocPrint(
                arena,
                "last alloc time (us): {d}{s}",
                .{ self.alloc_last_us, if (self.alloc_last_includes_dispatch) " (incl. dispatch)" else "" },
            ),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .info },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "alloc checksum: 0x{x:0>8}", .{self.alloc_checksum}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try alloc_row.close(frame);
    try frame.e(Text{
        .content = "32 concurrent worker tasks each run 256 small/medium allocations (16 B..4096 B), in-place same-class resize/remap, and frees on per-worker shards.",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true },
    });
    try alloc_card.close(frame);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });

    // 3. Jank-Free Non-Blocking Frame Polling (pollGroup during requestAnimationFrame)
    const stream_card = Rect{ .key = .src(@src()), .style = &section_card };
    _ = try stream_card.open(frame);
    try frame.e(Text{
        .content = "3. Jank-Free Non-Blocking Frame Polling (pollGroup during requestAnimationFrame)",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm },
    });
    const stream_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12, .@"align" = .center } };
    _ = try stream_row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "stream mesh (pollGroup)",
        .disabled = self.stream_active,
        .style = &action_button,
    })).clicked) try self.startStreamMesh(app, frame);
    const chunks_done = self.stream_chunks_done.load(.acquire);
    const mesh_checksum = self.stream_checksum.load(.acquire);
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "chunks: {d}/{d}", .{ chunks_done, self.stream_target_chunks }),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = if (self.stream_active) .warning else .success },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "frames rendered while streaming: {d}", .{self.frames_rendered}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .info },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "streams completed: {d}", .{self.stream_runs}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .text },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "mesh checksum: 0x{x:0>8}", .{mesh_checksum}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try stream_row.close(frame);
    try frame.e(Text{
        .content = "16 background mesh chunks stream concurrently via a non-blocking pollGroup check in rAF without blocking 60-120 Hz redraws.",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true },
    });
    try stream_card.close(frame);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });

    // 4. Async Sleep & Wakeup Queue (app.dispatch)
    const sleep_card = Rect{ .key = .src(@src()), .style = &section_card };
    _ = try sleep_card.open(frame);
    try frame.e(Text{
        .content = "4. Background Timer Wakeups (app.dispatch)",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm },
    });
    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12, .@"align" = .center } };
    _ = try row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "sleep x10",
        .style = &action_button,
    })).clicked) try self.sleep10(app, frame);
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "pending: {d}", .{self.pending}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = if (self.pending > 0) .warning else .dimmed },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "wakeups received: {d}", .{self.wakeups}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try row.close(frame);
    try frame.e(Text{
        .content = "each task sleeps 0..10 seconds. Wakeups land back on the main loop without blocking the UI.",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true },
    });
    try sleep_card.close(frame);
}

const GlyphBatchResult = struct {
    checksum: u32,
    worker_elapsed_ns: i96,
    dispatch_start: std.Io.Timestamp,
};

fn glyphBatch64(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    const start_ts = std.Io.Clock.awake.now(app.io);
    const seed: u32 = @truncate(self.glyph_batches +% 1);
    app.dispatch(
        app.main_viewport.id,
        runGlyphBatch,
        .{ app.io, seed, start_ts },
        onGlyphBatchComplete,
    ) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            std.log.warn("async dispatch is unavailable because this build has no thread support", .{});
            if (self.glyph_pending > 0) frame.requestRedraw();
            return;
        },
        else => return err,
    };
    self.glyph_pending += 1;
    frame.requestRedraw();
}

fn runGlyphBatch(io: std.Io, seed: u32, dispatch_start: std.Io.Timestamp) GlyphBatchResult {
    const t0 = std.Io.Clock.awake.now(io);
    var group: std.Io.Group = .init;
    var checksum: std.atomic.Value(u32) = .init(0);

    for (0..glyph_task_count) |task_idx| {
        const idx: u32 = @intCast(task_idx);
        group.concurrent(io, evalGlyphTask, .{ idx, seed, &checksum }) catch {
            evalGlyphTask(idx, seed, &checksum);
        };
    }
    group.await(io) catch {};
    const t1 = std.Io.Clock.awake.now(io);
    return .{
        .checksum = checksum.load(.acquire),
        .worker_elapsed_ns = t0.durationTo(t1).nanoseconds,
        .dispatch_start = dispatch_start,
    };
}

fn evalGlyphTask(task_idx: u32, seed: u32, out_checksum: *std.atomic.Value(u32)) void {
    var acc: u32 = (task_idx +% 1) *% 0x9e3779b9 ^ seed;
    for (0..glyph_curves_per_task) |curve_idx| {
        const c: u32 = @intCast(curve_idx);
        const base = @as(f32, @floatFromInt((task_idx * 37 + c * 13) & 0xff)) * 0.25;
        const p0 = [2]f32{ base, base * 0.5 + 1.0 };
        const p1 = [2]f32{ base + 12.5, base * 1.25 - 3.0 };
        const p2 = [2]f32{ base + 24.0, base * 0.75 + 6.0 };

        // Subdivide quadratic Bezier curve into 8 monotonic band segments and accumulate bounds
        var min_x = @min(p0[0], p2[0]);
        var max_x = @max(p0[0], p2[0]);
        var min_y = @min(p0[1], p2[1]);
        var max_y = @max(p0[1], p2[1]);
        var arc_accum: f32 = 0.0;
        var prev = p0;

        for (1..9) |step| {
            const t = @as(f32, @floatFromInt(step)) * 0.125;
            const omt = 1.0 - t;
            const qx = omt * omt * p0[0] + 2.0 * omt * t * p1[0] + t * t * p2[0];
            const qy = omt * omt * p0[1] + 2.0 * omt * t * p1[1] + t * t * p2[1];
            min_x = @min(min_x, qx);
            max_x = @max(max_x, qx);
            min_y = @min(min_y, qy);
            max_y = @max(max_y, qy);
            const dx = qx - prev[0];
            const dy = qy - prev[1];
            arc_accum += @sqrt(dx * dx + dy * dy);
            prev = .{ qx, qy };
        }

        const band_span = (max_x - min_x) * 16.0 + (max_y - min_y) * 16.0 + arc_accum;
        const quantized: u32 = @intFromFloat(@max(0.0, band_span * 64.0));
        acc = std.math.rotl(u32, acc ^ quantized, 7) *% 0x85ebca6b;
    }
    _ = out_checksum.fetchAdd(acc, .monotonic);
}

fn onGlyphBatchComplete(view: *knots.View, frame: *ui.Frame, result: GlyphBatchResult) !void {
    const self = &Playground.of(view.app).demos.async_dispatch;
    if (self.glyph_pending > 0) self.glyph_pending -= 1;
    self.glyph_batches += 1;
    self.glyph_checksum = result.checksum;

    const has_worker_time = result.worker_elapsed_ns > 0;
    self.glyph_last_includes_dispatch = !has_worker_time;
    const elapsed_ns = if (has_worker_time)
        result.worker_elapsed_ns
    else
        result.dispatch_start.durationTo(std.Io.Clock.awake.now(view.app.io)).nanoseconds;
    self.glyph_last_us = @intCast(@max(1, @divTrunc(elapsed_ns, std.time.ns_per_us)));
    frame.requestRedraw();
}

const AllocBatchResult = struct {
    checksum: u32,
    worker_elapsed_ns: i96,
    dispatch_start: std.Io.Timestamp,
};

fn shardedAlloc32(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    const start_ts = std.Io.Clock.awake.now(app.io);
    const seed: u32 = @truncate(self.alloc_batches +% 1);
    app.dispatch(
        app.main_viewport.id,
        runShardedAllocBatch,
        .{ app.io, app.allocator, seed, start_ts },
        onShardedAllocComplete,
    ) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            std.log.warn("async dispatch is unavailable because this build has no thread support", .{});
            if (self.alloc_pending > 0) frame.requestRedraw();
            return;
        },
        else => return err,
    };
    self.alloc_pending += 1;
    frame.requestRedraw();
}

fn runShardedAllocBatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    seed: u32,
    dispatch_start: std.Io.Timestamp,
) AllocBatchResult {
    const t0 = std.Io.Clock.awake.now(io);
    var group: std.Io.Group = .init;
    var checksum: std.atomic.Value(u32) = .init(0);

    for (0..alloc_worker_tasks) |task_idx| {
        const idx: u32 = @intCast(task_idx);
        group.concurrent(io, evalShardedAllocTask, .{ allocator, idx, seed, &checksum }) catch {
            evalShardedAllocTask(allocator, idx, seed, &checksum);
        };
    }
    group.await(io) catch {};
    const t1 = std.Io.Clock.awake.now(io);
    return .{
        .checksum = checksum.load(.acquire),
        .worker_elapsed_ns = t0.durationTo(t1).nanoseconds,
        .dispatch_start = dispatch_start,
    };
}

fn evalShardedAllocTask(
    allocator: std.mem.Allocator,
    task_idx: u32,
    seed: u32,
    out_checksum: *std.atomic.Value(u32),
) void {
    // 9 slab size classes spanning 16 B..4096 B, paired with same-class target sizes
    const initial_sizes = [_]usize{ 12, 24, 48, 96, 192, 384, 768, 1536, 3072 };
    const same_class_sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };

    var live_ring: [8]?[]u8 = @splat(null);
    defer for (&live_ring) |*slot| {
        if (slot.*) |buf| allocator.free(buf);
    };

    var acc: u32 = (task_idx +% 1) *% 0xc2b2ae35 ^ seed;
    for (0..alloc_ops_per_task) |op_idx| {
        const ring_idx = op_idx & (live_ring.len - 1);
        if (live_ring[ring_idx]) |old_buf| {
            acc = std.math.rotl(u32, acc +% old_buf[0] +% old_buf[old_buf.len - 1], 5);
            allocator.free(old_buf);
            live_ring[ring_idx] = null;
        }

        const class_sel = (op_idx + task_idx) % initial_sizes.len;
        const req_len = initial_sizes[class_sel];
        const grown_len = same_class_sizes[class_sel];

        var buf = allocator.alloc(u8, req_len) catch continue;
        const tag: u8 = @truncate(task_idx +% @as(u32, @intCast(op_idx)) +% seed);
        buf[0] = tag;
        buf[buf.len - 1] = tag ^ 0x5a;

        // Exercise in-place same-class resize and remap on ShardedAllocator
        if ((op_idx & 1) == 0) {
            if (allocator.resize(buf, grown_len)) {
                buf = buf.ptr[0..grown_len];
                buf[buf.len - 1] = tag ^ 0xa5;
            }
        } else if (allocator.remap(buf, grown_len)) |remapped| {
            buf = remapped;
            buf[buf.len - 1] = tag ^ 0x3c;
        }

        live_ring[ring_idx] = buf;
    }

    for (&live_ring) |*slot| {
        if (slot.*) |buf| {
            acc = std.math.rotl(u32, acc +% buf[0] +% buf[buf.len - 1], 5);
            allocator.free(buf);
            slot.* = null;
        }
    }

    _ = out_checksum.fetchAdd(acc, .monotonic);
}

fn onShardedAllocComplete(view: *knots.View, frame: *ui.Frame, result: AllocBatchResult) !void {
    const self = &Playground.of(view.app).demos.async_dispatch;
    if (self.alloc_pending > 0) self.alloc_pending -= 1;
    self.alloc_batches += 1;
    self.alloc_total_ops += alloc_ops_per_batch;
    self.alloc_checksum = result.checksum;

    const has_worker_time = result.worker_elapsed_ns > 0;
    self.alloc_last_includes_dispatch = !has_worker_time;
    const elapsed_ns = if (has_worker_time)
        result.worker_elapsed_ns
    else
        result.dispatch_start.durationTo(std.Io.Clock.awake.now(view.app.io)).nanoseconds;
    self.alloc_last_us = @intCast(@max(1, @divTrunc(elapsed_ns, std.time.ns_per_us)));
    frame.requestRedraw();
}

fn startStreamMesh(self: *AsyncDispatch, app: *knots.App, frame: *ui.Frame) !void {
    if (self.stream_active) return;

    self.stream_chunks_done.store(0, .release);
    self.stream_checksum.store(0, .release);
    self.stream_target_chunks = stream_chunk_count;
    self.frames_rendered = 0;
    self.stream_active = true;
    const seed: u32 = @truncate(self.stream_runs +% 1);

    if (comptime knots.platform.is_wasm) {
        var spawned: u32 = 0;
        for (0..stream_chunk_count) |chunk_idx| {
            const idx: u32 = @intCast(chunk_idx);
            self.stream_group.concurrent(
                app.io,
                generateMeshChunk,
                .{ app.io, idx, seed, &self.stream_chunks_done, &self.stream_checksum },
            ) catch |err| switch (err) {
                error.ConcurrencyUnavailable => break,
            };
            spawned += 1;
        }
        if (spawned == 0) {
            self.stream_active = false;
            std.log.warn("stream mesh pollGroup is unavailable because this build has no thread support", .{});
            return;
        }
        self.stream_target_chunks = spawned;
    } else {
        app.dispatch(
            app.main_viewport.id,
            runNativeStreamGroup,
            .{ app.io, seed, &self.stream_chunks_done, &self.stream_checksum },
            onNativeStreamComplete,
        ) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                self.stream_active = false;
                std.log.warn("async dispatch is unavailable because this build has no thread support", .{});
                return;
            },
            else => {
                self.stream_active = false;
                return err;
            },
        };
    }

    frame.requestRedraw();
}

fn runNativeStreamGroup(
    io: std.Io,
    seed: u32,
    chunks_done: *std.atomic.Value(u32),
    checksum: *std.atomic.Value(u32),
) void {
    var group: std.Io.Group = .init;
    for (0..stream_chunk_count) |chunk_idx| {
        const idx: u32 = @intCast(chunk_idx);
        group.concurrent(
            io,
            generateMeshChunk,
            .{ io, idx, seed, chunks_done, checksum },
        ) catch {
            generateMeshChunk(io, idx, seed, chunks_done, checksum);
        };
    }
    group.await(io) catch {};
}

fn onNativeStreamComplete(view: *knots.View, frame: *ui.Frame, _: void) !void {
    const self = &Playground.of(view.app).demos.async_dispatch;
    self.stream_active = false;
    self.stream_runs += 1;
    frame.requestRedraw();
}

fn generateMeshChunk(
    io: std.Io,
    chunk_idx: u32,
    seed: u32,
    chunks_done: *std.atomic.Value(u32),
    checksum: *std.atomic.Value(u32),
) void {
    var chunk_hash: u32 = (chunk_idx +% 1) *% 0x27d4eb2d ^ seed;
    for (0..512) |vertex_idx| {
        const v: u32 = @intCast(vertex_idx);
        const u_angle = @as(f32, @floatFromInt((chunk_idx * 32 + (v & 31)) & 0xff)) * 0.02454369;
        const v_angle = @as(f32, @floatFromInt((v >> 4) & 0x1f)) * 0.19634954;
        const radius = 2.0 + 0.65 * @cos(3.0 * u_angle);
        const px = radius * @cos(2.0 * u_angle) + 0.25 * @cos(v_angle);
        const py = radius * @sin(2.0 * u_angle) + 0.25 * @sin(v_angle);
        const pz = 0.65 * @sin(3.0 * u_angle);
        const metric = @sqrt(px * px + py * py + pz * pz) * 1024.0;
        const q: u32 = @intFromFloat(@max(0.0, metric));
        chunk_hash = std.math.rotl(u32, chunk_hash ^ q, 9) *% 0x165667b1;
    }

    const delay_ms: i64 = 15 + @as(i64, @intCast(chunk_idx % 6)) * 12;
    std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};

    _ = checksum.fetchAdd(chunk_hash, .acq_rel);
    _ = chunks_done.fetchAdd(1, .acq_rel);
}

fn sleep10(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    for (1..11) |i| {
        app.dispatch(
            app.main_viewport.id,
            doSleep,
            .{ app.io, @as(i64, @intCast(i)) },
            onWakeup,
        ) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                std.log.warn("async dispatch is unavailable because this build has no thread support", .{});
                if (self.pending > 0) frame.requestRedraw();
                return;
            },
            else => return err,
        };
        self.pending += 1;
    }
    frame.requestRedraw();
}

fn doSleep(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

fn onWakeup(view: *knots.View, frame: *ui.Frame, _: std.Io.Cancelable!void) !void {
    const self = &Playground.of(view.app).demos.async_dispatch;
    self.wakeups += 1;
    if (self.pending > 0) self.pending -= 1;
    frame.requestRedraw();
}
