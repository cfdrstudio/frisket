import { Annotation, Transaction } from '@codemirror/state';

/**
 * Keep several editor views of one note identical, as CodeMirror's split-view
 * example does: every change made in one view is replayed in the others,
 * marked so it is not replayed again and kept out of their undo history
 * (each view undoes only its own edits).
 */
export const mirrored = Annotation.define();

/** Was this update only replaying changes from another view? */
export function isMirrored(update) {
  return update.transactions.length > 0 && update.transactions.every((tr) => tr.annotation(mirrored));
}

/** Replay the document changes in `update` into each of `views`. */
export function mirrorChanges(update, views) {
  if (!views.length) return;
  for (const tr of update.transactions) {
    if (tr.changes.empty || tr.annotation(mirrored)) continue;
    // No user-event annotation: a mirrored edit must not open autocomplete in the other view.
    const annotations = [mirrored.of(true), Transaction.addToHistory.of(false)];
    for (const view of views) view.dispatch({ changes: tr.changes, annotations });
  }
}
