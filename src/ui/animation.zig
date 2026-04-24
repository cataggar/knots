const std = @import("std");
const Element = @import("layout").Element;

pub const Ease = enum {
    smooth_step,
    ease_out_cubic,

    pub fn eval(self: Ease, t: f32) f32 {
        return switch (self) {
            .smooth_step => t * t * (3.0 - 2.0 * t),
            .ease_out_cubic => 1.0 - std.math.pow(f32, 1.0 - t, 3.0),
        };
    }
};

pub fn channelId(widget_id: Element.Id, channel: []const u8) Element.Id {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&widget_id));
    hasher.update(channel);
    const result: Element.Id = @truncate(hasher.final());
    return if (result == Element.INVALID_ID) result -% 1 else result;
}

pub inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn lerpVec4(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        lerp(a[0], b[0], t),
        lerp(a[1], b[1], t),
        lerp(a[2], b[2], t),
        lerp(a[3], b[3], t),
    };
}
