import { tags } from '@lezer/highlight';

const DOLLAR = 36;
const BACKSLASH = 92;
const NEWLINE = 10;
const SPACE = 32;
const TAB = 9;

// "$1,200" and "$5 - $10" are money, not math. Require the delimited content to
// carry at least one character that a formula would actually use.
const LOOKS_LIKE_MONEY = /^[\d.,\s+\-]*$/;

/**
 * Adds LaTeX math to the Markdown parser: `$inline$` and `$$block$$`.
 * The marks are separate nodes so the live-preview layer can hide them.
 */
export const MathExtension = {
  defineNodes: [
    { name: 'InlineMath', style: tags.special(tags.monospace) },
    { name: 'BlockMath', block: true },
    { name: 'MathMark', style: tags.processingInstruction },
  ],

  parseBlock: [
    {
      name: 'BlockMath',
      before: 'FencedCode',
      parse(cx, line) {
        if (line.next !== DOLLAR || line.text.charCodeAt(line.pos + 1) !== DOLLAR) return false;

        const from = cx.lineStart + line.pos;
        const marks = [cx.elt('MathMark', from, from + 2)];

        // A one-liner such as `$$ x^2 $$`.
        const sameLine = line.text.indexOf('$$', line.pos + 2);
        if (sameLine > -1) {
          const closeFrom = cx.lineStart + sameLine;
          marks.push(cx.elt('MathMark', closeFrom, closeFrom + 2));
          const to = closeFrom + 2;
          cx.nextLine();
          cx.addElement(cx.elt('BlockMath', from, to, marks));
          return true;
        }

        while (cx.nextLine()) {
          const close = line.text.indexOf('$$');
          if (close > -1) {
            const closeFrom = cx.lineStart + close;
            marks.push(cx.elt('MathMark', closeFrom, closeFrom + 2));
            cx.nextLine();
            break;
          }
        }

        cx.addElement(cx.elt('BlockMath', from, cx.prevLineEnd(), marks));
        return true;
      },
    },
  ],

  parseInline: [
    {
      name: 'InlineMath',
      before: 'Emphasis',
      parse(cx, next, pos) {
        if (next !== DOLLAR) return -1;
        // `$$` at this point belongs to a block, not an inline span.
        if (cx.char(pos + 1) === DOLLAR) return -1;

        const after = cx.char(pos + 1);
        if (after === -1 || after === SPACE || after === TAB || after === NEWLINE) return -1;

        for (let i = pos + 1; i < cx.end; i++) {
          const ch = cx.char(i);
          if (ch === BACKSLASH) { i++; continue; }
          if (ch === NEWLINE) return -1;
          if (ch !== DOLLAR) continue;

          const before = cx.char(i - 1);
          if (before === SPACE || before === TAB) return -1;
          if (i === pos + 1) return -1;

          const body = cx.slice(pos + 1, i);
          if (LOOKS_LIKE_MONEY.test(body)) return -1;

          return cx.addElement(cx.elt('InlineMath', pos, i + 1, [
            cx.elt('MathMark', pos, pos + 1),
            cx.elt('MathMark', i, i + 1),
          ]));
        }
        return -1;
      },
    },
  ],
};

/**
 * YAML front matter at the very top of a document.
 *
 * Without this the closing `---` turns the first key into a setext heading,
 * which is how metadata ends up rendered as a title. The peek-ahead guard
 * means a lone `---` typed at the top of a draft stays a horizontal rule
 * instead of swallowing the rest of the document as you type.
 */
const YAML_KEY = /^\s*(?:[A-Za-z_][\w.-]*\s*:|#|-\s|---\s*$)/;

export const FrontMatterExtension = {
  defineNodes: [
    { name: 'FrontMatter', block: true },
    { name: 'FrontMatterMark', style: tags.processingInstruction },
  ],
  parseBlock: [
    {
      name: 'FrontMatter',
      before: 'HorizontalRule',
      parse(cx, line) {
        if (cx.lineStart !== 0) return false;
        if (!/^---\s*$/.test(line.text)) return false;
        if (!YAML_KEY.test(cx.peekLine())) return false;

        const from = cx.lineStart;
        const marks = [cx.elt('FrontMatterMark', from, from + 3)];

        while (cx.nextLine()) {
          if (/^(---|\.\.\.)\s*$/.test(line.text)) {
            marks.push(cx.elt('FrontMatterMark', cx.lineStart, cx.lineStart + 3));
            cx.nextLine();
            break;
          }
        }

        cx.addElement(cx.elt('FrontMatter', from, cx.prevLineEnd(), marks));
        return true;
      },
    },
  ],
};

/**
 * `[[wiki-links]]`, with an optional display alias: `[[target|shown as this]]`.
 *
 * Registered before `Link` so that `[[x]]` is not first swallowed as a link
 * reference by the standard parser.
 */
const BRACKET_OPEN = 91;   // [
const BRACKET_CLOSE = 93;  // ]
const PIPE = 124;

export const WikiLinkExtension = {
  defineNodes: [
    { name: 'WikiLink', style: tags.link },
    { name: 'WikiLinkMark', style: tags.processingInstruction },
    { name: 'WikiLinkTarget', style: tags.link },
    { name: 'WikiLinkAlias', style: tags.link },
  ],
  parseInline: [
    {
      name: 'WikiLink',
      before: 'Link',
      parse(cx, next, pos) {
        if (next !== BRACKET_OPEN || cx.char(pos + 1) !== BRACKET_OPEN) return -1;

        let end = -1;
        for (let i = pos + 2; i < cx.end - 1; i++) {
          const ch = cx.char(i);
          if (ch === NEWLINE) return -1;
          if (ch === BRACKET_CLOSE && cx.char(i + 1) === BRACKET_CLOSE) { end = i; break; }
        }
        if (end < 0 || end === pos + 2) return -1;

        const body = cx.slice(pos + 2, end);
        // A pipe splits target from the text actually displayed.
        const bar = body.indexOf('|');
        const children = [cx.elt('WikiLinkMark', pos, pos + 2)];

        if (bar > -1) {
          const barPos = pos + 2 + bar;
          children.push(cx.elt('WikiLinkTarget', pos + 2, barPos));
          children.push(cx.elt('WikiLinkMark', barPos, barPos + 1));
          if (barPos + 1 < end) children.push(cx.elt('WikiLinkAlias', barPos + 1, end));
        } else {
          children.push(cx.elt('WikiLinkTarget', pos + 2, end));
        }

        children.push(cx.elt('WikiLinkMark', end, end + 2));
        return cx.addElement(cx.elt('WikiLink', pos, end + 2, children));
      },
    },
  ],
};

/**
 * `==highlight==`, which Typora supports and GFM does not.
 */
export const HighlightExtension = {
  defineNodes: [
    { name: 'Highlight', style: tags.special(tags.emphasis) },
    { name: 'HighlightMark', style: tags.processingInstruction },
  ],
  parseInline: [
    {
      name: 'Highlight',
      before: 'Emphasis',
      parse(cx, next, pos) {
        if (next !== 61 /* = */ || cx.char(pos + 1) !== 61) return -1;
        for (let i = pos + 2; i < cx.end - 1; i++) {
          if (cx.char(i) === NEWLINE) return -1;
          if (cx.char(i) === 61 && cx.char(i + 1) === 61) {
            if (i === pos + 2) return -1;
            return cx.addElement(cx.elt('Highlight', pos, i + 2, [
              cx.elt('HighlightMark', pos, pos + 2),
              cx.elt('HighlightMark', i, i + 2),
            ]));
          }
        }
        return -1;
      },
    },
  ],
};
