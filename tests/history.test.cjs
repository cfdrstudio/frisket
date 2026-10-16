'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const history = require('../src/main/history');

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'frisket-history-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

const MINUTE = 60 * 1000;
const T0 = Date.parse('2026-10-15T09:00:00.000Z');

test('snapshots skip identical text and respect the save gaps', async (t) => {
  const library = await fixture(t);
  const note = path.join(library, 'Notes', 'plan.md');
  const roots = { libraryRoot: library };
  assert.ok((await history.record(note, 'one', { ...roots, reason: 'open', now: T0 })).snapshot);
  assert.equal((await history.record(note, 'one', { ...roots, reason: 'save', now: T0 + MINUTE })).skipped, 'unchanged');
  assert.equal((await history.record(note, 'two', { ...roots, reason: 'save', now: T0 + 10000 })).skipped, 'recent');
  assert.ok((await history.record(note, 'two', { ...roots, reason: 'save', now: T0 + 31000 })).snapshot);
  assert.equal((await history.record(note, 'three', { ...roots, reason: 'autosave', now: T0 + 2 * MINUTE })).skipped, 'recent');
  assert.ok((await history.record(note, 'three', { ...roots, reason: 'before-change', now: T0 + 2 * MINUTE })).snapshot);

  const versions = await history.list(note, 'three', roots);
  assert.deepEqual(versions.map((version) => version.time), [
    new Date(T0 + 2 * MINUTE).toISOString(), new Date(T0 + 31000).toISOString(), new Date(T0).toISOString(),
  ]);
  assert.equal(await history.read(note, 'three', versions[2].id, roots), 'one');
  await assert.rejects(history.read(note, 'three', '../../secret.md', roots), /Unknown version/);
});

test('library notes are keyed by frisket-id, so history survives renames', async (t) => {
  const library = await fixture(t);
  const text = '---\nfrisket-id: note-123\n---\n# Plan\n';
  await history.record(path.join(library, 'a.md'), text, { libraryRoot: library, reason: 'open', now: T0 });
  const moved = path.join(library, 'Archive', 'renamed.md');
  const versions = await history.list(moved, text, { libraryRoot: library });
  assert.equal(versions.length, 1);
  const meta = JSON.parse(await fs.readFile(path.join(library, '.frisket', 'history', 'id-note-123', 'meta.json'), 'utf8'));
  assert.deepEqual({ path: meta.path, title: meta.title }, { path: 'a.md', title: 'Plan' });
});

test('files outside a library keep history in app data', async (t) => {
  const appData = await fixture(t);
  const loose = path.join(await fixture(t), 'loose.md');
  const result = await history.record(loose, 'text', { libraryRoot: null, fallbackRoot: appData, reason: 'open', now: T0 });
  assert.ok(result.snapshot);
  assert.ok(result.key.startsWith('p-'));
  assert.equal((await fs.readdir(path.join(appData, 'history', result.key))).filter((name) => name.endsWith('.md')).length, 1);
  assert.equal((await history.record(loose, 'text', { reason: 'open', now: T0 })).skipped, 'no-location');
});

test('old snapshots thin out with age', () => {
  const now = T0;
  const names = [];
  // Every 5 minutes for 3 days.
  for (let age = 0; age <= 3 * 24 * 60; age += 5) names.push(history.stampFor(now - age * MINUTE) + '.md');
  const keep = history.snapshotsToKeep(names, now);
  const ages = [...keep].map((name) => (now - history.timeOf(name)) / MINUTE);
  assert.equal(ages.filter((age) => age < 60).length, 12, 'everything from the last hour');
  const day = ages.filter((age) => age >= 60 && age < 24 * 60).length;
  assert.ok(day >= 90 && day <= 93, 'about one per 15 minutes for the rest of the day, got ' + day);
  const older = ages.filter((age) => age >= 24 * 60).length;
  assert.ok(older >= 24 && older <= 26, 'about one per 2 hours after that, got ' + older);
});
