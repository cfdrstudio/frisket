import XCTest
@testable import FrisketExport

final class MarkdownRendererTests: XCTestCase {
    func render(_ md: String, _ renderer: MarkdownRenderer = MarkdownRenderer()) -> String {
        renderer.render(md).html
    }

    func testTablesWithAlignment() {
        let html = render("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n")
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">a</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">b</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">3</td>"))
    }

    func testTableWithoutAlignmentHasNoStyle() {
        let html = render("| a |\n|---|\n| 1 |\n")
        XCTAssertTrue(html.contains("<th>a</th>"))
        XCTAssertFalse(html.contains("style="))
    }

    func testTaskLists() {
        let html = render("- [x] done\n- [ ] todo\n- plain\n")
        XCTAssertTrue(html.contains("<ul class=\"contains-task-list\">"))
        XCTAssertTrue(html.contains("class=\"task-list-item\""))
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 2)
        XCTAssertEqual(html.components(separatedBy: "disabled=\"\"").count - 1, 2)
        XCTAssertEqual(html.components(separatedBy: "checked=\"\"").count - 1, 1)
        XCTAssertTrue(html.contains("<li>plain</li>"))
    }

    func testStrikethroughAndHighlight() {
        let html = render("~~old~~ and ==marked *text*== end")
        XCTAssertTrue(html.contains("<s>old</s>"))
        XCTAssertTrue(html.contains("<mark>marked *text*</mark>"), "highlight content is literal, as in markdown.js")
        XCTAssertFalse(render("a == b\nc == d").contains("<mark>"), "no highlight across lines")
    }

    func testAutolinks() {
        let html = render("see https://example.com/a?b=1&c=2. Also <https://x.org> and www.site.io")
        XCTAssertTrue(html.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">https://example.com/a?b=1&amp;c=2</a>."))
        XCTAssertTrue(html.contains("<a href=\"https://x.org\">https://x.org</a>"))
        XCTAssertTrue(html.contains("<a href=\"http://www.site.io\">www.site.io</a>"))
    }

    func testFootnotes() {
        let html = render("Text[^a] more[^a] and[^b].\n\n[^a]: First note.\n[^b]: Second\n    continued.\n")
        XCTAssertTrue(html.contains("<sup class=\"footnote-ref\"><a href=\"#fn1\" id=\"fnref1\">[1]</a></sup>"))
        XCTAssertTrue(html.contains("<a href=\"#fn1\" id=\"fnref1-2\">[1]</a>"))
        XCTAssertTrue(html.contains("<a href=\"#fn2\" id=\"fnref2\">[2]</a>"))
        XCTAssertTrue(html.contains("<section class=\"footnotes\">"))
        XCTAssertTrue(html.contains("<li id=\"fn1\" class=\"footnote-item\"><p>First note."))
        XCTAssertTrue(html.contains("href=\"#fnref1\" class=\"footnote-backref\""))
        XCTAssertFalse(html.contains("[^a]:"))
    }

    func testUndefinedFootnoteReferenceStaysLiteral() {
        let html = render("Text[^nope] here")
        XCTAssertTrue(html.contains("[^nope]"))
        XCTAssertFalse(html.contains("footnotes"))
    }

    func testInlineFootnote() {
        let html = render("Claim^[a short aside] ends.")
        XCTAssertTrue(html.contains("footnote-ref"))
        XCTAssertTrue(html.contains("a short aside"))
    }

    func testWikiLinks() {
        let html = render("[[Target]] [[Other Note|the alias]] [[Page#Some Heading]] [[img.png]]")
        XCTAssertTrue(html.contains("<a class=\"wikilink\" href=\"Target.md\">Target</a>"))
        XCTAssertTrue(html.contains("<a class=\"wikilink\" href=\"Other%20Note.md\">the alias</a>"))
        XCTAssertTrue(html.contains("<a class=\"wikilink\" href=\"Page.md#some-heading\">Page#Some Heading</a>"))
        XCTAssertTrue(html.contains("href=\"img.png\""), "targets with an extension are not given .md")
    }

    func testWikiLinkCustomResolver() {
        var received: [String] = []
        let renderer = MarkdownRenderer(linkResolver: { target in
            received.append(target)
            return target == "Known" ? "frisket://note/42" : nil
        })
        let html = renderer.render("[[Known]] [[Known#Part|label]] [[Missing]]").html
        XCTAssertEqual(received, ["Known", "Known", "Missing"])
        XCTAssertTrue(html.contains("href=\"frisket://note/42\">Known</a>"))
        XCTAssertTrue(html.contains("href=\"frisket://note/42#part\">label</a>"))
        XCTAssertTrue(html.contains("href=\"Missing.md\""))
    }

    func testWikiLinkInsideCodeIsLiteral() {
        let html = render("`[[Not]]` and\n\n```\n[[Also not]]\n```\n")
        XCTAssertFalse(html.contains("wikilink"))
        XCTAssertTrue(html.contains("<code>[[Not]]</code>"))
    }

    func testMathFallbackMarkup() {
        let html = render("Inline $a_b + c^2$ here.\n\n$$\n\\int_0^1 x\\,dx\n$$\n")
        XCTAssertTrue(html.contains("<span class=\"math inline\">\\(a_b + c^2\\)</span>"))
        XCTAssertTrue(html.contains("<div class=\"math display\">\\[\\int_0^1 x\\,dx\\]</div>"))
        XCTAssertFalse(html.contains("<p><div"))
    }

    func testMathIsEscapedAndRenderable() {
        let html = render("$a<b$")
        XCTAssertTrue(html.contains("\\(a&lt;b\\)"))
        let renderer = MarkdownRenderer(mathRenderer: { latex, display in
            "<katex display=\"\(display)\">\(latex)</katex>"
        })
        let custom = renderer.render("x $y$ and\n\n$$z$$\n").html
        XCTAssertTrue(custom.contains("<katex display=\"false\">y</katex>"))
        XCTAssertTrue(custom.contains("<katex display=\"true\">z</katex>"))
        let declined = MarkdownRenderer(mathRenderer: { _, _ in nil }).render("$q$").html
        XCTAssertTrue(declined.contains("math inline"))
    }

    func testMathNotTouchedInsideCode() {
        let html = render("`$x$ and $y$` then\n\n```\n$$\nbig\n$$\n$z$\n```\n\n~~~\n$w$\n~~~\n")
        XCTAssertFalse(html.contains("math"))
        XCTAssertTrue(html.contains("<code>$x$ and $y$</code>"))
        XCTAssertTrue(html.contains("$$\nbig\n$$\n$z$\n</code>"))
        XCTAssertTrue(html.contains("$w$"))
    }

    func testMathNotParsedForPricesAndNumbers() {
        let html = render("It costs $5 and $10 today, or $1,000.")
        XCTAssertFalse(html.contains("math"))
        XCTAssertTrue(html.contains("$5 and $10"))
    }

    func testMathSurvivesMarkdownSyntaxInside() {
        let html = render("Value $a*b*c$ and $x_1 + y_2$.")
        XCTAssertTrue(html.contains("\\(a*b*c\\)"))
        XCTAssertTrue(html.contains("\\(x_1 + y_2\\)"))
        XCTAssertFalse(html.contains("<em>"))
    }

    func testHeadingIDsAndOutline() {
        let result = MarkdownRenderer().render("# Intro\n\n## Crème brûlée *now*\n\n## Intro\n\n### Intro\n\n#### 🚀\n")
        XCTAssertEqual(result.outline, [
            OutlineItem(level: 1, text: "Intro", id: "intro"),
            OutlineItem(level: 2, text: "Crème brûlée now", id: "creme-brulee-now"),
            OutlineItem(level: 2, text: "Intro", id: "intro-2"),
            OutlineItem(level: 3, text: "Intro", id: "intro-3"),
            OutlineItem(level: 4, text: "🚀", id: "section"),
        ])
        XCTAssertTrue(result.html.contains("<h1 id=\"intro\">Intro</h1>"))
        XCTAssertTrue(result.html.contains("<h2 id=\"creme-brulee-now\">Crème brûlée <em>now</em></h2>"))
        XCTAssertTrue(result.html.contains("<h3 id=\"intro-3\">"))
    }

    func testSetextHeadingAndMathInHeading() {
        let result = MarkdownRenderer().render("Title\n=====\n\nSub $x^2$\n---\n")
        XCTAssertEqual(result.outline.map(\.level), [1, 2])
        XCTAssertEqual(result.outline[1].text, "Sub x^2")
    }

    func testFencedCodeIsEscaped() {
        let html = render("```swift\nlet a = \"<b>\" && x\n```\n\n```\nplain <i>\n```\n")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let a = &quot;&lt;b&gt;&quot; &amp;&amp; x\n</code></pre>"))
        XCTAssertTrue(html.contains("<pre><code>plain &lt;i&gt;\n</code></pre>"))
    }

    func testDiagramFences() {
        let md = "```mermaid\ngraph TD; A-->B\n```\n"
        let fallback = render(md)
        XCTAssertTrue(fallback.contains("<pre data-diagram=\"mermaid\"><code class=\"language-mermaid\">graph TD; A--&gt;B\n</code></pre>"))
        let renderer = MarkdownRenderer(diagramRenderer: { lang, source in
            lang == "mermaid" ? "<svg data-src=\"\(source.count)\"></svg>" : nil
        })
        XCTAssertTrue(renderer.render(md).html.contains("<div class=\"mermaid-rendered\"><svg data-src=\"16\"></svg></div>"))
        XCTAssertTrue(renderer.render("```gantt\nx\n```").html.contains("data-diagram=\"gantt\""))
        XCTAssertFalse(renderer.render("```swift\nx\n```").html.contains("data-diagram"))
    }

    func testFrontMatterStripped() {
        let html = render("---\ntitle: Secret\ntags: [a]\n---\n# Body\n")
        XCTAssertFalse(html.contains("Secret"))
        XCTAssertFalse(html.contains("tags"))
        XCTAssertTrue(html.contains("<h1 id=\"body\">Body</h1>"))
    }

    func testRawHTMLFollowsMarkdownJS() {
        XCTAssertTrue(render("<div class=\"x\">hi</div>\n\ntext <kbd>K</kbd>").contains("<div class=\"x\">hi</div>"))
        XCTAssertTrue(render("text <kbd>K</kbd>").contains("<kbd>K</kbd>"))
        let off = MarkdownRenderer(allowRawHTML: false).render("text <kbd>K</kbd>").html
        XCTAssertTrue(off.contains("&lt;kbd&gt;"))
    }

    func testListsTightAndLoose() {
        let tight = render("- a\n- b\n")
        XCTAssertTrue(tight.contains("<li>a</li>"))
        let loose = render("- a\n\n- b\n")
        XCTAssertTrue(loose.contains("<li><p>a</p>\n</li>"))
        let ordered = render("3. x\n4. y\n")
        XCTAssertTrue(ordered.contains("<ol start=\"3\">"))
    }

    func testLinksAndImages() {
        let html = render("[ok](<my file.md> \"T\") [bad](javascript:alert(1)) ![alt *x*](pic one.png) ![a](<pic one.png>)")
        XCTAssertTrue(html.contains("<a href=\"my%20file.md\" title=\"T\">ok</a>"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertTrue(html.contains("<img src=\"pic%20one.png\" alt=\"a\">"))
    }

    func testNoSmartPunctuation() {
        XCTAssertTrue(render("\"quoted\" -- dash...").contains("&quot;quoted&quot; -- dash..."))
    }
}
