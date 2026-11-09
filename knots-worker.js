import { createBridgeImports } from "./js-bridge.js";
import { createWasiImports } from "./knots-wasi.js";

let instance = null;
let exports;
let memory = null;
let idleStack;
let pointerSize = 4;
let assignedWorkerId = 0;
let assignedStack = 0;

const CAP_WAIT_ASYNC = 1 << 1;
const CAP_PROMISING_ACTIVE = 1 << 3;

const host = {
  activePromisingDepth: 0,
  inPromisingCall: 0,
  spawnConcurrent() {
    return 0;
  },
  forgetConcurrentGroup() {},
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

function toPointerGlobalValue(globalObj, value) {
  if (typeof globalObj?.value === "bigint" || pointerSize === 8) {
    return typeof value === "bigint" ? value : BigInt(Math.trunc(Number(value)));
  }
  return typeof value === "bigint" ? Number(value) >>> 0 : value >>> 0;
}

function toPointerArg(_fn, value) {
  if (pointerSize === 8 || typeof exports?.__stack_pointer?.value === "bigint") {
    return typeof value === "bigint" ? value : BigInt(Math.trunc(Number(value)));
  }
  return typeof value === "bigint" ? Number(value) >>> 0 : value >>> 0;
}

function createEnvImports(getMemory, getCapabilities, workerTask, waitScratch) {
  const wait32 = (addrPtr, expected, timeoutNsLo, timeoutNsHi) => {
    const mem = getMemory();
    if (!(mem?.buffer instanceof SharedArrayBuffer)) return 2;
    const index = Math.floor(Number(addrPtr) / 4);
    const view = new Int32Array(mem.buffer);
    const lo = BigInt(Number(timeoutNsLo) >>> 0);
    const hi = BigInt(Number(timeoutNsHi) >>> 0);
    const timeoutNs = (hi << 32n) | lo;
    const timeoutMs =
      timeoutNs === 0xffffffffffffffffn ? Infinity : Number(timeoutNs) / 1_000_000;
    const outcome = Atomics.wait(view, index, Number(expected) | 0, timeoutMs);
    return outcome === "ok" ? 0 : outcome === "not-equal" ? 1 : 2;
  };
  return {
    memory: getMemory(),
    knots_worker_task: workerTask,
    knots_host_capabilities: () =>
      (getCapabilities() | (host.activePromisingDepth > 0 ? CAP_PROMISING_ACTIVE : 0)) >>> 0,
    knots_host_notify_complete() {
      self.postMessage({ type: "complete" });
    },
    knots_host_spawn_concurrent() {
      return 0;
    },
    knots_host_atomic_wait32: wait32,
    knots_host_wait_async32: wait32,
    knots_host_atomic_notify: (addrPtr, count) => {
      const mem = getMemory();
      if (!(mem?.buffer instanceof SharedArrayBuffer)) return 0;
      const index = Math.floor(Number(addrPtr) / 4);
      return Atomics.notify(new Int32Array(mem.buffer), index, Number(count) >>> 0);
    },
    knots_host_sleep_ms: (ms) => {
      const delay = Number.isFinite(ms) && ms > 0 ? ms : 0;
      if (delay > 0) Atomics.wait(waitScratch, 0, 0, delay);
    },
  };
}

function enterWorkerLoop(workerId, stack) {
  if (workerId !== undefined && workerId !== null) {
    assignedWorkerId = Number(workerId) >>> 0;
  }
  if (stack !== undefined && stack !== null) {
    assignedStack = typeof stack === "bigint" ? stack : Number(stack);
  }
  if (typeof instance?.exports?.knots_worker_loop !== "function") return;
  const wasmExports = instance.exports;
  if (assignedStack && wasmExports.__stack_pointer) {
    wasmExports.__stack_pointer.value = toPointerGlobalValue(
      wasmExports.__stack_pointer,
      assignedStack,
    );
  }
  while (true) {
    try {
      if (assignedStack && wasmExports.__stack_pointer) {
        wasmExports.__stack_pointer.value = toPointerGlobalValue(
          wasmExports.__stack_pointer,
          assignedStack,
        );
      }
      wasmExports.knots_worker_loop(assignedWorkerId || 1);
      break;
    } catch (error) {
      if (assignedStack && wasmExports.__stack_pointer) {
        wasmExports.__stack_pointer.value = toPointerGlobalValue(
          wasmExports.__stack_pointer,
          assignedStack,
        );
      }
      const rawTask =
        typeof wasmExports.knots_worker_current_task === "function"
          ? wasmExports.knots_worker_current_task()
          : 0;
      const trappedTask = Number(rawTask);
      let aborted = false;
      if (trappedTask && typeof wasmExports.knots_worker_abort === "function") {
        try {
          wasmExports.knots_worker_abort(
            toPointerArg(wasmExports.knots_worker_abort, rawTask),
          );
          aborted = true;
        } catch {}
      }
      const message = error instanceof Error ? error.message : String(error);
      self.postMessage({
        type: "run-error",
        task: trappedTask,
        aborted,
        workerId: assignedWorkerId,
        message,
        error: String(error?.stack ?? error),
      });
      if (!trappedTask) break;
    }
  }
}

self.onmessage = async ({ data }) => {
  if (data.type === "init") {
    try {
      if (typeof data.workerId === "number") assignedWorkerId = data.workerId >>> 0;
      if (data.stack !== undefined && data.stack !== null) {
        assignedStack = typeof data.stack === "bigint" ? data.stack : Number(data.stack);
      }
      pointerSize = data.pointerSize === 8 ? 8 : 4;
      memory = data.memory;

      const bridge = createBridgeImports();
      bridge.setHost(host);
      const pointerType = pointerSize === 8 ? "i64" : "i32";
      const workerTask = new WebAssembly.Global(
        { value: pointerType, mutable: true },
        pointerSize === 8 ? 0n : 0,
      );
      const waitScratch = new Int32Array(new SharedArrayBuffer(4));
      const defaultCapabilities =
        typeof Atomics !== "undefined" && typeof Atomics.waitAsync === "function"
          ? CAP_WAIT_ASYNC
          : 0;
      const workerCapabilities =
        typeof data.capabilities === "number" ? data.capabilities >>> 0 : defaultCapabilities;
      const imports = {
        ...bridge.imports,
        wasi_snapshot_preview1: createWasiImports(() => memory),
        env: createEnvImports(() => memory, () => workerCapabilities, workerTask, waitScratch),
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

      instance = await WebAssembly.instantiate(data.module, imports);
      exports = instance.exports;

      for (const url of data.extensions ?? []) {
        const extension = await import(url);
        await extension.installWorker?.({ host, memory, exports });
      }

      idleStack = exports.__stack_pointer?.value;
      bridge.setWasmExports(exports);
      self.postMessage({ type: "ready", workerId: assignedWorkerId });
      if (data.park && assignedStack) {
        enterWorkerLoop(assignedWorkerId, assignedStack);
      }
    } catch (error) {
      self.postMessage({
        type: "init-error",
        workerId: assignedWorkerId,
        message: error instanceof Error ? error.message : String(error),
        error: String(error?.stack ?? error),
      });
    }
    return;
  }

  if (data.type === "park") {
    assignedWorkerId = (data.workerId ?? assignedWorkerId) >>> 0;
    if (data.stack !== undefined && data.stack !== null) {
      assignedStack = typeof data.stack === "bigint" ? data.stack : Number(data.stack);
    }
    enterWorkerLoop(assignedWorkerId, assignedStack);
    return;
  }

  if (data.type !== "run") return;
  try {
    if (data.stack !== undefined && data.stack !== null && exports.__stack_pointer) {
      exports.__stack_pointer.value = toPointerGlobalValue(exports.__stack_pointer, data.stack);
    }
    exports.knots_worker_run(
      toPointerArg(exports.knots_worker_run, data.start),
      toPointerArg(exports.knots_worker_run, data.context),
      toPointerArg(exports.knots_worker_run, data.task),
    );
    exports.knots_worker_complete?.(toPointerArg(exports.knots_worker_complete, data.task));
    self.postMessage({ type: "done", task: data.task, workerId: assignedWorkerId });
  } catch (error) {
    try {
      exports.knots_worker_abort?.(toPointerArg(exports.knots_worker_abort, data.task));
    } catch {}
    const message = error instanceof Error ? error.message : String(error);
    self.postMessage({
      type: "run-error",
      task: Number(data.task),
      aborted: true,
      workerId: assignedWorkerId,
      message,
      error: String(error?.stack ?? error),
    });
  } finally {
    if (idleStack !== undefined && exports?.__stack_pointer) {
      exports.__stack_pointer.value = idleStack;
    }
  }
};
