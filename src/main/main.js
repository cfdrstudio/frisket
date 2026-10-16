'use strict';
const { app, BrowserWindow, dialog, ipcMain, shell, Menu, nativeTheme } = require('electron');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { pathToFileURL, fileURLToPath } = require('node:url');
const store = require('./store');
const { buildMenu } = require('./menu');
const exporter = require('./exporter');
const { IndexService } = require('./indexService');
const history = require('./history');
const syncProviders = require('./syncProviders');
const { replaceFile } = require('./files');
const { setFrontMatterValue, splitFrontMatter, parseFrontMatter } = require('./workspace');

// ---------------------------------------------------------------------------
// Diagnostics. Off unless FRISKET_LOG is set, so normal runs stay silent.
// FRISKET_SHOT additionally captures the window to a PNG and exits, which is
// what the smoke test uses to confirm the editor actually renders.
// ---------------------------------------------------------------------------
const LOG_FILE = process.env.FRISKET_LOG || null;

function log(...parts) {
  if (!LOG_FILE) return;
  const line = parts.map((p) => (typeof p === 'string' ? p : JSON.stringify(p))).join(' ');
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch { /* logging must never throw */ }
}

process.on('uncaughtException', (err) => {
  log('MAIN uncaughtException:', err && err.stack ? err.stack : String(err));
  if (!LOG_FILE) throw err;
});

function attachDiagnostics(win) {
  if (!LOG_FILE) return;
  win.webContents.on('console-message', (_e, level, message, line, source) => {
    log('RENDERER[' + level + ']', message, '(' + source + ':' + line + ')');
  });
  win.webContents.on('did-fail-load', (_e, code, desc, url) => {
    log('did-fail-load', code, desc, url);
  });
  win.webContents.on('render-process-gone', (_e, details) => {
    log('render-process-gone', JSON.stringify(details));
  });
  win.webContents.on('preload-error', (_e, preloadPath, error) => {
    log('preload-error', preloadPath, error && error.stack ? error.stack : String(error));
  });
}

async function runSmokeTest(win) {
  const shot = process.env.FRISKET_SHOT;

  // Store listings want screenshots at fixed sizes, so allow the capture
  // window to be sized independently of the user's saved bounds.
  const size = /^(\d+)x(\d+)$/.exec(process.env.FRISKET_WINDOW || '');
  if (size) {
    win.unmaximize();
    win.setSize(Number(size[1]), Number(size[2]));
    win.center();
    log('smoke: window set to', size[1] + 'x' + size[2]);
  }

  const delay = Number(process.env.FRISKET_SMOKE_DELAY || 3500);
  log('smoke: waiting', String(delay), 'ms');
  await new Promise((r) => setTimeout(r, delay));
  try {
    const health = await win.webContents.executeJavaScript(
      '(() => ({ editors: document.querySelectorAll(".cm-editor").length,'
      + ' lines: document.querySelectorAll(".cm-line").length,'
      + ' title: document.getElementById("doc-title")?.textContent,'
      + ' words: document.getElementById("status-words")?.textContent,'
      + ' outline: document.querySelectorAll(".outline-row").length,'
      + ' bodyStart: document.body.innerHTML.slice(0, 120) }))()',
    );
    log('smoke: health', JSON.stringify(health));
  } catch (err) {
    log('smoke: health check failed', String(err));
  }
  // Drive the editor with real key events, so input handlers, auto-pairing
  // and the keymap are all exercised the way a person would exercise them.
  if (process.env.FRISKET_TYPE) {
    const steps = JSON.parse(process.env.FRISKET_TYPE);
    win.focus();
    // The focused pane's visible editor, not simply the first one on the page.
    await win.webContents.executeJavaScript('(document.querySelector(".pane.is-focused .tab-editor:not([hidden]) .cm-content")'
      + ' || document.querySelector(".tab-editor:not([hidden]) .cm-content")).focus(); true');
    for (const step of steps) {
      if (step.text) {
        for (const ch of step.text) {
          win.webContents.sendInputEvent({ type: 'char', keyCode: ch });
          await new Promise((r) => setTimeout(r, 12));
        }
      }
      if (step.key) {
        win.webContents.sendInputEvent({
          type: 'keyDown',
          keyCode: step.key,
          modifiers: step.modifiers || [],
        });
        win.webContents.sendInputEvent({
          type: 'keyUp',
          keyCode: step.key,
          modifiers: step.modifiers || [],
        });
        await new Promise((r) => setTimeout(r, 60));
      }
      if (step.check) {
        const value = await win.webContents.executeJavaScript(step.check);
        log('type-check:', step.label || step.check, '->', JSON.stringify(value));
      }
      await new Promise((r) => setTimeout(r, 120));
    }
  }

  const script = process.env.FRISKET_SCRIPT;
  if (script) {
    try {
      const result = await win.webContents.executeJavaScript(script);
      log('smoke: script ->', JSON.stringify(result ?? null));
    } catch (err) {
      log('smoke: script failed', String(err));
    }
    await new Promise((r) => setTimeout(r, 1500));
  }

  if (shot) {
    const offsets = (process.env.FRISKET_SCROLL || '0').split(',').map(Number);
    for (let i = 0; i < offsets.length; i++) {
      try {
        if (offsets[i]) {
          await win.webContents.executeJavaScript(
            'document.querySelector(".cm-scroller").scrollTop = ' + offsets[i] + ';',
          );
          await new Promise((r) => setTimeout(r, 1200));
        }
        const image = await win.webContents.capturePage();
        const target = i === 0 ? shot : shot.replace(/\.png$/, '-' + i + '.png');
        fs.writeFileSync(target, image.toPNG());
        log('smoke: screenshot', target);
      } catch (err) {
        log('smoke: screenshot failed', String(err));
      }
    }
  }
  const exportDir = process.env.FRISKET_EXPORT_DIR;
  if (exportDir) {
    fs.mkdirSync(exportDir, { recursive: true });
    const targets = (process.env.FRISKET_EXPORT_FORMATS || 'pdf,html,docx').split(',');
    for (const format of targets) {
      const ext = { latex: 'tex', mediawiki: 'wiki' }[format] || format;
      const out = path.join(exportDir, 'export.' + ext);
      try {
        const result = await win.webContents.executeJavaScript(
          'window.__frisketTest.export(' + JSON.stringify(format) + ',' + JSON.stringify(out) + ')',
        );
        let size = 0;
        try { size = fs.statSync(out).size; } catch { /* not written */ }
        log('export:', format, JSON.stringify(result || null), 'bytes=' + size);
      } catch (err) {
        log('export:', format, 'threw', String(err));
      }
    }
  }

  log('smoke: done');
  for (const w of windows) w.allowClose = true;
  app.exit(0);
}

const MD_EXTS = new Set(['.md', '.markdown', '.mdown', '.mkd', '.mdx', '.txt']);
const isMarkdown = (p) => MD_EXTS.has(path.extname(p).toLowerCase());

/** @type {Set<BrowserWindow>} */
const windows = new Set();
/** Per-window fs watchers, so external edits can be surfaced. */
const watchers = new Map();

/**
 * The library index runs in a worker thread and watches each open library.
 * Windows hear about changes and refresh their own lists.
 */
const libraryIndex = new IndexService({
  onChanged: (folder) => {
    for (const w of windows) if (!w.isDestroyed()) w.webContents.send('library:changed', folder);
  },
  onFallback: (err) => log('library index: worker unavailable, indexing in-process:', String(err && err.message ? err.message : err)),
});
app.on('will-quit', () => { libraryIndex.close().catch(() => {}); });

// A file passed on the command line (double-clicked in Explorer, "open with").
function fileFromArgv(argv) {
  const args = argv.slice(app.isPackaged ? 1 : 2);
  for (const a of args) {
    if (a.startsWith('-')) continue;
    try {
      if (fs.statSync(a).isFile()) return path.resolve(a);
    } catch { /* not a path */ }
  }
  return null;
}

const IS_MAC = process.platform === 'darwin';

/**
 * Window chrome differs by platform. Windows gets a fully frameless window
 * with the close/minimise/maximise buttons drawn in the renderer; macOS keeps
 * its native traffic lights and simply hides the title bar behind our own,
 * because a Mac window without traffic lights reads as broken.
 */
function chromeOptions() {
  if (IS_MAC) {
    return {
      titleBarStyle: 'hiddenInset',
      // Centres the traffic lights in the 38px title bar defined in app.css.
      trafficLightPosition: { x: 14, y: 12 },
    };
  }
  return {
    frame: false,
    icon: path.join(__dirname, '../../assets/icon.png'),
  };
}

function createWindow(filePath = null) {
  const settings = store.read();
  const bounds = settings.windowBounds || {};

  const win = new BrowserWindow({
    width: bounds.width || 1180,
    height: bounds.height || 820,
    x: bounds.x,
    y: bounds.y,
    minWidth: 560,
    minHeight: 420,
    show: false,
    backgroundColor: '#faf9f7',
    autoHideMenuBar: true,
    title: 'Frisket',
    ...chromeOptions(),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: true,
    },
  });

  // Only the first window reopens the last session's tabs; later windows start fresh.
  win.restoreSession = windows.size === 0;
  windows.add(win);
  win.pendingFile = filePath;

  win.loadFile(path.join(__dirname, '../../dist/index.html'));

  attachDiagnostics(win);

  win.once('ready-to-show', () => {
    win.show();
    if (bounds.maximized) win.maximize();
    if (process.env.FRISKET_SMOKE) runSmokeTest(win);
  });

  const sendState = () => win.webContents.send('window:state-changed', {
    maximized: win.isMaximized(),
    fullScreen: win.isFullScreen(),
  });
  win.on('maximize', sendState);
  win.on('unmaximize', sendState);
  win.on('enter-full-screen', sendState);
  win.on('leave-full-screen', sendState);

  const saveBounds = () => {
    if (win.isDestroyed() || win.isMinimized()) return;
    const maximized = win.isMaximized();
    if (!maximized) win.lastNormalBounds = win.getBounds();
    store.write({ windowBounds: { ...(win.lastNormalBounds || win.getBounds()), maximized } });
  };
  win.on('resize', saveBounds);
  win.on('move', saveBounds);

  win.on('closed', () => {
    windows.delete(win);
    closeWatchers(win);
  });

  // The renderer owns unsaved-changes prompting; ask it before we let the window go.
  win.on('close', (event) => {
    if (win.allowClose) return;
    event.preventDefault();
    win.webContents.send('app:before-close');
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });

  return win;
}

function focusedWindow() {
  return BrowserWindow.getFocusedWindow() || [...windows][0] || null;
}

/** Send a command to the focused window's renderer (used by menu items). */
function sendCommand(command, payload) {
  const win = focusedWindow();
  if (win) win.webContents.send('app:command', command, payload);
}

// ---------------------------------------------------------------------------
// Single instance: reuse the running app when Explorer opens another file.
// ---------------------------------------------------------------------------
if (!process.env.FRISKET_SMOKE && !app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    const file = fileFromArgv(argv);
    if (file) {
      createWindow(file);
    } else {
      const win = focusedWindow();
      if (win) { if (win.isMinimized()) win.restore(); win.focus(); }
    }
  });
}

app.on('open-file', (event, filePath) => {
  event.preventDefault();
  if (app.isReady()) createWindow(filePath);
  else app.once('ready', () => createWindow(filePath));
});

/** Rebuild the menu so dynamic sections (Open Recent, Theme) stay current. */
let menuRefreshTimer = null;
function refreshMenu() {
  clearTimeout(menuRefreshTimer);
  menuRefreshTimer = setTimeout(() => {
    if (app.isReady()) Menu.setApplicationMenu(buildMenu({ sendCommand, createWindow, store }));
  }, 150);
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(buildMenu({ sendCommand, createWindow, store }));
  createWindow(fileFromArgv(process.argv));

  nativeTheme.on('updated', () => {
    for (const w of windows) w.webContents.send('app:native-theme', nativeTheme.shouldUseDarkColors);
  });

  app.on('activate', () => {
    if (windows.size === 0) createWindow();
  });
});

// macOS convention: closing every window leaves the app running in the Dock.
app.on('window-all-closed', () => {
  if (!IS_MAC) app.quit();
});

// Cmd+Q reaches windows as a `close`, which the renderer may veto to prompt
// about unsaved work. Remember that a quit was in progress so that confirming
// the prompt finishes the job rather than merely closing one window.
let quitRequested = false;
app.on('before-quit', () => { quitRequested = true; });

// ---------------------------------------------------------------------------
// IPC: documents
// ---------------------------------------------------------------------------
async function readDocument(filePath) {
  const contents = await fsp.readFile(filePath, 'utf8');
  store.pushRecent('recentFiles', filePath);
  app.addRecentDocument(filePath);
  refreshMenu();
  const stat = await fsp.stat(filePath);
  return {
    path: filePath,
    contents,
    name: path.basename(filePath),
    dir: path.dirname(filePath),
    mtime: stat.mtimeMs,
  };
}

ipcMain.handle('file:open-dialog', async (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const { canceled, filePaths } = await dialog.showOpenDialog(win, {
    title: 'Open',
    properties: ['openFile'],
    filters: [
      { name: 'Markdown', extensions: ['md', 'markdown', 'mdown', 'mkd', 'mdx'] },
      { name: 'Text', extensions: ['txt'] },
      { name: 'All Files', extensions: ['*'] },
    ],
  });
  if (canceled || !filePaths[0]) return null;
  return readDocument(filePaths[0]);
});

/** Snapshot roots for version history: the library when the file is in one, else app data. */
function historyRoots(libraryRoot) {
  return { libraryRoot: typeof libraryRoot === 'string' && libraryRoot ? libraryRoot : null, fallbackRoot: app.getPath('userData') };
}

/** Record a version without ever letting history failures affect the document itself. */
function snapshot(filePath, contents, libraryRoot, reason) {
  return history.record(filePath, contents, { ...historyRoots(libraryRoot), reason })
    .catch((err) => log('history: snapshot failed', filePath, String(err)));
}

ipcMain.handle('file:read', async (_e, filePath, options = {}) => {
  try {
    const doc = await readDocument(filePath);
    // Opening captures any edits made outside Frisket since the last snapshot.
    void snapshot(filePath, doc.contents, options.libraryRoot, 'open');
    return doc;
  } catch (err) {
    return { error: err.message };
  }
});

// Read a file's text with no side effects (no recent-files entry, no snapshot).
ipcMain.handle('file:peek', async (_e, filePath) => {
  try { return { contents: await fsp.readFile(filePath, 'utf8') }; }
  catch (err) { return { error: err.message }; }
});

ipcMain.handle('history:list', async (_e, filePath, libraryRoot) => {
  try {
    const text = await fsp.readFile(filePath, 'utf8');
    return { versions: await history.list(filePath, text, historyRoots(libraryRoot)) };
  } catch (err) { return { error: err.message }; }
});

ipcMain.handle('history:read', async (_e, filePath, libraryRoot, id) => {
  try {
    const text = await fsp.readFile(filePath, 'utf8');
    return { contents: await history.read(filePath, text, id, historyRoots(libraryRoot)) };
  } catch (err) { return { error: err.message }; }
});

ipcMain.handle('file:write', async (_e, filePath, contents, expectedMtime = null, options = {}) => {
  try {
    let current;
    try { current = await fsp.stat(filePath); } catch (err) { if (err.code !== 'ENOENT') throw err; }
    if (Number.isFinite(expectedMtime) && (!current || Math.abs(current.mtimeMs - expectedMtime) > 1)) {
      return current
        ? { conflict: true, mtime: current.mtimeMs, contents: await fsp.readFile(filePath, 'utf8') }
        : { conflict: true, deleted: true, mtime: null, contents: '' };
    }
    const targetDir = path.dirname(filePath);
    const temporary = path.join(targetDir, '.' + path.basename(filePath) + '.' + process.pid + '.' + Date.now() + '.tmp');
    await fsp.writeFile(temporary, contents, 'utf8');
    try { await fsp.rename(temporary, filePath); }
    catch (err) { await fsp.rm(temporary, { force: true }); throw err; }
    store.pushRecent('recentFiles', filePath);
    refreshMenu();
    const mtime = (await fsp.stat(filePath)).mtimeMs;
    void snapshot(filePath, contents, options.libraryRoot, options.manual ? 'save' : 'autosave');
    return { ok: true, mtime };
  } catch (err) {
    return { error: err.message };
  }
});

ipcMain.handle('file:save-dialog', async (event, suggestedName) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const { canceled, filePath } = await dialog.showSaveDialog(win, {
    title: 'Save As',
    defaultPath: suggestedName || 'Untitled.md',
    filters: [
      { name: 'Markdown', extensions: ['md'] },
      { name: 'Text', extensions: ['txt'] },
      { name: 'All Files', extensions: ['*'] },
    ],
  });
  return canceled ? null : filePath;
});

ipcMain.handle('file:reveal', (_e, filePath) => { shell.showItemInFolder(filePath); });

ipcMain.handle('file:info', async (_e, filePath) => {
  try {
    const s = await fsp.stat(filePath);
    return { exists: true, mtime: s.mtimeMs, size: s.size };
  } catch {
    return { exists: false };
  }
});

/** Stop every file watcher a window holds. */
function closeWatchers(win) {
  const open = watchers.get(win);
  if (!open) return;
  for (const entry of open.values()) { clearTimeout(entry.timer); entry.watcher.close(); }
  watchers.delete(win);
}

// Watch every document open in a window's tabs so edits made elsewhere reach it.
ipcMain.handle('file:watch', (event, paths) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return { ok: false };
  const wanted = new Map((Array.isArray(paths) ? paths : [paths]).filter(Boolean)
    .map((filePath) => [IS_MAC || process.platform === 'win32' ? filePath.toLowerCase() : filePath, filePath]));
  const open = watchers.get(win) || new Map();
  for (const [key, entry] of open) {
    if (!wanted.has(key)) { clearTimeout(entry.timer); entry.watcher.close(); open.delete(key); }
  }
  const failed = [];
  for (const [key, filePath] of wanted) {
    if (open.has(key)) continue;
    try {
      const entry = { timer: null, watcher: null };
      entry.watcher = fs.watch(filePath, () => {
        clearTimeout(entry.timer);
        entry.timer = setTimeout(() => {
          if (!win.isDestroyed()) win.webContents.send('file:changed-externally', filePath);
        }, 250);
      });
      entry.watcher.on('error', () => { entry.watcher.close(); open.delete(key); });
      open.set(key, entry);
    } catch {
      failed.push(filePath);
    }
  }
  watchers.set(win, open);
  return { ok: true, failed };
});

// ---------------------------------------------------------------------------
// IPC: folders
// ---------------------------------------------------------------------------
ipcMain.handle('folder:open-dialog', async (event, options = {}) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const { canceled, filePaths } = await dialog.showOpenDialog(win, {
    title: options.title || 'Open Folder',
    defaultPath: typeof options.defaultPath === 'string' ? options.defaultPath : undefined,
    properties: ['openDirectory', 'createDirectory'],
  });
  if (canceled || !filePaths[0]) return null;
  store.pushRecent('recentFolders', filePaths[0]);
  store.write({ workingFolder: filePaths[0] });
  return filePaths[0];
});

// --- Sync: which cloud folder (if any) a library lives in ------------------
ipcMain.handle('sync:status', async (_e, folder) => {
  try { return await syncProviders.syncStatus(folder); }
  catch (err) { return { error: err.message }; }
});

/**
 * Copy a library into a synced folder and make the copy the working library.
 * The original is left where it was; the user deletes it once satisfied.
 */
ipcMain.handle('sync:copy-library', async (_e, folder, destinationRoot) => {
  try {
    const target = await syncProviders.copyLibrary(folder, destinationRoot);
    store.pushRecent('recentFolders', target);
    store.write({ workingFolder: target });
    return { path: target };
  } catch (err) { return { error: err.message }; }
});

const IGNORED_DIRS = new Set([
  '.git', 'node_modules', '.obsidian', '.vscode',
  '$RECYCLE.BIN', 'System Volume Information',
]);

ipcMain.handle('folder:list', async (_e, dirPath) => {
  try {
    const entries = await fsp.readdir(dirPath, { withFileTypes: true });
    const out = [];
    for (const entry of entries) {
      if (entry.name.startsWith('.') || IGNORED_DIRS.has(entry.name)) continue;
      const full = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        out.push({ name: entry.name, path: full, type: 'dir' });
      } else if (isMarkdown(entry.name)) {
        let mtime = 0;
        try { mtime = (await fsp.stat(full)).mtimeMs; } catch { /* races are fine */ }
        out.push({ name: entry.name, path: full, type: 'file', mtime });
      }
    }
    out.sort((a, b) => (a.type === b.type
      ? a.name.localeCompare(b.name, undefined, { numeric: true })
      : a.type === 'dir' ? -1 : 1));
    return out;
  } catch (err) {
    return { error: err.message };
  }
});

ipcMain.handle('folder:create-file', async (_e, dir, name) => {
  try {
    const target = path.join(dir, name.endsWith('.md') ? name : `${name}.md`);
    await fsp.writeFile(target, '', { flag: 'wx' });
    return { path: target };
  } catch (err) {
    return { error: err.message };
  }
});

ipcMain.handle('folder:create-folder', async (_e, dir, name) => {
  try {
    const target = path.join(dir, name);
    await fsp.mkdir(target);
    return { path: target };
  } catch (err) {
    return { error: err.message };
  }
});

ipcMain.handle('folder:rename', async (_e, oldPath, newName) => {
  try {
    const target = path.join(path.dirname(oldPath), newName);
    await fsp.rename(oldPath, target);
    return { path: target };
  } catch (err) {
    return { error: err.message };
  }
});

// Route deletions to the Recycle Bin rather than unlinking outright.
ipcMain.handle('folder:trash', async (event, target) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const { response } = await dialog.showMessageBox(win, {
    type: 'warning',
    buttons: ['Move to Recycle Bin', 'Cancel'],
    defaultId: 0,
    cancelId: 1,
    message: 'Move "' + path.basename(target) + '" to the Recycle Bin?',
  });
  if (response !== 0) return { canceled: true };
  try {
    await shell.trashItem(target);
    return { ok: true };
  } catch (err) {
    return { error: err.message };
  }
});

// The index refreshes incrementally; `refresh` asks it to re-check the disk
// first, which callers do right after their own writes. Only metadata crosses
// the preload bridge; full note text stays in the index.
ipcMain.handle('workspace:overview', async (_e, folder, targetPath, refresh) => {
  try {
    return await libraryIndex.call(folder, 'overview', targetPath || null, { refresh: !!refresh });
  } catch (err) { return { error: err.message }; }
});

// A note whose title changed while other notes still link to the old one.
ipcMain.handle('library:title-change', async (_e, folder, notePath, refresh) => {
  try { return await libraryIndex.call(folder, 'titleChange', notePath, { refresh: !!refresh }); }
  catch (err) { return { error: err.message }; }
});

ipcMain.handle('library:update-title-links', async (_e, folder, notePath) => {
  try { return await libraryIndex.call(folder, 'updateTitleLinks', notePath); }
  catch (err) { return { error: err.message }; }
});

ipcMain.handle('library:dismiss-title-change', async (_e, folder, notePath) => {
  try { return await libraryIndex.call(folder, 'dismissTitleChange', notePath); }
  catch (err) { return { error: err.message }; }
});

function safeMarkdownName(name) {
  const clean = String(name || '').trim().replace(/\.md$/i, '');
  if (!clean || clean.length > 100 || /[<>:"/\\|?*\x00-\x1f]/.test(clean) || clean === '.' || clean === '..') {
    throw new Error('Choose a short file name without path characters.');
  }
  return clean + '.md';
}

async function managedFolder(root, name) {
  const directory = path.join(path.resolve(root), name);
  await fsp.mkdir(directory, { recursive: true });
  const stat = await fsp.lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(name + ' must be a regular folder.');
  return directory;
}

function pathWithin(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep));
}

async function libraryRoot(root) {
  if (typeof root !== 'string' || !root.trim()) throw new Error('Choose a library folder first.');
  const resolved = await fsp.realpath(path.resolve(root));
  const stat = await fsp.stat(resolved);
  if (!stat.isDirectory()) throw new Error('The library must be a folder.');
  return resolved;
}

async function nextNotePath(notesDir, title) {
  const slug = String(title || 'Untitled').trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 52) || 'untitled';
  const date = new Date().toISOString().slice(0, 10);
  for (let suffix = 0; suffix < 1000; suffix++) {
    const name = date + '-' + slug + (suffix ? '-' + suffix : '') + '.md';
    const target = path.join(notesDir, name);
    try { await fsp.access(target); } catch { return target; }
  }
  throw new Error('Could not choose a unique note name.');
}

/** Create a portable library note without moving or changing legacy files. */
ipcMain.handle('library:create-note', async (_e, root, title) => {
  try {
    const library = await libraryRoot(root);
    const notesDir = await managedFolder(library, 'Notes');
    const cleanTitle = String(title || 'Untitled').trim().replace(/[\r\n]/g, ' ').slice(0, 120) || 'Untitled';
    const target = await nextNotePath(notesDir, cleanTitle);
    if (!pathWithin(library, target)) throw new Error('Invalid library note path.');
    const now = new Date().toISOString();
    const id = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : crypto.randomBytes(16).toString('hex');
    const contents = '---\nfrisket-id: ' + id + '\nfrisket-created: ' + now + '\n---\n\n# ' + cleanTitle + '\n\n';
    await fsp.writeFile(target, contents, { encoding: 'utf8', flag: 'wx' });
    return { path: target };
  } catch (err) { return { error: err.message }; }
});

async function activeLibraryNote(root, notePath) {
  const library = await libraryRoot(root);
  const realNote = await fsp.realpath(notePath);
  const hiddenRoot = path.join(library, '.frisket');
  if (!pathWithin(library, realNote) || pathWithin(hiddenRoot, realNote)) throw new Error('Only active notes in this library can be changed.');
  return { library, realNote };
}

/** Set or clear `frisket-trashed-at` with an atomic, change-checked write (B8). */
async function setTrashMetadata(notePath, timestamp, libraryRoot) {
  const before = await fsp.stat(notePath);
  const source = await fsp.readFile(notePath, 'utf8');
  const next = setFrontMatterValue(source, 'frisket-trashed-at', timestamp || null);
  if (next === source) return;
  await snapshot(notePath, source, libraryRoot, 'before-change');
  await replaceFile(notePath, next, before.mtimeMs);
}

function trashedInFrontMatter(text) {
  return !!parseFrontMatter(splitFrontMatter(text).metaText).properties['frisket-trashed-at'];
}

ipcMain.handle('library:trash-note', async (_e, root, notePath) => {
  try {
    const { library, realNote } = await activeLibraryNote(root, notePath);
    await setTrashMetadata(realNote, new Date().toISOString(), library);
    return { path: realNote };
  } catch (err) { return { error: err.message }; }
});

ipcMain.handle('library:restore-note', async (_e, root, notePath) => {
  try {
    const library = await libraryRoot(root);
    const trashRoot = path.join(library, '.frisket', 'Trash');
    const realNote = await fsp.realpath(notePath);
    if (pathWithin(trashRoot, realNote)) {
      const target = path.join(library, path.relative(trashRoot, realNote));
      if (!pathWithin(library, target)) throw new Error('Invalid restore path.');
      try { await fsp.access(target); throw new Error('A note already exists at the restore location.'); } catch (err) { if (err.code !== 'ENOENT') throw err; }
      await fsp.mkdir(path.dirname(target), { recursive: true });
      await fsp.rename(realNote, target);
      return { path: target };
    }
    const active = await activeLibraryNote(library, realNote);
    await setTrashMetadata(active.realNote, null, library);
    return { path: active.realNote };
  } catch (err) { return { error: err.message }; }
});

ipcMain.handle('library:delete-note', async (_e, root, notePath) => {
  try {
    const library = await libraryRoot(root);
    const trashRoot = path.join(library, '.frisket', 'Trash');
    const realNote = await fsp.realpath(notePath);
    if (!pathWithin(trashRoot, realNote)) {
      const active = await activeLibraryNote(library, realNote);
      const text = await fsp.readFile(active.realNote, 'utf8');
      if (!trashedInFrontMatter(text)) throw new Error('Only notes in this library Trash can be permanently deleted.');
    }
    // The last version stays in history, so even a permanent delete can be recovered by hand.
    await snapshot(realNote, await fsp.readFile(realNote, 'utf8'), library, 'before-change');
    await fsp.rm(realNote, { force: true });
    return { ok: true };
  } catch (err) { return { error: err.message }; }
});

// --- Library operations that run in the index worker -------------------------
const indexed = (op) => async (_e, folder, ...args) => {
  try { return await libraryIndex.call(folder, op, ...args); }
  catch (err) { return { error: err.message }; }
};
ipcMain.handle('library:context', (event, folder, notePath, refresh) => indexed('context')(event, folder, notePath, { refresh: !!refresh }));
ipcMain.handle('library:search', (event, folder, query, options = {}) => indexed('search')(event, folder, query, {
  refresh: !!options.refresh, includeTrashed: !!options.includeTrashed,
}));
ipcMain.handle('library:link-mention', indexed('linkMention'));
ipcMain.handle('library:set-pinned', indexed('setPinned'));
ipcMain.handle('library:resolve-conflict', indexed('resolveConflict'));

const IMPORT_FILTERS = { evernote: [{ name: 'Evernote export', extensions: ['enex'] }] };

/**
 * Import from another app. Without `source`, ask for it: .enex files for
 * Evernote; a .zip or a folder for Notion; nothing for Apple Notes, which is
 * read from the Notes app on macOS.
 */
ipcMain.handle('library:import', async (event, folder, kind, source = null) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  try {
    let input = source;
    if (!input && kind === 'evernote') {
      const picked = await dialog.showOpenDialog(win, { title: 'Import from Evernote', properties: ['openFile', 'multiSelections'], filters: IMPORT_FILTERS.evernote });
      if (picked.canceled || !picked.filePaths.length) return { canceled: true };
      input = picked.filePaths;
    } else if (!input && kind === 'notion') {
      const { response } = await dialog.showMessageBox(win, {
        type: 'question', title: 'Import from Notion',
        message: 'Import a Notion export',
        detail: 'In Notion, choose Settings › Export all workspace content (or Export on a page) with the "Markdown & CSV" format. Then pick the downloaded .zip, or the folder you extracted it to.',
        buttons: ['Choose .zip…', 'Choose Folder…', 'Cancel'], defaultId: 0, cancelId: 2,
      });
      if (response === 2) return { canceled: true };
      const picked = await dialog.showOpenDialog(win, response === 0
        ? { title: 'Notion export (.zip)', properties: ['openFile'], filters: [{ name: 'Notion export', extensions: ['zip'] }] }
        : { title: 'Notion export folder', properties: ['openDirectory'] });
      if (picked.canceled || !picked.filePaths[0]) return { canceled: true };
      input = picked.filePaths[0];
    } else if (kind === 'apple-notes' && !IS_MAC) {
      return { error: 'Apple Notes import needs macOS, where the Notes app runs.' };
    }
    return await libraryIndex.call(folder, 'importNotes', kind, input);
  } catch (err) { return { error: err.message }; }
});

/**
 * Open or create the daily note `Daily/<date>.md`. `body` (from the renderer's
 * Daily template, if any) is used only when the note does not exist yet.
 */
ipcMain.handle('library:daily-note', async (_e, root, date, body) => {
  try {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(date))) throw new Error('Invalid date.');
    const library = await libraryRoot(root);
    const dir = await managedFolder(library, 'Daily');
    const target = path.join(dir, date + '.md');
    try { await fsp.access(target); return { path: target, created: false }; } catch { /* create below */ }
    let text = typeof body === 'string' && body.trim() ? body : '# ' + date + '\n\n';
    text = setFrontMatterValue(text, 'frisket-id', crypto.randomUUID());
    text = setFrontMatterValue(text, 'frisket-created', new Date().toISOString());
    try { await fsp.writeFile(target, text, { encoding: 'utf8', flag: 'wx' }); }
    catch (err) { if (err.code !== 'EEXIST') throw err; }
    return { path: target, created: true };
  } catch (err) { return { error: err.message }; }
});

ipcMain.handle('templates:list', async (_e, folder) => {
  try {
    const dir = path.join(path.resolve(folder), 'Templates');
    let entries;
    try {
      const stat = await fsp.lstat(dir);
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Templates must be a regular folder.');
      entries = await fsp.readdir(dir, { withFileTypes: true });
    }
    catch (err) { if (err.code === 'ENOENT') return { templates: [] }; throw err; }
    const templates = [];
    for (const entry of entries.slice(0, 100)) {
      if (!entry.isFile() || !isMarkdown(entry.name)) continue;
      const file = path.join(dir, entry.name);
      const stat = await fsp.stat(file);
      if (stat.size > 256 * 1024) continue;
      templates.push({ name: entry.name, contents: await fsp.readFile(file, 'utf8') });
    }
    templates.sort((a, b) => a.name.localeCompare(b.name));
    return { templates };
  } catch (err) { return { error: err.message }; }
});

ipcMain.handle('templates:save', async (_e, folder, name, contents) => {
  try {
    const text = String(contents);
    if (Buffer.byteLength(text, 'utf8') > 256 * 1024) throw new Error('Snippet exceeds the 256 KB template limit.');
    const dir = await managedFolder(folder, 'Templates');
    const file = path.join(dir, safeMarkdownName(name));
    await fsp.writeFile(file, text, { encoding: 'utf8', flag: 'wx' });
    return { path: file };
  } catch (err) { return { error: err.message }; }
});

ipcMain.handle('workspace:capture', async (_e, folder, title, body) => {
  try {
    const dir = await managedFolder(folder, 'Inbox');
    const cleanTitle = String(title || 'Untitled').trim().slice(0, 120).replace(/[\r\n]/g, ' ');
    const slug = cleanTitle.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48) || 'note';
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const file = path.join(dir, timestamp + '-' + slug + '.md');
    const contents = '# ' + cleanTitle + '\n\n' + String(body || '') + '\n';
    await fsp.writeFile(file, contents, { encoding: 'utf8', flag: 'wx' });
    return { path: file };
  } catch (err) { return { error: err.message }; }
});

// ---------------------------------------------------------------------------
// IPC: internal links
// ---------------------------------------------------------------------------

/** Recursively collect Markdown files, bounded so a huge tree cannot hang us. */
async function collectMarkdown(dir, depth, out, limit = 5000) {
  if (depth > 6 || out.length >= limit) return out;
  let entries;
  try {
    entries = await fsp.readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (entry.name.startsWith('.') || IGNORED_DIRS.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) await collectMarkdown(full, depth + 1, out, limit);
    else if (isMarkdown(entry.name)) out.push(full);
    if (out.length >= limit) break;
  }
  return out;
}

/**
 * Resolve a `[[wiki-link]]` or a relative Markdown path to a note.
 *
 * With a library open, the index decides: path, `frisket-id`, file name, title,
 * then aliases, reporting ambiguity instead of guessing. A miss there (for
 * example a file beyond the index bounds) falls through to the disk search
 * below, which is also all a single file opened outside a library gets.
 */
ipcMain.handle('link:resolve', async (_e, target, docPath, workingFolder) => {
  if (!target) return { missing: true };
  let indexed = null;
  if (workingFolder) {
    try { indexed = await libraryIndex.call(workingFolder, 'resolveLink', target, docPath || null); }
    catch (err) { log('link:resolve index failed', String(err)); }
  }
  if (indexed && !indexed.missing) return indexed;
  const onDisk = await resolveOnDisk(target, docPath, workingFolder);
  if (onDisk.path) return onDisk;
  return { ...onDisk, name: indexed ? indexed.name : undefined, trashed: indexed ? indexed.trashed : null };
});

/**
 * Tried in order: as a path relative to the current document, then the same
 * with `.md` appended, then by bare name anywhere under the working folder.
 */
async function resolveOnDisk(target, docPath, workingFolder) {
  const clean = String(target).trim().replace(/^<|>$/g, '');
  const anchorSplit = clean.split('#');
  const name = anchorSplit[0].trim();
  const anchor = anchorSplit.length > 1 ? anchorSplit.slice(1).join('#') : null;
  if (!name) return { missing: true, anchor };

  const baseDir = docPath ? path.dirname(docPath) : (workingFolder || app.getPath('documents'));

  const direct = [];
  if (path.isAbsolute(name)) {
    direct.push(name, name + '.md');
  } else {
    direct.push(path.resolve(baseDir, name), path.resolve(baseDir, name + '.md'));
    if (workingFolder) {
      direct.push(path.resolve(workingFolder, name), path.resolve(workingFolder, name + '.md'));
    }
  }

  for (const candidate of direct) {
    try {
      if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
        return { path: candidate, anchor };
      }
    } catch { /* keep looking */ }
  }

  // Fall back to a by-name search of the workspace, case-insensitively.
  if (workingFolder) {
    const wanted = path.basename(name).toLowerCase();
    const files = await collectMarkdown(workingFolder, 0, []);
    const hit = files.find((f) => {
      const base = path.basename(f).toLowerCase();
      return base === wanted || base === wanted + '.md' || base.replace(/\.[^.]+$/, '') === wanted;
    });
    if (hit) return { path: hit, anchor };
  }

  // Nothing yet — report where it would go if the user chooses to create it.
  const suggested = path.resolve(
    workingFolder || baseDir,
    /\.[a-z0-9]+$/i.test(name) ? name : name + '.md',
  );
  return { missing: true, anchor, suggested };
}

/** Create a note that a wiki-link points at but which does not exist yet. */
ipcMain.handle('link:create', async (_e, filePath, title) => {
  try {
    await fsp.mkdir(path.dirname(filePath), { recursive: true });
    const heading = title || path.basename(filePath).replace(/\.[^.]+$/, '');
    await fsp.writeFile(filePath, '# ' + heading + '\n\n', { flag: 'wx' });
    refreshMenu();
    return { path: filePath };
  } catch (err) {
    if (err.code === 'EEXIST') return { path: filePath };
    return { error: err.message };
  }
});

// ---------------------------------------------------------------------------
// IPC: workspace search
// ---------------------------------------------------------------------------

/**
 * Plain substring search across the working folder. Deliberately simple: no
 * index, no watcher, just a bounded walk, which is fast enough for the folder
 * sizes a prose writer actually keeps and cannot go stale.
 */
ipcMain.handle('search:workspace', async (_e, query, options = {}) => {
  const needle = String(query || '').trim();
  if (needle.length < 2 && !/^@(todo|images)$/i.test(needle)) return { results: [], truncated: false };

  const folder = options.folder;
  if (!folder) return { results: [], truncated: false, error: 'No folder is open.' };

  // Library operators are evaluated from the shared index contract so desktop
  // navigation and search agree about nested tags and task/image state.
  if (/(?:^|\s)(?:@todo|@images|#[\p{L}\p{N}_-])/iu.test(needle)) {
    try {
      const { notes, truncated } = await libraryIndex.call(folder, 'search', needle);
      return {
        results: notes.map((note) => ({
          path: note.path, name: note.name, relative: note.relative,
          matches: [note.match || { line: 1, column: 0, pos: 0, text: note.excerpt || note.title, snippetOffset: 0 }],
        })),
        truncated,
      };
    } catch (err) { return { results: [], truncated: false, error: err.message }; }
  }

  const caseSensitive = !!options.caseSensitive;
  const maxFiles = options.maxFiles || 2000;
  const maxResults = options.maxResults || 200;
  const compare = caseSensitive ? needle : needle.toLowerCase();

  const files = await collectMarkdown(folder, 0, [], maxFiles);
  const results = [];
  let truncated = false;

  for (const file of files) {
    if (results.length >= maxResults) { truncated = true; break; }
    let text;
    try {
      const stat = await fsp.stat(file);
      if (stat.size > 4 * 1024 * 1024) continue;
      text = await fsp.readFile(file, 'utf8');
    } catch { continue; }

    const haystack = caseSensitive ? text : text.toLowerCase();
    if (haystack.indexOf(compare) === -1) continue;

    const lines = text.split('\n');
    const matches = [];
    let offset = 0;
    for (let i = 0; i < lines.length && matches.length < 20; i++) {
      const line = lines[i];
      const hay = caseSensitive ? line : line.toLowerCase();
      const col = hay.indexOf(compare);
      if (col > -1) {
        matches.push({
          line: i + 1,
          column: col,
          pos: offset + col,
          // Trim long lines around the hit so the sidebar stays readable.
          text: line.length > 160 ? line.slice(Math.max(0, col - 40), col + 120) : line,
          snippetOffset: line.length > 160 ? Math.max(0, col - 40) : 0,
        });
      }
      offset += line.length + 1;
    }
    if (matches.length) {
      results.push({
        path: file,
        name: path.basename(file),
        relative: path.relative(folder, file),
        matches,
      });
    }
  }

  return { results, truncated: truncated || files.length >= maxFiles };
});

// ---------------------------------------------------------------------------
// IPC: settings & themes
// ---------------------------------------------------------------------------
function userThemeDir() {
  return path.join(app.getPath('userData'), 'themes');
}

ipcMain.handle('app:settings', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const pending = win ? win.pendingFile : null;
  if (win) win.pendingFile = null;
  return {
    settings: store.read(),
    pendingFile: pending,
    restoreSession: !!(win && win.restoreSession),
    systemDark: nativeTheme.shouldUseDarkColors,
    debug: !!process.env.FRISKET_SMOKE,
    platform: process.platform,
    userThemeDir: userThemeDir(),
    version: app.getVersion(),
  };
});

ipcMain.handle('app:settings-set', (_e, patch) => {
  const next = store.write(patch);
  if ('theme' in patch || 'darkMode' in patch || 'recentFiles' in patch) refreshMenu();
  return next;
});

ipcMain.handle('app:themes', async () => {
  const builtinDir = path.join(__dirname, '../../dist/themes');
  const list = [];
  const scan = async (dir, source) => {
    try {
      for (const f of await fsp.readdir(dir)) {
        if (f.endsWith('.css')) list.push({ id: path.basename(f, '.css'), source });
      }
    } catch { /* directory may not exist yet */ }
  };
  await scan(builtinDir, 'builtin');
  await fsp.mkdir(userThemeDir(), { recursive: true }).catch(() => {});
  await scan(userThemeDir(), 'user');
  return list;
});

ipcMain.handle('app:theme-read', async (_e, name) => {
  const candidates = [
    path.join(userThemeDir(), name + '.css'),
    path.join(__dirname, '../../dist/themes', name + '.css'),
  ];
  for (const c of candidates) {
    try { return await fsp.readFile(c, 'utf8'); } catch { /* try next */ }
  }
  return '';
});

// Read a bundled asset (stylesheets, themes) for inlining into exports.
ipcMain.handle('app:asset', async (_e, relative) => {
  const root = path.resolve(__dirname, '../../dist');
  const target = path.resolve(root, path.normalize(relative).replace(/^([\\/]|\.\.[\\/])+/, ''));
  if (!target.startsWith(root)) return '';
  try { return await fsp.readFile(target, 'utf8'); } catch { return ''; }
});

// Inline an image as a data URI so exported HTML stands on its own.
ipcMain.handle('shell:image-datauri', async (_e, src, docPath) => {
  if (!src || /^data:/i.test(src)) return src || null;
  try {
    let abs;
    if (/^file:/i.test(src)) {
      abs = fileURLToPath(src);
    } else if (/^https?:/i.test(src)) {
      return src;
    } else {
      const base = docPath ? path.dirname(docPath) : app.getPath('documents');
      let rel = src;
      try { rel = decodeURI(src); } catch { /* keep raw */ }
      abs = path.isAbsolute(rel) ? rel : path.resolve(base, rel);
    }
    const stat = await fsp.stat(abs);
    if (stat.size > 12 * 1024 * 1024) return pathToFileURL(abs).href;
    const buffer = await fsp.readFile(abs);
    const ext = path.extname(abs).slice(1).toLowerCase();
    const mime = {
      png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
      webp: 'image/webp', svg: 'image/svg+xml', bmp: 'image/bmp', avif: 'image/avif',
    }[ext] || 'application/octet-stream';
    return 'data:' + mime + ';base64,' + buffer.toString('base64');
  } catch {
    return null;
  }
});

ipcMain.handle('app:theme-folder', async () => {
  const dir = userThemeDir();
  await fsp.mkdir(dir, { recursive: true }).catch(() => {});
  const readme = path.join(dir, 'README.txt');
  if (!fs.existsSync(readme)) {
    fs.writeFileSync(readme, [
      'Drop .css files here to add custom Frisket themes.',
      'Each file becomes a theme named after the file (my-theme.css -> "my-theme").',
      'Copy a built-in theme from the app folder as a starting point.',
      'Reopen the Theme menu to pick up new files.',
    ].join('\r\n'), 'utf8');
  }
  shell.openPath(dir);
});

// ---------------------------------------------------------------------------
// IPC: window chrome
// ---------------------------------------------------------------------------
ipcMain.handle('window:action', (event, action) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return null;
  switch (action) {
    case 'minimize': win.minimize(); break;
    case 'maximize': win.isMaximized() ? win.unmaximize() : win.maximize(); break;
    case 'close': win.close(); break;
    case 'force-close':
      win.allowClose = true;
      win.close();
      // Finish the quit the user asked for, rather than stopping at one window.
      if (quitRequested) app.quit();
      break;
    case 'cancel-close':
      quitRequested = false;
      break;
    case 'fullscreen': win.setFullScreen(!win.isFullScreen()); break;
    default: break;
  }
  return { maximized: win.isMaximized(), fullScreen: win.isFullScreen() };
});

ipcMain.handle('window:state', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  return win ? { maximized: win.isMaximized(), fullScreen: win.isFullScreen() } : {};
});

ipcMain.handle('window:new', (_e, filePath) => { createWindow(filePath || null); });

ipcMain.handle('window:dirty', (event, dirty, title) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (!win) return;
  win.setTitle((dirty ? '• ' : '') + (title || 'Untitled') + ' — Frisket');
  win.setDocumentEdited(dirty);
});

ipcMain.handle('window:popup-menu', (event, x, y) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const menu = Menu.getApplicationMenu();
  if (menu && win) menu.popup({ window: win, x: Math.round(x), y: Math.round(y) });
});

// Build an ad-hoc context menu from a renderer-supplied description.
ipcMain.handle('window:context-menu', (event, items, x, y) => new Promise((resolve) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  let picked = null;
  const template = items.map((item) => (item.type === 'separator'
    ? { type: 'separator' }
    : {
        label: item.label,
        enabled: item.enabled !== false,
        click: () => { picked = item.id; },
      }));
  const menu = Menu.buildFromTemplate(template);
  menu.popup({
    window: win,
    x: Math.round(x),
    y: Math.round(y),
    callback: () => resolve(picked),
  });
}));

// ---------------------------------------------------------------------------
// IPC: export & shell
// ---------------------------------------------------------------------------
ipcMain.handle('export:pdf', (event, html, opts) => exporter.toPdf(event, html, opts));
ipcMain.handle('export:html', (event, html, opts) => exporter.toHtml(event, html, opts));
ipcMain.handle('export:text', (event, text, opts) => exporter.toText(event, text, opts));
ipcMain.handle('export:markdown', (event, markdown, opts) => exporter.toMarkdown(event, markdown, opts));
ipcMain.handle('export:jpg', (event, html, opts) => exporter.toJpg(event, html, opts));
ipcMain.handle('export:pandoc', (event, markdown, format, opts) => exporter.viaPandoc(event, markdown, format, opts));
ipcMain.handle('export:pandoc-available', () => exporter.pandocPath() !== null);
ipcMain.handle('export:print', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  if (win) win.webContents.print({ printBackground: true });
});

// Legal documents ship as extraResources, i.e. real files next to the app,
// because paths inside app.asar cannot be handed to the shell.
ipcMain.handle('shell:legal', async (_e, name) => {
  const safe = path.basename(String(name || ''));
  // Builds ship either an EULA or, for the open-source edition, the MIT LICENSE.
  const names = safe === 'EULA.md' ? ['EULA.md', 'LICENSE'] : [safe];
  for (const file of names) {
    for (const candidate of [path.join(process.resourcesPath || '', file), path.resolve(__dirname, '../../', file)]) {
      if (fs.existsSync(candidate)) {
        await shell.openPath(candidate);
        return { ok: true };
      }
    }
  }
  return { error: safe + ' was not found.' };
});

ipcMain.handle('shell:external', (_e, url) => {
  if (/^(https?|mailto):/i.test(url)) shell.openExternal(url);
});

// Turn a markdown image reference into a URL the renderer can actually load.
ipcMain.handle('shell:resolve-image', (_e, src, docPath) => {
  if (!src) return null;
  if (/^(https?:|data:|file:)/i.test(src)) return src;
  try {
    const base = docPath ? path.dirname(docPath) : app.getPath('documents');
    let rel = src;
    try { rel = decodeURI(src); } catch { /* keep raw when not percent-encoded */ }
    const abs = path.isAbsolute(rel) ? rel : path.resolve(base, rel);
    if (!fs.existsSync(abs)) return null;
    return pathToFileURL(abs).href;
  } catch {
    return null;
  }
});

ipcMain.handle('shell:pick-image', async (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const { canceled, filePaths } = await dialog.showOpenDialog(win, {
    title: 'Insert Image',
    properties: ['openFile'],
    filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp'] }],
  });
  return canceled ? null : filePaths[0];
});

ipcMain.handle('shell:pick-attachment', async (event) => {
  const win = BrowserWindow.fromWebContents(event.sender);
  const { canceled, filePaths } = await dialog.showOpenDialog(win, {
    title: 'Attach File',
    properties: ['openFile'],
    filters: [{ name: 'Supported files', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'pdf', 'txt', 'doc', 'docx', 'rtf', 'pages', 'numbers', 'key', 'zip'] }, { name: 'All files', extensions: ['*'] }],
  });
  return canceled ? null : filePaths[0];
});

ipcMain.handle('shell:import-attachment', async (_e, source, docPath) => {
  try {
    if (typeof source !== 'string' || !source) throw new Error('No file selected.');
    const sourceStat = await fsp.stat(source);
    if (!sourceStat.isFile()) throw new Error('Attachments must be files.');
    if (sourceStat.size > 100 * 1024 * 1024) throw new Error('Attachments are limited to 100 MB.');
    const baseDir = docPath ? path.dirname(docPath) : app.getPath('documents');
    const assetDir = path.join(baseDir, 'assets');
    await fsp.mkdir(assetDir, { recursive: true });
    const parsed = path.parse(source);
    const safeStem = parsed.name.replace(/[^a-z0-9._-]+/gi, '-').replace(/^-+|-+$/g, '').slice(0, 80) || 'attachment';
    const extension = parsed.ext.toLowerCase().replace(/[^.a-z0-9]/g, '').slice(0, 16);
    let target;
    for (let suffix = 0; suffix < 1000; suffix++) {
      target = path.join(assetDir, safeStem + (suffix ? '-' + suffix : '') + extension);
      try { await fsp.access(target); } catch { break; }
    }
    if (!target) throw new Error('Could not choose an attachment name.');
    await fsp.copyFile(source, target, fs.constants.COPYFILE_EXCL);
    return { path: target, relative: 'assets/' + path.basename(target), name: path.basename(source) };
  } catch (err) { return { error: err.message }; }
});

// Pasted/dropped image data lands next to the document in an assets folder.
ipcMain.handle('shell:save-dataurl', async (_e, dataUrl, docPath) => {
  try {
    const match = /^data:image\/([a-z0-9+.-]+);base64,(.*)$/i.exec(dataUrl);
    if (!match) return { error: 'Unsupported image data' };
    const ext = match[1].toLowerCase() === 'jpeg' ? 'jpg' : match[1].toLowerCase();
    const baseDir = docPath ? path.dirname(docPath) : app.getPath('documents');
    const assetDir = path.join(baseDir, 'assets');
    await fsp.mkdir(assetDir, { recursive: true });
    const name = 'image-' + Date.now() + '.' + ext;
    const target = path.join(assetDir, name);
    await fsp.writeFile(target, Buffer.from(match[2], 'base64'));
    return { path: target, relative: 'assets/' + name };
  } catch (err) {
    return { error: err.message };
  }
});
