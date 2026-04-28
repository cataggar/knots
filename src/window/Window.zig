const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const impl = @import("window_impl");

const Key = @import("root.zig").Key;
const Config = @import("root.zig").Config;
const Input = @import("root.zig").Input;
const KeyAction = @import("root.zig").KeyAction;
const Mods = @import("root.zig").Mods;
const KeyEvent = @import("root.zig").KeyEvent;
const Size = @import("root.zig").Size;
const ResizeEvent = @import("root.zig").ResizeEvent;
const DisplayMode = @import("root.zig").DisplayMode;
const DropCallback = @import("root.zig").DropCallback;

const SCROLL_SPEED: comptime_float = 10;

backend: impl.Backend,
should_close: bool = false,
mouse_button_pressed: bool = false,
scroll: [2]f64 = .{ 0, 0 },
char_buf: [32]u21 = [_]u21{0} ** 32,
char_count: u8 = 0,
key_events: [16]KeyEvent = undefined,
key_buf: [16]Key = undefined,
key_count: u8 = 0,
resized: bool = false,
drop_callback: ?DropCallback = null,
drop_ctx: ?*anyopaque = null,
canvas_selector: ?[:0]const u8,
pending_resize: ?ResizeEvent = null,
content_scale: f32 = 1.0,

const Window = @This();

pub fn init(cfg: Config) !Window {
    const initial: ?ResizeEvent = if (builtin.os.tag == .emscripten)
        applyCanvasSize(cfg.canvas_selector orelse @panic("canvas_selector must be set for emscripten windows"), cfg.width, cfg.height)
    else
        null;

    var self: Window = .{
        .backend = undefined,
        .canvas_selector = cfg.canvas_selector,
        .pending_resize = initial,
    };

    const init_w: u32 = if (initial) |ev| ev.logical.width else cfg.width;
    const init_h: u32 = if (initial) |ev| ev.logical.height else cfg.height;
    var sized_cfg = cfg;
    sized_cfg.width = init_w;
    sized_cfg.height = init_h;

    self.backend = try impl.init(sized_cfg, &self);
    self.content_scale = if (initial) |ev| ev.content_scale else self.backend.computeContentScale();
    return self;
}

pub fn deinit(self: *const Window) void {
    self.backend.deinit();
}

pub fn startCapture(self: *Window) void {
    self.backend.startCapture(self);
}

pub fn setDropCallback(self: *Window, ctx: *anyopaque, cb: DropCallback) void {
    self.drop_callback = cb;
    self.drop_ctx = ctx;
    self.backend.setDropCallback(self);
}

pub fn pollEvents(self: *const Window) void {
    self.backend.pollEvents();
}

pub fn waitEvents(self: *const Window) void {
    self.backend.waitEvents();
}

pub fn postEmptyEvent(self: *const Window) void {
    self.backend.postEmptyEvent();
}

pub fn isOpen(self: *const Window) bool {
    if (self.should_close) return false;
    return self.backend.isOpen();
}

pub fn close(self: *Window) void {
    self.should_close = true;
    self.backend.close();
}

pub fn getSize(self: *const Window) Size {
    return self.backend.getSize();
}

pub fn getFramebufferSize(self: *const Window) Size {
    return self.backend.getFramebufferSize();
}

pub fn getContentScale(self: *const Window) f32 {
    return self.content_scale;
}

pub fn getWindowHandle(self: *const Window) gpu.Context.WindowHandle {
    return self.backend.getNativeHandle(self.canvas_selector);
}

pub fn setDisplayMode(self: *Window, mode: DisplayMode) void {
    self.backend.setDisplayMode(mode);

    // macOS drops the mouseUp event during window reconfiguration,
    // leaving mouse_button_pressed stuck. Reset to prevent phantom press state.
    if (comptime builtin.os.tag == .macos) {
        self.mouse_button_pressed = false;
    }
}

pub fn setCursorVisible(self: *const Window, visible: bool) void {
    self.backend.setCursorVisible(visible);
}

pub fn collectInput(self: *Window) Input {
    const pos = self.backend.getCursorPos();
    const mouse_down_now = self.mouse_button_pressed;
    const scroll_delta: [2]f32 = .{
        @floatCast(self.scroll[0] * SCROLL_SPEED),
        @floatCast(-self.scroll[1] * SCROLL_SPEED),
    };
    self.scroll = [_]f64{0} ** 2;

    var translated_count: u8 = 0;
    var shift_held = false;
    var ctrl_held = false;
    var super_held = false;

    for (self.key_events[0..self.key_count]) |ev| {
        if (ev.mods.shift) shift_held = true;
        if (ev.mods.ctrl) ctrl_held = true;
        if (ev.mods.super) super_held = true;
        if (ev.action != .press and ev.action != .repeat) continue;
        if (translated_count >= self.key_buf.len) break;

        const key = std.enums.fromInt(Key, ev.key) orelse continue;
        self.key_buf[translated_count] = key;
        translated_count += 1;
    }

    const chars = self.char_buf[0..self.char_count];
    self.char_count = 0;
    self.key_count = 0;
    return .{
        .pos = pos,
        .mouse_down_now = mouse_down_now,
        .scroll_delta = scroll_delta,
        .chars = chars,
        .keys = self.key_buf[0..translated_count],
        .shift_held = shift_held,
        .ctrl_held = ctrl_held,
        .super_held = super_held,
    };
}

pub fn consumeResize(self: *Window) ?ResizeEvent {
    if (comptime builtin.os.tag == .emscripten) {
        const ev = self.pending_resize orelse return null;
        self.pending_resize = null;
        self.backend.applyEmscriptenSize(ev);
        self.content_scale = ev.content_scale;
        return ev;
    }
    if (!self.resized) return null;
    self.resized = false;
    const logical = self.getSize();
    const physical = self.getFramebufferSize();
    self.content_scale = self.backend.computeContentScale();
    return .{ .logical = logical, .physical = physical, .content_scale = self.content_scale };
}

pub fn pushChar(self: *Window, codepoint: u21) void {
    if (self.char_count < self.char_buf.len) {
        self.char_buf[self.char_count] = codepoint;
        self.char_count += 1;
    }
}

pub fn pushKey(self: *Window, key: i32, action: KeyAction, mods: Mods) void {
    if (self.key_count < self.key_events.len) {
        self.key_events[self.key_count] = .{ .key = key, .action = action, .mods = mods };
        self.key_count += 1;
    }
}

pub fn addScroll(self: *Window, dx: f64, dy: f64) void {
    self.scroll[0] += dx;
    self.scroll[1] += dy;
}

pub fn setMouseDown(self: *Window, down: bool) void {
    self.mouse_button_pressed = down;
}

pub fn markResized(self: *Window) void {
    self.resized = true;
}

pub fn markClosed(self: *Window) void {
    self.should_close = true;
}

pub fn setPendingResize(self: *Window, ev: ResizeEvent) void {
    self.pending_resize = ev;
}

pub fn dispatchDrop(self: *Window, paths: []const []const u8) void {
    const cb = self.drop_callback orelse return;
    const ctx = self.drop_ctx orelse return;
    cb(ctx, paths) catch {};
}

pub fn refreshEmscriptenCanvas(self: *Window) void {
    if (comptime builtin.os.tag != .emscripten) return;
    const selector = self.canvas_selector orelse return;
    self.pending_resize = applyCanvasSize(selector, self.backend.getSize().width, self.backend.getSize().height);
}

const EmscriptenExterns = struct {
    extern fn emscripten_get_element_css_size(target: [*:0]const u8, w: *f64, h: *f64) c_int;
    extern fn emscripten_set_element_css_size(target: [*:0]const u8, w: f64, h: f64) c_int;
    extern fn emscripten_set_canvas_element_size(target: [*:0]const u8, w: c_int, h: c_int) c_int;
};

fn applyCanvasSize(selector: [:0]const u8, fallback_w: u32, fallback_h: u32) ResizeEvent {
    var css_w: f64 = 0;
    var css_h: f64 = 0;
    _ = EmscriptenExterns.emscripten_get_element_css_size(selector.ptr, &css_w, &css_h);
    if (css_w <= 0 or css_h <= 0) {
        css_w = @floatFromInt(fallback_w);
        css_h = @floatFromInt(fallback_h);
    }
    const dpr = std.os.emscripten.emscripten_get_device_pixel_ratio();
    const px_w: c_int = @intFromFloat(@round(css_w * dpr));
    const px_h: c_int = @intFromFloat(@round(css_h * dpr));
    _ = EmscriptenExterns.emscripten_set_canvas_element_size(selector.ptr, px_w, px_h);
    // Re-assert CSS size: without this, the higher-resolution drawing buffer
    // gets CSS-scaled by the DOM, producing a blurry result on HiDPI.
    _ = EmscriptenExterns.emscripten_set_element_css_size(selector.ptr, css_w, css_h);
    return .{
        .logical = .{ .width = @intFromFloat(@round(css_w)), .height = @intFromFloat(@round(css_h)) },
        .physical = .{ .width = @intCast(px_w), .height = @intCast(px_h) },
        .content_scale = @floatCast(dpr),
    };
}
