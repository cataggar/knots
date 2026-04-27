const std = @import("std");
const c = @import("tracy");

pub inline fn zoneBegin(comptime name: [:0]const u8, comptime src: std.builtin.SourceLocation) c.TracyCZoneCtx {
    const loc = c.___tracy_source_location_data{
        .name = name.ptr,
        .function = src.fn_name.ptr,
        .file = src.file.ptr,
        .line = src.line,
        .color = 0,
    };
    return c.___tracy_emit_zone_begin(&loc, 1);
}

pub inline fn zoneEnd(ctx: c.TracyCZoneCtx) void {
    c.___tracy_emit_zone_end(ctx);
}

pub inline fn frameMark() void {
    c.___tracy_emit_frame_mark(null);
}

pub inline fn plotInt(comptime name: [:0]const u8, val: i64) void {
    c.___tracy_emit_plot_int(name.ptr, val);
}
