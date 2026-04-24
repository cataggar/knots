const std = @import("std");
const knots = @import("knots");
const App = knots.App;
const ui = knots.ui;
const Element = @import("layout").Element;

const anim = ui.animation;

pub fn Animated(comptime T: type) type {
    const count: usize = switch (@typeInfo(T)) {
        .float => 1,
        .array => |a| a.len,
        else => @compileError("T must be a float or fixed-size float array, got " ++ @typeName(T)),
    };

    const channels: [count][]const u8 = blk: {
        var out: [count][]const u8 = undefined;
        switch (@typeInfo(T)) {
            .float => out[0] = "value",
            .array => for (0..count) |i| {
                out[i] = std.fmt.comptimePrint("value.{d}", .{i});
            },
            else => unreachable,
        }
        break :blk out;
    };

    return struct {
        key: ui.Key,
        target: T,
        duration_ms: u32 = 200,
        ease: anim.Ease = .smooth_step,

        const Self = @This();

        pub fn read(self: *const Self, app: *App) T {
            const id = self.key.hash();
            const opts: ui.UI.AnimOpts = .{ .duration_ms = self.duration_ms, .ease = self.ease };
            switch (@typeInfo(T)) {
                .float => return app.ui.anim(id, channels[0], self.target, opts),
                .array => |a| {
                    var out: T = undefined;
                    for (0..a.len) |i| out[i] = app.ui.anim(id, channels[i], self.target[i], opts);
                    return out;
                },
                else => unreachable,
            }
        }
    };
}

pub const Measure = struct {
    key: ui.Key,
    width: Element.sizing.Axis = .fit(),
    height: Element.sizing.Axis = .fit(),
    child: *const fn (*App) anyerror!void,

    pub fn eval(self: *const Measure, app: *App) !void {
        _ = try app.ui.state.getOrCreate(.measured, app.ui.allocator, self.key.hash());
        _ = try app.ui.open(self.key, .{
            .width = self.width,
            .height = self.height,
        }, .none);
        try self.child(app);
        app.ui.close();
    }

    pub fn readWidth(self: *const Measure, app: *App) f32 {
        const s = app.ui.state.get(.measured, self.key.hash()) orelse return 0;
        return s.width;
    }

    pub fn readHeight(self: *const Measure, app: *App) f32 {
        const s = app.ui.state.get(.measured, self.key.hash()) orelse return 0;
        return s.height;
    }
};

pub const Clip = struct {
    key: ui.Key,
    width: Element.sizing.Axis = .grow(),
    height: Element.sizing.Axis = .grow(),
    dir: Element.Direction = .column,
    child: *const fn (*App) anyerror!void,

    pub fn eval(self: *const Clip, app: *App) !void {
        _ = try app.ui.open(self.key, .{
            .width = self.width,
            .height = self.height,
            .direction = self.dir,
            .overflow = .hidden,
        }, .none);
        try self.child(app);
        app.ui.close();
    }
};

pub const When = struct {
    active: bool,
    value: f32,
    visible: *const fn (f32) bool,
    then: *const fn (*App) anyerror!void,

    pub fn eval(self: *const When, app: *App) !void {
        if (self.active or self.visible(self.value)) try self.then(app);
    }
};
