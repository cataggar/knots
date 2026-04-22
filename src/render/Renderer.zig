const std = @import("std");
const gpu = @import("gpu");
const GPUBackend = @import("gpu_backend").Backend;
const text = @import("text");
const Window = @import("window").Window;
const builtin = @import("builtin");

const DrawList = @import("DrawList.zig");

const INIT_VERTEX_BYTES = 256 * 1024;
const INIT_INDEX_COUNT = 64 * 1024;
const MAX_TEXTURES = 16;

pub const Config = struct {
    present_mode: gpu.Context.PresentMode = .fifo,
    gpu_backend: GPUBackend = .preferred(),

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
};

allocator: std.mem.Allocator,
window: Window,
cfg: Config,
ctx: gpu.Context,
pipeline: gpu.Pipeline,
vertex_buf: gpu.Buffer,
index_buf: gpu.Buffer,
atlas_texture: gpu.Texture,
atlas_sampler: gpu.Sampler,
frame: gpu.Frame,
cached_vp_width: u32 = 0,
cached_vp_height: u32 = 0,
registered_textures: [MAX_TEXTURES]?TextureBinding = .{null} ** MAX_TEXTURES,

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

    const pipeline = try ctx.createPipeline(.{});
    errdefer pipeline.deinit();

    const vertex_buf = try ctx.createBuffer(INIT_VERTEX_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer vertex_buf.deinit();

    const atlas_texture = try ctx.createTexture(.{
        .width = 1024,
        .height = 1024,
        .format = .r8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer atlas_texture.deinit();

    const atlas_sampler = try ctx.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    errdefer atlas_sampler.deinit();

    const index_buf = try ctx.createBuffer(INIT_INDEX_COUNT * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer index_buf.deinit();

    return .{
        .allocator = allocator,
        .window = window,
        .cfg = cfg,
        .ctx = ctx,
        .pipeline = pipeline,
        .vertex_buf = vertex_buf,
        .index_buf = index_buf,
        .atlas_texture = atlas_texture,
        .atlas_sampler = atlas_sampler,
        .frame = try ctx.createFrame(),
    };
}

pub fn deinit(self: *Renderer) void {
    self.frame.deinit();
    for (&self.registered_textures) |*entry| {
        if (entry.*) |*reg| {
            reg.texture.deinit();
            reg.sampler.deinit();
        }
    }
    self.pipeline.deinit();
    self.vertex_buf.deinit();
    self.index_buf.deinit();
    self.atlas_texture.deinit();
    self.atlas_sampler.deinit();
    self.ctx.deinit();
}

pub fn createTexture(self: *Renderer, width: u32, height: u32, format: gpu.Texture.Format) !u32 {
    const id = for (0..MAX_TEXTURES) |i| {
        if (self.registered_textures[i] == null) break @as(u32, @intCast(i));
    } else return error.MaxTexturesReached;
    const sampler = try self.ctx.createSampler(.{ .mag_filter = .linear, .min_filter = .linear });
    const texture = try self.ctx.createTexture(.{
        .width = width,
        .height = height,
        .format = format,
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .sampler = &sampler,
    });
    self.registered_textures[id] = .{ .texture = texture, .sampler = sampler };
    return id;
}

pub fn writeTexture(self: *Renderer, id: u32, data: [*]const u8, len: usize, width: u32, height: u32, bytes_per_row: ?u32) void {
    if (self.registered_textures[id]) |reg| {
        reg.texture.write(data, len, width, height, bytes_per_row);
    }
}

pub fn destroyTexture(self: *Renderer, id: u32) void {
    if (id >= MAX_TEXTURES) return;
    if (self.registered_textures[id]) |*reg| {
        reg.texture.deinit();
        reg.sampler.deinit();
        self.registered_textures[id] = null;
    }
}

pub fn resize(self: *Renderer, width: u32, height: u32) !void {
    try self.frame.prepareResize();
    try self.ctx.resize(width, height);
}

pub fn reconfigure(self: *Renderer, new_cfg: Config) !void {
    if (std.meta.eql(new_cfg, self.cfg)) return;
    try new_cfg.validate();

    const allocator = self.allocator;
    const window = self.window;

    try self.frame.waitForCompletion();
    self.deinit();
    self.* = try Renderer.init(allocator, window, new_cfg);
}

pub fn draw(self: *Renderer, dl: *const DrawList, atlas: *text.Atlas, content_scale: f32) !void {
    if (dl.cmds.items.len == 0) return;

    try self.frame.waitForFence();

    self.syncAtlas(atlas);
    if (!self.atlas_texture.isReady()) return;

    // Vertex coords are in logical pixels; surface/scissor are in physical pixels.
    // The GPU rasterizer stretches NDC to the physical surface, so we feed the
    // shader the logical viewport size for correct pixel->NDC mapping.
    const logical_w: u32 = @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_width)) / content_scale);
    const logical_h: u32 = @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_height)) / content_scale);
    if (logical_w != self.cached_vp_width or logical_h != self.cached_vp_height) {
        self.pipeline.updateViewport(logical_w, logical_h);
        self.cached_vp_width = logical_w;
        self.cached_vp_height = logical_h;
    }

    const verts = dl.vertices.items;
    if (verts.len > 0) {
        try ensureBufferCapacity(&self.vertex_buf, verts.len);
        self.vertex_buf.load(u8, verts);
    }
    try ensureBufferCapacity(&self.index_buf, dl.indices.items.len * @sizeOf(u32));
    self.index_buf.load(u32, dl.indices.items);

    var pass = try self.frame.beginRenderPass(.{ .color_attachment = .{} });
    pass.setIndexBuffer(&self.index_buf, 0, dl.indices.items.len * @sizeOf(u32));
    pass.bindPipeline(&self.pipeline);
    pass.setVertexBuffer(0, &self.vertex_buf, 0, verts.len);

    const vw: f32 = @floatFromInt(self.ctx.cfg.window_width);
    const vh: f32 = @floatFromInt(self.ctx.cfg.window_height);
    var current_clip: ?[4]f32 = .{ 0, 0, 0, 0 };
    var current_texture: ?u32 = null;
    for (dl.cmds.items) |cmd| {
        if (cmd.texture != current_texture) {
            if (cmd.texture) |tex_id| {
                if (self.registered_textures[tex_id]) |*reg| {
                    self.pipeline.bindTexture(&reg.texture, &reg.sampler);
                }
            } else {
                self.pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
            }
            pass.rebindTextureSet();
            current_texture = cmd.texture;
        }
        if (!std.meta.eql(current_clip, cmd.clip_rect)) {
            if (cmd.clip_rect) |clip| {
                const cx = @max(0, clip[0] * content_scale);
                const cy = @max(0, clip[1] * content_scale);
                pass.setScissorRect(@intFromFloat(cx), @intFromFloat(cy), @intFromFloat(@max(0, @min(clip[2] * content_scale, vw - cx))), @intFromFloat(@max(0, @min(clip[3] * content_scale, vh - cy))));
            } else {
                pass.setScissorRect(0, 0, self.ctx.cfg.window_width, self.ctx.cfg.window_height);
            }

            current_clip = cmd.clip_rect;
        }
        pass.drawIndexed(cmd.index_count, 1, cmd.index_offset, 0, 0);
    }
    pass.end();
    try self.frame.submit();
}

fn syncAtlas(self: *Renderer, atlas: *text.Atlas) void {
    if (atlas.dirty) {
        self.atlas_texture.write(atlas.bitmap.ptr, atlas.bitmap.len, atlas.width, atlas.height, null);
        atlas.dirty = false;
    }
    // Ensure current_texture_ds is valid for the initial bindPipeline call
    self.pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
}

fn ensureBufferCapacity(buf: *gpu.Buffer, required: usize) !void {
    const current_size = buf.getSize();
    if (required <= current_size) return;
    const new_size = @max(required, current_size + current_size / 2);
    try buf.resize(new_size);
}
