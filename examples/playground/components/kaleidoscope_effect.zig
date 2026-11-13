const std = @import("std");
const sdk = @import("sdk");

const params = [_]sdk.ParamSpec{
    .{ .name = "Folds", .min_val = 2.0, .max_val = 10.0, .default_val = 6.0, .step = 1.0 },
    .{ .name = "Swirl", .min_val = -2.0, .max_val = 2.0, .default_val = 0.45, .step = 0.05 },
    .{ .name = "Scale", .min_val = 0.55, .max_val = 1.35, .default_val = 0.90, .step = 0.02 },
};

fn upstreamCtx(ctx: sdk.FrameContext) sdk.FrameContext {
    var next = ctx;
    next.params = if (ctx.params.len > params.len) ctx.params[params.len..] else &.{};
    return next;
}

fn transformPoint(px: f32, py: f32, cx: f32, cy: f32, max_r: f32, angle_offset: f32, mirror: bool, swirl: f32, scale: f32) [2]f32 {
    var dx = (px - cx) * scale;
    const dy = (py - cy) * scale;
    if (mirror) dx = -dx;
    const r = @sqrt(dx * dx + dy * dy);
    const swirl_ang = swirl * (r / @max(max_r, 1.0));
    const total = angle_offset + swirl_ang;
    const cs = @cos(total);
    const sn = @sin(total);
    return .{
        cx + dx * cs - dy * sn,
        cy + dx * sn + dy * cs,
    };
}

const Impl = struct {
    pub fn describe() sdk.ComponentInfo {
        return .{
            .id = "kaleidoscope-effect",
            .title = "Kaleidoscope Symmetry",
            .summary = "Imports upstream knots:visual/source and reflects vector or pixel output across N wedges.",
            .role = .effect,
            .preferred_output = .vector_scene,
            .params = &params,
        };
    }

    pub fn renderVector(ctx: sdk.FrameContext) []const sdk.ExternDrawShape {
        const folds_u: usize = @intFromFloat(std.math.clamp(ctx.param(0, 6.0), 2.0, 10.0));
        const swirl = ctx.param(1, 0.45);
        const scale = ctx.param(2, 0.90);

        const src = sdk.upstream.renderVector(upstreamCtx(ctx));
        if (src.len == 0) return &.{};

        const w: f32 = @floatFromInt(@max(ctx.width, 1));
        const h: f32 = @floatFromInt(@max(ctx.height, 1));
        const cx = w * 0.5;
        const cy = h * 0.5;
        const max_r = @min(w, h) * 0.5;

        // Keep background rect(s) once, and replicate geometric primitives across symmetry wedges.
        const has_backdrop = src[0].tag == @backingInt(sdk.ShapeTag.fill_rect) and src[0].x0 == 0 and src[0].y0 == 0;
        const body = if (has_backdrop) src[1..] else src;
        const stride: usize = if (body.len * folds_u > 2800) (body.len * folds_u + 2799) / 2800 else 1;
        const sampled_count = (body.len + stride - 1) / stride;
        const max_out = (if (has_backdrop) @as(usize, 1) else @as(usize, 0)) + sampled_count * folds_u;

        const out = sdk.allocSlice(sdk.ExternDrawShape, max_out);
        var n: usize = 0;
        if (has_backdrop) {
            out[n] = src[0];
            n += 1;
        }

        const step_angle = (std.math.pi * 2.0) / @as(f32, @floatFromInt(folds_u));
        for (0..folds_u) |fold_i| {
            const ang = @as(f32, @floatFromInt(fold_i)) * step_angle;
            const mirror = (fold_i % 2) == 1;
            var bi: usize = 0;
            while (bi < body.len) : (bi += stride) {
                var s = body[bi];
                const tag: sdk.ShapeTag = @fromBackingInt(@intCast(s.tag));
                switch (tag) {
                    .fill_circle, .stroke_circle => {
                        const p = transformPoint(s.x0, s.y0, cx, cy, max_r, ang, mirror, swirl, scale);
                        s.x0 = p[0];
                        s.y0 = p[1];
                        if (tag == .stroke_circle) {
                            s.x1 *= scale;
                        } else {
                            s.radius_or_width *= scale;
                        }
                    },
                    .line_seg => {
                        const p0 = transformPoint(s.x0, s.y0, cx, cy, max_r, ang, mirror, swirl, scale);
                        const p1 = transformPoint(s.x1, s.y1, cx, cy, max_r, ang, mirror, swirl, scale);
                        s.x0 = p0[0];
                        s.y0 = p0[1];
                        s.x1 = p1[0];
                        s.y1 = p1[1];
                        s.a *= 0.82;
                    },
                    .fill_triangle => {
                        const p0 = transformPoint(s.x0, s.y0, cx, cy, max_r, ang, mirror, swirl, scale);
                        const p1 = transformPoint(s.x1, s.y1, cx, cy, max_r, ang, mirror, swirl, scale);
                        const p2 = transformPoint(s.x2, s.y2, cx, cy, max_r, ang, mirror, swirl, scale);
                        s.x0 = p0[0];
                        s.y0 = p0[1];
                        s.x1 = p1[0];
                        s.y1 = p1[1];
                        s.x2 = p2[0];
                        s.y2 = p2[1];
                    },
                    .fill_rect, .stroke_rect => {
                        const pc = transformPoint(s.x0 + s.x1 * 0.5, s.y0 + s.y1 * 0.5, cx, cy, max_r, ang, mirror, swirl, scale);
                        s.x1 *= scale;
                        s.y1 *= scale;
                        s.x0 = pc[0] - s.x1 * 0.5;
                        s.y0 = pc[1] - s.y1 * 0.5;
                    },
                }
                out[n] = s;
                n += 1;
            }
        }
        return out[0..n];
    }

    pub fn renderPixels(ctx: sdk.FrameContext) sdk.PixelFrame {
        const folds = std.math.clamp(ctx.param(0, 6.0), 2.0, 10.0);
        const swirl = ctx.param(1, 0.45);
        const scale = std.math.clamp(ctx.param(2, 0.90), 0.35, 2.0);

        const src = sdk.upstream.renderPixels(upstreamCtx(ctx));
        if (src.width == 0 or src.height == 0 or src.rgba.len < @as(usize, src.width) * @as(usize, src.height) * 4) {
            return src;
        }

        const w = src.width;
        const h = src.height;
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const cx = fw * 0.5;
        const cy = fh * 0.5;
        const max_r = @min(cx, cy);
        const sector = (std.math.pi * 2.0) / folds;
        const half_sector = sector * 0.5;

        const out = sdk.allocSlice(u8, @as(usize, w) * @as(usize, h) * 4);
        var dst_idx: usize = 0;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const dy = @as(f32, @floatFromInt(y)) - cy;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) - cx;
                const r = @sqrt(dx * dx + dy * dy) / scale;
                var theta = std.math.atan2(dy, dx) + swirl * (r / @max(max_r, 1.0)) + std.math.pi;
                theta = @mod(theta, sector);
                if (theta > half_sector) theta = sector - theta;

                const sx_f = std.math.clamp(cx + @cos(theta) * r, 0.0, fw - 1.0);
                const sy_f = std.math.clamp(cy + @sin(theta) * r, 0.0, fh - 1.0);
                const sx: usize = @intFromFloat(sx_f);
                const sy: usize = @intFromFloat(sy_f);
                const src_off = (sy * @as(usize, w) + sx) * 4;
                out[dst_idx + 0] = src.rgba[src_off + 0];
                out[dst_idx + 1] = src.rgba[src_off + 1];
                out[dst_idx + 2] = src.rgba[src_off + 2];
                out[dst_idx + 3] = 255;
                dst_idx += 4;
            }
        }
        return .{ .width = w, .height = h, .rgba = out };
    }
};

pub const panic = sdk.panic;
pub const cabi_realloc = sdk.cabiReallocExport;

comptime {
    sdk.exportSource(Impl);
}
