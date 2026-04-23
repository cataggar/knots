const std = @import("std");
const Color = @import("Color.zig");

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

primary: Color = Color.hex("#6382ee"),
secondary: Color = Color.hex("#7763cc"),
success: Color = Color.hex("#42b080"),
info: Color = Color.hex("#42a5dc"),
warning: Color = Color.hex("#eeb333"),
@"error": Color = Color.hex("#dc4d4d"),
bg: Color = Color.hex("#121214"),
muted: Color = Color.hex("#1e1e21"),
elevated: Color = Color.hex("#1e1e21"),
accented: Color = Color.hex("#ededf2"),
inverted: Color = Color.hex("#121214"),
text: Color = Color.hex("#eaeaed"),
highlighted: Color = Color.hex("#ffffff"),
toned: Color = Color.hex("#38383d"),
dimmed: Color = Color.hex("#5c5c63"),
radius: f32 = 6,

const Theme = @This();

pub const definition = if (@hasDecl(@import("root"), "knots_theme")) parseTheme(@import("root").knots_theme) else Theme{};

const ColorFormat = union(enum) {
    hex: []const u8,
    rgba: [4]f32,
    rgb: [3]f32,
};

fn parseTheme(def: anytype) Theme {
    var res = Theme{};
    inline for (std.meta.fields(@TypeOf(def))) |field| {
        const v = @field(def, field.name);
        if (std.mem.eql(u8, "radius", field.name)) {
            res.radius = v;
            continue;
        }

        const T = @TypeOf(v);

        @field(res, field.name) = if (@hasField(T, "hex"))
            Color.hex(@field(v, "hex"))
        else if (@hasField(T, "rgba")) blk: {
            const rgba = @field(v, "rgba");
            break :blk Color.rgba(rgba[0], rgba[1], rgba[2], rgba[3]);
        } else if (@hasField(T, "rgb")) blk: {
            const rgb = @field(v, "rgb");
            break :blk Color.rgba(rgb[0], rgb[1], rgb[2], 1);
        } else @compileError("boom");
    }
    return res;
}
