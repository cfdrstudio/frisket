import Foundation

/// A front-matter value, as the small YAML subset in workspace.js reads it.
public enum FMValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([FMValue])

    /// The value as JavaScript's `String(value)` would print it.
    public var text: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case .list(let items): return items.map(\.text).joined(separator: ",")
        }
    }

    /// The string, when this is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var listValue: [FMValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    /// JavaScript truthiness: non-empty strings, non-zero numbers, true, any list.
    public var isTruthy: Bool {
        switch self {
        case .string(let value): return !value.isEmpty
        case .number(let value): return value != 0 && !value.isNaN
        case .bool(let value): return value
        case .list: return true
        }
    }
}

public typealias FMProperties = [String: FMValue]

private let frontMatterPattern = Rx("^---\\r?\\n([\\s\\S]*?)\\r?\\n---\\r?\\n?")

/// Split a note into its front-matter text and body. `bodyOffset` is the UTF-16
/// offset of the body in `text` (JavaScript's `text.length - body.length`).
public func splitFrontMatter(_ text: String) -> (metaText: String, body: String, bodyOffset: Int) {
    let ns = text as NSString
    guard let match = frontMatterPattern.first(ns) else { return ("", text, 0) }
    let end = match.range.location + match.range.length
    return (match.group(1, in: ns) ?? "", ns.substring(from: end), end)
}

private let numberPattern = Rx("^-?(?:\\d+\\.?\\d*|\\.\\d+)$")
private let trailingComment = Rx("\\s+#.*$")

/// One scalar: null (nil), quoted string, boolean, number or bare string.
public func frontMatterScalar(_ value: String) -> FMValue? {
    let text = value.jsTrimmed
    if text.isEmpty || text == "null" || text == "~" { return nil }
    if text.count >= 2, (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
        let inner = String(text.dropFirst().dropLast())
        if text.hasPrefix("\"") {
            return .string(Rx("\\\\([\"\\\\])").replace(inner, template: "$1"))
        }
        return .string(inner.replacingOccurrences(of: "''", with: "'"))
    }
    if text.lowercased() == "true" { return .bool(true) }
    if text.lowercased() == "false" { return .bool(false) }
    if numberPattern.test(text), let number = Double(text) { return .number(number) }
    return .string(trailingComment.replace(text, template: "").jsTrimmed)
}

/// Split `[a, "b, c", d]` (brackets optional) into scalars, honouring quotes.
public func splitInlineList(_ value: String) -> [FMValue] {
    var body = value.jsTrimmed
    if body.hasPrefix("[") { body.removeFirst() }
    if body.hasSuffix("]") { body.removeLast() }
    var items: [String] = []
    var current = ""
    var quote: Character? = nil
    var previous: Character? = nil
    for char in body {
        if let open = quote {
            current.append(char)
            if char == open && previous != "\\" { quote = nil }
        } else if char == "\"" || char == "'" {
            quote = char
            current.append(char)
        } else if char == "," {
            if !current.jsTrimmed.isEmpty { items.append(current.jsTrimmed) }
            current = ""
        } else {
            current.append(char)
        }
        previous = char
    }
    if !current.jsTrimmed.isEmpty { items.append(current.jsTrimmed) }
    return items.compactMap(frontMatterScalar).filter { $0 != .string("") }
}

private let listItemPattern = Rx("^\\s+-\\s+(.+?)\\s*$")
private let fieldPattern = Rx("^([A-Za-z0-9_.-]+)\\s*:\\s*(.*?)\\s*$")
private let leadingHash = Rx("^#")

/// Parse front-matter text into properties and tags (the `tags` key is pulled
/// out into `tags`, without `#`, de-duplicated case-insensitively).
public func parseFrontMatter(_ metaText: String) -> (properties: FMProperties, tags: [String]) {
    var properties: FMProperties = [:]
    var tags: [String] = []
    var listKey: String? = nil
    let lines = Rx("\\r?\\n").regex.stringByReplacingMatches(in: metaText, range: NSRange(location: 0, length: metaText.utf16Length), withTemplate: "\n")
        .components(separatedBy: "\n")
    for line in lines {
        if let item = listItemPattern.first(line), let key = listKey {
            if let value = frontMatterScalar(item.group(1, in: line) ?? ""), value != .string("") {
                if key == "tags" {
                    tags.append(leadingHash.replace(value.text, template: ""))
                } else if case .list(var items) = properties[key] {
                    items.append(value)
                    properties[key] = .list(items)
                }
            }
            continue
        }
        guard let field = fieldPattern.first(line) else { listKey = nil; continue }
        let key = field.group(1, in: line) ?? ""
        let value = field.group(2, in: line) ?? ""
        listKey = nil
        if key == "tags" {
            if value.hasPrefix("[") {
                tags.append(contentsOf: splitInlineList(value).map { leadingHash.replace($0.text, template: "") })
            } else if !value.isEmpty {
                tags.append(contentsOf: value.components(separatedBy: ",")
                    .compactMap { frontMatterScalar($0) }
                    .map { leadingHash.replace($0.text, template: "") }
                    .filter { !$0.isEmpty })
            } else {
                listKey = key
            }
            continue
        }
        if value.isEmpty { properties[key] = .list([]); listKey = key; continue }
        if value.hasPrefix("[") && value.hasSuffix("]") { properties[key] = .list(splitInlineList(value)); continue }
        if let parsed = frontMatterScalar(value) { properties[key] = parsed }
    }
    return (properties, uniqueTags(tags))
}

/// Set a top-level front-matter key to a scalar `value`, or remove it when
/// `value` is nil. Every other line, the line endings and the body are kept
/// exactly; a list or block value under the key is removed with it. Removing
/// the only key drops a front-matter block that holds nothing else.
public func setFrontMatterValue(_ text: String, key: String, value: String?) -> String {
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    let ns = text as NSString
    let block = Rx("^---\\r?\\n([\\s\\S]*?)\\r?\\n---(\\r?\\n|$)")
    let keyLine = Rx("^" + Rx.escape(key) + "\\s*:")
    let line = value.map { key + ": " + $0 }
    guard let match = block.first(ns), match.range.location == 0 else {
        if let line { return "---" + newline + line + newline + "---" + newline + newline + text }
        return text
    }
    let inner = match.group(1, in: ns) ?? ""
    let lines = inner.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    var kept: [String] = []
    var index = 0
    let continuation = Rx("^(?:\\s+\\S|\\s*-\\s)")
    while index < lines.count {
        if !keyLine.test(lines[index]) { kept.append(lines[index]); index += 1; continue }
        while index + 1 < lines.count && continuation.test(lines[index + 1]) { index += 1 }
        index += 1
    }
    if let line { kept.append(line) }
    let rest = ns.substring(from: match.range.location + match.range.length)
    if !kept.contains(where: { !$0.jsTrimmed.isEmpty }) {
        return Rx("^\\r?\\n").replace(rest, template: "")
    }
    let closing = match.group(2, in: ns).flatMap { $0.isEmpty ? nil : $0 } ?? newline
    return "---" + newline + kept.joined(separator: newline) + newline + "---" + closing + rest
}

private let firstHeading = Rx("^#\\s+(.+)$", [.anchorsMatchLines])

/// A note's title: front-matter `title`, else its first `# ` heading, else `fallback`.
public func noteTitle(_ text: String, fallback: String, properties: FMProperties) -> String {
    if case .string(let title)? = properties["title"], !title.jsTrimmed.isEmpty { return title.jsTrimmed }
    let body = splitFrontMatter(text).body
    if let heading = firstHeading.first(body), let title = heading.group(1, in: body) { return title.jsTrimmed }
    return fallback
}

/// Front-matter `aliases` (or `alias`) as display strings.
public func aliasesOf(_ properties: FMProperties) -> [String] {
    let raw = properties["aliases"] ?? properties["alias"]
    let list: [String]
    switch raw {
    case .list(let items)?: list = items.map(\.text)
    case .string(let value)?: list = value.components(separatedBy: ",")
    default: list = []
    }
    return list.map(\.jsTrimmed).filter { !$0.isEmpty }
}
