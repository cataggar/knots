const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Buffer = @import("Buffer.zig");
const Frame = @import("Frame.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Context = @This();

pub const NativeDevice = struct {
    device: wgpu.Device,
    queue: wgpu.Queue,
};

allocator: std.mem.Allocator,
instance: wgpu.Instance,
adapter: wgpu.Adapter,
device: wgpu.Device,
queue: wgpu.Queue,
surface: wgpu.Surface,
surface_format: wgpu.Texture.Format,
surface_is_srgb: bool,
present_mode: wgpu.types.PresentMode,
surface_width: u32,
surface_height: u32,

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !gpu.Context {
    const wgpu_handle: wgpu.RawWindowHandle = switch (window_handle) {
        .macos => |mac| .{ .macos = switch (mac) {
            .ns_view => |v| .{ .ns_view = v },
            .ns_window => |w| .{ .ns_window = w },
        } },
        .windows => |win| .{ .windows = .{ .hwnd = win.hwnd, .hinstance = win.hinstance } },
        .linux => |lin| switch (lin) {
            .x11 => |x11| .{
                .linux = .{ .x11 = .{ .display = x11.display, .window = x11.window } },
            },
            .wayland => |wl| .{
                .linux = .{ .wayland = .{ .display = wl.display, .surface = wl.surface } },
            },
        },
        .emscripten => |em| .{ .emscripten = .{ .selector = em.selector } },
        .wasm => @panic("wasm target not supported by the native/emscripten wgpu backend; use the webgpu_js backend"),
    };

    const instance = try wgpu.Instance.init();
    errdefer instance.deinit();

    var surface_desc = try wgpu.descriptorFromRawHandle(wgpu_handle);
    const desc = surface_desc.getDescriptor();
    const surface = try instance.createSurface(&desc);

    const adapter = try instance.requestAdapterSync(.{ .compatible_surface = surface });

    const capabilities = try surface.getCapabilities(adapter.adapter);

    const dev = try adapter.requestDeviceSync(.{ .label = "knots_device", .queue_label = "knots_queue" });

    const q = try dev.getQueue();

    const surface_format = try chooseSurfaceFormat(capabilities);
    const surface_is_srgb = isSrgbFormat(surface_format);

    const chosen_present_mode = try choosePresentMode(capabilities, cfg.present_mode);

    surface.configure(.{
        .width = cfg.window_width,
        .height = cfg.window_height,
        .format = surface_format,
        .device = dev,
        .present_mode = chosen_present_mode,
    });

    const self = try allocator.create(Context);
    self.* = .{
        .allocator = allocator,
        .instance = instance,
        .adapter = adapter,
        .device = dev,
        .queue = q,
        .surface = surface,
        .surface_format = surface_format,
        .surface_is_srgb = surface_is_srgb,
        .present_mode = chosen_present_mode,
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

fn clipSpaceYDown(_: *anyopaque) bool {
    return false;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Context = @ptrCast(@alignCast(ptr));
    self.queue.deinit();
    self.device.deinit();
    self.adapter.deinit();
    self.surface.unconfigure();
    self.surface.deinit();
    self.instance.deinit();
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
    return BindGroup.create(self.allocator, self, desc);
}

fn createTexture(ptr: *anyopaque, desc: gpu.Texture.Desc) anyerror!gpu.Texture {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return Texture.create(self.allocator, self.device, self.queue, desc);
}

fn createSampler(ptr: *anyopaque, desc: gpu.Sampler.Desc) anyerror!gpu.Sampler {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return Sampler.create(self.allocator, self.device, desc);
}

fn resize(ptr: *anyopaque, width: u32, height: u32) anyerror!void {
    const self: *Context = @ptrCast(@alignCast(ptr));
    self.reconfigureSurface(width, height);
}

pub fn reconfigureSurface(self: *Context, width: u32, height: u32) void {
    self.surface.configure(.{
        .width = width,
        .height = height,
        .format = self.surface_format,
        .device = self.device,
        .present_mode = self.present_mode,
    });
    self.surface_width = width;
    self.surface_height = height;
}

fn surfaceFormat(ptr: *anyopaque) gpu.Texture.Format {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return wgpuFormatToGpu(self.surface_format);
}

fn surfaceIsSrgb(ptr: *anyopaque) bool {
    const self: *Context = @ptrCast(@alignCast(ptr));
    return self.surface_is_srgb;
}

fn wgpuFormatToGpu(f: wgpu.Texture.Format) gpu.Texture.Format {
    return switch (f) {
        .rgba8_unorm => .rgba8,
        .rgba8_unorm_srgb => .rgba8_srgb,
        .bgra8_unorm => .bgra8,
        .bgra8_unorm_srgb => .bgra8_srgb,
        .r8_unorm => .r8,
        .rgba32_float => .rgba32f,
        .rgba32_uint => .rgba32u,
        else => unreachable,
    };
}

fn chooseSurfaceFormat(capabilities: wgpu.Surface.Capabilities) !wgpu.Texture.Format {
    if (capabilities.formats.len < 1) {
        return error.NoSurfaceFormatFound;
    }

    for (capabilities.formats) |format|
        if (format == .bgra8_unorm_srgb)
            return .bgra8_unorm_srgb;

    for (capabilities.formats) |format|
        if (format == .rgba8_unorm_srgb)
            return .rgba8_unorm_srgb;

    for (capabilities.formats) |format| switch (format) {
        .rgba8_unorm, .bgra8_unorm, .r8_unorm, .rgba32_float, .rgba32_uint => return format,
        else => {},
    };
    return error.UnsupportedSurfaceFormat;
}

fn isSrgbFormat(format: wgpu.Texture.Format) bool {
    return switch (format) {
        .bgra8_unorm_srgb, .rgba8_unorm_srgb => true,
        else => false,
    };
}

fn choosePresentMode(capabilities: wgpu.Surface.Capabilities, pm: gpu.Context.PresentMode) !wgpu.types.PresentMode {
    if (capabilities.present_modes.len < 1) {
        return error.NoSurfacePresentModeFound;
    }

    const needle: wgpu.types.PresentMode = switch (pm) {
        .fifo => .fifo,
        .fifo_relaxed => .fifo_relaxed,
        .immediate => .immediate,
        .mailbox => .mailbox,
    };

    for (capabilities.present_modes) |mode|
        if (mode == needle)
            return mode;

    return error.FifoPresentModeNotSupportedBySurface;
}
