const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const window = @import("window");
const events = @import("events.zig");
const dom = @import("bindings.zig");

pub const Backend = struct {
    allocator: std.mem.Allocator,
    selector: [:0]const u8,
    canvas: zjb.Handle,
    resize_observer: zjb.Handle,
    paste_catcher: zjb.Handle,
    logical_size: window.Size,
    physical_size: window.Size,
    content_scale: f32,
    pending_resize: ?window.ResizeEvent,
    is_fullscreen: bool = false,
    cursor_visible: bool = true,
    clipboard_text: std.ArrayList(u8) = .empty,
    clipboard_valid: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.resize_observer.call("disconnect", .{}, void);
        self.resize_observer.release();

        self.paste_catcher.call("remove", .{}, void);
        self.paste_catcher.release();

        self.canvas.release();
        self.clipboard_text.deinit(self.allocator);
        events.g_owner = null;
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        events.g_owner = owner;

        const win = zjb.global("window");
        // Keyboard events go on window — canvas-scoped keyboard requires the
        // canvas to have tabindex and be focused, which most host pages don't
        // set up (mirrors the emscripten backend's rationale).
        win.call("addEventListener", .{ zjb.constString("keydown"), zjb.fnHandle("knots_wasm_onKeyDown", &events.onKeyDown) }, void);
        win.call("addEventListener", .{ zjb.constString("keyup"), zjb.fnHandle("knots_wasm_onKeyUp", &events.onKeyUp) }, void);
        win.call("addEventListener", .{ zjb.constString("blur"), zjb.fnHandle("knots_wasm_onBlur", &events.onBlur) }, void);

        self.canvas.call("addEventListener", .{ zjb.constString("mousedown"), zjb.fnHandle("knots_wasm_onMouseDown", &events.onMouseDown) }, void);
        self.canvas.call("addEventListener", .{ zjb.constString("mousemove"), zjb.fnHandle("knots_wasm_onMouseMove", &events.onMouseMove) }, void);
        self.canvas.call("addEventListener", .{ zjb.constString("wheel"), zjb.fnHandle("knots_wasm_onWheel", &events.onWheel) }, void);
        self.canvas.call("addEventListener", .{ zjb.constString("contextmenu"), zjb.fnHandle("knots_wasm_onContextMenu", &events.onContextMenu) }, void);
        // Also listen for mouseup on the canvas and on document, so a drag
        // released outside the canvas still fires mouseup.
        self.canvas.call("addEventListener", .{ zjb.constString("mouseup"), zjb.fnHandle("knots_wasm_onMouseUp", &events.onMouseUp) }, void);
        zjb.global("document").call("addEventListener", .{ zjb.constString("mouseup"), zjb.fnHandle("knots_wasm_onMouseUp", &events.onMouseUp) }, void);

        self.resize_observer.call("observe", .{self.canvas}, void);
        self.paste_catcher.call("addEventListener", .{ zjb.constString("paste"), zjb.fnHandle("knots_wasm_onPaste", &events.onPaste) }, void);
    }

    pub fn preparePaste(self: *Self) void {
        self.paste_catcher.call("focus", .{}, void);
        self.paste_catcher.call("select", .{}, void);
    }

    pub fn pollEvents(_: *const Self, _: std.Io) void {}
    pub fn waitEvents(_: *const Self, _: std.Io) void {}
    pub fn postEmptyEvent(_: *const Self) void {}

    /// Installs a `requestAnimationFrame`-driven main loop, the browser
    /// equivalent of `emscripten_set_main_loop_arg`. `cb` is re-scheduled
    /// from within itself, so the loop keeps running (capped to the
    /// display refresh rate) until the page is torn down.
    pub fn setMainLoop(_: *Self, cb: *const fn (?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void {
        raf_cb = cb;
        raf_user_data = user_data;
        requestNextFrame();
    }

    pub fn isOpen(_: *const Self) bool {
        return true;
    }

    pub fn close(_: *const Self) void {}

    pub fn getSize(self: *const Self) window.Size {
        return self.logical_size;
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        return self.physical_size;
    }

    pub fn computeContentScale(self: *const Self) f32 {
        return self.content_scale;
    }

    pub fn getCursorPos(_: *const Self) [2]f64 {
        return .{ 0, 0 };
    }

    pub fn getNativeHandle(_: *const Self, canvas_selector: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .wasm = .{ .selector = canvas_selector orelse @panic("canvas_selector must be set for wasm windows") } };
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        if (self.cursor_visible == visible) return;
        self.cursor_visible = visible;
        const style = self.canvas.get("style", zjb.Handle);
        defer style.release();
        style.set("cursor", if (visible) zjb.constString("auto") else zjb.constString("none"));
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) void {
        switch (mode) {
            .windowed => {
                if (self.is_fullscreen) zjb.global("document").call("exitFullscreen", .{}, void);
                self.is_fullscreen = false;
            },
            .fullscreen, .fullscreen_windowed => {
                // The browser ignores requested width/height/refresh_rate and always uses monitor resolution.
                self.canvas.call("requestFullscreen", .{}, void);
                self.is_fullscreen = true;
            },
        }
    }

    pub fn refreshCanvas(self: *Self) void {
        const cs = dom.applyCanvasSize(self.canvas, self.logical_size.width, self.logical_size.height);
        const ev: window.ResizeEvent = .{
            .logical = .{ .width = cs.logical_w, .height = cs.logical_h },
            .physical = .{ .width = cs.physical_w, .height = cs.physical_h },
            .content_scale = cs.content_scale,
        };
        self.logical_size = ev.logical;
        self.physical_size = ev.physical;
        self.content_scale = ev.content_scale;
        self.pending_resize = ev;
    }

    pub fn consumeResize(self: *Self, _: *window.Window) ?window.ResizeEvent {
        const ev = self.pending_resize orelse return null;
        self.pending_resize = null;
        return ev;
    }

    pub fn consumeDrops(_: *Self, _: *window.Window, _: std.mem.Allocator, _: usize) ![][]const u8 {
        return &[_][]const u8{};
    }

    pub fn getClipboardText(self: *Self, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.clipboard_valid) return null;
        self.clipboard_valid = false;
        defer self.clipboard_text.clearRetainingCapacity();
        return try allocator.dupe(u8, self.clipboard_text.items);
    }

    pub fn setClipboardText(_: *Self, _: std.mem.Allocator, text: []const u8) !bool {
        // Best-effort, fire-and-forget: navigator.clipboard.writeText() is
        // Promise-based and this API is synchronous, so the result isn't
        // observed. Requires a secure context (HTTPS/localhost); silently
        // does nothing otherwise.
        const clipboard = zjb.global("navigator").get("clipboard", zjb.Handle);
        defer clipboard.release();
        if (clipboard.isNull()) return false;

        const s = zjb.string(text);
        defer s.release();
        const promise = clipboard.call("writeText", .{s}, zjb.Handle);
        promise.release();
        return true;
    }
};

pub fn init(_: std.Io, allocator: std.mem.Allocator, cfg: window.Config) !Backend {
    const selector = cfg.canvas_selector orelse @panic("canvas_selector must be set for wasm windows");

    const document = zjb.global("document");

    const sel_handle = zjb.string(selector);
    const canvas = document.call("querySelector", .{sel_handle}, zjb.Handle);
    sel_handle.release();
    if (canvas.isNull()) @panic("canvas element not found for the given canvas_selector");

    const cs = dom.applyCanvasSize(canvas, cfg.width, cfg.height);
    const ev: window.ResizeEvent = .{
        .logical = .{ .width = cs.logical_w, .height = cs.logical_h },
        .physical = .{ .width = cs.physical_w, .height = cs.physical_h },
        .content_scale = cs.content_scale,
    };

    const resize_observer = zjb.global("ResizeObserver").new(.{zjb.fnHandle("knots_wasm_onCanvasResize", &events.onCanvasResize)});

    // Hidden, always-present textarea used to capture native 'paste' events
    // (clipboardData is only available synchronously inside a real paste
    // event, so this mirrors the emscripten backend's approach without
    // needing the async Clipboard API for reads).
    const catcher = document.call("createElement", .{zjb.constString("textarea")}, zjb.Handle);
    catcher.call("setAttribute", .{ zjb.constString("readonly"), zjb.constString("") }, void);
    catcher.call("setAttribute", .{ zjb.constString("aria-hidden"), zjb.constString("true") }, void);
    {
        const style = catcher.get("style", zjb.Handle);
        defer style.release();
        style.set("position", zjb.constString("fixed"));
        style.set("left", zjb.constString("-10000px"));
        style.set("top", zjb.constString("0"));
        style.set("width", zjb.constString("1px"));
        style.set("height", zjb.constString("1px"));
        style.set("opacity", zjb.constString("0"));
    }
    {
        const body = document.get("body", zjb.Handle);
        defer body.release();
        body.call("appendChild", .{catcher}, void);
    }

    return .{
        .allocator = allocator,
        .selector = selector,
        .canvas = canvas,
        .resize_observer = resize_observer,
        .paste_catcher = catcher,
        .logical_size = ev.logical,
        .physical_size = ev.physical,
        .content_scale = ev.content_scale,
        .pending_resize = ev,
    };
}

var raf_cb: ?*const fn (?*anyopaque) callconv(.c) void = null;
var raf_user_data: ?*anyopaque = null;

fn rafTick(_: f64) callconv(.c) void {
    if (raf_cb) |cb| cb(raf_user_data);
    requestNextFrame();
}

fn requestNextFrame() void {
    zjb.global("window").call("requestAnimationFrame", .{zjb.fnHandle("knots_wasm_rafTick", &rafTick)}, void);
}
