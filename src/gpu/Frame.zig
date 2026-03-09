const RenderPass = @import("RenderPass.zig");

const Frame = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    waitForFence: *const fn (ptr: *anyopaque) anyerror!void,
    prepareResize: *const fn (ptr: *anyopaque) anyerror!void,
    beginRenderPass: *const fn (ptr: *anyopaque, desc: RenderPass.Desc) anyerror!RenderPass,
    submit: *const fn (ptr: *anyopaque) anyerror!void,
    waitForCompletion: *const fn (ptr: *anyopaque) anyerror!void,
};

pub inline fn deinit(self: *Frame) void {
    self.vtable.deinit(self.ptr);
}

pub inline fn waitForFence(self: *Frame) !void {
    return self.vtable.waitForFence(self.ptr);
}

pub inline fn prepareResize(self: *Frame) !void {
    return self.vtable.prepareResize(self.ptr);
}

pub inline fn beginRenderPass(self: *const Frame, desc: RenderPass.Desc) !RenderPass {
    return self.vtable.beginRenderPass(self.ptr, desc);
}

pub inline fn submit(self: *Frame) !void {
    return self.vtable.submit(self.ptr);
}

pub inline fn waitForCompletion(self: *Frame) !void {
    return self.vtable.waitForCompletion(self.ptr);
}
