import XCTest
@testable import FrisketBase

final class FrontMatterTests: XCTestCase {
    func testSplitFrontMatter() {
        let text = "---\ntitle: Hello\n---\n# Body\n"
        let parts = splitFrontMatter(text)
        XCTAssertEqual(parts.metaText, "title: Hello")
        XCTAssertEqual(parts.body, "# Body\n")
        XCTAssertEqual(parts.bodyOffset, 21)
        XCTAssertEqual(splitFrontMatter("no front matter").body, "no front matter")
    }

    func testParseScalarsListsAndTags() {
        let meta = """
        title: "Quoted \\"title\\""
        count: 3
        ratio: 1.5
        draft: true
        aliases: [One, "Two, three"]
        tags:
          - work/projects
          - "#Ideas"
          - ideas
        empty: ~
        """
        let parsed = parseFrontMatter(meta)
        XCTAssertEqual(parsed.properties["title"], .string("Quoted \"title\""))
        XCTAssertEqual(parsed.properties["count"], .number(3))
        XCTAssertEqual(parsed.properties["count"]?.text, "3")
        XCTAssertEqual(parsed.properties["ratio"]?.text, "1.5")
        XCTAssertEqual(parsed.properties["draft"], .bool(true))
        XCTAssertEqual(parsed.properties["aliases"], .list([.string("One"), .string("Two, three")]))
        XCTAssertNil(parsed.properties["empty"])
        XCTAssertEqual(parsed.tags, ["work/projects", "Ideas"])
        XCTAssertEqual(aliasesOf(parsed.properties), ["One", "Two, three"])
    }

    func testInlineTagForms() {
        XCTAssertEqual(parseFrontMatter("tags: [a, '#b']").tags, ["a", "b"])
        XCTAssertEqual(parseFrontMatter("tags: a, b ,c").tags, ["a", "b", "c"])
    }

    func testSetFrontMatterValue() {
        XCTAssertEqual(setFrontMatterValue("Body\n", key: "frisket-pinned", value: "true"),
                       "---\nfrisket-pinned: true\n---\n\nBody\n")
        let withList = "---\nid: 1\ntags:\n  - a\n  - b\nkeep: yes\n---\nBody"
        XCTAssertEqual(setFrontMatterValue(withList, key: "tags", value: nil), "---\nid: 1\nkeep: yes\n---\nBody")
        XCTAssertEqual(setFrontMatterValue("---\nid: 1\n---\nBody", key: "id", value: "2"), "---\nid: 2\n---\nBody")
        XCTAssertEqual(setFrontMatterValue("---\nonly: 1\n---\n\nBody", key: "only", value: nil), "Body")
        XCTAssertEqual(setFrontMatterValue("---\r\na: 1\r\n---\r\nBody", key: "b", value: "2"), "---\r\na: 1\r\nb: 2\r\n---\r\nBody")
    }

    func testNoteTitle() {
        XCTAssertEqual(noteTitle("# Heading\ntext", fallback: "file", properties: [:]), "Heading")
        XCTAssertEqual(noteTitle("text", fallback: "file", properties: [:]), "file")
        XCTAssertEqual(noteTitle("# H", fallback: "f", properties: ["title": .string(" Front ")]), "Front")
        XCTAssertEqual(noteTitle("# Windows\r\nline", fallback: "f", properties: [:]), "Windows")
    }

    func testNamesAndTags() {
        XCTAssertEqual(nameKey("  Hello   World "), "hello world")
        XCTAssertEqual(uniqueTags(["#Work", "work", "Ideas#", ""]), ["Work", "Ideas"])
        XCTAssertTrue(isDescendantTag("work/projects", of: "Work"))
        XCTAssertFalse(isDescendantTag("workshop", of: "work"))
    }

    func testSafeNameAndUnique() throws {
        XCTAssertEqual(FileOps.safeName("a/b:c?. "), "a b c")
        XCTAssertEqual(FileOps.safeName("con"), "Untitled")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try FileOps.uniqueURL(in: dir, stem: "Note", ext: ".md")
        try FileOps.writeNewFile(first, text: "x")
        XCTAssertThrowsError(try FileOps.writeNewFile(first, text: "y"))
        XCTAssertEqual(try FileOps.uniqueURL(in: dir, stem: "Note", ext: ".md").lastPathComponent, "Note 2.md")
        let modified = FileOps.modificationDate(first)
        try FileOps.replaceFile(first, text: "z", expectedModificationDate: modified)
        XCTAssertEqual(try FileOps.readText(first), "z")
        XCTAssertThrowsError(try FileOps.replaceFile(first, text: "w", expectedModificationDate: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(FileOps.isWithin(dir, first))
        XCTAssertFalse(FileOps.isWithin(first, dir))
        XCTAssertTrue(FileOps.isWithin(URL(fileURLWithPath: "/private/var/x"), URL(fileURLWithPath: "/private/var/x/new/a.md")))
        XCTAssertFalse(FileOps.isWithin(URL(fileURLWithPath: "/a/b"), URL(fileURLWithPath: "/a/b/../c")))
        // A reused URL must still see a change made behind its back.
        let reused = first
        _ = FileOps.modificationDate(reused)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: first.path)
        XCTAssertEqual(FileOps.modificationDate(reused), Date(timeIntervalSince1970: 1000))
    }

    func testISOTimestamp() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        XCTAssertEqual(isoTimestamp(date), "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(parseISODate("2023-11-14T22:13:20.123Z")?.timeIntervalSince1970 ?? 0, 1_700_000_000.123, accuracy: 0.001)
    }
}
