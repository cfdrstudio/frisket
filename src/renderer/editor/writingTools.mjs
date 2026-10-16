const FILLER_PHRASES = [
  { pattern: /\bin order to\b/gi, suggestion: 'to' },
  { pattern: /\bdue to the fact that\b/gi, suggestion: 'because' },
  { pattern: /\bat this point in time\b/gi, suggestion: 'now' },
  { pattern: /\b(very|really|quite)\s+([\p{L}\p{N}_-]+)/giu, suggestion: null },
];

function maskRange(chars, start, end) {
  for (let i = start; i < end; i++) {
    if (chars[i] !== '\n' && chars[i] !== '\r') chars[i] = ' ';
  }
}

function maskFrontMatter(chars, text) {
  const opening = /^---\r?\n/.exec(text);
  if (!opening) return;
  const closing = /^(?:---|\.\.\.)(?:\r?\n|$)/gm;
  closing.lastIndex = opening[0].length;
  const match = closing.exec(text);
  if (match) maskRange(chars, 0, match.index + match[0].length);
}

function maskFencedCode(chars, text) {
  const lines = text.matchAll(/.*(?:\r?\n|$)/g);
  let offset = 0;
  let fence = null;
  for (const [line] of lines) {
    if (!line) continue;
    const content = line.replace(/\r?\n$/, '');
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(content);
    if (!fence && marker) {
      fence = { char: marker[1][0], length: marker[1].length };
      maskRange(chars, offset, offset + line.length);
    } else if (fence) {
      const close = new RegExp('^ {0,3}' + (fence.char === '`' ? '`' : '~')
        + '{' + fence.length + ',}\\s*$').test(content);
      maskRange(chars, offset, offset + line.length);
      if (close) fence = null;
    }
    offset += line.length;
  }
}

function maskInlineCodeAndHtml(chars, text) {
  const lines = text.matchAll(/.*(?:\r?\n|$)/g);
  let offset = 0;
  for (const [line] of lines) {
    if (!line) continue;
    const content = line.replace(/\r?\n$/, '');
    // Treat raw HTML lines as authored markup. This avoids diagnostics on
    // script/style payloads and keeps suggestions strictly plain text.
    if (/<\/?[A-Za-z][^>]*>|<!--|-->/i.test(content)) {
      maskRange(chars, offset, offset + line.length);
      offset += line.length;
      continue;
    }
    const inlineCode = /(`+).*?\1/g;
    for (const match of content.matchAll(inlineCode)) {
      maskRange(chars, offset + match.index, offset + match.index + match[0].length);
    }
    offset += line.length;
  }
}

/** Return deterministic, advisory writing diagnostics with source character offsets. */
export function analyzeStyle(text) {
  const source = String(text ?? '');
  // Array.from iterates Unicode code points, while editor offsets are UTF-16.
  // Work with code units to keep every returned offset compatible with slices.
  const chars = source.split('');
  maskFrontMatter(chars, source);
  maskFencedCode(chars, source);
  maskInlineCodeAndHtml(chars, source);
  const searchable = chars.join('');
  const results = [];

  const repeatedWord = /\b([\p{L}][\p{L}\p{N}'’-]*)\s+\1\b/giu;
  for (const match of searchable.matchAll(repeatedWord)) {
    const start = match.index;
    const firstLength = match[1].length;
    const gap = match[0].slice(firstLength).match(/^\s*/)[0].length;
    const secondStart = start + firstLength + gap;
    results.push({
      from: start,
      to: secondStart + firstLength,
      kind: 'repeated-word',
      message: `“${match[1]}” is repeated.`,
      suggestion: match[1],
    });
  }

  for (const item of FILLER_PHRASES) {
    for (const match of searchable.matchAll(item.pattern)) {
      const phrase = match[0];
      results.push({
        from: match.index,
        to: match.index + phrase.length,
        kind: 'wordiness',
        message: item.suggestion
          ? `This phrase can be shorter: “${item.suggestion}”.`
          : `Consider whether “${phrase}” adds meaning.`,
        ...(item.suggestion ? { suggestion: item.suggestion } : {}),
      });
    }
  }

  results.sort((a, b) => a.from - b.from || a.to - b.to);
  return results;
}

function localDate(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function localTime(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** Interpolate the supported date, time, title, and selection placeholders. */
export function applyTemplate(template, { title = '', selection = '', now = new Date() } = {}) {
  const date = now instanceof Date ? now : new Date(now);
  const values = {
    title: String(title),
    selection: String(selection),
    date: localDate(date),
    time: localTime(date),
  };
  return String(template).replace(/\{\{(title|selection|date|time)\}\}/g,
    (_placeholder, key) => values[key]);
}
