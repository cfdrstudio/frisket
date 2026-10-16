import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildTitlePageHtml,
  buildTocHtml,
  headingSlug,
  normalizePresentation,
  presentationLayoutCss,
} from '../src/renderer/exportDoc.js';

test('presentation settings are constrained and normalize optional text', () => {
  assert.deepEqual(normalizePresentation({
    preset: 'report', titlePage: true, toc: 1, author: '  Ada  ', subtitle: null,
  }), {
    preset: 'report', titlePage: true, toc: false, author: 'Ada', subtitle: '',
  });
  assert.deepEqual(normalizePresentation({ preset: 'untrusted', titlePage: 'yes' }), {
    preset: 'standard', titlePage: false, toc: false, author: '', subtitle: '',
  });
});

test('heading IDs are readable for accented and punctuation-only headings', () => {
  assert.equal(headingSlug('Crème brûlée: Plan & Notes'), 'creme-brulee-plan-notes');
  assert.equal(headingSlug('🚀'), 'section');
});

test('TOC escapes visible text and encodes fragments while preserving heading levels', () => {
  const html = buildTocHtml([
    { tagName: 'H1', id: 'a section', textContent: 'Research <plan>' },
    { tagName: 'H3', id: 'a&b', textContent: 'Budget & timeline' },
  ]);
  assert.match(html, /href="#a%20section">Research &lt;plan&gt;/);
  assert.match(html, /href="#a%26b">Budget &amp; timeline/);
  assert.match(html, /export-toc-level-1/);
  assert.match(html, /export-toc-level-3/);
});

test('title page escapes all user supplied text', () => {
  const html = buildTitlePageHtml('<Plan>', normalizePresentation({
    subtitle: 'A & B', author: '"Writer"',
  }));
  assert.match(html, /&lt;Plan&gt;/);
  assert.match(html, /A &amp; B/);
  assert.match(html, /&quot;Writer&quot;/);
  assert.doesNotMatch(html, /<Plan>|A & B/);
});

test('each preset emits its own styling and export layout enables print page breaks', () => {
  const options = { mode: 'pdf', pageSize: 'A4', margin: 0.6, contentWidth: 780 };
  const standard = presentationLayoutCss(options, normalizePresentation({}));
  const manuscript = presentationLayoutCss(options, normalizePresentation({ preset: 'manuscript', titlePage: true, toc: true }));
  const report = presentationLayoutCss(options, normalizePresentation({ preset: 'report' }));
  assert.match(standard, /@page \{ size: A4; margin: 0\.6in; \}/);
  assert.match(manuscript, /Georgia/);
  assert.match(manuscript, /page-break-after: always/);
  assert.match(report, /border-bottom: 2px solid/);
});
