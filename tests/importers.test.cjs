'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const zlib = require('node:zlib');
const { htmlToMarkdown } = require('../src/main/importers/html');
const { parseEnex } = require('../src/main/importers/enex');
const { readZip } = require('../src/main/importers/zip');
const { stripNotionId, csvToMarkdownTable } = require('../src/main/importers/notion');
const { runImport, withTitle } = require('../src/main/importers');
const { scanWorkspace, summarizeNotes } = require('../src/main/workspace');

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'frisket-import-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

/** A minimal ZIP writer for tests: stored or deflated entries, UTF-8 names. */
function makeZip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const raw = Buffer.isBuffer(entry.data) ? entry.data : Buffer.from(entry.data);
    const data = entry.deflate ? zlib.deflateRawSync(raw) : raw;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(entry.deflate ? 8 : 0, 8); local.writeUInt32LE(data.length, 18); local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(name.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(0x800, 8);
    central.writeUInt16LE(entry.deflate ? 8 : 0, 10); central.writeUInt32LE(data.length, 20); central.writeUInt32LE(raw.length, 24);
    central.writeUInt16LE(name.length, 28); central.writeUInt32LE(offset, 42);
    locals.push(local, name, data);
    centrals.push(central, name);
    offset += local.length + name.length + data.length;
  }
  const directory = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

test('HTML converts to readable Markdown', () => {
  const markdown = htmlToMarkdown('<div>Shopping &amp; errands</div><div><en-todo checked="true"/>Milk</div><div><en-todo/>Eggs</div>'
    + '<ul><li>One<ul><li>Nested</li></ul></li><li>Two</li></ul><h2>Section</h2><p>A <b>bold </b>and <i>quiet</i> '
    + '<a href="https://example.test/a b">link</a>.</p><div>1. not a list</div><blockquote><div>quoted</div></blockquote>'
    + '<pre>code &lt;x&gt;</pre><table><tr><th>a|b</th><th>c</th></tr><tr><td>d</td></tr></table>'
    + '<div>Line 1<br>Line 2</div><script>alert(1)</script><div>Issue #42</div>');
  assert.equal(markdown, [
    'Shopping & errands', '', '- [x] Milk', '- [ ] Eggs', '', '- One', '  - Nested', '- Two', '', '## Section', '',
    'A **bold** and *quiet* [link](<https://example.test/a b>).', '', '1\\. not a list', '', '> quoted', '',
    '```', 'code <x>', '```', '', '| a\\|b | c |', '| --- | --- |', '| d |   |', '', 'Line 1  ', 'Line 2', '', 'Issue \\#42',
  ].join('\n'));
});

test('withTitle promotes a matching first line instead of repeating it', () => {
  assert.equal(withTitle('**Trip plan**\n\nDetails', 'Trip plan'), '# Trip plan\n\nDetails');
  assert.equal(withTitle('Details', 'Trip plan'), '# Trip plan\n\nDetails');
  assert.equal(withTitle('', 'Empty'), '# Empty');
});

const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');
const PDF = Buffer.from('%PDF-1.4 tiny');
const ENEX = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export3.dtd">\n'
  + '<en-export application="Evernote"><note><title>Trip &amp; plan</title><content><![CDATA[<?xml version="1.0"?>'
  + '<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note><div>Trip &amp; plan</div><div>Pack <b>light</b>.</div>'
  + '<div><en-todo checked="false"/>Passport</div><en-media hash="' + require('node:crypto').createHash('md5').update(PNG).digest('hex')
  + '" type="image/png"/></en-note>]]></content><created>20240102T030405Z</created><updated>20240203T040506Z</updated>'
  + '<tag>travel</tag><tag>Work/Projects</tag><resource><data encoding="base64">\n' + PNG.toString('base64') + '\n</data>'
  + '<mime>image/png</mime><resource-attributes><file-name>map photo.png</file-name></resource-attributes></resource>'
  + '<resource><data encoding="base64">' + PDF.toString('base64') + '</data><mime>application/pdf</mime></resource></note>'
  + '<note><title>Second</title><content><![CDATA[<en-note><div>Hello</div></en-note>]]></content></note></en-export>';

test('parseEnex reads notes, dates, tags and resources', () => {
  const [first, second] = parseEnex(ENEX);
  assert.equal(first.title, 'Trip & plan');
  assert.equal(first.created, '2024-01-02T03:04:05.000Z');
  assert.equal(first.updated, '2024-02-03T04:05:06.000Z');
  assert.deepEqual(first.tags, ['travel', 'Work/Projects']);
  assert.deepEqual(first.resources.map((r) => [r.name, r.mime, r.data.length]), [['map photo.png', 'image/png', PNG.length], ['attachment-2.pdf', 'application/pdf', PDF.length]]);
  assert.equal(second.title, 'Second');
  assert.throws(() => parseEnex('<html></html>'), /not an Evernote export/);
});

test('an Evernote import writes notes, front matter and attachments', async (t) => {
  const library = await fixture(t);
  const source = path.join(await fixture(t), 'Travel.enex');
  await fs.writeFile(source, ENEX);
  const report = await runImport({ kind: 'evernote', source, root: library, date: '2026-10-15' });
  assert.deepEqual({ folder: report.folder, notes: report.notes, attachments: report.attachments, skipped: report.skipped },
    { folder: 'Imported/Evernote 2026-10-15', notes: 2, attachments: 2, skipped: [] });

  const notePath = path.join(library, 'Imported', 'Evernote 2026-10-15', 'Trip & plan.md');
  const text = await fs.readFile(notePath, 'utf8');
  const id = /frisket-id: (\S+)/.exec(text)[1];
  assert.match(text, /^---\nfrisket-id: [0-9a-f-]{36}\nfrisket-created: 2024-01-02T03:04:05.000Z\nfrisket-source: evernote\ntags:\n {2}- "travel"\n {2}- "Work\/Projects"\n---\n\n# Trip & plan\n\nPack \*\*light\*\*\.\n\n- \[ \] Passport\n\n!\[map photo\.png\]\(<\.\.\/\.\.\/Assets\/[0-9a-f-]+\/map photo\.png>\)\n\n## Attachments\n\n- \[attachment-2\.pdf\]\(\.\.\/\.\.\/Assets\/[0-9a-f-]+\/attachment-2\.pdf\)\n$/);
  assert.deepEqual(await fs.readFile(path.join(library, 'Assets', id, 'map photo.png')), PNG);
  assert.equal((await fs.stat(notePath)).mtime.toISOString(), '2024-02-03T04:05:06.000Z');

  // The imported notes are ordinary library notes to the index.
  const summaries = summarizeNotes(await scanWorkspace(library));
  const trip = summaries.find((note) => note.title === 'Trip & plan');
  assert.deepEqual([trip.tags, trip.tasksTotal, trip.hasImages], [['travel', 'Work/Projects'], 1, true]);

  const again = await runImport({ kind: 'evernote', source, root: library, date: '2026-10-15' });
  assert.equal(again.folder, 'Imported/Evernote 2026-10-15 2', 'a second import never overwrites the first');
});

test('readZip reads stored and deflated entries and rejects escaping names', () => {
  const zip = makeZip([
    { name: 'a.txt', data: 'stored' },
    { name: 'dir/b.txt', data: 'deflated text '.repeat(20), deflate: true },
    { name: '../evil.txt', data: 'no' },
    { name: 'C:/evil.txt', data: 'no' },
  ]);
  const entries = readZip(zip);
  assert.deepEqual(entries.map((entry) => entry.name), ['a.txt', 'dir/b.txt']);
  assert.equal(entries[0].read().toString(), 'stored');
  assert.equal(entries[1].read().toString(), 'deflated text '.repeat(20));
  assert.throws(() => readZip(Buffer.from('not a zip at all, definitely not')), /not a ZIP/);
});

const ID1 = '0123456789abcdef0123456789abcdef';
const ID2 = 'fedcba9876543210fedcba9876543210';
const ID3 = '11111111111111111111111111111111';
function notionFiles() {
  return [
    { name: `Export-1a2b3c4d/Plan ${ID1}.md`, data: `# Plan\n\nSee [Child](Plan%20${ID1}/Child%20${ID2}.md) and ![diagram](Plan%20${ID1}/diagram.png).\nExternal [site](https://www.notion.so/x).\n` },
    { name: `Export-1a2b3c4d/Plan ${ID1}/Child ${ID2}.md`, data: `# Child\n\nBack to [Plan](../Plan%20${ID1}.md#goals).\n` },
    { name: `Export-1a2b3c4d/Plan ${ID1}/diagram.png`, data: PNG },
    { name: `Export-1a2b3c4d/Tasks ${ID3}.csv`, data: '\ufeffName,Status\n"Write, then edit",Done\nShip,"To do"\n' },
    { name: `Export-1a2b3c4d/Tasks ${ID3}_all.csv`, data: 'Name,Status\nDuplicate,x\n' },
  ];
}

async function checkNotionImport(library, report) {
  assert.equal(report.notes, 3);
  assert.equal(report.attachments, 1);
  const base = path.join(library, report.folder);
  const plan = await fs.readFile(path.join(base, 'Plan.md'), 'utf8');
  assert.match(plan, /See \[Child\]\(Plan\/Child\.md\) and !\[diagram\]\(\.\.\/\.\.\/Assets\/[0-9a-f-]+\/diagram\.png\)\./);
  assert.match(plan, /\[site\]\(https:\/\/www\.notion\.so\/x\)/);
  const child = await fs.readFile(path.join(base, 'Plan', 'Child.md'), 'utf8');
  assert.match(child, /Back to \[Plan\]\(\.\.\/Plan\.md#goals\)\./);
  const tasks = await fs.readFile(path.join(base, 'Tasks.md'), 'utf8');
  assert.match(tasks, /# Tasks\n\n\| Name \| Status \|\n\| --- \| --- \|\n\| Write, then edit \| Done \|\n\| Ship \| To do \|/);
}

test('a Notion export imports from a folder', async (t) => {
  const library = await fixture(t);
  const exportDir = await fixture(t);
  for (const file of notionFiles()) {
    const full = path.join(exportDir, file.name);
    await fs.mkdir(path.dirname(full), { recursive: true });
    await fs.writeFile(full, file.data);
  }
  await checkNotionImport(library, await runImport({ kind: 'notion', source: exportDir, root: library, date: '2026-10-15' }));
});

test('a Notion export imports from a zip of zips', async (t) => {
  const library = await fixture(t);
  const inner = makeZip(notionFiles().map((file) => ({ ...file, deflate: true })));
  const outer = path.join(await fixture(t), 'Export.zip');
  await fs.writeFile(outer, makeZip([{ name: 'Export-1a2b3c4d-Part-1.zip', data: inner }]));
  await checkNotionImport(library, await runImport({ kind: 'notion', source: outer, root: library, date: '2026-10-15' }));
});

test('Notion helpers strip IDs and build tables', () => {
  assert.equal(stripNotionId('Plan ' + ID1), 'Plan');
  assert.equal(stripNotionId('Plain name'), 'Plain name');
  assert.equal(csvToMarkdownTable('a,b\n"x|y","line\nbreak"\n'), '| a | b |\n| --- | --- |\n| x\\|y | line<br>break |');
});

test('unsupported sources fail clearly', async (t) => {
  const library = await fixture(t);
  await assert.rejects(runImport({ kind: 'onenote', source: 'x', root: library }), /Unknown import source/);
  if (process.platform !== 'darwin') {
    await assert.rejects(runImport({ kind: 'apple-notes', root: library }), /needs macOS/);
  }
});
