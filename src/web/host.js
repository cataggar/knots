import { createBridgeImports } from "./js-bridge.js";
import { createWasiImports } from "./knots-wasi.js";
import { createWebGL2Backend } from "./knots-webgl2.js";

const WASM_MEMORY_INITIAL_PAGES = 256;
const WASM_MEMORY_MAX_PAGES = 32768;
const WASM_MEMORY64_MAX_PAGES = 131072;
const textDecoder = new TextDecoder("utf-8");

export const WASMFX_PROBE_BYTES = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x02, 0x60, 0x00, 0x00, 0x5d, 0x00,
]);

export const WASMFX_HELPER_BYTES = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0b, 0x03, 0x60, 0x00, 0x00, 0x5d, 0x00,
  0x60, 0x01, 0x7f, 0x01, 0x7f, 0x02, 0x10, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x08, 0x6f, 0x6e, 0x5f,
  0x79, 0x69, 0x65, 0x6c, 0x64, 0x00, 0x00, 0x03, 0x05, 0x04, 0x00, 0x00, 0x02, 0x02, 0x0d, 0x03,
  0x01, 0x00, 0x00, 0x06, 0x0b, 0x02, 0x7f, 0x01, 0x41, 0x00, 0x0b, 0x7f, 0x01, 0x41, 0x00, 0x0b,
  0x07, 0x2e, 0x03, 0x0b, 0x73, 0x75, 0x73, 0x70, 0x65, 0x6e, 0x64, 0x5f, 0x6e, 0x6f, 0x77, 0x00,
  0x02, 0x0a, 0x72, 0x75, 0x6e, 0x5f, 0x79, 0x69, 0x65, 0x6c, 0x64, 0x73, 0x00, 0x03, 0x0f, 0x72,
  0x75, 0x6e, 0x5f, 0x70, 0x75, 0x72, 0x65, 0x5f, 0x79, 0x69, 0x65, 0x6c, 0x64, 0x73, 0x00, 0x04,
  0x09, 0x05, 0x01, 0x03, 0x00, 0x01, 0x01, 0x0a, 0xa1, 0x01, 0x04, 0x1a, 0x00, 0x02, 0x40, 0x03,
  0x40, 0x23, 0x01, 0x41, 0x00, 0x4c, 0x0d, 0x01, 0x23, 0x01, 0x41, 0x01, 0x6b, 0x24, 0x01, 0xe2,
  0x00, 0x0c, 0x00, 0x0b, 0x0b, 0x0b, 0x0c, 0x00, 0x23, 0x00, 0x04, 0x40, 0xe2, 0x00, 0x05, 0x10,
  0x00, 0x0b, 0x0b, 0x3c, 0x02, 0x01, 0x63, 0x01, 0x01, 0x7f, 0x20, 0x00, 0x24, 0x01, 0x41, 0x01,
  0x24, 0x00, 0xd2, 0x01, 0xe0, 0x01, 0x21, 0x01, 0x02, 0x40, 0x03, 0x40, 0x02, 0x64, 0x01, 0x20,
  0x01, 0xe3, 0x01, 0x01, 0x00, 0x00, 0x00, 0x0c, 0x02, 0x0b, 0x21, 0x01, 0x20, 0x02, 0x41, 0x01,
  0x6a, 0x21, 0x02, 0x10, 0x00, 0x0c, 0x00, 0x0b, 0x0b, 0x41, 0x00, 0x24, 0x00, 0x20, 0x02, 0x0b,
  0x3a, 0x02, 0x01, 0x63, 0x01, 0x01, 0x7f, 0x20, 0x00, 0x24, 0x01, 0x41, 0x01, 0x24, 0x00, 0xd2,
  0x01, 0xe0, 0x01, 0x21, 0x01, 0x02, 0x40, 0x03, 0x40, 0x02, 0x64, 0x01, 0x20, 0x01, 0xe3, 0x01,
  0x01, 0x00, 0x00, 0x00, 0x0c, 0x02, 0x0b, 0x21, 0x01, 0x20, 0x02, 0x41, 0x01, 0x6a, 0x21, 0x02,
  0x0c, 0x00, 0x0b, 0x0b, 0x41, 0x00, 0x24, 0x00, 0x20, 0x02, 0x0b,
]);

export const CAP_JSPI = 1 << 0;
export const CAP_WAIT_ASYNC = 1 << 1;
export const CAP_WASMFX = 1 << 2;
export const CAP_PROMISING_ACTIVE = 1 << 3;

export function detectWasmCapabilities() {
  const jspi =
    typeof WebAssembly !== "undefined" &&
    typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function";
  const waitAsync = typeof Atomics !== "undefined" && typeof Atomics.waitAsync === "function";
  let wasmfx = false;
  if (typeof WebAssembly !== "undefined" && typeof WebAssembly.validate === "function") {
    try {
      wasmfx = WebAssembly.validate(WASMFX_PROBE_BYTES);
    } catch {
      wasmfx = false;
    }
  }
  const bitmask = (jspi ? CAP_JSPI : 0) | (waitAsync ? CAP_WAIT_ASYNC : 0) | (wasmfx ? CAP_WASMFX : 0);
  return { jspi, waitAsync, wasmfx, bitmask };
}

export function instantiateWasmfxHelper(onYield = () => {}) {
  if (!detectWasmCapabilities().wasmfx) return null;
  const yieldCallback = typeof onYield === "function" ? onYield : () => {};
  const module = new WebAssembly.Module(WASMFX_HELPER_BYTES);
  const instance = new WebAssembly.Instance(module, {
    env: { on_yield: yieldCallback },
  });
  const { suspend_now, run_yields, run_pure_yields } = instance.exports;
  return {
    module,
    instance,
    exports: instance.exports,
    suspend_now,
    run_yields,
    run_pure_yields,
    suspendNow: suspend_now,
    runYields: run_yields,
    runPureYields: run_pure_yields,
  };
}

function adjustActivePromisingDepth(state, delta) {
  if (!state) return;
  const next = Math.max(0, (state.activePromisingDepth ?? 0) + delta);
  state.activePromisingDepth = next;
  if (state.options && state.options !== state) {
    state.options.activePromisingDepth = next;
  }
}

function adjustInPromisingCall(state, delta) {
  if (!state) return;
  const next = Math.max(0, (state.inPromisingCall ?? 0) + delta);
  state.inPromisingCall = next;
  if (state.options && state.options !== state) {
    state.options.inPromisingCall = next;
  }
}

export function wrapSuspendingImport(fn, state) {
  if (typeof WebAssembly?.Suspending !== "function") return fn;
  return new WebAssembly.Suspending((...args) => {
    const stack = state?.promisingStack;
    const frame = stack && stack.length > 0 ? stack[stack.length - 1] : null;
    if (frame && !frame.suspended) {
      frame.suspended = true;
      stack.pop();
      adjustActivePromisingDepth(state, -1);
    }
    let result;
    try {
      result = fn(...args);
    } catch (err) {
      if (frame) {
        frame.suspended = false;
        stack.push(frame);
        adjustActivePromisingDepth(state, 1);
      }
      throw err;
    }
    const promise =
      result && typeof result.then === "function" ? result : Promise.resolve(result);
    return promise.then(
      (val) => {
        if (frame) {
          frame.suspended = false;
          stack.push(frame);
          adjustActivePromisingDepth(state, 1);
        }
        return val;
      },
      (err) => {
        if (frame) {
          frame.suspended = false;
          stack.push(frame);
          adjustActivePromisingDepth(state, 1);
        }
        throw err;
      },
    );
  });
}

export function wrapPromisingExport(fnOrState, stateOrFn) {
  const [fn, state] =
    typeof fnOrState === "function" ? [fnOrState, stateOrFn] : [stateOrFn, fnOrState];
  if (typeof fn !== "function") return fn;
  const jspiSupported = state?.wasmCapabilities
    ? Boolean(state.wasmCapabilities.jspi)
    : detectWasmCapabilities().jspi;
  if (!state || !jspiSupported || typeof WebAssembly?.promising !== "function") return fn;
  const promisingFn = WebAssembly.promising(fn);
  return (...args) => {
    state.promisingStack ??= [];
    const frame = { suspended: false };
    state.promisingStack.push(frame);
    adjustActivePromisingDepth(state, 1);
    adjustInPromisingCall(state, 1);
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      if (!frame.suspended) {
        const idx = state.promisingStack.lastIndexOf(frame);
        if (idx !== -1) state.promisingStack.splice(idx, 1);
        adjustActivePromisingDepth(state, -1);
      }
      adjustInPromisingCall(state, -1);
    };
    try {
      const result = promisingFn(...args);
      if (frame.suspended && result && typeof result.then === "function") {
        const tracked = result.finally(finish);
        state.lastDispatchPromise = tracked;
        return tracked;
      }
      finish();
      return result;
    } catch (err) {
      finish();
      throw err;
    }
  };
}

function resolveGpuBackendOption(option) {
  if (option === "webgpu" || option === "webgl2" || option === "auto") return option;
  try {
    const param = new URLSearchParams(globalThis.location?.search ?? "").get("gpu");
    if (param === "webgpu" || param === "webgl2" || param === "auto") return param;
  } catch {}
  return "auto";
}

function isCanvas(value) {
  return typeof HTMLCanvasElement !== "undefined" && value instanceof HTMLCanvasElement;
}

function requireCanvas(value) {
  if (!isCanvas(value))
    throw new Error("Knots canvas resolver did not return an HTMLCanvasElement");
  return value;
}

function resolveCanvasOption(canvas, selector) {
  if (isCanvas(canvas)) return canvas;
  if (typeof canvas === "function") return requireCanvas(canvas(selector));
  if (typeof canvas === "string") return requireCanvas(document.querySelector(selector || canvas));
  throw new Error("Knots requires a canvas element, selector string, or resolver function");
}

let layoutMap = null;
let layoutMapPending = false;

function refreshLayoutMap() {
  if (layoutMapPending || !navigator.keyboard?.getLayoutMap) return;
  layoutMapPending = true;
  navigator.keyboard.getLayoutMap().then(
    (map) => {
      layoutMap = map;
      layoutMapPending = false;
    },
    () => {
      layoutMapPending = false;
    },
  );
}

const keyCodes = new Map(
  Object.entries({
    Space: 32,
    Quote: 39,
    Comma: 44,
    Minus: 45,
    Period: 46,
    Slash: 47,
    Digit0: 48,
    Digit1: 49,
    Digit2: 50,
    Digit3: 51,
    Digit4: 52,
    Digit5: 53,
    Digit6: 54,
    Digit7: 55,
    Digit8: 56,
    Digit9: 57,
    Semicolon: 59,
    Equal: 61,
    KeyA: 65,
    KeyB: 66,
    KeyC: 67,
    KeyD: 68,
    KeyE: 69,
    KeyF: 70,
    KeyG: 71,
    KeyH: 72,
    KeyI: 73,
    KeyJ: 74,
    KeyK: 75,
    KeyL: 76,
    KeyM: 77,
    KeyN: 78,
    KeyO: 79,
    KeyP: 80,
    KeyQ: 81,
    KeyR: 82,
    KeyS: 83,
    KeyT: 84,
    KeyU: 85,
    KeyV: 86,
    KeyW: 87,
    KeyX: 88,
    KeyY: 89,
    KeyZ: 90,
    BracketLeft: 91,
    Backslash: 92,
    BracketRight: 93,
    Backquote: 96,
    IntlBackslash: 161,
    IntlRo: 162,
    Escape: 256,
    Enter: 257,
    Tab: 258,
    Backspace: 259,
    Insert: 260,
    Delete: 261,
    ArrowRight: 262,
    ArrowLeft: 263,
    ArrowDown: 264,
    ArrowUp: 265,
    PageUp: 266,
    PageDown: 267,
    Home: 268,
    End: 269,
    CapsLock: 280,
    ScrollLock: 281,
    NumLock: 282,
    PrintScreen: 283,
    Pause: 284,
    F1: 290,
    F2: 291,
    F3: 292,
    F4: 293,
    F5: 294,
    F6: 295,
    F7: 296,
    F8: 297,
    F9: 298,
    F10: 299,
    F11: 300,
    F12: 301,
    F13: 302,
    F14: 303,
    F15: 304,
    F16: 305,
    F17: 306,
    F18: 307,
    F19: 308,
    F20: 309,
    F21: 310,
    F22: 311,
    F23: 312,
    F24: 313,
    F25: 314,
    Numpad0: 320,
    Numpad1: 321,
    Numpad2: 322,
    Numpad3: 323,
    Numpad4: 324,
    Numpad5: 325,
    Numpad6: 326,
    Numpad7: 327,
    Numpad8: 328,
    Numpad9: 329,
    NumpadDecimal: 330,
    NumpadDivide: 331,
    NumpadMultiply: 332,
    NumpadSubtract: 333,
    NumpadAdd: 334,
    NumpadEnter: 335,
    NumpadEqual: 336,
    ShiftLeft: 340,
    ControlLeft: 341,
    AltLeft: 342,
    MetaLeft: 343,
    ShiftRight: 344,
    ControlRight: 345,
    AltRight: 346,
    MetaRight: 347,
    OSLeft: 343,
    OSRight: 347,
    ContextMenu: 348,
  }),
);

const keyDefaults = new Set([32, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269]);

class KnotsBrowserHost {
  constructor(options = {}) {
    this.options = options;
    this.canvas = options.canvas;
    this.headless = Boolean(options.headless);
    this.fullscreenElementOption = options.fullscreenElement ?? null;
    this.logTarget = options.log ?? console;
    this.onError = typeof options.onError === "function" ? options.onError : null;
    this.requestedGpuBackend = resolveGpuBackendOption(options.gpuBackend);
    this.wasmCapabilities = options.wasmCapabilities ?? detectWasmCapabilities();
    this.wasmfxHelper = this.wasmCapabilities.wasmfx ? instantiateWasmfxHelper() : null;
    this.inPromisingCall = 0;
    this.activePromisingDepth = 0;
    this.promisingStack = [];
    this.lastDispatchPromise = null;
    this.frameInFlight = false;
    this.framePendingAfterInFlight = false;
    this.pendingFrameAfterSuspend = false;
    this.gpuBackend = null;
    this.webgl2Backend = null;
    this.gpuAdapter = null;
    this.gpuDevice = null;
    this.gpuQueue = null;
    this.preferredFormat = "bgra8unorm";
    this.pendingFullscreenCanvas = null;
    this.mouseCaptures = new Map();
    this.serviceFullscreen = this.serviceFullscreen.bind(this);
    if (typeof document !== "undefined" && typeof document.addEventListener === "function") {
      for (const event of ["pointerdown", "mousedown", "keydown", "touchstart"]) {
        document.addEventListener(event, this.serviceFullscreen, true);
      }
    }
    this.workerPool = null;
    this.frameCallback = null;
    this.frameRequest = null;
    this.ready = this.initGpu();
  }

  setWorkerPool(workerPool) {
    this.workerPool = workerPool;
  }

  spawnConcurrent(task, group, start, context) {
    return this.workerPool?.dispatch(task, group, start, context) ? 1 : 0;
  }

  forgetConcurrentGroup(group) {
    this.workerPool?.forgetGroup(group);
  }

  setFrameCallback(callback) {
    this.frameCallback = callback;
  }

  clearFrameCallback() {
    this.cancelFrame();
    this.frameCallback = null;
  }

  requestFrame() {
    if (!this.frameCallback || this.frameRequest !== null) return;
    if (this.frameInFlight) {
      this.framePendingAfterInFlight = true;
      this.pendingFrameAfterSuspend = true;
      return;
    }
    const step = (timestamp) => {
      this.frameRequest = null;
      if (!this.frameCallback) return;
      this.lastDispatchPromise = null;
      this.frameInFlight = true;
      const completeFrame = () => {
        this.frameInFlight = false;
        if (this.framePendingAfterInFlight || this.pendingFrameAfterSuspend) {
          this.framePendingAfterInFlight = false;
          this.pendingFrameAfterSuspend = false;
          this.requestFrame();
        }
      };
      let callResult;
      try {
        this.wasmExports?.knots_worker_ack_complete?.();
        callResult = this.frameCallback(timestamp);
      } catch (err) {
        this.frameInFlight = false;
        this.framePendingAfterInFlight = false;
        this.pendingFrameAfterSuspend = false;
        this.fatalError(errorMessage(err));
        return;
      }
      const pendingPromise =
        callResult && typeof callResult.then === "function"
          ? callResult
          : this.lastDispatchPromise;
      if (pendingPromise && typeof pendingPromise.then === "function") {
        pendingPromise.then(
          () => {
            completeFrame();
          },
          (err) => {
            this.frameInFlight = false;
            this.framePendingAfterInFlight = false;
            this.pendingFrameAfterSuspend = false;
            this.fatalError(errorMessage(err));
          },
        );
      } else {
        completeFrame();
      }
    };
    this.frameRequest = requestAnimationFrame(step);
  }

  cancelFrame() {
    this.framePendingAfterInFlight = false;
    this.pendingFrameAfterSuspend = false;
    if (this.frameRequest === null) return;
    cancelAnimationFrame(this.frameRequest);
    this.frameRequest = null;
  }

  async tryInitWebGpu() {
    if (!navigator.gpu) {
      return { ok: false, reason: "WebGPU is not available in this browser" };
    }
    try {
      let adapter = await navigator.gpu.requestAdapter();
      if (!adapter) {
        adapter = await navigator.gpu.requestAdapter({ forceFallbackAdapter: true });
      }
      if (!adapter) {
        return { ok: false, reason: "WebGPU adapter unavailable" };
      }
      const device = await adapter.requestDevice();
      this.gpuBackend = "webgpu";
      this.gpuAdapter = adapter;
      this.gpuDevice = device;
      this.gpuQueue = device.queue;
      this.preferredFormat = navigator.gpu.getPreferredCanvasFormat();
      return { ok: true };
    } catch (err) {
      return { ok: false, reason: errorMessage(err) };
    }
  }

  initWebGL2(selector) {
    let initialCanvas = null;
    try {
      initialCanvas = this.resolveCanvas(selector);
    } catch {}
    const backend = createWebGL2Backend(initialCanvas);
    this.webgl2Backend = backend;
    this.gpuBackend = "webgl2";
    this.gpuAdapter = backend.adapter;
    this.gpuDevice = backend.device;
    this.gpuQueue = backend.queue;
    this.preferredFormat = backend.preferredFormat;
  }

  async initGpu() {
    if (this.headless || (!this.canvas && typeof document === "undefined" && !globalThis.navigator?.gpu)) {
      return;
    }
    if (this.requestedGpuBackend === "webgl2") {
      try {
        this.initWebGL2();
        return;
      } catch (err) {
        this.fatalError(errorMessage(err));
        throw err;
      }
    }

    const webgpuResult = await this.tryInitWebGpu();
    if (webgpuResult.ok) return;

    if (this.requestedGpuBackend === "webgpu") {
      const err = new Error(webgpuResult.reason);
      this.fatalError(err.message);
      throw err;
    }

    try {
      this.initWebGL2();
      this.log(2, `WebGPU unavailable (${webgpuResult.reason}); using WebGL2 fallback`);
    } catch (webgl2Err) {
      const err = new Error(
        `Neither WebGPU (${webgpuResult.reason}) nor WebGL2 (${errorMessage(webgl2Err)}) could be initialized`,
      );
      this.fatalError(err.message);
      throw err;
    }
  }

  ensureGpuBackend(compiledBackend, selector) {
    if (compiledBackend === "webgl2" && this.gpuBackend !== "webgl2") {
      this.initWebGL2(selector);
    }
    if (!this.gpuDevice) {
      throw new Error("GPU device is not initialized");
    }
  }

  getGpuContext(canvas) {
    if (this.gpuBackend === "webgl2") {
      return this.webgl2Backend.getCanvasContext(canvas);
    }
    return canvas.getContext("webgpu");
  }

  resolveCanvas(selector) {
    return resolveCanvasOption(this.canvas, selector);
  }

  canvasSize(canvas, fallbackW, fallbackH) {
    const rect = canvas.getBoundingClientRect();
    const cssW = rect.width > 0 ? rect.width : fallbackW;
    const cssH = rect.height > 0 ? rect.height : fallbackH;
    const dpr = globalThis.devicePixelRatio || 1;
    const logicalW = Math.round(cssW);
    const logicalH = Math.round(cssH);
    const physicalW = Math.round(cssW * dpr);
    const physicalH = Math.round(cssH * dpr);
    canvas.width = physicalW;
    canvas.height = physicalH;
    return { logicalW, logicalH, physicalW, physicalH, contentScale: dpr };
  }

  eventPos(canvas, event) {
    const rect = canvas.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }

  modsOf(event) {
    return (
      (event.shiftKey ? 1 : 0) |
      (event.ctrlKey ? 2 : 0) |
      (event.altKey ? 4 : 0) |
      (event.metaKey ? 8 : 0)
    );
  }

  keyCode(code) {
    return keyCodes.get(code) ?? -1;
  }

  layoutCodepoint(event) {
    refreshLayoutMap();
    const ch = layoutMap?.get(event.code) ?? (event.shiftKey || event.altKey ? "" : event.key);
    if (!ch || Array.from(ch).length !== 1) return 0;
    return ch.codePointAt(0) ?? 0;
  }

  typedCodepoint(event) {
    const chars = Array.from(event.key ?? "");
    if (chars.length !== 1) return 0;
    return chars[0].codePointAt(0) ?? 0;
  }

  textCodepoint(event) {
    if (!event.key) return 0;
    const chars = Array.from(event.key);
    if (chars.length !== 1) return 0;
    if ((event.ctrlKey && !event.altKey) || event.metaKey) return 0;
    return chars[0].codePointAt(0) ?? 0;
  }

  shouldHandleEvent(event, catcher) {
    const target = event.target;
    if (!target || target === catcher) return 1;
    const element =
      typeof Element !== "undefined" && target instanceof Element ? target : target.parentElement;
    if (!element) return 1;
    const tag = element.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA") return 0;
    if (element.isContentEditable) return 0;
    return 1;
  }

  shouldPreventKeyDefault(event, key) {
    if (event.defaultPrevented) return 0;
    const command = (event.ctrlKey && !event.altKey) || event.metaKey;
    if (command) return key === 65 || key === 67 || key === 86 || key === 88 ? 1 : 0;
    if (event.ctrlKey || event.metaKey) return 0;
    if (event.altKey) return key >= 262 && key <= 265 ? 1 : 0;
    return keyDefaults.has(key) || (key >= 32 && key <= 162) ? 1 : 0;
  }

  createPasteCatcher() {
    const catcher = document.createElement("textarea");
    catcher.readOnly = true;
    catcher.ariaHidden = "true";
    Object.assign(catcher.style, {
      position: "fixed",
      left: "-10000px",
      top: "0",
      width: "1px",
      height: "1px",
      opacity: "0",
    });
    document.body.appendChild(catcher);
    return catcher;
  }

  preparePaste(catcher) {
    catcher.readOnly = false;
    catcher.value = "";
    catcher.focus();
    catcher.select();
    setTimeout(() => {
      catcher.readOnly = true;
      if (document.activeElement === catcher) catcher.blur();
    }, 1000);
  }

  copy(text) {
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.readOnly = true;
    Object.assign(textarea.style, {
      position: "fixed",
      left: "-10000px",
      top: "0",
      width: "1px",
      height: "1px",
      opacity: "0",
    });
    document.body.appendChild(textarea);
    textarea.focus();
    textarea.select();

    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch {
      copied = false;
    }
    textarea.remove();
    return copied ? 1 : 0;
  }

  isFullscreen(canvas) {
    return document.fullscreenElement === this.fullscreenTarget(canvas);
  }

  requestFullscreen(canvas) {
    if (document.fullscreenElement === this.fullscreenTarget(canvas)) return 1;
    if (!canvas.requestFullscreen) return 0;
    this.pendingFullscreenCanvas = canvas;
    if (!navigator.userActivation || navigator.userActivation.isActive) this.serviceFullscreen();
    return 1;
  }

  /// The element that goes fullscreen for `canvas`: the canvas itself, or
  /// the `fullscreenElement` option when the page stacks other content
  /// (such as a second canvas) with it.
  fullscreenTarget(canvas) {
    const option = this.fullscreenElementOption;
    if (!option) return canvas;
    return (typeof option === "string" ? document.querySelector(option) : option) ?? canvas;
  }

  exitFullscreen() {
    this.pendingFullscreenCanvas = null;
    if (!document.fullscreenElement) return 1;
    const request = document.exitFullscreen?.();
    if (!request) return 0;
    request.catch((err) => this.fullscreenFailed("exit", err));
    return 1;
  }

  cancelFullscreen(canvas) {
    if (!canvas || this.pendingFullscreenCanvas === canvas) this.pendingFullscreenCanvas = null;
  }

  serviceFullscreen(event) {
    if (event && event.isTrusted === false) return;
    const canvas = this.pendingFullscreenCanvas;
    if (!canvas) return;
    this.pendingFullscreenCanvas = null;
    const request = this.fullscreenTarget(canvas).requestFullscreen?.();
    if (!request) {
      document.dispatchEvent(new Event("knotsfullscreenfailed"));
      return;
    }
    request.catch((err) => this.fullscreenFailed("request", err));
  }

  fullscreenFailed(action, err) {
    this.log(3, `Fullscreen ${action} failed: ${errorMessage(err)}`);
    document.dispatchEvent(new Event("knotsfullscreenfailed"));
  }

  beginMouseCapture(canvas, callback) {
    const existing = this.mouseCaptures.get(canvas);
    if (existing === callback) return;
    if (existing) document.removeEventListener("mousemove", existing, false);
    document.addEventListener("mousemove", callback, false);
    this.mouseCaptures.set(canvas, callback);
  }

  endMouseCapture(canvas, callback) {
    const existing = this.mouseCaptures.get(canvas);
    if (!existing || existing !== callback) return;
    document.removeEventListener("mousemove", existing, false);
    this.mouseCaptures.delete(canvas);
  }

  nowMs(clock) {
    return clock === 0 ? Date.now() : performance.now();
  }

  randomSecure(bytes) {
    if (!globalThis.crypto?.getRandomValues) throw new Error("Secure random is unavailable");
    const maxBytes = 65536;
    for (let offset = 0; offset < bytes.length; offset += maxBytes) {
      globalThis.crypto.getRandomValues(bytes.subarray(offset, offset + maxBytes));
    }
  }

  log(level, message) {
    const logger = this.logTarget;
    if (level >= 3) (logger.error ?? console.error).call(logger, message);
    else if (level === 2) (logger.warn ?? console.warn).call(logger, message);
    else (logger.log ?? console.log).call(logger, message);
  }

  fatalError(message) {
    const error = new Error(String(message));
    error.name = "KnotsFrameError";
    this.log(3, `${error.name}: ${error.message}`);
    if (!this.onError) return;
    try {
      this.onError(error);
    } catch (err) {
      this.log(3, `Knots onError callback failed: ${errorMessage(err)}`);
    }
  }
}

export function createKnotsImports(options = {}, extraOptions = null) {
  if (extraOptions && typeof extraOptions === "object") {
    Object.assign(options, extraOptions);
  }
  const wasmCapabilities = options.wasmCapabilities ?? detectWasmCapabilities();
  options.wasmCapabilities = wasmCapabilities;
  options.inPromisingCall ??= 0;
  options.activePromisingDepth ??= 0;

  const bridge = createBridgeImports();
  const dispatchSymbol = options.symbols?.dispatch ?? "js_bridge_dispatch";
  bridge.setExportSymbols({
    dispatch: dispatchSymbol,
    pointerSize: options.symbols?.pointerSize,
  });
  const host = new KnotsBrowserHost(options);
  bridge.setHost(host);
  let wasiMemory = options.memory ?? null;
  let wasmExports = options.wasmExports ?? null;

  const resolveMemory = () =>
    wasiMemory ??
    options.memory ??
    wasmExports?.memory ??
    options.wasmExports?.memory ??
    bridge.memory ??
    null;

  const startSymbol = options.symbols?.start ?? "main";
  const wrapExports = (exports) => {
    if (!exports || !wasmCapabilities.jspi || options.isWorker) return exports;
    const wrapped = Object.create(exports);
    for (const name of [dispatchSymbol, startSymbol, "knots_init", "knots_event"]) {
      if (typeof exports[name] === "function") {
        Object.defineProperty(wrapped, name, {
          value: wrapPromisingExport(exports[name], host),
          configurable: true,
          enumerable: true,
          writable: true,
        });
      }
    }
    return wrapped;
  };

  if (options.wasmExports) {
    wasmExports = wrapExports(options.wasmExports);
    host.wasmExports = wasmExports;
    bridge.setWasmExports(wasmExports);
  }

  const waitAsync32Impl = async (addrPtr, expected, timeoutNsLo, timeoutNsHi) => {
    const memory = resolveMemory();
    if (!wasmCapabilities.waitAsync || !(memory?.buffer instanceof SharedArrayBuffer)) {
      return 2;
    }
    const index = Math.floor(Number(addrPtr) / 4);
    const view = new Int32Array(memory.buffer);
    const expectedVal = Number(expected) | 0;
    if (Atomics.load(view, index) !== expectedVal) return 1;
    const lo = BigInt(Number(timeoutNsLo) >>> 0);
    const hi = BigInt(Number(timeoutNsHi) >>> 0);
    const timeoutNs = (hi << 32n) | lo;
    const timeoutMs =
      timeoutNs === 0xffffffffffffffffn ? Infinity : Number(timeoutNs) / 1_000_000;
    if (timeoutMs <= 0) {
      return Atomics.load(view, index) === expectedVal ? 2 : 1;
    }
    const res = Atomics.waitAsync(view, index, expectedVal, timeoutMs);
    if (!res.async) {
      return res.value === "ok" ? 0 : res.value === "not-equal" ? 1 : 2;
    }
    const keepAliveMs = Number.isFinite(timeoutMs)
      ? Math.min(2147483647, Math.max(1, Math.ceil(timeoutMs) + 5))
      : 2147483647;
    const keepAliveTimer = setTimeout(() => {}, keepAliveMs);
    try {
      const outcome = await res.value;
      return outcome === "ok" ? 0 : outcome === "not-equal" ? 1 : 2;
    } finally {
      clearTimeout(keepAliveTimer);
    }
  };

  const sleepMsImpl = async (ms) => {
    const delay = Number.isFinite(ms) && ms > 0 ? ms : 0;
    await new Promise((resolve) => setTimeout(resolve, delay));
  };

  const waitAsync32SyncFallback = (addrPtr, expected, _timeoutNsLo, _timeoutNsHi) => {
    const memory = resolveMemory();
    if (!(memory?.buffer instanceof SharedArrayBuffer)) return 2;
    const index = Math.floor(Number(addrPtr) / 4);
    const view = new Int32Array(memory.buffer);
    return Atomics.load(view, index) === (Number(expected) | 0) ? 2 : 1;
  };

  const sleepMsSyncFallback = () => {};

  const useJspiSuspending = Boolean(wasmCapabilities.jspi && !options.isWorker);

  // Import modules of the application's own (for C code that calls into the
  // page). They run on the main thread only; workers get stubs.
  const extraImports =
    typeof options.imports === "function"
      ? options.imports(resolveMemory, () => wasmExports)
      : (options.imports ?? {});

  const envImports = {
    ...(options.memory ? { memory: options.memory } : {}),
    ...(extraImports.env ?? {}),
    knots_host_capabilities: () =>
      (
        (wasmCapabilities.bitmask & 0x7) |
        ((host.activePromisingDepth ?? 0) > 0 ? CAP_PROMISING_ACTIVE : 0)
      ) >>> 0,
    knots_host_notify_complete: () => {
      wasmExports?.knots_worker_ack_complete?.();
      host.requestFrame();
    },
    knots_host_wait_async32: useJspiSuspending
      ? wrapSuspendingImport(waitAsync32Impl, host)
      : waitAsync32SyncFallback,
    knots_host_sleep_ms: useJspiSuspending
      ? wrapSuspendingImport(sleepMsImpl, host)
      : sleepMsSyncFallback,
  };

  const imports = {
    ...extraImports,
    env: envImports,
    ...bridge.imports,
    wasi_snapshot_preview1: createWasiImports(resolveMemory, options.log ?? console),
  };

  return {
    imports,
    env: imports.env,
    js_bridge: imports.js_bridge,
    wasi_snapshot_preview1: imports.wasi_snapshot_preview1,
    wasmCapabilities,
    ready: host.ready,
    bridge,
    host,
    setWasmExports(exports) {
      wasmExports = wrapExports(exports);
      host.wasmExports = wasmExports;
      bridge.setWasmExports(wasmExports);
      return wasmExports;
    },
    getWasmExports() {
      return wasmExports;
    },
    setMemory(memory) {
      wasiMemory = memory;
      options.memory = memory;
    },
  };
}

function errorMessage(err) {
  return err instanceof Error ? `${err.name}: ${err.message}` : String(err);
}

function safeUsizeNumber(value, name) {
  if (typeof value === "bigint") {
    if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER))
      throw new RangeError(`${name} is outside the JS safe integer range`);
    return Number(value);
  }
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < 0)
    throw new RangeError(`${name} is outside the JS safe integer range`);
  return n;
}

function pointerSizeOf(exports, symbols) {
  const fn = exports[symbols.pointerSize];
  if (typeof fn !== "function")
    throw new Error(`Knots wasm export not found: ${symbols.pointerSize}`);
  const size = Number(fn());
  if (size !== 4 && size !== 8) throw new Error(`Unsupported Knots wasm pointer size: ${size}`);
  return size;
}

function wasmUsizeArg(value, pointerSize, name) {
  const n = safeUsizeNumber(value, name);
  if (pointerSize === 8) return BigInt(n);
  if (n > 0xffffffff) throw new RangeError(`${name} does not fit wasm32`);
  return n;
}

function readExportedString(exports, symbols) {
  const lenName = symbols.lastErrorLen;
  const copyName = symbols.lastErrorCopy;
  if (typeof exports[lenName] !== "function" || typeof exports[copyName] !== "function") return "";
  const pointerSize = pointerSizeOf(exports, symbols);
  const len = safeUsizeNumber(exports[lenName](), "exported string length");
  if (!Number.isFinite(len) || len <= 0) return "";
  if (typeof exports[symbols.alloc] !== "function" || typeof exports[symbols.free] !== "function")
    return "";
  const lenArg = wasmUsizeArg(len, pointerSize, "exported string allocation length");
  const ptrRaw = exports[symbols.alloc](lenArg);
  const ptr = safeUsizeNumber(ptrRaw, "exported string pointer");
  if (ptr === 0) return "";
  try {
    const copied = safeUsizeNumber(
      exports[copyName](ptrRaw, lenArg),
      "exported string copied length",
    );

    const byteLength = Math.min(copied, len);
    return new TextDecoder("utf-8").decode(
      Uint8Array.from(new Uint8Array(exports.memory.buffer, ptr, byteLength)),
    );
  } finally {
    exports[symbols.free](ptrRaw, lenArg);
  }
}

function requireKnotsExports(exports, symbols) {
  for (const name of Object.values(symbols)) {
    if (typeof exports[name] !== "function")
      throw new Error(`Knots wasm export not found: ${name}`);
  }
}

function requireBridgeImports(imports) {
  const jsBridge = imports?.js_bridge;
  if (!jsBridge || typeof jsBridge !== "object")
    throw new Error("Knots JS bridge imports must contain a js_bridge module");
  for (const name of [
    "js_bridge_host",
    "js_bridge_global",
    "js_bridge_get",
    "js_bridge_call",
    "js_bridge_release",
  ]) {
    if (typeof jsBridge[name] !== "function")
      throw new Error(`Knots JS bridge import is not a function: ${name}`);
  }
}

function normalizeSymbols(symbols) {
  return {
    start: symbols?.start ?? "main",
    alloc: symbols?.alloc ?? "js_bridge_alloc",
    free: symbols?.free ?? "js_bridge_free",
    dispatch: symbols?.dispatch ?? "js_bridge_dispatch",
    pointerSize: symbols?.pointerSize ?? "js_bridge_pointer_size",
    lastErrorLen: symbols?.lastErrorLen ?? "knots_last_error_len",
    lastErrorCopy: symbols?.lastErrorCopy ?? "knots_last_error_copy",
  };
}

async function ensureCrossOriginIsolation() {
  if (globalThis.crossOriginIsolated) {
    try {
      globalThis.sessionStorage?.removeItem("knots-coi-reloaded");
    } catch {}
    return true;
  }
  if (
    typeof window === "undefined" ||
    !window.isSecureContext ||
    typeof navigator === "undefined" ||
    !("serviceWorker" in navigator)
  ) {
    return false;
  }
  try {
    const reloadKey = "knots-coi-reloaded";
    if (window.sessionStorage?.getItem(reloadKey) === "1") {
      window.sessionStorage.removeItem(reloadKey);
      return false;
    }
    const swUrl = new URL("./coi-serviceworker.js", import.meta.url);
    const registration = await navigator.serviceWorker.register(swUrl);
    const worker =
      registration.installing || registration.waiting || registration.active;
    if (worker) {
      if (worker.state !== "activated") {
        await new Promise((resolve) => {
          const onStateChange = () => {
            if (worker.state === "activated" || worker.state === "redundant") {
              worker.removeEventListener("statechange", onStateChange);
              resolve();
            }
          };
          worker.addEventListener("statechange", onStateChange);
        });
      }
      if (worker.state === "redundant") {
        return false;
      }
      window.sessionStorage?.setItem(reloadKey, "1");
      window.location.reload();
      return await new Promise(() => {});
    }
  } catch {}
  return false;
}

export async function startKnots({
  wasmUrl,
  fallbackWasmUrl,
  startSymbol,
  symbols,
  canvas = "#canvas",
  gpuBackend,
  wasmExports,
  log,
  onError,
  extensions = [],
  minWorkers = 0,
  fullscreenElement,
  imports: extraImports,
}) {
  const extensionUrls = extensions.map((url) => new URL(url, document.baseURI).href);
  const module = wasmExports ? null : await compileWasm(wasmUrl, fallbackWasmUrl, log);
  const threaded =
    module !== null &&
    WebAssembly.Module.exports(module).some(({ name }) => name === "knots_worker_run");
  if (threaded && !(await ensureCrossOriginIsolation()))
    throw new Error(
      "Knots worker dispatch requires cross-origin isolation (COOP and COEP headers)",
    );
  const exports = wasmExports;
  const resolvedSymbols = normalizeSymbols({
    ...symbols,
    start: startSymbol ?? symbols?.start,
  });
  const imports = createKnotsImports({
    canvas,
    gpuBackend,
    fullscreenElement,
    imports: extraImports,
    wasmExports: exports,
    log,
    onError,
    symbols: resolvedSymbols,
  });
  await imports.ready;
  requireBridgeImports(imports.imports);
  const instantiated = exports
    ? { instance: { exports }, memory: null, pointerSize: null }
    : threaded
      ? await instantiateThreadedWasm(module, imports.imports)
      : {
          instance: await WebAssembly.instantiate(module, imports.imports),
          memory: null,
          pointerSize: null,
        };
  const result = { instance: instantiated.instance, module };
  requireKnotsExports(result.instance.exports, {
    start: resolvedSymbols.start,
    alloc: resolvedSymbols.alloc,
    free: resolvedSymbols.free,
    dispatch: resolvedSymbols.dispatch,
    pointerSize: resolvedSymbols.pointerSize,
  });
  if (threaded)
    requireKnotsExports(result.instance.exports, {
      run: "knots_worker_run",
      complete: "knots_worker_complete",
      release: "knots_worker_release",
      abort: "knots_worker_abort",
      stackAlloc: "knots_worker_stack_alloc",
      stackFree: "knots_worker_stack_free",
    });
  imports.setWasmExports(result.instance.exports);
  const memory = instantiated.memory ?? result.instance.exports.memory;
  imports.setMemory(memory);
  for (const url of extensionUrls) {
    const extension = await import(url);
    await extension.installMain?.({
      host: imports.host,
      bridge: imports.bridge,
      memory,
      exports: result.instance.exports,
      module: result.module,
    });
  }
  if (
    threaded &&
    pointerSizeOf(result.instance.exports, resolvedSymbols) !== instantiated.pointerSize
  )
    throw new Error("Knots worker runtime pointer size does not match the WebAssembly module");
  let workerPool = null;
  if (threaded) {
    const { WorkerPool } = await import("./knots-worker-pool.js");
    workerPool = new WorkerPool({
      module,
      memory: instantiated.memory,
      exports: result.instance.exports,
      pointerSize: instantiated.pointerSize,
      capabilities: imports.wasmCapabilities.bitmask,
      extensions: extensionUrls,
      minWorkers,
      onComplete: () => {
        result.instance.exports.knots_worker_ack_complete?.();
        imports.host.requestFrame();
      },
      onError: (error) => imports.host.fatalError(errorMessage(error)),
    });
    await workerPool.init();
    imports.host.setWorkerPool(workerPool);
  }
  // Exported by wasm32-wasi builds only.
  result.instance.exports.__wasm_call_ctors?.();
  const rawStart = result.instance.exports[resolvedSymbols.start];
  const start = wrapPromisingExport(rawStart, imports.host);
  const rc = await start();
  if (rc !== 0) {
    const detail = readExportedString(result.instance.exports, resolvedSymbols);
    throw new Error(`Knots start failed: ${rc}${detail ? `: ${detail}` : ""}`);
  }
  return {
    instance: result.instance,
    module: result.module,
    host: imports.host,
    bridge: imports.bridge,
    wasmCapabilities: imports.wasmCapabilities,
  };
}

async function compileWasm(wasmUrl, fallbackWasmUrl, log = console) {
  try {
    return await compileSingleWasm(wasmUrl);
  } catch (err) {
    if (
      err instanceof WebAssembly.CompileError &&
      typeof wasmUrl === "string" &&
      wasmUrl.endsWith(".wasm") &&
      !wasmUrl.endsWith("-wasm32.wasm")
    ) {
      const candidateUrl = fallbackWasmUrl ?? wasmUrl.replace(/\.wasm$/, "-wasm32.wasm");
      try {
        const response = await fetch(candidateUrl);
        if (response.ok) {
          console.warn("Memory64 (wasm64) unavailable; falling back to wasm32 build");
          if (log && log !== console && typeof log.warn === "function") {
            log.warn("Memory64 (wasm64) unavailable; falling back to wasm32 build");
          }
          return await WebAssembly.compile(await response.arrayBuffer());
        }
      } catch {}
    }
    throw err;
  }
}

async function compileSingleWasm(wasmUrl) {
  if (WebAssembly.compileStreaming) {
    try {
      return await WebAssembly.compileStreaming(fetch(wasmUrl));
    } catch (err) {
      if (!(err instanceof TypeError || err instanceof WebAssembly.CompileError)) throw err;
    }
  }
  const response = await fetch(wasmUrl);
  return WebAssembly.compile(await response.arrayBuffer());
}

async function instantiateThreadedWasm(module, imports) {
  let wasm32Error;
  try {
    return await instantiateThreadedWasmWithPointerSize(module, imports, 4);
  } catch (error) {
    if (!(error instanceof WebAssembly.LinkError)) throw error;
    wasm32Error = error;
  }

  try {
    return await instantiateThreadedWasmWithPointerSize(module, imports, 8);
  } catch (error) {
    if (
      error instanceof WebAssembly.LinkError &&
      !/memory|knots_worker_task|i64/i.test(wasm32Error?.message ?? "")
    ) {
      throw wasm32Error;
    }
    throw error;
  }
}

async function instantiateThreadedWasmWithPointerSize(module, imports, pointerSize) {
  if (typeof SharedArrayBuffer === "undefined") {
    throw new Error(
      "Failed to initialize shared WebAssembly memory for worker threads; serve the page with Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp.",
    );
  }
  const initial = pointerSize === 8 ? BigInt(WASM_MEMORY_INITIAL_PAGES) : WASM_MEMORY_INITIAL_PAGES;
  const maximum = pointerSize === 8 ? BigInt(WASM_MEMORY64_MAX_PAGES) : WASM_MEMORY_MAX_PAGES;
  let memory;
  try {
    memory = new WebAssembly.Memory({
      initial,
      maximum,
      shared: true,
      ...(pointerSize === 8 ? { address: "i64" } : {}),
    });
  } catch {
    throw new Error(
      "Failed to initialize shared WebAssembly memory for worker threads; serve the page with Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp.",
    );
  }
  const pointerType = pointerSize === 8 ? "i64" : "i32";
  const workerTask = new WebAssembly.Global(
    { value: pointerType, mutable: true },
    pointerSize === 8 ? 0n : 0,
  );
  const instance = await WebAssembly.instantiate(module, {
    ...imports,
    env: { ...imports.env, memory, knots_worker_task: workerTask },
  });
  return { instance, memory, pointerSize };
}
