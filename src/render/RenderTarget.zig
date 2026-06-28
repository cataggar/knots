const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");
const Window = @import("window").Window;

const RenderTarget = @This();

pub const Size = struct {
    width: u32,
    height: u32,
};

allocator: std.mem.Allocator,
surface: *gpu_impl.Surface,
frame: gpu_impl.Frame,

pub fn init(allocator: std.mem.Allocator, device: *gpu_impl.Device, window: *const Window, cfg: gpu.Context.Config) !RenderTarget {
    const surface = try allocator.create(gpu_impl.Surface);
    errdefer allocator.destroy(surface);
    surface.* = try gpu_impl.Surface.init(device, window.getWindowHandle(), cfg);
    errdefer surface.deinit();

    var frame = try gpu_impl.Frame.create(surface);
    errdefer frame.deinit();

    return .{
        .allocator = allocator,
        .surface = surface,
        .frame = frame,
    };
}

pub fn deinit(self: *RenderTarget) void {
    self.frame.deinit();
    self.surface.deinit();
    self.allocator.destroy(self.surface);
}

pub fn resize(self: *RenderTarget, width: u32, height: u32) !void {
    const current = self.size();
    if (width == current.width and height == current.height) return;

    self.frame.prepareResize();
    try self.surface.resize(width, height);
}

pub fn reconfigure(self: *RenderTarget, cfg: gpu.Context.Config) !void {
    try self.frame.waitForCompletion();
    self.frame.prepareResize();
    try self.surface.reconfigure(cfg);
}

pub fn supportedPresentModes(self: *const RenderTarget) gpu.Context.PresentModes {
    return self.surface.supportedPresentModes();
}

pub fn beginFrame(self: *RenderTarget) !gpu_impl.Frame.Context {
    return self.frame.begin();
}

pub fn uploadSlotCount(self: *const RenderTarget) u32 {
    return self.frame.uploadSlotCount();
}

pub fn waitForCompletion(self: *RenderTarget) !void {
    try self.frame.waitForCompletion();
}

pub fn config(self: *const RenderTarget) gpu.Context.Config {
    return self.surface.cfg;
}

pub fn size(self: *const RenderTarget) Size {
    return .{
        .width = self.surface.cfg.window_width,
        .height = self.surface.cfg.window_height,
    };
}
