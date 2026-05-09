const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Context = @import("Context.zig");

const Buffer = @This();

allocator: std.mem.Allocator,
buffer: vk.Buffer,
memory: vk.DeviceMemory,
mapped: [*]u8,
size: usize,
usage: vk.BufferUsageFlags,
vkd: vk.DeviceWrapper,
device: vk.Device,
physical_device: vk.PhysicalDevice,
vki: vk.InstanceWrapper,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, size: usize, usage: gpu.Buffer.Usage) !gpu.Buffer {
    const vk_usage = toVkUsage(usage);

    const buffer = try ctx.vkd.createBuffer(ctx.device, &.{
        .size = @intCast(size),
        .usage = vk_usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer ctx.vkd.destroyBuffer(ctx.device, buffer, null);

    const mem_reqs = ctx.vkd.getBufferMemoryRequirements(ctx.device, buffer);
    const mem_type = try ctx.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true });

    const memory = try ctx.vkd.allocateMemory(ctx.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = mem_type,
    }, null);
    errdefer ctx.vkd.freeMemory(ctx.device, memory, null);

    try ctx.vkd.bindBufferMemory(ctx.device, buffer, memory, 0);

    const mapped = try ctx.vkd.mapMemory(ctx.device, memory, 0, @intCast(size), .{});

    const self = try allocator.create(Buffer);
    self.* = .{
        .allocator = allocator,
        .buffer = buffer,
        .memory = memory,
        .mapped = @ptrCast(mapped),
        .size = size,
        .usage = vk_usage,
        .vkd = ctx.vkd,
        .device = ctx.device,
        .physical_device = ctx.physical_device,
        .vki = ctx.vki,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn toVkUsage(usage: gpu.Buffer.Usage) vk.BufferUsageFlags {
    return vk.BufferUsageFlags{
        .vertex_buffer_bit = usage.vertex,
        .index_buffer_bit = usage.index,
        .uniform_buffer_bit = usage.uniform,
        .transfer_dst_bit = usage.copy_dst,
        .transfer_src_bit = usage.copy_src,
        .storage_buffer_bit = usage.storage,
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
    self.vkd.destroyBuffer(self.device, self.buffer, null);
    self.vkd.freeMemory(self.device, self.memory, null);
    self.allocator.destroy(self);
}

fn load(ptr: *anyopaque, data: [*]const u8, len: usize) void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    @memcpy(self.mapped[0..len], data[0..len]);
}

fn getSize(ptr: *anyopaque) usize {
    const self: *Buffer = @ptrCast(@alignCast(ptr));
    return self.size;
}

fn resize(ptr: *anyopaque, new_size: usize) anyerror!void {
    const self: *Buffer = @ptrCast(@alignCast(ptr));

    self.vkd.destroyBuffer(self.device, self.buffer, null);
    self.vkd.freeMemory(self.device, self.memory, null);

    self.buffer = try self.vkd.createBuffer(self.device, &.{
        .size = @intCast(new_size),
        .usage = self.usage,
        .sharing_mode = .exclusive,
    }, null);

    const mem_reqs = self.vkd.getBufferMemoryRequirements(self.device, self.buffer);
    const mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.physical_device);
    const mem_type = findMemType(mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }, mem_props) orelse return error.NoSuitableMemoryType;

    self.memory = try self.vkd.allocateMemory(self.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = mem_type,
    }, null);

    try self.vkd.bindBufferMemory(self.device, self.buffer, self.memory, 0);
    self.mapped = @ptrCast(try self.vkd.mapMemory(self.device, self.memory, 0, @intCast(new_size), .{}));
    self.size = new_size;
}

fn findMemType(type_filter: u32, properties: vk.MemoryPropertyFlags, mem_props: vk.PhysicalDeviceMemoryProperties) ?u32 {
    for (0..mem_props.memory_type_count) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0) {
            const flags = mem_props.memory_types[i].property_flags;
            if ((@as(u32, @bitCast(flags)) & @as(u32, @bitCast(properties))) == @as(u32, @bitCast(properties))) {
                return @intCast(i);
            }
        }
    }
    return null;
}
