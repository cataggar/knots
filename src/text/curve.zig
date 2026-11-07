const std = @import("std");
const TrueType = @import("TrueType");

pub const Curve = struct {
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
};

// Eight fixed segments avoid recursive, input-dependent subdivision work.
const cubic_subdivision_depth: u32 = 3;
const cubic_segment_count = 1 << cubic_subdivision_depth;

const Cubic = struct {
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
};

comptime {
    std.debug.assert(cubic_subdivision_depth > 0);
    std.debug.assert(cubic_segment_count == 8);
}

inline fn midpoint(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

inline fn splitCubic(cubic: Cubic) [2]Cubic {
    const p01 = midpoint(cubic.p0, cubic.p1);
    const p12 = midpoint(cubic.p1, cubic.p2);
    const p23 = midpoint(cubic.p2, cubic.p3);
    const p012 = midpoint(p01, p12);
    const p123 = midpoint(p12, p23);
    const p0123 = midpoint(p012, p123);

    return .{
        .{ .p0 = cubic.p0, .p1 = p01, .p2 = p012, .p3 = p0123 },
        .{ .p0 = p0123, .p1 = p123, .p2 = p23, .p3 = cubic.p3 },
    };
}

fn appendCubic(out: *[cubic_segment_count]Curve, cubic: Cubic) void {
    var segments: [cubic_segment_count]Cubic = undefined;
    var subdivisions: [cubic_segment_count]Cubic = undefined;
    segments[0] = cubic;

    var segment_count: u32 = 1;
    for (0..cubic_subdivision_depth) |_| {
        for (segments[0..segment_count], 0..) |*segment, index| {
            const halves = splitCubic(segment.*);
            subdivisions[index * 2] = halves[0];
            subdivisions[index * 2 + 1] = halves[1];
        }

        segment_count *= 2;
        @memcpy(segments[0..segment_count], subdivisions[0..segment_count]);
    }

    std.debug.assert(segment_count == cubic_segment_count);
    for (&segments, out) |*segment, *dst| {
        const control_start = [2]f32{
            (3.0 * segment.p1[0] - segment.p0[0]) * 0.5,
            (3.0 * segment.p1[1] - segment.p0[1]) * 0.5,
        };
        const control_end = [2]f32{
            (3.0 * segment.p2[0] - segment.p3[0]) * 0.5,
            (3.0 * segment.p2[1] - segment.p3[1]) * 0.5,
        };
        dst.* = .{
            .p1 = segment.p0,
            .p2 = midpoint(control_start, control_end),
            .p3 = segment.p3,
        };
    }
}

pub inline fn countDecomposedCurves(vertices: []const TrueType.Vertex) usize {
    var count: usize = 0;
    for (vertices) |vertex| {
        count += switch (vertex.type) {
            .vline, .vcurve => 1,
            .vcubic => cubic_segment_count,
            else => 0,
        };
    }
    return count;
}

pub fn decomposeVerticesInto(out: []Curve, vertices: []const TrueType.Vertex, units_per_em: f32) []Curve {
    std.debug.assert(std.math.isFinite(units_per_em));
    std.debug.assert(units_per_em > 0);

    const units_per_em_inverse = 1.0 / units_per_em;
    var write_idx: usize = 0;
    var current_point: [2]f32 = .{ 0, 0 };

    for (vertices) |vertex| {
        const point = [2]f32{
            @as(f32, @floatFromInt(vertex.x)) * units_per_em_inverse,
            @as(f32, @floatFromInt(vertex.y)) * units_per_em_inverse,
        };
        switch (vertex.type) {
            .vmove => {
                current_point = point;
            },
            .vline => {
                out[write_idx] = .{
                    .p1 = current_point,
                    .p2 = midpoint(current_point, point),
                    .p3 = point,
                };
                write_idx += 1;
                current_point = point;
            },
            .vcurve => {
                out[write_idx] = .{
                    .p1 = current_point,
                    .p2 = .{
                        @as(f32, @floatFromInt(vertex.cx)) * units_per_em_inverse,
                        @as(f32, @floatFromInt(vertex.cy)) * units_per_em_inverse,
                    },
                    .p3 = point,
                };
                write_idx += 1;
                current_point = point;
            },
            .vcubic => {
                appendCubic(out[write_idx..][0..cubic_segment_count], .{
                    .p0 = current_point,
                    .p1 = .{
                        @as(f32, @floatFromInt(vertex.cx)) * units_per_em_inverse,
                        @as(f32, @floatFromInt(vertex.cy)) * units_per_em_inverse,
                    },
                    .p2 = .{
                        @as(f32, @floatFromInt(vertex.cx1)) * units_per_em_inverse,
                        @as(f32, @floatFromInt(vertex.cy1)) * units_per_em_inverse,
                    },
                    .p3 = point,
                });
                write_idx += cubic_segment_count;
                current_point = point;
            },
            else => {},
        }
    }

    return out[0..write_idx];
}

pub fn decomposeVertices(allocator: std.mem.Allocator, vertices: []const TrueType.Vertex, units_per_em: f32) ![]Curve {
    std.debug.assert(std.math.isFinite(units_per_em));
    std.debug.assert(units_per_em > 0);

    const out = try allocator.alloc(Curve, countDecomposedCurves(vertices));
    return decomposeVerticesInto(out, vertices, units_per_em);
}

test "decomposeVertices produces line as degenerate quadratic" {
    const allocator = std.testing.allocator;

    const vertices = [_]TrueType.Vertex{
        .{ .x = 0, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vmove },
        .{ .x = 1024, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
        .{ .x = 1024, .y = 1024, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
        .{ .x = 0, .y = 1024, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
        .{ .x = 0, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
    };

    const curves = try decomposeVertices(allocator, &vertices, 1024.0);
    defer allocator.free(curves);

    try std.testing.expectEqual(4, curves.len);

    for (curves) |curve| {
        const expected_midpoint = [2]f32{
            (curve.p1[0] + curve.p3[0]) * 0.5,
            (curve.p1[1] + curve.p3[1]) * 0.5,
        };
        try std.testing.expectApproxEqAbs(expected_midpoint[0], curve.p2[0], 1e-6);
        try std.testing.expectApproxEqAbs(expected_midpoint[1], curve.p2[1], 1e-6);
    }

    const mixed_vertices = [_]TrueType.Vertex{
        .{ .x = 0, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vmove },
        .{ .x = 512, .y = 0, .cx = 0, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vline },
        .{ .x = 1024, .y = 512, .cx = 1024, .cy = 0, .cx1 = 0, .cy1 = 0, .type = .vcurve },
        .{ .x = 0, .y = 0, .cx = 512, .cy = 1024, .cx1 = 0, .cy1 = 512, .type = .vcubic },
    };
    const expected_count = countDecomposedCurves(&mixed_vertices);
    try std.testing.expectEqual(@as(usize, 1 + 1 + cubic_segment_count), expected_count);

    var stack_out: [16]Curve = undefined;
    const into_slice = decomposeVerticesInto(&stack_out, &mixed_vertices, 1024.0);
    const heap_slice = try decomposeVertices(allocator, &mixed_vertices, 1024.0);
    defer allocator.free(heap_slice);
    try std.testing.expectEqual(expected_count, into_slice.len);
    try std.testing.expectEqualSlices(Curve, heap_slice, into_slice);
}
