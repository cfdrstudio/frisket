import { renderMarkdown, inferTitle, setMathOutput, escapeHtml } from './markdown.js';
import { renderMermaid } from './editor/widgets.js';

const assetCache = new Map();

async function asset(name) {
  if (!assetCache.has(name)) assetCache.set(name, await window.frisket.readAsset(name));
  return assetCache.get(name);
}

/** Turn `mermaid` fences into inline SVG so exports do not need a renderer. */
async function renderDiagrams(root) {
  const nodes = [...root.querySelectorAll('.mermaid-source')];
  await Promise.all(nodes.map(async (node) => {
    const source = node.textContent || '';
    try {
      const svg = await renderMermaid(source);
      const holder = document.createElement('div');
      holder.className = 'mermaid-rendered';
      holder.innerHTML = svg;
      // The wrapping <pre> is markdown-it's, not ours; replace the whole thing.
      const target = node.closest('pre') || node;
      target.replaceWith(holder);
    } catch (err) {
      node.textContent = 'Diagram error: ' + (err && err.message ? err.message : err);
    }
  }));
}

/** Rewrite every image to something that survives leaving this machine. */
async function resolveImages(root, docPath, embed) {
  const images = [...root.querySelectorAll('img')];
  await Promise.all(images.map(async (img) => {
    const src = img.getAttribute('src');
    if (!src) return;
    const resolved = embed
      ? await window.frisket.imageDataUri(src, docPath)
      : await window.frisket.resolveImage(src, docPath);
    if (resolved) img.setAttribute('src', resolved);
  }));
}

function pageCss(pageSize, margin) {
  return '@page { size: ' + pageSize + '; margin: ' + margin + 'in; }\n'
    + 'body { margin: 0; }\n'
    + '.md-render { max-width: none; padding: 0; }\n'
    + '.md-render h1, .md-render h2, .md-render h3 { break-after: avoid; page-break-after: avoid; }\n'
    + '.md-render pre, .md-render table, .md-render blockquote, .md-render figure,'
    + ' .md-render .mermaid-rendered { break-inside: avoid; page-break-inside: avoid; }\n'
    + '.md-render img { break-inside: avoid; }\n';
}

const PRESENTATION_PRESETS = new Set(['standard', 'manuscript', 'report']);

/** Keep option values predictable at the IPC/UI boundary. */
export function normalizePresentation(presentation) {
  const value = presentation && typeof presentation === 'object' ? presentation : {};
  return {
    preset: PRESENTATION_PRESETS.has(value.preset) ? value.preset : 'standard',
    titlePage: value.titlePage === true,
    toc: value.toc === true,
    author: typeof value.author === 'string' ? value.author.trim() : '',
    subtitle: typeof value.subtitle === 'string' ? value.subtitle.trim() : '',
  };
}

/** Produce readable, stable IDs from heading text (duplicates are disambiguated later). */
export function headingSlug(text) {
  const slug = String(text || '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return slug || 'section';
}

function assignUniqueHeadingIds(root) {
  const headings = [...root.querySelectorAll('h1, h2, h3')];
  const headingSet = new Set(headings);
  const used = new Set([...root.querySelectorAll('[id]')]
    .filter((node) => !headingSet.has(node))
    .map((node) => node.id));

  for (const heading of headings) {
    const base = headingSlug(heading.textContent);
    let id = heading.id || base;
    let suffix = 2;
    while (used.has(id)) id = base + '-' + suffix++;
    heading.id = id;
    used.add(id);
  }
  return headings;
}

export function buildTocHtml(headings) {
  if (!headings.length) return '';
  const rows = headings.map((heading) => {
    const level = Number(heading.tagName.slice(1));
    return '<li class="export-toc-level-' + level + '"><a href="#'
      + escapeHtml(encodeURIComponent(heading.id)) + '">'
      + escapeHtml(heading.textContent.trim()) + '</a></li>';
  }).join('');
  return '<nav class="export-toc" aria-label="Table of contents">'
    + '<h1>Contents</h1><ol>' + rows + '</ol></nav>';
}

function presentationCss(preset, mode) {
  if (preset === 'manuscript') {
    return '.md-render { font-family: Georgia, "Times New Roman", serif; line-height: 1.8; max-width: 7in; }\n'
      + '.md-render p { text-indent: 1.25em; margin: 0 0 0.35em; }\n'
      + '.md-render h1, .md-render h2, .md-render h3 { font-family: Georgia, "Times New Roman", serif; }\n'
      + (mode === 'pdf' ? '.md-render { font-size: 12pt !important; }\n' : '');
  }
  if (preset === 'report') {
    return '.md-render { max-width: 8in; line-height: 1.62; }\n'
      + '.md-render h1 { padding-bottom: .25em; border-bottom: 2px solid var(--line); }\n'
      + '.md-render h2 { padding-bottom: .15em; border-bottom: 1px solid var(--line); }\n'
      + '.md-render table { width: 100%; }\n';
  }
  return '';
}

export function buildTitlePageHtml(title, presentation) {
  return '<section class="export-title-page" aria-label="Title page">'
    + '<div class="export-title-content"><h1>' + escapeHtml(title) + '</h1>'
    + (presentation.subtitle ? '<p class="export-subtitle">' + escapeHtml(presentation.subtitle) + '</p>' : '')
    + (presentation.author ? '<p class="export-author">' + escapeHtml(presentation.author) + '</p>' : '')
    + '</div></section>';
}

export function presentationLayoutCss({ mode, pageSize, margin, contentWidth }, presentation) {
  const base = mode === 'pdf'
    ? pageCss(pageSize, margin)
    : 'body { margin: 0; padding: 48px 24px 72px; background: var(--bg); }\n'
      + '.md-render { max-width: ' + contentWidth + 'px; margin: 0 auto; }\n';
  return base + presentationCss(presentation.preset, mode)
    + '.export-title-page { min-height: ' + (mode === 'pdf' ? '9in' : 'calc(100vh - 120px)')
    + '; display: flex; align-items: center; justify-content: center; text-align: center; break-after: page; page-break-after: always; }\n'
    + '.export-title-content { max-width: 7in; }\n'
    + '.export-title-page h1 { font-size: 2.6em; line-height: 1.15; border: 0; }\n'
    + '.export-subtitle { font-size: 1.3em; opacity: .78; }\n'
    + '.export-author { margin-top: 3em; }\n'
    + '.export-toc { margin: 0 auto 3em; max-width: 8in; break-after: page; page-break-after: always; }\n'
    + '.export-toc h1 { border: 0; }\n'
    + '.export-toc ol { list-style: none; padding: 0; }\n'
    + '.export-toc li { margin: .45em 0; }\n'
    + '.export-toc-level-2 { padding-left: 1.5em; } .export-toc-level-3 { padding-left: 3em; }\n'
    + '.export-toc a { color: inherit; text-decoration: none; }\n';
}

/**
 * Build a complete standalone HTML document from Markdown.
 *
 * `mode` is 'html' for an exported file the user keeps, or 'pdf' for the
 * offscreen page Chromium prints. Both inline all styling; math is emitted as
 * MathML so no stylesheet or webfont has to travel with the file.
 */
export async function buildExportHtml({
  markdown,
  docPath,
  theme = 'frisket',
  dark = false,
  mode = 'html',
  pageSize = 'A4',
  margin = 0.6,
  embedImages = true,
  fontSize = 17,
  contentWidth = 780,
  presentation: presentationOptions,
}) {
  const previous = 'htmlAndMathml';
  setMathOutput('mathml');
  let bodyHtml;
  try {
    bodyHtml = renderMarkdown(markdown);
  } finally {
    setMathOutput(previous);
  }

  const holder = document.createElement('div');
  holder.innerHTML = bodyHtml;
  await renderDiagrams(holder);
  await resolveImages(holder, docPath, mode === 'html' ? embedImages : false);

  const title = inferTitle(markdown, docPath ? docPath.split(/[\\/]/).pop() : 'Untitled');

  // Keep the legacy export markup byte-for-byte unchanged unless the caller
  // opts into presentation controls. The UI may pass an empty object when the
  // user opens the layout dialog; that still means standard presentation.
  const hasPresentation = presentationOptions !== undefined && presentationOptions !== null;
  const presentation = normalizePresentation(presentationOptions);
  let beforeArticle = '';
  if (hasPresentation) {
    const headings = assignUniqueHeadingIds(holder);
    if (presentation.titlePage) beforeArticle += buildTitlePageHtml(title, presentation);
    if (presentation.toc) beforeArticle += buildTocHtml(headings);
  }

  const [themeCss, previewCss] = await Promise.all([
    asset('themes/' + theme + '.css'),
    asset('styles/preview.css'),
  ]);

  const layoutOptions = { mode, pageSize, margin, contentWidth };
  const layout = hasPresentation
    ? presentationLayoutCss(layoutOptions, presentation)
    : mode === 'pdf'
      ? pageCss(pageSize, margin)
      : 'body { margin: 0; padding: 48px 24px 72px; background: var(--bg); }\n'
        + '.md-render { max-width: ' + contentWidth + 'px; margin: 0 auto; }\n';

  return [
    '<!doctype html>',
    '<html lang="en"' + (dark ? ' data-dark="true"' : '') + '>',
    '<head>',
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<title>' + escapeHtml(title) + '</title>',
    '<style>',
    themeCss,
    previewCss,
    '.md-render { font-size: ' + fontSize + 'px; }',
    'html { color-scheme: ' + (dark ? 'dark' : 'light') + '; }',
    'body { color: var(--fg); background: var(--bg); }',
    'math { font-size: 1.05em; }',
    layout,
    '</style>',
    '</head>',
    '<body>',
    beforeArticle,
    '<article class="md-render">',
    holder.innerHTML,
    '</article>',
    '</body>',
    '</html>',
  ].join('\n');
}

/**
 * Flatten the document to plain text.
 *
 * Rendering to HTML first and then walking the result is more faithful than
 * stripping markers with regexes: it keeps list bullets, table cells and code
 * blocks legible, and it drops link URLs while keeping their text.
 */
export function buildPlainText(markdown) {
  const NL = String.fromCharCode(10);
  const TAB = String.fromCharCode(9);
  const NBSP = String.fromCharCode(160);

  const previous = 'htmlAndMathml';
  setMathOutput('mathml');
  let html;
  try {
    html = renderMarkdown(markdown);
  } finally {
    setMathOutput(previous);
  }

  const holder = document.createElement('div');
  holder.innerHTML = html;

  // Diagrams have no sensible text form, so keep their source instead.
  holder.querySelectorAll('.mermaid-source').forEach((node) => {
    const source = (node.textContent || '').trim();
    node.replaceWith(document.createTextNode(NL + source + NL));
  });
  // Maths is already duplicated as MathML; dropping it avoids doubled output.
  holder.querySelectorAll('math').forEach((node) => node.remove());

  holder.querySelectorAll('li').forEach((li) => {
    const marker = li.closest('ol') ? '  1. ' : '  - ';
    li.insertBefore(document.createTextNode(marker), li.firstChild);
  });
  holder.querySelectorAll('th, td').forEach((cell) => {
    cell.appendChild(document.createTextNode(TAB));
  });
  holder.querySelectorAll('hr').forEach((rule) => {
    rule.replaceWith(document.createTextNode(NL + '-'.repeat(60) + NL));
  });

  // One break after every block, and a second after the ones that want air.
  const BLOCKS = 'p, h1, h2, h3, h4, h5, h6, li, tr, pre, blockquote, figcaption';
  const AIRY = 'h1, h2, h3, h4, h5, h6, pre, blockquote, table';
  holder.querySelectorAll(BLOCKS).forEach((node) => {
    node.appendChild(document.createTextNode(NL));
  });
  holder.querySelectorAll(AIRY).forEach((node) => {
    node.appendChild(document.createTextNode(NL));
  });

  return (holder.textContent || '')
    .split(NBSP).join(' ')
    .replace(new RegExp('[ ' + TAB + ']+$', 'gm'), '')
    .replace(new RegExp(NL + '{3,}', 'g'), NL + NL)
    .trim() + NL;
}

/** Plain rendered HTML fragment, for "Copy as HTML". */
export function renderFragment(markdown) {
  return renderMarkdown(markdown);
}
