const std = @import("std");

const Window = @import("window").Window;
const render = @import("render");
const UI = @import("ui").UI;

const App = @import("App.zig");
const Timer = @import("Timer.zig");

pub const Id = enum(u32) {
    main = 0,
    _,
};

pub const Config = struct {
    ui: UI.Config,
    timer_clock: std.Io.Clock,
};

const Viewport = @This();

app: ?*App = null,
id: Id,
window: Window,
ui: UI,
renderer: render.Renderer,
timer: Timer,
ui_cfg: UI.Config,
frame_cb: ?App.Callback = null,
pending_renderer_cfg: ?render.Renderer.Config = null,
pending_reconfigure: bool = false,
renderer_reconfigure_error: ?render.Renderer.ReconfigureError = null,
frame_active: bool = false,
frame_pending: bool = false,

pub fn init(allocator: std.mem.Allocator, id: Id, window_value: Window, renderer: render.Renderer, cfg: Config) !Viewport {
    var ui: UI = try .init(allocator, cfg.ui);
    errdefer ui.deinit();

    return .{
        .id = id,
        .window = window_value,
        .ui = ui,
        .renderer = renderer,
        .timer = .init(cfg.timer_clock),
        .ui_cfg = cfg.ui,
    };
}

pub fn deinit(self: *Viewport) void {
    self.window.clearFrameHandler();
    self.ui.deinit();
    self.renderer.deinit();
    self.window.deinit();
}
