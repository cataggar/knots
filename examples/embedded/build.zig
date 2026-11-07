const std = @import("std");
const knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const web_threads = b.option(bool, "web_threads", "Enable worker threads in the web embedded app.") orelse false;
    const gpu_backend = b.option(knots.GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse
        knots.defaultGpuBackend(target.result);

    const knots_dep = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .web_threads = web_threads,
        .gpu_backend = gpu_backend,
    });

    const executable = b.addExecutable(.{
        .name = "embedded",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "knots", .module = knots_dep.module("knots") },
                .{ .name = "knots-ui", .module = knots_dep.module("ui") },
                .{ .name = "knots-renderer", .module = knots_dep.module("renderer") },
                .{ .name = "knots-window", .module = knots_dep.module("window") },
            },
        }),
    });

    b.installArtifact(executable);

    if (target.result.cpu.arch.isWasm()) {
        executable.entry = .disabled;
        knots.installWeb(b, knots_dep, executable.root_module, executable, .{});
    } else {
        const run = b.addRunArtifact(executable);
        run.addPassthruArgs();
        b.step("run", "Run the bounded embedding example").dependOn(&run.step);
    }
}
