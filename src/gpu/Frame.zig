const RenderPass = @import("RenderPass.zig");

const Frame = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    begin: *const fn (ptr: *anyopaque) anyerror!u32,
    uploadSlotCount: *const fn (ptr: *anyopaque) u32,
    prepareResize: *const fn (ptr: *anyopaque) void,
    beginRenderPass: *const fn (ptr: *anyopaque, desc: RenderPass.Desc) anyerror!RenderPass,
    submit: *const fn (ptr: *anyopaque) anyerror!void,
    waitForCompletion: *const fn (ptr: *anyopaque) anyerror!void,
};

pub const Context = struct {
    frame: *Frame,
    upload_slot: u32,

    pub inline fn beginRenderPass(self: *const Context, desc: RenderPass.Desc) !RenderPass {
        return self.frame.vtable.beginRenderPass(self.frame.ptr, desc);
    }

    pub inline fn submit(self: *Context) !void {
        return self.frame.vtable.submit(self.frame.ptr);
    }
};

pub inline fn deinit(self: *Frame) void {
    self.vtable.deinit(self.ptr);
}

pub inline fn begin(self: *Frame) !Context {
    return .{
        .frame = self,
        .upload_slot = try self.vtable.begin(self.ptr),
    };
}

pub inline fn uploadSlotCount(self: *const Frame) u32 {
    return self.vtable.uploadSlotCount(self.ptr);
}

pub inline fn prepareResize(self: *Frame) void {
    return self.vtable.prepareResize(self.ptr);
}

pub inline fn waitForCompletion(self: *Frame) !void {
    return self.vtable.waitForCompletion(self.ptr);
}
