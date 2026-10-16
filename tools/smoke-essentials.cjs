/**
 * Electron smoke test for library features: note-list search,
 * back/forward, the backlinks pane and its Link button, pinning, version
 * history, today's note, Evernote import and the sync-conflict resolver.
 * Drives the real app through the FRISKET_SMOKE / FRISKET_TYPE hooks against a
 * fixture library and a throwaway profile.
 *
 *   node build.mjs
 *   node tools/smoke-essentials.cjs                    # development build
 *   node tools/smoke-essentials.cjs path\to\Frisket.exe  # packaged build
 */
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const app = path.resolve(__dirname, '..');
const packaged = process.argv[2] ? path.resolve(process.argv[2]) : null;
const work = path.join(os.tmpdir(), 'frisket-smoke-essentials');
fs.rmSync(work, { recursive: true, force: true });
const lib = path.join(work, 'library');
const profile = path.join(work, 'profile');
const log = path.join(work, 'frisket.log');
const shot = path.join(work, 'essentials.png');
fs.mkdirSync(profile, { recursive: true });

const write = (rel, text) => {
  const full = path.join(lib, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, text);
  return full;
};
const planText = '---\nfrisket-id: plan\n---\n\n# Project Plan\n\nGoals for the quarter. #work\n\n- [ ] Draft the brief\n';
const plan = write('Notes/plan.md', planText);
const log1 = write('Notes/log.md', '# Log\n\nWe discussed the Project Plan today.\nSee [[Project Plan]].\n');
write('Notes/other.md', '# Other\n\nA quick brown fox.\n');
const copy = write("Notes/plan (Test's conflicted copy 2026-10-15).md", planText.replace('Goals for the quarter.', 'Goals edited on the laptop.'));

const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');
const enex = path.join(work, 'Travel.enex');
fs.writeFileSync(enex, '<?xml version="1.0"?><en-export><note><title>Imported trip</title><content><![CDATA[<en-note><div>Imported trip</div>'
  + '<div><en-todo/>Book train</div><en-media hash="' + crypto.createHash('md5').update(png).digest('hex') + '" type="image/png"/></en-note>]]></content>'
  + '<created>20240102T030405Z</created><tag>travel</tag><resource><data encoding="base64">' + png.toString('base64')
  + '</data><mime>image/png</mime><resource-attributes><file-name>map.png</file-name></resource-attributes></resource></note></en-export>');

const js = (value) => JSON.stringify(value);
const later = (expr, ms) => 'new Promise((r) => setTimeout(() => r(' + expr + '), ' + ms + '))';
const t = 'window.__frisketTest';
const listTitles = "[...document.querySelectorAll('#note-list .note-card strong')].map((e) => e.textContent)";
const docTitle = 'document.getElementById("doc-title").textContent';
const modalText = "[document.querySelector('#modal h2')?.textContent, document.querySelector('#modal .modal-sub')?.textContent]";
const today = (() => { const d = new Date(); const p = (n) => String(n).padStart(2, '0'); return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()); })();

const steps = [
  { label: 'open library', check: t + '.setFolder(' + js(lib) + '); true' },
  { label: 'notes (conflict copy hidden)', check: later(listTitles, 1500) },
  { label: 'conflicts filter shown', check: "document.querySelector('[data-filter=conflicts]')?.textContent" },

  { label: 'focus list search', check: "document.getElementById('library-search').focus(); true" },
  { text: 'fox' },
  { label: 'search results', check: later("[" + listTitles + ", document.getElementById('note-list-count').textContent, document.querySelector('.note-card-match')?.innerHTML]", 700) },
  { key: 'Escape' },
  { label: 'search cleared', check: later(listTitles, 400) },

  { label: 'open plan', check: t + '.command("file:open-path", ' + js(plan) + ').then(() => ' + docTitle + ')' },
  { label: 'open log', check: t + '.command("file:open-path", ' + js(log1) + ').then(() => ' + docTitle + ')' },
  { label: 'back', check: t + '.command("nav:back").then(() => [' + docTitle + ', document.getElementById("btn-forward").disabled])' },
  { label: 'forward', check: t + '.command("nav:forward").then(() => [' + docTitle + ', document.getElementById("btn-back").disabled])' },
  { label: 'back again', check: t + '.command("nav:back").then(() => ' + docTitle + ')' },

  { label: 'backlinks pane', check: t + '.command("view:backlinks").then(() => ' + later("document.getElementById('backlinks-body').innerText", 900) + ')' },
  { label: 'link the mention', check: "document.querySelector('.backlink-link').click(); true" },
  { label: 'log on disk', check: later('null', 1200) + '.then(() => window.frisket.peekFile(' + js(log1) + ')).then((d) => d.contents)' },
  { label: 'backlinks after linking', check: "document.getElementById('backlinks-body').innerText" },

  { label: 'pin plan', check: t + '.command("note:toggle-pin").then(() => ' + later("[document.querySelector('#note-list .note-card')?.classList.contains('is-pinned'), document.querySelector('#note-list .note-card strong')?.textContent]", 900) + ')' },
  { label: 'plan front matter', check: 'window.frisket.peekFile(' + js(plan) + ').then((d) => d.contents.split("\\n").slice(0, 4).join("|"))' },

  { label: 'caret to end', check: t + '.caretTo(1e9); true' },
  { text: 'An edit to undo.' },
  { label: 'save', check: t + '.command("file:save").then(() => true)' },
  { label: 'history dialog', check: t + '.command("note:history"); ' + later("[document.querySelectorAll('.history-item').length, document.getElementById('history-summary')?.textContent]", 1200) },
  { label: 'restore', check: "document.getElementById('history-restore').click(); " + later(t + '.content().includes("An edit to undo.")', 300) },
  { label: 'save restored', check: t + '.command("file:save").then(() => window.frisket.peekFile(' + js(plan) + ')).then((d) => d.contents.includes("An edit to undo."))' },

  { label: "today's note", check: t + '.command("note:daily").then(() => ' + docTitle + ')' },
  { label: 'daily file', check: 'window.frisket.peekFile(' + js(path.join(lib, 'Daily', today + '.md')) + ').then((d) => d.contents)' },

  { label: 'import evernote', check: t + '.import("evernote", [' + js(enex) + ']); ' + later(modalText, 1500) },
  { label: 'close import report', check: "document.querySelector('#modal button.primary').click(); " + later(listTitles, 800) },

  { label: 'conflicts view', check: "document.querySelector('[data-filter=conflicts]').click(); " + later(listTitles + ".concat([document.querySelector('.note-card-conflict')?.textContent])", 400) },
  { label: 'resolver', check: "document.querySelector('#note-list .note-card').click(); " + later(modalText + ".concat([document.querySelectorAll('#modal .diff-add').length, document.querySelectorAll('#modal .diff-del').length])", 900) },
  { label: 'keep original', check: "document.querySelector('#modal [data-action=keep-original]').click(); " + later("[document.querySelector('[data-filter=conflicts]') === null, " + listTitles + "]", 1500) },
  { label: 'copy trashed on disk', check: 'window.frisket.peekFile(' + js(copy) + ').then((d) => /frisket-trashed-at/.test(d.contents))' },

  { label: 'reopen plan for screenshot', check: t + '.command("file:open-path", ' + js(plan) + ').then(() => ' + later("document.getElementById('backlinks-body').innerText.split('\\n').slice(0, 3)", 900) + ')' },
];

const electron = packaged || path.join(app, 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
const result = spawnSync(electron, [...(packaged ? [] : [app]), '--user-data-dir=' + profile], {
  cwd: app,
  env: {
    ...process.env,
    FRISKET_SMOKE: '1',
    FRISKET_LOG: log,
    FRISKET_SHOT: shot,
    FRISKET_WINDOW: '1500x900',
    FRISKET_SMOKE_DELAY: '2500',
    FRISKET_TYPE: JSON.stringify(steps),
  },
  timeout: 180000,
  encoding: 'utf8',
});
console.log('exit', result.status, result.error ? String(result.error) : '');
console.log(fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : 'no log');
console.log('screenshot:', fs.existsSync(shot) ? shot : 'missing');
