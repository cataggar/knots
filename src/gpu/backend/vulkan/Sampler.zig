const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Context = @import("Context.zig");

const Sampler = @This();

allocator: std.mem.Allocator,
sampler: vk.Sampler,
vkd: Context.DeviceDispatch,
device: vk.Device,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Sampler.Desc) !gpu.Sampler {
    const sampler = try ctx.vkd.createSampler(ctx.device, &.{
        .mag_filter = toVkFilter(desc.mag_filter),
        .min_filter = toVkFilter(desc.min_filter),
        .mipmap_mode = .nearest,
        .address_mode_u = toVkAddressMode(desc.address_mode_u),
        .address_mode_v = toVkAddressMode(desc.address_mode_v),
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = .false,
    }, null);

    const self = try allocator.create(Sampler);
    self.* = .{
        .allocator = allocator,
        .sampler = sampler,
        .vkd = ctx.vkd,
        .device = ctx.device,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Sampler.VTable{
    .deinit = &deinit,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Sampler = @ptrCast(@alignCast(ptr));
    self.vkd.destroySampler(self.device, self.sampler, null);
    self.allocator.destroy(self);
}

fn toVkFilter(mode: gpu.Sampler.FilterMode) vk.Filter {
    return switch (mode) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn toVkAddressMode(mode: gpu.Sampler.AddressMode) vk.SamplerAddressMode {
    return switch (mode) {
        .clamp_to_edge => .clamp_to_edge,
        .repeat => .repeat,
        .mirror_repeat => .mirrored_repeat,
    };
}
