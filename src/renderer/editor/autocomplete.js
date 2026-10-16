import { autocompletion } from '@codemirror/autocomplete';
import { syntaxTree } from '@codemirror/language';
import {
  wikiLinkContext, tagContext, noteCompletions, tagCompletions, wikiInsertion,
} from './completions.mjs';

// Places where `[[` and `#` are literal text rather than links or tags.
const LITERAL_NODES = /^(?:InlineCode|FencedCode|CodeBlock|CodeText|CodeMark|FrontMatter|URL|Autolink|HTMLBlock|HTMLTag|Comment)/;

function inLiteral(state, pos) {
  for (let node = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
    if (LITERAL_NODES.test(node.name)) return true;
  }
  return false;
}

function lineBefore(context) {
  const line = context.state.doc.lineAt(context.pos);
  return { line, before: line.text.slice(0, context.pos - line.from) };
}

function noteSource(getData) {
  return (context) => {
    const { line, before } = lineBefore(context);
    const found = wikiLinkContext(before);
    if (!found || inLiteral(context.state, context.pos)) return null;
    const options = noteCompletions((getData() || {}).notes, found.query).map((option) => ({
      label: option.label,
      detail: option.detail,
      apply: (view, _completion, from, to) => {
        const after = view.state.sliceDoc(to, view.state.doc.lineAt(to).to);
        const edit = wikiInsertion(option, after);
        view.dispatch({
          changes: { from, to: to + edit.replace, insert: edit.text },
          selection: { anchor: from + edit.cursor },
          userEvent: 'input.complete',
        });
      },
    }));
    return options.length ? { from: line.from + found.start, options, filter: false } : null;
  };
}

function tagSource(getData) {
  return (context) => {
    const { line, before } = lineBefore(context);
    const found = tagContext(before);
    if (!found || inLiteral(context.state, context.pos)) return null;
    const options = tagCompletions((getData() || {}).tags, found.query).map((option) => ({
      label: '#' + option.label,
      detail: option.detail,
      apply: option.insert,
    }));
    return options.length ? { from: line.from + found.start, options, filter: false } : null;
  };
}

/**
 * `[[` completes note links and `#` completes existing tags. `getData` returns
 * the latest library overview (`{ notes, tags }`), so typing costs no IPC.
 */
export function noteAutocomplete(getData) {
  return autocompletion({
    override: [noteSource(getData), tagSource(getData)],
    icons: false,
    closeOnBlur: true,
    maxRenderedOptions: 50,
  });
}
