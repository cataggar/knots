const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");
const bootstrap = @import("bootstrap.zig");
const Buffer = @import("Buffer.zig");
const Frame = @import("Frame.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Context = @This();

allocator: std.mem.Allocator,
adapter: zjb.Handle,
device: zjb.Handle,
queue: zjb.Handle,
canvas_context: zjb.Handle,
surface_format: gpu.Texture.Format,
surface_width: u32,
surface_height: u32,

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !gpu.Context {
    const selector = switch (window_handle) {
        .wasm => |w| w.selector,
        else => @panic("webgpu_js backend requires a .wasm WindowHandle"),
    };

    const device = bootstrap.resolved_device orelse
        @panic("webgpu_js Context.init called before the GPU device was ready -- bootstrap.requestDeviceAsync's callback must construct the App, not the wasm entry point's main()");
    const adapter = bootstrap.resolved_adapter.?;

    const sel_handle = zjb.string(selector);
    defer sel_handle.release();
    const canvas = zjb.global("document").call("querySelector", .{sel_handle}, zjb.Handle);
    defer canvas.release();
    if (canvas.isNull()) @panic("canvas element not found for the given canvas_selector");

    const canvas_context = canvas.call("getContext", .{zjb.constString("webgpu")}, zjb.Handle);
    if (canvas_context.isNull()) @panic("canvas.getContext(\"webgpu\") returned null -- this browser doesn't support WebGPU");

    var format_buf: [32]u8 = undefined;
    const format_handle = zjb.global("navigator").get("gpu", zjb.Handle).call("getPreferredCanvasFormat", .{}, zjb.Handle);
    defer format_handle.release();
    const format_str = readJsStringUtf8(format_handle, &format_buf);
    const surface_format = js.formatFromCanvasFormatStr(format_str);

    const config = js.obj();
    defer config.release();
    config.set("device", device);
    config.set("format", js.textureFormatStr(surface_format));
    config.set("alphaMode", zjb.constString("opaque"));
    canvas_context.call("configure", .{config}, void);

    const queue = device.get("queue", zjb.Handle);

    const self = try allocator.create(Context);
    self.* = .{
        .allocator = allocator,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .canvas_context = canvas_context,
        .surface_format = surface_format,
        .surface_width = cfg.window_width,
        .surface_height = cfg.window_height,
    };

    return .{ .ptr = self, .vtable = &vtable, .cfg = cfg };
}

const vtable = gpu.Context.VTable{
    .deinit = &deinit,
    .createBuffer = &createBuffer,
    .createFrame = &createFrame,
    .createPipeline = &createPipeline,
    .createBindGroup = &createBindGroup,
    .createTexture = &createTexture,
    .createSampler = &createSampler,
    .resize = &resize,
    .surfaceFormat = &surfaceFormat,
    .surfaceIsSrgb = &surfaceIsSrgb,
    .clipSpaceYDown = &clipSpaceYDown,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Context = @ptrCast(@alignCast(ptr));
    self.queue.release();
    self.canvas_context.release();
    // The device/adapter handles came from `bootstrap` and are intentionally
    // never released -- there is exactly one GPU device for the lifetime of
    // the page, matching the single-App-per-page model this backend targets.
    self.allocator.destroy(self);
}

fn createBuffer(ptr: *anyopaque, size: usize, usage: gpu.Buffer.Usage) anyerror!gpu.Buffer {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return Buffer.create(self.allocator, self.device, self.queue, size, usage);
}

fn createFrame(ptr: *anyopaque) anyerror!gpu.Frame {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return Frame.create(self.allocator, self);
}

fn createPipeline(ptr: *anyopaque, desc: gpu.Pipeline.Desc) anyerror!gpu.Pipeline {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return Pipeline.create(self.allocator, self, desc);
}

fn createBindGroup(ptr: *anyopaque, desc: gpu.BindGroup.Desc) anyerror!gpu.BindGroup {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return BindGroup.create(self.allocator, self.device, desc);
}

fn createTexture(ptr: *anyopaque, desc: gpu.Texture.Desc) anyerror!gpu.Texture {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return Texture.create(self.allocator, self.device, self.queue, desc);
}

fn createSampler(ptr: *anyopaque, desc: gpu.Sampler.Desc) anyerror!gpu.Sampler {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return Sampler.create(self.allocator, self.device, desc);
}

/// A no-op: the canvas's *drawing buffer* size (which is what
/// `getCurrentTexture()` actually sizes itself against) is already updated
/// directly on the `<canvas>` element by the wasm window backend
/// (`bindings.applyCanvasSize`) whenever the window resizes, and WebGPU
/// canvas contexts don't need (or support) an explicit `reconfigure` for
/// size changes the way native swapchains do.
fn resize(_: *anyopaque, _: u32, _: u32) anyerror!void {}

fn surfaceFormat(ptr: *anyopaque) gpu.Texture.Format {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return self.surface_format;
}

/// `GPUCanvasContext.configure()` only accepts non-sRGB formats
/// ("rgba8unorm"/"bgra8unorm") -- sRGB output on the web is handled by
/// `render/pipelines.zig`'s `fs_main_srgb_encode` shader path instead
/// (the same path already used for any non-sRGB native surface format).
fn surfaceIsSrgb(_: *anyopaque) bool {
    return false;
}

fn clipSpaceYDown(_: *anyopaque) bool {
    return false;
}

fn readJsStringUtf8(handle: zjb.Handle, buf: []u8) []const u8 {
    const view = zjb.u8ArrayView(buf);
    defer view.release();
    const encoder = zjb.global("TextEncoder").new(.{});
    defer encoder.release();
    const result = encoder.call("encodeInto", .{ handle, view }, zjb.Handle);
    defer result.release();
    const written: usize = @intFromFloat(result.get("written", f64));
    return buf[0..written];
}
