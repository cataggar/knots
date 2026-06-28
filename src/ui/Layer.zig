const std = @import("std");

z: u8,

const Layer = @This();

pub const count: usize = 256;

pub const base: Layer = .{ .z = 0 };
pub const dropdown: Layer = .{ .z = 1 };
pub const popup: Layer = .{ .z = 10 };
pub const modal: Layer = .{ .z = 200 };

pub const floating_window_min: usize = 32;
pub const floating_window_max: usize = 199;
pub const floating_window_stride: usize = 4;
pub const floating_window_capacity: usize = ((floating_window_max - floating_window_min) / floating_window_stride) + 1;

pub fn fromIndex(i: usize) Layer {
    std.debug.assert(i < count);
    return .{ .z = @intCast(i) };
}

pub fn index(self: Layer) u8 {
    return self.z;
}

pub fn above(self: Layer, other: Layer) bool {
    return self.z > other.z;
}

pub fn eql(self: Layer, other: Layer) bool {
    return self.z == other.z;
}

pub fn max(a: Layer, b: Layer) Layer {
    return if (a.z >= b.z) a else b;
}

pub fn floatingWindow(order: usize) Layer {
    std.debug.assert(order > 0 and order <= floating_window_capacity);
    return fromIndex(floating_window_min + (order - 1) * floating_window_stride);
}

pub fn overlayWithin(parent: Layer, requested: Layer) Layer {
    if (!parent.isFloatingWindowLayer() or requested.z == base.z) return max(parent, requested);
    return fromIndex(@min(floating_window_max, @as(usize, parent.z) + floatingOverlayOffset(requested)));
}

fn isFloatingWindowLayer(self: Layer) bool {
    const z: usize = self.z;
    return z >= floating_window_min and z <= floating_window_max;
}

fn floatingOverlayOffset(requested: Layer) usize {
    if (requested.z >= modal.z) return 3;
    if (requested.z >= popup.z) return 2;
    if (requested.z >= dropdown.z) return 1;
    return 0;
}
