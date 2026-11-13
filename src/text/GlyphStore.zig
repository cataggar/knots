//! Glyph outlines for the Slug shader, one relocatable blob per glyph in a single
//! word buffer, plus a table of per-slot bounds and band transforms.
//!
//! A blob holds band headers, band lists and a point stream. Band headers and lists
//! are relative to the blob, so compaction moves blobs without rewriting them. Points
//! are quantized to u16 inside the glyph's bounds, and consecutive curves of a contour
//! share end points. Slots unused for `eviction_age_frames` are evicted, oldest first,
//! while the store is over its byte budget.

const std = @import("std");
const Curve = @import("curve.zig").Curve;
const band = @import("band.zig");

allocator: std.mem.Allocator,
words: std.ArrayList(u32) = .empty,
table: std.ArrayList(Entry) = .empty,
slots: std.ArrayList(SlotInfo) = .empty,
free_slots: std.ArrayList(u32) = .empty,
dead_words: usize = 0,
budget_bytes: usize = budget_bytes_default,
frame: u32 = 0,
revision_value: u64 = 1,
/// Bumped when slots are evicted, so holders of slot numbers know to look them up again.
generation: u64 = 0,
emitted_revision: u64 = 0,
dirty: Dirty = .{},

const GlyphStore = @This();

pub const budget_bytes_default = 64 * 1024 * 1024;
pub const eviction_age_frames = 2;
pub const empty_slot: u32 = 0;
pub const blob_words_max = std.math.maxInt(u16);

comptime {
    std.debug.assert(eviction_age_frames == 2);
    std.debug.assert(@sizeOf(Entry) == 48);
}

/// GPU layout of one slot, shared with the renderer.
const render = @import("render");
pub const Entry = render.GlyphAtlas.Entry;

const SlotInfo = struct {
    blob: u32,
    words: u32,
    last_used: u32,
    owner: u64,
    live: bool,
};

const Dirty = struct {
    words_start: usize = std.math.maxInt(usize),
    words_end: usize = 0,
    table_start: usize = std.math.maxInt(usize),
    table_end: usize = 0,
    full: bool = true,

    fn markWords(self: *Dirty, start: usize, end: usize) void {
        self.words_start = @min(self.words_start, start);
        self.words_end = @max(self.words_end, end);
    }

    fn markTable(self: *Dirty, slot: usize) void {
        self.table_start = @min(self.table_start, slot);
        self.table_end = @max(self.table_end, slot + 1);
    }
};

pub const Added = struct {
    slot: u32,
    entry: Entry,
};

pub fn init(allocator: std.mem.Allocator) !GlyphStore {
    var store: GlyphStore = .{ .allocator = allocator };
    try store.table.append(allocator, .empty);
    try store.slots.append(allocator, .{ .blob = 0, .words = 0, .last_used = 0, .owner = 0, .live = true });
    try store.words.append(allocator, 0);
    return store;
}

pub fn deinit(self: *GlyphStore) void {
    self.words.deinit(self.allocator);
    self.table.deinit(self.allocator);
    self.slots.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
}

pub fn bytes(self: *const GlyphStore) usize {
    return self.words.items.len * 4 + self.table.items.len * @sizeOf(Entry);
}

pub fn liveBytes(self: *const GlyphStore) usize {
    return self.bytes() - self.dead_words * 4;
}

pub fn touch(self: *GlyphStore, slot: u32) void {
    self.slots.items[slot].last_used = self.frame;
}

pub fn add(self: *GlyphStore, curves: []const Curve, owner: u64) !Added {
    if (curves.len == 0) {
        return .{ .slot = empty_slot, .entry = .empty };
    }
    const blob: u32 = @intCast(self.words.items.len);
    const encoded = try encodeInto(self.allocator, curves, &self.words);
    if (encoded.words_len > blob_words_max) {
        self.words.shrinkRetainingCapacity(blob);
        return .{ .slot = empty_slot, .entry = .empty };
    }
    self.dirty.markWords(blob, self.words.items.len);

    var entry = encoded.entry;
    entry.blob = blob;
    const slot = try self.allocateSlot();
    self.table.items[slot] = entry;
    self.slots.items[slot] = .{ .blob = blob, .words = @intCast(encoded.words_len), .last_used = self.frame, .owner = owner, .live = true };
    self.dirty.markTable(slot);
    self.bumpRevision();
    return .{ .slot = slot, .entry = entry };
}

fn allocateSlot(self: *GlyphStore) !u32 {
    if (self.free_slots.pop()) |slot| {
        return slot;
    }
    try self.table.append(self.allocator, .empty);
    try self.slots.append(self.allocator, undefined);
    return @intCast(self.table.items.len - 1);
}

fn bumpRevision(self: *GlyphStore) void {
    self.revision_value +%= 1;
    if (self.revision_value == 0) {
        self.revision_value = 1;
    }
}

/// Evicts slots unused for `eviction_age_frames`, oldest first, while over budget, and compacts.
/// Returns the owners of evicted slots, valid until the next call.
pub fn endFrame(self: *GlyphStore, evicted: *std.ArrayList(u64)) !void {
    evicted.clearRetainingCapacity();
    defer self.frame +%= 1;
    if (self.liveBytes() > self.budget_bytes) {
        try self.evictOldest(evicted);
    }
    if (self.dead_words > 0 and (self.dead_words * 2 > self.words.items.len or self.bytes() > self.budget_bytes)) {
        try self.compact();
    }
}

fn evictOldest(self: *GlyphStore, evicted: *std.ArrayList(u64)) !void {
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(self.allocator);
    for (self.slots.items[1..], 1..) |info, slot| {
        if (!info.live) {
            continue;
        }
        if (self.frame -% info.last_used < eviction_age_frames) {
            continue;
        }
        try candidates.append(self.allocator, @intCast(slot));
    }
    std.mem.sort(u32, candidates.items, self, struct {
        fn lessThan(store: *GlyphStore, a: u32, b: u32) bool {
            return store.frame -% store.slots.items[a].last_used > store.frame -% store.slots.items[b].last_used;
        }
    }.lessThan);
    for (candidates.items) |slot| {
        if (self.liveBytes() <= self.budget_bytes) {
            break;
        }
        const info = &self.slots.items[slot];
        info.live = false;
        self.dead_words += info.words;
        try evicted.append(self.allocator, info.owner);
        try self.free_slots.append(self.allocator, slot);
        self.table.items[slot] = .empty;
    }
    // In-flight frames may still read evicted slots, so consumers replace their copy.
    self.dirty.full = true;
    if (evicted.items.len > 0) {
        self.generation +%= 1;
    }
    self.bumpRevision();
}

/// Moves live blobs down over dead space. Blobs are relative, so only table offsets change.
fn compact(self: *GlyphStore) !void {
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(self.allocator);
    for (self.slots.items[1..], 1..) |info, slot| {
        if (info.live) {
            try order.append(self.allocator, @intCast(slot));
        }
    }
    std.mem.sort(u32, order.items, self, struct {
        fn lessThan(store: *GlyphStore, a: u32, b: u32) bool {
            return store.slots.items[a].blob < store.slots.items[b].blob;
        }
    }.lessThan);
    var write: u32 = 1;
    for (order.items) |slot| {
        const info = &self.slots.items[slot];
        if (info.blob != write) {
            std.mem.copyForwards(u32, self.words.items[write..][0..info.words], self.words.items[info.blob..][0..info.words]);
        }
        info.blob = write;
        self.table.items[slot].blob = write;
        write += info.words;
    }
    self.words.shrinkRetainingCapacity(write);
    self.dead_words = 0;
    self.dirty.full = true;
    self.bumpRevision();
}

pub const Snapshot = struct {
    revision: u64,
    base_revision: u64,
    words: []const u8,
    table: []const u8,
    /// Byte ranges changed since `base_revision`, valid only for consumers holding that base.
    words_dirty: [2]usize,
    table_dirty: [2]usize,
    full: bool,
};

/// Data for the renderer, with changes since the previous snapshot. Marks the store clean.
pub fn snapshot(self: *GlyphStore) Snapshot {
    const result: Snapshot = .{
        .revision = self.revision_value,
        .base_revision = self.emitted_revision,
        .words = std.mem.sliceAsBytes(self.words.items),
        .table = std.mem.sliceAsBytes(self.table.items),
        .words_dirty = byteRange(self.dirty.words_start, self.dirty.words_end, 4),
        .table_dirty = byteRange(self.dirty.table_start, self.dirty.table_end, @sizeOf(Entry)),
        .full = self.dirty.full,
    };
    self.emitted_revision = self.revision_value;
    self.dirty = .{ .full = false };
    return result;
}

fn byteRange(start: usize, end: usize, size: usize) [2]usize {
    if (start >= end) {
        return .{ 0, 0 };
    }
    return .{ start * size, end * size };
}

const Encoded = struct {
    words: []u32,
    entry: Entry,
};

const EncodedInto = struct {
    words_len: usize,
    entry: Entry,
};

const quant_max: f32 = 65535;

inline fn quantizeScaled(value: f32, min: f32, scale: f32) u16 {
    const scaled = (value - min) * scale;
    return @intFromFloat(std.math.clamp(@round(scaled), 0, quant_max));
}

pub inline fn dequantize(q: u16, min: f32, extent: f32) f32 {
    return min + @as(f32, @floatFromInt(q)) * (extent / quant_max);
}

const Bounds = struct { min: [2]f32, extent: [2]f32 };

inline fn boundsOf(curves: []const Curve) Bounds {
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (curves) |c| {
        min_x = @min(min_x, @min(c.p1[0], @min(c.p2[0], c.p3[0])));
        min_y = @min(min_y, @min(c.p1[1], @min(c.p2[1], c.p3[1])));
        max_x = @max(max_x, @max(c.p1[0], @max(c.p2[0], c.p3[0])));
        max_y = @max(max_y, @max(c.p1[1], @max(c.p2[1], c.p3[1])));
    }
    var extent: [2]f32 = .{ max_x - min_x, max_y - min_y };
    if (extent[0] <= 0) {
        extent[0] = 1;
    }
    if (extent[1] <= 0) {
        extent[1] = 1;
    }
    return .{ .min = .{ min_x, min_y }, .extent = extent };
}

const Point = [2]u16;

inline fn packQuantizedPoint(point: [2]f32, min: [2]f32, quant_scale: [2]f32) u32 {
    const qx = quantizeScaled(point[0], min[0], quant_scale[0]);
    const qy = quantizeScaled(point[1], min[1], quant_scale[1]);
    return @as(u32, qx) | (@as(u32, qy) << 16);
}

inline fn decodePackedPoint(packed_pt: u32, bounds: Bounds, dequant_scale: [2]f32) [2]f32 {
    const qx: u16 = @truncate(packed_pt);
    const qy: u16 = @truncate(packed_pt >> 16);
    return .{
        bounds.min[0] + @as(f32, @floatFromInt(qx)) * dequant_scale[0],
        bounds.min[1] + @as(f32, @floatFromInt(qy)) * dequant_scale[1],
    };
}

fn decodePoint(point: Point, bounds: Bounds) [2]f32 {
    return .{ dequantize(point[0], bounds.min[0], bounds.extent[0]), dequantize(point[1], bounds.min[1], bounds.extent[1]) };
}

const stack_encode_curve_capacity: usize = 256;

fn encodeInto(allocator: std.mem.Allocator, curves_in: []const Curve, out_words: *std.ArrayList(u32)) !EncodedInto {
    const bounds = boundsOf(curves_in);
    const quant_scale: [2]f32 = .{ quant_max / bounds.extent[0], quant_max / bounds.extent[1] };
    const dequant_scale: [2]f32 = .{ bounds.extent[0] / quant_max, bounds.extent[1] / quant_max };
    const use_stack = curves_in.len <= stack_encode_curve_capacity;

    var stack_starts: [stack_encode_curve_capacity]u32 = undefined;
    const starts = if (use_stack) stack_starts[0..curves_in.len] else try allocator.alloc(u32, curves_in.len);
    defer if (!use_stack) allocator.free(starts);

    var stack_decoded: [stack_encode_curve_capacity]Curve = undefined;
    const decoded = if (use_stack) stack_decoded[0..curves_in.len] else try allocator.alloc(Curve, curves_in.len);
    defer if (!use_stack) allocator.free(decoded);

    var stack_points: [stack_encode_curve_capacity * 3]u32 = undefined;
    var heap_points: std.ArrayList(u32) = .empty;
    defer if (!use_stack) heap_points.deinit(allocator);
    if (!use_stack) try heap_points.ensureTotalCapacity(allocator, curves_in.len * 3);

    var points_len: usize = 0;
    var prev_raw_p3: [2]f32 = undefined;
    var prev_packed_p3: u32 = 0;
    var prev_decoded_p3: [2]f32 = undefined;

    for (curves_in, 0..) |c, index| {
        var p1_packed: u32 = undefined;
        var p1_decoded: [2]f32 = undefined;
        if (index > 0 and c.p1[0] == prev_raw_p3[0] and c.p1[1] == prev_raw_p3[1]) {
            p1_packed = prev_packed_p3;
            p1_decoded = prev_decoded_p3;
        } else {
            p1_packed = packQuantizedPoint(c.p1, bounds.min, quant_scale);
            p1_decoded = decodePackedPoint(p1_packed, bounds, dequant_scale);
        }
        const p2_packed = packQuantizedPoint(c.p2, bounds.min, quant_scale);
        const p3_packed = packQuantizedPoint(c.p3, bounds.min, quant_scale);
        const p2_decoded = decodePackedPoint(p2_packed, bounds, dequant_scale);
        const p3_decoded = decodePackedPoint(p3_packed, bounds, dequant_scale);

        if (use_stack) {
            const shares = points_len > 0 and stack_points[points_len - 1] == p1_packed;
            if (!shares) {
                stack_points[points_len] = p1_packed;
                points_len += 1;
            }
            starts[index] = @intCast(points_len - 1);
            stack_points[points_len] = p2_packed;
            stack_points[points_len + 1] = p3_packed;
            points_len += 2;
        } else {
            const shares = heap_points.items.len > 0 and heap_points.items[heap_points.items.len - 1] == p1_packed;
            if (!shares) {
                heap_points.appendAssumeCapacity(p1_packed);
            }
            starts[index] = @intCast(heap_points.items.len - 1);
            heap_points.appendAssumeCapacity(p2_packed);
            heap_points.appendAssumeCapacity(p3_packed);
        }
        decoded[index] = .{ .p1 = p1_decoded, .p2 = p2_decoded, .p3 = p3_decoded };
        prev_raw_p3 = c.p3;
        prev_packed_p3 = p3_packed;
        prev_decoded_p3 = p3_decoded;
    }
    const points_slice = if (use_stack) stack_points[0..points_len] else heap_points.items;
    if (points_slice.len > std.math.maxInt(u16)) {
        return error.GlyphTooComplex;
    }

    var bands_buf: [2 * band.bands_per_axis_max][]u32 = undefined;
    var indices_buf: [2048]u32 = undefined;
    var partition_result = try band.partitionWithBuffer(allocator, decoded, &bands_buf, &indices_buf);
    defer partition_result.deinit(allocator);
    const header_count = partition_result.horizontal_bands.len + partition_result.vertical_bands.len;
    var list_words: usize = 0;
    for (partition_result.horizontal_bands) |entries| list_words += (entries.len + 1) / 2;
    for (partition_result.vertical_bands) |entries| list_words += (entries.len + 1) / 2;
    const points_offset = header_count + list_words;
    if (points_offset > std.math.maxInt(u16)) {
        return error.GlyphTooComplex;
    }
    const total = points_offset + points_slice.len;

    const base_len = out_words.items.len;
    try out_words.ensureUnusedCapacity(allocator, total);
    const words = out_words.items.ptr[base_len .. base_len + total];
    @memset(words[0..points_offset], 0);

    var cursor: usize = header_count;
    var header: usize = 0;
    for ([_][][]u32{ partition_result.horizontal_bands, partition_result.vertical_bands }) |bands| {
        for (bands) |entries| {
            words[header] = @as(u32, @intCast(entries.len)) | (@as(u32, @intCast(cursor)) << 16);
            var pos: usize = 0;
            while (pos + 2 <= entries.len) : (pos += 2) {
                words[cursor + pos / 2] = starts[entries[pos]] | (starts[entries[pos + 1]] << 16);
            }
            if (pos < entries.len) {
                words[cursor + pos / 2] = starts[entries[pos]];
            }
            cursor += (entries.len + 1) / 2;
            header += 1;
        }
    }
    @memcpy(words[points_offset .. points_offset + points_slice.len], points_slice);
    out_words.items.len = base_len + total;

    return .{
        .words_len = total,
        .entry = .{
            .bounds = .{ bounds.min[0], bounds.min[1], bounds.min[0] + bounds.extent[0], bounds.min[1] + bounds.extent[1] },
            .band = .{ partition_result.band_scale[0], partition_result.band_scale[1], partition_result.band_offset[0], partition_result.band_offset[1] },
            .blob = 0,
            .points = @intCast(points_offset),
            .band_max = @as(u32, partition_result.band_index_max[0]) | (@as(u32, partition_result.band_index_max[1]) << 8),
        },
    };
}

pub fn encode(allocator: std.mem.Allocator, curves_in: []const Curve) !Encoded {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(allocator);
    const res = try encodeInto(allocator, curves_in, &list);
    return .{
        .words = try list.toOwnedSlice(allocator),
        .entry = res.entry,
    };
}

/// Reads curve `index` of band list entry back, the way the shader does.
pub fn decodeCurve(words: []const u32, entry: Entry, point_index: u32) Curve {
    const bounds: Bounds = .{ .min = .{ entry.bounds[0], entry.bounds[1] }, .extent = .{ entry.bounds[2] - entry.bounds[0], entry.bounds[3] - entry.bounds[1] } };
    var result: [3][2]f32 = undefined;
    for (&result, 0..) |*point, offset| {
        const word = words[entry.blob + entry.points + point_index + offset];
        point.* = decodePoint(.{ @truncate(word), @truncate(word >> 16) }, bounds);
    }
    return .{ .p1 = result[0], .p2 = result[1], .p3 = result[2] };
}

fn squareCurves() [4]Curve {
    return .{
        .{ .p1 = .{ 0, 0 }, .p2 = .{ 0.5, 0 }, .p3 = .{ 1, 0 } },
        .{ .p1 = .{ 1, 0 }, .p2 = .{ 1, 0.5 }, .p3 = .{ 1, 1 } },
        .{ .p1 = .{ 1, 1 }, .p2 = .{ 0.5, 1 }, .p3 = .{ 0, 1 } },
        .{ .p1 = .{ 0, 1 }, .p2 = .{ 0, 0.5 }, .p3 = .{ 0, 0 } },
    };
}

test "blobs share end points and decode back within quantization error" {
    var store = try GlyphStore.init(std.testing.allocator);
    defer store.deinit();
    const curves = squareCurves();
    const added = try store.add(&curves, 1);
    const info = store.slots.items[added.slot];
    const headers = (added.entry.band_max & 0xFF) + 1 + (added.entry.band_max >> 8) + 1;
    try std.testing.expect(info.words - added.entry.points == 9);
    try std.testing.expect(headers > 0);
    const words = store.words.items;
    for (0..headers) |header| {
        const word = words[info.blob + header];
        const count = word & 0xFFFF;
        const list = word >> 16;
        for (0..count) |position| {
            const packed_word = words[info.blob + list + position / 2];
            const point_index = (packed_word >> @intCast((position % 2) * 16)) & 0xFFFF;
            const decoded = decodeCurve(words, store.table.items[added.slot], point_index);
            var matched = false;
            for (curves) |original| {
                if (@abs(original.p1[0] - decoded.p1[0]) < 1e-4 and @abs(original.p1[1] - decoded.p1[1]) < 1e-4 and
                    @abs(original.p3[0] - decoded.p3[0]) < 1e-4 and @abs(original.p3[1] - decoded.p3[1]) < 1e-4) matched = true;
            }
            try std.testing.expect(matched);
        }
    }
}

test "evicts cold glyphs over budget and compacts the store" {
    var store = try GlyphStore.init(std.testing.allocator);
    defer store.deinit();
    var evicted: std.ArrayList(u64) = .empty;
    defer evicted.deinit(std.testing.allocator);
    const curves = squareCurves();
    const first = try store.add(&curves, 1);
    try store.endFrame(&evicted);
    try store.endFrame(&evicted);
    store.budget_bytes = store.bytes();
    const second = try store.add(&curves, 2);
    try store.endFrame(&evicted);
    try std.testing.expectEqualSlices(u64, &.{1}, evicted.items);
    try std.testing.expect(store.slots.items[second.slot].live);
    try std.testing.expect(!store.slots.items[first.slot].live);
    try std.testing.expectEqual(@as(u32, 1), store.table.items[second.slot].blob);
    try std.testing.expect(store.snapshot().full);
}

test "200k distinct glyphs fit a 4 MiB budget across frames" {
    var store = try GlyphStore.init(std.testing.allocator);
    defer store.deinit();
    store.budget_bytes = 4 * 1024 * 1024;
    var evicted: std.ArrayList(u64) = .empty;
    defer evicted.deinit(std.testing.allocator);
    var curves = squareCurves();
    var count: u64 = 0;
    while (count < 200_000) : (count += 1) {
        curves[1].p2[0] = 1 + @as(f32, @floatFromInt(count % 97)) / 97;
        _ = try store.add(&curves, count);
        if (count % 1000 == 999) {
            try store.endFrame(&evicted);
            try std.testing.expect(store.bytes() <= store.budget_bytes + 1000 * 128);
        }
    }
}
