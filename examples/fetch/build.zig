const std = @import("std");
const GPUBackend = @import("knots").GPUBackend;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .gpu_backends = &[_]GPUBackend{.wgpu},
    });

    const exe = b.addExecutable(.{
        .name = "fetch",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
        }),
    });

    if (optimize != .Debug) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the fetch app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
}
