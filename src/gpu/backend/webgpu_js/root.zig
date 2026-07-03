const std = @import("std");
const gpu = @import("gpu");

// Placeholder for the zjb-based WebGPU backend (wasm32-freestanding).
// Wires up the `GPUBackend.webgpu_js` enum tag and `build.zig` module graph
// ahead of the real implementation (see thoughts/wasm-zjb-backend/plans/implementation-plan.md, Phase 4).
pub fn init(_: std.mem.Allocator, _: gpu.Context.WindowHandle, _: gpu.Context.Config) !gpu.Context {
    @panic("webgpu_js backend is not yet implemented (Phase 4 of thoughts/wasm-zjb-backend/plans/implementation-plan.md)");
}
