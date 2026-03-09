pub const RGBA = [4]f32;

pub const Color = union(enum) {
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
    rgba: [4]f32,

    pub const transparent: Color = .{ .rgba = .{ 0, 0, 0, 0 } };

    pub inline fn resolve(self: Color) [4]f32 {
        return switch (self) {
            .rgba => |v| v,
            inline else => |_, tag| @field(definition, @tagName(tag)),
        };
    }

    pub inline fn isTransparent(self: Color) bool {
        return switch (self) {
            .rgba => |v| v[3] == 0,
            else => false,
        };
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

        const parseByte = struct {
            fn f(comptime hi: u8, comptime lo: u8) f32 {
                return @as(f32, @floatFromInt(parseNibble(hi) * 16 + parseNibble(lo))) / 255.0;
            }
        }.f;

        return switch (s.len) {
            3 => .{ .rgba = .{
                parseByte(s[0], s[0]),
                parseByte(s[1], s[1]),
                parseByte(s[2], s[2]),
                1.0,
            } },
            4 => .{ .rgba = .{
                parseByte(s[0], s[0]),
                parseByte(s[1], s[1]),
                parseByte(s[2], s[2]),
                parseByte(s[3], s[3]),
            } },
            6 => .{ .rgba = .{
                parseByte(s[0], s[1]),
                parseByte(s[2], s[3]),
                parseByte(s[4], s[5]),
                1.0,
            } },
            8 => .{ .rgba = .{
                parseByte(s[0], s[1]),
                parseByte(s[2], s[3]),
                parseByte(s[4], s[5]),
                parseByte(s[6], s[7]),
            } },
            else => @compileError("invalid hex color length, expected #RGB / #RGBA / #RRGGBB / #RRGGBBAA"),
        };
    }
};

pub const Radius = union(enum) {
    none,
    xs,
    sm,
    md,
    lg,
    xl,
    fixed: f32,

    pub inline fn resolve(self: Radius) f32 {
        const base = definition.radius;
        return switch (self) {
            .none => 0,
            .xs => base * 0.25,
            .sm => base * 0.5,
            .md => base,
            .lg => base * 1.5,
            .xl => base * 2.0,
            .fixed => |v| v,
        };
    }
};

primary: RGBA = .{ 0.388, 0.510, 0.933, 1.0 },
secondary: RGBA = .{ 0.467, 0.388, 0.800, 1.0 },
success: RGBA = .{ 0.259, 0.690, 0.502, 1.0 },
info: RGBA = .{ 0.259, 0.647, 0.863, 1.0 },
warning: RGBA = .{ 0.933, 0.702, 0.200, 1.0 },
@"error": RGBA = .{ 0.863, 0.302, 0.302, 1.0 },
bg: RGBA = .{ 0.071, 0.071, 0.078, 1.0 },
muted: RGBA = .{ 0.118, 0.118, 0.129, 1.0 },
elevated: RGBA = .{ 0.118, 0.118, 0.129, 1.0 },
accented: RGBA = .{ 0.929, 0.929, 0.949, 1.0 },
inverted: RGBA = .{ 0.071, 0.071, 0.078, 1.0 },
text: RGBA = .{ 0.918, 0.918, 0.929, 1.0 },
highlighted: RGBA = .{ 1.000, 1.000, 1.000, 1.0 },
toned: RGBA = .{ 0.220, 0.220, 0.240, 1.0 },
dimmed: RGBA = .{ 0.360, 0.360, 0.390, 1.0 },
radius: f32 = 6,

const Theme = @This();

pub const definition = if (@hasDecl(@import("root"), "knots_theme")) @import("root").knots_theme else Theme{};
