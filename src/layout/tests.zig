const std = @import("std");
const Context = @import("Context.zig");
const Element = @import("Element.zig");
const Grid = @import("Grid.zig");

fn approxEq(a: f32, b: f32) !void {
    try std.testing.expectApproxEqAbs(a, b, 0.001);
}

fn expectRect(el: *Element, x: f32, y: f32, w: f32, h: f32) !void {
    try approxEq(el.box.x(), x);
    try approxEq(el.box.y(), y);
    try approxEq(el.box.w(), w);
    try approxEq(el.box.h(), h);
}

fn noScroll(_: *anyopaque, _: Element.Id) [2]f32 {
    return .{ 0, 0 };
}

fn runLayout(ctx: *Context) !void {
    ctx.computeSizes();
    try ctx.computeLayout(.{ .ctx = undefined, .getFn = @ptrCast(&noScroll) }, 8);
}

fn initCtx() Context {
    var ctx = Context.init(std.testing.allocator);
    ctx.reset();
    return ctx;
}

test "single fixed element" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(300) });
    defer ctx.close();

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 400, 300);
}

test "row: one fixed, one grow" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(100), .height = .grow() });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 400, 50);
    try expectRect(ctx.pool.get(1), 0, 0, 100, 50); // fixed width, grow height fills parent
    try expectRect(ctx.pool.get(2), 100, 0, 300, 50); // grows to fill remaining width
}

test "row: centered grow child fills the space without an offset" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row, .justify = .center });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(100), .height = .grow() });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 100, 50);
    try expectRect(ctx.pool.get(2), 100, 0, 300, 50);
}

test "row: centering counts the gaps" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row, .justify = .center, .gap = 20 });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(100), .height = .grow() });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(100), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // 400 - 100 - 20 - 100 leaves 180, half of it on each side.
    try expectRect(ctx.pool.get(1), 90, 0, 100, 50);
    try expectRect(ctx.pool.get(2), 210, 0, 100, 50);
}

test "row: space_between puts the free space between the gaps" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row, .justify = .space_between, .gap = 20 });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(100), .height = .grow() });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(100), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 100, 50);
    try expectRect(ctx.pool.get(2), 300, 0, 100, 50);
}

test "row: two grow children split space equally" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 200, 50);
    try expectRect(ctx.pool.get(2), 200, 0, 200, 50);
}

test "row: gap is accounted for in free space" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row, .gap = 10 });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // 400 - 10 gap = 390, split equally = 195 each
    try expectRect(ctx.pool.get(1), 0, 0, 195, 50);
    try expectRect(ctx.pool.get(2), 205, 0, 195, 50); // 195 + 10 gap = 205
}

test "column: one fixed, one grow" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(100), .height = .fixed(400), .direction = .column });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(100) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 100, 100);
    try expectRect(ctx.pool.get(2), 0, 100, 100, 300);
}

test "fit: parent wraps children" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fit(), .height = .fit(), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(80), .height = .fixed(40) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(120), .height = .fixed(60) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // width = 80 + 120 = 200, height = max(40, 60) = 60
    try expectRect(ctx.pool.get(root), 0, 0, 200, 60);
    try expectRect(ctx.pool.get(1), 0, 0, 80, 40);
    try expectRect(ctx.pool.get(2), 80, 0, 120, 60);
}

test "padding: offsets children and shrinks available space" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{
        .width = .fixed(400),
        .height = .fixed(200),
        .direction = .row,
        .padding = .init(10, 20, 10, 20),
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // child fills inner area: 400-40 wide, 200-20 tall, offset by padding
    try expectRect(ctx.pool.get(1), 20, 10, 360, 180);
}

test "min/max: grow does not exceed max" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .{ .kind = .grow, .max = 100 }, .height = .fixed(50) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // a is clamped to 100, b gets remaining 300
    try expectRect(ctx.pool.get(1), 0, 0, 100, 50);
    try expectRect(ctx.pool.get(2), 100, 0, 300, 50);
}

test "nested: row inside column" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(300), .direction = .column });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(50), .direction = .row });
        defer ctx.close();
        {
            _ = try ctx.open(2, .{ .width = .fixed(100), .height = .grow() });
            defer ctx.close();
        }
        {
            _ = try ctx.open(3, .{ .width = .grow(), .height = .grow() });
            defer ctx.close();
        }
    }
    {
        _ = try ctx.open(4, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 400, 300);
    try expectRect(ctx.pool.get(1), 0, 0, 400, 50); // row
    try expectRect(ctx.pool.get(2), 0, 0, 100, 50); // a
    try expectRect(ctx.pool.get(3), 100, 0, 300, 50); // b
    try expectRect(ctx.pool.get(4), 0, 50, 400, 250); // footer grows to fill remaining
}

test "children stack at parent origin" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(200), .height = .fixed(200), .direction = .layer });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(120), .height = .fixed(80) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(60), .height = .fixed(40) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 200, 200);
    try expectRect(ctx.pool.get(1), 0, 0, 120, 80);
    try expectRect(ctx.pool.get(2), 0, 0, 60, 40);
}

test "fit parent sizes to max(child) on both axes" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fit(), .height = .fit(), .direction = .layer });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(100), .height = .fixed(80) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(150), .height = .fixed(40) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 150, 80);
}

test "2x2 fr tracks split parent equally" {
    var ctx = initCtx();
    defer ctx.deinit();

    const cols = [_]Grid.Track{ .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]Grid.Track{ .{ .fr = 1 }, .{ .fr = 1 } };
    const root = try ctx.open(0, .{
        .width = .fixed(200),
        .height = .fixed(100),
        .direction = .grid,
        .grid_template = .{ .cols = &cols, .rows = &rows },
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .grid_placement = .{ .row = 0, .col = 0 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .grid_placement = .{ .row = 0, .col = 1 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(3, .{ .grid_placement = .{ .row = 1, .col = 0 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(4, .{ .grid_placement = .{ .row = 1, .col = 1 } });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 200, 100);
    try expectRect(ctx.pool.get(1), 0, 0, 100, 50);
    try expectRect(ctx.pool.get(2), 100, 0, 100, 50);
    try expectRect(ctx.pool.get(3), 0, 50, 100, 50);
    try expectRect(ctx.pool.get(4), 100, 50, 100, 50);
}

test "fixed + fr column with gap" {
    var ctx = initCtx();
    defer ctx.deinit();

    const cols = [_]Grid.Track{ .{ .fixed = 60 }, .{ .fr = 1 } };
    const rows = [_]Grid.Track{.{ .fixed = 40 }};
    _ = try ctx.open(0, .{
        .width = .fixed(200),
        .height = .fixed(40),
        .direction = .grid,
        .grid_template = .{ .cols = &cols, .rows = &rows },
        .gap = 10,
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .grid_placement = .{ .row = 0, .col = 0 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .grid_placement = .{ .row = 0, .col = 1 } });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 60, 40);
    // fr column gets remaining: 200 - 60 - 10 (gap) = 130
    try expectRect(ctx.pool.get(2), 70, 0, 130, 40);
}

test "col span covers multiple tracks" {
    var ctx = initCtx();
    defer ctx.deinit();

    const cols = [_]Grid.Track{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]Grid.Track{.{ .fixed = 50 }};
    const root = try ctx.open(0, .{
        .width = .fixed(300),
        .height = .fixed(50),
        .direction = .grid,
        .grid_template = .{ .cols = &cols, .rows = &rows },
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .grid_placement = .{ .row = 0, .col = 0, .col_span = 2 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .grid_placement = .{ .row = 0, .col = 2 } });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 300, 50);
    // Two fr columns at 100 each: 200 wide.
    try expectRect(ctx.pool.get(1), 0, 0, 200, 50);
    try expectRect(ctx.pool.get(2), 200, 0, 100, 50);
}

test "grid: absolute children use parent-local offset" {
    var ctx = initCtx();
    defer ctx.deinit();

    const cols = [_]Grid.Track{.{ .fr = 1 }};
    const rows = [_]Grid.Track{.{ .fr = 1 }};
    _ = try ctx.open(0, .{
        .width = .fixed(200),
        .height = .fixed(100),
        .direction = .grid,
        .grid_template = .{ .cols = &cols, .rows = &rows },
        .padding = .init(10, 20, 10, 20),
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{
            .width = .fixed(30),
            .height = .fixed(20),
            .position = .absolute,
            .offset = .{ 7, 9 },
        });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 27, 19, 30, 20);
}

test "grow children fill parent independently" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(300), .height = .fixed(200), .direction = .layer });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 300, 200);
    try expectRect(ctx.pool.get(1), 0, 0, 300, 200);
    try expectRect(ctx.pool.get(2), 0, 0, 300, 200);
}

test "buildZOrder: single-layer fast path (z=0 and z=5) and multi-layer counting sort" {
    var ctx = initCtx();
    defer ctx.deinit();

    // Default single layer (z_index = 0)
    {
        const s0 = try ctx.open(10, .{ .width = .fixed(100), .height = .fixed(100) });
        defer ctx.close();
        {
            const s1 = try ctx.open(11, .{ .width = .fixed(50), .height = .fixed(50) });
            defer ctx.close();
            _ = s1;
        }
        {
            const s2 = try ctx.open(12, .{ .width = .fixed(50), .height = .fixed(50) });
            defer ctx.close();
            _ = s2;
        }
        _ = s0;
    }
    try ctx.buildZOrder();
    try std.testing.expectEqualSlices(Element.Slot, &.{ 0, 1, 2 }, ctx.zSlots(0));
    try std.testing.expectEqual(@as(usize, 0), ctx.zSlots(1).len);
    try std.testing.expectEqual(@as(usize, 0), ctx.zSlots(255).len);

    // Custom single layer (z_index = 5)
    ctx.reset();
    {
        _ = try ctx.open(20, .{ .width = .fixed(100), .height = .fixed(100), .z_index = 5 });
        defer ctx.close();
        {
            _ = try ctx.open(21, .{ .width = .fixed(50), .height = .fixed(50) });
            defer ctx.close();
        }
    }
    try ctx.buildZOrder();
    try std.testing.expectEqual(@as(usize, 0), ctx.zSlots(0).len);
    try std.testing.expectEqual(@as(usize, 0), ctx.zSlots(4).len);
    try std.testing.expectEqualSlices(Element.Slot, &.{ 0, 1 }, ctx.zSlots(5));
    try std.testing.expectEqual(@as(usize, 0), ctx.zSlots(6).len);

    // Multi-layer counting sort
    ctx.reset();
    {
        _ = try ctx.open(30, .{ .width = .fixed(100), .height = .fixed(100), .z_index = 0 });
        defer ctx.close();
        {
            _ = try ctx.open(31, .{ .width = .fixed(50), .height = .fixed(50), .z_index = 10 });
            defer ctx.close();
        }
        {
            _ = try ctx.open(32, .{ .width = .fixed(50), .height = .fixed(50), .z_index = 0 });
            defer ctx.close();
        }
        {
            _ = try ctx.open(33, .{ .width = .fixed(50), .height = .fixed(50), .z_index = 200 });
            defer ctx.close();
        }
    }
    try ctx.buildZOrder();
    try std.testing.expectEqualSlices(Element.Slot, &.{ 0, 2 }, ctx.zSlots(0));
    try std.testing.expectEqualSlices(Element.Slot, &.{1}, ctx.zSlots(10));
    try std.testing.expectEqualSlices(Element.Slot, &.{3}, ctx.zSlots(200));
    try std.testing.expectEqual(@as(usize, 0), ctx.zSlots(1).len);
}

test "slotForId: lazy population after open, openRoot, and reset" {
    var ctx = initCtx();
    defer ctx.deinit();

    const s0 = try ctx.open(100, .{ .width = .fixed(200), .height = .fixed(100) });
    const s1 = try ctx.open(101, .{ .width = .fixed(50), .height = .fixed(50) });
    ctx.close();
    ctx.close();

    const s2 = try ctx.openRoot(102, .{ .width = .fixed(80), .height = .fixed(40) });
    ctx.close();
    ctx.pool.get(s2).box.setX(15);
    ctx.pool.get(s2).box.setY(25);

    // Also exercise the lazy population loop explicitly even in Debug builds.
    ctx.id_to_slot.clearRetainingCapacity();
    try ctx.id_to_slot.ensureTotalCapacity(ctx.allocator, @intCast(ctx.pool.elements.capacity));
    ctx.id_to_slot_populated = 0;

    try std.testing.expectEqual(@as(?Element.Slot, null), ctx.slotForId(Element.INVALID_ID));
    try std.testing.expectEqual(@as(?Element.Slot, s0), ctx.slotForId(100));
    try std.testing.expectEqual(@as(?Element.Slot, s1), ctx.slotForId(101));
    try std.testing.expectEqual(@as(?Element.Slot, s2), ctx.slotForId(102));
    try std.testing.expectEqual(@as(?Element.Slot, null), ctx.slotForId(999));

    try runLayout(&ctx);
    try expectRect(ctx.pool.get(s2), 15, 25, 80, 40);

    ctx.reset();
    try std.testing.expectEqual(@as(?Element.Slot, null), ctx.slotForId(100));
    try std.testing.expectEqual(@as(?Element.Slot, null), ctx.slotForId(102));
    try std.testing.expect(!ctx.has_extra_roots);

    // Stress-test lazy capacity across all HashMap 80% load-factor windows (1..100 elements).
    for (1..100) |count| {
        ctx.reset();
        const root_s = try ctx.open(1000, .{ .width = .fixed(100), .height = .fixed(100) });
        for (1..count) |k| {
            _ = try ctx.open(@intCast(1000 + k), .{ .width = .fixed(10), .height = .fixed(10) });
            ctx.close();
        }
        ctx.close();
        // Simulate non-Debug lazy state by clearing entries while keeping open()'s reserved capacity.
        ctx.id_to_slot.clearRetainingCapacity();
        ctx.id_to_slot_populated = 0;

        try std.testing.expectEqual(@as(?Element.Slot, root_s), ctx.slotForId(1000));
        for (1..count) |k| {
            try std.testing.expectEqual(@as(?Element.Slot, @intCast(k)), ctx.slotForId(@intCast(1000 + k)));
        }
    }
}

test "row: combined percent, grow (unclamped and clamped), fit, and absolute children across alignments" {
    var ctx = initCtx();
    defer ctx.deinit();

    const justifications = [_]Element.Justify{ .start, .center, .end };
    for (justifications) |justify| {
        ctx.reset();

        // Total width 500, padding 10 left/right => available 480.
        // 4 static children => 3 gaps of 10 = 30 => main_base = 450.
        // Child 1 (.percent 0.2): 0.2 * 450 = 90.
        // Child 2 (.fit wrapping 60x20 child): 60.
        // Remaining free for 2 grow children = 480 - (90 + 60 + 30) = 300.
        // Child 3 (.grow clamped to max 100): 100.
        // Child 4 (.grow unclamped): gets remaining 200.
        // Child 5 (.absolute at offset (12, 8) with 25% width/50% height): does not affect static count or gaps!
        const root = try ctx.open(1, .{
            .width = .fixed(500),
            .height = .fixed(100),
            .padding = .init(10, 10, 10, 10),
            .gap = 10,
            .direction = .row,
            .justify = justify,
        });
        {
            _ = try ctx.open(2, .{ .width = .percent(0.2), .height = .percent(0.5) });
            ctx.close();

            _ = try ctx.open(3, .{ .width = .fit(), .height = .fit(), .direction = .row });
            {
                _ = try ctx.open(30, .{ .width = .fixed(60), .height = .fixed(20) });
                ctx.close();
            }
            ctx.close();

            _ = try ctx.open(4, .{ .width = .{ .kind = .grow, .max = 100 }, .height = .grow() });
            ctx.close();

            _ = try ctx.open(5, .{ .width = .grow(), .height = .grow() });
            ctx.close();

            _ = try ctx.open(6, .{
                .width = .percent(0.25),
                .height = .percent(0.5),
                .position = .absolute,
                .offset = .{ 12, 8 },
            });
            ctx.close();
        }
        ctx.close();

        try std.testing.expectEqual(@as(u32, 4), ctx.pool.get(root).child_count);
        try std.testing.expect(ctx.pool.get(root).has_absolute_child);

        try runLayout(&ctx);

        // Cross size = 100 - 20 = 80.
        try expectRect(ctx.pool.get(1), 10, 10, 90, 40);
        try expectRect(ctx.pool.get(2), 110, 10, 60, 20);
        try expectRect(ctx.pool.get(4), 180, 10, 100, 80);
        try expectRect(ctx.pool.get(5), 290, 10, 200, 80);
        // Absolute child: content_w = 480, content_h = 80 => w = 120, h = 40, x = 10 + 12 = 22, y = 10 + 8 = 18.
        try expectRect(ctx.pool.get(6), 22, 18, 120, 40);
    }

    // Also test non-grow children with .center and .end justify + absolute child
    for (justifications) |justify| {
        ctx.reset();
        _ = try ctx.open(1, .{
            .width = .fixed(400),
            .height = .fixed(100),
            .padding = .init(10, 10, 10, 10),
            .gap = 20,
            .direction = .row,
            .justify = justify,
        });
        {
            // Available = 380, 2 static children => 1 gap of 20 => main_base = 360.
            // Child 1: 25% of 360 = 90.
            // Child 2: fit (70).
            // Total static main + gap = 90 + 70 + 20 = 180; justify_free = 380 - 180 = 200.
            _ = try ctx.open(2, .{ .width = .percent(0.25), .height = .grow() });
            ctx.close();
            _ = try ctx.open(3, .{ .width = .fit(), .height = .fit() });
            ctx.pool.get(2).intrinsic_w = 70;
            ctx.pool.get(2).intrinsic_h = 30;
            ctx.close();
            _ = try ctx.open(4, .{
                .width = .fixed(25),
                .height = .fixed(15),
                .position = .absolute,
                .offset = .{ 5, 6 },
            });
            ctx.close();
        }
        ctx.close();

        try runLayout(&ctx);

        const base_x: f32 = switch (justify) {
            .start => 10,
            .center => 10 + 100,
            .end => 10 + 200,
            else => unreachable,
        };
        try expectRect(ctx.pool.get(1), base_x, 10, 90, 80);
        try expectRect(ctx.pool.get(2), base_x + 110, 10, 70, 30);
        try expectRect(ctx.pool.get(3), 15, 16, 25, 15);
    }
}
