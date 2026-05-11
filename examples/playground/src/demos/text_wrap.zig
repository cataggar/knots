const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const TextInput = knots.component.TextInput;
const Spacer = knots.component.Spacer;

const lorem =
    "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. " ++
    "How vexingly quick daft zebras jump! Sphinx of black quartz, judge my vow. " ++
    "Two driven jocks help fax my big quiz.";

const with_newlines =
    "First line is short.\n" ++
    "Second line is a bit longer and may still fit, depending on width.\n" ++
    "\n" ++
    "Empty line above. The greedy wrapper breaks on spaces and hard newlines, " ++
    "and falls back to mid-word breaks for runs longer than the wrap width.";

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Text wrap",
        "wrap=true opts text into greedy word-wrapping. Width comes from the element's own assigned box.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .dir = .column,
            .gap = 16,
            .key = .src(@src()),
        },
        .{
            fixedWidthSection,
            growWidthSection,
            newlinesSection,
            multiLineInputSection,
        },
    });
}

fn caption(app: *knots.App, comptime label: []const u8, key: knots.ui.Key) !void {
    try app.e(Text{
        .content = label,
        .size = .xs,
        .color = .dimmed,
        .key = key,
    });
}

fn fixedWidthSection(app: *knots.App) !void {
    try caption(app, "fixed(220) container, text wraps inside a narrow column", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .height = .fit(),
            .padding = .init(10, 10, 10, 10),
            .style = .{ .color = .muted, .corner_radius = .sm },
            .key = .src(@src()),
        },
        .{Text{
            .content = lorem,
            .wrap = true,
            .width = .grow(),
            .key = .src(@src()),
        }},
    });
}

fn growWidthSection(app: *knots.App) !void {
    try caption(app, "grow() in a row, text reflows when the window resizes", .src(@src()));
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .dir = .row,
            .gap = 12,
            .key = .src(@src()),
        },
        .{
            Rect{
                .width = .grow(),
                .height = .fit(),
                .padding = .init(10, 10, 10, 10),
                .style = .{ .color = .muted, .corner_radius = .sm },
                .key = .src(@src()),
            },
            Rect{
                .width = .fixed(120),
                .height = .fit(),
                .padding = .init(10, 10, 10, 10),
                .style = .{ .color = .accented, .corner_radius = .sm },
                .key = .src(@src()),
            },
        },
    });

    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .dir = .row,
            .gap = 12,
            .key = .src(@src()),
        },
        .{
            growParagraph,
            Rect{
                .width = .fixed(120),
                .height = .fixed(60),
                .style = .{ .color = .accented, .corner_radius = .sm },
                .key = .src(@src()),
            },
        },
    });
}

fn growParagraph(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(10, 10, 10, 10),
            .style = .{ .color = .muted, .corner_radius = .sm },
            .key = .src(@src()),
        },
        .{Text{
            .content = lorem,
            .wrap = true,
            .width = .grow(),
            .key = .src(@src()),
        }},
    });
}

fn newlinesSection(app: *knots.App) !void {
    try caption(app, "hard \\n breaks combined with soft wrap", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(320),
            .height = .fit(),
            .padding = .init(10, 10, 10, 10),
            .style = .{ .color = .muted, .corner_radius = .sm },
            .key = .src(@src()),
        },
        .{Text{
            .content = with_newlines,
            .wrap = true,
            .width = .grow(),
            .key = .src(@src()),
        }},
    });
}

fn multiLineInputSection(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try caption(app, "TextInput with wrap=true, enter inserts a newline, arrow up/down navigate lines", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(360),
            .height = .fit(),
            .padding = .init(8, 8, 8, 8),
            .style = .{ .color = .muted, .corner_radius = .sm },
            .key = .src(@src()),
        },
        .{TextInput{
            .key = .src(@src()),
            .buf = &self.demo_state.notes_buf,
            .wrap = true,
            .placeholder = "type a multi-line note...",
            .width = .grow(),
        }},
    });
}
