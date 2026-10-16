'use strict';

/**
 * Apple Notes reader (macOS only). Notes has no export format, so this asks
 * the Notes app for each note's HTML body through JavaScript for Automation.
 * The first run triggers macOS's "Frisket wants to control Notes" prompt.
 * Locked notes cannot be read and are reported as skipped; Recently Deleted
 * is left out.
 */

const { execFile } = require('node:child_process');

const SCRIPT = `
const Notes = Application('Notes');
const out = [];
for (const account of Notes.accounts()) {
  const accountName = account.name();
  for (const folder of account.folders()) {
    const folderName = folder.name();
    if (folderName === 'Recently Deleted') continue;
    const notes = folder.notes;
    const names = notes.name();
    if (!names.length) continue;
    const locked = notes.passwordProtected();
    const created = notes.creationDate();
    const modified = notes.modificationDate();
    const bodies = notes.body();
    for (let i = 0; i < names.length; i++) {
      out.push({
        account: accountName, folder: folderName, name: names[i], locked: !!locked[i],
        body: locked[i] ? null : bodies[i],
        created: created[i] ? created[i].toISOString() : null,
        modified: modified[i] ? modified[i].toISOString() : null,
      });
    }
  }
}
JSON.stringify(out);
`;

/** Read every note from the Notes app as `{ account, folder, name, locked, body, created, modified }`. */
function readAppleNotes({ run = execFile } = {}) {
  if (process.platform !== 'darwin') {
    return Promise.reject(new Error('Apple Notes import needs macOS, where the Notes app runs.'));
  }
  return new Promise((resolve, reject) => {
    run('osascript', ['-l', 'JavaScript', '-e', SCRIPT], { maxBuffer: 1024 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const detail = String(stderr || err.message || '');
        reject(new Error(/not allowed|not authori[sz]ed|-1743/i.test(detail)
          ? 'Frisket is not allowed to read Notes. Allow it in System Settings › Privacy & Security › Automation, then try again.'
          : 'Could not read Apple Notes: ' + detail.trim()));
        return;
      }
      try { resolve(JSON.parse(stdout)); } catch { reject(new Error('Apple Notes returned data Frisket could not read.')); }
    });
  });
}

module.exports = { readAppleNotes, SCRIPT };
