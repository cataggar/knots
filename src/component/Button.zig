const std = @import("std");

const UI = @import("ui").UI;
const Style = @import("ui").Style;
const Element = @import("layout").Element;
const App = @import("knots").App;

@"align": Element.Align = .start,
justify: Element.Justify = .start,
width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
padding: Element.Padding = .init(0, 0, 0, 0),
style: Style = .{ .color = .primary },
hover_style: ?Style.Override = null,
key: UI.Key,
onClick: ?*const fn (*App) anyerror!void = null,
onHover: ?*const fn (*App) anyerror!void = null,

const Button = @This();

pub fn open(self: *const Button, ui: *UI) !Element.Id {
    const id = self.key.hash();
    const is_hovered = ui.hovering(id);

    const resolved = if (is_hovered)
        if (self.hover_style) |hs| self.style.merge(hs) else self.style
    else
        self.style;

    var deco_rect = resolved.toRect();
    if (is_hovered and self.hover_style == null) {
        const f = 0.15;
        deco_rect.color = .{
            deco_rect.color[0] + (1.0 - deco_rect.color[0]) * f,
            deco_rect.color[1] + (1.0 - deco_rect.color[1]) * f,
            deco_rect.color[2] + (1.0 - deco_rect.color[2]) * f,
            deco_rect.color[3],
        };
    }

    const rect = try ui.open(self.key, .{
        .alignment = self.@"align",
        .justify = self.justify,
        .width = self.width,
        .height = self.height,
        .padding = self.padding,
        .interactive = true,
    }, .{ .rect = deco_rect });

    if (self.onClick) |cb|
        if (ui.clicked(rect))
            try cb(@alignCast(@fieldParentPtr("ui", ui)));

    if (self.onHover) |cb|
        if (is_hovered)
            try cb(@alignCast(@fieldParentPtr("ui", ui)));

    return rect;
}

pub fn close(_: *const Button, ui: *UI) !void {
    ui.close();
}
