const layout = @import("layout");
const text = @import("text");
const Window = @import("window").Window;
const Element = layout.Element;
const std = @import("std");
const gpu = @import("gpu");
const DrawList = @import("render").DrawList;

const State = @import("State.zig");
const Input = @import("Input.zig");

pub const Decoration = @import("Decoration.zig").Decoration;
pub const Key = @import("Key.zig");
pub const Style = @import("Style.zig");

const Allocator = std.mem.Allocator;

pub const HitRecord = struct {
    id: Element.Id,
    bounds: [4]f32,
    clip: ?[4]f32,
    layer: u8,
    insertion_order: u32,
};

pub fn queryId(key: Key) Element.Id {
    return key.hash();
}

pub const Config = struct {
    fonts: []const text.Font.FontKey = &.{.{ "default", @embedFile("fonts/default.ttf") }},
};

allocator: Allocator,
layout_ctx: layout.Context,
decorations: std.ArrayList(Decoration),
font: text.Font,
state: State,
input: Input,
hit_records: std.ArrayList(HitRecord),
hit_counter: u32,

const UI = @This();

pub fn init(allocator: Allocator, cfg: Config) !UI {
    return .{
        .allocator = allocator,
        .layout_ctx = .init(allocator),
        .decorations = .empty,
        .state = .init(allocator),
        .input = .{},
        .font = try .init(allocator, cfg.fonts),
        .hit_records = .empty,
        .hit_counter = 0,
    };
}

pub fn deinit(self: *UI) void {
    self.layout_ctx.deinit();
    self.decorations.deinit(self.allocator);
    self.font.deinit();
    self.state.deinit();
    self.hit_records.deinit(self.allocator);
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
    el.box.x = x;
    el.box.y = y;
    if (decoration == .text) {
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    return id;
}

pub fn textDecoration(self: *UI, content: []const u8, size: f32, font: ?[]const u8) !Decoration {
    const face = self.font.getFace(font);
    const measured = try face.measure(self.allocator, content, size);
    return .{ .text = .{
        .content = content,
        .size = size,
        .font = font,
        .intrinsic_w = measured.width,
        .intrinsic_h = measured.height,
    } };
}

pub fn setDecoration(self: *UI, slot: Element.Slot, decoration: Decoration) void {
    self.decorations.items[slot] = decoration;
}

pub fn currentSlot(self: *UI) Element.Slot {
    return self.layout_ctx.stack[self.layout_ctx.stack_top - 1];
}

pub fn reset(self: *UI) void {
    self.layout_ctx.reset();
    self.decorations.clearRetainingCapacity();
    self.hit_records.clearRetainingCapacity();
    self.hit_counter = 0;
}

pub fn resolve(self: *UI) !void {
    self.layout_ctx.computeSizes();
    self.layout_ctx.computeLayout(.{
        .ctx = @ptrCast(&self.state),
        .getFn = @ptrCast(&State.getScroll),
    });
    try self.layout_ctx.buildZOrder();
    self.syncSelectAnchors();
    self.syncSliderBounds();
}

fn syncSliderBounds(self: *UI) void {
    for (self.layout_ctx.pool.elements.items) |el| {
        if (self.state.get(.slider, el.id)) |s| {
            s.bounds = el.box;
        }
    }
}

fn syncSelectAnchors(self: *UI) void {
    const root_box = self.layout_ctx.pool.get(self.layout_ctx.root_slot).box;
    for (self.layout_ctx.pool.elements.items) |el| {
        if (el.z_index != 0) continue;
        if (self.state.get(.select_input, el.id)) |s| {
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

pub fn isHoveredWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (self.state.hovered == Element.INVALID_ID) return false;
    if (self.state.hovered == ancestor_id) return true;
    var ancestor_slot: ?Element.Slot = null;
    var hovered_slot: ?Element.Slot = null;
    for (self.layout_ctx.pool.elements.items, 0..) |el, i| {
        if (el.id == ancestor_id) ancestor_slot = @intCast(i);
        if (el.id == self.state.hovered) hovered_slot = @intCast(i);
        if (ancestor_slot != null and hovered_slot != null) break;
    }
    if (ancestor_slot == null or hovered_slot == null) return false;
    return self.layout_ctx.isDescendantOf(hovered_slot.?, ancestor_slot.?);
}

pub fn collectInput(self: *UI, input: Window.Input, now_ms: i64) !void {
    self.input.collect(input, now_ms);

    if (self.input.mouse_pressed) {
        self.state.active = self.state.hovered;
        self.state.focused = self.state.hovered;
    }
    if (self.input.mouse_released) self.state.active = Element.INVALID_ID;

    if (input.scroll_delta[0] != 0 or input.scroll_delta[1] != 0) {
        try self.routeScroll(self.layout_ctx.pool.elements.items, input);
    }

    self.state.endFrame();
}

pub fn resolveHit(self: *UI) void {
    const mx = self.input.mouse_pos[0];
    const my = self.input.mouse_pos[1];

    var best_id: Element.Id = Element.INVALID_ID;
    var best_layer: u8 = 0;
    var best_order: u32 = 0;

    for (self.hit_records.items) |rec| {
        const in_bounds = mx >= rec.bounds[0] and
            mx < rec.bounds[0] + rec.bounds[2] and
            my >= rec.bounds[1] and
            my < rec.bounds[1] + rec.bounds[3];
        if (!in_bounds) continue;

        if (rec.clip) |c| {
            const in_clip = mx >= c[0] and mx < c[0] + c[2] and
                my >= c[1] and my < c[1] + c[3];
            if (!in_clip) continue;
        }

        if (best_id == Element.INVALID_ID or
            rec.layer > best_layer or
            (rec.layer == best_layer and rec.insertion_order > best_order))
        {
            best_id = rec.id;
            best_layer = rec.layer;
            best_order = rec.insertion_order;
        }
    }

    self.state.hovered = best_id;
}

fn routeScroll(self: *UI, elements: []Element, input: Window.Input) !void {
    var j: Element.Slot = @intCast(elements.len);
    while (j > 0) {
        j -= 1;
        const el = self.layout_ctx.pool.get(j);
        if (!el.overflow.isScroll()) continue;
        const hit = self.input.mouse_pos[0] >= el.box.x and
            self.input.mouse_pos[0] < el.box.x + el.box.w and
            self.input.mouse_pos[1] >= el.box.y and
            self.input.mouse_pos[1] < el.box.y + el.box.h;
        if (hit) {
            const delta: [2]f32 = switch (el.overflow) {
                .scroll_x => .{ input.scroll_delta[0], 0 },
                .scroll_y => .{ 0, input.scroll_delta[1] },
                else => unreachable,
            };
            try self.state.addScroll(el.id, el, delta);
            return;
        }
    }
}

pub fn tessellate(self: *UI, allocator: Allocator, draw_list: *DrawList) !void {
    var it = self.layout_ctx.z_used.iterator(.{});
    while (it.next()) |z| {
        draw_list.setLayer(@intCast(z));
        try self.tessellateLayer(allocator, draw_list, self.layout_ctx.zSlots(@intCast(z)), @intCast(z));
    }
    try draw_list.finalize();
    self.font.atlas.flush();
}

fn tessellateLayer(self: *UI, allocator: Allocator, draw_list: *DrawList, slots: []const Element.Slot, layer: u8) !void {
    const elements = self.layout_ctx.pool.elements.items;

    var clip_rects: [64][4]f32 = undefined;
    var clip_owners: [64]Element.Slot = undefined;
    var clip_top: u8 = 0;

    for (slots) |slot| {
        const el = &elements[slot];

        // Pop clips whose owner is not an ancestor of the current element.
        while (clip_top > 0) {
            if (self.layout_ctx.isDescendantOf(slot, clip_owners[clip_top - 1])) break;
            clip_top -= 1;
        }

        const clip: ?[4]f32 = if (clip_top > 0) clip_rects[clip_top - 1] else null;

        if (el.interactive) {
            try self.hit_records.append(self.allocator, .{
                .id = el.id,
                .bounds = .{ el.box.x, el.box.y, el.box.w, el.box.h },
                .clip = clip,
                .layer = layer,
                .insertion_order = self.hit_counter,
            });
            self.hit_counter += 1;
        }

        switch (self.decorations.items[slot]) {
            .none => {},
            .rect => |r| {
                if (clip) |c|
                    if (el.box.x >= c[0] + c[2] or
                        el.box.x + el.box.w <= c[0] or
                        el.box.y >= c[1] + c[3] or
                        el.box.y + el.box.h <= c[1])
                    {
                        if (el.overflow != .visible) {
                            clip_rects[clip_top] = if (clip_top > 0)
                                layout.Context.intersectClip(clip_rects[clip_top - 1], .{ el.box.x, el.box.y, el.box.w, el.box.h })
                            else
                                .{ el.box.x, el.box.y, el.box.w, el.box.h };
                            clip_owners[clip_top] = slot;
                            clip_top += 1;
                        }
                        continue;
                    };

                const hw = el.box.w / 2.0;
                const hh = el.box.h / 2.0;
                const cx = el.box.x + hw;
                const cy = el.box.y + hh;

                const vertices = [4]gpu.Vertex{
                    .{ .pos = .{ cx - hw, cy - hh }, .uv = .{ -hw, -hh }, .color = r.color, .corner_radius = r.corner_radius, .half_size = .{ hw, hh }, .border_width = r.border_width, .border_color = r.border_color, .prim_type = 0.0 },
                    .{ .pos = .{ cx + hw, cy - hh }, .uv = .{ hw, -hh }, .color = r.color, .corner_radius = r.corner_radius, .half_size = .{ hw, hh }, .border_width = r.border_width, .border_color = r.border_color, .prim_type = 0.0 },
                    .{ .pos = .{ cx + hw, cy + hh }, .uv = .{ hw, hh }, .color = r.color, .corner_radius = r.corner_radius, .half_size = .{ hw, hh }, .border_width = r.border_width, .border_color = r.border_color, .prim_type = 0.0 },
                    .{ .pos = .{ cx - hw, cy + hh }, .uv = .{ -hw, hh }, .color = r.color, .corner_radius = r.corner_radius, .half_size = .{ hw, hh }, .border_width = r.border_width, .border_color = r.border_color, .prim_type = 0.0 },
                };
                try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
            },
            .text => |t| {
                const face = self.font.getFace(t.font);
                const shaped = try face.shape(allocator, t.content, t.size);
                const glyphs = shaped.glyphs;
                defer allocator.free(glyphs);
                const ascender = @as(f32, @floatFromInt(face.ft_face.*.size.*.metrics.ascender)) / 64.0;
                const baseline = el.box.y + ascender;
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const zero2 = [2]f32{ 0, 0 };

                for (glyphs) |gl| {
                    if (gl.metrics.rect.width == 0) continue;

                    const gx = el.box.x + gl.x;
                    const gy = baseline - gl.metrics.bearing_y;
                    const gw = gl.metrics.rect.width;
                    const gh = gl.metrics.rect.height;

                    if (clip) |c| {
                        if (gx >= c[0] + c[2] or
                            gx + gw <= c[0] or
                            gy >= c[1] + c[3] or
                            gy + gh <= c[1]) continue;
                    }

                    const u = gl.metrics.rect.u;
                    const v = gl.metrics.rect.v;
                    const uw = gl.metrics.rect.uw;
                    const uh = gl.metrics.rect.uh;

                    const vertices = [4]gpu.Vertex{
                        .{ .pos = .{ gx, gy }, .uv = .{ u, v }, .color = t.color, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 1.0 },
                        .{ .pos = .{ gx + gw, gy }, .uv = .{ u + uw, v }, .color = t.color, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 1.0 },
                        .{ .pos = .{ gx + gw, gy + gh }, .uv = .{ u + uw, v + uh }, .color = t.color, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 1.0 },
                        .{ .pos = .{ gx, gy + gh }, .uv = .{ u, v + uh }, .color = t.color, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 1.0 },
                    };
                    try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                }
            },
            .canvas => |c| {
                const ox = el.box.x;
                const oy = el.box.y;
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const flat_hs = [2]f32{ 1e4, 1e4 };

                for (c.cmds) |cmd| {
                    switch (cmd) {
                        .fill_rect => |fr| {
                            const hw = fr.w / 2.0;
                            const hh = fr.h / 2.0;
                            const fcx = ox + fr.x + hw;
                            const fcy = oy + fr.y + hh;
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ fcx - hw, fcy - hh }, .uv = .{ -hw, -hh }, .color = fr.color, .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx + hw, fcy - hh }, .uv = .{ hw, -hh }, .color = fr.color, .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx + hw, fcy + hh }, .uv = .{ hw, hh }, .color = fr.color, .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx - hw, fcy + hh }, .uv = .{ -hw, hh }, .color = fr.color, .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .fill_rect_gradient => |fr| {
                            const hw = fr.w / 2.0;
                            const hh = fr.h / 2.0;
                            const fcx = ox + fr.x + hw;
                            const fcy = oy + fr.y + hh;
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ fcx - hw, fcy - hh }, .uv = .{ -hw, -hh }, .color = fr.colors[0], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx + hw, fcy - hh }, .uv = .{ hw, -hh }, .color = fr.colors[1], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx + hw, fcy + hh }, .uv = .{ hw, hh }, .color = fr.colors[2], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx - hw, fcy + hh }, .uv = .{ -hw, hh }, .color = fr.colors[3], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .stroke_rect => |sr| {
                            const hw = sr.w / 2.0;
                            const hh = sr.h / 2.0;
                            const scx = ox + sr.x + hw;
                            const scy = oy + sr.y + hh;
                            const transparent = [4]f32{ 0, 0, 0, 0 };
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ scx - hw, scy - hh }, .uv = .{ -hw, -hh }, .color = transparent, .corner_radius = sr.corner_radius, .half_size = .{ hw, hh }, .border_width = sr.thickness, .border_color = sr.color, .prim_type = 0.0 },
                                .{ .pos = .{ scx + hw, scy - hh }, .uv = .{ hw, -hh }, .color = transparent, .corner_radius = sr.corner_radius, .half_size = .{ hw, hh }, .border_width = sr.thickness, .border_color = sr.color, .prim_type = 0.0 },
                                .{ .pos = .{ scx + hw, scy + hh }, .uv = .{ hw, hh }, .color = transparent, .corner_radius = sr.corner_radius, .half_size = .{ hw, hh }, .border_width = sr.thickness, .border_color = sr.color, .prim_type = 0.0 },
                                .{ .pos = .{ scx - hw, scy + hh }, .uv = .{ -hw, hh }, .color = transparent, .corner_radius = sr.corner_radius, .half_size = .{ hw, hh }, .border_width = sr.thickness, .border_color = sr.color, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .fill_circle => |fc| {
                            const cr = fc.radius;
                            const ccx = ox + fc.cx;
                            const ccy = oy + fc.cy;
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ ccx - cr, ccy - cr }, .uv = .{ -cr, -cr }, .color = fc.color, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ ccx + cr, ccy - cr }, .uv = .{ cr, -cr }, .color = fc.color, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ ccx + cr, ccy + cr }, .uv = .{ cr, cr }, .color = fc.color, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ ccx - cr, ccy + cr }, .uv = .{ -cr, cr }, .color = fc.color, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .stroke_circle => |sc| {
                            const cr = sc.radius;
                            const ccx = ox + sc.cx;
                            const ccy = oy + sc.cy;
                            const transparent = [4]f32{ 0, 0, 0, 0 };
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ ccx - cr, ccy - cr }, .uv = .{ -cr, -cr }, .color = transparent, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = sc.thickness, .border_color = sc.color, .prim_type = 0.0 },
                                .{ .pos = .{ ccx + cr, ccy - cr }, .uv = .{ cr, -cr }, .color = transparent, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = sc.thickness, .border_color = sc.color, .prim_type = 0.0 },
                                .{ .pos = .{ ccx + cr, ccy + cr }, .uv = .{ cr, cr }, .color = transparent, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = sc.thickness, .border_color = sc.color, .prim_type = 0.0 },
                                .{ .pos = .{ ccx - cr, ccy + cr }, .uv = .{ -cr, cr }, .color = transparent, .corner_radius = cr, .half_size = .{ cr, cr }, .border_width = sc.thickness, .border_color = sc.color, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .line => |l| {
                            const dx = l.to[0] - l.from[0];
                            const dy = l.to[1] - l.from[1];
                            const len = @sqrt(dx * dx + dy * dy);
                            if (len < 1e-6) continue;
                            const nx = -dy / len * l.thickness * 0.5;
                            const ny = dx / len * l.thickness * 0.5;
                            const x0 = ox + l.from[0];
                            const y0 = oy + l.from[1];
                            const x1 = ox + l.to[0];
                            const y1 = oy + l.to[1];
                            const zero2 = [2]f32{ 0, 0 };
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ x0 + nx, y0 + ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ x1 + nx, y1 + ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ x1 - nx, y1 - ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ x0 - nx, y0 - ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .fill_triangle => |t| {
                            const zero2 = [2]f32{ 0, 0 };
                            const vertices = [3]gpu.Vertex{
                                .{ .pos = .{ ox + t.points[0][0], oy + t.points[0][1] }, .uv = zero2, .color = t.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ ox + t.points[1][0], oy + t.points[1][1] }, .uv = zero2, .color = t.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ ox + t.points[2][0], oy + t.points[2][1] }, .uv = zero2, .color = t.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2 }, null, clip);
                        },
                        .fill_convex_polygon => |p| {
                            if (p.points.len < 3) continue;
                            const zero2 = [2]f32{ 0, 0 };
                            const verts = try allocator.alloc(gpu.Vertex, p.points.len);
                            defer allocator.free(verts);
                            for (p.points, 0..) |pt, vi| {
                                verts[vi] = .{ .pos = .{ ox + pt[0], oy + pt[1] }, .uv = zero2, .color = p.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 };
                            }
                            const n_tris = p.points.len - 2;
                            const fan_indices = try allocator.alloc(u32, n_tris * 3);
                            defer allocator.free(fan_indices);
                            for (0..n_tris) |i| {
                                fan_indices[i * 3] = 0;
                                fan_indices[i * 3 + 1] = @as(u32, @intCast(i)) + 1;
                                fan_indices[i * 3 + 2] = @as(u32, @intCast(i)) + 2;
                            }
                            try draw_list.push(verts, fan_indices, null, clip);
                        },
                    }
                }
            },
            .image => |img| {
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const zero2 = [2]f32{ 0, 0 };
                const vertices = [4]gpu.Vertex{
                    .{ .pos = .{ el.box.x, el.box.y }, .uv = .{ 0, 0 }, .color = img.tint, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 2.0 },
                    .{ .pos = .{ el.box.x + el.box.w, el.box.y }, .uv = .{ 1, 0 }, .color = img.tint, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 2.0 },
                    .{ .pos = .{ el.box.x + el.box.w, el.box.y + el.box.h }, .uv = .{ 1, 1 }, .color = img.tint, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 2.0 },
                    .{ .pos = .{ el.box.x, el.box.y + el.box.h }, .uv = .{ 0, 1 }, .color = img.tint, .corner_radius = 0, .half_size = zero2, .border_width = 0, .border_color = zero4, .prim_type = 2.0 },
                };
                try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, img.texture_id, clip);
            },
            .slider => |s| {
                const bx = el.box.x;
                const by = el.box.y;
                const bw = el.box.w;
                const bh = el.box.h;
                const cr = s.corner_radius;
                const zero4 = [4]f32{ 0, 0, 0, 0 };

                // Track background
                {
                    const hw = bw / 2.0;
                    const hh = bh / 2.0;
                    const cx = bx + hw;
                    const cy = by + hh;
                    const vtx = [4]gpu.Vertex{
                        .{ .pos = .{ cx - hw, cy - hh }, .uv = .{ -hw, -hh }, .color = s.track_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                        .{ .pos = .{ cx + hw, cy - hh }, .uv = .{ hw, -hh }, .color = s.track_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                        .{ .pos = .{ cx + hw, cy + hh }, .uv = .{ hw, hh }, .color = s.track_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                        .{ .pos = .{ cx - hw, cy + hh }, .uv = .{ -hw, hh }, .color = s.track_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                    };
                    try draw_list.push(&vtx, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                }

                // Fill
                if (s.progress > 0) {
                    const fw = bw * s.progress;
                    const hw = fw / 2.0;
                    const hh = bh / 2.0;
                    const cx = bx + hw;
                    const cy = by + hh;
                    const vtx = [4]gpu.Vertex{
                        .{ .pos = .{ cx - hw, cy - hh }, .uv = .{ -hw, -hh }, .color = s.fill_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                        .{ .pos = .{ cx + hw, cy - hh }, .uv = .{ hw, -hh }, .color = s.fill_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                        .{ .pos = .{ cx + hw, cy + hh }, .uv = .{ hw, hh }, .color = s.fill_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                        .{ .pos = .{ cx - hw, cy + hh }, .uv = .{ -hw, hh }, .color = s.fill_color, .corner_radius = cr, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                    };
                    try draw_list.push(&vtx, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                }
            },
        }

        if (el.overflow != .visible) {
            const new_clip = [4]f32{ el.box.x, el.box.y, el.box.w, el.box.h };
            clip_rects[clip_top] = if (clip_top > 0)
                layout.Context.intersectClip(clip_rects[clip_top - 1], new_clip)
            else
                new_clip;
            clip_owners[clip_top] = slot;
            clip_top += 1;
        }
    }
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

    try ui.collectInput(.{
        .pos = .{ 150, 100 },
        .mouse_down_now = false,
        .scroll_delta = .{ 0, 50 },
        .chars = &.{},
        .keys = &.{},
        .shift_held = false,
        .ctrl_held = false,
    }, 0);
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
    var child_box: ?Element.Rect = null;
    for (ui.layout_ctx.pool.elements.items) |el| {
        if (el.id == child_id) {
            child_box = el.box;
            break;
        }
    }

    const box = child_box.?;
    try std.testing.expectApproxEqAbs(box.y, -50.0, 0.001);
}
