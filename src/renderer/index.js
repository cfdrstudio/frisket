import 'katex/dist/katex.min.css';

import { createEditor, commands, metricsTheme } from './editor/setup.js';
import { focusMode, typewriterMode, markdownAutoPair } from './editor/modes.js';
import { EditorView } from '@codemirror/view';
import { openSearchPanel } from '@codemirror/search';
import { createSidebar } from './ui/sidebar.js';
import { createLibraryWorkspace } from './ui/libraryWorkspace.js';
import { toast } from './ui/toast.js';
import { showModal, confirmDialog, promptDialog, escape } from './ui/modals.js';
import { buildExportHtml, buildPlainText, renderFragment } from './exportDoc.js';
import { setMermaidTheme, clearImageCache } from './editor/widgets.js';
import { inferTitle } from './markdown.js';
import { analyzeStyle, applyTemplate } from './editor/writingTools.mjs';
import { lineDiff, diffStats, withContext } from './ui/lineDiff.mjs';
import { createEditorArea } from './ui/editorArea.js';
import { mirrorChanges, isMirrored } from './editor/docSync.mjs';

const api = window.frisket;

/** Each tab keeps a back/forward history of `{ path, pos }`, like a browser tab. */
const NAVIGATION_LIMIT = 100;

const state = {
  settings: null,
  systemDark: false,
  zen: false,
  wordMode: 0,
  headings: [],
};

let editorArea = null;
let sidebar = null;
let libraryWorkspace = null;
let workspaceOverview = null;

const activeTab = () => editorArea.activeTab();
const activeDoc = () => activeTab().doc;

// The document fields of `state` belong to the focused tab's document, so code
// written for one document per window keeps working with tabs and splits.
for (const key of ['path', 'name', 'savedText', 'dirty', 'mtime', 'saving']) {
  Object.defineProperty(state, key, {
    get: () => activeDoc()[key],
    set: (value) => { activeDoc()[key] = value; },
    enumerable: true,
  });
}

/** The focused tab's editor. */
const editor = {
  get view() { return activeTab().editor.view; },
  getContent: () => activeTab().editor.getContent(),
  setContent: (text) => activeTab().editor.setContent(text),
};

const el = (id) => document.getElementById(id);

/** Compare folder paths the way the platform's file system does. */
function samePath(a, b) {
  const norm = (value) => String(value || '').replace(/\\/g, '/').replace(/\/+$/, '');
  return state.platform === 'linux' ? norm(a) === norm(b) : norm(a).toLowerCase() === norm(b).toLowerCase();
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------
function isDark() {
  const mode = state.settings.darkMode;
  if (mode === 'dark') return true;
  if (mode === 'light') return false;
  return state.systemDark;
}

function applyTheme() {
  const theme = state.settings.theme || 'frisket';
  document.documentElement.dataset.theme = theme;
  el('theme-sheet').href = 'themes/' + theme + '.css';

  const dark = isDark();
  document.documentElement.dataset.dark = dark ? 'true' : 'false';
  document.documentElement.style.colorScheme = dark ? 'dark' : 'light';

  // Diagrams bake their palette in at render time, so they need rebuilding.
  if (setMermaidTheme(dark) && editorArea) {
    for (const tab of editorArea.allTabs()) {
      tab.editor.view.dispatch({ effects: [] });
      requestAnimationFrame(() => tab.editor.view.requestMeasure());
    }
  }
}

async function setSettings(patch, { rerender = false } = {}) {
  state.settings = await api.setSettings(patch);
  if (rerender) applyTheme();
  return state.settings;
}

// ---------------------------------------------------------------------------
// Document lifecycle
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Documents and tabs
// ---------------------------------------------------------------------------
/** Open documents by path. A note shown in two tabs (or both panes) is one document. */
const docs = new Map();

function docKey(path) {
  const value = String(path || '').replace(/\\/g, '/');
  return state.platform === 'linux' ? value : value.toLowerCase();
}

function findDoc(path) {
  return path ? docs.get(docKey(path)) || null : null;
}

function makeDoc({ path = null, name = 'Untitled', contents = '', mtime = 0 } = {}) {
  const doc = { path, name, savedText: contents, mtime, dirty: false, saving: false, tabs: new Set(), autoSaveTimer: null };
  if (path) docs.set(docKey(path), doc);
  return doc;
}

/** Forget a document once no tab shows it. */
function releaseDoc(doc) {
  if (doc.tabs.size) return;
  clearTimeout(doc.autoSaveTimer);
  if (doc.path && findDoc(doc.path) === doc) docs.delete(docKey(doc.path));
  syncWatches();
}

/** Any editor showing `doc`; they all hold the same text. */
function docEditor(doc) {
  const [tab] = doc.tabs;
  return tab ? tab.editor : null;
}

function docContent(doc) {
  const shown = docEditor(doc);
  return shown ? shown.getContent() : doc.savedText;
}

/** Watch every open file for changes made outside Frisket. */
function syncWatches() {
  void api.watchFiles([...docs.values()].map((doc) => doc.path).filter(Boolean));
}

function setDocDirty(doc, dirty) {
  doc.dirty = dirty;
  editorArea.refresh();
  if (doc === activeDoc()) {
    el('doc-dirty').hidden = !dirty;
    api.setDirty(dirty, doc.name);
  }
}

function setDirty(dirty) {
  setDocDirty(activeDoc(), dirty);
}

function updateTitle() {
  el('doc-title').textContent = state.name;
  el('status-path').textContent = state.path || 'Not saved to disk';
  el('status-path').title = state.path || '';
  el('doc-dirty').hidden = !state.dirty;
  api.setDirty(state.dirty, state.name);
  editorArea.refresh();
}

/** Tab label: the note's title (front matter or first heading), else its file name. */
function describeTab(tab) {
  const doc = tab.doc;
  const fileName = doc.name.replace(/\.(?:md|markdown|mdown|mkd|mdx|txt)$/i, '') || 'Untitled';
  // The start of the note is enough to find its title, and cheap to read on every redraw.
  const head = tab.editor ? tab.editor.view.state.doc.sliceString(0, 4000) : doc.savedText.slice(0, 4000);
  const title = inferTitle(head, fileName);
  return { title, tooltip: doc.path || title, dirty: doc.dirty };
}

function createTabEditor(tab, host) {
  return createEditor({
    parent: host,
    doc: '',
    settings: () => state.settings,
    handlers: {
      onUpdate: (update) => onTabUpdate(tab, update),
      onFocus: () => { if (activeTab() !== tab) editorArea.activateTab(tab, { focus: false }); },
      onFollowInternal: followInternalLink,
      getCompletionData: () => (workspaceOverview && !workspaceOverview.error
        ? { notes: workspaceOverview.notes, tags: workspaceOverview.tags } : null),
    },
  });
}

function onTabUpdate(tab, update) {
  const doc = tab.doc;
  if (update.docChanged) {
    // Every other tab showing this note follows the edit.
    mirrorChanges(update, [...doc.tabs].filter((other) => other !== tab).map((other) => other.editor.view));
    if (!isMirrored(update)) {
      const dirty = update.state.doc.toString() !== doc.savedText;
      if (dirty !== doc.dirty) setDocDirty(doc, dirty);
      scheduleAutoSave(doc);
    }
  }
  if (tab !== activeTab()) return;
  if (update.docChanged) { refreshOutline(); updateCounts(); }
  if (update.selectionSet || update.docChanged) updatePosition(update.state);
}

/** The focused tab changed: point the title, outline, status bar and panels at it. */
function onActivateTab(tab) {
  updateTitle();
  sidebar.setActiveFile(tab.doc.path);
  libraryWorkspace?.setActiveFile(tab.doc.path);
  refreshOutline();
  updateCounts();
  updatePosition(tab.editor.view.state);
  updateNavigationButtons();
  if (sidebar.getTab() === 'insights') refreshInsights();
  void refreshBacklinks();
  persistSession();
}

/** Show `doc` in `tab`, replacing what the tab showed. */
function attachDoc(tab, doc, text) {
  const previous = tab.doc;
  if (previous === doc) return;
  if (previous) { previous.tabs.delete(tab); releaseDoc(previous); }
  tab.doc = doc;
  doc.tabs.add(tab);
  tab.editor.load(text, doc.path, !!state.settings.sourceMode);
  syncWatches();
}

/** A new tab showing `doc`; its text comes from another tab of the note when there is one. */
function addTab(doc, { pane = null, text = null, activate = true } = {}) {
  const live = docEditor(doc);
  const tab = editorArea.openTab({ pane: pane || editorArea.activePane(), doc, activate: false });
  doc.tabs.add(tab);
  tab.editor.load(text ?? (live ? live.getContent() : doc.savedText), doc.path, !!state.settings.sourceMode);
  syncWatches();
  if (activate) editorArea.activateTab(tab);
  return tab;
}

/** A new tab with an unsaved note. `clean: false` marks the contents as unsaved. */
function newUntitledTab({ name = 'Untitled', contents = '', clean = true, pane = null } = {}) {
  const doc = makeDoc({ name, contents: clean ? contents : '' });
  const tab = addTab(doc, { pane, text: contents });
  if (!clean && contents) setDocDirty(doc, true);
  tab.editor.view.focus();
  return tab;
}

/** The empty, unsaved tab a window starts with; it is reused rather than kept. */
function isBlankTab(tab) {
  return !!tab && !tab.doc.path && !tab.doc.dirty && tab.doc.tabs.size === 1 && !tab.editor.getContent();
}

/** Show file data in `tab` (default: the focused tab) and focus it. */
async function loadDocument(data, { tab = activeTab() } = {}) {
  const open = findDoc(data.path);
  const doc = open || makeDoc({ path: data.path, name: data.name || 'Untitled', contents: data.contents, mtime: data.mtime || 0 });
  clearImageCache();
  attachDoc(tab, doc, open ? docContent(open) : data.contents);
  const wasActive = activeTab() === tab;
  editorArea.activateTab(tab);
  // activateTab reports a change of tab, not a change of note within the tab.
  if (wasActive) onActivateTab(tab);
  tab.editor.view.focus();
}

/** Reload a document from disk into every tab that shows it, keeping each caret where it was. */
function reloadDoc(doc, contents, mtime) {
  doc.savedText = contents;
  doc.mtime = mtime;
  for (const tab of doc.tabs) {
    const pos = tab.editor.view.state.selection.main.head;
    tab.editor.load(contents, doc.path, !!state.settings.sourceMode);
    tab.editor.view.dispatch({ selection: { anchor: Math.min(pos, contents.length) } });
  }
  setDocDirty(doc, false);
  if (doc === activeDoc()) { refreshOutline(); updateCounts(); }
}

/** The open library, passed along so history snapshots land in it. */
function libraryOptions() {
  const libraryRoot = libraryWorkspace?.getFolder();
  return libraryRoot ? { libraryRoot } : {};
}

/**
 * Open a file. Resolves 'opened', 'cancelled' (the user kept unsaved work) or
 * 'failed'. A note already open in the pane is brought forward. Otherwise it
 * replaces the focused tab's note, unless `newTab` is set or that tab holds
 * unsaved edits that auto-save cannot save, in which case it opens in a new
 * tab. Moving from note to note within a tab is remembered for Back.
 */
async function openPath(filePath, { fromHistory = false, quiet = false, newTab = false, pane = null } = {}) {
  const targetPane = pane || editorArea.activePane();
  if (!fromHistory) {
    const open = targetPane.tabs.find((tab) => tab.doc.path && samePath(tab.doc.path, filePath));
    if (open) { editorArea.activateTab(open); return 'opened'; }
  }
  let tab = targetPane.active;
  const current = tab ? tab.doc : null;
  let replace = false;
  if (tab && isBlankTab(tab)) replace = true;
  else if (tab && !newTab) {
    if (!current.dirty || current.tabs.size > 1) replace = true;
    else if (current.path && state.settings.autoSave) {
      if (!(await save({ doc: current }))) return 'cancelled';
      replace = true;
    } else if (fromHistory) {
      if (!(await confirmDiscard(current))) return 'cancelled';
      replace = true;
    }
    // Otherwise the unsaved edits keep their tab and the note opens in a new one.
  }
  const previous = replace && current.path ? { path: current.path, pos: tab.editor.view.state.selection.main.head } : null;
  if (previous && !samePath(previous.path, filePath)) await offerTitleLinkUpdate(previous.path);
  let data = findDoc(filePath) ? { path: filePath } : null;
  if (!data) {
    data = await api.readFile(filePath, libraryOptions());
    if (data.error) {
      if (!quiet) toast('Could not open file: ' + data.error, { error: true });
      return 'failed';
    }
  }
  if (!replace) tab = addTab(makeDoc(), { pane: targetPane, activate: false });
  await loadDocument(data, { tab });
  if (previous && !fromHistory && !samePath(previous.path, filePath)) {
    tab.back.push(previous);
    if (tab.back.length > NAVIGATION_LIMIT) tab.back.shift();
    tab.forward = [];
  }
  updateNavigationButtons();
  persistSession();
  return 'opened';
}

function updateNavigationButtons() {
  const tab = editorArea && activeTab();
  el('btn-back').disabled = !tab || !tab.back.length;
  el('btn-forward').disabled = !tab || !tab.forward.length;
}

/** Go back (-1) or forward (+1) in the focused tab, skipping notes that no longer exist. */
async function navigate(direction) {
  const tab = activeTab();
  const from = direction < 0 ? tab.back : tab.forward;
  const to = direction < 0 ? tab.forward : tab.back;
  while (from.length) {
    const entry = from.pop();
    const current = state.path ? { path: state.path, pos: editor.view.state.selection.main.head } : null;
    const result = await openPath(entry.path, { fromHistory: true, quiet: true });
    if (result === 'cancelled') { from.push(entry); break; }
    if (result !== 'opened') continue;
    if (current) to.push(current);
    moveCaret(entry.pos);
    break;
  }
  updateNavigationButtons();
}

/** Put the caret at `pos` (clamped) and bring it into view. */
function moveCaret(pos, focus = true) {
  const target = Math.max(0, Math.min(Number(pos) || 0, editor.view.state.doc.length));
  editor.view.dispatch({ selection: { anchor: target }, effects: EditorView.scrollIntoView(target, { y: 'center' }) });
  if (focus) editor.view.focus();
}

/** Open a note at a character position (search hits, backlinks). */
async function openAtPosition(filePath, pos) {
  if (filePath !== state.path && (await openPath(filePath)) !== 'opened') return;
  if (filePath === state.path) moveCaret(pos);
}

async function openDialog() {
  const doc = await api.openDialog();
  if (doc) await openPath(doc.path);
}

/** File › New: a new tab with an unsaved note. */
function newDocument() {
  newUntitledTab();
  return true;
}

/**
 * `manual` marks a save the user asked for (Ctrl+S or the menu). Only those,
 * and leaving the note, offer to update links after a title change, so
 * auto-save never interrupts someone halfway through retyping a heading.
 */
async function save({ doc = activeDoc(), saveAs = false, manual = false } = {}) {
  if (doc.saving || !doc.tabs.size) return false;
  let target = doc.path;
  if (saveAs || !target) {
    const suggested = (doc.name && doc.name !== 'Untitled')
      ? doc.name
      : inferTitle(docContent(doc), 'Untitled').replace(/[\\/:*?"<>|]/g, '-').slice(0, 60) + '.md';
    target = await api.saveDialog(suggested);
    if (!target) return false;
  }

  doc.saving = true;
  const text = docContent(doc);
  const samePlace = !!doc.path && samePath(target, doc.path);
  const result = await api.writeFile(target, text, samePlace ? doc.mtime : null,
    { ...libraryOptions(), manual: manual || saveAs });
  doc.saving = false;

  if (result.conflict) {
    const choice = await confirmDialog({
      title: 'File changed on disk',
      message: '“' + doc.name + '” was saved by another device or app. Reload it, or save your draft as a separate file.',
      buttons: [
        { label: 'Reload from disk', value: 'reload', primary: true },
        { label: 'Save a copy', value: 'copy' },
        { label: 'Cancel', value: 'cancel' },
      ],
    });
    if (choice === 'reload') reloadDoc(doc, result.contents, result.mtime);
    else if (choice === 'copy') await save({ doc, saveAs: true });
    return false;
  }

  if (result.error) {
    toast('Save failed: ' + result.error, { error: true });
    return false;
  }

  if (!samePlace) {
    if (doc.path && findDoc(doc.path) === doc) docs.delete(docKey(doc.path));
    doc.path = target;
    docs.set(docKey(target), doc);
    for (const tab of doc.tabs) tab.editor.setDocPath(target);
    syncWatches();
  }
  doc.name = target.split(/[\\/]/).pop();
  doc.savedText = text;
  doc.mtime = result.mtime;
  // Typing during the save leaves the note dirty again.
  setDocDirty(doc, docContent(doc) !== text);
  if (doc === activeDoc()) updateTitle();

  if (!samePlace) {
    if (doc === activeDoc()) {
      sidebar.setActiveFile(target);
      libraryWorkspace?.setActiveFile(target);
    }
    sidebar.refresh();
    persistSession();
  }
  toast('Saved');
  if (sidebar.getTab() === 'insights') refreshInsights(true);
  void refreshLibrary(true);
  void refreshBacklinks(true);
  if (manual) await offerTitleLinkUpdate(target, { refresh: true });
  return true;
}

/**
 * After a note's title changes, offer to point links that still use the old
 * title at the new one. Escape leaves the offer pending for next time;
 * "Leave them" drops it. `refresh` re-checks the disk first, which a save that
 * just happened needs; switching notes relies on the watcher instead.
 */
async function offerTitleLinkUpdate(notePath, { refresh = false } = {}) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder || !notePath) return;
  const change = await api.titleChange(folder, notePath, refresh);
  if (!change || change.error || !change.links) return;
  const files = change.files.length;
  const choice = await confirmDialog({
    title: 'Update links to this note?',
    message: '“' + change.from + '” is now “' + change.to + '”. ' + change.links
      + (change.links === 1 ? ' link' : ' links') + ' in ' + files + (files === 1 ? ' note' : ' notes')
      + ' still use the old title.',
    buttons: [
      { label: 'Update links', value: 'update', primary: true },
      { label: 'Leave them', value: 'leave' },
    ],
  });
  if (choice === 'leave') {
    await api.dismissTitleChange(folder, notePath);
    return;
  }
  if (choice !== 'update') return;
  const result = await api.updateTitleLinks(folder, notePath);
  if (result?.error) {
    toast('Could not update links: ' + result.error, { error: true });
    return;
  }
  toast('Updated ' + result.links + (result.links === 1 ? ' link' : ' links')
    + (result.skipped.length ? '; ' + result.skipped.length + ' note(s) changed on disk and were left alone' : ''),
  { error: result.skipped.length > 0 });
  await refreshLibrary(true);
}

/** Returns false when the user cancels out of losing a document's unsaved work. */
async function confirmDiscard(doc = activeDoc()) {
  if (!doc.dirty) return true;
  const choice = await confirmDialog({
    title: 'Unsaved changes',
    message: '"' + doc.name + '" has changes that have not been saved.',
    buttons: [
      { label: 'Save', value: 'save', primary: true },
      { label: "Don't Save", value: 'discard' },
      { label: 'Cancel', value: 'cancel' },
    ],
  });
  // Not `manual`: switching notes offers the link update itself, once.
  if (choice === 'save') return save({ doc });
  return choice === 'discard';
}

/** Save a document 1.5 s after its last edit, whichever tab it is in. */
function scheduleAutoSave(doc = activeDoc()) {
  clearTimeout(doc.autoSaveTimer);
  if (!state.settings.autoSave || !doc.path) return;
  doc.autoSaveTimer = setTimeout(() => { if (doc.dirty && doc.tabs.size) save({ doc }); }, 1500);
}

// ---------------------------------------------------------------------------
// Tabs and split view
// ---------------------------------------------------------------------------
/** Before the window closes: ask about every note with unsaved changes. False keeps the window open. */
async function confirmCloseAll() {
  const dirty = [...new Set(editorArea.allTabs().map((tab) => tab.doc))].filter((doc) => doc.dirty);
  if (!dirty.length) return true;
  if (dirty.length === 1) return confirmDiscard(dirty[0]);
  const choice = await confirmDialog({
    title: 'Unsaved changes',
    message: dirty.length + ' notes have changes that have not been saved: '
      + dirty.slice(0, 5).map((doc) => '“' + doc.name + '”').join(', ') + (dirty.length > 5 ? ', …' : '') + '.',
    buttons: [
      { label: 'Save All', value: 'save', primary: true },
      { label: "Don't Save", value: 'discard' },
      { label: 'Cancel', value: 'cancel' },
    ],
  });
  if (choice === 'discard') return true;
  if (choice !== 'save') return false;
  for (const doc of dirty) if (!(await save({ doc }))) return false;
  return true;
}

/** Close a tab, asking first if it is the last view of a note with unsaved changes. */
async function closeTab(tab = activeTab()) {
  const doc = tab.doc;
  if (doc.tabs.size === 1) {
    if (!(await confirmDiscard(doc))) return false;
    if (doc.path) await offerTitleLinkUpdate(doc.path);
  }
  doc.tabs.delete(tab);
  editorArea.removeTab(tab);
  releaseDoc(doc);
  // A window always has at least one tab.
  if (!editorArea.allTabs().length) newUntitledTab();
  persistSession();
  return true;
}

/** Open the focused note in the other pane, splitting the editor first if needed. */
function splitEditor(orientation = null) {
  const tab = activeTab();
  const other = editorArea.split(orientation || state.settings.splitOrientation || 'row');
  const existing = other.tabs.find((item) => item.doc === tab.doc);
  if (existing) editorArea.activateTab(existing);
  else addTab(tab.doc, { pane: other });
  void setSettings({ splitOrientation: editorArea.orientation() });
}

/** Back to one pane: the other pane's tabs join the focused one. */
function unsplit(closing = null) {
  const panes = editorArea.panes();
  if (panes.length < 2) return;
  const remove = closing || panes.find((pane) => pane !== editorArea.activePane());
  const keep = panes.find((pane) => pane !== remove);
  for (const tab of [...remove.tabs]) editorArea.moveTab(tab, keep, keep.tabs.length);
  persistSession();
}

function moveToOtherPane(tab = activeTab()) {
  const other = editorArea.otherPane(tab.pane) || editorArea.split(state.settings.splitOrientation || 'row');
  editorArea.moveTab(tab, other, other.tabs.length);
}

async function showTabMenu(tab, x, y) {
  const split = editorArea.panes().length > 1;
  const choice = await api.showContextMenu([
    { id: 'close', label: 'Close' },
    { id: 'close-others', label: 'Close Others', enabled: tab.pane.tabs.length > 1 },
    { type: 'separator' },
    { id: 'split', label: split ? 'Open in Other Pane' : 'Split Right' },
    { id: 'move', label: split ? 'Move to Other Pane' : 'Move to New Pane' },
    { type: 'separator' },
    { id: 'reveal', label: 'Show in Folder', enabled: !!tab.doc.path },
    { id: 'copy-path', label: 'Copy Path', enabled: !!tab.doc.path },
  ], x, y);
  if (choice === 'close') await closeTab(tab);
  else if (choice === 'close-others') {
    for (const other of [...tab.pane.tabs]) if (other !== tab && !(await closeTab(other))) break;
  } else if (choice === 'split') { editorArea.activateTab(tab); splitEditor(); }
  else if (choice === 'move') moveToOtherPane(tab);
  else if (choice === 'reveal') api.revealInExplorer(tab.doc.path);
  else if (choice === 'copy-path') { await navigator.clipboard.writeText(tab.doc.path); toast('Path copied'); }
}

let sessionTimer = null;
let restoringSession = false;

/** Remember open tabs and the split layout, so the next start opens them again. */
function persistSession() {
  if (restoringSession || !editorArea) return;
  clearTimeout(sessionTimer);
  sessionTimer = setTimeout(() => {
    const panes = editorArea.panes().map((pane) => {
      const tabs = pane.tabs.filter((tab) => tab.doc.path);
      return { tabs: tabs.map((tab) => tab.doc.path), active: Math.max(0, tabs.indexOf(pane.active)) };
    });
    void setSettings({ session: {
      panes, orientation: editorArea.orientation(), ratio: editorArea.ratio(),
      focused: Math.max(0, editorArea.panes().indexOf(editorArea.activePane())),
    } });
  }, 400);
}

/** Reopen the tabs and split saved by `persistSession`. Missing files are skipped. */
async function restoreSession(session) {
  if (!session || !Array.isArray(session.panes) || !session.panes.some((pane) => (pane.tabs || []).length)) return false;
  restoringSession = true;
  try {
    const saved = session.panes.filter((pane) => (pane.tabs || []).length).slice(0, 2);
    const panes = [editorArea.activePane()];
    if (saved.length > 1) {
      editorArea.setRatio(session.ratio);
      panes.push(editorArea.split(session.orientation === 'column' ? 'column' : 'row'));
    }
    for (let i = 0; i < saved.length; i++) {
      for (const filePath of saved[i].tabs) await openPath(filePath, { newTab: true, quiet: true, pane: panes[i] });
      const active = panes[i].tabs.find((tab) => tab.doc.path && samePath(tab.doc.path, saved[i].tabs[saved[i].active] || ''));
      if (active) editorArea.activateTab(active, { focus: false });
    }
    // A pane whose files have all gone is not worth keeping.
    editorArea.removeEmptyPanes();
    const focused = editorArea.panes()[session.focused] || editorArea.panes()[0];
    if (focused && focused.active) editorArea.activateTab(focused.active);
  } finally {
    restoringSession = false;
  }
  persistSession();
  return true;
}

// ---------------------------------------------------------------------------
// Outline & counts
// ---------------------------------------------------------------------------
function computeHeadings(text) {
  const lines = text.split('\n');
  const out = [];
  let inFence = false;
  let fence = '';
  let offset = 0;
  let start = 0;

  // Skip YAML front matter, whose closing `---` would otherwise read as a
  // setext underline and turn the last metadata key into a heading.
  if (/^---\s*$/.test(lines[0] || '')) {
    for (let i = 1; i < lines.length; i++) {
      if (/^(---|\.\.\.)\s*$/.test(lines[i])) { start = i + 1; break; }
    }
  }
  for (let i = 0; i < start; i++) offset += lines[i].length + 1;

  for (let i = start; i < lines.length; i++) {
    const line = lines[i];
    const fenceMatch = /^\s*(```+|~~~+)/.exec(line);
    if (fenceMatch) {
      if (!inFence) { inFence = true; fence = fenceMatch[1][0]; }
      else if (fenceMatch[1][0] === fence) { inFence = false; }
    } else if (!inFence) {
      const atx = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
      if (atx) {
        out.push({ level: atx[1].length, text: atx[2], line: i, pos: offset });
      } else if (i > start && /^(=+|-{2,})\s*$/.test(line) && lines[i - 1].trim()) {
        const level = line.trim()[0] === '=' ? 1 : 2;
        const prev = out[out.length - 1];
        const prevLine = lines[i - 1].trim();
        if (!prev || prev.line !== i - 1) {
          out.push({ level, text: prevLine, line: i - 1, pos: offset - lines[i - 1].length - 1 });
        }
      }
    }
    offset += line.length + 1;
  }
  return out;
}

function refreshOutline() {
  state.headings = computeHeadings(editor.getContent());
  sidebar.setOutline(state.headings);
}

function currentHeadingIndex(pos) {
  let index = -1;
  for (let i = 0; i < state.headings.length; i++) {
    if (state.headings[i].pos <= pos) index = i;
    else break;
  }
  return index;
}

const WORD_RE = /[\p{L}\p{N}'’\-]+/gu;

function updateCounts() {
  const text = editor.getContent();
  const words = (text.match(WORD_RE) || []).length;
  const chars = text.length;
  const charsNoSpace = text.replace(/\s/g, '').length;
  const lines = editor.view.state.doc.lines;
  const minutes = Math.max(1, Math.round(words / 220));

  const label = [
    words.toLocaleString() + (words === 1 ? ' word' : ' words'),
    chars.toLocaleString() + ' characters',
    charsNoSpace.toLocaleString() + ' chars (no spaces)',
    lines.toLocaleString() + (lines === 1 ? ' line' : ' lines'),
  ][state.wordMode % 4];

  el('status-words').textContent = label;
  el('status-reading').textContent = words ? minutes + ' min read' : '';
}

function updatePosition(cmState) {
  const head = cmState.selection.main.head;
  const line = cmState.doc.lineAt(head);
  const selected = cmState.selection.ranges.reduce((n, r) => n + (r.to - r.from), 0);
  el('status-position').textContent = selected
    ? 'Ln ' + line.number + ', Col ' + (head - line.from + 1) + '  ·  ' + selected + ' selected'
    : 'Ln ' + line.number + ', Col ' + (head - line.from + 1);
  sidebar.highlightHeading(currentHeadingIndex(head));
}

/**
 * Follow a `[[wiki-link]]` or a relative Markdown path. Resolution happens in
 * main, which knows the working folder; a target with nowhere to go becomes an
 * offer to create it, so linking can run ahead of writing.
 */
async function followInternalLink(target) {
  const folder = sidebar.getFolder();
  const result = await api.resolveLink(target, state.path, folder);

  if (result && result.anchorOnly) {
    if (result.anchor) jumpToAnchor(result.anchor);
    return;
  }

  // Several notes share this name or title: ask rather than guess.
  if (result && result.ambiguous) {
    const chosen = await pickNote('Which note?', '“' + target + '” matches more than one note.', result.ambiguous);
    if (!chosen) return;
    await openPath(chosen);
    if (result.anchor && state.path === chosen) jumpToAnchor(result.anchor);
    return;
  }

  if (result && result.path) {
    await openPath(result.path);
    if (result.anchor && state.path === result.path) jumpToAnchor(result.anchor);
    return;
  }

  if (result && result.trashed) {
    toast('“' + target + '” is in Trash. Restore it from the Trash view to follow this link.', { error: true });
    return;
  }

  if (!result || !result.suggested) {
    toast('Could not resolve “' + target + '”.', { error: true });
    return;
  }

  // In a library, a plain name becomes a library note titled with it, so the
  // link resolves by title. Path-like targets are created where they point.
  const library = libraryWorkspace?.getFolder();
  const asLibraryNote = !!(library && result.name && !/[\\/]/.test(result.name)
    && !/\.(?:md|markdown|mdown|mkd|mdx|txt)$/i.test(result.name));
  const name = asLibraryNote ? result.name : result.suggested.split(/[\\/]/).pop();
  const choice = await confirmDialog({
    title: 'Create this note?',
    message: '“' + target + '” does not exist yet. Create ' + name + '?',
    buttons: [
      { label: 'Create', value: 'create', primary: true },
      { label: 'Cancel', value: 'cancel' },
    ],
  });
  if (choice !== 'create') return;

  const created = asLibraryNote
    ? await api.createLibraryNote(library, result.name)
    : await api.createLinkedFile(result.suggested, target);
  if (created.error) {
    toast('Could not create the file: ' + created.error, { error: true });
    return;
  }
  await openPath(created.path);
  sidebar.refresh();
  void refreshLibrary(true);
}

/** A modal list of notes; resolves with the chosen path, or null. */
async function pickNote(title, message, notes) {
  const chosen = await showModal('<h2>' + escape(title) + '</h2><p class="modal-sub">' + escape(message) + '</p>'
    + '<div class="quick-results">' + notes.map((note, i) =>
      '<button class="quick-row" data-index="' + i + '"><strong>' + escape(note.title || note.relative)
      + '</strong><small>' + escape(note.relative || note.path) + '</small></button>').join('') + '</div>'
    + '<div class="modal-actions"><button class="secondary" data-close="cancel">Cancel</button></div>',
  (root, done) => root.querySelectorAll('.quick-row').forEach((row) =>
    row.addEventListener('click', () => done(notes[Number(row.dataset.index)].path))));
  return typeof chosen === 'string' ? chosen : null;
}

/** Scroll to the heading a link's `#anchor` names. */
function jumpToAnchor(anchor) {
  const slug = String(anchor).toLowerCase().replace(/[^\w]+/g, '-').replace(/^-|-$/g, '');
  const match = state.headings.find((h) =>
    h.text.toLowerCase().replace(/[^\w]+/g, '-').replace(/^-|-$/g, '') === slug);
  if (match) goToHeading(match);
}

function goToHeading(heading) {
  if (!heading) return;
  const pos = Math.min(heading.pos, editor.view.state.doc.length);
  editor.view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 60 }),
  });
  editor.view.focus();
}

// ---------------------------------------------------------------------------
// View modes
// ---------------------------------------------------------------------------
function applyViewModes() {
  const s = state.settings;
  for (const tab of editorArea.allTabs()) {
    const tabEditor = tab.editor;
    tabEditor.reconfigure('focus', s.focusMode ? focusMode : []);
    tabEditor.reconfigure('typewriter', s.typewriterMode ? typewriterMode : []);
    tabEditor.reconfigure('autoPair', s.autoPair ? markdownAutoPair : []);
    tabEditor.reconfigure('spellcheck', EditorView.contentAttributes.of({
      spellcheck: s.spellCheck ? 'true' : 'false',
    }));
    tabEditor.reconfigure('metrics', metricsTheme(s));
    tabEditor.setSourceMode(!!s.sourceMode);
  }

  const app = el('app');
  app.classList.toggle('sidebar-hidden', !s.sidebarVisible);
  app.classList.toggle('statusbar-hidden', !s.showStatusBar);
  app.classList.toggle('source-mode', !!s.sourceMode);
  app.classList.toggle('zen', state.zen);
  app.style.setProperty('--sidebar-width', s.sidebarWidth + 'px');
  app.style.setProperty('--library-width', (s.libraryWidth || 220) + 'px');
  app.style.setProperty('--note-list-width', (s.noteListWidth || 310) + 'px');

  el('btn-sidebar').classList.toggle('is-active', s.sidebarVisible);
  el('btn-source').classList.toggle('is-active', !!s.sourceMode);
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------
const PANDOC_FORMATS = new Set(['docx', 'odt', 'rtf', 'epub', 'latex', 'rst', 'textile', 'mediawiki']);

async function runExport(format, outputPath = null, presentation = null) {
  const markdown = editor.getContent();
  if (!markdown.trim()) {
    toast('Nothing to export yet.', { error: true });
    return;
  }
  const opts = {
    docPath: state.path,
    libraryRoot: libraryWorkspace?.getFolder() || undefined,
    title: inferTitle(markdown, state.name.replace(/\.[^.]+$/, '')),
  };
  if (presentation) {
    opts.pageSize = presentation.pageSize;
    opts.margin = presentation.margin;
    opts.headerFooter = presentation.headerFooter;
  }
  if (outputPath) opts.outputPath = outputPath;

  try {
    if (format === 'pdf') {
      toast('Building PDF…');
      const html = await buildExportHtml({
        markdown,
        docPath: state.path,
        theme: state.settings.theme,
        dark: false,
        mode: 'pdf',
        fontSize: 12,
        embedImages: false,
        presentation,
        pageSize: presentation?.pageSize || 'A4',
        margin: presentation?.margin || 0.6,
      });
      const result = await api.exportPdf(html, { ...opts, outline: true });
      report(result, 'PDF');
      return;
    }

    if (format === 'html') {
      const html = await buildExportHtml({
        markdown,
        docPath: state.path,
        theme: state.settings.theme,
        dark: isDark(),
        mode: 'html',
        fontSize: state.settings.fontSize,
        contentWidth: state.settings.contentWidth,
        embedImages: true,
        presentation,
      });
      const result = await api.exportHtml(html, opts);
      report(result, 'HTML');
      return;
    }

    if (format === 'txt') {
      const result = await api.exportText(buildPlainText(markdown), opts);
      report(result, 'plain text');
      return;
    }

    if (format === 'markdown') {
      const result = await api.exportMarkdown(markdown, opts);
      report(result, 'Markdown');
      if (result?.skipped?.length) toast('Markdown exported, but ' + result.skipped.length + ' linked file(s) could not be copied.', { error: true });
      return;
    }

    if (format === 'jpg') {
      toast('Rendering JPEG…');
      const html = await buildExportHtml({
        markdown, docPath: state.path, theme: state.settings.theme, dark: false,
        mode: 'html', fontSize: state.settings.fontSize, contentWidth: state.settings.contentWidth,
        embedImages: true, presentation,
      });
      const result = await api.exportJpg(html, opts);
      report(result, 'JPEG');
      return;
    }

    if (PANDOC_FORMATS.has(format)) {
      toast('Converting with Pandoc…');
      const result = await api.exportPandoc(markdown, format, opts);
      report(result, format.toUpperCase());
      return;
    }

    toast('Unknown export format: ' + format, { error: true });
  } catch (err) {
    toast('Export failed: ' + (err && err.message ? err.message : err), { error: true });
  }
}

function report(result, label) {
  if (!result || result.canceled) return;
  if (result.error) toast(label + ' export failed: ' + result.error, { error: true });
  else toast('Exported ' + label + ' to ' + result.path.split(/[\\/]/).pop());
}

async function refreshInsights(refresh = false) {
  const folder = sidebar.getFolder();
  const targetPath = state.path;
  if (!folder) { sidebar.setInsights(null); return; }
  sidebar.setInsights(null);
  try {
    workspaceOverview = await api.workspaceOverview(folder, targetPath, refresh);
    if (sidebar.getFolder() !== folder || state.path !== targetPath) return;
    sidebar.setInsights(workspaceOverview);
  } catch (err) {
    sidebar.setInsights({ error: err.message });
  }
}

let libraryRequest = 0;
let libraryRefreshTimer = null;

/** Pass `refresh` after Frisket's own writes; watcher-driven updates are already indexed. */
async function refreshLibrary(refresh = false) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) return;
  const request = ++libraryRequest;
  try {
    // Per-note context (backlinks, attachments) is only worth computing for Insights.
    const target = sidebar.getTab() === 'insights' ? state.path : null;
    const overview = await api.workspaceOverview(folder, target, refresh);
    // A later refresh has already been issued; let it win.
    if (request !== libraryRequest) return;
    if (libraryWorkspace?.getFolder() !== folder || overview.error) {
      if (overview?.error) toast('Library index: ' + overview.error, { error: true });
      return;
    }
    workspaceOverview = overview;
    libraryWorkspace.setOverview(overview);
    // Tab labels follow note titles, which may have just changed.
    editorArea.refresh();
    if (sidebar.getTab() === 'insights') sidebar.setInsights(overview);
  } catch (err) {
    toast('Library index: ' + err.message, { error: true });
  }
}

async function createLibraryNote() {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) { await chooseFolder(); return; }
  const result = await api.createLibraryNote(folder, 'Untitled');
  if (result?.error) { toast('Could not create note: ' + result.error, { error: true }); return; }
  if (!result?.path) return;
  await openPath(result.path, { newTab: true });
  await refreshLibrary(true);
}

async function trashLibraryNote(notePath) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) return;
  const doc = findDoc(notePath);
  if (doc && !(await confirmDiscard(doc))) return;
  const result = await api.trashLibraryNote(folder, notePath);
  if (result?.error) { toast('Could not move note to Trash: ' + result.error, { error: true }); return; }
  // Close every tab showing the trashed note; its edits were saved or discarded above.
  if (doc) {
    doc.dirty = false;
    for (const tab of [...doc.tabs]) await closeTab(tab);
  }
  await refreshLibrary(true);
}

async function restoreLibraryNote(notePath) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) return;
  const result = await api.restoreLibraryNote(folder, notePath);
  if (result?.error) { toast('Could not restore note: ' + result.error, { error: true }); return; }
  await refreshLibrary(true);
  if (result.path) await openPath(result.path);
}

async function deleteLibraryNote(notePath) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) return;
  const choice = await confirmDialog({
    title: 'Delete note permanently?',
    message: 'This removes the note from Frisket Trash and cannot be undone.',
    buttons: [{ label: 'Delete permanently', value: 'delete', primary: true }, { label: 'Cancel', value: 'cancel' }],
  });
  if (choice !== 'delete') return;
  const result = await api.deleteLibraryNote(folder, notePath);
  if (result?.error) { toast('Could not delete note: ' + result.error, { error: true }); return; }
  await refreshLibrary(true);
}

// ---------------------------------------------------------------------------
// Backlinks pane
// ---------------------------------------------------------------------------
let backlinksRequest = 0;

function backlinksVisible() {
  return !!state.settings.backlinksVisible;
}

async function setBacklinksVisible(visible) {
  await setSettings({ backlinksVisible: !!visible });
  el('backlinks-pane').hidden = !visible;
  el('btn-backlinks').classList.toggle('is-active', !!visible);
  if (visible) void refreshBacklinks();
}

/** Linked and unlinked mentions of the open note, computed by the index on request. */
async function refreshBacklinks(refresh = false) {
  if (!backlinksVisible()) return;
  const body = el('backlinks-body');
  const folder = libraryWorkspace?.getFolder();
  const target = state.path;
  if (!folder || !target) {
    body.innerHTML = '<div class="backlinks-empty">' + (folder ? 'Save this note to see what links to it.'
      : 'Open a library to see which notes link here.') + '</div>';
    return;
  }
  const request = ++backlinksRequest;
  const context = await api.noteContext(folder, target, refresh);
  if (request !== backlinksRequest || state.path !== target) return;
  if (!context || context.error || !context.found) {
    body.innerHTML = '<div class="backlinks-empty">' + escape(context?.error || 'This note is not in the open library.') + '</div>';
    return;
  }
  const linked = context.backlinks.linked || [];
  const unlinked = context.backlinks.unlinked || [];
  const row = (item, index, kind) => '<button class="backlink" data-kind="' + kind + '" data-index="' + index + '"><strong>'
    + escape(item.title || item.relative) + (item.ambiguous ? ' <span class="insight-flag" title="This link matches more than one note">ambiguous</span>' : '')
    + '</strong><small>' + escape(item.excerpt || '') + '</small></button>';
  body.innerHTML = '<h3>Linked mentions · ' + linked.length + '</h3>'
    + (linked.length ? linked.map((item, i) => row(item, i, 'linked')).join('') : '<div class="backlinks-empty">No notes link here yet.</div>')
    + '<h3>Unlinked mentions · ' + unlinked.length + '</h3>'
    + (unlinked.length ? unlinked.map((item, i) => '<div class="backlink-row">' + row(item, i, 'unlinked')
      + '<button class="backlink-link" data-index="' + i + '" title="Turn this mention into a link">Link</button></div>').join('')
      : '<div class="backlinks-empty">No other notes mention “' + escape(context.title) + '”.</div>');
  body.querySelectorAll('.backlink').forEach((button) => button.addEventListener('click', () => {
    const item = (button.dataset.kind === 'linked' ? linked : unlinked)[Number(button.dataset.index)];
    if (item) void openAtPosition(item.path, item.pos);
  }));
  body.querySelectorAll('.backlink-link').forEach((button) => button.addEventListener('click', async () => {
    const item = unlinked[Number(button.dataset.index)];
    if (!item) return;
    const result = await api.linkMention(folder, item.path, item.pos, item.length, item.text, target);
    if (result?.error) toast('Could not link the mention: ' + result.error, { error: true });
    else toast('Linked in ' + (item.title || item.relative));
    void refreshBacklinks(true);
  }));
}

// ---------------------------------------------------------------------------
// Version history
// ---------------------------------------------------------------------------
function diffHtml(ops) {
  return withContext(ops, 3).map((op) => {
    if (op.type === 'skip') return '<div class="diff-skip">… ' + op.count + ' unchanged line' + (op.count === 1 ? '' : 's') + '</div>';
    const cls = op.type === 'add' ? 'diff-add' : op.type === 'del' ? 'diff-del' : 'diff-same';
    const sign = op.type === 'add' ? '+ ' : op.type === 'del' ? '− ' : '  ';
    return '<div class="' + cls + '">' + sign + escape(op.text || ' ') + '</div>';
  }).join('') || '<div class="diff-skip">No differences.</div>';
}

/** Browse snapshots of a note, compare one with the editor, and restore it as an undoable edit. */
async function showHistory(notePath = state.path) {
  if (!notePath) { toast('Save this note first; versions are kept from its first save.', { error: true }); return; }
  if (notePath !== state.path && (await openPath(notePath)) !== 'opened') return;
  const libraryRoot = libraryWorkspace?.getFolder() || null;
  const listed = await api.historyList(notePath, libraryRoot);
  if (listed?.error) { toast('Version history: ' + listed.error, { error: true }); return; }
  const versions = listed.versions || [];
  if (!versions.length) { toast('No earlier versions yet. Frisket keeps one as you edit and save.'); return; }
  const when = (iso) => new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  const restored = await showModal('<h2>Version History</h2><p class="modal-sub">' + escape(state.name)
    + ' · newest first. The diff shows what restoring would change.</p>'
    + '<div class="history-layout"><div class="history-list">' + versions.map((version, i) =>
      '<button class="history-item" data-index="' + i + '">' + escape(when(version.time))
      + '<small>' + Math.max(1, Math.round(version.size / 1024)) + ' KB</small></button>').join('') + '</div>'
    + '<div><div class="diff-summary" id="history-summary">Choose a version.</div><div class="diff" id="history-diff"></div></div></div>'
    + '<div class="modal-actions"><button class="secondary" data-close="cancel">Close</button>'
    + '<button class="primary" id="history-restore" disabled>Restore this version</button></div>',
  (root, done) => {
    root.classList.add('wide');
    let selected = null;
    const choose = async (index) => {
      root.querySelectorAll('.history-item').forEach((item) => item.classList.toggle('is-active', Number(item.dataset.index) === index));
      const result = await api.historyRead(notePath, libraryRoot, versions[index].id);
      if (result?.error) { root.querySelector('#history-summary').textContent = result.error; return; }
      selected = { text: result.contents, time: versions[index].time };
      const ops = lineDiff(editor.getContent(), result.contents);
      const { added, removed } = diffStats(ops);
      root.querySelector('#history-summary').textContent = added || removed
        ? 'Restoring would add ' + added + ' and remove ' + removed + ' line' + (removed === 1 ? '' : 's') + '.'
        : 'This version matches the note as it is now.';
      root.querySelector('#history-diff').innerHTML = diffHtml(ops);
      root.querySelector('#history-restore').disabled = !(added || removed);
    };
    root.querySelectorAll('.history-item').forEach((item) => item.addEventListener('click', () => choose(Number(item.dataset.index))));
    root.querySelector('#history-restore').addEventListener('click', () => { if (selected) done(selected); });
    void choose(0);
  });
  el('modal').classList.remove('wide');
  if (restored && typeof restored === 'object') {
    editor.view.dispatch({ changes: { from: 0, to: editor.view.state.doc.length, insert: restored.text } });
    toast('Restored the version from ' + when(restored.time) + '. Undo with Ctrl+Z.');
  }
}

// ---------------------------------------------------------------------------
// Sync conflicts
// ---------------------------------------------------------------------------
const CONFLICT_NAMES = {
  'conflicted-copy': 'a conflicted copy made by Dropbox or Nextcloud', syncthing: 'a Syncthing conflict copy',
  onedrive: 'a copy OneDrive made on another device', 'duplicate-id': 'a second note with the same Frisket ID (iCloud or a manual copy)',
};

async function resolveConflict(copyPath) {
  const folder = libraryWorkspace?.getFolder();
  const note = (workspaceOverview?.notes || []).find((item) => item.path === copyPath);
  if (!folder || !note || !note.conflict) { toast('That note is no longer a conflict copy.'); return; }
  const copy = await api.peekFile(copyPath);
  const original = note.conflict.original ? await api.peekFile(note.conflict.original) : null;
  if (copy.error) { toast(copy.error, { error: true }); return; }
  const ops = original && !original.error ? lineDiff(original.contents, copy.contents) : null;
  const stats = ops ? diffStats(ops) : null;
  const name = (p) => escape(String(p).split(/[\\/]/).pop());
  const buttons = [
    ...(ops ? [{ label: 'Keep original', value: 'keep-original', hint: 'Moves the copy to Trash.' },
      { label: 'Keep this copy', value: 'keep-copy', hint: 'Replaces the original; its text is kept in version history.' }] : []),
    { label: 'Keep both', value: 'keep-both', hint: 'Makes the copy an ordinary note.' },
  ];
  const choice = await showModal('<h2>Resolve sync conflict</h2><p class="modal-sub">“' + name(copyPath) + '” is '
    + escape(CONFLICT_NAMES[note.conflict.kind] || 'a conflict copy')
    + (ops ? ' of “' + name(note.conflict.original) + '”. Lines marked + are only in the copy; − only in the original.' : '. The original is missing.') + '</p>'
    + (ops ? '<div class="diff-summary">The copy adds ' + stats.added + ' and removes ' + stats.removed + ' lines.</div><div class="diff">' + diffHtml(ops) + '</div>' : '')
    + '<div class="modal-actions"><button class="secondary" data-close="cancel">Cancel</button><button class="secondary" id="conflict-open">Open copy</button>'
    + buttons.map((button, i) => '<button class="' + (i === 0 ? 'primary' : 'secondary') + '" data-action="' + button.value
      + '" title="' + escape(button.hint) + '">' + escape(button.label) + '</button>').join('') + '</div>',
  (root, done) => {
    root.classList.add('wide');
    root.querySelector('#conflict-open').addEventListener('click', () => done('open'));
    root.querySelectorAll('[data-action]').forEach((button) => button.addEventListener('click', () => done(button.dataset.action)));
  });
  el('modal').classList.remove('wide');
  if (choice === 'open') { await openPath(copyPath); return; }
  if (!choice || choice === true) return;
  const result = await api.resolveConflict(folder, copyPath, choice);
  if (result?.error) { toast('Could not resolve the conflict: ' + result.error, { error: true }); return; }
  toast(choice === 'keep-both' ? 'Kept both notes.' : choice === 'keep-copy' ? 'The copy replaced the original.' : 'Kept the original; the copy is in Trash.');
  await refreshLibrary(true);
}

// ---------------------------------------------------------------------------
// Pins, daily notes, imports
// ---------------------------------------------------------------------------
async function togglePin(notePath = state.path, pinned = null) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder || !notePath) { toast('Open a note in a library to pin it.', { error: true }); return; }
  const summary = (workspaceOverview?.notes || []).find((note) => note.path === notePath);
  const next = pinned === null ? !(summary && summary.pinned) : pinned;
  // The pin is written to the file, so save pending edits first.
  if (notePath === state.path && state.dirty && !(await save())) return;
  const result = await api.setPinned(folder, notePath, next);
  if (result?.error) { toast('Could not ' + (next ? 'pin' : 'unpin') + ' the note: ' + result.error, { error: true }); return; }
  toast(next ? 'Pinned to the top' : 'Unpinned');
  await refreshLibrary(true);
}

function localDate(now = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
}

/** Open (or create) `Daily/YYYY-MM-DD.md`, from `Templates/Daily.md` when there is one. */
async function openDailyNote() {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) { toast('Open a library first; daily notes live in its Daily folder.', { error: true }); return; }
  const date = localDate();
  const templates = await api.listTemplates(folder);
  const daily = (templates?.templates || []).find((item) => /^daily\.(?:md|markdown)$/i.test(item.name));
  const body = daily ? applyTemplate(daily.contents, { title: date }) : null;
  const result = await api.dailyNote(folder, date, body);
  if (result?.error) { toast('Could not open today’s note: ' + result.error, { error: true }); return; }
  if ((await openPath(result.path)) === 'opened') moveCaret(editor.view.state.doc.length);
  if (result.created) void refreshLibrary(true);
}

const IMPORT_NAMES = { evernote: 'Evernote', notion: 'Notion', 'apple-notes': 'Apple Notes' };

async function importFrom(kind, source = null) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) { toast('Open a library first; imported notes go into its Imported folder.', { error: true }); return null; }
  toast('Importing from ' + IMPORT_NAMES[kind] + '…');
  const report = await api.importNotes(folder, kind, source);
  if (!report || report.canceled) return report;
  if (report.error) { toast(IMPORT_NAMES[kind] + ' import failed: ' + report.error, { error: true }); return report; }
  await refreshLibrary(true);
  const skipped = report.skipped || [];
  await showModal('<h2>Import finished</h2><p class="modal-sub">'
    + (report.notes ? 'Imported ' + report.notes + ' note' + (report.notes === 1 ? '' : 's') + ' and ' + report.attachments
      + ' attachment' + (report.attachments === 1 ? '' : 's') + ' into <strong>' + escape(report.folder) + '</strong>.'
      : 'Nothing was imported.') + '</p>'
    + (skipped.length ? '<h3>Skipped</h3><div class="import-report">' + skipped.slice(0, 50).map((item) =>
      '<div>' + escape(item.title || 'Untitled') + ' — ' + escape(item.reason === 'locked' ? 'locked note' : item.reason) + '</div>').join('')
      + (skipped.length > 50 ? '<div>… and ' + (skipped.length - 50) + ' more</div>' : '') + '</div>' : '')
    + '<div class="modal-actions"><button class="primary" data-close="ok">Done</button></div>');
  return report;
}

function quickMatchScore(note, query) {
  if (!query) return 0;
  const fields = [note.title || '', note.name || '', note.relative || ''];
  let best = -1;
  for (const field of fields) {
    const value = field.toLowerCase();
    const at = value.indexOf(query);
    if (at >= 0) { best = Math.max(best, 1000 - at); continue; }
    let cursor = 0;
    let score = 0;
    for (const character of query) {
      const found = value.indexOf(character, cursor);
      if (found < 0) { score = -1; break; }
      score += found === cursor ? 12 : 4;
      cursor = found + 1;
    }
    best = Math.max(best, score);
  }
  return best;
}

async function showQuickOpen() {
  const folder = sidebar.getFolder();
  if (!folder) { toast('Open a folder first.', { error: true }); return; }
  const overview = await api.workspaceOverview(folder, null, false);
  if (overview.error) { toast(overview.error, { error: true }); return; }
  const notes = overview.notes || [];
  const selected = await showModal(
    '<h2>Quick Open</h2><input id="quick-query" type="text" placeholder="Find a Markdown file…" autofocus>'
      + '<div id="quick-results" class="quick-results"></div>'
      + '<div class="modal-actions"><button class="secondary" data-close="cancel">Cancel</button></div>',
    (root, done) => {
      const input = root.querySelector('#quick-query');
      const results = root.querySelector('#quick-results');
      let matches = [];
      let active = 0;
      const render = () => {
        const q = input.value.trim().toLowerCase();
        matches = notes.map((note) => ({ note, score: quickMatchScore(note, q) }))
          .filter((item) => item.score >= 0)
          .sort((a, b) => b.score - a.score || a.note.title.localeCompare(b.note.title))
          .slice(0, 60).map((item) => item.note);
        active = Math.min(active, Math.max(0, matches.length - 1));
        results.innerHTML = matches.length ? matches.map((note, i) =>
          '<button class="quick-row' + (i === active ? ' is-active' : '') + '" data-index="' + i + '">'
          + '<strong>' + escape(note.title || note.name) + '</strong><small>' + escape(note.relative) + '</small></button>').join('')
          : '<div class="empty-note">No matching Markdown files.</div>';
        results.querySelectorAll('.quick-row').forEach((row) => row.addEventListener('click', () => done(matches[Number(row.dataset.index)].path)));
      };
      input.addEventListener('input', () => { active = 0; render(); });
      input.addEventListener('keydown', (event) => {
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault();
          active = Math.max(0, Math.min(matches.length - 1, active + (event.key === 'ArrowDown' ? 1 : -1)));
          render();
        } else if (event.key === 'Enter' && matches[active]) done(matches[active].path);
      });
      render();
      setTimeout(() => input.focus(), 0);
    },
  );
  if (selected && selected !== 'cancel') await openPath(selected);
}

async function showTagNotes(tag) {
  const folder = sidebar.getFolder();
  if (!folder) return;
  const overview = await api.workspaceOverview(folder, null, false);
  if (overview.error) { toast(overview.error, { error: true }); return; }
  const notes = (overview.notes || []).filter((note) => (note.tags || []).some((value) => value.toLowerCase() === tag.toLowerCase()));
  const chosen = await showModal('<h2>#' + escape(tag) + '</h2>'
    + (notes.length ? '<div class="quick-results">' + notes.map((note, i) =>
      '<button class="quick-row" data-index="' + i + '"><strong>' + escape(note.title)
      + '</strong><small>' + escape(note.relative) + '</small></button>').join('') + '</div>'
      : '<p>No notes with this tag.</p>')
    + '<div class="modal-actions"><button class="primary" data-close="ok">Close</button></div>',
  (root, done) => root.querySelectorAll('.quick-row').forEach((row) =>
    row.addEventListener('click', () => done(notes[Number(row.dataset.index)].path))));
  if (typeof chosen === 'string') await openPath(chosen);
}

async function saveSearch(query) {
  const current = Array.isArray(state.settings.savedSearches) ? state.settings.savedSearches : [];
  if (current.includes(query)) return;
  const savedSearches = [...current, query].slice(-20);
  await setSettings({ savedSearches });
  sidebar.setSavedSearches(savedSearches);
  toast('Search saved');
}

async function deleteSavedSearch(query) {
  const savedSearches = (state.settings.savedSearches || []).filter((item) => item !== query);
  await setSettings({ savedSearches });
  sidebar.setSavedSearches(savedSearches);
}

async function chooseTemplate() {
  const folder = sidebar.getFolder();
  if (!folder) { toast('Open a folder first.', { error: true }); return null; }
  const result = await api.listTemplates(folder);
  if (result.error) { toast(result.error, { error: true }); return null; }
  if (!result.templates.length) {
    toast('Add Markdown files to the Templates folder first.', { error: true });
    return null;
  }
  const chosen = await showModal(
    '<h2>Templates</h2><p class="modal-sub">Files in the workspace Templates folder.</p>'
      + '<div class="quick-results">' + result.templates.map((item, i) =>
        '<button class="quick-row" data-index="' + i + '"><strong>' + escape(item.name) + '</strong></button>').join('') + '</div>'
      + '<div class="modal-actions"><button class="secondary" data-close="cancel">Cancel</button></div>',
    (root, done) => root.querySelectorAll('.quick-row').forEach((row) =>
      row.addEventListener('click', () => done(result.templates[Number(row.dataset.index)]))),
  );
  return chosen && chosen !== 'cancel' ? chosen : null;
}

async function newFromTemplate() {
  const template = await chooseTemplate();
  if (!template) return;
  newUntitledTab({ contents: applyTemplate(template.contents, { title: template.name.replace(/\.[^.]+$/, '') }), clean: false });
}

async function insertTemplate() {
  const template = await chooseTemplate();
  if (!template) return;
  const selection = editor.view.state.selection.main;
  const text = editor.view.state.sliceDoc(selection.from, selection.to);
  const replacement = applyTemplate(template.contents, {
    title: inferTitle(editor.getContent(), state.name.replace(/\.[^.]+$/, '')),
    selection: text,
  });
  editor.view.dispatch({ changes: { from: selection.from, to: selection.to, insert: replacement },
    selection: { anchor: selection.from + replacement.length } });
  editor.view.focus();
}

async function saveSnippet() {
  const folder = sidebar.getFolder();
  if (!folder) { toast('Open a folder first.', { error: true }); return; }
  const selection = editor.view.state.selection.main;
  const text = editor.view.state.sliceDoc(selection.from, selection.to);
  if (!text.trim()) { toast('Select some text first.', { error: true }); return; }
  const name = await promptDialog({ title: 'Save Snippet', message: 'Store this selection in the workspace Templates folder.',
    placeholder: 'Snippet name', okLabel: 'Save' });
  if (!name) return;
  const result = await api.saveTemplate(folder, name, text);
  toast(result.error ? result.error : 'Snippet saved', { error: !!result.error });
  if (!result.error) { sidebar.refresh(); refreshInsights(true); }
}

async function quickCapture() {
  const folder = sidebar.getFolder();
  if (!folder) { toast('Open a folder first.', { error: true }); return; }
  const capture = await showModal(
    '<h2>Quick Capture</h2><p class="modal-sub">Save a Markdown note to Inbox.</p>'
      + field('Title', '<input id="capture-title" type="text" placeholder="Note title">')
      + field('Note', '<textarea id="capture-body" rows="8" placeholder="Write a thought…"></textarea>')
      + '<div class="modal-actions"><button class="secondary" data-close="cancel">Cancel</button>'
      + '<button class="primary" id="capture-save">Save to Inbox</button></div>',
    (root, done) => root.querySelector('#capture-save').addEventListener('click', () => done({
      title: root.querySelector('#capture-title').value.trim(),
      body: root.querySelector('#capture-body').value,
    })),
  );
  if (!capture || capture === 'cancel') return;
  const result = await api.quickCapture(folder, capture.title, capture.body);
  if (result.error) { toast(result.error, { error: true }); return; }
  sidebar.refresh();
  await openPath(result.path);
  refreshInsights(true);
}

async function showStyleCheck() {
  const issues = analyzeStyle(editor.getContent());
  const chosen = await showModal(
    '<h2>Style Check</h2><p class="modal-sub">Suggestions for the current document.</p>'
      + (issues.length ? '<div class="style-issues">' + issues.map((issue, i) =>
        '<button class="style-issue" data-index="' + i + '"><strong>' + escape(issue.message)
        + '</strong><small>' + escape(editor.getContent().slice(issue.from, issue.to)) + '</small></button>').join('') + '</div>'
        : '<p>No style suggestions found.</p>')
      + '<div class="modal-actions"><button class="primary" data-close="ok">Close</button></div>',
    (root, done) => root.querySelectorAll('.style-issue').forEach((row) =>
      row.addEventListener('click', () => done(Number(row.dataset.index)))),
  );
  if (Number.isInteger(chosen) && issues[chosen]) {
    const issue = issues[chosen];
    editor.view.dispatch({ selection: { anchor: issue.from, head: issue.to }, scrollIntoView: true });
    editor.view.focus();
  }
}

async function showAttachmentAudit() {
  const folder = sidebar.getFolder();
  if (!folder) { toast('Open a folder first.', { error: true }); return; }
  if (!state.path) { toast('Open a note first.', { error: true }); return; }
  const overview = await api.workspaceOverview(folder, state.path, true);
  if (overview.error) { toast(overview.error, { error: true }); return; }
  const { referenced = [], missing = [] } = overview.attachments || {};
  await showModal('<h2>Attachment Audit</h2><p class="modal-sub">Images linked from the current note.</p>'
    + '<p>' + referenced.length + ' resolved; ' + missing.length + ' missing.</p>'
    + (missing.length ? '<h3>Missing</h3><div class="style-issues">' + missing.map((item) =>
      '<div class="style-issue">' + escape(typeof item === 'string' ? item : item.reference || item.path || '') + '</div>').join('') + '</div>' : '')
    + '<div class="modal-actions"><button class="primary" data-close="ok">Close</button></div>');
  sidebar.setInsights(overview);
}

async function showExportLayout() {
  const choice = await showModal(
    '<h2>Export Layout</h2><p class="modal-sub">Make a standalone HTML file or print ready PDF.</p>'
    + field('Format', '<select id="layout-format"><option value="pdf">PDF</option><option value="html">HTML</option></select>')
    + field('Preset', '<select id="layout-preset"><option value="standard">Standard</option><option value="manuscript">Manuscript</option><option value="report">Report</option></select>')
    + field('Subtitle', '<input id="layout-subtitle" type="text">')
    + field('Author', '<input id="layout-author" type="text">')
    + field('Page size', '<select id="layout-size"><option value="A4">A4</option><option value="Letter">Letter</option></select>')
    + toggle('layout-cover', 'Title page', 'Start with a cover page.', true)
    + toggle('layout-toc', 'Table of contents', 'Include document headings.', true)
    + '<div class="modal-actions"><button class="secondary" data-close="cancel">Cancel</button>'
    + '<button class="primary" id="layout-export">Export…</button></div>',
    (root, done) => root.querySelector('#layout-export').addEventListener('click', () => done({
      format: root.querySelector('#layout-format').value,
      preset: root.querySelector('#layout-preset').value,
      subtitle: root.querySelector('#layout-subtitle').value.trim(),
      author: root.querySelector('#layout-author').value.trim(),
      pageSize: root.querySelector('#layout-size').value,
      titlePage: root.querySelector('#layout-cover').checked,
      toc: root.querySelector('#layout-toc').checked,
      margin: 0.75,
      headerFooter: false,
    })),
  );
  if (choice && choice !== 'cancel') await runExport(choice.format, null, choice);
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------
async function showPreferences() {
  const s = state.settings;
  const themes = await api.listThemes();
  const options = themes.map((t) =>
    '<option value="' + escape(t.id) + '"' + (t.id === s.theme ? ' selected' : '') + '>'
    + escape(t.id.replace(/(^|-)([a-z])/g, (_m, sep, ch) => (sep ? ' ' : '') + ch.toUpperCase()).trim())
    + (t.source === 'user' ? ' (custom)' : '') + '</option>').join('');

  await showModal(
    '<h2>Preferences</h2><p class="modal-sub">Changes apply immediately.</p>'
    + field('Theme', '<select id="pref-theme">' + options + '</select>')
    + field('Appearance', '<select id="pref-dark">'
      + opt('system', 'Follow system', s.darkMode) + opt('light', 'Light', s.darkMode)
      + opt('dark', 'Dark', s.darkMode) + '</select>')
    + field('Font size', '<input type="range" id="pref-font" min="13" max="26" step="1" value="' + s.fontSize + '"> <span id="pref-font-val">' + s.fontSize + 'px</span>')
    + field('Line height', '<input type="range" id="pref-lh" min="1.3" max="2.2" step="0.02" value="' + s.lineHeight + '"> <span id="pref-lh-val">' + s.lineHeight + '</span>')
    + field('Line width', '<input type="range" id="pref-width" min="520" max="1200" step="20" value="' + s.contentWidth + '"> <span id="pref-width-val">' + s.contentWidth + 'px</span>')
    + toggle('pref-autosave', 'Auto-save', 'Saves a second and a half after you stop typing.', s.autoSave)
    + toggle('pref-spell', 'Spell check', 'Uses the Windows dictionary.', s.spellCheck)
    + toggle('pref-pair', 'Auto-pair symbols', 'Completes brackets, quotes, and Markdown markers.', s.autoPair)
    + toggle('pref-status', 'Show status bar', 'Word count, reading time and cursor position.', s.showStatusBar)
    + '<div class="modal-actions">'
    + '<button class="secondary" id="pref-themes-folder">Open Theme Folder…</button>'
    + '<button class="primary" data-close="ok">Done</button></div>',
    (root) => {
      const live = (id, key, format, extra) => {
        const input = root.querySelector('#' + id);
        const label = root.querySelector('#' + id + '-val');
        input.addEventListener('input', async () => {
          const value = Number(input.value);
          if (label) label.textContent = format(value);
          await setSettings({ [key]: value });
          applyViewModes();
          if (extra) extra();
        });
      };
      live('pref-font', 'fontSize', (v) => v + 'px');
      live('pref-lh', 'lineHeight', (v) => v.toFixed(2));
      live('pref-width', 'contentWidth', (v) => v + 'px');

      root.querySelector('#pref-theme').addEventListener('change', async (event) => {
        await setSettings({ theme: event.target.value }, { rerender: true });
      });
      root.querySelector('#pref-dark').addEventListener('change', async (event) => {
        await setSettings({ darkMode: event.target.value }, { rerender: true });
      });

      const bind = (id, key, after) => {
        root.querySelector('#' + id).addEventListener('change', async (event) => {
          await setSettings({ [key]: event.target.checked });
          applyViewModes();
          if (after) after();
        });
      };
      bind('pref-autosave', 'autoSave');
      bind('pref-spell', 'spellCheck');
      bind('pref-pair', 'autoPair');
      bind('pref-status', 'showStatusBar');

      root.querySelector('#pref-themes-folder').addEventListener('click', () => api.openThemeFolder());
    },
  );
}

function field(label, control) {
  return '<div class="field"><label>' + escape(label) + '</label><div>' + control + '</div></div>';
}

function opt(value, label, current) {
  return '<option value="' + value + '"' + (value === current ? ' selected' : '') + '>' + label + '</option>';
}

function toggle(id, label, hint, checked) {
  return '<div class="field"><label for="' + id + '">' + escape(label)
    + '<span class="hint">' + escape(hint) + '</span></label>'
    + '<input type="checkbox" id="' + id + '"' + (checked ? ' checked' : '') + '></div>';
}

function showShortcuts() {
  const groups = [
    ['File', [
      ['New', 'Ctrl N'], ['Open', 'Ctrl O'], ['Quick open', 'Ctrl P'],
      ['Quick capture', 'Ctrl Shift J'], ['Open folder', 'Ctrl Shift O'],
      ['Save', 'Ctrl S'], ['Save as', 'Ctrl Shift S'], ['Print', 'Ctrl Alt P'],
      ['Today’s note', 'Ctrl Shift T'],
    ]],
    ['Tabs and panes', [
      ['New tab', 'Ctrl N'], ['Close tab', 'Ctrl W'], ['Next / previous tab', 'Ctrl Tab / Ctrl Shift Tab'],
      ['Close tab with the mouse', 'Middle-click'], ['Close window', 'Ctrl Shift W'],
    ]],
    ['Notes', [
      ['Link to a note', '[['], ['Tag', '#'], ['Accept suggestion', 'Enter'],
      ['Back / forward', state.platform === 'darwin' ? 'Cmd Alt ← / Cmd Alt →' : 'Alt ← / Alt →'],
      ['Backlinks panel', state.platform === 'darwin' ? 'Cmd Alt B' : 'F7'],
    ]],
    ['Format', [
      ['Bold', 'Ctrl B'], ['Italic', 'Ctrl I'], ['Underline', 'Ctrl U'],
      ['Inline code', 'Ctrl Shift C'], ['Highlight', 'Ctrl Shift H'],
      ['Inline math', 'Ctrl Shift D'], ['Strikethrough', 'Alt Shift 5'],
      ['Hyperlink', 'Ctrl K'], ['Image', 'Ctrl Shift I'], ['Clear formatting', 'Ctrl \\'],
    ]],
    ['Paragraph', [
      ['Heading 1–6', 'Ctrl 1 … Ctrl 6'], ['Paragraph', 'Ctrl 0'],
      ['Bullet list', 'Ctrl Shift U'], ['Numbered list', 'Ctrl Shift L'],
      ['Task list', 'Ctrl Shift X'], ['Blockquote', 'Ctrl Shift Q'],
      ['Code fence', 'Ctrl Shift K'], ['Math block', 'Ctrl Shift M'],
      ['Table', 'Ctrl T'], ['Indent / outdent', 'Tab / Shift Tab'],
    ]],
    ['View', [
      ['Toggle sidebar', 'Ctrl Shift B'], ['Files / Outline / Articles / Search / Insights', 'Ctrl Shift 1–5'],
      ['Style check', 'Ctrl Shift E'],
      ['Source code mode', 'Ctrl /'], ['Focus mode', 'F8'],
      ['Typewriter mode', 'F9'], ['Distraction-free', 'F10'], ['Full screen', 'F11'],
      ['Zoom in / out / reset', 'Ctrl Shift + / _ / 0'],
    ]],
  ];
  const rows = groups.map(([name, items]) =>
    '<div class="group">' + name + '</div>'
    + items.map(([label, key]) =>
      '<div>' + escape(label) + '</div><div>'
      + key.split(' ').map((k) => (k === '/' || k === '…' || k === '–') ? k : '<kbd>' + escape(k) + '</kbd>').join(' ')
      + '</div>').join('')).join('');

  return showModal(
    '<h2>Keyboard Shortcuts</h2><div class="shortcut-list">' + rows + '</div>'
    + '<div class="modal-actions"><button class="primary" data-close="ok">Close</button></div>',
  );
}

const REFERENCE = `# Markdown Reference

Frisket hides the syntax below as soon as your cursor leaves it.

## Text

**bold**, *italic*, ***both***, ~~strikethrough~~, ==highlight==, \`inline code\`,
H~2~O and E = mc^2^.

## Headings

Type \`#\` through \`######\` followed by a space, or press Ctrl+1 … Ctrl+6.

## Lists

- A bullet list
- With a second item
  - And a nested one

1. Numbered lists
2. Renumber as you go

- [ ] A task
- [x] A finished task

> A blockquote, for when someone else said it better.

## Links and images

[A link](https://example.com) — Ctrl+click to open it.
![An image](assets/example.png)

## Linking between notes

Ctrl+click any of these to follow them:

- [[another-note]] finds a file by that name anywhere in the open folder
- [[another-note|shown as this]] displays the second part instead
- [a normal link](another-note.md) behaves the same way

If the target doesn't exist yet, Frisket offers to create it.

## Tables

| Column | Meaning |
| --- | --- |
| Ctrl+T | Insert a table |
| Tab | Next cell |

## Code

\`\`\`javascript
const greet = (name) => \`Hello, \${name}\`;
\`\`\`

## Math

Inline $E = mc^2$ and display:

$$
\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}
$$

## Diagrams

\`\`\`mermaid
graph LR
  Draft --> Edit --> Publish
\`\`\`

---

*Delete this document freely — it is a scratch buffer, not a file on disk.*
`;

function showReference() {
  newUntitledTab({ name: 'Markdown Reference', contents: REFERENCE });
}

// ---------------------------------------------------------------------------
// Commands from the native menu
// ---------------------------------------------------------------------------
async function handleCommand(command, payload) {
  const view = editor.view;
  switch (command) {
    case 'file:new': return newDocument();
    case 'file:new-from-template': return newFromTemplate();
    case 'file:quick-capture': return quickCapture();
    case 'file:quick-open': return showQuickOpen();
    case 'file:open': return openDialog();
    case 'file:open-path': return openPath(payload);
    case 'file:save': return save({ manual: true });
    case 'file:save-as': return save({ saveAs: true });
    case 'file:reveal':
      if (state.path) api.revealInExplorer(state.path);
      else toast('Save the document first.', { error: true });
      return;
    case 'folder:open': return chooseFolder();
    case 'preferences': return showPreferences();
    case 'print': return api.print();
    case 'export': return runExport(payload);
    case 'export:layout': return showExportLayout();
    case 'tools:style-check': return showStyleCheck();
    case 'tools:insert-template': return insertTemplate();
    case 'tools:save-snippet': return saveSnippet();
    case 'tools:attachment-audit': return showAttachmentAudit();

    case 'tab:close': return closeTab();
    case 'tab:next': return editorArea.cycle(1);
    case 'tab:previous': return editorArea.cycle(-1);
    case 'tab:move-other': return moveToOtherPane();
    case 'view:split': return splitEditor(payload || null);
    case 'view:unsplit': return unsplit();
    case 'view:split-orientation': {
      const next = editorArea.orientation() === 'row' ? 'column' : 'row';
      editorArea.setOrientation(next);
      await setSettings({ splitOrientation: next });
      return;
    }
    case 'view:focus-other-pane': {
      const other = editorArea.otherPane(editorArea.activePane());
      if (other && other.active) editorArea.activateTab(other.active);
      return;
    }
    case 'sync:show': return showSyncDialog();

    case 'note:daily': return openDailyNote();
    case 'note:toggle-pin': return togglePin(payload || state.path);
    case 'note:history': return showHistory(payload || state.path);
    case 'import': return importFrom(payload);
    case 'nav:back': return navigate(-1);
    case 'nav:forward': return navigate(1);
    case 'view:backlinks': return setBacklinksVisible(!backlinksVisible());
    case 'library:conflicts':
      if (!libraryWorkspace?.getFolder()) { toast('Open a library first.', { error: true }); return; }
      if (!state.settings.sidebarVisible) { await setSettings({ sidebarVisible: true }); applyViewModes(); }
      libraryWorkspace.setFilter('conflicts');
      return;

    case 'edit:undo': return void view.focus();
    case 'edit:redo': return void view.focus();
    case 'edit:select-all':
      view.dispatch({ selection: { anchor: 0, head: view.state.doc.length } });
      return void view.focus();
    case 'edit:find': openSearchPanel(view); return;
    case 'edit:find-all':
      if (!state.settings.sidebarVisible) {
        await setSettings({ sidebarVisible: true });
        applyViewModes();
      }
      sidebar.focusSearch();
      return;
    case 'edit:replace': openSearchPanel(view); return;
    case 'edit:top':
      view.dispatch({ selection: { anchor: 0 }, scrollIntoView: true });
      return void view.focus();
    case 'edit:bottom':
      view.dispatch({ selection: { anchor: view.state.doc.length }, scrollIntoView: true });
      return void view.focus();
    case 'edit:copy-html': {
      await navigator.clipboard.writeText(renderFragment(editor.getContent()));
      toast('Copied as HTML');
      return;
    }

    case 'para:heading': return void commands.setHeading(view, payload);
    case 'para:heading-inc': return void commands.adjustHeading(view, 1);
    case 'para:heading-dec': return void commands.adjustHeading(view, -1);
    case 'para:ul': return void commands.toggleList(view, 'ul');
    case 'para:ol': return void commands.toggleList(view, 'ol');
    case 'para:task': return void commands.toggleList(view, 'task');
    case 'para:quote': return void commands.toggleQuote(view);
    case 'para:code-fence': return void commands.insertCodeFence(view);
    case 'para:math': return void commands.insertMathBlock(view);
    case 'para:hr': return void commands.insertHorizontalRule(view);
    case 'para:indent': return void commands.indentListItem(view, false);
    case 'para:outdent': return void commands.indentListItem(view, true);
    case 'para:table': return insertTableDialog();

    case 'fmt:bold': return void commands.toggleWrap(view, '**');
    case 'fmt:italic': return void commands.toggleWrap(view, '*');
    case 'fmt:underline': return void commands.toggleWrap(view, '<u>', '</u>');
    case 'fmt:strike': return void commands.toggleWrap(view, '~~');
    case 'fmt:highlight': return void commands.toggleWrap(view, '==');
    case 'fmt:code': return void commands.toggleWrap(view, '`');
    case 'fmt:math': return void commands.toggleWrap(view, '$');
    case 'fmt:sup': return void commands.toggleWrap(view, '^');
    case 'fmt:sub': return void commands.toggleWrap(view, '~');
    case 'fmt:clear': return void commands.clearFormatting(view);
    case 'fmt:link': return linkDialog();
    case 'fmt:image': {
      const file = await api.pickImage();
      if (!file) return;
      const result = await api.importAttachment(file, state.path);
      if (result?.error) toast('Could not import image: ' + result.error, { error: true });
      else if (result?.relative) commands.insertImage(view, result.relative, '');
      return;
    }
    case 'fmt:attachment': {
      const file = await api.pickAttachment();
      if (!file) return;
      const result = await api.importAttachment(file, state.path);
      if (result?.error) toast('Could not attach file: ' + result.error, { error: true });
      else if (result?.relative) commands.insertAttachment(view, result.relative, result.name);
      return;
    }

    case 'view:sidebar':
      await setSettings({ sidebarVisible: !state.settings.sidebarVisible });
      applyViewModes();
      return;
    case 'view:search': return handleCommand('edit:find-all');
    case 'view:sidebar-tab':
      if (!state.settings.sidebarVisible) await setSettings({ sidebarVisible: true });
      await setSettings({ sidebarTab: payload });
      sidebar.setTab(payload);
      applyViewModes();
      return;
    case 'view:source':
      await setSettings({ sourceMode: !state.settings.sourceMode });
      applyViewModes();
      return;
    case 'view:focus':
      await setSettings({ focusMode: !state.settings.focusMode });
      applyViewModes();
      toast(state.settings.focusMode ? 'Focus mode on' : 'Focus mode off');
      return;
    case 'view:typewriter':
      await setSettings({ typewriterMode: !state.settings.typewriterMode });
      applyViewModes();
      toast(state.settings.typewriterMode ? 'Typewriter mode on' : 'Typewriter mode off');
      return;
    case 'view:zen':
      state.zen = !state.zen;
      applyViewModes();
      toast(state.zen ? 'Distraction-free mode — press F10 to exit' : 'Distraction-free mode off');
      return;
    case 'view:fullscreen': return void api.windowAction('fullscreen');
    case 'view:zoom': {
      const current = state.settings.fontSize;
      const next = payload === 0 ? 17 : Math.max(12, Math.min(30, current + payload));
      await setSettings({ fontSize: next });
      applyViewModes();
      return;
    }
    case 'view:theme':
      await setSettings({ theme: payload }, { rerender: true });
      return;
    case 'view:dark-mode':
      await setSettings({ darkMode: payload }, { rerender: true });
      return;
    case 'view:theme-folder': return void api.openThemeFolder();

    case 'help:reference': return showReference();
    case 'help:shortcuts': return showShortcuts();
    case 'help:legal': {
      const result = await api.openLegalDocument(payload);
      if (result && result.error) toast(result.error, { error: true });
      return;
    }
    default:
      return;
  }
}

async function insertTableDialog() {
  const result = await showModal(
    '<h2>Insert Table</h2><p class="modal-sub">You can add rows later by pressing Tab in the last cell.</p>'
    + field('Columns', '<input type="text" id="tbl-cols" value="3" style="min-width:70px">')
    + field('Body rows', '<input type="text" id="tbl-rows" value="2" style="min-width:70px">')
    + '<div class="modal-actions"><button class="secondary" data-close="cancel">Cancel</button>'
    + '<button class="primary" id="tbl-ok">Insert</button></div>',
    (root, done) => {
      root.querySelector('#tbl-ok').addEventListener('click', () => done({
        cols: Number(root.querySelector('#tbl-cols').value) || 3,
        rows: Number(root.querySelector('#tbl-rows').value) || 2,
      }));
    },
  );
  if (result) {
    commands.insertTable(editor.view, Math.max(1, Math.min(20, result.rows)), Math.max(1, Math.min(12, result.cols)));
  }
}

async function linkDialog() {
  const url = await promptDialog({
    title: 'Insert Link',
    message: 'Paste a URL, or leave it blank and fill it in later.',
    placeholder: 'https://',
    okLabel: 'Insert',
  });
  if (url === null) return;
  commands.insertLink(editor.view, url.trim());
}

async function chooseFolder(options = {}) {
  const folder = await api.openFolderDialog(options);
  if (folder) await openLibrary(folder);
}

/** Make `folder` the library shown in the sidebars. */
async function openLibrary(folder) {
  sidebar.setFolder(folder);
  libraryWorkspace?.setFolder(folder);
  if (!state.settings.sidebarVisible) {
    await setSettings({ sidebarVisible: true });
    applyViewModes();
  }
  sidebar.setTab('files');
  workspaceOverview = null;
  refreshInsights(true);
  refreshLibrary(true);
  void refreshBacklinks(true);
  void refreshSyncStatus();
}

// ---------------------------------------------------------------------------
// Sync & devices
// ---------------------------------------------------------------------------
let syncStatus = null;

/** Which sync app, if any, the open library is in; shown as the chip in the library panel. */
async function refreshSyncStatus() {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) { syncStatus = null; return null; }
  const status = await api.syncStatus(folder);
  if (libraryWorkspace.getFolder() !== folder) return null;
  syncStatus = status && !status.error ? status : null;
  libraryWorkspace.setSyncStatus(syncStatus);
  return syncStatus;
}

function formatBytes(bytes) {
  if (bytes < 1024 * 1024) return Math.max(1, Math.round(bytes / 1024)) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  return (bytes / 1024 / 1024 / 1024).toFixed(1) + ' GB';
}

/**
 * Sync & Devices: how sync works, whether this library syncs and through
 * what, conflicts waiting, and one-step setup when it does not sync yet.
 */
async function showSyncDialog() {
  const folder = libraryWorkspace?.getFolder() || null;
  const status = folder ? await refreshSyncStatus() : await api.syncStatus(null);
  const provider = status && status.provider;
  const available = ((status && status.available) || []).filter((item) => !provider || item.path !== provider.root);
  const conflicts = Number((workspaceOverview && workspaceOverview.conflicts) || 0);
  const item = (strong, text) => '<li><strong>' + strong + '</strong> ' + text + '</li>';

  let card;
  if (!folder) {
    card = '<div class="sync-card is-local"><strong>No library is open</strong><p>Open a folder of notes first; then this window shows whether it syncs.</p></div>';
  } else if (provider) {
    card = '<div class="sync-card is-synced"><strong>This library syncs with ' + escape(provider.label) + '</strong>'
      + '<small>' + escape(folder) + '</small>'
      + '<p>Notes upload whenever ' + escape(provider.label) + ' is running on this computer, and changes from your other devices appear here a few seconds after they arrive. There is nothing to switch on in Frisket.</p></div>';
  } else {
    card = '<div class="sync-card is-local"><strong>This library is only on this computer</strong>'
      + '<small>' + escape(folder) + '</small>'
      + '<p>To use it on other devices, keep it inside a folder that a sync app syncs. You can copy it into one below.</p></div>';
  }
  const conflictRow = folder && (provider || conflicts)
    ? (conflicts
      ? '<div class="sync-row is-alert"><span>' + conflicts + (conflicts === 1 ? ' note was' : ' notes were') + ' changed on two devices before they synced. Both versions are kept.</span>'
        + '<button class="secondary" data-action="conflicts">Review conflicts</button></div>'
      : '<div class="sync-row">No sync conflicts. If two devices change the same note before syncing, Frisket keeps both versions under Conflicts.</div>')
    : '';
  let setup = '';
  if (folder && !provider) {
    const files = status && status.size ? status.size.files : 0;
    const size = status && status.size
      ? ' (' + files.toLocaleString() + (files === 1 ? ' file, ' : ' files, ') + formatBytes(status.size.bytes) + ')' : '';
    setup = '<h3>Set up sync</h3>' + (available.length
      ? available.map((entry, index) => '<div class="sync-provider"><div><strong>' + escape(entry.label) + '</strong><small>'
        + escape(entry.path) + '</small></div><div class="sync-provider-actions">'
        + '<button class="primary" data-copy="' + index + '">Copy this library here</button>'
        + '<button class="secondary" data-choose="' + index + '">Open a library from here…</button></div></div>').join('')
        + '<p class="sync-note">Copying' + escape(size) + ' leaves the original folder where it is; delete it yourself once you have checked the copy. Use “Open a library from here” on a second device, once the library has synced to it.</p>'
      : '<p>No sync app was found on this computer. Install OneDrive, Dropbox, iCloud for Windows, Google Drive or Syncthing, sign in, then open this window again.</p>');
  } else if (!folder && available.length) {
    setup = '<h3>Synced folders on this computer</h3>' + available.map((entry, index) =>
      '<div class="sync-provider"><div><strong>' + escape(entry.label) + '</strong><small>' + escape(entry.path) + '</small></div>'
      + '<div class="sync-provider-actions"><button class="secondary" data-choose="' + index + '">Open a library from here…</button></div></div>').join('');
  }
  const choice = await showModal('<h2>Sync &amp; Devices</h2>'
    + '<p class="modal-sub">Frisket does not run its own cloud. A library is an ordinary folder of Markdown files: keep it inside a folder that OneDrive, Dropbox, iCloud Drive, Google Drive or Syncthing syncs, and every device that opens that folder sees the same notes.</p>'
    + card + conflictRow + setup
    + '<h3>On your other devices</h3><ul class="sync-list">'
    + item('Windows or Mac:', 'install Frisket and the same sync app, then choose File › Open Folder… and pick this library inside the synced folder.')
    + item('iPhone and iPad:', 'keep the library in iCloud Drive, and open its notes with any Markdown app from the Files app.')
    + item('Anything else:', 'notes are plain Markdown files, so any Markdown editor can read and edit them.')
    + '</ul><h3>Good to know</h3><ul class="sync-list">'
    + item('Keep it offline:', 'let the sync app keep the library on this device (OneDrive: right-click › Always keep on this device) so Frisket can read every note.')
    + item('History travels:', 'version history is stored in the library’s .frisket folder, so earlier versions are on every device.')
    + '</ul><div class="modal-actions">' + (folder ? '' : '<button class="secondary" data-action="open">Open Folder…</button>')
    + '<button class="primary" data-close="ok">Done</button></div>',
  (root, done) => {
    root.classList.add('wide');
    root.querySelectorAll('[data-action]').forEach((button) => button.addEventListener('click', () => done({ action: button.dataset.action })));
    root.querySelectorAll('[data-copy]').forEach((button) => button.addEventListener('click', () => done({ action: 'copy', entry: available[Number(button.dataset.copy)] })));
    root.querySelectorAll('[data-choose]').forEach((button) => button.addEventListener('click', () => done({ action: 'choose', entry: available[Number(button.dataset.choose)] })));
  });
  el('modal').classList.remove('wide');
  if (!choice || choice === true) return;
  if (choice.action === 'conflicts') return handleCommand('library:conflicts');
  if (choice.action === 'open') return chooseFolder();
  if (choice.action === 'choose') return chooseFolder({ defaultPath: choice.entry.path, title: 'Open a library in ' + choice.entry.label });
  if (choice.action === 'copy') return copyLibraryTo(choice.entry);
}

/** Copy the open library into a synced folder and switch to the copy. */
async function copyLibraryTo(entry) {
  const folder = libraryWorkspace?.getFolder();
  if (!folder) return;
  const name = folder.split(/[\\/]/).filter(Boolean).pop();
  const confirm = await confirmDialog({
    title: 'Copy library into ' + entry.label + '?',
    message: 'Frisket copies “' + name + '” into ' + entry.path + ' and opens the copy. Your original folder is not changed or removed.',
    buttons: [{ label: 'Copy and open', value: 'copy', primary: true }, { label: 'Cancel', value: 'cancel' }],
  });
  if (confirm !== 'copy') return;
  toast('Copying the library into ' + entry.label + '…');
  const result = await api.syncCopyLibrary(folder, entry.path);
  if (result?.error) { toast('Could not copy the library: ' + result.error, { error: true }); return; }
  await openLibrary(result.path);
  toast('Now using the copy in ' + entry.label + '. Notes already open in tabs still point at the original folder.');
}

// ---------------------------------------------------------------------------
// Chrome wiring
// ---------------------------------------------------------------------------
function wireChrome() {
  el('btn-menu').addEventListener('click', (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    api.popupMenu(rect.left, rect.bottom);
  });

  el('btn-sidebar').addEventListener('click', () => handleCommand('view:sidebar'));
  el('btn-quick-open').addEventListener('click', () => showQuickOpen());
  el('btn-source').addEventListener('click', () => handleCommand('view:source'));
  el('btn-back').addEventListener('click', () => navigate(-1));
  el('btn-forward').addEventListener('click', () => navigate(1));
  el('btn-backlinks').addEventListener('click', () => handleCommand('view:backlinks'));
  el('backlinks-close').addEventListener('click', () => setBacklinksVisible(false));
  // Mouse back and forward buttons.
  window.addEventListener('mouseup', (event) => {
    if (event.button === 3 || event.button === 4) {
      event.preventDefault();
      void navigate(event.button === 3 ? -1 : 1);
    }
  });

  el('win-min').addEventListener('click', () => api.windowAction('minimize'));
  el('win-max').addEventListener('click', () => api.windowAction('maximize'));
  el('win-close').addEventListener('click', () => api.windowAction('close'));
  el('titlebar-drag').addEventListener('dblclick', () => api.windowAction('maximize'));

  el('status-words').addEventListener('click', () => {
    state.wordMode = (state.wordMode + 1) % 4;
    updateCounts();
  });

  // Sidebar resizing.
  const resizer = el('sidebar-resizer');
  let dragging = false;
  resizer.addEventListener('mousedown', (event) => {
    dragging = true;
    resizer.classList.add('is-dragging');
    document.body.style.cursor = 'col-resize';
    event.preventDefault();
  });
  window.addEventListener('mousemove', (event) => {
    if (!dragging) return;
    const width = Math.max(180, Math.min(460, event.clientX));
    el('app').style.setProperty('--sidebar-width', width + 'px');
  });
  window.addEventListener('mouseup', async () => {
    if (!dragging) return;
    dragging = false;
    resizer.classList.remove('is-dragging');
    document.body.style.cursor = '';
    const width = parseInt(el('app').style.getPropertyValue('--sidebar-width'), 10);
    if (width) await setSettings({ sidebarWidth: width });
  });

  const installPaneResizer = (id, setting, min, max, origin) => {
    const handle = el(id);
    let active = false;
    handle.addEventListener('mousedown', (event) => {
      active = true;
      handle.classList.add('is-dragging');
      document.body.style.cursor = 'col-resize';
      event.preventDefault();
    });
    window.addEventListener('mousemove', (event) => {
      if (!active) return;
      const width = Math.max(min, Math.min(max, event.clientX - origin()));
      el('app').style.setProperty(setting, width + 'px');
    });
    window.addEventListener('mouseup', async () => {
      if (!active) return;
      active = false;
      handle.classList.remove('is-dragging');
      document.body.style.cursor = '';
      const width = parseInt(el('app').style.getPropertyValue(setting), 10);
      if (width) await setSettings({ [id === 'library-resizer' ? 'libraryWidth' : 'noteListWidth']: width });
    });
  };
  installPaneResizer('library-resizer', '--library-width', 150, 420, () => 0);
  installPaneResizer('notes-resizer', '--note-list-width', 210, 560, () => el('library-nav').getBoundingClientRect().width);

  // Dropping a .md file anywhere in the window opens it.
  window.addEventListener('dragover', (event) => event.preventDefault());
  window.addEventListener('drop', async (event) => {
    const file = event.dataTransfer && event.dataTransfer.files[0];
    if (!file) return;
    if (file.type.startsWith('image/')) return; // handled inside the editor
    const path = window.frisketFilePath ? window.frisketFilePath(file) : file.path;
    if (path && /\.(md|markdown|mdown|mkd|mdx|txt)$/i.test(path)) {
      event.preventDefault();
      openPath(path);
    }
  });

  el('main').addEventListener('scroll', () => {}, { passive: true });
}

function wireIpc() {
  api.on('app:command', (command, payload) => { handleCommand(command, payload); });

  api.on('app:native-theme', (dark) => {
    state.systemDark = dark;
    if (state.settings.darkMode === 'system') applyTheme();
  });

  // The library index watches the folder; refresh the list when it changes.
  api.on('library:changed', (folder) => {
    const current = libraryWorkspace?.getFolder();
    if (!current || !samePath(folder, current)) return;
    clearTimeout(libraryRefreshTimer);
    libraryRefreshTimer = setTimeout(() => { void refreshLibrary(false); void refreshBacklinks(); }, 150);
  });

  api.on('window:state-changed', ({ maximized }) => {
    el('win-max').classList.toggle('is-maximized', maximized);
  });

  api.on('app:before-close', async () => {
    // Telling main which way this went matters on macOS, where Cmd+Q reaches
    // us as a window close and must still quit the app once confirmed.
    api.windowAction(await confirmCloseAll() ? 'force-close' : 'cancel-close');
  });

  api.on('file:changed-externally', async (changedPath) => {
    const doc = findDoc(changedPath);
    if (!doc || doc.saving) return;
    const fresh = await api.readFile(changedPath, libraryOptions());
    if (fresh.error || fresh.contents === docContent(doc)) return;

    if (!doc.dirty) {
      reloadDoc(doc, fresh.contents, fresh.mtime);
      toast('Reloaded “' + doc.name + '” — it changed on disk');
      return;
    }

    const choice = await confirmDialog({
      title: 'File changed on disk',
      message: '"' + doc.name + '" was modified outside Frisket, and you have unsaved changes here.',
      buttons: [
        { label: 'Keep mine', value: 'keep', primary: true },
        { label: 'Reload from disk', value: 'reload' },
      ],
    });
    if (choice === 'reload') reloadDoc(doc, fresh.contents, fresh.mtime);
  });
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
async function boot() {
  const info = await api.getSettings();
  state.settings = info.settings;
  state.systemDark = info.systemDark;
  state.platform = info.platform || 'win32';

  // Drives the platform-specific window chrome in app.css: macOS keeps its
  // native traffic lights and menu bar, so our own are hidden there.
  document.documentElement.dataset.platform = state.platform;

  applyTheme();

  sidebar = createSidebar({
    onOpenFile: openPath,
    onGoToHeading: goToHeading,
    onRequestFolder: chooseFolder,
    onSaveSearch: saveSearch,
    onDeleteSavedSearch: deleteSavedSearch,
    onRefreshInsights: () => refreshInsights(true),
    onSelectTag: showTagNotes,
    onOpenMatch: openAtPosition,
  });

  libraryWorkspace = createLibraryWorkspace({
    onOpenFile: openPath,
    onOpenMatch: openAtPosition,
    onOpenFolder: chooseFolder,
    onNewNote: createLibraryNote,
    onDailyNote: openDailyNote,
    onSearch: (query, options) => api.searchLibrary(libraryWorkspace.getFolder(), query, options),
    onFilterChange: async (filter) => {
      await setSettings({ libraryFilter: filter });
    },
    onSortChange: async (sort) => {
      await setSettings({ librarySort: sort });
    },
    onTrashNote: trashLibraryNote,
    onRestoreNote: restoreLibraryNote,
    onDeleteNote: deleteLibraryNote,
    onTogglePin: togglePin,
    onShowHistory: showHistory,
    onResolveConflict: resolveConflict,
    onSync: showSyncDialog,
    initialSort: state.settings.librarySort || 'modified',
  });

  // No session writes until the saved one has been restored.
  restoringSession = true;
  editorArea = createEditorArea({
    container: el('main'),
    createEditorFor: createTabEditor,
    describe: describeTab,
    onActivate: onActivateTab,
    onClose: (tab) => { void closeTab(tab); },
    onNewTab: (pane) => { newUntitledTab({ pane }); },
    onSplit: () => splitEditor(),
    onUnsplit: (pane) => unsplit(pane),
    onContextMenu: (tab, x, y) => { void showTabMenu(tab, x, y); },
    onChanged: persistSession,
  });
  editorArea.setOrientation(state.settings.splitOrientation || 'row');
  newUntitledTab();

  applyViewModes();
  sidebar.setTab(state.settings.sidebarTab || 'files');
  sidebar.setSavedSearches(state.settings.savedSearches || []);
  if (state.settings.workingFolder) sidebar.setFolder(state.settings.workingFolder);
  else sidebar.refresh();
  if (state.settings.workingFolder) {
    libraryWorkspace.setFolder(state.settings.workingFolder);
    libraryWorkspace.setFilter(state.settings.libraryFilter || 'notes');
    refreshLibrary(true);
    void refreshSyncStatus();
  }
  refreshInsights();
  el('backlinks-pane').hidden = !backlinksVisible();
  el('btn-backlinks').classList.toggle('is-active', backlinksVisible());

  wireChrome();
  wireIpc();

  updateCounts();
  updatePosition(editor.view.state);

  // Automation hook for the smoke test. Gated so a shipped build exposes no
  // scriptable surface to page content.
  if (info.debug) window.__frisketTest = {
    export: (format, outputPath, presentation) => runExport(format, outputPath, presentation),
    command: (name, payload) => handleCommand(name, payload),
    content: () => editor.getContent(),
    settings: () => state.settings,
    setFolder: (folder) => { sidebar.setFolder(folder); sidebar.setTab('files'); libraryWorkspace.setFolder(folder); refreshLibrary(true); void refreshSyncStatus(); },
    syncStatus: () => syncStatus,
    setTab: (tab) => sidebar.setTab(tab),
    import: (kind, source) => importFrom(kind, source),
    navigation: () => ({ back: activeTab().back.map((entry) => entry.path), forward: activeTab().forward.map((entry) => entry.path) }),
    overview: () => workspaceOverview,
    openTab: (filePath, options) => openPath(filePath, options),
    tabs: () => editorArea.panes().map((pane) => ({
      focused: pane === editorArea.activePane(),
      active: pane.active ? describeTab(pane.active).title : null,
      tabs: pane.tabs.map((tab) => describeTab(tab).title + (tab.doc.dirty ? '*' : '')),
      text: pane.active ? pane.active.editor.getContent() : null,
    })),
    orientation: () => editorArea.orientation(),
    apply: async (patch) => {
      await setSettings(patch, { rerender: true });
      applyViewModes();
      return state.settings;
    },
    caretTo: (index) => {
      const pos = Math.min(index, editor.view.state.doc.length);
      editor.view.dispatch({ selection: { anchor: pos }, scrollIntoView: true });
      editor.view.focus();
    },
  };

  // The first window reopens the last session's tabs; a file the app was opened with joins them.
  restoringSession = false;
  if (info.restoreSession) await restoreSession(state.settings.session);
  if (info.pendingFile) await openPath(info.pendingFile, { newTab: true });
  updateTitle();
  updateNavigationButtons();
  editor.view.focus();
}

boot().catch((err) => {
  document.body.innerHTML = '<pre style="padding:24px;font:13px monospace;white-space:pre-wrap">'
    + 'Frisket failed to start:\n\n' + String(err && err.stack ? err.stack : err) + '</pre>';
});
