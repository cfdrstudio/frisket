import { EditorSelection } from '@codemirror/state';

/**
 * Wrap or unwrap the selection in a pair of markers. With an empty selection
 * this drops the markers in and parks the caret between them, and running it
 * again on already-wrapped text takes the markers back off.
 */
export function toggleWrap(view, before, after = before) {
  const { state } = view;
  const changes = [];
  const selections = [];

  for (const range of state.selection.ranges) {
    const from = range.from;
    const to = range.to;
    const outerFrom = from - before.length;
    const outerTo = to + after.length;

    const alreadyWrappedOutside = outerFrom >= 0 && outerTo <= state.doc.length
      && state.sliceDoc(outerFrom, from) === before
      && state.sliceDoc(to, outerTo) === after;

    const text = state.sliceDoc(from, to);
    const alreadyWrappedInside = text.length >= before.length + after.length
      && text.startsWith(before) && text.endsWith(after);

    if (alreadyWrappedOutside) {
      changes.push({ from: outerFrom, to: from, insert: '' });
      changes.push({ from: to, to: outerTo, insert: '' });
      selections.push(EditorSelection.range(outerFrom, to - before.length));
    } else if (alreadyWrappedInside) {
      const inner = text.slice(before.length, text.length - after.length);
      changes.push({ from, to, insert: inner });
      selections.push(EditorSelection.range(from, from + inner.length));
    } else if (from === to) {
      changes.push({ from, insert: before + after });
      selections.push(EditorSelection.cursor(from + before.length));
    } else {
      changes.push({ from, insert: before });
      changes.push({ from: to, insert: after });
      selections.push(EditorSelection.range(from + before.length, to + before.length));
    }
  }

  view.dispatch({
    changes,
    selection: EditorSelection.create(selections, state.selection.mainIndex),
    scrollIntoView: true,
    userEvent: 'input.format',
  });
  view.focus();
  return true;
}

/** Every line touched by the selection, de-duplicated. */
function selectedLines(state) {
  const lines = [];
  const seen = new Set();
  for (const range of state.selection.ranges) {
    let pos = range.from;
    while (pos <= range.to) {
      const line = state.doc.lineAt(pos);
      if (!seen.has(line.number)) { seen.add(line.number); lines.push(line); }
      if (line.to >= range.to) break;
      pos = line.to + 1;
    }
  }
  return lines.sort((a, b) => a.from - b.from);
}

const HEADING_PREFIX = /^(\s*)(#{1,6})(\s+)?/;

export function setHeading(view, level) {
  const { state } = view;
  const changes = [];
  for (const line of selectedLines(state)) {
    const match = HEADING_PREFIX.exec(line.text);
    const indent = match ? match[1] : (/^\s*/.exec(line.text)[0] || '');
    const bodyFrom = line.from + (match ? match[0].length : indent.length);
    const prefix = level > 0 ? indent + '#'.repeat(level) + ' ' : indent;
    changes.push({ from: line.from, to: bodyFrom, insert: prefix });
  }
  view.dispatch({ changes, userEvent: 'input.format', scrollIntoView: true });
  view.focus();
  return true;
}

export function adjustHeading(view, delta) {
  const { state } = view;
  const line = state.doc.lineAt(state.selection.main.head);
  const match = HEADING_PREFIX.exec(line.text);
  const current = match && match[2] ? match[2].length : 0;
  const next = Math.max(0, Math.min(6, current + delta));
  return setHeading(view, next);
}

const BULLET_RE = /^(\s*)([-*+])(\s+)(\[[ xX]\]\s+)?/;
const ORDERED_RE = /^(\s*)(\d+)([.)])(\s+)/;

export function toggleList(view, kind) {
  const { state } = view;
  const lines = selectedLines(state);
  const changes = [];

  const isKind = (line) => {
    const bullet = BULLET_RE.exec(line.text);
    if (kind === 'ul') return !!bullet && !bullet[4];
    if (kind === 'task') return !!bullet && !!bullet[4];
    return ORDERED_RE.test(line.text);
  };

  const allMatch = lines.length > 0 && lines.every((line) => !line.text.trim() || isKind(line));
  let counter = 1;

  for (const line of lines) {
    if (!line.text.trim()) continue;
    const bullet = BULLET_RE.exec(line.text);
    const ordered = ORDERED_RE.exec(line.text);
    const indent = /^\s*/.exec(line.text)[0];
    const stripTo = line.from + (bullet ? bullet[0].length : ordered ? ordered[0].length : indent.length);

    if (allMatch) {
      changes.push({ from: line.from, to: stripTo, insert: indent });
      continue;
    }
    let prefix = indent;
    if (kind === 'ul') prefix += '- ';
    else if (kind === 'task') prefix += '- [ ] ';
    else prefix += (counter++) + '. ';
    changes.push({ from: line.from, to: stripTo, insert: prefix });
  }

  view.dispatch({ changes, userEvent: 'input.format', scrollIntoView: true });
  view.focus();
  return true;
}

export function toggleQuote(view) {
  const { state } = view;
  const lines = selectedLines(state);
  const allQuoted = lines.length > 0 && lines.every((line) => /^\s*>\s?/.test(line.text) || !line.text.trim());
  const changes = [];
  for (const line of lines) {
    if (allQuoted) {
      const match = /^(\s*)>\s?/.exec(line.text);
      if (match) changes.push({ from: line.from, to: line.from + match[0].length, insert: match[1] });
    } else {
      changes.push({ from: line.from, insert: '> ' });
    }
  }
  view.dispatch({ changes, userEvent: 'input.format', scrollIntoView: true });
  view.focus();
  return true;
}

/** Insert a block construct, reusing the selection as its body when present. */
function insertBlock(view, open, close, body = '', caretOffset = null) {
  const { state } = view;
  const range = state.selection.main;
  const line = state.doc.lineAt(range.from);
  const selected = state.sliceDoc(range.from, range.to);
  const content = selected || body;

  const needsLeadingBreak = line.from !== range.from || line.text.trim() !== '';
  const prefix = needsLeadingBreak ? '\n\n' : '';
  const text = prefix + open + '\n' + content + '\n' + close + '\n';
  const insertAt = needsLeadingBreak ? line.to : line.from;

  const caret = caretOffset !== null
    ? insertAt + prefix + caretOffset
    : insertAt + prefix + open.length + 1 + content.length;

  view.dispatch({
    changes: { from: insertAt, to: Math.max(insertAt, range.to), insert: text },
    selection: { anchor: caret },
    userEvent: 'input.format',
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

export function insertCodeFence(view, lang = '') {
  return insertBlock(view, '```' + lang, '```', '', lang ? null : 3);
}

export function insertMathBlock(view) {
  return insertBlock(view, '$$', '$$');
}

export function insertHorizontalRule(view) {
  const { state } = view;
  const line = state.doc.lineAt(state.selection.main.head);
  const prefix = line.text.trim() ? '\n\n' : '';
  view.dispatch({
    changes: { from: line.to, insert: prefix + '---\n' },
    selection: { anchor: line.to + prefix.length + 4 },
    userEvent: 'input.format',
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

export function insertTable(view, rows = 2, cols = 3) {
  const { state } = view;
  const line = state.doc.lineAt(state.selection.main.head);
  const header = '| ' + Array.from({ length: cols }, (_, i) => 'Column ' + (i + 1)).join(' | ') + ' |';
  const divider = '| ' + Array.from({ length: cols }, () => '---').join(' | ') + ' |';
  const body = Array.from({ length: rows }, () =>
    '| ' + Array.from({ length: cols }, () => '   ').join(' | ') + ' |').join('\n');
  const prefix = line.text.trim() ? '\n\n' : '';
  const text = prefix + header + '\n' + divider + '\n' + body + '\n';

  view.dispatch({
    changes: { from: line.to, insert: text },
    selection: { anchor: line.to + prefix.length + 2 },
    userEvent: 'input.format',
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

export function insertLink(view, url = '') {
  const { state } = view;
  const range = state.selection.main;
  const selected = state.sliceDoc(range.from, range.to);
  const looksLikeUrl = /^(https?:\/\/|mailto:|www\.)/i.test(selected.trim());
  const label = looksLikeUrl ? '' : selected;
  const href = url || (looksLikeUrl ? selected.trim() : '');
  const text = '[' + label + '](' + href + ')';
  const caret = label
    ? range.from + text.length - 1 - href.length + href.length
    : range.from + 1;

  view.dispatch({
    changes: { from: range.from, to: range.to, insert: text },
    selection: { anchor: href && label ? range.from + text.length : caret },
    userEvent: 'input.format',
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

export function insertImage(view, src, alt = '') {
  const { state } = view;
  const range = state.selection.main;
  const text = '![' + alt + '](' + src + ')';
  view.dispatch({
    changes: { from: range.from, to: range.to, insert: text },
    selection: { anchor: range.from + text.length },
    userEvent: 'input.format',
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

export function insertAttachment(view, src, label = '') {
  const { state } = view;
  const range = state.selection.main;
  const text = '[' + (label || src.split('/').pop() || 'Attachment') + '](' + src + ')';
  view.dispatch({
    changes: { from: range.from, to: range.to, insert: text },
    selection: { anchor: range.from + text.length },
    userEvent: 'input.format',
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

const INLINE_MARKERS = /(\*\*\*|___|\*\*|__|~~|==|\*|_|`)/g;

export function clearFormatting(view) {
  const { state } = view;
  const changes = [];
  for (const range of state.selection.ranges) {
    if (range.empty) continue;
    const text = state.sliceDoc(range.from, range.to);
    const stripped = text
      .replace(/^(\s*)(#{1,6}\s+|>\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)/gm, '$1')
      .replace(INLINE_MARKERS, '')
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    changes.push({ from: range.from, to: range.to, insert: stripped });
  }
  if (!changes.length) return false;
  view.dispatch({ changes, userEvent: 'input.format' });
  view.focus();
  return true;
}

// ---------------------------------------------------------------------------
// Smart editing
// ---------------------------------------------------------------------------

/**
 * Leave a list or blockquote: drop the dangling marker and open a blank line
 * beneath it, so what you type next is a real paragraph rather than a lazy
 * continuation of the last item.
 */
function endBlock(view, line) {
  const atEnd = line.to >= view.state.doc.length;
  const insert = atEnd ? '\n' : '';
  view.dispatch({
    changes: { from: line.from, to: line.to, insert },
    selection: { anchor: line.from + insert.length },
    userEvent: 'input',
    scrollIntoView: true,
  });
  return true;
}

/**
 * Enter inside a list continues it; Enter on an empty list item ends the list.
 * Also carries blockquote markers onto the next line.
 */
export function smartEnter(view) {
  const { state } = view;
  const range = state.selection.main;
  if (!range.empty) return false;

  const line = state.doc.lineAt(range.head);
  const beforeCaret = line.text.slice(0, range.head - line.from);

  const bullet = BULLET_RE.exec(beforeCaret);
  const ordered = ORDERED_RE.exec(beforeCaret);
  const quote = /^(\s*)>\s?/.exec(beforeCaret);

  if (bullet) {
    const marker = bullet[0];
    // An empty item means "I'm done with this list".
    if (beforeCaret.trim() === marker.trim() && line.text.trim() === marker.trim()) {
      return endBlock(view, line);
    }
    const next = '\n' + bullet[1] + bullet[2] + bullet[3] + (bullet[4] ? '[ ] ' : '');
    view.dispatch({
      changes: { from: range.head, insert: next },
      selection: { anchor: range.head + next.length },
      userEvent: 'input',
      scrollIntoView: true,
    });
    return true;
  }

  if (ordered) {
    if (beforeCaret.trim() === ordered[0].trim() && line.text.trim() === ordered[0].trim()) {
      return endBlock(view, line);
    }
    const next = '\n' + ordered[1] + (Number(ordered[2]) + 1) + ordered[3] + ordered[4];
    view.dispatch({
      changes: { from: range.head, insert: next },
      selection: { anchor: range.head + next.length },
      userEvent: 'input',
      scrollIntoView: true,
    });
    return true;
  }

  if (quote) {
    if (line.text.trim() === '>') {
      return endBlock(view, line);
    }
    const next = '\n' + quote[1] + '> ';
    view.dispatch({
      changes: { from: range.head, insert: next },
      selection: { anchor: range.head + next.length },
      userEvent: 'input',
      scrollIntoView: true,
    });
    return true;
  }

  return false;
}

/** Tab indents the current list item rather than inserting a literal tab. */
export function indentListItem(view, outdent = false) {
  const { state } = view;
  const lines = selectedLines(state);
  const listLines = lines.filter((line) => BULLET_RE.test(line.text) || ORDERED_RE.test(line.text));
  if (!listLines.length) return false;

  const unit = '    ';
  const changes = [];
  for (const line of listLines) {
    const indent = /^\s*/.exec(line.text)[0];
    if (outdent) {
      const trimmed = indent.startsWith(unit) ? indent.slice(unit.length)
        : indent.startsWith('\t') ? indent.slice(1)
        : indent.replace(/^ {1,4}/, '');
      if (trimmed !== indent) changes.push({ from: line.from, to: line.from + indent.length, insert: trimmed });
    } else {
      changes.push({ from: line.from, insert: unit });
    }
  }
  if (!changes.length) return false;
  view.dispatch({ changes, userEvent: 'input.indent' });
  return true;
}

/** Backspace at the head of a list item removes the marker before the text. */
export function smartBackspace(view) {
  const { state } = view;
  const range = state.selection.main;
  if (!range.empty) return false;
  const line = state.doc.lineAt(range.head);
  const bullet = BULLET_RE.exec(line.text);
  const ordered = ORDERED_RE.exec(line.text);
  const marker = bullet ? bullet[0] : ordered ? ordered[0] : null;
  if (!marker) return false;
  if (range.head !== line.from + marker.length) return false;

  const indent = /^\s*/.exec(line.text)[0];
  view.dispatch({
    changes: { from: line.from + indent.length, to: line.from + marker.length, insert: '' },
    userEvent: 'delete.backward',
  });
  return true;
}
