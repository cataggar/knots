const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const Texture = @import("Texture.zig");

const RenderPass = @This();

allocator: std.mem.Allocator,
command_buffer: vk.CommandBuffer,
vkd: Context.DeviceDispatch,
extent: vk.Extent2D,
current_pipeline: ?*Pipeline,
frame_index: u32,

pub fn create(allocator: std.mem.Allocator, command_buffer: vk.CommandBuffer, ctx: *Context, desc: gpu.RenderPass.Desc) !gpu.RenderPass {
    const ca = desc.color_attachment;
    ctx.vkd.cmdBeginRenderPass(command_buffer, &.{
        .render_pass = ctx.render_pass,
        .framebuffer = ctx.framebuffers[ctx._current_image_index],
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain_extent },
        .clear_value_count = 1,
        .p_clear_values = &[_]vk.ClearValue{.{ .color = .{ .float_32 = .{
            ca.clear_color[0], ca.clear_color[1], ca.clear_color[2], ca.clear_color[3],
        } } }},
    }, .@"inline");
    ctx.vkd.cmdSetViewport(command_buffer, 0, &.{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(ctx.swapchain_extent.width),
        .height = @floatFromInt(ctx.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    ctx.vkd.cmdSetScissor(command_buffer, 0, &.{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = ctx.swapchain_extent,
    }});

    const self = try allocator.create(RenderPass);
    self.* = .{
        .allocator = allocator,
        .command_buffer = command_buffer,
        .vkd = ctx.vkd,
        .extent = ctx.swapchain_extent,
        .current_pipeline = null,
        .frame_index = ctx._current_image_index,
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
    self.vkd.cmdEndRenderPass(self.command_buffer);
    self.allocator.destroy(self);
}

fn bindPipeline(ptr: *anyopaque, pipeline: *const gpu.Pipeline) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const vk_pipeline: *Pipeline = @ptrCast(@alignCast(pipeline.ptr));
    self.current_pipeline = vk_pipeline;

    self.vkd.cmdBindPipeline(self.command_buffer, .graphics, vk_pipeline.pipeline);

    self.vkd.cmdBindDescriptorSets(
        self.command_buffer,
        .graphics,
        vk_pipeline.pipeline_layout,
        0,
        &[_]vk.DescriptorSet{
            vk_pipeline.uniform_descriptor_sets[self.frame_index],
            vk_pipeline.current_texture_ds,
        },
        null,
    );
}

fn rebindTextureSet(ptr: *anyopaque) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    if (self.current_pipeline) |p| {
        self.vkd.cmdBindDescriptorSets(
            self.command_buffer,
            .graphics,
            p.pipeline_layout,
            1,
            &[_]vk.DescriptorSet{p.current_texture_ds},
            null,
        );
    }
}

fn setVertexBuffer(ptr: *anyopaque, slot: u32, buf: *const gpu.Buffer, offset: usize, _: usize) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const vk_buf: *Buffer = @ptrCast(@alignCast(buf.ptr));
    self.vkd.cmdBindVertexBuffers(self.command_buffer, slot, &.{vk_buf.buffer}, &.{@as(vk.DeviceSize, @intCast(offset))});
}

fn setIndexBuffer(ptr: *anyopaque, buf: *const gpu.Buffer, offset: usize, _: usize) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const vk_buf: *Buffer = @ptrCast(@alignCast(buf.ptr));
    self.vkd.cmdBindIndexBuffer(self.command_buffer, vk_buf.buffer, @intCast(offset), .uint32);
}

fn setScissorRect(ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.vkd.cmdSetScissor(self.command_buffer, 0, &.{.{
        .offset = .{ .x = @intCast(x), .y = @intCast(y) },
        .extent = .{ .width = w, .height = h },
    }});
}

fn drawIndexed(ptr: *anyopaque, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.vkd.cmdDrawIndexed(self.command_buffer, index_count, instance_count, first_index, base_vertex, first_instance);
}
