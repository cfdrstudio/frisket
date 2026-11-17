import Foundation

/// Which application an import reads from.
public enum ImportKind: String, Sendable, CaseIterable {
    case evernote
    case notion
    case appleNotes = "apple-notes"

    /// The name used in the `Imported/<Source> YYYY-MM-DD` folder.
    public var label: String {
        switch self {
        case .evernote: return "Evernote"
        case .notion: return "Notion"
        case .appleNotes: return "Apple Notes"
        }
    }
}

/// What to import from.
public enum ImportSource: Sendable {
    /// One or more `.enex` files (Evernote).
    case files([URL])
    /// A Notion export: the `.zip` or an extracted folder.
    case folderOrZip(URL)
    /// Apple Notes needs no file; the Notes app is asked directly.
    case none
}

/// An attachment of an imported note (Evernote `<resource>`).
public struct ImportedResource: Sendable, Equatable {
    /// Lower-case MD5 of `data`, the key `<en-media hash="…">` refers to.
    public var hash: String
    public var mime: String
    public var name: String
    public var data: Data
    public init(hash: String, mime: String, name: String, data: Data) {
        self.hash = hash
        self.mime = mime
        self.name = name
        self.data = data
    }
}

/// A note read from any source, in the shape the writer needs.
public struct ImportedNote: Sendable {
    /// Identifies the note within its source (Notion: its path in the export), for link rewriting.
    public var key: String
    public var title: String
    /// File name stem to prefer over `title` (Notion).
    public var fileStem: String?
    /// HTML body (Evernote, Apple Notes); nil for Markdown sources.
    public var html: String?
    /// Markdown body (Notion).
    public var markdown: String?
    /// ISO-8601 creation / modification times, if the source has them.
    public var created: String?
    public var updated: String?
    public var tags: [String]
    /// Folders below the import folder.
    public var folder: [String]
    public var resources: [ImportedResource]
    /// A Notion database (CSV) rendered as a table.
    public var isDatabase: Bool

    public init(key: String, title: String, fileStem: String? = nil, html: String? = nil, markdown: String? = nil,
                created: String? = nil, updated: String? = nil, tags: [String] = [], folder: [String] = [],
                resources: [ImportedResource] = [], isDatabase: Bool = false) {
        self.key = key
        self.title = title
        self.fileStem = fileStem
        self.html = html
        self.markdown = markdown
        self.created = created
        self.updated = updated
        self.tags = tags
        self.folder = folder
        self.resources = resources
        self.isDatabase = isDatabase
    }
}

/// A note that was not imported, and why.
public struct SkippedNote: Sendable, Equatable {
    public var title: String
    public var reason: String
    public init(title: String, reason: String) {
        self.title = title
        self.reason = reason
    }
}

/// The result of an import.
public struct ImportReport: Sendable, Equatable {
    /// Library-relative folder the notes were written to (`Imported/Evernote 2026-10-15`), nil if nothing was found.
    public var folder: String?
    public var notes: Int
    public var attachments: Int
    public var skipped: [SkippedNote]
    public init(folder: String?, notes: Int, attachments: Int, skipped: [SkippedNote]) {
        self.folder = folder
        self.notes = notes
        self.attachments = attachments
        self.skipped = skipped
    }
}

/// A readable import failure.
public struct ImportError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
