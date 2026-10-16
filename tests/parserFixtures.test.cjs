'use strict';

// The note parser contract in fixtures/parser-cases.json, checked against src/main/workspace.js.

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { scanWorkspace, summarizeNotes, isTrashed } = require('../src/main/workspace');

const { cases } = require('../fixtures/parser-cases.json');
const tagSet = (tags) => tags.map((tag) => tag.normalize('NFC').toLowerCase()).sort();

for (const fixture of cases) {
  test('parser fixture: ' + fixture.name, async (t) => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'frisket-fixture-'));
    t.after(() => fs.rm(root, { recursive: true, force: true }));
    await fs.writeFile(path.join(root, fixture.fileName || 'note.md'), fixture.markdown);
    const index = await scanWorkspace(root);
    const [note] = index.notes;
    const [summary] = summarizeNotes(index);
    const { expect } = fixture;
    assert.equal(note.title, expect.title);
    assert.deepEqual(tagSet(summary.tags), tagSet(expect.tags));
    assert.equal(summary.tags.length, expect.tags.length, 'no case-variant duplicates');
    assert.equal(summary.tasksDone, expect.tasksDone);
    assert.equal(summary.tasksTotal, expect.tasksTotal);
    assert.equal(summary.hasImages, expect.hasImages);
    assert.equal(isTrashed(note), expect.trashed);
    assert.equal(summary.pinned, expect.pinned);
  });
}
