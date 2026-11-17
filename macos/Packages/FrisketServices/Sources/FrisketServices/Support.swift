import Foundation
import FrisketBase

// Small internal helpers shared by the ports: JavaScript-flavoured string and
// path operations (UTF-16 based, no Character/grapheme surprises with "\r\n"),
// JSON string quoting and a Process runner.

/// Split on a single-character separator, keeping empty pieces (JS `split`).
func jsSplit(_ text: String, _ separator: Character) -> [String] {
    let sep = separator.utf16.first!
    return text.utf16.split(separator: sep, omittingEmptySubsequences: false).map { String($0)! }
}

/// The UTF-16 index of the first occurrence of `needle` at or after `from`, or nil.
func jsIndexOf(_ text: String, _ needle: String, from: Int = 0) -> Int? {
    let ns = text as NSString
    if from > ns.length { return nil }
    let range = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
    return range.location == NSNotFound ? nil : range.location
}

/// Compare two strings by their UTF-8 bytes (Swift's `==` is canonical-equivalence).
func sameText(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// JavaScript `JSON.stringify(string)`.
func jsonQuoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{8}": out += "\\b"
        case "\u{c}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += "\\u" + String(format: "%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

// MARK: POSIX path helpers (`path.posix.*`)

func posixBasename(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
    if trimmed == "/" { return "" }
    return String(trimmed[trimmed.index(after: slash)...])
}

func posixDirname(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let slash = trimmed.lastIndex(of: "/") else { return "." }
    if slash == trimmed.startIndex { return "/" }
    return String(trimmed[..<slash])
}

/// `path.extname` of the last component: ".png", "" for ".bashrc" or no dot.
func posixExtname(_ path: String) -> String {
    let base = posixBasename(path)
    guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
    return String(base[dot...])
}

/// `path.posix.normalize`.
func posixNormalize(_ path: String) -> String {
    if path.isEmpty { return "." }
    let absolute = path.hasPrefix("/")
    let trailing = path.hasSuffix("/")
    var parts: [String] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
        if part == "." { continue }
        if part == ".." {
            if let last = parts.last, last != ".." { parts.removeLast() }
            else if !absolute { parts.append("..") }
            continue
        }
        parts.append(part)
    }
    var out = parts.joined(separator: "/")
    if out.isEmpty && !absolute { out = "." }
    if !out.isEmpty && trailing { out += "/" }
    return absolute ? "/" + out : out
}

/// `path.relative(dirname(from), to)` joined with "/", for two file URLs.
func relativeHref(from file: URL, to target: URL) -> String {
    let base = file.deletingLastPathComponent().standardizedFileURL.pathComponents
    let goal = target.standardizedFileURL.pathComponents
    var common = 0
    while common < base.count, common < goal.count, base[common] == goal[common] { common += 1 }
    let ups = Array(repeating: "..", count: base.count - common)
    return (ups + goal[common...]).joined(separator: "/")
}

// MARK: Processes

struct ProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}

/// Run an executable to completion, collecting both output pipes without
/// deadlocking on large output. After `timeout` seconds the process is
/// terminated and `timedOut` is set.
func runProcessBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()

    let group = DispatchGroup()
    var outData = Data()
    var errData = Data()
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

    let timedOutBox = TimeoutFlag()
    var timer: DispatchSourceTimer?
    if let timeout {
        let source = DispatchSource.makeTimerSource(queue: .global())
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler {
            timedOutBox.set()
            if process.isRunning { process.terminate() }
        }
        source.resume()
        timer = source
    }
    process.waitUntilExit()
    timer?.cancel()
    group.wait()
    return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData, timedOut: timedOutBox.value)
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval?) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do { continuation.resume(returning: try runProcessBlocking(executable, arguments, timeout: timeout)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}
