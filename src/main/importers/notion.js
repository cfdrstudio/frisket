'use strict';

/**
 * Notion "Markdown & CSV" export reader. Accepts the export .zip (including
 * the zip-of-zips Notion produces for large workspaces) or an extracted
 * folder, and returns a virtual file tree plus the pages and databases in it.
 * Notion appends a 32-character ID to every file and folder name; the
 * importer strips it and rewrites links accordingly.
 */

const fsp = require('node:fs/promises');
const path = require('node:path');
const { readZip } = require('./zip');

const MAX_ARCHIVE_BYTES = 1536 * 1024 * 1024;
const NOTION_ID = /\s+[0-9a-f]{32}$/i;
const EXPORT_WRAPPER = /^Export-[0-9a-f-]{8,}$/i;

/** A Notion name without its trailing ID: `Plan 0123…cdef` → `Plan`. */
function stripNotionId(stem) {
  const clean = String(stem).replace(NOTION_ID, '').trim();
  return clean || String(stem).trim();
}

async function readArchive(file) {
  const stat = await fsp.stat(file);
  if (stat.size > MAX_ARCHIVE_BYTES) {
    throw new Error('This export is too large to read in one go. Extract it, then import the folder.');
  }
  return readZip(await fsp.readFile(file));
}

/** Map of `relative/path` → `{ size, read() }` for a zip or a folder. */
async function loadTree(source) {
  const tree = new Map();
  const stat = await fsp.stat(source);
  if (stat.isDirectory()) {
    const walk = async (dir, prefix) => {
      for (const entry of await fsp.readdir(dir, { withFileTypes: true })) {
        if (entry.name.startsWith('.') || entry.isSymbolicLink()) continue;
        const full = path.join(dir, entry.name);
        const relative = prefix ? prefix + '/' + entry.name : entry.name;
        if (entry.isDirectory()) await walk(full, relative);
        else if (entry.isFile()) {
          const { size } = await fsp.stat(full);
          tree.set(relative, { size, read: () => fsp.readFile(full) });
        }
      }
    };
    await walk(source, '');
  } else {
    let entries = (await readArchive(source)).filter((entry) => !entry.isDirectory);
    // Large Notion exports are a zip of zips; read through one level.
    if (entries.length && entries.every((entry) => /\.zip$/i.test(entry.name))) {
      entries = entries.flatMap((entry) => readZip(entry.read()).filter((inner) => !inner.isDirectory));
    }
    for (const entry of entries) tree.set(entry.name, { size: entry.size, read: async () => entry.read() });
  }
  // Drop Notion's single `Export-<uuid>` wrapper folder.
  const tops = new Set([...tree.keys()].map((key) => key.split('/')[0]));
  if (tops.size === 1) {
    const [top] = tops;
    if (EXPORT_WRAPPER.test(top) && [...tree.keys()].every((key) => key.includes('/'))) {
      const unwrapped = new Map();
      for (const [key, value] of tree) unwrapped.set(key.slice(top.length + 1), value);
      return unwrapped;
    }
  }
  return tree;
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (quoted) {
      if (char === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (char === '"') quoted = false;
      else field += char;
    } else if (char === '"') quoted = true;
    else if (char === ',') { row.push(field); field = ''; }
    else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[i + 1] === '\n') i++;
      row.push(field); rows.push(row); row = []; field = '';
    } else field += char;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  return rows.filter((cells) => cells.some((cell) => cell.trim()));
}

function csvToMarkdownTable(text) {
  const rows = parseCsv(text.replace(/^﻿/, ''));
  if (!rows.length) return '';
  const width = Math.max(...rows.map((cells) => cells.length));
  const cell = (value) => String(value ?? '').replace(/\r?\n/g, '<br>').replace(/\|/g, '\\|').trim() || ' ';
  const line = (cells) => '| ' + Array.from({ length: width }, (_, i) => cell(cells[i])).join(' | ') + ' |';
  return [line(rows[0]), '| ' + Array(width).fill('---').join(' | ') + ' |', ...rows.slice(1).map(line)].join('\n');
}

/**
 * Read a Notion export. Returns `{ tree, notes }` where each note has
 * `{ key, title, folder, markdown, isDatabase }` and `key` is its path in the
 * export, which the writer uses to rewrite links between pages.
 */
async function readNotionExport(source) {
  const tree = await loadTree(source);
  const notes = [];
  const keys = [...tree.keys()].sort();
  for (const key of keys) {
    const ext = path.posix.extname(key).toLowerCase();
    if (ext !== '.md' && ext !== '.csv') continue;
    if (ext === '.csv' && /_all\.csv$/i.test(key) && tree.has(key.replace(/_all\.csv$/i, '.csv'))) continue;
    const dir = path.posix.dirname(key);
    const folder = dir === '.' ? [] : dir.split('/').map(stripNotionId);
    const stem = stripNotionId(path.posix.basename(key, path.posix.extname(key)).replace(/_all$/i, ''));
    const text = (await tree.get(key).read()).toString('utf8').replace(/^﻿/, '');
    if (ext === '.csv') {
      const table = csvToMarkdownTable(text);
      if (table) notes.push({ key, title: stem, folder, markdown: '# ' + stem + '\n\n' + table + '\n', isDatabase: true });
      continue;
    }
    const heading = /^#\s+(.+?)\s*$/m.exec(text);
    notes.push({ key, title: heading ? heading[1] : stem, fileStem: stem, folder, markdown: text });
  }
  return { tree, notes };
}

module.exports = { readNotionExport, stripNotionId, csvToMarkdownTable, parseCsv, loadTree };
