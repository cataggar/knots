const layout = @import("layout");
const text = @import("text");
const window = @import("window");
const math = @import("math");

const Element = layout.Element;
const std = @import("std");
const gpu = @import("gpu");
const DrawList = @import("render").DrawList;

const State = @import("State.zig");
const Input = @import("Input.zig");
const animation = @import("animation.zig");

const Decoration = @import("decoration.zig").Decoration;
const Key = @import("Key.zig");
const Style = @import("Style.zig");
const Size = @import("Size.zig");
const Theme = @import("Theme.zig");
const scrollbar = @import("scrollbar.zig");
const canvas_tessellator = @import("canvas_tessellator.zig");

const Allocator = std.mem.Allocator;

const INV_SQRT2: f32 = 0.70710677;
const TEXT_QUAD_NORMALS = [4][2]f32{
    .{ -INV_SQRT2, -INV_SQRT2 }, // tl
    .{ INV_SQRT2, -INV_SQRT2 }, // tr
    .{ INV_SQRT2, INV_SQRT2 }, // br
    .{ -INV_SQRT2, INV_SQRT2 }, // bl
};

pub const HitRecord = struct {
    id: Element.Id,
    bounds: math.Rect,
    clip: ?math.Rect,
    layer: u8,
    insertion_order: u32,
};

pub const Config = struct {
    /// Default is Roboto regular + Material icons regular.
    fonts: []const text.Font.FontKey = &.{.{ "default", @embedFile("fonts/default.ttf") }},
    /// Per-pool eviction TTLs in frames. Long-lived widget state (cursor,
    /// scroll, dropdown-open, selection) survives conditional hiding (Tabs,
    /// Accordion, Tree); short-lived state (anim) is evicted promptly.
    state_ttls: State.Ttls = .{},
    theme: Theme = Theme.light,
};

pub const Stats = struct {
    elements: usize = 0,
    hit_records: usize = 0,
    scroll_containers: usize = 0,
    decorations: usize = 0,
    layers: usize = 0,
};

allocator: Allocator,
layout_ctx: layout.Context,
decorations: std.ArrayList(Decoration),
font: text.Font,
state: State,
input: Input,
hit_records: std.ArrayList(HitRecord),
hit_counter: u32,
scroll_geoms: std.ArrayList(scrollbar.SlotGeom),
content_scale: f32,
anim_active: bool,
theme: Theme,
last_stats: Stats,

const UI = @This();

pub fn init(allocator: Allocator, cfg: Config) !UI {
    return .{
        .allocator = allocator,
        .layout_ctx = .init(allocator),
        .decorations = .empty,
        .state = .init(allocator, cfg.state_ttls),
        .input = .{},
        .font = try .init(allocator, cfg.fonts),
        .hit_records = .empty,
        .hit_counter = 0,
        .scroll_geoms = .empty,
        .content_scale = 1.0,
        .anim_active = false,
        .theme = cfg.theme,
        .last_stats = .{},
    };
}

pub fn deinit(self: *UI) void {
    self.layout_ctx.deinit();
    self.decorations.deinit(self.allocator);
    self.font.deinit();
    self.state.deinit();
    self.hit_records.deinit(self.allocator);
    self.scroll_geoms.deinit(self.allocator);
}

pub fn open(self: *UI, key: Key, element: Element.Config, decoration: Decoration) !Element.Id {
    const id = key.hash();
    const slot = try self.layout_ctx.open(id, element);
    try self.decorations.append(self.allocator, decoration);
    if (decoration == .text) {
        const el = self.layout_ctx.pool.get(slot);
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    return id;
}

pub fn close(self: *UI) void {
    self.layout_ctx.close();
}

pub fn openRoot(self: *UI, key: Key, x: f32, y: f32, config: Element.Config, decoration: Decoration) !Element.Id {
    const id = key.hash();
    const slot = try self.layout_ctx.openRoot(id, config);
    try self.decorations.append(self.allocator, decoration);
    const el = self.layout_ctx.pool.get(slot);
    el.box.setX(x);
    el.box.setY(y);
    if (decoration == .text) {
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    return id;
}

/// Open an absolutely-positioned element inside the current parent at parent-local
/// offset (x, y) with size (w, h). The caller still pairs this with `close()`.
/// Use this for overlay rects (cursor, selection, drag handles, tab indicators)
/// that need precise placement on top of sibling content without escaping the parent.
/// For popups that need to escape clipping or the layout tree, use `openRoot`.
pub fn openAt(self: *UI, key: Key, x: f32, y: f32, w: f32, h: f32, config: Element.Config, decoration: Decoration) !Element.Id {
    var cfg = config;
    cfg.position = .absolute;
    cfg.width = .fixed(w);
    cfg.height = .fixed(h);
    cfg.offset = .{ x, y };
    return self.open(key, cfg, decoration);
}

pub fn lineHeight(self: *UI, size: Size, font: ?[]const u8) !f32 {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    return (try face.lineHeight(size.value * scale)) / scale;
}

pub fn textDecoration(self: *UI, content: []const u8, size: Size, font: ?[]const u8, wrap: bool) !Decoration {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    if (wrap) {
        const lh = (try face.lineHeight(size.value * scale)) / scale;
        return .{ .text = .{
            .content = content,
            .size = size.value,
            .font = font,
            .intrinsic_w = 0,
            .intrinsic_h = lh,
            .wrap = true,
        } };
    }
    const measured = try face.measure(content, size.value * scale);
    return .{ .text = .{
        .content = content,
        .size = size.value,
        .font = font,
        .intrinsic_w = measured.width / scale,
        .intrinsic_h = measured.height / scale,
        .wrap = false,
    } };
}

pub fn setDecoration(self: *UI, slot: Element.Slot, decoration: Decoration) void {
    self.decorations.items[slot] = decoration;
}

pub fn currentSlot(self: *UI) Element.Slot {
    const stack = self.layout_ctx.stack.items;
    return stack[stack.len - 1];
}

pub fn reset(self: *UI) void {
    self.layout_ctx.reset();
    self.decorations.clearRetainingCapacity();
    self.hit_records.clearRetainingCapacity();
    self.hit_counter = 0;
    self.scroll_geoms.clearRetainingCapacity();
    self.anim_active = false;
}

/// Drive a time-based animation toward `target` for the given (element_id, channel)
/// pair. Returns the current eased value. On target change, snapshots the current
/// value as the new start_value so interrupted animations continue smoothly from
/// wherever they were rather than restarting.
///
/// Marks the UI dirty while in flight so the host app can keep ticking frames.
pub fn anim(self: *UI, element_id: Element.Id, channel: []const u8, target: f32, opts: animation.Options) f32 {
    const id = animation.channelId(element_id, channel);
    const s: *State.Anim = self.state.getOrCreate(.anim, self.allocator, id) catch return target;
    const now = self.input.now_ms;

    if (!s.initialized) {
        s.* = .{
            .current = target,
            .start_value = target,
            .target = target,
            .t0_ms = now,
            .duration_ms = opts.duration_ms,
            .ease = opts.ease,
            .initialized = true,
        };
        return target;
    }

    if (s.target != target) {
        s.current = sampleAnim(s, now).value;
        s.start_value = s.current;
        s.target = target;
        s.t0_ms = now;
        s.duration_ms = opts.duration_ms;
        s.ease = opts.ease;
    }

    if (s.duration_ms == 0) {
        s.current = target;
        return s.current;
    }

    const sample = sampleAnim(s, now);
    s.current = sample.value;
    if (sample.t < 1.0) self.anim_active = true;
    return s.current;
}

const AnimSample = struct {
    value: f32,
    t: f32,
};

fn sampleAnim(s: *const State.Anim, now_ms: i64) AnimSample {
    if (s.duration_ms == 0) return .{ .value = s.target, .t = 1.0 };
    const elapsed: i64 = now_ms - s.t0_ms;
    const raw_t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(s.duration_ms));
    const t = std.math.clamp(raw_t, 0.0, 1.0);
    return .{
        .value = math.lerp(s.start_value, s.target, s.ease.eval(t)),
        .t = t,
    };
}

pub fn resolve(self: *UI) !void {
    const scroll: layout.Context.ScrollLookup = .{
        .ctx = @ptrCast(&self.state),
        .getFn = @ptrCast(&State.getScroll),
    };

    self.layout_ctx.computeSizes();
    try self.layout_ctx.computeLayout(scroll, self.theme.scrollbar_thickness);

    // After a first layout pass, recompute intrinsic_h for every wrap-text element using its just-assigned box width.
    if (try self.reflowWrappedText()) {
        self.layout_ctx.computeSizes();
        try self.layout_ctx.computeLayout(scroll, self.theme.scrollbar_thickness);
    }

    try self.layout_ctx.buildZOrder();
    self.syncStateBounds();
}

/// Returns true if any height changed, in which case the caller should re-run layout so ancestors fit the new heights.
fn reflowWrappedText(self: *UI) !bool {
    var changed = false;
    for (self.decorations.items, 0..) |dec, slot| {
        if (dec != .text) continue;
        const t = dec.text;
        if (!t.wrap or t.content.len == 0) continue;

        const el = self.layout_ctx.pool.get(@intCast(slot));
        const wrap_px = el.box.w() * self.content_scale;
        if (wrap_px <= 0) continue;

        const face = try self.font.getFace(t.font);
        const shaped = try face.shapeWrapped(t.content, t.size * self.content_scale, wrap_px);
        const new_h = shaped.height / self.content_scale;
        if (new_h != el.intrinsic_h) {
            el.intrinsic_h = new_h;
            changed = true;
        }
    }
    return changed;
}

fn syncStateBounds(self: *UI) void {
    const root_box = self.layout_ctx.pool.get(self.layout_ctx.root_slot).box;
    for (self.layout_ctx.pool.elements.items) |el| {
        if (self.state.get(.text_select, el.id)) |s| s.box = el.box;
        if (self.state.get(.slider, el.id)) |s| s.bounds = el.box;
        if (self.state.get(.measured, el.id)) |s| {
            s.box = el.box;
            s.width = el.box.w();
            s.height = el.box.h();
        }
        if (self.state.get(.select_input, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (self.state.get(.color_picker, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
    }
}

pub fn hovering(self: *UI, id: Element.Id) bool {
    return self.state.hovered == id;
}

pub fn pressing(self: *UI, id: Element.Id) bool {
    return self.state.active == id;
}

pub fn clicked(self: *UI, id: Element.Id) bool {
    return self.input.mouse_pressed and self.state.active == id;
}

pub fn focused(self: *UI, id: Element.Id) bool {
    return self.state.focused == id;
}

pub fn selectionText(self: *UI) ?[]const u8 {
    if (self.state.selection_text.len == 0) return null;
    return self.state.selection_text;
}

pub fn isHoveredWithin(self: *UI, ancestor_id: Element.Id) bool {
    return self.isDescendantOrSelf(self.state.hovered, ancestor_id);
}

pub fn clickedWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (!self.input.mouse_released) return false;
    if (self.state.press_drag) return false;
    if (!self.isDescendantOrSelf(self.state.press_origin, ancestor_id)) return false;
    return self.isDescendantOrSelf(self.state.hovered, ancestor_id);
}

fn isDescendantOrSelf(self: *UI, descendant_id: Element.Id, ancestor_id: Element.Id) bool {
    if (descendant_id == Element.INVALID_ID) return false;
    if (descendant_id == ancestor_id) return true;
    const ancestor_slot = self.layout_ctx.slotForId(ancestor_id) orelse return false;
    const descendant_slot = self.layout_ctx.slotForId(descendant_id) orelse return false;
    return self.layout_ctx.isDescendantOf(descendant_slot, ancestor_slot);
}

pub fn resolveWindow(self: *UI, input: window.Input, now_ms: i64, content_scale: f32) !void {
    self.content_scale = content_scale;
    self.state.selection_text = &.{};
    self.input.collect(input, now_ms);

    if (self.layout_ctx.has_scroll) try scrollbar.route(self);

    if (self.input.mouse_pressed) {
        self.state.active = self.state.hovered;
        self.state.focused = self.state.hovered;
        self.state.press_origin = self.state.hovered;
        self.state.press_pos = self.input.mouse_pos;
        self.state.press_drag = false;

        self.state.forEach(.text_select, self.state.hovered, clearOtherTextSelect);
    }
    if (self.input.mouse_down and !self.state.press_drag) {
        const dx = self.input.mouse_pos[0] - self.state.press_pos[0];
        const dy = self.input.mouse_pos[1] - self.state.press_pos[1];
        if (dx * dx + dy * dy > press_drag_threshold_sq) self.state.press_drag = true;
    }
    if (self.input.mouse_released) self.state.active = Element.INVALID_ID;
}

/// Advance the per widget state TTL clock. Call once per frame after the
/// users frame callback has had a chance to touch its state, otherwise
/// entries lose a frame of TTL grace before the sweep sees them.
pub fn endFrame(self: *UI) !void {
    try self.state.endFrame();
}

const press_drag_threshold_sq: f64 = 9.0;

fn clearOtherTextSelect(hovered: Element.Id, id: Element.Id, s: *State.TextSelect) void {
    if (id == hovered) return;
    s.anchor_byte = 0;
    s.cursor_byte = 0;
    s.dragging = false;
}

pub fn appendHit(self: *UI, id: Element.Id, bounds: math.Rect, clip: ?math.Rect, layer: u8) !void {
    try self.hit_records.append(self.allocator, .{
        .id = id,
        .bounds = bounds,
        .clip = clip,
        .layer = layer,
        .insertion_order = self.hit_counter,
    });
    self.hit_counter += 1;
}

pub fn resolveHit(self: *UI) bool {
    const p: math.Vec2 = .{ @floatCast(self.input.mouse_pos[0]), @floatCast(self.input.mouse_pos[1]) };

    var best_id: Element.Id = Element.INVALID_ID;
    var best_layer: u8 = 0;
    var best_order: u32 = 0;

    for (self.hit_records.items) |rec| {
        if (!rec.bounds.contains(p)) continue;
        if (rec.clip) |c| if (!c.contains(p)) continue;

        if (best_id == Element.INVALID_ID or
            rec.layer > best_layer or
            (rec.layer == best_layer and rec.insertion_order > best_order))
        {
            best_id = rec.id;
            best_layer = rec.layer;
            best_order = rec.insertion_order;
        }
    }

    const changed = self.state.hovered != best_id;
    self.state.hovered = best_id;
    self.updateStats();
    return changed;
}

fn updateStats(self: *UI) void {
    self.last_stats = .{
        .elements = self.layout_ctx.pool.elements.items.len,
        .hit_records = self.hit_records.items.len,
        .scroll_containers = self.layout_ctx.scroll_slots.items.len,
        .decorations = self.decorations.items.len,
        .layers = self.layout_ctx.z_used.count(),
    };
}

pub fn tessellate(self: *UI, allocator: Allocator, draw_list: *DrawList) !void {
    defer self.font.endFrame();
    var it = self.layout_ctx.z_used.iterator(.{});
    while (it.next()) |z| {
        draw_list.setLayer(@intCast(z));
        try self.tessellateLayer(allocator, draw_list, self.layout_ctx.zSlots(@intCast(z)), @intCast(z));
    }
}

fn tessellateLayer(self: *UI, allocator: Allocator, draw_list: *DrawList, slots: []const Element.Slot, layer: u8) !void {
    const content_scale = self.content_scale;
    const elements = self.layout_ctx.pool.elements.items;

    var clip_rects: std.ArrayList(math.Rect) = .empty;
    var clip_owners: std.ArrayList(Element.Slot) = .empty;

    for (slots) |slot| {
        const el = &elements[slot];

        while (clip_owners.items.len > 0) {
            if (self.layout_ctx.isDescendantOf(slot, clip_owners.items[clip_owners.items.len - 1])) break;
            _ = clip_owners.pop();
            _ = clip_rects.pop();
        }

        const clip: ?math.Rect = if (clip_rects.items.len > 0) clip_rects.items[clip_rects.items.len - 1] else null;
        const clip_arr: ?[4]f32 = if (clip) |c| @as([4]f32, c.v) else null;
        const clipped_out = if (clip) |c| !c.overlaps(el.box) else false;

        if (clipped_out) {
            if (el.overflow != .visible) {
                const new_clip = clip.?.intersect(el.box);
                try clip_rects.append(allocator, new_clip);
                try clip_owners.append(allocator, slot);
            }
            continue;
        }

        if (el.overflow.isScroll()) try scrollbar.recordForTessellate(self, slot, clip, layer);

        if (el.interactive) try self.appendHit(el.id, el.box, clip, layer);

        switch (self.decorations.items[slot]) {
            .none => {},
            .rect => |r| {
                const inst = gpu.Instance{
                    .pos = .{ el.box.x(), el.box.y() },
                    .size = .{ el.box.w(), el.box.h() },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = r.color,
                    .border_color = r.border_color,
                    .corner_radius = r.corner_radius,
                    .border_width = r.border_width,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip_arr);
            },
            .text => |t| if (t.content.len > 0) {
                const face = try self.font.getFace(t.font);
                const wrap_px: f32 = if (t.wrap) @max(0, el.box.w() * content_scale) else 0;
                const shaped = try face.shapeWrapped(t.content, t.size * content_scale, wrap_px);
                if (shaped.lines.len > 0) {
                    const ascender = shaped.ascender / content_scale;
                    const size_logical = t.size;

                    const inv_size = 1.0 / size_logical;
                    const jac = [4]f32{ inv_size, 0, 0, -inv_size };

                    var total_glyphs: usize = 0;
                    for (shaped.lines) |ln| total_glyphs += ln.glyphs.len;
                    if (total_glyphs == 0) continue;

                    const batch = (try draw_list.beginTextBatch(total_glyphs, clip_arr)).?;

                    for (shaped.lines) |line| {
                        const baseline = el.box.y() + ascender + line.y / content_scale;
                        for (line.glyphs) |gl| {
                            const rec = gl.record;
                            if (rec.is_empty) continue;

                            const em_x: math.Vec4 = .{ rec.em_min[0], rec.em_max[0], rec.em_max[0], rec.em_min[0] };
                            const em_y: math.Vec4 = .{ rec.em_max[1], rec.em_max[1], rec.em_min[1], rec.em_min[1] };
                            const size_v: math.Vec4 = @splat(size_logical);
                            const origin_x_v: math.Vec4 = @splat(el.box.x() + gl.x / content_scale);
                            const baseline_v: math.Vec4 = @splat(baseline);

                            const sx_v = origin_x_v + em_x * size_v;
                            const sy_v = baseline_v - em_y * size_v;

                            if (clip) |c| {
                                const dilation_margin = 2.0 / content_scale;
                                const glyph_bounds = math.Rect.fromMinMax(
                                    .{ @reduce(.Min, sx_v), @reduce(.Min, sy_v) },
                                    .{ @reduce(.Max, sx_v), @reduce(.Max, sy_v) },
                                ).expand(dilation_margin);
                                if (!c.overlaps(glyph_bounds)) continue;
                            }

                            const tex_z_bits: u32 =
                                @as(u32, rec.glyph_loc_x) | (@as(u32, rec.glyph_loc_y) << 16);
                            const tex_w_bits: u32 =
                                @as(u32, rec.band_max_x) | (@as(u32, rec.band_max_y) << 16);
                            const tex_z: f32 = @bitCast(tex_z_bits);
                            const tex_w: f32 = @bitCast(tex_w_bits);

                            const bnd = [4]f32{
                                rec.band_scale[0],  rec.band_scale[1],
                                rec.band_offset[0], rec.band_offset[1],
                            };

                            var verts: [4]gpu.SlugVertex = undefined;
                            inline for (0..4) |ci| {
                                verts[ci] = .{
                                    .pos = .{
                                        sx_v[ci],
                                        sy_v[ci],
                                        TEXT_QUAD_NORMALS[ci][0],
                                        TEXT_QUAD_NORMALS[ci][1],
                                    },
                                    .tex = .{ em_x[ci], em_y[ci], tex_z, tex_w },
                                    .jac = jac,
                                    .bnd = bnd,
                                    .col = t.color,
                                };
                            }
                            try draw_list.pushTextQuad(batch, verts);
                        }
                    }
                }
            },
            .canvas => |c| try canvas_tessellator.tessellate(allocator, draw_list, c.cmds, .{ el.box.x(), el.box.y() }, clip_arr),
            .image => |img| {
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const inst = gpu.Instance{
                    .pos = .{ el.box.x(), el.box.y() },
                    .size = .{ el.box.w(), el.box.h() },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 1, 1 },
                    .color = img.tint,
                    .border_color = zero4,
                    .corner_radius = 0,
                    .border_width = 0,
                    .prim_type = 2.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, img.texture_id, clip_arr);
            },
            .slider => |s| {
                const bx = el.box.x();
                const by = el.box.y();
                const bw = el.box.w();
                const bh = el.box.h();
                const cr = s.corner_radius;
                const th = @min(s.track_height, bh);
                const ty = by + (bh - th) * 0.5;
                const zero4 = [4]f32{ 0, 0, 0, 0 };

                const track = gpu.Instance{
                    .pos = .{ bx, ty },
                    .size = .{ bw, th },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = s.track_color,
                    .border_color = zero4,
                    .corner_radius = cr,
                    .border_width = 0,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{track}, null, clip_arr);

                if (s.progress > 0) {
                    const fill = gpu.Instance{
                        .pos = .{ bx, ty },
                        .size = .{ bw * s.progress, th },
                        .uv0 = .{ 0, 0 },
                        .uv1 = .{ 0, 0 },
                        .color = s.fill_color,
                        .border_color = zero4,
                        .corner_radius = cr,
                        .border_width = 0,
                        .prim_type = 0.0,
                    };
                    try draw_list.pushInstances(&[_]gpu.Instance{fill}, null, clip_arr);
                }

                if (s.halo_radius > 0 and s.halo_color[3] > 0) {
                    const hr = s.halo_radius;
                    const hcx = bx + bw * s.progress;
                    const hcy = by + bh * 0.5;
                    const halo = gpu.Instance{
                        .pos = .{ hcx - hr, hcy - hr },
                        .size = .{ hr * 2, hr * 2 },
                        .uv0 = .{ 0, 0 },
                        .uv1 = .{ 0, 0 },
                        .color = s.halo_color,
                        .border_color = zero4,
                        .corner_radius = hr,
                        .border_width = 0,
                        .prim_type = 0.0,
                    };
                    try draw_list.pushInstances(&[_]gpu.Instance{halo}, null, clip_arr);
                }

                if (s.knob_radius > 0) {
                    const kr = s.knob_radius;
                    const kcx = bx + bw * s.progress;
                    const kcy = by + bh * 0.5;
                    const knob = gpu.Instance{
                        .pos = .{ kcx - kr, kcy - kr },
                        .size = .{ kr * 2, kr * 2 },
                        .uv0 = .{ 0, 0 },
                        .uv1 = .{ 0, 0 },
                        .color = s.knob_color,
                        .border_color = zero4,
                        .corner_radius = kr,
                        .border_width = 0,
                        .prim_type = 0.0,
                    };
                    try draw_list.pushInstances(&[_]gpu.Instance{knob}, null, clip_arr);
                }
            },
            .progress_bar => |p| {
                const bx = el.box.x();
                const by = el.box.y();
                const bw = el.box.w();
                const bh = el.box.h();
                const cr = p.corner_radius;
                const progress = std.math.clamp(p.progress, 0.0, 1.0);
                const zero4 = [4]f32{ 0, 0, 0, 0 };

                const track = gpu.Instance{
                    .pos = .{ bx, by },
                    .size = .{ bw, bh },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = p.track_color,
                    .border_color = zero4,
                    .corner_radius = cr,
                    .border_width = 0,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{track}, null, clip_arr);

                if (progress > 0) {
                    const fill = gpu.Instance{
                        .pos = .{ bx, by },
                        .size = .{ bw * progress, bh },
                        .uv0 = .{ 0, 0 },
                        .uv1 = .{ 0, 0 },
                        .color = p.fill_color,
                        .border_color = zero4,
                        .corner_radius = cr,
                        .border_width = 0,
                        .prim_type = 0.0,
                    };
                    try draw_list.pushInstances(&[_]gpu.Instance{fill}, null, clip_arr);
                }
            },
        }

        if (el.overflow != .visible) {
            const new_clip: math.Rect = if (clip_rects.items.len > 0)
                clip_rects.items[clip_rects.items.len - 1].intersect(el.box)
            else
                el.box;
            try clip_rects.append(allocator, new_clip);
            try clip_owners.append(allocator, slot);
        }
    }

    try scrollbar.render(self, draw_list, layer);
}

test "scroll routing uses previous frame elements" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    {
        _ = try ui.open(Key.str("root"), .{
            .width = .fixed(300),
            .height = .fixed(200),
            .direction = .column,
            .overflow = .scroll_y,
        }, .none);
        {
            _ = try ui.open(Key.str("child"), .{
                .width = .grow(),
                .height = .fixed(500),
            }, .none);
            ui.close();
        }
        ui.close();

        try ui.resolve();
    }

    try ui.resolveWindow(.{
        .pos = .{ 150, 100 },
        .mouse_down_now = false,
        .scroll_delta = .{ 0, 50 },
        .chars = &.{},
        .keys = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);
    ui.reset();

    {
        _ = try ui.open(Key.str("root"), .{
            .width = .fixed(300),
            .height = .fixed(200),
            .direction = .column,
            .overflow = .scroll_y,
        }, .none);
        {
            _ = try ui.open(Key.str("child"), .{
                .width = .grow(),
                .height = .fixed(500),
            }, .none);
            ui.close();
        }
        ui.close();

        try ui.resolve();
    }

    const child_id = Key.str("child").hash();
    var child_box: ?math.Rect = null;
    for (ui.layout_ctx.pool.elements.items) |el| {
        if (el.id == child_id) {
            child_box = el.box;
            break;
        }
    }

    const box = child_box.?;
    try std.testing.expectApproxEqAbs(box.y(), -50.0, 0.001);
}

test "anim returns target immediately on first touch" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 1000;
    const v = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });
    try std.testing.expectApproxEqAbs(v, 1.0, 1e-6);
    try std.testing.expect(!ui.anim_active);
}

test "anim snapshots start_value mid-interruption" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 100;
    const midway = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });
    try std.testing.expect(midway > 0.0 and midway < 1.0);
    try std.testing.expect(ui.anim_active);

    ui.input.now_ms = 100;
    const reversed_start = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expectApproxEqAbs(reversed_start, midway, 1e-6);

    ui.input.now_ms = 150;
    const reversing = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expect(reversing < midway);
    try std.testing.expect(reversing > 0.0);
}

test "anim retarget samples elapsed progress before interruption" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 100;
    const reversed_start = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expectApproxEqAbs(reversed_start, 0.5, 1e-6);

    ui.input.now_ms = 150;
    const reversing = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expect(reversing < reversed_start);
    try std.testing.expect(reversing > 0.0);
}

test "resolveHit reports hover changes" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    try ui.appendHit(42, math.Rect.init(0, 0, 100, 100), null, 0);

    ui.input.mouse_pos = .{ 10, 10 };
    try std.testing.expect(ui.resolveHit());
    try std.testing.expectEqual(@as(Element.Id, 42), ui.state.hovered);

    try std.testing.expect(!ui.resolveHit());

    ui.input.mouse_pos = .{ 200, 200 };
    try std.testing.expect(ui.resolveHit());
    try std.testing.expectEqual(Element.INVALID_ID, ui.state.hovered);
}

test "anim settles and clears dirty flag" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 0.0, .{ .duration_ms = 100 });
    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 1.0, .{ .duration_ms = 100 });

    ui.anim_active = false;
    ui.input.now_ms = 500;
    const done = ui.anim(1, "hover", 1.0, .{ .duration_ms = 100 });
    try std.testing.expectApproxEqAbs(done, 1.0, 1e-6);
    try std.testing.expect(!ui.anim_active);
}
