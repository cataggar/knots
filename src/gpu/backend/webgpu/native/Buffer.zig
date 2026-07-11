const std = @import("std");
const wgpu = @import("wgpu");
const Desc = @import("gpu").Buffer.Desc;

const Buffer = @This();

allocator: std.mem.Allocator,
buffer: wgpu.Buffer,
queue: wgpu.Queue,
device: wgpu.Device,
size: usize,
usage: wgpu.Buffer.Usage,
label: []u8,

pub fn create(allocator: std.mem.Allocator, device: wgpu.Device, queue: wgpu.Queue, desc: Desc) !Buffer {
    std.debug.assert(desc.size != 0);
    const label = try allocator.dupe(u8, desc.label);
    errdefer allocator.free(label);
    const wgpu_usage = toWgpuUsage(desc.usage);
    return .{
        .allocator = allocator,
        .buffer = try device.createBuffer(.{
            .usage = wgpu_usage,
            .size = desc.size,
            .label = label,
        }),
        .queue = queue,
        .device = device,
        .size = desc.size,
        .usage = wgpu_usage,
        .label = label,
    };
}

fn toWgpuUsage(usage: @import("gpu").Buffer.Usage) wgpu.Buffer.Usage {
    return .{
        .vertex = usage.vertex,
        .index = usage.index,
        .uniform = usage.uniform,
        .copy_dst = usage.copy_dst,
        .copy_src = usage.copy_src,
        .storage = usage.storage,
    };
}

pub fn deinit(self: *Buffer) void {
    self.buffer.deinit();
    self.allocator.free(self.label);
}

pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
    std.debug.assert(@sizeOf(T) != 0);
    std.debug.assert(data.len <= self.size / @sizeOf(T));
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    self.queue.writeBuffer(u8, self.buffer, 0, bytes[0 .. data.len * @sizeOf(T)]);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    std.debug.assert(new_size != 0);
    const new_buffer = try self.device.createBuffer(.{
        .usage = self.usage,
        .size = new_size,
        .label = self.label,
    });
    self.buffer.deinit();
    self.buffer = new_buffer;
    self.size = new_size;
}
