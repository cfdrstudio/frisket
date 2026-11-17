import Foundation
import FrisketBase

// MARK: - Link resolution

/// The outcome of resolving a link target.
public enum LinkResolution: Sendable, Equatable {
    case note(NoteBrief, anchor: String?)
    /// Several notes match at the same tier; never silently narrowed to one of them.
    case ambiguous([NoteBrief], anchor: String?)
    case anchorOnly(anchor: String?)
    case external
    /// Nothing active matches; `trashed` is a trashed note that would have.
    case missing(name: String, anchor: String?, trashed: NoteBrief?)

    public var note: NoteBrief? {
        if case .note(let brief, _) = self { return brief }
        return nil
    }
}

/// Resolves link targets against a set of notes. Tiers, first match wins: path (relative to the
/// linking note, then the library root), `frisket-id`, file name, title, then front-matter
/// aliases. Trashed notes are only reported when nothing active matches.
public final class LinkResolver: @unchecked Sendable {
    private struct Maps {
        var byPath: [String: Int] = [:]
        var byID: [String: [Int]] = [:]
        var byBase: [String: [Int]] = [:]
        var byTitle: [String: [Int]] = [:]
        var byAlias: [String: [Int]] = [:]
    }

    private let notes: [NoteRecord]
    private let root: String?
    private var active = Maps()
    private var trashed = Maps()

    public init(notes: [NoteRecord], root: String?) {
        self.notes = notes
        self.root = root
        for (index, note) in notes.enumerated() {
            if note.isTrashed { Self.index(note, at: index, into: &trashed) } else { Self.index(note, at: index, into: &active) }
        }
    }

    private static func index(_ note: NoteRecord, at index: Int, into maps: inout Maps) {
        func add(_ map: inout [String: [Int]], _ key: String) {
            if key.isEmpty { return }
            if map[key] == nil { map[key] = [index] } else if !map[key]!.contains(index) { map[key]!.append(index) }
        }
        maps.byPath[normalizedPath(note.path)] = index
        if let id = note.properties["frisket-id"], id.isTruthy { add(&maps.byID, id.text.jsTrimmed) }
        add(&maps.byBase, nameKey(stripNoteExtension(baseName(note.path))))
        add(&maps.byTitle, nameKey(note.title))
        for alias in aliasesOf(note.properties) { add(&maps.byAlias, nameKey(alias)) }
    }

    private func lookup(_ maps: Maps, _ sourcePath: String?, _ name: String) -> [Int] {
        var candidates: [String] = []
        if name.hasPrefix("/") {
            candidates.append(name)
        } else {
            if let sourcePath { candidates.append(resolvePath(dirName(sourcePath), name)) }
            if let root { candidates.append(resolvePath(root, name)) }
        }
        for candidate in candidates {
            // Always try both: a title such as "Mr. Smith" looks like it has an extension.
            for option in [candidate, candidate + ".md"] {
                if let hit = maps.byPath[normalizedPath(option)] { return [hit] }
            }
        }
        if let hit = maps.byID[name.jsTrimmed] { return hit }
        let pathLike = name.contains("/") || name.contains("\\")
        let plain = stripNoteExtension(name.replacingOccurrences(of: "\\", with: "/"))
        let last = plain.components(separatedBy: "/").last ?? ""
        if let base = maps.byBase[nameKey(last)] {
            if !pathLike { return base }
            // `folder/Note` must match the end of the note's path, not just its name.
            let suffix = nameKey(Rx(#"^(?:\.{1,2}/)+"#).replace(plain, template: ""))
            let narrowed = base.filter { index in
                let key = relativeKey(notes[index])
                return key == suffix || key.hasSuffix("/" + suffix)
            }
            if !narrowed.isEmpty { return narrowed }
        }
        if let hit = maps.byTitle[nameKey(name)] { return hit }
        return maps.byAlias[nameKey(name)] ?? []
    }

    private func relativeKey(_ note: NoteRecord) -> String {
        nameKey(stripNoteExtension((note.relative.isEmpty ? note.name : note.relative).replacingOccurrences(of: "\\", with: "/")))
    }

    /// Resolve `rawTarget` as written in the note at `sourcePath`.
    public func resolve(from sourcePath: String?, _ rawTarget: String) -> LinkResolution {
        guard let parsed = parseLinkTarget(rawTarget) else { return .external }
        let name = parsed.name
        if name.isEmpty { return .anchorOnly(anchor: parsed.anchor) }
        var names = [name]
        if let decoded = name.removingPercentEncoding, !sameText(decoded, name) { names.append(decoded) }
        for candidate in names {
            let hits = lookup(active, sourcePath, candidate)
            if hits.count == 1 { return .note(NoteBrief(notes[hits[0]]), anchor: parsed.anchor) }
            if hits.count > 1 { return .ambiguous(hits.map { NoteBrief(notes[$0]) }, anchor: parsed.anchor) }
        }
        var inTrash: NoteBrief? = nil
        for candidate in names {
            let hits = lookup(trashed, sourcePath, candidate)
            if let first = hits.first { inTrash = NoteBrief(notes[first]); break }
        }
        return .missing(name: name, anchor: parsed.anchor, trashed: inTrash)
    }

    private static let unsafeLinkText = Rx(#"[\[\]|#^]"#)

    /// The shortest wiki-link target that resolves uniquely to `note` from anywhere.
    public func linkText(for note: NoteRecord) -> String? {
        if note.isTrashed { return nil }
        func unique(_ text: String) -> Bool {
            if text.isEmpty || Self.unsafeLinkText.test(text) { return false }
            let hits = lookup(active, nil, text)
            return hits.count == 1 && notes[hits[0]].path == note.path
        }
        if unique(note.title) { return note.title }
        let base = stripNoteExtension(baseName(note.path))
        if unique(base) { return base }
        return stripNoteExtension((note.relative.isEmpty ? base : note.relative).replacingOccurrences(of: "\\", with: "/"))
    }
}

public func createLinkResolver(notes: [NoteRecord], root: String? = nil) -> LinkResolver {
    LinkResolver(notes: notes, root: root)
}

// MARK: - Backlinks

public struct LinkedBacklink: Sendable, Hashable {
    public var path: String
    public var title: String
    public var relative: String
    /// UTF-16 offset of the link in the whole file.
    public var pos: Int
    public var excerpt: String
    /// The link matches several notes, this one among them.
    public var ambiguous: Bool
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct UnlinkedMention: Sendable, Hashable {
    public var path: String
    public var title: String
    public var relative: String
    /// UTF-16 offset and length of the mention in the whole file.
    public var pos: Int
    public var length: Int
    public var text: String
    public var excerpt: String
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct Backlinks: Sendable, Equatable {
    public var linked: [LinkedBacklink] = []
    public var unlinked: [UnlinkedMention] = []
    public static let empty = Backlinks()
}

func rootOf(_ notes: [NoteRecord]) -> String? {
    guard let sample = notes.first, !sample.relative.isEmpty else { return nil }
    let depth = sample.relative.split(separator: "/").count - 1
    var path = dirName(sample.path)
    for _ in 0..<max(0, depth) { path = dirName(path) }
    return path
}

/// Notes linking to a target, and notes mentioning it without a link. Pass the library's cached
/// `resolver` to avoid rebuilding it. Offsets are UTF-16 offsets in the whole file.
public func getBacklinks(notes: [NoteRecord], targetPath: String, resolver: LinkResolver? = nil, root: String? = nil) -> Backlinks {
    let key = normalizedPath(targetPath)
    guard let target = notes.first(where: { normalizedPath($0.path) == key }), !target.isTrashed else { return .empty }
    let linkResolver = resolver ?? createLinkResolver(notes: notes, root: root ?? rootOf(notes))
    var linked: [LinkedBacklink] = []
    var unlinked: [UnlinkedMention] = []
    let name = Rx(#"\.[^.]+\z"#).replace(baseName(target.path), template: "")
    var seenTerms = Set<String>()
    var termList: [String] = []
    for candidate in [name, target.title] + aliasesOf(target.properties) {
        let term = candidate.jsTrimmed
        if !term.isEmpty, seenTerms.insert(term).inserted { termList.append(term) }
    }
    let terms = termList.stableSorted { $1.utf16Length - $0.utf16Length }
        .map { (term: $0, matcher: Rx(Rx.escape($0), [.caseInsensitive]), units: Array($0.utf16)) }

    for note in notes where note.path != target.path && !note.isTrashed {
        let links = note.linkSpans
        let body = note.text.utf16Slice(note.bodyOffset)
        let bodyUnits = Array(body.utf16)
        let bodyOffset = note.bodyOffset
        var linkedSpans: [(Int, Int)] = []
        for link in links {
            let result = linkResolver.resolve(from: note.path, link.target)
            var ambiguous = false
            var hit = false
            switch result {
            case .note(let brief, _): hit = brief.path == target.path
            case .ambiguous(let briefs, _): ambiguous = briefs.contains { $0.path == target.path }; hit = ambiguous
            default: break
            }
            if hit {
                linkedSpans.append((link.start, link.end))
                linked.append(LinkedBacklink(
                    path: note.path, title: note.title, relative: note.relative, pos: bodyOffset + link.start,
                    excerpt: excerptAt(bodyUnits, pos: link.start, termLength: link.end - link.start), ambiguous: ambiguous))
            }
        }
        let plain = maskCode(body)
        let plainUnits = Array(plain.utf16)
        let plainNS = plain as NSString
        var mentionSpans: [(Int, Int)] = []
        for (_, matcher, units) in terms {
            for match in matcher.matches(plainNS) {
                let start = match.range.location
                let end = start + match.range.length
                if let first = units.first, isWordUnit(first), start > 0, isWordUnit(plainUnits[start - 1]) { continue }
                if let last = units.last, isWordUnit(last), end < plainUnits.count, isWordUnit(plainUnits[end]) { continue }
                if linkedSpans.contains(where: { start < $0.1 && end > $0.0 }) { continue }
                // Suppress matches inside any Markdown link syntax, even when that link points elsewhere.
                if links.contains(where: { start < $0.end && end > $0.start }) { continue }
                if mentionSpans.contains(where: { start < $0.1 && end > $0.0 }) { continue }
                mentionSpans.append((start, end))
                unlinked.append(UnlinkedMention(
                    path: note.path, title: note.title, relative: note.relative, pos: bodyOffset + start,
                    length: match.range.length, text: plainNS.substring(with: match.range),
                    excerpt: excerptAt(plainUnits, pos: start, termLength: match.range.length)))
            }
        }
    }
    linked = linked.stableSorted { localeCompare($0.relative, $1.relative) != 0 ? localeCompare($0.relative, $1.relative) : $0.pos - $1.pos }
    unlinked = unlinked.stableSorted { localeCompare($0.relative, $1.relative) != 0 ? localeCompare($0.relative, $1.relative) : $0.pos - $1.pos }
    return Backlinks(linked: linked, unlinked: unlinked)
}

// MARK: - Quick open

/// Score for a quick-open match: a substring scores high (more at the start), otherwise the
/// characters must appear in order; -1 for no match.
public func fuzzyScore(_ haystack: String, _ query: String) -> Int {
    let value = Array(haystack.lowercased().utf16)
    let needle = query.lowercased()
    let whole = Array(needle.utf16)
    let at = indexOf(value, whole)
    if at >= 0 { return at == 0 ? 1000 + whole.count : 700 + whole.count - at }
    var cursor = 0, score = 0, run = 0
    for scalar in needle.unicodeScalars {
        let found = indexOf(value, Array(String(scalar).utf16), from: cursor)
        if found < 0 { return -1 }
        if found == cursor { run += 1; score += 12 + run * 2 } else { run = 0; score += Swift.max(1, 8 - (found - cursor)) }
        cursor = found + 1
    }
    return score
}

/// Fuzzy title, file name and path search for a quick-open list; everything sorted by title for an empty query.
public func filterNotes<Note: NoteNaming>(_ notes: [Note], query: String) -> [Note] {
    let needle = query.jsTrimmed
    func byTitle(_ a: Note, _ b: Note) -> Int {
        let order = localeCompare(a.title, b.title)
        return order != 0 ? order : localeCompare(a.relative, b.relative)
    }
    if needle.isEmpty { return notes.stableSorted(by: byTitle) }
    let scored = notes.compactMap { note -> (Note, Int)? in
        let score = [note.name, note.title, note.relative].map { fuzzyScore($0, needle) }.max() ?? -1
        return score >= 0 ? (note, score) : nil
    }
    return scored.stableSorted { $0.1 != $1.1 ? $1.1 - $0.1 : byTitle($0.0, $1.0) }.map(\.0)
}

// MARK: - Tags

/// Tag counts including ancestor tags (`a/b` also counts under `a`), sorted case-insensitively.
public func getTags(_ notes: [NoteRecord]) -> [TagCount] {
    tagCounts(notes.map(\.tags))
}

func tagCounts(_ tagLists: [[String]]) -> [TagCount] {
    var order: [String] = []
    var counts: [String: TagCount] = [:]
    for tags in tagLists {
        var perNoteOrder: [String] = []
        var perNote: [String: String] = [:]
        for tag in uniqueTags(tags) {
            let parts = tag.split(separator: "/").map(String.init)
            if parts.isEmpty { continue }
            for level in 1...parts.count {
                let ancestor = parts[0..<level].joined(separator: "/")
                let key = normalizedTag(ancestor)
                if perNote[key] == nil { perNoteOrder.append(key) }
                perNote[key] = ancestor
            }
        }
        for key in perNoteOrder {
            if var current = counts[key] { current.count += 1; counts[key] = current } else {
                counts[key] = TagCount(tag: perNote[key] ?? key, count: 1)
                order.append(key)
            }
        }
    }
    return order.compactMap { counts[$0] }.stableSorted {
        switch $0.tag.compare($1.tag, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: .current) {
        case .orderedAscending: return -1
        case .orderedSame: return 0
        case .orderedDescending: return 1
        }
    }
}

// MARK: - Attachments

public struct AttachmentReference: Sendable, Hashable {
    public var reference: String
    public var path: String
    public var size: Int
}

public struct MissingAttachment: Sendable, Hashable {
    public var reference: String
    public var path: String
    /// `"outside-workspace"` when the reference escapes the library folder.
    public var reason: String?
}

public struct AttachmentReport: Sendable, Equatable {
    public var referenced: [AttachmentReference] = []
    public var missing: [MissingAttachment] = []
}

private func realPathWithin(_ root: String, _ candidate: String) -> String? {
    guard let realRoot = realPath(root) else { return nil }
    var existing = candidate
    while true {
        if let realExisting = realPath(existing) {
            if !pathIsInside(realRoot, realExisting) { return nil }
            if existing == candidate { return realExisting }
            return pathIsInside(realRoot, candidate) ? candidate : nil
        }
        if errno != ENOENT && errno != ENOTDIR { return nil }
        let parent = dirName(existing)
        if parent == existing { return nil }
        existing = parent
    }
}

func inspectAttachments(of note: NoteRecord, root rawRoot: String) -> AttachmentReport {
    let root = normalizedPath(rawRoot)
    var report = AttachmentReport()
    for reference in note.images {
        if schemeLikeReference.test(reference) { continue }
        let decoded = reference.removingPercentEncoding ?? reference
        let clean = decoded.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? decoded
        let candidate = resolvePath(dirName(note.path), clean)
        if !pathIsInside(root, candidate) {
            report.missing.append(MissingAttachment(reference: reference, path: candidate, reason: "outside-workspace"))
            continue
        }
        guard let safe = realPathWithin(root, candidate) else {
            report.missing.append(MissingAttachment(reference: reference, path: candidate, reason: nil))
            continue
        }
        if let stat = fileStat(safe), stat.isFile {
            report.referenced.append(AttachmentReference(reference: reference, path: safe, size: stat.size))
        } else {
            report.missing.append(MissingAttachment(reference: reference, path: safe, reason: nil))
        }
    }
    return report
}

private let schemeLikeReference = Rx(#"^(?:[a-z][a-z0-9+.-]*:|//|data:)"#, [.caseInsensitive])

/// Local image files referenced by one note, without following paths outside the library folder.
public func inspectAttachments(notes: [NoteRecord], root: String, targetPath: String) -> AttachmentReport {
    let key = normalizedPath(targetPath)
    guard let note = notes.first(where: { normalizedPath($0.path) == key }) else { return AttachmentReport() }
    return inspectAttachments(of: note, root: root)
}
