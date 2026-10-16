/**
 * Pure helpers for `[[note` and `#tag` autocompletion. No CodeMirror imports,
 * so they run under `node --test`; autocomplete.js wires them into the editor.
 *
 * Note data comes from the library overview: each summary carries `linkText`,
 * the shortest target that resolves uniquely to that note, so what is inserted
 * here is exactly what the main-process resolver will follow.
 */

const WIKI_CONTEXT = /\[\[([^[\]|#\n]*)$/;
// Same boundary as the desktop tag parser, plus `&` and `\` for entities and escapes.
const TAG_CONTEXT = /(?:^|[^\p{L}\p{N}_/&#\\])#([\p{L}\p{N}_\-/]+)$/u;
const HEADING_LINE = /^\s{0,3}#{1,6}\s/;

function fold(value) {
  return String(value || '').normalize('NFC').toLowerCase();
}

/** `[[query` immediately before the caret, or null. `start` is the offset of the query. */
export function wikiLinkContext(before) {
  const match = WIKI_CONTEXT.exec(before);
  return match ? { query: match[1], start: before.length - match[1].length } : null;
}

/** `#query` (at least one character) immediately before the caret, outside headings. */
export function tagContext(before) {
  if (HEADING_LINE.test(before)) return null;
  const match = TAG_CONTEXT.exec(before);
  return match ? { query: match[1], start: before.length - match[1].length } : null;
}

/** Higher is better; -1 means no match. Prefix beats word start beats substring beats subsequence. */
export function matchScore(field, query) {
  const value = fold(field);
  const needle = fold(query).trim();
  if (!needle) return 0;
  if (!value) return -1;
  if (value.startsWith(needle)) return 1000 - value.length;
  const at = value.indexOf(needle);
  if (at > 0) return (/[\s/_-]/.test(value[at - 1]) ? 800 : 600) - at;
  let cursor = 0;
  let score = 0;
  for (const char of needle) {
    const found = value.indexOf(char, cursor);
    if (found < 0) return -1;
    score += found === cursor ? 6 : 1;
    cursor = found + 1;
  }
  return score;
}

function folderOf(relative) {
  const parts = String(relative || '').split(/[\\/]/);
  parts.pop();
  return parts.join('/');
}

/**
 * Notes matching `query`, best first, as `{ label, detail, insert, alias, path }`.
 * Picking an alias links to the note and keeps the alias as the visible text.
 */
export function noteCompletions(notes, query, limit = 50) {
  const ranked = [];
  for (const note of notes || []) {
    if (note.trashedAt || !note.linkText) continue;
    const fileName = String(note.name || '').replace(/\.[^.]+$/, '');
    const fields = [
      { text: note.title, kind: 'title' },
      ...(note.aliases || []).map((text) => ({ text, kind: 'alias' })),
      { text: fileName, kind: 'file' },
    ];
    let best = null;
    for (const field of fields) {
      const score = matchScore(field.text, query);
      if (score >= 0 && (!best || score > best.score)) best = { score, field };
    }
    if (best) ranked.push({ note, ...best });
  }
  const modified = (note) => Date.parse(note.modifiedAt || '') || 0;
  ranked.sort((a, b) => b.score - a.score || modified(b.note) - modified(a.note)
    || String(a.note.title).localeCompare(String(b.note.title)));
  return ranked.slice(0, limit).map(({ note, field }) => {
    const title = note.title || note.linkText;
    const alias = field.kind === 'alias' ? field.text : (note.linkText === title ? null : title);
    const folder = folderOf(note.relative);
    return {
      label: field.kind === 'alias' ? field.text : title,
      detail: field.kind === 'alias' ? '→ ' + title : folder,
      insert: note.linkText,
      alias,
      path: note.path,
    };
  });
}

/** Existing tags matching `query`, excluding an exact match so Enter still ends the line. */
export function tagCompletions(tags, query, limit = 30) {
  const needle = fold(query);
  const ranked = [];
  for (const item of tags || []) {
    const tag = String(item.tag || '');
    const value = fold(tag);
    if (!value || value === needle) continue;
    let score;
    if (value.startsWith(needle)) score = 3;
    else if (value.includes('/' + needle)) score = 2;
    else if (value.includes(needle)) score = 1;
    else continue;
    ranked.push({ tag, count: Number(item.count || 0), score });
  }
  ranked.sort((a, b) => b.score - a.score || b.count - a.count || a.tag.localeCompare(b.tag));
  return ranked.slice(0, limit).map(({ tag, count }) => ({ label: tag, detail: String(count), insert: tag }));
}

/**
 * How to apply a note completion given the text after the caret on its line.
 * Reuses a `]]` that auto-pairing already typed, keeps an existing `|alias` or
 * `#anchor` when editing a link, and otherwise closes the link itself.
 * Returns `{ text, replace, cursor }`: replace `replace` characters after the
 * caret with `text`, then put the caret `cursor` characters after the start.
 */
export function wikiInsertion(option, after) {
  const aliasPart = option.alias ? '|' + option.alias : '';
  const existing = /^([^[\]|#\n]*)(\]\]|\||#[^[\]\n]*\]\])/.exec(after);
  if (existing) {
    const [, tail, next] = existing;
    if (next === ']]') {
      const text = option.insert + aliasPart;
      return { text, replace: tail.length, cursor: text.length + 2 };
    }
    return { text: option.insert, replace: tail.length, cursor: option.insert.length };
  }
  const text = option.insert + aliasPart + ']]';
  return { text, replace: 0, cursor: text.length };
}
