import XCTest
@testable import FrisketServices

final class LineDiffTests: XCTestCase {
    private func kinds(_ ops: [DiffOp]) -> String {
        ops.map { String($0.kind.rawValue.first!) + $0.text }.joined(separator: ",")
    }

    func testAlignsInsertionsDeletionsAndReplacements() {
        XCTAssertEqual(kinds(LineDiff.diff("a\nb\nc", "a\nb\nc")), "sa,sb,sc")
        XCTAssertEqual(kinds(LineDiff.diff("a\nc", "a\nb\nc")), "sa,ab,sc")
        XCTAssertEqual(kinds(LineDiff.diff("a\nb\nc", "a\nc")), "sa,db,sc")
        XCTAssertEqual(kinds(LineDiff.diff("a\nold\nc", "a\nnew\nc")), "sa,dold,anew,sc")
        XCTAssertEqual(kinds(LineDiff.diff("", "x")), "ax")
        XCTAssertEqual(kinds(LineDiff.diff("x\r\ny", "x\ny")), "sx,sy", "line endings are ignored")
        let stats = LineDiff.stats(LineDiff.diff("a\nb", "a\nc\nd"))
        XCTAssertEqual(stats.added, 2)
        XCTAssertEqual(stats.removed, 1)
    }

    func testFallsBackToRemoveAllAddAllWhenTheChangedRegionIsHuge() {
        let ops = LineDiff.diff("s\nx\ny\ne", "s\np\nq\ne", maxCells: 1)
        XCTAssertEqual(kinds(ops), "ss,dx,dy,ap,aq,se")
    }

    func testCanonicallyEquivalentButDifferentTextCountsAsChanged() {
        XCTAssertEqual(kinds(LineDiff.diff("caf\u{e9}", "cafe\u{301}")), "d\(String("caf\u{e9}")),acafe\u{301}")
    }

    func testWithContextCollapsesLongUnchangedRuns() {
        let before = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "line 10", with: "changed")
        let shown = LineDiff.withContext(LineDiff.diff(before, after), context: 2)
        let names = shown.map { row -> String in
            switch row {
            case .skip: return "skip"
            case .line(let op): return op.kind.rawValue
            }
        }
        XCTAssertEqual(names, ["skip", "same", "same", "del", "add", "same", "same", "skip"])
        XCTAssertEqual(shown[0], .skip(count: 8))
        XCTAssertEqual(shown[7], .skip(count: 7))
    }
}
