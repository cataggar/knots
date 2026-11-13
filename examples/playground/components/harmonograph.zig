const std = @import("std");
const sdk = @import("sdk");

const params = [_]sdk.ParamSpec{
    .{ .name = "Harmonics", .min_val = 1.0, .max_val = 7.0, .default_val = 3.0, .step = 1.0 },
    .{ .name = "Ribbons", .min_val = 2.0, .max_val = 8.0, .default_val = 5.0, .step = 1.0 },
    .{ .name = "Twist", .min_val = 0.2, .max_val = 3.6, .default_val = 1.35, .step = 0.05 },
    .{ .name = "Hue", .min_val = 0.0, .max_val = 1.0, .default_val = 0.56, .step = 0.01 },
};

const Impl = struct {
    pub fn describe() sdk.ComponentInfo {
        return .{
            .id = "harmonograph",
            .title = "Orbital Harmonograph",
            .summary = "Phase-coupled harmonic vector ribbons and orbital nodes with pointer gravity.",
            .role = .generator,
            .preferred_output = .vector_scene,
            .params = &params,
        };
    }

    pub fn renderVector(ctx: sdk.FrameContext) []const sdk.ExternDrawShape {
        const w: f32 = @floatFromInt(@max(ctx.width, 1));
        const h: f32 = @floatFromInt(@max(ctx.height, 1));
        const cx = w * 0.5;
        const cy = h * 0.5;
        const radius_base = @min(w, h) * 0.38;

        const harmonics = std.math.clamp(ctx.param(0, 3.0), 1.0, 7.0);
        const ribbons_u: usize = @intFromFloat(std.math.clamp(ctx.param(1, 5.0), 2.0, 8.0));
        const twist = ctx.param(2, 1.35);
        const hue_base = ctx.param(3, 0.56);

        const segs_per_ribbon: usize = 96;
        // 1 backdrop + 3 guide rings + ribbons * (segs_per_ribbon lines + 2 endpoint circles)
        const max_shapes = 4 + ribbons_u * (segs_per_ribbon + 2);
        const out = sdk.allocSlice(sdk.ExternDrawShape, max_shapes);
        var n: usize = 0;

        out[n] = sdk.ExternDrawShape.fillRect(0, 0, w, h, .{ 0.008, 0.011, 0.022, 1.0 });
        n += 1;

        for (0..3) |ring_i| {
            const rf: f32 = @as(f32, @floatFromInt(ring_i + 1)) / 3.0;
            out[n] = sdk.ExternDrawShape.strokeCircle(cx, cy, radius_base * rf, 1.0, .{ 0.06, 0.11, 0.19, 0.55 });
            n += 1;
        }

        const has_ptr = ctx.pointer_x > 0 and ctx.pointer_y > 0 and ctx.pointer_x < w and ctx.pointer_y < h;
        const pull_strength: f32 = if (ctx.pointer_down) 0.42 else if (has_ptr) 0.16 else 0.0;

        for (0..ribbons_u) |r_idx| {
            const rf: f32 = @floatFromInt(r_idx);
            const phase = rf * (std.math.pi * 2.0 / @as(f32, @floatFromInt(ribbons_u))) + ctx.time_sec * 0.55;
            const ribbon_hue = hue_base + rf * 0.09 + @sin(ctx.time_sec * 0.25) * 0.05;

            var prev = evalPoint(0, segs_per_ribbon, cx, cy, radius_base, harmonics, twist, phase, ctx.time_sec, ctx.pointer_x, ctx.pointer_y, pull_strength);
            const first = prev;

            for (1..segs_per_ribbon + 1) |s_idx| {
                const cur = evalPoint(s_idx, segs_per_ribbon, cx, cy, radius_base, harmonics, twist, phase, ctx.time_sec, ctx.pointer_x, ctx.pointer_y, pull_strength);
                const frac = @as(f32, @floatFromInt(s_idx)) / @as(f32, @floatFromInt(segs_per_ribbon));
                const pulse = 0.45 + 0.55 * (0.5 + 0.5 * @sin(frac * std.math.pi * 4.0 - ctx.time_sec * 3.0));
                const color = sdk.hsvLinear(ribbon_hue + frac * 0.18, 0.78, 0.92, 0.35 + 0.55 * pulse);
                out[n] = sdk.ExternDrawShape.line(prev[0], prev[1], cur[0], cur[1], 1.6 + 1.8 * pulse, color);
                n += 1;
                prev = cur;
            }

            const node_color = sdk.hsvLinear(ribbon_hue + 0.08, 0.55, 1.0, 0.95);
            out[n] = sdk.ExternDrawShape.fillCircle(first[0], first[1], 4.2, node_color);
            n += 1;
            out[n] = sdk.ExternDrawShape.fillCircle(prev[0], prev[1], 3.2, node_color);
            n += 1;
        }

        return out[0..n];
    }

    pub fn renderPixels(ctx: sdk.FrameContext) sdk.PixelFrame {
        const pw: u32 = 160;
        const ph: u32 = 104;
        const rgba = sdk.allocSlice(u8, @as(usize, pw) * @as(usize, ph) * 4);
        const harmonics = std.math.clamp(ctx.param(0, 3.0), 1.0, 7.0);
        const twist = ctx.param(2, 1.35);
        const hue_base = ctx.param(3, 0.56);

        var idx: usize = 0;
        var y: u32 = 0;
        while (y < ph) : (y += 1) {
            const ny = (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(ph)) - 0.5) * 2.0;
            var x: u32 = 0;
            while (x < pw) : (x += 1) {
                const nx = (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(pw)) - 0.5) * 2.4;
                const r = @sqrt(nx * nx + ny * ny);
                const ang = std.math.atan2(ny, nx);
                const wave = @sin(r * 10.0 * twist - ctx.time_sec * 2.4 + @sin(ang * harmonics + ctx.time_sec));
                const glow = std.math.clamp(0.5 + 0.5 * wave, 0.0, 1.0) * std.math.clamp(1.25 - r * 0.75, 0.05, 1.0);
                const px = sdk.hsvSrgb8(hue_base + r * 0.22 + wave * 0.08, 0.75, 0.10 + 0.88 * glow);
                rgba[idx + 0] = px[0];
                rgba[idx + 1] = px[1];
                rgba[idx + 2] = px[2];
                rgba[idx + 3] = 255;
                idx += 4;
            }
        }
        return .{ .width = pw, .height = ph, .rgba = rgba };
    }

    fn evalPoint(
        step: usize,
        total: usize,
        cx: f32,
        cy: f32,
        radius: f32,
        harmonics: f32,
        twist: f32,
        phase: f32,
        t: f32,
        px: f32,
        py: f32,
        pull: f32,
    ) [2]f32 {
        const u = (@as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(total))) * std.math.pi * 2.0;
        const env = 0.62 + 0.38 * @cos(u * twist + t * 0.7);
        var x = cx + radius * env * (@cos(u + phase) * 0.72 + 0.28 * @cos(u * harmonics - t * 1.3 + phase));
        var y = cy + radius * env * (@sin(u * twist + phase) * 0.72 + 0.28 * @sin(u * harmonics + t * 1.1 - phase));
        if (pull > 0) {
            const dx = px - x;
            const dy = py - y;
            const dist_sq = dx * dx + dy * dy + 2400.0;
            const factor = pull * (18000.0 / dist_sq);
            x += dx * @min(factor, 0.65);
            y += dy * @min(factor, 0.65);
        }
        return .{ x, y };
    }
};

pub const panic = sdk.panic;
pub const cabi_realloc = sdk.cabiReallocExport;

comptime {
    sdk.exportSource(Impl);
}
