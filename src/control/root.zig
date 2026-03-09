const App = @import("knots").App;

pub const If = struct {
    when: bool,
    then: *const fn (*App) anyerror!void,
    @"else": ?*const fn (*App) anyerror!void = null,

    const Self = @This();

    pub fn eval(self: *const Self, app: *App) !void {
        if (self.when)
            try self.then(app)
        else if (self.@"else") |fb|
            try fb(app);
    }
};

pub fn For(comptime T: type) type {
    return struct {
        items: []const T,
        each: *const fn (*App, T, usize) anyerror!void,

        const Self = @This();

        pub fn eval(self: *const Self, app: *App) !void {
            for (self.items, 0..) |item, i| try self.each(app, item, i);
        }
    };
}
