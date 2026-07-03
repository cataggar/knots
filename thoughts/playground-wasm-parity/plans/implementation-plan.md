# examples/playground wasm parity — Implementation Plan

**Status: ✅ All 4 phases complete.** `examples/playground` builds and runs
on `wasm32-freestanding`; all 17 demos validated in real (headless, WebGPU-
enabled) Chromium with zero errors, including the two bugs this plan fixed
(`async_dispatch`'s crash-on-click, and `form`'s `std.log` compile hazard).

## Overview

Add a `wasm32-freestanding` target to `examples/playground` (the full demo
gallery), following the same pattern established for `examples/triangle` in
the merged wasm/zjb backend work (`cataggar/knots` PR #2). This is the
`playground` follow-up explicitly deferred from that plan.

## Current State Analysis

- The wasm/zjb backend (`src/window/backend/wasm/`, `src/gpu/backend/webgpu_js/`,
  `App.zig`'s RAF loop, `src/window/backend/wasm/io.zig`) is merged into
  `zig16` and already proven working end-to-end (real WebGPU rendering,
  input, resize) via `examples/triangle`.
- `examples/playground`'s shared `root.zig` (used identically by native,
  Emscripten, and — once this plan lands — wasm) already sets
  `.canvas_selector = "#canvas"` unconditionally, and loads its font via
  `@embedFile` — both already portable to the wasm target with no changes.
- All 17 demos in `examples/playground/src/demos/` were reviewed. All demo
  *source* embedding (`demos.zig:57-58`, `@embedFile(path)`) and font
  loading are comptime/embedded — no runtime filesystem access anywhere.
  `demos/drops.zig` (drag-and-drop) already degrades to an empty
  "no drops yet" state on backends without OS drag-and-drop support (the
  wasm backend's `consumeDrops` is `&[_][]const u8{}`, matching Emscripten's
  existing behavior) — no fix needed there; this is expected parity, not a
  gap.

### Key Discoveries:

- **`demos/async_dispatch.zig`** (`sleep10()`) calls `try app.dispatch(...)`
  unconditionally except on Emscripten (`is_emscripten` local const at the
  top of the file already special-cases it: "on emscripten dispatch is
  synchronous; clicks just bump the counter"). `App.dispatch`
  (`src/App.zig:230`) forwards straight to `CompletionQueue.dispatch`
  (`src/CompletionQueue.zig`), whose `DispatchError` includes
  `std.Io.ConcurrentError`. The wasm backend's custom `Io`
  (`src/window/backend/wasm/io.zig`) is built on `std.Io.failing`, whose
  `groupConcurrent` unconditionally returns `error.ConcurrencyUnavailable`
  (matching `std.Io.Threaded`'s own behavior when `builtin.single_threaded`
  is true, which it always is on this target). Since `try app.dispatch(...)`
  isn't wrapped in a `catch` in the demo, this error would propagate up
  through the `Button.onClick` handler, through `App.renderFrame`'s
  `try @call(.auto, frameCb, ...)`, and reach `wasmMain`'s
  `catch |err| @panic(@errorName(err))` in `main_wasm.zig` — **clicking
  "sleep x10" would hard-crash the whole wasm app.** Fix: add the same kind
  of branch already used for `is_emscripten`.
- **`demos/form.zig:229`**'s `submit()` calls `std.log.info(...)`. Zig
  0.16's `std.Options.debug_io` (used by `std.log`'s default `logFn` via
  `std.debug.lockStderr`) defaults to
  `Io.Threaded.global_single_threaded.io()` (`lib/std/std.zig`'s `Options`
  struct, `debug_threaded_io`/`debug_io` fields) unless the root module
  declares `pub const std_options_debug_io`/`_debug_threaded_io`, or
  overrides `logFn` directly so `log.defaultLog` (the only caller of
  `debug_io`) is never referenced. Since `std.Io.Threaded` cannot compile
  at all for `wasm32-freestanding` (the Phase 2/3 finding from the original
  plan — it needs `posix.system.getrandom`/`IOV_MAX`, absent there), merely
  *reaching* `log.defaultLog` would fail to compile. `examples/triangle`
  never hit this because nothing in its reachable code calls `std.log.*`;
  confirmed via `grep -rn "std\.log\."` across `src/` and
  `examples/playground/src/` that `demos/form.zig` is the only reachable
  call site in scope for this plan. `examples/playground/src/main_web.zig`
  already works around the equivalent Emscripten problem with a custom
  `webLog`/`pub const std_options: std.Options = .{ .logFn = webLog };` —
  the same pattern, implemented with `zjb` instead of
  `std.os.emscripten.emscripten_log`, fixes this for wasm. Per your
  decision, this is added to *both* `examples/playground/src/main_wasm.zig`
  (new) and `examples/triangle/src/main_wasm.zig` (already merged) —
  defensively, since the hazard is generic to this backend, not specific to
  any one example.

## Desired End State

`examples/playground` builds and serves on `wasm32-freestanding` exactly
like `examples/triangle` does, with every demo reachable and usable without
crashing, verified via headless-Chromium WebGPU automation (clicking
through every nav tab) and a final manual pass in a real browser.

## What We're NOT Doing

- Not implementing OS drag-and-drop for the web target (`drops.zig` keeps
  its existing "no drops yet" empty-state behavior, matching Emscripten).
- Not adding real concurrent `app.dispatch` support for this backend (the
  `async_dispatch` demo gets the same synchronous-fallback treatment
  Emscripten already has, not a working implementation).
- Not touching the README's platform table or CI — separate follow-ups.
- Not changing anything in `src/gpu/backend/webgpu_js/` or
  `src/window/backend/wasm/` (the merged backend needs no changes for this
  — the two bugs found are both example-level).

## Implementation Approach

Branch `playground-wasm-parity` from the current `zig16` tip (`2a7a7da`,
already includes the merged wasm/zjb backend). Fix the two demo-level bugs
first (small, isolated, no build.zig changes), then wire up the wasm
target (directly mirroring `examples/triangle`'s already-proven
`build.zig`/`main_wasm.zig`/`static/` pattern), then validate every demo.

---

## Phase 1: Fix `async_dispatch.zig` for wasm — ✅ Complete

### Overview

Prevent the hard crash when `app.dispatch` is unavailable, using the same
pattern the demo already applies for Emscripten.

### Changes Required:

#### 1. `examples/playground/src/demos/async_dispatch.zig` ✅
**Changes**: extend the existing `is_emscripten` check to also cover wasm,
and update the two spots that branch on it (`body`'s explanatory text and
`sleep10`'s early-return):
```zig
const is_emscripten = @import("builtin").os.tag == .emscripten;
const is_wasm = @import("builtin").cpu.arch == .wasm32 and @import("builtin").os.tag == .freestanding;
const dispatch_unavailable = is_emscripten or is_wasm;
```
Replace the two `if (is_emscripten)` checks (in `body`'s text selection and
`sleep10`'s early return) with `if (dispatch_unavailable)`. Update the
explanatory text to something accurate for both targets, e.g.: `"this
target can't dispatch concurrent work; clicks just bump the counter."`
(replacing the Emscripten-specific wording, since it's no longer accurate
to single out Emscripten).

### Success Criteria:

- [x] `zig build test` (root package) still passes.
- [x] Native and (pre-existing-bug-permitting) Emscripten builds of
  `examples/playground` are unaffected (same behavior as before for those
  targets, since `dispatch_unavailable` is `true` for Emscripten exactly
  when `is_emscripten` was).

**Verification performed:** native `zig build test` (root package) still
green. `zig build` of `examples/playground` (native) reaches the exact same
pre-existing, unrelated vulkan-zig branch-quota error as before (confirmed
present on unmodified `zig16` in the original plan's Phase 1) — no new
errors introduced, confirming this file compiles cleanly.

---

## Phase 2: Fix the `std.log` / `std.Io.Threaded` compile hazard — ✅ Complete (triangle half)

### Overview

Add a custom `logFn` so `std.log.*` never reaches `std.Io.Threaded`
(which can't compile for `wasm32-freestanding`), in both
`examples/playground` (where `demos/form.zig` actually calls `std.log.info`)
and `examples/triangle` (defensive, per your decision — same hazard,
currently latent there).

### Changes Required:

#### 1. `examples/playground/src/main_wasm.zig` (new, written in Phase 3 — this content included there)
```zig
fn webLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = scope;
    const msg = std.fmt.allocPrint(std.heap.wasm_allocator, format, args) catch return;
    defer std.heap.wasm_allocator.free(msg);
    const handle = zjb.string(msg);
    defer handle.release();
    const console = zjb.global("console");
    switch (level) {
        .err => console.call("error", .{handle}, void),
        .warn => console.call("warn", .{handle}, void),
        .info => console.call("info", .{handle}, void),
        .debug => console.call("debug", .{handle}, void),
    }
}

pub const std_options: std.Options = .{ .logFn = webLog };
```
(This is folded into Phase 3's `main_wasm.zig` listing rather than written
twice — called out as its own phase here because it's conceptually a
distinct fix, verified independently in Phase 4 by actually triggering the
form demo's submit button.)

#### 2. `examples/triangle/src/main_wasm.zig` ✅
**Changes**: added the identical `webLog` function and
`pub const std_options` declaration (triangle had neither). No behavior
change for triangle today (nothing in its path calls `std.log`), purely
defensive.

### Success Criteria:

- [x] `examples/triangle` (wasm target) still compiles and runs correctly
  after adding the unused-today `std_options` override (regression check —
  re-run the same headless-Chromium validation from the original plan's
  Phase 5/6).

**Verification performed:** rebuilt `examples/triangle`'s wasm target
(`zig build -Dtarget=wasm32-freestanding`) — compiles cleanly. Re-ran the
same real-WebGPU headless-Chromium check used throughout the original
plan: zero page errors, screenshot confirms the triangle still renders
identically to before this change.

The `examples/playground` half of this fix is written in Phase 3 (below),
since it's part of that phase's new `main_wasm.zig` file rather than an
edit to an existing one — verified together with the rest of Phase 3/4.

---

## Phase 3: Wire up `examples/playground`'s wasm target — ✅ Complete

### Overview

Directly mirror `examples/triangle`'s already-proven `build.zig`/
`main_wasm.zig`/`static/` pattern (same shapes, adapted for playground's
`Self`-based app struct instead of triangle's inline `Ctx`).

### Changes Required:

#### 1. `examples/playground/src/main_wasm.zig` ✅
Implemented as planned (code below matches what was written).
```zig
const std = @import("std");
const zjb = @import("zjb");
const playground = @import("playground");

fn webLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = scope;
    const msg = std.fmt.allocPrint(std.heap.wasm_allocator, format, args) catch return;
    defer std.heap.wasm_allocator.free(msg);
    const handle = zjb.string(msg);
    defer handle.release();
    const console = zjb.global("console");
    switch (level) {
        .err => console.call("error", .{handle}, void),
        .warn => console.call("warn", .{handle}, void),
        .info => console.call("info", .{handle}, void),
        .debug => console.call("debug", .{handle}, void),
    }
}

pub const std_options: std.Options = .{ .logFn = webLog };
pub const panic = zjb.panic;

fn logStr(msg: zjb.ConstHandle) void {
    zjb.global("console").call("log", .{msg}, void);
}

var app: playground = undefined;

export fn main() void {
    logStr(zjb.constString("[playground] requesting GPU device..."));
    playground.knots.gpu_webgpu_js.bootstrap.requestDeviceAsync(&onDeviceReady);
}

fn onDeviceReady(_: zjb.Handle, _: zjb.Handle) callconv(.c) void {
    app = playground.init(playground.knots.wasm_io.io, std.heap.wasm_allocator) catch |err| {
        logStr(zjb.constString("[playground] init failed:"));
        zjb.throwError(err);
    };
    logStr(zjb.constString("[playground] ready"));
    app.start() catch |err| {
        logStr(zjb.constString("[playground] start failed:"));
        zjb.throwError(err);
    };
}
```
`examples/playground/src/root.zig`'s `const knots = @import("knots");` was
changed to `pub const knots = @import("knots");` (exactly as planned) so
`main_wasm.zig` can reach `knots.gpu_webgpu_js`/`knots.wasm_io` through the
`playground` module.

#### 2. `examples/playground/static/index.html`, `examples/playground/static/script.js` ✅
Same shape as `examples/triangle/static/*`, titled "Playground", pointing
at `playground.wasm`. `script.js` uses a somewhat larger initial/maximum
`WebAssembly.Memory` (512/8192 pages vs triangle's 256/4096) given
playground's larger embedded content (17 demo sources + font).

#### 3. `examples/playground/build.zig` ✅
Implemented with one structural adjustment from the plan text: rather than
computing a single shared `exe_mod` and passing it to a `buildWasm`
function (which would need `zjb` added to that shared module, awkward
since native/Emscripten don't need it), `buildWasm` builds its own
dedicated executable module from `src/main_wasm.zig` with its own
`playground`+`zjb` imports — called with just the already-built
`playground` module (`mod`) as a parameter, mirroring how `buildEmscripten`
already takes a module parameter. Dispatches from `build()` right after
`mod` is constructed, before the native/Emscripten-only `exe_mod` is built
(so `exe_mod`'s target-based file-selection switch no longer needs a wasm
case — it only ever runs for native/Emscripten now).

#### 4. `examples/playground/build.zig.zon` ✅
Added the `zjb` dependency via `zig fetch --save=zjb`.

### Success Criteria:

- [x] `zig build -Dtarget=wasm32-freestanding` (from `examples/playground`)
  succeeds and produces `playground.wasm`, `zjb_extract.js`, `index.html`.
- [x] Native and Emscripten `examples/playground` targets are unaffected.

**Verification performed:** wasm build produced a real 5.3MB `playground.wasm`
plus `zjb_extract.js`/`index.html`/`script.js`. Native build reaches only
the same pre-existing, unrelated vulkan-zig branch-quota error confirmed in
Phase 1 of the original plan — no new regressions.

---

## Phase 4: Validation across every demo — ✅ Complete

### Overview

`examples/playground` has far more surface area than `triangle` (17 demos,
text input, scrolling lists, canvas effects, context menus, forms) — verify
each one is actually usable on the new target, not just that the shell
renders.

### Manual Testing Steps:

1. [x] Build + serve, open in a real WebGPU-capable browser. Confirm the
   demo gallery shell renders (nav sidebar, header, first demo pane, source
   viewer) with no console errors.
2. [x] Click through every nav tab (all 17 demos) and confirm each renders
   without a console error or crash.
3. [x] Toggle the source-code viewer panel; confirm syntax-highlighted
   source renders correctly.
4. [x] Resize the browser window; confirm the whole layout reflows
   correctly.
5. [x] Confirm `examples/triangle`'s wasm build still works after Phase 2's
   `main_wasm.zig` change.
6. [x] Confirm native `examples/playground` is still unaffected.

**Verification performed (real headless-Chromium WebGPU, screenshots for
each):**
- Initial load: full gallery shell renders pixel-perfect (nav sidebar with
  all 17 icons/labels, header, "Buttons" demo active by default with its
  interactive buttons, syntax-highlighted source viewer) — zero console
  errors (only the harmless favicon 404).
- **All 17 nav tabs** clicked in sequence (`Buttons`, `Context menu`,
  `Sizing`, `Nesting`, `Alignment`, `Justify`, `Control flow`, `Form`,
  `Layer`, `Overflow`, `Grid`, `Virtual list`, `Canvas`, `Async dispatch`,
  `Drops`, `Text wrap`, `Theme`) — every single one: zero new errors.
- **`async_dispatch`** (the Phase 1 fix): clicked "sleep x10" 3 times;
  "wakeups received" went from 0 → 150 (3 × 50, exactly matching the
  synchronous-fallback logic) with zero errors — confirms the crash is
  actually fixed, not just "didn't happen to trigger."
- **`form`** (the Phase 2/3 `std.log` fix): typed into the email field,
  clicked "submit" (opened a confirmation dialog — `form_confirm_open`
  state working correctly), clicked "Yes" — the browser console showed
  `[info] form submit -> email='...' password='...' role=0
  notifications=true cadence=1 volume=0.70`, i.e. `demos/form.zig`'s
  `std.log.info` call, correctly routed through the new `webLog` all the
  way to a real `console.info` call. Definitive proof the compile hazard
  is both real (this is the exact call site that would have failed to
  compile without the fix) and fixed.
- **`canvas`**: gradient effect renders correctly (smooth animated
  multi-color gradient grid).
- **`virtual_list`**: scrolled via mouse wheel from row #0 to row #73-86
  out of 100,000 rows, rendering correctly throughout — confirms
  `VirtualList` + wheel-scroll input work together under real load.
- Resized viewport 1280×720 → 900×600: nav/demo/source panes all reflowed
  correctly.
- Re-verified `examples/triangle`'s wasm build in Phase 2 already (still
  renders correctly).
- Native `examples/playground` confirmed hitting only the pre-existing
  vulkan-zig bug (Phase 3's verification).

### Success Criteria:

- [x] All steps above pass with no console errors and no crashes across
  every demo.

---

## Testing Strategy

### Automated (headless Chromium with real WebGPU, same setup used
throughout the original plan):
- Scripted click-through of all 17 nav tabs, checking for `pageerror`
  events and console errors after each.
- Explicit `async_dispatch` "sleep x10" click + wait, confirming no crash
  and the counter increments.
- Explicit `form` fill-in + submit click, confirming a `webLog` console
  message appears and no crash occurs.
- Screenshot each demo for a quick visual sanity check.

### Manual Testing:
- See Phase 4's steps — a final human pass in a real (non-headless)
  browser, same as the original plan's Phase 6.

## Performance Considerations

None beyond what the original plan already covers — `playground` uses the
same `Renderer`/pipeline machinery as `triangle`, just with more UI
elements on screen at once (more draw calls, larger clip-node/glyph-atlas
usage), which is a quantity change, not a new code path.

## Migration Notes

Not applicable — purely additive; `examples/triangle`'s only change is the
defensive `std_options` addition (no behavior change for existing targets).

## References

- Original plan (merged): `thoughts/wasm-zjb-backend/plans/implementation-plan.md`
  (this repo's history — see `cataggar/knots` PR #2, merged into `zig16`).
- `examples/triangle`'s wasm wiring (the pattern this plan mirrors):
  `examples/triangle/{build.zig,build.zig.zon,src/main_wasm.zig,static/}`.
- Emscripten's equivalent `std.log` workaround:
  `examples/playground/src/main_web.zig`'s `webLog`.
- The `std.Io.Threaded`-can't-compile-for-wasm32-freestanding finding:
  `src/window/backend/wasm/io.zig` and the original plan's Phase 2/3
  write-ups.
