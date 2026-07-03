const std = @import("std");
const zjb = @import("zjb");
const playground = @import("playground");

// The default Zig panic handler needs libc/OS facilities that don't exist
// on wasm32-freestanding; route panics through zjb's instead, which reports
// them to the browser console (and throws, tearing down the wasm instance).
pub const panic = zjb.panic;

// `std.log`'s default `logFn` reaches `std.Options.debug_io`, which defaults
// to `std.Io.Threaded.global_single_threaded` -- and `std.Io.Threaded` can't
// compile at all for wasm32-freestanding (see
// src/window/backend/wasm/io.zig's doc comment). `demos/async_dispatch.zig`
// aside, `demos/form.zig`'s `submit()` calls `std.log.info` directly, so
// this override is required here (not just defensive, unlike
// `examples/triangle`'s copy of this same fix). Mirrors
// `examples/playground/src/main_web.zig`'s `webLog`, routed through `zjb`'s
// `console` instead of `emscripten_log`.
fn webLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = scope;
    const msg = std.fmt.allocPrint(std.heap.wasm_allocator, format, args) catch return;
    defer std.heap.wasm_allocator.free(msg);
    const handle = zjb.string(msg);
    defer handle.release();
    const console = zjb.global("console");
    switch (level) {
        .err => console.call("error", .{handle}, void),
        .warn => console.call("warn", .{handle}, void),
        .info => console.call("info", .{handle}, void),
        .debug => console.call("debug", .{handle}, void),
    }
}

pub const std_options: std.Options = .{ .logFn = webLog };

fn logStr(msg: zjb.ConstHandle) void {
    zjb.global("console").call("log", .{msg}, void);
}

// The wasm module only ever runs one App per page, and it must outlive
// `main()` (constructed later, from `onDeviceReady`'s async callback), so a
// single static instance -- rather than a heap allocation whose pointer
// would need threading through every callback -- is simplest here.
var app: playground = undefined;

export fn main() void {
    logStr(zjb.constString("[playground] requesting GPU device..."));
    // WebGPU's requestAdapter()/requestDevice() are Promises, and this
    // single-threaded wasm target can never block waiting on one -- so
    // `App`/`Context` construction happens later, inside `onDeviceReady`,
    // once the device is actually ready. See
    // thoughts/wasm-zjb-backend/plans/implementation-plan.md, Phase 4.
    playground.knots.gpu_webgpu_js.bootstrap.requestDeviceAsync(&onDeviceReady);
}

fn onDeviceReady(_: zjb.Handle, _: zjb.Handle) callconv(.c) void {
    app = playground.init(playground.knots.wasm_io.io, std.heap.wasm_allocator) catch |err| {
        logStr(zjb.constString("[playground] init failed:"));
        zjb.throwError(err);
    };

    logStr(zjb.constString("[playground] ready"));
    app.start() catch |err| {
        logStr(zjb.constString("[playground] start failed:"));
        zjb.throwError(err);
    };
}
