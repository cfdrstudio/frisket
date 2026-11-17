import XCTest
@testable import FrisketExport

/// Port of tests/exportLayout.test.mjs plus the option validation the Swift side adds.
final class ExportLayoutTests: XCTestCase {
    func testPresentationSettingsAreConstrainedAndNormalizeOptionalText() {
        XCTAssertEqual(
            ExportPresentation(normalizing: ["preset": "report", "titlePage": true, "toc": 1, "author": "  Ada  ", "subtitle": NSNull()]),
            ExportPresentation(preset: .report, titlePage: true, toc: false, author: "Ada", subtitle: "")
        )
        XCTAssertEqual(
            ExportPresentation(normalizing: ["preset": "untrusted", "titlePage": "yes"]),
            ExportPresentation(preset: .standard, titlePage: false, toc: false, author: "", subtitle: "")
        )
        XCTAssertEqual(ExportPresentation(normalizing: nil), ExportPresentation())
        XCTAssertEqual(ExportPresentation(author: " \n x ").author, "x")
    }

    func testHeadingIDsAreReadableForAccentedAndPunctuationOnlyHeadings() {
        XCTAssertEqual(headingSlug("Crème brûlée: Plan & Notes"), "creme-brulee-plan-notes")
        XCTAssertEqual(headingSlug("🚀"), "section")
    }

    func testTOCEscapesVisibleTextAndEncodesFragmentsWhilePreservingLevels() {
        let html = ExportDocument.tocHTML([
            OutlineItem(level: 1, text: "Research <plan>", id: "a section"),
            OutlineItem(level: 3, text: "Budget & timeline", id: "a&b"),
        ])
        XCTAssertTrue(html.contains("href=\"#a%20section\">Research &lt;plan&gt;"))
        XCTAssertTrue(html.contains("href=\"#a%26b\">Budget &amp; timeline"))
        XCTAssertTrue(html.contains("export-toc-level-1"))
        XCTAssertTrue(html.contains("export-toc-level-3"))
        XCTAssertEqual(ExportDocument.tocHTML([]), "")
    }

    func testTitlePageEscapesAllUserSuppliedText() {
        let html = ExportDocument.titlePageHTML(title: "<Plan>", presentation: ExportPresentation(author: "\"Writer\"", subtitle: "A & B"))
        XCTAssertTrue(html.contains("&lt;Plan&gt;"))
        XCTAssertTrue(html.contains("A &amp; B"))
        XCTAssertTrue(html.contains("&quot;Writer&quot;"))
        XCTAssertFalse(html.contains("<Plan>"))
        XCTAssertFalse(html.contains("A & B"))
    }

    func testEachPresetEmitsItsOwnStylingAndExportLayoutEnablesPrintPageBreaks() {
        let options = ExportOptions(mode: .pdf, pageSize: .a4, margin: 0.6, contentWidth: 780)
        let standard = ExportDocument.layoutCSS(options: options, presentation: ExportPresentation())
        let manuscript = ExportDocument.layoutCSS(options: options, presentation: ExportPresentation(preset: .manuscript, titlePage: true, toc: true))
        let report = ExportDocument.layoutCSS(options: options, presentation: ExportPresentation(preset: .report))
        XCTAssertTrue(standard.contains("@page { size: A4; margin: 0.6in; }"))
        XCTAssertTrue(manuscript.contains("Georgia"))
        XCTAssertTrue(manuscript.contains("page-break-after: always"))
        XCTAssertTrue(report.contains("border-bottom: 2px solid"))
    }

    func testOptionsValidationClampsNumbers() {
        let bad = ExportOptions(margin: .nan, fontSize: 500, contentWidth: -3).validated()
        XCTAssertEqual(bad.margin, 0.6)
        XCTAssertEqual(bad.fontSize, 48)
        XCTAssertEqual(bad.contentWidth, 320)
        XCTAssertEqual(ExportOptions(margin: -1).validated().margin, 0)
        XCTAssertEqual(PageSize(name: "letter"), .letter)
        XCTAssertEqual(PageSize(name: "bogus"), .a4)
    }

    func testPageRuleFormatsNumbersLikeJavaScript() {
        let css = ExportDocument.pageCSS(ExportOptions(mode: .pdf, pageSize: .letter, landscape: true, margin: 1))
        XCTAssertTrue(css.contains("@page { size: Letter landscape; margin: 1in; }"))
    }

    func testBuildProducesSelfContainedDocument() {
        let result = ExportDocument.build(
            markdown: "---\ntitle: My <Title>\n---\n# Head\n\ntext\n",
            themeCSS: ":root { --bg: #fff; }",
            options: ExportOptions(mode: .html, dark: true, presentation: ExportPresentation(titlePage: true, toc: true, author: "Me"))
        )
        let html = result.html
        XCTAssertEqual(result.title, "My <Title>")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<html lang=\"en\" data-dark=\"true\">"))
        XCTAssertTrue(html.contains("<title>My &lt;Title&gt;</title>"))
        XCTAssertTrue(html.contains(":root { --bg: #fff; }"))
        XCTAssertTrue(html.contains(".md-render h1, .md-render h2"))   // preview stylesheet
        XCTAssertTrue(html.contains("color-scheme: dark"))
        XCTAssertTrue(html.contains("<section class=\"export-title-page\""))
        XCTAssertTrue(html.contains("<nav class=\"export-toc\""))
        XCTAssertTrue(html.contains("<article class=\"md-render\">"))
        XCTAssertTrue(html.contains("<h1 id=\"head\">Head</h1>"))
        XCTAssertEqual(result.outline, [OutlineItem(level: 1, text: "Head", id: "head")])
    }

    func testLegacyLayoutHasNoPresentationParts() {
        let html = ExportDocument.build(markdown: "# A\n", noteURL: URL(fileURLWithPath: "/tmp/Some Note.md"), themeCSS: "", options: ExportOptions(mode: .html, contentWidth: 700)).html
        XCTAssertFalse(html.contains("<section class=\"export-title-page\""))
        XCTAssertFalse(html.contains("<nav class=\"export-toc\""))
        XCTAssertTrue(html.contains("max-width: 700px"))
        XCTAssertTrue(html.contains("<title>A</title>"))
    }

    func testTitleFallsBackToFileName() {
        XCTAssertEqual(ExportDocument.documentTitle("no heading", fallback: "Note"), "Note")
        XCTAssertEqual(ExportDocument.documentTitle("# First\ntext", fallback: "Note"), "First")
    }
}
