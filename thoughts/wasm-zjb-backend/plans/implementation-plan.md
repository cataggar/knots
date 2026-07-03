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

## Phase 2: Window backend — `src/window/backend/wasm/` — ✅ Complete

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

- [x] A minimal standalone wasm executable (temporary smoke test, can live under
  `examples/triangle` once Phase 5 lands, or a throwaway scratch build in
  this phase) that only creates a `Window` (no GPU) logs canvas creation,
  responds to `ResizeObserver` events, and forwards a keydown to
  `console.log` when manually loaded in a browser.
- [x] `zig build test` still green; native/emscripten targets unaffected.

**Verification performed:** Built a throwaway scratch harness outside the
repo (`/tmp/wasm-window-smoke`, deleted after use — not committed) whose
`build.zig` imports `src/gpu/root.zig` and `src/window/{root,backend/wasm/root}.zig`
directly by absolute path (bypassing the public `knots` package, since that
would pull in `App`/`Renderer` and hit the still-unimplemented Phase 4
`webgpu_js` backend). Drove the resulting wasm page with a **real headless
Chromium** (Playwright, already cached in this environment) rather than
relying only on a compile check:
- Window/canvas init: correct logical/physical size + content scale logged.
- `ResizeObserver`: fires on both initial `observe()` and on real viewport
  resizes, with correct updated canvas dimensions each time.
- Keyboard: `KeyA` down produced `key pressed: 65` (`Key.a`) and
  `char: 97` ('a'), confirming `keymap.zig`'s JS `code`-string table and
  `decodePrintableChar`'s UTF-8 decoding both work against real
  `KeyboardEvent`s.
- Mouse: left-button press/release and canvas-relative position
  (`offsetX`/`offsetY`) all correct.
- Wheel: `deltaY` correctly accumulated into `ScrollInput.pixel`.
- Stability: 5 rapid resize+keypress cycles produced zero `pageerror`
  events (no zjb handle-lifetime crashes, no observer/listener issues).

**Finding relevant to Phase 3:** `std.Io.Threaded` (used by
`main_web.zig`'s `.init_single_threaded`) **cannot compile for
wasm32-freestanding** — it unconditionally requires `posix.system.getrandom`
and `posix.IOV_MAX`, which don't exist for freestanding wasm32 (unlike
`wasm32-emscripten`, which has a libc/posix emulation layer providing them).
This smoke test sidestepped it (the window backend never dispatches through
`io`), using `const io: std.Io = undefined;` — safe here, but **Phase 3/5
will need a real, working `std.Io` implementation** for `App`'s frame timer
(`Timer.tick` calls `std.Io.Timestamp.now(io, clock)`) and `CompletionQueue`.
This needs to be resolved as part of Phase 3, not deferred further.

**Implementation Note**: Pause here for manual browser confirmation
(console output for resize/keyboard/mouse) before proceeding.

---

## Phase 3: `App.zig` requestAnimationFrame main loop — ✅ Complete

### Overview

`App.start()`'s per-target main-loop dispatch (`src/App.zig:103`) needs a
non-blocking, browser-driven loop for the new target, analogous to
Emscripten's `emscripten_set_main_loop_arg`.

**Scope grew during implementation** (see "Io implementation" below): making
this loop actually drive real frames requires a working `std.Io` for
`App`'s frame `Timer`, which the Phase 2 write-up flagged but didn't scope.
Resolved as part of this phase — see the dedicated write-up below.

### Changes Required:

#### 1. `src/window/backend/wasm/root.zig` ✅
Added `pub fn setMainLoop(self: *Self, cb: *const fn (?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void`, backed by module-level
`raf_cb`/`raf_user_data` globals and a `requestNextFrame()` helper that calls
`zjb.global("window").call("requestAnimationFrame", .{zjb.fnHandle("knots_wasm_rafTick", &rafTick)}, void)`; `rafTick` invokes `cb(user_data)` then
re-requests itself — the RAF-loop equivalent of `emscripten_set_main_loop_arg`.

#### 2. `src/window/Window.zig` — not in the original plan, needed for layering
Added `pub inline fn setMainLoop(self: *Window, cb, user_data) void` delegating
to `self.backend.setMainLoop(...)`. Unlike the Emscripten branch (which calls
`std.os.emscripten` directly from `App.zig`, since it's always-available std
lib), `zjb` is a real dependency requiring explicit per-module import wiring
— routing through `Window`/`Backend` (which already has `zjb` wired via
`window_impl_mod`) avoids plumbing `zjb` into `App.zig`'s module too. Backends
that don't implement `setMainLoop` are fine: Zig only analyzes a function
body when it's actually called, and `Window.setMainLoop` is only called from
`App.zig`'s `.freestanding` arm, itself only analyzed for that target.

#### 3. `src/App.zig:103` ✅
```zig
switch (builtin.os.tag) {
    inline .emscripten => std.os.emscripten.emscripten_set_main_loop_arg(emscriptenMain, @ptrCast(self), 0, 0),
    inline .freestanding => if (builtin.cpu.arch == .wasm32)
        self.window.setMainLoop(wasmMain, @ptrCast(self))
    else
        std.debug.panic("no main-loop implementation for freestanding {s}", .{@tagName(builtin.cpu.arch)}),
    inline else => { /* existing blocking loop */ },
}
```
`wasmMain` mirrors `emscriptenMain`'s `stepFrame` pattern but `@panic`s on
error instead of logging-and-continuing (simpler; no new `Window`/`Backend`
API surface needed for this pass — logging-and-continuing is a nice-to-have
left for later polish, not required for `triangle`).

#### 4. `src/window/backend/wasm/io.zig` — new, not in the original plan
**Finding:** `std.Io.Threaded` (what every other target's entry point uses)
cannot compile for `wasm32-freestanding` (Phase 2's note). Investigated
`lalinsky/zio` (a full `std.Io` implementation) and `chung-leong/zigar` per
your suggestion — `zio` targets native OS async APIs (io_uring/kqueue/IOCP)
with a heavy coroutine runtime, not applicable to a freestanding wasm
target, and neither project has solved this exact case. However, reading
`zio`'s source revealed the actual fix: **`std.Io` ships `std.Io.failing`**,
a complete, ready-to-use `std.Io` constant that "simulates a system
supporting no Io operations" (concurrency unavailable, empty/full
filesystem, no entropy, `now`/`sleep` degrade gracefully) — built from
~30 pre-written `noXxx`/`failingXxx`/`unreachableXxx` helper functions
covering the *entire* 109-field `std.Io.VTable`. Since knots' core
App/Renderer/Window/Text/UI code paths never touch filesystem/network/
concurrency (confirmed: the only real `io` dispatch anywhere in `src/` is
`Timer`'s `std.Io.Timestamp.now`/`CompletionQueue`'s queue+group ops, and
`Group.await`/`cancel` short-circuit to a no-op whenever nothing was ever
dispatched, which is always true for `triangle`), this reduces the "custom
Io" task from writing ~109 stub functions down to **copying
`std.Io.failing`'s vtable and overriding exactly one field, `now`**:
```zig
const vtable: std.Io.VTable = blk: {
    var v = std.Io.failing.vtable.*;
    v.now = &wasmNow;
    break :blk v;
};
pub const io: std.Io = .{ .userdata = null, .vtable = &vtable };
```
`wasmNow` uses `Date.now()` for `Clock.real` (matches its documented
wall-clock-since-epoch semantics) and `performance.now()` for every other
`Clock` variant (monotonic, matches `.awake`/`.boot`). `app.dispatch(...)`
(used by playground's async_dispatch demo and the fetch example, not by
`triangle`) will gracefully return `error.ConcurrencyUnavailable` on this
backend, matching `std.Io.Threaded`'s own single-threaded-build behavior —
an intentional, acceptable degradation, not a bug. This file isn't
publicly exposed from `root.zig` yet — deferred to Phase 5, when
`examples/triangle`'s wasm entry point actually needs to construct one.

### Success Criteria:

- [x] The Phase 2 smoke test app now runs a real per-frame callback driven by
  `requestAnimationFrame` (verified via a frame counter logged every N
  frames), with no blocking loop and no busy CPU usage between frames.

**Verification performed:**
1. **Full-app compile check**: a throwaway scratch harness (`/tmp/wasm-app-smoke`,
   deleted after use) depended on the modified `knots` package the same way
   `examples/triangle` does (`b.dependency("knots", .{ .gpu_backends = &.{.webgpu_js} })`,
   `target = wasm32-freestanding`) and called both `knots.App.init(...)` *and*
   `app.start(frameCb)` — forcing full analysis of the new `.freestanding`
   branch in `App.zig`, `Window.setMainLoop`, and the wasm `Backend.setMainLoop`.
   Produced a real 2.7MB `app_smoke.wasm`. (This only proves compilation —
   running it would immediately hit Phase 4's intentional placeholder panic
   during `Renderer.init`, before `.start()`'s RAF branch ever executes, so
   full runtime proof of the *complete* App loop is deferred to Phase 4/5.)
2. **Real headless-browser runtime check of the RAF+Io pieces in isolation**
   (`/tmp/wasm-raf-smoke`, deleted after use): a window-only harness (like
   Phase 2's, but calling `win.setMainLoop(tick, null)` instead of
   `setInterval`, and reading `std.Io.Timestamp.now(wasm_io.io, .real)` each
   tick) confirmed, via real headless Chromium: the RAF loop runs
   continuously (~120 ticks/sec, browser/display-paced, not a busy loop) and
   `now()`'s wall-clock timestamps advance correctly in real ~1000ms
   increments between logged samples.

---

## Phase 4: GPU backend — `src/gpu/backend/webgpu_js/` — ✅ Complete

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

#### 1. `src/gpu/backend/webgpu_js/bootstrap.zig` ✅
Implemented as planned: `requestDeviceAsync(on_ready)` chains
`navigator.gpu.requestAdapter().then(...)` → `adapter.requestDevice().then(...)`,
storing `resolved_adapter`/`resolved_device` as public module-level
optionals before invoking `on_ready(adapter, device)`.

#### 2. `src/gpu/backend/webgpu_js/Context.zig` ✅
Implemented as planned, plus one addition not in the original plan: picking
the preferred canvas format needed reading a JS string back into Zig, so
`Context.zig` has its own small `readJsStringUtf8` (same technique as the
window backend's `bindings.zig`, duplicated rather than shared across
modules — `gpu_backend`/`window_impl` aren't linked to each other and
shouldn't need to be).

#### 3. `src/gpu/backend/webgpu_js/{js,Buffer,Pipeline,BindGroup,Texture,Sampler,Frame,RenderPass}.zig` ✅
Implemented as planned. `js.zig` is the shared descriptor-building helper
(`obj()`/`arr()`/`push()`) plus every `gpu.*` enum → WebGPU JS string/bitflag
mapping (texture format, vertex format, blend factor/op, filter/address
mode, texture-sample/sampler-binding type, and the `GPUBufferUsage`/
`GPUTextureUsage`/`GPUShaderStage` bitflag constants, hardcoded from the
spec since they never change). Two deliberate simplifications validated as
correct, not just assumed (see verification below):
- `Frame.begin()`/`waitForCompletion()` are no-ops: `GPUQueue.writeBuffer`/
  `writeTexture` copy data into an internal staging buffer synchronously
  per spec, and WebGPU's resource-lifetime model keeps resources referenced
  by already-submitted command buffers valid even after `destroy()` — so
  none of the native backend's `device.poll(true)` CPU/GPU sync calls have
  an equivalent need here.
- `Context.resize()` is a no-op: the canvas texture size tracks the
  `<canvas>` element's own `width`/`height` attributes automatically
  (already kept in sync by the wasm window backend's `applyCanvasSize`),
  unlike native swapchains which need explicit reconfiguration.
- `createRenderPipeline` (synchronous) is used instead of
  `createRenderPipelineAsync`, avoiding a third async round trip at the
  cost of a one-time, per-pipeline main-thread compile stall — acceptable
  since knots only creates a small, fixed set of pipelines at startup.

#### 4. `src/gpu/backend/root.zig` / `build.zig` ✅ — plus a real architectural gap found and fixed
Replaced the Phase-1 placeholder module. While building an end-to-end
validation harness (see below), discovered that `bootstrap.zig`'s
module-level `resolved_adapter`/`resolved_device` state must be the *same
compiled module instance* the wasm entry point and `Context.init` both
read from — simply pointing a second `b.createModule` at the same file
path (as I did for the throwaway Phase 2/3 scratch harnesses) creates a
*second, independent* copy of that state, so a real entry point calling
`requestDeviceAsync` that way would never actually hand off to `Context.init`.
This isn't just a scratch-harness wrinkle — it's a real requirement for
Phase 5. Fixed by capturing the `webgpu_js` backend module when created in
`build.zig`'s per-backend loop and also wiring it onto the top-level
`knots` module (`mod.addImport("gpu_webgpu_js", m)`), then re-exporting it
from `src/root.zig` as `pub const gpu_webgpu_js = if (wasm32-freestanding) @import("gpu_webgpu_js") else struct {};` (comptime-gated so other
targets never need to resolve it). This is the mechanism Phase 5's
`main_wasm.zig` will use: `knots.gpu_webgpu_js.bootstrap.requestDeviceAsync(...)`.

### Success Criteria:

- [x] Compiles with `webgpu_js` selected as the `gpu_backend` for
  wasm32-freestanding, with no `.wasm`/`webgpu_js` arms left as placeholder
  `@panic`s.

**Verification exceeded the plan's own bar substantially.** The plan
anticipated that only a compile check was meaningful before Phase 6's
manual browser pass, but headless Chromium with real WebGPU support
(`--enable-unsafe-webgpu --use-angle=metal`, already cached in this
environment via Playwright) turned out to be available, so a full
real-GPU runtime validation was done instead:
- **Compile check**: a scratch harness depending on `knots` exactly like
  `examples/triangle` will (`gpu_backends=&.{.webgpu_js}`,
  wasm32-freestanding) compiled `App.init()`+`app.start()` successfully.
- **Real end-to-end render test** (throwaway harness, deleted after use):
  a wasm entry point that called the real `bootstrap.requestDeviceAsync`
  → constructed a real `App` + `knots.debug.DevTools` → rendered a
  `Canvas`-drawn filled triangle every frame, driven by the real RAF loop,
  in headless Chromium with a real (software/ANGLE-backed) WebGPU device.
  Result: **zero page errors**, console logs confirmed the full sequence
  (device ready → `App.init` ok → `DevTools.init` ok → continuous frames at
  ~127fps), and **screenshots confirm visually correct rendering**: a
  correctly shaped/colored/positioned red triangle, and — after simulating
  a mouse click on the DevTools toggle (proving Phase 2's input handling
  works end-to-end too) — a fully legible DevTools metrics panel (text,
  tab buttons, a live animated line graph) rendered via the `slug` text
  shader, confirming the atlas/curve/band textures, their storage-buffer
  bind group, and the primitives pipeline's instance path all work
  correctly against a real WebGPU implementation, not just in theory.
- Native `zig build test` still green throughout (default backends, and
  with `webgpu_js` explicitly opted in — confirming `zjb`'s `extern "zjb"`
  declarations don't break native compilation even though they'd only
  resolve at link time for an actual wasm build).

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
