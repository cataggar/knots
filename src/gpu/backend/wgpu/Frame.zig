const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const RenderPass = @import("RenderPass.zig");

const Frame = @This();

allocator: std.mem.Allocator,
surface_texture: ?wgpu.Texture,
view: ?wgpu.TextureView,
encoder: ?wgpu.CommandEncoder,
ctx: *Context,

pub fn create(allocator: std.mem.Allocator, ctx: *Context) !gpu.Frame {
    const self = try allocator.create(Frame);
    self.* = .{
        .allocator = allocator,
        .surface_texture = null,
        .view = null,
        .encoder = null,
        .ctx = ctx,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Frame.VTable{
    .deinit = &deinit,
    .waitForFence = &waitForFence,
    .prepareResize = &prepareResize,
    .beginRenderPass = &beginRenderPass,
    .submit = &submit,
    .waitForCompletion = &waitForCompletion,
};

fn waitForFence(ptr: *anyopaque) !void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    _ = self.ctx.device.poll(true);
}

fn prepareResize(ptr: *anyopaque) void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    if (self.view) |v| v.deinit();
    self.view = null;
    if (self.surface_texture) |t| t.deinit();
    self.surface_texture = null;
    _ = self.ctx.device.poll(true);
}

fn deinit(ptr: *anyopaque) void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    if (self.encoder) |e| e.deinit();
    if (self.view) |v| v.deinit();
    if (self.surface_texture) |t| t.deinit();
    self.allocator.destroy(self);
}

fn beginRenderPass(ptr: *anyopaque, desc: gpu.RenderPass.Desc) anyerror!gpu.RenderPass {
    const self: *Frame = @ptrCast(@alignCast(ptr));

    if (self.encoder) |e| e.deinit();
    self.encoder = null;
    if (self.view) |v| v.deinit();
    self.view = null;
    if (self.surface_texture) |t| t.deinit();
    self.surface_texture = null;

    self.surface_texture = self.ctx.surface.getCurrentTexture() catch |err| switch (err) {
        error.CurrentTextureOutdated, error.CurrentTextureLost => blk: {
            _ = self.ctx.device.poll(true);
            self.ctx.reconfigureSurface(self.ctx.surface_width, self.ctx.surface_height);
            break :blk try self.ctx.surface.getCurrentTexture();
        },
        else => return err,
    };
    self.view = try self.surface_texture.?.createView(.{ .format = self.ctx.surface_format });
    self.encoder = try self.ctx.device.createCommandEncoder(.{ .label = "frame_encoder" });

    const target_view = if (desc.color_attachment.target) |target| blk: {
        const tex: *@import("Texture.zig") = @ptrCast(@alignCast(target.ptr));
        break :blk tex.view;
    } else self.view.?;

    return RenderPass.create(self.allocator, self.encoder.?, target_view, desc);
}

fn submit(ptr: *anyopaque) anyerror!void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    const cmd = try self.encoder.?.finish(.{});
    self.ctx.queue.submitCommands(&.{cmd});
    try self.ctx.surface.present();

    if (self.encoder) |e| e.deinit();
    self.encoder = null;
    if (self.view) |v| v.deinit();
    self.view = null;
    if (self.surface_texture) |t| t.deinit();
    self.surface_texture = null;
}

fn waitForCompletion(ptr: *anyopaque) !void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    _ = self.ctx.device.poll(true);
}
