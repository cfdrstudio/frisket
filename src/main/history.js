'use strict';

/**
 * Local version history. Snapshots are plain Markdown files, so they can be
 * read without Frisket:
 *
 *   <library>/.frisket/history/<key>/<timestamp>.md   (notes in a library)
 *   <userData>/history/<key>/<timestamp>.md           (files opened on their own)
 *
 * `<key>` is the note's `frisket-id`, so history follows a library note through
 * renames, or a hash of its path for notes without one. `meta.json` beside the
 * snapshots records the latest path and title.
 *
 * No Electron imports: used by the main process and the index worker.
 */

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { splitFrontMatter, parseFrontMatter, noteTitle } = require('./workspace');
const { within } = require('./files');

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const MAX_SNAPSHOTS = 300;
const MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024;
// Minimum gap since the previous snapshot, per reason. Others always snapshot a change.
const MIN_GAP = { autosave: 5 * MINUTE, save: 30 * 1000 };
// `~NNN` marks a second snapshot in the same millisecond; `~` sorts after `.`, so name order is time order.
const SNAPSHOT_NAME = /^(\d{4}-\d{2}-\d{2}T\d{2})-(\d{2})-(\d{2})-(\d{3})Z(?:~\d{3})?\.md$/;

function stampFor(time) {
  return new Date(time).toISOString().replace(/:/g, '-').replace('.', '-');
}

function timeOf(name) {
  const match = SNAPSHOT_NAME.exec(name);
  return match ? Date.parse(match[1] + ':' + match[2] + ':' + match[3] + '.' + match[4] + 'Z') : NaN;
}

function propertiesOf(text) {
  return parseFrontMatter(splitFrontMatter(text).metaText).properties;
}

/** Where a file's snapshots live, or null when there is nowhere to keep them. */
function locate(file, text, { libraryRoot = null, fallbackRoot = null } = {}) {
  const inLibrary = !!(libraryRoot && within(libraryRoot, file));
  if (!inLibrary && !fallbackRoot) return null;
  const base = inLibrary ? path.join(libraryRoot, '.frisket', 'history') : path.join(fallbackRoot, 'history');
  const relative = inLibrary ? path.relative(libraryRoot, file) : path.resolve(file);
  const id = String(propertiesOf(text || '')['frisket-id'] || '').trim();
  const pathKey = (process.platform === 'win32' ? relative.toLowerCase() : relative).replace(/\\/g, '/');
  const key = /^[A-Za-z0-9._-]{1,80}$/.test(id)
    ? 'id-' + id
    : 'p-' + crypto.createHash('sha1').update(pathKey).digest('hex').slice(0, 20);
  return { dir: path.join(base, key), key, relative };
}

async function snapshotNames(dir) {
  let names;
  try { names = await fsp.readdir(dir); } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
  return names.filter((name) => SNAPSHOT_NAME.test(name)).sort();
}

/**
 * Thin old snapshots: keep everything from the last hour, then the newest per
 * 15 minutes (to a day), 2 hours (to a week), day (to 30 days), week (to a
 * year), 30 days beyond that, at most MAX_SNAPSHOTS in all.
 */
function snapshotsToKeep(names, now) {
  const keep = [];
  const buckets = new Set();
  for (const name of [...names].sort().reverse()) {
    const time = timeOf(name);
    const age = now - time;
    let size = 0;
    if (age >= HOUR) {
      if (age < DAY) size = 15 * MINUTE;
      else if (age < 7 * DAY) size = 2 * HOUR;
      else if (age < 30 * DAY) size = DAY;
      else if (age < 365 * DAY) size = 7 * DAY;
      else size = 30 * DAY;
      const bucket = size + ':' + Math.floor(time / size);
      if (buckets.has(bucket)) continue;
      buckets.add(bucket);
    }
    keep.push(name);
    if (keep.length >= MAX_SNAPSHOTS) break;
  }
  return new Set(keep);
}

async function prune(dir, now) {
  const names = await snapshotNames(dir);
  const keep = snapshotsToKeep(names, now);
  await Promise.all(names.filter((name) => !keep.has(name))
    .map((name) => fsp.rm(path.join(dir, name), { force: true })));
}

/**
 * Snapshot `text` as a version of `file`. `reason` is 'open', 'save',
 * 'autosave' or 'before-change'. Identical content is never stored twice, and
 * saves within MIN_GAP of the previous snapshot are skipped.
 */
async function record(file, text, { libraryRoot = null, fallbackRoot = null, reason = 'save', now = Date.now() } = {}) {
  const content = String(text ?? '');
  if (Buffer.byteLength(content, 'utf8') > MAX_SNAPSHOT_BYTES) return { skipped: 'too-large' };
  const location = locate(file, content, { libraryRoot, fallbackRoot });
  if (!location) return { skipped: 'no-location' };
  await fsp.mkdir(location.dir, { recursive: true });
  const names = await snapshotNames(location.dir);
  const last = names[names.length - 1];
  if (last) {
    let previous = null;
    try { previous = await fsp.readFile(path.join(location.dir, last), 'utf8'); } catch { /* unreadable: snapshot again */ }
    if (previous === content) return { skipped: 'unchanged' };
    const gap = MIN_GAP[reason] || 0;
    if (gap && now - timeOf(last) < gap) return { skipped: 'recent' };
  }
  let name = stampFor(now) + '.md';
  for (let n = 1; names.includes(name); n++) name = stampFor(now) + '~' + String(n).padStart(3, '0') + '.md';
  await fsp.writeFile(path.join(location.dir, name), content, { encoding: 'utf8', flag: 'wx' });
  const title = noteTitle(content, path.basename(file).replace(/\.[^.]+$/, ''), propertiesOf(content));
  await fsp.writeFile(path.join(location.dir, 'meta.json'),
    JSON.stringify({ path: location.relative.replace(/\\/g, '/'), title, updatedAt: new Date(now).toISOString() }, null, 2), 'utf8');
  await prune(location.dir, now);
  return { snapshot: name, key: location.key };
}

/** Snapshots of `file`, newest first, as `{ id, time, size }`. */
async function list(file, text, roots) {
  const location = locate(file, text, roots);
  if (!location) return [];
  const names = (await snapshotNames(location.dir)).reverse();
  return Promise.all(names.map(async (name) => {
    let size = 0;
    try { size = (await fsp.stat(path.join(location.dir, name))).size; } catch { /* removed meanwhile */ }
    return { id: name, time: new Date(timeOf(name)).toISOString(), size };
  }));
}

/** The text of one snapshot. `id` must be a snapshot name from `list`. */
async function read(file, text, id, roots) {
  if (!SNAPSHOT_NAME.test(String(id))) throw new Error('Unknown version.');
  const location = locate(file, text, roots);
  if (!location) throw new Error('This note has no history.');
  return fsp.readFile(path.join(location.dir, id), 'utf8');
}

module.exports = { record, list, read, locate, snapshotsToKeep, timeOf, stampFor };
