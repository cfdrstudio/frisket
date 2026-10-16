import {
  EditorView, keymap, drawSelection, dropCursor, rectangularSelection,
  crosshairCursor, placeholder, highlightSpecialChars,
} from '@codemirror/view';
import { EditorState, Compartment, Prec } from '@codemirror/state';
import { history, historyKeymap, defaultKeymap, undo, redo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { HighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import { searchKeymap, highlightSelectionMatches, search } from '@codemirror/search';
import { closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete';

import {
  MathExtension, HighlightExtension, FrontMatterExtension, WikiLinkExtension,
} from './markdownMath.js';
import { livePreviewExtensions, setDocPath, setSourceMode, sourceModeField } from './livePreview.js';
import { focusMode, typewriterMode, markdownAutoPair } from './modes.js';
import { noteAutocomplete } from './autocomplete.js';
import * as cmd from './commands.js';

/**
 * Token classes only — every colour lives in the theme CSS so that swapping
 * a theme file restyles code blocks too.
 */
const inkHighlight = HighlightStyle.define([
  { tag: t.keyword, class: 'tok-keyword' },
  { tag: [t.name, t.deleted, t.character, t.macroName], class: 'tok-name' },
  { tag: [t.propertyName], class: 'tok-property' },
  { tag: [t.variableName, t.labelName], class: 'tok-variable' },
  { tag: [t.function(t.variableName), t.function(t.propertyName)], class: 'tok-function' },
  { tag: [t.typeName, t.className, t.namespace], class: 'tok-type' },
  { tag: [t.number, t.bool, t.null, t.atom], class: 'tok-number' },
  { tag: [t.string, t.special(t.string), t.regexp], class: 'tok-string' },
  { tag: [t.comment, t.lineComment, t.blockComment], class: 'tok-comment' },
  { tag: [t.operator, t.operatorKeyword, t.punctuation], class: 'tok-operator' },
  { tag: [t.meta, t.processingInstruction], class: 'tok-meta' },
  { tag: t.invalid, class: 'tok-invalid' },
  { tag: t.link, class: 'tok-link' },
]);

export const compartments = {
  focus: new Compartment(),
  typewriter: new Compartment(),
  autoPair: new Compartment(),
  spellcheck: new Compartment(),
  metrics: new Compartment(),
};

/** Font size / measure / line height, applied as a CodeMirror theme. */
export function metricsTheme({ fontSize, lineHeight, contentWidth }) {
  return EditorView.theme({
    '.cm-content': {
      fontSize: fontSize + 'px',
      lineHeight: String(lineHeight),
      maxWidth: contentWidth + 'px',
    },
  });
}

/**
 * The link target at a position, read from the syntax tree rather than by
 * pattern-matching the line, so aliases, nested brackets and titles behave.
 * Returns a URL, a wiki-link target, or null.
 */
function linkTargetAt(state, pos) {
  const tree = syntaxTree(state);
  let node = tree.resolveInner(pos, 1);

  for (let n = node; n; n = n.parent) {
    if (n.name === 'WikiLink') {
      const target = n.node.getChild('WikiLinkTarget');
      return target ? state.sliceDoc(target.from, target.to).trim() : null;
    }
    if (n.name === 'Link' || n.name === 'Image') {
      const url = n.node.getChild('URL');
      if (url) return state.sliceDoc(url.from, url.to).trim();
    }
    if (n.name === 'Autolink' || n.name === 'URL') {
      return state.sliceDoc(n.from, n.to).replace(/^<|>$/g, '').trim();
    }
  }

  // Bare autolinked text carries no URL node of its own.
  const line = state.doc.lineAt(pos);
  const bare = /(https?:\/\/[^\s)<>]+)/.exec(line.text);
  return bare ? bare[1] : null;
}

function imagePasteHandler(getDocPath, onFollowInternal) {
  return EditorView.domEventHandlers({
    paste(event, view) {
      const items = event.clipboardData ? [...event.clipboardData.items] : [];
      const imageItem = items.find((i) => i.type.startsWith('image/'));
      if (!imageItem) return false;
      const file = imageItem.getAsFile();
      if (!file) return false;
      event.preventDefault();

      const reader = new FileReader();
      reader.onload = async () => {
        const result = await window.frisket.saveDataUrl(reader.result, getDocPath());
        if (result && result.relative) cmd.insertImage(view, result.relative, '');
      };
      reader.readAsDataURL(file);
      return true;
    },

    drop(event, view) {
      const files = event.dataTransfer ? [...event.dataTransfer.files] : [];
      if (!files.length) return false;
      const image = files.find((f) => f.type.startsWith('image/'));
      const attachment = files.find((f) => !f.type.startsWith('image/'));
      if (!image && !attachment) return false;
      event.preventDefault();
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (pos != null) view.dispatch({ selection: { anchor: pos } });
      if (!image) {
        const source = window.frisketFilePath ? window.frisketFilePath(attachment) : attachment.path;
        if (!source) return true;
        window.frisket.importAttachment(source, getDocPath()).then((result) => {
          if (result && result.relative) cmd.insertAttachment(view, result.relative, result.name || attachment.name);
        });
        return true;
      }
      const reader = new FileReader();
      reader.onload = async () => {
        const result = await window.frisket.saveDataUrl(reader.result, getDocPath());
        if (result && result.relative) cmd.insertImage(view, result.relative, '');
      };
      reader.readAsDataURL(image);
      return true;
    },

    // Ctrl/Cmd-click follows a link; a plain click just moves the caret.
    mousedown(event, view) {
      if (!(event.ctrlKey || event.metaKey)) return false;
      const el = event.target instanceof Element
        ? event.target.closest('.cm-link, .cm-autolink, .cm-wikilink, .cm-wikilink-target')
        : null;
      if (!el) return false;

      const pos = view.posAtDOM(el);
      const target = linkTargetAt(view.state, pos);
      if (!target) return false;

      event.preventDefault();
      if (/^(https?:|mailto:)/i.test(target)) window.frisket.openExternal(target);
      else if (onFollowInternal) onFollowInternal(target);
      return true;
    },
  });
}

/**
 * Build the editor. `handlers` receives change/selection notifications so the
 * shell can keep the outline, word count and dirty flag current, and supplies
 * `getCompletionData` for `[[` and `#` autocompletion. `onUpdate` sees every
 * view update (tabs use it to mirror edits between views of one note) and
 * `onFocus` fires when this editor gains focus. `settings` may be a function,
 * so editors created or reloaded later pick up the current preferences.
 */
export function createEditor({ parent, doc = '', settings, handlers = {} }) {
  let currentPath = null;
  const currentSettings = () => (typeof settings === 'function' ? settings() : settings);

  const keys = Prec.high(keymap.of([
    { key: 'Enter', run: cmd.smartEnter },
    { key: 'Backspace', run: cmd.smartBackspace },
    { key: 'Tab', run: (view) => cmd.indentListItem(view, false) },
    { key: 'Shift-Tab', run: (view) => cmd.indentListItem(view, true) },
    { key: 'Mod-b', run: (view) => cmd.toggleWrap(view, '**') },
    { key: 'Mod-i', run: (view) => cmd.toggleWrap(view, '*') },
    { key: 'Mod-u', run: (view) => cmd.toggleWrap(view, '<u>', '</u>') },
    { key: 'Mod-Shift-c', run: (view) => cmd.toggleWrap(view, '`') },
    { key: 'Mod-Shift-h', run: (view) => cmd.toggleWrap(view, '==') },
    { key: 'Mod-Shift-d', run: (view) => cmd.toggleWrap(view, '$') },
    { key: 'Alt-Shift-5', run: (view) => cmd.toggleWrap(view, '~~') },
    { key: 'Mod-z', run: undo, preventDefault: true },
    { key: 'Mod-y', run: redo, preventDefault: true },
    { key: 'Mod-Shift-z', run: redo, preventDefault: true },
  ]));

  const buildState = (text) => {
    const settings = currentSettings();
    return EditorState.create({
      doc: text,
      extensions: [
        history(),
        drawSelection(),
        dropCursor(),
        highlightSpecialChars(),
        rectangularSelection(),
        crosshairCursor(),
        EditorState.allowMultipleSelections.of(true),
        EditorView.lineWrapping,
        placeholder('Start writing…'),
        search({ top: true }),
        highlightSelectionMatches(),
        closeBrackets(),
        noteAutocomplete(() => (handlers.getCompletionData ? handlers.getCompletionData() : null)),
        markdown({
          base: markdownLanguage,
          codeLanguages: languages,
          addKeymap: false,
          extensions: [FrontMatterExtension, MathExtension, HighlightExtension, WikiLinkExtension],
        }),
        syntaxHighlighting(inkHighlight),
        livePreviewExtensions,
        keys,
        keymap.of([...closeBracketsKeymap, ...searchKeymap, ...historyKeymap, ...defaultKeymap]),
        compartments.autoPair.of(settings.autoPair ? markdownAutoPair : []),
        compartments.focus.of(settings.focusMode ? focusMode : []),
        compartments.typewriter.of(settings.typewriterMode ? typewriterMode : []),
        compartments.spellcheck.of(
          EditorView.contentAttributes.of({ spellcheck: settings.spellCheck ? 'true' : 'false' }),
        ),
        compartments.metrics.of(metricsTheme(settings)),
        imagePasteHandler(() => currentPath, handlers.onFollowInternal),
        EditorView.domEventHandlers({
          focus: () => { if (handlers.onFocus) handlers.onFocus(); return false; },
        }),
        EditorView.updateListener.of((update) => {
          if (handlers.onUpdate) handlers.onUpdate(update);
          if (update.docChanged && handlers.onChange) handlers.onChange(update.state.doc.toString());
          if ((update.selectionSet || update.docChanged) && handlers.onSelection) {
            handlers.onSelection(update.state);
          }
        }),
      ],
    });
  };

  const view = new EditorView({ state: buildState(doc), parent });

  return {
    view,
    /**
     * Show another document: a fresh editor state, so undo history never
     * reaches back into the previous note.
     */
    load(text, path = null, sourceMode = false) {
      currentPath = path;
      view.setState(buildState(text));
      view.dispatch({ effects: [setDocPath.of(path), setSourceMode.of(!!sourceMode)] });
    },
    destroy() {
      view.destroy();
    },
    setDocPath(path) {
      currentPath = path;
      view.dispatch({ effects: setDocPath.of(path) });
    },
    setSourceMode(on) {
      view.dispatch({ effects: setSourceMode.of(on) });
    },
    isSourceMode() {
      return view.state.field(sourceModeField, false) || false;
    },
    reconfigure(key, extension) {
      view.dispatch({ effects: compartments[key].reconfigure(extension) });
    },
    setContent(text) {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
        selection: { anchor: 0 },
        scrollIntoView: true,
      });
    },
    getContent() {
      return view.state.doc.toString();
    },
  };
}

export { cmd as commands };
