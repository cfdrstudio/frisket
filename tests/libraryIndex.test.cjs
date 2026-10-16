'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { scanWorkspace, createLinkResolver, rewriteWikiLinks, getBacklinks } = require('../src/main/workspace');
const { LibraryIndex, IndexHost, ignoredChange } = require('../src/main/libraryIndex');
const { IndexService } = require('../src/main/indexService');

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'frisket-index-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

async function write(root, relative, content = '', mtime = null) {
  const full = path.join(root, relative);
  await fs.mkdir(path.dirname(full), { recursive: true });
  await fs.writeFile(full, content);
  if (mtime) await fs.utimes(full, mtime, mtime);
  return full;
}

function waitFor(check, timeout = 8000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      const value = check();
      if (value) resolve(value);
      else if (Date.now() - started > timeout) reject(new Error('timed out'));
      else setTimeout(tick, 50);
    };
    tick();
  });
}

test('links resolve by path, id, file name, title and alias, in that order', async (t) => {
  const root = await fixture(t);
  const plan = await write(root, 'Notes/2026-10-14-untitled.md', '---\nfrisket-id: plan-id\naliases: [Roadmap]\n---\n\n# Project Plan\n');
  const named = await write(root, 'Projects/Plan.md', '# Something else\n');
  const daily = await write(root, 'Journal/daily.md', '# Daily\n');
  const index = await scanWorkspace(root);
  const { resolve } = createLinkResolver(index.notes, root);

  assert.equal(resolve(daily, 'Project Plan').note.path, plan, 'title');
  assert.equal(resolve(daily, 'project   plan#Goals').note.path, plan, 'title is case- and space-insensitive');
  assert.equal(resolve(daily, 'project plan#Goals').anchor, 'Goals');
  assert.equal(resolve(daily, 'plan-id').note.path, plan, 'frisket-id');
  assert.equal(resolve(daily, 'Roadmap').note.path, plan, 'alias');
  assert.equal(resolve(daily, 'Plan').note.path, named, 'file name wins over a title tier');
  assert.equal(resolve(daily, '../Projects/Plan.md').note.path, named, 'relative path');
  assert.equal(resolve(daily, 'Projects/Plan').note.path, named, 'root-relative path');
  assert.equal(resolve(daily, 'Elsewhere/Plan').missing, true, 'a path suffix must match');
  assert.equal(resolve(daily, '#Heading').anchorOnly, true);
  assert.equal(resolve(daily, 'https://example.test').external, true);
});

test('duplicate titles are ambiguous, and trashed notes are reported separately', async (t) => {
  const root = await fixture(t);
  const first = await write(root, 'a/one.md', '# Meeting\n');
  const second = await write(root, 'b/two.md', '# Meeting\n');
  await write(root, 'gone.md', '---\nfrisket-trashed-at: 2026-01-01T00:00:00Z\n---\n# Archived idea\n');
  const index = await scanWorkspace(root);
  const resolver = createLinkResolver(index.notes, root);

  const ambiguous = resolver.resolve(null, 'Meeting');
  assert.deepEqual(ambiguous.ambiguous.map((note) => note.path).sort(), [first, second].sort());
  const trashed = resolver.resolve(null, 'Archived idea');
  assert.equal(trashed.missing, true);
  assert.equal(trashed.trashed.title, 'Archived idea');

  const one = index.notes.find((note) => note.path === first);
  assert.equal(resolver.linkTextFor(one), 'one', 'falls back to the unique file name');
});

test('backlinks follow title links to library notes and flag ambiguity (B2)', async (t) => {
  const root = await fixture(t);
  const plan = await write(root, 'Notes/2026-10-14-untitled.md', '---\nfrisket-id: abc\n---\n\n# Project Plan\n');
  await write(root, 'Notes/daily.md', '# Daily\n\nSee [[Project Plan]] for details.\n');
  const meeting = await write(root, 'a/one.md', '# Meeting\n');
  await write(root, 'b/two.md', '# Meeting\n');
  await write(root, 'c/log.md', 'From the [[Meeting]].\n');
  const index = await scanWorkspace(root);

  const backlinks = getBacklinks(index, plan);
  assert.equal(backlinks.linked.length, 1);
  assert.match(backlinks.linked[0].excerpt, /See \[\[Project Plan\]\]/);
  const ambiguous = getBacklinks(index, meeting).linked;
  assert.equal(ambiguous.length, 1);
  assert.equal(ambiguous[0].ambiguous, true);
});

test('rewriteWikiLinks keeps anchors and aliases and skips code', () => {
  const source = [
    'See [[Old Title]], [[old title#Goals|the plan]] and [[Other]].',
    '`[[Old Title]]` stays.',
    '```',
    '[[Old Title]]',
    '```',
  ].join('\n');
  const result = rewriteWikiLinks(source, (name) => name.toLowerCase() === 'old title', 'New Title');
  assert.equal(result.count, 2);
  assert.match(result.text, /See \[\[New Title\]\], \[\[New Title#Goals\|the plan\]\] and \[\[Other\]\]\./);
  assert.match(result.text, /`\[\[Old Title\]\]` stays\./);
  assert.match(result.text, /```\n\[\[Old Title\]\]\n```/);
  const aliased = rewriteWikiLinks('[[Old Title]]', () => true, 'notes/new', 'New Title');
  assert.equal(aliased.text, '[[notes/new|New Title]]');
});

test('refresh re-reads only changed files and tracks additions, deletions and trash', async (t) => {
  const root = await fixture(t);
  const past = new Date(Date.now() - 60000);
  const a = await write(root, 'a.md', '# A\n', past);
  const b = await write(root, 'b.md', '# B\n', past);
  const index = new LibraryIndex(root);
  t.after(() => index.close());
  await index.refresh();
  const recordB = [...index.records.values()].find((note) => note.path === b);
  const version = index.version;

  await write(root, 'a.md', '# A changed\n');
  await write(root, 'c.md', '# C\n');
  assert.equal(await index.refresh(), true);
  assert.equal(index.version, version + 1);
  assert.equal([...index.records.values()].find((note) => note.path === b), recordB, 'unchanged file kept its record');
  const titles = () => index.derived().notes.map((note) => note.title).sort();
  assert.deepEqual(titles(), ['A changed', 'B', 'C']);
  assert.equal(await index.refresh(), false, 'nothing changed');

  await fs.rm(a);
  await fs.mkdir(path.join(root, '.frisket', 'Trash'), { recursive: true });
  await fs.rename(b, path.join(root, '.frisket', 'Trash', 'b.md'));
  await index.refresh();
  const overview = await index.overview(null);
  assert.deepEqual(overview.notes.map((note) => [note.title, !!note.trashedAt]).sort(), [['B', true], ['C', false]]);
  assert.deepEqual(overview.tags, []);
});

test('the overview reports a truncated index', async (t) => {
  const root = await fixture(t);
  for (const name of ['a', 'b', 'c']) await write(root, name + '.md', '# ' + name);
  const index = new LibraryIndex(root, { maxFiles: 2 });
  const overview = await index.overview(null);
  assert.equal(overview.truncated, true);
  assert.equal(overview.notes.length, 2);
  assert.equal(overview.limits.maxFiles, 2);
});

test('a title change offers to update links that used the old title', async (t) => {
  const root = await fixture(t);
  const past = new Date(Date.now() - 60000);
  const plan = await write(root, 'Notes/2026-10-14-untitled.md', '---\nfrisket-id: abc\n---\n\n# Project Plan\n', past);
  const daily = await write(root, 'Notes/daily.md', 'See [[Project Plan#Goals|the plan]] and [[Project Plan]].\n', past);
  await write(root, 'Notes/other.md', 'Unrelated [[Elsewhere]].\n', past);
  const index = new LibraryIndex(root);
  t.after(() => index.close());
  await index.refresh();

  await write(root, 'Notes/2026-10-14-untitled.md', '---\nfrisket-id: abc\n---\n\n# Road\n');
  await index.refresh();
  await write(root, 'Notes/2026-10-14-untitled.md', '---\nfrisket-id: abc\n---\n\n# Roadmap\n');
  const change = await index.titleChange(plan, { refresh: true });
  assert.deepEqual({ from: change.from, to: change.to, links: change.links, files: change.files },
    { from: 'Project Plan', to: 'Roadmap', links: 2, files: [daily] });

  const result = await index.updateTitleLinks(plan);
  assert.deepEqual(result, { links: 2, files: 1, skipped: [] });
  assert.equal(await fs.readFile(daily, 'utf8'), 'See [[Roadmap#Goals|the plan]] and [[Roadmap]].\n');
  assert.equal(await index.titleChange(plan), null);
  const overview = await index.overview(plan);
  assert.equal(overview.backlinks.linked.length, 2);
});

test('changing a title back clears the pending change', async (t) => {
  const root = await fixture(t);
  const past = new Date(Date.now() - 60000);
  const plan = await write(root, 'plan.md', '# Alpha\n', past);
  await write(root, 'ref.md', '[[Alpha]]\n', past);
  const index = new LibraryIndex(root);
  t.after(() => index.close());
  await index.refresh();
  await write(root, 'plan.md', '# Beta\n');
  assert.equal((await index.titleChange(plan, { refresh: true })).links, 1);
  await write(root, 'plan.md', '# Alpha\n', new Date());
  assert.equal(await index.titleChange(plan, { refresh: true }), null);
});

test('backlinks for 2,000 linked notes take well under the old 20 s (B1)', async (t) => {
  const root = await fixture(t);
  const count = 2000;
  await Promise.all(Array.from({ length: count }, (_, i) => {
    const links = Array.from({ length: 5 }, (_unused, k) => '[[note-' + ((i * 7 + k * 13) % count) + ']]').join(' ');
    return write(root, 'note-' + i + '.md', '# Note ' + i + '\n\n#work/p' + (i % 20) + ' Prose about note ' + i + '. ' + links + '\n- [ ] task\n');
  }));
  const index = new LibraryIndex(root);
  t.after(() => index.close());
  await index.refresh();
  const started = Date.now();
  const overview = await index.overview(path.join(root, 'note-0.md'));
  const elapsed = Date.now() - started;
  assert.equal(overview.notes.length, count);
  assert.ok(overview.backlinks.linked.length > 0);
  assert.ok(elapsed < 3000, 'overview with backlinks took ' + elapsed + ' ms');
});

test('watcher events ignore hidden and dependency paths but not the library trash', () => {
  assert.equal(ignoredChange('.git/index'), true);
  assert.equal(ignoredChange('notes/.a.md.123.tmp'), true);
  assert.equal(ignoredChange('node_modules/x/readme.md'), true);
  assert.equal(ignoredChange('.frisket/history/x.md'), true);
  assert.equal(ignoredChange('.frisket/Trash/x.md'), false);
  assert.equal(ignoredChange('Notes/plan.md'), false);
});

test('the host evicts the least recently used library', async (t) => {
  const one = await fixture(t);
  const two = await fixture(t);
  const host = new IndexHost({ maxIndexes: 1, watch: false });
  t.after(() => host.close());
  await host.handle('overview', one, [null]);
  await host.handle('overview', two, [null]);
  assert.equal(host.indexes.size, 1);
  await assert.rejects(host.handle('constructor', one, []), /Unsupported/);
});

test('the worker answers requests and reports changes on disk', async (t) => {
  const root = await fixture(t);
  await write(root, 'first.md', '# First\n');
  const changes = [];
  const service = new IndexService({ onChanged: (folder) => changes.push(folder) });
  t.after(() => service.close());
  const overview = await service.call(root, 'overview', null, { refresh: true });
  assert.equal(service.mode, 'worker');
  assert.deepEqual(overview.notes.map((note) => note.title), ['First']);

  await write(root, 'second.md', '# Second\n');
  await waitFor(() => changes.length);
  const after = await service.call(root, 'overview', null);
  assert.deepEqual(after.notes.map((note) => note.title).sort(), ['First', 'Second']);
});

test('the service falls back to in-process indexing when the worker cannot load', async (t) => {
  const root = await fixture(t);
  await write(root, 'only.md', '# Only\n');
  let failure = null;
  const service = new IndexService({ workerPath: path.join(root, 'missing-worker.js'), onFallback: (err) => { failure = err; } });
  t.after(() => service.close());
  const overview = await service.call(root, 'overview', null);
  assert.deepEqual(overview.notes.map((note) => note.title), ['Only']);
  assert.equal(service.mode, 'in-process');
  assert.ok(failure);
});
