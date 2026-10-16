'use strict';

/**
 * The live library index. It keeps one parsed record per Markdown file and
 * re-reads only files whose size or modification time changed, so refreshing
 * after a save costs a directory walk rather than a full re-parse. Everything
 * derived from the records (summaries, tags, the link resolver, sync-conflict
 * copies) is rebuilt once per change and reused until the next one.
 *
 * No Electron imports: this runs inside a worker thread (indexWorker.js), in
 * the main process as a fallback (indexService.js), and under `node --test`.
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const workspace = require('./workspace');
const history = require('./history');
const { replaceFile, uniquePath } = require('./files');

const {
  parseNote, walkMarkdown, summaryFor, createLinkResolver, rewriteWikiLinks, parseLinkTarget,
  extractLinks, isTrashed, nameKey, normalizedPath, getTags, getBacklinks, inspectAttachments,
  searchLibrary, parseSearchQuery, findSearchMatch, setFrontMatterValue, IGNORED_DIRS, NOTE_EXTENSION,
} = workspace;

const DEFAULT_LIMITS = {
  maxDepth: 12,
  maxFiles: 10000,
  maxFileBytes: 4 * 1024 * 1024,
  maxTotalBytes: 96 * 1024 * 1024,
};
const STAT_BATCH = 64;
const READ_BATCH = 16;
const WATCH_DEBOUNCE_MS = 300;

/** True for watcher events that cannot change the index (hidden or ignored paths). */
function ignoredChange(relative) {
  const parts = String(relative).split(/[\\/]+/).filter(Boolean);
  if (!parts.length) return false;
  if (parts[0] === '.frisket') return parts[1] !== 'Trash';
  return parts.some((part) => part.startsWith('.') || IGNORED_DIRS.has(part));
}

async function inBatches(items, size, worker) {
  const results = [];
  for (let i = 0; i < items.length; i += size) {
    results.push(...await Promise.all(items.slice(i, i + size).map(worker)));
  }
  return results;
}

/**
 * Recognise the copies sync services make when two devices edit one file.
 * Returns `{ kind, base }` where `base` is the original file's name without
 * extension, or null for an ordinary name.
 */
function conflictCopyOf(name, hostname = os.hostname()) {
  let match = /^(.*?) \((?:[^()]*?['’]s )?conflicted copy(?: [^()]*)?\)$/i.exec(name);
  if (match) return { kind: 'conflicted-copy', base: match[1] };
  match = /^(.*)\.sync-conflict-\d{8}-\d{6}(?:-[A-Z0-9]{7})?$/.exec(name);
  if (match) return { kind: 'syncthing', base: match[1] };
  match = /^(.*)-((?:DESKTOP|LAPTOP)-[A-Z0-9]{4,})$/.exec(name);
  // OneDrive appends the device name; short names would match ordinary titles.
  const host = String(hostname || '').split('.')[0];
  if (!match && host.length >= 6) {
    match = new RegExp('^(.*)-' + host.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$', 'i').exec(name);
  }
  if (match && match[1]) return { kind: 'onedrive', base: match[1] };
  return null;
}

/** Of several notes sharing a `frisket-id`, the one most likely to be the original. */
function likelyOriginal(group) {
  const copyLike = (note) => / (?:\d+|copy(?: \d+)?)$|\(\d+\)$/i.test(path.basename(note.path).replace(NOTE_EXTENSION, ''));
  return [...group].sort((a, b) => Number(copyLike(a)) - Number(copyLike(b))
    || a.relative.length - b.relative.length
    || a.mtimeMs - b.mtimeMs
    || a.relative.localeCompare(b.relative))[0];
}

class LibraryIndex {
  constructor(root, limits = {}) {
    this.root = root;
    this.trashRoot = path.join(root, '.frisket', 'Trash');
    this.limits = { ...DEFAULT_LIMITS, ...limits };
    this.records = new Map();
    this.truncated = false;
    this.version = 0;
    this.loaded = false;
    this.watching = false;
    this.watcher = null;
    this.watchTimer = null;
    this.refreshing = null;
    this.again = false;
    this.derivedCache = null;
    // Notes whose title changed while other notes still link to the old title.
    this.titleChanges = new Map();
  }

  /** Bring the index up to date. Overlapping calls share one run. Resolves true if anything changed. */
  refresh() {
    if (this.refreshing) {
      this.again = true;
      return this.refreshing;
    }
    this.refreshing = (async () => {
      let changed = false;
      do {
        this.again = false;
        changed = (await this.refreshOnce()) || changed;
      } while (this.again);
      this.loaded = true;
      return changed;
    })().finally(() => { this.refreshing = null; });
    return this.refreshing;
  }

  async refreshOnce() {
    const { maxDepth, maxFiles, maxFileBytes, maxTotalBytes } = this.limits;
    const walked = await walkMarkdown(this.root, { maxDepth, maxFiles });
    let truncated = walked.truncated;
    const entries = walked.files.map((file) => ({ file, trashed: false }));
    try {
      const stat = await fsp.lstat(this.trashRoot);
      if (stat.isDirectory() && !stat.isSymbolicLink()) {
        const trash = await walkMarkdown(this.trashRoot, { maxDepth, maxFiles });
        truncated = truncated || trash.truncated;
        entries.push(...trash.files.map((file) => ({ file, trashed: true })));
      }
    } catch (err) {
      if (err.code !== 'ENOENT' && err.code !== 'ENOTDIR') throw err;
    }

    const stats = await inBatches(entries, STAT_BATCH, (entry) => fsp.stat(entry.file).catch(() => null));
    const seen = new Set();
    const toRead = [];
    let totalBytes = 0;
    entries.forEach((entry, i) => {
      const stat = stats[i];
      if (!stat || !stat.isFile()) return;
      if (stat.size > maxFileBytes || totalBytes + stat.size > maxTotalBytes) { truncated = true; return; }
      totalBytes += stat.size;
      const key = normalizedPath(entry.file);
      seen.add(key);
      const previous = this.records.get(key);
      if (previous && previous.mtimeMs === stat.mtimeMs && previous.size === stat.size
        && previous.inTrash === entry.trashed) return;
      toRead.push({ ...entry, stat, key, previous });
    });

    const updates = (await inBatches(toRead, READ_BATCH, async (item) => {
      let text;
      try { text = await fsp.readFile(item.file, 'utf8'); } catch { seen.delete(item.key); return null; }
      const record = parseNote({ file: item.file, root: this.root, text, mtime: item.stat.mtimeMs });
      record.mtimeMs = item.stat.mtimeMs;
      record.size = item.stat.size;
      record.inTrash = item.trashed;
      if (item.trashed) {
        record.properties = { ...record.properties, 'frisket-trashed-at': new Date(item.stat.mtimeMs).toISOString() };
      }
      return { key: item.key, previous: item.previous, next: record };
    })).filter(Boolean);
    const removed = [...this.records.keys()].filter((key) => !seen.has(key));

    if (!updates.length && !removed.length && truncated === this.truncated) return false;

    const renamed = updates.filter((update) => update.previous && !isTrashed(update.previous)
      && nameKey(update.previous.title) !== nameKey(update.next.title));
    if (renamed.length) this.trackTitleChanges(renamed);

    for (const update of updates) this.records.set(update.key, update.next);
    for (const key of removed) this.records.delete(key);
    this.truncated = truncated;
    this.version++;
    this.derivedCache = null;
    return true;
  }

  /**
   * Remember which notes linked to a note by its old title, using the resolver
   * from before the change. The first title is kept if it changes again, since
   * the links still use it.
   */
  trackTitleChanges(renamed) {
    const before = this.derived();
    for (const { key, previous, next } of renamed) {
      const existing = this.titleChanges.get(key);
      if (existing) { existing.to = next.title; continue; }
      const oldKey = nameKey(previous.title);
      const sources = [];
      for (const source of before.activeNotes) {
        if (source === previous || isTrashed(source)) continue;
        const linksHere = extractLinks(source.text || '').links.some((link) => {
          if (link.kind !== 'wiki') return false;
          const parsed = parseLinkTarget(link.target);
          return parsed && nameKey(parsed.name) === oldKey
            && before.resolver.resolve(source.path, link.target).note === previous;
        });
        if (linksHere) sources.push(source.path);
      }
      if (sources.length) this.titleChanges.set(key, { path: next.path, from: previous.title, to: next.title, sources });
    }
  }

  /** Sync-conflict copies among active notes, keyed by normalised path. */
  findConflicts(notes) {
    const conflicts = new Map();
    const active = notes.filter((note) => !isTrashed(note));
    const byPath = new Map(active.map((note) => [normalizedPath(note.path), note]));
    for (const note of active) {
      const name = path.basename(note.path);
      const ext = path.extname(name);
      const copy = conflictCopyOf(name.slice(0, name.length - ext.length));
      if (!copy) continue;
      const original = byPath.get(normalizedPath(path.join(path.dirname(note.path), copy.base + ext)));
      conflicts.set(normalizedPath(note.path), { kind: copy.kind, original: original ? original.path : null });
    }
    const byId = new Map();
    for (const note of active) {
      if (conflicts.has(normalizedPath(note.path))) continue;
      const id = note.properties && note.properties['frisket-id'];
      if (!id) continue;
      const group = byId.get(String(id)) || [];
      group.push(note);
      byId.set(String(id), group);
    }
    for (const group of byId.values()) {
      if (group.length < 2) continue;
      const original = likelyOriginal(group);
      for (const note of group) {
        if (note !== original) conflicts.set(normalizedPath(note.path), { kind: 'duplicate-id', original: original.path });
      }
    }
    return conflicts;
  }

  /** Summaries, tags, the resolver and conflicts for the current version, built once per change. */
  derived() {
    if (this.derivedCache && this.derivedCache.version === this.version) return this.derivedCache;
    const notes = [...this.records.values()]
      .sort((a, b) => a.relative.localeCompare(b.relative, undefined, { numeric: true }));
    const conflicts = this.findConflicts(notes);
    // Conflict copies stay out of links, tags and backlinks until resolved.
    const activeNotes = notes.filter((note) => !conflicts.has(normalizedPath(note.path)));
    const resolver = createLinkResolver(activeNotes, this.root);
    const summaries = notes.map((note) => {
      if (!note.summary) note.summary = summaryFor(note);
      const conflict = conflicts.get(normalizedPath(note.path)) || null;
      return { ...note.summary, linkText: conflict ? null : resolver.linkTextFor(note), conflict };
    });
    const tags = getTags({ notes: activeNotes.filter((note) => !isTrashed(note)) });
    this.derivedCache = { version: this.version, notes, activeNotes, conflicts, resolver, summaries, tags };
    return this.derivedCache;
  }

  async ensureFresh(refresh) {
    if (refresh || !this.loaded || !this.watching) await this.refresh();
  }

  record(notePath) {
    return notePath ? this.records.get(normalizedPath(notePath)) || null : null;
  }

  /** How many links still use a note's previous title, or null when none do. */
  titleChangeFor(notePath) {
    const key = normalizedPath(notePath);
    const change = this.titleChanges.get(key);
    if (!change) return null;
    const target = this.records.get(key);
    if (!target || isTrashed(target)) { this.titleChanges.delete(key); return null; }
    const { resolver } = this.derived();
    const fromKey = nameKey(change.from);
    let links = 0;
    const files = [];
    for (const sourcePath of change.sources) {
      const source = this.records.get(normalizedPath(sourcePath));
      if (!source || isTrashed(source)) continue;
      const stale = extractLinks(source.text || '').links.filter((link) => {
        if (link.kind !== 'wiki') return false;
        const parsed = parseLinkTarget(link.target);
        return parsed && nameKey(parsed.name) === fromKey && resolver.resolve(source.path, link.target).note !== target;
      }).length;
      if (stale) { links += stale; files.push(source.path); }
    }
    if (!links) { this.titleChanges.delete(key); return null; }
    change.to = target.title;
    return { path: target.path, from: change.from, to: target.title, links, files };
  }

  /** Everything about one note that is costly to compute: backlinks, attachments, properties. */
  async context(targetPath, { refresh = false } = {}) {
    await this.ensureFresh(refresh);
    const derived = this.derived();
    const target = this.record(targetPath);
    const empty = { linked: [], unlinked: [] };
    if (!target) {
      return { found: false, currentProperties: {}, backlinks: empty, attachments: { referenced: [], missing: [] }, titleChange: null };
    }
    return {
      found: true,
      path: target.path,
      title: target.title,
      linkText: derived.resolver.linkTextFor(target),
      currentProperties: target.properties,
      backlinks: getBacklinks({ notes: derived.activeNotes, root: this.root }, target.path, derived.resolver),
      attachments: await inspectAttachments({ notes: derived.notes, root: this.root }, target.path),
      titleChange: this.titleChangeFor(target.path),
    };
  }

  async overview(targetPath = null, { refresh = false } = {}) {
    await this.ensureFresh(refresh);
    const derived = this.derived();
    const context = targetPath ? await this.context(targetPath) : null;
    return {
      notes: derived.summaries,
      tags: derived.tags,
      conflicts: derived.conflicts.size,
      truncated: this.truncated,
      limits: { maxFiles: this.limits.maxFiles, maxDepth: this.limits.maxDepth, maxFileBytes: this.limits.maxFileBytes },
      version: this.version,
      currentProperties: context ? context.currentProperties : {},
      backlinks: context ? context.backlinks : { linked: [], unlinked: [] },
      attachments: context ? context.attachments : { referenced: [], missing: [] },
      titleChange: context ? context.titleChange : null,
    };
  }

  /** Search results with where each one matched, for the note list and the sidebar. */
  async search(query, { refresh = false, includeTrashed = false } = {}) {
    await this.ensureFresh(refresh);
    const derived = this.derived();
    const parsed = parseSearchQuery(query);
    const notes = searchLibrary({ notes: derived.notes }, query, derived.summaries, { includeTrashed })
      .filter((note) => !note.conflict)
      .map((note) => {
        const record = this.record(note.path);
        return { ...note, match: record ? findSearchMatch(record.text, parsed) : null };
      });
    return { notes, terms: parsed.terms, truncated: this.truncated };
  }

  /** Resolve a link from `sourcePath`. A miss triggers one refresh, in case the target was just created. */
  async resolveLink(target, sourcePath = null) {
    await this.ensureFresh(false);
    let result = this.derived().resolver.resolve(sourcePath, target);
    if (result.missing) {
      await this.refresh();
      result = this.derived().resolver.resolve(sourcePath, target);
    }
    const brief = (note) => ({ path: note.path, title: note.title, relative: note.relative });
    if (result.note) return { path: result.note.path, anchor: result.anchor };
    if (result.ambiguous) return { ambiguous: result.ambiguous.map(brief), anchor: result.anchor };
    if (result.anchorOnly) return { anchorOnly: true, anchor: result.anchor };
    if (result.external) return { external: true };
    return { missing: true, name: result.name, anchor: result.anchor, trashed: result.trashed ? brief(result.trashed) : null };
  }

  async titleChange(notePath, { refresh = false } = {}) {
    await this.ensureFresh(refresh);
    return this.titleChangeFor(notePath);
  }

  dismissTitleChange(notePath) {
    this.titleChanges.delete(normalizedPath(notePath));
    return { ok: true };
  }

  /**
   * Rewrite a note on disk through `transform(text)`, snapshotting the old
   * version first and refusing if the file changed in between.
   */
  async rewrite(file, transform) {
    const before = await fsp.stat(file);
    const text = await fsp.readFile(file, 'utf8');
    const next = transform(text);
    if (next === null || next === undefined || next === text) return false;
    await history.record(file, text, { libraryRoot: this.root, reason: 'before-change' });
    await replaceFile(file, next, before.mtimeMs);
    return true;
  }

  /** Point links that still use a note's old title at its current one. */
  async updateTitleLinks(notePath) {
    await this.refresh();
    const change = this.titleChangeFor(notePath);
    if (!change) return { links: 0, files: 0, skipped: [] };
    const target = this.record(notePath);
    const linkText = this.derived().resolver.linkTextFor(target) || target.title;
    const alias = linkText === target.title ? null : target.title;
    const fromKey = nameKey(change.from);
    let links = 0;
    let files = 0;
    const skipped = [];
    for (const file of change.files) {
      try {
        let count = 0;
        const changed = await this.rewrite(file, (text) => {
          const result = rewriteWikiLinks(text, (name) => nameKey(name) === fromKey, linkText, alias);
          count = result.count;
          return result.text;
        });
        if (changed) { links += count; files++; }
      } catch {
        skipped.push(file);
      }
    }
    if (!skipped.length) this.titleChanges.delete(normalizedPath(notePath));
    await this.refresh();
    return { links, files, skipped };
  }

  /** Turn an unlinked mention at `pos` in `sourcePath` into a wiki link to `targetPath`. */
  async linkMention(sourcePath, pos, length, expected, targetPath) {
    await this.refresh();
    const derived = this.derived();
    const source = this.record(sourcePath);
    const target = this.record(targetPath);
    if (!source || !target) throw new Error('That note is no longer in the library.');
    const plain = derived.resolver.resolve(source.path, expected).note === target;
    const linkText = derived.resolver.linkTextFor(target) || target.title;
    const link = plain ? '[[' + expected + ']]' : '[[' + linkText + '|' + expected + ']]';
    const changed = await this.rewrite(source.path, (text) => {
      if (text.slice(pos, pos + length) !== expected) throw new Error('The note changed; refresh and try again.');
      return text.slice(0, pos) + link + text.slice(pos + length);
    });
    await this.refresh();
    return { ok: changed, link };
  }

  /** Set or clear `frisket-pinned` on a note. */
  async setPinned(notePath, pinned) {
    await this.ensureFresh(false);
    const note = this.record(notePath);
    if (!note || note.inTrash) throw new Error('Only notes in this library can be pinned.');
    await this.rewrite(note.path, (text) => setFrontMatterValue(text, 'frisket-pinned', pinned ? 'true' : null));
    await this.refresh();
    return { ok: true, pinned: !!pinned };
  }

  /**
   * Resolve a sync-conflict copy. `keep-original` moves the copy to Trash;
   * `keep-copy` writes the copy's text over the original (snapshotted first)
   * and trashes the copy; `keep-both` makes the copy an ordinary note.
   */
  async resolveConflict(copyPath, action) {
    await this.refresh();
    const derived = this.derived();
    const copy = this.record(copyPath);
    const conflict = copy && derived.conflicts.get(normalizedPath(copy.path));
    if (!conflict) throw new Error('That note is no longer a conflict copy.');
    const original = conflict.original ? this.record(conflict.original) : null;
    const trash = (text) => setFrontMatterValue(text, 'frisket-trashed-at', new Date().toISOString());
    let result = { ok: true, path: original ? original.path : copy.path };

    if (action === 'keep-original') {
      await this.rewrite(copy.path, trash);
    } else if (action === 'keep-copy') {
      if (!original) throw new Error('The original note is missing; keep both instead.');
      const copyText = await fsp.readFile(copy.path, 'utf8');
      await this.rewrite(original.path, () => copyText);
      await this.rewrite(copy.path, trash);
    } else if (action === 'keep-both') {
      const freshId = (text) => setFrontMatterValue(text, 'frisket-id', crypto.randomUUID());
      const needsId = !!(original && copy.properties && copy.properties['frisket-id']
        && copy.properties['frisket-id'] === (original.properties || {})['frisket-id']);
      if (needsId || conflict.kind === 'duplicate-id') await this.rewrite(copy.path, freshId);
      if (conflict.kind !== 'duplicate-id') {
        const ext = path.extname(copy.path);
        const base = conflictCopyOf(path.basename(copy.path, ext)).base;
        const target = await uniquePath(path.dirname(copy.path), base + ' (copy)', ext);
        await fsp.rename(copy.path, target);
        result = { ok: true, path: target };
      } else {
        result = { ok: true, path: copy.path };
      }
    } else {
      throw new Error('Unknown conflict action: ' + action);
    }
    await this.refresh();
    return result;
  }

  /** Import notes from another app into this library; see importers/index.js. */
  async importNotes(kind, source, options = {}) {
    const { runImport } = require('./importers');
    const report = await runImport({ kind, source, root: this.root, ...options });
    await this.refresh();
    return report;
  }

  /** Watch the library; `onChange` runs after a change has been indexed. */
  watch(onChange) {
    if (this.watcher) return this.watching;
    try {
      this.watcher = fs.watch(this.root, { recursive: true }, (_event, filename) => {
        if (filename && ignoredChange(filename)) return;
        clearTimeout(this.watchTimer);
        this.watchTimer = setTimeout(() => {
          this.refresh().then((changed) => { if (changed) onChange(this.version); }).catch(() => {});
        }, WATCH_DEBOUNCE_MS);
      });
      this.watcher.on('error', () => this.unwatch());
      this.watching = true;
    } catch {
      // Recursive watching is unavailable here; requests then refresh on demand.
      this.watcher = null;
      this.watching = false;
    }
    return this.watching;
  }

  unwatch() {
    clearTimeout(this.watchTimer);
    if (this.watcher) { try { this.watcher.close(); } catch { /* already closed */ } }
    this.watcher = null;
    this.watching = false;
  }

  close() { this.unwatch(); }
}

const OPERATIONS = new Set([
  'overview', 'context', 'search', 'resolveLink', 'titleChange', 'dismissTitleChange', 'updateTitleLinks',
  'linkMention', 'setPinned', 'resolveConflict', 'importNotes',
]);

/** Owns the indexes for recently used libraries and dispatches requests to them. */
class IndexHost {
  constructor({ onChanged = () => {}, limits = {}, maxIndexes = 4, watch = true } = {}) {
    this.onChanged = onChanged;
    this.limits = limits;
    this.maxIndexes = maxIndexes;
    this.shouldWatch = watch;
    this.indexes = new Map();
  }

  async indexFor(folder) {
    if (typeof folder !== 'string' || !folder.trim()) throw new Error('Choose a library folder first.');
    const root = await fsp.realpath(path.resolve(folder));
    if (!(await fsp.stat(root)).isDirectory()) throw new Error('The library must be a folder.');
    const key = normalizedPath(root);
    let index = this.indexes.get(key);
    if (index) {
      // Re-insert so the map stays in least-recently-used order.
      this.indexes.delete(key);
    } else {
      index = new LibraryIndex(root, this.limits);
      if (this.shouldWatch) index.watch(() => this.onChanged(folder, root));
    }
    this.indexes.set(key, index);
    while (this.indexes.size > this.maxIndexes) {
      const [oldestKey, oldest] = this.indexes.entries().next().value;
      oldest.close();
      this.indexes.delete(oldestKey);
    }
    return index;
  }

  async handle(op, folder, args = []) {
    if (!OPERATIONS.has(op)) throw new Error('Unsupported library index operation: ' + op);
    const index = await this.indexFor(folder);
    return index[op](...args);
  }

  close() {
    for (const index of this.indexes.values()) index.close();
    this.indexes.clear();
  }
}

module.exports = { LibraryIndex, IndexHost, DEFAULT_LIMITS, ignoredChange, conflictCopyOf };
