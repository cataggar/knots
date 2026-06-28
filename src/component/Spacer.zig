const App = @import("knots").App;
const Key = @import("ui").Key;
const Element = @import("layout").Element;

width: Element.sizing.Axis = .fixed(0),
height: Element.sizing.Axis = .fixed(0),
key: Key,

const Spacer = @This();

pub fn open(self: *const Spacer, app: *App) !Element.Id {
    return try app.viewport.ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
    }, .none);
}

pub fn close(_: *const Spacer, app: *App) !void {
    app.viewport.ui.close();
}
