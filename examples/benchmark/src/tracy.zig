const std = @import("std");
const builtin = @import("builtin");
const c = @import("tracy");

const has_tracy = @hasDecl(c, "___tracy_emit_zone_begin");

comptime {
    if (builtin.cpu.arch.isWasm() and has_tracy) {
        const Stubs = struct {
            fn emitZoneBegin(_: [*c]const c.___tracy_source_location_data, active: i32) callconv(.c) c.TracyCZoneCtx {
                return .{ .id = 0, .active = active };
            }
            fn emitZoneEnd(_: c.TracyCZoneCtx) callconv(.c) void {}
            fn emitFrameMark(_: [*c]const u8) callconv(.c) void {}
            fn emitPlotInt(_: [*c]const u8, _: i64) callconv(.c) void {}
        };
        @export(&Stubs.emitZoneBegin, .{ .name = "___tracy_emit_zone_begin" });
        @export(&Stubs.emitZoneEnd, .{ .name = "___tracy_emit_zone_end" });
        @export(&Stubs.emitFrameMark, .{ .name = "___tracy_emit_frame_mark" });
        @export(&Stubs.emitPlotInt, .{ .name = "___tracy_emit_plot_int" });
    }
}

pub inline fn zoneBegin(comptime name: [:0]const u8, comptime src: std.builtin.SourceLocation) c.TracyCZoneCtx {
    if (!has_tracy) return null;
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
    if (!has_tracy) return;
    c.___tracy_emit_zone_end(ctx);
}

pub inline fn frameMark() void {
    if (!has_tracy) return;
    c.___tracy_emit_frame_mark(null);
}

pub inline fn plotInt(comptime name: [:0]const u8, val: i64) void {
    if (!has_tracy) return;
    c.___tracy_emit_plot_int(name.ptr, val);
}
