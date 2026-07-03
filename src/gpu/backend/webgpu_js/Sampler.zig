const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");

const Sampler = @This();

allocator: std.mem.Allocator,
sampler: zjb.Handle,

pub fn create(allocator: std.mem.Allocator, device: zjb.Handle, desc: gpu.Sampler.Desc) !gpu.Sampler {
    const jdesc = js.obj();
    defer jdesc.release();
    jdesc.set("magFilter", js.filterModeStr(desc.mag_filter));
    jdesc.set("minFilter", js.filterModeStr(desc.min_filter));
    jdesc.set("addressModeU", js.addressModeStr(desc.address_mode_u));
    jdesc.set("addressModeV", js.addressModeStr(desc.address_mode_v));

    const sampler = device.call("createSampler", .{jdesc}, zjb.Handle);

    const self = try allocator.create(Sampler);
    self.* = .{
        .allocator = allocator,
        .sampler = sampler,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Sampler.VTable{
    .deinit = &deinit,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Sampler = @ptrCast(@alignCast(ptr));
    self.sampler.release();
    self.allocator.destroy(self);
}
