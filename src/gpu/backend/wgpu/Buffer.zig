const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");

const Buffer = @This();

allocator: std.mem.Allocator,
buffer: wgpu.Buffer,
queue: wgpu.Queue,
device: wgpu.Device,
size: usize,
usage: wgpu.Buffer.Usage,

pub fn create(allocator: std.mem.Allocator, device: wgpu.Device, queue: wgpu.Queue, size: usize, usage: gpu.Buffer.Usage) !gpu.Buffer {
    const wgpu_usage = toWgpuUsage(usage);
    const self = try allocator.create(Buffer);
    self.* = .{
        .allocator = allocator,
        .buffer = try device.createBuffer(.{
            .usage = wgpu_usage,
            .size = size,
            .label = "",
        }),
        .queue = queue,
        .device = device,
        .size = size,
        .usage = wgpu_usage,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn toWgpuUsage(usage: gpu.Buffer.Usage) wgpu.Buffer.Usage {
    return .{
        .vertex = usage.vertex,
        .index = usage.index,
        .uniform = usage.uniform,
        .copy_dst = usage.copy_dst,
        .copy_src = usage.copy_src,
        .storage = usage.storage,
    };
}

const vtable = gpu.Buffer.VTable{
    .deinit = &deinit,
    .load = &load,
    .getSize = &getSize,
    .resize = &resize,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    self.buffer.deinit();
    self.allocator.destroy(self);
}

fn load(ptr: *anyopaque, data: [*]const u8, len: usize) void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    self.queue.writeBuffer(u8, self.buffer, 0, data[0..len]);
}

fn getSize(ptr: *anyopaque) usize {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    return self.size;
}

fn resize(ptr: *anyopaque, new_size: usize) anyerror!void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    const new_buffer = try self.device.createBuffer(.{
        .usage = self.usage,
        .size = new_size,
        .label = "",
    });
    self.buffer.deinit();
    self.buffer = new_buffer;
    self.size = new_size;
}
