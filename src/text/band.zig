const std = @import("std");
const Curve = @import("curve.zig").Curve;

// The shader stores each axis's maximum band index in a u8.
pub const bands_per_axis_max: u32 = 16;

const band_epsilon: f32 = 1.0 / 65536.0;
const curves_per_band_target: f32 = 4.0;
const stack_curve_capacity: usize = 256;
const per_band_insertion_limit: usize = 32;
// Sentinel byte where first_band (15) > last_band (0), which cannot occur for any valid overlap.
const no_band_overlap: u8 = 0xF0;

comptime {
    std.debug.assert(bands_per_axis_max > 0);
    std.debug.assert(bands_per_axis_max <= 16);
    std.debug.assert(bands_per_axis_max - 1 <= std.math.maxInt(u8));
}

pub const PartitionResult = struct {
    band_index_max: [2]u8,
    band_scale: [2]f32,
    band_offset: [2]f32,
    horizontal_bands: [][]u32,
    vertical_bands: [][]u32,
    backing_indices: []u32 = &.{},
    bounding_box_min: [2]f32,
    bounding_box_max: [2]f32,
    owns_bands: bool = true,
    owns_indices: bool = true,

    pub fn deinit(self: *PartitionResult, allocator: std.mem.Allocator) void {
        if (self.owns_indices and self.backing_indices.len > 0) allocator.free(self.backing_indices);
        if (self.owns_bands) {
            const all_bands = self.horizontal_bands.ptr[0 .. self.horizontal_bands.len + self.vertical_bands.len];
            allocator.free(all_bands);
        }
        self.* = undefined;
    }
};

const Bounds = extern struct {
    min: [2]f32,
    max: [2]f32,
};

comptime {
    std.debug.assert(@sizeOf(Bounds) == 4 * @sizeOf(u32));
    std.debug.assert(@alignOf(Bounds) == @alignOf(u32));
}

fn emptyPartition(
    allocator: std.mem.Allocator,
    bands_buf: ?*[2 * bands_per_axis_max][]u32,
) !PartitionResult {
    const all_bands = if (bands_buf) |buf| buf[0..2] else try allocator.alloc([]u32, 2);
    all_bands[0] = &.{};
    all_bands[1] = &.{};

    return .{
        .band_index_max = .{ 0, 0 },
        .band_scale = .{ 0, 0 },
        .band_offset = .{ 0, 0 },
        .horizontal_bands = all_bands[0..1],
        .vertical_bands = all_bands[1..2],
        .backing_indices = &.{},
        .bounding_box_min = .{ 0, 0 },
        .bounding_box_max = .{ 0, 0 },
        .owns_bands = bands_buf == null,
        .owns_indices = false,
    };
}

inline fn computeCurveExtents(curves: []const Curve, extents: []Bounds) Bounds {
    if (comptime std.debug.runtime_safety) {
        std.debug.assert(curves.len > 0);
        std.debug.assert(extents.len == curves.len);
    }

    var bounds_min_x: f32 = std.math.inf(f32);
    var bounds_min_y: f32 = std.math.inf(f32);
    var bounds_max_x: f32 = -std.math.inf(f32);
    var bounds_max_y: f32 = -std.math.inf(f32);
    for (curves, extents) |curve, *extent| {
        const p1 = curve.p1;
        const p2 = curve.p2;
        const p3 = curve.p3;
        if (comptime std.debug.runtime_safety) {
            inline for ([_][2]f32{ p1, p2, p3 }) |point| {
                std.debug.assert(std.math.isFinite(point[0]));
                std.debug.assert(std.math.isFinite(point[1]));
            }
        }
        const min_x = @min(p1[0], @min(p2[0], p3[0]));
        const min_y = @min(p1[1], @min(p2[1], p3[1]));
        const max_x = @max(p1[0], @max(p2[0], p3[0]));
        const max_y = @max(p1[1], @max(p2[1], p3[1]));
        extent.* = .{ .min = .{ min_x, min_y }, .max = .{ max_x, max_y } };
        bounds_min_x = @min(bounds_min_x, min_x);
        bounds_min_y = @min(bounds_min_y, min_y);
        bounds_max_x = @max(bounds_max_x, max_x);
        bounds_max_y = @max(bounds_max_y, max_y);
    }
    return .{
        .min = .{ bounds_min_x, bounds_min_y },
        .max = .{ bounds_max_x, bounds_max_y },
    };
}

pub fn partition(allocator: std.mem.Allocator, curves: []const Curve) !PartitionResult {
    return partitionWithBuffer(allocator, curves, null, &.{});
}

pub fn partitionWithBuffer(
    allocator: std.mem.Allocator,
    curves: []const Curve,
    bands_buf: ?*[2 * bands_per_axis_max][]u32,
    indices_buf: []u32,
) !PartitionResult {
    if (curves.len == 0) return emptyPartition(allocator, bands_buf);
    if (curves.len > std.math.maxInt(u32)) return error.TooManyCurves;

    const n = curves.len;
    var stack_extents: [stack_curve_capacity]Bounds = undefined;
    var stack_scratch_indices: [stack_curve_capacity]u32 = undefined;
    var stack_sort_keys: [stack_curve_capacity]f32 = undefined;
    var stack_h_ranges: [stack_curve_capacity]u8 = undefined;
    var stack_v_ranges: [stack_curve_capacity]u8 = undefined;

    var heap_scratch: []u32 = &.{};
    defer if (heap_scratch.len > 0) allocator.free(heap_scratch);

    var extents: []Bounds = undefined;
    var scratch_indices: []u32 = undefined;
    var sort_keys: []f32 = undefined;
    var h_ranges: []u8 = undefined;
    var v_ranges: []u8 = undefined;
    if (n <= stack_curve_capacity) {
        extents = stack_extents[0..n];
        scratch_indices = stack_scratch_indices[0..n];
        sort_keys = stack_sort_keys[0..n];
        h_ranges = stack_h_ranges[0..n];
        v_ranges = stack_v_ranges[0..n];
    } else {
        heap_scratch = try allocator.alloc(u32, n * 7);
        extents = @as([*]Bounds, @ptrCast(heap_scratch.ptr))[0..n];
        scratch_indices = heap_scratch[n * 4 .. n * 5];
        sort_keys = @as([*]f32, @ptrCast(heap_scratch[n * 5 .. n * 6].ptr))[0..n];
        const range_bytes = std.mem.sliceAsBytes(heap_scratch[n * 6 .. n * 7]);
        h_ranges = range_bytes[0..n];
        v_ranges = range_bytes[n .. n * 2];
    }

    const bounds = computeCurveExtents(curves, extents);
    var span = [2]f32{
        bounds.max[0] - bounds.min[0],
        bounds.max[1] - bounds.min[1],
    };
    inline for (&span) |*axis_span| {
        if (axis_span.* <= 0) axis_span.* = 1;
    }

    const curve_count_float: f32 = @floatFromInt(curves.len);
    const band_count_raw: u32 = @intFromFloat(
        @round(curve_count_float / curves_per_band_target),
    );
    const band_count_x: u32 = @max(1, @min(band_count_raw, bands_per_axis_max));
    const band_count_y: u32 = band_count_x;

    const band_scale = [2]f32{
        @as(f32, @floatFromInt(band_count_x)) / span[0],
        @as(f32, @floatFromInt(band_count_y)) / span[1],
    };
    const band_offset = [2]f32{
        -bounds.min[0] * band_scale[0],
        -bounds.min[1] * band_scale[1],
    };

    var h_counts: [bands_per_axis_max]usize = undefined;
    const h_refs = computeAxisBandRanges(
        extents,
        band_count_y,
        bounds.min[1],
        span[1],
        1,
        h_ranges,
        &h_counts,
    );

    var v_counts: [bands_per_axis_max]usize = undefined;
    const v_refs = computeAxisBandRanges(
        extents,
        band_count_x,
        bounds.min[0],
        span[0],
        0,
        v_ranges,
        &v_counts,
    );

    const total_bands: usize = band_count_y + band_count_x;
    const owns_bands = bands_buf == null;
    const all_bands = if (bands_buf) |buf|
        buf[0..total_bands]
    else
        try allocator.alloc([]u32, total_bands);
    errdefer if (owns_bands) allocator.free(all_bands);
    const horizontal_bands = all_bands[0..band_count_y];
    const vertical_bands = all_bands[band_count_y..total_bands];

    const total_refs = h_refs + v_refs;
    const owns_indices = total_refs > indices_buf.len;
    const backing_indices: []u32 = if (total_refs == 0)
        &.{}
    else if (!owns_indices)
        indices_buf[0..total_refs]
    else
        try allocator.alloc(u32, total_refs);

    var offset: usize = 0;
    for (horizontal_bands, 0..) |*band_slice, b| {
        const len = h_counts[b];
        band_slice.* = backing_indices[offset .. offset + len];
        offset += len;
    }
    for (vertical_bands, 0..) |*band_slice, b| {
        const len = v_counts[b];
        band_slice.* = backing_indices[offset .. offset + len];
        offset += len;
    }
    if (comptime std.debug.runtime_safety) std.debug.assert(offset == total_refs);

    scatterAxisBands(extents, h_ranges, 0, scratch_indices, sort_keys, horizontal_bands);
    scatterAxisBands(extents, v_ranges, 1, scratch_indices, sort_keys, vertical_bands);

    return .{
        .band_index_max = .{
            @intCast(band_count_x - 1),
            @intCast(band_count_y - 1),
        },
        .band_scale = band_scale,
        .band_offset = band_offset,
        .horizontal_bands = horizontal_bands,
        .vertical_bands = vertical_bands,
        .backing_indices = backing_indices,
        .bounding_box_min = bounds.min,
        .bounding_box_max = bounds.max,
        .owns_bands = owns_bands,
        .owns_indices = owns_indices,
    };
}

noinline fn mergeSortBandSlice(
    items: []u32,
    scratch: []u32,
    sort_keys: []const f32,
) void {
    if (comptime std.debug.runtime_safety) {
        std.debug.assert(scratch.len >= items.len);
    }

    var chunk_start: usize = 0;
    while (chunk_start < items.len) : (chunk_start += per_band_insertion_limit) {
        const chunk_end = @min(chunk_start + per_band_insertion_limit, items.len);
        var i = chunk_start + 1;
        while (i < chunk_end) : (i += 1) {
            const idx = items[i];
            const key_max = sort_keys[idx];
            var j = i;
            while (j > chunk_start and sort_keys[items[j - 1]] < key_max) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = idx;
        }
    }

    var src = items;
    var dst = scratch[0..items.len];
    var width: usize = per_band_insertion_limit;
    while (width < items.len) : (width *= 2) {
        var left: usize = 0;
        while (left < items.len) : (left += width * 2) {
            const mid = @min(left + width, items.len);
            const right = @min(left + width * 2, items.len);
            var l = left;
            var r = mid;
            var out = left;
            while (l < mid and r < right) : (out += 1) {
                const left_idx = src[l];
                const right_idx = src[r];
                if (sort_keys[left_idx] >= sort_keys[right_idx]) {
                    dst[out] = left_idx;
                    l += 1;
                } else {
                    dst[out] = right_idx;
                    r += 1;
                }
            }
            if (l < mid) @memcpy(dst[out .. out + (mid - l)], src[l..mid]);
            if (r < right) @memcpy(dst[out .. out + (right - r)], src[r..right]);
        }
        const tmp = src;
        src = dst;
        dst = tmp;
    }

    if (src.ptr != items.ptr) {
        @memcpy(items, src);
    }
}

inline fn computeAxisBandRanges(
    extents: []const Bounds,
    num_bands: usize,
    origin: f32,
    span: f32,
    slab_axis: u1,
    out_ranges: []u8,
    out_counts: *[bands_per_axis_max]usize,
) usize {
    if (comptime std.debug.runtime_safety) {
        std.debug.assert(num_bands > 0 and num_bands <= bands_per_axis_max);
        std.debug.assert(span > 0);
        std.debug.assert(out_ranges.len == extents.len);
    }

    out_counts.* = @splat(0);
    if (num_bands == 1 or !std.math.isFinite(span)) {
        @memset(out_ranges, 0);
        out_counts[0] = extents.len;
        return extents.len;
    }

    const num_bands_f: f32 = @floatFromInt(num_bands);
    const band_height = span / num_bands_f;
    const inv_band_height = num_bands_f / span;

    var band_mins: [bands_per_axis_max]f32 = undefined;
    var band_maxs: [bands_per_axis_max]f32 = undefined;
    for (0..num_bands) |b| {
        band_mins[b] = origin + @as(f32, @floatFromInt(b)) * band_height - band_epsilon;
        band_maxs[b] = origin + @as(f32, @floatFromInt(b + 1)) * band_height + band_epsilon;
    }

    const max_band_f: f32 = @floatFromInt(num_bands - 1);
    var total_refs: usize = 0;

    for (extents, out_ranges) |extent, *range_out| {
        const min_v = extent.min[slab_axis];
        const max_v = extent.max[slab_axis];

        const clamped_first = @max(0.0, @min((min_v - band_epsilon - origin) * inv_band_height, max_band_f));
        var first_band: usize = @intFromFloat(clamped_first);
        while (first_band > 0 and min_v <= band_maxs[first_band - 1]) first_band -= 1;
        while (first_band < num_bands and min_v > band_maxs[first_band]) first_band += 1;

        const clamped_last = @max(0.0, @min((max_v + band_epsilon - origin) * inv_band_height, max_band_f));
        var last_band: usize = @intFromFloat(clamped_last);
        while (last_band + 1 < num_bands and max_v >= band_mins[last_band + 1]) last_band += 1;
        while (last_band > 0 and max_v < band_mins[last_band]) last_band -= 1;

        if (first_band <= last_band and !(max_v < band_mins[first_band]) and !(min_v > band_maxs[last_band])) {
            range_out.* = (@as(u8, @intCast(first_band)) << 4) | @as(u8, @intCast(last_band));
            if (first_band == last_band) {
                out_counts[first_band] += 1;
                total_refs += 1;
            } else {
                for (first_band..last_band + 1) |b| {
                    out_counts[b] += 1;
                }
                total_refs += (last_band - first_band + 1);
            }
        } else {
            range_out.* = no_band_overlap;
        }
    }

    return total_refs;
}

inline fn scatterAxisBands(
    extents: []const Bounds,
    ranges: []const u8,
    sort_axis: u1,
    scratch_indices: []u32,
    sort_keys: []f32,
    bands: [][]u32,
) void {
    const curve_count = extents.len;
    if (comptime std.debug.runtime_safety) {
        std.debug.assert(ranges.len == curve_count);
        std.debug.assert(scratch_indices.len == curve_count);
        std.debug.assert(sort_keys.len == curve_count);
    }

    var write_pos: [bands_per_axis_max]usize = @splat(0);
    for (ranges, 0..) |packed_range, i| {
        if (packed_range == no_band_overlap) continue;
        const curve_idx: u32 = @intCast(i);
        const first_band: usize = packed_range >> 4;
        const last_band: usize = packed_range & 0x0F;
        if (first_band == last_band) {
            bands[first_band][write_pos[first_band]] = curve_idx;
            write_pos[first_band] += 1;
        } else {
            for (first_band..last_band + 1) |b| {
                bands[b][write_pos[b]] = curve_idx;
                write_pos[b] += 1;
            }
        }
    }

    if (comptime std.debug.runtime_safety) {
        for (bands, 0..) |band_slice, b| {
            std.debug.assert(write_pos[b] == band_slice.len);
        }
    }

    var keys_extracted = false;
    for (bands) |band_slice| {
        if (band_slice.len <= 1) continue;
        if (!keys_extracted) {
            for (extents, sort_keys) |ext, *key| {
                key.* = ext.max[sort_axis];
            }
            keys_extracted = true;
        }
        if (band_slice.len <= per_band_insertion_limit) {
            var i: usize = 1;
            while (i < band_slice.len) : (i += 1) {
                const idx = band_slice[i];
                const key_max = sort_keys[idx];
                var j = i;
                while (j > 0 and sort_keys[band_slice[j - 1]] < key_max) : (j -= 1) {
                    band_slice[j] = band_slice[j - 1];
                }
                band_slice[j] = idx;
            }
        } else {
            mergeSortBandSlice(band_slice, scratch_indices, sort_keys);
        }
    }
}

test "partition single horizontal line yields one band" {
    const allocator = std.testing.allocator;
    const curves = &[_]Curve{
        .{ .p1 = .{ 0, 0.5 }, .p2 = .{ 0.5, 0.5 }, .p3 = .{ 1, 0.5 } },
    };
    var result = try partition(allocator, curves);
    defer result.deinit(allocator);

    try std.testing.expectEqual(0, result.band_index_max[0]);
    try std.testing.expectEqual(0, result.band_index_max[1]);
    try std.testing.expectEqual(1, result.horizontal_bands.len);
    try std.testing.expectEqual(1, result.horizontal_bands[0].len);
    try std.testing.expectEqual(0, result.horizontal_bands[0][0]);
}

test "partition sorts within band by descending max-x" {
    const allocator = std.testing.allocator;
    const curves = &[_]Curve{
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.05, 0.0 }, .p3 = .{ 0.1, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.45, 0.0 }, .p3 = .{ 0.9, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.25, 0.0 }, .p3 = .{ 0.5, 0.0 } },
    };
    var result = try partition(allocator, curves);
    defer result.deinit(allocator);

    var found_band: ?[]u32 = null;
    for (result.horizontal_bands) |candidate| {
        if (candidate.len == 3) found_band = candidate;
    }
    const matching_band = found_band orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(1, matching_band[0]);
    try std.testing.expectEqual(2, matching_band[1]);
    try std.testing.expectEqual(0, matching_band[2]);
}

test "partition preserves original index order when sort-axis max ties" {
    const allocator = std.testing.allocator;
    const curves = &[_]Curve{
        .{ .p1 = .{ 0.1, 0.0 }, .p2 = .{ 0.3, 0.0 }, .p3 = .{ 0.5, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.45, 0.0 }, .p3 = .{ 0.9, 0.0 } },
        .{ .p1 = .{ 0.2, 0.0 }, .p2 = .{ 0.35, 0.0 }, .p3 = .{ 0.5, 0.0 } },
        .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.25, 0.0 }, .p3 = .{ 0.5, 0.0 } },
    };
    var result = try partition(allocator, curves);
    defer result.deinit(allocator);

    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 2, 3 }, result.horizontal_bands[0]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, result.vertical_bands[0]);
}

test "partition handles stack/heap boundary (256 and 257) and > 256 curves" {
    const allocator = std.testing.allocator;
    var curves: [300]Curve = undefined;
    for (&curves, 0..) |*curve, index| {
        const x: f32 = @floatFromInt(index + 1);
        curve.* = .{
            .p1 = .{ 0.0, 0.0 },
            .p2 = .{ x * 0.5, 0.5 },
            .p3 = .{ x, 1.0 },
        };
    }

    for ([_]usize{ 256, 257, 300 }) |len| {
        var result = try partition(allocator, curves[0..len]);
        defer result.deinit(allocator);

        try std.testing.expectEqual(bands_per_axis_max, result.horizontal_bands.len);
        try std.testing.expectEqual(bands_per_axis_max, result.vertical_bands.len);
        for (result.horizontal_bands) |h_band| {
            try std.testing.expectEqual(len, h_band.len);
            try std.testing.expectEqual(@as(u32, @intCast(len - 1)), h_band[0]);
            try std.testing.expectEqual(0, h_band[len - 1]);
        }
        try std.testing.expect(result.vertical_bands[0].len > 0);
        try std.testing.expect(result.vertical_bands[bands_per_axis_max - 1].len > 0);
    }

    const OomTest = struct {
        fn run(gpa: std.mem.Allocator, input: []const Curve) !void {
            var res = try partition(gpa, input);
            defer res.deinit(gpa);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, OomTest.run, .{curves[0..300]});
}

test "partition empty curves returns sentinel band" {
    const allocator = std.testing.allocator;
    var result = try partition(allocator, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(0, result.band_index_max[0]);
    try std.testing.expectEqual(1, result.horizontal_bands.len);
    try std.testing.expectEqual(0, result.horizontal_bands[0].len);
    try std.testing.expectEqual(0, result.backing_indices.len);
}

test "partition direct band-range indexing matches brute-force boundary overlap and uses single backing slice" {
    const allocator = std.testing.allocator;

    // 64 curves -> 16 bands per axis (bands_per_axis_max).
    // Include curves spanning single bands (including band 15 = 0xFF packed),
    // multiple bands, and exact band_epsilon boundaries.
    var curves: [64]Curve = undefined;
    curves[0] = .{ .p1 = .{ 0.0, 0.0 }, .p2 = .{ 0.01, 0.01 }, .p3 = .{ 0.02, 0.02 } };
    // Curve only in the last band (band 15 on both axes -> packed 0xFF).
    curves[1] = .{ .p1 = .{ 0.98, 0.98 }, .p2 = .{ 0.99, 0.99 }, .p3 = .{ 1.0, 1.0 } };
    // Curves right around band boundaries +/- band_epsilon.
    const band_step: f32 = 1.0 / 16.0;
    for (2..curves.len) |i| {
        const b: f32 = @floatFromInt(i % 16);
        const edge = b * band_step;
        const delta: f32 = switch (i % 4) {
            0 => -band_epsilon,
            1 => band_epsilon,
            2 => -band_epsilon * 0.5,
            else => band_epsilon * 2.0,
        };
        const lo = @max(0.0, edge + delta);
        const hi = @min(1.0, lo + band_step * @as(f32, @floatFromInt((i % 3) + 1)));
        curves[i] = .{
            .p1 = .{ lo, hi * 0.5 },
            .p2 = .{ (lo + hi) * 0.5, lo },
            .p3 = .{ hi, hi },
        };
    }

    var result = try partition(allocator, &curves);
    defer result.deinit(allocator);

    try std.testing.expectEqual(bands_per_axis_max, result.horizontal_bands.len);
    try std.testing.expectEqual(bands_per_axis_max, result.vertical_bands.len);

    // Verify all horizontal and vertical band slices point contiguously into backing_indices.
    var expected_offset: usize = 0;
    for (result.horizontal_bands) |b_slice| {
        try std.testing.expectEqual(@intFromPtr(result.backing_indices.ptr + expected_offset), @intFromPtr(b_slice.ptr));
        expected_offset += b_slice.len;
    }
    for (result.vertical_bands) |b_slice| {
        try std.testing.expectEqual(@intFromPtr(result.backing_indices.ptr + expected_offset), @intFromPtr(b_slice.ptr));
        expected_offset += b_slice.len;
    }
    try std.testing.expectEqual(result.backing_indices.len, expected_offset);

    // Verify exact membership and sort order against brute-force per-band overlap check.
    var extents: [curves.len]Bounds = undefined;
    const bounds = computeCurveExtents(&curves, &extents);
    const span = [2]f32{ bounds.max[0] - bounds.min[0], bounds.max[1] - bounds.min[1] };

    inline for (.{
        .{ .bands = result.horizontal_bands, .origin = bounds.min[1], .span = span[1], .slab_axis = @as(u1, 1), .sort_axis = @as(u1, 0) },
        .{ .bands = result.vertical_bands, .origin = bounds.min[0], .span = span[0], .slab_axis = @as(u1, 0), .sort_axis = @as(u1, 1) },
    }) |axis| {
        const band_h = axis.span / @as(f32, @floatFromInt(axis.bands.len));
        for (axis.bands, 0..) |actual_band, b_idx| {
            const band_min = axis.origin + @as(f32, @floatFromInt(b_idx)) * band_h - band_epsilon;
            const band_max = axis.origin + @as(f32, @floatFromInt(b_idx + 1)) * band_h + band_epsilon;

            var expected_count: usize = 0;
            for (extents) |ext| {
                if (!(ext.max[axis.slab_axis] < band_min or ext.min[axis.slab_axis] > band_max)) {
                    expected_count += 1;
                }
            }
            try std.testing.expectEqual(expected_count, actual_band.len);

            for (actual_band, 0..) |c_idx, pos| {
                const ext = extents[c_idx];
                try std.testing.expect(!(ext.max[axis.slab_axis] < band_min or ext.min[axis.slab_axis] > band_max));
                if (pos > 0) {
                    const prev_idx = actual_band[pos - 1];
                    const prev_max = extents[prev_idx].max[axis.sort_axis];
                    const curr_max = ext.max[axis.sort_axis];
                    try std.testing.expect(prev_max > curr_max or (prev_max == curr_max and prev_idx < c_idx));
                }
            }
        }
    }

    // Extreme finite coordinates whose span overflows f32 to +inf must not trap or drop curves.
    const extreme_curves = [_]Curve{
        .{ .p1 = .{ -3e38, -3e38 }, .p2 = .{ -2e38, -2e38 }, .p3 = .{ -1e38, -1e38 } },
        .{ .p1 = .{ 1e38, 1e38 }, .p2 = .{ 2e38, 2e38 }, .p3 = .{ 3e38, 3e38 } },
    };
    var extreme_res = try partition(allocator, &extreme_curves);
    defer extreme_res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), extreme_res.horizontal_bands[0].len);
    try std.testing.expectEqual(@as(usize, 2), extreme_res.vertical_bands[0].len);

    // Verify partitionWithBuffer uses caller stack buffers without heap allocation when sufficient,
    // and falls back to heap allocation for indices when indices_buf is too small.
    var stack_bands: [2 * bands_per_axis_max][]u32 = undefined;
    var stack_indices: [1024]u32 = undefined;
    var buffered_res = try partitionWithBuffer(std.testing.failing_allocator, &curves, &stack_bands, &stack_indices);
    defer buffered_res.deinit(std.testing.failing_allocator);
    try std.testing.expect(!buffered_res.owns_bands);
    try std.testing.expect(!buffered_res.owns_indices);
    try std.testing.expectEqualSlices(u32, result.backing_indices, buffered_res.backing_indices);

    var small_indices: [4]u32 = undefined;
    var fallback_res = try partitionWithBuffer(allocator, &curves, &stack_bands, &small_indices);
    defer fallback_res.deinit(allocator);
    try std.testing.expect(!fallback_res.owns_bands);
    try std.testing.expect(fallback_res.owns_indices);
    try std.testing.expectEqualSlices(u32, result.backing_indices, fallback_res.backing_indices);
}
