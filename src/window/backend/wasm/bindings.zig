const std = @import("std");
const zjb = @import("zjb");

pub const CanvasSize = struct {
    logical_w: u32,
    logical_h: u32,
    physical_w: u32,
    physical_h: u32,
    content_scale: f32,
};

var text_encoder_handle: ?zjb.Handle = null;

/// A single, never-released `TextEncoder` instance, lazily created on first
/// use and kept for the program's lifetime (mirrors how zjb memoizes
/// `zjb.global`/`zjb.constString` handles).
fn textEncoder() zjb.Handle {
    if (text_encoder_handle) |h| return h;
    const h = zjb.global("TextEncoder").new(.{});
    text_encoder_handle = h;
    return h;
}

/// Copies a JS string's UTF-8 bytes into `buf`, returning the written slice.
/// Truncates if the string doesn't fit in `buf`; only used for short strings
/// (KeyboardEvent.code/.key, clipboard text, canvas selectors).
pub fn readJsStringUtf8(handle: zjb.Handle, buf: []u8) []const u8 {
    const view = zjb.u8ArrayView(buf);
    defer view.release();
    const result = textEncoder().call("encodeInto", .{ handle, view }, zjb.Handle);
    defer result.release();
    const written: usize = @intFromFloat(result.get("written", f64));
    return buf[0..written];
}

/// Reads the canvas's CSS size, scales by devicePixelRatio, and pushes the
/// resulting physical pixel size back to the canvas element. Returns the
/// computed sizes so the caller can construct a ResizeEvent without taking a
/// dependency on the public window types. Mirrors
/// `emscripten/bindings.zig`'s `applyCanvasSize`.
pub fn applyCanvasSize(canvas: zjb.Handle, fallback_w: u32, fallback_h: u32) CanvasSize {
    const rect = canvas.call("getBoundingClientRect", .{}, zjb.Handle);
    defer rect.release();

    var css_w = rect.get("width", f64);
    var css_h = rect.get("height", f64);
    if (css_w <= 0 or css_h <= 0) {
        css_w = @floatFromInt(fallback_w);
        css_h = @floatFromInt(fallback_h);
    }

    const dpr = zjb.global("window").get("devicePixelRatio", f64);
    const px_w: i32 = @intFromFloat(@round(css_w * dpr));
    const px_h: i32 = @intFromFloat(@round(css_h * dpr));
    canvas.set("width", px_w);
    canvas.set("height", px_h);

    return .{
        .logical_w = @intFromFloat(@round(css_w)),
        .logical_h = @intFromFloat(@round(css_h)),
        .physical_w = @intCast(px_w),
        .physical_h = @intCast(px_h),
        .content_scale = @floatCast(dpr),
    };
}
