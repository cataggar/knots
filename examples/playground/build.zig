const std = @import("std");
const GPUBackend = @import("knots").GPUBackend;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const is_wasm = target.result.os.tag == .freestanding and target.result.cpu.arch == .wasm32;

    const backends: []const GPUBackend = if (target.result.os.tag == .emscripten)
        &[_]GPUBackend{.wgpu}
    else if (is_wasm)
        &[_]GPUBackend{.webgpu_js}
    else
        &[_]GPUBackend{ .wgpu, .vulkan };

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .gpu_backends = backends,
    });

    const mod = b.addModule("playground", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
    });

    if (is_wasm) {
        buildWasm(b, target, optimize, mod);
        return;
    }

    const exe_mod = b.createModule(.{
        .root_source_file = switch (target.result.os.tag) {
            .emscripten => b.path("src/main_web.zig"),
            else => b.path("src/main.zig"),
        },
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "playground", .module = mod }},
    });

    if (target.result.os.tag == .emscripten) {
        buildEmscripten(b, target, optimize, exe_mod);
        return;
    }

    const exe = b.addExecutable(.{
        .name = "playground",
        .root_module = exe_mod,
    });

    if (optimize != .Debug) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the playground app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn buildWasm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, playground_mod: *std.Build.Module) void {
    const zjb = b.dependency("zjb", .{});

    const exe = b.addExecutable(.{
        .name = "playground",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main_wasm.zig"),
            .imports = &.{
                .{ .name = "playground", .module = playground_mod },
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

    const run_step = b.step("run", "Serve the playground wasm build on http://localhost:8000/");
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory" });
    serve.addArg(b.getInstallPath(dir, ""));
    serve.step.dependOn(b.getInstallStep());
    run_step.dependOn(&serve.step);
}

fn buildEmscripten(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root_module: *std.Build.Module) void {
    const emcc_path =
        b.option([]const u8, "emcc", "Path to emcc. Defaults to searching PATH.") orelse b.findProgram(&.{"emcc"}, &.{}) catch
            @panic("emcc not found. Put emcc on PATH or pass -Demcc=/path/to/emcc.");

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "playground",
        .root_module = root_module,
    });
    lib.entry = .disabled;

    const emcc = b.addSystemCommand(&.{emcc_path});
    emcc.addArtifactArg(lib);
    emcc.addArg("-o");
    const html_out = emcc.addOutputFileArg("playground.html");

    var args = std.ArrayList([]const u8).initCapacity(b.allocator, 32) catch @panic("OOM");
    defer args.deinit(b.allocator);
    args.appendSliceAssumeCapacity(&.{
        "--use-port=emdawnwebgpu",
        "-sUSE_GLFW=3",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sEXIT_RUNTIME=0",
        "-sASYNCIFY",
        "-sASYNCIFY_STACK_SIZE=65536",
        "-sSTACK_SIZE=4194304",
        "-sINITIAL_MEMORY=33554432",
    });
    if (optimize == .Debug) args.appendAssumeCapacity("-sASSERTIONS=2");
    if (target.result.cpu.arch == .wasm64) args.appendAssumeCapacity("-sMEMORY64");
    args.appendAssumeCapacity("--shell-file");

    emcc.addArgs(args.items);
    emcc.addFileArg(b.path("src/shell.html"));

    const install_html = b.addInstallFileWithDir(html_out, .{ .custom = "web" }, "index.html");
    const install_js = b.addInstallFileWithDir(html_out.dirname().path(b, "playground.js"), .{ .custom = "web" }, "playground.js");
    const install_wasm = b.addInstallFileWithDir(html_out.dirname().path(b, "playground.wasm"), .{ .custom = "web" }, "playground.wasm");

    b.getInstallStep().dependOn(&install_html.step);
    b.getInstallStep().dependOn(&install_js.step);
    b.getInstallStep().dependOn(&install_wasm.step);

    const serve_step = b.step("run", "Serve the playground on http://localhost:8000/");
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory" });
    serve.addArg(b.getInstallPath(.{ .custom = "web" }, ""));
    serve.step.dependOn(b.getInstallStep());
    serve_step.dependOn(&serve.step);
}
