const std = @import("std");
const zjb = @import("zjb");

/// `now`'s replacement for `.real`: wall-clock milliseconds since the Unix
/// epoch, matching `Clock.real`'s documented semantics. Every other `Clock`
/// variant uses `performance.now()`, which is monotonic (unaffected by
/// system clock adjustments) and higher-resolution, matching `.awake`/`.boot`.
fn wasmNow(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    const ms: f64 = switch (clock) {
        .real => zjb.global("Date").call("now", .{}, f64),
        else => zjb.global("performance").call("now", .{}, f64),
    };
    return .{ .nanoseconds = @intFromFloat(ms * @as(f64, std.time.ns_per_ms)) };
}

/// `std.Io.failing` already simulates "a system supporting no Io operations"
/// (concurrency unavailable, no filesystem/network/entropy) -- exactly right
/// for wasm32-freestanding, since none of knots' App/Renderer/Window/Text/UI
/// code paths touch those. `App`'s frame `Timer` is the one genuine
/// dependency on a working clock, so `now` is the only field overridden here.
const vtable: std.Io.VTable = blk: {
    var v = std.Io.failing.vtable.*;
    v.now = &wasmNow;
    break :blk v;
};

pub const io: std.Io = .{ .userdata = null, .vtable = &vtable };
