const std = @import("std");
const GPUBackend = @import("knots").GPUBackend;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const is_wasm = target.result.os.tag == .freestanding and target.result.cpu.arch == .wasm32;
    const gpu_backends: []const GPUBackend = if (is_wasm)
        &[_]GPUBackend{.webgpu_js}
    else
        &[_]GPUBackend{ .wgpu, .vulkan };

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .gpu_backends = gpu_backends,
    });

    if (is_wasm) {
        buildWasm(b, target, optimize, knots);
        return;
    }

    const exe = b.addExecutable(.{
        .name = "playground",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
        }),
    });

    if (optimize != .Debug) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the triangle app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

fn buildWasm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, knots: *std.Build.Dependency) void {
    const zjb = b.dependency("zjb", .{});

    const exe = b.addExecutable(.{
        .name = "triangle",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main_wasm.zig"),
            .imports = &.{
                .{ .name = "knots", .module = knots.module("knots") },
                .{ .name = "zjb", .module = zjb.module("zjb") },
            },
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    const extract = b.addRunArtifact(zjb.artifact("generate_js"));
    const extract_out = extract.addOutputFileArg("zjb_extract.js");
    extract.addArg("Zjb");
    extract.addArtifactArg(exe);

    const dir: std.Build.InstallDir = .prefix;
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = dir } }).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(extract_out, dir, "zjb_extract.js").step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("static"),
        .install_dir = dir,
        .install_subdir = "",
    }).step);

    const run_step = b.step("run", "Serve the triangle wasm build on http://localhost:8000/");
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory" });
    serve.addArg(b.getInstallPath(dir, ""));
    serve.step.dependOn(b.getInstallStep());
    run_step.dependOn(&serve.step);
}

