const std = @import("std");
const Curve = @import("curve.zig").Curve;

// The shader stores each axis's maximum band index in a u8.
pub const bands_per_axis_max: u32 = 16;

const band_epsilon: f32 = 1.0 / 65536.0;
const curves_per_band_target: f32 = 4.0;
const stack_curve_capacity: usize = 256;
const insertion_sort_limit: usize = 32;

comptime {
    std.debug.assert(bands_per_axis_max > 0);
    std.debug.assert(bands_per_axis_max - 1 <= std.math.maxInt(u8));
}

pub const PartitionResult = struct {
    band_index_max: [2]u8,
    band_scale: [2]f32,
    band_offset: [2]f32,
    horizontal_bands: [][]u32,
    vertical_bands: [][]u32,
    bounding_box_min: [2]f32,
    bounding_box_max: [2]f32,

    pub fn deinit(self: *PartitionResult, allocator: std.mem.Allocator) void {
        for (self.horizontal_bands) |band| allocator.free(band);
        for (self.vertical_bands) |band| allocator.free(band);
        allocator.free(self.horizontal_bands);
        allocator.free(self.vertical_bands);
    }
};

const Bounds = struct {
    min: [2]f32,
    max: [2]f32,
};

const FillOptions = struct {
    bands: [][]u32,
    origin: f32,
    span: f32,
    slab_axis: u1,
    sort_axis: u1,
};

fn emptyPartition(allocator: std.mem.Allocator) !PartitionResult {
    const horizontal_bands = try allocator.alloc([]u32, 1);
    errdefer allocator.free(horizontal_bands);
    horizontal_bands[0] = try allocator.alloc(u32, 0);
    errdefer allocator.free(horizontal_bands[0]);

    const vertical_bands = try allocator.alloc([]u32, 1);
    errdefer allocator.free(vertical_bands);
    vertical_bands[0] = try allocator.alloc(u32, 0);

    return .{
        .band_index_max = .{ 0, 0 },
        .band_scale = .{ 0, 0 },
        .band_offset = .{ 0, 0 },
        .horizontal_bands = horizontal_bands,
        .vertical_bands = vertical_bands,
        .bounding_box_min = .{ 0, 0 },
        .bounding_box_max = .{ 0, 0 },
    };
}

fn computeCurveExtents(curves: []const Curve, extents: []Bounds) Bounds {
    std.debug.assert(curves.len > 0);
    std.debug.assert(extents.len == curves.len);

    var bounds = Bounds{
        .min = .{ std.math.inf(f32), std.math.inf(f32) },
        .max = .{ -std.math.inf(f32), -std.math.inf(f32) },
    };
    for (curves, extents) |curve, *extent| {
        const p1 = curve.p1;
        const p2 = curve.p2;
        const p3 = curve.p3;
        inline for ([_][2]f32{ p1, p2, p3 }) |point| {
            std.debug.assert(std.math.isFinite(point[0]));
            std.debug.assert(std.math.isFinite(point[1]));
        }
        const curve_min = [2]f32{
            @min(@min(p1[0], p2[0]), p3[0]),
            @min(@min(p1[1], p2[1]), p3[1]),
        };
        const curve_max = [2]f32{
            @max(@max(p1[0], p2[0]), p3[0]),
            @max(@max(p1[1], p2[1]), p3[1]),
        };
        extent.* = .{ .min = curve_min, .max = curve_max };
        bounds.min[0] = @min(bounds.min[0], curve_min[0]);
        bounds.min[1] = @min(bounds.min[1], curve_min[1]);
        bounds.max[0] = @max(bounds.max[0], curve_max[0]);
        bounds.max[1] = @max(bounds.max[1], curve_max[1]);
    }
    return bounds;
}

pub fn partition(allocator: std.mem.Allocator, curves: []const Curve) !PartitionResult {
    if (curves.len == 0) return emptyPartition(allocator);
    if (curves.len > std.math.maxInt(u32)) return error.TooManyCurves;

    var stack_extents: [stack_curve_capacity]Bounds = undefined;
    const extents: []Bounds = if (curves.len <= stack_extents.len)
        stack_extents[0..curves.len]
    else
        try allocator.alloc(Bounds, curves.len);
    defer if (curves.len > stack_extents.len) allocator.free(extents);

    var stack_indices: [stack_curve_capacity]u32 = undefined;
    const curve_indices: []u32 = if (curves.len <= stack_indices.len)
        stack_indices[0..curves.len]
    else
        try allocator.alloc(u32, curves.len);
    defer if (curves.len > stack_indices.len) allocator.free(curve_indices);

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

    const horizontal_bands = try allocator.alloc([]u32, band_count_y);
    errdefer allocator.free(horizontal_bands);
    const vertical_bands = try allocator.alloc([]u32, band_count_x);
    errdefer allocator.free(vertical_bands);

    try fillBands(allocator, extents, curve_indices, .{
        .bands = horizontal_bands,
        .origin = bounds.min[1],
        .span = span[1],
        .slab_axis = 1,
        .sort_axis = 0,
    });
    errdefer for (horizontal_bands) |band| allocator.free(band);

    try fillBands(allocator, extents, curve_indices, .{
        .bands = vertical_bands,
        .origin = bounds.min[0],
        .span = span[0],
        .slab_axis = 0,
        .sort_axis = 1,
    });

    return .{
        .band_index_max = .{
            @intCast(band_count_x - 1),
            @intCast(band_count_y - 1),
        },
        .band_scale = band_scale,
        .band_offset = band_offset,
        .horizontal_bands = horizontal_bands,
        .vertical_bands = vertical_bands,
        .bounding_box_min = bounds.min,
        .bounding_box_max = bounds.max,
    };
}

fn sortBandIndices(
    extents: []const Bounds,
    sort_axis: u1,
    items: []u32,
    band_slice: []u32,
) void {
    std.debug.assert(items.len == band_slice.len);

    var chunk_start: usize = 0;
    while (chunk_start < items.len) : (chunk_start += insertion_sort_limit) {
        const chunk_end = @min(chunk_start + insertion_sort_limit, items.len);
        var i = chunk_start + 1;
        while (i < chunk_end) : (i += 1) {
            const idx = items[i];
            const key_max = extents[idx].max[sort_axis];
            var j = i;
            while (j > chunk_start and extents[items[j - 1]].max[sort_axis] < key_max) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = idx;
        }
    }

    var src = items;
    var dst = band_slice;
    var width: usize = insertion_sort_limit;
    while (width < items.len) : (width *= 2) {
        var left: usize = 0;
        while (left < items.len) : (left += width * 2) {
            const mid = @min(left + width, items.len);
            const right = @min(left + width * 2, items.len);
            var l = left;
            var r = mid;
            var out = left;
            while (l < mid and r < right) : (out += 1) {
                if (extents[src[l]].max[sort_axis] >= extents[src[r]].max[sort_axis]) {
                    dst[out] = src[l];
                    l += 1;
                } else {
                    dst[out] = src[r];
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

    if (src.ptr != band_slice.ptr) {
        @memcpy(band_slice, src);
    }
}

fn fillBands(
    allocator: std.mem.Allocator,
    extents: []const Bounds,
    curve_indices: []u32,
    options: FillOptions,
) !void {
    std.debug.assert(options.bands.len > 0);
    std.debug.assert(options.bands.len <= bands_per_axis_max);
    std.debug.assert(options.span > 0);
    std.debug.assert(curve_indices.len >= extents.len);

    const band_height = options.span / @as(f32, @floatFromInt(options.bands.len));

    var filled: u32 = 0;
    errdefer {
        for (options.bands[0..filled]) |band| allocator.free(band);
    }

    const slab_axis = options.slab_axis;
    const sort_axis = options.sort_axis;

    for (options.bands, 0..) |*band, band_index| {
        const band_min = options.origin +
            @as(f32, @floatFromInt(band_index)) * band_height - band_epsilon;
        const band_max = options.origin +
            @as(f32, @floatFromInt(band_index + 1)) * band_height + band_epsilon;

        var count: usize = 0;
        for (extents, 0..) |extent, curve_index| {
            if (extent.max[slab_axis] < band_min) continue;
            if (extent.min[slab_axis] > band_max) continue;
            curve_indices[count] = @intCast(curve_index);
            count += 1;
        }

        const band_slice = try allocator.alloc(u32, count);
        band.* = band_slice;
        filled += 1;

        sortBandIndices(extents, sort_axis, curve_indices[0..count], band_slice);
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
}
