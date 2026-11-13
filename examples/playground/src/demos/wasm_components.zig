const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const inspector = @import("../component_inspector.zig");

const js = if (knots.platform.is_wasm) @import("js-bridge") else struct {};

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const SliderInput = ui.component.SliderInput;
const Collapsible = ui.component.Collapsible;
const Canvas = ui.component.Canvas;
const Image = ui.component.Image;
const Spacer = ui.component.Spacer;
const Style = ui.Style;

const wit_source = @embedFile("visual_wit");

const max_shapes: usize = 4096;
const max_pixel_dim: usize = 256;
const max_pixel_bytes: usize = max_pixel_dim * max_pixel_dim * 4;
const max_params_per_slot: usize = 8;

const viewport_key = ui.Key.str("wasm-comp.viewport");
const inspector_collapsible_key = ui.Key.str("wasm-comp.inspector-collapsible");

const section_card: Style = .{
    .width = .grow(),
    .padding = .all(12),
    .direction = .column,
    .gap = 8,
    .background = .muted,
    .radius = .md,
    .border_width = .all(1),
    .border_color = .toned,
};

const pill_btn: Style = .{
    .height = .fixed(28),
    .padding = .xy(10, 0),
    .font_size = .xs,
};

const pill_btn_active: Style = pill_btn.with(.{
    .tone = .primary,
});

const OutputMode = enum(u8) {
    auto = 0,
    vector = 1,
    pixels = 2,
};

const ShapeTag = enum(u8) {
    fill_rect = 0,
    stroke_rect = 1,
    fill_circle = 2,
    stroke_circle = 3,
    line_seg = 4,
    fill_triangle = 5,
};

const ExternDrawShape = extern struct {
    tag: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 0,
    y2: f32 = 0,
    radius_or_width: f32 = 0,
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,
};

comptime {
    std.debug.assert(@sizeOf(ExternDrawShape) == 48);
}

const ParamControl = struct {
    name: []u8,
    min_val: f32,
    max_val: f32,
    default_val: f32,
    step: f32,
    value: f32,
};

const SlotState = struct {
    loaded: bool = false,
    loading: bool = false,
    label: ?[]u8 = null,
    title: ?[]u8 = null,
    summary_text: ?[]u8 = null,
    preferred_output: u8 = 0,
    load_micros: f64 = 0,
    memory_bytes: u32 = 0,
    params: [max_params_per_slot]ParamControl = undefined,
    param_count: usize = 0,
    binary: ?inspector.Summary = null,

    fn clear(self: *SlotState, allocator: std.mem.Allocator) void {
        if (self.label) |s| allocator.free(s);
        if (self.title) |s| allocator.free(s);
        if (self.summary_text) |s| allocator.free(s);
        for (self.params[0..self.param_count]) |p| allocator.free(p.name);
        if (self.binary) |*b| b.deinit(allocator);
        self.* = .{};
    }
};

const Preset = struct {
    label: []const u8,
    filename: []const u8,
    url: []const u8,
};

const generator_presets = [_]Preset{
    .{ .label = "Harmonograph", .filename = "harmonograph.wasm", .url = "./components/harmonograph.wasm" },
    .{ .label = "Boids Flock", .filename = "boids-flock.wasm", .url = "./components/boids-flock.wasm" },
    .{ .label = "Plasma SDF", .filename = "plasma-sdf.wasm", .url = "./components/plasma-sdf.wasm" },
};

const effect_presets = [_]Preset{
    .{ .label = "Kaleidoscope", .filename = "kaleidoscope-effect.wasm", .url = "./components/kaleidoscope-effect.wasm" },
    .{ .label = "Chromatic Prism", .filename = "chromatic-prism-effect.wasm", .url = "./components/chromatic-prism-effect.wasm" },
};

const JsonParam = struct {
    name: []const u8,
    min_val: f32,
    max_val: f32,
    default_val: f32,
    step: f32 = 0,
};

const JsonMetadata = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    summary: []const u8 = "",
    role: u8 = 0,
    preferred_output: u8 = 0,
    memory_bytes: u32 = 0,
    params: []const JsonParam = &.{},
};

const WasmComponents = @This();

initialized: bool = false,
allocator_ref: ?std.mem.Allocator = null,
comp_host: if (knots.platform.is_wasm) js.Value else void = if (knots.platform.is_wasm) .invalid else {},
event_cb: if (knots.platform.is_wasm) ?js.Callback else void = if (knots.platform.is_wasm) null else {},

slots: [2]SlotState = .{ .{}, .{} },
last_error: ?[]u8 = null,

time_sec: f32 = 0,
paused: bool = false,
output_mode: OutputMode = .auto,
inspector_open: bool = false,

shape_buf: ?[]ExternDrawShape = null,
last_shape_count: usize = 0,

pixel_buf: ?[]u8 = null,
pixel_width: u32 = 0,
pixel_height: u32 = 0,
pixel_bytes_len: usize = 0,
pixel_version: u64 = 1,

last_exec_micros: f32 = 0,

pub fn deinit(self: *WasmComponents, allocator: std.mem.Allocator) void {
    self.slots[0].clear(allocator);
    self.slots[1].clear(allocator);
    if (self.last_error) |e| allocator.free(e);
    if (self.shape_buf) |b| allocator.free(b);
    if (self.pixel_buf) |b| allocator.free(b);
    if (comptime knots.platform.is_wasm) {
        if (self.event_cb) |*cb| cb.deinit();
        if (self.comp_host.handle != 0) self.comp_host.release();
    }
    self.* = .{};
}

fn setError(self: *WasmComponents, allocator: std.mem.Allocator, msg: []const u8) void {
    if (self.last_error) |old| allocator.free(old);
    self.last_error = if (msg.len > 0) allocator.dupe(u8, msg) catch null else null;
}

fn ensureInitialized(self: *WasmComponents, app: *knots.App) !void {
    if (self.initialized) return;
    self.initialized = true;
    self.allocator_ref = app.allocator;

    self.shape_buf = try app.allocator.alloc(ExternDrawShape, max_shapes);
    self.pixel_buf = try app.allocator.alloc(u8, max_pixel_bytes);

    if (comptime knots.platform.is_wasm) {
        const host = js.host() catch return;
        defer host.release();
        const mgr = host.get("wasmComponents") catch return;
        if (mgr.isNullish()) {
            mgr.release();
            self.setError(app.allocator, "component-host.js extension is not attached");
            return;
        }
        self.comp_host = mgr;
        const cb = try js.Callback.init(self, onSlotEvent);
        self.event_cb = cb;
        mgr.callVoid("setEventCallback", &.{js.Arg.value(cb.function)}) catch {};

        // Dynamically fetch the starter generator component over HTTP on first visit.
        self.requestFetch(app.allocator, 0, generator_presets[0].filename, generator_presets[0].url);
    } else {
        // On native builds, inspect prebuilt component binaries on disk if present.
        self.inspectNativeFile(app, 0, "zig-out/web/components/harmonograph.wasm");
    }
}

fn requestFetch(self: *WasmComponents, allocator: std.mem.Allocator, slot: usize, filename: []const u8, url: []const u8) void {
    if (comptime !knots.platform.is_wasm) return;
    if (self.comp_host.handle == 0) return;
    self.setError(allocator, "");
    self.slots[slot].loading = true;
    if (self.slots[slot].label) |old| allocator.free(old);
    self.slots[slot].label = allocator.dupe(u8, filename) catch null;
    self.comp_host.callVoid("loadUrl", &.{
        js.Arg.u32(@intCast(slot)),
        js.Arg.string(url),
    }) catch |err| {
        self.slots[slot].loading = false;
        self.setError(allocator, @errorName(err));
    };
}

fn requestUnload(self: *WasmComponents, allocator: std.mem.Allocator, slot: usize) void {
    self.setError(allocator, "");
    if (comptime knots.platform.is_wasm) {
        if (self.comp_host.handle != 0) {
            self.comp_host.callVoid("unload", &.{js.Arg.u32(@intCast(slot))}) catch {};
            return;
        }
    }
    self.slots[slot].clear(allocator);
}

fn requestFilePicker(self: *WasmComponents, slot: u32) void {
    if (comptime !knots.platform.is_wasm) return;
    if (self.comp_host.handle == 0) return;
    self.comp_host.callVoid("openFilePicker", &.{js.Arg.u32(slot)}) catch {};
}

fn inspectNativeFile(self: *WasmComponents, app: *knots.App, slot: usize, sub_path: []const u8) void {
    if (comptime knots.platform.is_wasm) return;
    const allocator = app.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(app.io, sub_path, allocator, .limited(8 * 1024 * 1024)) catch return;
    defer allocator.free(bytes);

    const parsed = inspector.inspect(allocator, bytes) catch |err| {
        self.setError(allocator, @errorName(err));
        return;
    };
    const target_slot: usize = if (slot > 1) (if (parsed.importsUpstreamInterface()) 1 else 0) else slot;
    self.slots[target_slot].clear(allocator);
    self.slots[target_slot].loaded = true;
    self.slots[target_slot].binary = parsed;
    const base = std.fs.path.basename(sub_path);
    self.slots[target_slot].label = allocator.dupe(u8, base) catch null;
    self.slots[target_slot].title = allocator.dupe(u8, base) catch null;
    self.slots[target_slot].summary_text = allocator.dupe(u8, "Inspected Wasm Component binary on native host (run browser target for live WebAssembly execution).") catch null;
}

fn onSlotEvent(ctx_ptr: ?*anyopaque, args: if (knots.platform.is_wasm) js.Value else void, args_len: u32) void {
    if (comptime !knots.platform.is_wasm) return;
    const self: *WasmComponents = @ptrCast(@alignCast(ctx_ptr orelse return));
    const allocator = self.allocator_ref orelse return;
    if (args_len < 6) return;

    const slot_v = args.getIndex(0) catch return;
    defer slot_v.release();
    const ok_v = args.getIndex(1) catch return;
    defer ok_v.release();
    const label_v = args.getIndex(2) catch return;
    defer label_v.release();
    const len_v = args.getIndex(3) catch return;
    defer len_v.release();
    const us_v = args.getIndex(4) catch return;
    defer us_v.release();
    const err_v = args.getIndex(5) catch return;
    defer err_v.release();

    const slot_idx = slot_v.tryU32() catch return;
    if (slot_idx >= self.slots.len) return;
    const ok = ok_v.tryBool() catch false;
    const byte_len = len_v.tryU32() catch 0;
    const load_us = us_v.tryF64() catch 0;

    if (!ok) {
        self.slots[slot_idx].loading = false;
        const msg = err_v.toOwnedString(allocator) catch return;
        defer allocator.free(msg);
        self.setError(allocator, msg);
        return;
    }

    self.setError(allocator, "");
    self.slots[slot_idx].clear(allocator);

    if (byte_len == 0) {
        return;
    }

    const slot = &self.slots[slot_idx];
    slot.loaded = true;
    slot.loading = false;
    slot.load_micros = load_us;
    slot.label = label_v.toOwnedString(allocator) catch null;

    if (allocator.alloc(u8, byte_len)) |raw_bytes| {
        defer allocator.free(raw_bytes);
        self.comp_host.callVoid("copySlotBytes", &.{
            js.Arg.u32(slot_idx),
            js.Arg.bytes(raw_bytes),
        }) catch {};
        if (inspector.inspect(allocator, raw_bytes)) |summary| {
            slot.binary = summary;
        } else |inspect_err| {
            self.setError(allocator, @errorName(inspect_err));
        }
    } else |_| {}

    const json_val = self.comp_host.call("getMetadataJson", &.{js.Arg.u32(slot_idx)}) catch return;
    defer json_val.release();
    const json_text = json_val.toOwnedString(allocator) catch return;
    defer allocator.free(json_text);

    const parsed = std.json.parseFromSlice(JsonMetadata, allocator, json_text, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const meta = parsed.value;
    slot.title = allocator.dupe(u8, meta.title) catch null;
    slot.summary_text = allocator.dupe(u8, meta.summary) catch null;
    slot.preferred_output = meta.preferred_output;
    slot.memory_bytes = meta.memory_bytes;

    const count = @min(meta.params.len, max_params_per_slot);
    var populated: usize = 0;
    for (meta.params[0..count]) |p| {
        const dup_name = allocator.dupe(u8, p.name) catch break;
        slot.params[populated] = .{
            .name = dup_name,
            .min_val = p.min_val,
            .max_val = p.max_val,
            .default_val = p.default_val,
            .step = p.step,
            .value = p.default_val,
        };
        populated += 1;
    }
    slot.param_count = populated;
}

fn activeOutputIsPixels(self: *const WasmComponents) bool {
    return switch (self.output_mode) {
        .vector => false,
        .pixels => true,
        .auto => blk: {
            if (self.slots[0].loaded) break :blk self.slots[0].preferred_output == 1;
            break :blk false;
        },
    };
}

fn executeFrame(
    self: *WasmComponents,
    delta_sec: f32,
    view_w: u32,
    view_h: u32,
    ptr_x: f32,
    ptr_y: f32,
    ptr_down: bool,
    use_pixels: bool,
) void {
    if (comptime !knots.platform.is_wasm) return;
    if (self.comp_host.handle == 0 or !self.slots[0].loaded) {
        self.last_shape_count = 0;
        self.pixel_bytes_len = 0;
        return;
    }

    var combined_params: [max_params_per_slot * 2]f32 = undefined;
    var param_total: usize = 0;
    if (self.slots[1].loaded) {
        for (self.slots[1].params[0..self.slots[1].param_count]) |p| {
            combined_params[param_total] = p.value;
            param_total += 1;
        }
    }
    for (self.slots[0].params[0..self.slots[0].param_count]) |p| {
        combined_params[param_total] = p.value;
        param_total += 1;
    }
    const param_bytes = std.mem.sliceAsBytes(combined_params[0..param_total]);

    if (!use_pixels) {
        const shapes = self.shape_buf orelse return;
        var stats_bytes: [12]u8 align(4) = @splat(0);
        const res = self.comp_host.call("renderVectorFrame", &.{
            js.Arg.f64(self.time_sec),
            js.Arg.f64(delta_sec),
            js.Arg.u32(view_w),
            js.Arg.u32(view_h),
            js.Arg.f64(ptr_x),
            js.Arg.f64(ptr_y),
            js.Arg.boolean(ptr_down),
            js.Arg.bytes(param_bytes),
            js.Arg.bytes(std.mem.sliceAsBytes(shapes)),
            js.Arg.bytes(&stats_bytes),
        }) catch {
            self.last_shape_count = 0;
            return;
        };
        defer res.release();
        const count = res.tryU32() catch 0;
        self.last_shape_count = @min(@as(usize, count), shapes.len);
        self.last_exec_micros = @bitCast(std.mem.readInt(u32, stats_bytes[0..4], .little));
        self.slots[0].memory_bytes = std.mem.readInt(u32, stats_bytes[4..8], .little);
        if (self.slots[1].loaded) {
            self.slots[1].memory_bytes = std.mem.readInt(u32, stats_bytes[8..12], .little);
        }
    } else {
        const pixels = self.pixel_buf orelse return;
        var meta_bytes: [20]u8 align(4) = @splat(0);
        const res = self.comp_host.call("renderPixelFrame", &.{
            js.Arg.f64(self.time_sec),
            js.Arg.f64(delta_sec),
            js.Arg.u32(view_w),
            js.Arg.u32(view_h),
            js.Arg.f64(ptr_x),
            js.Arg.f64(ptr_y),
            js.Arg.boolean(ptr_down),
            js.Arg.bytes(param_bytes),
            js.Arg.bytes(pixels),
            js.Arg.bytes(&meta_bytes),
        }) catch {
            self.pixel_bytes_len = 0;
            return;
        };
        defer res.release();
        const copied = res.tryU32() catch 0;
        self.pixel_width = std.mem.readInt(u32, meta_bytes[0..4], .little);
        self.pixel_height = std.mem.readInt(u32, meta_bytes[4..8], .little);
        self.last_exec_micros = @bitCast(std.mem.readInt(u32, meta_bytes[8..12], .little));
        self.slots[0].memory_bytes = std.mem.readInt(u32, meta_bytes[12..16], .little);
        if (self.slots[1].loaded) {
            self.slots[1].memory_bytes = std.mem.readInt(u32, meta_bytes[16..20], .little);
        }
        if (copied > 0 and self.pixel_width > 0 and self.pixel_height > 0) {
            self.pixel_bytes_len = @min(@as(usize, copied), pixels.len);
            self.pixel_version +%= 1;
        } else {
            self.pixel_bytes_len = 0;
        }
    }
}

pub fn render(self: *WasmComponents, app: *knots.App, frame: *ui.Frame) !void {
    @setEvalBranchQuota(6000);
    try self.ensureInitialized(app);
    const arena = frame.arena();

    if (comptime !knots.platform.is_wasm) {
        for (frame.droppedPaths()) |path| {
            if (std.mem.endsWith(u8, path, ".wasm")) {
                self.inspectNativeFile(app, 2, path);
            }
        }
    }

    const raw_dt = @as(f32, @floatFromInt(frame.input().delta_ns)) * 1e-9;
    const dt = std.math.clamp(raw_dt, 0.001, 0.05);
    if (!self.paused) {
        self.time_sec += dt;
    }

    try frame.e(Text{
        .content = "Dynamically fetch, inspect, hot-swap, and compose wasm32-wasip2 Component Model plugins at runtime. Effects import knots:visual/upstream@0.1.0 and lift/lower across isolated linear memories.",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm, .foreground = .dimmed, .wrap = true, .width = .grow() },
    });

    const gen_name = self.slots[0].title orelse (if (self.slots[0].loading) "Fetching..." else "Unloaded");
    const pipeline_banner = if (self.slots[0].loaded and self.slots[1].loaded)
        try std.fmt.allocPrint(
            arena,
            "PIPELINE: {s} ({d} KiB)  --[WIT knots:visual/upstream]-->  {s} ({d} KiB)  -->  Knots GPU  ·  {d:.1} us/frame",
            .{
                gen_name,
                self.slots[0].memory_bytes / 1024,
                self.slots[1].title orelse "Effect",
                self.slots[1].memory_bytes / 1024,
                self.last_exec_micros,
            },
        )
    else if (self.slots[0].loaded)
        try std.fmt.allocPrint(
            arena,
            "PIPELINE: {s} ({d} KiB)  --[WIT knots:visual/source]-->  Knots GPU  ·  {d:.1} us/frame",
            .{ gen_name, self.slots[0].memory_bytes / 1024, self.last_exec_micros },
        )
    else
        "PIPELINE: Idle — select a .wasm component below or drop a .wasm Component binary onto the window";

    try frame.e(Text{
        .content = pipeline_banner,
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .accented, .wrap = true, .width = .grow() },
    });

    if (self.last_error) |err_msg| {
        try frame.e(.{
            Rect{
                .key = .src(@src()),
                .style = &.{ .width = .grow(), .padding = .xy(10, 6), .background = .elevated, .border_width = .all(1), .border_color = .@"error", .radius = .sm },
            },
            .{Text{
                .content = try std.fmt.allocPrint(arena, "Component loader error: {s}", .{err_msg}),
                .key = .src(@src()),
                .style = &.{ .font_size = .xs, .foreground = .@"error", .wrap = true },
            }},
        });
    }

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(8) } });

    // Slot 0 (Generator) & Slot 1 (Effect) side-by-side cards
    const slots_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12 } };
    _ = try slots_row.open(frame);
    try self.renderGeneratorCard(app, frame);
    try self.renderEffectCard(app, frame);
    try slots_row.close(frame);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });

    // Toolbar: Output mode + Pause + Binary/WIT Inspector toggle
    const use_pixels = self.activeOutputIsPixels();
    try self.renderToolbar(frame, use_pixels);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(8) } });

    // Collapsible Component Binary & WIT Inspector
    const inspector_collapse = Collapsible{
        .key = inspector_collapsible_key,
        .open = self.inspector_open,
    };
    if (try inspector_collapse.openContent(frame)) {
        try self.renderInspectorPanel(frame);
        try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
        inspector_collapse.closeContent(frame);
    }

    // Measure live viewport bounds & pointer position, execute Wasm component pipeline, and draw Canvas or Image
    const ui_ = frame.ui();
    const measured_box = (try ui_.state.getOrCreate(.measured, ui_.allocator, viewport_key.hash())).box;
    const vw: u32 = if (measured_box.w() >= 64) @intFromFloat(measured_box.w()) else 720;
    const vh: u32 = if (measured_box.h() >= 64) @intFromFloat(measured_box.h()) else 380;
    const local_x = @as(f32, @floatCast(ui_.input.mouse_pos[0])) - measured_box.x();
    const local_y = @as(f32, @floatCast(ui_.input.mouse_pos[1])) - measured_box.y();
    const ptr_inside = local_x >= 0 and local_y >= 0 and local_x < @as(f32, @floatFromInt(vw)) and local_y < @as(f32, @floatFromInt(vh));
    const ptr_down = ptr_inside and ui_.input.mouseButton(.left).down;

    self.executeFrame(
        if (self.paused) 0.0 else dt,
        vw,
        vh,
        if (ptr_inside) local_x else -1.0,
        if (ptr_inside) local_y else -1.0,
        ptr_down,
        use_pixels,
    );

    const viewport_panel = Rect{
        .key = viewport_key,
        .style = &.{
            .width = .grow(),
            .height = .fixed(380),
            .overflow = .hidden,
            .background = .{ .color = ui.Color.rgba(6, 9, 18, 255) },
            .border_width = .all(1),
            .border_color = .toned,
            .radius = .md,
            .@"align" = .center,
            .justify = .center,
        },
    };
    _ = try viewport_panel.open(frame);

    if (!knots.platform.is_wasm) {
        try frame.e(Text{
            .content = "Native build: Component Binary & WIT Inspector active above. Build for wasm32/wasm64-freestanding to run live browser Component Model instantiation.",
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed, .wrap = true },
        });
    } else if (!self.slots[0].loaded) {
        try frame.e(Text{
            .content = if (self.slots[0].loading) "Fetching & instantiating .wasm component..." else "No Generator component loaded. Click Harmonograph, Boids Flock, Plasma SDF, or Load .wasm...",
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        });
    } else if (!use_pixels) {
        var commands: std.ArrayList(Canvas.DrawCmd) = .empty;
        if (self.shape_buf) |shapes| {
            try commands.ensureTotalCapacity(arena, self.last_shape_count);
            for (shapes[0..self.last_shape_count]) |s| {
                const color = [4]f32{ s.r, s.g, s.b, s.a };
                switch (@as(ShapeTag, @fromBackingInt(@intCast(s.tag % 6)))) {
                    .fill_rect => commands.appendAssumeCapacity(.{ .fill_rect = .{
                        .x = s.x0,
                        .y = s.y0,
                        .w = s.x1,
                        .h = s.y1,
                        .color = color,
                    } }),
                    .stroke_rect => commands.appendAssumeCapacity(.{ .stroke_rect = .{
                        .x = s.x0,
                        .y = s.y0,
                        .w = s.x1,
                        .h = s.y1,
                        .thickness = s.radius_or_width,
                        .color = color,
                    } }),
                    .fill_circle => commands.appendAssumeCapacity(.{ .fill_circle = .{
                        .cx = s.x0,
                        .cy = s.y0,
                        .radius = s.radius_or_width,
                        .color = color,
                    } }),
                    .stroke_circle => commands.appendAssumeCapacity(.{ .stroke_circle = .{
                        .cx = s.x0,
                        .cy = s.y0,
                        .radius = s.x1,
                        .thickness = s.radius_or_width,
                        .color = color,
                    } }),
                    .line_seg => commands.appendAssumeCapacity(.{ .line = .{
                        .from = .{ s.x0, s.y0 },
                        .to = .{ s.x1, s.y1 },
                        .thickness = s.radius_or_width,
                        .color = color,
                    } }),
                    .fill_triangle => commands.appendAssumeCapacity(.{ .fill_triangle = .{
                        .points = .{ .{ s.x0, s.y0 }, .{ s.x1, s.y1 }, .{ s.x2, s.y2 } },
                        .color = color,
                    } }),
                }
            }
        }
        try frame.e(Canvas{
            .interactive = true,
            .commands = commands.items,
            .key = .str("wasm-comp.canvas"),
            .style = &.{ .width = .grow(), .height = .grow() },
        });
    } else if (self.pixel_buf != null and self.pixel_bytes_len > 0 and self.pixel_width > 0 and self.pixel_height > 0) {
        try frame.e(Image{
            .source = .{ .pixels = .{
                .data = self.pixel_buf.?[0..self.pixel_bytes_len],
                .width = self.pixel_width,
                .height = self.pixel_height,
                .format = .rgba8,
                .upload_policy = .versioned,
                .version = self.pixel_version,
            } },
            .sampling_mode = .@"opaque",
            .key = .str("wasm-comp.image"),
            .style = &.{ .width = .grow(), .height = .grow() },
        });
    }

    try viewport_panel.close(frame);

    if (knots.platform.is_wasm and (self.slots[0].loading or self.slots[1].loading or (self.slots[0].loaded and !self.paused))) {
        frame.requestRedraw();
    }
}

fn renderGeneratorCard(self: *WasmComponents, app: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();
    const card = Rect{ .key = .str("wasm-comp.gen-card"), .style = &section_card };
    _ = try card.open(frame);

    try frame.e(Text{
        .content = "Slot 0 · Visual Generator (exports knots:visual/source@0.1.0)",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .info },
    });

    const btn_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 6 } };
    _ = try btn_row.open(frame);
    for (generator_presets, 0..) |preset, i| {
        const is_active = if (self.slots[0].label) |lbl| std.mem.eql(u8, lbl, preset.filename) else false;
        if ((try frame.interact(Button{
            .key = ui.Key.str("wasm-comp.gen-preset").indexed(i),
            .label = preset.label,
            .style = if (is_active) &pill_btn_active else &pill_btn,
        })).clicked) {
            if (knots.platform.is_wasm) {
                self.requestFetch(app.allocator, 0, preset.filename, preset.url);
            } else {
                const rel = try std.fmt.allocPrint(arena, "zig-out/web/components/{s}", .{preset.filename});
                self.inspectNativeFile(app, 0, rel);
            }
            frame.requestRedraw();
        }
    }
    if (knots.platform.is_wasm) {
        if ((try frame.interact(Button{
            .key = .str("wasm-comp.gen-pick"),
            .label = "Load .wasm...",
            .style = &pill_btn,
        })).clicked) {
            self.requestFilePicker(0);
        }
    }
    if (self.slots[0].loaded) {
        if ((try frame.interact(Button{
            .key = .str("wasm-comp.gen-unload"),
            .label = "Unload",
            .style = &pill_btn,
        })).clicked) {
            self.requestUnload(app.allocator, 0);
            frame.requestRedraw();
        }
    }
    try btn_row.close(frame);

    try renderSlotDetails(frame, &self.slots[0], 0);
    try card.close(frame);
}

fn renderEffectCard(self: *WasmComponents, app: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();
    const card = Rect{ .key = .str("wasm-comp.eff-card"), .style = &section_card };
    _ = try card.open(frame);

    try frame.e(Text{
        .content = "Slot 1 · Composable Effect (imports upstream -> exports source)",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .warning },
    });

    const btn_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 6 } };
    _ = try btn_row.open(frame);
    if ((try frame.interact(Button{
        .key = .str("wasm-comp.eff-none"),
        .label = "None (Direct)",
        .style = if (!self.slots[1].loaded and !self.slots[1].loading) &pill_btn_active else &pill_btn,
    })).clicked) {
        self.requestUnload(app.allocator, 1);
        frame.requestRedraw();
    }
    for (effect_presets, 0..) |preset, i| {
        const is_active = if (self.slots[1].label) |lbl| std.mem.eql(u8, lbl, preset.filename) else false;
        if ((try frame.interact(Button{
            .key = ui.Key.str("wasm-comp.eff-preset").indexed(i),
            .label = preset.label,
            .style = if (is_active) &pill_btn_active else &pill_btn,
        })).clicked) {
            if (knots.platform.is_wasm) {
                self.requestFetch(app.allocator, 1, preset.filename, preset.url);
            } else {
                const rel = try std.fmt.allocPrint(arena, "zig-out/web/components/{s}", .{preset.filename});
                self.inspectNativeFile(app, 1, rel);
            }
            frame.requestRedraw();
        }
    }
    if (knots.platform.is_wasm) {
        if ((try frame.interact(Button{
            .key = .str("wasm-comp.eff-pick"),
            .label = "Load .wasm...",
            .style = &pill_btn,
        })).clicked) {
            self.requestFilePicker(1);
        }
    }
    try btn_row.close(frame);

    try renderSlotDetails(frame, &self.slots[1], 1);
    try card.close(frame);
}

fn renderSlotDetails(frame: *ui.Frame, slot: *SlotState, comptime slot_idx: usize) !void {
    const arena = frame.arena();
    const prefix = if (slot_idx == 0) "wasm-comp.s0" else "wasm-comp.s1";

    if (slot.loading) {
        try frame.e(Text{
            .content = try std.fmt.allocPrint(arena, "Fetching {s}...", .{slot.label orelse "component"}),
            .key = .str(prefix ++ ".loading"),
            .style = &.{ .font_size = .xs, .foreground = .warning },
        });
        return;
    }
    if (!slot.loaded) {
        try frame.e(Text{
            .content = if (slot_idx == 0)
                "Unloaded — pick a .wasm generator to dynamically fetch & instantiate."
            else
                "Bypassed — Generator output renders directly without an effect stage.",
            .key = .str(prefix ++ ".empty"),
            .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true },
        });
        return;
    }

    const byte_kb = if (slot.binary) |b| @as(f64, @floatFromInt(b.byte_len)) / 1024.0 else 0.0;
    try frame.e(Text{
        .content = try std.fmt.allocPrint(
            arena,
            "{s} ({s}) · {d:.1} KiB .wasm · load {d:.0} us · mem {d} KiB",
            .{
                slot.title orelse "Component",
                slot.label orelse "custom.wasm",
                byte_kb,
                slot.load_micros,
                slot.memory_bytes / 1024,
            },
        ),
        .key = .str(prefix ++ ".meta"),
        .style = &.{ .font_size = .xs, .foreground = .text, .wrap = true },
    });

    if (slot.summary_text) |summary| {
        try frame.e(Text{
            .content = summary,
            .key = .str(prefix ++ ".summary"),
            .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true },
        });
    }

    if (slot.param_count > 0) {
        const sliders_grid = Rect{
            .key = .str(prefix ++ ".params"),
            .style = &.{ .width = .grow(), .direction = .row, .gap = 10 },
        };
        _ = try sliders_grid.open(frame);
        for (slot.params[0..slot.param_count], 0..) |*p, pi| {
            const col = Rect{
                .key = ui.Key.str(prefix ++ ".pcol").indexed(pi),
                .style = &.{ .width = .grow(), .direction = .column, .gap = 4 },
            };
            _ = try col.open(frame);
            try frame.e(Text{
                .content = try std.fmt.allocPrint(arena, "{s}: {d:.2}", .{ p.name, p.value }),
                .key = ui.Key.str(prefix ++ ".plbl").indexed(pi),
                .style = &.{ .font_size = .xs, .foreground = .dimmed },
            });
            _ = try frame.interact(SliderInput{
                .value = &p.value,
                .min = p.min_val,
                .max = p.max_val,
                .steps = p.step,
                .key = ui.Key.str(prefix ++ ".pslider").indexed(pi),
                .style = &.{ .width = .grow() },
            });
            try col.close(frame);
        }
        try sliders_grid.close(frame);
    }
}

fn renderToolbar(self: *WasmComponents, frame: *ui.Frame, use_pixels: bool) !void {
    const arena = frame.arena();
    const bar = Rect{
        .key = .str("wasm-comp.toolbar"),
        .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center, .justify = .space_between },
    };
    _ = try bar.open(frame);

    const left = Rect{ .key = .src(@src()), .style = &.{ .direction = .row, .gap = 6, .@"align" = .center } };
    _ = try left.open(frame);
    const modes = [_]struct { mode: OutputMode, label: []const u8 }{
        .{ .mode = .auto, .label = "Output: Auto" },
        .{ .mode = .vector, .label = "Vector (Canvas)" },
        .{ .mode = .pixels, .label = "Pixels (Image RGBA8)" },
    };
    for (modes, 0..) |m, i| {
        if ((try frame.interact(Button{
            .key = ui.Key.str("wasm-comp.mode").indexed(i),
            .label = m.label,
            .style = if (self.output_mode == m.mode) &pill_btn_active else &pill_btn,
        })).clicked) {
            self.output_mode = m.mode;
            frame.requestRedraw();
        }
    }
    if ((try frame.interact(Button{
        .key = .str("wasm-comp.pause"),
        .label = if (self.paused) "Resume" else "Pause",
        .style = &pill_btn,
    })).clicked) {
        self.paused = !self.paused;
        frame.requestRedraw();
    }
    if ((try frame.interact(Button{
        .key = .str("wasm-comp.inspect-toggle"),
        .label = if (self.inspector_open) "Hide WIT & Binary Inspector" else "Inspect WIT & Component Binary",
        .style = if (self.inspector_open) &pill_btn_active else &pill_btn,
    })).clicked) {
        self.inspector_open = !self.inspector_open;
        frame.requestRedraw();
    }
    try left.close(frame);

    const stats_label = if (!self.slots[0].loaded)
        "0 primitives"
    else if (!use_pixels)
        try std.fmt.allocPrint(arena, "Canvas: {d} vector shapes", .{self.last_shape_count})
    else
        try std.fmt.allocPrint(arena, "Image: {d}x{d} RGBA8 ({d} KiB)", .{ self.pixel_width, self.pixel_height, self.pixel_bytes_len / 1024 });

    try frame.e(Text{
        .content = stats_label,
        .key = .str("wasm-comp.toolbar-stats"),
        .style = &.{ .font_size = .xs, .foreground = .dimmed },
    });

    try bar.close(frame);
}

fn renderInspectorPanel(self: *const WasmComponents, frame: *ui.Frame) !void {
    const arena = frame.arena();
    const panel = Rect{
        .key = .str("wasm-comp.inspector-panel"),
        .style = &comptime section_card.with(.{ .background = .elevated, .gap = 10 }),
    };
    _ = try panel.open(frame);

    const cols = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12 } };
    _ = try cols.open(frame);

    inline for (0..2) |slot_i| {
        const prefix = if (slot_i == 0) "wasm-comp.insp0" else "wasm-comp.insp1";
        const box = Rect{
            .key = .str(prefix),
            .style = &.{ .width = .grow(), .padding = .all(10), .direction = .column, .gap = 4, .background = .muted, .radius = .sm },
        };
        _ = try box.open(frame);
        try frame.e(Text{
            .content = if (slot_i == 0) "Binary Decode · Slot 0 (Generator)" else "Binary Decode · Slot 1 (Effect)",
            .key = .str(prefix ++ ".hdr"),
            .style = &.{ .font_size = .xs, .foreground = .accented },
        });
        if (self.slots[slot_i].binary) |bin| {
            try frame.e(Text{
                .content = try std.fmt.allocPrint(
                    arena,
                    "Preamble: \\0asm v0x{x:0>2} layer 0x{x:0>2} · {d} bytes · {d} sections",
                    .{ bin.version, bin.layer, bin.byte_len, bin.section_count },
                ),
                .key = .str(prefix ++ ".pre"),
                .style = &.{ .font = "jetbrains-mono", .font_size = .xs },
            });
            try frame.e(Text{
                .content = try std.fmt.allocPrint(
                    arena,
                    "Core modules: {d}  |  types: {d}  |  canon.lift: {d}  |  canon.lower: {d}",
                    .{ bin.core_module_count, bin.type_count, bin.canon_lift_count, bin.canon_lower_count },
                ),
                .key = .str(prefix ++ ".counts"),
                .style = &.{ .font = "jetbrains-mono", .font_size = .xs, .foreground = .dimmed },
            });
            for (bin.imports, 0..) |imp, ii| {
                try frame.e(Text{
                    .content = try std.fmt.allocPrint(arena, "  import {s} ({s})", .{ imp.name, imp.kind.label() }),
                    .key = ui.Key.str(prefix ++ ".imp").indexed(ii),
                    .style = &.{ .font = "jetbrains-mono", .font_size = .xs, .foreground = .warning },
                });
            }
            for (bin.exports, 0..) |exp, ei| {
                try frame.e(Text{
                    .content = try std.fmt.allocPrint(arena, "  export {s} ({s})", .{ exp.name, exp.kind.label() }),
                    .key = ui.Key.str(prefix ++ ".exp").indexed(ei),
                    .style = &.{ .font = "jetbrains-mono", .font_size = .xs, .foreground = .info },
                });
            }
        } else {
            try frame.e(Text{
                .content = "Slot empty — load a .wasm component to inspect its sections.",
                .key = .str(prefix ++ ".none"),
                .style = &.{ .font_size = .xs, .foreground = .dimmed },
            });
        }
        try box.close(frame);
    }

    try cols.close(frame);

    try frame.e(Text{
        .content = "WIT Contract (examples/playground/wit/visual.wit)",
        .key = .str("wasm-comp.wit-hdr"),
        .style = &.{ .font_size = .xs, .foreground = .accented },
    });
    try frame.e(.{
        Rect{
            .key = .str("wasm-comp.wit-box"),
            .style = &.{ .width = .grow(), .height = .fixed(148), .padding = .all(10), .background = .muted, .radius = .sm, .overflow = .scroll_y },
        },
        .{Text{
            .content = wit_source,
            .key = .str("wasm-comp.wit-src"),
            .style = &.{ .font = "jetbrains-mono", .font_size = .xs, .foreground = .dimmed },
        }},
    });

    try panel.close(frame);
}
