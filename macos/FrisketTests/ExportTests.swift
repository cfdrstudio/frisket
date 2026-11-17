import XCTest
import AppKit
import PDFKit
import FrisketExport
@testable import Frisket

/// The export web view renders note HTML, which may contain raw HTML from the note.
/// These check that page script never runs, navigation away is refused, and the
/// PDF path produces a paginated document.
@MainActor
final class ExportTests: XCTestCase {
    private let probe = """
    <!doctype html><html><body>
    <p id="x">before</p>
    <script>document.getElementById('x').textContent = 'after'</script>
    <img src="x" onerror="document.getElementById('x').textContent = 'onerror'">
    </body></html>
    """

    func testPageScriptDoesNotRun() async throws {
        let job = WebJob(size: NSSize(width: 600, height: 400))
        defer { job.finish() }
        try await job.load(html: probe)
        let text = try await job.webView.evaluateJavaScript("document.getElementById('x').textContent") as? String
        XCTAssertEqual(text, "before")
    }

    func testNavigationAwayIsRefused() async throws {
        let job = WebJob(size: NSSize(width: 600, height: 400))
        defer { job.finish() }
        try await job.load(html: "<html><head><meta http-equiv=\"refresh\" content=\"0;url=https://example.com/\"></head><body><p id=\"x\">still here</p></body></html>")
        try await Task.sleep(nanoseconds: 500_000_000)
        let text = try await job.webView.evaluateJavaScript("document.getElementById('x') ? document.getElementById('x').textContent : 'gone'") as? String
        XCTAssertEqual(text, "still here")
        XCTAssertNotEqual(job.webView.url?.host, "example.com")
    }

    func testMathBecomesAnImage() {
        let html = ExportController.mathHTML("x^2 + \\frac{1}{2}", display: false)
        XCTAssertNotNil(html)
        XCTAssertTrue(html?.hasPrefix("<img class=\"math-image\" src=\"data:image/png;base64,") == true)
        XCTAssertTrue(html?.contains("alt=\"x^2 + \\frac{1}{2}\"") == true)
        XCTAssertNil(ExportController.mathHTML("\\frac{", display: true), "Broken LaTeX falls back to its source")
    }

    func testPDFHasPages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("note.pdf")

        let markdown = "# Title\n\n" + (1...120).map { "Paragraph \($0) with some words in it." }.joined(separator: "\n\n")
        var options = ExportOptions(mode: .pdf, pageSize: .a4, embedImages: true)
        options.dark = false
        let renderer = MarkdownRenderer(linkResolver: nil, mathRenderer: { ExportController.mathHTML($0, display: $1) }, diagramRenderer: nil, allowRawHTML: true)
        let html = ExportDocument.build(markdown: markdown, noteURL: nil, title: "Title", themeCSS: "", options: options, renderer: renderer).html

        let page = ExportController.pageSize(options)
        let margin: CGFloat = 54
        let frame = NSRect(x: 0, y: 0, width: page.width - 2 * margin, height: page.height - 2 * margin)
        let job = WebJob(size: frame.size)
        defer { job.finish() }
        try await job.load(html: html)
        let info = NSPrintInfo()
        info.paperSize = page
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let ok = await job.printPDF(info: info, frame: frame)
        XCTAssertTrue(ok)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Paragraph 120") == true)
    }
}
