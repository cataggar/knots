const builtin = @import("builtin");

pub const App = @import("App.zig");
pub const component = @import("component");
pub const control = @import("control");
pub const animation = @import("animation");
pub const ui = @import("ui");
pub const debug = @import("debug");

/// Only meaningful for the wasm32-freestanding target: exposes `webgpu_js`'s
/// async adapter/device bootstrap so the wasm entry point can call
/// `gpu_webgpu_js.bootstrap.requestDeviceAsync(...)` before constructing
/// `App` (WebGPU's `requestAdapter`/`requestDevice` are Promises, and a
/// single-threaded wasm call can never block waiting on one -- see
/// thoughts/wasm-zjb-backend/plans/implementation-plan.md, Phase 4).
pub const gpu_webgpu_js = if (builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding)
    @import("gpu_webgpu_js")
else
    struct {};
