/**
 * Generate THIRD-PARTY-NOTICES.md from the production dependency tree.
 *
 * Every permissive licence in the stack (MIT, ISC, BSD, Apache-2.0) requires
 * that its copyright notice and licence text travel with the binaries you
 * distribute. This collects them so the shipped app satisfies that.
 *
 * Run: node tools/licenses.mjs
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LICENSE_FILES = [
  'LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE', 'LICENCE.md', 'LICENCE.txt',
  'license', 'license.md', 'license.txt', 'COPYING', 'COPYING.md',
];

/** npm ships alongside whichever node is running, including a portable one. */
function npmCli() {
  const candidates = [
    path.join(path.dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    path.join(root, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    path.join(path.dirname(process.execPath), '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js'),
  ];
  const found = candidates.find((c) => fs.existsSync(c));
  if (!found) throw new Error('Could not locate npm-cli.js next to ' + process.execPath);
  return found;
}

/** Walk the production tree reported by npm and collect every distinct package. */
function productionPackages() {
  const raw = execFileSync(
    process.execPath,
    [npmCli(), 'ls', '--omit=dev', '--all', '--json', '--long'],
    { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  );
  const tree = JSON.parse(raw);
  const seen = new Map();

  const visit = (node) => {
    for (const [name, dep] of Object.entries(node.dependencies || {})) {
      const key = name + '@' + (dep.version || '?');
      if (!seen.has(key)) {
        seen.set(key, { name, version: dep.version, dir: dep.path });
        visit(dep);
      }
    }
  };
  visit(tree);
  return [...seen.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function readPackage(dir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  } catch {
    return {};
  }
}

function licenseId(pkg, dir) {
  let id = pkg.license || pkg.licenses;
  if (Array.isArray(id)) id = id.map((x) => x.type || x).join(' OR ');
  if (id && typeof id === 'object') id = id.type;
  if (id) return id;
  // Some packages omit the field but still ship the file.
  const text = licenseText(dir);
  if (/MIT License/i.test(text)) return 'MIT';
  if (/Apache License/i.test(text)) return 'Apache-2.0';
  if (/ISC License/i.test(text)) return 'ISC';
  return 'See licence text';
}

function licenseText(dir) {
  for (const name of LICENSE_FILES) {
    const file = path.join(dir, name);
    try {
      if (fs.statSync(file).isFile()) return fs.readFileSync(file, 'utf8').trim();
    } catch { /* try the next candidate */ }
  }
  return '';
}

const packages = productionPackages();
const missing = [];

const sections = packages.map(({ name, version, dir }) => {
  if (!dir || !fs.existsSync(dir)) { missing.push(name); return null; }
  const pkg = readPackage(dir);
  const id = licenseId(pkg, dir);
  const text = licenseText(dir);
  if (!text) missing.push(name + ' (no licence file)');
  return [
    '### ' + name + ' — ' + version,
    '',
    'Licence: **' + id + '**'
      + (pkg.homepage ? '  ·  ' + pkg.homepage : ''),
    '',
    text ? '```\n' + text + '\n```' : '_Licence text not included in the published package._',
    '',
  ].join('\n');
}).filter(Boolean);

const header = `# Third-Party Notices

Frisket is built on open-source software. The components below are included in
or bundled with the application, and are distributed under their own licences.
Their copyright notices and licence texts are reproduced here in full, as those
licences require.

Frisket also runs on **Electron**, which embeds **Chromium** and **Node.js**.
Electron is MIT-licensed; Chromium and Node.js carry their own notices, viewable
in the running application at \`chrome://credits\`.

---

## Summary

| Component | Licence |
| --- | --- |
${packages.map(({ name, version, dir }) =>
    `| ${name} ${version} | ${dir && fs.existsSync(dir) ? licenseId(readPackage(dir), dir) : '?'} |`).join('\n')}

---

## Full licence texts

`;

const out = path.join(root, 'THIRD-PARTY-NOTICES.md');
fs.writeFileSync(out, header + sections.join('\n'), 'utf8');

console.log('Wrote ' + out);
console.log('  packages: ' + packages.length);
if (missing.length) {
  console.log('  needs a manual check: ' + missing.join(', '));
}
