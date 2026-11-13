const std = @import("std");
const sdk = @import("sdk");

const params = [_]sdk.ParamSpec{
    .{ .name = "Prism split", .min_val = 0.0, .max_val = 26.0, .default_val = 9.5, .step = 0.5 },
    .{ .name = "Wave warp", .min_val = 0.0, .max_val = 22.0, .default_val = 6.5, .step = 0.5 },
    .{ .name = "Scanlines", .min_val = 0.0, .max_val = 0.85, .default_val = 0.30, .step = 0.05 },
};

fn upstreamCtx(ctx: sdk.FrameContext) sdk.FrameContext {
    var next = ctx;
    next.params = if (ctx.params.len > params.len) ctx.params[params.len..] else &.{};
    return next;
}

fn warpX(x: f32, y: f32, t: f32, amp: f32) f32 {
    return x + @sin(y * 0.032 + t * 3.4) * amp;
}

const Impl = struct {
    pub fn describe() sdk.ComponentInfo {
        return .{
            .id = "chromatic-prism-effect",
            .title = "Chromatic Prism & Wave",
            .summary = "Imports upstream knots:visual/source and applies RGB spectral dispersion and wave warp.",
            .role = .effect,
            .preferred_output = .pixel_buffer,
            .params = &params,
        };
    }

    pub fn renderVector(ctx: sdk.FrameContext) []const sdk.ExternDrawShape {
        const split = ctx.param(0, 9.5);
        const wave = ctx.param(1, 6.5);
        const scan = ctx.param(2, 0.30);

        const src = sdk.upstream.renderVector(upstreamCtx(ctx));
        if (src.len == 0) return &.{};

        const has_backdrop = src[0].tag == @backingInt(sdk.ShapeTag.fill_rect) and src[0].x0 == 0 and src[0].y0 == 0;
        const body = if (has_backdrop) src[1..] else src;
        const w: f32 = @floatFromInt(@max(ctx.width, 1));
        const h: f32 = @floatFromInt(@max(ctx.height, 1));
        const scan_lines: usize = if (scan > 0.02) @intFromFloat(@min(48.0, h / 12.0)) else 0;

        const out = sdk.allocSlice(sdk.ExternDrawShape, (if (has_backdrop) @as(usize, 1) else @as(usize, 0)) + body.len * 3 + scan_lines);
        var n: usize = 0;
        if (has_backdrop) {
            out[n] = src[0];
            n += 1;
        }

        const channels = [3]struct { dx: f32, dy: f32, mask: [3]f32 }{
            .{ .dx = -split, .dy = -split * 0.25, .mask = .{ 1.25, 0.18, 0.25 } },
            .{ .dx = 0.0, .dy = split * 0.2, .mask = .{ 0.20, 1.15, 0.55 } },
            .{ .dx = split, .dy = -split * 0.15, .mask = .{ 0.28, 0.45, 1.30 } },
        };

        for (body) |orig| {
            for (channels) |ch| {
                var s = orig;
                s.x0 = warpX(orig.x0, orig.y0, ctx.time_sec, wave) + ch.dx;
                s.y0 = orig.y0 + ch.dy;
                const tag: sdk.ShapeTag = @fromBackingInt(@intCast(orig.tag));
                if (tag == .line_seg or tag == .fill_triangle) {
                    s.x1 = warpX(orig.x1, orig.y1, ctx.time_sec, wave) + ch.dx;
                    s.y1 = orig.y1 + ch.dy;
                }
                if (tag == .fill_triangle) {
                    s.x2 = warpX(orig.x2, orig.y2, ctx.time_sec, wave) + ch.dx;
                    s.y2 = orig.y2 + ch.dy;
                }
                s.r = std.math.clamp(orig.r * ch.mask[0], 0.0, 1.0);
                s.g = std.math.clamp(orig.g * ch.mask[1], 0.0, 1.0);
                s.b = std.math.clamp(orig.b * ch.mask[2], 0.0, 1.0);
                s.a = orig.a * 0.62;
                out[n] = s;
                n += 1;
            }
        }

        for (0..scan_lines) |si| {
            const y = @mod(@as(f32, @floatFromInt(si)) * (h / @as(f32, @floatFromInt(@max(scan_lines, 1)))) + ctx.time_sec * 24.0, h);
            out[n] = sdk.ExternDrawShape.fillRect(0, y, w, 2.0, .{ 0.0, 0.0, 0.0, scan * 0.55 });
            n += 1;
        }

        return out[0..n];
    }

    pub fn renderPixels(ctx: sdk.FrameContext) sdk.PixelFrame {
        const split = ctx.param(0, 9.5) * 0.25;
        const wave = ctx.param(1, 6.5) * 0.22;
        const scan = ctx.param(2, 0.30);

        const src = sdk.upstream.renderPixels(upstreamCtx(ctx));
        if (src.width == 0 or src.height == 0 or src.rgba.len < @as(usize, src.width) * @as(usize, src.height) * 4) {
            return src;
        }

        const w = src.width;
        const h = src.height;
        const max_x: i32 = @intCast(w - 1);
        const out = sdk.allocSlice(u8, @as(usize, w) * @as(usize, h) * 4);

        var idx: usize = 0;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const fy: f32 = @floatFromInt(y);
            const row_warp = @sin(fy * 0.18 + ctx.time_sec * 4.0) * wave;
            const scan_mul: f32 = if ((y & 1) == 1) (1.0 - scan * 0.65) else 1.0;
            const row_base = @as(usize, y) * @as(usize, w);

            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) + row_warp;
                const rx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(fx - split)), 0, max_x));
                const gx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(fx)), 0, max_x));
                const bx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(fx + split)), 0, max_x));

                const r_val: f32 = @floatFromInt(src.rgba[(row_base + rx) * 4 + 0]);
                const g_val: f32 = @floatFromInt(src.rgba[(row_base + gx) * 4 + 1]);
                const b_val: f32 = @floatFromInt(src.rgba[(row_base + bx) * 4 + 2]);

                out[idx + 0] = @intFromFloat(std.math.clamp(r_val * scan_mul, 0.0, 255.0));
                out[idx + 1] = @intFromFloat(std.math.clamp(g_val * scan_mul, 0.0, 255.0));
                out[idx + 2] = @intFromFloat(std.math.clamp(b_val * scan_mul, 0.0, 255.0));
                out[idx + 3] = 255;
                idx += 4;
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
