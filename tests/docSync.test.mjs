import assert from 'node:assert/strict';
import test from 'node:test';
import { EditorState, Transaction } from '@codemirror/state';
import { mirrorChanges, isMirrored, mirrored } from '../src/renderer/editor/docSync.mjs';

/** Enough of an EditorView for mirroring: a state and dispatch. */
function fakeView(doc) {
  return {
    state: EditorState.create({ doc }),
    dispatched: [],
    dispatch(spec) {
      const tr = this.state.update(spec);
      this.state = tr.state;
      this.dispatched.push(tr);
    },
  };
}

test('edits in one view are replayed in the others, outside their undo history', () => {
  const source = EditorState.create({ doc: 'hello' });
  const typed = source.update({ changes: { from: 5, insert: ' world' }, userEvent: 'input.type' });
  const left = fakeView('hello');
  const right = fakeView('hello');
  mirrorChanges({ transactions: [typed] }, [left, right]);
  assert.equal(left.state.doc.toString(), 'hello world');
  assert.equal(right.state.doc.toString(), 'hello world');
  const replay = left.dispatched[0];
  assert.equal(replay.annotation(mirrored), true);
  assert.equal(replay.annotation(Transaction.addToHistory), false);
  assert.equal(replay.annotation(Transaction.userEvent), undefined, 'no input event, so no autocomplete in the other view');
});

test('replayed edits are not replayed again, and selection-only updates send nothing', () => {
  const left = fakeView('abc');
  mirrorChanges({ transactions: [EditorState.create({ doc: 'abc' }).update({ changes: { from: 0, insert: 'x' } })] }, [left]);
  const echo = fakeView('xabc');
  mirrorChanges({ transactions: left.dispatched }, [echo]);
  assert.equal(echo.dispatched.length, 0);
  assert.equal(isMirrored({ transactions: left.dispatched }), true);
  const select = EditorState.create({ doc: 'abc' }).update({ selection: { anchor: 2 } });
  mirrorChanges({ transactions: [select] }, [echo]);
  assert.equal(echo.dispatched.length, 0);
  assert.equal(isMirrored({ transactions: [select] }), false);
});
