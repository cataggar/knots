const std = @import("std");

const UI = @import("ui").UI;
const State = @import("ui").State;
const Style = @import("ui").Style;
const Theme = @import("ui").Theme;
const Color = @import("ui").Color;
const Key = UI.Key;

const Element = @import("layout").Element;
const Decoration = UI.Decoration;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fit(),
size: f32 = 14,
buf: *std.ArrayList(u8),
placeholder: []const u8 = "",
color: Color.Input = .text,
placeholder_color: Color.Input = .dimmed,
style: Style = .{ .color = .muted },
focused_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = 1 },
key: Key,

const TextInput = @This();

pub fn open(self: *const TextInput, ui: *UI) !Element.Id {
    const id = self.key.hash();
    const is_focused = ui.focused(id);

    if (is_focused) {
        const s = try ui.state.getOrCreate(.text_input, ui.allocator, id);
        try processInput(self, ui, s);
        ui.input.consumeKeyboard();
    }

    const current_style = if (is_focused) self.focused_style else self.style;

    var height = self.height;
    height.min = try ui.lineHeight(self.size, null);

    const decoration: Decoration = if (current_style.hasDecoration())
        .{ .rect = current_style.toRect() }
    else
        .none;
    return try ui.open(self.key, .{
        .width = self.width,
        .height = height,
        .overflow = .scroll_x,
        .interactive = true,
        .alignment = .center,
    }, decoration);
}

pub fn close(self: *const TextInput, ui: *UI) !void {
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    const items = self.buf.items;
    const resolved_color = self.color.resolve();

    if (is_focused) {
        const s = ui.state.get(.text_input, id).?;
        const sel_lo = @min(s.cursor, s.sel_anchor);
        const sel_hi = @max(s.cursor, s.sel_anchor);
        const has_sel = sel_lo != sel_hi;

        try renderSpan(ui, id, "a", items[0..sel_lo], self.size, resolved_color, .none);

        if (has_sel) {
            const sel_color = comptime blk: {
                const base: Color.Input = .primary;
                var c = base.resolve();
                c[3] = 0.4;
                break :blk c;
            };
            const highlight: Decoration = .{ .rect = .{ .color = sel_color } };
            try renderSpan(ui, id, "b", items[sel_lo..sel_hi], self.size, resolved_color, highlight);
        } else {
            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "__ti_cursor_{}", .{id}) catch buf[0..];
            _ = try ui.open(.str(key), .{
                .width = .fixed(1),
                .height = .fixed(try ui.lineHeight(self.size, null)),
            }, .{ .rect = .{ .color = resolved_color } });
            ui.close();
        }

        try renderSpan(ui, id, "c", items[sel_hi..], self.size, resolved_color, .none);
    } else {
        const display, const color = if (items.len == 0)
            .{ self.placeholder, self.placeholder_color.resolve() }
        else
            .{ items, resolved_color };
        try renderSpan(ui, id, "d", display, self.size, color, .none);
    }

    ui.close();
}

fn renderSpan(
    ui: *UI,
    id: u64,
    comptime tag: []const u8,
    text: []const u8,
    size: f32,
    color: [4]f32,
    wrap: Decoration,
) !void {
    if (text.len == 0 and wrap == .none) return;

    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "__ti_" ++ tag ++ "_{}", .{id}) catch buf[0..];
    const key_t = std.fmt.bufPrint(&buf2, "__ti_" ++ tag ++ "_t_{}", .{id}) catch buf2[0..];

    _ = try ui.open(.str(key), .{ .width = .fit(), .height = .fit() }, wrap);
    if (text.len > 0) {
        var deco = try ui.textDecoration(text, size, null);
        deco.text.color = color;
        _ = try ui.open(.str(key_t), .{ .width = .fit(), .height = .fit() }, deco);
        ui.close();
    }
    ui.close();
}

fn processInput(self: *const TextInput, ui: *UI, s: *State.TextInput) !void {
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
            .home => {
                s.cursor = 0;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .end => {
                s.cursor = len;
                if (!ui.input.shift_held) s.sel_anchor = s.cursor;
            },
            .a => if (ui.input.ctrl_held) {
                s.sel_anchor = 0;
                s.cursor = len;
            },
            else => {},
        }
    }
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
