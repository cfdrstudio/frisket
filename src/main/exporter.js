'use strict';
const { app, dialog, BrowserWindow, shell } = require('electron');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const store = require('./store');

const TMP = path.join(os.tmpdir(), 'frisket-export');

/**
 * Locate Pandoc.
 *
 * Pandoc is GPL-licensed, so it is deliberately not bundled with this
 * application — shipping it inside a proprietary installer would drag the
 * whole distribution into GPL source-offer obligations. Instead we find a copy
 * the user has installed, in this order: an explicit path they set in
 * preferences, the usual install locations, then PATH.
 */
let cachedPandoc;

const IS_MAC = process.platform === 'darwin';
const IS_WINDOWS = process.platform === 'win32';
const PANDOC_BIN = IS_WINDOWS ? 'pandoc.exe' : 'pandoc';

/**
 * Where Pandoc actually lands, per platform.
 *
 * These matter most on macOS: a bundled .app is launched by Finder rather than
 * a login shell, so `process.env.PATH` is the bare system default and contains
 * neither Homebrew directory. Searching PATH alone would fail for nearly every
 * Mac user who has Pandoc installed.
 */
function commonInstallPaths() {
  if (IS_WINDOWS) {
    const roots = [
      process.env['ProgramFiles'],
      process.env['ProgramFiles(x86)'],
      process.env.LOCALAPPDATA,
      process.env.APPDATA,
    ].filter(Boolean);
    const out = [];
    for (const root of roots) {
      out.push(path.join(root, 'Pandoc', PANDOC_BIN));
      out.push(path.join(root, 'Programs', 'Pandoc', PANDOC_BIN));
    }
    return out;
  }

  const home = os.homedir();
  const dirs = [
    '/opt/homebrew/bin',      // Homebrew on Apple Silicon
    '/usr/local/bin',         // Homebrew on Intel, and the official installer
    '/opt/local/bin',         // MacPorts
    '/usr/bin',
    '/bin',
    path.join(home, '.local', 'bin'),
    path.join(home, 'bin'),
  ];
  if (IS_MAC) {
    // The .pkg from pandoc.org installs here.
    dirs.push('/Applications/pandoc/bin');
  }
  return dirs.map((dir) => path.join(dir, PANDOC_BIN));
}

function pandocPath(configured) {
  const explicit = configured || store.read().pandocPath;
  if (explicit) {
    try { if (fs.existsSync(explicit)) return explicit; } catch { /* fall through */ }
  }
  if (cachedPandoc !== undefined) return cachedPandoc;

  const onPath = (process.env.PATH || '').split(path.delimiter)
    .filter(Boolean)
    .map((dir) => path.join(dir, PANDOC_BIN));

  for (const candidate of [...commonInstallPaths(), ...onPath]) {
    try { if (fs.existsSync(candidate)) { cachedPandoc = candidate; return candidate; } } catch { /* keep looking */ }
  }
  cachedPandoc = null;
  return null;
}

/** Called after the user points us at a copy manually. */
function forgetPandoc() {
  cachedPandoc = undefined;
}

const FORMATS = {
  docx: { ext: 'docx', to: 'docx', name: 'Word Document' },
  odt: { ext: 'odt', to: 'odt', name: 'OpenDocument Text' },
  rtf: { ext: 'rtf', to: 'rtf', name: 'Rich Text Format', standalone: true },
  epub: { ext: 'epub', to: 'epub3', name: 'EPUB eBook' },
  latex: { ext: 'tex', to: 'latex', name: 'LaTeX Source' },
  rst: { ext: 'rst', to: 'rst', name: 'reStructuredText' },
  textile: { ext: 'textile', to: 'textile', name: 'Textile' },
  mediawiki: { ext: 'wiki', to: 'mediawiki', name: 'MediaWiki Markup' },
};

const PANDOC_FROM = [
  'markdown',
  'tex_math_dollars',
  'tex_math_single_backslash',
  'backtick_code_blocks',
  'fenced_code_attributes',
  'pipe_tables',
  'task_lists',
  'strikeout',
  'footnotes',
  'definition_lists',
  'superscript',
  'subscript',
  'yaml_metadata_block',
  'raw_html',
  'autolink_bare_uris',
  'implicit_figures',
].join('+');

/** Ask for a destination; returns null when the user backs out. */
async function pickPath(parent, options) {
  const { canceled, filePath } = await dialog.showSaveDialog(parent, options);
  return canceled ? null : filePath;
}

async function ensureTmp() {
  await fsp.mkdir(TMP, { recursive: true });
  return TMP;
}

function suggestedName(opts, ext) {
  const base = opts?.docPath
    ? path.basename(opts.docPath, path.extname(opts.docPath))
    : (opts?.title || 'Untitled');
  const dir = opts?.docPath ? path.dirname(opts.docPath) : app.getPath('documents');
  return path.join(dir, base + '.' + ext);
}

function insideDirectory(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep));
}

/** Copy local Markdown-linked files into a collision-safe sidecar export folder. */
async function copyMarkdownAssets(markdown, sourceDocument, outputDocument, libraryRoot) {
  if (!sourceDocument) return { markdown, copied: 0, skipped: [] };
  const sourceDir = path.dirname(sourceDocument);
  const outputDir = path.dirname(outputDocument);
  const allowedRoot = libraryRoot && insideDirectory(libraryRoot, sourceDir) ? libraryRoot : sourceDir;
  let allowedRealRoot;
  try { allowedRealRoot = await fsp.realpath(allowedRoot); }
  catch { return { markdown, copied: 0, skipped: [] }; }
  const normalizeReference = (reference) => {
    let decoded = reference;
    try { decoded = decodeURIComponent(reference); } catch { /* keep original */ }
    return decoded.split(/[?#]/, 1)[0];
  };
  const references = new Set();
  const matcher = /!?\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))/g;
  let match;
  while ((match = matcher.exec(markdown))) {
    const reference = (match[1] || match[2] || '').trim();
    if (!reference || /^(?:[a-z][a-z0-9+.-]*:|\/\/|data:|#)/i.test(reference)) continue;
    const clean = normalizeReference(reference);
    if (clean) references.add(clean);
  }
  const mappings = new Map();
  const reservedNames = new Set();
  let assetDir = null;
  let copied = 0;
  const skipped = [];

  async function ensureAssetDir() {
    if (assetDir) return assetDir;
    const stem = path.basename(outputDocument, path.extname(outputDocument)).replace(/[^a-z0-9._-]+/gi, '-') || 'export';
    for (let suffix = 0; suffix < 1000; suffix++) {
      const candidate = path.join(outputDir, stem + '-assets' + (suffix ? '-' + suffix : ''));
      try { await fsp.mkdir(candidate); assetDir = candidate; return candidate; }
      catch (err) { if (err.code !== 'EEXIST') throw err; }
    }
    throw new Error('Could not create a collision-safe asset export folder.');
  }

  for (const reference of references) {
    let source;
    try { source = await fsp.realpath(path.resolve(sourceDir, reference)); }
    catch { skipped.push(reference); continue; }
    if (!insideDirectory(allowedRealRoot, source)) {
      skipped.push(reference);
      continue;
    }
    try {
      const stat = await fsp.stat(source);
      if (!stat.isFile()) { skipped.push(reference); continue; }
      const directory = await ensureAssetDir();
      const parsed = path.parse(source);
      const stem = parsed.name.replace(/[^a-z0-9._-]+/gi, '-').replace(/^-+|-+$/g, '') || 'attachment';
      let target;
      for (let suffix = 0; suffix < 1000; suffix++) {
        const name = stem + (suffix ? '-' + suffix : '') + parsed.ext;
        if (reservedNames.has(name)) continue;
        target = path.join(directory, name);
        try { await fsp.access(target); } catch { reservedNames.add(name); break; }
      }
      if (!target) throw new Error('Could not create a unique asset name.');
      await fsp.copyFile(source, target, fs.constants.COPYFILE_EXCL);
      mappings.set(reference, path.relative(outputDir, target).split(path.sep).join('/'));
      copied++;
    } catch { skipped.push(reference); }
  }
  const rewritten = markdown.replace(/(!?\[[^\]]*\]\(\s*)(?:<([^>]+)>|([^\s)]+))/g,
    (whole, prefix, bracketed, plain) => {
      const reference = (bracketed || plain || '').trim();
      const mapped = mappings.get(normalizeReference(reference));
      if (!mapped) return whole;
      return prefix + (bracketed !== undefined ? '<' + mapped + '>' : mapped);
    });
  return { markdown: rewritten, copied, skipped };
}

// ---------------------------------------------------------------------------
// PDF — rendered by Chromium in an offscreen window, so it matches the theme.
// ---------------------------------------------------------------------------
async function toPdf(event, html, opts = {}) {
  const parent = BrowserWindow.fromWebContents(event.sender);
  const filePath = opts.outputPath || await pickPath(parent, {
    title: 'Export to PDF',
    defaultPath: suggestedName(opts, 'pdf'),
    filters: [{ name: 'PDF Document', extensions: ['pdf'] }],
  });
  if (!filePath) return { canceled: true };

  await ensureTmp();
  const tmpHtml = path.join(TMP, 'print-' + Date.now() + '.html');
  await fsp.writeFile(tmpHtml, html, 'utf8');

  const printer = new BrowserWindow({
    show: false,
    webPreferences: { offscreen: true, javascript: true, sandbox: true },
  });

  try {
    await printer.loadURL(pathToFileURL(tmpHtml).href);
    // Give webfonts, KaTeX and Mermaid SVG a moment to settle before capture.
    await printer.webContents.executeJavaScript(
      'new Promise(r => { if (document.fonts && document.fonts.ready) '
      + 'document.fonts.ready.then(() => setTimeout(r, 250)); else setTimeout(r, 400); })',
    ).catch(() => {});

    const margin = Number.isFinite(opts.margin) ? opts.margin : 0.6;
    const data = await printer.webContents.printToPDF({
      printBackground: true,
      pageSize: opts.pageSize || 'A4',
      landscape: !!opts.landscape,
      margins: { top: margin, bottom: margin, left: margin, right: margin },
      preferCSSPageSize: false,
      generateDocumentOutline: opts.outline !== false,
      generateTaggedPDF: true,
      displayHeaderFooter: !!opts.headerFooter,
      headerTemplate: '<div style="font-size:8px;width:100%;padding:0 12mm;color:#888;">'
        + '<span class="title"></span></div>',
      footerTemplate: '<div style="font-size:8px;width:100%;padding:0 12mm;color:#888;text-align:center;">'
        + '<span class="pageNumber"></span> / <span class="totalPages"></span></div>',
    });
    await fsp.writeFile(filePath, data);
    return { ok: true, path: filePath };
  } catch (err) {
    return { error: err.message };
  } finally {
    if (!printer.isDestroyed()) printer.destroy();
    fsp.rm(tmpHtml, { force: true }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// HTML — the renderer hands us a fully self-contained document.
// ---------------------------------------------------------------------------
async function toHtml(event, html, opts = {}) {
  const parent = BrowserWindow.fromWebContents(event.sender);
  const filePath = opts.outputPath || await pickPath(parent, {
    title: 'Export to HTML',
    defaultPath: suggestedName(opts, 'html'),
    filters: [{ name: 'HTML Document', extensions: ['html', 'htm'] }],
  });
  if (!filePath) return { canceled: true };
  try {
    await fsp.writeFile(filePath, html, 'utf8');
    return { ok: true, path: filePath };
  } catch (err) {
    return { error: err.message };
  }
}

// ---------------------------------------------------------------------------
// Plain text — flattened by the renderer, saved here.
// ---------------------------------------------------------------------------
async function toText(event, text, opts = {}) {
  const parent = BrowserWindow.fromWebContents(event.sender);
  const filePath = opts.outputPath || await pickPath(parent, {
    title: 'Export to Plain Text',
    defaultPath: suggestedName(opts, 'txt'),
    filters: [{ name: 'Plain Text', extensions: ['txt'] }],
  });
  if (!filePath) return { canceled: true };
  try {
    await fsp.writeFile(filePath, text, 'utf8');
    return { ok: true, path: filePath };
  } catch (err) {
    return { error: err.message };
  }
}

/** Save portable Markdown. Asset references remain relative to the document. */
async function toMarkdown(event, markdown, opts = {}) {
  const parent = BrowserWindow.fromWebContents(event.sender);
  const filePath = opts.outputPath || await pickPath(parent, {
    title: 'Export to Markdown',
    defaultPath: suggestedName(opts, 'md'),
    filters: [{ name: 'Markdown', extensions: ['md', 'markdown'] }],
  });
  if (!filePath) return { canceled: true };
  try {
    const assets = await copyMarkdownAssets(markdown, opts.docPath, filePath, opts.libraryRoot);
    await fsp.writeFile(filePath, assets.markdown, 'utf8');
    return { ok: true, path: filePath, ...assets };
  } catch (err) { return { error: err.message }; }
}

/** Raster snapshots of an exported document; long documents become numbered JPEGs. */
async function toJpg(event, html, opts = {}) {
  const parent = BrowserWindow.fromWebContents(event.sender);
  const filePath = opts.outputPath || await pickPath(parent, {
    title: 'Export to JPEG',
    defaultPath: suggestedName(opts, 'jpg'),
    filters: [{ name: 'JPEG Image', extensions: ['jpg', 'jpeg'] }],
  });
  if (!filePath) return { canceled: true };
  await ensureTmp();
  const tmpHtml = path.join(TMP, 'image-' + Date.now() + '.html');
  const renderer = new BrowserWindow({ show: false, width: 1200, height: 900, webPreferences: { offscreen: true, sandbox: true } });
  try {
    await fsp.writeFile(tmpHtml, html, 'utf8');
    await renderer.loadURL(pathToFileURL(tmpHtml).href);
    const size = await renderer.webContents.executeJavaScript('({ width: Math.max(document.documentElement.scrollWidth, 1), height: Math.max(document.documentElement.scrollHeight, 1) })');
    const width = Math.min(4096, Math.max(640, Math.ceil(size.width)));
    const pageHeight = 16384;
    const totalHeight = Math.max(480, Math.ceil(size.height));
    renderer.setContentSize(width, Math.min(pageHeight, totalHeight));
    await new Promise((resolve) => setTimeout(resolve, 100));
    const pages = Math.ceil(totalHeight / pageHeight);
    const parsed = path.parse(filePath);
    const paths = [];
    for (let page = 0; page < pages; page++) {
      const height = Math.min(pageHeight, totalHeight - page * pageHeight);
      const output = pages === 1 ? filePath : path.join(parsed.dir, parsed.name + '-' + (page + 1) + parsed.ext);
      const image = await renderer.webContents.capturePage({ x: 0, y: page * pageHeight, width, height });
      await fsp.writeFile(output, image.toJPEG(88));
      paths.push(output);
    }
    return { ok: true, path: paths[0], paths };
  } catch (err) { return { error: err.message }; }
  finally {
    if (!renderer.isDestroyed()) renderer.destroy();
    fsp.rm(tmpHtml, { force: true }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Everything else goes through Pandoc.
// ---------------------------------------------------------------------------
function runPandoc(bin, args, cwd) {
  return new Promise((resolve) => {
    execFile(bin, args, { cwd, windowsHide: true, maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) resolve({ error: (stderr || err.message || '').trim() || 'Pandoc failed' });
      else resolve({ ok: true, stderr });
    });
  });
}

async function viaPandoc(event, markdown, format, opts = {}) {
  const spec = FORMATS[format];
  if (!spec) return { error: 'Unsupported export format: ' + format };

  let bin = pandocPath();
  const parent = BrowserWindow.fromWebContents(event.sender);
  if (!bin) {
    const { response } = await dialog.showMessageBox(parent, {
      type: 'info',
      title: 'Pandoc Required',
      message: 'Exporting to ' + spec.name + ' needs Pandoc.',
      detail: 'Pandoc is a free, open-source document converter. Install it once and '
        + 'this export will work from then on — it is found automatically.\n\n'
        + 'If you already have it somewhere unusual, you can point to it directly.',
      buttons: ['Download Pandoc', 'Locate ' + PANDOC_BIN + '…', 'Cancel'],
      defaultId: 0,
      cancelId: 2,
    });

    if (response === 0) {
      shell.openExternal('https://pandoc.org/installing.html');
      return { canceled: true };
    }
    if (response === 1) {
      const picked = await dialog.showOpenDialog(parent, {
        title: 'Locate ' + PANDOC_BIN,
        properties: ['openFile'],
        filters: IS_WINDOWS ? [{ name: 'Pandoc', extensions: ['exe'] }] : [],
        defaultPath: IS_WINDOWS ? undefined : '/usr/local/bin',
      });
      if (picked.canceled || !picked.filePaths[0]) return { canceled: true };
      bin = picked.filePaths[0];
      forgetPandoc();
      store.write({ pandocPath: bin });
    } else {
      return { canceled: true };
    }
  }

  const filePath = opts.outputPath || await pickPath(parent, {
    title: 'Export to ' + spec.name,
    defaultPath: suggestedName(opts, spec.ext),
    filters: [{ name: spec.name, extensions: [spec.ext] }],
  });
  if (!filePath) return { canceled: true };

  await ensureTmp();
  const docDir = opts.docPath ? path.dirname(opts.docPath) : app.getPath('documents');
  const tmpMd = path.join(TMP, 'source-' + Date.now() + '.md');
  await fsp.writeFile(tmpMd, markdown, 'utf8');

  const args = [
    tmpMd,
    '--from=' + PANDOC_FROM,
    '--to=' + spec.to,
    '--output=' + filePath,
    '--resource-path=' + docDir,
    '--wrap=preserve',
  ];
  if (spec.to !== 'docx' && spec.to !== 'odt') args.push('--standalone');
  if (spec.to === 'epub3' || spec.to === 'docx') args.push('--mathml');
  if (opts.toc) args.push('--toc', '--toc-depth=3');
  if (opts.title) args.push('--metadata=title:' + opts.title);
  if (spec.to === 'latex' && opts.pdfEngineArgs) args.push(...opts.pdfEngineArgs);

  const result = await runPandoc(bin, args, docDir);
  fsp.rm(tmpMd, { force: true }).catch(() => {});
  if (result.error) return { error: result.error };
  return { ok: true, path: filePath };
}

module.exports = { toPdf, toHtml, toText, toMarkdown, toJpg, viaPandoc, pandocPath, forgetPandoc, FORMATS };
