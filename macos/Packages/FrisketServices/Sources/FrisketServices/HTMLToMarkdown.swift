import Foundation
import FrisketBase

/// An attachment an Evernote `<en-media>` element refers to, once the importer has saved it.
public struct HTMLMedia: Sendable {
    /// Link destination to write.
    public var href: String
    /// Visible label.
    public var name: String
    /// Image attachments are written as `![name](href)`.
    public var image: Bool
    public init(href: String, name: String, image: Bool) {
        self.href = href
        self.name = name
        self.image = image
    }
}

/// A small, dependency-free HTML to Markdown converter for imported notes
/// (Evernote ENML, Apple Notes HTML). It is tolerant rather than complete:
/// unknown elements contribute their text, and nothing it cannot express is
/// allowed to break the surrounding Markdown. Port of html.js, using the same
/// hand-written tokenizer (not `XMLDocument`) so output matches the original.
public enum HTMLToMarkdown {
    /// Convert HTML to Markdown. `media(hash, type)` resolves Evernote `<en-media>`;
    /// `image(src, attributes)` may return a replacement `src` for `<img>`
    /// (for example a saved copy of a `data:` URI).
    public static func convert(
        _ html: String,
        media: @escaping (_ hash: String, _ type: String) -> HTMLMedia? = { _, _ in nil },
        image: @escaping (_ src: String, _ attributes: [String: String]) -> String? = { _, _ in nil }
    ) -> String {
        let converter = HTMLConverter(media: media, image: image)
        return finishMarkdown(converter.node(parseHTML(html), block: true))
    }

    /// Decode `&amp;`, `&#x41;`, `&#65;` and the common named entities; unknown ones are left as written.
    public static func decodeEntities(_ text: String) -> String { decodeHTMLEntities(text) }
}

// MARK: Tables and constants

private let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "en-media", "en-todo"]
private let skipElements: Set<String> = ["script", "style", "head", "title", "noscript", "template"]
private let blockElements: Set<String> = [
    "address", "article", "aside", "blockquote", "body", "center", "dd", "details", "dialog", "div", "dl", "dt",
    "en-note", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
    "hr", "html", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "ul",
]
/// Opening one of these ends an open `<p>`, as browsers do.
private let closesParagraph: Set<String> = ["div", "ul", "ol", "table", "pre", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "p", "hr", "section", "article", "figure"]

private let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
    "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
    "bull": "•", "middot": "·", "times": "×", "divide": "÷", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "plusmn": "±",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
    "hearts": "♥", "check": "✓", "frac12": "½", "frac14": "¼", "frac34": "¾", "iexcl": "¡", "iquest": "¿", "shy": "",
]

private let hardBreak = "\u{1}"
private let todoOpen = "\u{2}"
private let todoClose = "\u{3}"

private let entityPattern = Rx("&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);", [.caseInsensitive])

func decodeHTMLEntities(_ text: String) -> String {
    if !text.contains("&") { return text }
    return entityPattern.replace(text) { match, ns in
        let whole = ns.substring(with: match.range)
        let body = match.group(1, in: ns) ?? ""
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let code: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") { code = UInt32(digits.dropFirst(), radix: 16) }
            else { code = UInt32(digits, radix: 10) }
            guard let code else { return whole }
            if code == 0 { return "" }
            guard let scalar = Unicode.Scalar(code) else { return whole }
            return String(Character(scalar))
        }
        return namedEntities[body.lowercased()] ?? whole
    }
}

// MARK: Parsing

final class HTMLNode {
    let isText: Bool
    var name: String
    var attrs: [String: String]
    var children: [HTMLNode] = []
    var text: String

    init(element name: String, attrs: [String: String] = [:]) {
        isText = false
        self.name = name
        self.attrs = attrs
        text = ""
    }

    init(text: String) {
        isText = true
        name = ""
        attrs = [:]
        self.text = text
    }
}

private let attributePattern = Rx("([^\\s\"'>/=]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+)))?")

private func parseAttributes(_ source: String?) -> [String: String] {
    var attrs: [String: String] = [:]
    guard let source, !source.isEmpty else { return attrs }
    let ns = source as NSString
    for match in attributePattern.matches(ns) {
        let name = (match.group(1, in: ns) ?? "").lowercased()
        let value = match.group(2, in: ns) ?? match.group(3, in: ns) ?? match.group(4, in: ns) ?? ""
        attrs[name] = decodeHTMLEntities(value)
    }
    return attrs
}

private let tokenPattern = Rx(
    "<!--[\\s\\S]*?-->|<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>|<![^>]*>|<\\?[\\s\\S]*?\\?>"
    + "|<\\/\\s*([a-zA-Z][A-Za-z0-9_:-]*)\\s*>"
    + "|<([a-zA-Z][A-Za-z0-9_:-]*)((?:\\s+[^\\s\"'>/=]+(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s\"'=<>`]+))?)*)\\s*(\\/?)>"
)

/// Parse HTML into a node tree (an element named `#root`).
func parseHTML(_ html: String) -> HTMLNode {
    let root = HTMLNode(element: "#root")
    var stack: [HTMLNode] = [root]
    let source = html as NSString
    let length = source.length
    var last = 0
    var position = 0

    func addText(_ text: String) {
        if !text.isEmpty { stack[stack.count - 1].children.append(HTMLNode(text: text)) }
    }

    while position <= length, let match = tokenPattern.first(source, range: NSRange(location: position, length: length - position)) {
        addText(decodeHTMLEntities(source.substring(with: NSRange(location: last, length: match.range.location - last))))
        last = match.range.location + match.range.length
        position = last
        if let cdata = match.group(1, in: source) { addText(cdata); continue }
        if let closing = match.group(2, in: source) {
            let name = closing.lowercased()
            if let at = stack.lastIndex(where: { $0.name == name }), at > 0 { stack.removeSubrange(at...) }
            continue
        }
        guard let rawName = match.group(3, in: source), !rawName.isEmpty else { continue }
        let name = rawName.lowercased()
        if skipElements.contains(name) {
            let end = source.range(of: "</" + name, options: [.caseInsensitive, .literal], range: NSRange(location: last, length: length - last))
            var close = length
            if end.location != NSNotFound, let gt = jsIndexOf(html, ">", from: end.location) { close = gt + 1 }
            position = close
            last = close
            continue
        }
        if closesParagraph.contains(name), stack.last?.name == "p" { stack.removeLast() }
        if name == "li" {
            let open = stack.map(\.name)
            let li = open.lastIndex(of: "li") ?? -1
            let list = max(open.lastIndex(of: "ul") ?? -1, open.lastIndex(of: "ol") ?? -1)
            if li > list { stack.removeSubrange(li...) }
        }
        if name == "td" || name == "th", let top = stack.last?.name, top == "td" || top == "th" { stack.removeLast() }
        if name == "tr" {
            let open = stack.map(\.name)
            let tr = open.lastIndex(of: "tr") ?? -1
            if tr > (open.lastIndex(of: "table") ?? -1) { stack.removeSubrange(tr...) }
        }
        let node = HTMLNode(element: name, attrs: parseAttributes(match.group(4, in: source)))
        stack[stack.count - 1].children.append(node)
        let selfClosing = !(match.group(5, in: source) ?? "").isEmpty
        if !voidElements.contains(name) && !selfClosing { stack.append(node) }
    }
    addText(decodeHTMLEntities(source.substring(from: min(last, length))))
    return root
}

// MARK: Text helpers

private func textContent(_ node: HTMLNode) -> String {
    if node.isText { return node.text }
    if node.name == "br" { return "\n" }
    let inner = node.children.map(textContent).joined()
    return blockElements.contains(node.name) && node.name != "pre" ? inner + "\n" : inner
}

private struct InlineStyle {
    var bold = false, italic = false, underline = false, strike = false, highlight = false
}

private let boldStyle = Rx("font-weight\\s*:\\s*(?:bold|[6-9]00)")
private let italicStyle = Rx("font-style\\s*:\\s*italic")
private let underlineStyle = Rx("text-decoration[^;]*underline")
private let strikeStyle = Rx("text-decoration[^;]*line-through")
private let highlightStyle = Rx("--en-highlight|background-color\\s*:\\s*(?:rgb\\(\\s*255\\s*,\\s*2[0-9]{2}\\s*,|#ff[ef])")

private func styleOf(_ node: HTMLNode) -> InlineStyle {
    let style = (node.attrs["style"] ?? "").lowercased()
    return InlineStyle(
        bold: boldStyle.test(style), italic: italicStyle.test(style), underline: underlineStyle.test(style),
        strike: strikeStyle.test(style), highlight: highlightStyle.test(style))
}

private let wrapPattern = Rx("^(\\s*)([\\s\\S]*?)(\\s*)\\z")

/// Wrap inline text in a marker, keeping surrounding spaces outside it.
private func wrap(_ content: String, _ open: String, _ close: String? = nil) -> String {
    let ns = content as NSString
    guard let match = wrapPattern.first(ns) else { return content }
    let middle = match.group(2, in: ns) ?? ""
    if middle.isEmpty || middle.replacingOccurrences(of: hardBreak, with: "").jsTrimmed.isEmpty { return content }
    return (match.group(1, in: ns) ?? "") + open + middle + (close ?? open) + (match.group(3, in: ns) ?? "")
}

private let underscoreEdge = Rx("(^|[^\\p{L}\\p{N}])_|_(?=[^\\p{L}\\p{N}]|\\z)")
private let specialChars = Rx("([*`\\[\\]])")
private let angleOpen = Rx("<(?=[a-zA-Z!/?])")
private let hashDigit = Rx("#(?=[0-9])")

private func escapeText(_ text: String) -> String {
    var out = text.replacingOccurrences(of: "\\", with: "\\\\")
    out = specialChars.replace(out) { match, ns in "\\" + ns.substring(with: match.range) }
    out = underscoreEdge.replace(out) { match, ns in
        // `whole.replace('_', '\\_')` in the original: only the first underscore of the match.
        let whole = ns.substring(with: match.range) as NSString
        return whole.replacingCharacters(in: whole.range(of: "_"), with: "\\_")
    }
    out = angleOpen.replace(out) { _, _ in "\\<" }
    out = hashDigit.replace(out) { _, _ in "\\#" }
    return out
}

private let needsAngles = Rx("[\\s()<>]")

func markdownLinkDestination(_ href: String) -> String {
    let value = href.jsTrimmed
    guard needsAngles.test(value) else { return value }
    let encoded = value.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
    return "<" + encoded + ">"
}

private let backtickRun = Rx("`+")
private let backtickEdge = Rx("^`|`\\z")

private func codeSpan(_ text: String) -> String {
    let longest = backtickRun.matches(text).map { $0.range.length }.max() ?? 0
    let fence = String(repeating: "`", count: longest + 1)
    let pad = backtickEdge.test(text) ? " " : ""
    return fence + pad + text + pad + fence
}

private let fenceRun = Rx("^`{3,}", [.anchorsMatchLines])
private let trailingNewlines = Rx("\\n+\\z")

private func fencedBlock(_ text: String, language: String = "") -> String {
    let longest = fenceRun.matches(text).map { $0.range.length + 1 }.max() ?? 0
    let fence = String(repeating: "`", count: max(3, longest))
    return fence + language + "\n" + trailingNewlines.replace(text, template: "") + "\n" + fence
}

// MARK: Converter

private let whitespaceRun = Rx("[ \\t\\r\\n\\f]+")
private let anyWhitespaceRun = Rx("\\s+")
private let spaceTabRun = Rx("[ \\t]+")
private let lineStartMarker = Rx("(^|\\n)(#{1,6}\\s|>|[-+]\\s)")
private let lineStartNumber = Rx("(^|\\n)([0-9]+)([.)]\\s)")
private let unsafeHref = Rx("^(?:javascript|vbscript|data):", [.caseInsensitive])
private let dataScheme = Rx("^data:", [.caseInsensitive])
private let todoPrefix = Rx("^" + todoOpen + "([ x])" + todoClose + "\\s*")
private let nestedListGap = Rx("\\n\\n(?=\\s*(?:[-+*]|[0-9]+[.)]) )")
private let newlineRun = Rx("\\n+")
private let pipe = Rx("\\|")

private final class HTMLConverter {
    let media: (String, String) -> HTMLMedia?
    let image: (String, [String: String]) -> String?

    init(media: @escaping (String, String) -> HTMLMedia?, image: @escaping (String, [String: String]) -> String?) {
        self.media = media
        self.image = image
    }

    /// Inline rendering of a node's children.
    func inline(_ node: HTMLNode) -> String {
        node.children.map { self.node($0, block: false) }.joined()
    }

    /// Children rendered as blocks separated by blank lines.
    func blocks(_ node: HTMLNode) -> String {
        var out = ""
        var run = ""
        func flush() {
            let text = spaceTabRun.replace(run, template: " ").jsTrimmed
            if !text.isEmpty { out += "\n\n" + guardLineStart(text) + "\n\n" }
            run = ""
        }
        for child in node.children {
            if !child.isText && blockElements.contains(child.name) {
                flush()
                out += "\n\n" + self.node(child, block: true) + "\n\n"
            } else {
                run += self.node(child, block: false)
            }
        }
        flush()
        return out
    }

    /// Text that would start a heading, quote or list at line start gets escaped.
    func guardLineStart(_ text: String) -> String {
        let first = lineStartMarker.replace(text) { match, ns in
            (match.group(1, in: ns) ?? "") + "\\" + (match.group(2, in: ns) ?? "")
        }
        return lineStartNumber.replace(first) { match, ns in
            (match.group(1, in: ns) ?? "") + (match.group(2, in: ns) ?? "") + "\\" + (match.group(3, in: ns) ?? "")
        }
    }

    func node(_ node: HTMLNode, block: Bool) -> String {
        if node.isText { return escapeText(whitespaceRun.replace(node.text, template: " ")) }
        let attrs = node.attrs
        switch node.name {
        case "br": return hardBreak
        case "hr": return "---"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let flat = inline(node).replacingOccurrences(of: hardBreak, with: " ")
            let text = anyWhitespaceRun.replace(flat, template: " ").jsTrimmed
            return text.isEmpty ? "" : String(repeating: "#", count: Int(String(node.name.last!))!) + " " + text
        case "p", "div", "section", "article", "header", "footer", "main", "center", "en-note", "body", "html", "figure",
             "figcaption", "address", "details", "summary", "dd", "dt", "dl", "aside", "nav", "form", "fieldset", "#root":
            return styled(node, blocks(node))
        case "blockquote":
            let inner = finishMarkdown(blocks(node))
            if inner.isEmpty { return "" }
            return jsSplit(inner, "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        case "pre":
            let text = textContent(node).replacingOccurrences(of: "\u{00A0}", with: " ")
            return text.jsTrimmed.isEmpty ? "" : fencedBlock(text)
        case "ul", "ol": return list(node)
        case "li": return finishMarkdown(blocks(node))
        case "table": return table(node)
        case "b", "strong": return wrap(inline(node), "**")
        case "i", "em", "cite", "dfn": return wrap(inline(node), "*")
        case "u", "ins": return wrap(inline(node), "<u>", "</u>")
        case "s", "strike", "del": return wrap(inline(node), "~~")
        case "mark": return wrap(inline(node), "==")
        case "sub": return wrap(inline(node), "~")
        case "sup": return wrap(inline(node), "^")
        case "code", "tt", "kbd", "samp":
            let text = anyWhitespaceRun.replace(textContent(node), template: " ")
            return text.jsTrimmed.isEmpty ? "" : codeSpan(text)
        case "a":
            let content = inline(node)
            let href = (attrs["href"] ?? "").jsTrimmed
            if href.isEmpty || unsafeHref.test(href) { return content }
            if content.jsTrimmed.isEmpty { return "<" + href + ">" }
            return "[" + content.jsTrimmed + "](" + markdownLinkDestination(href) + ")"
        case "img":
            var src = image(attrs["src"] ?? "", attrs) ?? ""
            if src.isEmpty { src = attrs["src"] ?? "" }
            if src.isEmpty || dataScheme.test(src) { return "" }
            return "![" + escapeText(attrs["alt"] ?? "") + "](" + markdownLinkDestination(src) + ")"
        case "en-media":
            guard let found = media(attrs["hash"] ?? "", attrs["type"] ?? "") else { return "" }
            let label = escapeText(found.name.isEmpty ? "attachment" : found.name)
            return (found.image ? "!" : "") + "[" + label + "](" + markdownLinkDestination(found.href) + ")"
        case "en-todo": return todoOpen + (attrs["checked"] == "true" ? "x" : " ") + todoClose
        case "input":
            return attrs["type"] == "checkbox" ? todoOpen + (attrs["checked"] != nil ? "x" : " ") + todoClose : ""
        case "en-crypt": return "*[Encrypted text not imported]*"
        default:
            return styled(node, block ? blocks(node) : inline(node))
        }
    }

    func styled(_ node: HTMLNode, _ content: String) -> String {
        guard let style = node.attrs["style"], !style.isEmpty else { return content }
        let flags = styleOf(node)
        var out = content
        if flags.bold { out = wrap(out, "**") }
        if flags.italic { out = wrap(out, "*") }
        if flags.strike { out = wrap(out, "~~") }
        if flags.underline { out = wrap(out, "<u>", "</u>") }
        if flags.highlight { out = wrap(out, "==") }
        return out
    }

    func list(_ node: HTMLNode) -> String {
        let ordered = node.name == "ol"
        var number = 1
        if let start = node.attrs["start"], let parsed = Int(start.jsTrimmed), parsed != 0 { number = parsed }
        var items: [String] = []
        for child in node.children where !child.isText {
            if child.name == "ul" || child.name == "ol" {
                // A list directly inside a list: nest it under the previous item.
                let nested = list(child)
                let indented = jsSplit(nested, "\n").map { "  " + $0 }.joined(separator: "\n")
                if items.isEmpty { items.append(nested) } else { items[items.count - 1] += "\n" + indented }
                continue
            }
            if child.name != "li" { continue }
            var raw = blocks(child).jsTrimmed
            var marker = "- "
            if ordered { marker = "\(number). "; number += 1 }
            if let todo = todoPrefix.first(raw) {
                marker = "- [" + (todo.group(1, in: raw) ?? " ") + "] "
                raw = raw.utf16Slice(todo.range.length)
            }
            // Keep a nested list tight against its item rather than a blank line apart.
            let content = nestedListGap.replace(finishMarkdown(raw), template: "\n")
            let indent = String(repeating: " ", count: marker.utf16Length)
            let lines = jsSplit(content, "\n")
            items.append(marker + lines[0] + lines.dropFirst().map { "\n" + ($0.isEmpty ? "" : indent + $0) }.joined())
        }
        return items.joined(separator: "\n")
    }

    func table(_ node: HTMLNode) -> String {
        var rows: [HTMLNode] = []
        func collect(_ parent: HTMLNode) {
            for child in parent.children where !child.isText {
                if child.name == "tr" { rows.append(child) }
                else if ["thead", "tbody", "tfoot"].contains(child.name) { collect(child) }
            }
        }
        collect(node)
        let cells: [[String]] = rows.map { row in
            row.children.filter { !$0.isText && ($0.name == "td" || $0.name == "th") }.map { cell in
                let flat = newlineRun.replace(finishMarkdown(blocks(cell)), template: "<br>")
                return pipe.replace(flat) { _, _ in "\\|" }.jsTrimmed
            }
        }
        let width = cells.map(\.count).max() ?? 0
        if width == 0 { return "" }
        func line(_ row: [String]) -> String {
            let padded = row + Array(repeating: "", count: width - row.count)
            return "| " + padded.map { $0.isEmpty ? " " : $0 }.joined(separator: " | ") + " |"
        }
        let rule = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        return ([line(cells[0]), rule] + cells.dropFirst().map(line)).joined(separator: "\n")
    }
}

// MARK: Finishing

private let trailingBlankSpace = Rx("[ \\t]+\\n")
private let blankSpaceLine = Rx("\\n[ \\t]+(?=\\n)")
private let threeNewlines = Rx("\\n{3,}")
private let todoLine = Rx("^(\\s*)" + todoOpen + "([ x])" + todoClose + "\\s*")
private let todoInline = Rx(todoOpen + "([ x])" + todoClose)
private let trailingBreaks = Rx("(?:" + hardBreak + "\\s*)+$", [.anchorsMatchLines])
private let leadingBreak = Rx("^\\s*" + hardBreak, [.anchorsMatchLines])
private let breakRun = Rx("\\s*" + hardBreak + "\\s*")
private let looseTodos = Rx("^(\\s*- \\[[ x]\\] .*)\\n\\n(?=\\s*- \\[[ x]\\] )", [.anchorsMatchLines])

/// Tidy converted output: whitespace, to-do markers and hard breaks.
func finishMarkdown(_ markdown: String) -> String {
    var text = trailingBlankSpace.replace(markdown, template: "\n")
    text = blankSpaceLine.replace(text, template: "\n")
    text = threeNewlines.replace(text, template: "\n\n")
    text = jsSplit(text, "\n").map { line in
        todoInline.replace(todoLine.replace(line, template: "$1- [$2] "), template: "[$1]")
    }.joined(separator: "\n")
    text = trailingBreaks.replace(text, template: "")
    text = leadingBreak.replace(text, template: "")
    text = breakRun.replace(text, template: "  \n")
    text = threeNewlines.replace(text, template: "\n\n")
    text = looseTodos.replace(text, template: "$1\n")
    return text.jsTrimmed
}
