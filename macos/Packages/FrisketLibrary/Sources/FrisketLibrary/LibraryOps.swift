import Foundation
import FrisketBase

public struct NoteTemplate: Sendable, Hashable {
    public var name: String
    public var contents: String
}

/// One hit line of a plain-text workspace search.
public struct LineMatch: Sendable, Hashable {
    public var line: Int
    public var column: Int
    /// UTF-16 offset in the whole file.
    public var pos: Int
    public var text: String
    public var snippetOffset: Int
}

public struct FileSearchResult: Sendable, Hashable {
    public var path: String
    public var name: String
    public var relative: String
    public var matches: [LineMatch]
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct PlainSearchResults: Sendable {
    public var results: [FileSearchResult]
    public var truncated: Bool
}

private let slugRuns = Rx("[^a-z0-9]+")
private let slugEdges = Rx("^-|-\\z")
private let lineBreaks = Rx("[\\r\\n]")
private let markdownSuffix = Rx("\\.md\\z", [.caseInsensitive])
private let unsafeFileName = Rx("[<>:\"/\\\\|?*\\x00-\\x1f]")
private let datePattern = Rx("^\\d{4}-\\d{2}-\\d{2}\\z")
private let searchOperators = Rx("(?:^|\\s)(?:@todo|@images|#[\\p{L}\\p{N}_-])", [.caseInsensitive])
private let operatorOnly = Rx("^@(todo|images)\\z", [.caseInsensitive])

private func slug(_ text: String, max: Int, fallback: String) -> String {
    let lowered = slugRuns.replace(text.lowercased(), template: "-")
    let trimmed = slugEdges.replace(lowered, template: "")
    let cut = safeSlice(trimmed, 0, max)
    return cut.isEmpty ? fallback : cut
}

/// Library file operations: notes, trash, daily notes, templates, capture and plain search.
/// Each one refreshes the index afterwards.
extension LibraryIndex {
    private var libraryRootURL: URL { root }
    private var hiddenRootPath: String { rootPath + "/.frisket" }
    private var trashRootPath: String { rootPath + "/.frisket/Trash" }

    // MARK: Create

    /// Create `Notes/YYYY-MM-DD-slug.md` with `frisket-id` and `frisket-created` front matter and a
    /// `# Title` heading. The date is the UTC date, as in the Windows app.
    @discardableResult
    public func createNote(title: String?, now: Date = Date()) throws -> URL {
        let notes = try FileOps.managedFolder(root, "Notes")
        var clean = lineBreaks.replace((title ?? "Untitled").jsTrimmed, template: " ")
        clean = safeSlice(clean, 0, 120)
        if clean.isEmpty { clean = "Untitled" }
        let date = String(isoString(ms: msSinceEpoch(now)).prefix(10))
        let base = slug(clean, max: 52, fallback: "untitled")
        var target: URL? = nil
        for suffix in 0..<1000 {
            let candidate = notes.appendingPathComponent(date + "-" + base + (suffix > 0 ? "-\(suffix)" : "") + ".md")
            if !FileManager.default.fileExists(atPath: candidate.path) { target = candidate; break }
        }
        guard let target else { throw LibraryError("Could not choose a unique note name.") }
        if !pathIsInside(rootPath, normalizedPath(target.path)) { throw LibraryError("Invalid library note path.") }
        let contents = "---\nfrisket-id: " + newNoteID() + "\nfrisket-created: " + isoTimestamp(now) + "\n---\n\n# " + clean + "\n\n"
        try FileOps.writeNewFile(target, text: contents)
        refresh()
        return target
    }

    /// Create a note that a wiki link points at but which does not exist yet (`link:create`). An
    /// existing file is returned unchanged. The path is not required to be inside the library.
    @discardableResult
    public func createLinkedNote(at url: URL, title: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let heading = (title?.isEmpty == false) ? title! : Rx("\\.[^.]+\\z").replace(url.lastPathComponent, template: "")
        do {
            try FileOps.writeNewFile(url, text: "# " + heading + "\n\n")
        } catch FileOpsError.exists {
            // Already there: nothing to create.
        }
        refresh()
        return url
    }

    /// Open or create the daily note `Daily/<date>.md`. `body` (a Daily template, if any) is used
    /// only when the note does not exist yet.
    public func dailyNote(date: String, body: String? = nil) throws -> (url: URL, created: Bool) {
        if !datePattern.test(date) { throw LibraryError("Invalid date.") }
        let directory = try FileOps.managedFolder(root, "Daily")
        let target = directory.appendingPathComponent(date + ".md")
        if FileManager.default.fileExists(atPath: target.path) { return (target, false) }
        var text = (body?.jsTrimmed.isEmpty == false) ? body! : "# " + date + "\n\n"
        text = setFrontMatterValue(text, key: "frisket-id", value: newNoteID())
        text = setFrontMatterValue(text, key: "frisket-created", value: isoTimestamp())
        do { try FileOps.writeNewFile(target, text: text) } catch FileOpsError.exists { /* created meanwhile */ }
        refresh()
        return (target, true)
    }

    /// Save a quick capture as `Inbox/<timestamp>-slug.md`.
    @discardableResult
    public func capture(title: String?, body: String?, now: Date = Date()) throws -> URL {
        let directory = try FileOps.managedFolder(root, "Inbox")
        let raw = (title?.isEmpty == false) ? title! : "Untitled"
        let clean = lineBreaks.replace(safeSlice(raw.jsTrimmed, 0, 120), template: " ")
        let name = slug(clean, max: 48, fallback: "note")
        let stamp = isoString(ms: msSinceEpoch(now), clockSeparator: "-", millisSeparator: "-")
        let file = directory.appendingPathComponent(stamp + "-" + name + ".md")
        try FileOps.writeNewFile(file, text: "# " + clean + "\n\n" + (body ?? "") + "\n")
        refresh()
        return file
    }

    // MARK: Templates

    private static let templateLimit = 256 * 1024

    /// The Markdown files in `Templates/` (first 100 by name; larger than 256 KB are skipped).
    public func templates() throws -> [NoteTemplate] {
        let directory = root.appendingPathComponent("Templates", isDirectory: true)
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: directory.path) else { return [] }
        if attributes[.type] as? FileAttributeType != .typeDirectory { throw LibraryError("Templates must be a regular folder.") }
        var templates: [NoteTemplate] = []
        for name in try fm.contentsOfDirectory(atPath: directory.path).stableSorted(by: numericCompare).prefix(100) {
            let url = directory.appendingPathComponent(name)
            guard let stat = fileStat(url.path), stat.isFile, markdownExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            if stat.size > Self.templateLimit { continue }
            templates.append(NoteTemplate(name: name, contents: try FileOps.readText(url)))
        }
        return templates.stableSorted { localeCompare($0.name, $1.name) }
    }

    /// Save a new template `Templates/<name>.md`; fails if it exists or exceeds 256 KB.
    @discardableResult
    public func saveTemplate(name: String, contents: String) throws -> URL {
        if contents.utf8.count > Self.templateLimit { throw LibraryError("Snippet exceeds the 256 KB template limit.") }
        let directory = try FileOps.managedFolder(root, "Templates")
        let clean = markdownSuffix.replace(name.jsTrimmed, template: "")
        if clean.isEmpty || clean.utf16Length > 100 || unsafeFileName.test(clean) || clean == "." || clean == ".." {
            throw LibraryError("Choose a short file name without path characters.")
        }
        let file = directory.appendingPathComponent(clean + ".md")
        try FileOps.writeNewFile(file, text: contents)
        return file
    }

    // MARK: Trash

    private func activeLibraryNote(_ url: URL) throws -> String {
        guard let real = realPath(url.path), pathIsInside(rootPath, real), !pathIsInside(hiddenRootPath, real) else {
            throw LibraryError("Only active notes in this library can be changed.")
        }
        return real
    }

    /// Set or clear `frisket-trashed-at` with a snapshot and a change-checked write.
    private func setTrashMetadata(_ path: String, timestamp: String?) throws {
        let url = URL(fileURLWithPath: path)
        let before = FileOps.modificationDate(URL(fileURLWithPath: path))
        let source = try FileOps.readText(url)
        let next = setFrontMatterValue(source, key: "frisket-trashed-at", value: timestamp)
        if sameText(next, source) { return }
        try HistoryStore.record(file: url, text: source, libraryRoot: root, reason: .beforeChange)
        try FileOps.replaceFile(URL(fileURLWithPath: path), text: next, expectedModificationDate: before)
    }

    /// Move a note to the trash by setting `frisket-trashed-at`.
    @discardableResult
    public func trashNote(_ url: URL) throws -> URL {
        let real = try activeLibraryNote(url)
        try setTrashMetadata(real, timestamp: isoTimestamp())
        refresh()
        return URL(fileURLWithPath: real)
    }

    /// Restore a trashed note: clear the flag, or move it out of the legacy `.frisket/Trash` folder.
    @discardableResult
    public func restoreNote(_ url: URL) throws -> URL {
        guard let real = realPath(url.path) else { throw LibraryError("\(url.lastPathComponent) no longer exists.") }
        let result: String
        if pathIsInside(trashRootPath, real) {
            let target = rootPath + "/" + relativePath(from: trashRootPath, to: real)
            if !pathIsInside(rootPath, target) { throw LibraryError("Invalid restore path.") }
            if FileManager.default.fileExists(atPath: target) { throw LibraryError("A note already exists at the restore location.") }
            try FileManager.default.createDirectory(atPath: dirName(target), withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: real, toPath: target)
            result = target
        } else {
            let active = try activeLibraryNote(URL(fileURLWithPath: real))
            try setTrashMetadata(active, timestamp: nil)
            result = active
        }
        refresh()
        return URL(fileURLWithPath: result)
    }

    /// Permanently delete a note that is in the trash. The last version stays in history.
    public func deleteNote(_ url: URL) throws {
        guard let real = realPath(url.path) else { throw LibraryError("\(url.lastPathComponent) no longer exists.") }
        if !pathIsInside(trashRootPath, real) {
            let active = try activeLibraryNote(URL(fileURLWithPath: real))
            let text = try FileOps.readText(URL(fileURLWithPath: active))
            let properties = parseFrontMatter(splitFrontMatter(text).metaText).properties
            if properties["frisket-trashed-at"]?.isTruthy != true {
                throw LibraryError("Only notes in this library Trash can be permanently deleted.")
            }
        }
        let file = URL(fileURLWithPath: real)
        try HistoryStore.record(file: file, text: try FileOps.readText(file), libraryRoot: root, reason: .beforeChange)
        try FileManager.default.removeItem(at: file)
        refresh()
    }

    // MARK: Plain search

    /// Markdown files for the plain search: depth up to 6, no hidden or ignored names, sorted by name.
    private func collectMarkdown(_ directory: String, depth: Int, into out: inout [String], limit: Int) {
        if depth > 6 || out.count >= limit { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names.stableSorted(by: numericCompare) {
            if name.hasPrefix(".") || ignoredDirectoryNames.contains(name) { continue }
            let full = directory + "/" + name
            let type = (try? fm.attributesOfItem(atPath: full))?[.type] as? FileAttributeType
            if type == .typeDirectory { collectMarkdown(full, depth: depth + 1, into: &out, limit: limit) }
            else if markdownExtensions.contains((name as NSString).pathExtension.lowercased()) { out.append(full) }
            if out.count >= limit { break }
        }
    }

    /// Plain substring search across the library folder. Queries with `#tag`, `@todo` or `@images`
    /// go through the index instead (so nested tags and task/image state agree with the sidebar).
    /// Needles shorter than two characters find nothing, except `@todo` and `@images`.
    public func plainSearch(query: String, caseSensitive: Bool = false, maxFiles: Int = 2000, maxResults: Int = 200) throws -> PlainSearchResults {
        let needle = query.jsTrimmed
        if needle.utf16Length < 2 && !operatorOnly.test(needle) { return PlainSearchResults(results: [], truncated: false) }

        if searchOperators.test(needle) {
            let found = search(query: needle)
            let results = found.notes.map { hit -> FileSearchResult in
                let match = hit.match.map {
                    LineMatch(line: $0.line, column: $0.column, pos: $0.pos, text: $0.text, snippetOffset: $0.snippetOffset)
                } ?? LineMatch(line: 1, column: 0, pos: 0,
                               text: hit.summary.excerpt.isEmpty ? hit.summary.title : hit.summary.excerpt, snippetOffset: 0)
                return FileSearchResult(path: hit.summary.path, name: hit.summary.name, relative: hit.summary.relative, matches: [match])
            }
            return PlainSearchResults(results: results, truncated: found.truncated)
        }

        let compare = caseSensitive ? needle : needle.lowercased()
        let compareUnits = Array(compare.utf16)
        var files: [String] = []
        collectMarkdown(rootPath, depth: 0, into: &files, limit: maxFiles)
        var results: [FileSearchResult] = []
        var truncated = false
        for file in files {
            if results.count >= maxResults { truncated = true; break }
            guard let stat = fileStat(file), stat.size <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let haystack = caseSensitive ? text : text.lowercased()
            if indexOf(Array(haystack.utf16), compareUnits) < 0 { continue }
            var matches: [LineMatch] = []
            var offset = 0
            for (index, line) in splitLines(text).enumerated() {
                if matches.count >= 20 { break }
                let units = Array(line.utf16)
                let hay = caseSensitive ? units : Array(line.lowercased().utf16)
                let column = indexOf(hay, compareUnits)
                if column > -1 {
                    let long = units.count > 160
                    matches.append(LineMatch(
                        line: index + 1, column: column, pos: offset + column,
                        text: string16(long ? slice16(units, Swift.max(0, column - 40), column + 120) : units),
                        snippetOffset: long ? Swift.max(0, column - 40) : 0))
                }
                offset += units.count + 1
            }
            if !matches.isEmpty {
                results.append(FileSearchResult(path: file, name: baseName(file), relative: relativePath(from: rootPath, to: file), matches: matches))
            }
        }
        return PlainSearchResults(results: results, truncated: truncated || files.count >= maxFiles)
    }
}
