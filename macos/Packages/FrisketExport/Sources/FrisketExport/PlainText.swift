import Foundation
import FrisketBase

/// The `.txt` export (exportDoc.js `buildPlainText`): render to HTML, then flatten it
/// block by block. List bullets, table cells (tab separated) and code stay legible,
/// link URLs are dropped but their text kept.
public enum PlainText {
    /// Differences from the Electron app: maths keeps its LaTeX source (`$x$`, `$$x$$`)
    /// where the original dropped it, diagram fences stay as source text, and list items and
    /// table cells are not double-spaced (table cells are tab separated within a row).
    public static func from(markdown: String) -> String {
        var renderer = MarkdownRenderer()
        renderer.mathRenderer = { latex, display in
            // Display maths replaces its whole paragraph, so give it a paragraph.
            display ? "<p>" + escapeHTML("$$" + latex + "$$") + "</p>" : escapeHTML("$" + latex + "$")
        }
        return flatten(html: renderer.render(markdown).html)
    }

    private static let tag = Rx("<(/?)([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*?(/?)>|<!--[\\s\\S]*?-->")
    private static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "pre", "blockquote", "figcaption"]
    private static let airyTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "table"]

    private static let structural: Set<String> = ["ul", "ol", "table", "thead", "tbody", "tr"]

    static func flatten(html: String) -> String {
        let ns = html as NSString
        var out = ""
        var cursor = 0
        var lists: [String] = []
        var skipDepth = 0   // inside <script>/<style>
        var containers: [String] = []
        // The markup's own line breaks between list items and table cells would double
        // every line (the Electron export had that quirk), so they are not text here.
        func text(_ s: String) {
            guard skipDepth == 0 else { return }
            if let top = containers.last, structural.contains(top), s.jsTrimmed.isEmpty { return }
            out += decodeHTMLEntities(s)
        }

        for match in tag.matches(html) {
            text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
            guard let name = match.group(1 + 1, in: ns)?.lowercased() else { continue }
            let closing = !(match.group(1, in: ns) ?? "").isEmpty
            if name == "script" || name == "style" { skipDepth = max(0, skipDepth + (closing ? -1 : 1)); continue }
            if skipDepth > 0 { continue }
            if !closing {
                switch name {
                case "ul", "ol": lists.append(name); containers.append(name)
                case "li": out += lists.last == "ol" ? "  1. " : "  - "
                case "hr": out += "\n" + String(repeating: "-", count: 60) + "\n"
                case "table", "thead", "tbody", "tr": containers.append(name)
                default: break
                }
                continue
            }
            switch name {
            case "ul", "ol": _ = lists.popLast(); _ = containers.popLast()
            case "table", "thead", "tbody", "tr": _ = containers.popLast()
            case "th", "td": out += "\t"
            default: break
            }
            if blockTags.contains(name) { out += "\n" }
            if airyTags.contains(name) { out += "\n" }
        }
        text(ns.substring(from: cursor))

        out = out.replacingOccurrences(of: "\u{a0}", with: " ")
        out = Rx("[ \\t]+$", [.anchorsMatchLines]).replace(out, template: "")
        out = Rx("\\n{3,}").replace(out, template: "\n\n")
        return out.jsTrimmed + "\n"
    }
}
