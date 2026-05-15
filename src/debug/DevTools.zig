const std = @import("std");

const knots = @import("knots");
const Perf = @import("Perf.zig");

const Decoration = @import("ui").Decoration;
const Element = @import("layout").Element;

pub const GPUBackend = @import("gpu_backend").Backend;
pub const PresentMode = @import("gpu").Context.PresentMode;

const Button = knots.component.Button;
const Rect = knots.component.Rect;
const SelectInput = knots.component.SelectInput;
const Text = knots.component.Text;

const present_modes = std.enums.values(PresentMode);

const panel_w: f32 = 680.0;
const panel_landscape_h: f32 = 235.0;
const panel_portrait_max_h: f32 = 360.0;
const margin: f32 = 16.0;
const trigger_size: f32 = 40.0;
const trigger_visible_h: f32 = trigger_size / 2.0;
const panel_gap: f32 = 6.0;
const panel_z: u8 = 240;
const trigger_z: u8 = 245;
const popup_z: u8 = 250;

const Tab = enum {
    metrics,
    renderer,
};

const State = struct {
    backend_idx: u32,
    present_mode_idx: u32,
    panel_open: bool = false,
    active_tab: Tab = .metrics,
    perf: Perf = .{},
    spark_cmds: std.ArrayList(Decoration.DrawCmd) = .empty,
};

state: *State,
onClick: ?*const fn (*knots.App) anyerror!void = null,

const DevTools = @This();

fn mustFindIdx(slice: anytype, needle: anytype) u32 {
    for (slice, 0..) |value, i| {
        if (needle == value) return @intCast(i);
    }
    unreachable;
}

fn enumTagNames(comptime T: type, comptime values: []const T) [][]const u8 {
    comptime var names: [values.len][]const u8 = undefined;
    inline for (values, 0..) |v, i| names[i] = @tagName(v);
    const fixed: [values.len][]const u8 = names;
    return @constCast(&fixed);
}

pub fn init(allocator: std.mem.Allocator, gpu_backend: GPUBackend, present_mode: PresentMode) !DevTools {
    const state = try allocator.create(State);
    state.* = .{
        .backend_idx = mustFindIdx(GPUBackend.availableSlice(), gpu_backend),
        .present_mode_idx = mustFindIdx(present_modes, present_mode),
    };
    return .{ .state = state };
}

pub fn deinit(self: *const DevTools, allocator: std.mem.Allocator) void {
    self.state.spark_cmds.deinit(allocator);
    allocator.destroy(self.state);
}

const trigger_key: knots.ui.Key = .str("debug_devtools_trigger");
const trigger_button_key: knots.ui.Key = .str("debug_devtools_trigger_button");
const panel_key: knots.ui.Key = .str("debug_devtools_panel");
const metrics_tab_key: knots.ui.Key = .str("debug_devtools_metrics_tab");
const renderer_tab_key: knots.ui.Key = .str("debug_devtools_renderer_tab");
const close_key: knots.ui.Key = .str("debug_devtools_close");
const apply_key: knots.ui.Key = .str("debug_devtools_apply");
const backend_key: knots.ui.Key = .str("debug_devtools_backend");
const present_mode_key: knots.ui.Key = .str("debug_devtools_present_mode");
const spark_key: knots.ui.Key = .str("debug_devtools_spark");

fn selectedIdx(app: *knots.App, key: knots.ui.Key, fallback: u32) u32 {
    const s = app.ui.state.get(.select_input, key.hash()) orelse return fallback;
    return s.selected orelse fallback;
}

pub fn render(self: *const DevTools, app: *knots.App) anyerror!void {
    self.state.perf.update(app.timer.delta);

    const size = app.window.getSize();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);
    const trigger_x = @max(0, (w - trigger_size) / 2.0);
    const trigger_y = @max(0, h - trigger_visible_h);

    try self.renderTrigger(app, trigger_x, trigger_y);
    if (app.ui.clickedWithin(trigger_button_key.hash())) self.state.panel_open = !self.state.panel_open;

    if (self.state.panel_open) try self.renderPanel(app, w, trigger_y);
    if (app.ui.clickedWithin(close_key.hash())) self.state.panel_open = false;
}

fn renderTrigger(_: *const DevTools, app: *knots.App, x: f32, y: f32) !void {
    _ = try app.ui.openRoot(trigger_key, x, y, .{
        .width = .fixed(trigger_size),
        .height = .fixed(trigger_size),
        .z_index = trigger_z,
    }, .none);

    try app.e(Button{
        .key = trigger_button_key,
        .width = .grow(),
        .height = .grow(),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = .primary, .corner_radius = .{ .fixed = trigger_size / 2.0 } },
        .hover_anim = .{},
        .text = .{ .content = ">_", .size = .xs },
        .padding = .init(0, 0, 18, 0),
    });

    app.ui.close();
}

fn renderPanel(self: *const DevTools, app: *knots.App, window_w: f32, trigger_y: f32) !void {
    const width = @min(panel_w, @max(trigger_size, window_w - margin * 2.0));
    const x = centeredOverlayX(window_w, width);
    const is_landscape = width >= 560.0;
    const max_h = @max(80.0, trigger_y - margin - panel_gap);
    const desired_h = if (is_landscape) panel_landscape_h else panel_portrait_max_h;
    const height = @min(desired_h, max_h);
    const y = @max(margin, trigger_y - height - panel_gap);

    _ = try app.ui.openRoot(panel_key, x, y, .{
        .width = .fixed(width),
        .height = if (is_landscape) .fixed(height) else .{ .kind = .fit, .max = height },
        .padding = .init(14, 14, 14, 14),
        .direction = .column,
        .gap = 12,
        .overflow = .scroll_y,
        .z_index = panel_z,
    }, .{ .rect = .{
        .color = app.ui.theme.elevated.value,
        .corner_radius = app.ui.theme.radius * 1.5,
        .border_width = 1,
        .border_color = app.ui.theme.toned.value,
    } });

    try self.renderTabs(app);
    if (app.ui.clickedWithin(metrics_tab_key.hash())) self.state.active_tab = .metrics;
    if (app.ui.clickedWithin(renderer_tab_key.hash())) self.state.active_tab = .renderer;

    const content_w = @max(0, width - 28.0);
    switch (self.state.active_tab) {
        .metrics => try self.renderMetricsTab(app, content_w),
        .renderer => try self.renderRenderer(app),
    }

    app.ui.close();

    if (app.ui.clickedWithin(apply_key.hash())) {
        const backend_idx = selectedIdx(app, backend_key, self.state.backend_idx);
        const present_mode_idx = selectedIdx(app, present_mode_key, self.state.present_mode_idx);
        self.state.backend_idx = backend_idx;
        self.state.present_mode_idx = present_mode_idx;
        try app.reconfigureRenderer(.{
            .gpu_backend = GPUBackend.availableSlice()[backend_idx],
            .present_mode = present_modes[present_mode_idx],
        });
        if (self.onClick) |cb| try cb(app);
    }
}

fn centeredOverlayX(window_w: f32, width: f32) f32 {
    if (window_w <= width + margin * 2.0) return @max(0, (window_w - width) / 2.0);
    return std.math.clamp((window_w - width) / 2.0, margin, window_w - width - margin);
}

fn renderTabs(self: *const DevTools, app: *knots.App) !void {
    _ = try app.ui.open(panel_key.indexed(4), .{
        .width = .grow(),
        .height = .fixed(30),
        .direction = .row,
        .gap = 6,
    }, .none);

    try app.e(Button{
        .key = metrics_tab_key,
        .width = .grow(),
        .height = .grow(),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = if (self.state.active_tab == .metrics) .primary else .muted, .corner_radius = .sm },
        .hover_style = if (self.state.active_tab == .metrics) null else .{ .color = .toned },
        .hover_anim = .{},
        .text = .{ .content = "Metrics", .size = .xs },
    });

    try app.e(Button{
        .key = renderer_tab_key,
        .width = .grow(),
        .height = .grow(),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = if (self.state.active_tab == .renderer) .primary else .muted, .corner_radius = .sm },
        .hover_style = if (self.state.active_tab == .renderer) null else .{ .color = .toned },
        .hover_anim = .{},
        .text = .{ .content = "Renderer", .size = .xs },
    });

    app.ui.close();
}

fn renderMetricsTab(self: *const DevTools, app: *knots.App, content_w: f32) !void {
    _ = try app.ui.open(panel_key.indexed(40), .{
        .width = .grow(),
        .direction = .column,
        .gap = 12,
    }, .none);

    try self.renderMetricsGrid(app);
    try self.renderSparkline(app, content_w);

    app.ui.close();
}

fn renderPerformance(self: *const DevTools, app: *knots.App, width: f32) !void {
    try self.renderPerformanceMetrics(app);
    try self.renderSparkline(app, width);
}

fn renderPerformanceMetrics(self: *const DevTools, app: *knots.App) !void {
    const arena = app.arena();
    const mm = self.state.perf.minMaxMs();

    try metricGrid(app, panel_key.indexed(11), &.{
        .{ "FPS", try std.fmt.allocPrint(arena, "{d:.1}", .{self.state.perf.averageFps()}) },
        .{ "Frame", try std.fmt.allocPrint(arena, "{d:.2} ms", .{self.state.perf.latest_ms}) },
        .{ "Min", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.min}) },
        .{ "Max", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.max}) },
    });
}

fn renderMetricsGrid(self: *const DevTools, app: *knots.App) !void {
    const arena = app.arena();
    const mm = self.state.perf.minMaxMs();
    const stats = app.ui.last_stats;

    try metricGridColumns(app, panel_key.indexed(12), 5, &.{
        .{ "FPS", try std.fmt.allocPrint(arena, "{d:.1}", .{self.state.perf.averageFps()}) },
        .{ "Frame", try std.fmt.allocPrint(arena, "{d:.2} ms", .{self.state.perf.latest_ms}) },
        .{ "Min", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.min}) },
        .{ "Max", try std.fmt.allocPrint(arena, "{d:.2} ms", .{mm.max}) },
        .{ "Elements", try std.fmt.allocPrint(arena, "{d}", .{stats.elements}) },
        .{ "Hit records", try std.fmt.allocPrint(arena, "{d}", .{stats.hit_records}) },
        .{ "Scroll roots", try std.fmt.allocPrint(arena, "{d}", .{stats.scroll_containers}) },
        .{ "Draw layers", try std.fmt.allocPrint(arena, "{d}", .{stats.layers}) },
        .{ "Hovered", try formatId(arena, app.ui.state.hovered) },
        .{ "Focused", try formatId(arena, app.ui.state.focused) },
    });
}

fn renderSparkline(self: *const DevTools, app: *knots.App, width: f32) !void {
    const label_w: f32 = 42.0;
    try self.buildSparkline(app, @max(1, width - label_w));

    _ = try app.ui.open(spark_key.indexed(1), .{
        .width = .grow(),
        .height = .fixed(68),
        .direction = .row,
        .alignment = .center,
        .gap = 8,
    }, .none);

    try app.e(Text{
        .key = spark_key.indexed(2),
        .content = "ms",
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });

    _ = try app.ui.open(spark_key, .{
        .width = .grow(),
        .height = .fixed(68),
        .overflow = .hidden,
    }, .{ .canvas = .{ .cmds = self.state.spark_cmds.items } });
    app.ui.close();

    app.ui.close();
}

fn renderRenderer(self: *const DevTools, app: *knots.App) !void {
    _ = try app.ui.open(panel_key.indexed(20), .{
        .width = .grow(),
        .direction = .column,
        .gap = 8,
    }, .none);

    _ = try app.ui.open(panel_key.indexed(21), .{
        .width = .grow(),
        .padding = .init(8, 10, 8, 10),
        .direction = .column,
        .gap = 8,
    }, .{ .rect = .{
        .color = app.ui.theme.muted.value,
        .corner_radius = app.ui.theme.radius * 0.5,
        .border_width = 1,
        .border_color = app.ui.theme.toned.value,
    } });
    _ = try app.ui.open(panel_key.indexed(22), .{
        .width = .grow(),
        .direction = .column,
        .gap = 4,
    }, .none);
    try app.e(Text{
        .key = panel_key.indexed(23),
        .content = "GPU API",
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });
    try app.e(SelectInput(GPUBackend){
        .key = backend_key,
        .initial_selected = self.state.backend_idx,
        .width = .grow(),
        .labels = enumTagNames(GPUBackend, GPUBackend.availableSlice()),
        .values = GPUBackend.availableSlice(),
        .dropdown_z_index = popup_z,
        .size = .sm,
    });
    app.ui.close();

    _ = try app.ui.open(panel_key.indexed(24), .{
        .width = .grow(),
        .direction = .column,
        .gap = 4,
    }, .none);
    try app.e(Text{
        .key = panel_key.indexed(25),
        .content = "Present mode",
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });
    try app.e(SelectInput(PresentMode){
        .key = present_mode_key,
        .initial_selected = self.state.present_mode_idx,
        .width = .grow(),
        .dropdown_z_index = popup_z,
        .size = .sm,
    });
    app.ui.close();

    try app.e(Button{
        .key = apply_key,
        .width = .grow(),
        .height = .fixed(32),
        .justify = .center,
        .@"align" = .center,
        .style = .{ .color = .primary, .corner_radius = .sm },
        .hover_anim = .{},
        .text = .{ .content = "Apply" },
    });

    app.ui.close();

    app.ui.close();
}

fn renderDiagnostics(_: *const DevTools, app: *knots.App) !void {
    const arena = app.arena();
    const stats = app.ui.last_stats;

    try metricGrid(app, panel_key.indexed(31), &.{
        .{ "Elements", try std.fmt.allocPrint(arena, "{d}", .{stats.elements}) },
        .{ "Hit records", try std.fmt.allocPrint(arena, "{d}", .{stats.hit_records}) },
        .{ "Scroll roots", try std.fmt.allocPrint(arena, "{d}", .{stats.scroll_containers}) },
        .{ "Draw layers", try std.fmt.allocPrint(arena, "{d}", .{stats.layers}) },
        .{ "Hovered", try formatId(arena, app.ui.state.hovered) },
        .{ "Focused", try formatId(arena, app.ui.state.focused) },
    });
}

fn buildSparkline(self: *const DevTools, app: *knots.App, panel_width: f32) !void {
    const cmds = &self.state.spark_cmds;
    cmds.clearRetainingCapacity();

    const line_color = app.ui.theme.primary.value;
    const guide_color = app.ui.theme.dimmed.value;

    const plot_w = @max(1, panel_width);

    if (self.state.perf.count < 2) return;

    const width: f32 = plot_w;
    const height: f32 = 52.0;
    const ox: f32 = 0.0;
    const oy: f32 = 8.0;
    const mm = self.state.perf.minMaxMs();
    const max_ms = @max(16.7, mm.max);
    const denom = @max(1.0, max_ms);
    const n = self.state.perf.count;
    const step = width / @as(f32, @floatFromInt(n - 1));

    try cmds.append(app.ui.allocator, .{ .line = .{
        .from = .{ ox, oy + height * 0.5 },
        .to = .{ ox + width, oy + height * 0.5 },
        .color = guide_color,
        .thickness = 1,
    } });

    var prev_x: f32 = ox;
    var prev_y: f32 = oy + height - (std.math.clamp(self.state.perf.sampleAt(0) / denom, 0, 1) * height);
    for (1..n) |i| {
        const x = ox + step * @as(f32, @floatFromInt(i));
        const y = oy + height - (std.math.clamp(self.state.perf.sampleAt(i) / denom, 0, 1) * height);
        try cmds.append(app.ui.allocator, .{ .line = .{
            .from = .{ prev_x, prev_y },
            .to = .{ x, y },
            .color = line_color,
            .thickness = 2,
        } });
        prev_x = x;
        prev_y = y;
    }
}

fn label(app: *knots.App, key: knots.ui.Key, content: []const u8) !void {
    try app.e(Text{
        .key = key,
        .content = content,
        .size = .xs,
        .color = .dimmed,
        .selectable = false,
    });
}

fn metricGrid(app: *knots.App, key: knots.ui.Key, items: []const struct { []const u8, []const u8 }) !void {
    try metricGridColumns(app, key, 2, items);
}

fn metricGridColumns(app: *knots.App, key: knots.ui.Key, columns: usize, items: []const struct { []const u8, []const u8 }) !void {
    _ = try app.ui.open(key, .{
        .width = .grow(),
        .direction = .column,
        .gap = 4,
    }, .none);

    var i: usize = 0;
    while (i < items.len) : (i += columns) {
        _ = try app.ui.open(key.indexed(100 + i), .{
            .width = .grow(),
            .direction = .row,
            .gap = 4,
        }, .none);

        var col: usize = 0;
        while (col < columns) : (col += 1) {
            const item_idx = i + col;
            if (item_idx < items.len) {
                try app.e(MetricCard{
                    .key = key.indexed(200 + item_idx),
                    .name_key = key.indexed(300 + item_idx * 2),
                    .value_key = key.indexed(301 + item_idx * 2),
                    .name = items[item_idx][0],
                    .value = items[item_idx][1],
                });
            } else {
                try app.e(Rect{ .key = key.indexed(200 + item_idx), .width = .grow() });
            }
        }

        app.ui.close();
    }

    app.ui.close();
}

const MetricCard = struct {
    key: knots.ui.Key,
    name_key: knots.ui.Key,
    value_key: knots.ui.Key,
    name: []const u8,
    value: []const u8,

    pub fn render(self: *const MetricCard, app: *knots.App) anyerror!void {
        try app.e(.{
            Rect{
                .key = self.key,
                .width = .grow(),
                .padding = .init(5, 8, 5, 8),
                .dir = .column,
                .style = .{ .color = .muted, .corner_radius = .sm, .border_width = 1, .border_color = .toned },
            },
            .{
                Text{ .key = self.name_key, .content = self.name, .size = .xs, .color = .dimmed, .selectable = false },
                Text{ .key = self.value_key, .content = self.value, .size = .xs, .selectable = false },
            },
        });
    }
};

fn formatId(allocator: std.mem.Allocator, id: Element.Id) ![]const u8 {
    if (id == Element.INVALID_ID) return "none";
    return std.fmt.allocPrint(allocator, "0x{x}", .{@as(u32, @truncate(id))});
}
