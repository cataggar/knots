const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const harfbuzz = b.dependency("harfbuzz", .{});
    const freetype = b.dependency("freetype", .{});

    const freetype_art = freetype.artifact("freetype");

    const c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = harfbuzz.path("src/hb-ft.h"),
    });
    c.addIncludePath(freetype_art.getEmittedIncludeTree());

    // Fluff it
    if (target.result.isMinGW() or target.result.isGnuLibC()) {
        c.defineCMacro("_FORTIFY_VA_ARG", "0");
        c.defineCMacro("_FORTIFY_SOURCE", "0");
    }

    const harfbuzz_mod = c.createModule();

    harfbuzz_mod.link_libcpp = true;
    harfbuzz_mod.addCSourceFile(.{
        .file = harfbuzz.path("src/harfbuzz.cc"),
        .language = .cpp,
    });
    harfbuzz_mod.addIncludePath(harfbuzz.path("src"));

    harfbuzz_mod.addCMacro("HAVE_FREETYPE", "1");
    harfbuzz_mod.linkLibrary(freetype_art);

    const mod = b.addModule("harfbuzz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    mod.addImport("harfbuzz", harfbuzz_mod);

    const mod_tests = b.addTest(.{ .root_module = mod });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
