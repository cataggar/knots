const App = @import("knots").App;
const ui_mod = @import("ui");
const Color = ui_mod.Color;
const Key = ui_mod.Key;
const Radius = ui_mod.Radius;
const Element = @import("layout").Element;

progress: f32,
width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fixed(8),
track_color: Color.Input = .toned,
fill_color: Color.Input = .primary,
corner_radius: Radius.Input = .{ .fixed = 4 },
key: Key,

const ProgressBar = @This();

pub fn open(self: *const ProgressBar, app: *App) !Element.Id {
    const ui = &app.viewport.ui;
    return try ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
    }, .{ .range = .{
        .progress = self.progress,
        .track_color = self.track_color.resolve(&ui.theme),
        .fill_color = self.fill_color.resolve(&ui.theme),
        .corner_radius = self.corner_radius.resolve(&ui.theme),
    } });
}

pub fn close(_: *const ProgressBar, app: *App) !void {
    app.viewport.ui.close();
}
