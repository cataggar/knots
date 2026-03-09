const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const freetype = b.dependency("freetype", .{});

    const c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = freetype.path("include/freetype/freetype.h"),
    });
    c.addIncludePath(freetype.path("include"));
    c.defineCMacro("FT_BEGIN_HEADER", "");
    c.defineCMacro("FT_END_HEADER", "");

    // Fluff it
    if (target.result.isMinGW() or target.result.isGnuLibC()) {
        c.defineCMacro("_FORTIFY_VA_ARG", "0");
        c.defineCMacro("_FORTIFY_SOURCE", "0");
    }

    const freetype_bindings = c.createModule();

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    lib_mod.link_libc = true;
    lib_mod.addCMacro("FT2_BUILD_LIBRARY", "1");
    lib_mod.addCMacro("HAVE_UNISTD_H", "1");
    lib_mod.addIncludePath(freetype.path("include"));
    if (target.result.os.tag == .macos)
        lib_mod.addCSourceFile(.{ .file = freetype.path("src/base/ftmac.c"), .language = .c });
    lib_mod.addCSourceFiles(.{ .files = &sources, .language = .c, .root = freetype.path("src") });

    const lib = b.addLibrary(.{
        .name = "freetype",
        .root_module = lib_mod,
    });
    lib.installHeadersDirectory(freetype.path("include/freetype"), "freetype", .{});
    lib.installHeader(freetype.path("include/ft2build.h"), "ft2build.h");
    b.installArtifact(lib);

    const mod = b.addModule("freetype", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    mod.addImport("freetype", freetype_bindings);
    mod.linkLibrary(lib);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

const sources = [_][]const u8{
    "autofit/autofit.c",
    "base/ftbase.c",
    "base/ftsystem.c",
    "base/ftdebug.c",
    "base/ftbbox.c",
    "base/ftbdf.c",
    "base/ftbitmap.c",
    "base/ftcid.c",
    "base/ftfstype.c",
    "base/ftgasp.c",
    "base/ftglyph.c",
    "base/ftgxval.c",
    "base/ftinit.c",
    "base/ftmm.c",
    "base/ftotval.c",
    "base/ftpatent.c",
    "base/ftpfr.c",
    "base/ftstroke.c",
    "base/ftsynth.c",
    "base/fttype1.c",
    "base/ftwinfnt.c",
    "bdf/bdf.c",
    "bzip2/ftbzip2.c",
    "cache/ftcache.c",
    "cff/cff.c",
    "cid/type1cid.c",
    "gzip/ftgzip.c",
    "lzw/ftlzw.c",
    "pcf/pcf.c",
    "pfr/pfr.c",
    "psaux/psaux.c",
    "pshinter/pshinter.c",
    "psnames/psnames.c",
    "raster/raster.c",
    "sdf/sdf.c",
    "sfnt/sfnt.c",
    "smooth/smooth.c",
    "svg/svg.c",
    "truetype/truetype.c",
    "type1/type1.c",
    "type42/type42.c",
    "winfonts/winfnt.c",
};
