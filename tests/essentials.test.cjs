'use strict';

// Library features as seen by the index: front-matter
// edits, pins, search hits, linking mentions, per-note context and conflicts.

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { setFrontMatterValue, findSearchMatch, parseSearchQuery } = require('../src/main/workspace');
const { LibraryIndex, conflictCopyOf } = require('../src/main/libraryIndex');
const history = require('../src/main/history');

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'frisket-essentials-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

async function write(root, relative, content, mtime = null) {
  const full = path.join(root, relative);
  await fs.mkdir(path.dirname(full), { recursive: true });
  await fs.writeFile(full, content);
  if (mtime) await fs.utimes(full, mtime, mtime);
  return full;
}

async function openIndex(t, root) {
  const index = new LibraryIndex(root);
  t.after(() => index.close());
  await index.refresh();
  return index;
}

test('setFrontMatterValue adds, replaces and removes keys without touching the rest', () => {
  assert.equal(setFrontMatterValue('# Body\n', 'frisket-pinned', 'true'), '---\nfrisket-pinned: true\n---\n\n# Body\n');
  assert.equal(setFrontMatterValue('---\nfrisket-pinned: true\n---\n\n# Body\n', 'frisket-pinned', null), '# Body\n');
  const text = '---\r\ntitle: Plan\r\ntags:\r\n  - a\r\nfrisket-pinned: false\r\n---\r\nBody\r\n';
  assert.equal(setFrontMatterValue(text, 'frisket-pinned', 'true'), '---\r\ntitle: Plan\r\ntags:\r\n  - a\r\nfrisket-pinned: true\r\n---\r\nBody\r\n');
  assert.equal(setFrontMatterValue(text, 'tags', null), '---\r\ntitle: Plan\r\nfrisket-pinned: false\r\n---\r\nBody\r\n');
  assert.equal(setFrontMatterValue('# No front matter\n', 'x', null), '# No front matter\n');
});

test('search hits report the matching line, task, tag or image', () => {
  const text = '---\nfrisket-id: a\n---\n# Title\n\nIntro line.\n- [x] done\n- [ ] open task\nTagged #work/plan here.\n![img](a.png)\n';
  const at = (query) => findSearchMatch(text, parseSearchQuery(query));
  assert.deepEqual([at('intro').line, at('intro').text, at('intro').column], [6, 'Intro line.', 0]);
  assert.equal(text.slice(at('intro').pos, at('intro').pos + 5), 'Intro');
  assert.equal(at('@todo').line, 8);
  assert.equal(at('#work').line, 9);
  assert.equal(at('@images').line, 10);
  assert.equal(at('').line, 4, 'no operator: the first body line');
});

test('pinning writes front matter and sorts nothing else', async (t) => {
  const root = await fixture(t);
  const plan = await write(root, 'plan.md', '# Plan\n\nBody\n');
  const index = await openIndex(t, root);
  await index.setPinned(plan, true);
  assert.equal(await fs.readFile(plan, 'utf8'), '---\nfrisket-pinned: true\n---\n\n# Plan\n\nBody\n');
  assert.equal((await index.overview()).notes[0].pinned, true);
  await index.setPinned(plan, false);
  assert.equal(await fs.readFile(plan, 'utf8'), '# Plan\n\nBody\n');
  // Both rewrites were snapshotted first.
  assert.equal((await history.list(plan, '# Plan\n', { libraryRoot: root })).length, 2);
});

test('search returns matches, skipping trash unless asked', async (t) => {
  const root = await fixture(t);
  await write(root, 'a.md', '# Alpha\n\nThe quick fox.\n');
  await write(root, 'b.md', '---\nfrisket-trashed-at: 2026-01-01T00:00:00Z\n---\n# Beta\n\nAnother fox.\n');
  const index = await openIndex(t, root);
  const found = await index.search('fox');
  assert.deepEqual(found.notes.map((note) => [note.title, note.match.line, note.match.text]), [['Alpha', 3, 'The quick fox.']]);
  assert.deepEqual(found.terms, ['fox']);
  assert.equal((await index.search('fox', { includeTrashed: true })).notes.length, 2);
});

test('the context operation returns backlinks; linkMention turns a mention into a link', async (t) => {
  const root = await fixture(t);
  const target = await write(root, 'Notes/2026-10-14-plan.md', '---\nfrisket-id: p\n---\n# Project Plan\n');
  const source = await write(root, 'Notes/daily.md', 'Talked about the Project Plan today.\nAlso [[Project Plan]].\n');
  const index = await openIndex(t, root);
  const context = await index.context(target);
  assert.equal(context.found, true);
  assert.equal(context.backlinks.linked.length, 1);
  assert.equal(context.backlinks.unlinked.length, 1);
  const mention = context.backlinks.unlinked[0];
  await assert.rejects(index.linkMention(source, mention.pos, mention.length, 'Something else', target), /changed/);
  await index.linkMention(source, mention.pos, mention.length, mention.text, target);
  assert.equal(await fs.readFile(source, 'utf8'), 'Talked about the [[Project Plan]] today.\nAlso [[Project Plan]].\n');
  const after = await index.context(target);
  assert.deepEqual([after.backlinks.linked.length, after.backlinks.unlinked.length], [2, 0]);
  assert.equal((await index.context(path.join(root, 'missing.md'))).found, false);
});

test('conflict copies are recognised by name and by duplicate frisket-id', () => {
  assert.deepEqual(conflictCopyOf("Plan (Sam's conflicted copy 2026-10-15)", 'host'), { kind: 'conflicted-copy', base: 'Plan' });
  assert.deepEqual(conflictCopyOf('Plan (conflicted copy 2026-10-15 101010)', 'host'), { kind: 'conflicted-copy', base: 'Plan' });
  assert.deepEqual(conflictCopyOf('Plan.sync-conflict-20261015-101010-ABCDEFG', 'host'), { kind: 'syncthing', base: 'Plan' });
  assert.deepEqual(conflictCopyOf('Plan-DESKTOP-4F2K9QZ', 'host'), { kind: 'onedrive', base: 'Plan' });
  assert.deepEqual(conflictCopyOf('Plan-studio-mac', 'Studio-Mac.local'), { kind: 'onedrive', base: 'Plan' });
  assert.equal(conflictCopyOf('topic-pc', 'pc'), null, 'short device names are not matched');
  assert.equal(conflictCopyOf('Plan', 'host'), null);
});

test('conflicts leave the normal views and resolve without silent overwrites', async (t) => {
  const root = await fixture(t);
  const past = new Date(Date.now() - 60000);
  const plan = await write(root, 'Plan.md', '---\nfrisket-id: plan\n---\n# Plan\n\nOriginal line.\n', past);
  const planCopy = await write(root, "Plan (Sam's conflicted copy 2026-10-15).md", '---\nfrisket-id: plan\n---\n# Plan\n\nEdited elsewhere.\n', past);
  const orphan = await write(root, 'Old.sync-conflict-20261015-101010-ABCDEFG.md', '# Old\n', past);
  const idea = await write(root, 'Idea.md', '---\nfrisket-id: idea\n---\n# Idea\n#tagged\n', past);
  const ideaCopy = await write(root, 'Idea 2.md', '---\nfrisket-id: idea\n---\n# Idea\n#tagged\n', past);
  await write(root, 'links.md', 'See [[Plan]] and [[Idea]].\n', past);
  const index = await openIndex(t, root);

  const overview = await index.overview();
  assert.equal(overview.conflicts, 3);
  const byName = Object.fromEntries(overview.notes.map((note) => [note.name, note.conflict]));
  assert.deepEqual(byName["Plan (Sam's conflicted copy 2026-10-15).md"], { kind: 'conflicted-copy', original: plan });
  assert.deepEqual(byName['Old.sync-conflict-20261015-101010-ABCDEFG.md'], { kind: 'syncthing', original: null });
  assert.deepEqual(byName['Idea 2.md'], { kind: 'duplicate-id', original: idea });
  assert.equal(byName['Idea.md'], null);
  assert.deepEqual(overview.tags, [{ tag: 'tagged', count: 1 }], 'copies do not double tag counts');
  assert.equal((await index.resolveLink('Plan', path.join(root, 'links.md'))).path, plan, 'copies do not make links ambiguous');

  // Keep this copy: the original takes the copy's text (and is snapshotted), the copy goes to Trash.
  await index.resolveConflict(planCopy, 'keep-copy');
  assert.match(await fs.readFile(plan, 'utf8'), /Edited elsewhere\./);
  assert.match(await fs.readFile(planCopy, 'utf8'), /frisket-trashed-at: /);
  const versions = await history.list(plan, await fs.readFile(plan, 'utf8'), { libraryRoot: root });
  assert.equal(await history.read(plan, '---\nfrisket-id: plan\n---\n', versions[versions.length - 1].id, { libraryRoot: root }),
    '---\nfrisket-id: plan\n---\n# Plan\n\nOriginal line.\n');

  // Keep both: a duplicate gets a new frisket-id; a named copy is renamed.
  await index.resolveConflict(ideaCopy, 'keep-both');
  assert.doesNotMatch(await fs.readFile(ideaCopy, 'utf8'), /frisket-id: idea\n/);
  const kept = await index.resolveConflict(orphan, 'keep-both');
  assert.equal(path.basename(kept.path), 'Old (copy).md');
  await assert.rejects(fs.access(orphan));
  assert.equal((await index.overview()).conflicts, 0);
  await assert.rejects(index.resolveConflict(plan, 'keep-original'), /no longer a conflict copy/);
});
