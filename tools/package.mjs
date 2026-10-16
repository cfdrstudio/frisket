/**
 * Package Frisket for Windows.
 *
 * electron-builder normally stamps the executable's icon and version info
 * itself, but that step pulls in its `winCodeSign` bundle, which contains
 * macOS symlinks. Extracting those needs either Administrator rights or
 * Windows Developer Mode, so on a locked-down machine the whole build fails
 * before it starts.
 *
 * The workaround is to do it in three passes:
 *   1. pack the app with `signAndEditExecutable: false`
 *   2. stamp the icon and version strings with rcedit directly
 *   3. build the installers from the already-packed directory
 *
 * If a usable rcedit is not on hand, step 2 is skipped with a warning and the
 * executable simply keeps Electron's default icon. The app itself still shows
 * the Frisket icon at runtime, because that comes from BrowserWindow.
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const dirOnly = process.argv.includes('--dir-only');

const unpacked = path.join(root, 'release', 'win-unpacked');
const exePath = path.join(unpacked, pkg.build.productName + '.exe');
const iconPath = path.join(root, 'assets', 'icon.ico');

function run(command, args, label) {
  console.log('\n> ' + label);
  const result = spawnSync(command, args, {
    cwd: root,
    stdio: 'inherit',
    shell: process.platform === 'win32',
    env: { ...process.env, CSC_IDENTITY_AUTO_DISCOVERY: 'false' },
  });
  if (result.status !== 0) {
    console.error('\n' + label + ' failed with exit code ' + result.status);
    process.exit(result.status ?? 1);
  }
}

/** rcedit ships inside electron-builder's winCodeSign cache; find any copy. */
function findRcedit() {
  const cache = path.join(
    process.env.LOCALAPPDATA || os.homedir(),
    'electron-builder', 'Cache', 'winCodeSign',
  );
  const candidates = [path.join(root, 'tools', 'rcedit-x64.exe')];
  try {
    for (const entry of fs.readdirSync(cache)) {
      candidates.push(path.join(cache, entry, 'rcedit-x64.exe'));
    }
  } catch { /* no cache yet */ }
  return candidates.find((c) => fs.existsSync(c)) || null;
}

function stampExecutable() {
  const rcedit = findRcedit();
  if (!rcedit) {
    console.warn('\n! rcedit not found — the executable will keep the default Electron icon.');
    return;
  }
  if (!fs.existsSync(exePath)) {
    console.warn('\n! ' + exePath + ' not found — skipping icon stamping.');
    return;
  }
  console.log('\n> stamping icon and version info with rcedit');
  const result = spawnSync(rcedit, [
    exePath,
    '--set-icon', iconPath,
    '--set-version-string', 'ProductName', pkg.build.productName,
    '--set-version-string', 'FileDescription', pkg.description,
    '--set-version-string', 'CompanyName', pkg.author.name,
    '--set-version-string', 'LegalCopyright', pkg.build.copyright,
    '--set-version-string', 'InternalName', pkg.build.productName,
    '--set-version-string', 'OriginalFilename', pkg.build.productName + '.exe',
    '--set-file-version', pkg.version,
    '--set-product-version', pkg.version + '.0',
  ], { stdio: 'inherit' });
  if (result.status !== 0) {
    console.warn('! rcedit failed; continuing with the default icon.');
  }
}

// macOS needs none of the workaround below: electron-builder signs, packages
// and notarizes there in one pass, so hand straight over to it.
if (process.platform !== 'win32') {
  run('npx', ['electron-builder', dirOnly ? '--dir' : ''].filter(Boolean), 'building');
  console.log('\nDone. Artifacts in ' + path.join(root, 'release'));
  process.exit(0);
}

run('npx', ['electron-builder', '--win', '--dir'], 'packing application');
stampExecutable();

if (dirOnly) {
  console.log('\nDone. Unpacked build: ' + unpacked);
  process.exit(0);
}

run('npx', ['electron-builder', '--win', '--prepackaged', unpacked], 'building installers');

const releaseDir = path.join(root, 'release');
const artifacts = fs.readdirSync(releaseDir)
  .filter((f) => f.endsWith('.exe'))
  .map((f) => {
    const { size } = fs.statSync(path.join(releaseDir, f));
    return '  ' + f + '  (' + (size / 1024 / 1024).toFixed(1) + ' MB)';
  });

console.log('\nDone. Artifacts in ' + releaseDir + ':');
console.log(artifacts.join('\n'));
