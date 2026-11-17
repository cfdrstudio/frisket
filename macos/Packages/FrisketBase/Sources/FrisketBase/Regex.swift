import Foundation

/// A compiled `NSRegularExpression` with the handful of operations the ports of
/// the JavaScript code need. Offsets are UTF-16 (`NSString`) offsets throughout
/// Frisket, the same unit `NSTextView` uses, so positions computed here can be
/// handed straight to the editor.
///
/// JavaScript → ICU notes for porting: `\p{L}`, lookbehind and lazy quantifiers
/// work as in JS. Without `.anchorsMatchLines`, `^` is the start of the input;
/// `$` is the end of the input but ICU also accepts it just before a final line
/// terminator. `.` matches neither `\n` nor `\r` (JS `.` matches `\r`).
public struct Rx: @unchecked Sendable {
    public let regex: NSRegularExpression

    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            fatalError("Invalid regular expression \(pattern): \(error)")
        }
    }

    /// Every match in `string`, or in `range` of it.
    public func matches(_ string: String, range: NSRange? = nil) -> [NSTextCheckingResult] {
        let ns = string as NSString
        return regex.matches(in: string, options: [], range: range ?? NSRange(location: 0, length: ns.length))
    }

    public func matches(_ string: NSString, range: NSRange? = nil) -> [NSTextCheckingResult] {
        regex.matches(in: string as String, options: [], range: range ?? NSRange(location: 0, length: string.length))
    }

    public func first(_ string: String, range: NSRange? = nil) -> NSTextCheckingResult? {
        let ns = string as NSString
        return regex.firstMatch(in: string, options: [], range: range ?? NSRange(location: 0, length: ns.length))
    }

    public func first(_ string: NSString, range: NSRange? = nil) -> NSTextCheckingResult? {
        regex.firstMatch(in: string as String, options: [], range: range ?? NSRange(location: 0, length: string.length))
    }

    public func test(_ string: String) -> Bool { first(string) != nil }

    /// Replace every match with the string `transform` returns for it.
    public func replace(_ string: String, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = string as NSString
        let found = matches(string)
        if found.isEmpty { return string }
        let out = NSMutableString()
        var cursor = 0
        for match in found {
            out.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            out.append(transform(match, ns))
            cursor = match.range.location + match.range.length
        }
        out.append(ns.substring(from: cursor))
        return out as String
    }

    /// Replace every match with an ICU template (`$1` refers to group 1).
    public func replace(_ string: String, template: String) -> String {
        let ns = string as NSString
        return regex.stringByReplacingMatches(in: string, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    /// Escape `text` for use as a literal inside a pattern.
    public static func escape(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: text)
    }
}

public extension NSTextCheckingResult {
    /// The text of capture group `index`, or nil when the group did not take part.
    func group(_ index: Int, in string: NSString) -> String? {
        guard index < numberOfRanges else { return nil }
        let range = self.range(at: index)
        return range.location == NSNotFound ? nil : string.substring(with: range)
    }

    func group(_ index: Int, in string: String) -> String? {
        group(index, in: string as NSString)
    }
}

public extension String {
    /// Length in UTF-16 code units, the unit of every Frisket offset.
    var utf16Length: Int { (self as NSString).length }

    /// Substring by UTF-16 range, clamped to the string.
    func utf16Slice(_ from: Int, _ to: Int? = nil) -> String {
        let ns = self as NSString
        let start = Swift.max(0, Swift.min(from, ns.length))
        let end = Swift.max(start, Swift.min(to ?? ns.length, ns.length))
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// JavaScript's `String.prototype.trim()`: strips whitespace and line terminators.
    var jsTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
