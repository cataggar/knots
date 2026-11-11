pub const backend = @import("config").backend;

var runtime_backend: @TypeOf(backend) = backend;

pub fn activeBackend() @TypeOf(backend) {
    return runtime_backend;
}

pub fn setActiveBackend(value: @TypeOf(backend)) void {
    runtime_backend = value;
}

pub const Context = @import("Context.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Buffer = @import("Buffer.zig");
pub const Texture = @import("Texture.zig");
pub const Sampler = @import("Sampler.zig");
pub const SurfaceReadback = @import("SurfaceReadback.zig");
