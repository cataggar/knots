const std = @import("std");
const Element = @import("layout").Element;

seed: u64,
index: usize = 0,

const Key = @This();

pub inline fn src(comptime src_: std.builtin.SourceLocation) Key {
    const seed = comptime blk: {
        var h = std.hash.Wyhash.init(0);
        h.update(src_.file);
        h.update(std.mem.asBytes(&src_.line));
        h.update(std.mem.asBytes(&src_.column));
        break :blk h.final();
    };
    return .{
        .seed = seed,
        .index = 0,
    };
}

pub inline fn str(key: []const u8) Key {
    return .{
        .seed = std.hash.Wyhash.hash(0, key),
        .index = 0,
    };
}

pub inline fn indexed(self: Key, index: usize) Key {
    return .{
        .seed = self.seed,
        .index = chainIndex(self.index, index),
    };
}

pub fn fmt(comptime format: []const u8, args: anytype) Element.Id {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, format, args) catch @panic("Key.fmt buffer too small");
    return str(s).hash();
}

pub fn fmtBuf(buf: []u8, comptime format: []const u8, args: anytype) !Element.Id {
    const s = try std.fmt.bufPrint(buf, format, args);
    return str(s).hash();
}

pub inline fn hash(self: Key) Element.Id {
    const final: u64 = mixIndex(self.seed, self.index);
    return if (final == Element.INVALID_ID) final -% 1 else final;
}

/// Wyhash-style finalizer applied to (seed, index). Cheap, well-distributed.
inline fn mixIndex(seed: u64, index: usize) u64 {
    var x: u64 = seed ^ @as(u64, index);
    x = (x ^ (x >> 32)) *% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 32)) *% 0xBF58476D1CE4E5B9;
    return x ^ (x >> 32);
}

inline fn chainIndex(parent: usize, child: usize) usize {
    const p = (@as(u64, parent) +% 0x7ac4_71f4_6d77_1a33) *% 0x9E3779B97F4A7C15;
    const mixed: usize = @truncate(mixIndex(p, child +% 1));
    return if (mixed == 0) 1 else mixed;
}

const testing = std.testing;

test "hash produces full u64 codomain" {
    const a = str("a").hash();
    const b = str("b").hash();
    try testing.expect(a != b);

    var any_high_bits = false;
    inline for ([_][]const u8{ "a", "b", "c", "widget", "scroll", "modal" }) |s| {
        if ((str(s).hash() >> 32) != 0) any_high_bits = true;
    }
    try testing.expect(any_high_bits);
}

test "indexed composes nested component keys" {
    const a = str("row").indexed(10).indexed(1).hash();
    const b = str("row").indexed(11).indexed(1).hash();
    const direct = str("row").indexed(1).hash();

    try testing.expect(a != b);
    try testing.expect(a != direct);
    try testing.expect(b != direct);
}
