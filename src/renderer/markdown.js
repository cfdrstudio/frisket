import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import taskLists from 'markdown-it-task-lists';
import katex from 'katex';
import hljs from 'highlight.js/lib/common';

/** Fenced languages that are rendered as diagrams rather than highlighted code. */
export const DIAGRAM_LANGS = new Set(['mermaid', 'sequence', 'flow', 'flowchart', 'gantt']);

// Exports use MathML only: it needs no stylesheet or webfonts, which is what
// makes an exported HTML file genuinely self-contained.
let mathOutput = 'htmlAndMathml';

export function setMathOutput(mode) {
  mathOutput = mode;
}

function renderMath(source, displayMode) {
  try {
    return katex.renderToString(source, {
      displayMode,
      throwOnError: false,
      strict: 'ignore',
      trust: false,
      output: mathOutput,
    });
  } catch (err) {
    const cls = displayMode ? 'math-error math-block' : 'math-error';
    return '<span class="' + cls + '">' + escapeHtml(source) + '</span>';
  }
}

export function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** markdown-it plugin: `$inline$` and `$$block$$` via KaTeX. */
function mathPlugin(md) {
  md.inline.ruler.before('escape', 'inline_math', (state, silent) => {
    const start = state.pos;
    if (state.src.charCodeAt(start) !== 0x24) return false;
    if (state.src.charCodeAt(start + 1) === 0x24) return false;

    let pos = start + 1;
    const max = state.posMax;
    if (pos >= max) return false;
    const first = state.src.charCodeAt(pos);
    if (first === 0x20 || first === 0x09 || first === 0x0a) return false;

    while (pos < max) {
      const ch = state.src.charCodeAt(pos);
      if (ch === 0x5c) { pos += 2; continue; }
      if (ch === 0x0a) return false;
      if (ch === 0x24) break;
      pos++;
    }
    if (pos >= max || pos === start + 1) return false;
    const prev = state.src.charCodeAt(pos - 1);
    if (prev === 0x20 || prev === 0x09) return false;

    const content = state.src.slice(start + 1, pos);
    if (/^[\d.,\s+\-]*$/.test(content)) return false;

    if (!silent) {
      const token = state.push('math_inline', 'math', 0);
      token.markup = '$';
      token.content = content;
    }
    state.pos = pos + 1;
    return true;
  });

  md.block.ruler.before('fence', 'block_math', (state, startLine, endLine, silent) => {
    const start = state.bMarks[startLine] + state.tShift[startLine];
    const max = state.eMarks[startLine];
    if (start + 2 > max) return false;
    if (state.src.slice(start, start + 2) !== '$$') return false;

    let firstLine = state.src.slice(start + 2, max);
    let lastLine = null;
    let line = startLine;
    let found = false;

    if (firstLine.trim().endsWith('$$')) {
      firstLine = firstLine.trim().slice(0, -2);
      found = true;
    }

    while (!found) {
      line++;
      if (line >= endLine) break;
      const begin = state.bMarks[line] + state.tShift[line];
      const stop = state.eMarks[line];
      const text = state.src.slice(begin, stop);
      if (text.trim().endsWith('$$')) {
        lastLine = text.trim().slice(0, -2);
        found = true;
      }
    }
    if (!found) return false;
    if (silent) return true;

    const parts = [firstLine];
    for (let i = startLine + 1; i < line; i++) {
      parts.push(state.src.slice(state.bMarks[i] + state.tShift[i], state.eMarks[i]));
    }
    if (lastLine !== null) parts.push(lastLine);

    state.line = line + 1;
    const token = state.push('math_block', 'math', 0);
    token.block = true;
    token.markup = '$$';
    token.content = parts.join('\n').trim();
    token.map = [startLine, state.line];
    return true;
  }, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });

  md.renderer.rules.math_inline = (tokens, idx) => renderMath(tokens[idx].content, false);
  md.renderer.rules.math_block = (tokens, idx) => '<p class="math-display">' + renderMath(tokens[idx].content, true) + '</p>';
}

/** markdown-it plugin: `==highlight==`. */
function markPlugin(md) {
  md.inline.ruler.before('emphasis', 'mark_highlight', (state, silent) => {
    const start = state.pos;
    if (state.src.charCodeAt(start) !== 0x3d || state.src.charCodeAt(start + 1) !== 0x3d) return false;
    const close = state.src.indexOf('==', start + 2);
    if (close < 0 || close === start + 2) return false;
    const nl = state.src.indexOf('\n', start);
    if (nl >= 0 && nl < close) return false;
    if (!silent) {
      state.push('mark_open', 'mark', 1);
      const text = state.push('text', '', 0);
      text.content = state.src.slice(start + 2, close);
      state.push('mark_close', 'mark', -1);
    }
    state.pos = close + 2;
    return true;
  });
}

/** markdown-it plugin: `[[wiki-links]]`, with optional `|alias`. */
function wikiLinkPlugin(md) {
  md.inline.ruler.before('link', 'wiki_link', (state, silent) => {
    const start = state.pos;
    if (state.src.charCodeAt(start) !== 0x5b || state.src.charCodeAt(start + 1) !== 0x5b) return false;

    const close = state.src.indexOf(']]', start + 2);
    if (close < 0 || close === start + 2) return false;
    const nl = state.src.indexOf('\n', start);
    if (nl >= 0 && nl < close) return false;

    const body = state.src.slice(start + 2, close);
    const bar = body.indexOf('|');
    const target = (bar > -1 ? body.slice(0, bar) : body).trim();
    const label = (bar > -1 ? body.slice(bar + 1) : body).trim();
    if (!target) return false;

    if (!silent) {
      const href = /\.[a-z0-9]+$/i.test(target) ? target : target + '.md';
      const open = state.push('link_open', 'a', 1);
      open.attrs = [['href', href], ['class', 'wiki-link']];
      const text = state.push('text', '', 0);
      text.content = label || target;
      state.push('link_close', 'a', -1);
    }
    state.pos = close + 2;
    return true;
  });
}

const md = new MarkdownIt({
  html: true,
  linkify: true,
  breaks: false,
  typographer: false,
  highlight(code, lang) {
    if (DIAGRAM_LANGS.has((lang || '').toLowerCase())) {
      return '<div class="mermaid-source" data-lang="' + escapeHtml(lang)
        + '">' + escapeHtml(code) + '</div>';
    }
    if (lang && hljs.getLanguage(lang)) {
      try {
        return '<pre class="hljs"><code class="language-' + escapeHtml(lang) + '">'
          + hljs.highlight(code, { language: lang, ignoreIllegals: true }).value
          + '</code></pre>';
      } catch { /* fall through to plain */ }
    }
    return '<pre class="hljs"><code>' + escapeHtml(code) + '</code></pre>';
  },
});

md.use(footnote).use(taskLists, { enabled: true, label: true }).use(mathPlugin).use(markPlugin).use(wikiLinkPlugin);

// Strip the YAML front matter Typora-style documents often carry.
const FRONT_MATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;

export function splitFrontMatter(source) {
  const match = FRONT_MATTER.exec(source);
  if (!match) return { meta: null, body: source };
  return { meta: match[1], body: source.slice(match[0].length) };
}

/** Pull a document title out of front matter or the first H1. */
export function inferTitle(source, fallback) {
  const { meta, body } = splitFrontMatter(source);
  if (meta) {
    const line = /^title:\s*(.+)$/m.exec(meta);
    if (line) return line[1].trim().replace(/^["']|["']$/g, '');
  }
  const h1 = /^#\s+(.+)$/m.exec(body);
  if (h1) return h1[1].trim();
  return fallback || 'Untitled';
}

export function renderMarkdown(source) {
  const { body } = splitFrontMatter(source);
  return md.render(body);
}

/** Render a small snippet without front-matter handling (used for table widgets). */
export function renderInlineMarkdown(source) {
  return md.render(source);
}

export { md, renderMath };
