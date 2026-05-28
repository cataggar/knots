const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;
const ContextMenu = knots.component.ContextMenu;

const Menu = ContextMenu(ContextActions);

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(app, "Context menu", body);
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(
                arena,
                "last action: {s} on {s}",
                .{ self.demo_state.context_menu_last_action, self.demo_state.context_menu_last_target },
            ),
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(12), .key = .src(@src()) },
    });

    const grid = Rect{
        .width = .grow(),
        .height = .grow(),
        .dir = .grid,
        .gap = 12,
        .padding = .init(8, 8, 8, 8),
        .grid_template = .{
            .cols = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
            .rows = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
        },
        .key = .src(@src()),
    };

    _ = try grid.open(app);
    try card(app, "top-left", "Top left target", "menu.tl", .{ .row = 0, .col = 0 });
    try card(app, "top-right", "Top right target", "menu.tr", .{ .row = 0, .col = 1 });
    try card(app, "bottom-left", "Bottom left target", "menu.bl", .{ .row = 1, .col = 0 });
    try card(app, "bottom-right", "Bottom right target", "menu.br", .{ .row = 1, .col = 1 });
    try grid.close(app);
}

fn card(
    app: *knots.App,
    comptime target: []const u8,
    comptime title: []const u8,
    comptime key_prefix: []const u8,
    placement: Rect.GridPlacement,
) !void {
    return app.e(.{
        Menu{
            .key = .str(key_prefix ++ ".wrap"),
            .menu = ContextActions{
                .target = target,
                .inspect_key = .str(key_prefix ++ ".inspect"),
                .duplicate_key = .str(key_prefix ++ ".duplicate"),
                .archive_key = .str(key_prefix ++ ".archive"),
            },
            .width = .grow(),
            .height = .grow(),
            .dir = .column,
            .grid_placement = placement,
            .menu_width = 168,
        },
        .{
            Rect{
                .width = .grow(),
                .height = .grow(),
                .padding = .init(14, 14, 14, 14),
                .dir = .column,
                .justify = .space_between,
                .key = .str(key_prefix ++ ".card"),
                .style = .{
                    .color = .muted,
                    .corner_radius = .md,
                    .border_width = 1,
                    .border_color = .toned,
                },
            },
            .{
                Text{ .content = title, .size = .md, .selectable = false, .key = .str(key_prefix ++ ".title") },
                Text{ .content = "Right-click inside this area.", .size = .xs, .color = .dimmed, .selectable = false, .key = .str(key_prefix ++ ".hint") },
            },
        },
    });
}

const ContextActions = struct {
    target: []const u8,
    inspect_key: knots.ui.Key,
    duplicate_key: knots.ui.Key,
    archive_key: knots.ui.Key,

    pub fn render(self: *const ContextActions, app: *knots.App) anyerror!void {
        try app.e(.{
            ActionRow{ .target = self.target, .action = "inspect", .label = "Inspect", .key = self.inspect_key },
            ActionRow{ .target = self.target, .action = "duplicate", .label = "Duplicate", .key = self.duplicate_key },
            ActionRow{ .target = self.target, .action = "archive", .label = "Archive", .key = self.archive_key },
        });
    }
};

const ActionRow = struct {
    target: []const u8,
    action: []const u8,
    label: []const u8,
    key: knots.ui.Key,

    pub fn open(self: *const ActionRow, app: *knots.App) !u64 {
        const ui = &app.ui;
        const id = self.key.hash();
        const hovered = ui.hovering(id);

        _ = try ui.open(self.key, .{
            .width = .grow(),
            .height = .fixed(30),
            .padding = .init(0, 10, 0, 10),
            .alignment = .center,
            .interactive = true,
        }, .{ .rect = .{
            .color = (if (hovered) ui.theme.muted else ui.theme.elevated).value,
            .corner_radius = ui.theme.radius.scale(0.5),
        } });

        try app.e(Text{
            .content = self.label,
            .size = .sm,
            .selectable = false,
            .key = self.key.indexed(1),
        });

        return id;
    }

    pub fn close(self: *const ActionRow, app: *knots.App) !void {
        const ui = &app.ui;
        const id = self.key.hash();
        ui.close();

        if (ui.leftClickedWithin(id)) {
            const root: *Self = @fieldParentPtr("app", app);
            root.demo_state.context_menu_last_action = self.action;
            root.demo_state.context_menu_last_target = self.target;
            try app.signal(.redraw);
        }
    }
};
