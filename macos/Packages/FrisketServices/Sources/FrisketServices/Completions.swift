import Foundation
import FrisketBase

/// The text before the caret that triggers a completion. `start` is the UTF-16 offset of `query`.
public struct CompletionContext: Equatable, Sendable {
    public var query: String
    public var start: Int
}

/// A note as completions see it, taken from the library overview. `linkText` is
/// the shortest target that resolves uniquely to the note, so what is inserted
/// is exactly what the link resolver will follow.
public struct CompletionNote: Sendable {
    public var title: String
    public var linkText: String?
    /// File name, e.g. `one.md`.
    public var name: String
    /// Library-relative path, e.g. `a/one.md`.
    public var relative: String
    public var path: String
    public var aliases: [String]
    /// ISO-8601 time; newer notes win ties.
    public var modifiedAt: String?
    public var trashedAt: String?

    public init(title: String, linkText: String?, name: String, relative: String, path: String,
                aliases: [String] = [], modifiedAt: String? = nil, trashedAt: String? = nil) {
        self.title = title
        self.linkText = linkText
        self.name = name
        self.relative = relative
        self.path = path
        self.aliases = aliases
        self.modifiedAt = modifiedAt
        self.trashedAt = trashedAt
    }
}

/// A `[[note` suggestion. Picking an alias links to the note and keeps the alias as the visible text.
public struct NoteCompletion: Equatable, Sendable {
    public var label: String
    public var detail: String
    public var insert: String
    public var alias: String?
    public var path: String
}

public struct TagCount: Sendable {
    public var tag: String
    public var count: Int
    public init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
    }
}

public struct TagCompletion: Equatable, Sendable {
    public var label: String
    public var detail: String
    public var insert: String
}

/// How to apply a note completion: replace `replace` UTF-16 units after the
/// caret with `text`, then put the caret `cursor` units after the start.
public struct WikiInsertion: Equatable, Sendable {
    public var text: String
    public var replace: Int
    public var cursor: Int
}

/// Pure helpers for `[[note` and `#tag` autocompletion (no editor glue). Port of completions.mjs.
public enum Completions {
    private static let wikiContext = Rx("\\[\\[([^\\[\\]|#\\n]*)\\z")
    // Same boundary as the tag parser, plus `&` and `\` for entities and escapes.
    private static let tagContextPattern = Rx("(?:^|[^\\p{L}\\p{N}_/&#\\\\])#([\\p{L}\\p{N}_\\-/]+)\\z")
    private static let headingLine = Rx("^\\s{0,3}#{1,6}\\s")

    private static func fold(_ value: String?) -> String {
        (value ?? "").precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `[[query` immediately before the caret, or nil.
    public static func wikiLinkContext(_ before: String) -> CompletionContext? {
        guard let match = wikiContext.first(before), let query = match.group(1, in: before) else { return nil }
        return CompletionContext(query: query, start: before.utf16Length - query.utf16Length)
    }

    /// `#query` (at least one character) immediately before the caret, outside headings.
    public static func tagContext(_ before: String) -> CompletionContext? {
        if headingLine.test(before) { return nil }
        guard let match = tagContextPattern.first(before), let query = match.group(1, in: before) else { return nil }
        return CompletionContext(query: query, start: before.utf16Length - query.utf16Length)
    }

    /// Higher is better; -1 means no match. Prefix beats word start beats substring beats subsequence.
    public static func matchScore(_ field: String?, _ query: String) -> Int {
        let value = fold(field)
        let needle = fold(query).jsTrimmed
        if needle.isEmpty { return 0 }
        if value.isEmpty { return -1 }
        let ns = value as NSString
        if ns.range(of: needle, options: [.literal, .anchored]).location != NSNotFound { return 1000 - ns.length }
        let at = ns.range(of: needle, options: [.literal]).location
        if at != NSNotFound, at > 0 {
            let before = ns.substring(with: NSRange(location: at - 1, length: 1))
            return (Rx("[\\s/_-]").test(before) ? 800 : 600) - at
        }
        var cursor = 0
        var score = 0
        for scalar in needle.unicodeScalars {
            let char = String(scalar)
            guard cursor <= ns.length else { return -1 }
            let found = ns.range(of: char, options: [.literal], range: NSRange(location: cursor, length: ns.length - cursor)).location
            if found == NSNotFound { return -1 }
            score += found == cursor ? 6 : 1
            cursor = found + 1
        }
        return score
    }

    private static func folder(of relative: String) -> String {
        var parts = relative.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    /// Notes matching `query`, best first. Trashed notes and notes without link text are skipped.
    public static func noteCompletions(_ notes: [CompletionNote], query: String, limit: Int = 50) -> [NoteCompletion] {
        struct Field { var text: String; var isAlias: Bool }
        struct Ranked { var note: CompletionNote; var score: Int; var field: Field; var order: Int }
        var ranked: [Ranked] = []
        for note in notes {
            if let trashed = note.trashedAt, !trashed.isEmpty { continue }
            guard let link = note.linkText, !link.isEmpty else { continue }
            let fileName = Rx("\\.[^.]+\\z").replace(note.name, template: "")
            let fields = [Field(text: note.title, isAlias: false)] + note.aliases.map { Field(text: $0, isAlias: true) } + [Field(text: fileName, isAlias: false)]
            var best: (score: Int, field: Field)?
            for field in fields {
                let score = matchScore(field.text, query)
                if score >= 0, best == nil || score > best!.score { best = (score, field) }
            }
            if let best { ranked.append(Ranked(note: note, score: best.score, field: best.field, order: ranked.count)) }
        }
        func modified(_ note: CompletionNote) -> Double {
            note.modifiedAt.flatMap(parseISODate)?.timeIntervalSince1970 ?? 0
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let ma = modified(a.note), mb = modified(b.note)
            if ma != mb { return ma > mb }
            let order = a.note.title.localizedCompare(b.note.title)
            if order != .orderedSame { return order == .orderedAscending }
            return a.order < b.order
        }
        return ranked.prefix(limit).map { item in
            let note = item.note
            let title = note.title.isEmpty ? (note.linkText ?? "") : note.title
            let alias = item.field.isAlias ? item.field.text : (note.linkText == title ? nil : title)
            return NoteCompletion(
                label: item.field.isAlias ? item.field.text : title,
                detail: item.field.isAlias ? "→ " + title : folder(of: note.relative),
                insert: note.linkText ?? "",
                alias: alias,
                path: note.path)
        }
    }

    /// Existing tags matching `query`, excluding an exact match so Enter still ends the line.
    public static func tagCompletions(_ tags: [TagCount], query: String, limit: Int = 30) -> [TagCompletion] {
        let needle = fold(query)
        var ranked: [(tag: String, count: Int, score: Int, order: Int)] = []
        for item in tags {
            let value = fold(item.tag)
            if value.isEmpty || value == needle { continue }
            let ns = value as NSString
            let score: Int
            if ns.range(of: needle, options: [.literal, .anchored]).location != NSNotFound { score = 3 }
            else if ns.range(of: "/" + needle, options: [.literal]).location != NSNotFound { score = 2 }
            else if ns.range(of: needle, options: [.literal]).location != NSNotFound { score = 1 }
            else { continue }
            ranked.append((item.tag, item.count, score, ranked.count))
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.count != b.count { return a.count > b.count }
            let order = a.tag.localizedCompare(b.tag)
            if order != .orderedSame { return order == .orderedAscending }
            return a.order < b.order
        }
        return ranked.prefix(limit).map { TagCompletion(label: $0.tag, detail: String($0.count), insert: $0.tag) }
    }

    private static let existingClose = Rx("^([^\\[\\]|#\\n]*)(\\]\\]|\\||#[^\\[\\]\\n]*\\]\\])")

    /// How to apply a note completion given the text after the caret on its line.
    /// Reuses a `]]` that auto-pairing already typed, keeps an existing `|alias` or
    /// `#anchor` when editing a link, and otherwise closes the link itself.
    public static func wikiInsertion(insert: String, alias: String?, after: String) -> WikiInsertion {
        let aliasPart = alias.map { "|" + $0 } ?? ""
        if let match = existingClose.first(after) {
            let tail = match.group(1, in: after) ?? ""
            let next = match.group(2, in: after) ?? ""
            if next == "]]" {
                let text = insert + aliasPart
                return WikiInsertion(text: text, replace: tail.utf16Length, cursor: text.utf16Length + 2)
            }
            return WikiInsertion(text: insert, replace: tail.utf16Length, cursor: insert.utf16Length)
        }
        let text = insert + aliasPart + "]]"
        return WikiInsertion(text: text, replace: 0, cursor: text.utf16Length)
    }

    public static func wikiInsertion(_ option: NoteCompletion, after: String) -> WikiInsertion {
        wikiInsertion(insert: option.insert, alias: option.alias, after: after)
    }
}
