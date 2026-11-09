import { createBridgeImports } from "./js-bridge.js";
import { createWasiImports } from "./knots-wasi.js";

let exports;
let idleStack;

const CAP_WAIT_ASYNC = 1 << 1;
const CAP_PROMISING_ACTIVE = 1 << 3;

const host = {
  activePromisingDepth: 0,
  inPromisingCall: 0,
  nowMs(clock) {
    return clock === 0 ? Date.now() : performance.now();
  },
  randomSecure(bytes) {
    const maxBytes = 65536;
    for (let offset = 0; offset < bytes.length; offset += maxBytes)
      globalThis.crypto.getRandomValues(bytes.subarray(offset, offset + maxBytes));
  },
  log(level, message) {
    if (level >= 3) console.error(message);
    else if (level === 2) console.warn(message);
    else console.log(message);
  },
  fatalError(message) {
    throw new Error(String(message));
  },
};

self.onmessage = async ({ data }) => {
  if (data.type === "init") {
    try {
      const bridge = createBridgeImports();
      bridge.setHost(host);
      const pointerType = data.pointerSize === 8 ? "i64" : "i32";
      const workerTask = new WebAssembly.Global(
        { value: pointerType, mutable: true },
        data.pointerSize === 8 ? 0n : 0,
      );
      const waitScratch = new Int32Array(new SharedArrayBuffer(4));
      const workerCapabilities =
        typeof Atomics !== "undefined" && typeof Atomics.waitAsync === "function"
          ? CAP_WAIT_ASYNC
          : 0;
      const imports = {
        ...bridge.imports,
        wasi_snapshot_preview1: createWasiImports(() => data.memory),
        env: {
          memory: data.memory,
          knots_worker_task: workerTask,
          knots_host_capabilities: () =>
            (workerCapabilities | (host.activePromisingDepth > 0 ? CAP_PROMISING_ACTIVE : 0)) >>> 0,
          knots_host_wait_async32: (addrPtr, expected, timeoutNsLo, timeoutNsHi) => {
            if (!(data.memory?.buffer instanceof SharedArrayBuffer)) return 2;
            const index = (Number(addrPtr) >>> 0) >>> 2;
            const view = new Int32Array(data.memory.buffer);
            const lo = BigInt(Number(timeoutNsLo) >>> 0);
            const hi = BigInt(Number(timeoutNsHi) >>> 0);
            const timeoutNs = (hi << 32n) | lo;
            const timeoutMs =
              timeoutNs === 0xffffffffffffffffn ? Infinity : Number(timeoutNs) / 1_000_000;
            const outcome = Atomics.wait(view, index, Number(expected) | 0, timeoutMs);
            return outcome === "ok" ? 0 : outcome === "not-equal" ? 1 : 2;
          },
          knots_host_sleep_ms: (ms) => {
            const delay = Number.isFinite(ms) && ms > 0 ? ms : 0;
            if (delay > 0) Atomics.wait(waitScratch, 0, 0, delay);
          },
        },
      };

      // Import modules the application provides on the main thread only
      // (for example a GL context) are stubbed here.
      for (const { module, name, kind } of WebAssembly.Module.imports(data.module)) {
        if (kind !== "function") continue;
        if (module in imports) {
          if (!(name in imports[module])) {
            imports[module][name] = () => {
              throw new Error(`${module}.${name} is only available on the main thread`);
            };
          }
          continue;
        }
        (imports[`stub:${module}`] ??= {})[name] = () => {
          throw new Error(`${module}.${name} is only available on the main thread`);
        };
      }

      for (const key of Object.keys(imports)) {
        if (key.startsWith("stub:")) {
          imports[key.slice(5)] = imports[key];
          delete imports[key];
        }
      }

      const instance = await WebAssembly.instantiate(data.module, imports);
      exports = instance.exports;

      for (const url of data.extensions ?? []) {
        const extension = await import(url);
        await extension.installWorker?.({ host, memory: data.memory, exports });
      }

      idleStack = exports.__stack_pointer.value;
      bridge.setWasmExports(exports);
      self.postMessage({ type: "ready" });
    } catch (error) {
      self.postMessage({
        type: "init-error",
        error: String(error?.stack ?? error),
      });
    }
    return;
  }

  if (data.type !== "run") return;
  try {
    exports.__stack_pointer.value = data.stack;
    exports.knots_worker_run(data.start, data.context, data.task);
    exports.knots_worker_complete(data.task);
    self.postMessage({ type: "complete", task: data.task });
  } catch (error) {
    exports.knots_worker_abort(data.task);
    self.postMessage({
      type: "run-error",
      task: data.task,
      error: String(error?.stack ?? error),
    });
  } finally {
    exports.__stack_pointer.value = idleStack;
  }
};
