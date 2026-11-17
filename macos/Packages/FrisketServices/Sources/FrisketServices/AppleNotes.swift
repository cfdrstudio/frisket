import Foundation
import FrisketBase

/// One note as the Notes app reports it through JavaScript for Automation.
public struct AppleNote: Sendable, Equatable, Decodable {
    public var account: String
    public var folder: String
    public var name: String?
    public var locked: Bool
    /// HTML body, nil for locked notes.
    public var body: String?
    public var created: String?
    public var modified: String?

    public init(account: String, folder: String, name: String?, locked: Bool, body: String?, created: String?, modified: String?) {
        self.account = account
        self.folder = folder
        self.name = name
        self.locked = locked
        self.body = body
        self.created = created
        self.modified = modified
    }
}

/// Apple Notes reader (macOS only). Notes has no export format, so this asks
/// the Notes app for each note's HTML body through JavaScript for Automation.
/// The first run triggers macOS's "wants to control Notes" prompt. Locked notes
/// cannot be read and are reported as skipped; Recently Deleted is left out.
public enum AppleNotesReader {
    /// The JXA program, identical to the original.
    public static let script = """

    const Notes = Application('Notes');
    const out = [];
    for (const account of Notes.accounts()) {
      const accountName = account.name();
      for (const folder of account.folders()) {
        const folderName = folder.name();
        if (folderName === 'Recently Deleted') continue;
        const notes = folder.notes;
        const names = notes.name();
        if (!names.length) continue;
        const locked = notes.passwordProtected();
        const created = notes.creationDate();
        const modified = notes.modificationDate();
        const bodies = notes.body();
        for (let i = 0; i < names.length; i++) {
          out.push({
            account: accountName, folder: folderName, name: names[i], locked: !!locked[i],
            body: locked[i] ? null : bodies[i],
            created: created[i] ? created[i].toISOString() : null,
            modified: modified[i] ? modified[i].toISOString() : null,
          });
        }
      }
    }
    JSON.stringify(out);

    """

    /// Ask the Notes app for every note. `timeout` bounds the whole run, including
    /// the time the user takes to answer the first-run permission prompt.
    public static func read(timeout: TimeInterval = 600) async throws -> [AppleNote] {
        let result: ProcessResult
        do {
            result = try await runProcess("/usr/bin/osascript", ["-l", "JavaScript", "-e", script], timeout: timeout)
        } catch {
            throw ImportError("Could not read Apple Notes: \(error.localizedDescription)")
        }
        if result.timedOut { throw ImportError("Apple Notes did not answer in time. Try again.") }
        if result.status != 0 {
            let detail = String(decoding: result.stderr, as: UTF8.self)
            if Rx("not allowed|not authori[sz]ed|-1743", [.caseInsensitive]).test(detail) {
                throw ImportError("Frisket is not allowed to read Notes. Allow it in System Settings › Privacy & Security › Automation, then try again.")
            }
            throw ImportError("Could not read Apple Notes: " + detail.jsTrimmed)
        }
        return try parse(json: result.stdout)
    }

    /// Parse the script's JSON output.
    public static func parse(json: String) throws -> [AppleNote] { try parse(json: Data(json.utf8)) }

    public static func parse(json: Data) throws -> [AppleNote] {
        do { return try JSONDecoder().decode([AppleNote].self, from: json) }
        catch { throw ImportError("Apple Notes returned data Frisket could not read.") }
    }

    /// Turn raw notes into importable ones. Locked notes (or ones with no body) are
    /// skipped. Folders are `[account, folder]` when there is more than one account.
    public static func importable(_ raw: [AppleNote]) -> (notes: [ImportedNote], skipped: [SkippedNote]) {
        let accounts = Set(raw.map(\.account))
        var notes: [ImportedNote] = []
        var skipped: [SkippedNote] = []
        for (index, note) in raw.enumerated() {
            guard !note.locked, let body = note.body else {
                skipped.append(SkippedNote(title: note.name ?? "", reason: "locked"))
                continue
            }
            let name = note.name ?? ""
            notes.append(ImportedNote(
                key: "apple-\(index)", title: name.isEmpty ? "Untitled" : name, html: body,
                created: note.created, updated: note.modified, tags: [],
                folder: accounts.count > 1 ? [note.account, note.folder] : [note.folder]))
        }
        return (notes, skipped)
    }
}
