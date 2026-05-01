pub const EmscriptenUiEvent = extern struct {
    detail: c_long,
    documentBodyClientWidth: c_int,
    documentBodyClientHeight: c_int,
    windowInnerWidth: c_int,
    windowInnerHeight: c_int,
    windowOuterWidth: c_int,
    windowOuterHeight: c_int,
    scrollTop: c_int,
    scrollLeft: c_int,
};

pub const EmscriptenUiCallback = *const fn (event_type: c_int, ev: *const EmscriptenUiEvent, user_data: ?*anyopaque) callconv(.c) c_int;

pub extern fn emscripten_set_resize_callback_on_thread(
    target: [*:0]const u8,
    user_data: ?*anyopaque,
    use_capture: bool,
    cb: ?EmscriptenUiCallback,
    thread: c_int,
) c_int;

pub extern fn emscripten_get_element_css_size(target: [*:0]const u8, w: *f64, h: *f64) c_int;
pub extern fn emscripten_set_canvas_element_size(target: [*:0]const u8, w: c_int, h: c_int) c_int;

pub const EMSCRIPTEN_EVENT_TARGET_WINDOW: [*:0]const u8 = "2";
pub const EMSCRIPTEN_EVENT_TARGET_DOCUMENT: [*:0]const u8 = "1";

const std = @import("std");

pub const CanvasSize = struct {
    logical_w: u32,
    logical_h: u32,
    physical_w: u32,
    physical_h: u32,
    content_scale: f32,
};

/// Read the canvas's CSS size, scale by devicePixelRatio, and push the
/// resulting physical pixel size back to the canvas element. Returns the
/// computed sizes so the caller can construct a ResizeEvent without taking a
/// dependency on the public window types.
pub fn applyCanvasSize(selector: [:0]const u8, fallback_w: u32, fallback_h: u32) CanvasSize {
    var css_w: f64 = 0;
    var css_h: f64 = 0;
    _ = emscripten_get_element_css_size(selector.ptr, &css_w, &css_h);
    if (css_w <= 0 or css_h <= 0) {
        css_w = @floatFromInt(fallback_w);
        css_h = @floatFromInt(fallback_h);
    }
    const dpr = std.os.emscripten.emscripten_get_device_pixel_ratio();
    const px_w: c_int = @intFromFloat(@round(css_w * dpr));
    const px_h: c_int = @intFromFloat(@round(css_h * dpr));
    _ = emscripten_set_canvas_element_size(selector.ptr, px_w, px_h);
    return .{
        .logical_w = @intFromFloat(@round(css_w)),
        .logical_h = @intFromFloat(@round(css_h)),
        .physical_w = @intCast(px_w),
        .physical_h = @intCast(px_h),
        .content_scale = @floatCast(dpr),
    };
}
