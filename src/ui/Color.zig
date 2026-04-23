const std = @import("std");
const Theme = @import("Theme.zig");

pub const Input = union(enum) {
    primary,
    secondary,
    success,
    info,
    warning,
    @"error",
    bg,
    muted,
    elevated,
    accented,
    inverted,
    text,
    highlighted,
    toned,
    dimmed,
    color: Color,

    pub fn resolve(self: Input) [4]f32 {
        return switch (self) {
            .color => |c| c.value,
            inline else => |_, tag| @field(Theme.definition, @tagName(tag)).value,
        };
    }

    pub fn isTransparent(self: Input) bool {
        return switch (self) {
            .color => |c| c.value[3] == 0,
            else => false,
        };
    }
};

value: [4]f32,

const Color = @This();

pub const transparent: Color = .{ .value = .{ 0, 0, 0, 0 } };

fn srgbToLinear(c: f32) f32 {
    @setEvalBranchQuota(10_000);
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .value = .{
        srgbToLinear(@as(f32, @floatFromInt(r)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt(g)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt(b)) / 255.0),
        @as(f32, @floatFromInt(a)) / 255.0,
    } };
}

pub fn isTransparent(self: Color) bool {
    return self.value[3] == 0;
}

/// Parses a comptime RGBA hex string into a [4]f32 array.
/// Supported formats:
///   "#RRGGBB"   — opaque (alpha = 1.0)
///   "#RRGGBBAA"
///   "#RGB"      — shorthand, each nibble doubled
///   "#RGBA"     — shorthand with alpha
/// Values are normalized to [0.0, 1.0].
pub fn hex(comptime str: []const u8) Color {
    const s = if (str[0] == '#') str[1..] else str;

    const parseNibble = struct {
        fn f(comptime c: u8) u8 {
            return switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => @compileError("invalid hex character: " ++ [_]u8{c}),
            };
        }
    }.f;

    const parseByteSrgb = struct {
        fn f(comptime hi: u8, comptime lo: u8) f32 {
            const s_val = @as(f32, @floatFromInt(parseNibble(hi) * 16 + parseNibble(lo))) / 255.0;
            return srgbToLinear(s_val);
        }
    }.f;

    const parseByteAlpha = struct {
        fn f(comptime hi: u8, comptime lo: u8) f32 {
            return @as(f32, @floatFromInt(parseNibble(hi) * 16 + parseNibble(lo))) / 255.0;
        }
    }.f;

    return switch (s.len) {
        3 => .{ .value = .{
            parseByteSrgb(s[0], s[0]),
            parseByteSrgb(s[1], s[1]),
            parseByteSrgb(s[2], s[2]),
            1.0,
        } },
        4 => .{ .value = .{
            parseByteSrgb(s[0], s[0]),
            parseByteSrgb(s[1], s[1]),
            parseByteSrgb(s[2], s[2]),
            parseByteAlpha(s[3], s[3]),
        } },
        6 => .{ .value = .{
            parseByteSrgb(s[0], s[1]),
            parseByteSrgb(s[2], s[3]),
            parseByteSrgb(s[4], s[5]),
            1.0,
        } },
        8 => .{ .value = .{
            parseByteSrgb(s[0], s[1]),
            parseByteSrgb(s[2], s[3]),
            parseByteSrgb(s[4], s[5]),
            parseByteAlpha(s[6], s[7]),
        } },
        else => @compileError("invalid hex color length, expected #RGB / #RGBA / #RRGGBB / #RRGGBBAA"),
    };
}
