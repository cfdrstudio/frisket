'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { detectSyncFolders, providerFor, syncStatus, copyLibrary } = require('../src/main/syncProviders');

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'frisket-sync-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

async function dir(...parts) {
  const full = path.join(...parts);
  await fs.mkdir(full, { recursive: true });
  return full;
}

// Only folders under the fake home matter; the real machine may have its own (G:\My Drive, say).
const under = (home, found) => found.filter((item) => item.path.startsWith(home))
  .map((item) => [item.provider, item.label, path.relative(home, item.path)]);

test('finds Windows sync folders from the environment, Dropbox settings and usual places', async (t) => {
  const home = await fixture(t);
  const oneDrive = await dir(home, 'OneDrive');
  const work = await dir(home, 'OneDrive - Contoso');
  const dropbox = await dir(home, 'Box Sync', 'Dropbox Home');
  await dir(home, 'AppData', 'Roaming', 'Dropbox');
  await fs.writeFile(path.join(home, 'AppData', 'Roaming', 'Dropbox', 'info.json'), JSON.stringify({ personal: { path: dropbox } }));
  await dir(home, 'iCloudDrive');
  await dir(home, 'Sync', '.stfolder');
  await dir(home, 'Nextcloud');
  const env = { OneDrive: oneDrive, OneDriveCommercial: work, APPDATA: path.join(home, 'AppData', 'Roaming') };
  const found = await detectSyncFolders({ env, home, platform: 'win32' });
  assert.deepEqual(under(home, found), [
    ['onedrive', 'OneDrive', 'OneDrive'],
    ['onedrive', 'OneDrive – Contoso', 'OneDrive - Contoso'],
    ['dropbox', 'Dropbox', path.join('Box Sync', 'Dropbox Home')],
    ['icloud', 'iCloud Drive', 'iCloudDrive'],
    ['nextcloud', 'Nextcloud', 'Nextcloud'],
    ['syncthing', 'Syncthing', 'Sync'],
  ]);
});

test('finds macOS iCloud Drive and File Provider folders', async (t) => {
  const home = await fixture(t);
  await dir(home, 'Library', 'Mobile Documents', 'com~apple~CloudDocs');
  await dir(home, 'Library', 'CloudStorage', 'OneDrive-Personal');
  await dir(home, 'Library', 'CloudStorage', 'GoogleDrive-me@example.com', 'My Drive');
  await dir(home, 'Library', 'CloudStorage', 'Dropbox');
  const found = await detectSyncFolders({ env: {}, home, platform: 'darwin' });
  assert.deepEqual(under(home, found).map(([provider, label]) => [provider, label]), [
    ['icloud', 'iCloud Drive'], ['dropbox', 'Dropbox'], ['google-drive', 'Google Drive'], ['onedrive', 'OneDrive'],
  ]);
});

test('says which sync app a library is in, by folder, marker or name', async (t) => {
  const home = await fixture(t);
  const oneDrive = await dir(home, 'OneDrive');
  const known = [{ provider: 'onedrive', label: 'OneDrive', path: oneDrive }];
  assert.deepEqual(await providerFor(await dir(oneDrive, 'Notes'), known), { provider: 'onedrive', label: 'OneDrive', root: oneDrive });

  const shared = await dir(home, 'Shared');
  await dir(shared, '.stfolder');
  assert.equal((await providerFor(await dir(shared, 'deep', 'Notes'), [])).provider, 'syncthing');
  await fs.writeFile(path.join(await dir(home, 'DB'), '.dropbox'), '');
  assert.equal((await providerFor(await dir(home, 'DB', 'Notes'), [])).provider, 'dropbox');
  await fs.writeFile(path.join(await dir(home, 'NC'), '._sync_0123abcd.db'), '');
  assert.equal((await providerFor(await dir(home, 'NC', 'Notes'), [])).provider, 'nextcloud');
  assert.deepEqual(await providerFor(await dir(home, 'OneDrive - Contoso', 'Notes'), []),
    { provider: 'onedrive', label: 'OneDrive', root: path.join(home, 'OneDrive - Contoso') });
  assert.equal((await providerFor(await dir(home, 'Mount', 'My Drive', 'Notes'), [])).provider, 'google-drive');
  assert.equal((await providerFor(await dir(home, 'Mobile', 'com~apple~CloudDocs', 'Notes'), [])).provider, 'icloud');
  assert.equal(await providerFor(await dir(home, 'Documents', 'Notes'), []), null);
});

test('status reports the size of an unsynced library for the copy prompt', async (t) => {
  const home = await fixture(t);
  const library = await dir(home, 'Documents', 'Notes');
  await fs.writeFile(path.join(library, 'a.md'), '12345');
  await fs.writeFile(path.join(await dir(library, 'Sub'), 'b.md'), '123');
  const status = await syncStatus(library, { env: {}, home, platform: 'linux' });
  assert.equal(status.provider, null);
  assert.deepEqual(status.size, { files: 2, bytes: 8, truncated: false });
  assert.equal((await syncStatus(null, { env: {}, home, platform: 'linux' })).folder, null);
});

test('copying a library into a sync folder copies everything but .git and never overwrites', async (t) => {
  const home = await fixture(t);
  const library = await dir(home, 'Notes');
  await fs.writeFile(path.join(library, 'a.md'), '# A');
  await fs.writeFile(path.join(await dir(library, '.frisket', 'history', 'id-x'), 'v.md'), 'old');
  await fs.writeFile(path.join(await dir(library, '.git'), 'HEAD'), 'ref');
  const cloud = await dir(home, 'OneDrive');
  await dir(cloud, 'Notes');

  const copy = await copyLibrary(library, cloud);
  assert.equal(copy, path.join(cloud, 'Notes 2'));
  assert.equal(await fs.readFile(path.join(copy, 'a.md'), 'utf8'), '# A');
  assert.equal(await fs.readFile(path.join(copy, '.frisket', 'history', 'id-x', 'v.md'), 'utf8'), 'old');
  await assert.rejects(fs.access(path.join(copy, '.git')));
  assert.equal(await fs.readFile(path.join(library, 'a.md'), 'utf8'), '# A', 'the original stays');
  await assert.rejects(copyLibrary(library, await dir(library, 'Inside')), /inside the library/);
  await assert.rejects(copyLibrary(copy, cloud), /already inside/);
});
