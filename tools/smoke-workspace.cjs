/**
 * Electron smoke test for tabs, split panes, session restore and Sync &
 * Devices. Two runs share a throwaway profile: the first works with tabs and
 * splits and leaves a session behind; the second checks it is restored.
 * A fake OneDrive folder (via the OneDrive environment variables) stands in
 * for a real sync app.
 *
 *   node build.mjs
 *   node tools/smoke-workspace.cjs                     # development build
 *   node tools/smoke-workspace.cjs path\to\Frisket.exe   # packaged build
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const app = path.resolve(__dirname, '..');
const packaged = process.argv[2] ? path.resolve(process.argv[2]) : null;
const work = path.join(os.tmpdir(), 'frisket-smoke-workspace');
fs.rmSync(work, { recursive: true, force: true });
const profile = path.join(work, 'profile');
const oneDrive = path.join(work, 'OneDrive');
const synced = path.join(oneDrive, 'Notes');
const local = path.join(work, 'Documents', 'Local notes');
fs.mkdirSync(profile, { recursive: true });

const write = (dir, rel, text) => {
  const full = path.join(dir, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, text);
  return full;
};
const alpha = write(synced, 'alpha.md', '# Alpha\n\nFirst note.\n');
const beta = write(synced, 'beta.md', '# Beta\n\nSecond note.\n');
const gamma = write(synced, 'gamma.md', '# Gamma\n\nThird note.\n');
write(local, 'only-here.md', '# Only here\n\nA note on this computer.\n');

const js = (value) => JSON.stringify(value);
const later = (expr, ms) => 'new Promise((r) => setTimeout(() => r(' + expr + '), ' + ms + '))';
const t = 'window.__frisketTest';
const tabs = t + '.tabs().map((p) => (p.focused ? "*" : "") + p.tabs.join(",") + " [" + p.active + "]").join(" | ")';
const modal = "[document.querySelector('#modal h2')?.textContent, document.querySelector('#modal .modal-sub')?.textContent]";

const firstRun = [
  { label: 'open synced library', check: t + '.setFolder(' + js(synced) + '); true' },
  { label: 'sync chip', check: later("document.querySelector('#library-sync span')?.textContent", 1500) },
  { label: 'open alpha (reuses the blank tab)', check: t + '.openTab(' + js(alpha) + ').then(() => ' + tabs + ')' },
  { label: 'open beta in a new tab', check: t + '.openTab(' + js(beta) + ', { newTab: true }).then(() => ' + tabs + ')' },
  { label: 'next tab', check: t + '.command("tab:next").then(() => ' + tabs + ')' },
  { label: 'split right', check: t + '.command("view:split", "row").then(() => ' + later(tabs, 300) + ')' },
  { label: 'caret to end of the right pane', check: t + '.caretTo(1e9); true' },
  { text: 'Typed on the right.' },
  { label: 'both panes show the edit', check: later(t + '.tabs().map((p) => p.text.includes("Typed on the right.") + ":" + p.tabs.join(","))', 300) },
  { label: 'save (clears the dot on both tabs)', check: t + '.command("file:save").then(() => ' + later(tabs, 200) + ')' },
  { label: 'on disk', check: later('null', 400) + '.then(() => window.frisket.peekFile(' + js(alpha) + ')).then((d) => d.contents.includes("Typed on the right."))' },
  { label: 'focus left, pick beta, move it right', check: t + '.command("view:focus-other-pane").then(() => ' + t + '.openTab(' + js(beta) + ')).then(() => ' + t + '.command("tab:move-other")).then(() => ' + later(tabs, 200) + ')' },
  { label: 'stack the panes', check: t + '.command("view:split-orientation").then(() => ' + t + '.orientation())' },
  { label: 'close beta', check: t + '.command("tab:close").then(() => ' + later(tabs, 200) + ')' },
  { label: 'new tab', check: t + '.command("file:new").then(() => ' + tabs + ')' },
  { text: 'An unsaved draft' },
  { label: 'close it: unsaved prompt', check: t + '.command("tab:close"); ' + later(modal, 500) },
  { label: "don't save", check: "[...document.querySelectorAll('#modal button')].find((b) => b.textContent === \"Don't Save\").click(); " + later(tabs, 400) },
  { label: 'close split', check: t + '.command("view:unsplit").then(() => ' + later(tabs, 300) + ')' },
  { label: 'split again and open gamma on the right', check: t + '.command("view:split", "row").then(() => ' + t + '.openTab(' + js(gamma) + ', { newTab: true })).then(() => ' + later(tabs, 300) + ')' },

  { label: 'open local library', check: t + '.setFolder(' + js(local) + '); ' + later("document.querySelector('#library-sync span')?.textContent", 1500) },
  { label: 'sync dialog', check: t + '.command("sync:show"); ' + later("[document.querySelector('#modal .sync-card strong')?.textContent, [...document.querySelectorAll('#modal .sync-provider small')].map((s) => s.textContent).includes(" + js(oneDrive) + ")]", 1200) },
  { label: 'copy into OneDrive', check: "[...document.querySelectorAll('#modal .sync-provider')].find((r) => r.querySelector('small').textContent === " + js(oneDrive) + ").querySelector('[data-copy]').click(); " + later(modal, 500) },
  { label: 'confirm copy', check: "[...document.querySelectorAll('#modal button')].find((b) => b.textContent === 'Copy and open').click(); " + later('[' + t + '.syncStatus()?.provider?.label, ' + t + '.syncStatus()?.folder, document.querySelector("#library-sync span")?.textContent]', 2500) },
  { label: 'copied note exists', check: 'window.frisket.peekFile(' + js(path.join(oneDrive, 'Local notes', 'only-here.md')) + ').then((d) => !d.error)' },
  { label: 'session saved', check: later(t + '.settings().session && ' + t + '.settings().session.panes.map((p) => p.tabs.map((x) => x.split(/[\\\\/]/).pop()).join(","))', 800) },
];

const secondRun = [
  { label: 'restored tabs (right pane focused, as left)', check: later(tabs, 800) },
  { label: 'restored orientation', check: t + '.orientation()' },
];

const electron = packaged || path.join(app, 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
function run(name, steps) {
  const log = path.join(work, name + '.log');
  const shot = path.join(work, name + '.png');
  const result = spawnSync(electron, [...(packaged ? [] : [app]), '--user-data-dir=' + profile], {
    cwd: app,
    env: {
      ...process.env,
      OneDrive: oneDrive, OneDriveConsumer: oneDrive, OneDriveCommercial: '',
      FRISKET_SMOKE: '1', FRISKET_LOG: log, FRISKET_SHOT: shot, FRISKET_WINDOW: '1500x900', FRISKET_SMOKE_DELAY: '2500',
      FRISKET_TYPE: JSON.stringify(steps),
    },
    timeout: 180000,
    encoding: 'utf8',
  });
  console.log('--- ' + name + ': exit', result.status, result.error ? String(result.error) : '');
  console.log(fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : 'no log');
  console.log('screenshot:', fs.existsSync(shot) ? shot : 'missing');
}

run('first-run', firstRun);
run('second-run', secondRun);
