const std = @import("std");

pub const OutputKind = enum(u8) {
    vector_scene = 0,
    pixel_buffer = 1,
};

pub const Role = enum(u8) {
    generator = 0,
    effect = 1,
};

pub const ShapeTag = enum(u8) {
    fill_rect = 0,
    stroke_rect = 1,
    fill_circle = 2,
    stroke_circle = 3,
    line_seg = 4,
    fill_triangle = 5,
};

pub const ParamSpec = struct {
    name: []const u8,
    min_val: f32,
    max_val: f32,
    default_val: f32,
    step: f32 = 0,
};

pub const ComponentInfo = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    role: Role,
    preferred_output: OutputKind,
    params: []const ParamSpec,
};

pub const FrameContext = struct {
    time_sec: f32,
    delta_sec: f32,
    width: u32,
    height: u32,
    pointer_x: f32,
    pointer_y: f32,
    pointer_down: bool,
    params: []const f32,

    pub fn param(self: FrameContext, idx: usize, fallback: f32) f32 {
        return if (idx < self.params.len) self.params[idx] else fallback;
    }
};

pub const ExternParamSpec = extern struct {
    name_ptr: u32,
    name_len: u32,
    min_val: f32,
    max_val: f32,
    default_val: f32,
    step: f32,
};

pub const ExternComponentInfo = extern struct {
    id_ptr: u32,
    id_len: u32,
    title_ptr: u32,
    title_len: u32,
    summary_ptr: u32,
    summary_len: u32,
    role: u8,
    preferred_output: u8,
    _pad: [2]u8 = .{ 0, 0 },
    params_ptr: u32,
    params_len: u32,
};

pub const ExternListRef = extern struct {
    ptr: u32,
    len: u32,
};

pub const ExternDrawShape = extern struct {
    tag: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 0,
    y2: f32 = 0,
    radius_or_width: f32 = 0,
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,

    pub fn fillRect(x: f32, y: f32, w: f32, h: f32, color: [4]f32) ExternDrawShape {
        return .{
            .tag = @backingInt(ShapeTag.fill_rect),
            .x0 = x,
            .y0 = y,
            .x1 = w,
            .y1 = h,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        };
    }

    pub fn strokeRect(x: f32, y: f32, w: f32, h: f32, thickness: f32, color: [4]f32) ExternDrawShape {
        return .{
            .tag = @backingInt(ShapeTag.stroke_rect),
            .x0 = x,
            .y0 = y,
            .x1 = w,
            .y1 = h,
            .radius_or_width = thickness,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        };
    }

    pub fn fillCircle(cx: f32, cy: f32, radius: f32, color: [4]f32) ExternDrawShape {
        return .{
            .tag = @backingInt(ShapeTag.fill_circle),
            .x0 = cx,
            .y0 = cy,
            .radius_or_width = radius,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        };
    }

    pub fn strokeCircle(cx: f32, cy: f32, radius: f32, thickness: f32, color: [4]f32) ExternDrawShape {
        return .{
            .tag = @backingInt(ShapeTag.stroke_circle),
            .x0 = cx,
            .y0 = cy,
            .x1 = radius,
            .radius_or_width = thickness,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        };
    }

    pub fn line(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: [4]f32) ExternDrawShape {
        return .{
            .tag = @backingInt(ShapeTag.line_seg),
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .radius_or_width = thickness,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        };
    }

    pub fn fillTriangle(p0: [2]f32, p1: [2]f32, p2: [2]f32, color: [4]f32) ExternDrawShape {
        return .{
            .tag = @backingInt(ShapeTag.fill_triangle),
            .x0 = p0[0],
            .y0 = p0[1],
            .x1 = p1[0],
            .y1 = p1[1],
            .x2 = p2[0],
            .y2 = p2[1],
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
        };
    }
};

pub const ExternPixelFrame = extern struct {
    width: u32,
    height: u32,
    rgba_ptr: u32,
    rgba_len: u32,
};

pub const PixelFrame = struct {
    width: u32,
    height: u32,
    rgba: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(ExternParamSpec) == 24);
    std.debug.assert(@alignOf(ExternParamSpec) == 4);
    std.debug.assert(@sizeOf(ExternComponentInfo) == 36);
    std.debug.assert(@alignOf(ExternComponentInfo) == 4);
    std.debug.assert(@sizeOf(ExternListRef) == 8);
    std.debug.assert(@sizeOf(ExternDrawShape) == 48);
    std.debug.assert(@alignOf(ExternDrawShape) == 4);
    std.debug.assert(@sizeOf(ExternPixelFrame) == 16);
    std.debug.assert(@alignOf(ExternPixelFrame) == 4);
}

// Per-call resettable scratch region for Canonical ABI lowering/lifting + guest frame buffers.
// Lazily allocated via `@wasmMemoryGrow` on first call so `.wasm` component binaries stay ~8-15 KiB
// on the wire without embedding a zeroed data segment.
var dynamic_base: usize = 0;
var dynamic_cap: usize = 0;
var scratch_offset: usize = 0;

var ret_info: ExternComponentInfo align(8) = undefined;
var ret_list: ExternListRef align(8) = undefined;
var ret_pixels: ExternPixelFrame align(8) = undefined;

pub fn resetScratch() void {
    scratch_offset = 0;
}

pub fn cabiRealloc(old_ptr: u32, old_size: u32, align_bytes: u32, new_size: u32) u32 {
    const alignment: usize = if (align_bytes == 0) 1 else @intCast(align_bytes);
    if (new_size == 0) return @intCast(alignment);

    const needed: usize = @intCast(new_size);
    const old_len: usize = @intCast(old_size);
    const page_size: usize = 65536;

    if (dynamic_cap == 0) {
        const current_pages = @wasmMemorySize(0);
        const need_bytes = @max(needed + alignment, 512 * 1024);
        const add_pages = (need_bytes + page_size - 1) / page_size;
        const prev_pages = @wasmMemoryGrow(0, add_pages);
        if (prev_pages < 0) @trap();
        dynamic_base = @as(usize, @intCast(current_pages)) * page_size;
        dynamic_cap = add_pages * page_size;
    }

    const aligned_off = std.mem.alignForward(usize, scratch_offset, alignment);
    if (aligned_off + needed > dynamic_cap) {
        const extra = (aligned_off + needed - dynamic_cap) + (256 * 1024);
        const add_pages = (extra + page_size - 1) / page_size;
        const prev_pages = @wasmMemoryGrow(0, add_pages);
        if (prev_pages < 0) @trap();
        dynamic_cap += add_pages * page_size;
    }

    const dest_addr = dynamic_base + aligned_off;
    if (old_ptr != 0 and old_len > 0) {
        const copy_len = @min(old_len, needed);
        const src: [*]const u8 = @ptrFromInt(@as(usize, old_ptr));
        const dst: [*]u8 = @ptrFromInt(dest_addr);
        @memcpy(dst[0..copy_len], src[0..copy_len]);
    }
    scratch_offset = aligned_off + needed;
    return @intCast(dest_addr);
}

pub fn allocSlice(comptime T: type, count: usize) []T {
    if (count == 0) return &.{};
    const byte_len: u32 = @intCast(count * @sizeOf(T));
    const ptr = cabiRealloc(0, 0, @alignOf(T), byte_len);
    const typed: [*]T = @ptrFromInt(@as(usize, ptr));
    return typed[0..count];
}

pub fn srgbToLinear(c: f32) f32 {
    if (c <= 0.0) return 0.0;
    if (c >= 1.0) return 1.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

pub fn hsvLinear(h_in: f32, s: f32, v: f32, alpha: f32) [4]f32 {
    const h = h_in - @floor(h_in);
    const h6 = h * 6.0;
    const sector: u32 = @as(u32, @intFromFloat(@floor(h6))) % 6;
    const f = h6 - @floor(h6);
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));
    const rgb: [3]f32 = switch (sector) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{ srgbToLinear(rgb[0]), srgbToLinear(rgb[1]), srgbToLinear(rgb[2]), alpha };
}

pub fn hsvSrgb8(h_in: f32, s: f32, v: f32) [4]u8 {
    const h = h_in - @floor(h_in);
    const h6 = h * 6.0;
    const sector: u32 = @as(u32, @intFromFloat(@floor(h6))) % 6;
    const f = h6 - @floor(h6);
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));
    const rgb: [3]f32 = switch (sector) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{
        @intFromFloat(std.math.clamp(rgb[0], 0.0, 1.0) * 255.0 + 0.5),
        @intFromFloat(std.math.clamp(rgb[1], 0.0, 1.0) * 255.0 + 0.5),
        @intFromFloat(std.math.clamp(rgb[2], 0.0, 1.0) * 255.0 + 0.5),
        255,
    };
}

/// Upstream WIT `knots:visual/upstream@0.1.0` imports for `visual-effect` components.
pub const upstream = struct {
    extern "knots:visual/upstream@0.1.0" fn @"render-vector"(
        time_sec: f32,
        delta_sec: f32,
        width: u32,
        height: u32,
        pointer_x: f32,
        pointer_y: f32,
        pointer_down: i32,
        params_ptr: u32,
        params_len: u32,
        ret_ptr: *ExternListRef,
    ) callconv(.{ .wasm_mvp = .{} }) void;

    extern "knots:visual/upstream@0.1.0" fn @"render-pixels"(
        time_sec: f32,
        delta_sec: f32,
        width: u32,
        height: u32,
        pointer_x: f32,
        pointer_y: f32,
        pointer_down: i32,
        params_ptr: u32,
        params_len: u32,
        ret_ptr: *ExternPixelFrame,
    ) callconv(.{ .wasm_mvp = .{} }) void;

    pub fn renderVector(ctx: FrameContext) []const ExternDrawShape {
        var out: ExternListRef align(8) = .{ .ptr = 0, .len = 0 };
        const p_ptr: u32 = if (ctx.params.len > 0) @intCast(@intFromPtr(ctx.params.ptr)) else 0;
        const p_len: u32 = @intCast(ctx.params.len);
        @"render-vector"(
            ctx.time_sec,
            ctx.delta_sec,
            ctx.width,
            ctx.height,
            ctx.pointer_x,
            ctx.pointer_y,
            @intFromBool(ctx.pointer_down),
            p_ptr,
            p_len,
            &out,
        );
        if (out.len == 0 or out.ptr == 0) return &.{};
        const items: [*]const ExternDrawShape = @ptrFromInt(@as(usize, out.ptr));
        return items[0..@intCast(out.len)];
    }

    pub fn renderPixels(ctx: FrameContext) PixelFrame {
        var out: ExternPixelFrame align(8) = .{ .width = 0, .height = 0, .rgba_ptr = 0, .rgba_len = 0 };
        const p_ptr: u32 = if (ctx.params.len > 0) @intCast(@intFromPtr(ctx.params.ptr)) else 0;
        const p_len: u32 = @intCast(ctx.params.len);
        @"render-pixels"(
            ctx.time_sec,
            ctx.delta_sec,
            ctx.width,
            ctx.height,
            ctx.pointer_x,
            ctx.pointer_y,
            @intFromBool(ctx.pointer_down),
            p_ptr,
            p_len,
            &out,
        );
        if (out.rgba_len == 0 or out.rgba_ptr == 0) {
            return .{ .width = out.width, .height = out.height, .rgba = &.{} };
        }
        const bytes: [*]const u8 = @ptrFromInt(@as(usize, out.rgba_ptr));
        return .{
            .width = out.width,
            .height = out.height,
            .rgba = bytes[0..@intCast(out.rgba_len)],
        };
    }
};

fn decodeContext(
    time_sec: f32,
    delta_sec: f32,
    width: u32,
    height: u32,
    pointer_x: f32,
    pointer_y: f32,
    pointer_down: i32,
    params_ptr: u32,
    params_len: u32,
) FrameContext {
    const params_slice: []const f32 = if (params_len > 0 and params_ptr != 0) blk: {
        const ptr: [*]const f32 = @ptrFromInt(@as(usize, params_ptr));
        break :blk ptr[0..@intCast(params_len)];
    } else &.{};
    return .{
        .time_sec = time_sec,
        .delta_sec = delta_sec,
        .width = width,
        .height = height,
        .pointer_x = pointer_x,
        .pointer_y = pointer_y,
        .pointer_down = pointer_down != 0,
        .params = params_slice,
    };
}

pub const panic = std.debug.FullPanic(trapPanic);

fn trapPanic(_: []const u8, _: ?usize) noreturn {
    @trap();
}

pub fn cabiReallocExport(old_ptr: u32, old_size: u32, align_bytes: u32, new_size: u32) callconv(.{ .wasm_mvp = .{} }) u32 {
    return cabiRealloc(old_ptr, old_size, align_bytes, new_size);
}

/// Generates Canonical ABI exports (`cabi_realloc`, `knots:visual/source@0.1.0#*`,
/// and `cabi_post_*`) for a guest visual component implementation `Impl`.
pub fn exportSource(comptime Impl: type) void {
    const Wrapper = struct {
        fn describeExport() callconv(.{ .wasm_mvp = .{} }) u32 {
            const info: ComponentInfo = Impl.describe();
            const specs = allocSlice(ExternParamSpec, info.params.len);
            for (info.params, 0..) |p, idx| {
                specs[idx] = .{
                    .name_ptr = @intCast(@intFromPtr(p.name.ptr)),
                    .name_len = @intCast(p.name.len),
                    .min_val = p.min_val,
                    .max_val = p.max_val,
                    .default_val = p.default_val,
                    .step = p.step,
                };
            }
            ret_info = .{
                .id_ptr = @intCast(@intFromPtr(info.id.ptr)),
                .id_len = @intCast(info.id.len),
                .title_ptr = @intCast(@intFromPtr(info.title.ptr)),
                .title_len = @intCast(info.title.len),
                .summary_ptr = @intCast(@intFromPtr(info.summary.ptr)),
                .summary_len = @intCast(info.summary.len),
                .role = @backingInt(info.role),
                .preferred_output = @backingInt(info.preferred_output),
                .params_ptr = if (specs.len > 0) @intCast(@intFromPtr(specs.ptr)) else 0,
                .params_len = @intCast(specs.len),
            };
            return @intCast(@intFromPtr(&ret_info));
        }

        fn postDescribe(_: u32) callconv(.{ .wasm_mvp = .{} }) void {
            resetScratch();
        }

        fn renderVectorExport(
            time_sec: f32,
            delta_sec: f32,
            width: u32,
            height: u32,
            pointer_x: f32,
            pointer_y: f32,
            pointer_down: i32,
            params_ptr: u32,
            params_len: u32,
        ) callconv(.{ .wasm_mvp = .{} }) u32 {
            const ctx = decodeContext(time_sec, delta_sec, width, height, pointer_x, pointer_y, pointer_down, params_ptr, params_len);
            const shapes = Impl.renderVector(ctx);
            ret_list = .{
                .ptr = if (shapes.len > 0) @intCast(@intFromPtr(shapes.ptr)) else 0,
                .len = @intCast(shapes.len),
            };
            return @intCast(@intFromPtr(&ret_list));
        }

        fn postRenderVector(_: u32) callconv(.{ .wasm_mvp = .{} }) void {
            resetScratch();
        }

        fn renderPixelsExport(
            time_sec: f32,
            delta_sec: f32,
            width: u32,
            height: u32,
            pointer_x: f32,
            pointer_y: f32,
            pointer_down: i32,
            params_ptr: u32,
            params_len: u32,
        ) callconv(.{ .wasm_mvp = .{} }) u32 {
            const ctx = decodeContext(time_sec, delta_sec, width, height, pointer_x, pointer_y, pointer_down, params_ptr, params_len);
            const pf = Impl.renderPixels(ctx);
            ret_pixels = .{
                .width = pf.width,
                .height = pf.height,
                .rgba_ptr = if (pf.rgba.len > 0) @intCast(@intFromPtr(pf.rgba.ptr)) else 0,
                .rgba_len = @intCast(pf.rgba.len),
            };
            return @intCast(@intFromPtr(&ret_pixels));
        }

        fn postRenderPixels(_: u32) callconv(.{ .wasm_mvp = .{} }) void {
            resetScratch();
        }
    };

    @export(&cabiReallocExport, .{ .name = "cabi_realloc" });
    @export(&Wrapper.describeExport, .{ .name = "knots:visual/source@0.1.0#describe" });
    @export(&Wrapper.postDescribe, .{ .name = "cabi_post_knots:visual/source@0.1.0#describe" });
    @export(&Wrapper.renderVectorExport, .{ .name = "knots:visual/source@0.1.0#render-vector" });
    @export(&Wrapper.postRenderVector, .{ .name = "cabi_post_knots:visual/source@0.1.0#render-vector" });
    @export(&Wrapper.renderPixelsExport, .{ .name = "knots:visual/source@0.1.0#render-pixels" });
    @export(&Wrapper.postRenderPixels, .{ .name = "cabi_post_knots:visual/source@0.1.0#render-pixels" });
}
