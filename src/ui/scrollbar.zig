const std = @import("std");
const math = @import("math");
const layout = @import("layout");
const gpu = @import("gpu");
const DrawList = @import("render").DrawList;

const Element = layout.Element;
const State = @import("State.zig");
const Theme = @import("Theme.zig");
const UI = @import("UI.zig");

const THUMB_ID_SALT: Element.Id = 0x5C205C205C205C20;

pub const Geom = struct {
    track: math.Rect,
    thumb: math.Rect,
    axis: State.Scroll.Axis,
};

pub const SlotGeom = struct {
    slot: Element.Slot,
    layer: u8 = 0,
    parent_clip: ?math.Rect = null,
    geom: Geom,
};

pub fn idFor(container_id: Element.Id) Element.Id {
    return container_id ^ THUMB_ID_SALT;
}

pub fn compute(el: *const Element, offset: math.Vec2) ?Geom {
    const thickness = Theme.definition.scrollbar_thickness;
    const min_thumb = Theme.definition.scrollbar_min_thumb;

    switch (el.overflow) {
        .scroll_y => {
            const box_h = el.box.h();
            const content_h = el.content_h;
            if (content_h <= box_h or box_h <= thickness) return null;
            const track_x = el.box.x() + el.box.w() - thickness;
            const track_y = el.box.y();
            const track_h = box_h;
            const ratio = std.math.clamp(box_h / content_h, 0, 1);
            const thumb_h = @max(min_thumb, track_h * ratio);
            const free = @max(0, track_h - thumb_h);
            const max_off = @max(0, content_h - box_h);
            const t = if (max_off > 0) std.math.clamp(offset[1] / max_off, 0, 1) else 0;
            const thumb_y = track_y + free * t;
            return .{
                .track = math.Rect.init(track_x, track_y, thickness, track_h),
                .thumb = math.Rect.init(track_x, thumb_y, thickness, thumb_h),
                .axis = .y,
            };
        },
        .scroll_x => {
            const box_w = el.box.w();
            const content_w = el.content_w;
            if (content_w <= box_w or box_w <= thickness) return null;
            const track_x = el.box.x();
            const track_y = el.box.y() + el.box.h() - thickness;
            const track_w = box_w;
            const ratio = std.math.clamp(box_w / content_w, 0, 1);
            const thumb_w = @max(min_thumb, track_w * ratio);
            const free = @max(0, track_w - thumb_w);
            const max_off = @max(0, content_w - box_w);
            const t = if (max_off > 0) std.math.clamp(offset[0] / max_off, 0, 1) else 0;
            const thumb_x = track_x + free * t;
            return .{
                .track = math.Rect.init(track_x, track_y, track_w, thickness),
                .thumb = math.Rect.init(thumb_x, track_y, thumb_w, thickness),
                .axis = .x,
            };
        },
        else => return null,
    }
}

pub fn route(ui: *UI) !void {
    const elements = ui.layout_ctx.pool.elements.items;
    const p: math.Vec2 = .{ @floatCast(ui.input.mouse_pos[0]), @floatCast(ui.input.mouse_pos[1]) };
    const has_wheel = ui.input.scroll_delta[0] != 0 or ui.input.scroll_delta[1] != 0;

    var wheel_target: ?struct { slot: Element.Slot } = null;
    var press_target: ?struct { slot: Element.Slot, geom: Geom } = null;

    for (ui.layout_ctx.scroll_slots.items) |slot| {
        const el = &elements[slot];
        const offset = ui.state.getScroll(el.id);
        const geom = compute(el, .{ offset[0], offset[1] }) orelse continue;

        if (has_wheel and el.box.contains(p)) wheel_target = .{ .slot = slot };

        if (ui.input.mouse_pressed and geom.thumb.contains(p)) press_target = .{ .slot = slot, .geom = geom };

        const s = ui.state.get(.scroll, el.id) orelse continue;
        if (s.drag_axis == .none) continue;

        if (!ui.input.mouse_down) {
            s.drag_axis = .none;
            continue;
        }
        if (geom.axis != s.drag_axis) {
            s.drag_axis = .none;
            continue;
        }

        switch (geom.axis) {
            .y => {
                const my: f32 = @floatCast(ui.input.mouse_pos[1]);
                const free = @max(0, geom.track.h() - geom.thumb.h());
                const max_off = @max(0, el.content_h - el.box.h());
                if (free <= 0 or max_off <= 0) continue;
                const t = std.math.clamp((my - s.drag_grab - geom.track.y()) / free, 0, 1);
                s.offset = .{ s.offset[0], t * max_off };
            },
            .x => {
                const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
                const free = @max(0, geom.track.w() - geom.thumb.w());
                const max_off = @max(0, el.content_w - el.box.w());
                if (free <= 0 or max_off <= 0) continue;
                const t = std.math.clamp((mx - s.drag_grab - geom.track.x()) / free, 0, 1);
                s.offset = .{ t * max_off, s.offset[1] };
            },
            .none => unreachable,
        }
    }

    if (wheel_target) |w| {
        const el = &elements[w.slot];
        const delta: math.Vec2 = switch (el.overflow) {
            .scroll_x => .{ ui.input.scroll_delta[0], 0 },
            .scroll_y => .{ 0, ui.input.scroll_delta[1] },
            else => unreachable,
        };
        try ui.state.addScroll(el.id, el, delta);
    }

    if (press_target) |pt| {
        const el = &elements[pt.slot];
        const s = try ui.state.getOrCreate(.scroll, ui.allocator, el.id);
        s.drag_axis = pt.geom.axis;
        s.drag_grab = switch (pt.geom.axis) {
            .y => @as(f32, @floatCast(ui.input.mouse_pos[1])) - pt.geom.thumb.y(),
            .x => @as(f32, @floatCast(ui.input.mouse_pos[0])) - pt.geom.thumb.x(),
            .none => 0,
        };
    }
}

pub fn recordForTessellate(ui: *UI, slot: Element.Slot, parent_clip: ?math.Rect, layer: u8) !void {
    const el = &ui.layout_ctx.pool.elements.items[slot];
    const offset = ui.state.getScroll(el.id);
    const geom = compute(el, .{ offset[0], offset[1] }) orelse return;
    try ui.scroll_geoms.append(ui.allocator, .{
        .slot = slot,
        .layer = layer,
        .parent_clip = parent_clip,
        .geom = geom,
    });
}

pub fn render(ui: *UI, draw_list: *DrawList, layer: u8) !void {
    const elements = ui.layout_ctx.pool.elements.items;
    const cr = Theme.definition.scrollbar_corner_radius;
    const base: math.Vec4 = Theme.definition.scrollbar_thumb_color.value;
    const hi: math.Vec4 = Theme.definition.scrollbar_thumb_hover_color.value;
    const track_color: [4]f32 = Theme.definition.scrollbar_track_color.value;

    for (ui.scroll_geoms.items) |sg| {
        if (sg.layer != layer) continue;
        const el = &elements[sg.slot];
        const clip_arr: ?[4]f32 = if (sg.parent_clip) |c| @as([4]f32, c.v) else null;

        const track_inst = gpu.Instance{
            .pos = .{ sg.geom.track.x(), sg.geom.track.y() },
            .size = .{ sg.geom.track.w(), sg.geom.track.h() },
            .uv0 = .{ 0, 0 },
            .uv1 = .{ 0, 0 },
            .color = track_color,
            .border_color = .{ 0, 0, 0, 0 },
            .corner_radius = cr,
            .border_width = 0,
            .prim_type = 0.0,
        };
        try draw_list.pushInstances(&[_]gpu.Instance{track_inst}, null, clip_arr);

        const sb_id = idFor(el.id);
        const dragging = if (ui.state.get(.scroll, el.id)) |s| s.drag_axis == sg.geom.axis else false;
        const hovered = ui.state.hovered == sb_id or dragging;
        const hover_t = ui.anim(sb_id, "sb_hover", if (hovered) 1.0 else 0.0, .{ .duration_ms = 100 });
        const thumb_color: [4]f32 = math.lerp(base, hi, hover_t);

        const thumb_inst = gpu.Instance{
            .pos = .{ sg.geom.thumb.x(), sg.geom.thumb.y() },
            .size = .{ sg.geom.thumb.w(), sg.geom.thumb.h() },
            .uv0 = .{ 0, 0 },
            .uv1 = .{ 0, 0 },
            .color = thumb_color,
            .border_color = .{ 0, 0, 0, 0 },
            .corner_radius = cr,
            .border_width = 0,
            .prim_type = 0.0,
        };
        try draw_list.pushInstances(&[_]gpu.Instance{thumb_inst}, null, clip_arr);

        try ui.appendHit(sb_id, sg.geom.thumb, sg.parent_clip, layer);
    }
}

const Key = @import("Key.zig");
const testing = std.testing;

test "scrollbar drag moves scroll offset proportionally" {
    const allocator = testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    const root_key = Key.str("root");

    const buildTree = struct {
        fn run(u: *UI) !void {
            _ = try u.open(.str("root"), .{
                .width = .fixed(300),
                .height = .fixed(200),
                .direction = .column,
                .overflow = .scroll_y,
            }, .none);
            {
                _ = try u.open(.str("child"), .{
                    .width = .grow(),
                    .height = .fixed(1000),
                }, .none);
                u.close();
            }
            u.close();
        }
    }.run;

    try buildTree(&ui);
    try ui.resolve();

    const root_id = root_key.hash();
    var root_el: ?*const Element = null;
    for (ui.layout_ctx.pool.elements.items) |*el| {
        if (el.id == root_id) {
            root_el = el;
            break;
        }
    }

    const geom = compute(root_el.?, .{ 0, 0 }).?;
    const thumb_top_y = geom.thumb.y();

    try ui.resolveWindow(.{
        .pos = .{ geom.thumb.x() + 1, thumb_top_y + 4 },
        .mouse_down_now = true,
        .scroll_delta = .{ 0, 0 },
        .chars = &.{},
        .keys = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);
    ui.reset();
    try buildTree(&ui);
    try ui.resolve();

    const s_after_press = ui.state.get(.scroll, root_id).?;
    try testing.expectEqual(State.Scroll.Axis.y, s_after_press.drag_axis);
    try testing.expectApproxEqAbs(4, s_after_press.drag_grab, 0.001);

    const drag_target_y = thumb_top_y + 30;
    try ui.resolveWindow(.{
        .pos = .{ geom.thumb.x() + 1, drag_target_y },
        .mouse_down_now = true,
        .scroll_delta = .{ 0, 0 },
        .chars = &.{},
        .keys = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);

    const free = geom.track.h() - geom.thumb.h();
    const max_off: f32 = 1000 - 200;
    const expected_t = (drag_target_y - 4 - geom.track.y()) / free;
    const expected_offset = expected_t * max_off;

    const s_after_drag = ui.state.get(.scroll, root_id).?;
    try testing.expectApproxEqAbs(expected_offset, s_after_drag.offset[1], 0.5);

    try ui.resolveWindow(.{
        .pos = .{ geom.thumb.x() + 1, drag_target_y },
        .mouse_down_now = false,
        .scroll_delta = .{ 0, 0 },
        .chars = &.{},
        .keys = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);

    const s_after_release = ui.state.get(.scroll, root_id).?;
    try testing.expectEqual(State.Scroll.Axis.none, s_after_release.drag_axis);
}

test "wheel scroll over container updates offset" {
    const allocator = testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    const root_key = Key.str("root");

    const buildTree = struct {
        fn run(u: *UI) !void {
            _ = try u.open(.str("root"), .{
                .width = .fixed(300),
                .height = .fixed(200),
                .direction = .column,
                .overflow = .scroll_y,
            }, .none);
            {
                _ = try u.open(.str("child"), .{
                    .width = .grow(),
                    .height = .fixed(1000),
                }, .none);
                u.close();
            }
            u.close();
        }
    }.run;

    try buildTree(&ui);
    try ui.resolve();

    try ui.resolveWindow(.{
        .pos = .{ 50, 50 },
        .mouse_down_now = false,
        .scroll_delta = .{ 0, 25 },
        .chars = &.{},
        .keys = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);

    const root_id = root_key.hash();
    const s = ui.state.get(.scroll, root_id).?;
    try testing.expectApproxEqAbs(25, s.offset[1], 0.001);
}
