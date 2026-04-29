const objc = @import("objc");
const gpu = @import("gpu");
const window = @import("window");
const ak = @import("appkit.zig");
const classes = @import("classes.zig");

const c = ak.c;

var classes_registered: bool = false;
var KnotsView: objc.Class = undefined;
var KnotsDelegate: objc.Class = undefined;

pub const Backend = struct {
    ns_window: objc.Object,
    ns_view: objc.Object,
    delegate: objc.Object,
    backing_scale: f32 = 1.0,
    should_close: bool = false,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        self.ns_window.msgSend(void, "close", .{});
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        const owner_value = ak.wrapPointer(owner);
        self.ns_view.setInstanceVariable(ak.IVAR_OWNER, owner_value);
        self.delegate.setInstanceVariable(ak.IVAR_OWNER, owner_value);
        self.ns_window.msgSend(void, "makeFirstResponder:", .{self.ns_view});
    }

    pub fn setDropCallback(_: *Self, _: *window.Window) void {
        @panic("TODO");
    }

    pub fn pollEvents(_: *const Self) void {
        drainEventQueue(ak.sharedApp());
    }

    pub fn waitEvents(self: *const Self) void {
        const NSApp = ak.sharedApp();
        const NSDate = objc.getClass("NSDate").?;
        const distant_future = NSDate.msgSend(objc.Object, "distantFuture", .{});
        const event = NSApp.msgSend(
            objc.Object,
            "nextEventMatchingMask:untilDate:inMode:dequeue:",
            .{ ak.NSEventMaskAny, distant_future, ak.defaultRunLoopMode(), ak.boolParam(true) },
        );
        if (event.value != null) NSApp.msgSend(void, "sendEvent:", .{event});
        self.pollEvents();
    }

    pub fn postEmptyEvent(_: *const Self) void {
        const NSApp = ak.sharedApp();
        const NSEvent = objc.getClass("NSEvent").?;
        const zero = ak.NSPoint{ .x = 0, .y = 0 };
        const event = NSEvent.msgSend(
            objc.Object,
            "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
            .{
                ak.NSEventTypeApplicationDefined,
                zero,
                @as(c_ulong, 0),
                @as(f64, 0),
                @as(c_long, 0),
                @as(c.id, null),
                @as(c_short, 0),
                @as(c_long, 0),
                @as(c_long, 0),
            },
        );
        NSApp.msgSend(void, "postEvent:atStart:", .{ event, ak.boolParam(true) });
    }

    pub fn isOpen(self: *const Self) bool {
        return !self.should_close;
    }

    pub fn close(self: *Self) void {
        self.should_close = true;
    }

    pub fn getSize(self: *const Self) window.Size {
        const view_frame = self.ns_view.msgSend(ak.NSRect, "frame", .{});
        return .{
            .width = @intFromFloat(@round(view_frame.size.width)),
            .height = @intFromFloat(@round(view_frame.size.height)),
        };
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        const view_frame = self.ns_view.msgSend(ak.NSRect, "frame", .{});
        const backing = self.ns_view.msgSend(ak.NSRect, "convertRectToBacking:", .{view_frame});
        return .{
            .width = @intFromFloat(@round(backing.size.width)),
            .height = @intFromFloat(@round(backing.size.height)),
        };
    }

    pub fn computeContentScale(self: *const Self) f32 {
        return @floatCast(self.ns_window.msgSend(f64, "backingScaleFactor", .{}));
    }

    pub fn getCursorPos(self: *const Self) [2]f64 {
        const point_in_window = self.ns_window.msgSend(ak.NSPoint, "mouseLocationOutsideOfEventStream", .{});
        const point = self.ns_view.msgSend(ak.NSPoint, "convertPoint:fromView:", .{ point_in_window, @as(c.id, null) });
        return .{ point.x, point.y };
    }

    pub fn getNativeHandle(self: *const Self, _: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .macos = .{ .ns_window = @ptrCast(self.ns_window.value) } };
    }

    pub fn setCursorVisible(_: *const Self, _: bool) void {
        @panic("TODO");
    }

    pub fn setDisplayMode(_: *Self, _: window.DisplayMode) void {
        @panic("TODO");
    }

    pub fn applyEmscriptenSize(_: *Self, _: window.ResizeEvent) void {
        @compileError("emscripten not supported with cocoa backend");
    }
};

pub fn init(cfg: window.Config) !Backend {
    if (!classes_registered) {
        const registered = try classes.registerClasses();
        KnotsView = registered.view;
        KnotsDelegate = registered.delegate;
        classes_registered = true;
    }

    const NSApp = ak.sharedApp();
    NSApp.msgSend(void, "setActivationPolicy:", .{ak.NSApplicationActivationPolicyRegular});
    NSApp.msgSend(void, "finishLaunching", .{});

    const NSWindowClass = objc.getClass("NSWindow").?;
    const style: c_ulong = ak.NSWindowStyleMaskTitled | ak.NSWindowStyleMaskClosable |
        ak.NSWindowStyleMaskMiniaturizable | (if (cfg.resizable) ak.NSWindowStyleMaskResizable else 0);
    const frame = ak.NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(cfg.width), .height = @floatFromInt(cfg.height) },
    };
    const ns_window = NSWindowClass
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(
        objc.Object,
        "initWithContentRect:styleMask:backing:defer:",
        .{ frame, style, ak.NSBackingStoreBuffered, ak.boolParam(false) },
    );
    ns_window.msgSend(void, "setTitle:", .{ak.nsstring(cfg.title)});
    ns_window.msgSend(void, "setReleasedWhenClosed:", .{ak.boolParam(false)});
    ns_window.msgSend(void, "center", .{});

    const view = KnotsView
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    ns_window.msgSend(void, "setContentView:", .{view});

    const delegate = KnotsDelegate
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    ns_window.msgSend(void, "setDelegate:", .{delegate});

    NSApp.msgSend(void, "activateIgnoringOtherApps:", .{ak.boolParam(true)});
    ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(c.id, null)});

    drainEventQueue(NSApp);

    return .{
        .ns_window = ns_window,
        .ns_view = view,
        .delegate = delegate,
        .backing_scale = @floatCast(ns_window.msgSend(f64, "backingScaleFactor", .{})),
    };
}

fn drainEventQueue(NSApp: objc.Object) void {
    const NSDate = objc.getClass("NSDate").?;
    const distant_past = NSDate.msgSend(objc.Object, "distantPast", .{});
    while (true) {
        const event = NSApp.msgSend(
            objc.Object,
            "nextEventMatchingMask:untilDate:inMode:dequeue:",
            .{ ak.NSEventMaskAny, distant_past, ak.defaultRunLoopMode(), ak.boolParam(true) },
        );
        if (event.value == null) break;
        NSApp.msgSend(void, "sendEvent:", .{event});
    }
}
