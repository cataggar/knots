const std = @import("std");
const Element = @import("Element.zig");

elements: std.ArrayList(Element) = .empty,

const ElementPool = @This();

pub fn deinit(self: *ElementPool, allocator: std.mem.Allocator) void {
    self.elements.deinit(allocator);
}

pub fn reset(self: *ElementPool) void {
    self.elements.clearRetainingCapacity();
}

pub fn append(self: *ElementPool, allocator: std.mem.Allocator, id: Element.Id, el: Element) !Element.Slot {
    const slot: Element.Slot = @intCast(self.elements.items.len);
    var element = el;
    element.id = id;
    try self.elements.append(allocator, element);
    return slot;
}

pub fn appendConfig(self: *ElementPool, allocator: std.mem.Allocator, id: Element.Id, parent: Element.Slot, config: *const Element.Config) !Element.Slot {
    const slot: Element.Slot = @intCast(self.elements.items.len);
    const ptr = try self.elements.addOne(allocator);
    ptr.* = .{
        .id = id,
        .parent = parent,
        .width = config.width,
        .height = config.height,
        .padding = config.padding,
        .gap = config.gap,
        .direction = config.direction,
        .alignment = config.alignment,
        .justify = config.justify,
        .interactive = config.interactive,
        .overflow = config.overflow,
        .position = config.position,
        .z_index = config.z_index,
        .offset = config.offset,
    };
    return slot;
}

pub fn get(self: *ElementPool, slot: Element.Slot) *Element {
    return &self.elements.items[slot];
}
