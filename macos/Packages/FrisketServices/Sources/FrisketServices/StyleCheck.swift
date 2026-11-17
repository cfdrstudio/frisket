import Foundation
import FrisketBase

/// One advisory finding of the style check. Offsets are UTF-16, ready for `NSTextView`.
public struct StyleFinding: Equatable, Sendable {
    public enum Kind: String, Sendable { case repeatedWord = "repeated-word", wordiness }
    /// Start offset (UTF-16).
    public var from: Int
    /// End offset (UTF-16, exclusive).
    public var to: Int
    public var kind: Kind
    public var message: String
    public var suggestion: String?

    public var range: NSRange { NSRange(location: from, length: to - from) }
}

/// Deterministic, advisory writing diagnostics (repeated words, wordy phrases)
/// and template placeholders. Front matter, fenced and inline code and raw
/// HTML lines are ignored. Port of writingTools.mjs.
public enum StyleCheck {
    private struct Filler {
        var pattern: Rx
        var suggestion: String?
    }

    private static let fillers: [Filler] = [
        Filler(pattern: Rx("\\bin order to\\b", [.caseInsensitive]), suggestion: "to"),
        Filler(pattern: Rx("\\bdue to the fact that\\b", [.caseInsensitive]), suggestion: "because"),
        Filler(pattern: Rx("\\bat this point in time\\b", [.caseInsensitive]), suggestion: "now"),
        Filler(pattern: Rx("\\b(very|really|quite)\\s+([\\p{L}\\p{N}_-]+)", [.caseInsensitive]), suggestion: nil),
    ]
    private static let repeatedWord = Rx("\\b(\\p{L}[\\p{L}\\p{N}'’-]*)\\s+\\1\\b", [.caseInsensitive])
    private static let htmlLine = Rx("</?[A-Za-z][^>]*>|<!--|-->", [.caseInsensitive])
    private static let inlineCode = Rx("(`+).*?\\1")
    private static let fenceMarker = Rx("^ {0,3}(`{3,}|~{3,})")

    private static func mask(_ chars: inout [UInt16], _ start: Int, _ end: Int) {
        var i = max(0, start)
        while i < min(end, chars.count) {
            if chars[i] != 10 && chars[i] != 13 { chars[i] = 32 }
            i += 1
        }
    }

    /// Lines including their `\n` / `\r\n` terminator, as (UTF-16 offset, text).
    private static func lines(_ text: NSString) -> [(offset: Int, text: String)] {
        var out: [(Int, String)] = []
        var start = 0
        var i = 0
        let length = text.length
        while i < length {
            if text.character(at: i) == 10 {
                out.append((start, text.substring(with: NSRange(location: start, length: i + 1 - start))))
                start = i + 1
            }
            i += 1
        }
        if start < length { out.append((start, text.substring(from: start))) }
        return out
    }

    private static func content(_ line: String) -> String {
        if line.hasSuffix("\r\n") { return String(line.dropLast(2)) }
        if line.hasSuffix("\n") { return String(line.dropLast()) }
        return line
    }

    private static func maskFrontMatter(_ chars: inout [UInt16], _ text: String) {
        let ns = text as NSString
        guard let opening = Rx("^---\\r?\\n").first(ns) else { return }
        let start = opening.range.length
        guard let match = Rx("^(?:---|\\.\\.\\.)(?:\\r?\\n|$)", [.anchorsMatchLines])
            .first(ns, range: NSRange(location: start, length: ns.length - start)) else { return }
        mask(&chars, 0, match.range.location + match.range.length)
    }

    private static func maskFencedCode(_ chars: inout [UInt16], _ text: String) {
        var fence: (char: String, length: Int)?
        for (offset, line) in lines(text as NSString) {
            let body = content(line)
            let marker = fenceMarker.first(body)
            if fence == nil, let marker, let run = marker.group(1, in: body) {
                fence = (String(run.prefix(1)), run.utf16Length)
                mask(&chars, offset, offset + line.utf16Length)
            } else if let open = fence {
                let close = Rx("^ {0,3}" + Rx.escape(open.char) + "{\(open.length),}\\s*\\z").test(body)
                mask(&chars, offset, offset + line.utf16Length)
                if close { fence = nil }
            }
        }
    }

    private static func maskInlineCodeAndHTML(_ chars: inout [UInt16], _ text: String) {
        for (offset, line) in lines(text as NSString) {
            let body = content(line)
            // Raw HTML lines are authored markup: no diagnostics on script/style payloads.
            if htmlLine.test(body) {
                mask(&chars, offset, offset + line.utf16Length)
                continue
            }
            for match in inlineCode.matches(body) {
                mask(&chars, offset + match.range.location, offset + match.range.location + match.range.length)
            }
        }
    }

    /// Findings in `text`, ordered by position.
    public static func analyze(_ text: String) -> [StyleFinding] {
        var chars = Array(text.utf16)
        maskFrontMatter(&chars, text)
        maskFencedCode(&chars, text)
        maskInlineCodeAndHTML(&chars, text)
        let searchable = String(decoding: chars, as: UTF16.self)
        let ns = searchable as NSString
        var results: [StyleFinding] = []

        for match in repeatedWord.matches(ns) {
            let word = match.group(1, in: ns) ?? ""
            let start = match.range.location
            let firstLength = word.utf16Length
            let tail = ns.substring(with: NSRange(location: start + firstLength, length: match.range.length - firstLength))
            let gap = tail.utf16Length - Rx("^\\s*").replace(tail, template: "").utf16Length
            let secondStart = start + firstLength + gap
            results.append(StyleFinding(from: start, to: secondStart + firstLength, kind: .repeatedWord,
                                        message: "“\(word)” is repeated.", suggestion: word))
        }
        for filler in fillers {
            for match in filler.pattern.matches(ns) {
                let phrase = ns.substring(with: match.range)
                results.append(StyleFinding(
                    from: match.range.location, to: match.range.location + match.range.length, kind: .wordiness,
                    message: filler.suggestion.map { "This phrase can be shorter: “\($0)”." } ?? "Consider whether “\(phrase)” adds meaning.",
                    suggestion: filler.suggestion))
            }
        }
        return results.enumerated().sorted { l, r in
            if l.element.from != r.element.from { return l.element.from < r.element.from }
            if l.element.to != r.element.to { return l.element.to < r.element.to }
            return l.offset < r.offset
        }.map(\.element)
    }

    /// Interpolate `{{title}}`, `{{selection}}`, `{{date}}` (`YYYY-MM-DD`) and
    /// `{{time}}` (`HH:mm`, local time). Unknown tokens and replacement values are left alone.
    public static func applyTemplate(_ template: String, title: String = "", selection: String = "", now: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let values = [
            "title": title,
            "selection": selection,
            "date": String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            "time": String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0),
        ]
        return Rx("\\{\\{(title|selection|date|time)\\}\\}").replace(template) { match, ns in
            values[match.group(1, in: ns) ?? ""] ?? ""
        }
    }
}
