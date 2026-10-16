import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeStyle, applyTemplate } from '../src/renderer/editor/writingTools.mjs';

test('style diagnostics point at the exact repeated words and phrase offsets', () => {
  const text = 'We really need to to finish this in order to ship.';
  const diagnostics = analyzeStyle(text);
  assert.deepEqual(diagnostics.map(({ kind, from, to }) => ({ kind, from, to })), [
    { kind: 'wordiness', from: 3, to: 14 },
    { kind: 'repeated-word', from: 15, to: 20 },
    { kind: 'wordiness', from: 33, to: 44 },
  ]);
  for (const diagnostic of diagnostics) {
    assert.ok(text.slice(diagnostic.from, diagnostic.to).length > 0);
  }
});

test('front matter, fenced and inline code, and raw HTML are ignored', () => {
  const text = [
    '---',
    'title: really really',
    '---',
    'Normal text.',
    '```js',
    'really really in order to',
    '```',
    'Use `really really` as a literal.',
    '<script>really really in order to</script>',
  ].join('\n');
  assert.deepEqual(analyzeStyle(text), []);
});

test('wordiness rules do not flag ordinary prose or code-like identifiers', () => {
  assert.deepEqual(analyzeStyle('The quick brown fox writes markdown_parser values.'), []);
});

test('template interpolation uses local calendar fields and leaves unknown tokens alone', () => {
  const date = new Date(2025, 0, 2, 3, 4, 59);
  const input = '{{title}}\n{{date}} {{time}}\n{{selection}} {{unknown}}';
  const result = applyTemplate(input, {
    title: 'Plan {{date}}',
    selection: 'A $& quote',
    now: date,
  });
  assert.equal(result, 'Plan {{date}}\n2025-01-02 03:04\nA $& quote {{unknown}}');
  assert.equal(input, '{{title}}\n{{date}} {{time}}\n{{selection}} {{unknown}}');
});

test('template replacement supports omitted values without interpreting replacement metacharacters', () => {
  assert.equal(applyTemplate('{{title}}|{{selection}}', { title: '$&', selection: '$`' }), '$&|$`');
});
