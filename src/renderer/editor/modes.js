import { EditorView, Decoration, ViewPlugin } from '@codemirror/view';

/**
 * Focus mode: everything except the paragraph under the caret is dimmed.
 * A "paragraph" here is the run of non-blank lines around the cursor, which
 * matches how the feature reads to a writer better than the syntax tree does.
 */
class FocusMode {
  constructor(view) {
    this.decorations = this.compute(view);
  }

  update(update) {
    if (update.docChanged || update.viewportChanged || update.selectionSet) {
      this.decorations = this.compute(update.view);
    }
  }

  compute(view) {
    const { state } = view;
    const doc = state.doc;
    const head = state.selection.main.head;
    const current = doc.lineAt(head);

    let first = current.number;
    let last = current.number;
    while (first > 1 && doc.line(first - 1).text.trim() !== '') first--;
    while (last < doc.lines && doc.line(last + 1).text.trim() !== '') last++;

    const decorations = [];
    for (const { from, to } of view.visibleRanges) {
      const start = doc.lineAt(from).number;
      const end = doc.lineAt(to).number;
      for (let n = start; n <= end; n++) {
        if (n >= first && n <= last) continue;
        decorations.push(Decoration.line({ class: 'cm-dimmed' }).range(doc.line(n).from));
      }
    }
    return Decoration.set(decorations, true);
  }
}

export const focusMode = [
  ViewPlugin.fromClass(FocusMode, { decorations: (p) => p.decorations }),
  EditorView.editorAttributes.of({ class: 'fk-focus-mode' }),
];

/**
 * Typewriter mode: the active line is held at the vertical centre of the
 * viewport. The extra bottom padding is what lets the final line get there.
 */
export const typewriterMode = [
  ViewPlugin.fromClass(class {
    constructor(view) {
      this.lastLine = -1;
      this.center(view, true);
    }

    update(update) {
      if (!update.selectionSet && !update.docChanged) return;
      const line = update.state.doc.lineAt(update.state.selection.main.head).number;
      const moved = line !== this.lastLine;
      this.lastLine = line;
      if (moved || update.docChanged) this.center(update.view, false);
    }

    center(view, immediate) {
      const run = () => {
        if (!view.dom.isConnected) return;
        const head = view.state.selection.main.head;
        view.dispatch({ effects: EditorView.scrollIntoView(head, { y: 'center' }) });
      };
      if (immediate) requestAnimationFrame(run);
      else requestAnimationFrame(run);
    }
  }),
  EditorView.theme({
    '.cm-content': { paddingBottom: '45vh' },
  }),
  EditorView.editorAttributes.of({ class: 'fk-typewriter-mode' }),
];

/**
 * Markdown-aware auto-pairing for the symbols CodeMirror's bracket closer
 * does not know about. Typing `*` inserts `**` around the caret, and typing
 * the closing half when it is already there just steps over it.
 */
const PAIRS = {
  '*': '*',
  '_': '_',
  '`': '`',
  '~': '~',
  $: '$',
  '=': '=',
};

export const markdownAutoPair = EditorView.inputHandler.of((view, from, to, text) => {
  if (text.length !== 1) return false;
  const close = PAIRS[text];
  if (!close) return false;

  const { state } = view;
  const range = state.selection.main;

  // Wrap a non-empty selection instead of replacing it.
  if (from !== to || !range.empty) {
    const selected = state.sliceDoc(range.from, range.to);
    if (!selected) return false;
    view.dispatch({
      changes: { from: range.from, to: range.to, insert: text + selected + close },
      selection: { anchor: range.from + 1, head: range.from + 1 + selected.length },
      userEvent: 'input.type',
    });
    return true;
  }

  const next = state.sliceDoc(from, from + 1);
  // Typing over the closing half we inserted a moment ago.
  if (next === close) {
    view.dispatch({ selection: { anchor: from + 1 }, userEvent: 'move' });
    return true;
  }

  const prev = from > 0 ? state.sliceDoc(from - 1, from) : '';
  // Don't pair mid-word: `can't`, `foo_bar`, `2*3`.
  if (/[\w\d]/.test(prev)) return false;
  // `**` and `$$` want to become a doubled pair, handled by repeat typing.
  if (prev === text) return false;

  view.dispatch({
    changes: { from, to, insert: text + close },
    selection: { anchor: from + 1 },
    userEvent: 'input.type',
  });
  return true;
});
