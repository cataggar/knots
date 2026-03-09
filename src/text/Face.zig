const std = @import("std");
const ft = @import("freetype").c;
const hb = @import("harfbuzz").c;
const Atlas = @import("Atlas.zig");
const glyph = @import("glyph.zig");

ft_face: ft.FT_Face,
hb_font: *hb.hb_font_t,
hb_buf: *hb.hb_buffer_t,
atlas: *Atlas,
cache: std.AutoHashMap(glyph.Key, glyph.Metrics),
allocator: std.mem.Allocator,

const Face = @This();

pub fn init(allocator: std.mem.Allocator, ft_lib: ft.FT_Library, font_data: []const u8, atlas: *Atlas) !Face {
    var ft_face: ft.FT_Face = undefined;
    if (ft.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &ft_face) != 0)
        return error.FontLoadFailed;

    const hb_font = hb.hb_ft_font_create(@ptrCast(ft_face), null) orelse return error.HarfBuzzFontFailed;
    const hb_buf = hb.hb_buffer_create() orelse return error.HarfBuzzBufferFailed;

    return .{
        .ft_face = ft_face,
        .hb_font = hb_font,
        .hb_buf = hb_buf,
        .atlas = atlas,
        .cache = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Face) void {
    self.cache.deinit();
    hb.hb_buffer_destroy(self.hb_buf);
    hb.hb_font_destroy(self.hb_font);
    _ = ft.FT_Done_Face(self.ft_face);
}

fn rasterizeGlyph(self: *Face, codepoint: u32, size_px: f32) !glyph.Metrics {
    const key = glyph.Key{
        .codepoint = codepoint,
        .size_px = @intFromFloat(size_px * 64),
    };

    if (self.cache.get(key)) |metrics| return metrics;

    if (ft.FT_Load_Glyph(self.ft_face, codepoint, ft.FT_LOAD_TARGET_LIGHT) != 0)
        return error.LoadGlyphFailed;
    if (ft.FT_Render_Glyph(self.ft_face.*.glyph, ft.FT_RENDER_MODE_NORMAL) != 0)
        return error.RenderGlyphFailed;

    const g = self.ft_face.*.glyph;
    const bmp = g.*.bitmap;

    const atlas_rect = if (bmp.width > 0 and bmp.rows > 0) blk: {
        const bitmap_data = bmp.buffer[0 .. bmp.width * bmp.rows];
        break :blk try self.atlas.pack(bitmap_data, bmp.width, bmp.rows);
    } else glyph.Rect{
        .u = 0,
        .v = 0,
        .uw = 0,
        .uh = 0,
        .width = 0,
        .height = 0,
    };

    const metrics = glyph.Metrics{
        .rect = atlas_rect,
        .bearing_x = @floatFromInt(g.*.bitmap_left),
        .bearing_y = @floatFromInt(g.*.bitmap_top),
        .advance = @as(f32, @floatFromInt(g.*.advance.x)) / 64.0,
    };

    try self.cache.put(key, metrics);
    return metrics;
}

pub fn shape(self: *Face, allocator: std.mem.Allocator, text: []const u8, size_px: f32) !glyph.ShapedText {
    try self.setSize(size_px);
    self.shapeText(text);

    var glyph_count: u32 = 0;
    const glyph_infos = hb.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
    const glyph_positions = hb.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);

    var result = try std.ArrayList(glyph.Shaped).initCapacity(allocator, glyph_count);
    errdefer result.deinit(allocator);
    var pen_x: f32 = 0;

    for (0..glyph_count) |i| {
        const codepoint = glyph_infos[i].codepoint;
        const metrics = try self.rasterizeGlyph(codepoint, size_px);
        const x_offset = @as(f32, @floatFromInt(glyph_positions[i].x_offset)) / 64.0;
        const y_offset = @as(f32, @floatFromInt(glyph_positions[i].y_offset)) / 64.0;

        result.appendAssumeCapacity(.{
            .metrics = metrics,
            .x = @round(pen_x + x_offset + metrics.bearing_x),
            .y = y_offset,
        });

        pen_x += @as(f32, @floatFromInt(glyph_positions[i].x_advance)) / 64.0;
    }

    return .{
        .glyphs = try result.toOwnedSlice(allocator),
        .width = pen_x,
    };
}

fn setSize(self: *Face, size_px: f32) !void {
    if (ft.FT_Set_Char_Size(self.ft_face, 0, @intFromFloat(size_px * 64), 96, 96) != 0)
        return error.SetSizeFailed;
    hb.hb_ft_font_changed(self.hb_font);
}

fn shapeText(self: *Face, text: []const u8) void {
    hb.hb_buffer_reset(self.hb_buf);
    hb.hb_buffer_add_utf8(self.hb_buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    hb.hb_buffer_guess_segment_properties(self.hb_buf);
    hb.hb_shape(self.hb_font, self.hb_buf, null, 0);
}

fn measureLineWidth(self: *Face, text: []const u8, size_px: f32) !f32 {
    try self.setSize(size_px);
    self.shapeText(text);

    var glyph_count: u32 = 0;
    const glyph_positions = hb.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);

    var pen_x: f32 = 0;
    for (0..glyph_count) |i| {
        pen_x += @as(f32, @floatFromInt(glyph_positions[i].x_advance)) / 64.0;
    }

    return pen_x;
}

pub fn lineHeight(self: *Face, size_px: f32) !f32 {
    try self.setSize(size_px);
    return @as(f32, @floatFromInt(self.ft_face.*.size.*.metrics.height)) / 64.0;
}

pub fn measure(self: *Face, _: std.mem.Allocator, text: []const u8, size_px: f32) !glyph.TextMetrics {
    const line_height = try self.lineHeight(size_px);

    var max_line_width: f32 = 0;
    var line_count: u32 = 1;

    var line_start: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\n' or i == text.len - 1) {
            const line_end = if (byte == '\n') i else i + 1;
            const line = text[line_start..line_end];

            if (line.len > 0) {
                max_line_width = @max(max_line_width, try self.measureLineWidth(line, size_px));
            }

            if (byte == '\n') {
                line_count += 1;
                line_start = i + 1;
            }
        }
    }

    return .{
        .width = max_line_width,
        .height = line_height * @as(f32, @floatFromInt(line_count)),
        .line_count = line_count,
    };
}
