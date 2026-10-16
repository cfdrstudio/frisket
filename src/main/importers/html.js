'use strict';

/**
 * A small, dependency-free HTML → Markdown converter for imported notes
 * (Evernote ENML, Apple Notes HTML). It is tolerant rather than complete:
 * unknown elements contribute their text, and nothing it cannot express is
 * allowed to break the surrounding Markdown.
 */

const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr', 'en-media', 'en-todo']);
const SKIP = new Set(['script', 'style', 'head', 'title', 'noscript', 'template']);
const BLOCK = new Set([
  'address', 'article', 'aside', 'blockquote', 'body', 'center', 'dd', 'details', 'dialog', 'div', 'dl', 'dt',
  'en-note', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header',
  'hr', 'html', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'summary', 'table', 'ul',
]);
// Opening one of these ends an open <p>, as browsers do.
const CLOSES_P = new Set(['div', 'ul', 'ol', 'table', 'pre', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'hr', 'section', 'article', 'figure']);

const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ensp: ' ', emsp: ' ', thinsp: ' ',
  mdash: '—', ndash: '–', hellip: '…', lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”', laquo: '«', raquo: '»',
  bull: '•', middot: '·', times: '×', divide: '÷', copy: '©', reg: '®', trade: '™', deg: '°', plusmn: '±',
  euro: '€', pound: '£', yen: '¥', cent: '¢', sect: '§', para: '¶', larr: '←', rarr: '→', uarr: '↑', darr: '↓',
  hearts: '♥', check: '✓', frac12: '½', frac14: '¼', frac34: '¾', iexcl: '¡', iquest: '¿', shy: '',
};

const HARD_BREAK = '\u0001';
const TODO_OPEN = '\u0002';
const TODO_CLOSE = '\u0003';

function decodeEntities(text) {
  return String(text).replace(/&(#x[0-9a-f]+|#\d+|[a-z][a-z0-9]*);/gi, (whole, body) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      try { return code > 0 ? String.fromCodePoint(code) : ''; } catch { return whole; }
    }
    const named = ENTITIES[body.toLowerCase()];
    return named === undefined ? whole : named;
  });
}

function parseAttributes(source) {
  const attrs = {};
  const pattern = /([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
  let match;
  while ((match = pattern.exec(source || ''))) {
    attrs[match[1].toLowerCase()] = decodeEntities(match[2] ?? match[3] ?? match[4] ?? '');
  }
  return attrs;
}

/** Parse HTML into `{ type, name, attrs, children }` / `{ type: 'text', text }` nodes. */
function parseHtml(html) {
  const root = { type: 'element', name: '#root', attrs: {}, children: [] };
  const stack = [root];
  const top = () => stack[stack.length - 1];
  const token = /<!--[\s\S]*?-->|<!\[CDATA\[([\s\S]*?)\]\]>|<![^>]*>|<\?[\s\S]*?\?>|<\/\s*([a-zA-Z][\w:-]*)\s*>|<([a-zA-Z][\w:-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(\/?)>/g;
  const source = String(html || '');
  let last = 0;
  let match;
  const addText = (text) => { if (text) top().children.push({ type: 'text', text }); };
  while ((match = token.exec(source))) {
    addText(decodeEntities(source.slice(last, match.index)));
    last = token.lastIndex;
    if (match[1] !== undefined) { addText(match[1]); continue; }
    if (match[2]) {
      const name = match[2].toLowerCase();
      const at = stack.map((node) => node.name).lastIndexOf(name);
      if (at > 0) stack.length = at;
      continue;
    }
    if (!match[3]) continue;
    const name = match[3].toLowerCase();
    if (SKIP.has(name)) {
      const end = source.toLowerCase().indexOf('</' + name, token.lastIndex);
      const close = end < 0 ? source.length : source.indexOf('>', end) + 1 || source.length;
      token.lastIndex = close;
      last = close;
      continue;
    }
    if (CLOSES_P.has(name) && top().name === 'p') stack.pop();
    if (name === 'li') {
      const open = stack.map((node) => node.name);
      const li = open.lastIndexOf('li');
      if (li > Math.max(open.lastIndexOf('ul'), open.lastIndexOf('ol'))) stack.length = li;
    }
    if ((name === 'td' || name === 'th') && (top().name === 'td' || top().name === 'th')) stack.pop();
    if (name === 'tr') {
      const open = stack.map((node) => node.name);
      const tr = open.lastIndexOf('tr');
      if (tr > open.lastIndexOf('table')) stack.length = tr;
    }
    const node = { type: 'element', name, attrs: parseAttributes(match[4]), children: [] };
    top().children.push(node);
    if (!VOID.has(name) && !match[5]) stack.push(node);
  }
  addText(decodeEntities(source.slice(last)));
  return root;
}

function textContent(node) {
  if (node.type === 'text') return node.text;
  if (node.name === 'br') return '\n';
  const inner = node.children.map(textContent).join('');
  return BLOCK.has(node.name) && node.name !== 'pre' ? inner + '\n' : inner;
}

function styleOf(node) {
  const style = String(node.attrs.style || '').toLowerCase();
  return {
    bold: /font-weight\s*:\s*(?:bold|[6-9]00)/.test(style),
    italic: /font-style\s*:\s*italic/.test(style),
    underline: /text-decoration[^;]*underline/.test(style),
    strike: /text-decoration[^;]*line-through/.test(style),
    highlight: /--en-highlight|background-color\s*:\s*(?:rgb\(\s*255\s*,\s*2[0-9]{2}\s*,|#ff[ef])/.test(style),
  };
}

/** Wrap inline text in a marker, keeping surrounding spaces outside it. */
function wrap(content, open, close = open) {
  const match = /^(\s*)([\s\S]*?)(\s*)$/.exec(content);
  if (!match[2] || !match[2].replace(new RegExp(HARD_BREAK, 'g'), '').trim()) return content;
  return match[1] + open + match[2] + close + match[3];
}

function escapeText(text) {
  return text
    .replace(/\\/g, '\\\\')
    .replace(/([*`[\]])/g, '\\$1')
    .replace(/(^|[^\p{L}\p{N}])_|_(?=[^\p{L}\p{N}]|$)/gu, (whole) => whole.replace('_', '\\_'))
    .replace(/<(?=[a-zA-Z!/?])/g, '\\<')
    .replace(/#(?=\d)/g, '\\#');
}

function linkDestination(href) {
  const value = String(href || '').trim();
  return /[\s()<>]/.test(value) ? '<' + value.replace(/[<>]/g, encodeURIComponent) + '>' : value;
}

function codeSpan(text) {
  const runs = text.match(/`+/g) || [];
  const fence = '`'.repeat(Math.max(0, ...runs.map((run) => run.length)) + 1);
  const pad = /^`|`$/.test(text) ? ' ' : '';
  return fence + pad + text + pad + fence;
}

function fencedBlock(text, language = '') {
  const runs = text.match(/^`{3,}/gm) || [];
  const fence = '`'.repeat(Math.max(3, ...runs.map((run) => run.length + 1)));
  return fence + language + '\n' + text.replace(/\n+$/, '') + '\n' + fence;
}

class Converter {
  constructor({ media = () => null, image = () => null } = {}) {
    this.media = media;
    this.image = image;
  }

  /** Inline rendering of a node's children. */
  inline(node) {
    return node.children.map((child) => this.node(child, false)).join('');
  }

  /** Children rendered as blocks separated by blank lines. */
  blocks(node) {
    let out = '';
    let run = '';
    const flush = () => {
      const text = run.replace(/[ \t]+/g, ' ').trim();
      if (text) out += '\n\n' + this.guardLineStart(text) + '\n\n';
      run = '';
    };
    for (const child of node.children) {
      if (child.type === 'element' && BLOCK.has(child.name)) {
        flush();
        out += '\n\n' + this.node(child, true) + '\n\n';
      } else {
        run += this.node(child, false);
      }
    }
    flush();
    return out;
  }

  /** Text that would start a heading, quote or list at line start gets escaped. */
  guardLineStart(text) {
    return text
      .replace(/(^|\n)(#{1,6}\s|>|[-+]\s)/g, (_whole, start, marker) => start + '\\' + marker)
      .replace(/(^|\n)(\d+)([.)]\s)/g, (_whole, start, digits, rest) => start + digits + '\\' + rest);
  }

  node(node, block) {
    if (node.type === 'text') return escapeText(node.text.replace(/[ \t\r\n\f]+/g, ' '));
    const { name, attrs } = node;
    switch (name) {
      case 'br': return HARD_BREAK;
      case 'hr': return '---';
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': {
        const text = this.inline(node).replace(new RegExp(HARD_BREAK, 'g'), ' ').replace(/\s+/g, ' ').trim();
        return text ? '#'.repeat(Number(name[1])) + ' ' + text : '';
      }
      case 'p': case 'div': case 'section': case 'article': case 'header': case 'footer': case 'main':
      case 'center': case 'en-note': case 'body': case 'html': case 'figure': case 'figcaption': case 'address':
      case 'details': case 'summary': case 'dd': case 'dt': case 'dl': case 'aside': case 'nav': case 'form':
      case 'fieldset': case '#root':
        return this.styled(node, this.blocks(node));
      case 'blockquote': {
        const inner = finish(this.blocks(node));
        return inner ? inner.split('\n').map((line) => (line ? '> ' + line : '>')).join('\n') : '';
      }
      case 'pre': {
        const text = textContent(node).replace(/ /g, ' ');
        return text.trim() ? fencedBlock(text) : '';
      }
      case 'ul': case 'ol': return this.list(node);
      case 'li': return finish(this.blocks(node));
      case 'table': return this.table(node);
      case 'b': case 'strong': return wrap(this.inline(node), '**');
      case 'i': case 'em': case 'cite': case 'dfn': return wrap(this.inline(node), '*');
      case 'u': case 'ins': return wrap(this.inline(node), '<u>', '</u>');
      case 's': case 'strike': case 'del': return wrap(this.inline(node), '~~');
      case 'mark': return wrap(this.inline(node), '==');
      case 'sub': return wrap(this.inline(node), '~');
      case 'sup': return wrap(this.inline(node), '^');
      case 'code': case 'tt': case 'kbd': case 'samp': {
        const text = textContent(node).replace(/\s+/g, ' ');
        return text.trim() ? codeSpan(text) : '';
      }
      case 'a': {
        const content = this.inline(node);
        const href = String(attrs.href || '').trim();
        if (!href || /^(?:javascript|vbscript|data):/i.test(href)) return content;
        if (!content.trim()) return '<' + href + '>';
        return '[' + content.trim() + '](' + linkDestination(href) + ')';
      }
      case 'img': {
        const src = this.image(attrs.src || '', attrs) || attrs.src || '';
        if (!src || /^data:/i.test(src)) return '';
        return '![' + escapeText(attrs.alt || '') + '](' + linkDestination(src) + ')';
      }
      case 'en-media': {
        const found = this.media(attrs.hash || '', attrs.type || '');
        if (!found) return '';
        const label = escapeText(found.name || 'attachment');
        return (found.image ? '!' : '') + '[' + label + '](' + linkDestination(found.href) + ')';
      }
      case 'en-todo': return TODO_OPEN + (attrs.checked === 'true' ? 'x' : ' ') + TODO_CLOSE;
      case 'input': return attrs.type === 'checkbox' ? TODO_OPEN + ('checked' in attrs ? 'x' : ' ') + TODO_CLOSE : '';
      case 'en-crypt': return '*[Encrypted text not imported]*';
      default: {
        const content = block ? this.blocks(node) : this.inline(node);
        return this.styled(node, content);
      }
    }
  }

  styled(node, content) {
    if (!node.attrs || !node.attrs.style) return content;
    const style = styleOf(node);
    let out = content;
    if (style.bold) out = wrap(out, '**');
    if (style.italic) out = wrap(out, '*');
    if (style.strike) out = wrap(out, '~~');
    if (style.underline) out = wrap(out, '<u>', '</u>');
    if (style.highlight) out = wrap(out, '==');
    return out;
  }

  list(node) {
    const ordered = node.name === 'ol';
    let number = Number(node.attrs.start) || 1;
    const items = [];
    for (const child of node.children) {
      if (child.type !== 'element') continue;
      if (child.name === 'ul' || child.name === 'ol') {
        // A list directly inside a list: nest it under the previous item.
        const nested = this.list(child);
        if (items.length) items[items.length - 1] += '\n' + nested.split('\n').map((line) => '  ' + line).join('\n');
        else items.push(nested);
        continue;
      }
      if (child.name !== 'li') continue;
      let raw = this.blocks(child).trim();
      let marker = ordered ? number++ + '. ' : '- ';
      const todo = new RegExp('^' + TODO_OPEN + '([ x])' + TODO_CLOSE + '\\s*').exec(raw);
      if (todo) {
        marker = '- [' + todo[1] + '] ';
        raw = raw.slice(todo[0].length);
      }
      // Keep a nested list tight against its item rather than a blank line apart.
      const content = finish(raw).replace(/\n\n(?=\s*(?:[-+*]|\d+[.)]) )/g, '\n');
      const indent = ' '.repeat(marker.length);
      const lines = content.split('\n');
      items.push(marker + lines[0] + lines.slice(1).map((line) => '\n' + (line ? indent + line : '')).join(''));
    }
    return items.join('\n');
  }

  table(node) {
    const rows = [];
    const collect = (parent) => {
      for (const child of parent.children) {
        if (child.type !== 'element') continue;
        if (child.name === 'tr') rows.push(child);
        else if (['thead', 'tbody', 'tfoot'].includes(child.name)) collect(child);
      }
    };
    collect(node);
    const cells = rows.map((row) => row.children
      .filter((cell) => cell.type === 'element' && (cell.name === 'td' || cell.name === 'th'))
      .map((cell) => finish(this.blocks(cell)).replace(/\n+/g, '<br>').replace(/\|/g, '\\|').trim()));
    const width = Math.max(0, ...cells.map((row) => row.length));
    if (!width) return '';
    const pad = (row) => [...row, ...Array(width - row.length).fill('')];
    const line = (row) => '| ' + pad(row).map((cell) => cell || ' ').join(' | ') + ' |';
    return [line(cells[0]), '| ' + Array(width).fill('---').join(' | ') + ' |', ...cells.slice(1).map(line)].join('\n');
  }
}

/** Tidy converted output: whitespace, to-do markers and hard breaks. */
function finish(markdown) {
  return markdown
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n[ \t]+(?=\n)/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .split('\n')
    .map((line) => line.replace(new RegExp('^(\\s*)' + TODO_OPEN + '([ x])' + TODO_CLOSE + '\\s*'), '$1- [$2] ')
      .replace(new RegExp(TODO_OPEN + '([ x])' + TODO_CLOSE, 'g'), '[$1]'))
    .join('\n')
    .replace(new RegExp('(?:' + HARD_BREAK + '\\s*)+$', 'gm'), '')
    .replace(new RegExp('^\\s*' + HARD_BREAK, 'gm'), '')
    .replace(new RegExp('\\s*' + HARD_BREAK + '\\s*', 'g'), '  \n')
    .replace(/\n{3,}/g, '\n\n')
    // To-dos written one per block (Evernote's habit) become one tight list.
    .replace(/^(\s*- \[[ x]\] .*)\n\n(?=\s*- \[[ x]\] )/gm, '$1\n')
    .trim();
}

/**
 * Convert HTML to Markdown. `media(hash, type)` resolves Evernote `<en-media>`
 * to `{ href, name, image }`; `image(src, attrs)` may return a replacement
 * `src` for `<img>` (for example a saved copy of a data: URI).
 */
function htmlToMarkdown(html, options = {}) {
  const converter = new Converter(options);
  return finish(converter.node(parseHtml(html), true));
}

module.exports = { htmlToMarkdown, parseHtml, decodeEntities };
