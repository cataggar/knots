const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const harfbuzz = b.dependency("harfbuzz", .{});
    const freetype = b.dependency("freetype", .{});
    const is_emscripten = target.result.os.tag == .emscripten;

    const c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = harfbuzz.path("src/hb-ft.h"),
    });
    c.addIncludePath(freetype.namedLazyPath("include"));

    if (target.result.isMinGW() or target.result.isGnuLibC()) {
        c.defineCMacro("_FORTIFY_VA_ARG", "0");
        c.defineCMacro("_FORTIFY_SOURCE", "0");
    }

    if (is_emscripten) {
        const emsdk = b.graph.environ_map.get("EMSDK") orelse
            @panic("EMSDK environment variable not set");
        const sysroot_include = b.pathJoin(&.{
            emsdk, "upstream/emscripten/cache/sysroot/include",
        });
        c.addSystemIncludePath(.{ .cwd_relative = sysroot_include });
    }

    const harfbuzz_mod = c.createModule();
    harfbuzz_mod.link_libcpp = true;
    harfbuzz_mod.addCSourceFile(.{
        .file = harfbuzz.path("src/harfbuzz.cc"),
        .language = .cpp,
        .flags = if (is_emscripten) &.{"-fno-sanitize=undefined"} else &.{},
    });
    harfbuzz_mod.addIncludePath(harfbuzz.path("src"));
    harfbuzz_mod.addIncludePath(freetype.namedLazyPath("include"));
    harfbuzz_mod.addCMacro("HAVE_FREETYPE", "1");

    if (is_emscripten) {
        harfbuzz_mod.addCMacro("HAVE_PTHREAD", "0");
        harfbuzz_mod.addCMacro("HB_NO_MT", "1");
        harfbuzz_mod.addCMacro("NDEBUG", "1");

        const emsdk = b.graph.environ_map.get("EMSDK") orelse
            @panic("EMSDK environment variable not set");
        const sysroot_include = b.pathJoin(&.{
            emsdk, "upstream/emscripten/cache/sysroot/include",
        });
        harfbuzz_mod.addSystemIncludePath(.{ .cwd_relative = sysroot_include });
    }

    const mod = b.addModule("harfbuzz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    mod.addImport("harfbuzz", harfbuzz_mod);

    if (!is_emscripten) {
        const mod_tests = b.addTest(.{ .root_module = mod });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
    }
}
