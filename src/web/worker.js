import { createBridgeImports } from "./js-bridge.js";

let exports;
let idleStack;

const host = {
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
      const imports = {
        ...bridge.imports,
        env: { memory: data.memory, knots_worker_task: workerTask },
      };
      const instance = await WebAssembly.instantiate(data.module, imports);
      exports = instance.exports;
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
