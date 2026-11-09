const maxAllowedWorkers = 63;
const workerCount = Math.min(
  maxAllowedWorkers,
  Math.max(1, (globalThis.navigator?.hardwareConcurrency ?? 4) - 1),
);

export class WorkerPool {
  constructor({
    module,
    memory,
    exports,
    pointerSize,
    capabilities = 0,
    extensions = [],
    minWorkers = 0,
    maxWorkers,
    onComplete,
    onError,
  }) {
    this.extensions = extensions;
    this.minWorkers = Math.min(maxAllowedWorkers, Math.max(1, minWorkers));
    this.maxWorkers = Math.min(
      maxAllowedWorkers,
      Math.max(maxWorkers ?? workerCount, this.minWorkers),
    );
    this.module = module;
    this.memory = memory;
    this.exports = exports;
    this.pointerSize = pointerSize;
    this.capabilities = capabilities;
    this.onComplete = onComplete;
    this.onError = onError;
    this.workers = [];
    this.idle = [];
    this.tasks = new Map();
    this.pending = [];
    this.startingWorkers = 0;
    this.nextWorkerId = 1;
    this.destroyed = false;
  }

  get usesFutexQueue() {
    return typeof this.exports?.knots_worker_loop === "function";
  }

  async init() {
    this.destroyed = false;
    this.exports?.knots_worker_set_max_workers?.(this.maxWorkers);
    const count = Math.min(this.minWorkers, this.maxWorkers);
    const initialWorkers = Array.from({ length: count }, () => this.startWorker());
    await Promise.all(initialWorkers);
  }

  startWorker() {
    if (this.destroyed) {
      return Promise.reject(new Error("WorkerPool has been shut down"));
    }
    let initialStack = 0;
    if (this.usesFutexQueue) {
      const rawStack = this.exports.knots_worker_stack_alloc();
      if (rawStack === 0 || rawStack === 0n) {
        return Promise.reject(new Error("Knots worker stack allocation failed"));
      }
      initialStack = rawStack;
    }
    this.startingWorkers += 1;
    const workerId = ((this.nextWorkerId++ - 1) % 63) + 1;
    const worker = new Worker(new URL("./knots-worker.js", import.meta.url), {
      type: "module",
      name: `knots-${workerId}`,
    });
    const entry = {
      worker,
      workerId,
      ready: false,
      failed: false,
      busy: false,
      parkedInWasm: false,
      stack: initialStack,
      resolveReady: null,
      rejectReady: null,
    };
    this.workers.push(entry);

    const readyPromise = new Promise((resolve, reject) => {
      entry.resolveReady = resolve;
      entry.rejectReady = reject;
    });

    worker.onmessage = ({ data }) => {
      this.handleMessage(entry, data);
    };
    worker.onerror = (event) => {
      const error = new Error(event.message || "Knots worker failed");
      if (entry.ready) {
        this.failWorker(entry, error);
      } else {
        worker.terminate();
        if (entry.stack) {
          this.exports?.knots_worker_stack_free?.(this.wasmPointer(entry.stack));
          entry.stack = 0;
        }
        this.workers = this.workers.filter((candidate) => candidate !== entry);
        entry.rejectReady?.(error);
      }
    };

    worker.postMessage({
      type: "init",
      module: this.module,
      memory: this.memory,
      capabilities: this.capabilities,
      pointerSize: this.pointerSize,
      extensions: this.extensions,
      workerId,
      ...(this.usesFutexQueue ? { stack: entry.stack, park: true } : {}),
    });

    return readyPromise.finally(() => {
      this.startingWorkers = Math.max(0, this.startingWorkers - 1);
      if (!this.destroyed && !this.usesFutexQueue) {
        this.pump();
        this.scale();
      }
    });
  }

  addWorker() {
    return this.startWorker();
  }

  handleMessage(entry, data) {
    if (!data || this.destroyed) return;

    if (data.type === "ready") {
      if (!entry.stack) {
        const rawStack = this.exports.knots_worker_stack_alloc();
        if (rawStack === 0 || rawStack === 0n) {
          entry.worker.terminate();
          this.workers = this.workers.filter((candidate) => candidate !== entry);
          entry.rejectReady?.(new Error("Knots worker stack allocation failed"));
          return;
        }
        entry.stack = rawStack;
        entry.ready = true;
        if (this.usesFutexQueue) {
          entry.parkedInWasm = true;
          entry.worker.postMessage({
            type: "park",
            workerId: entry.workerId,
            stack: entry.stack,
          });
        } else {
          this.idle.push(entry);
          this.pump();
        }
        entry.resolveReady?.(entry);
        return;
      }
      entry.ready = true;
      if (this.usesFutexQueue) {
        entry.parkedInWasm = true;
      } else {
        this.idle.push(entry);
        this.pump();
      }
      entry.resolveReady?.(entry);
      return;
    }

    if (data.type === "init-error") {
      entry.worker.terminate();
      if (entry.stack) {
        this.exports?.knots_worker_stack_free?.(this.wasmPointer(entry.stack));
        entry.stack = 0;
      }
      this.workers = this.workers.filter((candidate) => candidate !== entry);
      const detail = data.error || data.message || "Unknown worker initialization error";
      entry.rejectReady?.(new Error(`Knots worker initialization failed: ${detail}`));
      return;
    }

    if (data.type === "complete") {
      if (!entry.parkedInWasm && data.task !== undefined) {
        this.finishTask(Number(data.task), false);
        entry.busy = false;
        if (!this.idle.includes(entry)) this.idle.push(entry);
        this.pump();
        return;
      }
      this.exports?.knots_worker_ack_complete?.();
      this.onComplete?.();
      return;
    }

    if (data.type === "done") {
      if (data.task !== undefined) {
        this.finishTask(Number(data.task), false);
      }
      entry.busy = false;
      if (!entry.parkedInWasm && !this.idle.includes(entry)) {
        this.idle.push(entry);
      }
      this.pump();
      return;
    }

    if (data.type === "run-error") {
      if (!entry.parkedInWasm) {
        const taskAddress = Number(data.task);
        const task = this.tasks.get(taskAddress);
        if (task) {
          this.tasks.delete(taskAddress);
          if (!task.forgotten && !data.aborted) {
            const wasmTask = this.wasmPointer(taskAddress);
            this.exports?.knots_worker_abort?.(wasmTask);
          }
        } else if (data.task && !data.aborted) {
          this.exports?.knots_worker_abort?.(this.wasmPointer(data.task));
        }
        entry.busy = false;
        if (!this.idle.includes(entry)) this.idle.push(entry);
        this.pump();
      }
      this.exports?.knots_worker_ack_complete?.();
      this.onError?.(
        new Error(data.message || data.error || "WebAssembly worker task failed"),
      );
      this.onComplete?.();
    }
  }

  dispatch(task, groupOrStart, startOrContext, maybeContext) {
    if (this.destroyed) return false;
    if (this.usesFutexQueue) {
      if (this.workers.length === 0 && this.maxWorkers <= 0) return false;
      if (this.workers.length < this.maxWorkers) {
        this.scale(this.maxWorkers - this.workers.length);
      }
      return this.workers.length > 0 || this.startingWorkers > 0;
    }
    if (this.workers.length === 0) return false;
    const hasGroup = maybeContext !== undefined;
    const group = hasGroup ? Number(groupOrStart) : 0;
    const start = hasGroup ? startOrContext : groupOrStart;
    const context = hasGroup ? maybeContext : startOrContext;
    const taskAddress = Number(task);
    this.tasks.set(taskAddress, {
      group,
      worker: null,
      forgotten: false,
      message: {
        type: "run",
        task: this.wasmPointer(task),
        start: this.wasmPointer(start),
        context: this.wasmPointer(context),
      },
    });
    this.pending.push(taskAddress);
    this.scale();
    this.pump();
    return true;
  }

  wasmPointer(value) {
    if (this.pointerSize === 8) {
      return typeof value === "bigint" ? value : BigInt(Math.trunc(Number(value)));
    }
    return typeof value === "bigint" ? Number(value) : value;
  }

  scale(desiredNewWorkers) {
    if (this.destroyed) return;
    const availableSlots = Math.max(0, this.maxWorkers - this.workers.length);
    if (availableSlots === 0) return;
    const requested =
      desiredNewWorkers !== undefined
        ? desiredNewWorkers
        : this.usesFutexQueue
          ? 1
          : Math.max(0, this.tasks.size - this.workers.length);
    const count = Math.min(availableSlots, Math.max(0, requested));
    for (let i = 0; i < count; i++) {
      this.startWorker().catch((error) => {
        this.onError?.(error);
      });
    }
  }

  pump() {
    if (this.usesFutexQueue) return;
    while (this.idle.length > 0 && this.pending.length > 0) {
      let taskAddress;
      let task;
      do {
        taskAddress = this.pending.shift();
        if (taskAddress === undefined) return;
        task = this.tasks.get(taskAddress);
      } while (!task);

      const record = this.idle.shift();
      if (!record || record.busy || record.failed) continue;
      task.worker = record;
      record.busy = true;
      try {
        record.worker.postMessage({
          ...task.message,
          stack: this.wasmPointer(record.stack),
        });
      } catch (error) {
        record.busy = false;
        this.idle.push(record);
        this.finishTask(taskAddress, true);
        this.onError?.(error);
      }
    }
  }

  finishTask(taskAddress, abort) {
    const task = this.tasks.get(taskAddress);
    if (!task) return;
    this.tasks.delete(taskAddress);
    if (task.forgotten) return;
    const wasmTask = this.wasmPointer(taskAddress);
    if (abort) {
      this.exports.knots_worker_abort(wasmTask);
    } else {
      this.exports.knots_worker_release(wasmTask);
    }
    this.onComplete?.();
  }

  failWorker(record, error) {
    if (record.failed) return;
    record.failed = true;
    record.worker.terminate();
    if (record.stack) {
      this.exports.knots_worker_stack_free?.(this.wasmPointer(record.stack));
    }
    this.workers = this.workers.filter((candidate) => candidate !== record);
    this.idle = this.idle.filter((candidate) => candidate !== record);
    for (const [taskAddress, task] of this.tasks) {
      if (task.worker !== record) continue;
      this.finishTask(taskAddress, true);
    }
    this.onError?.(error);
    if (!this.usesFutexQueue) {
      this.pump();
      this.scale();
    }
  }

  forgetGroup(group) {
    const key = Number(group);
    for (const task of this.tasks.values()) {
      if (task.group === key) task.forgotten = true;
    }
  }

  shutdown() {
    this.destroyed = true;
    this.exports?.knots_worker_stop?.();
    this.exports?.knots_worker_wake_all?.();
    for (const entry of this.workers) {
      try {
        entry.worker.terminate();
      } catch {}
      if (entry.stack && typeof this.exports?.knots_worker_stack_free === "function") {
        try {
          this.exports.knots_worker_stack_free(this.wasmPointer(entry.stack));
        } catch {}
      }
    }
    this.workers.length = 0;
    this.idle.length = 0;
    this.tasks.clear();
    this.pending.length = 0;
    this.startingWorkers = 0;
  }

  destroy() {
    this.shutdown();
  }
}
