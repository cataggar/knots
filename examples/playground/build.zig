const std = @import("std");
const knots = @import("knots");

pub fn build(b: *std.Build) void {
    const wasm64 = b.option(bool, "wasm64", "Use 64-bit WebAssembly (wasm64) when building for Wasm (default: false).") orelse false;
    var target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    if (wasm64 and target.result.cpu.arch == .wasm32) {
        var query = target.query;
        query.cpu_arch = .wasm64;
        target = b.resolveTargetQuery(query);
    }
    const optimize = b.standardOptimizeOption(.{});

    const web_threads = b.option(bool, "web_threads", "Enable worker threads in the web playground.") orelse true;
    // Decides the shader language the GPU demo needs: WGSL for WebGPU, GLSL ES 3.00 for WebGL2, SPIR-V for Vulkan.
    const gpu_backend = b.option(knots.GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse
        knots.defaultGpuBackend(target.result);

    const knots_dep = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .web_threads = web_threads,
        .backend = knots.Backend.fromGpu(gpu_backend),
        .wasm64 = wasm64,
    });

    const exe = buildExecutable(b, target, optimize, gpu_backend, knots_dep, "playground");
    b.installArtifact(exe);

    const components_step = b.step("components", "Build standalone Wasm visual components");
    const install_components = addVisualComponents(b, optimize);
    if (install_components) |comp_step| {
        components_step.dependOn(comp_step);
    }

    const test_step = b.step("test", "Run playground unit tests");
    const inspector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/component_inspector.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_inspector_tests = b.addRunArtifact(inspector_tests);
    if (install_components) |comp_step| {
        run_inspector_tests.step.dependOn(comp_step);
    }
    test_step.dependOn(&run_inspector_tests.step);

    const run = if (target.result.cpu.arch.isWasm()) blk: {
        exe.entry = .disabled;
        knots.installWeb(b, knots_dep, exe.root_module, exe, .{ .index_html = b.path("src/shell_wasm.html") });
        const install_comp_host = b.addInstallFileWithDir(b.path("src/component-host.js"), .{ .custom = "web" }, "component-host.js");
        b.getInstallStep().dependOn(&install_comp_host.step);
        const install_wit = b.addInstallFileWithDir(b.path("wit/visual.wit"), .{ .custom = "web/components" }, "visual.wit");
        b.getInstallStep().dependOn(&install_wit.step);
        if (install_components) |comp_step| {
            b.getInstallStep().dependOn(comp_step);
        }
        const run = webServer(b, web_threads, "zig-out/web");
        run.step.dependOn(b.getInstallStep());
        break :blk run;
    } else blk: {
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        break :blk run;
    };

    b.step("run", "Run the standalone browser playground").dependOn(&run.step);

    const dev = b.step("dev", "Rebuild and restart the app on every save");
    knots.addDevWatcher(b, knots_dep, dev, exe, .{});
}

fn webServer(b: *std.Build, web_threads: bool, directory: []const u8) *std.Build.Step.Run {
    if (web_threads) {
        const command = b.addSystemCommand(&.{"python3"});
        command.addFileArg(b.path("serve.py"));
        command.addArgs(&.{ "--port", "8000", "--directory", directory });
        return command;
    }

    return b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory", directory });
}

fn buildExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gpu_backend: knots.GPUBackend, knots_dep: *std.Build.Dependency, name: []const u8) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "knots", .module = knots_dep.module("knots") },
            .{ .name = "knots-ui", .module = knots_dep.module("ui") },
            .{ .name = "renderer", .module = knots_dep.module("renderer") },
        },
    });
    if (target.result.cpu.arch.isWasm()) {
        mod.addImport("js-bridge", knots_dep.module("js-bridge"));
    }
    mod.addAnonymousImport("visual_wit", .{ .root_source_file = b.path("wit/visual.wit") });
    // The GPU demo's shader, in the language of the backend.
    switch (gpu_backend) {
        .webgpu => {
            mod.addAnonymousImport("gpu_shader_wgsl", .{ .root_source_file = b.path("src/shaders/gpu_shader.wgsl") });
            mod.addAnonymousImport("gpu_shader_vert_glsl", .{ .root_source_file = b.path("src/shaders/gpu_shader.vert.glsl") });
            mod.addAnonymousImport("gpu_shader_frag_glsl", .{ .root_source_file = b.path("src/shaders/gpu_shader.frag.glsl") });
        },
        .webgl2 => {
            mod.addAnonymousImport("gpu_shader_vert_glsl", .{ .root_source_file = b.path("src/shaders/gpu_shader.vert.glsl") });
            mod.addAnonymousImport("gpu_shader_frag_glsl", .{ .root_source_file = b.path("src/shaders/gpu_shader.frag.glsl") });
        },
        .vulkan => {
            mod.addAnonymousImport("gpu_shader_vertex", .{ .root_source_file = knots.addSpirV(knots_dep, optimize, b.path("src/shaders/gpu_shader_vertex.zig")) });
            mod.addAnonymousImport("gpu_shader_fragment", .{ .root_source_file = knots.addSpirV(knots_dep, optimize, b.path("src/shaders/gpu_shader_fragment.zig")) });
        },
    }
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

const component_export_symbol_names = [_][]const u8{
    "cabi_realloc",
    "knots:visual/source@0.1.0#describe",
    "cabi_post_knots:visual/source@0.1.0#describe",
    "knots:visual/source@0.1.0#render-vector",
    "cabi_post_knots:visual/source@0.1.0#render-vector",
    "knots:visual/source@0.1.0#render-pixels",
    "cabi_post_knots:visual/source@0.1.0#render-pixels",
};

const VisualComponentSpec = struct {
    out_name: []const u8,
    src_file: []const u8,
    wit_world: []const u8,
};

const visual_component_specs = [_]VisualComponentSpec{
    .{ .out_name = "harmonograph", .src_file = "components/harmonograph.zig", .wit_world = "visual-generator" },
    .{ .out_name = "boids-flock", .src_file = "components/boids_flock.zig", .wit_world = "visual-generator" },
    .{ .out_name = "plasma-sdf", .src_file = "components/plasma_sdf.zig", .wit_world = "visual-generator" },
    .{ .out_name = "kaleidoscope-effect", .src_file = "components/kaleidoscope_effect.zig", .wit_world = "visual-effect" },
    .{ .out_name = "chromatic-prism-effect", .src_file = "components/chromatic_prism_effect.zig", .wit_world = "visual-effect" },
};

fn addVisualComponents(b: *std.Build, optimize: std.builtin.OptimizeMode) ?*std.Build.Step {
    if (comptime !(@hasField(std.Target.Os.Tag, "wasip2") and @hasField(std.Build.Step.Compile, "wit_path"))) {
        return null;
    }

    var cpu_features_add = std.Target.Cpu.Feature.Set.empty;
    cpu_features_add.addFeature(@backingInt(std.Target.wasm.Feature.simd128));
    const comp_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasip2,
        .cpu_features_add = cpu_features_add,
    });

    const group = b.step("install-visual-components", "Install standalone Wasm Component plugins");
    for (visual_component_specs) |spec| {
        const sdk_mod = b.createModule(.{
            .root_source_file = b.path("components/sdk.zig"),
            .target = comp_target,
            .optimize = optimize,
            .single_threaded = true,
        });
        const comp_mod = b.createModule(.{
            .root_source_file = b.path(spec.src_file),
            .target = comp_target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "sdk", .module = sdk_mod },
            },
        });
        comp_mod.export_symbol_names = &component_export_symbol_names;

        const comp_exe = b.addExecutable(.{
            .name = spec.out_name,
            .root_module = comp_mod,
        });
        comp_exe.entry = .disabled;
        comp_exe.wasi_exec_model = .reactor;
        comp_exe.export_memory = true;
        comp_exe.import_symbols = true;
        comp_exe.stack_size = 128 * 1024;
        comp_exe.wit_path = b.path("wit/visual.wit");
        comp_exe.wit_world = spec.wit_world;

        const out_filename = b.fmt("{s}.wasm", .{spec.out_name});
        const install_comp = b.addInstallFileWithDir(comp_exe.getEmittedBin(), .{ .custom = "web/components" }, out_filename);
        group.dependOn(&install_comp.step);
    }
    return group;
}
