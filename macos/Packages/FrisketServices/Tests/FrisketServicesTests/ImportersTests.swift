import XCTest
import CryptoKit
import FrisketBase
@testable import FrisketServices

private let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52])
private let pdf = Data("%PDF-1.4 tiny".utf8)

private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private let enexSource = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE en-export SYSTEM \"http://xml.evernote.com/pub/evernote-export3.dtd\">\n"
    + "<en-export application=\"Evernote\"><note><title>Trip &amp; plan</title><content><![CDATA[<?xml version=\"1.0\"?>"
    + "<!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\"><en-note><div>Trip &amp; plan</div><div>Pack <b>light</b>.</div>"
    + "<div><en-todo checked=\"false\"/>Passport</div><en-media hash=\"" + md5(png)
    + "\" type=\"image/png\"/></en-note>]]></content><created>20240102T030405Z</created><updated>20240203T040506Z</updated>"
    + "<tag>travel</tag><tag>Work/Projects</tag><resource><data encoding=\"base64\">\n" + png.base64EncodedString() + "\n</data>"
    + "<mime>image/png</mime><resource-attributes><file-name>map photo.png</file-name></resource-attributes></resource>"
    + "<resource><data encoding=\"base64\">" + pdf.base64EncodedString() + "</data><mime>application/pdf</mime></resource></note>"
    + "<note><title>Second</title><content><![CDATA[<en-note><div>Hello</div></en-note>]]></content></note></en-export>"

private let id1 = "0123456789abcdef0123456789abcdef"
private let id2 = "fedcba9876543210fedcba9876543210"
private let id3 = "11111111111111111111111111111111"

private func notionFiles() -> [(name: String, data: Data)] {
    [
        ("Export-1a2b3c4d/Plan \(id1).md", Data("# Plan\n\nSee [Child](Plan%20\(id1)/Child%20\(id2).md) and ![diagram](Plan%20\(id1)/diagram.png).\nExternal [site](https://www.notion.so/x).\n".utf8)),
        ("Export-1a2b3c4d/Plan \(id1)/Child \(id2).md", Data("# Child\n\nBack to [Plan](../Plan%20\(id1).md#goals).\n".utf8)),
        ("Export-1a2b3c4d/Plan \(id1)/diagram.png", png),
        ("Export-1a2b3c4d/Tasks \(id3).csv", Data("\u{FEFF}Name,Status\n\"Write, then edit\",Done\nShip,\"To do\"\n".utf8)),
        ("Export-1a2b3c4d/Tasks \(id3)_all.csv", Data("Name,Status\nDuplicate,x\n".utf8)),
    ]
}

final class ImportersTests: XCTestCase {
    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testHTMLConvertsToReadableMarkdown() {
        let html = "<div>Shopping &amp; errands</div><div><en-todo checked=\"true\"/>Milk</div><div><en-todo/>Eggs</div>"
            + "<ul><li>One<ul><li>Nested</li></ul></li><li>Two</li></ul><h2>Section</h2><p>A <b>bold </b>and <i>quiet</i> "
            + "<a href=\"https://example.test/a b\">link</a>.</p><div>1. not a list</div><blockquote><div>quoted</div></blockquote>"
            + "<pre>code &lt;x&gt;</pre><table><tr><th>a|b</th><th>c</th></tr><tr><td>d</td></tr></table>"
            + "<div>Line 1<br>Line 2</div><script>alert(1)</script><div>Issue #42</div>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), [
            "Shopping & errands", "", "- [x] Milk", "- [ ] Eggs", "", "- One", "  - Nested", "- Two", "", "## Section", "",
            "A **bold** and *quiet* [link](<https://example.test/a b>).", "", "1\\. not a list", "", "> quoted", "",
            "```", "code <x>", "```", "", "| a\\|b | c |", "| --- | --- |", "| d |   |", "", "Line 1  ", "Line 2", "", "Issue \\#42",
        ].joined(separator: "\n"))
    }

    func testEntityDecoding() {
        XCTAssertEqual(HTMLToMarkdown.decodeEntities("a &amp; b &lt;c&gt; &#65;&#x42; &mdash; &unknown; &#0; &#xD800;"), "a & b <c> AB — &unknown;  &#xD800;")
    }

    func testStylesLinksAndImages() {
        let html = "<p><span style=\"font-weight: bold\">strong</span> <u>under</u> <s>gone</s> <code>a`b</code> snake_case _x_ [x] *y*</p>"
            + "<p><img src=\"https://e.test/p.png\" alt=\"pic\"> <a href=\"javascript:x\">bad</a> <a href=\"https://e.test\"></a></p>"
        XCTAssertEqual(HTMLToMarkdown.convert(html),
                       "**strong** <u>under</u> ~~gone~~ ``a`b`` snake_case \\_x\\_ \\[x\\] \\*y\\*\n\n![pic](https://e.test/p.png) bad <https://e.test>")
    }

    func testUnderscoreEscapingMatchesTheOriginal() {
        XCTAssertEqual(HTMLToMarkdown.convert("<span>a_b _c d_ __e__ snake_</span>"), "a_b \\_c d\\_ \\__e\\__ snake\\_")
    }

    func testWithTitlePromotesMatchingFirstLine() {
        XCTAssertEqual(withTitle("**Trip plan**\n\nDetails", "Trip plan"), "# Trip plan\n\nDetails")
        XCTAssertEqual(withTitle("Details", "Trip plan"), "# Trip plan\n\nDetails")
        XCTAssertEqual(withTitle("", "Empty"), "# Empty")
    }

    func testParseEnexReadsNotesDatesTagsAndResources() throws {
        let notes = try Enex.parse(enexSource)
        XCTAssertEqual(notes.count, 2)
        let first = notes[0]
        XCTAssertEqual(first.title, "Trip & plan")
        XCTAssertEqual(first.created, "2024-01-02T03:04:05.000Z")
        XCTAssertEqual(first.updated, "2024-02-03T04:05:06.000Z")
        XCTAssertEqual(first.tags, ["travel", "Work/Projects"])
        XCTAssertEqual(first.resources.map(\.name), ["map photo.png", "attachment-2.pdf"])
        XCTAssertEqual(first.resources.map(\.mime), ["image/png", "application/pdf"])
        XCTAssertEqual(first.resources.map(\.data.count), [png.count, pdf.count])
        XCTAssertEqual(first.resources[0].hash, md5(png))
        XCTAssertEqual(notes[1].title, "Second")
        XCTAssertThrowsError(try Enex.parse("<html></html>")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not an Evernote export"))
        }
    }

    func testEvernoteImportWritesNotesFrontMatterAndAttachments() async throws {
        let library = try makeTempDirectory(self)
        let source = try makeTempDirectory(self).appendingPathComponent("Travel.enex")
        try write(enexSource, to: source)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let report = try await runImport(kind: .evernote, source: .files([source]), root: library, now: now)
        XCTAssertEqual(report, ImportReport(folder: "Imported/Evernote 2026-10-15", notes: 2, attachments: 2, skipped: []))

        let notePath = library.appendingPathComponent("Imported/Evernote 2026-10-15/Trip & plan.md")
        let text = try read(notePath)
        let pattern = "^---\\nfrisket-id: [0-9a-f-]{36}\\nfrisket-created: 2024-01-02T03:04:05.000Z\\nfrisket-source: evernote\\ntags:\\n {2}- \"travel\"\\n {2}- \"Work/Projects\"\\n---\\n\\n# Trip & plan\\n\\nPack \\*\\*light\\*\\*\\.\\n\\n- \\[ \\] Passport\\n\\n!\\[map photo\\.png\\]\\(<\\.\\./\\.\\./Assets/[0-9a-f-]+/map photo\\.png>\\)\\n\\n## Attachments\\n\\n- \\[attachment-2\\.pdf\\]\\(\\.\\./\\.\\./Assets/[0-9a-f-]+/attachment-2\\.pdf\\)\\n\\z"
        XCTAssertTrue(Rx(pattern).test(text), "unexpected note text:\n\(text)")

        let parsed = parseFrontMatter(splitFrontMatter(text).metaText)
        XCTAssertEqual(parsed.tags, ["travel", "Work/Projects"])
        let id = parsed.properties["frisket-id"]!.text
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("Assets/\(id)/map photo.png")), png)
        XCTAssertEqual(FileOps.modificationDate(notePath)?.timeIntervalSince1970, 1706933106)  // 2024-02-03T04:05:06Z

        let again = try await runImport(kind: .evernote, source: .files([source]), root: library, now: now)
        XCTAssertEqual(again.folder, "Imported/Evernote 2026-10-15 2", "a second import never overwrites the first")
    }

    func testEvernoteImportWithSeveralFilesUsesNotebookFolders() async throws {
        let library = try makeTempDirectory(self)
        let sources = try makeTempDirectory(self)
        try write(enexSource, to: sources.appendingPathComponent("Travel.enex"))
        try write("<en-export><note><title>Other</title><content>&lt;en-note&gt;&lt;div&gt;x&lt;/div&gt;&lt;/en-note&gt;</content></note></en-export>", to: sources.appendingPathComponent("Misc.enex"))
        let report = try await runImport(kind: .evernote,
                                         source: .files([sources.appendingPathComponent("Travel.enex"), sources.appendingPathComponent("Misc.enex")]),
                                         root: library)
        XCTAssertEqual(report.notes, 3)
        let base = library.appendingPathComponent(report.folder!)
        XCTAssertTrue(exists(base.appendingPathComponent("Travel/Trip & plan.md")))
        XCTAssertTrue(exists(base.appendingPathComponent("Misc/Other.md")))
    }

    func testDataURIImagesAreSavedAsAssets() async throws {
        let library = try makeTempDirectory(self)
        let note = ImportedNote(key: "k", title: "Pic", html: "<div>Pic</div><img src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"inline\">")
        let report = try writeImport(kind: .appleNotes, collected: CollectedImport(notes: [note], skipped: [], tree: nil), root: library, now: Date())
        XCTAssertEqual(report.attachments, 1)
        let text = try read(library.appendingPathComponent(report.folder!).appendingPathComponent("Pic.md"))
        XCTAssertTrue(text.contains("frisket-source: apple-notes"))
        XCTAssertTrue(Rx("!\\[inline\\]\\(\\.\\./\\.\\./Assets/[0-9a-f-]+/image-1\\.png\\)").test(text), text)
    }

    func checkNotionImport(_ library: URL, _ report: ImportReport) throws {
        XCTAssertEqual(report.notes, 3)
        XCTAssertEqual(report.attachments, 1)
        let base = library.appendingPathComponent(report.folder!)
        let plan = try read(base.appendingPathComponent("Plan.md"))
        XCTAssertTrue(Rx("See \\[Child\\]\\(Plan/Child\\.md\\) and !\\[diagram\\]\\(\\.\\./\\.\\./Assets/[0-9a-f-]+/diagram\\.png\\)\\.").test(plan), plan)
        XCTAssertTrue(plan.contains("[site](https://www.notion.so/x)"))
        let child = try read(base.appendingPathComponent("Plan/Child.md"))
        XCTAssertTrue(child.contains("Back to [Plan](../Plan.md#goals)."), child)
        let tasks = try read(base.appendingPathComponent("Tasks.md"))
        XCTAssertTrue(tasks.contains("# Tasks\n\n| Name | Status |\n| --- | --- |\n| Write, then edit | Done |\n| Ship | To do |"), tasks)
    }

    func testNotionExportImportsFromAFolder() async throws {
        let library = try makeTempDirectory(self)
        let exportDir = try makeTempDirectory(self)
        for file in notionFiles() {
            let url = exportDir.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        try checkNotionImport(library, try await runImport(kind: .notion, source: .folderOrZip(exportDir), root: library))
    }

    func testNotionExportImportsFromAZip() async throws {
        let library = try makeTempDirectory(self)
        let zip = try makeTempDirectory(self).appendingPathComponent("Export.zip")
        try makeZip(notionFiles()).write(to: zip)
        try checkNotionImport(library, try await runImport(kind: .notion, source: .folderOrZip(zip), root: library))
    }

    func testNotionExportImportsFromAZipOfZips() async throws {
        let library = try makeTempDirectory(self)
        let inner = makeZip(notionFiles())
        let outer = try makeTempDirectory(self).appendingPathComponent("Export.zip")
        try makeZip([("Export-1a2b3c4d-Part-1.zip", inner)]).write(to: outer)
        try checkNotionImport(library, try await runImport(kind: .notion, source: .folderOrZip(outer), root: library))
    }

    func testZipTemporaryFolderIsCleanedUp() async throws {
        let library = try makeTempDirectory(self)
        let zip = try makeTempDirectory(self).appendingPathComponent("Export.zip")
        try makeZip(notionFiles()).write(to: zip)
        func leftovers() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("frisket-import-") })
        }
        let before = leftovers()
        _ = try await runImport(kind: .notion, source: .folderOrZip(zip), root: library)
        XCTAssertEqual(leftovers(), before)
    }

    func testZipWithEscapingNamesIsRejected() async throws {
        let library = try makeTempDirectory(self)
        let parent = try makeTempDirectory(self)
        let zip = parent.appendingPathComponent("Evil.zip")
        try makeZip([("Page.md", Data("# Page".utf8)), ("../evil.txt", Data("no".utf8))]).write(to: zip)
        do {
            _ = try await runImport(kind: .notion, source: .folderOrZip(zip), root: library)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsafe"), error.localizedDescription)
        }
        XCTAssertFalse(exists(parent.appendingPathComponent("evil.txt")))
        XCTAssertFalse(exists(library.appendingPathComponent("Imported")))
    }

    func testBrokenZipFailsClearly() async throws {
        let library = try makeTempDirectory(self)
        let zip = try makeTempDirectory(self).appendingPathComponent("Bad.zip")
        try write("not a zip at all, definitely not", to: zip)
        do {
            _ = try await runImport(kind: .notion, source: .folderOrZip(zip), root: library)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ZIP"), error.localizedDescription)
        }
    }

    func testNotionHelpersStripIDsAndBuildTables() {
        XCTAssertEqual(NotionExport.stripNotionId("Plan " + id1), "Plan")
        XCTAssertEqual(NotionExport.stripNotionId("Plain name"), "Plain name")
        XCTAssertEqual(NotionExport.csvToMarkdownTable("a,b\n\"x|y\",\"line\nbreak\"\n"), "| a | b |\n| --- | --- |\n| x\\|y | line<br>break |")
    }

    func testMissingSourcesFailClearly() async throws {
        let library = try makeTempDirectory(self)
        do {
            _ = try await runImport(kind: .evernote, source: .none, root: library)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error.localizedDescription, "Choose one or more .enex files.") }
        do {
            _ = try await runImport(kind: .notion, source: .none, root: library)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error.localizedDescription, "Choose a Notion export (.zip or folder).") }
    }

    // MARK: Apple Notes (the Notes app itself cannot run here; the JSON conversion can)

    private let appleJSON = """
    [{"account":"iCloud","folder":"Notes","name":"Groceries","locked":false,"body":"<div>Groceries</div><ul><li>Milk</li></ul>","created":"2025-03-01T10:00:00.000Z","modified":"2025-03-02T11:30:00.000Z"},
     {"account":"iCloud","folder":"Notes","name":"Secret","locked":true,"body":null,"created":null,"modified":null},
     {"account":"On My Mac","folder":"Ideas","name":null,"locked":false,"body":"<div>Nameless</div>","created":null,"modified":null}]
    """

    func testAppleNotesJSONParses() throws {
        let raw = try AppleNotesReader.parse(json: appleJSON)
        XCTAssertEqual(raw.count, 3)
        XCTAssertEqual(raw[0].name, "Groceries")
        XCTAssertTrue(raw[1].locked)
        XCTAssertNil(raw[1].body)
        XCTAssertThrowsError(try AppleNotesReader.parse(json: "nope")) { error in
            XCTAssertEqual(error.localizedDescription, "Apple Notes returned data Frisket could not read.")
        }
        XCTAssertEqual(try AppleNotesReader.parse(json: "[]"), [])
    }

    func testAppleNotesConversionSkipsLockedAndUsesAccountFolders() throws {
        let converted = AppleNotesReader.importable(try AppleNotesReader.parse(json: appleJSON))
        XCTAssertEqual(converted.skipped, [SkippedNote(title: "Secret", reason: "locked")])
        XCTAssertEqual(converted.notes.map(\.title), ["Groceries", "Untitled"])
        XCTAssertEqual(converted.notes.map(\.folder), [["iCloud", "Notes"], ["On My Mac", "Ideas"]])
        XCTAssertEqual(converted.notes[0].updated, "2025-03-02T11:30:00.000Z")

        let single = AppleNotesReader.importable(try AppleNotesReader.parse(json: "[{\"account\":\"iCloud\",\"folder\":\"Notes\",\"name\":\"A\",\"locked\":false,\"body\":\"<div>A</div>\",\"created\":null,\"modified\":null}]"))
        XCTAssertEqual(single.notes[0].folder, ["Notes"])
    }

    func testAppleNotesWriteSetsFileTimes() throws {
        let library = try makeTempDirectory(self)
        let converted = AppleNotesReader.importable(try AppleNotesReader.parse(json: appleJSON))
        let report = try writeImport(kind: .appleNotes, collected: CollectedImport(notes: converted.notes, skipped: converted.skipped, tree: nil), root: library, now: Date())
        XCTAssertEqual(report.notes, 2)
        XCTAssertEqual(report.skipped.count, 1)
        let note = library.appendingPathComponent(report.folder!).appendingPathComponent("iCloud/Notes/Groceries.md")
        let text = try read(note)
        XCTAssertTrue(text.contains("frisket-created: 2025-03-01T10:00:00.000Z\nfrisket-source: apple-notes\n---\n\n# Groceries\n\n- Milk\n"), text)
        XCTAssertEqual(FileOps.modificationDate(note)?.timeIntervalSince1970, 1740915000)  // 2025-03-02T11:30:00Z
    }
}
