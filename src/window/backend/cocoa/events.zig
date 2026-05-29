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
    .{ "mouseDown:", mouseLeftDown },
    .{ "mouseUp:", mouseLeftUp },
    .{ "mouseMoved:", mouseMoved },
    .{ "mouseDragged:", mouseDragged },
    .{ "rightMouseDown:", mouseRightDown },
    .{ "rightMouseUp:", mouseRightUp },
    .{ "rightMouseDragged:", rightMouseDragged },
    .{ "scrollWheel:", scrollWheel },
};

pub const keyboard_methods = .{
    .{ "keyDown:", keyDown },
    .{ "keyUp:", keyUp },
    .{ "flagsChanged:", flagsChanged },
};

pub const drag_methods = .{
    .{ "draggingEntered:", draggingEntered },
    .{ "performDragOperation:", performDragOperation },
};

pub const delegate_methods = .{
    .{ "windowShouldClose:", windowShouldClose },
    .{ "windowWillStartLiveResize:", windowWillStartLiveResize },
    .{ "windowDidResize:", windowDidResize },
    .{ "windowDidEndLiveResize:", windowDidEndLiveResize },
    .{ "liveResizeTick:", liveResizeTick },
};

fn acceptsFirstResponder(_: c.id, _: c.SEL) callconv(.c) c.BOOL {
    return ak.boolParam(true);
}

fn isFlipped(_: c.id, _: c.SEL) callconv(.c) c.BOOL {
    return ak.boolParam(true);
}

fn eventPos(self: c.id, event_id: c.id) [2]f64 {
    const view = objc.Object.fromId(self);
    const event = objc.Object.fromId(event_id);
    const point_in_window = event.msgSend(ak.NSPoint, "locationInWindow", .{});
    const point = view.msgSend(ak.NSPoint, "convertPoint:fromView:", .{ point_in_window, @as(c.id, null) });
    return .{ point.x, point.y };
}

fn mouseLeftDown(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.left, true, eventPos(self, event_id));
}

fn mouseLeftUp(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.left, false, eventPos(self, event_id));
}

fn mouseMoved(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
}

fn mouseDragged(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
}

fn mouseRightDown(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.right, true, eventPos(self, event_id));
}

fn mouseRightUp(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.right, false, eventPos(self, event_id));
}

fn rightMouseDragged(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
}

fn scrollWheel(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
    const event = objc.Object.fromId(event_id);
    const dx = event.msgSend(f64, "scrollingDeltaX", .{});
    const dy = event.msgSend(f64, "scrollingDeltaY", .{});
    const precise = event.msgSend(bool, "hasPreciseScrollingDeltas", .{});
    if (precise)
        owner.addScrollPixels(dx, -dy)
    else
        owner.addScrollLines(dx, -dy);
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

fn draggingEntered(_: c.id, _: c.SEL, _: c.id) callconv(.c) c_ulong {
    return ak.NSDragOperationCopy;
}

fn performDragOperation(self: c.id, _: c.SEL, sender_id: c.id) callconv(.c) c.BOOL {
    const owner = ak.unwrapOwner(self) orelse return ak.boolParam(false);
    const sender = objc.Object.fromId(sender_id);
    const pasteboard = sender.msgSend(objc.Object, "draggingPasteboard", .{});
    if (pasteboard.value == null) return ak.boolParam(false);

    const NSURL = objc.getClass("NSURL").?;
    const NSArray = objc.getClass("NSArray").?;
    const classes_array = NSArray.msgSend(objc.Object, "arrayWithObject:", .{objc.Object{ .value = @ptrCast(@alignCast(NSURL.value)) }});
    const urls = pasteboard.msgSend(objc.Object, "readObjectsForClasses:options:", .{ classes_array, @as(c.id, null) });
    if (urls.value == null) return ak.boolParam(false);

    const be = &owner.backend;
    const count = urls.msgSend(c_ulong, "count", .{});
    const n: usize = @min(@as(usize, count), be.drop_paths_buf.len);
    for (0..n) |i| {
        const url = urls.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, i)});
        const c_path = url.msgSend([*:0]const u8, "fileSystemRepresentation", .{});
        const slice = @import("std").mem.sliceTo(c_path, 0);
        const len = @min(slice.len, be.drop_paths_buf[i].len);
        @memcpy(be.drop_paths_buf[i][0..len], slice[0..len]);
        be.drop_slices[i] = be.drop_paths_buf[i][0..len];
    }
    owner.markDropped(n);
    return ak.boolParam(true);
}

fn windowShouldClose(self: c.id, _: c.SEL, _: c.id) callconv(.c) c.BOOL {
    const owner = ak.unwrapOwner(self) orelse return ak.boolParam(true);
    owner.markClosed();
    return ak.boolParam(false);
}

fn windowWillStartLiveResize(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    if (owner.backend.live_resize_timer) |old| {
        old.msgSend(void, "invalidate", .{});
        old.msgSend(void, "release", .{});
        owner.backend.live_resize_timer = null;
    }

    const NSTimer = objc.getClass("NSTimer").?;
    const NSRunLoop = objc.getClass("NSRunLoop").?;
    const selector = c.sel_registerName("liveResizeTick:").?;
    const timer = NSTimer.msgSend(
        objc.Object,
        "timerWithTimeInterval:target:selector:userInfo:repeats:",
        .{
            window.live_resize_tick_seconds,
            objc.Object.fromId(self),
            selector,
            @as(c.id, null),
            ak.boolParam(true),
        },
    );
    const run_loop = NSRunLoop.msgSend(objc.Object, "currentRunLoop", .{});
    run_loop.msgSend(void, "addTimer:forMode:", .{ timer, ak.eventTrackingRunLoopMode() });
    _ = timer.msgSend(objc.Object, "retain", .{});
    owner.backend.live_resize_timer = timer;
}

fn windowDidResize(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.markResized();
    owner.requestFrame();
}

fn windowDidEndLiveResize(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    if (owner.backend.live_resize_timer) |timer| {
        timer.msgSend(void, "invalidate", .{});
        timer.msgSend(void, "release", .{});
        owner.backend.live_resize_timer = null;
    }
    owner.markResized();
    owner.stepFrame();
}

fn liveResizeTick(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    if (!owner.resized) return;
    owner.stepFrame();
}

fn modsFromFlags(flags: c_ulong) window.Mods {
    return .{
        .shift = (flags & ak.NSEventModifierFlagShift) != 0,
        .ctrl = (flags & ak.NSEventModifierFlagControl) != 0,
        .super = (flags & ak.NSEventModifierFlagCommand) != 0,
    };
}
