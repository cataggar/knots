const std = @import("std");
const sdk = @import("sdk");

const params = [_]sdk.ParamSpec{
    .{ .name = "Resolution", .min_val = 80.0, .max_val = 224.0, .default_val = 160.0, .step = 16.0 },
    .{ .name = "Metaballs", .min_val = 3.0, .max_val = 7.0, .default_val = 5.0, .step = 1.0 },
    .{ .name = "Wave freq", .min_val = 1.5, .max_val = 12.0, .default_val = 5.5, .step = 0.25 },
    .{ .name = "Glow", .min_val = 0.4, .max_val = 2.4, .default_val = 1.25, .step = 0.05 },
};

const Impl = struct {
    pub fn describe() sdk.ComponentInfo {
        return .{
            .id = "plasma-sdf",
            .title = "Metaball Plasma SDF",
            .summary = "Procedural 2D SDF metaballs and interference waves synthesized into RGBA8 pixels.",
            .role = .generator,
            .preferred_output = .pixel_buffer,
            .params = &params,
        };
    }

    pub fn renderPixels(ctx: sdk.FrameContext) sdk.PixelFrame {
        const res_w: u32 = @intFromFloat(std.math.clamp(ctx.param(0, 160.0), 64.0, 240.0));
        const aspect = @as(f32, @floatFromInt(@max(ctx.height, 1))) / @as(f32, @floatFromInt(@max(ctx.width, 1)));
        const res_h: u32 = @max(48, @as(u32, @intFromFloat(@as(f32, @floatFromInt(res_w)) * std.math.clamp(aspect, 0.45, 1.0))));
        const ball_count: usize = @intFromFloat(std.math.clamp(ctx.param(1, 5.0), 3.0, 7.0));
        const wave_freq = ctx.param(2, 5.5);
        const glow = ctx.param(3, 1.25);

        var centers: [8][2]f32 = undefined;
        for (0..ball_count) |i| {
            const fi: f32 = @floatFromInt(i + 1);
            centers[i] = .{
                @cos(ctx.time_sec * (0.42 + fi * 0.13) + fi * 1.7) * 0.72,
                @sin(ctx.time_sec * (0.55 + fi * 0.11) + fi * 2.3) * 0.52,
            };
        }

        const vw = @as(f32, @floatFromInt(@max(ctx.width, 1)));
        const vh = @as(f32, @floatFromInt(@max(ctx.height, 1)));
        var total_balls = ball_count;
        if (ctx.pointer_x > 0 and ctx.pointer_y > 0 and ctx.pointer_x < vw and ctx.pointer_y < vh) {
            centers[total_balls] = .{
                (ctx.pointer_x / vw - 0.5) * 2.4,
                (ctx.pointer_y / vh - 0.5) * 2.0 * aspect,
            };
            total_balls += 1;
        }

        const rgba = sdk.allocSlice(u8, @as(usize, res_w) * @as(usize, res_h) * 4);
        var idx: usize = 0;
        var y: u32 = 0;
        while (y < res_h) : (y += 1) {
            const py = (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(res_h)) - 0.5) * 2.0 * aspect;
            var x: u32 = 0;
            while (x < res_w) : (x += 1) {
                const px = (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(res_w)) - 0.5) * 2.4;
                var field: f32 = 0.0;
                for (0..total_balls) |bi| {
                    const dx = px - centers[bi][0];
                    const dy = py - centers[bi][1];
                    const weight: f32 = if (bi == ball_count and ctx.pointer_down) 0.18 else 0.095;
                    field += weight / (dx * dx + dy * dy + 0.045);
                }

                const rings = 0.5 + 0.5 * @sin(field * wave_freq - ctx.time_sec * 2.2);
                const intensity = std.math.clamp(field * 0.34 * glow + rings * 0.22, 0.0, 1.0);
                const hue = 0.58 + field * 0.085 + @sin(px * 1.4 + ctx.time_sec * 0.4) * 0.06;
                const sat = std.math.clamp(0.92 - intensity * 0.28, 0.25, 0.95);
                const col = sdk.hsvSrgb8(hue, sat, 0.06 + intensity * 0.94);
                rgba[idx + 0] = col[0];
                rgba[idx + 1] = col[1];
                rgba[idx + 2] = col[2];
                rgba[idx + 3] = 255;
                idx += 4;
            }
        }

        return .{ .width = res_w, .height = res_h, .rgba = rgba };
    }

    pub fn renderVector(ctx: sdk.FrameContext) []const sdk.ExternDrawShape {
        const w: f32 = @floatFromInt(@max(ctx.width, 1));
        const h: f32 = @floatFromInt(@max(ctx.height, 1));
        const ball_count: usize = @intFromFloat(std.math.clamp(ctx.param(1, 5.0), 3.0, 7.0));
        const glow = ctx.param(3, 1.25);

        const rings_per_ball: usize = 6;
        const out = sdk.allocSlice(sdk.ExternDrawShape, 1 + ball_count * (rings_per_ball + 1));
        var n: usize = 0;

        out[n] = sdk.ExternDrawShape.fillRect(0, 0, w, h, .{ 0.01, 0.008, 0.025, 1.0 });
        n += 1;

        for (0..ball_count) |i| {
            const fi: f32 = @floatFromInt(i + 1);
            const bx = w * (0.5 + 0.33 * @cos(ctx.time_sec * (0.42 + fi * 0.13) + fi * 1.7));
            const by = h * (0.5 + 0.33 * @sin(ctx.time_sec * (0.55 + fi * 0.11) + fi * 2.3));
            const hue = 0.58 + fi * 0.09;
            for (0..rings_per_ball) |r_i| {
                const rf: f32 = @floatFromInt(r_i + 1);
                const rad = rf * 18.0 * glow;
                const col = sdk.hsvLinear(hue + rf * 0.03, 0.78, 0.92, (1.0 - rf / 7.0) * 0.65);
                out[n] = sdk.ExternDrawShape.strokeCircle(bx, by, rad, 2.0, col);
                n += 1;
            }
            out[n] = sdk.ExternDrawShape.fillCircle(bx, by, 7.0, sdk.hsvLinear(hue, 0.35, 1.0, 0.95));
            n += 1;
        }
        return out[0..n];
    }
};

pub const panic = sdk.panic;
pub const cabi_realloc = sdk.cabiReallocExport;

comptime {
    sdk.exportSource(Impl);
}
