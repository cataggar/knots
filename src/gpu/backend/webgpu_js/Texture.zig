const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");

pub const NativeHandle = struct {
    texture: zjb.Handle,
    view: zjb.Handle,
};

const Texture = @This();

allocator: std.mem.Allocator,
texture: zjb.Handle,
view: zjb.Handle,
queue: zjb.Handle,
width: u32,
height: u32,
format: gpu.Texture.Format,
ready: bool,
_native_handle: NativeHandle = undefined,

pub fn create(allocator: std.mem.Allocator, device: zjb.Handle, queue: zjb.Handle, desc: gpu.Texture.Desc) !gpu.Texture {
    var flags: i32 = 0;
    if (desc.usage.texture_binding) flags |= js.TextureUsage.TEXTURE_BINDING;
    if (desc.usage.copy_dst) flags |= js.TextureUsage.COPY_DST;
    if (desc.usage.copy_src) flags |= js.TextureUsage.COPY_SRC;
    if (desc.usage.render_attachment) flags |= js.TextureUsage.RENDER_ATTACHMENT;

    const size = js.obj();
    defer size.release();
    size.set("width", @as(i32, @intCast(desc.width)));
    size.set("height", @as(i32, @intCast(desc.height)));
    size.set("depthOrArrayLayers", @as(i32, 1));

    const tex_desc = js.obj();
    defer tex_desc.release();
    tex_desc.set("size", size);
    tex_desc.set("format", js.textureFormatStr(desc.format));
    tex_desc.set("usage", flags);

    const texture = device.call("createTexture", .{tex_desc}, zjb.Handle);
    const view = texture.call("createView", .{}, zjb.Handle);

    const self = try allocator.create(Texture);
    self.* = .{
        .allocator = allocator,
        .texture = texture,
        .view = view,
        .queue = queue,
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .ready = false,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Texture.VTable{
    .deinit = &deinit,
    .write = &write,
    .is_ready = &isReady,
    .nativeHandle = &nativeHandle,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    self.view.release();
    self.texture.call("destroy", .{}, void);
    self.texture.release();
    self.allocator.destroy(self);
}

fn write(ptr: *anyopaque, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    const bpr = bytes_per_row orelse width * js.bytesPerPixel(self.format);

    const origin = js.obj();
    defer origin.release();
    origin.set("x", @as(i32, @intCast(x)));
    origin.set("y", @as(i32, @intCast(y)));
    origin.set("z", @as(i32, 0));

    const destination = js.obj();
    defer destination.release();
    destination.set("texture", self.texture);
    destination.set("origin", origin);

    const data_layout = js.obj();
    defer data_layout.release();
    data_layout.set("bytesPerRow", @as(i32, @intCast(bpr)));
    data_layout.set("rowsPerImage", @as(i32, @intCast(height)));

    const write_size = js.obj();
    defer write_size.release();
    write_size.set("width", @as(i32, @intCast(width)));
    write_size.set("height", @as(i32, @intCast(height)));
    write_size.set("depthOrArrayLayers", @as(i32, 1));

    const view = zjb.u8ArrayView(data[0..len]);
    defer view.release();

    self.queue.call("writeTexture", .{ destination, view, data_layout, write_size }, void);
    self.ready = true;
}

fn isReady(ptr: *anyopaque) bool {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    return self.ready;
}

fn nativeHandle(ptr: *anyopaque) *anyopaque {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    self._native_handle = .{ .texture = self.texture, .view = self.view };
    return &self._native_handle;
}
