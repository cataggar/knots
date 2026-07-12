const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");
const pipelines = @import("pipelines.zig");
const Clip = @import("Clip.zig");
const Context = @import("Context.zig");

const INIT_VERTEX_BYTES = 256 * 1024;
const INIT_INSTANCE_BYTES = 64 * 1024;
const INIT_INDEX_COUNT = 64 * 1024;
const INIT_TEXT_VERTEX_BYTES = 128 * 1024;
const INIT_TEXT_INDEX_COUNT = 16 * 1024;
const INIT_CLIP_NODE_COUNT = 64;

vertex_uniform_buf: gpu_impl.Buffer,
instance_uniform_buf: gpu_impl.Buffer,
text_uniform_buf: gpu_impl.Buffer,
vertex_uniform_bg: gpu_impl.BindGroup,
instance_uniform_bg: gpu_impl.BindGroup,
text_uniform_bg: gpu_impl.BindGroup,
vertex_clip_bg: gpu_impl.BindGroup,
instance_clip_bg: gpu_impl.BindGroup,
text_clip_bg: gpu_impl.BindGroup,

vertex_buf: gpu_impl.Buffer,
index_buf: gpu_impl.Buffer,
instance_buf: gpu_impl.Buffer,
composite_instance_buf: gpu_impl.Buffer,
text_vertex_buf: gpu_impl.Buffer,
text_index_buf: gpu_impl.Buffer,
clip_node_buf: gpu_impl.Buffer,

const FrameUploads = @This();

pub fn init(ctx: *Context) !FrameUploads {
    var vertex_uniform_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(pipelines.ViewportUniform), .usage = .{ .uniform = true, .copy_dst = true }, .label = "vertex_viewport_uniform" });
    errdefer vertex_uniform_buf.deinit();
    var instance_uniform_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(pipelines.ViewportUniform), .usage = .{ .uniform = true, .copy_dst = true }, .label = "instance_viewport_uniform" });
    errdefer instance_uniform_buf.deinit();
    var text_uniform_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(pipelines.SlugUniforms), .usage = .{ .uniform = true, .copy_dst = true }, .label = "text_uniforms" });
    errdefer text_uniform_buf.deinit();
    var clip_node_buf = try ctx.device.createBuffer(.{ .size = INIT_CLIP_NODE_COUNT * @sizeOf(Clip.Node), .usage = .{ .storage = true, .copy_dst = true }, .label = "clip_nodes" });
    errdefer clip_node_buf.deinit();
    clip_node_buf.load(Clip.Node, &.{Clip.Node.empty});

    var vertex_uniform_bg = try ctx.device.createBindGroup(.{
        .label = "vertex_uniform_bg",
        .pipeline = &ctx.pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &vertex_uniform_buf, .size = @sizeOf(pipelines.ViewportUniform) } } }},
    });
    errdefer vertex_uniform_bg.deinit();

    var instance_uniform_bg = try ctx.device.createBindGroup(.{
        .label = "instance_uniform_bg",
        .pipeline = &ctx.instance_pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &instance_uniform_buf, .size = @sizeOf(pipelines.ViewportUniform) } } }},
    });
    errdefer instance_uniform_bg.deinit();

    var text_uniform_bg = try ctx.device.createBindGroup(.{
        .label = "text_uniform_bg",
        .pipeline = &ctx.text_pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &text_uniform_buf, .size = @sizeOf(pipelines.SlugUniforms) } } }},
    });
    errdefer text_uniform_bg.deinit();

    var vertex_clip_bg = try createClipBindGroup(&ctx.device, &ctx.pipeline, &clip_node_buf, "vertex_clip_bg");
    errdefer vertex_clip_bg.deinit();
    var instance_clip_bg = try createClipBindGroup(&ctx.device, &ctx.instance_pipeline, &clip_node_buf, "instance_clip_bg");
    errdefer instance_clip_bg.deinit();
    var text_clip_bg = try createClipBindGroup(&ctx.device, &ctx.text_pipeline, &clip_node_buf, "text_clip_bg");
    errdefer text_clip_bg.deinit();

    var vertex_buf = try ctx.device.createBuffer(.{ .size = INIT_VERTEX_BYTES, .usage = .{ .vertex = true, .copy_dst = true }, .label = "ui_vertices" });
    errdefer vertex_buf.deinit();
    var instance_buf = try ctx.device.createBuffer(.{ .size = INIT_INSTANCE_BYTES, .usage = .{ .vertex = true, .copy_dst = true }, .label = "ui_instances" });
    errdefer instance_buf.deinit();
    var composite_instance_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(gpu.Instance), .usage = .{ .vertex = true, .copy_dst = true }, .label = "composite_instance" });
    errdefer composite_instance_buf.deinit();
    var text_vertex_buf = try ctx.device.createBuffer(.{ .size = INIT_TEXT_VERTEX_BYTES, .usage = .{ .vertex = true, .copy_dst = true }, .label = "text_vertices" });
    errdefer text_vertex_buf.deinit();
    var index_buf = try ctx.device.createBuffer(.{ .size = INIT_INDEX_COUNT * @sizeOf(u32), .usage = .{ .index = true, .copy_dst = true }, .label = "ui_indices" });
    errdefer index_buf.deinit();
    var text_index_buf = try ctx.device.createBuffer(.{ .size = INIT_TEXT_INDEX_COUNT * @sizeOf(u32), .usage = .{ .index = true, .copy_dst = true }, .label = "text_indices" });
    errdefer text_index_buf.deinit();

    return .{
        .vertex_uniform_buf = vertex_uniform_buf,
        .instance_uniform_buf = instance_uniform_buf,
        .text_uniform_buf = text_uniform_buf,
        .vertex_uniform_bg = vertex_uniform_bg,
        .instance_uniform_bg = instance_uniform_bg,
        .text_uniform_bg = text_uniform_bg,
        .vertex_clip_bg = vertex_clip_bg,
        .instance_clip_bg = instance_clip_bg,
        .text_clip_bg = text_clip_bg,
        .vertex_buf = vertex_buf,
        .index_buf = index_buf,
        .instance_buf = instance_buf,
        .composite_instance_buf = composite_instance_buf,
        .text_vertex_buf = text_vertex_buf,
        .text_index_buf = text_index_buf,
        .clip_node_buf = clip_node_buf,
    };
}

pub fn deinit(self: *FrameUploads) void {
    self.vertex_clip_bg.deinit();
    self.instance_clip_bg.deinit();
    self.text_clip_bg.deinit();
    self.vertex_uniform_bg.deinit();
    self.instance_uniform_bg.deinit();
    self.text_uniform_bg.deinit();
    self.vertex_uniform_buf.deinit();
    self.instance_uniform_buf.deinit();
    self.text_uniform_buf.deinit();
    self.vertex_buf.deinit();
    self.index_buf.deinit();
    self.instance_buf.deinit();
    self.composite_instance_buf.deinit();
    self.text_vertex_buf.deinit();
    self.text_index_buf.deinit();
    self.clip_node_buf.deinit();
}

pub fn ensureClipNodeCapacity(self: *FrameUploads, context: *Context, required: usize) !void {
    if (required <= self.clip_node_buf.getSize()) return;

    const current_size = self.clip_node_buf.getSize();
    const new_size = @max(required, current_size + current_size / 2);

    const device = &context.device;
    var clip_node_buf = try device.createBuffer(.{ .size = new_size, .usage = .{ .storage = true, .copy_dst = true }, .label = "clip_nodes" });
    errdefer clip_node_buf.deinit();
    clip_node_buf.load(Clip.Node, &.{Clip.Node.empty});

    var vertex_clip_bg = try createClipBindGroup(device, &context.pipeline, &clip_node_buf, "vertex_clip_bg");
    errdefer vertex_clip_bg.deinit();
    var instance_clip_bg = try createClipBindGroup(device, &context.instance_pipeline, &clip_node_buf, "instance_clip_bg");
    errdefer instance_clip_bg.deinit();
    var text_clip_bg = try createClipBindGroup(device, &context.text_pipeline, &clip_node_buf, "text_clip_bg");
    errdefer text_clip_bg.deinit();

    self.vertex_clip_bg.deinit();
    self.instance_clip_bg.deinit();
    self.text_clip_bg.deinit();
    self.clip_node_buf.deinit();
    self.vertex_clip_bg = vertex_clip_bg;
    self.instance_clip_bg = instance_clip_bg;
    self.text_clip_bg = text_clip_bg;
    self.clip_node_buf = clip_node_buf;
}

fn createClipBindGroup(device: *gpu_impl.Device, pipeline: *const gpu_impl.Pipeline, buf: *const gpu_impl.Buffer, label: []const u8) !gpu_impl.BindGroup {
    return device.createBindGroup(.{
        .label = label,
        .pipeline = pipeline,
        .layout_index = 2,
        .entries = &.{.{ .binding = 0, .resource = .{ .read_only_storage_buffer = .{ .buffer = buf, .size = @intCast(buf.getSize()) } } }},
    });
}
