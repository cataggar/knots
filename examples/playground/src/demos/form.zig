const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const TextInput = knots.component.TextInput;
const SelectInput = knots.component.SelectInput;
const SliderInput = knots.component.SliderInput;
const ColorPicker = knots.component.ColorPicker;
const Checkbox = knots.component.Checkbox;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const Dialog = knots.component.Dialog;

const Role = enum { admin, editor, viewer, guest };

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(app, "Form", body);
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Rect{
            .width = .fixed(420),
            .dir = .column,
            .gap = 12,
            .key = .src(@src()),
        },
        .{
            emailField,
            passwordField,
            roleField,
            notificationsField,
            volumeField,
            colorField,
            Spacer{ .height = .fixed(4), .key = .src(@src()) },
            Button{
                .width = .fixed(120),
                .height = .fixed(34),
                .style = .{ .color = .{ .color = self.demo_state.form_color }, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = openConfirm,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "submit" },
            },
            Text{
                .content = try std.fmt.allocPrint(arena, "current volume: {d:.0}%", .{self.demo_state.form_volume * 100}),
                .size = .xs,
                .color = .dimmed,
                .key = .src(@src()),
            },
        },
        Dialog{
            .is_open = &self.demo_state.form_confirm_open,
            .key = .src(@src()),
            .width = .fixed(320),
            .gap = 16,
        },
        .{
            Text{
                .content = "Are you sure?",
                .size = .lg,
                .key = .src(@src()),
            },
            Rect{
                .width = .grow(),
                .dir = .row,
                .gap = 8,
                .justify = .end,
                .key = .src(@src()),
            },
            .{
                Button{
                    .width = .fixed(80),
                    .height = .fixed(32),
                    .style = .{ .color = .success, .corner_radius = .sm },
                    .hover_anim = .{},
                    .key = .src(@src()),
                    .onClick = submit,
                    .justify = .center,
                    .@"align" = .center,
                    .text = .{ .content = "Yes", .color = .on_success },
                },
                Button{
                    .width = .fixed(80),
                    .height = .fixed(32),
                    .style = .{ .color = .@"error", .corner_radius = .sm },
                    .key = .src(@src()),
                    .onClick = closeConfirm,
                    .justify = .center,
                    .@"align" = .center,
                    .text = .{ .content = "Cancel", .color = .on_error },
                },
            },
        },
    });
}

fn labeled(app: *knots.App, comptime label: []const u8, body_fn: *const fn (*knots.App) anyerror!void) !void {
    try app.e(.{
        Rect{ .width = .grow(), .dir = .column, .gap = 2, .key = .str("form.field:" ++ label) },
        .{Text{ .content = label, .size = .xs, .color = .dimmed, .key = .str("form.label:" ++ label) }},
    });
    try body_fn(app);
}

fn emailField(app: *knots.App) !void {
    try labeled(app, "email", emailInput);
}

fn emailInput(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &self.demo_state.form_email,
        .placeholder = "you@example.com",
    });
}

fn passwordField(app: *knots.App) !void {
    try labeled(app, "password", passwordInput);
}

fn passwordInput(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(TextInput{
        .key = .src(@src()),
        .buf = &self.demo_state.form_password,
        .placeholder = "...",
    });
}

fn roleField(app: *knots.App) !void {
    try labeled(app, "role", roleInput);
}

fn roleInput(app: *knots.App) !void {
    try app.e(SelectInput(Role){ .key = .src(@src()), .onSelect = onRoleSelect });
}

fn notificationsField(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(Checkbox{
        .key = .src(@src()),
        .checked = &self.demo_state.form_notifications_enabled,
        .label = "send notifications",
    });
}

fn volumeField(app: *knots.App) !void {
    try labeled(app, "notification volume", volumeInput);
}

fn volumeInput(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(.{
        Rect{ .width = .grow(), .height = .fixed(20), .padding = .init(8, 0, 8, 0), .key = .src(@src()) },
        .{
            SliderInput{
                .key = .src(@src()),
                .value = &self.demo_state.form_volume,
                .steps = 0.02,
            },
        },
    });
}

fn colorField(app: *knots.App) !void {
    try labeled(app, "accent color", colorInput);
}

fn colorInput(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(ColorPicker{
        .key = .src(@src()),
        .value = &self.demo_state.form_color,
    });
}

fn openConfirm(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.form_confirm_open = true;
    try app.signal(.redraw);
}

fn closeConfirm(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.form_confirm_open = false;
    try app.signal(.redraw);
}

fn submit(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    std.log.info(
        "form submit -> email='{s}' password='{s}' role={d} notifications={} volume={d:.2}",
        .{
            self.demo_state.form_email.items,
            self.demo_state.form_password.items,
            self.demo_state.form_role,
            self.demo_state.form_notifications_enabled,
            self.demo_state.form_volume,
        },
    );
    self.demo_state.form_confirm_open = false;
    try app.signal(.redraw);
}

fn onRoleSelect(app: *knots.App, _: Role, idx: u32) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.form_role = idx;
}
