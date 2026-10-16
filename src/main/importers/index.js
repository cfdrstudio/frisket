'use strict';

/**
 * Import notes from other apps into a library. Every source is read into a
 * common shape, then written the same way:
 *
 *   Imported/<Source> YYYY-MM-DD/<folders…>/<Title>.md
 *   Assets/<frisket-id>/<attachment>
 *
 * with `frisket-id`, `frisket-created`, `frisket-source` and `tags` in front
 * matter, links between imported pages rewritten to relative paths, and file
 * times taken from the source. Nothing outside those two folders is touched,
 * and existing files are never overwritten.
 */

const crypto = require('node:crypto');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { safeName, uniquePath } = require('../files');
const { htmlToMarkdown } = require('./html');
const { parseEnex, MIME_EXTENSIONS } = require('./enex');
const { readNotionExport } = require('./notion');
const { readAppleNotes } = require('./appleNotes');

const SOURCES = { evernote: 'Evernote', notion: 'Notion', 'apple-notes': 'Apple Notes' };
const MAX_ENEX_BYTES = 1024 * 1024 * 1024;

function localDate(now = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
}

function linkDestination(href) {
  return /[\s()<>]/.test(href) ? '<' + href.replace(/[<>]/g, encodeURIComponent) + '>' : href;
}

function relativeHref(fromFile, toFile) {
  return path.relative(path.dirname(fromFile), toFile).split(path.sep).join('/');
}

function decodeDataUri(uri) {
  const match = /^data:([\w.+-]+\/[\w.+-]+)?((?:;[\w-]+=[^;,]*)*)(;base64)?,([\s\S]*)$/i.exec(String(uri || ''));
  if (!match) return null;
  const mime = (match[1] || 'application/octet-stream').toLowerCase();
  let data;
  try { data = match[3] ? Buffer.from(match[4], 'base64') : Buffer.from(decodeURIComponent(match[4]), 'utf8'); } catch { return null; }
  return { mime, data };
}

/** Put the title first as an `# H1`, promoting a matching first line rather than repeating it. */
function withTitle(body, title) {
  const plain = (line) => line.replace(/^#{1,6}\s+/, '').replace(/[*_~=`\\]/g, '').trim().toLowerCase();
  const lines = body.split('\n');
  const first = lines.findIndex((line) => line.trim());
  if (first >= 0 && plain(lines[first]) === plain(title)) {
    lines[first] = '# ' + title;
    return lines.slice(first).join('\n');
  }
  return '# ' + title + (body.trim() ? '\n\n' + body : '');
}

function frontMatter({ id, created, kind, tags }) {
  const lines = ['---', 'frisket-id: ' + id, 'frisket-created: ' + (created || new Date().toISOString()), 'frisket-source: ' + kind];
  const clean = [...new Set((tags || []).map((tag) => String(tag).replace(/^#+/, '').trim()).filter(Boolean))];
  if (clean.length) lines.push('tags:', ...clean.map((tag) => '  - ' + JSON.stringify(tag)));
  lines.push('---', '', '');
  return lines.join('\n');
}

/** Read the source into `{ notes, skipped }` in the shared shape. */
async function collect(kind, source) {
  const skipped = [];
  if (kind === 'evernote') {
    const files = (Array.isArray(source) ? source : [source]).filter(Boolean);
    if (!files.length) throw new Error('Choose one or more .enex files.');
    const notes = [];
    for (const file of files) {
      const { size } = await fsp.stat(file);
      if (size > MAX_ENEX_BYTES) throw new Error(path.basename(file) + ' is larger than 1 GB; export the notebook in parts.');
      const notebook = path.basename(file, path.extname(file));
      parseEnex(await fsp.readFile(file, 'utf8')).forEach((note, i) => {
        notes.push({ ...note, key: file + '#' + i, folder: files.length > 1 ? [notebook] : [] });
      });
    }
    return { notes, skipped };
  }
  if (kind === 'notion') {
    if (!source || typeof source !== 'string') throw new Error('Choose a Notion export (.zip or folder).');
    const { tree, notes } = await readNotionExport(source);
    return { notes, skipped, tree };
  }
  if (kind === 'apple-notes') {
    const raw = await readAppleNotes();
    const accounts = new Set(raw.map((note) => note.account));
    const notes = [];
    raw.forEach((note, i) => {
      if (note.locked || note.body === null) { skipped.push({ title: note.name, reason: 'locked' }); return; }
      notes.push({
        key: 'apple-' + i, title: note.name || 'Untitled', html: note.body, created: note.created, updated: note.modified,
        tags: [], folder: accounts.size > 1 ? [note.account, note.folder] : [note.folder],
      });
    });
    return { notes, skipped };
  }
  throw new Error('Unknown import source: ' + kind);
}

/** Rewrite links in a Notion page to the imported pages and copied attachments. */
async function rewriteNotionLinks(note, byKey, tree, saveAsset) {
  const pattern = /(!?)\[([^\]\n]*)\]\((<[^>\n]+>|[^)\s]+)(\s+"[^"\n]*")?\)/g;
  const base = path.posix.dirname(note.key);
  const edits = [];
  let match;
  while ((match = pattern.exec(note.markdown))) {
    const raw = match[3].replace(/^<|>$/g, '');
    if (/^(?:[a-z][a-z0-9+.-]+:|#|\/\/)/i.test(raw)) continue;
    let decoded = raw;
    try { decoded = decodeURIComponent(raw); } catch { /* keep as written */ }
    const hash = decoded.indexOf('#');
    const file = hash < 0 ? decoded : decoded.slice(0, hash);
    const anchor = hash < 0 ? '' : decoded.slice(hash);
    const resolved = path.posix.normalize(base === '.' ? file : base + '/' + file);
    if (!resolved || resolved.startsWith('..')) continue;
    let href = null;
    const linked = byKey.get(resolved);
    if (linked) href = relativeHref(note.output, linked.output) + anchor;
    else if (tree.has(resolved)) href = saveAsset(path.posix.basename(resolved), await tree.get(resolved).read());
    if (!href) continue;
    edits.push({ at: match.index, length: match[0].length, text: match[1] + '[' + match[2] + '](' + linkDestination(href) + (match[4] || '') + ')' });
  }
  let out = note.markdown;
  for (const edit of edits.reverse()) out = out.slice(0, edit.at) + edit.text + out.slice(edit.at + edit.length);
  return out;
}

/**
 * Import `source` of `kind` ('evernote', 'notion', 'apple-notes') into the
 * library at `root`. Resolves with `{ folder, notes, attachments, skipped }`.
 */
async function runImport({ kind, source, root, date = localDate() }) {
  const label = SOURCES[kind];
  if (!label) throw new Error('Unknown import source: ' + kind);
  const { notes, skipped, tree } = await collect(kind, source);
  if (!notes.length) return { folder: null, notes: 0, attachments: 0, skipped };

  const importRoot = path.join(root, 'Imported');
  await fsp.mkdir(importRoot, { recursive: true });
  const destination = await uniquePath(importRoot, safeName(label + ' ' + date), '');
  await fsp.mkdir(destination);

  // Pass 1: decide every output path, so links between pages can point at them.
  const reserved = new Set();
  for (const note of notes) {
    note.id = crypto.randomUUID();
    const dir = path.join(destination, ...note.folder.map((part) => safeName(part)));
    await fsp.mkdir(dir, { recursive: true });
    note.output = await uniquePath(dir, safeName(note.fileStem || note.title), '.md', reserved);
  }
  const byKey = new Map(notes.map((note) => [note.key, note]));

  // Pass 2: convert, copy attachments, write.
  let attachments = 0;
  let written = 0;
  for (const note of notes) {
    const assetDir = path.join(root, 'Assets', note.id);
    const names = new Set();
    const pending = [];
    const saveAsset = (name, data) => {
      const ext = path.extname(name);
      const stem = safeName(path.basename(name, ext), 'attachment');
      let file = stem + ext;
      for (let n = 2; names.has(file.toLowerCase()); n++) file = stem + ' ' + n + ext;
      names.add(file.toLowerCase());
      const full = path.join(assetDir, file);
      pending.push({ full, data });
      return relativeHref(note.output, full);
    };
    let body;
    try {
      if (note.html !== undefined) {
        const used = new Set();
        let images = 0;
        body = htmlToMarkdown(note.html, {
          media: (hash) => {
            const resource = (note.resources || []).find((item) => item.hash === String(hash).toLowerCase());
            if (!resource) return null;
            used.add(resource);
            return { href: saveAsset(resource.name, resource.data), name: resource.name, image: resource.mime.startsWith('image/') };
          },
          image: (src) => {
            const decoded = decodeDataUri(src);
            if (!decoded) return null;
            return saveAsset('image-' + ++images + (MIME_EXTENSIONS[decoded.mime] || '.bin'), decoded.data);
          },
        });
        const extra = (note.resources || []).filter((resource) => !used.has(resource));
        if (extra.length) {
          body += '\n\n## Attachments\n\n' + extra.map((resource) =>
            '- [' + resource.name.replace(/[[\]]/g, '') + '](' + linkDestination(saveAsset(resource.name, resource.data)) + ')').join('\n');
        }
        body = withTitle(body, note.title);
      } else {
        body = await rewriteNotionLinks(note, byKey, tree, saveAsset);
        if (!/^#\s/m.test(body.split('\n').find((line) => line.trim()) || '')) body = withTitle(body, note.title);
      }
    } catch (err) {
      skipped.push({ title: note.title, reason: err.message });
      continue;
    }
    if (pending.length) {
      await fsp.mkdir(assetDir, { recursive: true });
      for (const asset of pending) await fsp.writeFile(asset.full, asset.data, { flag: 'wx' });
      attachments += pending.length;
    }
    await fsp.writeFile(note.output, frontMatter({ id: note.id, created: note.created, kind, tags: note.tags })
      + body.replace(/\s+$/, '') + '\n', { encoding: 'utf8', flag: 'wx' });
    const when = Date.parse(note.updated || note.created || '');
    if (Number.isFinite(when)) await fsp.utimes(note.output, new Date(), new Date(when)).catch(() => {});
    written++;
  }
  return { folder: path.relative(root, destination).split(path.sep).join('/'), notes: written, attachments, skipped };
}

module.exports = { runImport, withTitle, frontMatter, localDate, decodeDataUri, SOURCES };
