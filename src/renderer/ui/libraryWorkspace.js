import { escape } from './modals.js';

const CLOUD_ICON = '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M4.5 12.5h7a3 3 0 00.4-5.97A4 4 0 004.2 6.6 2.95 2.95 0 004.5 12.5z" stroke="currentColor" stroke-width="1.2" fill="none" stroke-linejoin="round"/></svg>';
const LOCAL_ICON = '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><rect x="2" y="3" width="12" height="8" rx="1" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M6 13.5h4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>';

const PIN_ICON ='<svg class="note-card-pin" viewBox="0 0 16 16" width="11" height="11" aria-label="Pinned" role="img">'
  + '<path d="M9.5 1.5l5 5-2 .5-2.5 2.5.5 3-1.5 1.5L6 11l-3.5 3.5L2 14l3.5-3.5L2.5 7.5 4 6l3 .5L9.5 4z" fill="currentColor"/></svg>';

function relativeTime(value) {
  if (!value) return '';
  const diff = Math.max(0, Date.now() - new Date(value).getTime());
  if (diff < 60000) return 'just now';
  if (diff < 3600000) return Math.round(diff / 60000) + ' min ago';
  if (diff < 86400000) return Math.round(diff / 3600000) + ' h ago';
  if (diff < 7 * 86400000) return Math.round(diff / 86400000) + ' d ago';
  return new Date(value).toLocaleDateString();
}

/** Pinned notes first, then by the chosen order. */
function sortNotes(notes, mode) {
  const copy = [...notes];
  const time = (value) => {
    const parsed = typeof value === 'number' ? value : Date.parse(value || '');
    return Number.isFinite(parsed) ? parsed : 0;
  };
  const text = (a, b) => String(a || '').localeCompare(String(b || ''), undefined, { sensitivity: 'base', numeric: true });
  const pinned = (a, b) => Number(!!b.pinned) - Number(!!a.pinned);
  if (mode === 'created') return copy.sort((a, b) => pinned(a, b) || time(b.createdAt) - time(a.createdAt) || text(a.title, b.title));
  if (mode === 'title') return copy.sort((a, b) => pinned(a, b) || text(a.title, b.title) || time(b.modifiedAt || b.mtime) - time(a.modifiedAt || a.mtime));
  return copy.sort((a, b) => pinned(a, b) || time(b.modifiedAt || b.mtime) - time(a.modifiedAt || a.mtime) || text(a.title, b.title));
}

function normalizeTag(value) {
  return String(value || '').replace(/^#/, '').replace(/#$/, '').trim();
}

function tagTree(tags) {
  const root = new Map();
  for (const item of tags || []) {
    const tag = normalizeTag(item.tag);
    if (!tag) continue;
    let level = root;
    let full = '';
    for (const part of tag.split('/').filter(Boolean)) {
      full = full ? full + '/' + part : part;
      if (!level.has(part)) level.set(part, { tag: full, count: 0, children: new Map() });
      const node = level.get(part);
      if (full === tag) node.count = Number(item.count || 0);
      level = node.children;
    }
  }
  return root;
}

function renderTagTree(tree, active, depth = 0) {
  let html = '';
  for (const [label, node] of [...tree.entries()].sort((a, b) => a[0].localeCompare(b[0], undefined, { sensitivity: 'base' }))) {
    html += '<button class="library-tag' + (active === node.tag ? ' is-active' : '') + '" data-tag="' + escape(node.tag)
      + '" style="--tag-depth:' + depth + '"><span>#' + escape(label) + '</span><small>' + Number(node.count) + '</small></button>';
    html += renderTagTree(node.children, active, depth + 1);
  }
  return html;
}

/** Sync-conflict copies appear only under Conflicts until they are resolved. */
function belongsToFilter(note, filter) {
  if (filter === 'conflicts') return !!note.conflict && !note.trashedAt;
  if (note.conflict && !note.trashedAt) return false;
  if (filter === 'untagged') return !(note.tags || []).length && !note.trashedAt;
  if (filter === 'todo') return !note.trashedAt && Number(note.tasksTotal || 0) > Number(note.tasksDone || 0);
  if (filter === 'trash') return !!note.trashedAt;
  if (filter.startsWith('tag:')) {
    const wanted = normalizeTag(filter.slice(4)).toLocaleLowerCase();
    return !note.trashedAt && (note.tags || []).some((tag) => {
      const value = normalizeTag(tag).toLocaleLowerCase();
      return value === wanted || value.startsWith(wanted + '/');
    });
  }
  return !note.trashedAt;
}

/** Escape a snippet and mark each search term in it. */
function highlightTerms(text, terms) {
  const value = String(text || '');
  const needles = (terms || []).filter(Boolean).map((term) => term.toLowerCase());
  if (!needles.length) return escape(value);
  const lower = value.toLowerCase();
  let out = '';
  let at = 0;
  while (at < value.length) {
    let best = -1;
    let length = 0;
    for (const needle of needles) {
      const hit = lower.indexOf(needle, at);
      if (hit >= 0 && (best < 0 || hit < best)) { best = hit; length = needle.length; }
    }
    if (best < 0) { out += escape(value.slice(at)); break; }
    out += escape(value.slice(at, best)) + '<mark>' + escape(value.slice(best, best + length)) + '</mark>';
    at = best + length;
  }
  return out;
}

const CONFLICT_LABELS = {
  'conflicted-copy': 'Conflicted copy', syncthing: 'Syncthing conflict', onedrive: 'OneDrive copy', 'duplicate-id': 'Duplicate of another note',
};

/**
 * The visible tag navigation and note-list panes. The editor remains owned by
 * index.js, so this module has no document write access.
 */
export function createLibraryWorkspace({
  onOpenFile, onOpenMatch, onOpenFolder, onNewNote, onDailyNote, onSearch, onFilterChange, onSortChange,
  onTrashNote, onRestoreNote, onDeleteNote, onTogglePin, onShowHistory, onResolveConflict, onSync, initialSort = 'modified',
}) {
  const nav = document.getElementById('library-nav');
  const list = document.getElementById('note-list');
  const count = document.getElementById('note-list-count');
  const title = document.getElementById('note-list-title');
  const sort = document.getElementById('note-list-sort');
  const search = document.getElementById('library-search');

  let folder = null;
  let overview = { notes: [], tags: [] };
  let activePath = null;
  let filter = 'notes';
  let sortMode = initialSort;
  let query = '';
  let results = null;
  let searchRequest = 0;
  let searchTimer = null;
  let syncStatus = null;
  sort.value = sortMode;

  /** "Synced · OneDrive" or "Not synced", with conflicts called out; opens Sync & Devices. */
  function syncChip() {
    if (!folder || !syncStatus) return '';
    const conflicts = Number(overview.conflicts || 0);
    const provider = syncStatus.provider;
    const label = provider ? 'Synced · ' + provider.label : 'Not synced · set up';
    const title = provider
      ? 'This library is in ' + provider.label + ', so it syncs to your other devices. Click for details.'
      : 'This library is only on this computer. Click to set up sync.';
    return '<button class="library-sync ' + (provider ? 'is-synced' : 'is-local') + '" id="library-sync" title="' + escape(title) + '">'
      + (provider ? CLOUD_ICON : LOCAL_ICON) + '<span>' + escape(label) + '</span>'
      + (conflicts ? '<small class="library-alert" title="Sync conflicts">' + conflicts + '</small>' : '') + '</button>';
  }

  function filterTitle() {
    if (filter === 'untagged') return 'Untagged';
    if (filter === 'todo') return 'Todo';
    if (filter === 'trash') return 'Trash';
    if (filter === 'conflicts') return 'Sync conflicts';
    if (filter.startsWith('tag:')) return '#' + filter.slice(4);
    return 'Notes';
  }

  function renderNav() {
    const tags = tagTree(overview.tags || []);
    const selectedTag = filter.startsWith('tag:') ? filter.slice(4) : '';
    const conflicts = Number(overview.conflicts || 0);
    const filterButton = (id, label, extra = '') => '<button data-filter="' + id + '" class="' + (filter === id ? 'is-active' : '')
      + extra + '">' + label + '</button>';
    nav.innerHTML = '<div class="library-nav-head"><span id="library-name" title="' + escape(folder || '') + '">'
      + escape(folder ? folder.split(/[\\/]/).filter(Boolean).pop() : 'No library selected') + '</span>'
      + '<button class="icon-btn small" id="library-open" title="Open library" aria-label="Open library">⌄</button></div>'
      + syncChip()
      + '<div class="library-actions"><button class="library-new" id="library-new-note">+ New note</button>'
      + '<button class="library-today" id="library-today" title="Open today’s note (Ctrl+Shift+T)">Today</button></div>'
      + '<nav class="library-filters" aria-label="Library filters">'
      + filterButton('notes', 'Notes') + filterButton('untagged', 'Untagged') + filterButton('todo', 'Todo')
      + filterButton('trash', 'Trash')
      + (conflicts || filter === 'conflicts'
        ? filterButton('conflicts', 'Conflicts <small class="library-alert">' + conflicts + '</small>', ' library-conflicts') : '')
      + '</nav>'
      + '<div class="library-tags"><div class="library-section-label">Tags</div>'
      + (tags.size ? renderTagTree(tags, selectedTag) : '<div class="library-empty-tags">Tags you type in notes appear here.</div>')
      + '</div>';
    nav.querySelector('#library-open').addEventListener('click', onOpenFolder);
    nav.querySelector('#library-new-note').addEventListener('click', onNewNote);
    nav.querySelector('#library-today').addEventListener('click', () => onDailyNote && onDailyNote());
    const syncButton = nav.querySelector('#library-sync');
    if (syncButton) syncButton.addEventListener('click', () => onSync && onSync());
    nav.querySelectorAll('[data-filter]').forEach((button) => button.addEventListener('click', () => setFilter(button.dataset.filter)));
    nav.querySelectorAll('[data-tag]').forEach((button) => button.addEventListener('click', () => setFilter('tag:' + button.dataset.tag)));
  }

  async function resolvePreviews() {
    for (const image of list.querySelectorAll('img[data-reference]')) {
      const note = overview.notes.find((item) => item.path === image.dataset.path);
      if (!note) continue;
      const resolved = await window.frisket.resolveImage(image.dataset.reference, note.path);
      if (resolved && !resolved.error) {
        // Show the thumbnail only once it decodes, never a broken-image icon.
        image.addEventListener('load', () => { image.hidden = false; }, { once: true });
        image.src = resolved;
      }
    }
  }

  function visibleNotes() {
    if (results) return results.notes.filter((note) => belongsToFilter(note, filter));
    return sortNotes((overview.notes || []).filter((note) => belongsToFilter(note, filter)), sortMode);
  }

  function card(note) {
    const total = Number(note.tasksTotal || 0);
    const done = Number(note.tasksDone || 0);
    const progress = total ? '<span class="note-card-progress">' + done + '/' + total + '</span>' : '';
    const preview = note.imagePreview
      ? '<img class="note-card-image" hidden data-reference="' + escape(note.imagePreview) + '" data-path="' + escape(note.path) + '" alt="">'
      : '';
    const snippet = results && note.match
      ? '<span class="note-card-excerpt note-card-match">' + highlightTerms(note.match.text, results.terms) + '</span>'
      : '<span class="note-card-excerpt">' + escape(note.excerpt || 'Empty note') + '</span>';
    const conflict = note.conflict
      ? '<span class="note-card-conflict">' + escape(CONFLICT_LABELS[note.conflict.kind] || 'Conflict')
        + (note.conflict.original ? ' of ' + escape(note.conflict.original.split(/[\\/]/).pop()) : '') + '</span>'
      : '';
    return '<button class="note-card' + (note.path === activePath ? ' is-active' : '') + (note.pinned ? ' is-pinned' : '')
      + '" data-path="' + escape(note.path) + '" data-pos="' + Number(note.match ? note.match.pos : -1) + '">'
      + preview + '<span class="note-card-copy"><strong>' + (note.pinned ? PIN_ICON : '') + escape(note.title || note.name || 'Untitled') + '</strong>'
      + snippet + conflict
      + '<span class="note-card-meta">' + escape(relativeTime(note.modifiedAt || note.mtime)) + progress + '</span></span></button>';
  }

  function renderList() {
    const notes = visibleNotes();
    title.textContent = results ? 'Search' : filterTitle();
    count.textContent = results
      ? notes.length + (notes.length === 1 ? ' result' : ' results') + ' in ' + filterTitle()
      : (notes.length ? notes.length + (notes.length === 1 ? ' note' : ' notes') : '');
    if (!folder) {
      list.innerHTML = '<div class="note-list-empty">Open a folder to use it as a Frisket library. Your Markdown files stay where they are.</div>';
      return;
    }
    // Never omit notes silently: say when the index stopped at its limits.
    const limits = overview.limits || {};
    const notice = overview.truncated
      ? '<div class="note-list-notice" role="status">Some notes are not shown. Frisket indexes up to '
        + Number(limits.maxFiles || 0).toLocaleString() + ' notes, ' + Number(limits.maxDepth || 0)
        + ' folders deep, ' + Math.round(Number(limits.maxFileBytes || 0) / 1048576) + ' MB each.</div>'
      : '';
    if (!notes.length) {
      const empty = results ? 'No notes match “' + escape(query) + '”.'
        : filter === 'conflicts' ? 'No sync conflicts. Copies made by Dropbox, OneDrive, Syncthing or iCloud appear here.'
          : 'No notes in this view yet.';
      list.innerHTML = notice + '<div class="note-list-empty">' + empty + '</div>';
      return;
    }
    list.innerHTML = notice + notes.map(card).join('');
    list.querySelectorAll('.note-card').forEach((element) => {
      const notePath = element.dataset.path;
      const pos = Number(element.dataset.pos);
      element.addEventListener('click', () => {
        if (filter === 'conflicts' && onResolveConflict) onResolveConflict(notePath);
        else if (pos >= 0 && onOpenMatch) onOpenMatch(notePath, pos);
        else onOpenFile(notePath);
      });
      element.addEventListener('contextmenu', async (event) => {
        event.preventDefault();
        const note = notes.find((item) => item.path === notePath) || {};
        let items;
        if (filter === 'trash') {
          items = [{ id: 'open', label: 'Open' }, { id: 'restore', label: 'Restore note' }, { type: 'separator' }, { id: 'delete', label: 'Delete permanently' }];
        } else if (note.conflict) {
          items = [{ id: 'resolve', label: 'Resolve conflict…' }, { id: 'open', label: 'Open' }];
        } else {
          items = [{ id: 'open', label: 'Open' }, { id: 'pin', label: note.pinned ? 'Unpin' : 'Pin to top' },
            { id: 'history', label: 'Version history…' }, { type: 'separator' }, { id: 'trash', label: 'Move to Trash' }];
        }
        const choice = await window.frisket.showContextMenu(items, event.clientX, event.clientY);
        if (choice === 'open') onOpenFile(notePath);
        else if (choice === 'trash' && onTrashNote) onTrashNote(notePath);
        else if (choice === 'restore' && onRestoreNote) onRestoreNote(notePath);
        else if (choice === 'delete' && onDeleteNote) onDeleteNote(notePath);
        else if (choice === 'pin' && onTogglePin) onTogglePin(notePath, !note.pinned);
        else if (choice === 'history' && onShowHistory) onShowHistory(notePath);
        else if (choice === 'resolve' && onResolveConflict) onResolveConflict(notePath);
      });
    });
    void resolvePreviews();
  }

  /** Run the current query through the index; a later keystroke supersedes it. */
  async function runSearch() {
    const request = ++searchRequest;
    if (!query || !folder || !onSearch) {
      results = null;
      renderList();
      return;
    }
    const found = await onSearch(query, { includeTrashed: filter === 'trash' });
    if (request !== searchRequest) return;
    results = found && !found.error ? { notes: found.notes || [], terms: found.terms || [] } : { notes: [], terms: [] };
    renderList();
  }

  function setFilter(next) {
    filter = next || 'notes';
    renderNav();
    if (query) void runSearch();
    else renderList();
    if (onFilterChange) onFilterChange(filter);
  }

  sort.addEventListener('change', () => { sortMode = sort.value; renderList(); if (onSortChange) onSortChange(sortMode); });
  search.addEventListener('input', () => {
    query = search.value.trim();
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { void runSearch(); }, query ? 150 : 0);
  });
  search.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      search.value = '';
      query = '';
      void runSearch();
    } else if (event.key === 'Enter') {
      clearTimeout(searchTimer);
      const first = list.querySelector('.note-card');
      if (first) first.click();
    }
  });
  // Bind the navigation now, so it works before any library is opened.
  renderNav();

  return {
    setFolder(next) { folder = next || null; results = null; syncStatus = null; renderNav(); renderList(); },
    setSyncStatus(next) { syncStatus = next || null; renderNav(); },
    setOverview(next) {
      overview = next && !next.error ? next : { notes: [], tags: [] };
      if (filter === 'conflicts' && !overview.conflicts) filter = 'notes';
      renderNav();
      if (query) void runSearch();
      else renderList();
    },
    setActiveFile(path) { activePath = path || null; renderList(); },
    setFilter,
    getFilter: () => filter,
    getFolder: () => folder,
    getSort: () => sortMode,
    focusSearch(text = '') { search.value = text; query = text.trim(); search.focus(); void runSearch(); },
    refresh: renderList,
  };
}
