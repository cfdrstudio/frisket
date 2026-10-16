import { escape } from './modals.js';

const SPLIT_ICON = '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M8 2.5v11" stroke="currentColor" stroke-width="1.2"/></svg>';
const UNSPLIT_ICON = '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M6 6l4 4M10 6l-4 4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>';

let nextTabId = 1;

/**
 * The editor area: one pane, or two side by side or stacked, each with a tab
 * strip and one editor per tab (only the active one is shown). This module
 * owns layout, tab order, activation and drag-and-drop; index.js owns
 * documents, saving and what closing a tab means.
 *
 * Callbacks:
 *   createEditorFor(tab, host) → editor   build the editor for a new tab
 *   describe(tab) → { title, tooltip, dirty }
 *   onActivate(tab)       the focused tab changed
 *   onClose(tab)          the user asked to close a tab
 *   onNewTab(pane)        the + button or a double-click on the strip
 *   onSplit(pane) / onUnsplit(pane)
 *   onContextMenu(tab, x, y)
 *   onChanged()           tabs or layout changed (for saving the session)
 */
export function createEditorArea({
  container, createEditorFor, describe, onActivate, onClose, onNewTab, onSplit, onUnsplit, onContextMenu, onChanged,
}) {
  container.replaceChildren();
  const panesEl = document.createElement('div');
  panesEl.className = 'panes';
  container.appendChild(panesEl);

  const area = { panes: [], focused: null, orientation: 'row', ratio: 0.5 };
  let dragging = null;
  const resizer = createResizer();

  function activeTab() {
    return area.focused ? area.focused.active : null;
  }

  function tabIn(pane, element) {
    const node = element && element.closest('.tab');
    return node ? pane.tabs.find((tab) => tab.id === Number(node.dataset.tab)) || null : null;
  }

  function createPane() {
    const el = document.createElement('section');
    el.className = 'pane';
    el.innerHTML = '<div class="tab-bar"><div class="tab-strip" role="tablist"></div><div class="tab-actions">'
      + '<button class="icon-btn small tab-new" title="New tab (Ctrl+N)" aria-label="New tab">+</button>'
      + '<button class="icon-btn small tab-split" title="Split editor" aria-label="Split editor">' + SPLIT_ICON + '</button>'
      + '<button class="icon-btn small tab-unsplit" title="Close this pane" aria-label="Close this pane">' + UNSPLIT_ICON + '</button>'
      + '</div></div><div class="pane-editors"></div>';
    const pane = { el, strip: el.querySelector('.tab-strip'), hosts: el.querySelector('.pane-editors'), tabs: [], active: null };

    // Any click in a pane makes it the focused one.
    el.addEventListener('mousedown', () => {
      if (area.focused !== pane && pane.active) activateTab(pane.active, { focus: false });
    }, true);
    el.querySelector('.tab-new').addEventListener('click', () => onNewTab(pane));
    el.querySelector('.tab-split').addEventListener('click', () => onSplit(pane));
    el.querySelector('.tab-unsplit').addEventListener('click', () => onUnsplit(pane));

    const strip = pane.strip;
    strip.addEventListener('mousedown', (event) => { if (event.button === 1) event.preventDefault(); });
    strip.addEventListener('click', (event) => {
      const tab = tabIn(pane, event.target);
      if (!tab) return;
      if (event.target.closest('.tab-close')) { event.stopPropagation(); onClose(tab); return; }
      activateTab(tab);
    });
    strip.addEventListener('auxclick', (event) => {
      const tab = event.button === 1 ? tabIn(pane, event.target) : null;
      if (tab) { event.preventDefault(); onClose(tab); }
    });
    strip.addEventListener('dblclick', (event) => { if (event.target === strip) onNewTab(pane); });
    strip.addEventListener('contextmenu', (event) => {
      const tab = tabIn(pane, event.target);
      if (!tab) return;
      event.preventDefault();
      onContextMenu(tab, event.clientX, event.clientY);
    });
    strip.addEventListener('wheel', (event) => {
      if (event.deltaY && !event.deltaX) { strip.scrollLeft += event.deltaY; event.preventDefault(); }
    }, { passive: false });

    // Drag a tab to reorder it, or onto the other pane's tabs or editor to move it there.
    const dropIndex = (event) => {
      const nodes = [...strip.querySelectorAll('.tab')];
      const at = nodes.findIndex((node) => {
        const rect = node.getBoundingClientRect();
        return event.clientX < rect.left + rect.width / 2;
      });
      return at < 0 ? nodes.length : at;
    };
    strip.addEventListener('dragstart', (event) => {
      const tab = tabIn(pane, event.target);
      if (!tab) return;
      dragging = tab;
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/plain', describe(tab).title);
    });
    strip.addEventListener('dragend', () => { dragging = null; clearDropMarks(); });
    strip.addEventListener('dragover', (event) => {
      if (!dragging) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      markDrop(pane, dropIndex(event));
    });
    strip.addEventListener('drop', (event) => {
      if (!dragging) return;
      event.preventDefault();
      event.stopPropagation();
      const tab = dragging;
      dragging = null;
      clearDropMarks();
      moveTab(tab, pane, dropIndex(event));
    });
    pane.hosts.addEventListener('dragover', (event) => {
      if (!dragging || dragging.pane === pane) return;
      event.preventDefault();
      pane.el.classList.add('is-drop-target');
    });
    pane.hosts.addEventListener('dragleave', () => pane.el.classList.remove('is-drop-target'));
    pane.hosts.addEventListener('drop', (event) => {
      if (!dragging || dragging.pane === pane) return;
      event.preventDefault();
      event.stopPropagation();
      const tab = dragging;
      dragging = null;
      clearDropMarks();
      moveTab(tab, pane, pane.tabs.length);
    });
    return pane;
  }

  function markDrop(pane, index) {
    clearDropMarks();
    const nodes = pane.strip.querySelectorAll('.tab');
    if (index < nodes.length) nodes[index].classList.add('drop-before');
    else if (nodes.length) nodes[nodes.length - 1].classList.add('drop-after');
  }

  function clearDropMarks() {
    for (const node of panesEl.querySelectorAll('.drop-before, .drop-after')) node.classList.remove('drop-before', 'drop-after');
    for (const pane of area.panes) pane.el.classList.remove('is-drop-target');
  }

  function createResizer() {
    const handle = document.createElement('div');
    handle.className = 'pane-resizer';
    handle.setAttribute('role', 'separator');
    handle.title = 'Drag to resize; double-click to make the panes equal';
    handle.addEventListener('mousedown', (event) => {
      event.preventDefault();
      const rect = panesEl.getBoundingClientRect();
      const row = area.orientation === 'row';
      document.body.style.cursor = row ? 'col-resize' : 'row-resize';
      handle.classList.add('is-dragging');
      const move = (moveEvent) => {
        const ratio = row ? (moveEvent.clientX - rect.left) / rect.width : (moveEvent.clientY - rect.top) / rect.height;
        area.ratio = Math.max(0.15, Math.min(0.85, ratio));
        area.panes[0].el.style.flex = '0 0 ' + (area.ratio * 100) + '%';
      };
      const up = () => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
        document.body.style.cursor = '';
        handle.classList.remove('is-dragging');
        onChanged();
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
    });
    handle.addEventListener('dblclick', () => { area.ratio = 0.5; layout(); onChanged(); });
    return handle;
  }

  function layout() {
    panesEl.dataset.orientation = area.orientation;
    const split = area.panes.length > 1;
    panesEl.classList.toggle('is-split', split);
    panesEl.replaceChildren(...area.panes.flatMap((pane, i) => (i ? [resizer, pane.el] : [pane.el])));
    area.panes.forEach((pane, i) => {
      pane.el.style.flex = split && i === 0 ? '0 0 ' + (area.ratio * 100) + '%' : '1 1 0';
    });
    updateFocusClasses();
  }

  function updateFocusClasses() {
    const split = area.panes.length > 1;
    for (const pane of area.panes) pane.el.classList.toggle('is-focused', split && pane === area.focused);
  }

  function renderStrip(pane) {
    pane.strip.innerHTML = pane.tabs.map((tab) => {
      const info = describe(tab);
      const active = tab === pane.active;
      return '<div class="tab' + (active ? ' is-active' : '') + (info.dirty ? ' is-dirty' : '') + '" role="tab" aria-selected="'
        + active + '" draggable="true" data-tab="' + tab.id + '" title="' + escape(info.tooltip || info.title) + '">'
        + '<span class="tab-title">' + escape(info.title) + '</span>'
        + '<button class="tab-close" tabindex="-1" aria-label="Close ' + escape(info.title) + '">×</button></div>';
    }).join('');
    const current = pane.strip.querySelector('.tab.is-active');
    if (current) current.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  function renderAll() {
    for (const pane of area.panes) renderStrip(pane);
  }

  function activateTab(tab, { focus = true } = {}) {
    const pane = tab.pane;
    const previous = activeTab();
    if (pane.active && pane.active !== tab) pane.active.host.hidden = true;
    pane.active = tab;
    tab.host.hidden = false;
    area.focused = pane;
    updateFocusClasses();
    renderStrip(pane);
    tab.editor.view.requestMeasure();
    if (focus) tab.editor.view.focus();
    if (previous !== tab) onActivate(tab);
  }

  /** Add a tab for `doc` to `pane` (after its active tab unless `index` is given). */
  function openTab({ pane = area.focused || area.panes[0], doc, index = null, activate = true }) {
    const host = document.createElement('div');
    host.className = 'tab-editor';
    host.hidden = true;
    pane.hosts.appendChild(host);
    const tab = { id: nextTabId++, doc, pane, host, editor: null, back: [], forward: [] };
    tab.editor = createEditorFor(tab, host);
    const at = index === null ? (pane.active ? pane.tabs.indexOf(pane.active) + 1 : pane.tabs.length) : index;
    pane.tabs.splice(Math.max(0, Math.min(at, pane.tabs.length)), 0, tab);
    if (!pane.active) pane.active = tab;
    renderStrip(pane);
    if (activate) activateTab(tab);
    onChanged();
    return tab;
  }

  /** Remove a tab and its editor. Closing the last tab of a split pane closes the pane. */
  function removeTab(tab) {
    const pane = tab.pane;
    const at = pane.tabs.indexOf(tab);
    if (at < 0) return;
    const wasActive = activeTab() === tab;
    pane.tabs.splice(at, 1);
    tab.editor.destroy();
    tab.host.remove();
    if (pane.active === tab) {
      pane.active = pane.tabs[Math.min(at, pane.tabs.length - 1)] || null;
      if (pane.active) pane.active.host.hidden = false;
    }
    if (!pane.tabs.length && area.panes.length > 1) removePane(pane);
    renderAll();
    const next = area.focused && area.focused.active;
    if (next && wasActive) activateTab(next);
    onChanged();
  }

  /** Move a tab within its pane or into the other one. A note already open there is focused instead. */
  function moveTab(tab, toPane, index = toPane.tabs.length) {
    const fromPane = tab.pane;
    if (toPane !== fromPane) {
      const twin = toPane.tabs.find((other) => other.doc === tab.doc);
      if (twin) { activateTab(twin); onClose(tab); return; }
    }
    const from = fromPane.tabs.indexOf(tab);
    let at = Math.max(0, Math.min(index, toPane.tabs.length));
    if (fromPane === toPane && from < at) at--;
    if (fromPane === toPane && from === at) { activateTab(tab); return; }
    fromPane.tabs.splice(from, 1);
    if (fromPane.active === tab) {
      fromPane.active = fromPane.tabs[Math.min(from, fromPane.tabs.length - 1)] || null;
      if (fromPane.active) fromPane.active.host.hidden = false;
    }
    toPane.tabs.splice(at, 0, tab);
    tab.pane = toPane;
    // Moving the host element keeps the editor, its undo history and scroll position.
    toPane.hosts.appendChild(tab.host);
    if (toPane.active && toPane.active !== tab) toPane.active.host.hidden = true;
    if (!fromPane.tabs.length && area.panes.length > 1) removePane(fromPane);
    renderAll();
    activateTab(tab);
    onChanged();
  }

  function removePane(pane) {
    area.panes = area.panes.filter((item) => item !== pane);
    if (area.focused === pane) area.focused = area.panes[0];
    pane.el.remove();
    layout();
  }

  /** Make sure there are two panes; returns the one that is not focused. */
  function split(orientation = null) {
    if (orientation) area.orientation = orientation;
    if (area.panes.length < 2) area.panes.push(createPane());
    layout();
    onChanged();
    return area.panes.find((pane) => pane !== area.focused) || area.panes[1];
  }

  function removeEmptyPanes() {
    for (const pane of [...area.panes]) if (!pane.tabs.length && area.panes.length > 1) removePane(pane);
    renderAll();
  }

  function setOrientation(orientation) {
    area.orientation = orientation === 'column' ? 'column' : 'row';
    layout();
    onChanged();
  }

  function setRatio(ratio) {
    area.ratio = Math.max(0.15, Math.min(0.85, Number(ratio) || 0.5));
    layout();
  }

  function cycle(delta) {
    const pane = area.focused;
    if (!pane || pane.tabs.length < 2) return;
    const at = pane.tabs.indexOf(pane.active);
    activateTab(pane.tabs[(at + delta + pane.tabs.length) % pane.tabs.length]);
  }

  area.panes.push(createPane());
  area.focused = area.panes[0];
  layout();

  return {
    activeTab,
    activePane: () => area.focused,
    panes: () => [...area.panes],
    allTabs: () => area.panes.flatMap((pane) => pane.tabs),
    otherPane: (pane) => area.panes.find((item) => item !== pane) || null,
    orientation: () => area.orientation,
    ratio: () => area.ratio,
    openTab,
    activateTab,
    removeTab,
    moveTab,
    split,
    removeEmptyPanes,
    setOrientation,
    setRatio,
    cycle,
    refresh: renderAll,
  };
}
