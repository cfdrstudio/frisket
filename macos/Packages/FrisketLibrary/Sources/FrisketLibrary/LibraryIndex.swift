import Foundation
import FrisketBase

// MARK: - Sync-conflict recognition

public struct ConflictCopy: Sendable, Equatable {
    public var kind: ConflictKind
    /// The original file's name without extension.
    public var base: String
}

private let conflictedCopyName = Rx(#"^(.*?) \((?:[^()]*?['’]s )?conflicted copy(?: [^()]*)?\)\z"#, [.caseInsensitive])
private let syncthingName = Rx(#"^(.*)\.sync-conflict-\d{8}-\d{6}(?:-[A-Z0-9]{7})?\z"#)
private let oneDriveDeviceName = Rx(#"^(.*)-((?:DESKTOP|LAPTOP)-[A-Z0-9]{4,})\z"#)

/// Recognise the copies sync services make when two devices edit one file. `name` is the file name
/// without extension; `hostName` is this machine's, for OneDrive-style `-<hostname>` suffixes.
public func conflictCopyOf(_ name: String, hostName: String = ProcessInfo.processInfo.hostName) -> ConflictCopy? {
    let ns = name as NSString
    if let match = conflictedCopyName.first(ns), let base = match.group(1, in: ns) { return ConflictCopy(kind: .conflictedCopy, base: base) }
    if let match = syncthingName.first(ns), let base = match.group(1, in: ns) { return ConflictCopy(kind: .syncthing, base: base) }
    var match = oneDriveDeviceName.first(ns)
    // OneDrive appends the device name; short names would match ordinary titles.
    let host = hostName.components(separatedBy: ".").first ?? ""
    if match == nil, host.utf16Length >= 6 {
        match = Rx("^(.*)-" + Rx.escape(host) + #"\z"#, [.caseInsensitive]).first(ns)
    }
    if let match, let base = match.group(1, in: ns), !base.isEmpty { return ConflictCopy(kind: .onedrive, base: base) }
    return nil
}

private let copyLikeName = Rx(#" (?:\d+|copy(?: \d+)?)\z|\(\d+\)\z"#, [.caseInsensitive])

/// Of several notes sharing a `frisket-id`, the one most likely to be the original.
func likelyOriginal(_ group: [NoteRecord]) -> NoteRecord {
    func copyLike(_ note: NoteRecord) -> Int { copyLikeName.test(stripNoteExtension(baseName(note.path))) ? 1 : 0 }
    return group.stableSorted { a, b in
        if copyLike(a) != copyLike(b) { return copyLike(a) - copyLike(b) }
        if a.relative.utf16Length != b.relative.utf16Length { return a.relative.utf16Length - b.relative.utf16Length }
        if a.mtime != b.mtime { return a.mtime < b.mtime ? -1 : 1 }
        return localeCompare(a.relative, b.relative)
    }[0]
}

// MARK: - Public value types

/// An immutable picture of the library, ready to render without awaiting per item.
public struct LibrarySnapshot: Sendable {
    public let root: URL
    /// Increases each time the index changes.
    public let version: Int
    /// Every note, sorted by relative path, with `linkText` and `conflict` filled in.
    public let summaries: [NoteSummary]
    public let tags: [TagCount]
    /// Some files were left out because of the limits.
    public let truncated: Bool
    /// How many notes are sync-conflict copies.
    public let conflicts: Int
}

/// Links that still use a note's previous title.
public struct TitleChange: Sendable, Hashable {
    public var path: String
    public var from: String
    public var to: String
    public var links: Int
    /// Notes containing such links.
    public var files: [String]
}

public struct NoteContext: Sendable {
    public var path: String
    public var title: String
    public var linkText: String?
    public var properties: FMProperties
    public var backlinks: Backlinks
    public var attachments: AttachmentReport
    public var titleChange: TitleChange?
}

public struct LibraryOverview: Sendable {
    public var snapshot: LibrarySnapshot
    public var context: NoteContext?
}

public struct SearchHit: Sendable, Hashable {
    public var summary: NoteSummary
    public var match: SearchMatch?
}

public struct SearchResults: Sendable {
    public var notes: [SearchHit]
    public var terms: [String]
    public var truncated: Bool
}

public struct UpdateTitleLinksResult: Sendable, Equatable {
    public var links: Int
    public var files: Int
    public var skipped: [String]
}

public struct LinkMentionResult: Sendable, Equatable {
    public var ok: Bool
    public var link: String
}

public enum ConflictResolution: String, Sendable {
    case keepOriginal = "keep-original"
    case keepCopy = "keep-copy"
    case keepBoth = "keep-both"
}

// MARK: - The index

/// The live library index. It keeps one parsed record per Markdown file and re-reads only files
/// whose size or modification time changed, so refreshing after a save costs a directory walk
/// rather than a full re-parse. Everything derived from the records is rebuilt once per change.
///
/// Call `refresh()` when the library changes on disk (the app's FSEvents watcher decides when,
/// using `isIgnoredChange`). File work runs inside the actor, so calls never interleave.
public actor LibraryIndex {
    private struct Entry {
        var record: NoteRecord
        var summary: NoteSummary?
        var prose: String?
    }

    private struct TitleChangeState {
        var path: String
        var from: String
        var to: String
        var sources: [String]
    }

    private struct Derived {
        var version: Int
        var notes: [NoteRecord]
        var activeNotes: [NoteRecord]
        var conflicts: [String: NoteConflict]
        var resolver: LinkResolver
        var summaries: [NoteSummary]
        var tags: [TagCount]
    }

    /// The library folder, with symlinks resolved.
    public nonisolated let root: URL
    public nonisolated let limits: ScanLimits
    nonisolated let rootPath: String
    private let trashRootPath: String
    private let hostName: String
    private let alwaysRefresh: Bool

    private var records: [String: Entry] = [:]
    private var truncated = false
    private(set) var version = 0
    private var loaded = false
    private var derivedCache: Derived?
    private var titleChanges: [String: TitleChangeState] = [:]

    /// - Parameters:
    ///   - alwaysRefresh: refresh before every query, for apps without a file watcher.
    ///   - hostName: used to recognise OneDrive-style conflict copies.
    public init(root: URL, limits: ScanLimits = .library, alwaysRefresh: Bool = false,
                hostName: String = ProcessInfo.processInfo.hostName) {
        let resolved = realPath(root.path) ?? normalizedPath(root.path)
        self.rootPath = resolved
        self.root = URL(fileURLWithPath: resolved, isDirectory: true)
        self.trashRootPath = resolved + "/.frisket/Trash"
        self.limits = limits
        self.alwaysRefresh = alwaysRefresh
        self.hostName = hostName
    }

    /// True for watcher events that cannot change the index (hidden or ignored paths); `relativePath`
    /// is relative to the library root. The library's own `.frisket/Trash` still counts.
    public nonisolated static func isIgnoredChange(relativePath: String) -> Bool {
        let parts = relativePath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        if parts.isEmpty { return false }
        if parts[0] == ".frisket" { return parts.count < 2 || parts[1] != "Trash" }
        return parts.contains { $0.hasPrefix(".") || ignoredDirectoryNames.contains($0) }
    }

    // MARK: Refresh

    /// Bring the index up to date. Returns true if anything changed.
    @discardableResult
    public func refresh() -> Bool {
        let changed = refreshOnce()
        loaded = true
        return changed
    }

    private func ensureFresh(_ refreshNow: Bool) {
        if refreshNow || !loaded || alwaysRefresh { refresh() }
    }

    private func refreshOnce() -> Bool {
        let walked = walkMarkdown(root: rootPath, maxDepth: limits.maxDepth, maxFiles: limits.maxFiles)
        var truncatedNow = walked.truncated
        var entries = walked.files.map { (file: $0, trashed: false) }
        if let type = (try? FileManager.default.attributesOfItem(atPath: trashRootPath))?[.type] as? FileAttributeType, type == .typeDirectory {
            let trash = walkMarkdown(root: trashRootPath, maxDepth: limits.maxDepth, maxFiles: limits.maxFiles)
            truncatedNow = truncatedNow || trash.truncated
            entries += trash.files.map { (file: $0, trashed: true) }
        }

        var seen = Set<String>()
        var toRead: [(file: String, trashed: Bool, size: Int, mtime: Date, previous: Entry?)] = []
        var totalBytes = 0
        for entry in entries {
            guard let stat = fileStat(entry.file), stat.isFile else { continue }
            if stat.size > limits.maxFileBytes || totalBytes + stat.size > limits.maxTotalBytes { truncatedNow = true; continue }
            totalBytes += stat.size
            seen.insert(entry.file)
            let previous = records[entry.file]
            if let previous, previous.record.mtime == stat.mtime, previous.record.size == stat.size,
               previous.record.inTrash == entry.trashed { continue }
            toRead.append((entry.file, entry.trashed, stat.size, stat.mtime, previous))
        }

        var updates: [(key: String, previous: NoteRecord?, next: NoteRecord)] = []
        for item in toRead {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.file)) else { seen.remove(item.file); continue }
            var record = parseNote(file: item.file, root: rootPath, text: decodeText(data), mtime: item.mtime, size: item.size, inTrash: item.trashed)
            if item.trashed {
                record.properties["frisket-trashed-at"] = .string(isoTimestamp(item.mtime))
            }
            updates.append((item.file, item.previous?.record, record))
        }
        let removed = records.keys.filter { !seen.contains($0) }

        if updates.isEmpty && removed.isEmpty && truncatedNow == truncated { return false }

        let renamed = updates.compactMap { update -> (key: String, previous: NoteRecord, next: NoteRecord)? in
            guard let previous = update.previous, !previous.isTrashed, nameKey(previous.title) != nameKey(update.next.title) else { return nil }
            return (update.key, previous, update.next)
        }
        if !renamed.isEmpty { trackTitleChanges(renamed) }

        for update in updates { records[update.key] = Entry(record: update.next, summary: nil, prose: nil) }
        for key in removed { records.removeValue(forKey: key) }
        truncated = truncatedNow
        version += 1
        derivedCache = nil
        return true
    }

    /// Remember which notes linked to a note by its old title, using the resolver from before the
    /// change. The first title is kept if it changes again, since the links still use it.
    private func trackTitleChanges(_ renamed: [(key: String, previous: NoteRecord, next: NoteRecord)]) {
        let before = derived()
        for (key, previous, next) in renamed {
            if titleChanges[key] != nil { titleChanges[key]?.to = next.title; continue }
            let oldKey = nameKey(previous.title)
            var sources: [String] = []
            for source in before.activeNotes where source.path != previous.path && !source.isTrashed {
                let linksHere = source.linkSpans.contains { link in
                    guard link.kind == .wiki, let parsed = parseLinkTarget(link.target), nameKey(parsed.name) == oldKey else { return false }
                    return before.resolver.resolve(from: source.path, link.target).note?.path == previous.path
                }
                if linksHere { sources.append(source.path) }
            }
            if !sources.isEmpty {
                titleChanges[key] = TitleChangeState(path: next.path, from: previous.title, to: next.title, sources: sources)
            }
        }
    }

    // MARK: Derived data

    private func findConflicts(_ notes: [NoteRecord]) -> [String: NoteConflict] {
        var conflicts: [String: NoteConflict] = [:]
        let active = notes.filter { !$0.isTrashed }
        let byPath = Dictionary(active.map { (normalizedPath($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        for note in active {
            let name = baseName(note.path)
            let ext = extName(name)
            guard let copy = conflictCopyOf(String(name.dropLast(ext.count)), hostName: hostName) else { continue }
            let original = byPath[normalizedPath(dirName(note.path) + "/" + copy.base + ext)]
            conflicts[normalizedPath(note.path)] = NoteConflict(kind: copy.kind, originalPath: original?.path)
        }
        var byID: [String: [NoteRecord]] = [:]
        var idOrder: [String] = []
        for note in active where conflicts[normalizedPath(note.path)] == nil {
            guard let id = note.properties["frisket-id"], id.isTruthy else { continue }
            if byID[id.text] == nil { idOrder.append(id.text) }
            byID[id.text, default: []].append(note)
        }
        for id in idOrder {
            let group = byID[id] ?? []
            if group.count < 2 { continue }
            let original = likelyOriginal(group)
            for note in group where note.path != original.path {
                conflicts[normalizedPath(note.path)] = NoteConflict(kind: .duplicateID, originalPath: original.path)
            }
        }
        return conflicts
    }

    /// Summaries, tags, the resolver and conflicts for the current version, built once per change.
    private func derived() -> Derived {
        if let cache = derivedCache, cache.version == version { return cache }
        let notes = records.values.map(\.record).stableSorted { numericCompare($0.relative, $1.relative) }
        let conflicts = findConflicts(notes)
        // Conflict copies stay out of links, tags and backlinks until resolved.
        let activeNotes = notes.filter { conflicts[normalizedPath($0.path)] == nil }
        let resolver = createLinkResolver(notes: activeNotes, root: rootPath)
        let summaries = notes.map { note -> NoteSummary in
            var summary: NoteSummary
            if let cached = records[note.path]?.summary { summary = cached } else {
                summary = summaryFor(note)
                records[note.path]?.summary = summary
            }
            let conflict = conflicts[normalizedPath(note.path)]
            summary.conflict = conflict
            summary.linkText = conflict == nil ? resolver.linkText(for: note) : nil
            return summary
        }
        let tags = getTags(activeNotes.filter { !$0.isTrashed })
        let result = Derived(version: version, notes: notes, activeNotes: activeNotes, conflicts: conflicts,
                             resolver: resolver, summaries: summaries, tags: tags)
        derivedCache = result
        return result
    }

    func record(_ url: URL) -> NoteRecord? { records[normalizedPath(url.path)]?.record }
    func record(path: String) -> NoteRecord? { records[normalizedPath(path)]?.record }

    // MARK: Queries

    /// The current state, without refreshing (call `refresh()` first).
    public func snapshot() -> LibrarySnapshot {
        let derived = derived()
        return LibrarySnapshot(root: root, version: version, summaries: derived.summaries, tags: derived.tags,
                               truncated: truncated, conflicts: derived.conflicts.count)
    }

    /// The summary of one note in the current state.
    public func summary(for url: URL) -> NoteSummary? {
        let key = normalizedPath(url.path)
        return derived().summaries.first { normalizedPath($0.path) == key }
    }

    private func titleChangeFor(_ path: String) -> TitleChange? {
        let key = normalizedPath(path)
        guard let change = titleChanges[key] else { return nil }
        guard let target = records[key]?.record, !target.isTrashed else { titleChanges[key] = nil; return nil }
        let resolver = derived().resolver
        let fromKey = nameKey(change.from)
        var links = 0
        var files: [String] = []
        for sourcePath in change.sources {
            guard let source = records[normalizedPath(sourcePath)]?.record, !source.isTrashed else { continue }
            let stale = source.linkSpans.filter { link in
                guard link.kind == .wiki, let parsed = parseLinkTarget(link.target), nameKey(parsed.name) == fromKey else { return false }
                return resolver.resolve(from: source.path, link.target).note?.path != target.path
            }.count
            if stale > 0 { links += stale; files.append(source.path) }
        }
        if links == 0 { titleChanges[key] = nil; return nil }
        titleChanges[key]?.to = target.title
        return TitleChange(path: target.path, from: change.from, to: target.title, links: links, files: files)
    }

    /// Everything about one note that is costly to compute: backlinks, attachments, properties.
    /// Nil when the note is not in the index.
    public func context(for url: URL, refresh refreshNow: Bool = false) -> NoteContext? {
        ensureFresh(refreshNow)
        let derived = derived()
        guard let target = record(url) else { return nil }
        return NoteContext(
            path: target.path, title: target.title,
            linkText: derived.resolver.linkText(for: target),
            properties: target.properties,
            backlinks: getBacklinks(notes: derived.activeNotes, targetPath: target.path, resolver: derived.resolver, root: rootPath),
            attachments: inspectAttachments(of: target, root: rootPath),
            titleChange: titleChangeFor(target.path))
    }

    /// The snapshot plus the context of one note.
    public func overview(for url: URL? = nil, refresh refreshNow: Bool = false) -> LibraryOverview {
        ensureFresh(refreshNow)
        let context = url.flatMap { self.context(for: $0) }
        return LibraryOverview(snapshot: snapshot(), context: context)
    }

    private func proseLowercased(_ note: NoteRecord) -> String {
        if let cached = records[note.path]?.prose { return cached }
        let prose = maskNonProse(splitFrontMatter(note.text).body).lowercased()
        records[note.path]?.prose = prose
        return prose
    }

    /// Search results with where each one matched, for the note list and the sidebar. Conflict
    /// copies are left out; trashed notes unless `includeTrashed`.
    public func search(query: String, includeTrashed: Bool = false, refresh refreshNow: Bool = false) -> SearchResults {
        ensureFresh(refreshNow)
        let derived = derived()
        let parsed = parseSearchQuery(query)
        var hits: [SearchHit] = []
        for (summary, note) in zip(derived.summaries, derived.notes) where summary.conflict == nil {
            if searchMatches(summary: summary, query: parsed, includeTrashed: includeTrashed, prose: { proseLowercased(note) }) {
                hits.append(SearchHit(summary: summary, match: findSearchMatch(note.text, query: parsed)))
            }
        }
        return SearchResults(notes: hits, terms: parsed.terms, truncated: truncated)
    }

    /// Resolve a link from `source`. A miss triggers one refresh, in case the target was just created.
    public func resolveLink(_ target: String, from source: URL? = nil) -> LinkResolution {
        ensureFresh(false)
        var result = derived().resolver.resolve(from: source.map { normalizedPath($0.path) }, target)
        if case .missing = result {
            refresh()
            result = derived().resolver.resolve(from: source.map { normalizedPath($0.path) }, target)
        }
        return result
    }

    public func titleChange(for url: URL, refresh refreshNow: Bool = false) -> TitleChange? {
        ensureFresh(refreshNow)
        return titleChangeFor(url.path)
    }

    public func dismissTitleChange(for url: URL) {
        titleChanges[normalizedPath(url.path)] = nil
    }

    // MARK: Editing

    /// Rewrite a note on disk through `transform`, snapshotting the old version first
    /// (`before-change`) and refusing if the file changed in between. Returns false when
    /// `transform` returns nil or the same text.
    @discardableResult
    public func rewrite(_ url: URL, transform: (String) throws -> String?) throws -> Bool {
        // Fresh URL instances: URL caches resource values, which would hide a change made meanwhile.
        let before = FileOps.modificationDate(URL(fileURLWithPath: url.path))
        let text = try FileOps.readText(url)
        guard let next = try transform(text), !sameText(next, text) else { return false }
        try HistoryStore.record(file: url, text: text, libraryRoot: root, reason: .beforeChange)
        try FileOps.replaceFile(URL(fileURLWithPath: url.path), text: next, expectedModificationDate: before)
        return true
    }

    /// Point links that still use a note's old title at its current one.
    public func updateTitleLinks(for url: URL) -> UpdateTitleLinksResult {
        refresh()
        guard let change = titleChangeFor(url.path), let target = record(url) else {
            return UpdateTitleLinksResult(links: 0, files: 0, skipped: [])
        }
        let linkText = derived().resolver.linkText(for: target) ?? target.title
        let alias: String? = sameText(linkText, target.title) ? nil : target.title
        let fromKey = nameKey(change.from)
        var links = 0, files = 0
        var skipped: [String] = []
        for file in change.files {
            do {
                var count = 0
                let changed = try rewrite(URL(fileURLWithPath: file)) { text in
                    let result = rewriteWikiLinks(text, matching: { nameKey($0) == fromKey }, replacement: linkText, alias: alias)
                    count = result.count
                    return result.text
                }
                if changed { links += count; files += 1 }
            } catch {
                skipped.append(file)
            }
        }
        if skipped.isEmpty { titleChanges[normalizedPath(url.path)] = nil }
        refresh()
        return UpdateTitleLinksResult(links: links, files: files, skipped: skipped)
    }

    /// Turn an unlinked mention at UTF-16 offset `pos` (of `length`) in `source` into a wiki link to
    /// `target`. `expected` is the mention text; the call fails if the note no longer has it there.
    public func linkMention(in source: URL, pos: Int, length: Int, expected: String, target: URL) throws -> LinkMentionResult {
        refresh()
        let derived = derived()
        guard let sourceNote = record(source), let targetNote = record(target) else {
            throw LibraryError("That note is no longer in the library.")
        }
        let plain = derived.resolver.resolve(from: sourceNote.path, expected).note?.path == targetNote.path
        let linkText = derived.resolver.linkText(for: targetNote) ?? targetNote.title
        let link = plain ? "[[" + expected + "]]" : "[[" + linkText + "|" + expected + "]]"
        let changed = try rewrite(source) { text in
            let ns = text as NSString
            guard pos >= 0, length >= 0, pos + length <= ns.length,
                  sameText(ns.substring(with: NSRange(location: pos, length: length)), expected) else {
                throw LibraryError("The note changed; refresh and try again.")
            }
            return ns.replacingCharacters(in: NSRange(location: pos, length: length), with: link)
        }
        refresh()
        return LinkMentionResult(ok: changed, link: link)
    }

    /// Set or clear `frisket-pinned` on a note.
    public func setPinned(_ url: URL, pinned: Bool) throws {
        ensureFresh(false)
        guard let note = record(url), !note.inTrash else { throw LibraryError("Only notes in this library can be pinned.") }
        try rewrite(note.url) { setFrontMatterValue($0, key: "frisket-pinned", value: pinned ? "true" : nil) }
        refresh()
    }

    /// Resolve a sync-conflict copy. `keepOriginal` trashes the copy; `keepCopy` writes the copy's
    /// text over the original (snapshotted first) and trashes the copy; `keepBoth` makes the copy an
    /// ordinary note. Returns the path of the note to show afterwards.
    @discardableResult
    public func resolveConflict(_ copyURL: URL, action: ConflictResolution) throws -> URL {
        refresh()
        let derived = derived()
        guard let copy = record(copyURL), let conflict = derived.conflicts[normalizedPath(copy.path)] else {
            throw LibraryError("That note is no longer a conflict copy.")
        }
        let original = conflict.originalPath.flatMap { record(path: $0) }
        let trash: (String) -> String? = { setFrontMatterValue($0, key: "frisket-trashed-at", value: isoTimestamp()) }
        var resultPath = original?.path ?? copy.path

        switch action {
        case .keepOriginal:
            try rewrite(copy.url, transform: trash)
        case .keepCopy:
            guard let original else { throw LibraryError("The original note is missing; keep both instead.") }
            let copyText = try FileOps.readText(copy.url)
            try rewrite(original.url) { _ in copyText }
            try rewrite(copy.url, transform: trash)
        case .keepBoth:
            let copyID = copy.properties["frisket-id"]
            let needsID = original != nil && copyID?.isTruthy == true && copyID == original?.properties["frisket-id"]
            if needsID || conflict.kind == .duplicateID {
                try rewrite(copy.url) { setFrontMatterValue($0, key: "frisket-id", value: newNoteID()) }
            }
            if conflict.kind != .duplicateID {
                let ext = extName(copy.path)
                let stem = String(baseName(copy.path).dropLast(ext.count))
                let base = conflictCopyOf(stem, hostName: hostName)?.base ?? stem
                let target = try FileOps.uniqueURL(in: URL(fileURLWithPath: dirName(copy.path), isDirectory: true), stem: base + " (copy)", ext: ext)
                try FileManager.default.moveItem(at: copy.url, to: target)
                resultPath = target.path
            } else {
                resultPath = copy.path
            }
        }
        refresh()
        return URL(fileURLWithPath: resultPath)
    }
}
