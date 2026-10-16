'use strict';

/**
 * Frisket has no sync service of its own. A library syncs because it lives
 * inside a folder that a sync app already syncs: OneDrive, Dropbox, iCloud
 * Drive, Google Drive, Nextcloud, Syncthing or Box. This module finds those
 * folders on this computer, says which one (if any) a library is in, and can
 * copy a library into one.
 *
 * No Electron imports, so it can be tested under `node --test`.
 */

const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { within, uniquePath, safeName } = require('./files');

const LABELS = {
  onedrive: 'OneDrive', dropbox: 'Dropbox', icloud: 'iCloud Drive', 'google-drive': 'Google Drive',
  nextcloud: 'Nextcloud', syncthing: 'Syncthing', box: 'Box',
};
const SIZE_LIMIT = 20000;

async function isDirectory(target) {
  try { return (await fsp.stat(target)).isDirectory(); } catch { return false; }
}

async function exists(target) {
  try { await fsp.access(target); return true; } catch { return false; }
}

async function readJson(file) {
  try { return JSON.parse(await fsp.readFile(file, 'utf8')); } catch { return null; }
}

function samePath(a, b, platform) {
  const norm = (value) => path.resolve(value).replace(/[\\/]+$/, '');
  return platform === 'linux' ? norm(a) === norm(b) : norm(a).toLowerCase() === norm(b).toLowerCase();
}

/** Synced folders on this computer, as `[{ provider, label, path }]`. */
async function detectSyncFolders({ env = process.env, home = os.homedir(), platform = process.platform } = {}) {
  const found = [];
  const add = async (provider, folder, label = LABELS[provider]) => {
    if (!folder || !(await isDirectory(folder))) return;
    const resolved = path.resolve(folder);
    if (found.some((item) => samePath(item.path, resolved, platform))) return;
    found.push({ provider, label, path: resolved });
  };

  if (platform === 'win32') {
    await add('onedrive', env.OneDriveConsumer || env.OneDrive);
    if (env.OneDriveCommercial) {
      const name = path.basename(env.OneDriveCommercial).replace(/^OneDrive\s*-\s*/i, '');
      await add('onedrive', env.OneDriveCommercial, name && !/^OneDrive$/i.test(name) ? 'OneDrive – ' + name : 'OneDrive (work)');
    }
    for (const base of [env.APPDATA, env.LOCALAPPDATA].filter(Boolean)) {
      const info = await readJson(path.join(base, 'Dropbox', 'info.json'));
      if (info && info.personal) await add('dropbox', info.personal.path);
      if (info && info.business) await add('dropbox', info.business.path, 'Dropbox (work)');
    }
    await add('dropbox', path.join(home, 'Dropbox'));
    await add('icloud', path.join(home, 'iCloudDrive'));
    // Google Drive for desktop mounts G: by default; other letters are found by the path check below.
    await add('google-drive', 'G:\\My Drive');
    await add('google-drive', path.join(home, 'Google Drive'));
    await add('nextcloud', path.join(home, 'Nextcloud'));
    await add('box', path.join(home, 'Box'));
  } else if (platform === 'darwin') {
    await add('icloud', path.join(home, 'Library', 'Mobile Documents', 'com~apple~CloudDocs'));
    const storage = path.join(home, 'Library', 'CloudStorage');
    let entries = [];
    try { entries = (await fsp.readdir(storage)).sort(); } catch { /* no File Provider folders */ }
    for (const name of entries) {
      const full = path.join(storage, name);
      if (/^OneDrive/i.test(name)) {
        const account = name.replace(/^OneDrive-?/i, '').replace(/^Personal$/i, '');
        await add('onedrive', full, account ? 'OneDrive – ' + account : 'OneDrive');
      } else if (/^Dropbox/i.test(name)) await add('dropbox', full);
      else if (/^GoogleDrive/i.test(name)) await add('google-drive', (await isDirectory(path.join(full, 'My Drive'))) ? path.join(full, 'My Drive') : full);
      else if (/^Box/i.test(name)) await add('box', full);
    }
    await add('dropbox', path.join(home, 'Dropbox'));
    await add('nextcloud', path.join(home, 'Nextcloud'));
  } else {
    await add('dropbox', path.join(home, 'Dropbox'));
    await add('nextcloud', path.join(home, 'Nextcloud'));
    await add('onedrive', path.join(home, 'OneDrive'));
  }
  // Syncthing's default folder counts once Syncthing has marked it.
  if (await exists(path.join(home, 'Sync', '.stfolder'))) await add('syncthing', path.join(home, 'Sync'));
  return found;
}

async function hasNextcloudMarker(dir) {
  let names;
  try { names = await fsp.readdir(dir); } catch { return false; }
  return names.some((name) => /^\._?sync_[0-9a-f]+\.db$/i.test(name) || /^\.(?:owncloud|nextcloud)sync\.log$/i.test(name));
}

/**
 * The sync app a folder belongs to, as `{ provider, label, root }`, or null.
 * Known sync folders are checked first, then markers and well-known names in
 * the folder's parents (Syncthing's `.stfolder`, Dropbox's `.dropbox`,
 * Nextcloud's journal, "OneDrive…", "iCloudDrive", "My Drive").
 */
async function providerFor(folder, known = []) {
  const resolved = path.resolve(folder);
  const hit = known.filter((item) => within(item.path, resolved)).sort((a, b) => b.path.length - a.path.length)[0];
  if (hit) return { provider: hit.provider, label: hit.label, root: hit.path };
  const named = (provider, root, label = LABELS[provider]) => ({ provider, label, root });
  let dir = resolved;
  for (let depth = 0; depth < 40; depth++) {
    const name = path.basename(dir);
    if (await exists(path.join(dir, '.stfolder'))) return named('syncthing', dir);
    if (await exists(path.join(dir, '.dropbox'))) return named('dropbox', dir);
    if (await hasNextcloudMarker(dir)) return named('nextcloud', dir);
    if (/^OneDrive(?:\s*-\s*.+|-.+)?$/i.test(name)) return named('onedrive', dir);
    if (name === 'iCloudDrive' || name === 'com~apple~CloudDocs') return named('icloud', dir);
    if (name === 'My Drive') return named('google-drive', dir);
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

/** Number of files and bytes under a folder, stopping after SIZE_LIMIT entries. */
async function folderSize(folder) {
  let files = 0;
  let bytes = 0;
  let truncated = false;
  const walk = async (dir) => {
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (files >= SIZE_LIMIT) { truncated = true; return; }
      if (entry.name === 'node_modules' || entry.name === '.git' || entry.isSymbolicLink()) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) await walk(full);
      else if (entry.isFile()) {
        files++;
        try { bytes += (await fsp.stat(full)).size; } catch { /* removed meanwhile */ }
      }
    }
  };
  await walk(folder);
  return { files, bytes, truncated };
}

/**
 * How a library syncs: `{ folder, provider: { provider, label, root } | null,
 * available: [...synced folders on this computer], size? }`. `size` is given
 * only for an unsynced library, for the "copy it" prompt.
 */
async function syncStatus(folder, options = {}) {
  const available = await detectSyncFolders(options);
  if (!folder) return { folder: null, provider: null, available };
  const provider = await providerFor(folder, available);
  return { folder, provider, available, size: provider ? null : await folderSize(folder) };
}

/**
 * Copy a library folder into `destinationRoot` as a new folder of the same
 * name (numbered if taken). Nothing is moved or deleted. Resolves with the copy's path.
 */
async function copyLibrary(folder, destinationRoot) {
  const source = await fsp.realpath(path.resolve(String(folder || '')));
  const root = await fsp.realpath(path.resolve(String(destinationRoot || '')));
  if (!(await isDirectory(source))) throw new Error('The library folder is missing.');
  if (!(await isDirectory(root))) throw new Error('The sync folder is missing.');
  if (within(source, root)) throw new Error('That sync folder is inside the library. Choose another one.');
  if (within(root, source)) throw new Error('This library is already inside that folder.');
  const target = await uniquePath(root, safeName(path.basename(source), 'Frisket Library'), '');
  await fsp.cp(source, target, {
    recursive: true,
    errorOnExist: true,
    force: false,
    filter: (item) => !['.git', 'node_modules'].includes(path.basename(item)),
  });
  return target;
}

module.exports = { detectSyncFolders, providerFor, syncStatus, copyLibrary, folderSize, LABELS };
