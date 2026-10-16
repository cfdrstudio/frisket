'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  scanWorkspace, getBacklinks, filterNotes, getTags, inspectAttachments,
  summarizeNotes, filterLibraryNotes, searchLibrary,
} = require('../src/main/workspace');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'frisket-workspace-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

async function write(root, relative, content = '') {
  const full = path.join(root, relative);
  await fs.mkdir(path.dirname(full), { recursive: true });
  await fs.writeFile(full, content);
  return full;
}

test('indexes frontmatter, nested links, quick-open matches, and unlinked mentions', async (t) => {
  const root = await fixture(t);
  const target = await write(root, 'Research/Atlas.md', [
    '---',
    'title: "Atlas Notes"',
    'status: draft',
    'priority: 2',
    'tags: [maps, "field work"]',
    '---',
    '# Body title',
  ].join('\n'));
  const source = await write(root, 'Journal/Today.md', [
    '---',
    'tags:',
    '  - field work',
    '  - journal',
    '---',
    'Read [[../Research/Atlas|the atlas]] and [the report](../Research/Atlas.md#history).',
    'Atlas Notes still needs a review.',
    '`Atlas` appears inline as code.',
  ].join('\n'));
  const index = await scanWorkspace(root);
  assert.equal(index.truncated, false);
  assert.equal(index.notes.length, 2);
  const atlas = index.notes.find((note) => note.path === target);
  assert.equal(atlas.title, 'Atlas Notes');
  assert.deepEqual(atlas.tags, ['maps', 'field work']);
  assert.deepEqual(atlas.properties, { title: 'Atlas Notes', status: 'draft', priority: 2 });
  const today = index.notes.find((note) => note.path === source);
  assert.deepEqual(today.links, ['../Research/Atlas', '../Research/Atlas.md#history']);
  assert.equal(today.title, 'Today');

  const backlinks = getBacklinks(index, target);
  assert.equal(backlinks.linked.length, 2);
  assert.equal(backlinks.linked[0].pos > 0, true);
  assert.equal(backlinks.unlinked.length, 1);
  assert.match(backlinks.unlinked[0].excerpt, /Atlas Notes still needs/);
  assert.equal(filterNotes(index, 'atn')[0].path, target);
  assert.deepEqual(getTags(index), [
    { tag: 'field work', count: 2 },
    { tag: 'journal', count: 1 },
    { tag: 'maps', count: 1 },
  ]);
});

test('reports local attachments and missing references, ignoring remote images', async (t) => {
  const root = await fixture(t);
  await write(root, 'notes/images/diagram.png', 'png');
  const notePath = await write(root, 'notes/Plan.md', [
    '![diagram](images/diagram.png)',
    '![missing](images/absent.png)',
    '![remote](https://example.test/photo.png)',
  ].join('\n'));
  const index = await scanWorkspace(root);
  const result = await inspectAttachments(index, notePath);
  assert.equal(result.referenced.length, 1);
  assert.equal(result.referenced[0].reference, 'images/diagram.png');
  assert.equal(result.referenced[0].size, 3);
  assert.equal(result.missing.length, 1);
  assert.equal(result.missing[0].reference, 'images/absent.png');
});

test('enforces depth, count, and per-file byte bounds and skips hidden trees', async (t) => {
  const root = await fixture(t);
  await write(root, 'root.md', '# Root');
  await write(root, 'one/two/three/four/five/six/deep.md', '# Too deep');
  await write(root, 'large.md', '12345');
  await write(root, '.secret/hidden.md', '# Hidden');
  await write(root, '.git/config.md', '# Hidden');
  await write(root, 'a.md', '# A');
  await write(root, 'b.md', '# B');
  const index = await scanWorkspace(root, { maxDepth: 2, maxFiles: 2, maxFileBytes: 4 });
  assert.equal(index.notes.length, 2);
  assert.equal(index.notes.some((note) => note.name === 'deep.md'), false);
  assert.equal(index.notes.some((note) => note.name === 'hidden.md'), false);
  assert.equal(index.notes.some((note) => note.name === 'large.md'), false);
  assert.equal(index.truncated, true);
});

test('does not report an attachment that escapes the workspace', async (t) => {
  const root = await fixture(t);
  const notePath = await write(root, 'notes.md', '![escape](../secret.png)');
  const index = await scanWorkspace(root);
  const result = await inspectAttachments(index, notePath);
  assert.equal(result.referenced.length, 0);
  assert.equal(result.missing[0].reason, 'outside-workspace');
});

test('caps cumulative workspace text held in memory', async (t) => {
  const root = await fixture(t);
  await write(root, 'a.md', '# Alpha');
  await write(root, 'b.md', '# Beta');
  const index = await scanWorkspace(root, { maxTotalBytes: 8 });
  assert.equal(index.notes.length, 1);
  assert.equal(index.truncated, true);
});

test('unlinked mentions match whole words rather than title substrings', async (t) => {
  const root = await fixture(t);
  const target = await write(root, 'AI.md', '# AI');
  await write(root, 'Rain.md', 'The rain falls. AI matters.');
  const index = await scanWorkspace(root);
  const result = getBacklinks(index, target);
  assert.equal(result.unlinked.length, 1);
  assert.match(result.unlinked[0].excerpt, /AI matters/);
});

test('backlinks and attachment audit ignore code and resolve reference images', async (t) => {
  const root = await fixture(t);
  const target = await write(root, 'Target.md', '# Target');
  const source = await write(root, 'Source.md', [
    '```md', '[[Target]]', '![code](missing-code.png)', '```',
    '`[[Target]]` and `![inline](missing-inline.png)`',
    '![chart][fig]', '', '[fig]: assets/chart.png',
  ].join('\n'));
  const index = await scanWorkspace(root);
  assert.equal(getBacklinks(index, target).linked.length, 0);
  assert.equal(getBacklinks(index, target).unlinked.length, 0);
  const attachments = await inspectAttachments(index, source);
  assert.deepEqual(attachments.missing.map((item) => item.reference), ['assets/chart.png']);
});

test('frontmatter list properties appear in the index', async (t) => {
  const root = await fixture(t);
  await write(root, 'Lists.md', '---\naliases:\n  - Alpha\n  - Beta\npeople: [Ada, Bob]\n---\n# Lists');
  const index = await scanWorkspace(root);
  assert.deepEqual(index.notes[0].properties.aliases, ['Alpha', 'Beta']);
  assert.deepEqual(index.notes[0].properties.people, ['Ada', 'Bob']);
});

test('indexes prose tags while excluding headings, code, escaped hashes, URLs, and HTML', async (t) => {
  const root = await fixture(t);
  await write(root, 'Tags.md', [
    '# Heading #not-a-tag',
    'Use #work/projects# with #Ideas; escaped \\#hidden.',
    'URL https://example.test/#web-tag and www.example.test/#web-too',
    '<span data-tag="#html-attribute">visible text</span>',
    '`#inline-code`',
    '```md',
    '#fenced-code',
    '```',
  ].join('\n'));
  const index = await scanWorkspace(root);
  assert.deepEqual(index.notes[0].tags, ['work/projects', 'Ideas']);
  assert.deepEqual(getTags(index), [
    { tag: 'Ideas', count: 1 },
    { tag: 'work', count: 1 },
    { tag: 'work/projects', count: 1 },
  ]);
});

test('builds portable summaries and applies tag, todo, trash, and search filters', async (t) => {
  const root = await fixture(t);
  await write(root, 'Library/Plan.md', [
    '---',
    'frisket-id: plan-uuid',
    'frisket-created: 2024-01-02T03:04:05.000Z',
    'frisket-cover: media/cover.webp',
    'tags: [work]',
    '---',
    '# Plan title',
    'A useful project target #work/projects# with detail.',
    '- [ ] unfinished task',
    '- [x] finished task',
    '![inline image](media/image.png)',
    '[reference PDF](files/brief.pdf)',
  ].join('\n'));
  await write(root, 'Loose.md', 'A note without tags.');
  await write(root, 'Trash.md', [
    '---',
    'frisket-trashed-at: 2025-03-04T00:00:00Z',
    '---',
    'A trashed note.',
  ].join('\n'));

  const index = await scanWorkspace(root);
  const summaries = summarizeNotes(index);
  const plan = summaries.find((note) => note.title === 'Plan title');
  assert.equal(plan.id, 'plan-uuid');
  assert.equal(plan.createdAt, '2024-01-02T03:04:05.000Z');
  assert.equal(plan.modifiedAt, new Date(index.notes.find((note) => note.title === 'Plan title').mtime).toISOString());
  assert.equal(plan.imagePreview, 'media/cover.webp');
  assert.deepEqual(plan.tags, ['work', 'work/projects']);
  assert.equal(plan.tasksDone, 1);
  assert.equal(plan.tasksTotal, 2);
  assert.equal(plan.hasImages, true);
  assert.equal(plan.hasAttachments, true);
  assert.match(plan.excerpt, /useful project target/);

  assert.equal(summaries.find((note) => note.title === 'Loose').id.startsWith('legacy-'), true);
  assert.deepEqual(filterLibraryNotes(index, 'untagged').map((note) => note.title), ['Loose']);
  assert.deepEqual(filterLibraryNotes(index, 'todo').map((note) => note.title), ['Plan title']);
  assert.deepEqual(filterLibraryNotes(index, 'trash').map((note) => note.title), ['Trash']);
  assert.deepEqual(filterLibraryNotes(index, { type: 'tag', tag: 'WORK' }).map((note) => note.title), ['Plan title']);
  assert.deepEqual(searchLibrary(index, '@todo @images #work target').map((note) => note.title), ['Plan title']);
  assert.deepEqual(searchLibrary(index, '#work/projects#').map((note) => note.title), ['Plan title']);
  assert.deepEqual(searchLibrary(index, '@images').map((note) => note.title), ['Plan title']);
});
