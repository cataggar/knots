const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const RenderPass = @import("RenderPass.zig");

const FrameData = struct {
    command_buffer: vk.CommandBuffer,
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,
    in_flight: vk.Fence,
};

const Frame = @This();

allocator: std.mem.Allocator,
ctx: *Context,
frames: []FrameData,
current: u32,
image_index: u32,

const vtable = gpu.Frame.VTable{
    .deinit = &deinit,
    .begin = &begin,
    .uploadSlotCount = &uploadSlotCount,
    .prepareResize = &prepareResize,
    .beginRenderPass = &beginRenderPass,
    .submit = &submit,
    .waitForCompletion = &waitForCompletion,
};

pub fn create(allocator: std.mem.Allocator, ctx: *Context) !gpu.Frame {
    const frame_count = ctx.swapchain_images.len;
    const frames = try allocator.alloc(FrameData, frame_count);
    var created: usize = 0;

    errdefer {
        for (frames[0..created], ctx.command_pools[0..created]) |f, pool| {
            ctx.vkd.freeCommandBuffers(ctx.device, pool, &.{f.command_buffer});
            ctx.vkd.destroySemaphore(ctx.device, f.image_available, null);
            ctx.vkd.destroySemaphore(ctx.device, f.render_finished, null);
            ctx.vkd.destroyFence(ctx.device, f.in_flight, null);
        }
        allocator.free(frames);
    }

    for (frames, ctx.command_pools) |*f, pool| {
        var cmd: [1]vk.CommandBuffer = undefined;
        try ctx.vkd.allocateCommandBuffers(ctx.device, &.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, &cmd);

        f.* = .{
            .command_buffer = cmd[0],
            .image_available = try ctx.vkd.createSemaphore(ctx.device, &.{}, null),
            .render_finished = try ctx.vkd.createSemaphore(ctx.device, &.{}, null),
            .in_flight = try ctx.vkd.createFence(ctx.device, &.{ .flags = .{ .signaled_bit = true } }, null),
        };
        created += 1;
    }

    const self = try allocator.create(Frame);
    self.* = .{
        .allocator = allocator,
        .ctx = ctx,
        .frames = frames,
        .current = 0,
        .image_index = 0,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    const ctx = self.ctx;
    ctx.vkd.deviceWaitIdle(ctx.device) catch {};
    for (self.frames, ctx.command_pools) |f, pool| {
        ctx.vkd.freeCommandBuffers(ctx.device, pool, &.{f.command_buffer});
        ctx.vkd.destroySemaphore(ctx.device, f.image_available, null);
        ctx.vkd.destroySemaphore(ctx.device, f.render_finished, null);
        ctx.vkd.destroyFence(ctx.device, f.in_flight, null);
    }
    self.allocator.free(self.frames);
    self.allocator.destroy(self);
}

fn begin(ptr: *anyopaque) !u32 {
    const self: *const Frame = @ptrCast(@alignCast(ptr));
    const f = &self.frames[self.current];
    _ = try self.ctx.vkd.waitForFences(self.ctx.device, &.{f.in_flight}, .true, std.math.maxInt(u64));
    return self.current;
}

fn uploadSlotCount(ptr: *anyopaque) u32 {
    const self: *const Frame = @ptrCast(@alignCast(ptr));
    return @intCast(self.frames.len);
}

fn prepareResize(_: *anyopaque) void {}

fn acquireImage(ctx: *Context, semaphore: vk.Semaphore) !u32 {
    const result = try ctx.vkd.acquireNextImageKHR(ctx.device, ctx.swapchain, std.math.maxInt(u64), semaphore, .null_handle);
    return result.image_index;
}

fn beginRenderPass(ptr: *anyopaque, desc: gpu.RenderPass.Desc) !gpu.RenderPass {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    const ctx = self.ctx;
    const f = &self.frames[self.current];

    const image_index = acquireImage(ctx, f.image_available) catch |err| blk: {
        if (err != error.OutOfDateKHR) return err;
        try ctx.vkd.deviceWaitIdle(ctx.device);
        try ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height);
        break :blk try acquireImage(ctx, f.image_available);
    };

    try ctx.vkd.resetFences(ctx.device, &.{f.in_flight});

    self.image_index = image_index;
    ctx._current_image_index = image_index;

    try ctx.vkd.resetCommandPool(ctx.device, ctx.command_pools[self.current], .{});
    try ctx.vkd.beginCommandBuffer(f.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    return RenderPass.create(self.allocator, f.command_buffer, ctx, desc);
}

fn submit(ptr: *anyopaque) !void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    const ctx = self.ctx;
    const f = &self.frames[self.current];

    try ctx.vkd.endCommandBuffer(f.command_buffer);

    const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
    try ctx.vkd.queueSubmit(ctx.graphics_queue, &.{.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{f.image_available},
        .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
        .command_buffer_count = 1,
        .p_command_buffers = &[_]vk.CommandBuffer{f.command_buffer},
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &[_]vk.Semaphore{f.render_finished},
    }}, f.in_flight);

    const present_result = ctx.vkd.queuePresentKHR(ctx.graphics_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{f.render_finished},
        .swapchain_count = 1,
        .p_swapchains = &[_]vk.SwapchainKHR{ctx.swapchain},
        .p_image_indices = &[_]u32{self.image_index},
    }) catch |err|
        switch (err) {
            error.OutOfDateKHR => {
                try ctx.vkd.deviceWaitIdle(ctx.device);
                try ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height);
                self.current = (self.current + 1) % @as(u32, @intCast(self.frames.len));
                return;
            },
            else => return err,
        };

    if (present_result == .suboptimal_khr) {
        try ctx.vkd.deviceWaitIdle(ctx.device);
        try ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height);
    }

    self.current = (self.current + 1) % @as(u32, @intCast(self.frames.len));
}

fn waitForCompletion(ptr: *anyopaque) !void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    const ctx = self.ctx;
    for (self.frames) |f| {
        _ = try ctx.vkd.waitForFences(ctx.device, &.{f.in_flight}, .true, std.math.maxInt(u64));
    }
}
