import { escape } from './modals.js';

const CARET = '<span class="tree-caret"><svg viewBox="0 0 8 10" width="7" height="9" aria-hidden="true">'
  + '<path d="M1 1l5 4-5 4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></span>';

const FILE_ICON = '<span class="tree-caret"></span>';

function relativeTime(ms) {
  if (!ms) return '';
  const diff = Date.now() - ms;
  const minute = 60000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (diff < minute) return 'just now';
  if (diff < hour) return Math.round(diff / minute) + ' min ago';
  if (diff < day) return Math.round(diff / hour) + ' h ago';
  if (diff < 7 * day) return Math.round(diff / day) + ' d ago';
  return new Date(ms).toLocaleDateString();
}

export function createSidebar({ onOpenFile, onGoToHeading, onRequestFolder, onOpenMatch,
  onSaveSearch, onDeleteSavedSearch, onRefreshInsights, onSelectTag }) {
  const treeEl = document.getElementById('file-tree');
  const outlineEl = document.getElementById('outline');
  const articlesEl = document.getElementById('articles');
  const folderNameEl = document.getElementById('folder-name');
  const articlesFolderEl = document.getElementById('articles-folder');
  const searchInput = document.getElementById('search-input');
  const searchResultsEl = document.getElementById('search-results');
  const searchScopeEl = document.getElementById('search-scope');
  const savedSearchesEl = document.getElementById('saved-searches');
  const insightsEl = document.getElementById('insights');
  const tabs = [...document.querySelectorAll('.sidebar-tab')];

  const expanded = new Set();
  let folder = null;
  let activeFile = null;
  let headings = [];
  let currentHeading = -1;
  let activeTab = 'files';

  // --- tabs ----------------------------------------------------------------
  function setTab(tab) {
    const previous = activeTab;
    activeTab = tab;
    for (const btn of tabs) btn.classList.toggle('is-active', btn.dataset.tab === tab);
    for (const name of ['files', 'outline', 'articles', 'search', 'insights']) {
      document.getElementById('panel-' + name).hidden = name !== tab;
    }
    if (tab === 'articles') renderArticles();
    if (tab === 'search') setTimeout(() => searchInput.focus(), 30);
    if (tab === 'insights' && previous !== 'insights') onRefreshInsights();
  }

  tabs.forEach((btn) => {
    btn.addEventListener('click', () => setTab(btn.dataset.tab));
  });

  document.getElementById('btn-open-folder').addEventListener('click', () => onRequestFolder());
  document.getElementById('btn-refresh-insights').addEventListener('click', () => onRefreshInsights());

  // --- file tree -----------------------------------------------------------
  function emptyTree(message, actionLabel) {
    treeEl.innerHTML = '<div class="empty-note">' + escape(message)
      + (actionLabel ? '<br><button id="tree-open-folder">' + escape(actionLabel) + '</button>' : '')
      + '</div>';
    const btn = treeEl.querySelector('#tree-open-folder');
    if (btn) btn.addEventListener('click', () => onRequestFolder());
  }

  async function renderDir(dirPath, container, depth) {
    const entries = await window.frisket.listFolder(dirPath);
    container.innerHTML = '';
    if (entries.error) {
      container.innerHTML = '<div class="empty-note">' + escape(entries.error) + '</div>';
      return;
    }
    if (!entries.length && depth === 0) {
      emptyTree('This folder has no Markdown files yet.');
      return;
    }

    for (const entry of entries) {
      const row = document.createElement('div');
      row.className = 'tree-row';
      row.dataset.path = entry.path;
      row.title = entry.path;

      if (entry.type === 'dir') {
        const isOpen = expanded.has(entry.path);
        row.innerHTML = CARET + '<span class="tree-label">' + escape(entry.name) + '</span>';
        row.querySelector('.tree-caret').classList.toggle('is-open', isOpen);

        const children = document.createElement('div');
        children.className = 'tree-children';
        children.hidden = !isOpen;

        row.addEventListener('click', async () => {
          const open = expanded.has(entry.path);
          if (open) {
            expanded.delete(entry.path);
            children.hidden = true;
          } else {
            expanded.add(entry.path);
            children.hidden = false;
            await renderDir(entry.path, children, depth + 1);
          }
          row.querySelector('.tree-caret').classList.toggle('is-open', !open);
        });

        container.appendChild(row);
        container.appendChild(children);
        if (isOpen) await renderDir(entry.path, children, depth + 1);
      } else {
        row.innerHTML = FILE_ICON + '<span class="tree-label">' + escape(entry.name) + '</span>';
        row.classList.toggle('is-active', entry.path === activeFile);
        row.addEventListener('click', () => onOpenFile(entry.path));
        row.addEventListener('contextmenu', async (event) => {
          event.preventDefault();
          const choice = await window.frisket.showContextMenu([
            { id: 'open', label: 'Open' },
            { id: 'reveal', label: 'Show in Explorer' },
            { type: 'separator' },
            { id: 'rename', label: 'Rename…' },
            { id: 'delete', label: 'Move to Recycle Bin' },
          ], event.clientX, event.clientY);
          if (choice === 'open') onOpenFile(entry.path);
          else if (choice === 'reveal') window.frisket.revealInExplorer(entry.path);
          else if (choice === 'rename') {
            const { promptDialog } = await import('./modals.js');
            const name = await promptDialog({ title: 'Rename', value: entry.name, okLabel: 'Rename' });
            if (name && name !== entry.name) {
              await window.frisket.renameEntry(entry.path, name);
              refresh();
            }
          } else if (choice === 'delete') {
            const result = await window.frisket.trashEntry(entry.path);
            if (result && result.ok) refresh();
          }
        });
        container.appendChild(row);
      }
    }
  }

  async function refresh() {
    if (!folder) {
      emptyTree('Open a folder to browse your Markdown files, or just open a single file from anywhere on disk.', 'Open Folder…');
      return;
    }
    await renderDir(folder, treeEl, 0);
    renderArticles();
  }

  function setFolder(path) {
    folder = path;
    const label = path ? path.split(/[\\/]/).filter(Boolean).pop() : 'No folder opened';
    folderNameEl.textContent = label;
    folderNameEl.title = path || '';
    articlesFolderEl.textContent = label;
    articlesFolderEl.title = path || '';
    searchScopeEl.textContent = path ? 'Searching ' + label : 'No folder opened';
    searchScopeEl.title = path || '';
    expanded.clear();
    refresh();
  }

  function setActiveFile(path) {
    activeFile = path;
    treeEl.querySelectorAll('.tree-row').forEach((row) => {
      row.classList.toggle('is-active', row.dataset.path === path);
    });
    articlesEl.querySelectorAll('.article-row').forEach((row) => {
      row.classList.toggle('is-active', row.dataset.path === path);
    });
  }

  // --- outline -------------------------------------------------------------
  function setOutline(list) {
    headings = list;
    if (!list.length) {
      outlineEl.innerHTML = '<div class="empty-note">Headings you add will appear here as a clickable table of contents.</div>';
      return;
    }
    outlineEl.innerHTML = list.map((h, i) =>
      '<button class="outline-row" data-level="' + h.level + '" data-index="' + i + '" title="'
      + escape(h.text) + '">' + escape(h.text || 'Untitled') + '</button>').join('');
    outlineEl.querySelectorAll('.outline-row').forEach((btn) => {
      btn.addEventListener('click', () => onGoToHeading(headings[Number(btn.dataset.index)]));
    });
    highlightHeading(currentHeading);
  }

  function highlightHeading(index) {
    currentHeading = index;
    outlineEl.querySelectorAll('.outline-row').forEach((btn) => {
      btn.classList.toggle('is-current', Number(btn.dataset.index) === index);
    });
  }

  // --- articles ------------------------------------------------------------
  async function collect(dir, depth, out) {
    if (depth > 2 || out.length > 400) return;
    const entries = await window.frisket.listFolder(dir);
    if (entries.error) return;
    for (const entry of entries) {
      if (entry.type === 'file') out.push(entry);
      else await collect(entry.path, depth + 1, out);
    }
  }

  async function renderArticles() {
    if (!folder) {
      articlesEl.innerHTML = '<div class="empty-note">Open a folder to see all its articles in one list, most recently edited first.</div>';
      return;
    }
    const files = [];
    await collect(folder, 0, files);
    files.sort((a, b) => (b.mtime || 0) - (a.mtime || 0));
    if (!files.length) {
      articlesEl.innerHTML = '<div class="empty-note">No Markdown files in this folder.</div>';
      return;
    }
    articlesEl.innerHTML = files.map((f) =>
      '<button class="article-row' + (f.path === activeFile ? ' is-active' : '')
      + '" data-path="' + escape(f.path) + '" title="' + escape(f.path) + '">'
      + '<span class="article-name">' + escape(f.name.replace(/\.[^.]+$/, '')) + '</span>'
      + '<span class="article-meta">' + escape(relativeTime(f.mtime)) + '</span>'
      + '</button>').join('');
    articlesEl.querySelectorAll('.article-row').forEach((btn) => {
      btn.addEventListener('click', () => onOpenFile(btn.dataset.path));
    });
  }

  // --- global search -------------------------------------------------------
  let searchToken = 0;

  function setSavedSearches(queries = []) {
    savedSearchesEl.innerHTML = queries.map((query) =>
      '<span class="saved-search"><button class="saved-search-run" data-query="' + escape(query)
      + '">' + escape(query) + '</button><button class="saved-search-remove" data-query="'
      + escape(query) + '" aria-label="Remove saved search ' + escape(query) + '">×</button></span>')
      .join('');
    savedSearchesEl.querySelectorAll('.saved-search-run').forEach((btn) => {
      btn.addEventListener('click', () => {
        searchInput.value = btn.dataset.query;
        setTab('search');
        runSearch(searchInput.value);
      });
    });
    savedSearchesEl.querySelectorAll('.saved-search-remove').forEach((btn) => {
      btn.addEventListener('click', () => onDeleteSavedSearch(btn.dataset.query));
    });
  }

  document.getElementById('btn-save-search').addEventListener('click', () => {
    const query = searchInput.value.trim();
    if (query.length >= 2) onSaveSearch(query);
  });

  function setInsights(summary) {
    if (!folder) {
      insightsEl.innerHTML = '<div class="empty-note">Open a folder to inspect notes, links, tags and attachments.</div>';
      return;
    }
    if (!summary) {
      insightsEl.innerHTML = '<div class="empty-note">Loading workspace insights…</div>';
      return;
    }
    if (summary.error) {
      insightsEl.innerHTML = '<div class="empty-note">' + escape(summary.error) + '</div>';
      return;
    }
    const notes = summary.notes || [];
    const tags = summary.tags || [];
    const linked = summary.backlinks?.linked || [];
    const unlinked = summary.backlinks?.unlinked || [];
    const attachments = summary.attachments || { referenced: [], missing: [] };
    const properties = Object.entries(summary.currentProperties || {}).slice(0, 20);
    const linkRows = (items) => items.length
      ? items.map((item) => '<button class="insight-row" data-path="' + escape(item.path)
        + '" data-pos="' + Number(item.pos || 0) + '"><strong>' + escape(item.title || item.relative)
        + (item.ambiguous ? ' <span class="insight-flag" title="This link matches more than one note">ambiguous</span>' : '')
        + '</strong><small>' + escape(item.excerpt || item.relative || '') + '</small></button>').join('')
      : '<div class="empty-note">None yet.</div>';
    insightsEl.innerHTML = '<div class="insight-count">' + notes.length + ' Markdown files'
      + (summary.truncated ? ' (first batch)' : '') + '</div>'
      + '<h3>Tags</h3>'
      + (tags.length ? '<div class="insight-tags">' + tags.map((tag) =>
        '<button data-tag="' + escape(tag.tag) + '">#' + escape(tag.tag)
        + ' <small>' + Number(tag.count) + '</small></button>').join('') + '</div>'
        : '<div class="empty-note">No tags in this folder.</div>')
      + '<h3>Current note properties</h3>'
      + (properties.length ? '<div class="insight-properties">' + properties.map(([key, value]) =>
        '<div><strong>' + escape(key) + '</strong> ' + escape(String(value)) + '</div>').join('') + '</div>'
        : '<div class="empty-note">No frontmatter properties.</div>')
      + '<h3>Linked mentions</h3>' + linkRows(linked)
      + '<h3>Unlinked mentions</h3>' + linkRows(unlinked)
      + '<h3>Current note attachments</h3><div class="insight-count">'
      + Number(attachments.referenced?.length || 0) + ' referenced, '
      + Number(attachments.missing?.length || 0) + ' missing</div>'
      + (attachments.missing?.length ? '<div class="insight-missing">'
        + attachments.missing.map((item) => '<div>' + escape(typeof item === 'string' ? item : item.reference || item.path || '') + '</div>').join('')
        + '</div>' : '');
    insightsEl.querySelectorAll('.insight-row').forEach((btn) => {
      btn.addEventListener('click', () => onOpenMatch(btn.dataset.path, Number(btn.dataset.pos)));
    });
    insightsEl.querySelectorAll('[data-tag]').forEach((btn) => {
      btn.addEventListener('click', () => onSelectTag(btn.dataset.tag));
    });
  }

  function highlight(text, query, offset) {
    const lower = text.toLowerCase();
    const needle = query.toLowerCase();
    let out = '';
    let at = 0;
    for (;;) {
      const hit = lower.indexOf(needle, at);
      if (hit === -1) { out += escape(text.slice(at)); break; }
      out += escape(text.slice(at, hit)) + '<mark>'
        + escape(text.slice(hit, hit + query.length)) + '</mark>';
      at = hit + query.length;
    }
    return (offset ? '…' : '') + out;
  }

  async function runSearch(query) {
    const token = ++searchToken;
    const trimmed = query.trim();

    if (!folder) {
      searchResultsEl.innerHTML = '<div class="empty-note">Open a folder to search across files.'
        + '<br><button id="search-open-folder">Open Folder…</button></div>';
      const btn = searchResultsEl.querySelector('#search-open-folder');
      if (btn) btn.addEventListener('click', () => onRequestFolder());
      return;
    }
    if (trimmed.length < 2) {
      searchResultsEl.innerHTML = '<div class="search-status">Type at least two characters.</div>';
      return;
    }

    searchResultsEl.innerHTML = '<div class="search-status">Searching…</div>';
    const { results, truncated, error } = await window.frisket.searchWorkspace(trimmed, { folder });

    // A later keystroke has already superseded this run.
    if (token !== searchToken) return;

    if (error) {
      searchResultsEl.innerHTML = '<div class="search-status">' + escape(error) + '</div>';
      return;
    }
    if (!results.length) {
      searchResultsEl.innerHTML = '<div class="search-status">No matches for “'
        + escape(trimmed) + '”.</div>';
      return;
    }

    const total = results.reduce((n, r) => n + r.matches.length, 0);
    const parts = ['<div class="search-status">' + total + (total === 1 ? ' match in ' : ' matches in ')
      + results.length + (results.length === 1 ? ' file' : ' files')
      + (truncated ? ' (showing the first batch)' : '') + '</div>'];

    for (const file of results) {
      const dir = file.relative.slice(0, -file.name.length).replace(/[\/]$/, '');
      parts.push('<div class="search-file"><span>' + escape(file.name.replace(/\.[^.]+$/, ''))
        + '</span><span class="search-file-dir">' + escape(dir)
        + '</span><span class="search-file-count">' + file.matches.length + '</span></div>');
      for (const m of file.matches) {
        parts.push('<button class="search-hit" data-path="' + escape(file.path)
          + '" data-pos="' + m.pos + '" title="Line ' + m.line + '">'
          + '<span class="search-line-no">' + m.line + '</span>'
          + highlight(m.text.trim(), trimmed, m.snippetOffset) + '</button>');
      }
    }

    searchResultsEl.innerHTML = parts.join('');
    searchResultsEl.querySelectorAll('.search-hit').forEach((btn) => {
      btn.addEventListener('click', () => {
        onOpenMatch(btn.dataset.path, Number(btn.dataset.pos));
      });
    });
  }

  let searchTimer = null;
  searchInput.addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => runSearch(searchInput.value), 220);
  });
  searchInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { clearTimeout(searchTimer); runSearch(searchInput.value); }
    if (event.key === 'Escape') { searchInput.value = ''; runSearch(''); }
  });

  return {
    setTab,
    getTab: () => activeTab,
    setFolder,
    getFolder: () => folder,
    refresh,
    setActiveFile,
    setOutline,
    highlightHeading,
    setSavedSearches,
    setInsights,
    focusSearch: (query) => {
      setTab('search');
      if (query) { searchInput.value = query; runSearch(query); }
      searchInput.focus(); searchInput.select();
    },
    rerunSearch: () => runSearch(searchInput.value),
  };
}
