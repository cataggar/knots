const std = @import("std");
const Element = @import("layout").Element;

pub const TextInput = struct {
    cursor: u32 = 0,
    sel_anchor: u32 = 0,
    scroll_x: f32 = 0,
};

pub const Scroll = struct {
    offset: [2]f32 = .{ 0, 0 },
};

pub const SelectInput = struct {
    open: bool = false,
    anchor_box: Element.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    viewport_box: Element.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub const Slider = struct {
    bounds: Element.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

/// Double-buffered flat array of (id, T) pairs.
/// During a frame, `getOrCreate` migrates entries from `current` into `next`.
/// At end-of-frame, swap + clear so unmigrated state is evicted in O(1).
fn Pool(comptime T: type) type {
    return struct {
        const Entry = struct {
            id: Element.Id,
            value: T,
        };

        current: std.ArrayList(Entry) = .empty,
        next: std.ArrayList(Entry) = .empty,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.current.deinit(allocator);
            self.next.deinit(allocator);
        }

        pub fn get(self: *Self, id: Element.Id) ?*T {
            for (self.next.items) |*e| {
                if (e.id == id) return &e.value;
            }
            for (self.current.items) |*e| {
                if (e.id == id) return &e.value;
            }
            return null;
        }

        pub fn getOrCreate(self: *Self, allocator: std.mem.Allocator, id: Element.Id) !*T {
            for (self.next.items) |*e| {
                if (e.id == id) return &e.value;
            }
            for (self.current.items) |e| {
                if (e.id == id) {
                    try self.next.append(allocator, e);
                    return &self.next.items[self.next.items.len - 1].value;
                }
            }
            try self.next.append(allocator, .{ .id = id, .value = .{} });
            return &self.next.items[self.next.items.len - 1].value;
        }

        pub fn remove(self: *Self, id: Element.Id) void {
            for (self.next.items, 0..) |e, i| {
                if (e.id == id) {
                    _ = self.next.swapRemove(i);
                    return;
                }
            }
            for (self.current.items, 0..) |e, i| {
                if (e.id == id) {
                    _ = self.current.swapRemove(i);
                    return;
                }
            }
        }

        pub fn swap(self: *Self) void {
            const tmp = self.current;
            self.current = self.next;
            self.next = tmp;
            self.next.clearRetainingCapacity();
        }
    };
}

fn PoolValueType(comptime PoolT: type) type {
    return @FieldType(PoolT.Entry, "value");
}

pub const Storage = struct {
    const StoragePools = struct {
        text_input: Pool(TextInput) = .{},
        scroll: Pool(Scroll) = .{},
        select_input: Pool(SelectInput) = .{},
        slider: Pool(Slider) = .{},
    };

    pools: StoragePools = .{},

    inline fn poolFor(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools)) *@FieldType(StoragePools, @tagName(name)) {
        return &@field(self.pools, @tagName(name));
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(StoragePools)) |f| {
            @field(self.pools, f.name).deinit(allocator);
        }
    }

    pub fn get(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools), id: Element.Id) ?*PoolValueType(@FieldType(StoragePools, @tagName(name))) {
        return self.poolFor(name).get(id);
    }

    pub fn getOrCreate(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools), allocator: std.mem.Allocator, id: Element.Id) !*PoolValueType(@FieldType(StoragePools, @tagName(name))) {
        return self.poolFor(name).getOrCreate(allocator, id);
    }

    pub fn remove(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools), id: Element.Id) void {
        self.poolFor(name).remove(id);
    }

    pub fn swap(self: *Storage) void {
        inline for (std.meta.fields(StoragePools)) |f| {
            @field(self.pools, f.name).swap();
        }
    }
};

allocator: std.mem.Allocator,
hovered: Element.Id = Element.INVALID_ID,
active: Element.Id = Element.INVALID_ID,
focused: Element.Id = Element.INVALID_ID,
storage: Storage = .{},

const State = @This();

pub fn init(allocator: std.mem.Allocator) State {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *State) void {
    self.storage.deinit(self.allocator);
}

/// Returns a pointer to the state for `id`, or null if not yet created.
pub fn get(self: *State, comptime name: @EnumLiteral(), id: Element.Id) ?*PoolValueType(@FieldType(Storage.StoragePools, @tagName(name))) {
    return self.storage.get(name, id);
}

/// Returns a pointer to the state for `id`, creating a default-initialised
/// entry if it does not exist yet.
pub fn getOrCreate(self: *State, comptime name: @EnumLiteral(), allocator: std.mem.Allocator, id: Element.Id) !*PoolValueType(@FieldType(Storage.StoragePools, @tagName(name))) {
    return self.storage.getOrCreate(name, allocator, id);
}

pub fn remove(self: *State, comptime name: @EnumLiteral(), id: Element.Id) void {
    self.storage.remove(name, id);
}

/// Call at the end of each frame. Swaps double-buffered pools so that
/// state not accessed this frame is evicted.
pub fn endFrame(self: *State) void {
    self.storage.swap();
}

pub fn getScroll(self: *State, id: Element.Id) [2]f32 {
    const s = self.storage.getOrCreate(.scroll, self.allocator, id) catch return .{ 0, 0 };
    return s.offset;
}

pub fn addScroll(self: *State, id: Element.Id, el: *const Element, delta: [2]f32) !void {
    const max_x = @max(0, el.content_w - el.box.w);
    const max_y = @max(0, el.content_h - el.box.h);
    const s = try self.storage.getOrCreate(.scroll, self.allocator, id);
    s.offset[0] = std.math.clamp(s.offset[0] + delta[0], 0, max_x);
    s.offset[1] = std.math.clamp(s.offset[1] + delta[1], 0, max_y);
}

const testing = std.testing;

test "getOrCreate returns default state" {
    var state = init(testing.allocator);
    defer state.deinit();

    const s = try state.getOrCreate(.text_input, testing.allocator, 42);
    try testing.expectEqual(s.cursor, 0);
    try testing.expectEqual(s.sel_anchor, 0);
    try testing.expectEqual(s.scroll_x, 0);
}

test "get returns null before creation" {
    var state = init(testing.allocator);
    defer state.deinit();

    try testing.expectEqual(state.get(.text_input, 42), null);
}

test "getOrCreate is idempotent" {
    var state = init(testing.allocator);
    defer state.deinit();

    const a = try state.getOrCreate(.text_input, testing.allocator, 42);
    a.cursor = 7;

    const b = try state.getOrCreate(.text_input, testing.allocator, 42);
    try testing.expectEqual(b.cursor, 7);
}

test "separate ids are independent" {
    var state = init(testing.allocator);
    defer state.deinit();

    const a = try state.getOrCreate(.text_input, testing.allocator, 1);
    const b = try state.getOrCreate(.text_input, testing.allocator, 2);
    a.cursor = 3;
    b.cursor = 9;

    try testing.expectEqual((try state.getOrCreate(.text_input, testing.allocator, 1)).cursor, 3);
    try testing.expectEqual((try state.getOrCreate(.text_input, testing.allocator, 2)).cursor, 9);
}

test "swap evicts entries not accessed this frame" {
    var state = init(testing.allocator);
    defer state.deinit();

    _ = try state.getOrCreate(.text_input, testing.allocator, 1);
    _ = try state.getOrCreate(.text_input, testing.allocator, 2);

    state.endFrame();

    _ = try state.getOrCreate(.text_input, testing.allocator, 1);
    state.endFrame();

    try testing.expectEqual(state.get(.text_input, 2), null);
    try testing.expect(state.get(.text_input, 1) != null);
}

test "swap preserves mutated values across frames" {
    var state = init(testing.allocator);
    defer state.deinit();

    const s = try state.getOrCreate(.text_input, testing.allocator, 99);
    s.cursor = 5;

    state.endFrame();

    const after = try state.getOrCreate(.text_input, testing.allocator, 99);
    try testing.expectEqual(after.cursor, 5);
}

test "remove deletes entry" {
    var state = init(testing.allocator);
    defer state.deinit();

    _ = try state.getOrCreate(.text_input, testing.allocator, 10);
    state.remove(.text_input, 10);
    try testing.expectEqual(state.get(.text_input, 10), null);
}

test "pools are independent per type" {
    var state = init(testing.allocator);
    defer state.deinit();

    const t = try state.getOrCreate(.text_input, testing.allocator, 1);
    const s = try state.getOrCreate(.scroll, testing.allocator, 1);

    t.cursor = 42;
    s.offset = .{ 100, 200 };

    try testing.expectEqual(state.get(.text_input, 1).?.cursor, 42);
    try testing.expectEqual(state.get(.scroll, 1).?.offset[0], 100);
}
