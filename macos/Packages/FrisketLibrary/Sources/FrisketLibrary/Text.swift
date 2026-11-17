import Foundation
import FrisketBase

// Everything in this file works on note text and reports UTF-16 offsets, the unit
// NSTextView uses. Port of the text helpers in src/main/workspace.js.

// MARK: - Masking

private func fenceMarker(_ line: String) -> (char: UInt8, length: Int)? {
    var spaces = 0
    var iterator = line.utf8.makeIterator()
    var current = iterator.next()
    while current == 32, spaces < 3 { spaces += 1; current = iterator.next() }
    guard let first = current, first == 96 || first == 126 else { return nil }
    var run = 1
    while let next = iterator.next(), next == first { run += 1 }
    return run >= 3 ? (first, run) : nil
}

private let inlineCodePattern = Rx(#"(`+)(?!`)[^`\n]*?\1(?!`)"#)

/// Blank out fenced code, indented code and inline code with spaces, keeping every
/// offset and line boundary intact.
public func maskCode(_ body: String) -> String {
    var fence: (char: UInt8, length: Int)? = nil
    var out: [String] = []
    for line in splitLines(body) {
        let marker = fenceMarker(line)
        let length = line.utf16.count
        if let open = fence {
            if let marker, marker.char == open.char, marker.length >= open.length { fence = nil }
            out.append(spaces(length))
            continue
        }
        if let marker { fence = marker; out.append(spaces(length)); continue }
        if line.utf8.starts(with: [32, 32, 32, 32]) { out.append(spaces(length)); continue }
        if line.utf8.contains(96) {
            out.append(inlineCodePattern.replace(line) { match, _ in spaces(match.range.length) })
        } else {
            out.append(line)
        }
    }
    return out.joined(separator: "\n")
}

private func blank(_ pattern: Rx, _ text: String) -> String {
    pattern.replace(text) { match, _ in spaces(match.range.length) }
}

private let escapedHash = Rx(##"\\#"##)
private let headingLine = Rx(#"^ {0,3}#{1,6}(?:\s|\z)[^\n]*"#, [.anchorsMatchLines])
private let htmlTag = Rx(#"<[^>]*>"#)
private let bareURL = Rx(#"(?:https?://|ftp://|www\.)[^\s<>()]+"#, [.caseInsensitive])

/// Mask non-prose regions (code, escaped hashes, headings, HTML, URLs) while keeping
/// offsets and line boundaries intact.
public func maskNonProse(_ body: String) -> String {
    maskNonProse(codeMasked: maskCode(body))
}

func maskNonProse(codeMasked: String) -> String {
    var text = codeMasked
    if text.utf8.contains(92) { text = blank(escapedHash, text) }
    if text.utf8.contains(35) { text = blank(headingLine, text) }
    if text.utf8.contains(60) { text = blank(htmlTag, text) }
    return blank(bareURL, text)
}

// MARK: - Tags and tasks

private let inlineTagPattern = Rx(#"(?:^|[^\p{L}\p{N}_/])#([\p{L}\p{N}_-]+(?:/[\p{L}\p{N}_-]+)*)(#?)(?![\p{L}\p{N}_/-])"#)

/// `#tags` in prose (not in headings, code, URLs, HTML or after a backslash), without the `#`.
public func extractInlineTags(_ body: String) -> [String] {
    inlineTags(inMasked: maskNonProse(body))
}

func inlineTags(inMasked text: String) -> [String] {
    let ns = text as NSString
    return inlineTagPattern.matches(ns).compactMap { $0.group(1, in: ns) }
}

private let taskPattern = Rx(#"^\s*(?:[-+*]|\d+[.)])\s+\[([ xX])\]"#, [.anchorsMatchLines])

/// Task-list items outside code: how many are checked, how many in all.
public func taskCounts(_ body: String) -> (done: Int, total: Int) {
    taskCounts(codeMasked: maskCode(body))
}

func taskCounts(codeMasked text: String) -> (done: Int, total: Int) {
    let ns = text as NSString
    var done = 0, total = 0
    for match in taskPattern.matches(ns) {
        total += 1
        if match.group(1, in: ns)?.lowercased() == "x" { done += 1 }
    }
    return (done, total)
}

// MARK: - Excerpt

private let excerptTask = Rx(#"^\s*(?:[-+*]|\d+[.)])\s+\[[ xX]\]\s*"#)
private let excerptRule = Rx(#"^\s{0,3}(?:[-*_]\s*){3,}\s*\z"#)
private let excerptLink = Rx(#"!?\[([^\]]*)\]\([^)]*\)"#)
private let excerptWiki = Rx(#"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#)
private let excerptMarks = Rx(#"(^|\s)[#>*_~`]+(?=\S)|[*_~`]+(?=\s|\z)"#)

/// The first line of prose, stripped of Markdown marks, at most 180 characters.
public func makeExcerpt(_ body: String) -> String {
    makeExcerpt(prose: maskNonProse(body))
}

func makeExcerpt(prose: String) -> String {
    var found = ""
    for rawLine in prose.components(separatedBy: CharacterSet(charactersIn: "\n")) {
        var line = rawLine
        if line.utf8.last == 13 { line.removeLast() }
        line = excerptTask.replace(line, template: "")
        line = excerptRule.replace(line, template: "")
        line = excerptLink.replace(line, template: "$1")
        line = excerptWiki.replace(line) { match, ns in
            if let label = match.group(2, in: ns), !label.isEmpty { return label }
            return match.group(1, in: ns) ?? ""
        }
        line = excerptMarks.replace(line, template: "$1").jsTrimmed
        if !line.isEmpty { found = line; break }
    }
    if found.utf16Length <= 180 { return found }
    return safeSlice(found, 0, 177).jsTrimmedEnd + "…"
}

// MARK: - Images and links

private func referenceLabel(_ label: String) -> String {
    Rx(#"\s+"#).replace(label.jsTrimmed, template: " ").lowercased()
}

private let inlineImage = Rx(#"!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))"#)
private let imageDefinition = Rx(#"^ {0,3}\[([^\]]+)\]:\s*(?:<([^>]+)>|([^\s]+))"#, [.anchorsMatchLines])
private let fullReferenceImage = Rx(#"!\[([^\]]*)\]\[([^\]]*)\]"#)
private let shortcutImage = Rx(#"!\[([^\]]+)\](?![\[(])"#)

/// Image references outside code: inline, reference-style and shortcut, de-duplicated in order.
public func extractImages(_ text: String) -> [String] {
    let searchable = maskCode(splitFrontMatter(text).body)
    let ns = searchable as NSString
    var refs: [String] = []
    for match in inlineImage.matches(ns) {
        refs.append(match.group(1, in: ns) ?? match.group(2, in: ns) ?? "")
    }
    var definitions: [String: String] = [:]
    for match in imageDefinition.matches(ns) {
        definitions[referenceLabel(match.group(1, in: ns) ?? "")] = match.group(2, in: ns) ?? match.group(3, in: ns) ?? ""
    }
    if !definitions.isEmpty {
        for match in fullReferenceImage.matches(ns) {
            let second = match.group(2, in: ns) ?? ""
            let label = second.isEmpty ? (match.group(1, in: ns) ?? "") : second
            if let source = definitions[referenceLabel(label)], !source.isEmpty { refs.append(source) }
        }
        for match in shortcutImage.matches(ns) {
            if let source = definitions[referenceLabel(match.group(1, in: ns) ?? "")], !source.isEmpty { refs.append(source) }
        }
    }
    var seen = Set<String>()
    return refs.filter { seen.insert($0).inserted }
}

/// A link found in a note body. `start` and `end` are UTF-16 offsets into the **body**
/// (the text after the front matter); add `ExtractedLinks.bodyOffset` for file offsets.
public struct NoteLink: Sendable, Hashable {
    public enum Kind: String, Sendable { case wiki, markdown }
    public var target: String
    public var start: Int
    public var end: Int
    public var kind: Kind
}

public struct ExtractedLinks: Sendable {
    public var links: [NoteLink]
    public var body: String
    /// UTF-16 offset of `body` within the whole text.
    public var bodyOffset: Int
}

private let wikiLinkPattern = Rx(#"\[\[([^\]]+)\]\]"#)
private let markdownLinkPattern = Rx(#"(?<!!)\[[^\]]*\]\(\s*(?:<([^>]+)>|((?:\\.|[^\s)])+))"#)
private let escapedParens = Rx(#"\\([()])"#)

/// Wiki links (`[[Target|label]]`) first, then Markdown links, outside code, in the body.
public func extractLinks(_ text: String) -> ExtractedLinks {
    let split = splitFrontMatter(text)
    let searchable = maskCode(split.body)
    let ns = searchable as NSString
    var links: [NoteLink] = []
    for match in wikiLinkPattern.matches(ns) {
        let inner = match.group(1, in: ns) ?? ""
        let raw = (inner.components(separatedBy: "|").first ?? "").jsTrimmed
        if !raw.isEmpty {
            links.append(NoteLink(target: raw, start: match.range.location, end: match.range.location + match.range.length, kind: .wiki))
        }
    }
    for match in markdownLinkPattern.matches(ns) {
        let target = match.group(1, in: ns) ?? match.group(2, in: ns) ?? ""
        if !target.isEmpty {
            links.append(NoteLink(target: escapedParens.replace(target, template: "$1"),
                                  start: match.range.location, end: match.range.location + match.range.length, kind: .markdown))
        }
    }
    return ExtractedLinks(links: links, body: split.body, bodyOffset: split.bodyOffset)
}

/// A link target split into the note name and an optional `#anchor`.
public struct LinkTargetParts: Sendable, Equatable {
    public var name: String
    public var anchor: String?
}

private let externalTarget = Rx(#"^(?:[a-z][a-z0-9+.-]+:|//)"#, [.caseInsensitive])
private let angleEdges = Rx(#"^<|>\z"#)

/// Split a raw link target; nil for URLs (a two-letter minimum scheme keeps `C:\notes\a.md` a path).
public func parseLinkTarget(_ rawTarget: String) -> LinkTargetParts? {
    let target = angleEdges.replace(rawTarget.jsTrimmed, template: "")
    if target.isEmpty || externalTarget.test(target) { return nil }
    let hash = target.firstIndex(of: "#")
    let beforeHash = hash.map { String(target[target.startIndex..<$0]) } ?? target
    let name = (beforeHash.components(separatedBy: "?").first ?? "").jsTrimmed
    var anchor: String? = nil
    if let hash {
        let rest = String(target[target.index(after: hash)...])
        anchor = rest.isEmpty ? nil : rest
    }
    return LinkTargetParts(name: name, anchor: anchor)
}

/// Rewrite the target of matching `[[wiki-links]]`, keeping any `#anchor` and `|alias`. Links in
/// code and front matter are left alone. When `alias` is given it is added to links that had
/// none, so the visible text stays readable.
public func rewriteWikiLinks(_ text: String, matching matchesName: (String) -> Bool,
                             replacement: String, alias: String? = nil) -> (text: String, count: Int) {
    let split = splitFrontMatter(text)
    let body = split.body
    let masked = maskCode(body) as NSString
    let bodyNS = body as NSString
    let pattern = Rx(#"\[\[([^\]\n]+)\]\]"#)
    var edits: [(from: Int, to: Int, insert: String)] = []
    for match in pattern.matches(masked) {
        let innerStart = match.range.location + 2
        let innerLength = match.range(at: 1).length
        let inner = bodyNS.substring(with: NSRange(location: innerStart, length: innerLength)) as NSString
        let bar = inner.range(of: "|", options: .literal)
        let targetPart: NSString = bar.location == NSNotFound ? inner : inner.substring(to: bar.location) as NSString
        let hash = targetPart.range(of: "#", options: .literal)
        let name = (hash.location == NSNotFound ? targetPart as String : targetPart.substring(to: hash.location)).jsTrimmed
        if name.isEmpty || !matchesName(name) { continue }
        var rest = hash.location == NSNotFound ? "" : targetPart.substring(from: hash.location)
        if bar.location == NSNotFound {
            if let alias, !alias.isEmpty { rest += "|" + alias }
        } else {
            rest += inner.substring(from: bar.location)
        }
        edits.append((split.bodyOffset + innerStart, split.bodyOffset + innerStart + innerLength, replacement + rest))
    }
    let out = NSMutableString(string: text)
    for edit in edits.reversed() {
        out.replaceCharacters(in: NSRange(location: edit.from, length: edit.to - edit.from), with: edit.insert)
    }
    return (out as String, edits.count)
}

/// The line around `pos`, trimmed to at most about 180 characters with ellipses.
public func excerptAt(_ text: String, pos: Int, termLength: Int = 0) -> String {
    excerptAt(Array(text.utf16), pos: pos, termLength: termLength)
}

func excerptAt(_ units: [UInt16], pos: Int, termLength: Int = 0) -> String {
    let lineStart = lastIndexOf(units, 10, from: Swift.max(0, pos - 1)) + 1
    var lineEnd = indexOf(units, [10], from: pos + termLength)
    if lineEnd < 0 { lineEnd = units.count }
    let line = Array(string16(slice16(units, lineStart, lineEnd)).jsTrimmed.utf16)
    if line.count <= 180 { return string16(line) }
    let offset = Swift.max(0, pos - lineStart - 65)
    let piece = string16(slice16(line, offset, offset + 150)).jsTrimmed
    return (offset > 0 ? "…" : "") + piece + (offset + 150 < line.count ? "…" : "")
}

// MARK: - Search queries

/// A search split into plain terms and the `#tag`, `@todo` and `@images` operators.
public struct SearchQuery: Sendable, Equatable {
    public var terms: [String] = []
    public var tags: [String] = []
    public var todo = false
    public var images = false
    public init(terms: [String] = [], tags: [String] = [], todo: Bool = false, images: Bool = false) {
        self.terms = terms; self.tags = tags; self.todo = todo; self.images = images
    }
}

private let todoOperator = Rx(#"(?:^|\s)@todo(?=\s|\z)"#, [.caseInsensitive])
private let imagesOperator = Rx(#"(?:^|\s)@images(?=\s|\z)"#, [.caseInsensitive])
private let tagOperator = Rx(#"(?:^|\s)#([\p{L}\p{N}_-]+(?:/[\p{L}\p{N}_-]+)*)(#?)(?=\s|\z)"#)
private let anyOperator = Rx(#"(?:^|\s)@(?:todo|images)(?=\s|\z)"#, [.caseInsensitive])
private let anyTagOperator = Rx(#"(?:^|\s)#[\p{L}\p{N}_-]+(?:/[\p{L}\p{N}_-]+)*#?(?=\s|\z)"#)

public func parseSearchQuery(_ query: String = "") -> SearchQuery {
    let raw = query.jsTrimmed
    let ns = raw as NSString
    var parsed = SearchQuery()
    parsed.todo = todoOperator.test(raw)
    parsed.images = imagesOperator.test(raw)
    parsed.tags = tagOperator.matches(ns).compactMap { $0.group(1, in: ns) }
    let stripped = anyTagOperator.replace(anyOperator.replace(raw, template: " "), template: " ")
    parsed.terms = stripped.jsTrimmed.lowercased()
        .split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return parsed
}

/// Where a search hit is in a note's text. `pos` is a UTF-16 offset and `line` is 1-based,
/// both for the whole file; `column` is relative to the line (body line).
public struct SearchMatch: Sendable, Hashable {
    public var line: Int
    public var column: Int
    public var pos: Int
    public var length: Int
    public var text: String
    public var snippetOffset: Int
}

private let firstOpenTask = Rx(#"^\s*(?:[-+*]|\d+[.)])\s+\[ \]"#, [.anchorsMatchLines])
private let nonSpace = Rx(#"\S"#)

/// The first plain term in the body, else the first open task (`@todo`), tag or image, else
/// the first body line.
public func findSearchMatch(_ source: String, query: SearchQuery) -> SearchMatch {
    let split = splitFrontMatter(source)
    let body = split.body
    let bodyUnits = Array(body.utf16)
    let offset = split.bodyOffset
    var at = -1
    var length = 0
    if let term = query.terms.first {
        let needle = Array(term.utf16)
        at = indexOf(Array(body.lowercased().utf16), needle)
        length = needle.count
    }
    if at < 0, query.todo {
        let masked = maskCode(body)
        if let task = firstOpenTask.first(masked) {
            at = task.range.location + task.range.length - 3
            length = 3
        }
    }
    if at < 0, let tag = query.tags.first {
        let prose = maskNonProse(body)
        let pattern = Rx("#" + Rx.escape(tag), [.caseInsensitive])
        if let hit = pattern.first(prose) { at = hit.range.location; length = hit.range.length }
    }
    if at < 0, query.images {
        let masked = maskCode(body) as NSString
        let range = masked.range(of: "![", options: .literal)
        if range.location != NSNotFound { at = range.location; length = 2 }
    }
    if at < 0 {
        at = nonSpace.first(body)?.range.location ?? 0
        length = 0
    }
    let lineStart = lastIndexOf(bodyUnits, 10, from: at - 1) + 1
    var lineEnd = indexOf(bodyUnits, [10], from: at)
    if lineEnd < 0 { lineEnd = bodyUnits.count }
    var lineUnits = slice16(bodyUnits, lineStart, lineEnd)
    if lineUnits.last == 13 { lineUnits.removeLast() }
    let column = at - lineStart
    let long = lineUnits.count > 160
    let snippetOffset = long ? Swift.max(0, column - 40) : 0
    let sourceUnits = Array(source.utf16)
    var newlines = 0
    for unit in sourceUnits.prefix(Swift.max(0, offset + lineStart)) where unit == 10 { newlines += 1 }
    return SearchMatch(
        line: newlines + 1, column: column, pos: offset + at, length: length,
        text: string16(long ? slice16(lineUnits, snippetOffset, column + 120) : lineUnits),
        snippetOffset: snippetOffset
    )
}
