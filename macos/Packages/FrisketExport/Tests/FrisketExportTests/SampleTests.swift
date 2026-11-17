import XCTest
@testable import FrisketExport

final class SampleDocumentTests: XCTestCase {
    /// The Electron app's own sample note renders without trouble (skipped outside the repo checkout).
    func testSampleNoteRenders() throws {
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sample.md")
        guard let text = try? String(contentsOf: sample, encoding: .utf8) else { throw XCTSkip("sample.md not found") }
        let result = ExportDocument.build(markdown: text, noteURL: sample, themeCSS: ":root{}", options: ExportOptions(presentation: ExportPresentation(toc: true)))
        XCTAssertFalse(result.html.contains("\u{E000}"), "no placeholder may leak")
        XCTAssertFalse(result.outline.isEmpty)
        XCTAssertFalse(PlainText.from(markdown: text).isEmpty)
    }
}
