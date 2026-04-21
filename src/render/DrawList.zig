const std = @import("std");
const gpu = @import("gpu");

pub const Command = struct {
    texture: ?u32,
    index_offset: u32,
    index_count: u32,
    clip_rect: ?[4]f32,
};

const LayerRange = struct { start: u32 = 0, len: u32 = 0 };

allocator: std.mem.Allocator,
vertices: std.ArrayList(u8),
indices: std.ArrayList(u32),
cmds: std.ArrayList(Command),
layer_cmds: std.ArrayList(Command),
layer_ranges: [256]LayerRange,
current_layer: u8,
content_scale: f32 = 1.0,

const DrawList = @This();

pub fn init(allocator: std.mem.Allocator) DrawList {
    return DrawList{
        .allocator = allocator,
        .cmds = .empty,
        .indices = .empty,
        .vertices = .empty,
        .layer_cmds = .empty,
        .layer_ranges = [_]LayerRange{.{}} ** 256,
        .current_layer = 0,
    };
}

pub fn deinit(self: *DrawList) void {
    self.vertices.deinit(self.allocator);
    self.indices.deinit(self.allocator);
    self.cmds.deinit(self.allocator);
    self.layer_cmds.deinit(self.allocator);
}

pub fn reset(self: *DrawList) void {
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.cmds.clearRetainingCapacity();
    self.layer_cmds.clearRetainingCapacity();
    self.layer_ranges = [_]LayerRange{.{}} ** 256;
    self.current_layer = 0;
}

pub fn setLayer(self: *DrawList, layer: u8) void {
    self.current_layer = layer;
}

pub fn push(self: *DrawList, vertices: []const gpu.Vertex, indices: []const u32, texture: ?u32, clip: ?[4]f32) !void {
    const range = &self.layer_ranges[self.current_layer];
    const needs_new_command = blk: {
        if (range.len == 0) break :blk true;
        const last = &self.layer_cmds.items[range.start + range.len - 1];
        break :blk last.texture != texture or !std.meta.eql(last.clip_rect, clip);
    };

    if (needs_new_command) {
        if (range.len == 0) range.start = @intCast(self.layer_cmds.items.len);
        try self.layer_cmds.append(self.allocator, .{
            .texture = texture,
            .index_offset = @intCast(self.indices.items.len),
            .index_count = 0,
            .clip_rect = clip,
        });
        range.len += 1;
    }

    const vertex_base: u32 = @intCast(self.vertices.items.len / @sizeOf(gpu.Vertex));
    try self.indices.ensureUnusedCapacity(self.allocator, indices.len);
    for (indices) |idx| {
        self.indices.appendAssumeCapacity(idx + vertex_base);
    }

    try self.vertices.appendSlice(self.allocator, std.mem.sliceAsBytes(vertices));
    self.layer_cmds.items[range.start + range.len - 1].index_count += @intCast(indices.len);
}

pub fn finalize(self: *DrawList) !void {
    self.cmds.clearRetainingCapacity();
    try self.cmds.ensureTotalCapacity(self.allocator, self.layer_cmds.items.len);
    for (0..256) |z| {
        const range = self.layer_ranges[z];
        if (range.len == 0) continue;
        self.cmds.appendSliceAssumeCapacity(self.layer_cmds.items[range.start .. range.start + range.len]);
    }
}
