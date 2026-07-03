const std = @import("std");
const gpu = @import("gpu");
const Context = @import("Context.zig");

pub const bootstrap = @import("bootstrap.zig");

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !gpu.Context {
    return Context.init(allocator, window_handle, cfg);
}
