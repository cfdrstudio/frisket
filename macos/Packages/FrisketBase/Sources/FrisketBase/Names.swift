import Foundation

/// Comparison key for names, titles and aliases: Unicode- and case-insensitive,
/// with runs of whitespace collapsed. Port of `nameKey` in workspace.js.
public func nameKey(_ value: String) -> String {
    let nfc = value.precomposedStringWithCanonicalMapping.jsTrimmed
    return Rx("\\s+").replace(nfc, template: " ").lowercased()
}

private let tagEdges = Rx("^#|#$")

/// A tag without its leading/closing `#`, NFC-normalised and lower-cased.
public func normalizedTag(_ tag: String) -> String {
    tagEdges.replace(tag.jsTrimmed, template: "").precomposedStringWithCanonicalMapping.lowercased()
}

/// Tags without `#` marks, first spelling kept, case-variants dropped.
public func uniqueTags(_ tags: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for raw in tags {
        let tag = tagEdges.replace(raw.jsTrimmed, template: "")
        let key = tag.precomposedStringWithCanonicalMapping.lowercased()
        if tag.isEmpty || seen.contains(key) { continue }
        seen.insert(key)
        out.append(tag)
    }
    return out
}

/// Is `tag` the same as `selected`, or nested below it (`work/projects` under `work`)?
public func isDescendantTag(_ tag: String, of selected: String) -> Bool {
    let candidate = normalizedTag(tag)
    let parent = normalizedTag(selected)
    return candidate == parent || candidate.hasPrefix(parent + "/")
}

/// ISO-8601 with milliseconds and `Z`, the format JavaScript's `toISOString()` writes.
public func isoTimestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

/// Parse an ISO-8601 timestamp with or without fractional seconds, or a plain `YYYY-MM-DD` date.
public func parseISODate(_ text: String) -> Date? {
    let value = text.jsTrimmed
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: value) { return date }
    let day = ISO8601DateFormatter()
    day.formatOptions = [.withFullDate]
    return day.date(from: value)
}

/// A fresh note id, the same shape as `crypto.randomUUID()` (lower-case).
public func newNoteID() -> String { UUID().uuidString.lowercased() }
