const std = @import("std");
const zjb = @import("zjb");
const gpu = @import("gpu");
const js = @import("js.zig");
const Context = @import("Context.zig");

const Pipeline = @This();

allocator: std.mem.Allocator,
pipeline: zjb.Handle,
bind_group_layouts: []zjb.Handle,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Pipeline.Desc) !gpu.Pipeline {
    const wgsl = switch (desc.shader) {
        .wgsl => |s| s,
        .spirv => return error.UnsupportedShaderSource,
    };

    const code_handle = zjb.string(wgsl);
    defer code_handle.release();
    const module_desc = js.obj();
    defer module_desc.release();
    module_desc.set("code", code_handle);
    const shader_module = ctx.device.call("createShaderModule", .{module_desc}, zjb.Handle);
    defer shader_module.release();

    const bgls = try allocator.alloc(zjb.Handle, desc.bind_group_layouts.len);
    errdefer allocator.free(bgls);
    var bgls_created: usize = 0;
    errdefer for (bgls[0..bgls_created]) |bgl| bgl.release();

    for (desc.bind_group_layouts, 0..) |bgl_desc, i| {
        bgls[i] = try createBindGroupLayout(ctx.device, bgl_desc);
        bgls_created += 1;
    }

    const bgl_arr = js.arr();
    defer bgl_arr.release();
    for (bgls) |bgl| js.push(bgl_arr, bgl);

    const layout_desc = js.obj();
    defer layout_desc.release();
    layout_desc.set("bindGroupLayouts", bgl_arr);
    const pipeline_layout = ctx.device.call("createPipelineLayout", .{layout_desc}, zjb.Handle);
    defer pipeline_layout.release();

    const buffers_arr = js.arr();
    defer buffers_arr.release();
    for (desc.vertex_buffers) |vb| {
        const attrs_arr = js.arr();
        defer attrs_arr.release();
        for (vb.attributes) |a| {
            const attr = js.obj();
            defer attr.release();
            attr.set("format", js.vertexFormatStr(a.format));
            attr.set("offset", @as(f64, @floatFromInt(a.offset)));
            attr.set("shaderLocation", @as(i32, @intCast(a.location)));
            js.push(attrs_arr, attr);
        }
        const layout = js.obj();
        defer layout.release();
        layout.set("arrayStride", @as(f64, @floatFromInt(vb.stride)));
        layout.set("stepMode", switch (vb.step_mode) {
            .vertex => zjb.constString("vertex"),
            .instance => zjb.constString("instance"),
        });
        layout.set("attributes", attrs_arr);
        js.push(buffers_arr, layout);
    }

    const vs_entry_handle = zjb.string(desc.vs_entry);
    defer vs_entry_handle.release();
    const vertex_state = js.obj();
    defer vertex_state.release();
    vertex_state.set("module", shader_module);
    vertex_state.set("entryPoint", vs_entry_handle);
    vertex_state.set("buffers", buffers_arr);

    const target_format = desc.color_target.format orelse ctx.surface_format;
    const target = js.obj();
    defer target.release();
    target.set("format", js.textureFormatStr(target_format));
    if (desc.color_target.blend) |b| {
        const color = js.obj();
        defer color.release();
        color.set("srcFactor", js.blendFactorStr(b.color.src_factor));
        color.set("dstFactor", js.blendFactorStr(b.color.dst_factor));
        color.set("operation", js.blendOpStr(b.color.op));

        const alpha = js.obj();
        defer alpha.release();
        alpha.set("srcFactor", js.blendFactorStr(b.alpha.src_factor));
        alpha.set("dstFactor", js.blendFactorStr(b.alpha.dst_factor));
        alpha.set("operation", js.blendOpStr(b.alpha.op));

        const blend = js.obj();
        defer blend.release();
        blend.set("color", color);
        blend.set("alpha", alpha);
        target.set("blend", blend);
    }
    const targets_arr = js.arr();
    defer targets_arr.release();
    js.push(targets_arr, target);

    const fs_entry_handle = zjb.string(desc.fs_entry);
    defer fs_entry_handle.release();
    const fragment_state = js.obj();
    defer fragment_state.release();
    fragment_state.set("module", shader_module);
    fragment_state.set("entryPoint", fs_entry_handle);
    fragment_state.set("targets", targets_arr);

    const pipeline_desc = js.obj();
    defer pipeline_desc.release();
    pipeline_desc.set("layout", pipeline_layout);
    pipeline_desc.set("vertex", vertex_state);
    pipeline_desc.set("fragment", fragment_state);
    var label_handle: ?zjb.Handle = null;
    defer if (label_handle) |h| h.release();
    if (desc.label.len > 0) {
        label_handle = zjb.string(desc.label);
        pipeline_desc.set("label", label_handle.?);
    }

    // Synchronous `createRenderPipeline` (not `createRenderPipelineAsync`) to
    // avoid a third async round trip in this backend's already-async
    // startup sequence -- accepted tradeoff: shader compilation may briefly
    // stall the main thread. knots only creates a small, fixed set of
    // pipelines at startup/config-change time, so this is a one-time cost.
    const pipeline = ctx.device.call("createRenderPipeline", .{pipeline_desc}, zjb.Handle);

    const self = try allocator.create(Pipeline);
    self.* = .{
        .allocator = allocator,
        .pipeline = pipeline,
        .bind_group_layouts = bgls,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn createBindGroupLayout(device: zjb.Handle, bgl_desc: gpu.Pipeline.BindGroupLayoutDesc) !zjb.Handle {
    const entries_arr = js.arr();
    defer entries_arr.release();

    for (bgl_desc.entries) |e| {
        const entry = js.obj();
        defer entry.release();
        entry.set("binding", @as(i32, @intCast(e.binding)));

        var visibility: i32 = 0;
        if (e.visibility.vertex) visibility |= js.ShaderStage.VERTEX;
        if (e.visibility.fragment) visibility |= js.ShaderStage.FRAGMENT;
        entry.set("visibility", visibility);

        switch (e.type) {
            .uniform_buffer => {
                const buffer = js.obj();
                defer buffer.release();
                buffer.set("type", zjb.constString("uniform"));
                entry.set("buffer", buffer);
            },
            .read_only_storage_buffer => {
                const buffer = js.obj();
                defer buffer.release();
                buffer.set("type", zjb.constString("read-only-storage"));
                entry.set("buffer", buffer);
            },
            .sampled_texture => |st| {
                const texture = js.obj();
                defer texture.release();
                texture.set("sampleType", js.textureSampleTypeStr(st));
                texture.set("viewDimension", zjb.constString("2d"));
                entry.set("texture", texture);
            },
            .sampler => |sb| {
                const sampler = js.obj();
                defer sampler.release();
                sampler.set("type", js.samplerBindingTypeStr(sb));
                entry.set("sampler", sampler);
            },
        }
        js.push(entries_arr, entry);
    }

    const layout_desc = js.obj();
    defer layout_desc.release();
    layout_desc.set("entries", entries_arr);
    var label_handle: ?zjb.Handle = null;
    defer if (label_handle) |h| h.release();
    if (bgl_desc.label.len > 0) {
        label_handle = zjb.string(bgl_desc.label);
        layout_desc.set("label", label_handle.?);
    }

    return device.call("createBindGroupLayout", .{layout_desc}, zjb.Handle);
}

const vtable = gpu.Pipeline.VTable{
    .deinit = &deinit,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    self.pipeline.release();
    for (self.bind_group_layouts) |bgl| bgl.release();
    self.allocator.free(self.bind_group_layouts);
    self.allocator.destroy(self);
}

pub fn bindGroupLayout(self: *const Pipeline, index: u32) zjb.Handle {
    return self.bind_group_layouts[index];
}
