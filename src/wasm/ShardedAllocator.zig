const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const num_shards: usize = 16;
pub const min_class_shift: u5 = 4; // 16 bytes
pub const max_class_shift: u5 = 12; // 4096 bytes
pub const num_classes: usize = (max_class_shift - min_class_shift) + 1;
pub const max_slab_align_log2: u5 = 6; // 64 bytes
pub const max_cached_per_class: u16 = 64;

pub const min_slot_size: usize = @as(usize, 1) << min_class_shift;
pub const max_slot_size: usize = @as(usize, 1) << max_class_shift;
pub const max_slab_align_bytes: usize = @as(usize, 1) << max_slab_align_log2;
pub const small_batch_max_slot_size: usize = 256;
pub const small_batch_count: usize = 4;

pub const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic)) |_| {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub const FreeNode = struct {
    next: ?*FreeNode,
};

pub const Shard = struct {
    lock: SpinLock align(64) = .{},
    free_heads: [num_classes]?*FreeNode = @splat(null),
    counts: [num_classes]u16 = @splat(0),
};

pub fn classIndex(len: usize, alignment: std.mem.Alignment) ?usize {
    if (len == 0) return null;
    const align_bytes = alignment.toByteUnits();
    if (align_bytes > max_slab_align_bytes) return null;
    const needed = @max(len, align_bytes, min_slot_size);
    if (needed > max_slot_size) return null;
    const slot_size = std.math.ceilPowerOfTwoAssert(usize, needed);
    const shift: usize = @ctz(slot_size);
    return shift - min_class_shift;
}

pub fn slotSize(class_idx: usize) usize {
    std.debug.assert(class_idx < num_classes);
    const shift: std.math.Log2Int(usize) = @intCast(@as(usize, min_class_shift) + class_idx);
    return @as(usize, 1) << shift;
}

pub fn slotAlignment(class_idx: usize) std.mem.Alignment {
    const size = slotSize(class_idx);
    return std.mem.Alignment.fromByteUnits(@min(size, max_slab_align_bytes));
}

pub fn batchCountForClass(class_idx: usize) usize {
    return if (slotSize(class_idx) <= small_batch_max_slot_size) small_batch_count else 1;
}

pub fn baseAllocator() Allocator {
    return if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;
}

pub const ShardedPool = struct {
    backing_allocator: Allocator,
    backing_lock: SpinLock align(64) = .{},
    shards: [num_shards]Shard align(64) = @splat(.{}),

    pub fn init(backing_allocator: Allocator) ShardedPool {
        return .{
            .backing_allocator = backing_allocator,
        };
    }

    pub fn deinit(self: *ShardedPool) void {
        self.flush();
    }

    pub fn allocator(self: *ShardedPool, comptime shardIdFn: *const fn () u32) Allocator {
        const Adapter = struct {
            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
                const pool: *ShardedPool = @ptrCast(@alignCast(ctx));
                return pool.rawAllocOnShard(shardIdFn(), len, alignment, ret_addr);
            }

            fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
                const pool: *ShardedPool = @ptrCast(@alignCast(ctx));
                return pool.rawResize(memory, alignment, new_len, ret_addr);
            }

            fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                const pool: *ShardedPool = @ptrCast(@alignCast(ctx));
                return pool.rawRemap(memory, alignment, new_len, ret_addr);
            }

            fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
                const pool: *ShardedPool = @ptrCast(@alignCast(ctx));
                pool.rawFreeOnShard(shardIdFn(), memory, alignment, ret_addr);
            }

            const vtable: Allocator.VTable = .{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            };
        };

        return .{
            .ptr = @ptrCast(self),
            .vtable = &Adapter.vtable,
        };
    }

    pub fn allocatorForShard(self: *ShardedPool, comptime shard_id: u32) Allocator {
        const ShardIdProvider = struct {
            fn id() u32 {
                return shard_id;
            }
        };
        return self.allocator(ShardIdProvider.id);
    }

    pub fn rawAllocOnShard(
        self: *ShardedPool,
        shard_id: u32,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        if (classIndex(len, alignment)) |class_idx| {
            const shard = &self.shards[@as(usize, shard_id) % num_shards];
            {
                shard.lock.lock();
                defer shard.lock.unlock();
                if (shard.free_heads[class_idx]) |node| {
                    shard.free_heads[class_idx] = node.next;
                    shard.counts[class_idx] -= 1;
                    return @ptrCast(node);
                }
            }

            const slot_size = slotSize(class_idx);
            const slot_alignment = slotAlignment(class_idx);
            const batch_count = batchCountForClass(class_idx);

            var extras: [small_batch_count - 1][*]u8 = undefined;
            var extra_count: usize = 0;
            const primary = blk: {
                self.backing_lock.lock();
                defer self.backing_lock.unlock();

                const first = self.backing_allocator.rawAlloc(slot_size, slot_alignment, ret_addr) orelse
                    break :blk null;
                while (extra_count + 1 < batch_count) {
                    const extra = self.backing_allocator.rawAlloc(slot_size, slot_alignment, ret_addr) orelse break;
                    extras[extra_count] = extra;
                    extra_count += 1;
                }
                break :blk first;
            } orelse return null;

            if (extra_count > 0) {
                var evict_start: usize = extra_count;
                {
                    shard.lock.lock();
                    defer shard.lock.unlock();
                    for (0..extra_count) |i| {
                        if (shard.counts[class_idx] < max_cached_per_class) {
                            const node: *FreeNode = @ptrCast(@alignCast(extras[i]));
                            node.next = shard.free_heads[class_idx];
                            shard.free_heads[class_idx] = node;
                            shard.counts[class_idx] += 1;
                        } else {
                            evict_start = i;
                            break;
                        }
                    }
                }
                if (evict_start < extra_count) {
                    self.backing_lock.lock();
                    defer self.backing_lock.unlock();
                    for (evict_start..extra_count) |i| {
                        self.backing_allocator.rawFree(extras[i][0..slot_size], slot_alignment, ret_addr);
                    }
                }
            }

            return primary;
        }

        return self.backingAlloc(len, alignment, ret_addr);
    }

    pub fn rawResize(
        self: *ShardedPool,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const old_class = classIndex(memory.len, alignment);
        const new_class = classIndex(new_len, alignment);
        if (old_class) |old_idx| {
            return if (new_class) |new_idx| old_idx == new_idx else false;
        }
        if (new_class != null) return false;
        return self.backingResize(memory, alignment, new_len, ret_addr);
    }

    pub fn rawRemap(
        self: *ShardedPool,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const old_class = classIndex(memory.len, alignment);
        const new_class = classIndex(new_len, alignment);
        if (old_class) |old_idx| {
            if (new_class) |new_idx| {
                if (old_idx == new_idx) return memory.ptr;
            }
            return null;
        }
        if (new_class != null) return null;
        return self.backingRemap(memory, alignment, new_len, ret_addr);
    }

    pub fn rawFreeOnShard(
        self: *ShardedPool,
        shard_id: u32,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        if (memory.len == 0) return;

        if (classIndex(memory.len, alignment)) |class_idx| {
            const shard = &self.shards[@as(usize, shard_id) % num_shards];
            {
                shard.lock.lock();
                defer shard.lock.unlock();
                if (shard.counts[class_idx] < max_cached_per_class) {
                    const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
                    node.next = shard.free_heads[class_idx];
                    shard.free_heads[class_idx] = node;
                    shard.counts[class_idx] += 1;
                    return;
                }
            }

            const slot_size = slotSize(class_idx);
            const slot_alignment = slotAlignment(class_idx);
            self.backingFree(memory.ptr[0..slot_size], slot_alignment, ret_addr);
            return;
        }

        self.backingFree(memory, alignment, ret_addr);
    }

    pub fn flush(self: *ShardedPool) void {
        for (0..num_shards) |shard_idx| {
            self.flushShard(shard_idx);
        }
    }

    pub fn flushShard(self: *ShardedPool, shard_idx: usize) void {
        const shard = &self.shards[shard_idx % num_shards];
        var detached: [num_classes]?*FreeNode = @splat(null);
        {
            shard.lock.lock();
            defer shard.lock.unlock();
            for (0..num_classes) |class_idx| {
                detached[class_idx] = shard.free_heads[class_idx];
                shard.free_heads[class_idx] = null;
                shard.counts[class_idx] = 0;
            }
        }

        const ret_addr = @returnAddress();
        for (0..num_classes) |class_idx| {
            const slot_size = slotSize(class_idx);
            const slot_alignment = slotAlignment(class_idx);
            var node_opt = detached[class_idx];
            while (node_opt) |node| {
                const next = node.next;
                const ptr: [*]u8 = @ptrCast(node);
                self.backingFree(ptr[0..slot_size], slot_alignment, ret_addr);
                node_opt = next;
            }
        }
    }

    pub fn cachedCount(self: *ShardedPool, shard_idx: usize, class_idx: usize) u16 {
        std.debug.assert(class_idx < num_classes);
        const shard = &self.shards[shard_idx % num_shards];
        shard.lock.lock();
        defer shard.lock.unlock();
        return shard.counts[class_idx];
    }

    fn backingAlloc(self: *ShardedPool, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        self.backing_lock.lock();
        defer self.backing_lock.unlock();
        return self.backing_allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn backingResize(self: *ShardedPool, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        self.backing_lock.lock();
        defer self.backing_lock.unlock();
        return self.backing_allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn backingRemap(self: *ShardedPool, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        self.backing_lock.lock();
        defer self.backing_lock.unlock();
        return self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn backingFree(self: *ShardedPool, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        self.backing_lock.lock();
        defer self.backing_lock.unlock();
        self.backing_allocator.rawFree(memory, alignment, ret_addr);
    }
};

var global_pool: ShardedPool = ShardedPool.init(baseAllocator());

pub fn globalPool() *ShardedPool {
    return &global_pool;
}

pub fn allocator(comptime shardIdFn: *const fn () u32) Allocator {
    return global_pool.allocator(shardIdFn);
}

pub fn flushGlobalShards() void {
    global_pool.flush();
}

test "size class mapping covers 16..4096 bytes and alignment constraints" {
    try std.testing.expectEqual(@as(usize, 64), @alignOf(Shard));
    try std.testing.expectEqual(@as(?usize, null), classIndex(0, .@"1"));

    const expected_ranges = [_]struct { min: usize, max: usize, class_idx: usize, slot_size: usize }{
        .{ .min = 1, .max = 16, .class_idx = 0, .slot_size = 16 },
        .{ .min = 17, .max = 32, .class_idx = 1, .slot_size = 32 },
        .{ .min = 33, .max = 64, .class_idx = 2, .slot_size = 64 },
        .{ .min = 65, .max = 128, .class_idx = 3, .slot_size = 128 },
        .{ .min = 129, .max = 256, .class_idx = 4, .slot_size = 256 },
        .{ .min = 257, .max = 512, .class_idx = 5, .slot_size = 512 },
        .{ .min = 513, .max = 1024, .class_idx = 6, .slot_size = 1024 },
        .{ .min = 1025, .max = 2048, .class_idx = 7, .slot_size = 2048 },
        .{ .min = 2049, .max = 4096, .class_idx = 8, .slot_size = 4096 },
    };

    for (expected_ranges) |range| {
        try std.testing.expectEqual(@as(?usize, range.class_idx), classIndex(range.min, .@"1"));
        try std.testing.expectEqual(@as(?usize, range.class_idx), classIndex(range.max, .@"1"));
        try std.testing.expectEqual(range.slot_size, slotSize(range.class_idx));
    }

    // Alignment promotion within slab range
    try std.testing.expectEqual(@as(?usize, 1), classIndex(8, .fromByteUnits(32)));
    try std.testing.expectEqual(@as(?usize, 2), classIndex(8, .fromByteUnits(64)));

    // Oversized length or alignment > 64 falls back to backing allocator (null class)
    try std.testing.expectEqual(@as(?usize, null), classIndex(4097, .@"1"));
    try std.testing.expectEqual(@as(?usize, null), classIndex(8192, .@"16"));
    try std.testing.expectEqual(@as(?usize, null), classIndex(16, .fromByteUnits(128)));
    try std.testing.expectEqual(@as(?usize, null), classIndex(256, .fromByteUnits(256)));
}

test "slab allocation and lifo freelist reuse within a shard" {
    var pool = ShardedPool.init(std.testing.allocator);
    defer pool.deinit();

    const shard_alloc = pool.allocatorForShard(3);

    const first = try shard_alloc.alloc(u8, 24);
    @memset(first, 0xAB);
    const first_addr = @intFromPtr(first.ptr);
    // Class 1 (32B) refills a batch of 4 slots: 1 returned + 3 cached in shard.
    try std.testing.expectEqual(@as(u16, 3), pool.cachedCount(3, 1));

    shard_alloc.free(first);
    try std.testing.expectEqual(@as(u16, 4), pool.cachedCount(3, 1));

    // Request a different size in the same size class (class 1: 17..32 bytes)
    const second = try shard_alloc.alloc(u8, 31);
    try std.testing.expectEqual(first_addr, @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(u16, 3), pool.cachedCount(3, 1));

    shard_alloc.free(second);
    try std.testing.expectEqual(@as(u16, 4), pool.cachedCount(3, 1));
}

test "same-class resize and remap succeed in O(1) and cross-class realloc preserves data" {
    var pool = ShardedPool.init(std.testing.allocator);
    defer pool.deinit();

    const alloc = pool.allocatorForShard(1);

    var buf = try alloc.alloc(u8, 18);
    for (buf, 0..) |*b, i| b.* = @intCast(i + 1);
    const initial_ptr = buf.ptr;

    // Same class (class 1: 17..32 bytes) resize and remap happen in-place
    try std.testing.expect(alloc.resize(buf, 32));
    buf = buf.ptr[0..32];
    for (18..32) |i| buf[i] = @intCast(i + 1);

    const remapped = alloc.remap(buf, 20);
    try std.testing.expect(remapped != null);
    try std.testing.expectEqual(initial_ptr, remapped.?.ptr);
    buf = remapped.?;

    // Cross-class resize returns false so realloc allocates a new class slot and copies
    try std.testing.expect(!alloc.resize(buf, 64));
    buf = try alloc.realloc(buf, 64);
    for (0..20) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), buf[i]);
    }

    // Grow beyond max slab size (4096 -> 8192) and shrink back into slab size (8192 -> 128)
    buf = try alloc.realloc(buf, 8192);
    for (0..20) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), buf[i]);
    }
    try std.testing.expect(!alloc.resize(buf, 128));
    buf = try alloc.realloc(buf, 128);
    for (0..20) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), buf[i]);
    }

    alloc.free(buf);
}

test "cross-shard allocation and deallocation with dynamic shard routing" {
    const Context = struct {
        var active_shard: u32 = 0;
        fn currentShard() u32 {
            return active_shard;
        }
    };

    var pool = ShardedPool.init(std.testing.allocator);
    defer pool.deinit();

    const dynamic_alloc = pool.allocator(Context.currentShard);

    // Allocate on shard 2
    Context.active_shard = 2;
    const slice = try dynamic_alloc.alignedAlloc(u8, .fromByteUnits(32), 48);
    @memset(slice, 0x5A);

    // Free on shard 11 (and verify modulo wrapping on shard 11 + 16)
    Context.active_shard = 11 + @as(u32, @intCast(num_shards));
    dynamic_alloc.free(slice);

    const class_idx = classIndex(48, .fromByteUnits(32)).?;
    try std.testing.expectEqual(@as(u16, 3), pool.cachedCount(2, class_idx));
    try std.testing.expectEqual(@as(u16, 1), pool.cachedCount(11, class_idx));

    // Reuse from shard 11
    Context.active_shard = 11;
    const reused = try dynamic_alloc.alloc(u8, 64);
    try std.testing.expectEqual(slice.ptr, reused.ptr);
    dynamic_alloc.free(reused);
}

test "high-water-mark eviction returns excess blocks to backing allocator" {
    var pool = ShardedPool.init(std.testing.allocator);
    defer pool.deinit();

    const alloc = pool.allocatorForShard(5);
    const total = @as(usize, max_cached_per_class) + 20;
    var blocks: [total][]u8 = undefined;

    for (&blocks) |*slot| {
        slot.* = try alloc.alloc(u8, 128);
    }

    const class_idx = classIndex(128, .@"1").?;
    try std.testing.expectEqual(@as(u16, 0), pool.cachedCount(5, class_idx));

    for (blocks, 0..) |block, idx| {
        alloc.free(block);
        const expected: u16 = @intCast(@min(idx + 1, @as(usize, max_cached_per_class)));
        try std.testing.expectEqual(expected, pool.cachedCount(5, class_idx));
    }

    try std.testing.expectEqual(max_cached_per_class, pool.cachedCount(5, class_idx));
    pool.flushShard(5);
    try std.testing.expectEqual(@as(u16, 0), pool.cachedCount(5, class_idx));
}

test "global allocator entry point and flushGlobalShards" {
    const Provider = struct {
        fn shardId() u32 {
            return 7;
        }
    };
    const global_alloc = comptime allocator(Provider.shardId);
    const mem = try global_alloc.alloc(u8, 256);
    @memset(mem, 0x7F);
    global_alloc.free(mem);
    flushGlobalShards();
    try std.testing.expectEqual(@as(u16, 0), globalPool().cachedCount(7, classIndex(256, .@"1").?));
}
