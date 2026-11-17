import Foundation
import FrisketBase
import Markdown

/// One heading in a rendered document: its level (1-6), plain text and anchor id.
public struct OutlineItem: Equatable, Sendable {
    public var level: Int
    public var text: String
    public var id: String

    public init(level: Int, text: String, id: String) {
        self.level = level
        self.text = text
        self.id = id
    }
}

/// The HTML body of a note and its heading outline.
public struct RenderedMarkdown: Equatable, Sendable {
    public var html: String
    public var outline: [OutlineItem]
}

/// Fenced languages rendered as diagrams rather than highlighted code (markdown.js `DIAGRAM_LANGS`).
public let diagramLanguages: Set<String> = ["mermaid", "sequence", "flow", "flowchart", "gantt"]

/// Markdown to HTML body, matching markdown.js (markdown-it with footnotes,
/// task lists, `$math$`, `==mark==` and `[[wiki links]]`; raw HTML on, no
/// typographer, bare URLs linked). Built on swift-markdown (cmark-gfm).
public struct MarkdownRenderer {
    /// Maps a wiki-link target (without any `#heading`) to an href; nil falls back to `Target.md`.
    public var linkResolver: ((String) -> String?)?
    /// Renders LaTeX to HTML; nil falls back to `\(…\)` / `\[…\]` markup. For display
    /// maths the returned string replaces the whole paragraph, so return block markup.
    public var mathRenderer: ((_ latex: String, _ display: Bool) -> String?)?
    /// Renders a diagram fence (mermaid, …) to SVG/HTML, wrapped by the renderer in
    /// `<div class="mermaid-rendered">`; nil keeps the fenced code block.
    public var diagramRenderer: ((_ language: String, _ source: String) -> String?)?
    /// Pass raw HTML through (markdown.js `html: true`). When false it is shown as text.
    public var allowRawHTML: Bool

    public init(
        linkResolver: ((String) -> String?)? = nil,
        mathRenderer: ((_ latex: String, _ display: Bool) -> String?)? = nil,
        diagramRenderer: ((_ language: String, _ source: String) -> String?)? = nil,
        allowRawHTML: Bool = true
    ) {
        self.linkResolver = linkResolver
        self.mathRenderer = mathRenderer
        self.diagramRenderer = diagramRenderer
        self.allowRawHTML = allowRawHTML
    }

    /// Render a whole note (front matter is stripped) to an HTML body and outline.
    public func render(_ markdown: String) -> RenderedMarkdown {
        let session = RenderSession(renderer: self)
        return session.renderDocument(markdown)
    }

    /// Just the HTML body.
    public func renderHTML(_ markdown: String) -> String { render(markdown).html }
}

// MARK: - Session

private let swiftMarkdownOptions: ParseOptions = [.disableSmartOpts]

final class RenderSession {
    let renderer: MarkdownRenderer
    let store = TokenStore()
    let footnotes = FootnoteState()
    var outline: [OutlineItem] = []
    var usedIDs = Set<String>()
    private var collectHeadings = true
    private var sourceLines: [String] = []

    init(renderer: MarkdownRenderer) { self.renderer = renderer }

    func renderDocument(_ markdown: String) -> RenderedMarkdown {
        let source = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let body = splitFrontMatter(source).body
        var html = convert(body, allowFootnotes: true)
        html += footnotesSection()
        return RenderedMarkdown(html: substitute(html), outline: outline)
    }

    /// Protect, parse and walk one Markdown fragment; placeholders are left in the HTML.
    private func convert(_ source: String, allowFootnotes: Bool) -> String {
        let protector = InlineProtector(store: store, footnotes: footnotes, allowFootnotes: allowFootnotes)
        let protected = protector.run(source)
        let document = Document(parsing: protected, options: swiftMarkdownOptions)
        let savedLines = sourceLines
        sourceLines = protected.components(separatedBy: "\n")
        defer { sourceLines = savedLines }
        return blocks(document.children, tight: false)
    }

    // MARK: footnotes

    private func footnotesSection() -> String {
        // Rendering a body can add nothing new (nested footnotes are off), so one pass is enough.
        guard !footnotes.order.isEmpty else { return "" }
        let wasCollecting = collectHeadings
        collectHeadings = false
        defer { collectHeadings = wasCollecting }
        var items = ""
        for (index, label) in footnotes.order.enumerated() {
            let number = index + 1
            let definition = footnotes.definitions[label] ?? ""
            var body = convert(definition, allowFootnotes: false)
            var backrefs = ""
            let count = footnotes.refCount[label] ?? 1
            for sub in 0..<count {
                let anchor = sub == 0 ? "fnref\(number)" : "fnref\(number)-\(sub + 1)"
                backrefs += " <a href=\"#\(anchor)\" class=\"footnote-backref\">\u{21A9}\u{FE0E}</a>"
            }
            if let range = body.range(of: "</p>\n", options: .backwards), body[range.upperBound...].isEmpty {
                body.replaceSubrange(range, with: backrefs + "</p>\n")
            } else {
                body += "<p>" + backrefs.dropFirst() + "</p>\n"
            }
            items += "<li id=\"fn\(number)\" class=\"footnote-item\">" + body + "</li>\n"
        }
        return "<hr class=\"footnotes-sep\">\n<section class=\"footnotes\">\n<ol class=\"footnotes-list\">\n"
            + items + "</ol>\n</section>\n"
    }

    // MARK: placeholders

    private func substitute(_ html: String) -> String {
        guard html.contains(TokenStore.open) else { return html }
        // Display maths that is a paragraph on its own replaces the paragraph.
        var result = Rx("<p>\u{E000}(\\d+)\u{E001}</p>\\n?").replace(html) { match, ns in
            guard let index = Int(match.group(1, in: ns) ?? ""), case .blockMath(let latex)? = self.store.token(index) else {
                return ns.substring(with: match.range)
            }
            return self.mathHTML(latex, display: true) + "\n"
        }
        result = TokenStore.pattern.replace(result) { match, ns in
            guard let index = Int(match.group(1, in: ns) ?? ""), let token = self.store.token(index) else { return "" }
            switch token {
            case .inlineMath(let latex): return self.mathHTML(latex, display: false)
            case .blockMath(let latex): return self.mathHTML(latex, display: true)
            case .highlight(let text): return "<mark>" + escapeHTML(text) + "</mark>"
            case .wikiLink(let target, let label): return self.wikiLinkHTML(target: target, label: label)
            case .footnoteRef(let number, let sub, _):
                let id = sub == 0 ? "fnref\(number)" : "fnref\(number)-\(sub + 1)"
                return "<sup class=\"footnote-ref\"><a href=\"#fn\(number)\" id=\"\(id)\">[\(number)]</a></sup>"
            }
        }
        return result
    }

    private func mathHTML(_ latex: String, display: Bool) -> String {
        if let custom = renderer.mathRenderer?(latex, display) { return custom }
        if display { return "<div class=\"math display\">\\[" + escapeHTML(latex) + "\\]</div>" }
        return "<span class=\"math inline\">\\(" + escapeHTML(latex) + "\\)</span>"
    }

    private func wikiLinkHTML(target: String, label: String) -> String {
        var name = target
        var fragment: String? = nil
        if let hash = target.firstIndex(of: "#") {
            let anchor = String(target[target.index(after: hash)...]).jsTrimmed
            name = String(target[..<hash]).jsTrimmed
            if !anchor.isEmpty { fragment = headingSlug(anchor) }
        }
        var href: String
        if name.isEmpty {
            href = ""
        } else if let resolved = renderer.linkResolver?(name) {
            href = resolved
        } else {
            let file = Rx("\\.[a-z0-9]+$", [.caseInsensitive]).test(name) ? name : name + ".md"
            href = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        }
        if let fragment { href += "#" + fragment }
        return "<a class=\"wikilink\" href=\"" + escapeHTML(href) + "\">" + escapeHTML(label) + "</a>"
    }

    // MARK: blocks

    private func blocks(_ children: MarkupChildren, tight: Bool) -> String {
        var out = ""
        let all = Array(children)
        for (index, child) in all.enumerated() {
            out += block(child, tight: tight, isLast: index == all.count - 1)
        }
        return out
    }

    private func block(_ node: Markup, tight: Bool, isLast: Bool) -> String {
        switch node {
        case let paragraph as Paragraph:
            let inner = inlines(paragraph.children)
            if tight { return inner + (isLast ? "" : "\n") }
            return "<p>" + inner + "</p>\n"
        case let heading as Heading:
            return headingHTML(heading)
        case let quote as BlockQuote:
            return "<blockquote>\n" + blocks(quote.children, tight: false) + "</blockquote>\n"
        case let code as CodeBlock:
            return codeBlockHTML(code)
        case let html as HTMLBlock:
            let raw = html.rawHTML
            if renderer.allowRawHTML { return raw.hasSuffix("\n") ? raw : raw + "\n" }
            return "<p>" + escapeHTML(raw.jsTrimmed) + "</p>\n"
        case is ThematicBreak:
            return "<hr>\n"
        case let list as UnorderedList:
            return listHTML(list, ordered: false, start: 1)
        case let list as OrderedList:
            return listHTML(list, ordered: true, start: Int(list.startIndex))
        case let table as Markdown.Table:
            return tableHTML(table)
        default:
            return blocks(node.children, tight: tight)
        }
    }

    private func headingHTML(_ heading: Heading) -> String {
        let inner = inlines(heading.children)
        let text = store.plain(plainText(heading)).jsTrimmed
        var id = ""
        if collectHeadings {
            let base = headingSlug(text)
            id = base
            var suffix = 2
            while usedIDs.contains(id) { id = base + "-" + String(suffix); suffix += 1 }
            usedIDs.insert(id)
            outline.append(OutlineItem(level: heading.level, text: text, id: id))
        }
        let level = max(1, min(6, heading.level))
        return "<h\(level)" + (id.isEmpty ? "" : " id=\"" + escapeHTML(id) + "\"") + ">" + inner + "</h\(level)>\n"
    }

    private func codeBlockHTML(_ code: CodeBlock) -> String {
        let language = (code.language ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map(String.init) ?? ""
        let escaped = escapeHTML(code.code)
        if diagramLanguages.contains(language.lowercased()) {
            if let svg = renderer.diagramRenderer?(language.lowercased(), code.code) {
                return "<div class=\"mermaid-rendered\">" + svg + "</div>\n"
            }
            return "<pre data-diagram=\"" + escapeHTML(language.lowercased()) + "\"><code class=\"language-"
                + escapeHTML(language) + "\">" + escaped + "</code></pre>\n"
        }
        if language.isEmpty { return "<pre><code>" + escaped + "</code></pre>\n" }
        return "<pre><code class=\"language-" + escapeHTML(language) + "\">" + escaped + "</code></pre>\n"
    }

    // MARK: lists

    /// cmark's tight/loose flag is not exposed by swift-markdown, so derive it from
    /// the source: a blank line before the next item, or before the next block
    /// inside an item, makes the list loose.
    private func isTight(_ list: Markup) -> Bool {
        func blankBefore(_ node: Markup) -> Bool {
            guard let line = node.range?.lowerBound.line, line >= 2, line - 2 < sourceLines.count else { return false }
            return sourceLines[line - 2].trimmingCharacters(in: CharacterSet(charactersIn: "> \t")).isEmpty
        }
        let items = Array(list.children)
        for (index, item) in items.enumerated() {
            if index > 0, blankBefore(item) { return false }
            let kids = Array(item.children)
            for k in 1..<max(1, kids.count) where blankBefore(kids[k]) { return false }
        }
        return true
    }

    private func listHTML(_ list: ListItemContainer, ordered: Bool, start: Int) -> String {
        let tight = isTight(list)
        let items = Array(list.children).compactMap { $0 as? ListItem }
        let hasTasks = items.contains { $0.checkbox != nil }
        let tag = ordered ? "ol" : "ul"
        var open = "<" + tag
        if ordered, start != 1 { open += " start=\"\(start)\"" }
        if hasTasks { open += " class=\"contains-task-list\"" }
        var out = open + ">\n"
        for item in items { out += itemHTML(item, tight: tight) }
        return out + "</" + tag + ">\n"
    }

    private var checkboxCounter = 0

    private func itemHTML(_ item: ListItem, tight: Bool) -> String {
        var out = "<li" + (item.checkbox != nil ? " class=\"task-list-item\"" : "") + ">"
        var kids = Array(item.children)
        if let box = item.checkbox {
            let id = "cbx_\(checkboxCounter)"
            checkboxCounter += 1
            let input = "<input class=\"task-list-item-checkbox\" disabled=\"\" id=\"\(id)\" type=\"checkbox\""
                + (box == .checked ? " checked=\"\"" : "") + ">"
            if let first = kids.first as? Paragraph {
                let label = input + "<label class=\"task-list-item-label\" for=\"\(id)\"> " + inlines(first.children) + "</label>"
                out += tight ? label : "<p>" + label + "</p>\n"
                if tight, kids.count > 1 { out += "\n" }
                kids.removeFirst()
            } else {
                out += input
            }
        }
        for (index, kid) in kids.enumerated() {
            if tight, index == 0, !(kid is Paragraph), out.hasSuffix(">") == true, item.checkbox == nil { out += "\n" }
            out += block(kid, tight: tight, isLast: index == kids.count - 1)
        }
        if !tight, !out.hasSuffix("\n") { out += "\n" }
        return out + "</li>\n"
    }

    // MARK: tables

    private func tableHTML(_ table: Markdown.Table) -> String {
        let alignments = table.columnAlignments
        func cell(_ cell: Markdown.Table.Cell, _ index: Int, _ tag: String) -> String {
            var style = ""
            if index < alignments.count, let alignment = alignments[index] {
                switch alignment {
                case .left: style = " style=\"text-align:left\""
                case .center: style = " style=\"text-align:center\""
                case .right: style = " style=\"text-align:right\""
                }
            }
            return "<\(tag)\(style)>" + inlines(cell.children) + "</\(tag)>\n"
        }
        var out = "<table>\n<thead>\n<tr>\n"
        for (index, headCell) in table.head.cells.enumerated() { out += cell(headCell, index, "th") }
        out += "</tr>\n</thead>\n"
        let rows = Array(table.body.rows)
        if !rows.isEmpty {
            out += "<tbody>\n"
            for row in rows {
                out += "<tr>\n"
                for (index, bodyCell) in row.cells.enumerated() { out += cell(bodyCell, index, "td") }
                out += "</tr>\n"
            }
            out += "</tbody>\n"
        }
        return out + "</table>\n"
    }

    // MARK: inlines

    private func inlines(_ children: MarkupChildren) -> String {
        var out = ""
        for child in children { out += inline(child) }
        return out
    }

    private func inline(_ node: Markup) -> String {
        switch node {
        case let text as Text: return linkify(text.string)
        case let emphasis as Emphasis: return "<em>" + inlines(emphasis.children) + "</em>"
        case let strong as Strong: return "<strong>" + inlines(strong.children) + "</strong>"
        case let strike as Strikethrough: return "<s>" + inlines(strike.children) + "</s>"
        case let code as InlineCode: return "<code>" + escapeHTML(code.code) + "</code>"
        case is SoftBreak: return "\n"
        case is LineBreak: return "<br>\n"
        case let html as InlineHTML:
            return renderer.allowRawHTML ? html.rawHTML : escapeHTML(html.rawHTML)
        case let link as Link:
            inLink += 1
            let inner = inlines(link.children)
            inLink -= 1
            guard let destination = link.destination, isSafeLink(destination) else { return inner }
            var out = "<a href=\"" + normalizeLink(destination) + "\""
            if let title = link.title, !title.isEmpty { out += " title=\"" + escapeHTML(title) + "\"" }
            return out + ">" + inner + "</a>"
        case let image as Image:
            let alt = escapeHTML(store.plain(plainText(image)))
            guard let source = image.source, isSafeLink(source) else { return alt }
            var out = "<img src=\"" + normalizeLink(source) + "\" alt=\"" + alt + "\""
            if let title = image.title, !title.isEmpty { out += " title=\"" + escapeHTML(title) + "\"" }
            return out + ">"
        default:
            return inlines(node.children)
        }
    }

    /// Text content of an inline subtree, placeholders left in.
    private func plainText(_ node: Markup) -> String {
        switch node {
        case let text as Text: return text.string
        case let code as InlineCode: return code.code
        case is SoftBreak, is LineBreak: return " "
        case is InlineHTML: return ""
        default: return node.children.map { plainText($0) }.joined()
        }
    }

    // MARK: URLs

    private var inLink = 0
    private static let bareURL = Rx("(?:https?://|www\\.)[^\\s<\u{E000}]+|[A-Za-z0-9._%+\\-]+@[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)+", [.caseInsensitive])

    /// markdown-it `linkify`: bare http(s) and www URLs and e-mail addresses become links.
    private func linkify(_ text: String) -> String {
        guard inLink == 0 else { return escapeHTML(text) }
        let ns = text as NSString
        let found = RenderSession.bareURL.matches(text)
        if found.isEmpty { return escapeHTML(text) }
        var out = ""
        var cursor = 0
        for match in found {
            var range = match.range
            if range.location > 0 {
                let before = ns.character(at: range.location - 1)
                if let scalar = Unicode.Scalar(before), CharacterSet.alphanumerics.contains(scalar) { continue }
            }
            var url = ns.substring(with: range)
            // Trailing punctuation belongs to the sentence, not the URL.
            while let last = url.last {
                if ".,;:!?'\"*_~".contains(last) { url.removeLast(); continue }
                if last == ")" || last == "]" {
                    let open: Character = last == ")" ? "(" : "["
                    if url.filter({ $0 == open }).count < url.filter({ $0 == last }).count { url.removeLast(); continue }
                }
                break
            }
            if url.isEmpty { continue }
            range.length = (url as NSString).length
            if range.location < cursor { continue }
            out += escapeHTML(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            let href: String
            if url.contains("@"), !url.lowercased().hasPrefix("http") { href = "mailto:" + url }
            else if url.lowercased().hasPrefix("www.") { href = "http://" + url }
            else { href = url }
            out += "<a href=\"" + normalizeLink(href) + "\">" + escapeHTML(url) + "</a>"
            cursor = range.location + range.length
        }
        out += escapeHTML(ns.substring(from: cursor))
        return out
    }

    /// markdown-it `validateLink`: refuse script-ish schemes.
    private func isSafeLink(_ url: String) -> Bool {
        let compact = Rx("[\\u0000-\\u0020]").replace(url, template: "").lowercased()
        if Rx("^(?:vbscript|javascript|file|data):").test(compact) {
            return Rx("^data:image/(?:gif|png|jpeg|webp)").test(compact)
        }
        return true
    }

    /// Percent-encode what a URL cannot hold (keeping existing `%XX`), then HTML-escape.
    private func normalizeLink(_ url: String) -> String {
        let keep = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=")
        var out = ""
        let scalars = Array(url.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "%", i + 2 < scalars.count,
               scalars[i + 1].properties.isASCIIHexDigit, scalars[i + 2].properties.isASCIIHexDigit {
                out += "%"
            } else if s == "%" {
                out += "%25"
            } else if keep.contains(s) {
                out.unicodeScalars.append(s)
            } else {
                out += String(s).addingPercentEncoding(withAllowedCharacters: CharacterSet()) ?? ""
            }
            i += 1
        }
        return escapeHTML(out)
    }
}
