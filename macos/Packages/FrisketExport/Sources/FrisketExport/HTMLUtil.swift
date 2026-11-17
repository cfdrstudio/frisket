import Foundation
import FrisketBase

/// Escape text for HTML content and double-quoted attributes (markdown.js `escapeHtml`).
public func escapeHTML(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for ch in text.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out
}

/// Readable, stable heading id from text (exportDoc.js `headingSlug`).
/// Duplicates are disambiguated by the caller.
public func headingSlug(_ text: String) -> String {
    let decomposed = text.decomposedStringWithCompatibilityMapping
    var stripped = String.UnicodeScalarView()
    for scalar in decomposed.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
        stripped.append(scalar)
    }
    var slug = Rx("[^a-z0-9]+").replace(String(stripped).lowercased(), template: "-")
    slug = Rx("^-+|-+$").replace(slug, template: "")
    return slug.isEmpty ? "section" : slug
}

/// JavaScript's `encodeURIComponent`.
func encodeURIComponent(_ text: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
}

/// A number the way JavaScript prints it in string concatenation (`0.6`, `1`, not `1.0`).
func jsNumber(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
}

/// Decode the handful of HTML entities that matter when turning HTML back into text.
func decodeHTMLEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}",
        "copy": "\u{a9}", "reg": "\u{ae}", "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201c}", "rdquo": "\u{201d}",
    ]
    return Rx("&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);").replace(text) { match, ns in
        let body = match.group(1, in: ns) ?? ""
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            if let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
        } else if body.hasPrefix("#") {
            if let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
        } else if let value = named[body] {
            return value
        }
        return ns.substring(with: match.range)
    }
}
