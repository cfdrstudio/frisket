import assert from 'node:assert/strict';
import test from 'node:test';
import { lineDiff, diffStats, withContext } from '../src/renderer/ui/lineDiff.mjs';

const kinds = (ops) => ops.map((op) => op.type[0] + op.text).join(',');

test('aligns insertions, deletions and replacements', () => {
  assert.equal(kinds(lineDiff('a\nb\nc', 'a\nb\nc')), 'sa,sb,sc');
  assert.equal(kinds(lineDiff('a\nc', 'a\nb\nc')), 'sa,ab,sc');
  assert.equal(kinds(lineDiff('a\nb\nc', 'a\nc')), 'sa,db,sc');
  assert.equal(kinds(lineDiff('a\nold\nc', 'a\nnew\nc')), 'sa,dold,anew,sc');
  assert.equal(kinds(lineDiff('', 'x')), 'ax');
  assert.equal(kinds(lineDiff('x\r\ny', 'x\ny')), 'sx,sy', 'line endings are ignored');
  assert.deepEqual(diffStats(lineDiff('a\nb', 'a\nc\nd')), { added: 2, removed: 1 });
});

test('falls back to remove-all/add-all when the changed region is huge', () => {
  const ops = lineDiff('s\nx\ny\ne', 's\np\nq\ne', { maxCells: 1 });
  assert.equal(kinds(ops), 'ss,dx,dy,ap,aq,se');
});

test('withContext collapses long unchanged runs', () => {
  const before = Array.from({ length: 20 }, (_, i) => 'line ' + i).join('\n');
  const after = before.replace('line 10', 'changed');
  const shown = withContext(lineDiff(before, after), 2);
  assert.deepEqual(shown.map((op) => op.type), ['skip', 'same', 'same', 'del', 'add', 'same', 'same', 'skip']);
  assert.equal(shown[0].count, 8);
  assert.equal(shown[7].count, 7);
});
