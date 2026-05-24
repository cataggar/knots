const std = @import("std");

const App = @import("knots").App;
const ui_mod = @import("ui");
const Color = ui_mod.Color;
const Key = ui_mod.Key;
const Element = @import("layout").Element;

progress: f32,
width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fixed(8),
track_color: Color.Input = .toned,
fill_color: Color.Input = .primary,
corner_radius: f32 = 4,
key: Key,

const ProgressBar = @This();

pub fn open(self: *const ProgressBar, app: *App) !Element.Id {
    const ui = &app.ui;
    return try ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
    }, .{ .progress_bar = .{
        .progress = std.math.clamp(self.progress, 0.0, 1.0),
        .track_color = self.track_color.resolve(&ui.theme),
        .fill_color = self.fill_color.resolve(&ui.theme),
        .corner_radius = self.corner_radius,
    } });
}

pub fn close(_: *const ProgressBar, app: *App) !void {
    app.ui.close();
}
