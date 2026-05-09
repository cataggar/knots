const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");

const RenderPass = @This();

pub const LoadOp = enum { clear, load };
pub const StoreOp = enum { store, discard };

pub const ColorAttachment = struct {
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    target: ?*Texture = null,
};

pub const Desc = struct {
    label: []const u8 = "",
    color_attachment: ColorAttachment = .{},
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    end: *const fn (ptr: *anyopaque) void,
    bindPipeline: *const fn (ptr: *anyopaque, pipeline: *const Pipeline) void,
    setBindGroup: *const fn (ptr: *anyopaque, group_index: u32, group: *const BindGroup) void,
    setVertexBuffer: *const fn (ptr: *anyopaque, slot: u32, buf: *const Buffer, offset: usize, size: usize) void,
    setIndexBuffer: *const fn (ptr: *anyopaque, buf: *const Buffer, offset: usize, size: usize) void,
    setScissorRect: *const fn (ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32) void,
    drawIndexed: *const fn (ptr: *anyopaque, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void,
};

pub inline fn end(self: *RenderPass) void {
    self.vtable.end(self.ptr);
}

pub inline fn bindPipeline(self: *const RenderPass, pipeline: *const Pipeline) void {
    self.vtable.bindPipeline(self.ptr, pipeline);
}

pub inline fn setBindGroup(self: *const RenderPass, group_index: u32, group: *const BindGroup) void {
    self.vtable.setBindGroup(self.ptr, group_index, group);
}

pub inline fn setVertexBuffer(self: *const RenderPass, slot: u32, buf: *const Buffer, offset: usize, size: usize) void {
    self.vtable.setVertexBuffer(self.ptr, slot, buf, offset, size);
}

pub inline fn setIndexBuffer(self: *const RenderPass, buf: *const Buffer, offset: usize, size: usize) void {
    self.vtable.setIndexBuffer(self.ptr, buf, offset, size);
}

pub inline fn setScissorRect(self: *const RenderPass, x: u32, y: u32, w: u32, h: u32) void {
    self.vtable.setScissorRect(self.ptr, x, y, w, h);
}

pub inline fn drawIndexed(self: *const RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    self.vtable.drawIndexed(self.ptr, index_count, instance_count, first_index, base_vertex, first_instance);
}
