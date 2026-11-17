import Foundation
import CryptoKit
import FrisketBase

/// A stored version of a note.
public struct HistoryVersion: Sendable, Hashable {
    /// The snapshot's file name; pass it to `HistoryStore.read`.
    public var id: String
    public var time: Date
    public var size: Int
}

/// Why `HistoryStore.record` stored nothing.
public enum HistorySkip: String, Sendable {
    case tooLarge = "too-large"
    case noLocation = "no-location"
    case unchanged
    case recent
}

public enum HistoryRecordResult: Sendable, Equatable {
    case snapshot(id: String, key: String)
    case skipped(HistorySkip)

    public var snapshotID: String? { if case .snapshot(let id, _) = self { return id }; return nil }
    public var skipReason: HistorySkip? { if case .skipped(let reason) = self { return reason }; return nil }
}

/// Why a snapshot is being taken.
public enum HistoryReason: String, Sendable {
    case open, save, autosave
    case beforeChange = "before-change"
}

/// Where a file's snapshots live.
public struct HistoryLocation: Sendable, Equatable {
    public var directory: URL
    public var key: String
    public var relative: String
}

/// Local version history. Snapshots are plain Markdown files, readable without Frisket and shared
/// with the Windows app through the same layout:
///
///     <library>/.frisket/history/<key>/<timestamp>.md   (notes in a library)
///     <fallbackRoot>/history/<key>/<timestamp>.md       (files opened on their own)
///
/// `<key>` is `id-<frisket-id>` (history follows a note through renames) or `p-` plus the first 20
/// hex digits of the SHA-1 of its path. `meta.json` beside the snapshots records the latest path and title.
public enum HistoryStore {
    private static let minute: Int64 = 60_000
    private static let hour = 60 * minute
    private static let day = 24 * hour
    private static let maxSnapshots = 300
    private static let maxSnapshotBytes = 8 * 1024 * 1024
    private static let snapshotName = Rx(#"^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z(?:~\d{3})?\.md\z"#)

    private static func minGap(_ reason: HistoryReason) -> Int64 {
        switch reason {
        case .autosave: return 5 * minute
        case .save: return 30_000
        default: return 0
        }
    }

    /// `2026-10-15T09-00-00-000Z`, the base of a snapshot's file name.
    public static func stampFor(_ date: Date) -> String {
        isoString(ms: msSinceEpoch(date), clockSeparator: "-", millisSeparator: "-")
    }

    /// The time encoded in a snapshot name, or nil for other names.
    public static func timeOf(_ name: String) -> Date? { timeMs(name).map(dateFromMs) }

    static func timeMs(_ name: String) -> Int64? {
        let ns = name as NSString
        guard let match = snapshotName.first(ns) else { return nil }
        let n = (1...7).map { Int64(match.group($0, in: ns) ?? "") ?? 0 }
        let days = daysFromCivil(n[0], n[1], n[2])
        return days * 86_400_000 + n[3] * 3_600_000 + n[4] * 60_000 + n[5] * 1000 + n[6]
    }

    private static func properties(_ text: String) -> FMProperties {
        parseFrontMatter(splitFrontMatter(text).metaText).properties
    }

    private static let validID = Rx(#"^[A-Za-z0-9._-]{1,80}\z"#)

    /// Where a file's snapshots live, or nil when there is nowhere to keep them.
    public static func locate(file: URL, text: String, libraryRoot: URL?, fallbackRoot: URL?) -> HistoryLocation? {
        let filePath = normalizedPath(file.path)
        var inLibrary = false
        var relative = filePath
        var base: String? = fallbackRoot.map { normalizedPath($0.path) + "/history" }
        if let libraryRoot {
            let rootPath = normalizedPath(libraryRoot.path)
            var rootForRelative: String? = pathIsInside(rootPath, filePath) ? rootPath : nil
            var fileForRelative = filePath
            if rootForRelative == nil, let realRoot = realPath(rootPath), let realFile = realPath(dirName(filePath)).map({ $0 + "/" + baseName(filePath) }),
               pathIsInside(realRoot, realFile) {
                rootForRelative = realRoot
                fileForRelative = realFile
            }
            if let rootForRelative {
                inLibrary = true
                relative = relativePath(from: rootForRelative, to: fileForRelative)
                base = rootPath + "/.frisket/history"
            }
        }
        guard let base, inLibrary || fallbackRoot != nil else { return nil }
        let id = (properties(text)["frisket-id"].map { $0.isTruthy ? $0.text : "" } ?? "").jsTrimmed
        let pathKey = relative.replacingOccurrences(of: "\\", with: "/")
        let key: String
        if validID.test(id) {
            key = "id-" + id
        } else {
            let digest = Insecure.SHA1.hash(data: Data(pathKey.utf8)).map { String(format: "%02x", $0) }.joined()
            key = "p-" + digest.prefix(20)
        }
        return HistoryLocation(directory: URL(fileURLWithPath: base + "/" + key, isDirectory: true), key: key, relative: relative)
    }

    private static func snapshotNames(_ directory: URL) throws -> [String] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        return names.filter { snapshotName.test($0) }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Thin old snapshots: keep everything from the last hour, then the newest per 15 minutes (to a
    /// day), 2 hours (to a week), day (to 30 days), week (to a year), 30 days beyond that, at most
    /// 300 in all.
    public static func snapshotsToKeep(_ names: [String], now: Date) -> Set<String> {
        let nowMs = msSinceEpoch(now)
        var keep: [String] = []
        var buckets = Set<String>()
        let newestFirst = names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.reversed()
        for name in newestFirst {
            let time = timeMs(name) ?? 0
            let age = nowMs - time
            if age >= hour {
                let size: Int64
                if age < day { size = 15 * minute }
                else if age < 7 * day { size = 2 * hour }
                else if age < 30 * day { size = day }
                else if age < 365 * day { size = 7 * day }
                else { size = 30 * day }
                let bucket = "\(size):\(Int64((Double(time) / Double(size)).rounded(.down)))"
                if !buckets.insert(bucket).inserted { continue }
            }
            keep.append(name)
            if keep.count >= maxSnapshots { break }
        }
        return Set(keep)
    }

    private static func prune(_ directory: URL, now: Date) throws {
        let names = try snapshotNames(directory)
        let keep = snapshotsToKeep(names, now: now)
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// Snapshot `text` as a version of `file`. Identical content is never stored twice, and saves
    /// within the minimum gap of the previous snapshot are skipped (30 s for `.save`, 5 min for
    /// `.autosave`).
    @discardableResult
    public static func record(file: URL, text: String, libraryRoot: URL? = nil, fallbackRoot: URL? = nil,
                              reason: HistoryReason = .save, now: Date = Date()) throws -> HistoryRecordResult {
        let content = Data(text.utf8)
        if content.count > maxSnapshotBytes { return .skipped(.tooLarge) }
        guard let location = locate(file: file, text: text, libraryRoot: libraryRoot, fallbackRoot: fallbackRoot) else {
            return .skipped(.noLocation)
        }
        let directory = location.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = try snapshotNames(directory)
        let nowMs = msSinceEpoch(now)
        if let last = names.last {
            if let previous = try? Data(contentsOf: directory.appendingPathComponent(last)), previous == content {
                return .skipped(.unchanged)
            }
            let gap = minGap(reason)
            if gap > 0, let lastMs = timeMs(last), nowMs - lastMs < gap { return .skipped(.recent) }
        }
        let stamp = stampFor(now)
        var name = stamp + ".md"
        var n = 1
        while names.contains(name) {
            name = stamp + "~" + String(format: "%03d", n) + ".md"
            n += 1
        }
        try content.write(to: directory.appendingPathComponent(name), options: [.withoutOverwriting])
        let fileName = baseName(file.path)
        let title = noteTitle(text, fallback: Rx(#"\.[^.]+\z"#).replace(fileName, template: ""), properties: properties(text))
        let meta = "{\n  \"path\": \(jsonString(location.relative.replacingOccurrences(of: "\\", with: "/"))),\n  \"title\": \(jsonString(title)),\n  \"updatedAt\": \(jsonString(isoString(ms: nowMs)))\n}"
        try Data(meta.utf8).write(to: directory.appendingPathComponent("meta.json"))
        try prune(directory, now: now)
        return .snapshot(id: name, key: location.key)
    }

    /// Snapshots of `file`, newest first.
    public static func list(file: URL, text: String, libraryRoot: URL? = nil, fallbackRoot: URL? = nil) throws -> [HistoryVersion] {
        guard let location = locate(file: file, text: text, libraryRoot: libraryRoot, fallbackRoot: fallbackRoot) else { return [] }
        return try snapshotNames(location.directory).reversed().map { name in
            let size = (try? location.directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return HistoryVersion(id: name, time: timeOf(name) ?? Date(timeIntervalSince1970: 0), size: size)
        }
    }

    /// The text of one snapshot. `id` must be a snapshot name from `list`.
    public static func read(file: URL, text: String, id: String, libraryRoot: URL? = nil, fallbackRoot: URL? = nil) throws -> String {
        if !snapshotName.test(id) { throw LibraryError("Unknown version.") }
        guard let location = locate(file: file, text: text, libraryRoot: libraryRoot, fallbackRoot: fallbackRoot) else {
            throw LibraryError("This note has no history.")
        }
        return String(decoding: try Data(contentsOf: location.directory.appendingPathComponent(id)), as: UTF8.self)
    }
}
