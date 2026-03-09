const Buffer = @This();

pub const Usage = struct {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    copy_dst: bool = false,
    copy_src: bool = false,
    storage: bool = false,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    load: *const fn (ptr: *anyopaque, data: [*]const u8, len: usize) void,
    getSize: *const fn (ptr: *anyopaque) usize,
    resize: *const fn (ptr: *anyopaque, new_size: usize) anyerror!void,
};

pub fn deinit(self: *const Buffer) void {
    self.vtable.deinit(self.ptr);
}

pub fn load(self: *const Buffer, comptime T: type, data: []const T) void {
    self.vtable.load(self.ptr, @ptrCast(data.ptr), data.len * @sizeOf(T));
}

pub fn getSize(self: *const Buffer) usize {
    return self.vtable.getSize(self.ptr);
}

pub fn resize(self: *const Buffer, new_size: usize) !void {
    return self.vtable.resize(self.ptr, new_size);
}
