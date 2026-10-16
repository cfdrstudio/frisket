import { EditorView, Decoration, ViewPlugin } from '@codemirror/view';
import { StateEffect, StateField } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import {
  MathWidget, MermaidWidget, ImageWidget, BulletWidget,
  CheckboxWidget, RuleWidget, TableWidget, CodeLangWidget,
} from './widgets.js';
import { DIAGRAM_LANGS } from '../markdown.js';

/** The path of the document being edited, so relative images resolve. */
export const setDocPath = StateEffect.define();

export const docPathField = StateField.define({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setDocPath)) return effect.value;
    return value;
  },
});

/** Toggles raw-source mode, which switches every decoration below off. */
export const setSourceMode = StateEffect.define();

export const sourceModeField = StateField.define({
  create: () => false,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setSourceMode)) return effect.value;
    return value;
  },
});

const HEADING_RE = /^ATXHeading(\d)$/;
const SETEXT_RE = /^SetextHeading(\d)$/;
const IMAGE_ONLY_RE = /^!\[([^\]]*)\]\(\s*<?([^\s>)]*)>?(?:\s+["'(].*)?\s*\)$/;

const hidden = Decoration.replace({});

// Chromium honours spellcheck="false" on elements inside a contenteditable
// root, which is how code and metadata avoid picking up red squiggles.
const NO_SPELLCHECK = { spellcheck: 'false' };

const EMPTY = {
  deco: Decoration.none,
  atomic: Decoration.none,
  covered: [],
};

/** Shared selection helpers, built once per computation. */
function selectionProbe(state) {
  const doc = state.doc;
  const ranges = state.selection.ranges;
  const clamp = (pos) => Math.max(0, Math.min(pos, doc.length));
  return {
    doc,
    touches: (from, to) => ranges.some((r) => r.from <= to && r.to >= from),
    onLines: (from, to) => {
      const a = doc.lineAt(clamp(from)).from;
      const b = doc.lineAt(clamp(to)).to;
      return ranges.some((r) => r.from <= b && r.to >= a);
    },
  };
}

// ---------------------------------------------------------------------------
// Block level. These change the editor's vertical layout, so CodeMirror
// requires them to come from a state field rather than a view plugin — which
// means walking the whole document rather than just the viewport. The walk
// below only descends into containers that can actually hold block content.
// ---------------------------------------------------------------------------
const BLOCK_CONTAINERS = new Set([
  'Document', 'Blockquote', 'BulletList', 'OrderedList', 'ListItem',
]);

function computeBlocks(state) {
  if (state.field(sourceModeField, false)) return EMPTY;

  const { doc, onLines } = selectionProbe(state);
  const docPath = state.field(docPathField, false) || null;
  const decorations = [];
  const atomics = [];
  const covered = [];

  /** Snap a range out to whole lines, as block decorations require. */
  const blockRange = (from, to) => [
    doc.lineAt(Math.max(0, from)).from,
    doc.lineAt(Math.min(to, doc.length)).to,
  ];

  const replaceBlock = (from, to, widget) => {
    const [a, b] = blockRange(from, to);
    if (b < a) return;
    decorations.push(Decoration.replace({ widget, block: true }).range(a, b));
    atomics.push(hidden.range(a, b));
    covered.push([a, b]);
  };

  const visit = (node) => {
    const name = node.name;

    switch (name) {
      case 'BlockMath': {
        if (onLines(node.from, node.to)) return false;
        const raw = doc.sliceString(node.from, node.to);
        const body = raw.replace(/^\s*\$\$/, '').replace(/\$\$\s*$/, '');
        replaceBlock(node.from, node.to, new MathWidget(body, true));
        return true;
      }

      case 'FencedCode': {
        const info = node.node.getChild('CodeInfo');
        const lang = info ? doc.sliceString(info.from, info.to).trim().toLowerCase() : '';
        if (!DIAGRAM_LANGS.has(lang)) return false;
        if (onLines(node.from, node.to)) return false;
        const text = node.node.getChild('CodeText');
        replaceBlock(node.from, node.to, new MermaidWidget(text ? doc.sliceString(text.from, text.to) : ''));
        return true;
      }

      case 'HorizontalRule': {
        if (onLines(node.from, node.to)) return false;
        replaceBlock(node.from, node.to, new RuleWidget());
        return true;
      }

      case 'Table': {
        if (onLines(node.from, node.to)) return false;
        replaceBlock(node.from, node.to, new TableWidget(doc.sliceString(node.from, node.to)));
        return true;
      }

      case 'Paragraph': {
        // A paragraph holding nothing but an image renders as a block figure.
        const line = doc.lineAt(node.from);
        if (line.to < node.to) return false;
        const text = line.text.trim();
        if (!text.startsWith('![')) return false;
        const parsed = IMAGE_ONLY_RE.exec(text);
        if (!parsed) return false;
        if (onLines(line.from, line.to)) return false;
        replaceBlock(line.from, line.to, new ImageWidget(parsed[2], parsed[1], docPath, true));
        return true;
      }

      default:
        return false;
    }
  };

  const walk = (node) => {
    for (let child = node.firstChild; child; child = child.nextSibling) {
      const handled = visit(child);
      if (!handled && BLOCK_CONTAINERS.has(child.name)) walk(child);
    }
  };

  walk(syntaxTree(state).topNode);

  return {
    deco: Decoration.set(decorations, true),
    atomic: Decoration.set(atomics, true),
    covered,
  };
}

export const blockField = StateField.define({
  create: computeBlocks,
  update(value, tr) {
    const selectionMoved = !tr.startState.selection.eq(tr.state.selection);
    const treeChanged = syntaxTree(tr.startState) !== syntaxTree(tr.state);
    if (!tr.docChanged && !selectionMoved && !treeChanged && !tr.effects.length) return value;
    return computeBlocks(tr.state);
  },
  provide: (field) => [
    EditorView.decorations.from(field, (value) => value.deco),
    EditorView.atomicRanges.of((view) => view.state.field(field).atomic),
  ],
});

// ---------------------------------------------------------------------------
// Inline level. Viewport-limited, and free to run in a view plugin because
// nothing here replaces a line break or introduces a block widget.
// ---------------------------------------------------------------------------
class InlinePreview {
  constructor(view) {
    this.compute(view);
  }

  update(update) {
    const modeChanged = update.transactions.some((tr) =>
      tr.effects.some((e) => e.is(setSourceMode) || e.is(setDocPath)));
    const treeChanged = syntaxTree(update.startState) !== syntaxTree(update.state);
    if (update.docChanged || update.viewportChanged || update.selectionSet || modeChanged || treeChanged) {
      this.compute(update.view);
    }
  }

  compute(view) {
    const { state } = view;
    if (state.field(sourceModeField, false)) {
      this.decorations = Decoration.none;
      this.atomics = Decoration.none;
      return;
    }

    const { doc, touches, onLines } = selectionProbe(state);
    const docPath = state.field(docPathField, false) || null;
    const covered = state.field(blockField).covered;
    const inCovered = (pos) => covered.some(([a, b]) => pos >= a && pos < b);

    const decorations = [];
    const atomics = [];

    const hide = (from, to) => { if (to > from) decorations.push(hidden.range(from, to)); };
    const style = (from, to, cls) => {
      if (to > from) decorations.push(Decoration.mark({ class: cls }).range(from, to));
    };
    const dim = (from, to, cls = 'cm-md-mark') => style(from, to, cls);
    const lineClass = (pos, cls) => {
      decorations.push(Decoration.line({ class: cls }).range(doc.lineAt(pos).from));
    };
    const replaceInline = (from, to, widget) => {
      decorations.push(Decoration.replace({ widget }).range(from, to));
      atomics.push(hidden.range(from, to));
    };

    // Marks belonging to an inline construct: dim while editing, gone otherwise.
    const inlineMark = (node, owner) => {
      const from = owner ? owner.from : node.from;
      const to = owner ? owner.to : node.to;
      if (touches(from, to)) dim(node.from, node.to);
      else hide(node.from, node.to);
    };

    const tree = syntaxTree(state);

    for (const { from: viewFrom, to: viewTo } of view.visibleRanges) {
      tree.iterate({
        from: viewFrom,
        to: viewTo,
        enter: (node) => {
          const name = node.name;
          const from = node.from;
          const to = node.to;

          if (name !== 'Document' && inCovered(from)) return false;

          const heading = HEADING_RE.exec(name) || SETEXT_RE.exec(name);
          if (heading) {
            lineClass(from, 'cm-heading cm-h' + heading[1]);
            return;
          }

          switch (name) {
            // ---------------------------------------------------------------
            case 'HeaderMark': {
              const parent = node.node.parent;
              if (parent && SETEXT_RE.test(parent.name)) {
                dim(from, to, 'cm-setext-mark');
                return;
              }
              if (onLines(from, to)) {
                dim(from, to);
              } else {
                let end = to;
                while (end < doc.length && /[ \t]/.test(doc.sliceString(end, end + 1))) end++;
                hide(from, end);
              }
              return;
            }

            // ---------------------------------------------------------------
            case 'Emphasis': style(from, to, 'cm-em'); return;
            case 'StrongEmphasis': style(from, to, 'cm-strong'); return;
            case 'Strikethrough': style(from, to, 'cm-strike'); return;
            case 'Highlight': style(from, to, 'cm-highlight'); return;
            case 'Superscript': style(from, to, 'cm-sup'); return;
            case 'Subscript': style(from, to, 'cm-sub'); return;

            case 'EmphasisMark':
            case 'StrikethroughMark':
            case 'HighlightMark':
            case 'SuperscriptMark':
            case 'SubscriptMark':
              inlineMark(node, node.node.parent);
              return;

            // ---------------------------------------------------------------
            case 'InlineCode': style(from, to, 'cm-inline-code'); return;

            case 'CodeMark': {
              const parent = node.node.parent;
              const parentName = parent ? parent.name : '';
              if (parentName === 'FencedCode') {
                if (onLines(parent.from, parent.to)) dim(from, to);
                else hide(from, to);
              } else {
                inlineMark(node, parent);
              }
              return;
            }

            // ---------------------------------------------------------------
            case 'InlineMath': {
              if (touches(from, to)) {
                style(from, to, 'cm-math-source');
                return;
              }
              const body = doc.sliceString(from, to).replace(/^\$/, '').replace(/\$$/, '');
              replaceInline(from, to, new MathWidget(body, false));
              return false;
            }

            case 'MathMark': {
              const parent = node.node.parent;
              if (parent && parent.name === 'BlockMath') {
                if (onLines(parent.from, parent.to)) dim(from, to);
                else hide(from, to);
              } else {
                inlineMark(node, parent);
              }
              return;
            }

            // ---------------------------------------------------------------
            case 'FencedCode': {
              const first = doc.lineAt(from);
              const last = doc.lineAt(Math.min(to, doc.length));
              for (let n = first.number; n <= last.number; n++) {
                const line = doc.line(n);
                let cls = 'cm-code-line';
                if (n === first.number) cls += ' cm-code-first';
                if (n === last.number) cls += ' cm-code-last';
                decorations.push(Decoration.line({
                  class: cls,
                  attributes: NO_SPELLCHECK,
                }).range(line.from));
              }
              return;
            }

            case 'CodeInfo': {
              const parent = node.node.parent;
              if (parent && !onLines(parent.from, parent.to)) {
                replaceInline(from, to, new CodeLangWidget(doc.sliceString(from, to).trim()));
                return false;
              }
              dim(from, to, 'cm-code-info');
              return;
            }

            // ---------------------------------------------------------------
            case 'Blockquote': {
              const first = doc.lineAt(from).number;
              const last = doc.lineAt(Math.min(to, doc.length)).number;
              for (let n = first; n <= last; n++) {
                decorations.push(Decoration.line({ class: 'cm-blockquote' }).range(doc.line(n).from));
              }
              return;
            }

            case 'QuoteMark': {
              if (onLines(from, to)) {
                dim(from, to);
              } else {
                let end = to;
                while (end < doc.length && doc.sliceString(end, end + 1) === ' ') end++;
                hide(from, end);
              }
              return;
            }

            // ---------------------------------------------------------------
            case 'ListItem': lineClass(from, 'cm-list-item'); return;

            case 'ListMark': {
              if (/^\d/.test(doc.sliceString(from, to))) {
                dim(from, to, 'cm-ordered-mark');
                return;
              }
              let depth = 0;
              for (let p = node.node.parent; p; p = p.parent) {
                if (p.name === 'BulletList' || p.name === 'OrderedList') depth++;
              }
              replaceInline(from, to, new BulletWidget(Math.max(0, depth - 1)));
              return false;
            }

            case 'TaskMarker': {
              const checked = /[xX]/.test(doc.sliceString(from, to));
              replaceInline(from, to, new CheckboxWidget(checked, from));
              return false;
            }

            // ---------------------------------------------------------------
            case 'HorizontalRule': style(from, to, 'cm-hr-source'); return;

            case 'Table': {
              const first = doc.lineAt(from).number;
              const last = doc.lineAt(Math.min(to, doc.length)).number;
              for (let n = first; n <= last; n++) {
                decorations.push(Decoration.line({ class: 'cm-table-source' }).range(doc.line(n).from));
              }
              return;
            }

            // ---------------------------------------------------------------
            case 'Image': {
              if (touches(from, to)) {
                style(from, to, 'cm-image-source');
                return;
              }
              const parsed = IMAGE_ONLY_RE.exec(doc.sliceString(from, to));
              if (!parsed) { style(from, to, 'cm-image-source'); return; }
              replaceInline(from, to, new ImageWidget(parsed[2], parsed[1], docPath, false));
              return false;
            }

            // ---------------------------------------------------------------
            case 'Link': style(from, to, 'cm-link'); return;

            case 'WikiLink': style(from, to, 'cm-wikilink'); return;

            case 'WikiLinkMark': inlineMark(node, node.node.parent); return;

            case 'WikiLinkTarget': {
              const parent = node.node.parent;
              // With an alias present the target is plumbing, so it goes away
              // with the brackets and only the alias is left showing.
              const hasAlias = !!(parent && parent.node.getChild('WikiLinkAlias'));
              if (parent && !touches(parent.from, parent.to)) {
                if (hasAlias) hide(from, to + 1);
                else style(from, to, 'cm-wikilink-target');
              } else {
                dim(from, to, 'cm-wikilink-target');
              }
              return;
            }

            case 'WikiLinkAlias': style(from, to, 'cm-wikilink-target'); return;

            case 'LinkMark': inlineMark(node, node.node.parent); return;

            case 'URL': {
              const parent = node.node.parent;
              if (parent && (parent.name === 'Link' || parent.name === 'Image')) {
                if (touches(parent.from, parent.to)) dim(from, to, 'cm-url');
                else hide(from, to);
              } else {
                style(from, to, 'cm-autolink');
              }
              return;
            }

            case 'LinkTitle': {
              const parent = node.node.parent;
              if (parent && !touches(parent.from, parent.to)) hide(from, to);
              else dim(from, to, 'cm-url');
              return;
            }

            case 'Autolink': style(from, to, 'cm-autolink'); return;

            case 'FrontMatter': {
              const first = doc.lineAt(from).number;
              const last = doc.lineAt(Math.min(to, doc.length)).number;
              for (let n = first; n <= last; n++) {
                let cls = 'cm-frontmatter';
                if (n === first) cls += ' cm-frontmatter-first';
                if (n === last) cls += ' cm-frontmatter-last';
                decorations.push(Decoration.line({
                  class: cls,
                  attributes: NO_SPELLCHECK,
                }).range(doc.line(n).from));
              }
              return;
            }

            case 'FrontMatterMark': dim(from, to, 'cm-frontmatter-mark'); return;

            case 'Comment':
            case 'CommentBlock': dim(from, to, 'cm-comment'); return;

            case 'HTMLTag': dim(from, to, 'cm-html'); return;

            case 'Escape':
              if (!touches(from, to)) hide(from, from + 1);
              return;

            default:
              return;
          }
        },
      });
    }

    this.decorations = Decoration.set(decorations, true);
    this.atomics = Decoration.set(atomics, true);
  }
}

export const inlinePreview = ViewPlugin.fromClass(InlinePreview, {
  decorations: (plugin) => plugin.decorations,
  provide: (plugin) => EditorView.atomicRanges.of(
    (view) => view.plugin(plugin)?.atomics || Decoration.none,
  ),
});

export const livePreviewExtensions = [
  docPathField,
  sourceModeField,
  blockField,
  inlinePreview,
];
