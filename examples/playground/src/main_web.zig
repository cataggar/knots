const std = @import("std");
const playground = @import("playground");

pub const knots_theme = @import("theme.zon");

export fn main(_: c_int, _: [*][*:0]u8) c_int {
    const allocator = std.heap.c_allocator;

    var threaded_io: std.Io.Threaded = .init_single_threaded;
    defer threaded_io.deinit();

    const io = threaded_io.io();

    const app = allocator.create(playground) catch return -1;
    app.* = playground.init(io, allocator) catch return -1;
    app.start() catch return -1;
    return 0;
}
