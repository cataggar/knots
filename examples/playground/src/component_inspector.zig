const std = @import("std");

pub const wasm_magic = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
pub const core_version = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
pub const component_preamble = [_]u8{ 0x0d, 0x00, 0x01, 0x00 };

pub const InspectError = error{
    TooShort,
    InvalidMagic,
    CoreModuleNotComponent,
    UnsupportedVersion,
    UnexpectedEof,
    Overflow,
    InvalidEncoding,
    OutOfMemory,
};

pub const ExternKind = enum {
    core_module,
    func,
    value,
    type,
    component,
    instance,

    pub fn label(self: ExternKind) []const u8 {
        return switch (self) {
            .core_module => "core:module",
            .func => "func",
            .value => "value",
            .type => "type",
            .component => "component",
            .instance => "interface",
        };
    }
};

pub const ExternItem = struct {
    name: []u8,
    kind: ExternKind,
};

pub const Summary = struct {
    byte_len: usize,
    version: u16,
    layer: u16,
    section_count: u32 = 0,
    core_module_count: u32 = 0,
    core_module_sizes: []u32 = &.{},
    core_instance_count: u32 = 0,
    component_instance_count: u32 = 0,
    alias_count: u32 = 0,
    type_count: u32 = 0,
    canon_lift_count: u32 = 0,
    canon_lower_count: u32 = 0,
    canon_other_count: u32 = 0,
    imports: []ExternItem = &.{},
    exports: []ExternItem = &.{},

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.core_module_sizes.len > 0) allocator.free(self.core_module_sizes);
        for (self.imports) |item| allocator.free(item.name);
        if (self.imports.len > 0) allocator.free(self.imports);
        for (self.exports) |item| allocator.free(item.name);
        if (self.exports.len > 0) allocator.free(self.exports);
        self.* = undefined;
    }

    pub fn importsUpstreamInterface(self: *const Summary) bool {
        for (self.imports) |imp| {
            if (imp.kind == .instance and (std.mem.indexOf(u8, imp.name, "knots:visual/upstream") != null or std.mem.indexOf(u8, imp.name, "knots:visual/source") != null)) {
                return true;
            }
        }
        return false;
    }

    pub fn exportsSourceInterface(self: *const Summary) bool {
        for (self.exports) |exp| {
            if (exp.kind == .instance and std.mem.indexOf(u8, exp.name, "knots:visual/source") != null) {
                return true;
            }
        }
        return false;
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn remaining(self: Reader) usize {
        return self.bytes.len - self.pos;
    }

    fn readByte(self: *Reader) InspectError!u8 {
        if (self.pos >= self.bytes.len) return error.UnexpectedEof;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn readSlice(self: *Reader, len: usize) InspectError![]const u8 {
        if (len > self.remaining()) return error.UnexpectedEof;
        const out = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return out;
    }

    fn readU32Leb(self: *Reader) InspectError!u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        var count: usize = 0;
        while (count < 5) : (count += 1) {
            const byte = try self.readByte();
            const low: u32 = byte & 0x7f;
            if (shift == 28 and (byte & 0xf0) != 0) return error.Overflow;
            result |= low << shift;
            if ((byte & 0x80) == 0) return result;
            if (shift < 28) shift += 7;
        }
        return error.Overflow;
    }

    fn readName(self: *Reader) InspectError![]const u8 {
        const len = try self.readU32Leb();
        return self.readSlice(len);
    }

    fn readExternNameAlloc(self: *Reader, allocator: std.mem.Allocator) InspectError![]u8 {
        const disc = try self.readByte();
        switch (disc) {
            0x00, 0x01 => {
                const base = try self.readName();
                return allocator.dupe(u8, base);
            },
            0x02 => {
                const base = try self.readName();
                const attr_count = try self.readU32Leb();
                var version_suffix: ?[]const u8 = null;
                var i: u32 = 0;
                while (i < attr_count) : (i += 1) {
                    const attr_kind = try self.readByte();
                    const attr_val = try self.readName();
                    if (attr_kind == 0x01) version_suffix = attr_val;
                }
                if (version_suffix) |ver| {
                    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ver });
                }
                return allocator.dupe(u8, base);
            },
            else => return error.InvalidEncoding,
        }
    }

    fn skipValType(self: *Reader) InspectError!void {
        const b = try self.readByte();
        // Signed LEB128 type index (>= 0) or negative primitive opcode (0x7f..0x64).
        if ((b & 0x80) == 0) {
            // Single-byte positive type index or negative 7-bit SLEB128 (0x40..0x7f).
            return;
        }
        // Multi-byte SLEB128 type index.
        var count: usize = 1;
        while (count < 5) : (count += 1) {
            const next = try self.readByte();
            if ((next & 0x80) == 0) return;
        }
        return error.Overflow;
    }

    fn readExternDescKind(self: *Reader) InspectError!ExternKind {
        const tag = try self.readByte();
        return switch (tag) {
            0x00 => blk: {
                const sub = try self.readByte();
                if (sub != 0x11) return error.InvalidEncoding;
                _ = try self.readU32Leb();
                break :blk .core_module;
            },
            0x01 => blk: {
                _ = try self.readU32Leb();
                break :blk .func;
            },
            0x02 => blk: {
                const val_disc = try self.readByte();
                switch (val_disc) {
                    0x00 => _ = try self.readU32Leb(), // eq typeidx
                    0x01 => try self.skipValType(),
                    else => return error.InvalidEncoding,
                }
                break :blk .value;
            },
            0x03 => blk: {
                const bound = try self.readByte();
                switch (bound) {
                    0x00 => _ = try self.readU32Leb(),
                    0x01 => {},
                    else => return error.InvalidEncoding,
                }
                break :blk .type;
            },
            0x04 => blk: {
                _ = try self.readU32Leb();
                break :blk .component;
            },
            0x05 => blk: {
                _ = try self.readU32Leb();
                break :blk .instance;
            },
            else => error.InvalidEncoding,
        };
    }

    fn readSortKind(self: *Reader) InspectError!ExternKind {
        const sort = try self.readByte();
        const kind: ExternKind = switch (sort) {
            0x00 => blk: {
                _ = try self.readByte(); // core sort
                break :blk .core_module;
            },
            0x01 => .func,
            0x02 => .value,
            0x03 => .type,
            0x04 => .component,
            0x05 => .instance,
            else => return error.InvalidEncoding,
        };
        _ = try self.readU32Leb(); // sort index
        return kind;
    }

    fn skipCanonOpts(self: *Reader) InspectError!void {
        const count = try self.readU32Leb();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const opt = try self.readByte();
            switch (opt) {
                0x00, 0x01, 0x02, 0x06 => {},
                0x03, 0x04, 0x05, 0x07 => _ = try self.readU32Leb(),
                else => return error.InvalidEncoding,
            }
        }
    }
};

pub fn inspect(allocator: std.mem.Allocator, bytes: []const u8) InspectError!Summary {
    if (bytes.len < 8) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..4], &wasm_magic)) return error.InvalidMagic;
    if (std.mem.eql(u8, bytes[4..8], &core_version)) return error.CoreModuleNotComponent;
    if (!std.mem.eql(u8, bytes[4..8], &component_preamble)) return error.UnsupportedVersion;

    var summary: Summary = .{
        .byte_len = bytes.len,
        .version = std.mem.readInt(u16, bytes[4..6], .little),
        .layer = std.mem.readInt(u16, bytes[6..8], .little),
    };

    var module_sizes: std.ArrayList(u32) = .empty;
    defer module_sizes.deinit(allocator);
    var imports: std.ArrayList(ExternItem) = .empty;
    errdefer {
        for (imports.items) |it| allocator.free(it.name);
        imports.deinit(allocator);
    }
    var exports: std.ArrayList(ExternItem) = .empty;
    errdefer {
        for (exports.items) |it| allocator.free(it.name);
        exports.deinit(allocator);
    }

    var top = Reader{ .bytes = bytes, .pos = 8 };
    while (top.remaining() > 0) {
        const section_id = try top.readByte();
        const section_len = try top.readU32Leb();
        const body = try top.readSlice(section_len);
        summary.section_count += 1;

        var sec = Reader{ .bytes = body };
        switch (section_id) {
            0 => {}, // custom section
            1 => { // core:module
                summary.core_module_count += 1;
                try module_sizes.append(allocator, section_len);
            },
            2 => summary.core_instance_count += try sec.readU32Leb(),
            5 => summary.component_instance_count += try sec.readU32Leb(),
            6 => summary.alias_count += try sec.readU32Leb(),
            7 => summary.type_count += try sec.readU32Leb(),
            8 => { // canon
                const count = try sec.readU32Leb();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const op = sec.readByte() catch {
                        summary.canon_other_count += (count - i);
                        break;
                    };
                    if (op == 0x00) {
                        const sub = sec.readByte() catch {
                            summary.canon_lift_count += 1;
                            break;
                        };
                        _ = sub;
                        _ = sec.readU32Leb() catch {
                            summary.canon_lift_count += 1;
                            break;
                        };
                        sec.skipCanonOpts() catch {
                            summary.canon_lift_count += 1;
                            break;
                        };
                        _ = sec.readU32Leb() catch {
                            summary.canon_lift_count += 1;
                            break;
                        };
                        summary.canon_lift_count += 1;
                    } else if (op == 0x01) {
                        const sub = sec.readByte() catch {
                            summary.canon_lower_count += 1;
                            break;
                        };
                        _ = sub;
                        _ = sec.readU32Leb() catch {
                            summary.canon_lower_count += 1;
                            break;
                        };
                        sec.skipCanonOpts() catch {
                            summary.canon_lower_count += 1;
                            break;
                        };
                        summary.canon_lower_count += 1;
                    } else {
                        summary.canon_other_count += (count - i);
                        break;
                    }
                }
            },
            10 => { // import
                const count = try sec.readU32Leb();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const name = try sec.readExternNameAlloc(allocator);
                    errdefer allocator.free(name);
                    const kind = try sec.readExternDescKind();
                    try imports.append(allocator, .{ .name = name, .kind = kind });
                }
            },
            11 => { // export
                const count = try sec.readU32Leb();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const name = try sec.readExternNameAlloc(allocator);
                    errdefer allocator.free(name);
                    const sort_kind = try sec.readSortKind();
                    const has_desc = try sec.readByte();
                    const kind = switch (has_desc) {
                        0x00 => sort_kind,
                        0x01 => try sec.readExternDescKind(),
                        else => return error.InvalidEncoding,
                    };
                    try exports.append(allocator, .{ .name = name, .kind = kind });
                }
            },
            else => {},
        }
    }

    summary.core_module_sizes = try module_sizes.toOwnedSlice(allocator);
    errdefer if (summary.core_module_sizes.len > 0) allocator.free(summary.core_module_sizes);
    summary.imports = try imports.toOwnedSlice(allocator);
    summary.exports = try exports.toOwnedSlice(allocator);
    return summary;
}

test "rejects core module and malformed headers with distinct errors" {
    const core_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.CoreModuleNotComponent, inspect(std.testing.allocator, &core_wasm));
    try std.testing.expectError(error.TooShort, inspect(std.testing.allocator, "wasm"));
    try std.testing.expectError(error.InvalidMagic, inspect(std.testing.allocator, "notawasm"));
}

test "parses component preamble, core modules, imports, exports, and canon entries" {
    // Minimal synthetic Component Model binary:
    // - Preamble: \0asm \x0d\x00\x01\x00
    // - Section 1 (core:module, len 8): \0asm \x01\x00\x00\x00
    // - Section 10 (import, count 1): externname(0x00, "knots:visual/source@0.1.0"), instance(0x05, 0)
    // - Section 8 (canon, count 2): lower(0x01,0x00, func 0, opts 0), lift(0x00,0x00, func 0, opts 0, type 0)
    // - Section 11 (export, count 1): externname(0x00, "knots:visual/source@0.1.0"), sort instance(0x05, 0), no desc(0x00)
    const sample = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        // Section 1: core:module (8 bytes)
        0x01, 0x08, 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00,
        0x00, 0x00,
        // Section 10: import (30 bytes)
        0x0a, 30,   0x01, 0x00, 25,   'k',
        'n',  'o',  't',  's',  ':',  'v',  'i',  's',
        'u',  'a',  'l',  '/',  's',  'o',  'u',  'r',
        'c',  'e',  '@',  '0',  '.',  '1',  '.',  '0',
        0x05, 0x00,
        // Section 8: canon (10 bytes: 2 entries)
        0x08, 10,   0x02, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Section 11: export (31 bytes)
        0x0b, 31,
        0x01, 0x00, 25,   'k',  'n',  'o',  't',  's',
        ':',  'v',  'i',  's',  'u',  'a',  'l',  '/',
        's',  'o',  'u',  'r',  'c',  'e',  '@',  '0',
        '.',  '1',  '.',  '0',  0x05, 0x00, 0x00,
    };

    var summary = try inspect(std.testing.allocator, &sample);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 0x0d), summary.version);
    try std.testing.expectEqual(@as(u16, 0x01), summary.layer);
    try std.testing.expectEqual(@as(u32, 1), summary.core_module_count);
    try std.testing.expectEqual(@as(u32, 8), summary.core_module_sizes[0]);
    try std.testing.expectEqual(@as(u32, 1), summary.canon_lower_count);
    try std.testing.expectEqual(@as(u32, 1), summary.canon_lift_count);
    try std.testing.expect(summary.importsUpstreamInterface());
    try std.testing.expect(summary.exportsSourceInterface());
    try std.testing.expectEqualStrings("knots:visual/source@0.1.0", summary.imports[0].name);
    try std.testing.expectEqualStrings("knots:visual/source@0.1.0", summary.exports[0].name);
}

test "inspects wazig-built generator and effect component binaries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const gen_paths = [_][]const u8{
        "examples/playground/zig-out/web/components/harmonograph.wasm",
        "zig-out/web/components/harmonograph.wasm",
    };
    var gen_bytes: ?[]u8 = null;
    for (gen_paths) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(2 * 1024 * 1024))) |b| {
            gen_bytes = b;
            break;
        } else |_| {}
    }
    if (gen_bytes) |bytes| {
        defer allocator.free(bytes);
        var gen = try inspect(allocator, bytes);
        defer gen.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 0x0d), gen.version);
        try std.testing.expectEqual(@as(u16, 0x01), gen.layer);
        try std.testing.expect(!gen.importsUpstreamInterface());
        try std.testing.expect(gen.exportsSourceInterface());
        try std.testing.expectEqual(@as(u32, 3), gen.canon_lift_count);
    }

    const eff_paths = [_][]const u8{
        "examples/playground/zig-out/web/components/kaleidoscope-effect.wasm",
        "zig-out/web/components/kaleidoscope-effect.wasm",
    };
    var eff_bytes: ?[]u8 = null;
    for (eff_paths) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(2 * 1024 * 1024))) |b| {
            eff_bytes = b;
            break;
        } else |_| {}
    }
    if (eff_bytes) |bytes| {
        defer allocator.free(bytes);
        var eff = try inspect(allocator, bytes);
        defer eff.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 0x0d), eff.version);
        try std.testing.expectEqual(@as(u16, 0x01), eff.layer);
        try std.testing.expect(eff.importsUpstreamInterface());
        try std.testing.expect(eff.exportsSourceInterface());
        try std.testing.expectEqual(@as(u32, 3), eff.canon_lift_count);
        try std.testing.expectEqual(@as(u32, 2), eff.canon_lower_count);
    }
}
