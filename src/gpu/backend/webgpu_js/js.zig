const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");

// GPU*Usage/GPUShaderStage are plain bitflag constants in the WebGPU JS API
// (`GPUBufferUsage.VERTEX`, etc.) -- hardcoded here from the spec rather than
// looked up via zjb at runtime, since they never change.
pub const BufferUsage = struct {
    pub const MAP_READ: i32 = 0x0001;
    pub const MAP_WRITE: i32 = 0x0002;
    pub const COPY_SRC: i32 = 0x0004;
    pub const COPY_DST: i32 = 0x0008;
    pub const INDEX: i32 = 0x0010;
    pub const VERTEX: i32 = 0x0020;
    pub const UNIFORM: i32 = 0x0040;
    pub const STORAGE: i32 = 0x0080;
};

pub const TextureUsage = struct {
    pub const COPY_SRC: i32 = 0x01;
    pub const COPY_DST: i32 = 0x02;
    pub const TEXTURE_BINDING: i32 = 0x04;
    pub const STORAGE_BINDING: i32 = 0x08;
    pub const RENDER_ATTACHMENT: i32 = 0x10;
};

pub const ShaderStage = struct {
    pub const VERTEX: i32 = 0x1;
    pub const FRAGMENT: i32 = 0x2;
};

/// A fresh, empty JS object -- the building block for every WebGPU
/// descriptor (`zjb` has no struct->object marshalling, so descriptors are
/// built field-by-field via `.set`).
pub fn obj() zjb.Handle {
    return zjb.global("Object").new(.{});
}

/// A fresh, empty JS array.
pub fn arr() zjb.Handle {
    return zjb.global("Array").new(.{});
}

pub fn push(a: zjb.Handle, v: anytype) void {
    a.call("push", .{v}, void);
}

pub fn textureFormatStr(f: gpu.Texture.Format) zjb.ConstHandle {
    return switch (f) {
        .rgba8 => zjb.constString("rgba8unorm"),
        .rgba8_srgb => zjb.constString("rgba8unorm-srgb"),
        .bgra8 => zjb.constString("bgra8unorm"),
        .bgra8_srgb => zjb.constString("bgra8unorm-srgb"),
        .r8 => zjb.constString("r8unorm"),
        .rgba32f => zjb.constString("rgba32float"),
        .rgba32u => zjb.constString("rgba32uint"),
    };
}

pub fn formatFromCanvasFormatStr(buf: []const u8) gpu.Texture.Format {
    if (std.mem.eql(u8, buf, "bgra8unorm")) return .bgra8;
    if (std.mem.eql(u8, buf, "rgba8unorm")) return .rgba8;
    @panic("unexpected preferred canvas format");
}

pub fn vertexFormatStr(f: gpu.Pipeline.VertexFormat) zjb.ConstHandle {
    return switch (f) {
        .f32 => zjb.constString("float32"),
        .f32x2 => zjb.constString("float32x2"),
        .f32x3 => zjb.constString("float32x3"),
        .f32x4 => zjb.constString("float32x4"),
    };
}

pub fn blendFactorStr(f: gpu.Pipeline.BlendFactor) zjb.ConstHandle {
    return switch (f) {
        .zero => zjb.constString("zero"),
        .one => zjb.constString("one"),
        .src_alpha => zjb.constString("src-alpha"),
        .one_minus_src_alpha => zjb.constString("one-minus-src-alpha"),
    };
}

pub fn blendOpStr(o: gpu.Pipeline.BlendOp) zjb.ConstHandle {
    return switch (o) {
        .add => zjb.constString("add"),
    };
}

pub fn filterModeStr(f: gpu.Sampler.FilterMode) zjb.ConstHandle {
    return switch (f) {
        .nearest => zjb.constString("nearest"),
        .linear => zjb.constString("linear"),
    };
}

pub fn addressModeStr(m: gpu.Sampler.AddressMode) zjb.ConstHandle {
    return switch (m) {
        .clamp_to_edge => zjb.constString("clamp-to-edge"),
        .repeat => zjb.constString("repeat"),
        .mirror_repeat => zjb.constString("mirror-repeat"),
    };
}

pub fn textureSampleTypeStr(t: gpu.Pipeline.TextureSampleType) zjb.ConstHandle {
    return switch (t) {
        .float => zjb.constString("float"),
        .unfilterable_float => zjb.constString("unfilterable-float"),
        .uint => zjb.constString("uint"),
    };
}

pub fn samplerBindingTypeStr(t: gpu.Pipeline.SamplerBindingType) zjb.ConstHandle {
    return switch (t) {
        .filtering => zjb.constString("filtering"),
        .non_filtering => zjb.constString("non-filtering"),
    };
}

pub fn bytesPerPixel(format: gpu.Texture.Format) u32 {
    return switch (format) {
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .r8 => 1,
        .rgba32f, .rgba32u => 16,
    };
}
