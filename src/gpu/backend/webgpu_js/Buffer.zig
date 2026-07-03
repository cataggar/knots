const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");

const Buffer = @This();

allocator: std.mem.Allocator,
buffer: zjb.Handle,
device: zjb.Handle,
queue: zjb.Handle,
size: usize,
usage_flags: i32,

pub fn create(allocator: std.mem.Allocator, device: zjb.Handle, queue: zjb.Handle, size: usize, usage: gpu.Buffer.Usage) !gpu.Buffer {
    const flags = toUsageFlags(usage);
    const buffer = createGpuBuffer(device, size, flags);

    const self = try allocator.create(Buffer);
    self.* = .{
        .allocator = allocator,
        .buffer = buffer,
        .device = device,
        .queue = queue,
        .size = size,
        .usage_flags = flags,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn toUsageFlags(usage: gpu.Buffer.Usage) i32 {
    var flags: i32 = 0;
    if (usage.vertex) flags |= js.BufferUsage.VERTEX;
    if (usage.index) flags |= js.BufferUsage.INDEX;
    if (usage.uniform) flags |= js.BufferUsage.UNIFORM;
    if (usage.copy_dst) flags |= js.BufferUsage.COPY_DST;
    if (usage.copy_src) flags |= js.BufferUsage.COPY_SRC;
    if (usage.storage) flags |= js.BufferUsage.STORAGE;
    return flags;
}

fn createGpuBuffer(device: zjb.Handle, size: usize, flags: i32) zjb.Handle {
    const desc = js.obj();
    defer desc.release();
    desc.set("size", @as(f64, @floatFromInt(size)));
    desc.set("usage", flags);
    return device.call("createBuffer", .{desc}, zjb.Handle);
}

const vtable = gpu.Buffer.VTable{
    .deinit = &deinit,
    .load = &load,
    .getSize = &getSize,
    .resize = &resize,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    self.buffer.call("destroy", .{}, void);
    self.buffer.release();
    self.allocator.destroy(self);
}

fn load(ptr: *anyopaque, data: [*]const u8, len: usize) void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    const view = zjb.u8ArrayView(data[0..len]);
    defer view.release();
    self.queue.call("writeBuffer", .{ self.buffer, @as(i32, 0), view }, void);
}

fn getSize(ptr: *anyopaque) usize {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    return self.size;
}

fn resize(ptr: *anyopaque, new_size: usize) anyerror!void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    const new_buffer = createGpuBuffer(self.device, new_size, self.usage_flags);
    self.buffer.call("destroy", .{}, void);
    self.buffer.release();
    self.buffer = new_buffer;
    self.size = new_size;
}
