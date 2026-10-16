/**
 * Electron smoke test for the window's security boundary: the preload bridge
 * works in a sandboxed renderer, and nothing inside the page — a link, a
 * script or a form, as raw HTML in a note could carry — can replace the app
 * with another page that would inherit the bridge. Navigation targets are
 * local files, so a blocked web link never opens the browser during the test.
 *
 *   node build.mjs
 *   node tools/smoke-security.cjs                     # development build
 *   node tools/smoke-security.cjs path\to\Frisket.exe   # packaged build
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { spawnSync } = require('node:child_process');

const app = path.resolve(__dirname, '..');
const packaged = process.argv[2] ? path.resolve(process.argv[2]) : null;
const work = path.join(os.tmpdir(), 'frisket-smoke-security');
fs.rmSync(work, { recursive: true, force: true });
const profile = path.join(work, 'profile');
const log = path.join(work, 'frisket.log');
const shot = path.join(work, 'security.png');
fs.mkdirSync(profile, { recursive: true });

const note = path.join(work, 'library', 'probe.md');
fs.mkdirSync(path.dirname(note), { recursive: true });
fs.writeFileSync(note, '# Probe note\n\nText.\n');
const outside = path.join(work, 'outside.html');
fs.writeFileSync(outside, '<!doctype html><title>OUTSIDE</title><p>Not the app.</p>');
const outsideUrl = pathToFileURL(outside).href;

const js = (value) => JSON.stringify(value);
// Try to leave the app, then report where the page is. A build without the
// guard answers "left the app" as the page unloads.
const attempt = (code) => 'new Promise((r) => {'
  + ' addEventListener("pagehide", () => r("left the app"), { once: true });'
  + ' ' + code
  + ' setTimeout(() => r([location.pathname.split("/").slice(-2).join("/"), document.title, typeof window.frisket]), 1500);'
  + ' })';

const steps = [
  { label: 'bridge reads a file from the sandbox', check: 'window.frisket.peekFile(' + js(note) + ').then((d) => d.contents.includes("Probe note"))' },
  { label: 'no Node in the page', check: '[typeof require, typeof process, typeof module]' },
  { label: 'link click', check: attempt('const a = document.createElement("a"); a.href = ' + js(outsideUrl) + '; document.body.append(a); a.click();') },
  { label: 'script navigation', check: attempt('location.href = ' + js(outsideUrl) + ';') },
  { label: 'form submission', check: attempt('const f = document.createElement("form"); f.method = "get"; f.action = ' + js(outsideUrl) + '; document.body.append(f); f.submit();') },
  { label: 'bridge still answers', check: 'window.frisket.peekFile(' + js(note) + ').then((d) => d.contents.includes("Probe note"))' },
];

const electron = packaged || path.join(app, 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
const result = spawnSync(electron, [...(packaged ? [] : [app]), '--user-data-dir=' + profile, note], {
  cwd: app,
  env: {
    ...process.env,
    FRISKET_SMOKE: '1', FRISKET_LOG: log, FRISKET_SHOT: shot, FRISKET_SMOKE_DELAY: '2500',
    FRISKET_TYPE: JSON.stringify(steps),
  },
  timeout: 120000,
  encoding: 'utf8',
});
console.log('exit', result.status, result.error ? String(result.error) : '');
console.log(fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : 'no log');
console.log('screenshot:', fs.existsSync(shot) ? shot : 'missing');
