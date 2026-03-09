const std = @import("std");
const Element = @import("layout").Element;

const KeyType = union(enum) {
    src: std.builtin.SourceLocation,
    str: []const u8,
};

key: KeyType,
index: usize,

const Key = @This();

pub inline fn src(src_: std.builtin.SourceLocation) Key {
    return Key{
        .key = .{ .src = src_ },
        .index = 0,
    };
}

pub inline fn str(key: []const u8) Key {
    return Key{
        .key = .{ .str = key },
        .index = 0,
    };
}

pub inline fn indexed(self: Key, index: usize) Key {
    return Key{
        .key = self.key,
        .index = index,
    };
}

pub fn fmt(comptime format: []const u8, args: anytype) Element.Id {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, format, args) catch buf[0..];
    return str(s).hash();
}

pub fn hash(self: Key) Element.Id {
    var hasher = std.hash.Wyhash.init(0);
    switch (self.key) {
        inline .src => |s| {
            hasher.update(s.file);
            hasher.update(std.mem.asBytes(&s.line));
            hasher.update(std.mem.asBytes(&s.column));
        },
        inline .str => |s| hasher.update(s),
    }
    hasher.update(std.mem.asBytes(&self.index));
    const result: Element.Id = @truncate(hasher.final());
    return if (result == Element.INVALID_ID) result -% 1 else result;
}
