const std = @import("std");
const gpu = @import("gpu");
const GPUBackend = @import("gpu_backend").Backend;
const text = @import("text");
const Window = @import("window").Window;
const builtin = @import("builtin");

const DrawList = @import("DrawList.zig");
const pipelines = @import("pipelines.zig");

const INIT_VERTEX_BYTES = 256 * 1024;
const INIT_INSTANCE_BYTES = 64 * 1024;
const INIT_INDEX_COUNT = 64 * 1024;
const INIT_TEXT_VERTEX_BYTES = 128 * 1024;
const INIT_TEXT_INDEX_COUNT = 16 * 1024;
const TEX_INDEX_BITS: u5 = 16;
const TEX_INDEX_MASK: u32 = (@as(u32, 1) << TEX_INDEX_BITS) - 1;

const CURVE_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const BAND_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const INITIAL_TEX_HEIGHT: u32 = 256;

pub const Config = struct {
    present_mode: gpu.Context.PresentMode = .fifo,
    gpu_backend: GPUBackend = .preferred(),
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },

    pub const ValidationError = error{
        BackendNotAvailable,
        UnsupportedPresentMode,
    };

    pub fn validate(cfg: Config) ValidationError!void {
        if (!cfg.gpu_backend.isAvailable()) return error.BackendNotAvailable;

        switch (builtin.os.tag) {
            .macos => switch (cfg.present_mode) {
                // Metal/MoltenVK only supports fifo and immediate.
                .fifo_relaxed, .mailbox => return error.UnsupportedPresentMode,
                .fifo, .immediate => {},
            },
            .emscripten => switch (cfg.present_mode) {
                .fifo => {},
                else => return error.UnsupportedPresentMode,
            },
            else => {},
        }
    }
};

const TextureBinding = struct {
    texture: gpu.Texture,
    sampler: gpu.Sampler,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
};

const TextureSlot = struct {
    binding: ?TextureBinding,
    bg: ?gpu.BindGroup = null,
    gen: u16,
};

allocator: std.mem.Allocator,
window: Window,
cfg: Config,
ctx: gpu.Context,
pipeline: gpu.Pipeline,
instance_pipeline: gpu.Pipeline,
text_pipeline: gpu.Pipeline,

vertex_uniform_buf: gpu.Buffer,
instance_uniform_buf: gpu.Buffer,
text_uniform_buf: gpu.Buffer,
vertex_uniform_bg: gpu.BindGroup,
instance_uniform_bg: gpu.BindGroup,
text_uniform_bg: gpu.BindGroup,

atlas_texture_bg: gpu.BindGroup,
text_curveband_bg: gpu.BindGroup,

vertex_buf: gpu.Buffer,
index_buf: gpu.Buffer,
instance_buf: gpu.Buffer,
unit_index_buf: gpu.Buffer,
text_vertex_buf: gpu.Buffer,
text_index_buf: gpu.Buffer,
atlas_texture: gpu.Texture,
atlas_sampler: gpu.Sampler,
curve_texture: gpu.Texture,
band_texture: gpu.Texture,
curve_tex_height: u32,
band_tex_height: u32,
frame: gpu.Frame,
cached_vp_width: u32 = 0,
cached_vp_height: u32 = 0,
texture_slots: std.ArrayList(TextureSlot),
free_slot_indices: std.ArrayList(u32),
draw_list: DrawList,

const Renderer = @This();

pub fn init(allocator: std.mem.Allocator, window: Window, cfg: Config) !Renderer {
    try cfg.validate();

    const fb = window.getFramebufferSize();
    const ctx_cfg = gpu.Context.Config{
        .window_width = fb.width,
        .window_height = fb.height,
        .present_mode = cfg.present_mode,
    };

    const ctx = try cfg.gpu_backend.init(allocator, window.getWindowHandle(), ctx_cfg);
    errdefer ctx.deinit();

    const srgb_surface = ctx.surfaceIsSrgb();

    const pipeline = try ctx.createPipeline(pipelines.primitivesDesc(cfg.gpu_backend, .vertex, srgb_surface));
    errdefer pipeline.deinit();

    const instance_pipeline = try ctx.createPipeline(pipelines.primitivesDesc(cfg.gpu_backend, .instance, srgb_surface));
    errdefer instance_pipeline.deinit();

    const text_pipeline = try ctx.createPipeline(pipelines.slugDesc(cfg.gpu_backend, srgb_surface));
    errdefer text_pipeline.deinit();

    const vertex_uniform_buf = try ctx.createBuffer(@sizeOf(pipelines.ViewportUniform), .{ .uniform = true, .copy_dst = true });
    errdefer vertex_uniform_buf.deinit();
    const instance_uniform_buf = try ctx.createBuffer(@sizeOf(pipelines.ViewportUniform), .{ .uniform = true, .copy_dst = true });
    errdefer instance_uniform_buf.deinit();
    const text_uniform_buf = try ctx.createBuffer(@sizeOf(pipelines.SlugUniforms), .{ .uniform = true, .copy_dst = true });
    errdefer text_uniform_buf.deinit();

    const vertex_uniform_bg = try ctx.createBindGroup(.{
        .label = "vertex_uniform_bg",
        .pipeline = &pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &vertex_uniform_buf, .size = @sizeOf(pipelines.ViewportUniform) } } }},
    });
    errdefer vertex_uniform_bg.deinit();

    const instance_uniform_bg = try ctx.createBindGroup(.{
        .label = "instance_uniform_bg",
        .pipeline = &instance_pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &instance_uniform_buf, .size = @sizeOf(pipelines.ViewportUniform) } } }},
    });
    errdefer instance_uniform_bg.deinit();

    const text_uniform_bg = try ctx.createBindGroup(.{
        .label = "text_uniform_bg",
        .pipeline = &text_pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &text_uniform_buf, .size = @sizeOf(pipelines.SlugUniforms) } } }},
    });
    errdefer text_uniform_bg.deinit();

    const vertex_buf = try ctx.createBuffer(INIT_VERTEX_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer vertex_buf.deinit();

    const instance_buf = try ctx.createBuffer(INIT_INSTANCE_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer instance_buf.deinit();

    const text_vertex_buf = try ctx.createBuffer(INIT_TEXT_VERTEX_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer text_vertex_buf.deinit();

    const atlas_texture = try ctx.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .r8,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer atlas_texture.deinit();

    const atlas_sampler = try ctx.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    errdefer atlas_sampler.deinit();

    const dummy_pixel = [_]u8{0};
    try atlas_texture.write(&dummy_pixel, 1, 0, 0, 1, 1, null);

    const atlas_texture_bg = try ctx.createBindGroup(.{
        .label = "atlas_texture_bg",
        .pipeline = &pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &atlas_texture } },
            .{ .binding = 1, .resource = .{ .sampler = &atlas_sampler } },
        },
    });
    errdefer atlas_texture_bg.deinit();

    const curve_texture = try ctx.createTexture(.{
        .width = CURVE_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32f,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer curve_texture.deinit();

    const band_texture = try ctx.createTexture(.{
        .width = BAND_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32u,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer band_texture.deinit();

    const text_curveband_bg = try ctx.createBindGroup(.{
        .label = "text_curveband_bg",
        .pipeline = &text_pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &curve_texture } },
            .{ .binding = 1, .resource = .{ .texture_view = &band_texture } },
        },
    });
    errdefer text_curveband_bg.deinit();

    const index_buf = try ctx.createBuffer(INIT_INDEX_COUNT * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer index_buf.deinit();

    const text_index_buf = try ctx.createBuffer(INIT_TEXT_INDEX_COUNT * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer text_index_buf.deinit();

    const unit_index_buf = try ctx.createBuffer(6 * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer unit_index_buf.deinit();
    const unit_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    unit_index_buf.load(u32, &unit_indices);

    return .{
        .allocator = allocator,
        .window = window,
        .cfg = cfg,
        .ctx = ctx,
        .pipeline = pipeline,
        .instance_pipeline = instance_pipeline,
        .text_pipeline = text_pipeline,
        .vertex_uniform_buf = vertex_uniform_buf,
        .instance_uniform_buf = instance_uniform_buf,
        .text_uniform_buf = text_uniform_buf,
        .vertex_uniform_bg = vertex_uniform_bg,
        .instance_uniform_bg = instance_uniform_bg,
        .text_uniform_bg = text_uniform_bg,
        .atlas_texture_bg = atlas_texture_bg,
        .text_curveband_bg = text_curveband_bg,
        .vertex_buf = vertex_buf,
        .index_buf = index_buf,
        .instance_buf = instance_buf,
        .unit_index_buf = unit_index_buf,
        .text_vertex_buf = text_vertex_buf,
        .text_index_buf = text_index_buf,
        .atlas_texture = atlas_texture,
        .atlas_sampler = atlas_sampler,
        .curve_texture = curve_texture,
        .band_texture = band_texture,
        .curve_tex_height = INITIAL_TEX_HEIGHT,
        .band_tex_height = INITIAL_TEX_HEIGHT,
        .frame = try ctx.createFrame(),
        .draw_list = .init(allocator),
        .texture_slots = .empty,
        .free_slot_indices = .empty,
    };
}

pub fn deinit(self: *Renderer) void {
    self.draw_list.deinit();
    self.frame.deinit();

    self.atlas_texture_bg.deinit();
    self.text_curveband_bg.deinit();
    self.vertex_uniform_bg.deinit();
    self.instance_uniform_bg.deinit();
    self.text_uniform_bg.deinit();
    self.vertex_uniform_buf.deinit();
    self.instance_uniform_buf.deinit();
    self.text_uniform_buf.deinit();

    for (self.texture_slots.items) |*slot| {
        if (slot.bg) |bg| bg.deinit();
        if (slot.binding) |*reg| {
            reg.texture.deinit();
            reg.sampler.deinit();
        }
    }
    self.texture_slots.deinit(self.allocator);
    self.free_slot_indices.deinit(self.allocator);
    self.pipeline.deinit();
    self.instance_pipeline.deinit();
    self.text_pipeline.deinit();
    self.vertex_buf.deinit();
    self.index_buf.deinit();
    self.instance_buf.deinit();
    self.unit_index_buf.deinit();
    self.text_vertex_buf.deinit();
    self.text_index_buf.deinit();
    self.atlas_texture.deinit();
    self.atlas_sampler.deinit();
    self.curve_texture.deinit();
    self.band_texture.deinit();
    self.ctx.deinit();
}

pub fn createTexture(self: *Renderer, width: u32, height: u32, format: gpu.Texture.Format) !u32 {
    const sampler = try self.ctx.createSampler(.{ .mag_filter = .linear, .min_filter = .linear });
    errdefer sampler.deinit();
    const texture = try self.ctx.createTexture(.{
        .width = width,
        .height = height,
        .format = format,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer texture.deinit();

    const binding: TextureBinding = .{
        .texture = texture,
        .sampler = sampler,
        .width = width,
        .height = height,
        .format = format,
    };

    if (self.free_slot_indices.pop()) |idx| {
        self.texture_slots.items[idx].binding = binding;
        return packTextureId(idx, self.texture_slots.items[idx].gen);
    }

    const idx: u32 = @intCast(self.texture_slots.items.len);
    if (idx > TEX_INDEX_MASK) return error.MaxTexturesReached;
    try self.texture_slots.append(self.allocator, .{ .binding = binding, .gen = 0 });
    return packTextureId(idx, 0);
}

pub fn writeTexture(self: *Renderer, id: u32, data: [*]const u8, len: usize, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const reg = (try self.lookupTexture(id)) orelse return error.InvalidTextureId;
    if (width > reg.width or height > reg.height) return error.InvalidTextureWrite;
    if (len < @as(usize, width) * @as(usize, height) * bytesPerPixel(reg.format)) return error.InvalidTextureWrite;
    try reg.texture.write(data, len, 0, 0, width, height, bytes_per_row);
}

pub fn destroyTexture(self: *Renderer, id: u32) !void {
    const idx = id & TEX_INDEX_MASK;
    if (idx >= self.texture_slots.items.len) return error.InvalidTextureId;
    const slot = &self.texture_slots.items[idx];
    if ((id >> TEX_INDEX_BITS) != slot.gen) return error.InvalidTextureId;
    if (slot.binding) |*reg| {
        if (slot.bg) |bg| bg.deinit();
        slot.bg = null;
        reg.texture.deinit();
        reg.sampler.deinit();
        slot.binding = null;
        slot.gen +%= 1;
        try self.free_slot_indices.append(self.allocator, idx);
    } else return error.InvalidTextureId;
}

fn lookupTexture(self: *Renderer, id: u32) !?*TextureBinding {
    const idx = id & TEX_INDEX_MASK;
    if (idx >= self.texture_slots.items.len) return error.InvalidTextureId;
    const slot = &self.texture_slots.items[idx];
    if ((id >> TEX_INDEX_BITS) != slot.gen) return error.InvalidTextureId;
    if (slot.binding) |*b| return b;
    return null;
}

fn packTextureId(idx: u32, gen: u16) u32 {
    return (@as(u32, gen) << TEX_INDEX_BITS) | (idx & TEX_INDEX_MASK);
}

fn bytesPerPixel(format: gpu.Texture.Format) usize {
    return switch (format) {
        .r8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba32f, .rgba32u => 16,
    };
}

pub fn resize(self: *Renderer, width: u32, height: u32) !void {
    if (width == self.ctx.cfg.window_width and height == self.ctx.cfg.window_height) return;
    self.frame.prepareResize();
    try self.ctx.resize(width, height);
}

/// Tears down all GPU state and re-creates the renderer with the new config.
/// All textures registered via `createTexture` are dropped and their ids invalidated.
pub fn reconfigure(self: *Renderer, new_cfg: Config) !void {
    if (std.meta.eql(new_cfg, self.cfg)) return;
    try new_cfg.validate();

    const allocator = self.allocator;
    const window = self.window;

    try self.frame.waitForCompletion();
    self.deinit();
    self.* = try Renderer.init(allocator, window, new_cfg);
}

pub fn beginFrame(self: *Renderer) *DrawList {
    self.draw_list.reset();
    return &self.draw_list;
}

pub fn endFrame(self: *Renderer, glyph_builder: *text.GlyphBuilder, content_scale: f32) !void {
    return self.draw(&self.draw_list, glyph_builder, content_scale);
}

const FrameSizes = struct {
    verts_bytes: usize,
    insts_bytes: usize,
    indices_bytes: usize,
    tverts_bytes: usize,
    tindices_bytes: usize,
};

fn draw(self: *Renderer, dl: *const DrawList, glyph_builder: *text.GlyphBuilder, content_scale: f32) !void {
    try self.frame.waitForFence();
    try self.syncGlyphBuilder(glyph_builder);

    const has_work = !dl.isEmpty() and self.atlas_texture.isReady();
    if (!has_work) {
        var pass = try self.frame.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color } });
        pass.end();
        try self.frame.submit();
        return;
    }

    self.updateViewport(content_scale);
    const sizes = try self.uploadFrameData(dl);

    var pass = try self.frame.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color } });

    const phys_w = self.ctx.cfg.window_width;
    const phys_h = self.ctx.cfg.window_height;
    var current_clip: ?[4]f32 = null;
    var current_texture: ?u32 = null;
    var current_kind: ?DrawList.CommandKind = null;
    var clip_initialized = false;
    var layer_it = dl.layers_dirty.iterator(.{});
    while (layer_it.next()) |z| {
        const r = dl.layer_ranges[z];
        for (dl.layer_cmds.items[r.start .. r.start + r.len]) |cmd| {
            if (current_kind != cmd.kind) {
                self.bindKind(&pass, cmd.kind, sizes);
                current_texture = null;
                current_kind = cmd.kind;
            }
            if (cmd.kind != .text and cmd.texture != current_texture) {
                try self.bindTextureForCommand(&pass, cmd.texture);
                current_texture = cmd.texture;
            }
            if (!clip_initialized or !std.meta.eql(current_clip, cmd.clip_rect)) {
                applyClip(&pass, cmd.clip_rect, content_scale, phys_w, phys_h);
                current_clip = cmd.clip_rect;
                clip_initialized = true;
            }
            dispatchCommand(&pass, cmd);
        }
    }
    pass.end();
    try self.frame.submit();
}

fn updateViewport(self: *Renderer, content_scale: f32) void {
    const logical_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_width)) / content_scale)));
    const logical_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_height)) / content_scale)));
    if (logical_w == self.cached_vp_width and logical_h == self.cached_vp_height) return;

    const w_f: f32 = @floatFromInt(logical_w);
    const h_f: f32 = @floatFromInt(logical_h);
    const viewport: pipelines.ViewportUniform = .{ w_f, h_f };
    self.vertex_uniform_buf.load(pipelines.ViewportUniform, &.{viewport});
    self.instance_uniform_buf.load(pipelines.ViewportUniform, &.{viewport});

    const u = pipelines.computeSlugUniforms(w_f, h_f, self.ctx.clipSpaceYDown());
    self.text_uniform_buf.load(pipelines.SlugUniforms, &.{u});

    self.cached_vp_width = logical_w;
    self.cached_vp_height = logical_h;
}

fn uploadFrameData(self: *Renderer, dl: *const DrawList) !FrameSizes {
    const verts = dl.vertices.items;
    const insts = dl.instances.items;
    const tverts = dl.text_vertices.items;
    try self.ensureAndLoad(&self.vertex_buf, gpu.Vertex, verts);
    try self.ensureAndLoad(&self.instance_buf, gpu.Instance, insts);
    try self.ensureAndLoad(&self.index_buf, u32, dl.indices.items);
    try self.ensureAndLoad(&self.text_vertex_buf, gpu.SlugVertex, tverts);
    try self.ensureAndLoad(&self.text_index_buf, u32, dl.text_indices.items);
    return .{
        .verts_bytes = verts.len * @sizeOf(gpu.Vertex),
        .insts_bytes = insts.len * @sizeOf(gpu.Instance),
        .indices_bytes = dl.indices.items.len * @sizeOf(u32),
        .tverts_bytes = tverts.len * @sizeOf(gpu.SlugVertex),
        .tindices_bytes = dl.text_indices.items.len * @sizeOf(u32),
    };
}

fn bindKind(self: *Renderer, pass: *gpu.RenderPass, kind: DrawList.CommandKind, sizes: FrameSizes) void {
    switch (kind) {
        .vertex => {
            pass.bindPipeline(&self.pipeline);
            pass.setBindGroup(0, &self.vertex_uniform_bg);
            pass.setBindGroup(1, &self.atlas_texture_bg);
            pass.setVertexBuffer(0, &self.vertex_buf, 0, sizes.verts_bytes);
            pass.setIndexBuffer(&self.index_buf, 0, sizes.indices_bytes);
        },
        .instance => {
            pass.bindPipeline(&self.instance_pipeline);
            pass.setBindGroup(0, &self.instance_uniform_bg);
            pass.setBindGroup(1, &self.atlas_texture_bg);
            pass.setVertexBuffer(0, &self.instance_buf, 0, sizes.insts_bytes);
            pass.setIndexBuffer(&self.unit_index_buf, 0, 6 * @sizeOf(u32));
        },
        .text => {
            pass.bindPipeline(&self.text_pipeline);
            pass.setBindGroup(0, &self.text_uniform_bg);
            pass.setBindGroup(1, &self.text_curveband_bg);
            pass.setVertexBuffer(0, &self.text_vertex_buf, 0, sizes.tverts_bytes);
            pass.setIndexBuffer(&self.text_index_buf, 0, sizes.tindices_bytes);
        },
    }
}

fn bindTextureForCommand(self: *Renderer, pass: *gpu.RenderPass, texture: ?u32) !void {
    if (texture) |tex_id| {
        const idx = tex_id & TEX_INDEX_MASK;
        if (idx >= self.texture_slots.items.len) {
            pass.setBindGroup(1, &self.atlas_texture_bg);
            return;
        }
        const slot = &self.texture_slots.items[idx];
        if ((tex_id >> TEX_INDEX_BITS) != slot.gen or slot.binding == null) {
            pass.setBindGroup(1, &self.atlas_texture_bg);
            return;
        }
        const bg = try self.getOrCreateTextureBg(slot);
        pass.setBindGroup(1, &bg);
    } else {
        pass.setBindGroup(1, &self.atlas_texture_bg);
    }
}

fn getOrCreateTextureBg(self: *Renderer, slot: *TextureSlot) !gpu.BindGroup {
    if (slot.bg) |bg| return bg;
    const reg = &slot.binding.?;
    const bg = try self.ctx.createBindGroup(.{
        .label = "user_texture_bg",
        .pipeline = &self.pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &reg.texture } },
            .{ .binding = 1, .resource = .{ .sampler = &reg.sampler } },
        },
    });
    slot.bg = bg;
    return bg;
}

fn applyClip(pass: *gpu.RenderPass, clip_rect: ?[4]f32, content_scale: f32, phys_w: u32, phys_h: u32) void {
    const vw: f32 = @floatFromInt(phys_w);
    const vh: f32 = @floatFromInt(phys_h);
    if (sanitizeClip(clip_rect)) |clip| {
        const cx = @min(vw, @max(0, clip[0] * content_scale));
        const cy = @min(vh, @max(0, clip[1] * content_scale));
        const cw = @max(0, @min(clip[2] * content_scale, vw - cx));
        const ch = @max(0, @min(clip[3] * content_scale, vh - cy));
        pass.setScissorRect(@intFromFloat(cx), @intFromFloat(cy), @intFromFloat(cw), @intFromFloat(ch));
    } else {
        pass.setScissorRect(0, 0, phys_w, phys_h);
    }
}

fn dispatchCommand(pass: *gpu.RenderPass, cmd: DrawList.Command) void {
    switch (cmd.kind) {
        .vertex => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
        .instance => pass.drawIndexed(6, cmd.count, 0, 0, cmd.offset),
        .text => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
    }
}

fn syncGlyphBuilder(self: *Renderer, gb: *text.GlyphBuilder) !void {
    const needed_curve_h = gb.curveTextureHeight();
    const needed_band_h = gb.bandTextureHeight();

    var curveband_dirty = false;

    if (needed_curve_h > self.curve_tex_height) {
        try self.frame.waitForCompletion();
        self.curve_texture.deinit();
        const new_h = std.math.ceilPowerOfTwo(u32, needed_curve_h) catch needed_curve_h;
        self.curve_texture = try self.ctx.createTexture(.{
            .width = CURVE_TEX_WIDTH,
            .height = new_h,
            .format = .rgba32f,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        self.curve_tex_height = new_h;
        gb.markCurveDirtyTo(needed_curve_h);
        curveband_dirty = true;
    }
    if (needed_band_h > self.band_tex_height) {
        try self.frame.waitForCompletion();
        self.band_texture.deinit();
        const new_h = std.math.ceilPowerOfTwo(u32, needed_band_h) catch needed_band_h;
        self.band_texture = try self.ctx.createTexture(.{
            .width = BAND_TEX_WIDTH,
            .height = new_h,
            .format = .rgba32u,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        self.band_tex_height = new_h;
        gb.markBandDirtyTo(needed_band_h);
        curveband_dirty = true;
    }

    if (gb.curveDirtyRange()) |r| {
        try uploadDirtyRows(
            text.GlyphBuilder.CurveTexel,
            self.allocator,
            &self.curve_texture,
            gb.curve_data.items,
            CURVE_TEX_WIDTH,
            r.y0,
            r.y1,
        );
    }
    if (gb.bandDirtyRange()) |r| {
        try uploadDirtyRows(
            text.GlyphBuilder.BandTexel,
            self.allocator,
            &self.band_texture,
            gb.band_data.items,
            BAND_TEX_WIDTH,
            r.y0,
            r.y1,
        );
    }
    gb.markClean();

    if (curveband_dirty) {
        self.text_curveband_bg.deinit();
        self.text_curveband_bg = try self.ctx.createBindGroup(.{
            .label = "text_curveband_bg",
            .pipeline = &self.text_pipeline,
            .layout_index = 1,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = &self.curve_texture } },
                .{ .binding = 1, .resource = .{ .texture_view = &self.band_texture } },
            },
        });
    }
}

fn uploadDirtyRows(
    comptime T: type,
    allocator: std.mem.Allocator,
    texture: *gpu.Texture,
    items: []const T,
    width: u32,
    y0: u32,
    y1_excl: u32,
) !void {
    const rows = y1_excl - y0;
    const start_idx: usize = @as(usize, y0) * @as(usize, width);
    const end_idx: usize = @as(usize, y1_excl) * @as(usize, width);
    const have_end = @min(end_idx, items.len);

    var slice = items[start_idx..have_end];
    var owned: ?[]T = null;
    defer if (owned) |o| allocator.free(o);

    if (have_end < end_idx) {
        const buf = try allocator.alloc(T, end_idx - start_idx);
        owned = buf;
        @memcpy(buf[0..(have_end - start_idx)], items[start_idx..have_end]);
        @memset(buf[(have_end - start_idx)..], std.mem.zeroes(T));
        slice = buf;
    }

    const ptr: [*]const u8 = @ptrCast(slice.ptr);
    const len = slice.len * @sizeOf(T);
    try texture.write(ptr, len, 0, y0, width, rows, null);
}

fn sanitizeClip(c: ?[4]f32) ?[4]f32 {
    const v = c orelse return null;
    for (v) |f| if (!std.math.isFinite(f)) return null;
    return v;
}

fn ensureBufferCapacity(self: *Renderer, buf: *gpu.Buffer, required: usize) !void {
    const current_size = buf.getSize();
    if (required <= current_size) return;
    const new_size = @max(required, current_size + current_size / 2);
    try self.frame.waitForCompletion();
    try buf.resize(new_size);
}

fn ensureAndLoad(self: *Renderer, buf: *gpu.Buffer, comptime T: type, items: []const T) !void {
    if (items.len == 0) return;
    try self.ensureBufferCapacity(buf, items.len * @sizeOf(T));
    buf.load(T, items);
}
