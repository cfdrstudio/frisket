'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');

const MARKDOWN_EXTENSIONS = new Set(['.md', '.markdown', '.mdown', '.mkd', '.mdx', '.txt']);
const IGNORED_DIRS = new Set(['.git', 'node_modules', '.obsidian', '.vscode', '$RECYCLE.BIN', 'System Volume Information']);
const MAX_DEPTH = 6;
const MAX_FILES = 2000;
const MAX_FILE_BYTES = 4 * 1024 * 1024;
const MAX_TOTAL_BYTES = 64 * 1024 * 1024;
const FRONT_MATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;

function isMarkdown(file) {
  return MARKDOWN_EXTENSIONS.has(path.extname(file).toLowerCase());
}

function inside(root, candidate) {
  const rel = path.relative(root, candidate);
  return rel === '' || (!path.isAbsolute(rel) && rel !== '..' && !rel.startsWith('..' + path.sep));
}

function normalizedPath(file) {
  const resolved = path.resolve(file);
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
}

function splitFrontMatter(text) {
  const match = FRONT_MATTER.exec(text);
  return match
    ? { metaText: match[1], body: text.slice(match[0].length) }
    : { metaText: '', body: text };
}

function scalar(value) {
  const text = value.trim();
  if (!text || text === 'null' || text === '~') return null;
  if ((text.startsWith('"') && text.endsWith('"')) || (text.startsWith("'") && text.endsWith("'"))) {
    return text.slice(1, -1).replace(text.startsWith('"') ? /\\(["\\])/g : /''/g, text.startsWith('"') ? '$1' : "'");
  }
  if (/^(true|false)$/i.test(text)) return text.toLowerCase() === 'true';
  if (/^-?(?:\d+\.?\d*|\.\d+)$/.test(text)) return Number(text);
  return text.replace(/\s+#.*$/, '').trim();
}

function splitInlineList(value) {
  const body = value.trim().replace(/^\[/, '').replace(/\]$/, '');
  const items = [];
  let current = '';
  let quote = null;
  for (let i = 0; i < body.length; i++) {
    const char = body[i];
    if (quote) {
      current += char;
      if (char === quote && body[i - 1] !== '\\') quote = null;
    } else if (char === '"' || char === "'") {
      quote = char;
      current += char;
    } else if (char === ',') {
      if (current.trim()) items.push(current.trim());
      current = '';
    } else current += char;
  }
  if (current.trim()) items.push(current.trim());
  return items.map((item) => scalar(item)).filter((item) => item !== null && item !== '');
}

function parseFrontMatter(metaText) {
  const properties = {};
  const tags = [];
  let listKey = null;
  for (const line of metaText.split(/\r?\n/)) {
    const listItem = /^\s+-\s+(.+?)\s*$/.exec(line);
    if (listItem && listKey) {
      const item = scalar(listItem[1]);
      if (item !== null && item !== '') {
        if (listKey === 'tags') tags.push(String(item).replace(/^#/, ''));
        else if (Array.isArray(properties[listKey])) properties[listKey].push(item);
      }
      continue;
    }
    const field = /^([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$/.exec(line);
    if (!field) { listKey = null; continue; }
    const key = field[1];
    const value = field[2];
    listKey = null;
    if (key === 'tags') {
      if (value.startsWith('[')) tags.push(...splitInlineList(value).map(String).map((tag) => tag.replace(/^#/, '')));
      else if (value) {
        tags.push(...value.split(',').map((tag) => String(scalar(tag)).replace(/^#/, '')).filter(Boolean));
      } else listKey = key;
      continue;
    }
    if (!value) { properties[key] = []; listKey = key; continue; }
    if (value.startsWith('[') && value.endsWith(']')) { properties[key] = splitInlineList(value); continue; }
    const parsed = scalar(value);
    if (parsed !== null) properties[key] = parsed;
  }
  const seen = new Set();
  return { properties, tags: tags.map((tag) => String(tag).trim().replace(/^#|#$/g, ''))
    .filter((tag) => {
      const key = tag.normalize('NFC').toLowerCase();
      if (!tag || seen.has(key)) return false;
      seen.add(key);
      return true;
    }) };
}

/** Comparison key for names, titles and aliases: Unicode- and case-insensitive. */
function nameKey(value) {
  return String(value || '').normalize('NFC').trim().replace(/\s+/g, ' ').toLowerCase();
}

/** Front-matter `aliases` (or `alias`) as a list of display strings. */
function aliasesOf(properties = {}) {
  const raw = properties.aliases ?? properties.alias;
  const list = Array.isArray(raw) ? raw : (typeof raw === 'string' ? raw.split(',') : []);
  return list.map((item) => String(item ?? '').trim()).filter(Boolean);
}

function isTrashed(note) {
  return !!(note && (note.trashedAt || (note.properties && note.properties['frisket-trashed-at'])));
}

/**
 * Set a top-level front-matter key to a scalar `value`, or remove it when
 * `value` is null. Every other line, the line endings and the body are kept
 * exactly; a list or block value under the key is removed with it. Removing
 * the only key drops a front-matter block that holds nothing else.
 */
function setFrontMatterValue(text, key, value) {
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  const match = /^---\r?\n([\s\S]*?)\r?\n---(\r?\n|$)/.exec(text);
  const keyLine = new RegExp('^' + key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*:');
  const line = value === null || value === undefined ? null : key + ': ' + value;
  if (!match) {
    return line ? '---' + newline + line + newline + '---' + newline + newline + text : text;
  }
  const lines = match[1].split(/\r?\n/);
  const kept = [];
  for (let i = 0; i < lines.length; i++) {
    if (!keyLine.test(lines[i])) { kept.push(lines[i]); continue; }
    while (i + 1 < lines.length && /^(?:\s+\S|\s*-\s)/.test(lines[i + 1])) i++;
  }
  if (line) kept.push(line);
  const rest = text.slice(match[0].length);
  if (!kept.some((item) => item.trim())) return rest.replace(/^\r?\n/, '');
  return '---' + newline + kept.join(newline) + newline + '---' + (match[2] || newline) + rest;
}

function noteTitle(text, fallback, properties) {
  if (typeof properties.title === 'string' && properties.title.trim()) return properties.title.trim();
  const { body } = splitFrontMatter(text);
  const heading = /^#\s+(.+)$/m.exec(body);
  return heading ? heading[1].trim() : fallback;
}

function maskCode(body) {
  let fence = null;
  return body.split('\n').map((line) => {
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (fence) {
      if (marker && marker[1][0] === fence.char && marker[1].length >= fence.length) fence = null;
      return ' '.repeat(line.length);
    }
    if (marker) { fence = { char: marker[1][0], length: marker[1].length }; return ' '.repeat(line.length); }
    if (/^ {4}/.test(line)) return ' '.repeat(line.length);
    return line.replace(/(`+)(?!`)[^`\n]*?\1(?!`)/g, (match) => ' '.repeat(match.length));
  }).join('\n');
}

function maskRange(text, pattern) {
  return text.replace(pattern, (match) => ' '.repeat(match.length));
}

/** Mask non-prose regions while keeping offsets and line boundaries intact. */
function maskNonProse(body) {
  let text = maskCode(body);
  text = maskRange(text, /\\#/g);
  text = maskRange(text, /^ {0,3}#{1,6}(?:\s|$)[^\n]*/gm);
  text = maskRange(text, /<[^>]*>/g);
  text = maskRange(text, /(?:https?:\/\/|ftp:\/\/|www\.)[^\s<>()]+/gi);
  return text;
}

function extractInlineTags(body) {
  const text = maskNonProse(body);
  const tags = [];
  const matcher = /(?:^|[^\p{L}\p{N}_/])#([\p{L}\p{N}_-]+(?:\/[\p{L}\p{N}_-]+)*)(#?)(?![\p{L}\p{N}_/-])/gu;
  let match;
  while ((match = matcher.exec(text))) tags.push(match[1]);
  return tags;
}

function uniqueTags(tags) {
  const seen = new Set();
  return tags.map((tag) => String(tag || '').trim().replace(/^#|#$/g, ''))
    .filter((tag) => {
      const key = tag.normalize('NFC').toLowerCase();
      if (!tag || seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function taskCounts(body) {
  const text = maskCode(body);
  let tasksDone = 0;
  let tasksTotal = 0;
  const task = /^\s*(?:[-+*]|\d+[.)])\s+\[([ xX])\]/gm;
  let match;
  while ((match = task.exec(text))) {
    tasksTotal++;
    if (match[1].toLowerCase() === 'x') tasksDone++;
  }
  return { tasksDone, tasksTotal };
}

function makeExcerpt(body) {
  const text = maskNonProse(body).split(/\r?\n/)
    .map((line) => line.replace(/^\s*(?:[-+*]|\d+[.)])\s+\[[ xX]\]\s*/, '')
      .replace(/^\s{0,3}(?:[-*_]\s*){3,}\s*$/, '')
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_all, target, label) => label || target)
      .replace(/(^|\s)[#>*_~`]+(?=\S)|[*_~`]+(?=\s|$)/g, '$1')
      .trim())
    .find(Boolean) || '';
  return text.length <= 180 ? text : `${text.slice(0, 177).trimEnd()}…`;
}

function isoDate(value, fallback) {
  const parsed = value instanceof Date ? value : new Date(value);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : new Date(fallback).toISOString();
}

function summaryFor(note) {
  const { body } = splitFrontMatter(note.text || '');
  const tags = uniqueTags([...(note.tags || []), ...extractInlineTags(body)]);
  const counts = taskCounts(body);
  const images = note.images || extractImages(note.text || '');
  const { properties = {} } = note;
  const stablePath = String(note.relative || note.path || note.name || '').replace(/\\/g, '/').normalize('NFC');
  const id = properties['frisket-id'] || properties.frisketId || `legacy-${crypto.createHash('sha256').update(stablePath).digest('hex').slice(0, 24)}`;
  const modified = note.mtime ?? Date.now();
  const createdAt = isoDate(properties['frisket-created'] ?? properties.frisketCreated, modified);
  const trashedAt = properties['frisket-trashed-at'] ?? properties.trashedAt ?? null;
  const cover = properties['frisket-cover'] ?? properties.frisketCover;
  const imagePreview = (typeof cover === 'string' && cover.trim()) ? cover.trim() : (images[0] || null);
  const prose = maskNonProse(body);
  const attachmentPattern = /(?<!!)\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))/g;
  let attachmentMatch;
  let hasAttachments = false;
  while ((attachmentMatch = attachmentPattern.exec(prose))) {
    const reference = attachmentMatch[1] || attachmentMatch[2] || '';
    if (!/^(?:[a-z][a-z0-9+.-]*:|\/\/|data:)/i.test(reference) && !/\.(?:png|jpe?g|gif|webp|svg|avif|bmp)(?:[?#]|$)/i.test(reference)) {
      hasAttachments = true;
      break;
    }
  }
  return {
    id: String(id), path: note.path, relative: note.relative, name: note.name, title: note.title,
    aliases: aliasesOf(properties),
    pinned: properties['frisket-pinned'] === true || properties['frisket-pinned'] === 'true',
    createdAt, modifiedAt: isoDate(modified, Date.now()), tags, excerpt: makeExcerpt(body), imagePreview,
    tasksDone: counts.tasksDone, tasksTotal: counts.tasksTotal, hasImages: images.length > 0,
    hasAttachments, trashedAt: trashedAt ? isoDate(trashedAt, modified) : null,
  };
}

/** Convert a scanned index to the stable, UI-safe NoteSummary contract. */
function summarizeNotes(index) {
  const notes = Array.isArray(index) ? index : (index && index.notes) || [];
  return notes.map(summaryFor);
}

function normalizedTag(tag) {
  return String(tag || '').trim().replace(/^#|#$/g, '').normalize('NFC').toLowerCase();
}

function isDescendantTag(noteTag, selectedTag) {
  const candidate = normalizedTag(noteTag);
  const selected = normalizedTag(selectedTag);
  return candidate === selected || candidate.startsWith(`${selected}/`);
}

/** Apply a sidebar filter: notes, untagged, todo, trash, or { type: 'tag', tag }. */
function filterLibraryNotes(index, filter = 'notes') {
  const notes = summarizeNotes(index);
  const kind = typeof filter === 'string' ? filter : (filter && (filter.type || filter.kind || (filter.tag ? 'tag' : null))) || 'notes';
  if (kind === 'trash') return notes.filter((note) => note.trashedAt);
  if (kind === 'untagged') return notes.filter((note) => !note.trashedAt && note.tags.length === 0);
  if (kind === 'todo') return notes.filter((note) => !note.trashedAt && note.tasksDone < note.tasksTotal);
  if (kind === 'tag') {
    const selected = typeof filter === 'object' ? filter.tag : '';
    return notes.filter((note) => !note.trashedAt && note.tags.some((tag) => isDescendantTag(tag, selected)));
  }
  return notes.filter((note) => !note.trashedAt);
}

/** Split a search into plain terms and the `#tag`, `@todo` and `@images` operators. */
function parseSearchQuery(query = '') {
  const raw = String(query || '').trim();
  const todo = /(?:^|\s)@todo(?=\s|$)/i.test(raw);
  const images = /(?:^|\s)@images(?=\s|$)/i.test(raw);
  const tags = [];
  const tagMatcher = /(?:^|\s)#([\p{L}\p{N}_-]+(?:\/[\p{L}\p{N}_-]+)*)(#?)(?=\s|$)/gu;
  let tagMatch;
  while ((tagMatch = tagMatcher.exec(raw))) tags.push(tagMatch[1]);
  const terms = raw.replace(/(?:^|\s)@(?:todo|images)(?=\s|$)/gi, ' ')
    .replace(/(?:^|\s)#[\p{L}\p{N}_-]+(?:\/[\p{L}\p{N}_-]+)*#?(?=\s|$)/gu, ' ')
    .trim().toLowerCase().split(/\s+/).filter(Boolean);
  return { terms, tags, todo, images };
}

/**
 * Where a search hit is in a note's text: the first plain term in the body,
 * else the first open task (`@todo`), tag, or image, else the first body line.
 * Returns `{ line, column, pos, length, text, snippetOffset }`; `pos` and
 * `line` (1-based) refer to the whole file.
 */
function findSearchMatch(text, { terms = [], tags = [], todo = false, images = false } = {}) {
  const source = String(text || '');
  const { body } = splitFrontMatter(source);
  const offset = source.length - body.length;
  const prose = maskNonProse(body);
  let at = -1;
  let length = 0;
  if (terms.length) {
    at = body.toLowerCase().indexOf(terms[0]);
    length = terms[0].length;
  }
  if (at < 0 && todo) {
    const task = /^\s*(?:[-+*]|\d+[.)])\s+\[ \]/m.exec(maskCode(body));
    if (task) { at = task.index + task[0].length - 3; length = 3; }
  }
  if (at < 0 && tags.length) {
    const escaped = tags[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const tag = new RegExp('#' + escaped, 'iu').exec(prose);
    if (tag) { at = tag.index; length = tag[0].length; }
  }
  if (at < 0 && images) {
    const image = /!\[/.exec(maskCode(body));
    if (image) { at = image.index; length = 2; }
  }
  if (at < 0) {
    const first = /\S/.exec(body);
    at = first ? first.index : 0;
    length = 0;
  }
  const lineStart = body.lastIndexOf('\n', at - 1) + 1;
  let lineEnd = body.indexOf('\n', at);
  if (lineEnd < 0) lineEnd = body.length;
  const line = body.slice(lineStart, lineEnd).replace(/\r$/, '');
  const column = at - lineStart;
  const long = line.length > 160;
  const snippetOffset = long ? Math.max(0, column - 40) : 0;
  const lineNumber = (source.slice(0, offset + lineStart).match(/\n/g) || []).length + 1;
  return {
    line: lineNumber, column, pos: offset + at, length,
    text: long ? line.slice(snippetOffset, column + 120) : line, snippetOffset,
  };
}

/**
 * Search title, filename, path, tags, and body with @todo, @images, and #tag
 * operators. Pass `summaries` (in the same order as the notes) to reuse them.
 * Trashed notes are left out unless `includeTrashed` is set.
 */
function searchLibrary(index, query = '', summaries = null, { includeTrashed = false } = {}) {
  const sourceNotes = Array.isArray(index) ? index : (index && index.notes) || [];
  const notes = summaries || summarizeNotes(sourceNotes);
  const sourceByPath = new Map(sourceNotes.map((note) => [note.path, note]));
  const { terms, tags, todo, images } = parseSearchQuery(query);
  return notes.filter((note) => {
    if (note.trashedAt && !includeTrashed) return false;
    if (todo && note.tasksDone >= note.tasksTotal) return false;
    if (images && !note.hasImages) return false;
    if (!tags.every((tag) => note.tags.some((candidate) => isDescendantTag(candidate, tag)))) return false;
    const body = sourceByPath.get(note.path)?.text || '';
    const haystack = [note.title, note.name, note.relative, ...note.tags, maskNonProse(splitFrontMatter(body).body)]
      .join(' ').toLowerCase();
    return terms.every((term) => haystack.includes(term));
  });
}

function referenceLabel(label) {
  return String(label || '').trim().replace(/\s+/g, ' ').toLowerCase();
}

function extractImages(text) {
  const { body } = splitFrontMatter(text);
  const searchable = maskCode(body);
  const refs = [];
  const pattern = /!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))/g;
  let match;
  while ((match = pattern.exec(searchable))) refs.push(match[1] || match[2]);
  const definitions = new Map();
  const definition = /^ {0,3}\[([^\]]+)\]:\s*(?:<([^>]+)>|([^\s]+))/gm;
  while ((match = definition.exec(searchable))) definitions.set(referenceLabel(match[1]), match[2] || match[3]);
  const fullReference = /!\[([^\]]*)\]\[([^\]]*)\]/g;
  while ((match = fullReference.exec(searchable))) {
    const source = definitions.get(referenceLabel(match[2] || match[1]));
    if (source) refs.push(source);
  }
  const shortcut = /!\[([^\]]+)\](?![\[(])/g;
  while ((match = shortcut.exec(searchable))) {
    const source = definitions.get(referenceLabel(match[1]));
    if (source) refs.push(source);
  }
  return [...new Set(refs)];
}

function extractLinks(text) {
  const { body } = splitFrontMatter(text);
  const searchable = maskCode(body);
  const links = [];
  const wiki = /\[\[([^\]]+)\]\]/g;
  let match;
  while ((match = wiki.exec(searchable))) {
    const raw = match[1].split('|', 1)[0].trim();
    if (raw) links.push({ target: raw, start: match.index, end: wiki.lastIndex, kind: 'wiki' });
  }
  // Exclude images from ordinary Markdown links and avoid matching nested parens.
  const markdown = /(?<!!)\[[^\]]*\]\(\s*(?:<([^>]+)>|((?:\\.|[^\s)])+))/g;
  while ((match = markdown.exec(searchable))) {
    const target = match[1] || match[2];
    if (target) links.push({ target: target.replace(/\\([()])/g, '$1'), start: match.index, end: markdown.lastIndex, kind: 'markdown' });
  }
  return { links, body };
}

const NOTE_EXTENSION = /\.(?:md|markdown|mdown|mkd|mdx|txt)$/i;

/** Split a raw link target into the note name and an optional `#anchor`. */
function parseLinkTarget(rawTarget) {
  const target = String(rawTarget || '').trim().replace(/^<|>$/g, '');
  // Two-letter minimum keeps `C:\notes\a.md` a path rather than a URL scheme.
  if (!target || /^(?:[a-z][a-z0-9+.-]+:|\/\/)/i.test(target)) return null;
  const hash = target.indexOf('#');
  const name = (hash < 0 ? target : target.slice(0, hash)).split('?', 1)[0].trim();
  const anchor = hash < 0 ? null : target.slice(hash + 1) || null;
  return { name, anchor };
}

function relativeKey(note) {
  return nameKey(String(note.relative || note.name || '').replace(/\\/g, '/').replace(NOTE_EXTENSION, ''));
}

/**
 * Resolve link targets against a set of notes. Tiers, first match wins:
 * path (relative to the linking note, then the library root), `frisket-id`,
 * file name, title, then front-matter aliases. A tier with several matches is
 * ambiguous and is never silently narrowed to one of them. Trashed notes are
 * only reported when nothing active matches.
 */
function createLinkResolver(notes, root = null) {
  const build = (list) => {
    const maps = { byPath: new Map(), byId: new Map(), byBase: new Map(), byTitle: new Map(), byAlias: new Map() };
    const add = (map, key, note) => {
      if (!key) return;
      const bucket = map.get(key);
      if (!bucket) map.set(key, [note]);
      else if (!bucket.includes(note)) bucket.push(note);
    };
    for (const note of list) {
      maps.byPath.set(normalizedPath(note.path), note);
      const id = note.properties && note.properties['frisket-id'];
      if (id) add(maps.byId, String(id).trim(), note);
      add(maps.byBase, nameKey(path.basename(note.path).replace(NOTE_EXTENSION, '')), note);
      add(maps.byTitle, nameKey(note.title), note);
      for (const alias of aliasesOf(note.properties)) add(maps.byAlias, nameKey(alias), note);
    }
    return maps;
  };
  const active = build(notes.filter((note) => !isTrashed(note)));
  const trashed = build(notes.filter(isTrashed));

  function lookup(maps, sourcePath, name) {
    const candidates = [];
    if (path.isAbsolute(name)) candidates.push(name);
    else {
      if (sourcePath) candidates.push(path.resolve(path.dirname(sourcePath), name));
      if (root) candidates.push(path.resolve(root, name));
    }
    for (const candidate of candidates) {
      // Always try both: a title such as "Mr. Smith" looks like it has an extension.
      for (const option of [candidate, candidate + '.md']) {
        const hit = maps.byPath.get(normalizedPath(option));
        if (hit) return [hit];
      }
    }
    const id = maps.byId.get(name.trim());
    if (id) return id;
    const pathLike = /[\\/]/.test(name);
    const plain = name.replace(/\\/g, '/').replace(NOTE_EXTENSION, '');
    const base = maps.byBase.get(nameKey(plain.split('/').pop()));
    if (base) {
      if (!pathLike) return base;
      // `folder/Note` must match the end of the note's path, not just its name.
      const suffix = nameKey(plain.replace(/^(?:\.{1,2}\/)+/, ''));
      const narrowed = base.filter((note) => {
        const key = relativeKey(note);
        return key === suffix || key.endsWith('/' + suffix);
      });
      if (narrowed.length) return narrowed;
    }
    const title = maps.byTitle.get(nameKey(name));
    if (title) return title;
    return maps.byAlias.get(nameKey(name)) || [];
  }

  function resolve(sourcePath, rawTarget) {
    const parsed = parseLinkTarget(rawTarget);
    if (!parsed) return { external: true };
    const { name, anchor } = parsed;
    if (!name) return { anchorOnly: true, anchor };
    const names = [name];
    try {
      const decoded = decodeURIComponent(name);
      if (decoded !== name) names.push(decoded);
    } catch { /* keep malformed percent sequences as typed */ }
    for (const candidate of names) {
      const hits = lookup(active, sourcePath, candidate);
      if (hits.length === 1) return { note: hits[0], anchor };
      if (hits.length > 1) return { ambiguous: hits, anchor };
    }
    let inTrash = null;
    for (const candidate of names) {
      const hits = lookup(trashed, sourcePath, candidate);
      if (hits.length) { inTrash = hits[0]; break; }
    }
    return { missing: true, name, anchor, trashed: inTrash };
  }

  /** The shortest wiki-link target that resolves uniquely to `note` from anywhere. */
  function linkTextFor(note) {
    if (!note || isTrashed(note)) return null;
    const unique = (text) => {
      if (!text || /[[\]|#^]/.test(text)) return false;
      const hits = lookup(active, null, text);
      return hits.length === 1 && hits[0] === note;
    };
    if (unique(note.title)) return note.title;
    const base = path.basename(note.path).replace(NOTE_EXTENSION, '');
    if (unique(base)) return base;
    return String(note.relative || base).replace(/\\/g, '/').replace(NOTE_EXTENSION, '');
  }

  return { resolve, linkTextFor };
}

/**
 * Rewrite the target of matching `[[wiki-links]]`, keeping any `#anchor` and
 * `|alias`. Links in code and front matter are left alone. When `alias` is
 * given it is added to links that had none, so the visible text stays readable.
 */
function rewriteWikiLinks(text, matchesName, replacement, alias = null) {
  const { body } = splitFrontMatter(text);
  const offset = text.length - body.length;
  const masked = maskCode(body);
  const pattern = /\[\[([^\]\n]+)\]\]/g;
  const edits = [];
  let match;
  while ((match = pattern.exec(masked))) {
    const innerStart = match.index + 2;
    const inner = body.slice(innerStart, innerStart + match[1].length);
    const bar = inner.indexOf('|');
    const targetPart = bar < 0 ? inner : inner.slice(0, bar);
    const hash = targetPart.indexOf('#');
    const name = (hash < 0 ? targetPart : targetPart.slice(0, hash)).trim();
    if (!name || !matchesName(name)) continue;
    const rest = (hash < 0 ? '' : targetPart.slice(hash))
      + (bar < 0 ? (alias ? '|' + alias : '') : inner.slice(bar));
    edits.push({ from: offset + innerStart, to: offset + innerStart + inner.length, insert: replacement + rest });
  }
  let out = text;
  for (const edit of edits.reverse()) out = out.slice(0, edit.from) + edit.insert + out.slice(edit.to);
  return { text: out, count: edits.length };
}

function excerptAt(text, pos, termLength = 0) {
  const lineStart = text.lastIndexOf('\n', Math.max(0, pos - 1)) + 1;
  let lineEnd = text.indexOf('\n', pos + termLength);
  if (lineEnd < 0) lineEnd = text.length;
  const line = text.slice(lineStart, lineEnd).trim();
  if (line.length <= 180) return line;
  const offset = Math.max(0, pos - lineStart - 65);
  return (offset ? '…' : '') + line.slice(offset, offset + 150).trim() + (offset + 150 < line.length ? '…' : '');
}

/** Parse one Markdown file into the record shared by the scan and the live index. */
function parseNote({ file, root, text, mtime }) {
  const { metaText, body } = splitFrontMatter(text);
  const { properties, tags: frontmatterTags } = parseFrontMatter(metaText);
  return {
    path: file,
    relative: path.relative(root, file),
    name: path.basename(file),
    title: noteTitle(text, path.basename(file).replace(/\.[^.]+$/, ''), properties),
    tags: uniqueTags([...frontmatterTags, ...extractInlineTags(body)]),
    properties,
    links: extractLinks(text).links.map((link) => link.target),
    images: extractImages(text),
    mtime,
    text,
  };
}

/**
 * Collect Markdown files under `root` in a stable order, skipping hidden,
 * ignored and symlinked entries. `truncated` reports anything left out.
 */
async function walkMarkdown(root, { maxDepth, maxFiles }) {
  const files = [];
  let truncated = false;

  async function walk(dir, depth) {
    if (depth > maxDepth || files.length >= maxFiles) {
      truncated = true;
      return;
    }
    let entries;
    try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return; }
    entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    for (const entry of entries) {
      if (entry.name.startsWith('.') || IGNORED_DIRS.has(entry.name) || entry.isSymbolicLink()) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (depth < maxDepth) await walk(full, depth + 1);
        else {
          try {
            if ((await fs.readdir(full)).length) truncated = true;
          } catch { /* inaccessible directories are omitted */ }
        }
      } else if (entry.isFile() && isMarkdown(entry.name)) {
        if (files.length >= maxFiles) { truncated = true; break; }
        files.push(full);
      }
      if (files.length >= maxFiles) {
        // Confirm whether there are more indexable files before reporting truncation.
        if (entry !== entries[entries.length - 1]) truncated = true;
        break;
      }
    }
  }
  await walk(root, 0);
  return { files, truncated };
}

/** Build a bounded, read-only index of the Markdown files under a folder. */
async function scanWorkspace(folder, options = {}) {
  if (typeof folder !== 'string' || !folder.trim()) throw new TypeError('A workspace folder is required');
  const root = await fs.realpath(path.resolve(folder));
  const maxDepth = Math.min(MAX_DEPTH, Math.max(0, Number.isInteger(options.maxDepth) ? options.maxDepth : MAX_DEPTH));
  const maxFiles = Math.min(MAX_FILES, Math.max(1, Number.isInteger(options.maxFiles) ? options.maxFiles : MAX_FILES));
  const maxBytes = Math.min(MAX_FILE_BYTES, Math.max(1, Number.isInteger(options.maxFileBytes) ? options.maxFileBytes : MAX_FILE_BYTES));
  const maxTotalBytes = Math.min(MAX_TOTAL_BYTES, Math.max(1, Number.isInteger(options.maxTotalBytes) ? options.maxTotalBytes : MAX_TOTAL_BYTES));
  const walked = await walkMarkdown(root, { maxDepth, maxFiles });
  let truncated = walked.truncated;

  const notes = [];
  let totalBytes = 0;
  for (const file of walked.files) {
    let stat;
    try { stat = await fs.stat(file); } catch { continue; }
    if (!stat.isFile()) continue;
    if (stat.size > maxBytes) { truncated = true; continue; }
    if (totalBytes + stat.size > maxTotalBytes) { truncated = true; continue; }
    let buffer;
    try { buffer = await fs.readFile(file); } catch { continue; }
    if (buffer.byteLength > maxBytes) { truncated = true; continue; }
    totalBytes += buffer.byteLength;
    notes.push(parseNote({ file, root, text: buffer.toString('utf8'), mtime: stat.mtimeMs }));
  }
  return { notes, truncated, root };
}

function rootOf(index, notes) {
  if (index && index.root) return index.root;
  const sample = notes[0];
  if (!sample || !sample.relative) return null;
  const relativeDir = path.dirname(sample.relative);
  const parents = relativeDir === '.' ? [] : relativeDir.split(/[\\/]+/).map(() => '..');
  return path.resolve(path.dirname(sample.path), ...parents);
}

/**
 * Return notes linking to a target and notes mentioning it without a link.
 * Pass the library's cached `resolver` to avoid rebuilding it; either way the
 * cost is linear in the number of notes and links.
 */
function getBacklinks(index, targetPath, resolver = null) {
  const notes = Array.isArray(index) ? index : (index && index.notes) || [];
  const target = notes.find((note) => normalizedPath(note.path) === normalizedPath(targetPath));
  if (!target || isTrashed(target)) return { linked: [], unlinked: [] };
  const linkResolver = resolver || createLinkResolver(notes, rootOf(index, notes));
  const linked = [];
  const unlinked = [];
  const name = path.basename(target.path).replace(/\.[^.]+$/, '');
  const terms = [...new Set([name, target.title, ...aliasesOf(target.properties)]
    .filter((term) => term && term.trim()).map((term) => term.trim()))]
    .sort((a, b) => b.length - a.length)
    .map((term) => ({ term, matcher: new RegExp(term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu') }));
  const wordChar = /[\p{L}\p{N}_]/u;

  for (const note of notes) {
    if (note === target || isTrashed(note)) continue;
    const { links, body } = extractLinks(note.text || '');
    const bodyOffset = (note.text || '').length - body.length;
    const linkedSpans = [];
    for (const link of links) {
      const result = linkResolver.resolve(note.path, link.target);
      const ambiguous = !!(result.ambiguous && result.ambiguous.includes(target));
      if (result.note === target || ambiguous) {
        linkedSpans.push([link.start, link.end]);
        linked.push({ path: note.path, title: note.title, relative: note.relative, pos: bodyOffset + link.start,
          excerpt: excerptAt(body, link.start, link.end - link.start), ...(ambiguous ? { ambiguous: true } : {}) });
      }
    }
    const plain = maskCode(body);
    const mentionSpans = [];
    for (const { term, matcher } of terms) {
      matcher.lastIndex = 0;
      let match;
      while ((match = matcher.exec(plain))) {
        const start = match.index;
        const end = start + match[0].length;
        if (wordChar.test(term[0]) && start > 0 && wordChar.test(plain[start - 1])) continue;
        if (wordChar.test(term[term.length - 1]) && end < plain.length && wordChar.test(plain[end])) continue;
        if (linkedSpans.some(([left, right]) => start < right && end > left)) continue;
        // Suppress matches inside any Markdown link syntax, even when that link points elsewhere.
        if (links.some((link) => start < link.end && end > link.start)) continue;
        if (mentionSpans.some(([left, right]) => start < right && end > left)) continue;
        mentionSpans.push([start, end]);
        unlinked.push({ path: note.path, title: note.title, relative: note.relative, pos: bodyOffset + start,
          length: match[0].length, text: match[0], excerpt: excerptAt(plain, start, match[0].length) });
      }
    }
  }
  linked.sort((a, b) => a.relative.localeCompare(b.relative) || a.pos - b.pos);
  unlinked.sort((a, b) => a.relative.localeCompare(b.relative) || a.pos - b.pos);
  return { linked, unlinked };
}

function fuzzyScore(haystack, query) {
  const value = haystack.toLowerCase();
  const needle = query.toLowerCase();
  const at = value.indexOf(needle);
  if (at >= 0) return at === 0 ? 1000 + needle.length : 700 + needle.length - at;
  let cursor = 0;
  let score = 0;
  let run = 0;
  for (const char of needle) {
    const found = value.indexOf(char, cursor);
    if (found < 0) return -1;
    if (found === cursor) { run++; score += 12 + run * 2; }
    else { run = 0; score += Math.max(1, 8 - (found - cursor)); }
    cursor = found + 1;
  }
  return score;
}

/** Fuzzy title, filename, and path search for a quick-open list. */
function filterNotes(index, query) {
  const notes = Array.isArray(index) ? index : (index && index.notes) || [];
  const needle = String(query || '').trim();
  if (!needle) return [...notes].sort((a, b) => a.title.localeCompare(b.title) || a.relative.localeCompare(b.relative));
  return notes.map((note) => {
    const fields = [note.name, note.title, note.relative];
    const score = Math.max(...fields.map((field) => fuzzyScore(String(field || ''), needle)));
    return { note, score };
  }).filter((item) => item.score >= 0)
    .sort((a, b) => b.score - a.score || a.note.title.localeCompare(b.note.title) || a.note.relative.localeCompare(b.note.relative))
    .map((item) => item.note);
}

function getTags(index) {
  const notes = Array.isArray(index) ? index : (index && index.notes) || [];
  const counts = new Map();
  for (const note of notes) {
    const perNote = new Map();
    for (const tag of uniqueTags(note.tags || [])) {
      const parts = String(tag).split('/').filter(Boolean);
      for (let level = 1; level <= parts.length; level++) {
        const ancestor = parts.slice(0, level).join('/');
        perNote.set(normalizedTag(ancestor), ancestor);
      }
    }
    for (const [key, tag] of perNote) {
      const current = counts.get(key);
      if (current) current.count++;
      else counts.set(key, { tag, count: 1 });
    }
  }
  return [...counts.values()].sort((a, b) => a.tag.localeCompare(b.tag, undefined, { sensitivity: 'base' }));
}

async function realpathWithin(root, candidate) {
  const realRoot = await fs.realpath(root);
  let existing = candidate;
  while (true) {
    try {
      const realExisting = await fs.realpath(existing);
      if (!inside(realRoot, realExisting)) return null;
      if (existing === candidate) return realExisting;
      return inside(realRoot, candidate) ? candidate : null;
    } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') return null;
      const parent = path.dirname(existing);
      if (parent === existing) return null;
      existing = parent;
    }
  }
}

/** Report local image files referenced by one note, without following paths outside its folder. */
async function inspectAttachments(index, targetPath) {
  const notes = Array.isArray(index) ? index : (index && index.notes) || [];
  const note = notes.find((item) => normalizedPath(item.path) === normalizedPath(targetPath));
  if (!note) return { referenced: [], missing: [] };
  const relativeDir = path.dirname(note.relative);
  const parentSegments = relativeDir === '.' ? [] : relativeDir.split(/[\\/]+/).map(() => '..');
  const root = (index && index.root) || path.resolve(path.dirname(note.path), ...parentSegments);
  const referenced = [];
  const missing = [];
  for (const reference of note.images || []) {
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|data:)/i.test(reference)) continue;
    let decoded = reference;
    try { decoded = decodeURIComponent(reference); } catch { /* retain original */ }
    const clean = decoded.split(/[?#]/, 1)[0];
    const candidate = path.resolve(path.dirname(note.path), clean);
    if (!inside(path.resolve(root), candidate)) {
      missing.push({ reference, path: candidate, reason: 'outside-workspace' });
      continue;
    }
    const safeCandidate = await realpathWithin(root, candidate);
    if (!safeCandidate) {
      missing.push({ reference, path: candidate });
      continue;
    }
    try {
      const stat = await fs.stat(safeCandidate);
      if (stat.isFile()) referenced.push({ reference, path: safeCandidate, size: stat.size });
      else missing.push({ reference, path: safeCandidate });
    } catch {
      missing.push({ reference, path: candidate });
    }
  }
  return { referenced, missing };
}

module.exports = {
  scanWorkspace, getBacklinks, filterNotes, getTags, inspectAttachments,
  summarizeNotes, filterLibraryNotes, searchLibrary,
  // Shared with the live library index.
  parseNote, walkMarkdown, summaryFor, createLinkResolver, rewriteWikiLinks, parseLinkTarget,
  extractLinks, isTrashed, nameKey, normalizedPath, isMarkdown, IGNORED_DIRS,
  splitFrontMatter, parseFrontMatter, setFrontMatterValue, noteTitle, parseSearchQuery, findSearchMatch,
  NOTE_EXTENSION,
};
