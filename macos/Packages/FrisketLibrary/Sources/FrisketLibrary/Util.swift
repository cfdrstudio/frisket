import Foundation
import FrisketBase

// MARK: - Paths (POSIX, string based, no symlink resolution unless stated)

/// Resolve `.` and `..` and make the path absolute. Unlike `NSString.standardizingPath`
/// this never strips a leading `/private`.
func normalizedPath(_ path: String) -> String {
    var raw = path
    if !raw.hasPrefix("/") { raw = FileManager.default.currentDirectoryPath + "/" + raw }
    var stack: [Substring] = []
    for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == ".." { if !stack.isEmpty { stack.removeLast() }; continue }
        stack.append(part)
    }
    return "/" + stack.joined(separator: "/")
}

/// `path.resolve(base, name)`.
func resolvePath(_ base: String, _ name: String) -> String {
    name.hasPrefix("/") ? normalizedPath(name) : normalizedPath(base + "/" + name)
}

func dirName(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "." }
    if slash == path.startIndex { return "/" }
    return String(path[path.startIndex..<slash])
}

func baseName(_ path: String) -> String {
    var trimmed = Substring(path)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    guard let slash = trimmed.lastIndex(of: "/") else { return String(trimmed) }
    return String(trimmed[trimmed.index(after: slash)...])
}

/// Node's `path.extname`, including the dot ("" when none).
func extName(_ name: String) -> String {
    let base = baseName(name)
    guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
    return String(base[dot...])
}

/// `path.relative(root, path)` for absolute paths ("" when equal).
func relativePath(from root: String, to path: String) -> String {
    let a = normalizedPath(root).split(separator: "/")
    let b = normalizedPath(path).split(separator: "/")
    var common = 0
    while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
    let parts = Array(repeating: "..", count: a.count - common) + b[common...].map(String.init)
    return parts.joined(separator: "/")
}

/// Is `candidate` equal to or below `root`? Plain path comparison.
func pathIsInside(_ root: String, _ candidate: String) -> Bool {
    let rel = relativePath(from: root, to: candidate)
    return rel.isEmpty || (rel != ".." && !rel.hasPrefix("../") && !rel.hasPrefix("/"))
}

/// `realpath(3)`: the resolved path, or nil with `errno` set.
func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

// MARK: - Strings

/// Compare as JavaScript's `a === b`: by code units, not Unicode canonical equivalence.
func sameText(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

func spaces(_ count: Int) -> String { String(repeating: " ", count: count) }

/// `text.split('\n')`.
func splitLines(_ text: String) -> [String] {
    text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
}

/// A UTF-16 slice that never splits a surrogate pair at its end (JavaScript would leave a lone surrogate).
func safeSlice(_ text: String, _ from: Int, _ to: Int) -> String {
    let ns = text as NSString
    var end = Swift.max(0, Swift.min(to, ns.length))
    let start = Swift.max(0, Swift.min(from, end))
    if end > start, end < ns.length, UTF16.isLeadSurrogate(ns.character(at: end - 1)) { end -= 1 }
    return ns.substring(with: NSRange(location: start, length: end - start))
}

extension String {
    /// `trimEnd()`.
    var jsTrimmedEnd: String {
        var scalars = Substring(self)
        while let last = scalars.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars = scalars.dropLast()
        }
        return String(scalars)
    }
}

func localeCompare(_ a: String, _ b: String) -> Int {
    switch a.compare(b, options: [], range: nil, locale: .current) {
    case .orderedAscending: return -1
    case .orderedSame: return 0
    case .orderedDescending: return 1
    }
}

func numericCompare(_ a: String, _ b: String) -> Int {
    switch a.localizedStandardCompare(b) {
    case .orderedAscending: return -1
    case .orderedSame: return 0
    case .orderedDescending: return 1
    }
}

extension Array {
    /// A stable sort; `compare` returns negative, zero or positive.
    func stableSorted(by compare: (Element, Element) -> Int) -> [Element] {
        enumerated().sorted { left, right in
            let order = compare(left.element, right.element)
            return order != 0 ? order < 0 : left.offset < right.offset
        }.map(\.element)
    }
}

// MARK: - UTF-16 helpers (JavaScript string semantics)

func indexOf(_ hay: [UInt16], _ needle: [UInt16], from: Int = 0) -> Int {
    let start = Swift.max(0, from)
    if needle.isEmpty { return Swift.min(start, hay.count) }
    if hay.count < needle.count { return -1 }
    var i = start
    let last = hay.count - needle.count
    while i <= last {
        if hay[i] == needle[0] {
            var j = 1
            while j < needle.count, hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
        }
        i += 1
    }
    return -1
}

/// `lastIndexOf(unit, from)`; `from` below zero is treated as zero, as JavaScript does.
func lastIndexOf(_ hay: [UInt16], _ unit: UInt16, from: Int) -> Int {
    if hay.isEmpty { return -1 }
    var i = Swift.min(Swift.max(0, from), hay.count - 1)
    while i >= 0 {
        if hay[i] == unit { return i }
        i -= 1
    }
    return -1
}

/// `slice(from, to)`.
func slice16(_ units: [UInt16], _ from: Int, _ to: Int? = nil) -> [UInt16] {
    let count = units.count
    func clamp(_ v: Int) -> Int { v < 0 ? Swift.max(0, count + v) : Swift.min(v, count) }
    let start = clamp(from)
    let end = clamp(to ?? count)
    return start >= end ? [] : Array(units[start..<end])
}

func string16(_ units: [UInt16]) -> String { String(decoding: units, as: UTF16.self) }

func isWordUnit(_ unit: UInt16) -> Bool {
    if unit == 95 { return true }
    guard let scalar = Unicode.Scalar(unit) else { return false }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .decimalNumber, .letterNumber, .otherNumber:
        return true
    default:
        return false
    }
}

// MARK: - Dates

func msSinceEpoch(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
func dateFromMs(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

/// Days since 1970-01-01 → (year, month, day) in the proleptic Gregorian calendar.
func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
    let z = days + 719468
    let era = floorDiv(z, 146097)
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

func daysFromCivil(_ year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = floorDiv(y, 400)
    let yoe = y - era * 400
    let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

private func pad(_ value: Int64, _ width: Int) -> String {
    let text = String(value)
    return String(repeating: "0", count: Swift.max(0, width - text.count)) + text
}

/// `new Date(ms).toISOString()` with `separator` between the clock fields (":" for ISO).
func isoString(ms: Int64, clockSeparator: String = ":", millisSeparator: String = ".") -> String {
    let day = floorDiv(ms, 86_400_000)
    let inDay = ms - day * 86_400_000
    let (y, m, d) = civilFromDays(day)
    let hh = inDay / 3_600_000, mm = (inDay / 60_000) % 60, ss = (inDay / 1000) % 60, mmm = inDay % 1000
    return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(hh, 2))\(clockSeparator)\(pad(mm, 2))\(clockSeparator)\(pad(ss, 2))\(millisSeparator)\(pad(mmm, 3))Z"
}

/// Parse a front-matter date the way the library needs: ISO forms via FrisketBase, then
/// zone-less local forms (`2024-01-02T03:04:05`, `2024-01-02 03:04`).
func parseLooseDate(_ text: String) -> Date? {
    if let date = parseISODate(text) { return date }
    let value = text.jsTrimmed
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}
