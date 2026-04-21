const glfw = @import("glfw");
const gpu = @import("gpu");
const builtin = @import("builtin");
const config = @import("window_config");
const std = @import("std");

const SCROLL_SPEED: comptime_float = 10;

const GLFW_PRESS = 1;
const GLFW_REPEAT = 2;
const GLFW_MOD_SHIFT = 0x0001;
const GLFW_MOD_CTRL = 0x0002;

const EmscriptenUiEvent = extern struct {
    detail: c_long,
    documentBodyClientWidth: c_int,
    documentBodyClientHeight: c_int,
    windowInnerWidth: c_int,
    windowInnerHeight: c_int,
    windowOuterWidth: c_int,
    windowOuterHeight: c_int,
    scrollTop: c_int,
    scrollLeft: c_int,
};
const EmscriptenUiCallback = *const fn (event_type: c_int, ui_event: *const EmscriptenUiEvent, user_data: ?*anyopaque) callconv(.c) c_int;
extern fn emscripten_set_resize_callback_on_thread(target: [*:0]const u8, user_data: ?*anyopaque, use_capture: bool, cb: EmscriptenUiCallback, thread: c_int) c_int;
extern fn emscripten_get_element_css_size(target: [*:0]const u8, w: *f64, h: *f64) c_int;
extern fn emscripten_set_element_css_size(target: [*:0]const u8, w: f64, h: f64) c_int;
extern fn emscripten_set_canvas_element_size(target: [*:0]const u8, w: c_int, h: c_int) c_int;
const EMSCRIPTEN_EVENT_TARGET_WINDOW: [*:0]const u8 = "2";

pub const Key = enum(i32) {
    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,
    world_1 = 161,
    world_2 = 162,
    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,
    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,
    f13 = 302,
    f14 = 303,
    f15 = 304,
    f16 = 305,
    f17 = 306,
    f18 = 307,
    f19 = 308,
    f20 = 309,
    f21 = 310,
    f22 = 311,
    f23 = 312,
    f24 = 313,
    f25 = 314,
    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,
    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,
    _,
};

pub const Config = struct {
    height: u32,
    width: u32,
    title: []const u8,
    resizable: bool = true,
    canvas_selector: ?[:0]const u8 = null,
};

pub const Input = struct {
    pos: [2]f64,
    mouse_down_now: bool,
    scroll_delta: [2]f32,
    chars: []const u21,
    keys: []const Key,
    shift_held: bool,
    ctrl_held: bool,
};

pub const DropCallback = *const fn (ctx: *anyopaque, paths: []const []const u8) anyerror!void;

pub const KeyEvent = struct {
    key: i32,
    action: i32,
    mods: i32,
};

window: glfw.Window,
mouse_button_pressed: bool = false,
scroll: [2]f64,
char_buf: [32]u21 = [_]u21{0} ** 32,
char_count: u8 = 0,
key_events: [16]KeyEvent = undefined,
key_buf: [16]Key = undefined,
key_count: u8 = 0,
resized: bool = false,
is_fullscreen: bool = false,
windowed_pos: [2]c_int = .{ 0, 0 },
windowed_size: [2]c_int = .{ 0, 0 },
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

    const init_w: u32 = if (initial) |ev| ev.logical.width else cfg.width;
    const init_h: u32 = if (initial) |ev| ev.logical.height else cfg.height;

    const window = try glfw.Window.init(.{
        .title = cfg.title,
        .mode = .{ .windowed = .{ .width = init_w, .height = init_h } },
        .resizeable = if (cfg.resizable) glfw.c.GLFW_TRUE else glfw.c.GLFW_FALSE,
    });

    const scale: f32 = if (initial) |ev| ev.content_scale else computeNativeContentScale(window);

    return Window{
        .window = window,
        .scroll = [_]f64{0} ** 2,
        .canvas_selector = cfg.canvas_selector,
        .pending_resize = initial,
        .content_scale = scale,
    };
}

fn computeNativeContentScale(w: glfw.Window) f32 {
    if (comptime builtin.os.tag == .emscripten) return 1.0;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    glfw.c.glfwGetFramebufferSize(w.window, &fb_w, &fb_h);
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    glfw.c.glfwGetWindowSize(w.window, &win_w, &win_h);
    if (win_w <= 0 or win_h <= 0) return 1.0;
    const sx: f32 = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(win_w));
    const sy: f32 = @as(f32, @floatFromInt(fb_h)) / @as(f32, @floatFromInt(win_h));
    return @max(sx, sy);
}

pub fn deinit(self: *const Window) void {
    self.window.deinit();
}

pub fn startCapture(self: *Window) void {
    self.window.setUserPointer(@ptrCast(self));
    self.window.setScrollCallback(scrollCallback);
    self.window.setKeyCallback(keyCallback);
    self.window.setCharCallback(charCallback);
    self.window.setMouseButtonCallback(mouseButtonCallback);
    if (builtin.os.tag == .emscripten) {
        _ = emscripten_set_resize_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(self), false, resizeCallback, 0);
    } else {
        self.window.setFramebufferSizecallback(framebufferSizeCallback);
    }
}

pub fn setDropCallback(self: *Window, ctx: *anyopaque, cb: DropCallback) void {
    self.drop_callback = cb;
    self.drop_ctx = ctx;
    self.window.setDropCallback(dropCallback);
}

pub fn collectInput(self: *Window) Input {
    const pos = self.window.getCursorPos();
    const mouse_down_now = self.mouse_button_pressed;
    const scroll_delta: [2]f32 = .{
        @floatCast(self.scroll[0] * SCROLL_SPEED),
        @floatCast(-self.scroll[1] * SCROLL_SPEED),
    };
    self.scroll = [_]f64{0} ** 2;

    var translated_count: u8 = 0;
    var shift_held = false;
    var ctrl_held = false;

    for (self.key_events[0..self.key_count]) |ev| {
        if (ev.mods & GLFW_MOD_SHIFT != 0) shift_held = true;
        if (ev.mods & GLFW_MOD_CTRL != 0) ctrl_held = true;
        if (ev.action != GLFW_PRESS and ev.action != GLFW_REPEAT) continue;
        if (translated_count >= self.key_buf.len) break;

        const key = std.enums.fromInt(Key, ev.key) orelse continue;
        self.key_buf[translated_count] = key;
        translated_count += 1;
    }

    const chars = self.char_buf[0..self.char_count];
    self.char_count = 0;
    self.key_count = 0;
    return .{
        .pos = .{ pos.x, pos.y },
        .mouse_down_now = mouse_down_now,
        .scroll_delta = scroll_delta,
        .chars = chars,
        .keys = self.key_buf[0..translated_count],
        .shift_held = shift_held,
        .ctrl_held = ctrl_held,
    };
}

pub fn getWindowHandle(self: *const Window) gpu.Context.WindowHandle {
    return switch (builtin.os.tag) {
        .macos => .{ .macos = .{ .ns_window = self.window.getCocoaWindow() } },
        .windows => blk: {
            const handles = self.window.getWin32Window();
            break :blk .{ .windows = .{ .hwnd = handles[0], .hinstance = handles[1] } };
        },
        .linux => blk: {
            switch (config.linux_display_server) {
                .wayland => {
                    const handles = self.window.getWaylandWindow();
                    break :blk .{ .linux = .{ .wayland = .{ .display = handles[0], .surface = handles[1] } } };
                },
                .x11 => {
                    const handles = self.window.getX11Window();
                    break :blk .{ .linux = .{ .x11 = .{ .display = handles[0], .window = handles[1] } } };
                },
            }
        },
        .emscripten => .{ .emscripten = .{ .selector = self.canvas_selector orelse @panic("canvas_selector must be set for emscripten windows") } },
        else => |os| @compileError("unsupported platform: " ++ @tagName(os)),
    };
}

pub fn isOpen(self: *const Window) bool {
    return !self.window.shouldClose();
}

pub fn pollEvents(self: *const Window) void {
    self.window.pollEvents();
}

pub fn waitEvents(self: *const Window) void {
    self.window.waitEvents();
}

pub fn postEmptyEvent(self: *const Window) void {
    self.window.postEmptyEvent();
}

pub fn close(self: *const Window) void {
    self.window.close();
}

pub const Size = struct { width: u32, height: u32 };

pub const ResizeEvent = struct {
    logical: Size,
    physical: Size,
    content_scale: f32,
};

pub fn getSize(self: *const Window) Size {
    return .{ .width = self.window.getWidth(), .height = self.window.getHeight() };
}

pub fn getFramebufferSize(self: *const Window) Size {
    const fb = self.window.getFramebufferSize();
    return .{ .width = @intCast(fb[0]), .height = @intCast(fb[1]) };
}

pub fn getContentScale(self: *const Window) f32 {
    return self.content_scale;
}

pub const DisplayMode = union(enum) {
    windowed: void,
    fullscreen: struct {
        width: i32,
        height: i32,
        refresh_rate: i32,
    },
    fullscreen_windowed: void,
};

pub fn setDisplayMode(self: *Window, mode: DisplayMode) void {
    const win = self.window.window;
    switch (mode) {
        .windowed => {
            glfw.c.glfwRestoreWindow(win);
            switch (builtin.os.tag) {
                inline .macos => {},
                inline else => glfw.c.glfwSetWindowAttrib(win, glfw.c.GLFW_DECORATED, glfw.c.GLFW_TRUE),
            }
            glfw.c.glfwSetWindowMonitor(win, null, self.windowed_pos[0], self.windowed_pos[1], self.windowed_size[0], self.windowed_size[1], 0);
            self.is_fullscreen = false;
        },
        .fullscreen => |fullscreen| {
            self.saveWindowedGeometry(win);
            const monitor = glfw.c.glfwGetPrimaryMonitor() orelse return;
            glfw.c.glfwSetWindowMonitor(win, monitor, 0, 0, fullscreen.width, fullscreen.height, fullscreen.refresh_rate);
            self.is_fullscreen = true;
        },
        .fullscreen_windowed => {
            self.saveWindowedGeometry(win);
            const monitor = glfw.c.glfwGetPrimaryMonitor() orelse return;
            const vid = glfw.c.glfwGetVideoMode(monitor) orelse return;
            switch (builtin.os.tag) {
                inline .macos => glfw.c.glfwSetWindowMonitor(win, monitor, 0, 0, vid.*.width, vid.*.height, vid.*.refreshRate),
                inline .windows => {
                    glfw.c.glfwSetWindowAttrib(win, glfw.c.GLFW_DECORATED, glfw.c.GLFW_FALSE);
                    glfw.c.glfwSetWindowMonitor(win, null, 0, 0, vid.*.width, vid.*.height, 0);
                },
                inline .linux => {
                    glfw.c.glfwSetWindowAttrib(win, glfw.c.GLFW_DECORATED, glfw.c.GLFW_FALSE);
                    glfw.c.glfwMaximizeWindow(win);
                },
                inline else => |os| @compileError("unsupported platform: " ++ @tagName(os)),
            }
            self.is_fullscreen = true;
        },
    }

    // macOS drops the mouseUp event during window reconfiguration,
    // leaving mouse_button_pressed stuck. Reset to prevent phantom press state.
    if (comptime builtin.os.tag == .macos) {
        self.mouse_button_pressed = false;
    }
}

fn saveWindowedGeometry(self: *Window, win: *glfw.c.GLFWwindow) void {
    if (!self.is_fullscreen) {
        glfw.c.glfwGetWindowPos(win, &self.windowed_pos[0], &self.windowed_pos[1]);
        glfw.c.glfwGetWindowSize(win, &self.windowed_size[0], &self.windowed_size[1]);
    }
}

pub fn setCursorVisible(self: *const Window, visible: bool) void {
    self.window.setInputMode(
        glfw.c.GLFW_CURSOR,
        if (visible) glfw.c.GLFW_CURSOR_NORMAL else glfw.c.GLFW_CURSOR_HIDDEN,
    );
}

pub fn consumeResize(self: *Window) ?ResizeEvent {
    if (comptime builtin.os.tag == .emscripten) {
        const ev = self.pending_resize orelse return null;
        self.pending_resize = null;
        glfw.c.glfwSetWindowSize(self.window.window, @intCast(ev.logical.width), @intCast(ev.logical.height));
        self.content_scale = ev.content_scale;
        return ev;
    }
    if (!self.resized) return null;
    self.resized = false;
    const logical = self.getSize();
    const physical = self.getFramebufferSize();
    self.content_scale = computeNativeContentScale(self.window);
    return .{ .logical = logical, .physical = physical, .content_scale = self.content_scale };
}

fn applyCanvasSize(selector: [:0]const u8, fallback_w: u32, fallback_h: u32) ResizeEvent {
    var css_w: f64 = 0;
    var css_h: f64 = 0;
    _ = emscripten_get_element_css_size(selector.ptr, &css_w, &css_h);
    if (css_w <= 0 or css_h <= 0) {
        css_w = @floatFromInt(fallback_w);
        css_h = @floatFromInt(fallback_h);
    }
    const dpr = std.os.emscripten.emscripten_get_device_pixel_ratio();
    const px_w: c_int = @intFromFloat(@round(css_w * dpr));
    const px_h: c_int = @intFromFloat(@round(css_h * dpr));
    _ = emscripten_set_canvas_element_size(selector.ptr, px_w, px_h);
    // Re-assert CSS size: without this, the higher-resolution drawing buffer
    // gets CSS-scaled by the DOM, producing a blurry result on HiDPI.
    _ = emscripten_set_element_css_size(selector.ptr, css_w, css_h);
    return .{
        .logical = .{ .width = @intFromFloat(@round(css_w)), .height = @intFromFloat(@round(css_h)) },
        .physical = .{ .width = @intCast(px_w), .height = @intCast(px_h) },
        .content_scale = @floatCast(dpr),
    };
}

fn resizeCallback(_: c_int, _: *const EmscriptenUiEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const self: *Window = @ptrCast(@alignCast(user_data orelse return 0));
    const selector = self.canvas_selector orelse return 0;
    self.pending_resize = applyCanvasSize(selector, self.window.getWidth(), self.window.getHeight());
    return 1;
}

fn scrollCallback(win: ?*glfw.c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    const ptr: ?*anyopaque = glfw.c.glfwGetWindowUserPointer(win);
    const window: *Window = @ptrCast(@alignCast(ptr orelse return));
    window.scroll = [2]f64{ window.scroll[0] + xoffset, window.scroll[1] + yoffset };
}

fn keyCallback(win: ?*glfw.c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
    const ptr: ?*anyopaque = glfw.c.glfwGetWindowUserPointer(win);
    const window: *Window = @ptrCast(@alignCast(ptr orelse return));
    if (window.key_count < window.key_events.len) {
        window.key_events[window.key_count] = .{ .key = key, .action = action, .mods = mods };
        window.key_count += 1;
    }
}

fn mouseButtonCallback(win: ?*glfw.c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
    if (button != 0) return;
    const ptr: ?*anyopaque = glfw.c.glfwGetWindowUserPointer(win);
    const window: *Window = @ptrCast(@alignCast(ptr orelse return));
    window.mouse_button_pressed = action == GLFW_PRESS;
}

fn framebufferSizeCallback(win: ?*glfw.c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
    const ptr: ?*anyopaque = glfw.c.glfwGetWindowUserPointer(win);
    const window: *Window = @ptrCast(@alignCast(ptr orelse return));
    window.resized = true;
}

fn charCallback(win: ?*glfw.c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const ptr: ?*anyopaque = glfw.c.glfwGetWindowUserPointer(win);
    const window: *Window = @ptrCast(@alignCast(ptr orelse return));
    if (window.char_count < window.char_buf.len) {
        window.char_buf[window.char_count] = @intCast(codepoint);
        window.char_count += 1;
    }
}

fn dropCallback(win: ?*glfw.c.GLFWwindow, count: c_int, raw_paths: [*c]const [*c]const u8) callconv(.c) void {
    const ptr: ?*anyopaque = glfw.c.glfwGetWindowUserPointer(win);
    const window: *Window = @ptrCast(@alignCast(ptr orelse return));
    const cb = window.drop_callback orelse return;
    const n: usize = @intCast(count);
    const paths: [*]const [*:0]const u8 = @ptrCast(raw_paths);
    var slices: [64][]const u8 = undefined;
    const clamped = @min(n, slices.len);
    for (0..clamped) |i| {
        slices[i] = std.mem.sliceTo(paths[i], 0);
    }
    cb(window.drop_ctx orelse return, slices[0..clamped]) catch {};
}
