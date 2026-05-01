const std = @import("std");
const window = @import("window");
const root = @import("root.zig");
const keymap = @import("keymap.zig");

fn ownerOf(user_data: ?*anyopaque) ?*window.Window {
    return @ptrCast(@alignCast(user_data orelse return null));
}

fn modsOf(ev: *const root.EmscriptenKeyboardEvent) window.Mods {
    return .{ .shift = ev.shiftKey, .ctrl = ev.ctrlKey, .super = ev.metaKey };
}

fn decodePrintableChar(buf: []const u8) ?u21 {
    const slice = std.mem.sliceTo(buf, 0);
    if (slice.len == 0 or slice.len > 4) return null;
    const len = std.unicode.utf8ByteSequenceLength(slice[0]) catch return null;
    if (len != slice.len) return null;
    const cp = std.unicode.utf8Decode(slice[0..len]) catch return null;
    if (cp < 0x20 or cp == 0x7F) return null;
    return @intCast(cp);
}

pub fn onKeyDown(_: c_int, ev: *const root.EmscriptenKeyboardEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    const mods = modsOf(ev);
    const action: window.KeyAction = if (ev.repeat) .repeat else .press;
    if (keymap.translateCode(&ev.code)) |key| owner.pushKey(@intFromEnum(key), action, mods);
    if (!mods.ctrl and !mods.super) {
        if (decodePrintableChar(&ev.key)) |cp| owner.pushChar(cp);
    }
    return true;
}

pub fn onKeyUp(_: c_int, ev: *const root.EmscriptenKeyboardEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    const mods = modsOf(ev);
    if (keymap.translateCode(&ev.code)) |key| owner.pushKey(@intFromEnum(key), .release, mods);
    return true;
}

pub fn onMouseDown(_: c_int, ev: *const root.EmscriptenMouseEvent, user_data: ?*anyopaque) callconv(.c) bool {
    if (ev.button != 0) return false;
    const owner = ownerOf(user_data) orelse return false;
    owner.setMouseDown(true);
    return true;
}

pub fn onMouseUp(_: c_int, ev: *const root.EmscriptenMouseEvent, user_data: ?*anyopaque) callconv(.c) bool {
    if (ev.button != 0) return false;
    const owner = ownerOf(user_data) orelse return false;
    owner.setMouseDown(false);
    return true;
}

pub fn onMouseMove(_: c_int, ev: *const root.EmscriptenMouseEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    owner.backend.cursor_pos = .{ @floatFromInt(ev.targetX), @floatFromInt(ev.targetY) };
    return true;
}

pub fn onWheel(_: c_int, ev: *const root.EmscriptenWheelEvent, user_data: ?*anyopaque) callconv(.c) bool {
    const owner = ownerOf(user_data) orelse return false;
    // GLFW yoffset is +up; DOM deltaY is +down. Negate for sign parity.
    // Normalize by deltaMode so px / line / page wheels feel comparable.
    const norm: f64 = switch (ev.deltaMode) {
        0 => 100.0, // DOM_DELTA_PIXEL
        1 => 1.0, // DOM_DELTA_LINE
        2 => 0.1, // DOM_DELTA_PAGE
        else => 1.0,
    };
    owner.addScroll(-ev.deltaX / norm, -ev.deltaY / norm);
    return true;
}

pub fn onResize(_: c_int, _: *const root.EmscriptenUiEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const owner = ownerOf(user_data) orelse return 0;
    owner.backend.refreshCanvas();
    owner.markResized();
    return 1;
}

pub fn onBlur(_: c_int, _: *const root.EmscriptenFocusEvent, user_data: ?*anyopaque) callconv(.c) bool {
    // Synthesize release events for any keys we believe are still held would
    // require tracking pressed-key state. For now just clear pending key buffer.
    const owner = ownerOf(user_data) orelse return false;
    owner.key_count = 0;
    owner.char_count = 0;
    owner.mouse_button_pressed = false;
    return true;
}
