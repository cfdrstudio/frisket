import XCTest
@testable import FrisketMarkdown

final class ScannerTests: XCTestCase {
    private func substring(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

    private func styled(_ doc: MDDocument, _ text: String, _ style: MDStyle) -> [String] {
        doc.styles.filter { $0.style == style }.map { substring(text, $0.range) }
    }

    private func hidden(_ doc: MDDocument, _ text: String) -> [String] {
        doc.hides.filter { $0.widget == nil }.map { substring(text, $0.range) }
    }

    func testHeadingMarksHideUnlessOnLine() {
        let text = "# Title\n\nBody"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(doc.lines[0].kind, .heading(1))
        XCTAssertEqual(doc.lines[1].kind, .blank)
        XCTAssertEqual(doc.lines[2].kind, .paragraph)
        let mark = doc.hides.first!
        XCTAssertEqual(substring(text, mark.range), "# ")
        XCTAssertEqual(mark.mode, .lines)
        XCTAssertFalse(doc.isRevealed(mark, by: [NSRange(location: 12, length: 0)]))
        XCTAssertTrue(doc.isRevealed(mark, by: [NSRange(location: 5, length: 0)]))
        XCTAssertEqual(doc.headings.map(\.text), ["Title"])
    }

    func testEmphasisStrongAndNesting() {
        let text = "a **bold** and *it* and ***both*** and snake_case_word"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(styled(doc, text, .strong), ["**bold**", "**both**"])
        XCTAssertTrue(styled(doc, text, .emphasis).contains("*it*"))
        XCTAssertTrue(styled(doc, text, .emphasis).contains("***both***"))
        XCTAssertFalse(styled(doc, text, .emphasis).contains { $0.contains("case") }, "intraword underscores are not emphasis")
        let hiddenMarks = hidden(doc, text)
        XCTAssertEqual(hiddenMarks.filter { $0 == "**" }.count, 4)
    }

    func testMarksRevealOnTouch() {
        let text = "x **b** y"
        let doc = MarkdownScanner.scan(text)
        let marks = doc.hides.filter { $0.widget == nil }
        XCTAssertEqual(marks.count, 2)
        XCTAssertFalse(doc.isRevealed(marks[0], by: [NSRange(location: 0, length: 0)]))
        XCTAssertTrue(doc.isRevealed(marks[0], by: [NSRange(location: 2, length: 0)]))
        XCTAssertTrue(doc.isRevealed(marks[0], by: [NSRange(location: 7, length: 0)]), "caret just after the closing mark")
        XCTAssertFalse(doc.isRevealed(marks[0], by: [NSRange(location: 8, length: 0)]))
    }

    func testCodeSpanProtectsContents() {
        let text = "use `**not bold**` here"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(styled(doc, text, .inlineCode), ["`**not bold**`"])
        XCTAssertTrue(styled(doc, text, .strong).isEmpty)
    }

    func testLinksAndWikiLinks() {
        let text = "see [the site](https://example.com \"Title\") and [[Note|alias]] and [[Plain]]"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(styled(doc, text, .link), ["[the site](https://example.com \"Title\")"])
        let hiddenText = hidden(doc, text)
        XCTAssertTrue(hiddenText.contains("https://example.com"))
        XCTAssertTrue(hiddenText.contains("\"Title\""))
        XCTAssertTrue(hiddenText.contains("Note"), "an aliased wiki target is masked")
        XCTAssertFalse(hiddenText.contains("Plain"))
        XCTAssertEqual(styled(doc, text, .wikiLink), ["[[Note|alias]]", "[[Plain]]"])
    }

    func testListsTasksAndBullets() {
        let text = "- one\n  - nested\n- [x] done\n1. first\n"
        let doc = MarkdownScanner.scan(text)
        let widgets = doc.hides.compactMap(\.widget)
        XCTAssertEqual(widgets, [.bullet(depth: 0), .bullet(depth: 1), .bullet(depth: 0), .checkbox(checked: true)])
        XCTAssertEqual(doc.lines[2].list?.task, true)
        XCTAssertEqual(doc.lines[3].list?.ordered, true)
        XCTAssertEqual(styled(doc, text, .orderedMark), ["1."])
        XCTAssertEqual(doc.lines[1].listDepth, 1)
    }

    func testFencedCodeAndDiagram() {
        let text = "```swift\nlet a = **1**\n```\n\n```mermaid\ngraph TD\n```\n"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(doc.lines[0].kind, .codeFence)
        XCTAssertEqual(doc.lines[1].kind, .code)
        XCTAssertEqual(doc.lines[2].kind, .codeFence)
        XCTAssertTrue(styled(doc, text, .strong).isEmpty, "no inline parsing inside code")
        XCTAssertEqual(styled(doc, text, .codeInfo), ["swift", "mermaid"])
        XCTAssertEqual(doc.blockHides.compactMap(\.widget), [.diagram(lang: "mermaid", source: "graph TD")])
    }

    func testTable() {
        let text = "| A | B |\n|:--|--:|\n| 1 | `x|y` |\n\nafter"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(doc.lines[0].kind, .tableHeader)
        XCTAssertEqual(doc.lines[1].kind, .tableDelimiter)
        XCTAssertEqual(doc.lines[2].kind, .tableRow)
        guard case .table(let table)? = doc.blockHides.first?.widget else { return XCTFail("no table") }
        XCTAssertEqual(table.header, ["A", "B"])
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows, [["1", "`x|y`"]])
        XCTAssertEqual(substring(text, doc.blockHides[0].range), "| A | B |\n|:--|--:|\n| 1 | `x|y` |")
    }

    func testFrontMatterMathAndRule() {
        let text = "---\ntitle: X\n---\n\n$$\nx^2\n$$\n\n---\n\nInline $a+b$ but not $5 or $1,200$"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(doc.lines[0].kind, .frontMatterFence)
        XCTAssertEqual(doc.lines[1].kind, .frontMatter)
        XCTAssertEqual(doc.lines[2].kind, .frontMatterFence)
        XCTAssertEqual(doc.lines[4].kind, .mathFence)
        XCTAssertEqual(doc.lines[8].kind, .rule)
        let widgets = doc.blockHides.compactMap(\.widget)
        XCTAssertEqual(widgets, [.blockMath("x^2"), .rule])
        XCTAssertEqual(doc.hides.compactMap(\.widget), [.inlineMath("a+b")])
    }

    func testSetextAndImageParagraph() {
        let text = "Title\n=====\n\n![alt](pic.png)\n"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(doc.lines[0].kind, .heading(1))
        XCTAssertEqual(doc.lines[1].kind, .setextUnderline(1))
        XCTAssertEqual(doc.blockHides.compactMap(\.widget), [.image(src: "pic.png", alt: "alt")])
    }

    func testTagsHighlightAndEscapes() {
        let text = "Tagged #work/projects and ==bright== \\*not em\\* ~sub~ ^sup^ ~~gone~~ https://x.test/a."
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(styled(doc, text, .tag), ["#work/projects"])
        XCTAssertEqual(styled(doc, text, .highlight), ["==bright=="])
        XCTAssertTrue(styled(doc, text, .emphasis).isEmpty)
        XCTAssertEqual(styled(doc, text, .subscript), ["~sub~"])
        XCTAssertEqual(styled(doc, text, .superscript), ["^sup^"])
        XCTAssertEqual(styled(doc, text, .strike), ["~~gone~~"])
        XCTAssertEqual(styled(doc, text, .autolink), ["https://x.test/a"])
        XCTAssertEqual(hidden(doc, text).filter { $0 == "\\" }.count, 2)
    }

    func testUTF16OffsetsWithEmoji() {
        let text = "😀 **b**"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(doc.hides.first?.range.location, 3)
        XCTAssertEqual(styled(doc, text, .strong), ["**b**"])
    }

    func testBlocksAndSignatures() {
        let a = MarkdownScanner.scan("one\n\ntwo\n")
        let b = MarkdownScanner.scan("one\n\ntwo!\n")
        XCTAssertEqual(a.blocks.count, b.blocks.count)
        XCTAssertEqual(a.blocks[0].signature, b.blocks[0].signature)
        XCTAssertNotEqual(a.blocks[2].signature, b.blocks[2].signature)
        XCTAssertEqual(a.blockIndex(at: 6), 2)
    }

    func testQuoteMarks() {
        let text = "> quoted *text*\n> more"
        let doc = MarkdownScanner.scan(text)
        XCTAssertEqual(doc.lines[0].quoteDepth, 1)
        XCTAssertEqual(hidden(doc, text).filter { $0 == "> " }.count, 2)
        XCTAssertEqual(styled(doc, text, .emphasis), ["*text*"])
    }

    func testPlainTextAndCells() {
        XCTAssertEqual(MarkdownScanner.plainText("**Bold** [link](x) [[a|b]]"), "Bold link b")
        XCTAssertEqual(MarkdownScanner.tableCells("| a | b \\| c |"), ["a", "b | c"])
    }
}
