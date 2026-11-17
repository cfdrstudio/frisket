import XCTest
@testable import FrisketServices

final class StyleCheckTests: XCTestCase {
    func testDiagnosticsPointAtTheExactRepeatedWordsAndPhraseOffsets() {
        let text = "We really need to to finish this in order to ship."
        let findings = StyleCheck.analyze(text)
        XCTAssertEqual(findings.map { [$0.kind.rawValue, "\($0.from)", "\($0.to)"] }, [
            ["wordiness", "3", "14"], ["repeated-word", "15", "20"], ["wordiness", "33", "44"],
        ])
        XCTAssertEqual(findings.map { ($0.suggestion ?? "-") }, ["-", "to", "to"])
        XCTAssertEqual(findings[1].message, "“to” is repeated.")
        XCTAssertEqual(findings[2].message, "This phrase can be shorter: “to”.")
        XCTAssertEqual(findings[0].message, "Consider whether “really need” adds meaning.")
        for finding in findings {
            XCTAssertGreaterThan((text as NSString).substring(with: finding.range).count, 0)
        }
    }

    func testOffsetsAreUTF16() {
        let text = "😀 in order to go"
        let finding = StyleCheck.analyze(text).first!
        XCTAssertEqual((text as NSString).substring(with: finding.range), "in order to")
        XCTAssertEqual(finding.from, 3)
    }

    func testFrontMatterFencedAndInlineCodeAndRawHTMLAreIgnored() {
        let text = [
            "---", "title: really really", "---", "Normal text.", "```js", "really really in order to", "```",
            "Use `really really` as a literal.", "<script>really really in order to</script>",
        ].joined(separator: "\n")
        XCTAssertEqual(StyleCheck.analyze(text), [])
    }

    func testTildeFencesAndLongerClosingFencesWork() {
        XCTAssertEqual(StyleCheck.analyze("~~~\nin order to\n~~~\nin order to"), [
            StyleFinding(from: 20, to: 31, kind: .wordiness, message: "This phrase can be shorter: “to”.", suggestion: "to"),
        ])
        XCTAssertEqual(StyleCheck.analyze("````\nin order to\n```\nstill code\n````\nok"), [])
    }

    func testWordinessRulesDoNotFlagOrdinaryProseOrCodeLikeIdentifiers() {
        XCTAssertEqual(StyleCheck.analyze("The quick brown fox writes markdown_parser values."), [])
    }

    func testTemplateInterpolationUsesLocalCalendarFieldsAndLeavesUnknownTokensAlone() {
        let date = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 59))!
        let input = "{{title}}\n{{date}} {{time}}\n{{selection}} {{unknown}}"
        XCTAssertEqual(StyleCheck.applyTemplate(input, title: "Plan {{date}}", selection: "A $& quote", now: date),
                       "Plan {{date}}\n2025-01-02 03:04\nA $& quote {{unknown}}")
    }

    func testTemplateReplacementSupportsOmittedValuesWithoutInterpretingMetacharacters() {
        XCTAssertEqual(StyleCheck.applyTemplate("{{title}}|{{selection}}", title: "$&", selection: "$`"), "$&|$`")
        XCTAssertEqual(StyleCheck.applyTemplate("[{{title}}]"), "[]")
    }
}
