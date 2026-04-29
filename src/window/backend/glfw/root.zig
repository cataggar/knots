const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const gpu = @import("gpu");
const config = @import("window_config");
const window = @import("window");

const GLFW_PRESS = glfw.c.GLFW_PRESS;
const GLFW_REPEAT = glfw.c.GLFW_REPEAT;
const GLFW_MOD_SHIFT = glfw.c.GLFW_MOD_SHIFT;
const GLFW_MOD_CTRL = glfw.c.GLFW_MOD_CONTROL;
const GLFW_MOD_SUPER = glfw.c.GLFW_MOD_SUPER;

pub const Backend = struct {
    window: glfw.Window,
    is_fullscreen: bool = false,
    windowed_pos: [2]c_int = .{ 0, 0 },
    windowed_size: [2]c_int = .{ 0, 0 },

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        self.window.deinit();
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        self.window.setUserPointer(@ptrCast(owner));
        self.window.setScrollCallback(scrollCallback);
        self.window.setKeyCallback(keyCallback);
        self.window.setCharCallback(charCallback);
        self.window.setMouseButtonCallback(mouseButtonCallback);
        if (builtin.os.tag == .emscripten) {
            _ = emscripten_set_resize_callback_on_thread(EMSCRIPTEN_EVENT_TARGET_WINDOW, @ptrCast(owner), false, emscriptenResizeCallback, 0);
        } else {
            self.window.setFramebufferSizecallback(framebufferSizeCallback);
            _ = glfw.c.glfwSetWindowRefreshCallback(self.window.window, refreshCallback);
        }
    }

    pub fn setDropCallback(self: *Self, _: *window.Window) void {
        self.window.setDropCallback(dropCallback);
    }

    pub fn pollEvents(self: *const Self) void {
        _ = self;
        glfw.c.glfwPollEvents();
    }

    pub fn waitEvents(self: *const Self) void {
        _ = self;
        glfw.c.glfwWaitEvents();
    }

    pub fn postEmptyEvent(self: *const Self) void {
        _ = self;
        glfw.c.glfwPostEmptyEvent();
    }

    pub fn isOpen(self: *const Self) bool {
        return !self.window.shouldClose();
    }

    pub fn close(self: *const Self) void {
        self.window.close();
    }

    pub fn getSize(self: *const Self) window.Size {
        return .{ .width = self.window.getWidth(), .height = self.window.getHeight() };
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        const fb = self.window.getFramebufferSize();
        return .{ .width = @intCast(fb[0]), .height = @intCast(fb[1]) };
    }

    pub fn computeContentScale(self: *const Self) f32 {
        if (comptime builtin.os.tag == .emscripten) return 1.0;
        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        glfw.c.glfwGetFramebufferSize(self.window.window, &fb_w, &fb_h);
        var win_w: c_int = 0;
        var win_h: c_int = 0;
        glfw.c.glfwGetWindowSize(self.window.window, &win_w, &win_h);
        if (win_w <= 0 or win_h <= 0) return 1.0;
        const sx: f32 = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(win_w));
        const sy: f32 = @as(f32, @floatFromInt(fb_h)) / @as(f32, @floatFromInt(win_h));
        return @max(sx, sy);
    }

    pub fn getCursorPos(self: *const Self) [2]f64 {
        const pos = self.window.getCursorPos();
        return .{ pos.x, pos.y };
    }

    pub fn getNativeHandle(self: *const Self, canvas_selector: ?[:0]const u8) gpu.Context.WindowHandle {
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
            .emscripten => .{ .emscripten = .{ .selector = canvas_selector orelse @panic("canvas_selector must be set for emscripten windows") } },
            else => |os| @compileError("unsupported platform: " ++ @tagName(os)),
        };
    }

    pub fn setCursorVisible(self: *const Self, visible: bool) void {
        self.window.setInputMode(
            glfw.c.GLFW_CURSOR,
            if (visible) glfw.c.GLFW_CURSOR_NORMAL else glfw.c.GLFW_CURSOR_HIDDEN,
        );
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) void {
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
    }

    fn saveWindowedGeometry(self: *Self, win: *glfw.c.GLFWwindow) void {
        if (!self.is_fullscreen) {
            glfw.c.glfwGetWindowPos(win, &self.windowed_pos[0], &self.windowed_pos[1]);
            glfw.c.glfwGetWindowSize(win, &self.windowed_size[0], &self.windowed_size[1]);
        }
    }

    pub fn applyEmscriptenSize(self: *Self, ev: window.ResizeEvent) void {
        glfw.c.glfwSetWindowSize(self.window.window, @intCast(ev.logical.width), @intCast(ev.logical.height));
    }
};

pub fn init(cfg: window.Config) !Backend {
    const w = try glfw.Window.init(.{
        .title = cfg.title,
        .mode = .{ .windowed = .{ .width = cfg.width, .height = cfg.height } },
        .resizeable = if (cfg.resizable) glfw.c.GLFW_TRUE else glfw.c.GLFW_FALSE,
    });
    return .{ .window = w };
}

fn translateAction(action: c_int) window.KeyAction {
    return switch (action) {
        GLFW_PRESS => .press,
        GLFW_REPEAT => .repeat,
        else => .release,
    };
}

fn translateMods(mods: c_int) window.Mods {
    return .{
        .shift = (mods & GLFW_MOD_SHIFT) != 0,
        .ctrl = (mods & GLFW_MOD_CTRL) != 0,
        .super = (mods & GLFW_MOD_SUPER) != 0,
    };
}

fn ownerOf(win: ?*glfw.c.GLFWwindow) ?*window.Window {
    const ptr: ?*anyopaque = glfw.c.glfwGetWindowUserPointer(win);
    return @ptrCast(@alignCast(ptr orelse return null));
}

fn scrollCallback(win: ?*glfw.c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    const owner = ownerOf(win) orelse return;
    owner.addScroll(xoffset, yoffset);
}

fn keyCallback(win: ?*glfw.c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
    const owner = ownerOf(win) orelse return;
    owner.pushKey(@intCast(key), translateAction(action), translateMods(mods));
}

fn mouseButtonCallback(win: ?*glfw.c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
    if (button != 0) return;
    const owner = ownerOf(win) orelse return;
    owner.setMouseDown(action == GLFW_PRESS);
}

fn framebufferSizeCallback(win: ?*glfw.c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
    const owner = ownerOf(win) orelse return;
    owner.markResized();
}

fn refreshCallback(win: ?*glfw.c.GLFWwindow) callconv(.c) void {
    const owner = ownerOf(win) orelse return;
    owner.markResized();
    owner.dispatchRefresh();
}

fn charCallback(win: ?*glfw.c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const owner = ownerOf(win) orelse return;
    owner.pushChar(@intCast(codepoint));
}

fn dropCallback(win: ?*glfw.c.GLFWwindow, count: c_int, raw_paths: [*c]const [*c]const u8) callconv(.c) void {
    const owner = ownerOf(win) orelse return;
    const n: usize = @intCast(count);
    const paths: [*]const [*:0]const u8 = @ptrCast(raw_paths);
    var slices: [64][]const u8 = undefined;
    const clamped = @min(n, slices.len);
    for (0..clamped) |i| {
        slices[i] = std.mem.sliceTo(paths[i], 0);
    }
    owner.dispatchDrop(slices[0..clamped]);
}

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
const EMSCRIPTEN_EVENT_TARGET_WINDOW: [*:0]const u8 = "2";

fn emscriptenResizeCallback(_: c_int, _: *const EmscriptenUiEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const owner: *window.Window = @ptrCast(@alignCast(user_data orelse return 0));
    owner.refreshEmscriptenCanvas();
    return 1;
}
