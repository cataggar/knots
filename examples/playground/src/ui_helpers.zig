const knots = @import("knots");
const Rect = knots.component.Rect;

pub fn panel(
    app: *knots.App,
    comptime title: []const u8,
    body: *const fn (*knots.App) anyerror!void,
) !void {
    const wrap = Rect{
        .width = .grow(),
        .height = .grow(),
        .padding = .init(16, 16, 16, 16),
        .dir = .column,
        .overflow = .scroll,
        .key = .str("panel:" ++ title),
        .style = .{
            .color = .elevated,
            .corner_radius = .lg,
            .border_width = 1,
            .border_color = .toned,
        },
    };
    _ = try wrap.open(app);
    try body(app);
    try wrap.close(app);
}
