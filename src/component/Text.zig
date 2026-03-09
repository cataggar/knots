const UI = @import("ui").UI;
const Theme = @import("ui").Theme;
const Element = @import("layout").Element;

width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
size: f32 = 14,
content: []const u8,
color: Theme.Color = .text,
font: ?[]const u8 = null,
key: UI.Key,

const Text = @This();

pub fn open(self: *const Text, ui: *UI) !Element.Id {
    var decoration = try ui.textDecoration(self.content, self.size, self.font);
    decoration.text.color = self.color.resolve();
    return try ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
    }, decoration);
}

pub fn close(_: *const Text, ui: *UI) !void {
    ui.close();
}
