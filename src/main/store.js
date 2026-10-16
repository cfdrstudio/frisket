'use strict';
const { app } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const FILE = path.join(app.getPath('userData'), 'settings.json');

const DEFAULTS = {
  theme: 'red-graphite',
  darkMode: 'system', // 'system' | 'light' | 'dark'
  focusMode: false,
  typewriterMode: false,
  sourceMode: false,
  sidebarVisible: true,
  sidebarTab: 'files', // 'files' | 'outline' | 'articles' | 'search' | 'insights'
  savedSearches: [],
  sidebarWidth: 260,
  libraryWidth: 220,
  noteListWidth: 310,
  libraryFilter: 'notes',
  librarySort: 'modified',
  backlinksVisible: false,
  splitOrientation: 'row', // 'row' (side by side) | 'column' (stacked)
  session: null, // open tabs and split, restored when the first window opens
  fontSize: 17,
  lineHeight: 1.72,
  contentWidth: 780,
  spellCheck: true,
  autoSave: true,
  autoPair: true,
  showStatusBar: true,
  recentFiles: [],
  recentFolders: [],
  workingFolder: null,
  windowBounds: { width: 1180, height: 820 },
  customCssEnabled: false,
  pandocPath: null,
};

let cache = null;

function read() {
  if (cache) return cache;
  try {
    const raw = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    cache = { ...DEFAULTS, ...raw };
  } catch {
    cache = { ...DEFAULTS };
  }
  return cache;
}

function write(patch) {
  const next = { ...read(), ...patch };
  cache = next;
  try {
    fs.mkdirSync(path.dirname(FILE), { recursive: true });
    fs.writeFileSync(FILE, JSON.stringify(next, null, 2), 'utf8');
  } catch (err) {
    console.error('settings write failed', err);
  }
  return next;
}

/** Push a path onto a most-recently-used list, de-duplicated, capped at 15. */
function pushRecent(key, filePath) {
  const s = read();
  const list = [filePath, ...(s[key] || []).filter((p) => p !== filePath)].slice(0, 15);
  return write({ [key]: list });
}

module.exports = { read, write, pushRecent, DEFAULTS, FILE };
