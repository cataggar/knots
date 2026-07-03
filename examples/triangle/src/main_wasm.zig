const std = @import("std");
const zjb = @import("zjb");
const knots = @import("knots");

const Rect = knots.component.Rect;
const Canvas = knots.component.Canvas;

const triangle_width = 480;
const triangle_height = 320;

// The default Zig panic handler needs libc/OS facilities that don't exist
// on wasm32-freestanding; route panics through zjb's instead, which reports
// them to the browser console (and throws, tearing down the wasm instance).
pub const panic = zjb.panic;

fn logStr(msg: zjb.ConstHandle) void {
    zjb.global("console").call("log", .{msg}, void);
}

const Ctx = struct {
    app: knots.App,
    devtools: knots.debug.DevTools,
};

// The wasm module only ever runs one App per page, and it must outlive
// `main()` (constructed later, from `onDeviceReady`'s async callback), so a
// single static instance -- rather than a heap allocation whose pointer
// would need threading through every callback -- is simplest here.
var ctx: Ctx = undefined;

export fn main() void {
    logStr(zjb.constString("[triangle] requesting GPU device..."));
    // WebGPU's requestAdapter()/requestDevice() are Promises, and this
    // single-threaded wasm target can never block waiting on one -- so
    // `App`/`Context` construction happens later, inside `onDeviceReady`,
    // once the device is actually ready. See
    // thoughts/wasm-zjb-backend/plans/implementation-plan.md, Phase 4.
    knots.gpu_webgpu_js.bootstrap.requestDeviceAsync(&onDeviceReady);
}

fn onDeviceReady(_: zjb.Handle, _: zjb.Handle) callconv(.c) void {
    const allocator = std.heap.wasm_allocator;

    const app = knots.App.init(knots.wasm_io.io, allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Triangle",
            .canvas_selector = "#canvas",
        },
    }) catch |err| {
        logStr(zjb.constString("[triangle] App.init failed:"));
        zjb.throwError(err);
    };

    const devtools = knots.debug.DevTools.init(allocator, app.renderer.cfg.gpu_backend, app.renderer.cfg.present_mode) catch |err| {
        logStr(zjb.constString("[triangle] DevTools.init failed:"));
        zjb.throwError(err);
    };

    ctx = .{ .app = app, .devtools = devtools };

    logStr(zjb.constString("[triangle] ready"));
    ctx.app.start(frameCb) catch |err| {
        logStr(zjb.constString("[triangle] App.start failed:"));
        zjb.throwError(err);
    };
}

fn frameCb(app: *knots.App) !void {
    const c: *Ctx = @fieldParentPtr("app", app);
    const size = app.window.getSize();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .fixed(w),
            .height = .fixed(h),
            .@"align" = .center,
            .justify = .center,
        },
        .{Canvas{
            .onDraw = drawTriangle,
            .key = .src(@src()),
            .width = .fixed(triangle_width),
            .height = .fixed(triangle_height),
        }},
    });

    try app.e(.{c.devtools});
}

fn drawTriangle(_: *knots.App, painter: *Canvas.Painter) !void {
    try painter.fillTriangle(.{
        .points = .{
            .{ triangle_width / 2.0, 0.0 },
            .{ triangle_width, triangle_height },
            .{ 0.0, triangle_height },
        },
        .color = .{ 1.0, 0, 0, 1.0 },
    });
}
