import Foundation
import CryptoKit
import FrisketBase

/// How a sync-conflict copy was recognised.
public enum ConflictKind: String, Sendable, Hashable {
    case conflictedCopy = "conflicted-copy"
    case syncthing
    case onedrive
    case duplicateID = "duplicate-id"
}

/// A note that is a sync-conflict copy, and the original it is a copy of (when it exists).
public struct NoteConflict: Sendable, Hashable {
    public var kind: ConflictKind
    public var originalPath: String?
}

/// One parsed Markdown file: the record shared by workspace scans and the live index.
public struct NoteRecord: Sendable {
    /// Absolute, normalised file path (the key of the index).
    public var path: String
    /// Path relative to the library root, `/` separated.
    public var relative: String
    public var name: String
    public var title: String
    public var tags: [String]
    public var properties: FMProperties
    /// Link targets (wiki and Markdown), in `extractLinks` order.
    public var links: [String]
    /// Links with positions (body-relative UTF-16 offsets).
    public var linkSpans: [NoteLink]
    /// UTF-16 offset of the body within `text`.
    public var bodyOffset: Int
    public var images: [String]
    public var mtime: Date
    public var text: String
    public var size: Int
    /// True for notes found in the legacy `.frisket/Trash` folder.
    public var inTrash: Bool

    public var url: URL { URL(fileURLWithPath: path) }
    public var isTrashed: Bool { properties["frisket-trashed-at"]?.isTruthy ?? false }
}

/// Anything with the names quick open matches against.
public protocol NoteNaming {
    var name: String { get }
    var title: String { get }
    var relative: String { get }
}
extension NoteRecord: NoteNaming {}

/// A light reference to a note.
public struct NoteBrief: Sendable, Hashable {
    public var path: String
    public var title: String
    public var relative: String
    public var url: URL { URL(fileURLWithPath: path) }

    init(_ note: NoteRecord) { path = note.path; title = note.title; relative = note.relative }
}

/// The stable, UI-safe description of a note.
public struct NoteSummary: Sendable, Hashable, NoteNaming {
    /// `frisket-id`, or `legacy-<hash of the path>`. Not unique when copies share an id.
    public var id: String
    public var path: String
    public var relative: String
    public var name: String
    public var title: String
    public var aliases: [String]
    public var pinned: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var tags: [String]
    public var excerpt: String
    public var imagePreview: String?
    public var tasksDone: Int
    public var tasksTotal: Int
    public var hasImages: Bool
    public var hasAttachments: Bool
    public var trashedAt: Date?
    /// The shortest wiki-link text that resolves to this note (set by `LibraryIndex`).
    public var linkText: String?
    /// Set when this note is a sync-conflict copy (set by `LibraryIndex`).
    public var conflict: NoteConflict?

    public var url: URL { URL(fileURLWithPath: path) }
    public var isTrashed: Bool { trashedAt != nil }
}

/// A tag and how many active notes carry it or a tag below it.
public struct TagCount: Sendable, Hashable {
    public var tag: String
    public var count: Int
}

// MARK: - Parsing

private let fileExtension = Rx(#"\.[^.]+\z"#)
let noteExtensionPattern = Rx(#"\.(?:md|markdown|mdown|mkd|mdx|txt)\z"#, [.caseInsensitive])

func stripNoteExtension(_ name: String) -> String { noteExtensionPattern.replace(name, template: "") }

/// Parse one Markdown file into a record. `file` is an absolute path, `root` the library folder.
public func parseNote(file: String, root: String, text: String, mtime: Date, size: Int? = nil, inTrash: Bool = false) -> NoteRecord {
    let split = splitFrontMatter(text)
    let parsed = parseFrontMatter(split.metaText)
    let name = baseName(file)
    let extracted = extractLinks(text)
    return NoteRecord(
        path: file,
        relative: relativePath(from: root, to: file),
        name: name,
        title: noteTitle(text, fallback: fileExtension.replace(name, template: ""), properties: parsed.properties),
        tags: uniqueTags(parsed.tags + extractInlineTags(split.body)),
        properties: parsed.properties,
        links: extracted.links.map(\.target),
        linkSpans: extracted.links,
        bodyOffset: split.bodyOffset,
        images: extractImages(text),
        mtime: mtime,
        text: text,
        size: size ?? text.utf8.count,
        inTrash: inTrash
    )
}

private let attachmentLink = Rx(#"(?<!!)\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))"#)
private let schemeReference = Rx(#"^(?:[a-z][a-z0-9+.-]*:|//|data:)"#, [.caseInsensitive])
private let imageExtensionReference = Rx(#"\.(?:png|jpe?g|gif|webp|svg|avif|bmp)(?:[?#]|\z)"#, [.caseInsensitive])

private func hex(_ digest: some Sequence<UInt8>) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func summaryDate(_ value: FMValue?, fallback: Date) -> Date {
    guard let value else { return fallback }
    return parseLooseDate(value.text) ?? fallback
}

/// The summary of a note (without `linkText` and `conflict`, which need the whole library).
public func summaryFor(_ note: NoteRecord) -> NoteSummary {
    let split = splitFrontMatter(note.text)
    let codeMasked = maskCode(split.body)
    let prose = maskNonProse(codeMasked: codeMasked)
    let tags = uniqueTags(note.tags + inlineTags(inMasked: prose))
    let counts = taskCounts(codeMasked: codeMasked)
    let properties = note.properties
    let stable = note.relative.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
    let idValue = [properties["frisket-id"], properties["frisketId"]].compactMap { $0 }.first { $0.isTruthy }
    let id = idValue?.text
        ?? "legacy-" + String(hex(SHA256.hash(data: Data(stable.utf8))).prefix(24))
    let createdSource = properties["frisket-created"] ?? properties["frisketCreated"]
    let trashedSource = properties["frisket-trashed-at"] ?? properties["trashedAt"]
    let cover = properties["frisket-cover"] ?? properties["frisketCover"]
    var imagePreview: String? = note.images.first
    if case .string(let value)? = cover, !value.jsTrimmed.isEmpty { imagePreview = value.jsTrimmed }

    var hasAttachments = false
    let proseNS = prose as NSString
    for match in attachmentLink.matches(proseNS) {
        let reference = match.group(1, in: proseNS) ?? match.group(2, in: proseNS) ?? ""
        if !schemeReference.test(reference) && !imageExtensionReference.test(reference) { hasAttachments = true; break }
    }
    var trashedAt: Date? = nil
    if let trashedSource, trashedSource.isTruthy { trashedAt = summaryDate(trashedSource, fallback: note.mtime) }
    return NoteSummary(
        id: id, path: note.path, relative: note.relative, name: note.name, title: note.title,
        aliases: aliasesOf(properties),
        pinned: properties["frisket-pinned"] == .bool(true) || properties["frisket-pinned"] == .string("true"),
        createdAt: summaryDate(createdSource, fallback: note.mtime),
        modifiedAt: note.mtime,
        tags: tags,
        excerpt: makeExcerpt(prose: prose),
        imagePreview: imagePreview,
        tasksDone: counts.done, tasksTotal: counts.total,
        hasImages: !note.images.isEmpty,
        hasAttachments: hasAttachments,
        trashedAt: trashedAt,
        linkText: nil, conflict: nil
    )
}

public func summarizeNotes(_ notes: [NoteRecord]) -> [NoteSummary] { notes.map(summaryFor) }

// MARK: - Scanning

/// Bounds for a library walk.
public struct ScanLimits: Sendable, Equatable {
    public var maxDepth: Int
    public var maxFiles: Int
    public var maxFileBytes: Int
    public var maxTotalBytes: Int
    public init(maxDepth: Int, maxFiles: Int, maxFileBytes: Int, maxTotalBytes: Int) {
        self.maxDepth = maxDepth; self.maxFiles = maxFiles; self.maxFileBytes = maxFileBytes; self.maxTotalBytes = maxTotalBytes
    }
    /// The caps of `scanWorkspace`: depth 6, 2000 files, 4 MB per file, 64 MB in all.
    public static let workspace = ScanLimits(maxDepth: 6, maxFiles: 2000, maxFileBytes: 4 * 1024 * 1024, maxTotalBytes: 64 * 1024 * 1024)
    /// The defaults of the live `LibraryIndex`: depth 12, 10000 files, 4 MB per file, 96 MB in all.
    public static let library = ScanLimits(maxDepth: 12, maxFiles: 10000, maxFileBytes: 4 * 1024 * 1024, maxTotalBytes: 96 * 1024 * 1024)
}

/// Collect Markdown files under `root` in a stable order, skipping hidden, ignored and
/// symlinked entries. `truncated` reports anything left out.
func walkMarkdown(root: String, maxDepth: Int, maxFiles: Int) -> (files: [String], truncated: Bool) {
    var files: [String] = []
    var truncated = false
    let fm = FileManager.default

    func fileType(_ path: String) -> FileAttributeType? {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }

    func walk(_ dir: String, _ depth: Int) {
        if depth > maxDepth || files.count >= maxFiles { truncated = true; return }
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let entries = names.stableSorted(by: numericCompare)
        for (index, name) in entries.enumerated() {
            if name.hasPrefix(".") || ignoredDirectoryNames.contains(name) { continue }
            let full = (dir == "/" ? "" : dir) + "/" + name
            guard let type = fileType(full), type != .typeSymbolicLink else { continue }
            if type == .typeDirectory {
                if depth < maxDepth {
                    walk(full, depth + 1)
                } else if let inner = try? fm.contentsOfDirectory(atPath: full), !inner.isEmpty {
                    truncated = true
                }
            } else if type == .typeRegular, markdownExtensions.contains((name as NSString).pathExtension.lowercased()) {
                if files.count >= maxFiles { truncated = true; break }
                files.append(full)
            }
            if files.count >= maxFiles {
                if index != entries.count - 1 { truncated = true }
                break
            }
        }
    }
    walk(root, 0)
    return (files, truncated)
}

public struct WorkspaceScan: Sendable {
    public var notes: [NoteRecord]
    public var truncated: Bool
    /// The folder's real path.
    public var root: String
}

public struct LibraryError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

func fileStat(_ path: String) -> (isFile: Bool, size: Int, mtime: Date)? {
    guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
    return (values.isRegularFile ?? false, values.fileSize ?? 0, values.contentModificationDate ?? Date())
}

/// Build a bounded, read-only index of the Markdown files under a folder. Limits are clamped to
/// `ScanLimits.workspace`.
public func scanWorkspace(folder: URL, limits requested: ScanLimits = .workspace) throws -> WorkspaceScan {
    guard let root = realPath(folder.path) else { throw LibraryError("A workspace folder is required") }
    let caps = ScanLimits.workspace
    let maxDepth = min(caps.maxDepth, max(0, requested.maxDepth))
    let maxFiles = min(caps.maxFiles, max(1, requested.maxFiles))
    let maxBytes = min(caps.maxFileBytes, max(1, requested.maxFileBytes))
    let maxTotal = min(caps.maxTotalBytes, max(1, requested.maxTotalBytes))
    let walked = walkMarkdown(root: root, maxDepth: maxDepth, maxFiles: maxFiles)
    var truncated = walked.truncated
    var notes: [NoteRecord] = []
    var total = 0
    for file in walked.files {
        guard let stat = fileStat(file), stat.isFile else { continue }
        if stat.size > maxBytes { truncated = true; continue }
        if total + stat.size > maxTotal { truncated = true; continue }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { continue }
        if data.count > maxBytes { truncated = true; continue }
        total += data.count
        let text = decodeText(data)
        notes.append(parseNote(file: file, root: root, text: text, mtime: stat.mtime, size: data.count))
    }
    return WorkspaceScan(notes: notes, truncated: truncated, root: root)
}

/// UTF-8 text with a byte-order mark removed (the same tolerance as `FileOps.readText`).
func decodeText(_ data: Data) -> String {
    var text = String(decoding: data, as: UTF8.self)
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return text
}
