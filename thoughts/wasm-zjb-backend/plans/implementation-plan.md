# New wasm backend using zjb (WebGPU without Emscripten) — Implementation Plan

## Overview

Add a second web target to knots: a window backend + GPU backend that compile
for `wasm32-freestanding` and talk to the browser's `navigator.gpu` (WebGPU)
directly via [zjb](https://github.com/scottredig/zig-javascript-bridge) (Zig
JavaScript Bridge), instead of going through Emscripten. This mirrors how
`wgpu-rs`/`egui`/`eframe` target `wasm32-unknown-unknown` with
`wasm-bindgen`/`web-sys` and no Emscripten SDK. Implements GitHub issue #1.

## Current State Analysis

- Web support today is entirely Emscripten-based:
  - Window backend: `src/window/backend/emscripten/{root,bindings,events,keymap}.zig`,
    selected in `build.zig` on `target.result.os.tag == .emscripten`.
  - GPU backend: the external `wgpu` dependency (`codeberg.org/shahwali/wgpu-bindings`,
    pinned in `build.zig.zon`) has a `buildEmscripten` path in its own `build.zig`
    that `translate-c`'s `emdawnwebgpu`'s `webgpu.h`. This requires the full
    Emscripten SDK (`emcc`) and Dawn's `emdawnwebgpu` port.
  - `examples/playground` and `examples/triangle` both build an emscripten
    target via `--use-port=emdawnwebgpu -sUSE_GLFW=3 ... -sASYNCIFY`.
- `zjb` upstream (`main`/`0.16.0` branch, confirmed via its README as of writing)
  "is only known to work with Zig 0.16.0". This repo's `zig16` branch
  (tip `8d95785`, "Port to Zig 0.16.0 (stable)") is the only branch on
  `minimum_zig_version = "0.16.0"` — the current `dev813`/`main` branches are on
  a `0.17.0-dev` snapshot. **All work for this plan must branch from `zig16`,
  not from `dev813`/`main`.**
- Fonts are embedded at comptime (`@embedFile("fonts/default.ttf")` in
  `src/ui/UI.zig:52`), not fetched at runtime, so text rendering needs no
  async asset loading — this significantly de-risks the first milestone.
- `examples/triangle` is not a raw-GPU demo: it runs the full `knots.App`
  (window + renderer + ui + `knots.debug.DevTools`, which renders text), so
  "hello triangle" on the new backend exercises nearly the whole stack anyway.

### Key Discoveries

- **Async adapter/device acquisition is the central technical risk.**
  WebGPU's `requestAdapter()`/`requestDevice()` are JS Promises. wasm32-freestanding
  here has no threads and no Asyncify, so a single-threaded wasm call cannot
  block-wait on a Promise (the only JS thread is blocked for the duration of
  the wasm call, so no microtask/Promise can ever resolve inside it).
  `gpu.Context.WindowHandle`'s `init` (`src/gpu/backend/root.zig:60`,
  `Backend.init`) and every backend's `Context.init` (e.g.
  `src/gpu/backend/wgpu/Context.zig:30`) are synchronous, non-`async` Zig
  functions returning `!Context` directly, and `Renderer.init` /
  `App.init` (`src/App.zig`) call them synchronously in a straight line.
  **Resolution:** keep `Context.init`'s synchronous signature unchanged.
  Do the two async round trips (`requestAdapter`, `requestDevice`) *before*
  `App.init` is ever called, in the wasm entry point
  (`examples/triangle/src/main_wasm.zig`): `main()` kicks off
  `navigator.gpu.requestAdapter().then(...)`, chains `.requestDevice().then(...)`,
  and only when the device is ready does the JS-invoked Zig callback
  construct `App` (which then calls `Context.init` synchronously). The new
  GPU backend's `Context.init` simply reads adapter/device handles that a
  small package-level "pending handles" slot (set by the bootstrap) already
  populated — it never issues the requests itself. Surface creation
  (`canvas.getContext("webgpu")`) and swapchain configuration are synchronous
  in WebGPU, so only adapter/device acquisition needs this treatment.
- **`gpu.Context.WindowHandle` is a single shared `union(enum)`**
  (`src/gpu/Context.zig:10`) consumed by exhaustive `switch` statements in
  both `src/gpu/backend/wgpu/Context.zig:31` and
  `src/gpu/backend/vulkan/Context.zig:494,511`. Adding a new `.wasm` variant
  will fail to compile on macOS/Windows/Linux until those two switches get a
  new arm (a `@panic("...")`, matching the existing `.emscripten => @panic(...)`
  pattern in the vulkan backend) — a small, self-contained, two-file fix.
  **No changes to the external `wgpu-bindings` or `vulkan-zig` dependencies
  are required.**
- Every other OS-tag-specific fork point that needs a wasm arm is already
  identified (searched `builtin.os.tag` and `.emscripten` across `src/`):
  - `src/App.zig:103` — `start()`'s main-loop dispatch
    (`inline .emscripten => emscripten_set_main_loop_arg(...)`) needs a
    requestAnimationFrame-driven arm.
  - `src/gpu/backend/root.zig:37-53` — `GPUBackend.preferred()`'s
    comptime switch (`else => @compileError(...)`) needs a case that
    returns the new backend tag when available.
  - `src/render/Renderer.zig:36-46` — `Config.validate`'s present-mode
    restriction switch has an `else => {}`, so it's not a compile blocker,
    but should get a `.fifo`-only arm mirroring `.emscripten`, since
    presentation is implicit via `requestAnimationFrame` just like Emscripten.
  - `src/component/text_edit.zig:29-32` — `super_ctrl_held` 3-way switch
    (macos/emscripten/else) needs a wasm arm (mirror `.emscripten`: accept
    either Ctrl or the browser's reported "super"/Meta key).
- `src/gpu/Context.zig`'s `VTable` is a small, bounded surface (11 functions:
  `deinit`, `createBuffer`, `createFrame`, `createPipeline`, `createBindGroup`,
  `createTexture`, `createSampler`, `resize`, `surfaceFormat`, `surfaceIsSrgb`,
  `clipSpaceYDown`), comparable in size to the existing `wgpu`/`vulkan`
  backends (`src/gpu/backend/wgpu/{Pipeline,Frame,...}.zig`, ~100-200 lines
  each). The new backend reuses the already-embedded WGSL shaders
  (`src/gpu/backend/wgpu/shaders/{ui_primitives,slug}.wgsl`, wired in
  `build.zig` via `render_mod.addAnonymousImport`), so no new shader work is
  needed for the triangle milestone.
- `zjb`'s Zig-side API (from upstream README + `example/src/main.zig`):
  `zjb.global("x")`/`zjb.constString`/`zjb.string` build `Handle`s,
  `.call(name, args, ReturnType)` / `.get`/`.set`/`.new` drive JS objects,
  `zjb.fnHandle("name", &zigFn)` exports a Zig function as a JS-callable
  handle (used for event listeners and Promise `.then` callbacks),
  `zjb.exportFn`/`zjb.exportGlobal` expose plain Zig functions/globals.
  The build side needs `zjb.artifact("generate_js")` run over the compiled
  wasm executable to emit the JS glue (`example/build.zig`,
  `simple/build.zig` show the exact `b.addRunArtifact` pattern), plus
  `example.entry = .disabled; example.rdynamic = true;` on the wasm
  executable.

## Desired End State

`examples/triangle` builds and runs in a browser on `wasm32-freestanding`
using a new `webgpu_js` GPU backend and a new `wasm` window backend, with no
Emscripten SDK involved anywhere in the build. The existing Emscripten
backend (window + wgpu/emdawnwebgpu) is untouched and keeps working exactly
as before for `examples/playground`.

**Verification:**
- `zig build test` still passes on the `zig16` branch baseline (before and
  after this work) for the existing native targets.
- `zig build -Dtarget=wasm32-wasi ...` / native `zig build` on macOS/Windows/
  Linux for `examples/triangle` and `examples/playground` still succeed
  unmodified (no regressions from the new `WindowHandle`/`GPUBackend` arms).
- A new `examples/triangle` wasm build step (e.g. `zig build -Dtarget=wasm32-freestanding`,
  served locally) produces a working page: canvas appears, sized correctly
  for the viewport/DPR, the red triangle and DevTools overlay (text) render,
  window resize updates the canvas/backbuffer, and mouse/keyboard input reach
  the app (e.g. DevTools toggle, drag-to-resize behavior where applicable).
- No `emcc`/Emscripten SDK is invoked for this new target.

## What We're NOT Doing

- Not touching or forking the external `wgpu-bindings` (codeberg.org/shahwali/wgpu-bindings)
  or `vulkan-zig` dependencies.
- Not replacing or removing the existing Emscripten window/GPU backend —
  it stays as-is, alongside the new one.
- Not achieving full `examples/playground` parity in this plan (no images/
  drag-drop file testing, no full demo gallery on the web) — that is called
  out as an explicit follow-up once `triangle` proves the stack end-to-end.
- Not implementing WebGPU compute pipelines / features knots doesn't already
  use natively (compute isn't used by the existing `wgpu`/`vulkan` backends
  either, based on the `VTable` surface).
- Not adding multi-threading / SharedArrayBuffer / cross-origin-isolation
  requirements — the design intentionally avoids needing them.
- Not changing `App.zig`'s public synchronous `init`/`start` API shape for
  other platforms.

## Implementation Approach

Branch from `zig16` (not `dev813`/`main`) since `zjb` only supports Zig
0.16.0. Land the work in dependency order: (1) the small set of compile-time
touch points that must change in lockstep everywhere `gpu.Context.WindowHandle`
/ `GPUBackend` are used, so the tree keeps compiling for every existing
target at each step; (2) the new window backend; (3) the App main-loop RAF
integration; (4) the new GPU backend; (5) wiring up `examples/triangle`;
(6) manual browser validation. Each phase should leave `zig build test` and
the existing native/emscripten example builds green.

---

## Phase 1: Core plumbing (compiles, not yet functional) — ✅ Complete

### Overview

Introduce the new `WindowHandle` variant and `GPUBackend` tag everywhere
they're structurally required, add the `zjb` dependency, and create the
feature branch — without yet writing the wasm window/GPU backends
themselves. This keeps every subsequent phase's diff small and isolated.

### Changes Required:

#### 1. Branch setup ✅
```
git checkout zig16
git checkout -b wasm-zjb-backend
zig fetch --save=zjb git+https://github.com/scottredig/zig-javascript-bridge
```
Verify `build.zig.zon`'s `minimum_zig_version` stays `"0.16.0"` and a plain
`zig build test` still passes before making any other changes.

#### 2. `src/gpu/Context.zig` ✅
**Changes**: add a `.wasm` variant to `WindowHandle` carrying the canvas
selector, matching the existing `.emscripten` shape:
```zig
pub const WindowHandle = union(enum) {
    // ...
    emscripten: struct {
        selector: []const u8,
    },
    wasm: struct {
        selector: []const u8,
    },
};
```

#### 3. `src/gpu/backend/wgpu/Context.zig:31` ✅
**Changes**: add an arm to the exhaustive `wgpu_handle` switch:
```zig
.wasm => @panic("wasm target not supported by the native/emscripten wgpu backend; use the webgpu_js backend"),
```

#### 4. `src/gpu/backend/vulkan/Context.zig:494,511` ✅
**Changes**: add matching arms to `getInstanceExtensions` and `createSurface`:
```zig
.wasm => @panic("wasm not supported with the vulkan backend"),
```

#### 5. `src/gpu/backend/root.zig` ✅
**Changes**:
- Add `webgpu_js` to the `Backend` enum.
- Add a `.freestanding` case to `preferred()`'s comptime switch, guarded by
  `available.webgpu_js`:
```zig
.freestanding => {
    if (available.webgpu_js) return .webgpu_js;
},
```
- `Backend.init`'s `inline for` over enum fields + `module = switch(...) { .wgpu, .vulkan }` gets a `.webgpu_js => @import("gpu_webgpu_js")` arm (module doesn't exist yet until Phase 4 — stub it with a `@compileError`-free empty placeholder module exporting a matching `init` that `@panic`s, so the tree compiles before Phase 4 lands; replace in Phase 4).

#### 6. `build.zig` ✅
**Changes**:
- Extend `SupportedBackends` with `webgpu_js: bool`.
- Extend the `for (gpu_backends) |be| { switch (be) { ... } }` availability
  loop and the per-backend module-creation `switch` with a `.webgpu_js` arm
  that depends on `zjb` (`b.dependency("zjb", ...)`) and creates
  `src/gpu/backend/webgpu_js/root.zig` (placeholder in this phase, real
  implementation in Phase 4).
- Leave `gpu_backends`'s default (`&[_]GPUBackend{ .wgpu, .vulkan }`)
  unchanged — `webgpu_js` must be opt-in per the consumer's `build.zig`
  (mirrors how `examples/playground/build.zig` already restricts backends
  per-target).
- Also extended `has_wgpu_shaders`'s bool and the `primitives_wgsl`/`slug_wgsl`
  anonymous-import gating to `se.wgpu or se.webgpu_js`, since `webgpu_js`
  reuses the same embedded WGSL shaders (not called out explicitly in the
  original plan text, but required — same file/option `wgpu`/`webgpu_js`
  share).

#### 7. `src/render/Renderer.zig:36-46` ✅
**Changes**: add a `.freestanding` arm to `Config.validate`'s present-mode
switch:
```zig
.freestanding => switch (cfg.present_mode) {
    .fifo => {},
    else => return error.UnsupportedPresentMode,
},
```

#### 8. `src/component/text_edit.zig:29-32` ✅
**Changes**: extend `super_ctrl_held`:
```zig
const super_ctrl_held = switch (builtin.os.tag) {
    .macos => ui.input.super_held,
    .emscripten, .freestanding => ui.input.ctrl_held or ui.input.super_held,
    else => ui.input.ctrl_held,
};
```

#### 9. `src/render/pipelines.zig:110,144` — found during verification, not in original plan ✅
**Changes**: `primitivesDescForTarget`/`slugDescForTarget` each have an
exhaustive `switch (backend: GPUBackend)` selecting shader source
(`.wgpu => .{ .wgsl = ... }`, `.vulkan => .{ .spirv = ... }`) that the
original research pass missed (found via `switch must handle all
possibilities` compile errors when building `examples/triangle`). Added
`.wgpu, .webgpu_js => .{ .wgsl = ... }` to both switches, since `webgpu_js`
reuses the same WGSL sources as `wgpu`.

### Success Criteria:

- [x] `zig build test` passes on `wasm-zjb-backend` exactly as it did on `zig16` (verified: both default `-Dgpu_backends` and an explicit `-Dgpu_backends=wgpu,vulkan,webgpu_js` opt-in pass cleanly; a deliberate injected error in the `webgpu_js` placeholder confirmed it's actually compiled, not silently skipped, when opted in).
- [x] `examples/triangle` and `examples/playground` still build and run natively on macOS with no behavior change **except for two pre-existing, unrelated issues confirmed present on an unmodified `zig16` checkout too** (see note below) — not introduced by this phase, out of scope to fix here.
- [~] Adjusted: the plan's original wording ("tree compiles with `-Dgpu_backends=webgpu_js` for a wasm32-freestanding target, hitting only the intentional placeholder panic") isn't achievable until Phase 2 lands a window backend — `build.zig`'s `window_impl_mod` switch panics (during `zig build`'s own script execution, unconditionally, before any Zig compilation happens) for `target.result.os.tag == .freestanding` regardless of GPU backend selection, since window backend selection and GPU backend selection are independent switches in `build.zig`. Validated the GPU-side plumbing instead by opting `webgpu_js` into a **native macOS** build (see above) — this exercises the exact same `SupportedBackends`/`Backend` enum/`build.zig` module-wiring code paths that a wasm32-freestanding build would use, without requiring the (Phase 2) window backend to exist yet. Full wasm32-freestanding compilation will be validated at the end of Phase 2.

**Pre-existing, unrelated issues found (confirmed present on a pristine `zig16` checkout, not caused by this phase):**
1. `examples/triangle`/`examples/playground` native builds fail with `evaluation exceeded 1000 backwards branches` in the `vulkan-zig` dependency's generated `Dispatch` struct (`vk.zig:33322`), reached via `src/gpu/backend/vulkan/Context.zig:161`. Happens because the default `gpu_backends` list includes `.vulkan`, and `Backend.init`'s `inline for` unconditionally analyzes each available backend's `init` regardless of which one is selected at runtime.
2. `examples/playground -Dtarget=wasm32-emscripten` fails to compile with a `std.Io.Threaded`/`std.os.emscripten` enum-mismatch error (`W.STOPSIG`/`EXITSTATUS`), apparently a Zig 0.16.0 stdlib / installed Emscripten SDK (5.0.7) incompatibility, unrelated to GPU backend selection.

Neither blocks Phase 1's own success criteria (both reproduce identically on
unmodified `zig16`); flagging here for visibility. Recommend raising as a
separate issue if you want them fixed independent of this plan.

**Implementation Note**: Pause here for manual confirmation that the
baseline still builds/tests clean before writing backend code.

---

## Phase 2: Window backend — `src/window/backend/wasm/`

### Overview

New window backend targeting `wasm32-freestanding`, paralleling
`src/window/backend/emscripten/{root,bindings,events,keymap}.zig` but using
`zjb` instead of `emscripten_set_*_callback` externs.

### Changes Required:

#### 1. `src/window/backend/wasm/root.zig`
Implements the same `Backend` surface the emscripten backend implements
(all methods `Window.zig` calls through `impl.Backend`): `init`, `deinit`,
`startCapture`, `pollEvents`/`waitEvents` (no-ops, matching emscripten),
`postEmptyEvent`, `getSize`, `getFramebufferSize`, `computeContentScale`,
`getCursorPos`, `getNativeHandle` (returns `.wasm = .{ .selector = ... }`),
`setCursorVisible`, `setDisplayMode` (fullscreen via
`element.requestFullscreen()`/`document.exitFullscreen()` through zjb),
`consumeResize`, `consumeDrops` (stub returning empty, like emscripten),
`getClipboardText`/`setClipboardText` (via the async Clipboard API —
document as best-effort/no-op if the read side can't be made to fit the
synchronous `Window` API; write side can use `navigator.clipboard.writeText`
fire-and-forget).

#### 2. `src/window/backend/wasm/bindings.zig`
Canvas sizing helper mirroring `emscripten/bindings.zig`'s
`applyCanvasSize`: read `canvas.getBoundingClientRect()` width/height and
`window.devicePixelRatio` via `zjb`, set `canvas.width`/`canvas.height` to
the physical pixel size. Register a `ResizeObserver` on the canvas (via
`zjb.global("ResizeObserver").new(.{zjb.fnHandle("onCanvasResize", &onCanvasResize)})`)
instead of emscripten's `emscripten_set_resize_callback_on_thread`.

#### 3. `src/window/backend/wasm/events.zig`
Keyboard (`keydown`/`keyup` on `window`), mouse (`mousedown`/`mouseup`/
`mousemove`/`wheel` on the canvas, `mouseup` also on `document` to catch
drags released outside the canvas — mirroring the emscripten backend's
rationale), and `blur`/`focus`, each registered via
`element.call("addEventListener", .{ zjb.constString("keydown"), zjb.fnHandle(...) }, void)`.
Each Zig callback reads fields off the JS `Event`/`KeyboardEvent`/
`MouseEvent` `Handle` (`.get("key", ...)`, `.get("clientX", f64)`, etc.) and
forwards into the owning `*window.Window` via `Window.pushKey`/`pushChar`/
`setMouseButton`/`addScrollPixels`, exactly like `emscripten/events.zig`
does today.

#### 4. `src/window/backend/wasm/keymap.zig`
Map JS `KeyboardEvent.code`/`.key` strings to `window.Key` — port
`emscripten/keymap.zig`'s table, adjusted for JS `code` string values
(e.g. `"KeyA"`, `"ArrowLeft"`) instead of Emscripten's numeric DOM keycodes.

#### 5. `build.zig`
Add a new arm to the `window_impl_mod` `switch (target.result.os.tag)`:
```zig
.freestanding => if (target.result.cpu.arch == .wasm32) b.createModule(.{
    .target = target,
    .optimize = optimize,
    .root_source_file = b.path("src/window/backend/wasm/root.zig"),
    .imports = &.{
        .{ .name = "gpu", .module = gpu_mod },
        .{ .name = "zjb", .module = b.dependency("zjb", .{}).module("zjb") },
    },
}) else std.debug.panic("windowing implementation for freestanding target {s} is not yet implemented", .{@tagName(target.result.cpu.arch)}),
```

### Success Criteria:

- A minimal standalone wasm executable (temporary smoke test, can live under
  `examples/triangle` once Phase 5 lands, or a throwaway scratch build in
  this phase) that only creates a `Window` (no GPU) logs canvas creation,
  responds to `ResizeObserver` events, and forwards a keydown to
  `console.log` when manually loaded in a browser.
- `zig build test` still green; native/emscripten targets unaffected.

**Implementation Note**: Pause here for manual browser confirmation
(console output for resize/keyboard/mouse) before proceeding.

---

## Phase 3: `App.zig` requestAnimationFrame main loop

### Overview

`App.start()`'s per-target main-loop dispatch (`src/App.zig:103`) needs a
non-blocking, browser-driven loop for the new target, analogous to
Emscripten's `emscripten_set_main_loop_arg`.

### Changes Required:

#### 1. `src/window/backend/wasm/root.zig`
Add a `pub fn setMainLoop(self: *Self, cb: *const fn (?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void` that registers a
`requestAnimationFrame` callback which calls `cb(user_data)` and then
re-requests itself (`zjb.global("window").call("requestAnimationFrame", .{zjb.fnHandle("rafTick", &rafTick)}, void)` recursively) — the RAF-loop
equivalent of `emscripten_set_main_loop_arg`.

#### 2. `src/App.zig:103`
```zig
switch (builtin.os.tag) {
    inline .emscripten => std.os.emscripten.emscripten_set_main_loop_arg(emscriptenMain, @ptrCast(self), 0, 0),
    inline .freestanding => if (builtin.cpu.arch == .wasm32)
        self.window.backend.setMainLoop(wasmMain, @ptrCast(self))
    else
        std.debug.panic("no main-loop implementation for freestanding {s}", .{@tagName(builtin.cpu.arch)}),
    inline else => { /* existing blocking loop */ },
}
```
with a `wasmMain` mirroring `emscriptenMain`'s `stepFrame` + error-logging
pattern (logging via `zjb.global("console").call("error", ...)` instead of
`emscripten_log`).

### Success Criteria:

- The Phase 2 smoke test app now runs a real per-frame callback driven by
  `requestAnimationFrame` (verified via a frame counter logged every N
  frames), with no blocking loop and no busy CPU usage between frames.

---

## Phase 4: GPU backend — `src/gpu/backend/webgpu_js/`

### Overview

Implement `gpu.Context`'s `VTable` against the browser's WebGPU JS API via
`zjb`, replacing the Phase-1 placeholder module. Only the operations the
`VTable` actually needs are implemented (`deinit`, `createBuffer`,
`createFrame`, `createPipeline`, `createBindGroup`, `createTexture`,
`createSampler`, `resize`, `surfaceFormat`, `surfaceIsSrgb`, `clipSpaceYDown`),
scoped tightly to what `src/render/*.zig` and the two shaders
(`ui_primitives.wgsl`, `slug.wgsl`) actually use — no speculative API
coverage.

### Changes Required:

#### 1. `src/gpu/backend/webgpu_js/bootstrap.zig`
Package-level async bootstrap, called from the wasm entry point
(Phase 5), *before* `App.init`:
```zig
pub fn requestDeviceAsync(on_ready: *const fn (adapter: zjb.Handle, device: zjb.Handle) callconv(.c) void) void { ... }
```
Internally: `zjb.global("navigator").get("gpu", zjb.Handle).call("requestAdapter", .{}, zjb.Handle).call("then", .{ zjb.fnHandle("onAdapterReady", &onAdapterReady) }, void)`,
then in `onAdapterReady`, `adapter.call("requestDevice", .{}, zjb.Handle).call("then", .{ zjb.fnHandle("onDeviceReady", &onDeviceReady) }, void)`,
then in `onDeviceReady`, store both handles in module-level state and invoke
the caller's `on_ready`.

#### 2. `src/gpu/backend/webgpu_js/Context.zig`
`init(allocator, window_handle, cfg) !gpu.Context`: reads the
already-resolved adapter/device `Handle`s set by `bootstrap.zig`
(`@panic`s with a clear message if called before the bootstrap completed —
this should be structurally impossible given Phase 5's entry-point
ordering, but guard it anyway), gets `canvas.getContext("webgpu")` from the
`.wasm` `WindowHandle` selector, calls `context.configure({device, format,
alphaMode})` (WebGPU JS surface configuration is synchronous), and picks
the preferred canvas format via `navigator.gpu.getPreferredCanvasFormat()`.

#### 3. `src/gpu/backend/webgpu_js/{Buffer,Pipeline,BindGroup,Texture,Sampler,Frame,RenderPass}.zig`
Thin wrappers mirroring the shape of `src/gpu/backend/wgpu/*.zig`'s
equivalents, but each JS call routed through `zjb.Handle.call`/`.get`/`.set`/
`.new` instead of the `wgpu-native` C API:
- `Buffer`: `device.call("createBuffer", .{descriptorHandle}, zjb.Handle)`,
  `writeBuffer` via `queue.call("writeBuffer", .{buffer, offset, zjb.u8ArrayView(bytes)}, void)`.
- `ShaderModule`/`Pipeline`: `device.call("createShaderModule", .{.{code=wgslSourceHandle}}, zjb.Handle)`
  then `createRenderPipelineAsync` vs sync `createRenderPipeline` — **use the
  synchronous `createRenderPipeline`** to avoid a third async round trip
  (accept the (rare, one-time, per-pipeline) main-thread compile stall
  documented as a known tradeoff — call this out in code comments).
- `Frame`/`RenderPass`: `device.call("createCommandEncoder", ...)`,
  `encoder.call("beginRenderPass", ...)`, `pass.call("draw"/"setPipeline"/"setBindGroup"/"end", ...)`,
  `queue.call("submit", .{ jsArrayOfCommandBuffers }, void)`. No explicit
  `present()` call — the browser presents automatically at the end of the
  frame's task, matching the existing `wgpu` backend's emscripten
  short-circuit in `Surface.zig`'s `present()`.
- Building JS descriptor objects: since `zjb` doesn't marshal Zig structs
  into JS object literals automatically, each descriptor is built with
  `zjb.global("Object").call("assign", ...)`-style calls or (simpler) a
  small `zjb`-based object-builder helper (`obj.set("field", value)` calls
  chained) — write this helper once and share it across the wrapper files
  rather than duplicating boilerplate per descriptor.

#### 4. `src/gpu/backend/root.zig` / `build.zig`
Replace the Phase-1 placeholder module with the real one; wire
`gpu_backend_mod.addImport("gpu_webgpu_js", ...)` with `zjb`'s module as an
import.

### Success Criteria:

- A unit-level (non-browser) sanity check is not meaningful here (this code
  only runs in a wasm32-freestanding browser context), so success is
  verified in Phase 6's manual browser pass. This phase's own bar is: the
  wasm32-freestanding build **compiles** with `webgpu_js` selected as the
  `gpu_backend`, with no `.wasm`/`webgpu_js` arms left as `@panic` stubs
  outside the documented, intentional ones (e.g. clipboard read).

---

## Phase 5: `examples/triangle` wasm target

### Overview

Wire up the actual buildable/servable artifact, paralleling
`examples/playground`'s `buildEmscripten` in `examples/playground/build.zig`
and `main_web.zig`/`shell.html`.

### Changes Required:

#### 1. `examples/triangle/src/main_wasm.zig`
```zig
export fn main() void {
    gpu_webgpu_js.bootstrap.requestDeviceAsync(&onDeviceReady);
}

fn onDeviceReady(adapter: zjb.Handle, device: zjb.Handle) callconv(.c) void {
    // construct App (Window created here or already created in main();
    // Context.init() picks up the resolved adapter/device via bootstrap.zig).
    const app = allocator.create(App) catch @panic("OOM");
    app.* = App.init(io, allocator, .{ .window = .{ .width = 1280, .height = 720, .title = "Triangle", .canvas_selector = "#canvas" } }) catch @panic("init failed");
    app.start(frameCb) catch @panic("start failed");
}
```
Logging via `zjb.global("console")` instead of
`std.os.emscripten.emscripten_log`; allocator via `std.heap.wasm_allocator`
(no libc on freestanding) instead of `std.heap.c_allocator`; `std.Io` setup
reuses the same `std.Io.Threaded.init_single_threaded` pattern
`main_web.zig` already uses.

#### 2. `examples/triangle/src/shell.html` (or a new `static/` dir)
Minimal HTML with a `<canvas id="canvas">`, paralleling
`examples/playground/src/shell.html`, plus a `<script type="module">` that
`fetch`es/instantiates the wasm module and wires in the `zjb`-generated
`zjb_extract.js` (per `zjb`'s `example/build.zig` pattern:
`new Zjb(); ... WebAssembly.instantiateStreaming(fetch('triangle.wasm'), zjb.imports)`).

#### 3. `examples/triangle/build.zig`
Add a `buildWasm` function (parallel to `playground`'s `buildEmscripten`):
build the wasm32-freestanding executable (`entry = .disabled`,
`rdynamic = true`), run `zjb`'s `generate_js` artifact over it to produce
`zjb_extract.js`, install it alongside the wasm binary and the static HTML,
and add a `run`/`serve` step (reuse the same `python3 -m http.server`
pattern already used for the emscripten target, or `zjb`'s own
`demo_webserver` helper if it's easy to depend on — otherwise keep the
existing `http.server` approach for consistency with `playground`).
Dispatch into it from `build()` when
`target.result.cpu.arch == .wasm32 and target.result.os.tag == .freestanding`.

#### 4. `examples/triangle/build.zig.zon`
Add the `zjb` dependency (`zig fetch --save=zjb ...` from within
`examples/triangle`, since it's a separate build graph from the root
`knots` package).

### Success Criteria:

- `zig build -Dtarget=wasm32-freestanding` (from `examples/triangle`)
  succeeds and produces `triangle.wasm`, `zjb_extract.js`, and an
  `index.html`.
- `zig build serve` (or equivalent) serves the page locally.

---

## Phase 6: Manual browser validation & polish

### Overview

End-to-end validation in a real browser, and cleanup of any rough edges
found.

### Manual Testing Steps:

1. Serve `examples/triangle`'s wasm build locally, open in a browser with
   WebGPU support (recent Chrome/Edge); confirm no console errors and the
   canvas shows the red triangle plus the `DevTools` overlay text.
2. Resize the browser window; confirm the canvas and rendered content
   rescale (both CSS/logical and physical/DPR-scaled sizes), matching the
   emscripten backend's behavior.
3. Move/click the mouse over the canvas and press keys; confirm `DevTools`
   (or a temporary debug overlay) reflects input, proving event forwarding
   works.
4. Toggle device pixel ratio (e.g. browser zoom) and confirm content-scale
   updates correctly.
5. Leave the tab open for a while; confirm the RAF loop doesn't runaway
   CPU (should be capped to the display refresh rate) and doesn't leak
   `zjb` handles (`zjb.unreleasedHandleCount()` — call this out as a debug
   assertion in the wasm entry point during development, matching zjb's own
   example).
6. Confirm `examples/playground`'s existing Emscripten build is unaffected
   (still builds/runs).

### Success Criteria:

- All steps above pass with no console errors and no visible regressions
  to the existing Emscripten build.

---

## Testing Strategy

### Unit/Build Tests:
- `zig build test` (root `knots` package) at the end of every phase.
- Native (macOS/Windows/Linux) and Emscripten builds of both
  `examples/triangle` and `examples/playground` at the end of every phase
  that touches shared code (Phases 1, 3, 4 touch `App.zig`/`gpu` shared
  code; Phase 2/5 are additive-only).

### Manual Testing:
- See Phase 2's browser smoke test, Phase 3's RAF frame-counter check, and
  Phase 6's full end-to-end pass.

## Performance Considerations

- `createRenderPipeline` (sync) vs `createRenderPipelineAsync`: the sync
  path can stall the main thread on shader compilation; acceptable for the
  small, fixed set of pipelines knots creates at startup/config-change time,
  but should be revisited if pipeline creation becomes more dynamic later.
- The RAF loop should skip rendering (but keep rescheduling) when the
  canvas is zero-sized (mirrors `App.renderFrame`'s existing
  `if (ev.physical.width == 0 or ev.physical.height == 0) return;` check —
  no new code needed, just confirm it still applies).

## Migration Notes

Not applicable — purely additive; no existing data/build outputs change
shape.

## References

- Issue: https://github.com/cataggar/knots/issues/1
- zjb: https://github.com/scottredig/zig-javascript-bridge (branch `0.16.0`/`main`)
- Existing Emscripten window backend: `src/window/backend/emscripten/{root,bindings,events,keymap}.zig`
- Existing wgpu GPU backend: `src/gpu/backend/wgpu/{Context,Buffer,Pipeline,Frame,RenderPass,BindGroup,Texture,Sampler}.zig`
- Shared GPU interface: `src/gpu/Context.zig`, `src/gpu/backend/root.zig`
- App main loop: `src/App.zig` (`start`, `renderFrame`, `stepFrame`)
- Existing web example wiring: `examples/playground/{build.zig,src/main_web.zig,src/shell.html}`
- wgpu-rs's wasm-bindgen/web-sys WebGPU backend (no Emscripten):
  `wgpu/src/backend/webgpu.rs` in https://github.com/gfx-rs/wgpu
- egui/eframe web build (wasm-bindgen, no Emscripten):
  `crates/eframe/Cargo.toml` in https://github.com/emilk/egui
