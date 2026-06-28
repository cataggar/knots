const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");
const Window = @import("window").Window;

const Shared = @import("Shared.zig");

const RendererGroup = @This();
pub const TextureId = Shared.TextureId;

allocator: std.mem.Allocator,
device: *gpu_impl.Device,
shared: Shared,
max_upload_slots: u32 = 1,

pub fn init(allocator: std.mem.Allocator, window: *const Window) !RendererGroup {
    const device = try allocator.create(gpu_impl.Device);
    errdefer allocator.destroy(device);
    device.* = try .init(allocator, window.getWindowHandle());
    errdefer device.deinit();

    var shared: Shared = try .init(allocator, device);
    errdefer shared.deinit();

    return .{
        .allocator = allocator,
        .device = device,
        .shared = shared,
        .max_upload_slots = 1,
    };
}

pub fn deinit(self: *RendererGroup) void {
    self.shared.deinit();
    self.device.deinit();
    self.allocator.destroy(self.device);
}

pub fn createTexture(self: *RendererGroup, width: u32, height: u32, format: gpu.Texture.Format) !TextureId {
    return self.shared.createTexture(self.device, width, height, format);
}

pub fn writeTexture(self: *RendererGroup, id: TextureId, data: [*]const u8, len: usize, width: u32, height: u32, bytes_per_row: ?u32) !void {
    try self.shared.writeTexture(id, data, len, width, height, bytes_per_row);
}

pub fn destroyTexture(self: *RendererGroup, id: TextureId) !void {
    try self.shared.destroyTexture(id);
}

pub fn destroyTextureNoAlloc(self: *RendererGroup, id: TextureId) void {
    self.shared.destroyTextureNoAlloc(id);
}

pub fn noteUploadSlotCount(self: *RendererGroup, count: u32) void {
    self.max_upload_slots = @max(self.max_upload_slots, count);
}

pub fn sweepSharedCaches(self: *RendererGroup) !void {
    try self.shared.sweepPixelTextureCache(@max(@as(u64, 2), @as(u64, self.max_upload_slots)));
}
