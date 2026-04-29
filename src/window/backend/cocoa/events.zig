const objc = @import("objc");
const window = @import("window");
const ak = @import("appkit.zig");
const keymap = @import("keymap.zig");

const c = ak.c;
const Window = @import("window").Window;

pub const view_misc_methods = .{
    .{ "acceptsFirstResponder", acceptsFirstResponder },
    .{ "isFlipped", isFlipped },
};

pub const mouse_methods = .{
    .{ "mouseDown:", mouseDown },
    .{ "mouseUp:", mouseUp },
    .{ "scrollWheel:", scrollWheel },
};

pub const keyboard_methods = .{
    .{ "keyDown:", keyDown },
    .{ "keyUp:", keyUp },
    .{ "flagsChanged:", flagsChanged },
};

pub const delegate_methods = .{
    .{ "windowShouldClose:", windowShouldClose },
    .{ "windowDidResize:", windowDidResize },
};

fn acceptsFirstResponder(_: c.id, _: c.SEL) callconv(.c) c.BOOL {
    return ak.boolParam(true);
}

fn isFlipped(_: c.id, _: c.SEL) callconv(.c) c.BOOL {
    return ak.boolParam(true);
}

fn mouseDown(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseDown(true);
}

fn mouseUp(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseDown(false);
}

fn scrollWheel(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const dx = event.msgSend(f64, "scrollingDeltaX", .{});
    const dy = event.msgSend(f64, "scrollingDeltaY", .{});
    const precise = event.msgSend(bool, "hasPreciseScrollingDeltas", .{});
    const scale: f64 = if (precise) 0.1 else 1.0;
    owner.addScroll(dx * scale, dy * scale);
}

fn keyDown(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const kc = event.msgSend(u16, "keyCode", .{});
    const flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const key = keymap.translateKeyCode(kc);
    owner.pushKey(@intFromEnum(key), .press, modsFromFlags(flags));

    const skip_chars = (flags & ak.NSEventModifierFlagCommand) != 0 or
        (flags & ak.NSEventModifierFlagControl) != 0;
    if (skip_chars) return;
    const characters = event.msgSend(objc.Object, "characters", .{});
    if (characters.value == null) return;
    const utf8: [*:0]const u8 = characters.msgSend([*:0]const u8, "UTF8String", .{});
    const slice = @import("std").mem.sliceTo(utf8, 0);
    ak.pushUtf8Chars(owner, slice, true);
}

fn keyUp(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const kc = event.msgSend(u16, "keyCode", .{});
    const flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const key = keymap.translateKeyCode(kc);
    owner.pushKey(@intFromEnum(key), .release, modsFromFlags(flags));
}

fn flagsChanged(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const kc = event.msgSend(u16, "keyCode", .{});
    const flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const key = keymap.translateKeyCode(kc);
    // Derive press vs release: check whether the modifier bit corresponding
    // to the changed key is currently set in modifierFlags.
    const key_bit: c_ulong = switch (kc) {
        0x37, 0x36 => ak.NSEventModifierFlagCommand,
        0x38, 0x3C => ak.NSEventModifierFlagShift,
        0x3A, 0x3D => ak.NSEventModifierFlagOption,
        0x3B, 0x3E => ak.NSEventModifierFlagControl,
        else => 0,
    };
    const action: window.KeyAction = if (key_bit != 0 and (flags & key_bit) != 0) .press else .release;
    owner.pushKey(@intFromEnum(key), action, modsFromFlags(flags));
}

fn windowShouldClose(self: c.id, _: c.SEL, _: c.id) callconv(.c) c.BOOL {
    const owner = ak.unwrapOwner(self) orelse return ak.boolParam(true);
    owner.markClosed();
    return ak.boolParam(false);
}

fn windowDidResize(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.markResized();
    owner.dispatchRefresh();
}

fn modsFromFlags(flags: c_ulong) window.Mods {
    return .{
        .shift = (flags & ak.NSEventModifierFlagShift) != 0,
        .ctrl = (flags & ak.NSEventModifierFlagControl) != 0,
        .super = (flags & ak.NSEventModifierFlagCommand) != 0,
    };
}
