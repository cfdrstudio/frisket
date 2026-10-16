import assert from 'node:assert/strict';
import test from 'node:test';
import {
  wikiLinkContext, tagContext, noteCompletions, tagCompletions, wikiInsertion, matchScore,
} from '../src/renderer/editor/completions.mjs';

const notes = [
  { title: 'Project Plan', linkText: 'Project Plan', name: '2026-10-14-untitled.md', relative: 'Notes/2026-10-14-untitled.md', path: '/l/Notes/2026-10-14-untitled.md', aliases: ['Roadmap'], modifiedAt: '2026-10-10T00:00:00Z' },
  { title: 'Meeting', linkText: 'one', name: 'one.md', relative: 'a/one.md', path: '/l/a/one.md', aliases: [], modifiedAt: '2026-10-12T00:00:00Z' },
  { title: 'Meeting', linkText: 'two', name: 'two.md', relative: 'b/two.md', path: '/l/b/two.md', aliases: [], modifiedAt: '2026-10-11T00:00:00Z' },
  { title: 'Gone', linkText: null, name: 'gone.md', relative: 'gone.md', path: '/l/gone.md', trashedAt: '2026-01-01T00:00:00Z' },
];

test('detects the [[ and # contexts before the caret', () => {
  assert.deepEqual(wikiLinkContext('See [[Proj'), { query: 'Proj', start: 6 });
  assert.deepEqual(wikiLinkContext('See [['), { query: '', start: 6 });
  assert.equal(wikiLinkContext('See [[Done]] then'), null);
  assert.equal(wikiLinkContext('See [[Note|ali'), null, 'typing an alias is not a note query');
  assert.deepEqual(tagContext('Filed under #wo'), { query: 'wo', start: 13 });
  assert.deepEqual(tagContext('#work/pro'), { query: 'work/pro', start: 1 });
  assert.equal(tagContext('Filed under #'), null, 'needs a character first');
  assert.equal(tagContext('## Heading #wo'), null, 'headings do not hold tags');
  assert.equal(tagContext('https://x.test/#frag'), null);
  assert.equal(tagContext('C#'), null);
  assert.equal(tagContext('&#12'), null);
});

test('ranks notes by title, alias and file name, skipping trashed notes', () => {
  const byTitle = noteCompletions(notes, 'proj');
  assert.equal(byTitle[0].label, 'Project Plan');
  assert.equal(byTitle[0].insert, 'Project Plan');
  assert.equal(byTitle[0].alias, null);

  const byAlias = noteCompletions(notes, 'road');
  assert.equal(byAlias[0].label, 'Roadmap');
  assert.equal(byAlias[0].insert, 'Project Plan');
  assert.equal(byAlias[0].alias, 'Roadmap');

  const duplicates = noteCompletions(notes, 'meeting');
  assert.deepEqual(duplicates.map((item) => [item.insert, item.alias, item.detail]), [
    ['one', 'Meeting', 'a'],
    ['two', 'Meeting', 'b'],
  ], 'duplicate titles insert their unique link text, newest first');

  assert.equal(noteCompletions(notes, '').some((item) => item.path === '/l/gone.md'), false);
  assert.equal(noteCompletions(notes, 'zzz').length, 0);
  assert.ok(matchScore('Project Plan', 'plan') > matchScore('Explanation', 'plan'), 'word start beats mid-word');
});

test('offers existing tags by prefix, then segment, without the exact match', () => {
  const tags = [{ tag: 'work', count: 9 }, { tag: 'work/projects', count: 3 }, { tag: 'homework', count: 1 }, { tag: 'ideas', count: 4 }];
  assert.deepEqual(tagCompletions(tags, 'work').map((item) => item.insert), ['work/projects', 'homework']);
  assert.deepEqual(tagCompletions(tags, 'pro').map((item) => item.insert), ['work/projects']);
  assert.deepEqual(tagCompletions(tags, 'i').map((item) => item.insert), ['ideas']);
  assert.deepEqual(tagCompletions(tags, 'o').map((item) => item.insert), ['work', 'work/projects', 'homework'], 'then by usage');
});

test('inserting a link reuses typed closing brackets and keeps aliases and anchors', () => {
  const plain = { insert: 'Project Plan', alias: null };
  const aliased = { insert: 'one', alias: 'Meeting' };
  assert.deepEqual(wikiInsertion(plain, ']] and more'), { text: 'Project Plan', replace: 0, cursor: 14 });
  assert.deepEqual(wikiInsertion(aliased, ']]'), { text: 'one|Meeting', replace: 0, cursor: 13 });
  assert.deepEqual(wikiInsertion(plain, 'ect old]] tail'), { text: 'Project Plan', replace: 7, cursor: 14 });
  assert.deepEqual(wikiInsertion(aliased, 'x|shown]]'), { text: 'one', replace: 1, cursor: 3 });
  assert.deepEqual(wikiInsertion(plain, '#Goals]]'), { text: 'Project Plan', replace: 0, cursor: 12 });
  assert.deepEqual(wikiInsertion(plain, ' and text'), { text: 'Project Plan]]', replace: 0, cursor: 14 });
});
