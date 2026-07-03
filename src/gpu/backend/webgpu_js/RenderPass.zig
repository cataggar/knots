const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");

const RenderPass = @This();

allocator: std.mem.Allocator,
pass: zjb.Handle,

pub fn create(allocator: std.mem.Allocator, encoder: zjb.Handle, view: zjb.Handle, desc: gpu.RenderPass.Desc) !gpu.RenderPass {
    const ca = desc.color_attachment;

    const clear_value = js.obj();
    defer clear_value.release();
    clear_value.set("r", @as(f64, ca.clear_color[0]));
    clear_value.set("g", @as(f64, ca.clear_color[1]));
    clear_value.set("b", @as(f64, ca.clear_color[2]));
    clear_value.set("a", @as(f64, ca.clear_color[3]));

    const attachment = js.obj();
    defer attachment.release();
    attachment.set("view", view);
    attachment.set("loadOp", switch (ca.load_op) {
        .clear => zjb.constString("clear"),
        .load => zjb.constString("load"),
    });
    attachment.set("storeOp", switch (ca.store_op) {
        .store => zjb.constString("store"),
        .discard => zjb.constString("discard"),
    });
    attachment.set("clearValue", clear_value);

    const attachments_arr = js.arr();
    defer attachments_arr.release();
    js.push(attachments_arr, attachment);

    const pass_desc = js.obj();
    defer pass_desc.release();
    pass_desc.set("colorAttachments", attachments_arr);
    var label_handle: ?zjb.Handle = null;
    defer if (label_handle) |h| h.release();
    if (desc.label.len > 0) {
        label_handle = zjb.string(desc.label);
        pass_desc.set("label", label_handle.?);
    }

    const pass = encoder.call("beginRenderPass", .{pass_desc}, zjb.Handle);

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
    .setBindGroup = &setBindGroup,
    .setVertexBuffer = &setVertexBuffer,
    .setIndexBuffer = &setIndexBuffer,
    .setScissorRect = &setScissorRect,
    .drawIndexed = &drawIndexed,
};

fn end(ptr: *anyopaque) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.pass.call("end", .{}, void);
    self.pass.release();
    self.allocator.destroy(self);
}

fn bindPipeline(ptr: *anyopaque, pipeline: *const gpu.Pipeline) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const webgpu_pipeline: *Pipeline = @ptrCast(@alignCast(pipeline.ptr));
    self.pass.call("setPipeline", .{webgpu_pipeline.pipeline}, void);
}

fn setBindGroup(ptr: *anyopaque, group_index: u32, group: *const gpu.BindGroup) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const wbg: *BindGroup = @ptrCast(@alignCast(group.ptr));
    self.pass.call("setBindGroup", .{ @as(i32, @intCast(group_index)), wbg.bind_group }, void);
}

fn setVertexBuffer(ptr: *anyopaque, slot: u32, buf: *const gpu.Buffer, offset: usize, size: usize) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const wbuf: *Buffer = @ptrCast(@alignCast(buf.ptr));
    self.pass.call("setVertexBuffer", .{ @as(i32, @intCast(slot)), wbuf.buffer, @as(f64, @floatFromInt(offset)), @as(f64, @floatFromInt(size)) }, void);
}

fn setIndexBuffer(ptr: *anyopaque, buf: *const gpu.Buffer, offset: usize, size: usize) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    const wbuf: *Buffer = @ptrCast(@alignCast(buf.ptr));
    self.pass.call("setIndexBuffer", .{ wbuf.buffer, zjb.constString("uint32"), @as(f64, @floatFromInt(offset)), @as(f64, @floatFromInt(size)) }, void);
}

fn setScissorRect(ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.pass.call("setScissorRect", .{ @as(i32, @intCast(x)), @as(i32, @intCast(y)), @as(i32, @intCast(w)), @as(i32, @intCast(h)) }, void);
}

fn drawIndexed(ptr: *anyopaque, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    const self: *RenderPass = @ptrCast(@alignCast(ptr));
    self.pass.call("drawIndexed", .{
        @as(i32, @intCast(index_count)),
        @as(i32, @intCast(instance_count)),
        @as(i32, @intCast(first_index)),
        base_vertex,
        @as(i32, @intCast(first_instance)),
    }, void);
}
