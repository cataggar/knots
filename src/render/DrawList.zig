//! Mutable tessellation storage. `Packet` is its immutable, ordered projection.

const std = @import("std");
const types = @import("render_types");
const math = @import("math");
const Clip = @import("Clip.zig");
const Packet = @import("Packet.zig");
const GlyphAtlas = @import("GlyphAtlas.zig");

pub const MAX_LAYERS = 256;

pub const Command = @import("Command.zig").Command;
pub const TextureHandle = @import("Command.zig").TextureHandle;
pub const TextureSource = @import("Command.zig").TextureSource;
pub const CustomDrawCallback = @import("Command.zig").CustomDrawCallback;

const LayerRange = struct { start: u32 = 0, len: u32 = 0 };
const BackdropGroup = struct { layer: u8, blur: f32 };
const TextureTag = std.meta.Tag(TextureSource);
const CmdMeta = struct {
    kind: Command.Kind,
    tex_tag: TextureTag = .atlas,
};

inline fn clearList(list: anytype) void {
    if (comptime std.debug.runtime_safety) {
        list.clearRetainingCapacity();
    } else {
        list.items.len = 0;
    }
}

pub const TextBatch = struct {
    clip: Clip.State,
};

allocator: std.mem.Allocator,
vertices: std.ArrayList(types.Vertex),
indices: std.ArrayList(u32),
instances: std.ArrayList(types.Instance),
text_instances: std.ArrayList(types.SlugInstance),
clip_nodes: std.ArrayList(Clip.Node),
layer_cmds: std.ArrayList(Command),
layer_cmd_metas: std.ArrayList(CmdMeta),
layer_ranges: [MAX_LAYERS]LayerRange,
layers_dirty: std.StaticBitSet(MAX_LAYERS),
current_layer: u8,
/// Indexed by group id: one per layer and blur amount.
backdrop_groups: std.ArrayList(BackdropGroup),
/// Packet streams in batched draw order; `vertices` is shared unchanged.
packet_indices: std.ArrayList(u32),
packet_instances: std.ArrayList(types.Instance),
packet_text_instances: std.ArrayList(types.SlugInstance),
/// Layers whose data is in the packet streams since the last reset.
packet_layers: std.StaticBitSet(MAX_LAYERS),
batch_entries: std.ArrayList(BatchEntry),
batch_keys: std.ArrayList(BatchKey),
batch_links: std.ArrayList(BatchLink),
batch_sorted: std.ArrayList(BatchEntry),
batch_counts: std.ArrayList(u32),

const DrawList = @This();

pub fn init(allocator: std.mem.Allocator) DrawList {
    return .{
        .allocator = allocator,
        .indices = .empty,
        .vertices = .empty,
        .instances = .empty,
        .text_instances = .empty,
        .clip_nodes = .empty,
        .layer_cmds = .empty,
        .layer_cmd_metas = .empty,
        .layer_ranges = @splat(.{}),
        .layers_dirty = .empty,
        .current_layer = 0,
        .backdrop_groups = .empty,
        .packet_indices = .empty,
        .packet_instances = .empty,
        .packet_text_instances = .empty,
        .packet_layers = .empty,
        .batch_entries = .empty,
        .batch_keys = .empty,
        .batch_links = .empty,
        .batch_sorted = .empty,
        .batch_counts = .empty,
    };
}

pub fn deinit(self: *DrawList) void {
    self.vertices.deinit(self.allocator);
    self.indices.deinit(self.allocator);
    self.instances.deinit(self.allocator);
    self.text_instances.deinit(self.allocator);
    self.clip_nodes.deinit(self.allocator);
    self.layer_cmds.deinit(self.allocator);
    self.layer_cmd_metas.deinit(self.allocator);
    self.backdrop_groups.deinit(self.allocator);
    self.packet_indices.deinit(self.allocator);
    self.packet_instances.deinit(self.allocator);
    self.packet_text_instances.deinit(self.allocator);
    self.batch_entries.deinit(self.allocator);
    self.batch_keys.deinit(self.allocator);
    self.batch_links.deinit(self.allocator);
    self.batch_sorted.deinit(self.allocator);
    self.batch_counts.deinit(self.allocator);
}

pub fn reset(self: *DrawList) void {
    clearList(&self.vertices);
    clearList(&self.indices);
    clearList(&self.instances);
    clearList(&self.text_instances);
    clearList(&self.clip_nodes);
    clearList(&self.layer_cmds);
    clearList(&self.layer_cmd_metas);
    self.layers_dirty = .empty;
    self.current_layer = 0;
    clearList(&self.backdrop_groups);
    self.clearPacketStreams();
}

fn clearPacketStreams(self: *DrawList) void {
    clearList(&self.packet_indices);
    clearList(&self.packet_instances);
    clearList(&self.packet_text_instances);
    self.packet_layers = .empty;
}

pub fn setLayer(self: *DrawList, layer: u8) void {
    self.current_layer = layer;
}

pub fn isEmpty(self: *const DrawList) bool {
    return self.layer_cmds.items.len == 0;
}

/// Flatten bounded layers into draw order without dropping backend capabilities.
/// The caller retains `portable_commands`; all returned slices are borrowed.
pub fn buildPacket(
    self: *DrawList,
    portable_commands: *std.ArrayList(Command),
    glyph_atlas: ?GlyphAtlas,
) !Packet {
    return self.buildPacketRange(portable_commands, glyph_atlas, 0, MAX_LAYERS);
}

/// Flatten one bounded half-open layer range into draw order, batching draws
/// that share a pipeline and texture where painter's order allows it.
/// Packets built from disjoint layer ranges stay valid together until reset;
/// building an overlapping range invalidates earlier packets.
pub fn buildPacketRange(
    self: *DrawList,
    portable_commands: *std.ArrayList(Command),
    glyph_atlas: ?GlyphAtlas,
    layer_min: u32,
    layer_max: u32,
) !Packet {
    if (self.layer_cmds.items.len > Packet.commands_max) return error.TooManyDrawCommands;
    if (layer_min > layer_max) return error.InvalidLayerRange;
    if (layer_max > MAX_LAYERS) return error.InvalidLayerRange;
    clearList(portable_commands);
    try portable_commands.ensureTotalCapacity(self.allocator, self.layer_cmds.items.len);

    var range_layers: std.StaticBitSet(MAX_LAYERS) = .empty;
    range_layers.setRangeValue(.{ .start = layer_min, .end = layer_max }, true);
    if (self.packet_layers.intersectWith(range_layers).count() > 0) self.clearPacketStreams();
    self.packet_layers.setUnion(range_layers);
    // Disjoint ranges together copy at most every element once, so earlier
    // packets' slices survive later builds.
    try self.packet_indices.ensureTotalCapacity(self.allocator, self.indices.items.len);
    try self.packet_instances.ensureTotalCapacity(self.allocator, self.instances.items.len);
    try self.packet_text_instances.ensureTotalCapacity(self.allocator, self.text_instances.items.len);

    var layer = layer_min;
    while (layer < layer_max) : (layer += 1) {
        if (!self.layers_dirty.isSet(layer)) continue;
        const range = self.layer_ranges[layer];
        const start: usize = range.start;
        const end = start + range.len;
        if (end > self.layer_cmds.items.len) return error.CorruptDrawStream;

        const layer_commands = self.layer_cmds.items[start..end];
        const layer_metas = self.layer_cmd_metas.items[start..end];
        for (layer_commands, layer_metas) |*command, meta| switch (meta.kind) {
            .vertex => {
                const draw = &command.payload.vertex;
                try validateRange(draw.offset, draw.count, self.indices.items.len);
            },
            .instance => {
                const draw = &command.payload.instance;
                try validateRange(draw.offset, draw.count, self.instances.items.len);
            },
            .text => {
                const draw = &command.payload.text;
                try validateRange(draw.offset, draw.count, self.text_instances.items.len);
            },
            .custom_draw, .backdrop => {},
        };

        // Custom draws and backdrops are barriers; batch the runs between them.
        var segment_start: usize = 0;
        for (layer_commands, layer_metas, 0..) |*command, meta, index| switch (meta.kind) {
            .custom_draw, .backdrop => {
                try self.emitBatched(portable_commands, layer_commands[segment_start..index], layer_metas[segment_start..index]);
                portable_commands.addOneAssumeCapacity().* = command.*;
                segment_start = index + 1;
            },
            else => {},
        };
        try self.emitBatched(portable_commands, layer_commands[segment_start..], layer_metas[segment_start..]);
    }

    return .init(
        portable_commands.items,
        self.vertices.items,
        self.packet_indices.items,
        self.packet_instances.items,
        self.packet_text_instances.items,
        self.clip_nodes.items,
        glyph_atlas,
    );
}

const BatchKey = struct {
    command: *const Command,
    meta: CmdMeta,
    /// Highest level assigned to the key so far.
    level: u32 = 0,
};

const BatchEntry = struct {
    command: u32,
    key: u32,
    level: u32,
    bounds: Box,
};

/// Min/max corners in logical pixels.
const Box = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    const empty: Box = .{ .x0 = std.math.inf(f32), .y0 = std.math.inf(f32), .x1 = -std.math.inf(f32), .y1 = -std.math.inf(f32) };

    inline fn add(self: *Box, x: f32, y: f32) void {
        if (x < self.x0) self.x0 = x;
        if (y < self.y0) self.y0 = y;
        if (x > self.x1) self.x1 = x;
        if (y > self.y1) self.y1 = y;
    }

    inline fn merge(self: *Box, other: Box) void {
        if (other.x0 < self.x0) self.x0 = other.x0;
        if (other.y0 < self.y0) self.y0 = other.y0;
        if (other.x1 > self.x1) self.x1 = other.x1;
        if (other.y1 > self.y1) self.y1 = other.y1;
    }

    inline fn overlaps(self: Box, other: Box) bool {
        return self.x0 < other.x1 and other.x0 < self.x1 and self.y0 < other.y1 and other.y0 < self.y1;
    }

    inline fn isFinite(self: Box) bool {
        return std.math.isFinite(self.x0) and std.math.isFinite(self.y0) and
            std.math.isFinite(self.x1) and std.math.isFinite(self.y1) and
            self.x0 <= self.x1 and self.y0 <= self.y1;
    }
};

const grid_axis_max = 64;
const grid_cells_max = grid_axis_max * grid_axis_max;
const batch_keys_max = 256;
/// Covers antialiasing fringes and glyph dilation.
const bounds_padding: f32 = 2;

const BatchLink = struct { entry: u32, next: u32 };
const no_link = std.math.maxInt(u32);

inline fn emitSingle(self: *DrawList, out: *std.ArrayList(Command), command: *const Command, kind: Command.Kind) void {
    const out_cmd = out.addOneAssumeCapacity();
    out_cmd.* = command.*;
    switch (kind) {
        .vertex => {
            const draw = &out_cmd.payload.vertex;
            const src = self.indices.items[draw.offset..][0..draw.count];
            draw.offset = @intCast(self.packet_indices.items.len);
            self.packet_indices.appendSliceAssumeCapacity(src);
        },
        .instance => {
            const draw = &out_cmd.payload.instance;
            const src = self.instances.items[draw.offset..][0..draw.count];
            draw.offset = @intCast(self.packet_instances.items.len);
            self.packet_instances.appendSliceAssumeCapacity(src);
        },
        .text => {
            const draw = &out_cmd.payload.text;
            const src = self.text_instances.items[draw.offset..][0..draw.count];
            draw.offset = @intCast(self.packet_text_instances.items.len);
            self.packet_text_instances.appendSliceAssumeCapacity(src);
        },
        .custom_draw, .backdrop => unreachable,
    }
}

/// Reorder one barrier-free run so commands sharing a pipeline, texture and
/// scissor draw together. Each command gets the lowest level above every
/// earlier overlapping command of another key, and no lower than earlier
/// overlapping commands of its own key; drawing by level keeps every
/// overlapping pair in its original order.
fn emitBatched(self: *DrawList, out: *std.ArrayList(Command), commands: []const Command, metas: []const CmdMeta) !void {
    if (commands.len == 0) return;
    if (commands.len == 1) {
        self.emitSingle(out, &commands[0], metas[0].kind);
        return;
    }
    clearList(&self.batch_entries);
    clearList(&self.batch_keys);
    try self.batch_entries.ensureTotalCapacity(self.allocator, commands.len);

    var ux0: f32 = std.math.inf(f32);
    var uy0: f32 = std.math.inf(f32);
    var ux1: f32 = -std.math.inf(f32);
    var uy1: f32 = -std.math.inf(f32);
    var key_end: u32 = 0;
    var extent_sum_x: f32 = 0;
    var extent_sum_y: f32 = 0;
    var finite_count: u32 = 0;
    for (commands, metas, 0..) |*command, meta, index| {
        const bounds = self.commandBounds(command, meta.kind);
        if (bounds.isFinite()) {
            if (bounds.x0 < ux0) ux0 = bounds.x0;
            if (bounds.y0 < uy0) uy0 = bounds.y0;
            if (bounds.x1 > ux1) ux1 = bounds.x1;
            if (bounds.y1 > uy1) uy1 = bounds.y1;
            extent_sum_x += bounds.x1 - bounds.x0;
            extent_sum_y += bounds.y1 - bounds.y0;
            finite_count += 1;
        }
        const key = try self.batchKey(command, meta);
        const dst_entry = self.batch_entries.addOneAssumeCapacity();
        dst_entry.* = .{
            .command = @intCast(index),
            .key = key,
            .level = 0,
            .bounds = bounds,
        };
        if (key + 1 > key_end) key_end = key + 1;
    }
    if (key_end > 1) {
        var union_box: Box = .{ .x0 = ux0, .y0 = uy0, .x1 = ux1, .y1 = uy1 };
        if (!union_box.isFinite()) union_box = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
        // Unknown bounds overlap everything.
        for (self.batch_entries.items) |*entry| {
            if (!entry.bounds.isFinite()) entry.bounds = union_box;
        }

        // Cells about the size of an average command keep buckets short.
        const raw_w = union_box.x1 - union_box.x0;
        const raw_h = union_box.y1 - union_box.y0;
        const union_w = if (raw_w > 1e-3) raw_w else 1e-3;
        const union_h = if (raw_h > 1e-3) raw_h else 1e-3;
        const count_f: f32 = @floatFromInt(@max(finite_count, 1));
        const cols = gridCells(union_w, extent_sum_x / count_f);
        const rows = gridCells(union_h, extent_sum_y / count_f);
        const cell_w = union_w / @as(f32, @floatFromInt(cols));
        const cell_h = union_h / @as(f32, @floatFromInt(rows));

        // Buckets of earlier entries per cell, as linked lists through `batch_links`.
        var heads_buffer: [grid_cells_max]u32 = undefined;
        const heads = heads_buffer[0 .. cols * rows];
        @memset(heads, no_link);
        clearList(&self.batch_links);
        const entries = self.batch_entries.items;
        try self.batch_links.ensureTotalCapacity(self.allocator, entries.len * 4);
        var level_max: u32 = 0;
        for (entries, 0..) |*entry, entry_index| {
            const cx0 = gridCoord(entry.bounds.x0, union_box.x0, cell_w, cols);
            const cy0 = gridCoord(entry.bounds.y0, union_box.y0, cell_h, rows);
            const cx1 = gridCoord(entry.bounds.x1, union_box.x0, cell_w, cols);
            const cy1 = gridCoord(entry.bounds.y1, union_box.y0, cell_h, rows);
            // Any level at or above the minimum is valid; joining the key's latest
            // batch avoids opening a new draw.
            const tracked = entry.key < self.batch_keys.items.len;
            var level: u32 = if (tracked) self.batch_keys.items[entry.key].level else 0;
            for (cy0..cy1 + 1) |cy| for (cx0..cx1 + 1) |cx| {
                var link = heads[cy * cols + cx];
                while (link != no_link) : (link = self.batch_links.items[link].next) {
                    const other = &entries[self.batch_links.items[link].entry];
                    const needed = if (other.key == entry.key) other.level else other.level + 1;
                    if (needed > level and entry.bounds.overlaps(other.bounds)) level = needed;
                }
            };
            if (tracked) self.batch_keys.items[entry.key].level = level;
            entry.level = level;
            if (level > level_max) level_max = level;
            try self.batch_links.ensureUnusedCapacity(self.allocator, (cy1 - cy0 + 1) * (cx1 - cx0 + 1));
            for (cy0..cy1 + 1) |cy| for (cx0..cx1 + 1) |cx| {
                const head = &heads[cy * cols + cx];
                self.batch_links.appendAssumeCapacity(.{ .entry = @intCast(entry_index), .next = head.* });
                head.* = @intCast(self.batch_links.items.len - 1);
            };
        }

        try self.sortEntries(level_max, key_end);
    }

    var index: usize = 0;
    const entries = self.batch_entries.items;
    while (index < entries.len) {
        const first = &entries[index];
        const first_level = first.level;
        const first_key = first.key;
        const first_kind = metas[first.command].kind;
        const dst_cmd = out.addOneAssumeCapacity();
        dst_cmd.* = commands[first.command];
        var count: u32 = 0;
        switch (first_kind) {
            .vertex => {
                const dst_draw = &dst_cmd.payload.vertex;
                dst_draw.offset = @intCast(self.packet_indices.items.len);
                while (index < entries.len) : (index += 1) {
                    const entry = &entries[index];
                    if (entry.level != first_level or entry.key != first_key) break;
                    const draw = &commands[entry.command].payload.vertex;
                    self.packet_indices.appendSliceAssumeCapacity(self.indices.items[draw.offset..][0..draw.count]);
                    count += draw.count;
                }
                dst_draw.count = count;
            },
            .instance => {
                const dst_draw = &dst_cmd.payload.instance;
                dst_draw.offset = @intCast(self.packet_instances.items.len);
                while (index < entries.len) : (index += 1) {
                    const entry = &entries[index];
                    if (entry.level != first_level or entry.key != first_key) break;
                    const draw = &commands[entry.command].payload.instance;
                    self.packet_instances.appendSliceAssumeCapacity(self.instances.items[draw.offset..][0..draw.count]);
                    count += draw.count;
                }
                dst_draw.count = count;
            },
            .text => {
                const dst_draw = &dst_cmd.payload.text;
                dst_draw.offset = @intCast(self.packet_text_instances.items.len);
                while (index < entries.len) : (index += 1) {
                    const entry = &entries[index];
                    if (entry.level != first_level or entry.key != first_key) break;
                    const draw = &commands[entry.command].payload.text;
                    self.packet_text_instances.appendSliceAssumeCapacity(self.text_instances.items[draw.offset..][0..draw.count]);
                    count += draw.count;
                }
                dst_draw.count = count;
            },
            .custom_draw, .backdrop => unreachable,
        }
    }
}

/// Stable order by (level, key, command): counting sorts by key, then level.
fn sortEntries(self: *DrawList, level_max: u32, key_end: u32) !void {
    const entries = self.batch_entries.items;
    try self.batch_sorted.resize(self.allocator, entries.len);
    try self.batch_counts.resize(self.allocator, @max(level_max + 1, key_end) + 1);
    countingSort(entries, self.batch_sorted.items, self.batch_counts.items[0 .. key_end + 1], "key");
    if (level_max == 0) {
        std.mem.swap(std.ArrayList(BatchEntry), &self.batch_entries, &self.batch_sorted);
        return;
    }
    countingSort(self.batch_sorted.items, entries, self.batch_counts.items[0 .. level_max + 2], "level");
}

fn countingSort(from: []const BatchEntry, to: []BatchEntry, counts: []u32, comptime field: []const u8) void {
    @memset(counts, 0);
    for (from) |*entry| counts[@field(entry, field) + 1] += 1;
    for (1..counts.len) |index| counts[index] += counts[index - 1];
    for (from) |*entry| {
        const slot = &counts[@field(entry, field)];
        to[slot.*] = entry.*;
        slot.* += 1;
    }
}

inline fn gridCells(extent: f32, average: f32) usize {
    const denom = if (average > 1) average else 1;
    const cells = extent / denom;
    if (!(cells > 1)) return 1;
    if (cells >= grid_axis_max) return grid_axis_max;
    return @intFromFloat(cells);
}

inline fn gridCoord(value: f32, origin: f32, cell: f32, cells: usize) usize {
    const coord = @floor((value - origin) / cell);
    if (!(coord > 0)) return 0;
    const last: f32 = @floatFromInt(cells - 1);
    if (coord >= last) return cells - 1;
    return @intFromFloat(coord);
}

/// Commands with equal keys can share one draw.
inline fn batchKey(self: *DrawList, command: *const Command, meta: CmdMeta) !u32 {
    for (self.batch_keys.items, 0..) |*key, index| {
        if (self.keyMatches(key.command, key.meta, command, meta)) return @intCast(index);
    }
    // Past the bound, commands keep unique keys and simply do not merge.
    if (self.batch_keys.items.len == batch_keys_max) return @intCast(batch_keys_max + self.batch_entries.items.len);
    try self.batch_keys.append(self.allocator, .{ .command = command, .meta = meta });
    return @intCast(self.batch_keys.items.len - 1);
}

inline fn keyMatches(_: *const DrawList, other: *const Command, other_meta: CmdMeta, command: *const Command, meta: CmdMeta) bool {
    if (other_meta.kind != meta.kind or other_meta.tex_tag != meta.tex_tag) return false;
    if (!other.clip.scissorEql(command.clip)) return false;
    return switch (meta.kind) {
        .vertex => texturePayloadEql(meta.tex_tag, &command.payload.vertex.texture, &other.payload.vertex.texture),
        .instance => texturePayloadEql(meta.tex_tag, &command.payload.instance.texture, &other.payload.instance.texture),
        .text => true,
        .custom_draw, .backdrop => unreachable,
    };
}

/// Conservative screen bounds of everything the command can touch.
inline fn commandBounds(self: *const DrawList, command: *const Command, kind: Command.Kind) Box {
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    switch (kind) {
        .vertex => {
            const draw = &command.payload.vertex;
            for (self.indices.items[draw.offset..][0..draw.count]) |vertex_index| {
                if (vertex_index >= self.vertices.items.len) return .empty;
                const vertex = &self.vertices.items[vertex_index];
                const vx = vertex.pos[0];
                const vy = vertex.pos[1];
                x0 = @min(vx, x0);
                y0 = @min(vy, y0);
                x1 = @max(vx, x1);
                y1 = @max(vy, y1);
            }
        },
        .instance => {
            const draw = &command.payload.instance;
            for (self.instances.items[draw.offset..][0..draw.count]) |*inst| {
                const ix0 = inst.pos[0];
                const iy0 = inst.pos[1];
                const ix1 = ix0 + inst.size[0];
                const iy1 = iy0 + inst.size[1];
                x0 = @min(@min(ix0, ix1), x0);
                y0 = @min(@min(iy0, iy1), y0);
                x1 = @max(@max(ix0, ix1), x1);
                y1 = @max(@max(iy0, iy1), y1);
            }
        },
        .text => {
            const draw = &command.payload.text;
            for (self.text_instances.items[draw.offset..][0..draw.count]) |*inst| {
                const size = inst.origin_size[2];
                const tx0 = inst.origin_size[0] + inst.bounds[0] * size;
                const ty0 = inst.origin_size[1] - inst.bounds[1] * size;
                const tx1 = inst.origin_size[0] + inst.bounds[2] * size;
                const ty1 = inst.origin_size[1] - inst.bounds[3] * size;
                x0 = @min(@min(tx0, tx1), x0);
                y0 = @min(@min(ty0, ty1), y0);
                x1 = @max(@max(tx0, tx1), x1);
                y1 = @max(@max(ty0, ty1), y1);
            }
        },
        .custom_draw, .backdrop => unreachable,
    }
    var box: Box = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    if (!box.isFinite()) return .empty;
    box.x0 -= bounds_padding;
    box.y0 -= bounds_padding;
    box.x1 += bounds_padding;
    box.y1 += bounds_padding;
    if (command.clip.scissor) |*scissor| {
        const sx = scissor.v[0];
        const sy = scissor.v[1];
        const sx1 = sx + scissor.v[2];
        const sy1 = sy + scissor.v[3];
        box.x0 = @max(sx, box.x0);
        box.y0 = @max(sy, box.y0);
        box.x1 = @min(sx1, box.x1);
        box.y1 = @min(sy1, box.y1);
        // Fully scissored away: draws nothing, so it overlaps nothing.
        if (box.x0 > box.x1 or box.y0 > box.y1) return .{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x0, .y1 = box.y0 };
    }
    return box;
}

inline fn validateRange(offset: u32, count: u32, length: usize) !void {
    const end = @as(u64, offset) + count;
    if (end > @as(u64, @intCast(length))) return error.CorruptDrawStream;
}

inline fn lastCmdMatches(
    self: *const DrawList,
    comptime kind: Command.Kind,
    tex_tag: TextureTag,
    texture: *const TextureSource,
    clip: Clip.State,
) bool {
    if (!self.layers_dirty.isSet(self.current_layer)) return false;
    const range = self.layer_ranges[self.current_layer];
    if (range.len == 0) return false;
    const idx = range.start + range.len - 1;
    const last_meta = self.layer_cmd_metas.items[idx];
    if (last_meta.kind != kind or last_meta.tex_tag != tex_tag) return false;
    const last = &self.layer_cmds.items[idx];
    if (!last.clip.scissorEql(clip)) return false;
    return switch (kind) {
        .vertex => texturePayloadEql(tex_tag, &last.payload.vertex.texture, texture),
        .instance => texturePayloadEql(tex_tag, &last.payload.instance.texture, texture),
        .text => true,
        .custom_draw, .backdrop => false,
    };
}

inline fn texturePayloadEql(tex_tag: TextureTag, a: *const TextureSource, b: *const TextureSource) bool {
    return switch (tex_tag) {
        .atlas => true,
        .texture => std.meta.eql(a.texture, b.texture),
        // Pixel commands stay separate so each command retains its exact update metadata.
        .pixels => false,
    };
}

fn beginCommand(self: *DrawList, meta: CmdMeta, payload: Command.Payload, clip: Clip.State) !void {
    if (self.layer_cmds.items.len == Packet.commands_max) return error.TooManyDrawCommands;
    try self.layer_cmds.ensureUnusedCapacity(self.allocator, 1);
    try self.layer_cmd_metas.ensureUnusedCapacity(self.allocator, 1);
    const range = &self.layer_ranges[self.current_layer];
    if (!self.layers_dirty.isSet(self.current_layer)) {
        range.start = @intCast(self.layer_cmds.items.len);
        range.len = 0;
        self.layers_dirty.set(self.current_layer);
    }
    self.layer_cmds.addOneAssumeCapacity().* = .{ .clip = clip, .payload = payload };
    self.layer_cmd_metas.addOneAssumeCapacity().* = meta;
    range.len += 1;
}

inline fn lastCommand(self: *DrawList) *Command {
    const range = self.layer_ranges[self.current_layer];
    return &self.layer_cmds.items[range.start + range.len - 1];
}

pub fn push(
    self: *DrawList,
    vertices: []const types.Vertex,
    indices: []const u32,
    texture: TextureSource,
    clip: Clip.State,
) !void {
    try self.indices.ensureUnusedCapacity(self.allocator, indices.len);
    try self.vertices.ensureUnusedCapacity(self.allocator, vertices.len);
    const tex_tag = std.meta.activeTag(texture);
    if (!self.lastCmdMatches(.vertex, tex_tag, &texture, clip)) {
        try self.beginCommand(.{ .kind = .vertex, .tex_tag = tex_tag }, .{ .vertex = .{
            .texture = texture,
            .offset = @intCast(self.indices.items.len),
            .count = 0,
        } }, clip);
    }

    const vertex_base: u32 = @intCast(self.vertices.items.len);
    const dst_indices = self.indices.addManyAsSliceAssumeCapacity(indices.len);
    for (dst_indices, indices) |*dst, idx| dst.* = idx + vertex_base;

    const clip_node: f32 = @floatFromInt(clip.node);
    const dst_vertices = self.vertices.addManyAsSliceAssumeCapacity(vertices.len);
    @memcpy(dst_vertices, vertices);
    for (dst_vertices) |*dst| dst.clip_node = clip_node;
    self.lastCommand().payload.vertex.count += @intCast(indices.len);
}

pub fn pushInstances(
    self: *DrawList,
    insts: []const types.Instance,
    texture: TextureSource,
    clip: Clip.State,
) !void {
    if (insts.len == 0) return;
    try self.instances.ensureUnusedCapacity(self.allocator, insts.len);
    const tex_tag = std.meta.activeTag(texture);
    if (!self.lastCmdMatches(.instance, tex_tag, &texture, clip)) {
        try self.beginCommand(.{ .kind = .instance, .tex_tag = tex_tag }, .{ .instance = .{
            .texture = texture,
            .offset = @intCast(self.instances.items.len),
            .count = 0,
        } }, clip);
    }

    const clip_node: f32 = @floatFromInt(clip.node);
    const dst_slice = self.instances.addManyAsSliceAssumeCapacity(insts.len);
    @memcpy(dst_slice, insts);
    for (dst_slice) |*dst| dst.clip_node = clip_node;
    self.lastCommand().payload.instance.count += @intCast(insts.len);
}

pub fn pushCustomDraw(
    self: *DrawList,
    paint: *const @import("Command.zig").PaintCallback,
    bounds: math.Rect,
    clip: Clip.State,
) !void {
    paint.validate();
    try self.beginCommand(.{ .kind = .custom_draw }, .{ .custom_draw = .{
        .paint = paint.*,
        .bounds = bounds,
    } }, clip);
}

/// Filter what is already painted behind `bounds`. Backdrops in one layer with
/// the same blur share the snapshot taken at the first of them.
pub fn pushBackdrop(
    self: *DrawList,
    bounds: math.Rect,
    corner_radius: [4]f32,
    material: types.Material,
    clip: Clip.State,
) !void {
    if (comptime std.debug.runtime_safety) std.debug.assert(material.isValid());
    if (bounds.isEmpty()) return;
    const key: BackdropGroup = .{ .layer = self.current_layer, .blur = material.blur };
    const group = for (self.backdrop_groups.items, 0..) |existing, index| {
        if (std.meta.eql(existing, key)) break index;
    } else blk: {
        if (self.backdrop_groups.items.len == Command.Backdrop.groups_max) return error.TooManyBackdropGroups;
        try self.backdrop_groups.append(self.allocator, key);
        break :blk self.backdrop_groups.items.len - 1;
    };
    try self.beginCommand(.{ .kind = .backdrop }, .{ .backdrop = .{
        .bounds = bounds,
        .corner_radius = corner_radius,
        .material = material,
        .group = @intCast(group),
    } }, clip);
}

pub inline fn beginTextBatch(self: *DrawList, glyph_count_max: usize, clip: Clip.State) !?TextBatch {
    if (glyph_count_max == 0) return null;
    try self.text_instances.ensureUnusedCapacity(self.allocator, glyph_count_max);
    return .{ .clip = clip };
}

pub inline fn pushTextInstance(self: *DrawList, batch: TextBatch, instance: types.SlugInstance) !void {
    if (comptime std.debug.runtime_safety) {
        std.debug.assert(self.text_instances.items.len < self.text_instances.capacity);
        std.debug.assert(instance.origin_size[2] > 0);
    }
    if (!self.lastCmdMatches(.text, .atlas, &.atlas, batch.clip)) {
        try self.beginCommand(.{ .kind = .text, .tex_tag = .atlas }, .{ .text = .{
            .offset = @intCast(self.text_instances.items.len),
            .count = 0,
        } }, batch.clip);
    }

    const dst = self.text_instances.addOneAssumeCapacity();
    dst.* = instance;
    dst.clip_node = @floatFromInt(batch.clip.node);
    self.lastCommand().payload.text.count += 1;
}

test "packet preserves layer order, images, and custom callbacks" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    const vertex: types.Vertex = std.mem.zeroes(types.Vertex);
    draw_list.setLayer(2);
    try draw_list.push(&.{vertex}, &.{0}, .atlas, .{ .node = 2 });
    draw_list.setLayer(0);
    try draw_list.push(&.{vertex}, &.{0}, .atlas, .{ .node = 0 });

    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(@as(usize, 2), packet.commands().len);
    try std.testing.expectEqual(@as(u32, 0), packet.commands()[0].clip.node);
    try std.testing.expectEqual(@as(u32, 2), packet.commands()[1].clip.node);
    try std.testing.expectEqual(@as(usize, 2), packet.primitiveVertices().len);
    try std.testing.expectEqual(@as(usize, 2), packet.primitiveIndices().len);

    draw_list.layer_cmds.items[0].payload.vertex.count = 3;
    try std.testing.expectError(
        error.CorruptDrawStream,
        draw_list.buildPacket(&packet_commands, null),
    );

    draw_list.reset();
    const texture: TextureHandle = .{ .extension = .knots, .pointer = @ptrFromInt(0x1000) };
    try draw_list.push(&.{vertex}, &.{0}, .{ .texture = texture }, .{});
    const image_packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqualDeep(draw_list.layer_cmds.items[0], image_packet.commands()[0]);

    draw_list.reset();
    try draw_list.push(&.{vertex}, &.{0}, .{ .pixels = .{
        .key = 1,
        .data = &.{},
        .width = 1,
        .height = 1,
        .format = .rgba8,
        .bytes_per_row = null,
        .version = 0,
        .force_upload = true,
    } }, .{});
    const pixels_packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqualDeep(draw_list.layer_cmds.items[0], pixels_packet.commands()[0]);

    draw_list.reset();
    try draw_list.pushCustomDraw(&.{ .extension = .knots, .callback = testDrawCallback, .user_data = null }, .zero, .{});
    const custom_packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(testDrawCallback, custom_packet.commands()[0].payload.custom_draw.paint.callback);
}

test "backdrops group per layer and blur" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);
    const rect = math.Rect.init(0, 0, 10, 10);
    const radii: [4]f32 = @splat(2);

    draw_list.setLayer(3);
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 4 }, .{});
    try draw_list.push(&.{std.mem.zeroes(types.Vertex)}, &.{0}, .atlas, .{});
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 4 }, .{});
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 8 }, .{});
    draw_list.setLayer(1);
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 4 }, .{});
    try draw_list.pushBackdrop(.zero, radii, .{ .blur = 4 }, .{});

    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expect(packet.hasBackdrop());
    var groups: std.ArrayList(u32) = .empty;
    defer groups.deinit(std.testing.allocator);
    for (packet.commands()) |command| switch (command.payload) {
        .backdrop => |backdrop| try groups.append(std.testing.allocator, backdrop.group),
        else => {},
    };
    // Packet order puts layer 1 first; empty bounds are dropped.
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 0, 1 }, groups.items);
}

fn testRect(x: f32, y: f32, w: f32, h: f32) types.Instance {
    var inst = comptime std.mem.zeroes(types.Instance);
    inst.pos = .{ x, y };
    inst.size = .{ w, h };
    return inst;
}

fn testGlyph(x: f32, y: f32) types.SlugInstance {
    var inst = comptime std.mem.zeroes(types.SlugInstance);
    // Em box 0..1 at 10px: covers x..x+10, y-10..y.
    inst.bounds = .{ 0, 0, 1, 1 };
    inst.origin_size = .{ x, y, 10, 0.1 };
    return inst;
}

fn testPushGlyph(draw_list: *DrawList, x: f32, y: f32) !void {
    const batch = (try draw_list.beginTextBatch(1, .{})).?;
    try draw_list.pushTextInstance(batch, testGlyph(x, y));
}

test "disjoint widgets batch into one draw per pipeline" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    var row: f32 = 0;
    while (row < 100) : (row += 1) {
        try draw_list.pushInstances(&.{testRect(0, row * 40, 100, 30)}, .atlas, .{});
        try testPushGlyph(&draw_list, 10, row * 40 + 20);
    }
    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(@as(usize, 2), packet.commands().len);
    try std.testing.expect(packet.commands()[0].payload == .instance);
    try std.testing.expectEqual(@as(u32, 100), packet.commands()[0].payload.instance.count);
    try std.testing.expectEqual(@as(u32, 100), packet.commands()[1].payload.text.count);
    try std.testing.expectEqual(@as(f32, 99 * 40), packet.instances()[99].pos[1]);
}

test "overlapping draws keep painter's order" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    // Rect, glyph on it, rect over the glyph, and a disjoint rect.
    try draw_list.pushInstances(&.{testRect(0, 0, 50, 50)}, .atlas, .{});
    try testPushGlyph(&draw_list, 10, 20);
    try draw_list.pushInstances(&.{testRect(5, 5, 20, 20)}, .atlas, .{});
    try testPushGlyph(&draw_list, 200, 220);
    try draw_list.pushInstances(&.{testRect(300, 300, 10, 10)}, .atlas, .{});

    const packet = try draw_list.buildPacket(&packet_commands, null);
    const commands = packet.commands();
    try std.testing.expectEqual(@as(usize, 3), commands.len);
    // The base rect, both glyphs, then both later rects above the first glyph.
    try std.testing.expectEqual(@as(u32, 1), commands[0].payload.instance.count);
    try std.testing.expectEqual(@as(u32, 2), commands[1].payload.text.count);
    try std.testing.expectEqual(@as(u32, 2), commands[2].payload.instance.count);
    try std.testing.expectEqual(@as(f32, 5), packet.instances()[commands[2].payload.instance.offset].pos[0]);
}

test "custom draws stay barriers" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    try draw_list.pushInstances(&.{testRect(0, 0, 10, 10)}, .atlas, .{});
    try draw_list.pushCustomDraw(&.{ .extension = .knots, .callback = testDrawCallback, .user_data = null }, .zero, .{});
    try draw_list.pushInstances(&.{testRect(100, 100, 10, 10)}, .atlas, .{});
    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(@as(usize, 3), packet.commands().len);
    try std.testing.expect(packet.commands()[1].payload == .custom_draw);
}

test "non-overlapping multi-key and single-key segments batch across frames" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    for (0..2) |_| {
        draw_list.reset();
        var row: f32 = 0;
        while (row < 16) : (row += 1) {
            try draw_list.pushInstances(&.{testRect(0, row * 40, 30, 20)}, .atlas, .{});
            try testPushGlyph(&draw_list, 100, row * 40 + 15);
        }
        const packet = try draw_list.buildPacket(&packet_commands, null);
        try std.testing.expectEqual(@as(usize, 2), packet.commands().len);
        try std.testing.expectEqual(@as(u32, 16), packet.commands()[0].payload.instance.count);
        try std.testing.expectEqual(@as(u32, 16), packet.commands()[1].payload.text.count);
    }
}

fn testDrawCallback(_: ?*anyopaque, _: *anyopaque) !void {}
