const std = @import("std");
const builtin = @import("builtin");
const Element = @import("Element.zig");
const ElementPool = @import("ElementPool.zig");
const Grid = @import("Grid.zig");

// Element.Id is a well-distributed Wyhash output (see Key.hash), so
// identity-hashing is correct here.
const IdContext = struct {
    pub inline fn hash(_: IdContext, id: Element.Id) u64 {
        return id;
    }
    pub inline fn eql(_: IdContext, a: Element.Id, b: Element.Id) bool {
        return a == b;
    }
};

const IdToSlotMap = std.HashMapUnmanaged(
    Element.Id,
    Element.Slot,
    IdContext,
    std.hash_map.default_max_load_percentage,
);

inline fn clearList(list: anytype) void {
    if (comptime std.debug.runtime_safety) {
        list.clearRetainingCapacity();
    } else {
        list.items.len = 0;
    }
}

inline fn fclamp(val: f32, lower: f32, upper: f32) f32 {
    return @max(lower, @min(val, upper));
}

allocator: std.mem.Allocator,
pool: ElementPool,
stack: std.ArrayList(Element.Slot) = .empty,
root_slot: Element.Slot = Element.INVALID_SLOT,
z_used: std.StaticBitSet(256),
z_slots: std.ArrayList(Element.Slot) = .empty,
z_offsets: [257]u32 = @splat(0),
id_to_slot: IdToSlotMap = .empty,
id_to_slot_populated: u32 = 0,
has_extra_roots: bool = false,
has_scroll: bool = false,
scroll_slots: std.ArrayList(Element.Slot) = .empty,

// Sparse side-tables, grid templates live on parent slots, placements on child slots.
grid_templates: std.AutoHashMapUnmanaged(Element.Slot, Grid.Template) = .empty,
grid_placements: std.AutoHashMapUnmanaged(Element.Slot, Grid.Placement) = .empty,

const Context = @This();

pub const LayoutError = std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) Context {
    return .{
        .allocator = allocator,
        .pool = .{},
        .z_used = .empty,
    };
}

pub fn deinit(self: *Context) void {
    self.stack.deinit(self.allocator);
    self.z_slots.deinit(self.allocator);
    self.id_to_slot.deinit(self.allocator);
    self.grid_templates.deinit(self.allocator);
    self.grid_placements.deinit(self.allocator);
    self.scroll_slots.deinit(self.allocator);
    self.pool.deinit(self.allocator);
}

pub fn reset(self: *Context) void {
    self.pool.reset();
    clearList(&self.stack);
    clearList(&self.z_slots);
    if (self.id_to_slot_populated > 0 or self.id_to_slot.size > 0) {
        self.id_to_slot.clearRetainingCapacity();
        self.id_to_slot_populated = 0;
    }
    self.has_extra_roots = false;
    if (self.grid_templates.size > 0) self.grid_templates.clearRetainingCapacity();
    if (self.grid_placements.size > 0) self.grid_placements.clearRetainingCapacity();
    self.root_slot = Element.INVALID_SLOT;
    self.z_used = .empty;
    self.has_scroll = false;
    clearList(&self.scroll_slots);
}

pub fn open(self: *Context, id: Element.Id, config: Element.Config) !Element.Slot {
    if (comptime builtin.mode == .debug) {
        if (id != Element.INVALID_ID) {
            std.debug.assert(!self.id_to_slot.contains(id));
            try self.id_to_slot.ensureUnusedCapacity(self.allocator, 1);
        }
    } else {
        const needed_slots: u32 = @intCast(self.pool.elements.items.len + 1);
        if (self.id_to_slot.size + self.id_to_slot.available < needed_slots) {
            try self.id_to_slot.ensureTotalCapacity(
                self.allocator,
                @max(needed_slots, @as(u32, @intCast(self.pool.elements.capacity))),
            );
        }
    }

    const parent_slot: Element.Slot = if (self.stack.items.len > 0)
        self.stack.items[self.stack.items.len - 1]
    else
        Element.INVALID_SLOT;

    const slot = try self.pool.appendConfig(self.allocator, id, parent_slot, &config);
    if (comptime builtin.mode == .debug) {
        if (id != Element.INVALID_ID) {
            self.id_to_slot.putAssumeCapacity(id, slot);
        }
        self.id_to_slot_populated = @intCast(self.pool.elements.items.len);
    }
    if (config.grid_template != null) try self.grid_templates.put(self.allocator, slot, config.grid_template.?);
    if (config.grid_placement != null) try self.grid_placements.put(self.allocator, slot, config.grid_placement.?);

    const elements = self.pool.elements.items;
    const slot_el = blk: {
        if (parent_slot != Element.INVALID_SLOT) {
            const parent = &elements[parent_slot];

            if (parent.first_child == Element.INVALID_SLOT)
                parent.first_child = slot
            else
                elements[parent.last_child].next_sibling = slot;

            parent.last_child = slot;

            const child = &elements[slot];
            if (parent.z_index > child.z_index) child.z_index = parent.z_index;
            self.z_used.set(child.z_index);
            if (config.position == .absolute)
                parent.has_absolute_child = true
            else
                parent.child_count += 1;
            break :blk child;
        } else {
            if (self.root_slot != Element.INVALID_SLOT) self.has_extra_roots = true;
            self.root_slot = slot;
            const root = &elements[slot];
            self.z_used.set(root.z_index);
            break :blk root;
        }
    };

    if (slot_el.overflow.isScroll()) {
        self.has_scroll = true;
        try self.scroll_slots.append(self.allocator, slot);
    }

    if (self.stack.items.len < self.stack.capacity) {
        self.stack.appendAssumeCapacity(slot);
    } else {
        try self.stack.append(self.allocator, slot);
    }
    return slot;
}

pub fn openRoot(self: *Context, id: Element.Id, config: Element.Config) !Element.Slot {
    if (comptime builtin.mode == .debug) {
        if (id != Element.INVALID_ID) {
            std.debug.assert(!self.id_to_slot.contains(id));
            try self.id_to_slot.ensureUnusedCapacity(self.allocator, 1);
        }
    } else {
        const needed_slots: u32 = @intCast(self.pool.elements.items.len + 1);
        if (self.id_to_slot.size + self.id_to_slot.available < needed_slots) {
            try self.id_to_slot.ensureTotalCapacity(
                self.allocator,
                @max(needed_slots, @as(u32, @intCast(self.pool.elements.capacity))),
            );
        }
    }

    const slot = try self.pool.appendConfig(self.allocator, id, Element.INVALID_SLOT, &config);
    if (comptime builtin.mode == .debug) {
        if (id != Element.INVALID_ID) {
            self.id_to_slot.putAssumeCapacity(id, slot);
        }
        self.id_to_slot_populated = @intCast(self.pool.elements.items.len);
    }
    self.has_extra_roots = true;
    if (config.grid_template != null) try self.grid_templates.put(self.allocator, slot, config.grid_template.?);
    if (config.grid_placement != null) try self.grid_placements.put(self.allocator, slot, config.grid_placement.?);
    const el = self.pool.get(slot);
    self.z_used.set(el.z_index);
    if (el.overflow.isScroll()) {
        self.has_scroll = true;
        try self.scroll_slots.append(self.allocator, slot);
    }
    if (self.stack.items.len < self.stack.capacity) {
        self.stack.appendAssumeCapacity(slot);
    } else {
        try self.stack.append(self.allocator, slot);
    }
    return slot;
}

pub fn close(self: *Context) void {
    if (comptime std.debug.runtime_safety) std.debug.assert(self.stack.items.len > 0);
    const next_len = self.stack.items.len - 1;
    const slot = self.stack.items[next_len];
    self.stack.items.len = next_len;
    self.pool.elements.items[slot].subtree_end = @intCast(self.pool.elements.items.len);
}

pub fn slotForId(self: *const Context, id: Element.Id) ?Element.Slot {
    if (id == Element.INVALID_ID) return null;
    const elements = self.pool.elements.items;
    if (self.id_to_slot_populated < elements.len) {
        const mutable_self = @constCast(self);
        for (elements[self.id_to_slot_populated..], self.id_to_slot_populated..) |*el, idx| {
            if (el.id != Element.INVALID_ID) {
                mutable_self.id_to_slot.putAssumeCapacity(el.id, @intCast(idx));
            }
        }
        mutable_self.id_to_slot_populated = @intCast(elements.len);
    }
    return self.id_to_slot.get(id);
}

pub fn buildZOrder(self: *Context) !void {
    const elements = self.pool.elements.items;
    const n: u32 = @intCast(elements.len);
    try self.z_slots.resize(self.allocator, n);

    if (self.z_used.count() <= 1) {
        const active_idx: usize = if (self.z_used.findFirstSet()) |bit| bit else 128;
        @memset(self.z_offsets[0 .. active_idx + 1], 0);
        @memset(self.z_offsets[active_idx + 1 .. 257], n);
        for (self.z_slots.items[0..n], 0..) |*slot, i| {
            slot.* = @intCast(i);
        }
        return;
    }

    var counts: [256]u32 = @splat(0);
    for (elements) |*el| counts[el.z_index] += 1;

    self.z_offsets[0] = 0;
    for (0..256) |z| self.z_offsets[z + 1] = self.z_offsets[z] + counts[z];

    var write: [256]u32 = @splat(0);
    for (elements, 0..) |*el, idx| {
        const z = el.z_index;
        self.z_slots.items[self.z_offsets[z] + write[z]] = @intCast(idx);
        write[z] += 1;
    }
}

pub inline fn zSlots(self: *const Context, z: u8) []const Element.Slot {
    return self.z_slots.items[self.z_offsets[z]..self.z_offsets[@as(u9, z) + 1]];
}

/// Returns true iff `slot` is in the subtree rooted at `ancestor`.
/// Uses the pre-order (= insertion order) and `subtree_end` set in `close()`:
/// `slot` is a strict descendant iff `ancestor < slot < subtree_end(ancestor)`.
pub fn isDescendantOf(self: *const Context, slot: Element.Slot, ancestor: Element.Slot) bool {
    if (slot == Element.INVALID_SLOT or ancestor == Element.INVALID_SLOT) return false;
    if (slot <= ancestor) return false;
    return slot < self.pool.elements.items[ancestor].subtree_end;
}

pub fn computeSizes(self: *Context) void {
    const elements = self.pool.elements.items;
    var i: Element.Slot = @intCast(elements.len);
    while (i > 0) {
        i -= 1;
        const el = &elements[i];

        {
            const initial: f32 = switch (el.width.kind) {
                .fixed => el.width.value,
                .percent => 0,
                .grow => 0,
                .fit => if (el.first_child == Element.INVALID_SLOT and el.direction != .grid)
                    @max(0, el.intrinsic_w) + el.padding.value[3] + el.padding.value[1]
                else
                    fitWidth(self, i, el),
            };
            el.box.v[2] = fclamp(initial, el.width.min, el.width.max);
        }

        {
            const initial: f32 = switch (el.height.kind) {
                .fixed => el.height.value,
                .percent => 0,
                .grow => 0,
                .fit => if (el.first_child == Element.INVALID_SLOT and el.direction != .grid)
                    @max(0, el.intrinsic_h) + el.padding.value[0] + el.padding.value[2]
                else
                    fitHeight(self, i, el),
            };
            el.box.v[3] = fclamp(initial, el.height.min, el.height.max);
        }
    }
}

inline fn fitWidth(self: *Context, slot: Element.Slot, el: *Element) f32 {
    const pad_w = el.padding.value[3] + el.padding.value[1];
    if (el.intrinsic_w > 0)
        return el.intrinsic_w + pad_w;

    if (el.direction == .grid) {
        const tpl = self.grid_templates.get(slot) orelse return pad_w;
        if (tpl.cols.len == 0) return pad_w;
        var sum: f32 = 0;
        for (tpl.cols) |t| switch (t) {
            .fixed => |v| sum += v,
            .fr => {},
        };
        if (tpl.cols.len > 1)
            sum += el.gap * @as(f32, @floatFromInt(tpl.cols.len - 1));
        return sum + pad_w;
    }

    const elements = self.pool.elements.items;
    var total = pad_w;
    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = &elements[child_slot];
        if (child.position != .absolute) {
            const cw = child.box.v[2];
            switch (el.direction) {
                .row => total += cw,
                .column, .layer => total = @max(total, cw + pad_w),
                .grid => unreachable,
            }
        }
        child_slot = child.next_sibling;
    }
    if (el.direction == .row and el.child_count > 1)
        total += el.gap * @as(f32, @floatFromInt(el.child_count - 1));
    return total;
}

inline fn fitHeight(self: *Context, slot: Element.Slot, el: *Element) f32 {
    const pad_h = el.padding.value[0] + el.padding.value[2];
    if (el.intrinsic_h > 0)
        return el.intrinsic_h + pad_h;

    if (el.direction == .grid) {
        const tpl = self.grid_templates.get(slot) orelse return pad_h;
        if (tpl.rows.len == 0) return pad_h;
        var sum: f32 = 0;
        for (tpl.rows) |t| switch (t) {
            .fixed => |v| sum += v,
            .fr => {},
        };
        if (tpl.rows.len > 1)
            sum += el.gap * @as(f32, @floatFromInt(tpl.rows.len - 1));
        return sum + pad_h;
    }

    const elements = self.pool.elements.items;
    var total = pad_h;
    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = &elements[child_slot];
        if (child.position != .absolute) {
            const ch = child.box.v[3];
            switch (el.direction) {
                .column => total += ch,
                .row, .layer => total = @max(total, ch + pad_h),
                .grid => unreachable,
            }
        }
        child_slot = child.next_sibling;
    }
    if (el.direction == .column and el.child_count > 1)
        total += el.gap * @as(f32, @floatFromInt(el.child_count - 1));
    return total;
}

pub const ScrollLookup = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, id: Element.Id) [2]f32,

    pub inline fn get(self: ScrollLookup, id: Element.Id) [2]f32 {
        return self.getFn(self.ctx, id);
    }
};

pub fn computeLayout(self: *Context, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    try self.computeLayoutNode(self.root_slot, 0, 0, scroll, scrollbar_thickness);
    if (self.has_extra_roots) {
        for (self.pool.elements.items, 0..) |*el, idx| {
            const slot: Element.Slot = @intCast(idx);
            if (slot != self.root_slot and el.parent == Element.INVALID_SLOT) {
                try self.computeLayoutNode(slot, el.box.v[0], el.box.v[1], scroll, scrollbar_thickness);
            }
        }
    }
}

fn computeLayoutNode(self: *Context, root_slot: Element.Slot, x: f32, y: f32, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    const elements = self.pool.elements.items;
    const el = &elements[root_slot];

    const box_w = el.box.v[2];
    const box_h = el.box.v[3];
    el.box.v[0] = x;
    el.box.v[1] = y;
    el.content_w = box_w;
    el.content_h = box_h;

    if (el.first_child == Element.INVALID_SLOT) {
        if (el.overflow.isScroll() and (el.direction == .row or el.direction == .column)) {
            el.content_w = el.padding.value[3] + el.padding.value[1];
            el.content_h = el.padding.value[0] + el.padding.value[2];
        }
        return;
    }

    switch (el.direction) {
        .grid => return self.computeGridLayout(root_slot, el, scroll, scrollbar_thickness),
        .layer => return self.computeLayerLayout(el, scroll, scrollbar_thickness),
        .row => return self.computeFlexLayout(true, el, x, y, scroll, scrollbar_thickness),
        .column => return self.computeFlexLayout(false, el, x, y, scroll, scrollbar_thickness),
    }
}

inline fn computeFlexLayout(
    self: *Context,
    comptime is_row: bool,
    el: *Element,
    x: f32,
    y: f32,
    scroll: ScrollLookup,
    scrollbar_thickness: f32,
) LayoutError!void {
    const main_idx: usize = if (is_row) 2 else 3;
    const cross_idx: usize = if (is_row) 3 else 2;
    const elements = self.pool.elements.items;

    const box_w = el.box.v[2];
    const box_h = el.box.v[3];
    const pad_top = el.padding.value[0];
    const pad_right = el.padding.value[1];
    const pad_bottom = el.padding.value[2];
    const pad_left = el.padding.value[3];
    const main_size = if (is_row) box_w else box_h;
    const cross_size = if (is_row) box_h - pad_top - pad_bottom else box_w - pad_left - pad_right;
    const pad_main_start = if (is_row) pad_left else pad_top;
    const pad_main_end = if (is_row) pad_right else pad_bottom;
    const pad_cross_start = if (is_row) pad_top else pad_left;
    const pad_cross_end = if (is_row) pad_bottom else pad_right;

    const static_count = el.child_count;
    const gaps: f32 = if (static_count > 1) el.gap * @as(f32, @floatFromInt(static_count - 1)) else 0;
    const avail = main_size - pad_main_start - pad_main_end;
    const main_base: f32 = @max(0, avail - gaps);
    const cross_base: f32 = @max(0, cross_size);

    var used: f32 = 0;
    var grow_count: u32 = 0;
    var has_grow_minmax = false;
    var children_cross: f32 = 0;

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = &elements[child_slot];
        child_slot = child.next_sibling;
        if (child.position == .absolute) continue;

        const cross_axis = if (is_row) &child.height else &child.width;
        switch (cross_axis.kind) {
            .percent => {
                child.box.v[cross_idx] = fclamp(cross_axis.value * cross_base, cross_axis.min, cross_axis.max);
            },
            .grow => {
                child.box.v[cross_idx] = cross_size;
            },
            .fixed, .fit => {},
        }
        children_cross = @max(children_cross, child.box.v[cross_idx]);

        const main_axis = if (is_row) &child.width else &child.height;
        switch (main_axis.kind) {
            .grow => {
                grow_count += 1;
                if (main_axis.min > 0 or main_axis.max < std.math.floatMax(f32)) {
                    has_grow_minmax = true;
                }
            },
            .percent => {
                const s = fclamp(main_axis.value * main_base, main_axis.min, main_axis.max);
                child.box.v[main_idx] = s;
                used += s;
            },
            .fixed, .fit => {
                used += child.box.v[main_idx];
            },
        }
    }

    const free: f32 = @max(0, avail - (used + gaps));
    var unclamped_grow_unit: ?f32 = null;
    var grow_main_total: f32 = 0;
    if (grow_count > 0) {
        if (has_grow_minmax) {
            grow_main_total = self.distributeGrow(is_row, el, free, grow_count);
        } else {
            unclamped_grow_unit = free / @as(f32, @floatFromInt(grow_count));
            grow_main_total = free;
        }
    }

    var cursor: f32 = pad_main_start;
    var item_gap: f32 = el.gap;
    var scroll_offset: [2]f32 = .{ 0, 0 };

    if (el.justify != .start or el.overflow.isScroll()) {
        const children_main: f32 = used + grow_main_total;
        const justify_free: f32 = @max(0, avail - children_main - gaps);
        cursor = switch (el.justify) {
            .start, .space_between, .space_around => pad_main_start,
            .end => pad_main_start + justify_free,
            .center => pad_main_start + justify_free * 0.5,
        };

        item_gap = switch (el.justify) {
            .start, .end, .center => el.gap,
            .space_between => if (static_count > 1)
                justify_free / @as(f32, @floatFromInt(static_count - 1)) + el.gap
            else
                el.gap,
            .space_around => if (static_count > 0)
                justify_free / @as(f32, @floatFromInt(static_count)) + el.gap
            else
                el.gap,
        };

        if (el.overflow.isScroll()) {
            const content_main = children_main + gaps + pad_main_start + pad_main_end;
            const content_cross = children_cross + pad_cross_start + pad_cross_end;
            const content_w = if (is_row) content_main else content_cross;
            const content_h = if (is_row) content_cross else content_main;
            const metrics = Element.scrollMetrics(el.overflow, el.box, content_w, content_h, scrollbar_thickness);
            const raw = scroll.get(el.id);
            scroll_offset = switch (el.overflow) {
                .scroll_x => .{ fclamp(raw[0], 0, metrics.max_offset[0]), 0 },
                .scroll_y => .{ 0, fclamp(raw[1], 0, metrics.max_offset[1]) },
                .scroll => .{ fclamp(raw[0], 0, metrics.max_offset[0]), fclamp(raw[1], 0, metrics.max_offset[1]) },
                else => unreachable,
            };
            el.content_w = content_w;
            el.content_h = content_h;
        }
    }

    const origin_x = x - scroll_offset[0];
    const origin_y = y - scroll_offset[1];
    const alignment = el.alignment;

    child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const cur_slot = child_slot;
        const child = &elements[cur_slot];
        child_slot = child.next_sibling;
        if (child.position == .absolute) continue;

        if (unclamped_grow_unit) |grow_unit| {
            const c_main_kind = if (is_row) child.width.kind else child.height.kind;
            if (c_main_kind == .grow) {
                child.box.v[main_idx] = grow_unit;
            }
        }

        const child_w = child.box.v[2];
        const child_h = child.box.v[3];
        const child_main = if (is_row) child_w else child_h;
        const child_cross = if (is_row) child_h else child_w;

        const cross_offset = pad_cross_start + switch (alignment) {
            .start, .stretch => @as(f32, 0),
            .center => (cross_size - child_cross) * 0.5,
            .end => cross_size - child_cross,
        };

        const cx = origin_x + if (is_row) cursor else cross_offset;
        const cy = origin_y + if (is_row) cross_offset else cursor;
        cursor += child_main + item_gap;

        if (child.first_child == Element.INVALID_SLOT and !child.overflow.isScroll()) {
            child.box.v = .{ cx, cy, child_w, child_h };
            child.content_w = child_w;
            child.content_h = child_h;
        } else {
            try self.computeLayoutNode(cur_slot, cx, cy, scroll, scrollbar_thickness);
        }
    }

    // Position absolute children: fill parent's content area and place at parent origin + padding + offset.
    if (el.has_absolute_child) {
        const abs_content_w = box_w - pad_left - pad_right;
        const abs_content_h = box_h - pad_top - pad_bottom;
        const abs_origin_x = x + pad_left;
        const abs_origin_y = y + pad_top;
        child_slot = el.first_child;
        while (child_slot != Element.INVALID_SLOT) {
            const cur_slot = child_slot;
            const child = &elements[cur_slot];
            child_slot = child.next_sibling;
            if (child.position == .absolute) {
                if (child.width.kind == .grow) child.box.v[2] = abs_content_w;
                if (child.width.kind == .percent) child.box.v[2] = fclamp(child.width.value * abs_content_w, child.width.min, child.width.max);
                if (child.height.kind == .grow) child.box.v[3] = abs_content_h;
                if (child.height.kind == .percent) child.box.v[3] = fclamp(child.height.value * abs_content_h, child.height.min, child.height.max);
                const cx = abs_origin_x + child.offset[0];
                const cy = abs_origin_y + child.offset[1];
                if (child.first_child == Element.INVALID_SLOT and !child.overflow.isScroll()) {
                    const cw = child.box.v[2];
                    const ch = child.box.v[3];
                    child.box.v = .{ cx, cy, cw, ch };
                    child.content_w = cw;
                    child.content_h = ch;
                } else {
                    try self.computeLayoutNode(cur_slot, cx, cy, scroll, scrollbar_thickness);
                }
            }
        }
    }
}

fn computeLayerLayout(self: *Context, el: *Element, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    const elements = self.pool.elements.items;
    const content_w: f32 = @max(0, el.box.v[2] - el.padding.value[3] - el.padding.value[1]);
    const content_h: f32 = @max(0, el.box.v[3] - el.padding.value[0] - el.padding.value[2]);
    const origin_x = el.box.v[0] + el.padding.value[3];
    const origin_y = el.box.v[1] + el.padding.value[0];

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const cur_slot = child_slot;
        const child = &elements[cur_slot];
        child_slot = child.next_sibling;

        const cx: f32, const cy: f32 = if (child.position != .absolute) blk: {
            if (child.width.kind == .grow)
                child.box.v[2] = fclamp(content_w, child.width.min, child.width.max);
            if (child.width.kind == .percent)
                child.box.v[2] = fclamp(child.width.value * content_w, child.width.min, child.width.max);
            if (child.height.kind == .grow)
                child.box.v[3] = fclamp(content_h, child.height.min, child.height.max);
            if (child.height.kind == .percent)
                child.box.v[3] = fclamp(child.height.value * content_h, child.height.min, child.height.max);

            const cw = child.box.v[2];
            const ch = child.box.v[3];
            const x_off: f32 = switch (el.justify) {
                .start, .space_between, .space_around => 0,
                .center => (content_w - cw) * 0.5,
                .end => content_w - cw,
            };
            const y_off: f32 = switch (el.alignment) {
                .start, .stretch => 0,
                .center => (content_h - ch) * 0.5,
                .end => content_h - ch,
            };
            break :blk .{ origin_x + x_off, origin_y + y_off };
        } else blk: {
            if (child.width.kind == .grow) child.box.v[2] = content_w;
            if (child.width.kind == .percent) child.box.v[2] = fclamp(child.width.value * content_w, child.width.min, child.width.max);
            if (child.height.kind == .grow) child.box.v[3] = content_h;
            if (child.height.kind == .percent) child.box.v[3] = fclamp(child.height.value * content_h, child.height.min, child.height.max);
            break :blk .{ origin_x + child.offset[0], origin_y + child.offset[1] };
        };

        if (child.first_child == Element.INVALID_SLOT and !child.overflow.isScroll()) {
            const cw = child.box.v[2];
            const ch = child.box.v[3];
            child.box.v = .{ cx, cy, cw, ch };
            child.content_w = cw;
            child.content_h = ch;
        } else {
            try self.computeLayoutNode(cur_slot, cx, cy, scroll, scrollbar_thickness);
        }
    }
}

inline fn resolveGridTracks(tracks: []const Grid.Track, available: f32, gap: f32, sizes_out: []f32) void {
    if (tracks.len == 0) return;
    const gap_total = if (tracks.len > 1) gap * @as(f32, @floatFromInt(tracks.len - 1)) else 0;
    var fixed_total: f32 = 0;
    var fr_total: f32 = 0;
    for (tracks) |t| switch (t) {
        .fixed => |v| fixed_total += v,
        .fr => |v| fr_total += v,
    };
    const fr_pool: f32 = @max(0, available - fixed_total - gap_total);
    for (tracks, 0..) |t, i| {
        sizes_out[i] = switch (t) {
            .fixed => |v| v,
            .fr => |v| if (fr_total > 0) (v / fr_total) * fr_pool else 0,
        };
    }
}

const GRID_INLINE_TRACKS: usize = 32;

fn computeGridLayout(self: *Context, slot: Element.Slot, el: *Element, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    const tpl = self.grid_templates.get(slot) orelse return;
    const cols = tpl.cols;
    const rows = tpl.rows;
    if (cols.len == 0 or rows.len == 0) return;

    const elements = self.pool.elements.items;
    const content_w: f32 = @max(0, el.box.v[2] - el.padding.value[3] - el.padding.value[1]);
    const content_h: f32 = @max(0, el.box.v[3] - el.padding.value[0] - el.padding.value[2]);

    var stack_col_sizes: [GRID_INLINE_TRACKS]f32 = undefined;
    var stack_col_offsets: [GRID_INLINE_TRACKS + 1]f32 = undefined;
    var stack_row_sizes: [GRID_INLINE_TRACKS]f32 = undefined;
    var stack_row_offsets: [GRID_INLINE_TRACKS + 1]f32 = undefined;

    const need_heap = cols.len > GRID_INLINE_TRACKS or rows.len > GRID_INLINE_TRACKS;
    const heap_buf: []f32 = if (need_heap)
        try self.allocator.alloc(f32, (cols.len * 2 + 1) + (rows.len * 2 + 1))
    else
        &.{};
    defer if (need_heap) self.allocator.free(heap_buf);

    const col_sizes = if (!need_heap) stack_col_sizes[0..cols.len] else heap_buf[0..cols.len];
    const col_offsets = if (!need_heap) stack_col_offsets[0 .. cols.len + 1] else heap_buf[cols.len..][0 .. cols.len + 1];
    const row_base = cols.len * 2 + 1;
    const row_sizes = if (!need_heap) stack_row_sizes[0..rows.len] else heap_buf[row_base..][0..rows.len];
    const row_offsets = if (!need_heap) stack_row_offsets[0 .. rows.len + 1] else heap_buf[row_base + rows.len ..][0 .. rows.len + 1];

    resolveGridTracks(cols, content_w, el.gap, col_sizes);
    resolveGridTracks(rows, content_h, el.gap, row_sizes);

    col_offsets[0] = 0;
    for (col_sizes, 0..) |s, i| col_offsets[i + 1] = col_offsets[i] + s + el.gap;
    row_offsets[0] = 0;
    for (row_sizes, 0..) |s, i| row_offsets[i + 1] = row_offsets[i] + s + el.gap;

    const origin_x = el.box.v[0] + el.padding.value[3];
    const origin_y = el.box.v[1] + el.padding.value[0];
    const ncols: u32 = @intCast(cols.len);
    const nrows: u32 = @intCast(rows.len);

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const cur_slot = child_slot;
        const child = &elements[cur_slot];
        child_slot = child.next_sibling;
        if (child.position == .absolute) continue;

        // Children without explicit placement default to (0, 0, 1, 1).
        const placement = self.grid_placements.get(cur_slot) orelse Grid.Placement{};

        if (comptime std.debug.runtime_safety) {
            std.debug.assert(placement.col < ncols);
            std.debug.assert(placement.row < nrows);
            std.debug.assert(placement.col_span >= 1 and placement.col + placement.col_span <= ncols);
            std.debug.assert(placement.row_span >= 1 and placement.row + placement.row_span <= nrows);
        }

        const c = placement.col;
        const r = placement.row;
        const cs = placement.col_span;
        const rs = placement.row_span;

        var w: f32 = 0;
        for (col_sizes[c .. c + cs]) |s| w += s;
        if (cs > 1) w += el.gap * @as(f32, @floatFromInt(cs - 1));
        var h: f32 = 0;
        for (row_sizes[r .. r + rs]) |s| h += s;
        if (rs > 1) h += el.gap * @as(f32, @floatFromInt(rs - 1));

        const cx = origin_x + col_offsets[c];
        const cy = origin_y + row_offsets[r];
        const cw = fclamp(w, child.width.min, child.width.max);
        const ch = fclamp(h, child.height.min, child.height.max);
        child.box.v[2] = cw;
        child.box.v[3] = ch;

        if (child.first_child == Element.INVALID_SLOT and !child.overflow.isScroll()) {
            child.box.v = .{ cx, cy, cw, ch };
            child.content_w = cw;
            child.content_h = ch;
        } else {
            try self.computeLayoutNode(cur_slot, cx, cy, scroll, scrollbar_thickness);
        }
    }

    if (el.has_absolute_child) {
        child_slot = el.first_child;
        while (child_slot != Element.INVALID_SLOT) {
            const cur_slot = child_slot;
            const child = &elements[cur_slot];
            child_slot = child.next_sibling;
            if (child.position == .absolute) {
                if (child.width.kind == .grow) child.box.v[2] = content_w;
                if (child.width.kind == .percent) child.box.v[2] = fclamp(child.width.value * content_w, child.width.min, child.width.max);
                if (child.height.kind == .grow) child.box.v[3] = content_h;
                if (child.height.kind == .percent) child.box.v[3] = fclamp(child.height.value * content_h, child.height.min, child.height.max);
                const cx = origin_x + child.offset[0];
                const cy = origin_y + child.offset[1];
                if (child.first_child == Element.INVALID_SLOT and !child.overflow.isScroll()) {
                    const cw = child.box.v[2];
                    const ch = child.box.v[3];
                    child.box.v = .{ cx, cy, cw, ch };
                    child.content_w = cw;
                    child.content_h = ch;
                } else {
                    try self.computeLayoutNode(cur_slot, cx, cy, scroll, scrollbar_thickness);
                }
            }
        }
    }
}

inline fn distributeGrow(self: *Context, comptime is_row: bool, el: *const Element, initial_free: f32, initial_grow_count: u32) f32 {
    const main_idx: usize = if (is_row) 2 else 3;
    const elements = self.pool.elements.items;
    var remaining_free = initial_free;
    var grow_count: f32 = @floatFromInt(initial_grow_count);

    while (grow_count > 0) {
        const grow_unit = remaining_free / grow_count;
        var clamped_space: f32 = 0;
        var still_growing: f32 = 0;

        var child_slot = el.first_child;
        while (child_slot != Element.INVALID_SLOT) {
            const child = &elements[child_slot];
            child_slot = child.next_sibling;
            const main_axis = if (is_row) &child.width else &child.height;
            if (child.position != .absolute and main_axis.kind == .grow) {
                const clamped = fclamp(grow_unit, main_axis.min, main_axis.max);
                if (clamped != grow_unit) {
                    child.box.v[main_idx] = clamped;
                    clamped_space += clamped;
                } else still_growing += 1;
            }
        }

        if (still_growing == grow_count) break;

        remaining_free -= clamped_space;
        grow_count = still_growing;
    }

    const final_grow_unit = if (grow_count > 0) remaining_free / grow_count else 0;
    var total_grow: f32 = 0;
    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = &elements[child_slot];
        child_slot = child.next_sibling;
        const main_axis = if (is_row) &child.width else &child.height;
        if (child.position != .absolute and main_axis.kind == .grow) {
            var s = child.box.v[main_idx];
            if (s == 0) {
                s = fclamp(final_grow_unit, main_axis.min, main_axis.max);
                child.box.v[main_idx] = s;
            }
            total_grow += s;
        }
    }
    return total_grow;
}
