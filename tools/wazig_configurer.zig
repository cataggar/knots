const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = std.zig.Color;
const Configuration = std.Build.Configuration;
const Io = std.Io;
const Step = std.Build.Step;
const assert = std.debug.assert;
const fatal = std.process.fatal;
const log = std.log;
const mem = std.mem;
const process = std.process;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const std_options: std.Options = .{
    .side_channels_mitigations = .none,
    .http_disable_tls = true,
};

pub fn main(init: process.Init.Minimal) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var threaded: std.Io.Threaded = .init(arena, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.args.toSlice(arena);
    var arg_i: usize = 1;

    const zig_exe = expectArgOrFatal(args, &arg_i, "--zig");
    const build_root_sub_path = expectArgOrFatal(args, &arg_i, "--build-root");
    const cache_root_sub_path = expectArgOrFatal(args, &arg_i, "--cache-root");
    const global_cache_root_sub_path = expectArgOrFatal(args, &arg_i, "--global-cache-root");
    const install_prefix_sub_path = expectArgOrFatal(args, &arg_i, "--prefix");

    var graph: std.Build.Graph = .{
        .io = io,
        .arena = arena,
        .environ_map = try init.environ.createMap(arena),
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(io, .{}),
        },
        .generated_files = .empty,
        .zig_exe = zig_exe,
        .wip_configuration = .init(arena),
    };
    assert(try graph.wip_configuration.addString("") == .empty);
    assert(try graph.wip_configuration.addString("root") == .root);

    const cwd: Io.Dir = .cwd();

    const build_root: std.Build.Cache.Path = if (std.mem.eql(u8, build_root_sub_path, ".")) .cwd() else .{
        .root_dir = .{
            .handle = try cwd.openDir(io, build_root_sub_path, .{}),
            .path = build_root_sub_path,
        },
    };

    try cwd.createDirPath(io, cache_root_sub_path);
    try cwd.createDirPath(io, global_cache_root_sub_path);

    const builder = try std.Build.create(&graph, build_root, dependencies.root_deps);

    var color: Color = .auto;
    var requested_steps: std.ArrayList([]const u8) = .empty;

    while (nextArg(args, &arg_i)) |arg| {
        if (mem.cutPrefix(u8, arg, "-D")) |option_contents| {
            if (option_contents.len == 0)
                fatal("expected option name after '-D'", .{});
            if (mem.findScalar(u8, option_contents, '=')) |name_end| {
                const option_name = option_contents[0..name_end];
                const option_value = option_contents[name_end + 1 ..];
                if (try builder.addUserInputOption(option_name, option_value)) {
                    process.exit(1);
                }
            } else {
                if (try builder.addUserInputFlag(option_contents)) {
                    process.exit(1);
                }
            }
        } else if (mem.eql(u8, arg, "--step")) {
            try requested_steps.append(arena, nextArgOrFatal(args, &arg_i));
        } else if (mem.cutPrefix(u8, arg, "--color=")) |rest| {
            color = std.meta.stringToEnum(Color, rest) orelse
                fatal("expected --color=[auto|on|off]; found: {s}", .{arg});
        } else if (mem.eql(u8, arg, "--verbose")) {
            graph.verbose = true;
        } else if (mem.eql(u8, arg, "--search-prefix")) {
            try graph.search_prefixes.append(arena, nextArgOrFatal(args, &arg_i));
        } else {
            fatal("unrecognized argument: {s}", .{arg});
        }
    }

    const NO_COLOR = std.zig.EnvVar.NO_COLOR.isSet(&graph.environ_map);
    const CLICOLOR_FORCE = std.zig.EnvVar.CLICOLOR_FORCE.isSet(&graph.environ_map);

    graph.stderr_mode = switch (color) {
        .auto => try .detect(io, .stderr(), NO_COLOR, CLICOLOR_FORCE),
        .on => .escape_codes,
        .off => .no_color,
    };

    builder.runPackageScript(root);

    std.Build.PackageOptions.sort(&builder.user_input_options);
    for (builder.user_input_options.keys()) |name| {
        if (!builder.available_options_map.contains(name)) {
            log.err("invalid option: {q}", .{name});
            builder.invalid_user_input = true;
        }
    }
    if (builder.invalid_user_input) {
        process.exit(1);
    }

    // Wire up implied module dependencies across all steps (matching Serialize.write).
    var all_steps: std.array_hash_map.Auto(*Step, void) = .empty;
    for (builder.top_level_steps.values()) |tls| {
        try all_steps.put(arena, &tls.step, {});
    }
    var scan_idx: usize = 0;
    while (scan_idx < all_steps.count()) : (scan_idx += 1) {
        const step = all_steps.keys()[scan_idx];
        try createModuleDependenciesForStep(step);
        for (step.dependencies.items) |dep_step| {
            try all_steps.put(arena, dep_step, {});
        }
    }

    // Collect target top-level steps and traverse their dependency DAG in post-order (topological order).
    var ordered_steps: std.array_hash_map.Auto(*Step, void) = .empty;
    var visiting: std.array_hash_map.Auto(*Step, void) = .empty;

    if (requested_steps.items.len == 0) {
        try visitStep(arena, builder.default_step, &ordered_steps, &visiting);
    } else {
        for (requested_steps.items) |step_name| {
            const tls = builder.top_level_steps.get(step_name) orelse
                fatal("no step named {q}", .{step_name});
            try visitStep(arena, &tls.step, &ordered_steps, &visiting);
        }
    }

    const generated_paths = try arena.alloc([]const u8, graph.generated_files.items.len);
    @memset(generated_paths, "");

    var out_buf: std.Io.Writer.Allocating = .init(arena);
    const w = &out_buf.writer;

    try w.writeAll("{\n  \"steps\": [\n");
    var first_action = true;

    for (ordered_steps.keys(), 0..) |step, step_idx| {
        switch (step.tag) {
            .top_level => {},
            .options => {
                const so: *Step.Options = @fieldParentPtr("step", step);
                var digest: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(so.contents.items, &digest, .{});
                var hex: [Sha256.digest_length * 2]u8 = undefined;
                _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});

                const rel_dir = try std.fs.path.join(arena, &.{ cache_root_sub_path, "o", &hex });
                try cwd.createDirPath(io, rel_dir);
                const file_path = try std.fs.path.join(arena, &.{ rel_dir, "options.zig" });
                try cwd.writeFile(io, .{ .sub_path = file_path, .data = so.contents.items });
                generated_paths[@backingInt(so.generated_file)] = file_path;
            },
            .write_file => {
                const wf: *Step.WriteFile = @fieldParentPtr("step", step);
                const dir_name = try std.fmt.allocPrint(arena, "wf_{d}", .{step_idx});
                const rel_dir = try std.fs.path.join(arena, &.{ cache_root_sub_path, "o", dir_name });
                try cwd.createDirPath(io, rel_dir);
                const wc = &graph.wip_configuration;
                for (wf.embeds.items) |embed| {
                    const sub = wc.stringSlice(embed.sub_path);
                    const bytes = wc.string_bytes.items[embed.contents.index..][0..embed.contents.len];
                    const full = try std.fs.path.join(arena, &.{ rel_dir, sub });
                    if (std.fs.path.dirname(full)) |parent| try cwd.createDirPath(io, parent);
                    try cwd.writeFile(io, .{ .sub_path = full, .data = bytes });
                }
                for (wf.copies.items) |copy| {
                    const sub = wc.stringSlice(copy.sub_path);
                    const src = try resolveLazyPath(arena, copy.src_file, generated_paths);
                    const full = try std.fs.path.join(arena, &.{ rel_dir, sub });
                    if (std.fs.path.dirname(full)) |parent| try cwd.createDirPath(io, parent);
                    const data = try cwd.readFileAlloc(io, src, arena, .unlimited);
                    try cwd.writeFile(io, .{ .sub_path = full, .data = data });
                }
                generated_paths[@backingInt(wf.generated_directory)] = rel_dir;
            },
            .translate_c => {
                const tc: *Step.TranslateC = @fieldParentPtr("step", step);
                const src_path = try resolveLazyPath(arena, tc.source, generated_paths);
                const dir_name = try std.fmt.allocPrint(arena, "tc_{d}", .{step_idx});
                const rel_dir = try std.fs.path.join(arena, &.{ cache_root_sub_path, "o", dir_name });
                try cwd.createDirPath(io, rel_dir);
                const out_path = try std.fs.path.join(arena, &.{ rel_dir, "c.zig" });
                generated_paths[@backingInt(tc.output_file)] = out_path;

                var tc_args: std.ArrayList([]const u8) = .empty;
                try tc_args.append(arena, "translate-c");
                try tc_args.appendSlice(arena, &.{
                    "-target",
                    try tc.target.query.zigTriple(arena),
                    "-mcpu",
                    try tc.target.query.serializeCpuAlloc(arena),
                });
                if (tc.link_libc) try tc_args.append(arena, "-lc") else try tc_args.append(arena, "-fno-lc");
                for (tc.include_dirs.items) |inc| {
                    try appendIncludeDirFlags(arena, inc, &tc_args, generated_paths);
                }
                const wc = &graph.wip_configuration;
                if (tc.cc_argv.items.len != 0) {
                    try tc_args.append(arena, "-cflags");
                    for (tc.cc_argv.items) |arg_str| {
                        try tc_args.append(arena, wc.stringSlice(arg_str));
                    }
                    try tc_args.append(arena, "--");
                }
                try tc_args.append(arena, src_path);
                try tc_args.appendSlice(arena, &.{
                    "--cache-dir",
                    cache_root_sub_path,
                    "--global-cache-dir",
                    global_cache_root_sub_path,
                });

                if (!first_action) try w.writeAll(",\n");
                first_action = false;
                try w.writeAll("    {\"kind\": \"translate_c\", \"name\": ");
                try writeJsonString(w, step.name);
                try w.writeAll(", \"output\": ");
                try writeJsonString(w, out_path);
                try w.writeAll(", \"args\": ");
                try writeJsonStringArray(w, tc_args.items);
                try w.writeAll("}");
            },
            .compile => {
                const cs: *Step.Compile = @fieldParentPtr("step", step);
                const dir_name = try std.fmt.allocPrint(arena, "bin_{d}_{s}", .{ step_idx, cs.name });
                const rel_dir = try std.fs.path.join(arena, &.{ cache_root_sub_path, "o", dir_name });
                try cwd.createDirPath(io, rel_dir);
                const out_path = try std.fs.path.join(arena, &.{ rel_dir, cs.out_filename });
                if (cs.generated_bin.unwrap()) |gb| {
                    generated_paths[@backingInt(gb)] = out_path;
                }

                var zig_args: std.ArrayList([]const u8) = .empty;
                const cmd = switch (cs.kind) {
                    .lib => "build-lib",
                    .exe => "build-exe",
                    .obj => "build-obj",
                    .@"test" => "test",
                    .test_obj => "test-obj",
                };
                try zig_args.append(arena, cmd);
                if (cs.kind == .@"test") {
                    try zig_args.append(arena, "--test-no-exec");
                }
                try zig_args.append(arena, "-fno-llvm");
                try zig_args.append(arena, try std.fmt.allocPrint(arena, "-femit-bin={s}", .{out_path}));

                switch (cs.entry) {
                    .default => {},
                    .disabled => try zig_args.append(arena, "-fno-entry"),
                    .enabled => try zig_args.append(arena, "-fentry"),
                    .symbol_name => |sym| try zig_args.append(arena, try std.fmt.allocPrint(arena, "-fentry={s}", .{sym})),
                }
                for (cs.force_undefined_symbols.keys()) |sym| {
                    try zig_args.appendSlice(arena, &.{ "--force_undefined", sym });
                }
                if (cs.stack_size) |ss| {
                    try zig_args.appendSlice(arena, &.{ "--stack", try std.fmt.allocPrint(arena, "{d}", .{ss}) });
                }

                try zig_args.appendSlice(arena, &.{ "--name", cs.name });
                if (cs.rdynamic) try zig_args.append(arena, "-rdynamic");
                if (cs.import_memory) try zig_args.append(arena, "--import-memory");
                if (cs.export_memory) try zig_args.append(arena, "--export-memory");
                if (cs.import_symbols) try zig_args.append(arena, "--import-symbols");
                if (cs.import_table) try zig_args.append(arena, "--import-table");
                if (cs.export_table) try zig_args.append(arena, "--export-table");
                if (cs.growable_table) try zig_args.append(arena, "--growable-table");
                if (cs.shared_memory) try zig_args.append(arena, "--shared-memory");
                if (cs.initial_memory) |m| try zig_args.append(arena, try std.fmt.allocPrint(arena, "--initial-memory={d}", .{m}));
                if (cs.max_memory) |m| try zig_args.append(arena, try std.fmt.allocPrint(arena, "--max-memory={d}", .{m}));
                if (cs.global_base) |gb| try zig_args.append(arena, try std.fmt.allocPrint(arena, "--global-base={d}", .{gb}));
                if (cs.wasi_exec_model) |wem| {
                    try zig_args.append(arena, try std.fmt.allocPrint(arena, "-mexec-model={t}", .{wem}));
                }

                // Assign unique CLI names to all modules in cs.root_module.getGraph()
                const mod_graph = cs.root_module.getGraph();
                var mod_to_cli: std.array_hash_map.Auto(*std.Build.Module, []const u8) = .empty;
                var used_names: std.array_hash_map.String(void) = .empty;
                try mod_to_cli.putNoClobber(arena, mod_graph.modules[0], "root");
                try used_names.putNoClobber(arena, "root", {});

                for (mod_graph.modules[1..], mod_graph.names[1..]) |m, orig_name| {
                    var candidate = orig_name;
                    var suffix: usize = 0;
                    while (true) {
                        const gop = try used_names.getOrPut(arena, candidate);
                        if (!gop.found_existing) {
                            try mod_to_cli.putNoClobber(arena, m, candidate);
                            break;
                        }
                        candidate = try std.fmt.allocPrint(arena, "{s}{d}", .{ orig_name, suffix });
                        suffix += 1;
                    }
                }

                var is_linking_libc = false;
                var is_linking_libcpp = false;
                var prev_has_cflags = false;

                for (mod_graph.modules) |m| {
                    const cli_name = mod_to_cli.get(m).?;
                    if (m.link_libc == true) is_linking_libc = true;
                    if (m.link_libcpp == true) is_linking_libcpp = true;

                    for (m.link_objects.items) |lo| switch (lo) {
                        .static_path => |lp| {
                            try zig_args.append(arena, try resolveLazyPath(arena, lp, generated_paths));
                        },
                        .other_step => |other_cs| {
                            if (other_cs.generated_bin.unwrap()) |gb| {
                                try zig_args.append(arena, generated_paths[@backingInt(gb)]);
                            }
                        },
                        .system_lib => |sl| {
                            try zig_args.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{sl.name}));
                        },
                        .assembly_file => |lp| {
                            if (prev_has_cflags) {
                                try zig_args.appendSlice(arena, &.{ "-cflags", "--" });
                                prev_has_cflags = false;
                            }
                            try zig_args.append(arena, try resolveLazyPath(arena, lp, generated_paths));
                        },
                        .c_source_file => |csf| {
                            if (prev_has_cflags or csf.flags.len != 0) {
                                try zig_args.append(arena, "-cflags");
                                try zig_args.appendSlice(arena, csf.flags);
                                try zig_args.append(arena, "--");
                            }
                            prev_has_cflags = (csf.flags.len != 0);
                            if (csf.language) |lang| {
                                try zig_args.appendSlice(arena, &.{ "-x", lang.clangIdentifier() });
                            }
                            try zig_args.append(arena, try resolveLazyPath(arena, csf.file, generated_paths));
                            if (csf.language != null) {
                                try zig_args.appendSlice(arena, &.{ "-x", "none" });
                            }
                        },
                        .c_source_files => |csfs| {
                            if (prev_has_cflags or csfs.flags.len != 0) {
                                try zig_args.append(arena, "-cflags");
                                try zig_args.appendSlice(arena, csfs.flags);
                                try zig_args.append(arena, "--");
                            }
                            prev_has_cflags = (csfs.flags.len != 0);
                            if (csfs.language) |lang| {
                                try zig_args.appendSlice(arena, &.{ "-x", lang.clangIdentifier() });
                            }
                            const root_p = try resolveLazyPath(arena, csfs.root, generated_paths);
                            for (csfs.files) |sub_f| {
                                try zig_args.append(arena, try std.fs.path.join(arena, &.{ root_p, sub_f }));
                            }
                            if (csfs.language != null) {
                                try zig_args.appendSlice(arena, &.{ "-x", "none" });
                            }
                        },
                        .win32_resource_file => {},
                    };

                    if (m.strip) |v| try zig_args.append(arena, if (v) "-fstrip" else "-fno-strip");
                    if (m.single_threaded) |v| try zig_args.append(arena, if (v) "-fsingle-threaded" else "-fno-single-threaded");
                    if (m.stack_check) |v| try zig_args.append(arena, if (v) "-fstack-check" else "-fno-stack-check");
                    if (m.stack_protector) |v| try zig_args.append(arena, if (v) "-fstack-protector" else "-fno-stack-protector");
                    if (m.omit_frame_pointer) |v| try zig_args.append(arena, if (v) "-fomit-frame-pointer" else "-fno-omit-frame-pointer");
                    if (m.error_tracing) |v| try zig_args.append(arena, if (v) "-ferror-tracing" else "-fno-error-tracing");

                    if (m.optimize) |opt| {
                        try zig_args.append(arena, switch (opt) {
                            .Debug => "-ODebug",
                            .ReleaseSafe => "-OReleaseSafe",
                            .ReleaseFast => "-OReleaseFast",
                            .ReleaseSmall => "-OReleaseSmall",
                        });
                    }
                    if (m.resolved_target) |rt| {
                        try zig_args.appendSlice(arena, &.{
                            "-target",
                            try rt.query.zigTriple(arena),
                            "-mcpu",
                            try rt.query.serializeCpuAlloc(arena),
                        });
                    }
                    for (m.export_symbol_names) |sym| {
                        try zig_args.append(arena, try std.fmt.allocPrint(arena, "--export={s}", .{sym}));
                    }
                    for (m.include_dirs.items) |inc| {
                        try appendIncludeDirFlags(arena, inc, &zig_args, generated_paths);
                    }
                    for (m.c_macros.items) |cm| {
                        try zig_args.append(arena, cm);
                    }
                    for (m.import_table.keys(), m.import_table.values()) |imp_name, imp_mod| {
                        const imp_cli = mod_to_cli.get(imp_mod).?;
                        try zig_args.append(arena, "--dep");
                        if (mem.eql(u8, imp_cli, imp_name)) {
                            try zig_args.append(arena, imp_cli);
                        } else {
                            try zig_args.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ imp_name, imp_cli }));
                        }
                    }
                    if (m.root_source_file) |lp| {
                        const src_p = try resolveLazyPath(arena, lp, generated_paths);
                        try zig_args.append(arena, try std.fmt.allocPrint(arena, "-M{s}={s}", .{ cli_name, src_p }));
                    } else if (m.link_objects.items.len != 0) {
                        try zig_args.append(arena, try std.fmt.allocPrint(arena, "-M{s}", .{cli_name}));
                    }
                }

                if (cs.root_module.resolved_target) |rt| {
                    if (rt.result.os.tag == .freestanding) {
                        is_linking_libc = false;
                        is_linking_libcpp = false;
                    }
                }
                if (is_linking_libcpp) try zig_args.append(arena, "-lc++");
                if (is_linking_libc) try zig_args.append(arena, "-lc");
                try zig_args.appendSlice(arena, &.{
                    "--cache-dir",
                    cache_root_sub_path,
                    "--global-cache-dir",
                    global_cache_root_sub_path,
                });

                if (!first_action) try w.writeAll(",\n");
                first_action = false;
                try w.writeAll("    {\"kind\": \"compile\", \"name\": ");
                try writeJsonString(w, step.name);
                try w.writeAll(", \"output\": ");
                try writeJsonString(w, out_path);
                try w.writeAll(", \"args\": ");
                try writeJsonStringArray(w, zig_args.items);
                try w.writeAll("}");
            },
            .install_artifact => {
                const ia: *Step.InstallArtifact = @fieldParentPtr("step", step);
                if (ia.dest_dir) |dest_dir| {
                    if (ia.emitted_bin) |emitted_bin| {
                        const src_path = try resolveLazyPath(arena, emitted_bin, generated_paths);
                        const sub = ia.dest_sub_path orelse ia.artifact.out_filename;
                        const dest_path = try resolveInstallDir(arena, install_prefix_sub_path, dest_dir, sub);
                        if (!first_action) try w.writeAll(",\n");
                        first_action = false;
                        try w.writeAll("    {\"kind\": \"install_file\", \"src\": ");
                        try writeJsonString(w, src_path);
                        try w.writeAll(", \"dest\": ");
                        try writeJsonString(w, dest_path);
                        try w.writeAll("}");
                    }
                }
            },
            .install_file => {
                const inf: *Step.InstallFile = @fieldParentPtr("step", step);
                const src_path = try resolveLazyPath(arena, inf.source, generated_paths);
                const dest_path = try resolveInstallDir(arena, install_prefix_sub_path, inf.dir, inf.dest_rel_path);
                if (!first_action) try w.writeAll(",\n");
                first_action = false;
                try w.writeAll("    {\"kind\": \"install_file\", \"src\": ");
                try writeJsonString(w, src_path);
                try w.writeAll(", \"dest\": ");
                try writeJsonString(w, dest_path);
                try w.writeAll("}");
            },
            .run => {
                const run: *Step.Run = @fieldParentPtr("step", step);
                var run_args: std.ArrayList([]const u8) = .empty;
                var uses_threads = false;
                if (run.producer) |prod| {
                    if (prod.shared_memory) uses_threads = true;
                    if (prod.root_module.resolved_target) |rt| {
                        if (std.Target.wasm.featureSetHas(rt.result.cpu.features, .atomics)) {
                            uses_threads = true;
                        }
                    }
                }
                for (run.argv.items) |arg| switch (arg) {
                    .artifact => |pa| {
                        if (pa.artifact.generated_bin.unwrap()) |gb| {
                            const bin_p = generated_paths[@backingInt(gb)];
                            try run_args.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ pa.prefix, bin_p, pa.suffix }));
                        }
                    },
                    .lazy_path, .decorated_directory => |lp| {
                        const p = try resolveLazyPath(arena, lp.lazy_path, generated_paths);
                        try run_args.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ lp.prefix, p, lp.suffix }));
                    },
                    .bytes => |b| try run_args.append(arena, b),
                    else => {},
                };
                if (run_args.items.len > 0) {
                    if (!first_action) try w.writeAll(",\n");
                    first_action = false;
                    try w.writeAll("    {\"kind\": \"run\", \"name\": ");
                    try writeJsonString(w, step.name);
                    try w.print(", \"threads\": {s}, \"args\": ", .{if (uses_threads) "true" else "false"});
                    try writeJsonStringArray(w, run_args.items);
                    try w.writeAll("}");
                }
            },
            else => {},
        }
    }

    try w.writeAll("\n  ]\n}\n");

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);
    try stdout_writer.interface.writeAll(out_buf.written());
    try stdout_writer.interface.flush();
}

fn visitStep(
    arena: Allocator,
    step: *Step,
    ordered: *std.array_hash_map.Auto(*Step, void),
    visiting: *std.array_hash_map.Auto(*Step, void),
) !void {
    if (ordered.contains(step)) return;
    if (visiting.contains(step)) return;
    try visiting.put(arena, step, {});
    for (step.dependencies.items) |dep| {
        try visitStep(arena, dep, ordered, visiting);
    }
    _ = visiting.swapRemove(step);
    try ordered.putNoClobber(arena, step, {});
}

fn createModuleDependenciesForStep(step: *Step) Allocator.Error!void {
    const cs = step.cast(Step.Compile) orelse return;
    const modules = cs.root_module.getGraph().modules;
    for (modules) |mod| {
        if (mod.root_source_file) |lp| lp.addStepDependencies(step);
        for (mod.include_dirs.items) |include_dir| switch (include_dir) {
            .path,
            .path_system,
            .path_after,
            .framework_path,
            .framework_path_system,
            .embed_path,
            => |lp| lp.addStepDependencies(step),
            .other_step => |other| {
                other.getEmittedIncludeTree().addStepDependencies(step);
                step.dependOn(&other.step);
            },
            .config_header_step => |other| step.dependOn(&other.step),
        };
        for (mod.lib_paths.items) |lp| lp.addStepDependencies(step);
        for (mod.rpaths.items) |rpath| switch (rpath) {
            .lazy_path => |lp| lp.addStepDependencies(step),
            .special => {},
        };
        for (mod.link_objects.items) |link_object| switch (link_object) {
            .static_path, .assembly_file => |lp| lp.addStepDependencies(step),
            .other_step => |other| step.dependOn(&other.step),
            .system_lib => {},
            .c_source_file => |source| source.file.addStepDependencies(step),
            .c_source_files => |source_files| source_files.root.addStepDependencies(step),
            .win32_resource_file => |rc_source| {
                rc_source.file.addStepDependencies(step);
                for (rc_source.include_paths) |lp| lp.addStepDependencies(step);
            },
        };
    }
}

fn resolveLazyPath(
    arena: Allocator,
    lp: std.Build.LazyPath,
    generated_paths: []const []const u8,
) ![]const u8 {
    return switch (lp) {
        .src_path => |sp| blk: {
            const root_str = try sp.owner.root.toString(arena);
            if (root_str.len == 0 or mem.eql(u8, root_str, ".")) {
                break :blk if (sp.sub_path.len == 0) "." else sp.sub_path;
            }
            if (sp.sub_path.len == 0) break :blk root_str;
            break :blk try std.fs.path.join(arena, &.{ root_str, sp.sub_path });
        },
        .dependency => |dep| blk: {
            const root_str = try dep.dependency.builder.root.toString(arena);
            if (root_str.len == 0 or mem.eql(u8, root_str, ".")) {
                break :blk if (dep.sub_path.len == 0) "." else dep.sub_path;
            }
            if (dep.sub_path.len == 0) break :blk root_str;
            break :blk try std.fs.path.join(arena, &.{ root_str, dep.sub_path });
        },
        .cwd_relative => |p| if (p.len == 0) "." else p,
        .relative => |r| if (r.sub_path.len == 0) "." else r.sub_path,
        .generated => |gen| blk: {
            var base = generated_paths[@backingInt(gen.index)];
            var up = gen.up;
            while (up > 0) : (up -= 1) {
                base = std.fs.path.dirname(base) orelse ".";
            }
            if (gen.sub_path.len == 0) break :blk base;
            break :blk try std.fs.path.join(arena, &.{ base, gen.sub_path });
        },
    };
}

fn resolveInstallDir(
    arena: Allocator,
    prefix: []const u8,
    dir: std.Build.InstallDir,
    rel: []const u8,
) ![]const u8 {
    const sub_dir: []const u8 = switch (dir) {
        .prefix => "",
        .lib => "lib",
        .bin => "bin",
        .header => "include",
        .custom => |c| c,
    };
    if (sub_dir.len == 0) {
        return std.fs.path.join(arena, &.{ prefix, rel });
    }
    return std.fs.path.join(arena, &.{ prefix, sub_dir, rel });
}

fn appendIncludeDirFlags(
    arena: Allocator,
    inc: std.Build.Module.IncludeDir,
    zig_args: *std.ArrayList([]const u8),
    generated_paths: []const []const u8,
) !void {
    switch (inc) {
        .path => |lp| try zig_args.appendSlice(arena, &.{ "-I", try resolveLazyPath(arena, lp, generated_paths) }),
        .path_system => |lp| try zig_args.appendSlice(arena, &.{ "-isystem", try resolveLazyPath(arena, lp, generated_paths) }),
        .path_after => |lp| try zig_args.appendSlice(arena, &.{ "-irafter", try resolveLazyPath(arena, lp, generated_paths) }),
        .framework_path => |lp| try zig_args.appendSlice(arena, &.{ "-F", try resolveLazyPath(arena, lp, generated_paths) }),
        .framework_path_system => |lp| try zig_args.appendSlice(arena, &.{ "-iframework", try resolveLazyPath(arena, lp, generated_paths) }),
        .embed_path => |lp| try zig_args.appendSlice(arena, &.{ "--embed-dir", try resolveLazyPath(arena, lp, generated_paths) }),
        .other_step => |cs| {
            if (cs.installed_headers_include_tree) |wf| {
                const p = try resolveLazyPath(arena, wf.getDirectory(), generated_paths);
                try zig_args.appendSlice(arena, &.{ "-I", p });
            }
        },
        .config_header_step => {},
    }
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeJsonStringArray(w: *Io.Writer, items: []const []const u8) !void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(", ");
        try writeJsonString(w, item);
    }
    try w.writeByte(']');
}

fn nextArg(args: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

fn nextArgOrFatal(args: []const [:0]const u8, idx: *usize) [:0]const u8 {
    return nextArg(args, idx) orelse {
        fatal("expected argument after {q}", .{args[idx.* - 1]});
    };
}

fn expectArgOrFatal(args: []const [:0]const u8, index_ptr: *usize, first: []const u8) []const u8 {
    const next_arg = nextArg(args, index_ptr) orelse fatal("missing {q} argument", .{first});
    if (!mem.eql(u8, first, next_arg)) fatal("expected {q} instead of {q}", .{ first, next_arg });
    const arg = nextArg(args, index_ptr) orelse fatal("expected argument after {q}", .{first});
    return arg;
}
