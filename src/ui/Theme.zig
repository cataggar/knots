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

primary: Color,
secondary: Color,
success: Color,
info: Color,
warning: Color,
@"error": Color,
bg: Color,
muted: Color,
elevated: Color,
accented: Color,
inverted: Color,
text: Color,
highlighted: Color,
toned: Color,
dimmed: Color,
radius: f32,

scrollbar_thickness: f32,
scrollbar_min_thumb: f32,
scrollbar_track_color: Color,
scrollbar_thumb_color: Color,
scrollbar_thumb_hover_color: Color,
scrollbar_corner_radius: f32,

const Theme = @This();

pub const dark = parseTheme(@import("themes/dark.zon"));
pub const light = parseTheme(@import("themes/light.zon"));

pub const definition = if (@hasDecl(@import("root"), "knots_theme")) parseThemeWithBase(dark, @import("root").knots_theme) else light;

fn parseTheme(def: anytype) Theme {
    const res: Theme = undefined;
    return parseThemeWithBase(res, def);
}

fn parseThemeWithBase(base: anytype, def: anytype) Theme {
    var res = base;
    inline for (std.meta.fields(@TypeOf(def))) |field| {
        const v = @field(def, field.name);
        if (@TypeOf(v) == comptime_float or @TypeOf(v) == comptime_int or @TypeOf(v) == f32) {
            @field(res, field.name) = v;
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
