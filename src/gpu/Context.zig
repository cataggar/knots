const Buffer = @import("Buffer.zig");
const Frame = @import("Frame.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Context = @This();

pub const WindowHandle = union(enum) {
    macos: union(enum) {
        ns_view: *anyopaque,
        ns_window: *anyopaque,
    },
    windows: struct {
        hwnd: *anyopaque,
        hinstance: *anyopaque,
    },
    linux: union(enum) {
        x11: struct {
            display: *anyopaque,
            window: u64,
        },
        wayland: struct {
            display: *anyopaque,
            surface: *anyopaque,
        },
    },
    emscripten: struct {
        selector: []const u8,
    },
};

pub const PresentMode = enum {
    fifo,
    fifo_relaxed,
    immediate,
    mailbox,
};

pub const Config = struct {
    window_width: u32,
    window_height: u32,
    present_mode: PresentMode,
};

ptr: *anyopaque,
vtable: *const VTable,
cfg: Config,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    createBuffer: *const fn (ptr: *anyopaque, size: usize, usage: Buffer.Usage) anyerror!Buffer,
    createFrame: *const fn (ptr: *anyopaque) anyerror!Frame,
    createPipeline: *const fn (ptr: *anyopaque, desc: Pipeline.Desc) anyerror!Pipeline,
    createBindGroup: *const fn (ptr: *anyopaque, desc: BindGroup.Desc) anyerror!BindGroup,
    createTexture: *const fn (ptr: *anyopaque, desc: Texture.Desc) anyerror!Texture,
    createSampler: *const fn (ptr: *anyopaque, desc: Sampler.Desc) anyerror!Sampler,
    resize: *const fn (ptr: *anyopaque, width: u32, height: u32) anyerror!void,
    surfaceFormat: *const fn (ptr: *anyopaque) Texture.Format,
    surfaceIsSrgb: *const fn (ptr: *anyopaque) bool,
};

pub inline fn deinit(self: *const Context) void {
    self.vtable.deinit(self.ptr);
}

pub inline fn createBuffer(self: *const Context, size: usize, usage: Buffer.Usage) !Buffer {
    return self.vtable.createBuffer(self.ptr, size, usage);
}

pub inline fn createFrame(self: *const Context) !Frame {
    return self.vtable.createFrame(self.ptr);
}

pub inline fn createPipeline(self: *const Context, desc: Pipeline.Desc) !Pipeline {
    return self.vtable.createPipeline(self.ptr, desc);
}

pub inline fn createBindGroup(self: *const Context, desc: BindGroup.Desc) !BindGroup {
    return self.vtable.createBindGroup(self.ptr, desc);
}

pub inline fn createTexture(self: *const Context, desc: Texture.Desc) !Texture {
    return self.vtable.createTexture(self.ptr, desc);
}

pub inline fn createSampler(self: *const Context, desc: Sampler.Desc) !Sampler {
    return self.vtable.createSampler(self.ptr, desc);
}

pub inline fn resize(self: *Context, width: u32, height: u32) !void {
    try self.vtable.resize(self.ptr, width, height);
    self.cfg.window_width = width;
    self.cfg.window_height = height;
}

pub inline fn surfaceFormat(self: *const Context) Texture.Format {
    return self.vtable.surfaceFormat(self.ptr);
}

pub inline fn surfaceIsSrgb(self: *const Context) bool {
    return self.vtable.surfaceIsSrgb(self.ptr);
}
