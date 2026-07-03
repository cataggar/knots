const zjb = @import("zjb");

/// Set once `requestDeviceAsync`'s promise chain resolves; read by
/// `Context.init` (called synchronously, well after this point, from the
/// wasm entry point's `onReady` callback -- see Phase 5's `main_wasm.zig`).
pub var resolved_adapter: ?zjb.Handle = null;
pub var resolved_device: ?zjb.Handle = null;

var pending_on_ready: ?*const fn (adapter: zjb.Handle, device: zjb.Handle) callconv(.c) void = null;

/// Kicks off the only two async round trips this backend needs:
/// `navigator.gpu.requestAdapter()` then `adapter.requestDevice()`. Must be
/// called before constructing `App`/the GPU `Context` -- see
/// thoughts/wasm-zjb-backend/plans/implementation-plan.md, Phase 4's
/// "Key Discoveries" note on why this can't just be done inside
/// `Context.init` itself (WebGPU's adapter/device requests are Promises,
/// and a single-threaded wasm call can never block waiting on one).
pub fn requestDeviceAsync(on_ready: *const fn (adapter: zjb.Handle, device: zjb.Handle) callconv(.c) void) void {
    pending_on_ready = on_ready;

    const navigator = zjb.global("navigator");
    const gpu_obj = navigator.get("gpu", zjb.Handle);
    defer gpu_obj.release();
    if (gpu_obj.isNull()) @panic("navigator.gpu is unavailable -- this browser doesn't support WebGPU");

    const promise = gpu_obj.call("requestAdapter", .{}, zjb.Handle);
    defer promise.release();
    promise.call("then", .{zjb.fnHandle("knots_webgpu_js_onAdapterReady", &onAdapterReady)}, void);
}

fn onAdapterReady(adapter: zjb.Handle) callconv(.c) void {
    if (adapter.isNull()) @panic("navigator.gpu.requestAdapter() resolved to null -- no suitable GPU adapter found");
    resolved_adapter = adapter;

    const promise = adapter.call("requestDevice", .{}, zjb.Handle);
    defer promise.release();
    promise.call("then", .{zjb.fnHandle("knots_webgpu_js_onDeviceReady", &onDeviceReady)}, void);
}

fn onDeviceReady(device: zjb.Handle) callconv(.c) void {
    resolved_device = device;
    const cb = pending_on_ready orelse @panic("onDeviceReady fired without a pending callback");
    cb(resolved_adapter.?, device);
}
