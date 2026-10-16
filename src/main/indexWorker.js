'use strict';

/**
 * Worker-thread host for the library index, so scanning, parsing and link
 * resolution never block the Electron main process. Protocol:
 *   in:  { id, op, folder, args }
 *   out: { id, ok: true, result } | { id, ok: false, error } | { type: 'changed', folder }
 */

const { parentPort } = require('node:worker_threads');
const { IndexHost } = require('./libraryIndex');

const host = new IndexHost({
  onChanged: (folder) => parentPort.postMessage({ type: 'changed', folder }),
});

parentPort.on('message', async ({ id, op, folder, args }) => {
  try {
    const result = await host.handle(op, folder, args);
    parentPort.postMessage({ id, ok: true, result });
  } catch (err) {
    parentPort.postMessage({ id, ok: false, error: err && err.message ? err.message : String(err) });
  }
});
