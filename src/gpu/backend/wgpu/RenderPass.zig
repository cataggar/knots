const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");

const RenderPass = @This();

allocator: std.mem.Allocator,
pass: wgpu.RenderPassEncoder,
current_pipeline: ?*Pipeline = null,

pub fn create(allocator: std.mem.Allocator, encoder: wgpu.CommandEncoder, view: wgpu.TextureView, desc: gpu.RenderPass.Desc) !gpu.RenderPass {
    const ca = desc.color_attachment;

    const pass = try encoder.beginRenderPass(.{
        .label = if (desc.label.len > 0) desc.label else "render_pass",
        .color_attachments = &.{
            .{
                .view = view,
                .load_op = switch (ca.load_op) {
                    .clear => .clear,
                    .load => .load,
                },
                .store_op = switch (ca.store_op) {
                    .store => .store,
                    .discard => .discard,
                },
                .clear_value = .{
                    .r = ca.clear_color[0],
                    .g = ca.clear_color[1],
                    .b = ca.clear_color[2],
                    .a = ca.clear_color[3],
                },
            },
        },
    });

    const self = try allocator.create(RenderPass);
    self.* = .{
        .allocator = allocator,
        .pass = pass,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.RenderPass.VTable{
    .end = &end,
    .bindPipeline = &bindPipeline,
    .rebindTextureSet = &rebindTextureSet,
    .setVertexBuffer = &setVertexBuffer,
    .setIndexBuffer = &setIndexBuffer,
    .setScissorRect = &setScissorRect,
    .drawIndexed = &drawIndexed,
};

fn end(ptr: *anyopaque) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.pass.end();
    self.pass.deinit();
    self.allocator.destroy(self);
}

fn bindPipeline(ptr: *anyopaque, pipeline: *const gpu.Pipeline) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const wgpu_pipeline: *Pipeline = @ptrCast(@alignCast(pipeline.ptr));
    self.current_pipeline = wgpu_pipeline;
    self.pass.setPipeline(wgpu_pipeline.render_pipeline);
    if (wgpu_pipeline.bind_group) |bg| self.pass.setBindGroup(0, bg, &.{});
}

fn rebindTextureSet(ptr: *anyopaque) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    if (self.current_pipeline) |p| {
        if (p.bind_group) |bg| self.pass.setBindGroup(0, bg, &.{});
    }
}

fn setVertexBuffer(ptr: *anyopaque, slot: u32, buf: *const gpu.Buffer, offset: usize, size: usize) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const wgpu_buf: *Buffer = @ptrCast(@alignCast(buf.ptr));
    self.pass.setVertexBuffer(slot, wgpu_buf.buffer, offset, size);
}

fn setIndexBuffer(ptr: *anyopaque, buf: *const gpu.Buffer, offset: usize, size: usize) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const wgpu_buf: *Buffer = @ptrCast(@alignCast(buf.ptr));
    self.pass.setIndexBuffer(wgpu_buf.buffer, .uint32, offset, size);
}

fn setScissorRect(ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.pass.setScissorRect(x, y, w, h);
}

fn drawIndexed(ptr: *anyopaque, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.pass.drawIndexed(index_count, instance_count, first_index, base_vertex, first_instance);
}
