const is_browser_wasm = @import("builtin").cpu.arch.isWasm();
const browser_gpu = @import("browser_gpu");

comptime {
    if (!is_browser_wasm) {
        @compileError("The webgl2 GPU backend is only supported on browser WebAssembly targets");
    }
}

pub const Device = browser_gpu.Device;
pub const Surface = browser_gpu.Surface;
pub const Buffer = browser_gpu.Buffer;
pub const Pipeline = browser_gpu.Pipeline;
pub const BindGroup = browser_gpu.BindGroup;
pub const Frame = browser_gpu.Frame;
pub const RenderPass = browser_gpu.RenderPass;
pub const Texture = browser_gpu.Texture;
pub const Sampler = browser_gpu.Sampler;
