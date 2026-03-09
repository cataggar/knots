const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");

const Sampler = @This();

allocator: std.mem.Allocator,
sampler: wgpu.Sampler,

pub fn create(allocator: std.mem.Allocator, device: wgpu.Device, desc: gpu.Sampler.Desc) !gpu.Sampler {
    const sampler = try device.createSampler(.{
        .mag_filter = toWgpuFilter(desc.mag_filter),
        .min_filter = toWgpuFilter(desc.min_filter),
        .address_mode_u = toWgpuAddressMode(desc.address_mode_u),
        .address_mode_v = toWgpuAddressMode(desc.address_mode_v),
    });

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
    self.sampler.deinit();
    self.allocator.destroy(self);
}

fn toWgpuFilter(mode: gpu.Sampler.FilterMode) wgpu.Sampler.FilterMode {
    return switch (mode) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn toWgpuAddressMode(mode: gpu.Sampler.AddressMode) wgpu.Sampler.AddressMode {
    return switch (mode) {
        .clamp_to_edge => .clamp_to_edge,
        .repeat => .repeat,
        .mirror_repeat => .mirror_repeat,
    };
}
