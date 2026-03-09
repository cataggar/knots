# Knots

Knots is a high performance cross-platform immediate-mode GUI library written in Zig.

## Requirements

Zig 0.16.0-dev.2905+5d71e3051 and newer.

## Install

```sh
zig fetch --save git+https://codeberg.org/shahwali/knots.git
```

## Minimal app

```zig
// build.zig
const GPUBackend = @import("knots").GPUBackend;

const knots = b.dependency("knots", .{ .target = target, .optimize = optimize, .gpu_backends = &[_]GPUBackend{ .vulkan, .wgpu } });


exe.root_module.addImport(knots.module("knots"));
// or
mod.addImport(knots.module("knots"));
```

```zig
const std = @import("std");
const knots = @import("knots");

pub fn main(init: std.process.Init) !void {
    var app = try knots.App.init(init.io, init.gpa, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Playground",
        },
    });
    defer app.deinit();

    try app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const size = app.window.getSize();
    return app.e(.{
        knots.component.Rect{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .init(16, 16, 16, 16),
            .dir = .column,
            .key = .src(@src()),
        },
    });
}
```

## Supported platforms:

| OS      | Supported GPU APIs         |
| ------- | -------------------------- |
| macOS   | WGPU and Vulkan (MoltenVK) |
| Linux   | WGPU and Vulkan            |
| Windows | WGPU and Vulkan            |

## Examples

See [examples/playground](examples/playground).

## Known limitations

- Currently there is a hard dependency on GLFW for windowing.
- Two C++ dependencies are currently used for text rendering, FreeType and HarfBuzz.
- Only 1 font can be loaded at a time, in general, text rendering is in very early stages.
- No X11 support yet.
