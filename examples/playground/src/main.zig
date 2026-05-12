const std = @import("std");
const playground = @import("playground");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var app = try playground.init(init.io, init.gpa);
    defer app.deinit();

    try app.start();
}
