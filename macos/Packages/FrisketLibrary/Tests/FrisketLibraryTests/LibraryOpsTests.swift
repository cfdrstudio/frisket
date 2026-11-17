import XCTest
import FrisketBase
@testable import FrisketLibrary

final class LibraryOpsTests: XCTestCase {
    private func openIndex(_ root: String) async -> LibraryIndex {
        let index = LibraryIndex(root: u(root), hostName: "host")
        await index.refresh()
        return index
    }

    private let day = dateFromMs(1_792_054_800_000)  // 2026-10-15T09:00:00.000Z

    func testCreateNoteWritesFrontMatterAndPicksAUniqueName() async throws {
        let root = try makeTempDir()
        let index = await openIndex(root)
        let first = try await index.createNote(title: "  My First: Note!  ", now: day)
        XCTAssertEqual(first.path, root + "/Notes/2026-10-15-my-first-note.md")
        let text = try read(first.path)
        XCTAssertTrue(text.hasPrefix("---\nfrisket-id: "))
        XCTAssertTrue(text.contains("\nfrisket-created: 2026-10-15T09:00:00.000Z\n---\n\n# My First: Note!\n\n"))
        let second = try await index.createNote(title: "My First: Note!", now: day)
        XCTAssertEqual(second.lastPathComponent, "2026-10-15-my-first-note-1.md")
        let untitled = try await index.createNote(title: "!!!", now: day)
        XCTAssertEqual(untitled.lastPathComponent, "2026-10-15-untitled.md")
        let snapshot = await index.snapshot()
        XCTAssertEqual(snapshot.summaries.count, 3, "created notes are indexed")
    }

    func testTrashRestoreAndDelete() async throws {
        let root = try makeTempDir()
        let note = try write(root, "Notes/a.md", "---\nfrisket-id: abc\n---\n# A\n")
        let index = await openIndex(root)

        do { try await index.deleteNote(u(note)); XCTFail("active notes cannot be deleted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("Only notes in this library Trash"))
        }
        try await index.trashNote(u(note))
        XCTAssertTrue(try read(note).contains("frisket-trashed-at: "))
        var snapshot = await index.snapshot()
        XCTAssertTrue(snapshot.summaries[0].isTrashed)
        XCTAssertEqual(try HistoryStore.list(file: u(note), text: "---\nfrisket-id: abc\n---\n", libraryRoot: u(root)).count, 1)

        try await index.restoreNote(u(note))
        XCTAssertEqual(try read(note), "---\nfrisket-id: abc\n---\n# A\n")
        snapshot = await index.snapshot()
        XCTAssertFalse(snapshot.summaries[0].isTrashed)

        try await index.trashNote(u(note))
        try await index.deleteNote(u(note))
        XCTAssertFalse(FileManager.default.fileExists(atPath: note))
        let left = await index.snapshot().summaries.count
        XCTAssertEqual(left, 0)
        XCTAssertGreaterThanOrEqual(try HistoryStore.list(file: u(note), text: "---\nfrisket-id: abc\n---\n", libraryRoot: u(root)).count, 2)
    }

    func testLegacyTrashFolderRestoresAndDeletes() async throws {
        let root = try makeTempDir()
        let old = try write(root, ".frisket/Trash/Sub/old.md", "# Old\n")
        let index = await openIndex(root)
        let before = await index.snapshot()
        XCTAssertEqual(before.summaries.map(\.isTrashed), [true])
        let restored = try await index.restoreNote(u(old))
        XCTAssertEqual(restored.path, root + "/Sub/old.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/Sub/old.md"))
        let after = await index.snapshot()
        XCTAssertEqual(after.summaries.map(\.isTrashed), [false])

        let other = try write(root, ".frisket/Trash/gone.md", "# Gone\n")
        await index.refresh()
        try await index.deleteNote(u(other))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other))
    }

    func testTrashRefusesFilesOutsideTheLibraryAndItsHiddenFolder() async throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        let stray = try write(outside, "x.md", "# X\n")
        let hidden = try write(root, ".frisket/history/x.md", "# H\n")
        let index = await openIndex(root)
        for path in [stray, hidden] {
            do { try await index.trashNote(u(path)); XCTFail() } catch {
                XCTAssertTrue(error.localizedDescription.contains("Only active notes"))
            }
        }
    }

    func testDailyNoteCreatesOnceAndUsesTheTemplateBody() async throws {
        let root = try makeTempDir()
        let index = await openIndex(root)
        let first = try await index.dailyNote(date: "2026-10-15", body: "# Daily {{date}}\n\n- [ ] plan\n")
        XCTAssertTrue(first.created)
        XCTAssertEqual(first.url.path, root + "/Daily/2026-10-15.md")
        let text = try read(first.url.path)
        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(text.contains("frisket-id: "))
        XCTAssertTrue(text.contains("frisket-created: "))
        XCTAssertTrue(text.hasSuffix("# Daily {{date}}\n\n- [ ] plan\n"))
        let second = try await index.dailyNote(date: "2026-10-15", body: "ignored")
        XCTAssertFalse(second.created)
        XCTAssertEqual(try read(first.url.path), text)
        let blank = try await index.dailyNote(date: "2026-10-16", body: "   ")
        XCTAssertTrue(try read(blank.url.path).hasSuffix("# 2026-10-16\n\n"))
        do { _ = try await index.dailyNote(date: "2026-1-5"); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid date.")
        }
    }

    func testTemplatesListAndSave() async throws {
        let root = try makeTempDir()
        let index = await openIndex(root)
        let none = try await index.templates()
        XCTAssertEqual(none, [])
        try await index.saveTemplate(name: "Meeting.md", contents: "# Meeting\n")
        try await index.saveTemplate(name: "Agenda", contents: "# Agenda\n")
        try write(root, "Templates/readme.pdf", "x")
        try write(root, "Templates/huge.md", String(repeating: "x", count: 256 * 1024 + 1))
        let listed = try await index.templates()
        XCTAssertEqual(listed, [NoteTemplate(name: "Agenda.md", contents: "# Agenda\n"), NoteTemplate(name: "Meeting.md", contents: "# Meeting\n")])
        do { try await index.saveTemplate(name: "Meeting", contents: "again"); XCTFail("exists") } catch {}
        do { try await index.saveTemplate(name: "a/b", contents: "x"); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("short file name"))
        }
        do { try await index.saveTemplate(name: "Big", contents: String(repeating: "x", count: 256 * 1024 + 1)); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("256 KB"))
        }
    }

    func testCaptureWritesInboxNote() async throws {
        let root = try makeTempDir()
        let index = await openIndex(root)
        let file = try await index.capture(title: "Quick idea!", body: "Remember the milk", now: day)
        XCTAssertEqual(file.path, root + "/Inbox/2026-10-15T09-00-00-000Z-quick-idea.md")
        XCTAssertEqual(try read(file.path), "# Quick idea!\n\nRemember the milk\n")
        let untitled = try await index.capture(title: nil, body: nil, now: day.addingTimeInterval(1))
        XCTAssertTrue(untitled.lastPathComponent.hasSuffix("-untitled.md"))
    }

    func testCreateLinkedNote() async throws {
        let root = try makeTempDir()
        let index = await openIndex(root)
        let target = u(root + "/Deep/er/Missing Note.md")
        let made = try await index.createLinkedNote(at: target)
        XCTAssertEqual(try read(made.path), "# Missing Note\n\n")
        let again = try await index.createLinkedNote(at: target, title: "Other")
        XCTAssertEqual(again, target)
        XCTAssertEqual(try read(made.path), "# Missing Note\n\n", "an existing note is untouched")
        let titled = try await index.createLinkedNote(at: u(root + "/Titled.md"), title: "Custom")
        XCTAssertEqual(try read(titled.path), "# Custom\n\n")
        let link = await index.resolveLink("Missing Note")
        XCTAssertEqual(link.note?.path, target.path)
    }

    func testPlainSearchFindsLinesAndDelegatesOperatorsToTheIndex() async throws {
        let root = try makeTempDir()
        try write(root, "a.md", "# Alpha\n😀 The quick Fox jumps\nnothing\nfox again\nshared\n")
        try write(root, "b.md", "# Beta\n- [ ] open #work task\nshared\n")
        try write(root, ".hidden/c.md", "fox hidden\n")
        let index = await openIndex(root)

        let plain = try await index.plainSearch(query: "fox")
        XCTAssertEqual(plain.results.map(\.relative), ["a.md"])
        XCTAssertEqual(plain.results[0].matches.map(\.line), [2, 4])
        let hit = plain.results[0].matches[0]
        XCTAssertEqual(hit.column, "😀 The quick ".utf16.count)
        let text = try read(root + "/a.md") as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: hit.pos, length: 3)), "Fox")
        XCTAssertFalse(plain.truncated)

        let sensitive = try await index.plainSearch(query: "fox", caseSensitive: true)
        XCTAssertEqual(sensitive.results[0].matches.map(\.line), [4])
        let short = try await index.plainSearch(query: "f")
        XCTAssertTrue(short.results.isEmpty)

        let todo = try await index.plainSearch(query: "@todo")
        XCTAssertEqual(todo.results.map(\.relative), ["b.md"])
        XCTAssertEqual(todo.results[0].matches[0].line, 2)
        let tagged = try await index.plainSearch(query: "#work")
        XCTAssertEqual(tagged.results.map(\.relative), ["b.md"])

        let limited = try await index.plainSearch(query: "shared", maxFiles: 2000, maxResults: 1)
        XCTAssertEqual(limited.results.count, 1)
        XCTAssertTrue(limited.truncated)
    }

    func testRewriteRefusesWhenTheFileChangedUnderneath() async throws {
        let root = try makeTempDir()
        let note = try write(root, "a.md", "# A\n")
        let index = await openIndex(root)
        do {
            try await index.rewrite(u(note)) { text in
                try? "# Changed elsewhere\n".write(toFile: note, atomically: false, encoding: .utf8)
                try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: note)
                return text + "more"
            }
            XCTFail("should refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed on disk"))
        }
        XCTAssertEqual(try read(note), "# Changed elsewhere\n")
    }

    // MARK: LibraryFilter

    private func summaries() throws -> [NoteSummary] {
        let root = try makeTempDir()
        try write(root, "Inbox/one.md", "---\ntags: [work]\nfrisket-pinned: true\n---\n# One\n- [ ] task\n", mtime: Date(timeIntervalSince1970: 1_000))
        try write(root, "Inbox/Deep/two.md", "# Two\n#work/projects\n", mtime: Date(timeIntervalSince1970: 3_000))
        try write(root, "Inboxed.md", "# Three\n", mtime: Date(timeIntervalSince1970: 2_000))
        try write(root, "four.md", "---\nfrisket-trashed-at: 2026-01-01T00:00:00Z\nfrisket-pinned: true\n---\n# Four\n")
        return summarizeNotes(try scanWorkspace(folder: u(root)).notes)
    }

    func testLibraryFilters() throws {
        let all = try summaries()
        func names(_ filter: LibraryFilter) -> [String] { filter.filter(all).map(\.title).sorted() }
        XCTAssertEqual(names(.notes), ["One", "Three", "Two"])
        XCTAssertEqual(names(.untagged), ["Three"])
        XCTAssertEqual(names(.todo), ["One"])
        XCTAssertEqual(names(.pinned), ["One"])
        XCTAssertEqual(names(.trash), ["Four"])
        XCTAssertEqual(names(.tag("WORK")), ["One", "Two"])
        XCTAssertEqual(names(.tag("work/projects")), ["Two"])
        XCTAssertEqual(names(.folder("")), ["One", "Three", "Two"])
        XCTAssertEqual(names(.folder("Inbox")), ["One", "Two"])
        XCTAssertEqual(names(.folder("Inbox/")), ["One", "Two"])
        XCTAssertEqual(names(.folder("Inbox/Deep")), ["Two"])
        XCTAssertEqual(LibraryFilter.filter(all, by: .pinned).count, 1)
    }

    func testLibrarySorting() throws {
        let all = LibraryFilter.notes.filter(try summaries())
        XCTAssertEqual(LibrarySort.modified.sorted(all).map(\.title), ["Two", "Three", "One"])
        XCTAssertEqual(LibrarySort.modified.sorted(all, ascending: true).map(\.title), ["One", "Three", "Two"])
        XCTAssertEqual(LibrarySort.title.sorted(all).map(\.title), ["One", "Three", "Two"])
        XCTAssertEqual(LibrarySort.sorted(all, by: .title, ascending: false).map(\.title), ["Two", "Three", "One"])
        XCTAssertEqual(LibrarySort.created.sorted(all).count, 3)
    }
}
