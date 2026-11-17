import XCTest
@testable import FrisketExport

final class ImageEmbeddingTests: XCTestCase {
    /// A 1x1 transparent PNG.
    static let png = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
        0x00, 0x05, 0xFE, 0x02, 0xFE, 0xA7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-export-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes/assets"), withIntermediateDirectories: true)
        try Self.png.write(to: root.appendingPathComponent("notes/assets/pic one.png"))
        try Self.png.write(to: root.appendingPathComponent("outside.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    var note: URL { root.appendingPathComponent("notes/Note.md") }
    var expectedURI: String { "data:image/png;base64," + Self.png.base64EncodedString() }

    func testLocalImageIsEmbedded() {
        let html = ExportDocument.build(markdown: "![p](<assets/pic one.png>)\n", noteURL: note, themeCSS: "").html
        XCTAssertTrue(html.contains("<img src=\"\(expectedURI)\" alt=\"p\">"))
    }

    func testRawHTMLImageIsEmbeddedToo() {
        let html = ExportDocument.build(markdown: "<img src='assets/pic%20one.png' width=10>\n", noteURL: note, themeCSS: "").html
        XCTAssertTrue(html.contains(expectedURI))
    }

    func testRemoteAndDataSourcesAreLeftAlone() {
        let md = "![a](https://example.com/a.png) ![b](data:image/png;base64,AAAA) ![c](//cdn.example.com/c.png)\n"
        let html = ExportDocument.build(markdown: md, noteURL: note, themeCSS: "").html
        XCTAssertTrue(html.contains("src=\"https://example.com/a.png\""))
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,AAAA\""))
        XCTAssertTrue(html.contains("src=\"//cdn.example.com/c.png\""))
    }

    func testImagesOutsideTheAllowedRootAreNotRead() {
        let html = ExportDocument.build(markdown: "![x](../outside.png) ![y](\(root.path)/outside.png)\n", noteURL: note, themeCSS: "").html
        XCTAssertFalse(html.contains("base64"))
        XCTAssertTrue(html.contains("src=\"../outside.png\""))
    }

    func testAllowedRootWidensAccess() {
        var options = ExportOptions()
        options.allowedRoot = root
        let html = ExportDocument.build(markdown: "![x](../outside.png)\n", noteURL: note, themeCSS: "", options: options).html
        XCTAssertTrue(html.contains(expectedURI))
    }

    func testMissingFilesAndEmbedOffLeaveSourceAlone() {
        XCTAssertTrue(ExportDocument.build(markdown: "![x](assets/nope.png)", noteURL: note, themeCSS: "").html.contains("src=\"assets/nope.png\""))
        var options = ExportOptions()
        options.embedImages = false
        XCTAssertFalse(ExportDocument.build(markdown: "![x](<assets/pic one.png>)", noteURL: note, themeCSS: "", options: options).html.contains("base64"))
    }

    func testSizeCapLinksInsteadOfEmbedding() {
        let embedder = ImageEmbedder(noteDirectory: note.deletingLastPathComponent(), maxBytes: 10)
        let result = embedder.resolve("assets/pic%20one.png")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.hasPrefix("file://"))
    }

    func testSymlinkEscapeIsRefused() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("notes/link.png"), withDestinationURL: root.appendingPathComponent("outside.png"))
        let embedder = ImageEmbedder(noteDirectory: note.deletingLastPathComponent())
        XCTAssertNil(embedder.resolve("link.png"))
    }
}
