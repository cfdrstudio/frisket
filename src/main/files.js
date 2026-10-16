'use strict';

/** File writes shared by the main process and the index worker. No Electron imports. */

const fsp = require('node:fs/promises');
const path = require('node:path');

/**
 * Replace `file` atomically: write a hidden temporary file beside it, then
 * rename over it. With `expectedMtime`, refuse (and leave the file alone) if
 * it changed on disk since that time.
 */
async function replaceFile(file, text, expectedMtime = null) {
  const temporary = path.join(path.dirname(file), '.' + path.basename(file) + '.' + process.pid + '.' + Date.now() + '.tmp');
  await fsp.writeFile(temporary, text, 'utf8');
  try {
    if (expectedMtime !== null && expectedMtime !== undefined) {
      const current = await fsp.stat(file);
      if (Math.abs(current.mtimeMs - expectedMtime) > 1) throw new Error('changed on disk');
    }
    await fsp.rename(temporary, file);
  } catch (err) {
    await fsp.rm(temporary, { force: true });
    throw err;
  }
}

/** Is `candidate` inside (or equal to) `root`? Both are resolved first. */
function within(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep));
}

/** A file or folder name that is safe on Windows, macOS and Linux. */
function safeName(name, fallback = 'Untitled', max = 120) {
  const clean = String(name || '')
    .replace(/[<>:"/\\|?*\x00-\x1f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/g, '')
    .slice(0, max)
    .trim();
  if (!clean || /^\.+$/.test(clean) || /^(?:con|prn|aux|nul|com\d|lpt\d)$/i.test(clean)) return fallback;
  return clean;
}

/** The first `<dir>/<stem><ext>`, `<stem> 2<ext>`, … that does not exist and is not reserved. */
async function uniquePath(dir, stem, ext, reserved = null) {
  for (let n = 1; n < 10000; n++) {
    const candidate = path.join(dir, stem + (n === 1 ? '' : ' ' + n) + ext);
    const key = candidate.toLowerCase();
    if (reserved && reserved.has(key)) continue;
    try { await fsp.access(candidate); } catch {
      if (reserved) reserved.add(key);
      return candidate;
    }
  }
  throw new Error('Could not choose a unique name for ' + stem + ext);
}

module.exports = { replaceFile, within, safeName, uniquePath };
