const std = @import("std");
const zjb = @import("zjb");
const window = @import("window");
const bindings = @import("bindings.zig");
const keymap = @import("keymap.zig");

/// Set by `Backend.startCapture` when the app installs its event listeners.
/// A single global is sufficient since a wasm module only ever drives one
/// canvas/window per page.
pub var g_owner: ?*window.Window = null;

fn decodePrintableChar(slice: []const u8) ?u21 {
    if (slice.len == 0 or slice.len > 4) return null;
    const len = std.unicode.utf8ByteSequenceLength(slice[0]) catch return null;
    if (len != slice.len) return null;
    const cp = std.unicode.utf8Decode(slice[0..len]) catch return null;
    if (cp < 0x20 or cp == 0x7F) return null;
    return @intCast(cp);
}

fn modsOf(ev: zjb.Handle) window.Mods {
    return .{
        .shift = ev.get("shiftKey", bool),
        .ctrl = ev.get("ctrlKey", bool),
        .super = ev.get("metaKey", bool),
    };
}

fn mousePos(ev: zjb.Handle) [2]f64 {
    return .{ ev.get("offsetX", f64), ev.get("offsetY", f64) };
}

pub fn onKeyDown(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;

    const mods = modsOf(ev);
    const action: window.KeyAction = if (ev.get("repeat", bool)) .repeat else .press;

    var code_buf: [32]u8 = undefined;
    const code_handle = ev.get("code", zjb.Handle);
    const code = bindings.readJsStringUtf8(code_handle, &code_buf);
    code_handle.release();

    if (keymap.translateCode(code)) |key| {
        if ((mods.ctrl or mods.super) and key == .v) {
            win.backend.preparePaste();
            ev.call("preventDefault", .{}, void);
            return;
        }
        win.pushKey(@intFromEnum(key), action, mods);
    }

    if (!mods.ctrl and !mods.super) {
        var key_buf: [8]u8 = undefined;
        const key_handle = ev.get("key", zjb.Handle);
        const key_str = bindings.readJsStringUtf8(key_handle, &key_buf);
        key_handle.release();
        if (decodePrintableChar(key_str)) |cp| win.pushChar(cp);
    }

    ev.call("preventDefault", .{}, void);
}

pub fn onKeyUp(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;
    const mods = modsOf(ev);

    var code_buf: [32]u8 = undefined;
    const code_handle = ev.get("code", zjb.Handle);
    const code = bindings.readJsStringUtf8(code_handle, &code_buf);
    code_handle.release();

    if (keymap.translateCode(code)) |key| win.pushKey(@intFromEnum(key), .release, mods);
    ev.call("preventDefault", .{}, void);
}

pub fn onMouseDown(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;
    const pos = mousePos(ev);
    switch (@as(i32, @intFromFloat(ev.get("button", f64)))) {
        0 => {
            win.setMouseButton(.left, true, pos);
            ev.call("preventDefault", .{}, void);
        },
        2 => {
            win.setMouseButton(.right, true, pos);
            ev.call("preventDefault", .{}, void);
        },
        else => {},
    }
}

pub fn onMouseUp(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;
    const pos = mousePos(ev);
    switch (@as(i32, @intFromFloat(ev.get("button", f64)))) {
        0 => {
            win.setMouseButton(.left, false, pos);
            ev.call("preventDefault", .{}, void);
        },
        2 => {
            win.setMouseButton(.right, false, pos);
            ev.call("preventDefault", .{}, void);
        },
        else => {},
    }
}

pub fn onMouseMove(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;
    win.setCursorPos(mousePos(ev));
    ev.call("preventDefault", .{}, void);
}

pub fn onWheel(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;
    win.setCursorPos(mousePos(ev));

    const dx = ev.get("deltaX", f64);
    const dy = ev.get("deltaY", f64);
    switch (@as(i32, @intFromFloat(ev.get("deltaMode", f64)))) {
        0 => win.addScrollPixels(dx, dy), // DOM_DELTA_PIXEL
        1 => win.addScrollLines(dx, dy), // DOM_DELTA_LINE
        2 => win.addScrollPages(dx, dy), // DOM_DELTA_PAGE
        else => win.addScrollPixels(dx, dy),
    }
    ev.call("preventDefault", .{}, void);
}

pub fn onContextMenu(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    ev.call("preventDefault", .{}, void);
}

pub fn onBlur(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;
    win.key_count = 0;
    win.char_count = 0;
    win.setMouseLeftDown(false);
    win.setMouseRightDown(false);
}

pub fn onCanvasResize(entries: zjb.Handle) callconv(.c) void {
    defer entries.release();
    const win = g_owner orelse return;
    win.backend.refreshCanvas();
    win.markResized();
}

pub fn onPaste(ev: zjb.Handle) callconv(.c) void {
    defer ev.release();
    const win = g_owner orelse return;

    const clipboard_data = ev.get("clipboardData", zjb.Handle);
    defer clipboard_data.release();
    if (clipboard_data.isNull()) return;

    const text_handle = clipboard_data.call("getData", .{zjb.constString("text/plain")}, zjb.Handle);
    defer text_handle.release();

    var buf: [4096]u8 = undefined;
    const text = bindings.readJsStringUtf8(text_handle, &buf);
    if (text.len == 0) return;

    win.backend.clipboard_text.clearRetainingCapacity();
    win.backend.clipboard_text.appendSlice(win.backend.allocator, text) catch {
        win.backend.clipboard_valid = false;
        return;
    };
    win.backend.clipboard_valid = true;
    win.pushKey(@intFromEnum(window.Key.v), .press, .{ .ctrl = true });
    ev.call("preventDefault", .{}, void);
}
