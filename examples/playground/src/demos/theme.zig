const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Theme = knots.ui.Theme;

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;

const Entry = struct {
    name: []const u8,
    theme: Theme,
};

const entries = [_]Entry{
    .{ .name = "dark", .theme = Theme.dark },
    .{ .name = "light", .theme = Theme.light },
    .{ .name = "custom", .theme = Theme.parseWithBase(Theme.dark, @import("../theme.zon")) },
};

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Theme",
        "Click a swatch to swap the UI theme at runtime. Notice that every panel \u{2014} including the nav and header \u{2014} repaints with the new palette on the next frame, with no rebuild.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .gap = 12,
            .key = .src(@src()),
        },
        .{
            Slot(0).render,
            Slot(1).render,
            Slot(2).render,
        },
    });
}

fn Slot(comptime idx: u32) type {
    return struct {
        pub fn render(app: *knots.App) !void {
            const self: *Self = @fieldParentPtr("app", app);
            const entry = entries[idx];
            const is_active = self.demo_state.theme_idx == idx;

            try app.e(.{
                Button{
                    .width = .fixed(250),
                    .padding = .init(12, 12, 12, 12),
                    .key = .str("theme.swatch:" ++ entry.name),
                    .style = .{
                        .color = .{ .color = entry.theme.elevated },
                        .corner_radius = .md,
                        .border_width = if (is_active) 2 else 1,
                        .border_color = if (is_active)
                            .{ .color = entry.theme.primary }
                        else
                            .{ .color = entry.theme.toned },
                    },
                    .hover_anim = .{},
                    .onClick = onClick,
                },
                .{
                    Rect{
                        .@"align" = .center,
                        .justify = .space_between,
                        .key = .str("theme.button.container:" ++ entry.name),
                        .dir = .column,
                    },
                    .{
                        Text{
                            .content = entry.name,
                            .size = .md,
                            .color = .{ .color = entry.theme.text },
                            .selectable = false,
                            .key = .str("theme.label:" ++ entry.name),
                        },
                        Rect{
                            .width = .grow(),
                            .height = .fixed(20),
                            .dir = .row,
                            .gap = 4,
                            .key = .str("theme.row:" ++ entry.name),
                        },
                        .{
                            chip(entry.theme.primary, "p", entry.name),
                            chip(entry.theme.secondary, "s", entry.name),
                            chip(entry.theme.success, "ok", entry.name),
                            chip(entry.theme.warning, "wa", entry.name),
                            chip(entry.theme.@"error", "er", entry.name),
                            chip(entry.theme.muted, "mu", entry.name),
                        },
                    },
                },
            });
        }

        fn onClick(app: *knots.App) !void {
            const self: *Self = @fieldParentPtr("app", app);
            self.demo_state.theme_idx = idx;
            app.ui.theme = entries[idx].theme;
            try app.signal(.redraw);
        }
    };
}

fn chip(color: knots.ui.Color, comptime tag: []const u8, comptime theme_name: []const u8) Rect {
    return Rect{
        .width = .fixed(20),
        .height = .fixed(20),
        .key = .str("theme.chip:" ++ theme_name ++ ":" ++ tag),
        .style = .{
            .color = .{ .color = color },
            .corner_radius = .sm,
        },
    };
}
