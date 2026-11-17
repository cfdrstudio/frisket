import Foundation
import FrisketBase

/// A sidebar selection.
public enum LibraryFilter: Equatable, Hashable, Sendable {
    /// Every active (not trashed) note.
    case notes
    /// Active notes without tags.
    case untagged
    /// Active notes with open tasks.
    case todo
    /// Active, pinned notes.
    case pinned
    /// Trashed notes.
    case trash
    /// Active notes carrying the tag or a tag below it (`work` also selects `work/projects`).
    case tag(String)
    /// Active notes whose relative path is inside this folder (`""` is the root); recursive.
    case folder(String)

    public func matches(_ note: NoteSummary) -> Bool {
        let active = note.trashedAt == nil
        switch self {
        case .notes: return active
        case .untagged: return active && note.tags.isEmpty
        case .todo: return active && note.tasksDone < note.tasksTotal
        case .pinned: return active && note.pinned
        case .trash: return !active
        case .tag(let selected): return active && note.tags.contains { isDescendantTag($0, of: selected) }
        case .folder(let directory):
            guard active else { return false }
            var folder = directory.replacingOccurrences(of: "\\", with: "/")
            while folder.hasPrefix("/") { folder.removeFirst() }
            while folder.hasSuffix("/") { folder.removeLast() }
            if folder.isEmpty || folder == "." { return true }
            return note.relative.hasPrefix(folder + "/")
        }
    }

    public func filter(_ summaries: [NoteSummary]) -> [NoteSummary] { summaries.filter(matches) }

    public static func filter(_ summaries: [NoteSummary], by filter: LibraryFilter) -> [NoteSummary] {
        filter.filter(summaries)
    }
}

/// How the note list is ordered. Putting pinned notes first is up to the app.
public enum LibrarySort: Equatable, Hashable, Sendable {
    case modified, created, title

    /// Newest first for dates, A to Z for titles, unless `ascending` says otherwise. Stable.
    public func sorted(_ summaries: [NoteSummary], ascending: Bool? = nil) -> [NoteSummary] {
        let up = ascending ?? (self == .title)
        return summaries.stableSorted { a, b in
            let order: Int
            switch self {
            case .modified: order = a.modifiedAt < b.modifiedAt ? -1 : (a.modifiedAt > b.modifiedAt ? 1 : 0)
            case .created: order = a.createdAt < b.createdAt ? -1 : (a.createdAt > b.createdAt ? 1 : 0)
            case .title:
                let byTitle = numericCompare(a.title, b.title)
                order = byTitle != 0 ? byTitle : numericCompare(a.relative, b.relative)
            }
            return up ? order : -order
        }
    }

    public static func sorted(_ summaries: [NoteSummary], by mode: LibrarySort, ascending: Bool? = nil) -> [NoteSummary] {
        mode.sorted(summaries, ascending: ascending)
    }
}

/// `filterLibraryNotes` of the JavaScript app: summaries of `notes` under a sidebar filter.
public func filterLibraryNotes(_ notes: [NoteRecord], filter: LibraryFilter = .notes) -> [NoteSummary] {
    filter.filter(summarizeNotes(notes))
}

/// Search title, file name, path, tags and body with `@todo`, `@images` and `#tag` operators.
/// Pass `summaries` (in the same order as `notes`) to reuse them. Trashed notes are left out
/// unless `includeTrashed` is set.
public func searchLibrary(_ notes: [NoteRecord], query: String = "", summaries: [NoteSummary]? = nil,
                          includeTrashed: Bool = false) -> [NoteSummary] {
    let summaries = summaries ?? summarizeNotes(notes)
    let parsed = parseSearchQuery(query)
    var out: [NoteSummary] = []
    for (summary, note) in zip(summaries, notes) {
        if searchMatches(summary: summary, query: parsed, includeTrashed: includeTrashed,
                         prose: { maskNonProse(splitFrontMatter(note.text).body).lowercased() }) {
            out.append(summary)
        }
    }
    return out
}

func searchMatches(summary note: NoteSummary, query: SearchQuery, includeTrashed: Bool, prose: () -> String) -> Bool {
    if note.trashedAt != nil && !includeTrashed { return false }
    if query.todo && note.tasksDone >= note.tasksTotal { return false }
    if query.images && !note.hasImages { return false }
    for tag in query.tags where !note.tags.contains(where: { isDescendantTag($0, of: tag) }) { return false }
    if query.terms.isEmpty { return true }
    let head = ([note.title, note.name, note.relative] + note.tags).joined(separator: " ").lowercased()
    let haystack = (head + " " + prose()) as NSString
    for term in query.terms where haystack.range(of: term, options: .literal).location == NSNotFound { return false }
    return true
}
