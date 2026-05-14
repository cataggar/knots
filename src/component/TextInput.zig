const std = @import("std");
const builtin = @import("builtin");

const App = @import("knots").App;
const UI = @import("ui").UI;
const State = @import("ui").State;
const Style = @import("ui").Style;
const Color = @import("ui").Color;
const Size = @import("ui").Size;
const Key = @import("ui").Key;
const Decoration = @import("ui").Decoration;

const Element = @import("layout").Element;
const glyph = @import("text").glyph;
const util = @import("util.zig");

const BODY_INDEX: usize = 1; // text decoration
const CURSOR_INDEX: usize = 2; // cursor overlay
const SELECTION_BASE: usize = 16; // selection line overlays start here, one per line

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fit(),
size: Size.Input = .sm,
buf: *std.ArrayList(u8),
placeholder: []const u8 = "",
color: Color.Input = .text,
placeholder_color: Color.Input = .dimmed,
style: Style = .{ .color = .muted },
focused_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = 1 },
wrap: bool = false,
key: Key,

const TextInput = @This();

pub fn open(self: *const TextInput, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);

    if (is_focused) {
        const s = try ui.state.getOrCreate(.text_input, ui.allocator, id);
        try processInputEarly(self, ui, s);
    }

    const current_style = if (is_focused) self.focused_style else self.style;

    var height = self.height;
    height.min = try ui.lineHeight(self.size.resolve(), null);

    const decoration: Decoration = if (current_style.hasDecoration())
        .{ .rect = current_style.toRect(&ui.theme) }
    else
        .none;
    const overflow: Element.Overflow = if (self.wrap) .visible else .scroll_x;
    return try ui.open(self.key, .{
        .width = self.width,
        .height = height,
        .overflow = overflow,
        .interactive = true,
        .alignment = .center,
        .padding = .init(0, 0, 0, 6),
    }, decoration);
}

pub fn close(self: *const TextInput, app: *App) !void {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    const items = self.buf.items;
    const resolved_color = self.color.resolve(&ui.theme);
    const size = self.size.resolve();

    const display, const color = if (!is_focused and items.len == 0)
        .{ self.placeholder, self.placeholder_color.resolve(&ui.theme) }
    else
        .{ items, resolved_color };

    if (is_focused) {
        const s = ui.state.get(.text_input, id).?;
        const scale = ui.content_scale;

        const face = try ui.font.getFace(null);
        const wrap_px: f32 = if (self.wrap) blk: {
            const m = try ui.state.getOrCreate(.measured, ui.allocator, id);
            break :blk @max(0, m.width * scale);
        } else 0;
        const shaped = try face.shapeWrapped(items, size.value * scale, wrap_px);
        const line_h = shaped.line_height / scale;

        try processInputLate(self, ui, s, shaped, line_h);
        ui.input.consumeKeyboard();

        const sel_lo = @min(s.cursor, s.sel_anchor);
        const sel_hi = @max(s.cursor, s.sel_anchor);
        const has_sel = sel_lo != sel_hi;

        if (has_sel) {
            const sel_color = blk: {
                const base: Color.Input = .primary;
                var c = base.resolve(&ui.theme);
                c[3] = 0.4;
                break :blk c;
            };
            const spans = try util.lineSpansForRange(ui.allocator, shaped, sel_lo, sel_hi, scale);
            defer ui.allocator.free(spans);
            for (spans, 0..) |sp, i| {
                _ = try ui.openAt(self.key.indexed(SELECTION_BASE + i), sp.x, sp.y, sp.w, line_h, .{}, .{ .rect = .{ .color = sel_color } });
                ui.close();
            }
        } else {
            const p = util.posAtByte(shaped, s.cursor, scale);
            _ = try ui.openAt(self.key.indexed(CURSOR_INDEX), p.x, p.y, 1, line_h, .{}, .{ .rect = .{ .color = resolved_color } });
            ui.close();
        }

        if (has_sel) ui.state.selection_text = items[sel_lo..sel_hi];
    }

    if (display.len > 0) {
        var deco = try ui.textDecoration(display, size, null, self.wrap);
        deco.text.color = color;
        const inner_w: Element.sizing.Axis = if (self.wrap) .grow() else .fit();
        _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = inner_w, .height = .fit() }, deco);
        ui.close();
    }

    ui.close();
}

fn processInputEarly(self: *const TextInput, ui: *UI, s: *State.TextInput) !void {
    const buf = self.buf;
    var len: u32 = @intCast(buf.items.len);
    s.cursor = @min(s.cursor, len);
    s.sel_anchor = @min(s.sel_anchor, len);

    for (ui.input.chars) |ch| {
        if (ch == 0) break;
        var encoded: [4]u8 = undefined;
        const n: u32 = @intCast(std.unicode.utf8Encode(ch, &encoded) catch continue);

        if (s.sel_anchor != s.cursor) deleteSelection(buf, &len, s);

        buf.insertSlice(ui.allocator, s.cursor, encoded[0..n]) catch continue;
        len += n;
        s.cursor += n;
        s.sel_anchor = s.cursor;
    }

    const super_ctrl_held = switch (builtin.os.tag) {
        .macos => ui.input.super_held,
        else => ui.input.ctrl_held,
    };

    for (ui.input.keys) |key| {
        switch (key) {
            .backspace => {
                if (s.sel_anchor != s.cursor) {
                    deleteSelection(buf, &len, s);
                } else if (s.cursor > 0) {
                    const prev = prevCharStart(buf.items, s.cursor);
                    const n = s.cursor - prev;
                    buf.replaceRangeAssumeCapacity(prev, n, &.{});
                    len -= n;
                    s.cursor = prev;
                    s.sel_anchor = s.cursor;
                }
            },
            .delete => {
                if (s.sel_anchor != s.cursor) {
                    deleteSelection(buf, &len, s);
                } else if (s.cursor < len) {
                    const next = nextCharStart(buf.items, s.cursor);
                    const n = next - s.cursor;
                    buf.replaceRangeAssumeCapacity(s.cursor, n, &.{});
                    len -= n;
                }
            },
            .left => {
                const extend = ui.input.shift_held;
                if (!extend and s.sel_anchor != s.cursor) {
                    s.cursor = @min(s.cursor, s.sel_anchor);
                    s.sel_anchor = s.cursor;
                } else if (s.cursor > 0) {
                    s.cursor = prevCharStart(buf.items, s.cursor);
                    if (!extend) s.sel_anchor = s.cursor;
                }
            },
            .right => {
                const extend = ui.input.shift_held;
                if (!extend and s.sel_anchor != s.cursor) {
                    s.cursor = @max(s.cursor, s.sel_anchor);
                    s.sel_anchor = s.cursor;
                } else if (s.cursor < len) {
                    s.cursor = nextCharStart(buf.items, s.cursor);
                    if (!extend) s.sel_anchor = s.cursor;
                }
            },
            .a => if (super_ctrl_held) {
                s.sel_anchor = 0;
                s.cursor = len;
            },
            else => {},
        }
    }
}

fn processInputLate(self: *const TextInput, ui: *UI, s: *State.TextInput, shaped: glyph.ShapedWrappedView, line_h: f32) !void {
    const buf = self.buf;
    var len: u32 = @intCast(buf.items.len);
    const scale = ui.content_scale;

    for (ui.input.keys) |key| {
        switch (key) {
            .enter => if (self.wrap) {
                if (s.sel_anchor != s.cursor) deleteSelection(buf, &len, s);
                buf.insertSlice(ui.allocator, s.cursor, "\n") catch return;
                len += 1;
                s.cursor += 1;
                s.sel_anchor = s.cursor;
                return;
            },
            .up, .down => if (self.wrap) {
                const cur_pos = util.posAtByte(shaped, s.cursor, scale);
                const target_y = if (key == .up) cur_pos.y - line_h * 0.5 else cur_pos.y + line_h * 1.5;
                const target: util.Pos = .{ .x = cur_pos.x, .y = target_y };
                const new_cursor = util.byteAtPos(shaped, target, scale);
                s.cursor = @min(new_cursor, len);
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .home => {
                const new_cursor: u32 = if (self.wrap)
                    lineBounds(shaped, s.cursor).start
                else
                    0;
                s.cursor = new_cursor;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .end => {
                const new_cursor: u32 = if (self.wrap)
                    lineBounds(shaped, s.cursor).end
                else
                    len;
                s.cursor = new_cursor;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            else => {},
        }
    }
}

fn lineBounds(view: glyph.ShapedWrappedView, byte: u32) struct { start: u32, end: u32 } {
    if (view.lines.len == 0) return .{ .start = 0, .end = 0 };
    for (view.lines) |line| {
        if (byte <= line.byte_end) return .{ .start = line.byte_start, .end = line.byte_end };
    }
    const last = view.lines[view.lines.len - 1];
    return .{ .start = last.byte_start, .end = last.byte_end };
}

fn deleteSelection(buf: *std.ArrayList(u8), len: *u32, s: *State.TextInput) void {
    const lo = @min(s.cursor, s.sel_anchor);
    const hi = @max(s.cursor, s.sel_anchor);
    const n = hi - lo;
    std.debug.assert(buf.capacity >= buf.items.len);
    buf.replaceRangeAssumeCapacity(lo, n, &.{});
    len.* -= n;
    s.cursor = lo;
    s.sel_anchor = lo;
}

fn prevCharStart(buf: []const u8, pos: u32) u32 {
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (buf[i] & 0xC0 != 0x80) return i;
    }
    return 0;
}

fn nextCharStart(buf: []const u8, pos: u32) u32 {
    var i = pos + 1;
    while (i < buf.len) : (i += 1) {
        if (buf[i] & 0xC0 != 0x80) return i;
    }
    return @intCast(buf.len);
}
