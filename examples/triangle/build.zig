const std = @import("std");
const knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const web_threads = b.option(bool, "web_threads", "Enable worker threads in the web triangle app.") orelse false;
    const gpu_backend = b.option(knots.GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse
        knots.defaultGpuBackend(target.result);

    const knots_dep = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .web_threads = web_threads,
        .gpu_backend = gpu_backend,
    });

    const mod = b.addModule("triangle", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "knots", .module = knots_dep.module("knots") },
            .{ .name = "knots-ui", .module = knots_dep.module("ui") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "triangle",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "knots", .module = knots_dep.module("knots") },
                .{ .name = "triangle", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    if (target.result.cpu.arch.isWasm()) {
        exe.entry = .disabled;
        knots.installWeb(b, knots_dep, exe.root_module, exe, .{});
    } else {
        const run_step = b.step("run", "Run the triangle app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
    }
}
