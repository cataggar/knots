const std = @import("std");

pub const Input = union(enum) {
    xs,
    sm,
    md,
    lg,
    xl,
    size: f32,

    const Self = @This();

    pub fn resolve(self: Self) Size {
        return switch (self) {
            .size => |s| .{ .value = s },
            else => |t| switch (t) {
                .xs => .{ .value = 12 },
                .sm => .{ .value = 16 },
                .md => .{ .value = 20 },
                .lg => .{ .value = 24 },
                .xl => .{ .value = 28 },
                else => unreachable,
            },
        };
    }
};

const Size = @This();

value: f32,
