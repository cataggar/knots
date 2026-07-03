const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const BindGroup = @This();

allocator: std.mem.Allocator,
bind_group: zjb.Handle,

pub fn create(allocator: std.mem.Allocator, device: zjb.Handle, desc: gpu.BindGroup.Desc) !gpu.BindGroup {
    const webgpu_pipeline: *Pipeline = @ptrCast(@alignCast(desc.pipeline.ptr));
    const layout = webgpu_pipeline.bindGroupLayout(desc.layout_index);

    const entries_arr = js.arr();
    defer entries_arr.release();

    for (desc.entries) |e| {
        const entry = js.obj();
        defer entry.release();
        entry.set("binding", @as(i32, @intCast(e.binding)));

        switch (e.resource) {
            .buffer, .read_only_storage_buffer => |b| {
                const wbuf: *Buffer = @ptrCast(@alignCast(b.buffer.ptr));
                const resource = js.obj();
                defer resource.release();
                resource.set("buffer", wbuf.buffer);
                resource.set("offset", @as(f64, @floatFromInt(b.offset)));
                const size = if (b.size == 0) wbuf.size - b.offset else b.size;
                resource.set("size", @as(f64, @floatFromInt(size)));
                entry.set("resource", resource);
            },
            .texture_view => |t| {
                const wtex: *Texture = @ptrCast(@alignCast(t.ptr));
                entry.set("resource", wtex.view);
            },
            .sampler => |s| {
                const wsamp: *Sampler = @ptrCast(@alignCast(s.ptr));
                entry.set("resource", wsamp.sampler);
            },
        }
        js.push(entries_arr, entry);
    }

    const bg_desc = js.obj();
    defer bg_desc.release();
    bg_desc.set("layout", layout);
    bg_desc.set("entries", entries_arr);
    var label_handle: ?zjb.Handle = null;
    defer if (label_handle) |h| h.release();
    if (desc.label.len > 0) {
        label_handle = zjb.string(desc.label);
        bg_desc.set("label", label_handle.?);
    }

    const bind_group = device.call("createBindGroup", .{bg_desc}, zjb.Handle);

    const self = try allocator.create(BindGroup);
    self.* = .{
        .allocator = allocator,
        .bind_group = bind_group,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.BindGroup.VTable{
    .deinit = &deinit,
};

fn deinit(ptr: *anyopaque) void {
    const self: *BindGroup = @ptrCast(@alignCast(ptr));
    self.bind_group.release();
    self.allocator.destroy(self);
}
