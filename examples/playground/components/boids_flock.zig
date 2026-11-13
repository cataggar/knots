const std = @import("std");
const sdk = @import("sdk");

const max_boids = 128;

const Boid = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    hue: f32,
};

var boids: [max_boids]Boid = undefined;
var initialized: bool = false;

fn ensureInit(w: f32, h: f32) void {
    if (initialized) return;
    initialized = true;
    var seed: u32 = 0x9e3779b9;
    for (&boids, 0..) |*b, i| {
        seed = seed *% 1664525 +% 1013904223;
        const rx = @as(f32, @floatFromInt(seed & 0xffff)) / 65535.0;
        seed = seed *% 1664525 +% 1013904223;
        const ry = @as(f32, @floatFromInt(seed & 0xffff)) / 65535.0;
        const ang = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(max_boids))) * std.math.pi * 2.0;
        b.* = .{
            .x = 24.0 + rx * @max(w - 48.0, 64.0),
            .y = 24.0 + ry * @max(h - 48.0, 64.0),
            .vx = @cos(ang) * 90.0,
            .vy = @sin(ang) * 90.0,
            .hue = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(max_boids)),
        };
    }
}

const params = [_]sdk.ParamSpec{
    .{ .name = "Agents", .min_val = 24.0, .max_val = 112.0, .default_val = 68.0, .step = 4.0 },
    .{ .name = "Cohesion", .min_val = 0.15, .max_val = 2.0, .default_val = 0.85, .step = 0.05 },
    .{ .name = "Web radius", .min_val = 28.0, .max_val = 104.0, .default_val = 62.0, .step = 2.0 },
    .{ .name = "Speed", .min_val = 50.0, .max_val = 240.0, .default_val = 135.0, .step = 5.0 },
};

const Impl = struct {
    pub fn describe() sdk.ComponentInfo {
        return .{
            .id = "boids-flock",
            .title = "Emergent Boids Flock",
            .summary = "Stateful flocking agents stored in isolated component memory with constellation links.",
            .role = .generator,
            .preferred_output = .vector_scene,
            .params = &params,
        };
    }

    fn stepSimulation(ctx: sdk.FrameContext, count: usize, cohesion: f32, web_radius: f32, target_speed: f32) void {
        const w: f32 = @floatFromInt(@max(ctx.width, 64));
        const h: f32 = @floatFromInt(@max(ctx.height, 64));
        ensureInit(w, h);

        const dt = std.math.clamp(ctx.delta_sec, 0.001, 0.04);
        const sep_r2: f32 = 24.0 * 24.0;
        const neigh_r2: f32 = web_radius * web_radius;
        const has_ptr = ctx.pointer_x > 0 and ctx.pointer_y > 0 and ctx.pointer_x < w and ctx.pointer_y < h;

        for (0..count) |i| {
            var b = boids[i];
            var cx_sum: f32 = 0;
            var cy_sum: f32 = 0;
            var vx_sum: f32 = 0;
            var vy_sum: f32 = 0;
            var sep_x: f32 = 0;
            var sep_y: f32 = 0;
            var neighbors: u32 = 0;

            for (0..count) |j| {
                if (i == j) continue;
                const other = boids[j];
                const dx = other.x - b.x;
                const dy = other.y - b.y;
                const d2 = dx * dx + dy * dy;
                if (d2 < neigh_r2 and d2 > 0.001) {
                    cx_sum += other.x;
                    cy_sum += other.y;
                    vx_sum += other.vx;
                    vy_sum += other.vy;
                    neighbors += 1;
                    if (d2 < sep_r2) {
                        const inv = 1.0 / @sqrt(d2);
                        sep_x -= dx * inv * 42.0;
                        sep_y -= dy * inv * 42.0;
                    }
                }
            }

            if (neighbors > 0) {
                const nf: f32 = @floatFromInt(neighbors);
                b.vx += (((cx_sum / nf) - b.x) * cohesion * 1.4 + ((vx_sum / nf) - b.vx) * 1.8 + sep_x * 2.4) * dt;
                b.vy += (((cy_sum / nf) - b.y) * cohesion * 1.4 + ((vy_sum / nf) - b.vy) * 1.8 + sep_y * 2.4) * dt;
            }

            if (has_ptr) {
                const pdx = ctx.pointer_x - b.x;
                const pdy = ctx.pointer_y - b.y;
                const pd = @sqrt(pdx * pdx + pdy * pdy + 64.0);
                if (ctx.pointer_down) {
                    // Vortex repulsion burst on click/drag
                    b.vx += (-pdx / pd * 220.0 - pdy / pd * 140.0) * dt;
                    b.vy += (-pdy / pd * 220.0 + pdx / pd * 140.0) * dt;
                } else if (pd < 220.0) {
                    b.vx += (pdx / pd * 95.0) * dt;
                    b.vy += (pdy / pd * 95.0) * dt;
                }
            }

            const margin: f32 = 36.0;
            if (b.x < margin) b.vx += (margin - b.x) * 5.0 * dt;
            if (b.x > w - margin) b.vx -= (b.x - (w - margin)) * 5.0 * dt;
            if (b.y < margin) b.vy += (margin - b.y) * 5.0 * dt;
            if (b.y > h - margin) b.vy -= (b.y - (h - margin)) * 5.0 * dt;

            const speed = @sqrt(b.vx * b.vx + b.vy * b.vy + 0.001);
            const clamped = std.math.clamp(speed, target_speed * 0.55, target_speed * 1.35);
            b.vx = (b.vx / speed) * clamped;
            b.vy = (b.vy / speed) * clamped;

            b.x = std.math.clamp(b.x + b.vx * dt, 4.0, w - 4.0);
            b.y = std.math.clamp(b.y + b.vy * dt, 4.0, h - 4.0);
            boids[i] = b;
        }
    }

    pub fn renderVector(ctx: sdk.FrameContext) []const sdk.ExternDrawShape {
        const w: f32 = @floatFromInt(@max(ctx.width, 64));
        const h: f32 = @floatFromInt(@max(ctx.height, 64));
        const count: usize = @intFromFloat(std.math.clamp(ctx.param(0, 68.0), 24.0, @as(f32, @floatFromInt(max_boids))));
        const cohesion = ctx.param(1, 0.85);
        const web_radius = ctx.param(2, 62.0);
        const speed = ctx.param(3, 135.0);

        stepSimulation(ctx, count, cohesion, web_radius, speed);

        const max_links: usize = 420;
        const out = sdk.allocSlice(sdk.ExternDrawShape, 2 + max_links + count);
        var n: usize = 0;

        out[n] = sdk.ExternDrawShape.fillRect(0, 0, w, h, .{ 0.007, 0.014, 0.020, 1.0 });
        n += 1;

        const r2 = web_radius * web_radius;
        var links: usize = 0;
        outer: for (0..count) |i| {
            const a = boids[i];
            for (i + 1..count) |j| {
                const b = boids[j];
                const dx = b.x - a.x;
                const dy = b.y - a.y;
                const d2 = dx * dx + dy * dy;
                if (d2 < r2) {
                    const alpha = (1.0 - @sqrt(d2) / web_radius) * 0.55;
                    const col = sdk.hsvLinear(0.48 + a.hue * 0.22, 0.68, 0.88, alpha);
                    out[n] = sdk.ExternDrawShape.line(a.x, a.y, b.x, b.y, 1.15, col);
                    n += 1;
                    links += 1;
                    if (links >= max_links) break :outer;
                }
            }
        }

        if (ctx.pointer_x > 0 and ctx.pointer_y > 0 and ctx.pointer_x < w and ctx.pointer_y < h) {
            const ring_col: [4]f32 = if (ctx.pointer_down) .{ 0.95, 0.28, 0.18, 0.65 } else .{ 0.18, 0.68, 0.85, 0.35 };
            out[n] = sdk.ExternDrawShape.strokeCircle(ctx.pointer_x, ctx.pointer_y, if (ctx.pointer_down) 44.0 else 28.0, 1.5, ring_col);
            n += 1;
        }

        for (0..count) |i| {
            const b = boids[i];
            const vlen = @sqrt(b.vx * b.vx + b.vy * b.vy + 0.001);
            const ux = b.vx / vlen;
            const uy = b.vy / vlen;
            const px = -uy;
            const py = ux;
            const nose = [2]f32{ b.x + ux * 8.5, b.y + uy * 8.5 };
            const left = [2]f32{ b.x - ux * 5.0 + px * 4.2, b.y - uy * 5.0 + py * 4.2 };
            const right = [2]f32{ b.x - ux * 5.0 - px * 4.2, b.y - uy * 5.0 - py * 4.2 };
            const col = sdk.hsvLinear(0.44 + b.hue * 0.3, 0.72, 0.98, 0.95);
            out[n] = sdk.ExternDrawShape.fillTriangle(nose, left, right, col);
            n += 1;
        }

        return out[0..n];
    }

    pub fn renderPixels(ctx: sdk.FrameContext) sdk.PixelFrame {
        const count: usize = @intFromFloat(std.math.clamp(ctx.param(0, 68.0), 24.0, @as(f32, @floatFromInt(max_boids))));
        stepSimulation(ctx, count, ctx.param(1, 0.85), ctx.param(2, 62.0), ctx.param(3, 135.0));

        const pw: u32 = 160;
        const ph: u32 = 104;
        const rgba = sdk.allocSlice(u8, @as(usize, pw) * @as(usize, ph) * 4);
        const sx = @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(@max(ctx.width, 1)));
        const sy = @as(f32, @floatFromInt(ph)) / @as(f32, @floatFromInt(@max(ctx.height, 1)));

        @memset(rgba, 12);
        var p: usize = 3;
        while (p < rgba.len) : (p += 4) rgba[p] = 255;

        for (0..count) |i| {
            const b = boids[i];
            const bx: i32 = @intFromFloat(b.x * sx);
            const by: i32 = @intFromFloat(b.y * sy);
            const col = sdk.hsvSrgb8(0.44 + b.hue * 0.3, 0.78, 0.98);
            var dy: i32 = -3;
            while (dy <= 3) : (dy += 1) {
                const yy = by + dy;
                if (yy < 0 or yy >= @as(i32, @intCast(ph))) continue;
                var dx: i32 = -3;
                while (dx <= 3) : (dx += 1) {
                    const xx = bx + dx;
                    if (xx < 0 or xx >= @as(i32, @intCast(pw))) continue;
                    const d2 = dx * dx + dy * dy;
                    if (d2 > 10) continue;
                    const wgt: u32 = @intCast(11 - d2);
                    const off = (@as(usize, @intCast(yy)) * @as(usize, pw) + @as(usize, @intCast(xx))) * 4;
                    rgba[off + 0] = @intCast(@min(255, @as(u32, rgba[off + 0]) + (@as(u32, col[0]) * wgt) / 12));
                    rgba[off + 1] = @intCast(@min(255, @as(u32, rgba[off + 1]) + (@as(u32, col[1]) * wgt) / 12));
                    rgba[off + 2] = @intCast(@min(255, @as(u32, rgba[off + 2]) + (@as(u32, col[2]) * wgt) / 12));
                }
            }
        }
        return .{ .width = pw, .height = ph, .rgba = rgba };
    }
};

pub const panic = sdk.panic;
pub const cabi_realloc = sdk.cabiReallocExport;

comptime {
    sdk.exportSource(Impl);
}
