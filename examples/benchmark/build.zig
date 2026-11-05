const std = @import("std");
const knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_wasm = target.result.cpu.arch.isWasm();

    const tracy_dep = b.dependency("tracy", .{});

    const tracy_lib = if (!is_wasm) blk: {
        const lib = b.addLibrary(.{
            .name = "tracy",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        lib.root_module.addCSourceFile(.{
            .file = tracy_dep.path("public/TracyClient.cpp"),
            .flags = &.{
                "-DTRACY_ENABLE",
                "-std=c++17",
                "-fno-sanitize=all",
            },
        });
        switch (target.result.os.tag) {
            .windows => {
                lib.root_module.linkSystemLibrary("dbghelp", .{});
                lib.root_module.linkSystemLibrary("ws2_32", .{});
            },
            else => {},
        }
        lib.root_module.link_libcpp = true;
        break :blk lib;
    } else null;

    const tracy_c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = tracy_dep.path("public/tracy/TracyC.h"),
    });
    tracy_c.defineCMacro("TRACY_ENABLE", null);
    const tracy_mod = tracy_c.createModule();
    if (is_wasm) tracy_mod.link_libc = false;

    const web_threads = b.option(bool, "web_threads", "Enable worker threads in the web benchmark app.") orelse false;
    const gpu_backend = b.option(knots.GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse
        knots.defaultGpuBackend(target.result);

    const knots_dep = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .web_threads = web_threads,
        .gpu_backend = gpu_backend,
    });

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "knots", .module = knots_dep.module("knots") },
                .{ .name = "knots-ui", .module = knots_dep.module("ui") },
                .{ .name = "tracy", .module = tracy_mod },
            },
        }),
    });
    if (tracy_lib) |lib| exe.root_module.linkLibrary(lib);
    if (is_wasm) {
        exe.entry = .disabled;
        knots.installWeb(b, knots_dep, exe.root_module, exe, .{});
    }

    if (target.result.os.tag == .windows) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the benchmark app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
}
