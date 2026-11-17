import Foundation
import FrisketBase

/// Import notes from other apps into a library. Every source is read into a
/// common shape, then written the same way:
///
///     Imported/<Source> YYYY-MM-DD/<folders…>/<Title>.md
///     Assets/<frisket-id>/<attachment>
///
/// with `frisket-id`, `frisket-created`, `frisket-source` and `tags` in front
/// matter, links between imported pages rewritten to relative paths, and file
/// times taken from the source. Nothing outside those two folders is touched,
/// and existing files are never overwritten.
///
/// Evernote and Notion read files; Apple Notes asks the Notes app (which can
/// prompt the user), hence `async`. Resolves with the folder written, counts and skipped notes.
public func runImport(kind: ImportKind, source: ImportSource, root: URL, now: Date = Date()) async throws -> ImportReport {
    let collected: CollectedImport
    switch kind {
    case .evernote:
        guard case .files(let files) = source, !files.isEmpty else { throw ImportError("Choose one or more .enex files.") }
        collected = try collectEvernote(files)
    case .notion:
        guard case .folderOrZip(let url) = source else { throw ImportError("Choose a Notion export (.zip or folder).") }
        let tree = try NotionTree.load(url)
        do { collected = CollectedImport(notes: try NotionExport.notes(in: tree), skipped: [], tree: tree) }
        catch { tree.cleanup(); throw error }
    case .appleNotes:
        let raw = try await AppleNotesReader.read()
        let converted = AppleNotesReader.importable(raw)
        collected = CollectedImport(notes: converted.notes, skipped: converted.skipped, tree: nil)
    }
    defer { collected.tree?.cleanup() }
    return try writeImport(kind: kind, collected: collected, root: root, now: now)
}

/// Notes read from a source, ready to be written.
struct CollectedImport {
    var notes: [ImportedNote]
    var skipped: [SkippedNote]
    var tree: NotionTree?
}

private let maxEnexBytes = 1024 * 1024 * 1024

private func collectEvernote(_ files: [URL]) throws -> CollectedImport {
    var notes: [ImportedNote] = []
    for file in files {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxEnexBytes { throw ImportError(file.lastPathComponent + " is larger than 1 GB; export the notebook in parts.") }
        let notebook = file.deletingPathExtension().lastPathComponent
        for (index, var note) in try Enex.parse(try FileOps.readText(file)).enumerated() {
            note.key = file.path + "#\(index)"
            note.folder = files.count > 1 ? [notebook] : []
            notes.append(note)
        }
    }
    return CollectedImport(notes: notes, skipped: [], tree: nil)
}

/// Today's date as `YYYY-MM-DD` in the local time zone.
public func importDateStamp(_ now: Date = Date()) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

private let dataURIPattern = Rx("^data:([\\w.+-]+/[\\w.+-]+)?((?:;[\\w-]+=[^;,]*)*)(;base64)?,([\\s\\S]*)\\z", [.caseInsensitive])

/// Decode a `data:` URI into its (lower-cased) MIME type and bytes, or nil.
public func decodeDataURI(_ uri: String) -> (mime: String, data: Data)? {
    let ns = uri as NSString
    guard let match = dataURIPattern.first(ns) else { return nil }
    let mime = (match.group(1, in: ns) ?? "application/octet-stream").lowercased()
    let payload = match.group(4, in: ns) ?? ""
    if match.group(3, in: ns) != nil { return (mime, decodeBase64(payload)) }
    guard let decoded = payload.removingPercentEncoding else { return nil }
    return (mime, Data(decoded.utf8))
}

/// Put the title first as an `# H1`, promoting a matching first line rather than repeating it.
public func withTitle(_ body: String, _ title: String) -> String {
    func plain(_ line: String) -> String {
        var text = Rx("^#{1,6}\\s+").replace(line, template: "")
        text = Rx("[*_~=`\\\\]").replace(text, template: "")
        return text.jsTrimmed.lowercased()
    }
    var lines = jsSplit(body, "\n")
    if let first = lines.firstIndex(where: { !$0.jsTrimmed.isEmpty }), plain(lines[first]) == plain(title) {
        lines[first] = "# " + title
        return lines[first...].joined(separator: "\n")
    }
    return "# " + title + (body.jsTrimmed.isEmpty ? "" : "\n\n" + body)
}

/// The front-matter block written above every imported note.
public func importFrontMatter(id: String, created: String?, kind: ImportKind, tags: [String], now: Date = Date()) -> String {
    var lines = ["---", "frisket-id: " + id, "frisket-created: " + (created ?? isoTimestamp(now)), "frisket-source: " + kind.rawValue]
    var seen = Set<String>()
    var clean: [String] = []
    for tag in tags {
        let value = Rx("^#+").replace(tag, template: "").jsTrimmed
        if !value.isEmpty && seen.insert(value).inserted { clean.append(value) }
    }
    if !clean.isEmpty { lines.append("tags:"); lines.append(contentsOf: clean.map { "  - " + jsonQuoted($0) }) }
    lines.append(contentsOf: ["---", "", ""])
    return lines.joined(separator: "\n")
}

/// Saves a note's attachments under `Assets/<id>/`, deferring the writes until the note is complete.
private final class AssetSaver {
    let assetDirectory: URL
    let output: URL
    var names = Set<String>()
    var pending: [(url: URL, data: Data)] = []

    init(assetDirectory: URL, output: URL) {
        self.assetDirectory = assetDirectory
        self.output = output
    }

    /// Reserve a file name and return the relative link to it from the note.
    func save(name: String, data: Data) -> String {
        let ext = posixExtname(name)
        let base = posixBasename(name)
        let stem = FileOps.safeName(String(base.dropLast(ext.count)), fallback: "attachment")
        var file = stem + ext
        var n = 2
        while names.contains(file.lowercased()) { file = stem + " \(n)" + ext; n += 1 }
        names.insert(file.lowercased())
        let url = assetDirectory.appendingPathComponent(file)
        pending.append((url, data))
        return relativeHref(from: output, to: url)
    }
}

private let notionLinkPattern = Rx("(!?)\\[([^\\]\\n]*)\\]\\((<[^>\\n]+>|[^)\\s]+)(\\s+\"[^\"\\n]*\")?\\)")
private let externalLink = Rx("^(?:[a-z][a-z0-9+.-]+:|#|//)", [.caseInsensitive])

/// Rewrite links in a Notion page to the imported pages and copied attachments.
private func rewriteNotionLinks(_ markdown: String, key: String, output: URL, byKey: [String: URL], tree: NotionTree, saver: AssetSaver) throws -> String {
    let ns = markdown as NSString
    let base = posixDirname(key)
    let result = NSMutableString()
    var cursor = 0
    for match in notionLinkPattern.matches(ns) {
        var raw = match.group(3, in: ns) ?? ""
        if raw.hasPrefix("<") { raw.removeFirst() }
        if raw.hasSuffix(">") { raw.removeLast() }
        if externalLink.test(raw) { continue }
        let decoded = raw.removingPercentEncoding ?? raw
        let hash = jsIndexOf(decoded, "#")
        let file = hash.map { decoded.utf16Slice(0, $0) } ?? decoded
        let anchor = hash.map { decoded.utf16Slice($0) } ?? ""
        let resolved = posixNormalize(base == "." ? file : base + "/" + file)
        if resolved.isEmpty || resolved.hasPrefix("..") { continue }
        var href: String?
        if let linked = byKey[resolved] {
            href = relativeHref(from: output, to: linked) + anchor
        } else if let url = tree.files[resolved] {
            href = saver.save(name: posixBasename(resolved), data: try Data(contentsOf: url))
        }
        guard let href else { continue }
        result.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
        result.append((match.group(1, in: ns) ?? "") + "[" + (match.group(2, in: ns) ?? "") + "](" + markdownLinkDestination(href) + (match.group(4, in: ns) ?? "") + ")")
        cursor = match.range.location + match.range.length
    }
    result.append(ns.substring(from: cursor))
    return result as String
}

private let trailingSpace = Rx("\\s+\\z")

/// Write collected notes into `root`. Internal so tests can feed it canned notes.
func writeImport(kind: ImportKind, collected: CollectedImport, root: URL, now: Date) throws -> ImportReport {
    var skipped = collected.skipped
    let notes = collected.notes
    if notes.isEmpty { return ImportReport(folder: nil, notes: 0, attachments: 0, skipped: skipped) }
    let fm = FileManager.default

    let importRoot = root.appendingPathComponent("Imported", isDirectory: true)
    try fm.createDirectory(at: importRoot, withIntermediateDirectories: true)
    let destination = try FileOps.uniqueURL(in: importRoot, stem: FileOps.safeName(kind.label + " " + importDateStamp(now)), ext: "")
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)

    // Pass 1: decide every output path, so links between pages can point at them.
    var reserved = Set<String>()
    var ids: [String] = []
    var outputs: [URL] = []
    var byKey: [String: URL] = [:]
    for note in notes {
        ids.append(newNoteID())
        var directory = destination
        for part in note.folder { directory.appendPathComponent(FileOps.safeName(part), isDirectory: true) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = try FileOps.uniqueURL(in: directory, stem: FileOps.safeName(note.fileStem ?? note.title), ext: ".md", reserved: &reserved)
        outputs.append(output)
        byKey[note.key] = output
    }

    // Pass 2: convert, copy attachments, write.
    var attachments = 0
    var written = 0
    for (index, note) in notes.enumerated() {
        let id = ids[index]
        let output = outputs[index]
        let saver = AssetSaver(assetDirectory: root.appendingPathComponent("Assets", isDirectory: true).appendingPathComponent(id, isDirectory: true), output: output)
        var body: String
        do {
            if let html = note.html {
                var used = Set<Int>()
                var images = 0
                body = HTMLToMarkdown.convert(
                    html,
                    media: { hash, _ in
                        let wanted = hash.lowercased()
                        guard let at = note.resources.firstIndex(where: { $0.hash == wanted }) else { return nil }
                        used.insert(at)
                        let resource = note.resources[at]
                        return HTMLMedia(href: saver.save(name: resource.name, data: resource.data), name: resource.name, image: resource.mime.hasPrefix("image/"))
                    },
                    image: { src, _ in
                        guard let decoded = decodeDataURI(src) else { return nil }
                        images += 1
                        return saver.save(name: "image-\(images)" + (mimeExtensions[decoded.mime] ?? ".bin"), data: decoded.data)
                    })
                let extra = note.resources.enumerated().filter { !used.contains($0.offset) }.map(\.element)
                if !extra.isEmpty {
                    body += "\n\n## Attachments\n\n" + extra.map { resource in
                        let label = Rx("[\\[\\]]").replace(resource.name, template: "")
                        return "- [" + label + "](" + markdownLinkDestination(saver.save(name: resource.name, data: resource.data)) + ")"
                    }.joined(separator: "\n")
                }
                body = withTitle(body, note.title)
            } else {
                body = try rewriteNotionLinks(note.markdown ?? "", key: note.key, output: output, byKey: byKey, tree: collected.tree ?? NotionTree(), saver: saver)
                let firstLine = jsSplit(body, "\n").first { !$0.jsTrimmed.isEmpty } ?? ""
                if !Rx("^#\\s").test(firstLine) { body = withTitle(body, note.title) }
            }
        } catch {
            skipped.append(SkippedNote(title: note.title, reason: error.localizedDescription))
            continue
        }
        if !saver.pending.isEmpty {
            try fm.createDirectory(at: saver.assetDirectory, withIntermediateDirectories: true)
            for asset in saver.pending { try asset.data.write(to: asset.url, options: [.withoutOverwriting]) }
            attachments += saver.pending.count
        }
        let text = importFrontMatter(id: id, created: note.created, kind: kind, tags: note.tags, now: now)
            + trailingSpace.replace(body, template: "") + "\n"
        try FileOps.writeNewFile(output, text: text)
        let stamp = [note.updated, note.created].compactMap { $0 }.first { !$0.isEmpty }
        if let stamp, let when = parseISODate(stamp) {
            try? fm.setAttributes([.modificationDate: when], ofItemAtPath: output.path)
        }
        written += 1
    }
    let relative = destination.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count).drop { $0 == "/" }
    return ImportReport(folder: String(relative), notes: written, attachments: attachments, skipped: skipped)
}
