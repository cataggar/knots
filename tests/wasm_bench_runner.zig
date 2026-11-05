const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const layout = @import("layout");
const style = @import("style");
const text = @import("text");
const render = @import("render");
const render_types = @import("render_types");
const math = @import("math");
const input = @import("input");
const ui = @import("ui");
const TrueType = @import("TrueType");

const Element = layout.Element;

const Stats = struct {
    iterations: usize,
    warmup_iterations: usize,
    elements_per_iter: usize,
    total_ms: f64,
    mean_ms: f64,
    median_ms: f64,
    p95_ms: f64,
    min_ms: f64,
    max_ms: f64,
    ops_per_sec: f64,
    checksum: u64,
};

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn computeStats(allocator: std.mem.Allocator, samples_ns: []const u64, warmup: usize, elements_per_iter: usize, checksum: u64) !Stats {
    const n = samples_ns.len;
    std.debug.assert(n > 0);

    const sorted = try allocator.dupe(u64, samples_ns);
    defer allocator.free(sorted);
    std.mem.sortUnstable(u64, sorted, {}, std.sort.asc(u64));

    var sum_ns: u128 = 0;
    for (sorted) |s| sum_ns += s;

    const ns_to_ms = 1e-6;
    const total_ms = @as(f64, @floatFromInt(sum_ns)) * ns_to_ms;
    const mean_ms = total_ms / @as(f64, @floatFromInt(n));
    const median_ns = if (n % 2 == 1)
        @as(f64, @floatFromInt(sorted[n / 2]))
    else
        @as(f64, @floatFromInt(sorted[n / 2 - 1] + sorted[n / 2])) * 0.5;
    const median_ms = median_ns * ns_to_ms;

    const p95_idx = @min(n - 1, (n * 95) / 100);
    const p95_ms = @as(f64, @floatFromInt(sorted[p95_idx])) * ns_to_ms;
    const min_ms = @as(f64, @floatFromInt(sorted[0])) * ns_to_ms;
    const max_ms = @as(f64, @floatFromInt(sorted[n - 1])) * ns_to_ms;
    const ops_per_sec = if (total_ms > 0.0) (@as(f64, @floatFromInt(n)) * 1000.0) / total_ms else 0.0;

    return .{
        .iterations = n,
        .warmup_iterations = warmup,
        .elements_per_iter = elements_per_iter,
        .total_ms = total_ms,
        .mean_ms = mean_ms,
        .median_ms = median_ms,
        .p95_ms = p95_ms,
        .min_ms = min_ms,
        .max_ms = max_ms,
        .ops_per_sec = ops_per_sec,
        .checksum = checksum,
    };
}

fn mixHash(acc: u64, val: u64) u64 {
    var x = acc ^ (val +% 0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn floatBits(v: f32) u64 {
    // Quantize to 1/64th pixel to avoid cross-backend float rounding differences in checksum
    const q: i64 = @intFromFloat(@round(v * 64.0));
    return @bitCast(q);
}

// ============================================================================
// Workload 1: Complex Dashboard UI Flexbox Layout (`layout_bench`)
// ~2,047 nodes per frame: sidebar, top bar, metric cards, data rows, badges
// ============================================================================

const ScrollState = struct {
    frame_idx: u32,

    fn getScroll(ctx_ptr: *anyopaque, id: Element.Id) [2]f32 {
        const self: *const ScrollState = @ptrCast(@alignCast(ctx_ptr));
        const offset_y: f32 = @floatFromInt((self.frame_idx * 3 + @as(u32, @truncate(id))) % 120);
        return .{ 0.0, offset_y };
    }
};

const MeasureCallback = struct {
    char_width: f32 = 7.5,
    line_height: f32 = 18.0,

    fn measure(self: MeasureCallback, text_len: usize, font_scale: f32) [2]f32 {
        return .{
            @as(f32, @floatFromInt(text_len)) * self.char_width * font_scale,
            self.line_height * font_scale,
        };
    }
};

fn buildDashboardLayoutFrame(ctx: *layout.Context, frame_idx: u32, measure_cb: MeasureCallback) !usize {
    ctx.reset();
    var next_id: Element.Id = 1;

    // Root container (1600x1000)
    const dyn_w: f32 = 1600.0 + @as(f32, @floatFromInt(frame_idx % 8)) * 4.0;
    const dyn_h: f32 = 1000.0 + @as(f32, @floatFromInt(frame_idx % 4)) * 4.0;
    _ = try ctx.open(next_id, .{
        .width = .fixed(dyn_w),
        .height = .fixed(dyn_h),
        .padding = .all(8),
        .gap = 8,
        .direction = .column,
        .alignment = .stretch,
        .justify = .start,
    });
    next_id += 1;

    // 1. Top bar (1 + 8 * 3 = 25 nodes)
    _ = try ctx.open(next_id, .{
        .width = .grow(),
        .height = .fixed(48),
        .padding = .xy(16, 8),
        .gap = 12,
        .direction = .row,
        .alignment = .center,
        .justify = .space_between,
    });
    next_id += 1;
    for (0..8) |nav_i| {
        _ = try ctx.open(next_id, .{
            .width = .fit(),
            .height = .fixed(32),
            .padding = .xy(10, 4),
            .gap = 6,
            .direction = .row,
            .alignment = .center,
            .justify = .center,
        });
        next_id += 1;

        // Icon
        _ = try ctx.open(next_id, .{ .width = .fixed(16), .height = .fixed(16) });
        next_id += 1;
        ctx.close();

        // Nav label with measured intrinsic size
        const label_slot = try ctx.open(next_id, .{ .width = .fit(), .height = .fit() });
        next_id += 1;
        const m = measure_cb.measure(6 + (nav_i % 5) * 2, 1.0);
        ctx.pool.get(label_slot).intrinsic_w = m[0];
        ctx.pool.get(label_slot).intrinsic_h = m[1];
        ctx.close();

        ctx.close();
    }
    ctx.close();

    // 2. Body container (row: sidebar + main content)
    _ = try ctx.open(next_id, .{
        .width = .grow(),
        .height = .grow(),
        .gap = 8,
        .direction = .row,
        .alignment = .stretch,
    });
    next_id += 1;

    // 2a. Sidebar (1 + 150 * 4 = 601 nodes)
    _ = try ctx.open(next_id, .{
        .width = .fixed(260),
        .height = .grow(),
        .padding = .all(8),
        .gap = 4,
        .direction = .column,
        .overflow = .scroll_y,
    });
    next_id += 1;
    for (0..150) |sb_i| {
        _ = try ctx.open(next_id, .{
            .width = .grow(),
            .height = .fixed(28),
            .padding = .xy(8, 4),
            .gap = 8,
            .direction = .row,
            .alignment = .center,
            .justify = .space_between,
        });
        next_id += 1;

        // Status indicator dot
        _ = try ctx.open(next_id, .{ .width = .fixed(8), .height = .fixed(8) });
        next_id += 1;
        ctx.close();

        // Item label (grow)
        const item_slot = try ctx.open(next_id, .{ .width = .grow(), .height = .fit() });
        next_id += 1;
        const im = measure_cb.measure(10 + (sb_i % 8), 0.9);
        ctx.pool.get(item_slot).intrinsic_w = im[0];
        ctx.pool.get(item_slot).intrinsic_h = im[1];
        ctx.close();

        // Count badge (fit)
        const badge_slot = try ctx.open(next_id, .{
            .width = .fit(),
            .height = .fixed(18),
            .padding = .xy(6, 2),
        });
        next_id += 1;
        const bm = measure_cb.measure(2 + (sb_i % 3), 0.8);
        ctx.pool.get(badge_slot).intrinsic_w = bm[0];
        ctx.pool.get(badge_slot).intrinsic_h = bm[1];
        ctx.close();

        ctx.close();
    }
    ctx.close();

    // 2b. Main content area
    _ = try ctx.open(next_id, .{
        .width = .grow(),
        .height = .grow(),
        .gap = 8,
        .direction = .column,
        .alignment = .stretch,
    });
    next_id += 1;

    // Metric cards row (1 + 8 * 12 = 97 nodes)
    _ = try ctx.open(next_id, .{
        .width = .grow(),
        .height = .fixed(120),
        .gap = 8,
        .direction = .row,
        .alignment = .stretch,
        .justify = .space_between,
    });
    next_id += 1;
    for (0..8) |card_i| {
        _ = try ctx.open(next_id, .{
            .width = .grow(),
            .height = .grow(),
            .padding = .all(10),
            .gap = 6,
            .direction = .column,
            .justify = .space_between,
        });
        next_id += 1;

        // Title + value
        const title_slot = try ctx.open(next_id, .{ .width = .fit(), .height = .fit() });
        next_id += 1;
        const tm = measure_cb.measure(8 + (card_i % 4), 0.85);
        ctx.pool.get(title_slot).intrinsic_w = tm[0];
        ctx.pool.get(title_slot).intrinsic_h = tm[1];
        ctx.close();

        const val_slot = try ctx.open(next_id, .{ .width = .fit(), .height = .fit() });
        next_id += 1;
        const vm = measure_cb.measure(6 + (card_i % 3), 1.4);
        ctx.pool.get(val_slot).intrinsic_w = vm[0];
        ctx.pool.get(val_slot).intrinsic_h = vm[1];
        ctx.close();

        // Sparkline container + 5 bars (6 nodes)
        _ = try ctx.open(next_id, .{
            .width = .grow(),
            .height = .fixed(28),
            .gap = 3,
            .direction = .row,
            .alignment = .end,
        });
        next_id += 1;
        for (0..5) |bar_i| {
            const bar_h: f32 = 8.0 + @as(f32, @floatFromInt(((card_i * 7 + bar_i * 5 + frame_idx) % 20)));
            _ = try ctx.open(next_id, .{ .width = .grow(), .height = .fixed(bar_h) });
            next_id += 1;
            ctx.close();
        }
        ctx.close();

        // Footer row + 2 badges (3 nodes)
        _ = try ctx.open(next_id, .{
            .width = .grow(),
            .height = .fixed(18),
            .direction = .row,
            .justify = .space_between,
            .alignment = .center,
        });
        next_id += 1;
        _ = try ctx.open(next_id, .{ .width = .percent(0.45), .height = .fixed(14) });
        next_id += 1;
        ctx.close();
        _ = try ctx.open(next_id, .{ .width = .percent(0.45), .height = .fixed(14) });
        next_id += 1;
        ctx.close();
        ctx.close();

        ctx.close();
    }
    ctx.close();

    // Scrollable data table (1 + 120 * 11 = 1,321 nodes)
    _ = try ctx.open(next_id, .{
        .width = .grow(),
        .height = .grow(),
        .padding = .all(8),
        .gap = 2,
        .direction = .column,
        .overflow = .scroll_y,
    });
    next_id += 1;
    for (0..120) |row_i| {
        _ = try ctx.open(next_id, .{
            .width = .grow(),
            .height = .fixed(24),
            .padding = .xy(6, 2),
            .gap = 6,
            .direction = .row,
            .alignment = .center,
            .justify = .space_between,
        });
        next_id += 1;

        for (0..10) |col_i| {
            const width_axis: Element.sizing.Axis = switch (col_i % 4) {
                0 => .fixed(64.0 + @as(f32, @floatFromInt((col_i * 8) % 24))),
                1 => .grow(),
                2 => .percent(0.08),
                3 => .fit(),
                else => unreachable,
            };
            const cell_slot = try ctx.open(next_id, .{
                .width = width_axis,
                .height = .grow(),
                .padding = .xy(4, 1),
            });
            next_id += 1;
            if (col_i % 4 == 3) {
                const cm = measure_cb.measure(4 + ((row_i + col_i) % 7), 0.9);
                ctx.pool.get(cell_slot).intrinsic_w = cm[0];
                ctx.pool.get(cell_slot).intrinsic_h = cm[1];
            }
            ctx.close();
        }
        ctx.close();
    }
    ctx.close();

    // Close main content, body, root
    ctx.close();
    ctx.close();
    ctx.close();

    var scroll_state = ScrollState{ .frame_idx = frame_idx };
    const scroll_lookup = layout.Context.ScrollLookup{
        .ctx = @ptrCast(&scroll_state),
        .getFn = ScrollState.getScroll,
    };

    ctx.computeSizes();
    try ctx.computeLayout(scroll_lookup, 8.0);
    try ctx.buildZOrder();

    return ctx.pool.elements.items.len;
}

fn runLayoutBench(allocator: std.mem.Allocator, io: Io, warmup_iters: usize, measured_iters: usize) !Stats {
    var ctx = layout.Context.init(allocator);
    defer ctx.deinit();

    const measure_cb = MeasureCallback{};
    var elements_per_iter: usize = 0;
    var checksum: u64 = 0;

    for (0..warmup_iters) |i| {
        elements_per_iter = try buildDashboardLayoutFrame(&ctx, @intCast(i), measure_cb);
    }

    const samples = try allocator.alloc(u64, measured_iters);
    defer allocator.free(samples);

    for (0..measured_iters) |i| {
        const start_ns = nowNs(io);
        elements_per_iter = try buildDashboardLayoutFrame(&ctx, @intCast(i), measure_cb);
        const end_ns = nowNs(io);
        samples[i] = @intCast(@max(0, end_ns - start_ns));

        // Sample elements across the layout hierarchy for checksum
        const items = ctx.pool.elements.items;
        const step = @max(1, items.len / 32);
        var idx: usize = i % step;
        while (idx < items.len) : (idx += step) {
            const box = items[idx].box;
            checksum = mixHash(checksum, floatBits(box.x()));
            checksum = mixHash(checksum, floatBits(box.y()));
            checksum = mixHash(checksum, floatBits(box.w()));
            checksum = mixHash(checksum, floatBits(box.h()));
        }
    }
    std.mem.doNotOptimizeAway(checksum);

    return computeStats(allocator, samples, warmup_iters, elements_per_iter, checksum);
}

// ============================================================================
// Workload 2: TrueType Font Parsing, Slug Glyph Curve Prep & Text Shaping
// ============================================================================

const sample_paragraphs = [_][]const u8{
    "Knots UI declarative layout and GPU-accelerated Slug quadratic bezier text rendering benchmark across WebAssembly toolchains.",
    "Frame budget: 16.67ms (60 FPS) | Layout: 0.42ms | Text Shaping & Slug Band Indexing: 0.31ms | DrawList Batching: 0.28ms.",
    "0123456789  99.98%  1,024.50 MB/s  4,096x4,096 RGBA32F  [OK] [WARN] [ERR]  p50=0.41ms  p95=0.49ms  p99=0.55ms",
    "The quick brown fox jumps over the lazy dog. PACK MY BOX WITH FIVE DOZEN LIQUOR JUGS! #@&%$*+-=/<>?[]{}()",
    "Wazig compiles Zig and C to WebAssembly in a single self-contained wasm64-wasip3 binary without LLVM overhead.",
    "Metric Card #14: Throughput 142,850 req/s (+12.4% vs baseline) | Active Workers: 16/16 | Memory Pool: 38.2 MiB",
};

const font_sizes = [_]f32{ 12.0, 14.0, 16.0, 20.0, 24.0 };
const wrap_widths = [_]f32{ 185.0, 265.0, 385.0, 545.0 };

fn runTextIteration(allocator: std.mem.Allocator, font_bytes: []const u8, iter_idx: usize) !struct { ops: usize, hash: u64 } {
    var glyph_builder = try text.GlyphBuilder.init(allocator);
    defer glyph_builder.deinit();

    var face = try text.Face.init(allocator, font_bytes, &glyph_builder);
    defer face.deinit();

    var h: u64 = @intCast(iter_idx);
    var ops_count: usize = 0;

    // 1. Direct TrueType outline extraction + Slug curve decomposition + band indexing
    // across printable ASCII codepoints (33..126)
    var cp: u21 = 33;
    var accum_w: f32 = 0;
    while (cp <= 126) : (cp += 1) {
        const rec = try face.getGlyph(cp);
        h = mixHash(h, (@as(u64, rec.glyph_location_x) << 16) | rec.glyph_location_y);
        accum_w += rec.advance_em;
        ops_count += 1;
    }

    // 2. Shape and word-wrap paragraphs, headings, and numeric tables across sizes & wrap widths
    for (sample_paragraphs, 0..) |para, p_idx| {
        const size_px = font_sizes[(p_idx + iter_idx) % font_sizes.len];
        const shaped = try face.shape(para, size_px);
        accum_w += shaped.width;
        h = mixHash(h, @intCast(shaped.glyphs.len));
        ops_count += shaped.glyphs.len;

        for (wrap_widths) |wrap_w| {
            const wrapped = try face.shapeWrapped(para, size_px, wrap_w);
            accum_w += wrapped.width;
            h = mixHash(h, @intFromFloat(@round(wrapped.height)));
            h = mixHash(h, @intCast(wrapped.lines.len));
            for (wrapped.lines) |line| {
                accum_w += line.width;
                h = mixHash(h, @intCast(line.glyphs.len));
                ops_count += line.glyphs.len;
            }
        }
    }

    h = mixHash(h, @intFromFloat(accum_w / 16.0));
    h = mixHash(h, @intCast(glyph_builder.curve_data.items.len));
    h = mixHash(h, @intCast(glyph_builder.band_data.items.len >> 4));
    face.endFrame();

    return .{ .ops = ops_count, .hash = h };
}

fn runTextBench(allocator: std.mem.Allocator, io: Io, warmup_iters: usize, measured_iters: usize) !Stats {
    const default_ui_cfg: ui.UI.Config = .{};
    const font_bytes = default_ui_cfg.fonts[0].data;

    var elements_per_iter: usize = 0;
    var checksum: u64 = 0;

    for (0..warmup_iters) |i| {
        const res = try runTextIteration(allocator, font_bytes, i);
        elements_per_iter = res.ops;
    }

    const samples = try allocator.alloc(u64, measured_iters);
    defer allocator.free(samples);

    for (0..measured_iters) |i| {
        const start_ns = nowNs(io);
        const res = try runTextIteration(allocator, font_bytes, i);
        const end_ns = nowNs(io);
        samples[i] = @intCast(@max(0, end_ns - start_ns));
        elements_per_iter = res.ops;
        checksum = mixHash(checksum, res.hash);
    }
    std.mem.doNotOptimizeAway(checksum);

    return computeStats(allocator, samples, warmup_iters, elements_per_iter, checksum);
}

// ============================================================================
// Workload 3: Render Command List & Batch Generation (`render_bench`)
// ~5,000 primitives per frame across multiple layers, clips, instances & glyphs
// ============================================================================

fn buildRenderFrame(
    draw_list: *render.DrawList,
    packet_commands: *std.ArrayList(render.DrawList.Command),
    frame_idx: u32,
) !struct { primitives: usize, hash: u64 } {
    draw_list.reset();

    var prim_count: usize = 0;
    const f_offset: f32 = @floatFromInt(frame_idx % 16);

    // Populate clip nodes
    try draw_list.clip_nodes.append(draw_list.allocator, render.Clip.Node.empty);
    const clip_panels = [4]math.Rect{
        math.Rect.init(0, 0, 1600, 1000),
        math.Rect.init(0, 48, 260, 952),
        math.Rect.init(268, 48, 1332, 160),
        math.Rect.init(268, 216, 1332, 784),
    };

    // Layer 0: Base UI background & 2,400 instanced rounded rects + 2,400 Slug glyph quads + 200 tessellated quads
    draw_list.setLayer(0);

    // 60 rows x 40 cols = 2,400 UI card/cell instances + 2,400 glyph quads
    for (0..60) |row| {
        const y: f32 = 50.0 + @as(f32, @floatFromInt(row)) * 15.0;
        const clip_state = render.Clip.State{
            .node = 0,
            .scissor = clip_panels[(row / 15) % 4],
        };

        var row_instances: [40]render_types.Instance = undefined;
        for (0..40) |col| {
            const x: f32 = 12.0 + @as(f32, @floatFromInt(col)) * 38.0 + (f_offset * 0.25);
            var inst = std.mem.zeroes(render_types.Instance);
            inst.pos = .{ x, y };
            inst.size = .{ 34.0, 13.0 };
            inst.color = .{ 0.15, 0.25, 0.45, 1.0 };
            inst.corner_radius = .{ 3.0, 3.0, 3.0, 3.0 };
            inst.border_width = .{ 1.0, 1.0, 1.0, 1.0 };
            inst.border_color = .{ 0.35, 0.45, 0.65, 1.0 };
            row_instances[col] = inst;
        }
        try draw_list.pushInstances(&row_instances, .atlas, clip_state);
        prim_count += 40;

        if (try draw_list.beginTextBatch(40, clip_state)) |batch| {
            for (0..40) |col| {
                const x: f32 = 16.0 + @as(f32, @floatFromInt(col)) * 38.0;
                var glyph_inst = std.mem.zeroes(render_types.SlugInstance);
                glyph_inst.bounds = .{ 0.0, 0.0, 0.65, 0.85 };
                glyph_inst.origin_size = .{ x, y + 10.0, 12.0, 1.0 / 12.0 };
                glyph_inst.col = .{ 0.92, 0.95, 0.98, 1.0 };
                glyph_inst.glyph = .{ @floatFromInt((row * 40 + col) % 94 + 1), 0.0 };
                try draw_list.pushTextInstance(batch, glyph_inst);
            }
            prim_count += 40;
        }
    }

    // 200 tessellated vector primitives (4 vertices, 6 indices each)
    const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    for (0..200) |vi| {
        const vx: f32 = @floatFromInt((vi * 23) % 1400);
        const vy: f32 = @floatFromInt((vi * 17) % 900);
        var verts: [4]render_types.Vertex = @splat(std.mem.zeroes(render_types.Vertex));
        verts[0].pos = .{ vx, vy };
        verts[1].pos = .{ vx + 18.0, vy };
        verts[2].pos = .{ vx + 18.0, vy + 10.0 };
        verts[3].pos = .{ vx, vy + 10.0 };
        for (&verts) |*v| v.color = .{ 0.3, 0.7, 0.5, 0.9 };
        try draw_list.push(&verts, &quad_indices, .atlas, .{ .node = 0, .scissor = clip_panels[0] });
        prim_count += 1;
    }

    // Layer 1: Floating overlay / modal backdrop & tooltip cards (4 backdrops + 96 instances)
    draw_list.setLayer(1);
    for (0..4) |bi| {
        const bx: f32 = 300.0 + @as(f32, @floatFromInt(bi)) * 220.0;
        try draw_list.pushBackdrop(
            math.Rect.init(bx, 120.0, 200.0, 140.0),
            .{ 8.0, 8.0, 8.0, 8.0 },
            .{ .blur = 8.0 },
            .{ .node = 0, .scissor = clip_panels[0] },
        );
        prim_count += 1;
    }
    var overlay_insts: [96]render_types.Instance = undefined;
    for (0..96) |oi| {
        var inst = std.mem.zeroes(render_types.Instance);
        inst.pos = .{ 310.0 + @as(f32, @floatFromInt((oi % 16) * 52)), 130.0 + @as(f32, @floatFromInt((oi / 16) * 20)) };
        inst.size = .{ 48.0, 16.0 };
        inst.color = .{ 0.25, 0.30, 0.40, 0.95 };
        overlay_insts[oi] = inst;
    }
    try draw_list.pushInstances(&overlay_insts, .atlas, .{ .node = 0, .scissor = clip_panels[0] });
    prim_count += 96;

    const packet = try draw_list.buildPacket(packet_commands, null);

    var h: u64 = @intCast(packet.commands().len);
    h = mixHash(h, @intCast(packet.instances().len));
    h = mixHash(h, @intCast(packet.textInstances().len));
    h = mixHash(h, @intCast(packet.primitiveIndices().len));
    for (packet.commands()) |cmd| {
        switch (cmd.payload) {
            .vertex => |r| h = mixHash(h, (@as(u64, r.offset) << 32) | r.count),
            .instance => |r| h = mixHash(h, (@as(u64, r.offset) << 32) | r.count),
            .text => |r| h = mixHash(h, (@as(u64, r.offset) << 32) | r.count),
            .backdrop => |b| h = mixHash(h, b.group),
            .custom_draw => {},
        }
    }

    return .{ .primitives = prim_count, .hash = h };
}

fn runRenderBench(allocator: std.mem.Allocator, io: Io, warmup_iters: usize, measured_iters: usize) !Stats {
    var draw_list = render.DrawList.init(allocator);
    defer draw_list.deinit();

    var packet_commands: std.ArrayList(render.DrawList.Command) = .empty;
    defer packet_commands.deinit(allocator);

    var elements_per_iter: usize = 0;
    var checksum: u64 = 0;

    for (0..warmup_iters) |i| {
        const res = try buildRenderFrame(&draw_list, &packet_commands, @intCast(i));
        elements_per_iter = res.primitives;
    }

    const samples = try allocator.alloc(u64, measured_iters);
    defer allocator.free(samples);

    for (0..measured_iters) |i| {
        const start_ns = nowNs(io);
        const res = try buildRenderFrame(&draw_list, &packet_commands, @intCast(i));
        const end_ns = nowNs(io);
        samples[i] = @intCast(@max(0, end_ns - start_ns));
        elements_per_iter = res.primitives;
        checksum = mixHash(checksum, res.hash);
    }
    std.mem.doNotOptimizeAway(checksum);

    return computeStats(allocator, samples, warmup_iters, elements_per_iter, checksum);
}

// ============================================================================
// Workload 4: Combined End-to-End Frame (`combined_frame`)
// Full `ui.Context` frame: layout + wrapped text reflow + accessibility + DrawList packet
// ============================================================================

fn runCombinedUiFrame(view: *ui.Context, frame_idx: usize) !struct { elements: usize, hash: u64 } {
    var frame = try view.beginFrame(.{
        .input = .{ .pos = .{ 320.0, 240.0 }, .pointer_inside = true },
        .now_ms = @as(i64, @intCast(frame_idx)) * 16,
        .delta_ns = 16 * std.time.ns_per_ms,
        .logical_extent = .{ .width = 1280, .height = 800 },
        .physical_extent = .{ .width = 1280, .height = 800 },
        .content_scale = 1.0,
    });
    defer frame.deinit();

    const u = frame.ui();
    _ = try u.open(ui.Key.str("root"), .{
        .width = .fixed(1280),
        .height = .fixed(800),
        .padding = .all(12),
        .gap = 8,
        .direction = .column,
    }, .none);

    // Header
    try frame.e(.{
        ui.component.Rect{
            .key = ui.Key.str("header"),
            .style = &.{
                .width = .grow(),
                .height = .fixed(44),
                .padding = .xy(12, 6),
                .direction = .row,
                .@"align" = .center,
                .justify = .space_between,
                .background = .bg,
                .border_width = .all(1),
                .border_color = .toned,
                .radius = .sm,
            },
        },
        .{
            ui.component.Text{
                .key = ui.Key.str("header-title"),
                .content = "Knots Headless Wasm Benchmark Suite",
                .style = &.{ .font_size = .md },
            },
        },
    });

    // Body: 30 rows x 8 cells with buttons and text
    for (0..30) |r| {
        _ = try u.open(ui.Key.str("row").indexed(r), .{
            .width = .grow(),
            .height = .fixed(22),
            .gap = 4,
            .direction = .row,
            .alignment = .center,
        }, .none);
        for (0..8) |c| {
            const btn = ui.component.Button{
                .key = ui.Key.str("cell-btn").indexed(r * 8 + c),
                .label = if ((r + c) % 2 == 0) "Active" else "Ready",
                .style = &.{
                    .width = .grow(),
                    .height = .fixed(20),
                    .padding = .xy(6, 2),
                    .font_size = .xs,
                },
            };
            _ = try btn.interact(&frame);
        }
        u.close();
    }

    u.close();

    const elem_count = view.ui.layout_ctx.pool.elements.items.len;
    const output = try view.endFrame(&frame);

    var h: u64 = @intCast(output.packet.commands().len);
    h = mixHash(h, @intCast(output.packet.instances().len));
    h = mixHash(h, @intCast(output.packet.textInstances().len));
    h = mixHash(h, @intCast(output.accessibility.nodes.len));
    h = mixHash(h, output.accessibility.revision);

    return .{ .elements = elem_count, .hash = h };
}

fn runCombinedBench(allocator: std.mem.Allocator, io: Io, warmup_iters: usize, measured_iters: usize) !Stats {
    var view = try ui.Context.init(allocator, .{});
    defer view.deinit();

    var elements_per_iter: usize = 0;
    var checksum: u64 = 0;

    for (0..warmup_iters) |i| {
        const res = try runCombinedUiFrame(&view, i);
        elements_per_iter = res.elements;
    }

    const samples = try allocator.alloc(u64, measured_iters);
    defer allocator.free(samples);

    for (0..measured_iters) |i| {
        const start_ns = nowNs(io);
        const res = try runCombinedUiFrame(&view, warmup_iters + i);
        const end_ns = nowNs(io);
        samples[i] = @intCast(@max(0, end_ns - start_ns));
        elements_per_iter = res.elements;
        checksum = mixHash(checksum, res.hash);
    }
    std.mem.doNotOptimizeAway(checksum);

    return computeStats(allocator, samples, warmup_iters, elements_per_iter, checksum);
}

fn printWorkloadJson(stdout: *Io.Writer, name: []const u8, s: Stats, trailing_comma: bool) !void {
    try stdout.print(
        \\    "{s}": {{
        \\      "iterations": {d},
        \\      "warmup_iterations": {d},
        \\      "elements_per_iter": {d},
        \\      "total_ms": {d:.3},
        \\      "mean_ms": {d:.4},
        \\      "median_ms": {d:.4},
        \\      "p95_ms": {d:.4},
        \\      "min_ms": {d:.4},
        \\      "max_ms": {d:.4},
        \\      "ops_per_sec": {d:.2},
        \\      "checksum": {d}
        \\    }}{s}
        \\
    , .{
        name,
        s.iterations,
        s.warmup_iterations,
        s.elements_per_iter,
        s.total_ms,
        s.mean_ms,
        s.median_ms,
        s.p95_ms,
        s.min_ms,
        s.max_ms,
        s.ops_per_sec,
        s.checksum,
        if (trailing_comma) "," else "",
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var human_output = false;
    var scale_div: usize = 1;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--human")) {
            human_output = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            human_output = false;
        } else if (std.mem.startsWith(u8, arg, "--scale=")) {
            scale_div = std.fmt.parseUnsigned(usize, arg["--scale=".len..], 10) catch 1;
            if (scale_div == 0) scale_div = 1;
        }
    }

    const suite_start_ns = nowNs(io);

    const layout_stats = try runLayoutBench(
        allocator,
        io,
        @max(5, 50 / scale_div),
        @max(10, 300 / scale_div),
    );
    const text_stats = try runTextBench(
        allocator,
        io,
        @max(5, 20 / scale_div),
        @max(10, 200 / scale_div),
    );
    const render_stats = try runRenderBench(
        allocator,
        io,
        @max(5, 30 / scale_div),
        @max(10, 300 / scale_div),
    );
    const combined_stats = try runCombinedBench(
        allocator,
        io,
        @max(3, 15 / scale_div),
        @max(10, 100 / scale_div),
    );

    const suite_end_ns = nowNs(io);
    const total_bench_ms = @as(f64, @floatFromInt(@max(0, suite_end_ns - suite_start_ns))) * 1e-6;

    var total_checksum: u64 = 0;
    total_checksum = mixHash(total_checksum, layout_stats.checksum);
    total_checksum = mixHash(total_checksum, text_stats.checksum);
    total_checksum = mixHash(total_checksum, render_stats.checksum);
    total_checksum = mixHash(total_checksum, combined_stats.checksum);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (human_output) {
        try stdout.print(
            \\Knots Wasm Benchmark Runner ({s}, {s}-{s})
            \\  layout_bench:   median={d:.3}ms  mean={d:.3}ms  p95={d:.3}ms  fps={d:.1}  (n={d}, nodes={d})
            \\  text_bench:     median={d:.3}ms  mean={d:.3}ms  p95={d:.3}ms  fps={d:.1}  (n={d}, glyphs={d})
            \\  render_bench:   median={d:.3}ms  mean={d:.3}ms  p95={d:.3}ms  fps={d:.1}  (n={d}, prims={d})
            \\  combined_frame: median={d:.3}ms  mean={d:.3}ms  p95={d:.3}ms  fps={d:.1}  (n={d}, elems={d})
            \\  total_bench_ms: {d:.2}ms  checksum: {d}
            \\
        , .{
            @tagName(builtin.mode),
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
            layout_stats.median_ms,
            layout_stats.mean_ms,
            layout_stats.p95_ms,
            layout_stats.ops_per_sec,
            layout_stats.iterations,
            layout_stats.elements_per_iter,
            text_stats.median_ms,
            text_stats.mean_ms,
            text_stats.p95_ms,
            text_stats.ops_per_sec,
            text_stats.iterations,
            text_stats.elements_per_iter,
            render_stats.median_ms,
            render_stats.mean_ms,
            render_stats.p95_ms,
            render_stats.ops_per_sec,
            render_stats.iterations,
            render_stats.elements_per_iter,
            combined_stats.median_ms,
            combined_stats.mean_ms,
            combined_stats.p95_ms,
            combined_stats.ops_per_sec,
            combined_stats.iterations,
            combined_stats.elements_per_iter,
            total_bench_ms,
            total_checksum,
        });
    }

    try stdout.print(
        \\{{
        \\  "optimize_mode": "{s}",
        \\  "target": "{s}-{s}",
        \\  "total_bench_ms": {d:.3},
        \\  "total_checksum": {d},
        \\  "workloads": {{
        \\
    , .{
        @tagName(builtin.mode),
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        total_bench_ms,
        total_checksum,
    });
    try printWorkloadJson(stdout, "layout_bench", layout_stats, true);
    try printWorkloadJson(stdout, "text_bench", text_stats, true);
    try printWorkloadJson(stdout, "render_bench", render_stats, true);
    try printWorkloadJson(stdout, "combined_frame", combined_stats, false);
    try stdout.print(
        \\  }}
        \\}}
        \\
    , .{});
    try stdout.flush();
}
