/**
 * Electron smoke test for the library index, link resolution and autocomplete.
 * Drives the real app with real key events
 * through the FRISKET_SMOKE / FRISKET_TYPE hooks in src/main/main.js, against
 * a fixture library and a throwaway profile, so your own settings and recent
 * files are never touched.
 *
 *   node build.mjs
 *   node tools/smoke-library.cjs                  # development build
 *   node tools/smoke-library.cjs path\to\Frisket.exe   # packaged build
 *
 * Prints each check's result, then the log and screenshot locations. A
 * packaged run that logs "library index: worker unavailable" means the worker
 * failed to load from app.asar.unpacked and the app fell back to in-process.
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const app = path.resolve(__dirname, '..');
const packaged = process.argv[2] ? path.resolve(process.argv[2]) : null;
const work = path.join(os.tmpdir(), 'frisket-smoke-library');
fs.rmSync(work, { recursive: true, force: true });
const lib = path.join(work, 'library');
const profile = path.join(work, 'profile');
const log = path.join(work, 'frisket.log');
const shot = path.join(work, 'autocomplete.png');
fs.mkdirSync(profile, { recursive: true });

const write = (rel, text) => {
  const full = path.join(lib, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, text);
  return full;
};
const planHead = '---\nfrisket-id: plan-id\n---\n\n# Project Plan';
const plan = write('Notes/2026-10-14-untitled.md', planHead + '\n\nGoals for the quarter. #work/projects\n');
const daily = write('Notes/daily.md', '# Daily\n\nSee [[Project Plan]] for details. #work\n');
write('a/one.md', '# Meeting\n\nFirst meeting.\n');
write('b/two.md', '# Meeting\n\nSecond meeting.\n');
const external = path.join(lib, 'Notes', 'external.md');

const js = (value) => JSON.stringify(value);
const later = (expr, ms) => 'new Promise((r) => setTimeout(() => r(' + expr + '), ' + ms + '))';
const listTitles = "[...document.querySelectorAll('#note-list .note-card strong')].map((e) => e.textContent)";
const popup = "[...document.querySelectorAll('.cm-tooltip-autocomplete li')].map((li) => li.textContent)";

const steps = [
  { label: 'open library', check: 'window.__frisketTest.setFolder(' + js(lib) + '); true' },
  { label: 'note list', check: later(listTitles, 1500) },
  { label: 'open daily', check: 'window.__frisketTest.command("file:open-path", ' + js(daily) + ').then(() => document.getElementById("doc-title").textContent)' },
  { label: 'caret to end', check: 'window.__frisketTest.caretTo(1e9); true' },
  { key: 'Enter' },
  { text: '[[Proj' },
  { label: 'note completions for [[Proj', check: later(popup, 400) },
  { key: 'Enter' },
  { label: 'after accepting', check: 'window.__frisketTest.content().split("\\n").pop()' },
  { key: 'Enter' },
  { text: 'Filed #wo' },
  { label: 'tag completions for #wo', check: later(popup, 400) },
  { key: 'Escape' },
  { key: 'Enter' },
  { text: '[[Meet' },
  { label: 'duplicate-title completions', check: later(popup, 400) },
  { key: 'Enter' },
  { label: 'after accepting duplicate', check: 'window.__frisketTest.content().split("\\n").pop()' },
  { label: 'save daily', check: 'window.__frisketTest.command("file:save").then(() => true)' },
  { label: 'external write', check: 'window.frisket.writeFile(' + js(external) + ', "# External note\\n", null).then((r) => !!r.ok)' },
  { label: 'list after external write (no manual refresh)', check: later(listTitles, 2000) },
  { label: 'open plan', check: 'window.__frisketTest.command("file:open-path", ' + js(plan) + ').then(() => document.getElementById("doc-title").textContent)' },
  { label: 'caret to heading end', check: 'window.__frisketTest.caretTo(' + planHead.length + '); true' },
  { text: ' v2' },
  { label: 'manual save', check: 'window.__frisketTest.command("file:save"); true' },
  { label: 'prompt', check: later("[document.querySelector('#modal h2')?.textContent, document.querySelector('#modal .modal-sub')?.textContent]", 1500) },
  { label: 'accept prompt', check: "document.querySelector('#modal button.primary').click(); true" },
  { label: 'daily on disk', check: later('null', 1200) + '.then(() => window.frisket.readFile(' + js(daily) + ')).then((d) => d.contents)' },
  { label: 'backlinks for plan', check: 'window.frisket.workspaceOverview(' + js(lib) + ', ' + js(plan) + ', true).then((o) => o.backlinks.linked.map((l) => l.excerpt))' },
  { label: 'truncated', check: 'window.frisket.workspaceOverview(' + js(lib) + ', null, false).then((o) => o.truncated)' },
  { key: 'End', modifiers: ['control'] },
  { key: 'Enter' },
  { text: '[[' },
  { label: 'popup for screenshot', check: later(popup, 400) },
];

const electron = packaged || path.join(app, 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
const result = spawnSync(electron, [...(packaged ? [] : [app]), '--user-data-dir=' + profile], {
  cwd: app,
  env: {
    ...process.env,
    FRISKET_SMOKE: '1',
    FRISKET_LOG: log,
    FRISKET_SHOT: shot,
    FRISKET_WINDOW: '1400x900',
    FRISKET_SMOKE_DELAY: '2500',
    FRISKET_TYPE: JSON.stringify(steps),
  },
  timeout: 120000,
  encoding: 'utf8',
});
console.log('exit', result.status, result.error ? String(result.error) : '');
console.log(fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : 'no log');
console.log('screenshot:', fs.existsSync(shot) ? shot : 'missing');
