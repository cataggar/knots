const builtin = @import("builtin");
const Context = @import("gpu").Context;
const std = @import("std");

pub const Backend = enum {
    vulkan,
    wgpu,

    pub const available = @import("config").gpu_backends;

    pub fn availableSlice() []const Backend {
        const backends = comptime blk: {
            var buf: [std.meta.fields(Backend).len]Backend = undefined;
            var i: usize = 0;
            for (std.meta.fields(Backend)) |field| {
                if (@field(available, field.name)) {
                    buf[i] = @enumFromInt(field.value);
                    i += 1;
                }
            }
            break :blk buf[0..i].*;
        };
        return &backends;
    }

    pub fn isAvailable(self: Backend) bool {
        inline for (comptime availableSlice()) |be| {
            if (be == self) return true;
        }

        return false;
    }

    pub fn preferred() Backend {
        comptime {
            switch (builtin.os.tag) {
                .macos => {
                    if (available.wgpu) return .wgpu;
                    if (available.vulkan) return .vulkan;
                },
                .windows => {
                    if (available.vulkan) return .vulkan;
                    if (available.wgpu) return .wgpu;
                },
                .linux => {
                    if (available.vulkan) return .vulkan;
                    if (available.wgpu) return .wgpu;
                },
                else => @compileError("Unsupported OS: " ++ builtin.os.tag),
            }

            @compileError("No gpu backends available.");
        }
    }

    pub fn init(self: Backend, allocator: std.mem.Allocator, window_handle: Context.WindowHandle, cfg: Context.Config) !Context {
        inline for (@typeInfo(Backend).@"enum".fields) |field| {
            if (self == @as(Backend, @enumFromInt(field.value))) {
                if (!@field(available, field.name)) return error.BackendUnavailable;
                const module = switch (@as(Backend, @enumFromInt(field.value))) {
                    .wgpu => @import("gpu_wgpu"),
                    .vulkan => @import("gpu_vulkan"),
                };
                return module.init(allocator, window_handle, cfg);
            }
        }
        unreachable;
    }
};
