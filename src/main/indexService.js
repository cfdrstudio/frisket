'use strict';

/**
 * Main-process client for the library index. Requests go to a worker thread
 * (indexWorker.js). If the worker cannot start or dies, the service switches
 * to an in-process IndexHost and replays whatever was pending, so a packaging
 * or runtime problem degrades responsiveness rather than breaking the library.
 *
 * No Electron imports, so it can be exercised from `node --test`.
 */

const path = require('node:path');
const { Worker } = require('node:worker_threads');
const { IndexHost } = require('./libraryIndex');

/** Inside a packaged app the worker must load from app.asar.unpacked. */
function defaultWorkerPath() {
  return path.join(__dirname, 'indexWorker.js').replace(/app\.asar([\\/])/, 'app.asar.unpacked$1');
}

class IndexService {
  constructor({ onChanged = () => {}, onFallback = () => {}, workerPath = defaultWorkerPath(), useWorker = true } = {}) {
    this.onChanged = onChanged;
    this.onFallback = onFallback;
    this.workerPath = workerPath;
    this.useWorker = useWorker;
    this.worker = null;
    this.local = null;
    this.pending = new Map();
    this.sequence = 0;
    this.closing = false;
  }

  get mode() {
    return this.local ? 'in-process' : (this.worker ? 'worker' : 'idle');
  }

  call(folder, op, ...args) {
    if (this.closing) return Promise.reject(new Error('The library index is shutting down.'));
    if (!this.local && this.useWorker) this.startWorker();
    if (this.local || !this.worker) return this.localHost().handle(op, folder, args);
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      this.pending.set(id, { resolve, reject, op, folder, args });
      this.worker.postMessage({ id, op, folder, args });
    });
  }

  localHost() {
    if (!this.local) this.local = new IndexHost({ onChanged: (folder) => this.onChanged(folder) });
    return this.local;
  }

  startWorker() {
    if (this.worker) return;
    try {
      this.worker = new Worker(this.workerPath);
    } catch (err) {
      this.fallback(err);
      return;
    }
    this.worker.on('message', (message) => {
      if (message && message.type === 'changed') { this.onChanged(message.folder); return; }
      const request = this.pending.get(message.id);
      if (!request) return;
      this.pending.delete(message.id);
      if (message.ok) request.resolve(message.result);
      else request.reject(new Error(message.error));
    });
    this.worker.on('error', (err) => this.fallback(err));
    this.worker.on('exit', (code) => {
      if (!this.closing) this.fallback(new Error('The library index worker exited with code ' + code + '.'));
    });
  }

  /** Switch to in-process indexing and replay requests the worker never answered. */
  fallback(err) {
    if (this.local) return;
    const worker = this.worker;
    this.worker = null;
    const host = this.localHost();
    this.onFallback(err);
    if (worker) worker.terminate().catch(() => {});
    const waiting = [...this.pending.values()];
    this.pending.clear();
    for (const request of waiting) {
      host.handle(request.op, request.folder, request.args).then(request.resolve, request.reject);
    }
  }

  async close() {
    this.closing = true;
    const worker = this.worker;
    this.worker = null;
    for (const request of this.pending.values()) request.reject(new Error('The library index was closed.'));
    this.pending.clear();
    if (worker) await worker.terminate();
    if (this.local) this.local.close();
  }
}

module.exports = { IndexService, defaultWorkerPath };
