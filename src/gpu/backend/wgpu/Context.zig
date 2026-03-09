const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Buffer = @import("Buffer.zig");
const Frame = @import("Frame.zig");
const Pipeline = @import("Pipeline.zig");
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
present_mode: wgpu.types.PresentMode,
_native_device: NativeDevice = undefined,

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
        .present_mode = chosen_present_mode,
    };

    return .{ .ptr = self, .vtable = &vtable, .cfg = cfg };
}

const vtable = gpu.Context.VTable{
    .deinit = &deinit,
    .createBuffer = &createBuffer,
    .createFrame = &createFrame,
    .createPipeline = &createPipeline,
    .createTexture = &createTexture,
    .createSampler = &createSampler,
    .resize = &resize,
    .nativeDevice = &nativeDevice,
};

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
    self.surface.configure(.{
        .width = width,
        .height = height,
        .format = self.surface_format,
        .device = self.device,
        .present_mode = self.present_mode,
    });
}

fn nativeDevice(ptr: *anyopaque) *anyopaque {
    const self: *Context = @ptrCast(@alignCast(ptr));
    self._native_device = .{
        .device = self.device,
        .queue = self.queue,
    };
    return &self._native_device;
}

fn chooseSurfaceFormat(capabilities: wgpu.Surface.Capabilities) !wgpu.Texture.Format {
    if (capabilities.formats.len < 1) {
        return error.NoSurfaceFormatFound;
    }

    for (capabilities.formats) |format|
        if (format == .bgra8_unorm_srgb)
            return .bgra8_unorm_srgb;

    return capabilities.formats[0];
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
