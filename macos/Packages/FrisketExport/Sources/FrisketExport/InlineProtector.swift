import Foundation
import FrisketBase

/// A span cmark would mangle (or cannot parse) that is replaced by a private-use
/// placeholder before parsing and substituted back into the HTML afterwards.
enum ProtectedToken {
    case inlineMath(String)
    case blockMath(String)
    case highlight(String)
    case wikiLink(target: String, label: String)
    case footnoteRef(number: Int, sub: Int, label: String)
}

/// Collects placeholders. A placeholder is `U+E000 <index> U+E001`.
final class TokenStore {
    var tokens: [ProtectedToken] = []

    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"
    static let pattern = Rx("\u{E000}(\\d+)\u{E001}")

    func add(_ token: ProtectedToken) -> String {
        tokens.append(token)
        return "\(TokenStore.open)\(tokens.count - 1)\(TokenStore.close)"
    }

    func token(_ index: Int) -> ProtectedToken? {
        tokens.indices.contains(index) ? tokens[index] : nil
    }

    /// The text a placeholder stands for in plain-text contexts (alt text, outline, slugs).
    func plain(_ text: String) -> String {
        guard text.contains(TokenStore.open) else { return text }
        return TokenStore.pattern.replace(text) { match, ns in
            guard let index = Int(match.group(1, in: ns) ?? ""), let token = self.token(index) else { return "" }
            switch token {
            case .inlineMath(let latex), .blockMath(let latex): return latex
            case .highlight(let text): return text
            case .wikiLink(_, let label): return label
            case .footnoteRef(let number, _, _): return "[\(number)]"
            }
        }
    }
}

/// Footnote bookkeeping shared by the protect pass and the renderer.
final class FootnoteState {
    /// Definition source by label (first definition wins).
    var definitions: [String: String] = [:]
    /// Labels in order of first reference.
    var order: [String] = []
    /// How many references each label has.
    var refCount: [String: Int] = [:]
    var inlineCounter = 0

    func reference(_ label: String) -> (number: Int, sub: Int) {
        if let index = order.firstIndex(of: label) {
            refCount[label, default: 0] += 1
            return (index + 1, refCount[label]! - 1)
        }
        order.append(label)
        refCount[label] = 1
        return (order.count, 0)
    }
}

/// The source-level pass: footnote definitions out, then math, highlights, wiki
/// links and footnote references replaced by placeholders, never inside code.
struct InlineProtector {
    let store: TokenStore
    let footnotes: FootnoteState
    /// Nested renders (footnote bodies) leave footnote references alone.
    let allowFootnotes: Bool

    private static let fenceOpen = Rx("^[ \\t>]*(?:(?:[-*+]|\\d+[.)])[ \\t]+)?(`{3,}|~{3,})(.*)$")
    private static let definition = Rx("^ {0,3}\\[\\^([^\\]\\s]+)\\]:[ \\t]?(.*)$")
    private static let numbersOnly = Rx("^[\\d.,\\s+\\-]*$")

    func run(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var segment: [String] = []
        var fence: (char: Character, count: Int)? = nil
        func flush() {
            if segment.isEmpty { return }
            output.append(scan(segment.joined(separator: "\n")))
            segment = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                output.append(line)
                if let match = InlineProtector.fenceOpen.first(line),
                   let marker = match.group(1, in: line), marker.first == open.char, marker.count >= open.count,
                   (match.group(2, in: line) ?? "").jsTrimmed.isEmpty {
                    fence = nil
                }
                index += 1
                continue
            }
            if let match = InlineProtector.fenceOpen.first(line), let marker = match.group(1, in: line) {
                let info = match.group(2, in: line) ?? ""
                if !(marker.first == "`" && info.contains("`")) {
                    flush()
                    output.append(line)
                    fence = (marker.first!, marker.count)
                    index += 1
                    continue
                }
            }
            if allowFootnotes, let match = InlineProtector.definition.first(line) {
                let label = match.group(1, in: line) ?? ""
                var body = [match.group(2, in: line) ?? ""]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if next.hasPrefix("    ") || next.hasPrefix("\t") {
                        body.append(next.hasPrefix("\t") ? String(next.dropFirst()) : String(next.dropFirst(4)))
                        index += 1
                    } else if next.jsTrimmed.isEmpty, index + 1 < lines.count,
                              lines[index + 1].hasPrefix("    ") || lines[index + 1].hasPrefix("\t") {
                        body.append("")
                        index += 1
                    } else {
                        break
                    }
                }
                if footnotes.definitions[label] == nil {
                    footnotes.definitions[label] = body.joined(separator: "\n").jsTrimmed
                }
                continue
            }
            segment.append(line)
            index += 1
        }
        flush()
        return output.joined(separator: "\n")
    }

    // MARK: scanning

    private func scan(_ text: String) -> String {
        let c = Array(text)
        let n = c.count
        var out = ""
        var i = 0
        var lineStart = 0

        func isBlankAhead(_ from: Int) -> Bool {
            // `from` is the index of a "\n"; is the next line blank?
            var k = from + 1
            while k < n, c[k] == " " || c[k] == "\t" { k += 1 }
            return k >= n || c[k] == "\n"
        }
        func slice(_ a: Int, _ b: Int) -> String { String(c[a..<b]) }

        while i < n {
            let ch = c[i]
            if ch == "\n" { out.append(ch); i += 1; lineStart = i; continue }

            if ch == "\\" {
                out.append(ch)
                if i + 1 < n { out.append(c[i + 1]) }
                i += 2
                continue
            }

            if ch == "`" {
                var run = 0
                while i + run < n, c[i + run] == "`" { run += 1 }
                var k = i + run
                var close = -1
                while k < n {
                    if c[k] == "`" {
                        var m = 0
                        while k + m < n, c[k + m] == "`" { m += 1 }
                        if m == run { close = k; break }
                        k += m
                        continue
                    }
                    if c[k] == "\n", isBlankAhead(k) { break }
                    k += 1
                }
                if close >= 0 {
                    out += slice(i, close + run)
                    i = close + run
                } else {
                    out += slice(i, i + run)
                    i += run
                }
                continue
            }

            // Link destinations, inline HTML and bare URLs are copied untouched.
            if ch == "]", i + 1 < n, c[i + 1] == "(" {
                var depth = 0
                var k = i + 1
                var end = -1
                while k < n, c[k] != "\n" {
                    if c[k] == "\\" { k += 2; continue }
                    if c[k] == "(" { depth += 1 }
                    if c[k] == ")" { depth -= 1; if depth == 0 { end = k; break } }
                    k += 1
                }
                if end >= 0 { out += slice(i, end + 1); i = end + 1; continue }
            }
            if ch == "<", i + 1 < n, c[i + 1].isLetter || c[i + 1] == "/" || c[i + 1] == "!" {
                var k = i + 1
                while k < n, c[k] != ">", c[k] != "\n", c[k] != "<" { k += 1 }
                if k < n, c[k] == ">" { out += slice(i, k + 1); i = k + 1; continue }
            }
            if ch == "h", slice(i, min(n, i + 8)).hasPrefix("http://") || slice(i, min(n, i + 8)).hasPrefix("https://"),
               i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber) {
                var k = i
                while k < n, !c[k].isWhitespace, c[k] != "<" { k += 1 }
                out += slice(i, k)
                i = k
                continue
            }

            if ch == "$" {
                if i + 1 < n, c[i + 1] == "$" {
                    var atLineStart = true
                    for k in lineStart..<i where c[k] != " " && c[k] != "\t" { atLineStart = false; break }
                    if atLineStart, let (content, end) = blockMath(c, i) {
                        out += "\n" + store.add(.blockMath(content)) + "\n"
                        i = end
                        continue
                    }
                    out.append(ch)
                    i += 1
                    continue
                }
                if let (content, end) = inlineMath(c, i) {
                    out += store.add(.inlineMath(content))
                    i = end
                    continue
                }
                out.append(ch)
                i += 1
                continue
            }

            if ch == "=", i + 1 < n, c[i + 1] == "=" {
                var close = -1
                var k = i + 2
                while k + 1 < n {
                    if c[k] == "\n" { break }
                    if c[k] == "=", c[k + 1] == "=" { close = k; break }
                    k += 1
                }
                if close > i + 2 {
                    out += store.add(.highlight(slice(i + 2, close)))
                    i = close + 2
                    continue
                }
                out.append(ch)
                i += 1
                continue
            }

            if ch == "[", i + 1 < n, c[i + 1] == "[" {
                var close = -1
                var k = i + 2
                while k + 1 < n {
                    if c[k] == "\n" { break }
                    if c[k] == "]", c[k + 1] == "]" { close = k; break }
                    k += 1
                }
                if close > i + 2 {
                    let body = slice(i + 2, close)
                    let bar = body.firstIndex(of: "|")
                    let target = (bar.map { String(body[..<$0]) } ?? body).jsTrimmed
                    let label = (bar.map { String(body[body.index(after: $0)...]) } ?? body).jsTrimmed
                    if !target.isEmpty {
                        out += store.add(.wikiLink(target: target, label: label.isEmpty ? target : label))
                        i = close + 2
                        continue
                    }
                }
            }

            if allowFootnotes, ch == "[", i + 1 < n, c[i + 1] == "^" {
                var k = i + 2
                while k < n, c[k] != "]", c[k] != "\n", c[k] != " ", c[k] != "\t" { k += 1 }
                if k < n, c[k] == "]", k > i + 2 {
                    let label = slice(i + 2, k)
                    if footnotes.definitions[label] != nil {
                        let ref = footnotes.reference(label)
                        out += store.add(.footnoteRef(number: ref.number, sub: ref.sub, label: label))
                        i = k + 1
                        continue
                    }
                }
            }

            if allowFootnotes, ch == "^", i + 1 < n, c[i + 1] == "[" {
                var k = i + 2
                var depth = 1
                while k < n, c[k] != "\n" {
                    if c[k] == "\\" { k += 2; continue }
                    if c[k] == "[" { depth += 1 }
                    if c[k] == "]" { depth -= 1; if depth == 0 { break } }
                    k += 1
                }
                if k < n, c[k] == "]", depth == 0, k > i + 2 {
                    footnotes.inlineCounter += 1
                    let label = "inline-\(footnotes.inlineCounter)"
                    footnotes.definitions[label] = slice(i + 2, k)
                    let ref = footnotes.reference(label)
                    out += store.add(.footnoteRef(number: ref.number, sub: ref.sub, label: label))
                    i = k + 1
                    continue
                }
            }

            out.append(ch)
            i += 1
        }
        return out
    }

    /// markdown.js `inline_math`: `$…$`, no space just inside, not a plain number.
    private func inlineMath(_ c: [Character], _ start: Int) -> (String, Int)? {
        let n = c.count
        var pos = start + 1
        guard pos < n else { return nil }
        if c[pos] == " " || c[pos] == "\t" || c[pos] == "\n" { return nil }
        while pos < n {
            let ch = c[pos]
            if ch == "\\" { pos += 2; continue }
            if ch == "\n" { return nil }
            if ch == "$" { break }
            pos += 1
        }
        if pos >= n || pos == start + 1 { return nil }
        if c[pos - 1] == " " || c[pos - 1] == "\t" { return nil }
        let content = String(c[(start + 1)..<pos])
        if InlineProtector.numbersOnly.test(content) { return nil }
        return (content, pos + 1)
    }

    /// markdown.js `block_math`: a line starting `$$` up to the first line ending `$$`.
    private func blockMath(_ c: [Character], _ start: Int) -> (String, Int)? {
        let n = c.count
        func lineEnd(_ from: Int) -> Int {
            var k = from
            while k < n, c[k] != "\n" { k += 1 }
            return k
        }
        var parts: [String] = []
        var end = lineEnd(start + 2)
        let first = String(c[(start + 2)..<end]).jsTrimmed
        if first.hasSuffix("$$") {
            parts.append(String(first.dropLast(2)))
            return (parts.joined(separator: "\n").jsTrimmed, end)
        }
        parts.append(String(c[(start + 2)..<end]))
        var k = end + 1
        while k <= n {
            end = lineEnd(k)
            if k > n { break }
            let text = String(c[min(k, n)..<end])
            if text.jsTrimmed.hasSuffix("$$") {
                parts.append(String(text.jsTrimmed.dropLast(2)))
                return (parts.joined(separator: "\n").jsTrimmed, end)
            }
            parts.append(text)
            if end >= n { break }
            k = end + 1
        }
        return nil
    }
}
