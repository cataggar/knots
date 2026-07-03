const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");
const Context = @import("Context.zig");
const RenderPass = @import("RenderPass.zig");

const Frame = @This();

allocator: std.mem.Allocator,
surface_texture: ?zjb.Handle,
view: ?zjb.Handle,
encoder: ?zjb.Handle,
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
    .begin = &begin,
    .uploadSlotCount = &uploadSlotCount,
    .prepareResize = &prepareResize,
    .beginRenderPass = &beginRenderPass,
    .submit = &submit,
    .waitForCompletion = &waitForCompletion,
};

/// No CPU/GPU sync is needed before writing to upload buffers again:
/// `GPUQueue.writeBuffer`/`writeTexture` copy the provided data into an
/// internal staging buffer synchronously (per the WebGPU spec), so a single
/// upload slot is always safe to reuse immediately -- unlike native APIs,
/// there's no `device.poll`/fence-wait equivalent to call here.
fn begin(_: *anyopaque) !u32 {
    return 0;
}

fn uploadSlotCount(_: *anyopaque) u32 {
    return 1;
}

fn releaseTextureView(self: *Frame) void {
    if (self.view) |v| {
        v.release();
        self.view = null;
    }
    if (self.surface_texture) |t| {
        t.release();
        self.surface_texture = null;
    }
}

fn prepareResize(ptr: *anyopaque) void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    releaseTextureView(self);
}

fn deinit(ptr: *anyopaque) void {
    const self: *Frame = @ptrCast(@alignCast(ptr));
    if (self.encoder) |e| e.release();
    releaseTextureView(self);
    self.allocator.destroy(self);
}

fn beginRenderPass(ptr: *anyopaque, desc: gpu.RenderPass.Desc) anyerror!gpu.RenderPass {
    const self: *Frame = @ptrCast(@alignCast(ptr));

    if (self.encoder == null) {
        self.encoder = self.ctx.device.call("createCommandEncoder", .{}, zjb.Handle);
    }

    const target_view = if (desc.color_attachment.target) |target| blk: {
        const tex: *@import("Texture.zig") = @ptrCast(@alignCast(target.ptr));
        break :blk tex.view;
    } else blk: {
        if (self.surface_texture == null) {
            self.surface_texture = self.ctx.canvas_context.call("getCurrentTexture", .{}, zjb.Handle);
            self.view = self.surface_texture.?.call("createView", .{}, zjb.Handle);
        }
        break :blk self.view.?;
    };

    return RenderPass.create(self.allocator, self.encoder.?, target_view, desc);
}

fn submit(ptr: *anyopaque) anyerror!void {
    const self: *Frame = @ptrCast(@alignCast(ptr));

    const cmd = self.encoder.?.call("finish", .{}, zjb.Handle);
    defer cmd.release();

    const cmds_arr = js.arr();
    defer cmds_arr.release();
    js.push(cmds_arr, cmd);
    self.ctx.queue.call("submit", .{cmds_arr}, void);

    // No explicit present() call: the browser presents the canvas
    // automatically at the end of the current task, matching the existing
    // wgpu backend's emscripten short-circuit in `Surface.zig`'s `present()`.

    if (self.encoder) |e| {
        e.release();
        self.encoder = null;
    }
    releaseTextureView(self);
}

/// A no-op: see `begin`'s comment on why no CPU/GPU sync primitive is
/// needed (or available) in the browser -- WebGPU's resource lifetime
/// model guarantees objects referenced by already-submitted command
/// buffers stay valid until that work completes, even after `destroy()`,
/// so callers needing this to happen before recreating/destroying a
/// resource (e.g. `Renderer.syncGlyphBuilder` growing the glyph atlas) are
/// already safe without an explicit wait.
fn waitForCompletion(_: *anyopaque) !void {}
