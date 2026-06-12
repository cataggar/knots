//! Minimal example: send a JSON request and parse the JSON response.
//!
//! Clicking the button dispatches an HTTP POST off the UI thread. The request
//! body is built from a Zig struct (JSON in) and the response is parsed back
//! into a struct (JSON out). The wakeup lands on the main loop without blocking
//! rendering.

const std = @import("std");
const knots = @import("knots");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;

const is_emscripten = @import("builtin").os.tag == .emscripten;

const url = "https://httpbin.org/post";

const Payload = struct {
    library: []const u8,
    question: []const u8,
};

const Outcome = union(enum) {
    /// Heap-allocated with `std.heap.smp_allocator`; owned by the receiver.
    ok: []u8,
    /// Static string (an error name); not freed.
    err: []const u8,
};

const Context = struct {
    app: knots.App,
    pending: bool = false,
    result: []const u8 = "Click \"Fetch\" to send a JSON request.",
    result_owned: bool = false,

    fn setResult(self: *Context, outcome: Outcome) void {
        if (self.result_owned) std.heap.smp_allocator.free(@constCast(self.result));
        switch (outcome) {
            .ok => |t| {
                self.result = t;
                self.result_owned = true;
            },
            .err => |e| {
                self.result = e;
                self.result_owned = false;
            },
        }
    }

    fn deinit(self: *Context) void {
        if (self.result_owned) std.heap.smp_allocator.free(@constCast(self.result));
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try knots.App.init(init.io, init.gpa, .{
        .window = .{
            .width = 900,
            .height = 480,
            .title = "Fetch JSON",
        },
    });
    var ctx = Context{ .app = app };
    defer {
        ctx.app.deinit();
        ctx.deinit();
    }

    try ctx.app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const ctx: *Context = @fieldParentPtr("app", app);

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .grow(),
            .height = .grow(),
            .dir = .column,
            .gap = 16,
            .padding = .init(24, 24, 24, 24),
            .style = .{ .color = .{ .color = .{ .value = .{ 0.97, 0.97, 0.98, 1.0 } } } },
        },
        .{
            Button{
                .key = .src(@src()),
                .width = .fixed(140),
                .height = .fixed(36),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .hover_anim = .{},
                .justify = .center,
                .@"align" = .center,
                .onClick = startFetch,
                .text = .{ .content = if (ctx.pending) "Fetching..." else "Fetch" },
            },
            Spacer{ .height = .fixed(4), .key = .src(@src()) },
            Text{
                .key = .src(@src()),
                .content = ctx.result,
                .size = .sm,
                .color = .{ .color = .{ .value = .{ 0.1, 0.1, 0.12, 1.0 } } },
            },
        },
    });

    if (ctx.pending) try app.signal(.redraw);
}

fn startFetch(app: *knots.App) !void {
    const ctx: *Context = @fieldParentPtr("app", app);
    if (ctx.pending) return;

    if (is_emscripten) {
        ctx.setResult(.{ .err = "HTTP fetch is not supported on the web build." });
        try app.signal(.redraw);
        return;
    }

    ctx.pending = true;
    try app.dispatch(fetchEcho, .{app.io}, onFetch);
    try app.signal(.redraw);
}

/// Runs on a worker thread. Errors are folded into the result so the callback
/// can render them.
fn fetchEcho(io: std.Io) Outcome {
    return doFetch(io) catch |e| .{ .err = @errorName(e) };
}

fn doFetch(io: std.Io) !Outcome {
    const gpa = std.heap.smp_allocator;

    const payload = Payload{
        .library = "knots",
        .question = "json in and out?",
    };

    // JSON in: serialize the request body from a struct.
    const body = try std.json.Stringify.valueAlloc(gpa, payload, .{});
    defer gpa.free(body);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var response: std.Io.Writer.Allocating = .init(gpa);
    defer response.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .response_writer = &response.writer,
    });

    // JSON out: parse the echoed response back into a struct.
    const Echo = struct {
        url: []const u8 = "",
        json: Payload = .{ .library = "", .question = "" },
    };
    const parsed = try std.json.parseFromSlice(
        Echo,
        gpa,
        response.writer.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const text = try std.fmt.allocPrint(
        gpa,
        "HTTP {d}\n\nsent    -> library={s}, question={s}\nechoed  <- url={s}\n           library={s}, question={s}",
        .{
            @intFromEnum(result.status),
            payload.library,
            payload.question,
            parsed.value.url,
            parsed.value.json.library,
            parsed.value.json.question,
        },
    );
    return .{ .ok = text };
}

fn onFetch(app: *knots.App, outcome: Outcome) !void {
    const ctx: *Context = @fieldParentPtr("app", app);
    ctx.setResult(outcome);
    ctx.pending = false;
    try app.signal(.redraw);
}
