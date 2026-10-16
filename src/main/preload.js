'use strict';
const { contextBridge, ipcRenderer, webUtils } = require('electron');

const invoke = (channel, ...args) => ipcRenderer.invoke(channel, ...args);

/** Subscribe to a main-process push channel; returns an unsubscribe function. */
function on(channel, handler) {
  const wrapped = (_event, ...args) => handler(...args);
  ipcRenderer.on(channel, wrapped);
  return () => ipcRenderer.removeListener(channel, wrapped);
}

contextBridge.exposeInMainWorld('frisket', {
  // --- documents -------------------------------------------------------
  openDialog: () => invoke('file:open-dialog'),
  readFile: (p, options) => invoke('file:read', p, options || {}),
  peekFile: (p) => invoke('file:peek', p),
  writeFile: (p, contents, expectedMtime, options) => invoke('file:write', p, contents, expectedMtime, options || {}),
  historyList: (p, libraryRoot) => invoke('history:list', p, libraryRoot || null),
  historyRead: (p, libraryRoot, id) => invoke('history:read', p, libraryRoot || null, id),
  saveDialog: (suggestedName) => invoke('file:save-dialog', suggestedName),
  revealInExplorer: (p) => invoke('file:reveal', p),
  pathInfo: (p) => invoke('file:info', p),
  watchFiles: (paths) => invoke('file:watch', paths || []),

  // --- folders ---------------------------------------------------------
  openFolderDialog: (options) => invoke('folder:open-dialog', options || {}),
  syncStatus: (folder) => invoke('sync:status', folder || null),
  syncCopyLibrary: (folder, destination) => invoke('sync:copy-library', folder, destination),
  listFolder: (p) => invoke('folder:list', p),
  createFile: (dir, name) => invoke('folder:create-file', dir, name),
  createFolder: (dir, name) => invoke('folder:create-folder', dir, name),
  renameEntry: (p, name) => invoke('folder:rename', p, name),
  trashEntry: (p) => invoke('folder:trash', p),
  workspaceOverview: (folder, targetPath, refresh) => invoke('workspace:overview', folder, targetPath, !!refresh),
  listTemplates: (folder) => invoke('templates:list', folder),
  saveTemplate: (folder, name, contents) => invoke('templates:save', folder, name, contents),
  quickCapture: (folder, title, body) => invoke('workspace:capture', folder, title, body),
  createLibraryNote: (folder, title) => invoke('library:create-note', folder, title),
  trashLibraryNote: (folder, note) => invoke('library:trash-note', folder, note),
  restoreLibraryNote: (folder, note) => invoke('library:restore-note', folder, note),
  deleteLibraryNote: (folder, note) => invoke('library:delete-note', folder, note),
  titleChange: (folder, note, refresh) => invoke('library:title-change', folder, note, !!refresh),
  updateTitleLinks: (folder, note) => invoke('library:update-title-links', folder, note),
  dismissTitleChange: (folder, note) => invoke('library:dismiss-title-change', folder, note),
  noteContext: (folder, note, refresh) => invoke('library:context', folder, note, !!refresh),
  searchLibrary: (folder, query, options) => invoke('library:search', folder, query, options || {}),
  linkMention: (folder, source, pos, length, text, target) => invoke('library:link-mention', folder, source, pos, length, text, target),
  setPinned: (folder, note, pinned) => invoke('library:set-pinned', folder, note, !!pinned),
  resolveConflict: (folder, copy, action) => invoke('library:resolve-conflict', folder, copy, action),
  importNotes: (folder, kind, source) => invoke('library:import', folder, kind, source || null),
  dailyNote: (folder, date, body) => invoke('library:daily-note', folder, date, body || null),

  // --- internal links & search ------------------------------------------
  resolveLink: (target, docPath, folder) => invoke('link:resolve', target, docPath, folder),
  createLinkedFile: (filePath, title) => invoke('link:create', filePath, title),
  searchWorkspace: (query, options) => invoke('search:workspace', query, options),

  // --- app state -------------------------------------------------------
  getSettings: () => invoke('app:settings'),
  setSettings: (patch) => invoke('app:settings-set', patch),
  listThemes: () => invoke('app:themes'),
  readTheme: (name) => invoke('app:theme-read', name),
  openThemeFolder: () => invoke('app:theme-folder'),
  readAsset: (relative) => invoke('app:asset', relative),
  setDirty: (dirty, title) => invoke('window:dirty', dirty, title),

  // --- window ----------------------------------------------------------
  windowAction: (action) => invoke('window:action', action),
  windowState: () => invoke('window:state'),
  newWindow: (filePath) => invoke('window:new', filePath),
  popupMenu: (x, y) => invoke('window:popup-menu', x, y),
  showContextMenu: (items, x, y) => invoke('window:context-menu', items, x, y),

  // --- export ----------------------------------------------------------
  exportPdf: (html, opts) => invoke('export:pdf', html, opts),
  exportHtml: (html, opts) => invoke('export:html', html, opts),
  exportText: (text, opts) => invoke('export:text', text, opts),
  exportMarkdown: (markdown, opts) => invoke('export:markdown', markdown, opts),
  exportJpg: (html, opts) => invoke('export:jpg', html, opts),
  exportPandoc: (markdown, format, opts) => invoke('export:pandoc', markdown, format, opts),
  hasPandoc: () => invoke('export:pandoc-available'),
  print: () => invoke('export:print'),

  // --- misc ------------------------------------------------------------
  openExternal: (url) => invoke('shell:external', url),
  openLegalDocument: (name) => invoke('shell:legal', name),
  resolveImage: (src, docPath) => invoke('shell:resolve-image', src, docPath),
  imageDataUri: (src, docPath) => invoke('shell:image-datauri', src, docPath),
  pickImage: () => invoke('shell:pick-image'),
  pickAttachment: () => invoke('shell:pick-attachment'),
  importAttachment: (source, docPath) => invoke('shell:import-attachment', source, docPath),
  saveDataUrl: (dataUrl, docPath) => invoke('shell:save-dataurl', dataUrl, docPath),

  on,
});

// Electron 32 removed File.path; this is the supported replacement.
contextBridge.exposeInMainWorld('frisketFilePath', (file) => {
  try { return webUtils.getPathForFile(file); } catch { return null; }
});
