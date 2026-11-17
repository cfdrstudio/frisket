import XCTest
@testable import FrisketServices

final class CompletionsTests: XCTestCase {
    private let notes = [
        CompletionNote(title: "Project Plan", linkText: "Project Plan", name: "2026-10-14-untitled.md", relative: "Notes/2026-10-14-untitled.md", path: "/l/Notes/2026-10-14-untitled.md", aliases: ["Roadmap"], modifiedAt: "2026-10-10T00:00:00Z"),
        CompletionNote(title: "Meeting", linkText: "one", name: "one.md", relative: "a/one.md", path: "/l/a/one.md", modifiedAt: "2026-10-12T00:00:00Z"),
        CompletionNote(title: "Meeting", linkText: "two", name: "two.md", relative: "b/two.md", path: "/l/b/two.md", modifiedAt: "2026-10-11T00:00:00Z"),
        CompletionNote(title: "Gone", linkText: nil, name: "gone.md", relative: "gone.md", path: "/l/gone.md", trashedAt: "2026-01-01T00:00:00Z"),
    ]

    func testDetectsTheWikiAndTagContextsBeforeTheCaret() {
        XCTAssertEqual(Completions.wikiLinkContext("See [[Proj"), CompletionContext(query: "Proj", start: 6))
        XCTAssertEqual(Completions.wikiLinkContext("See [["), CompletionContext(query: "", start: 6))
        XCTAssertNil(Completions.wikiLinkContext("See [[Done]] then"))
        XCTAssertNil(Completions.wikiLinkContext("See [[Note|ali"), "typing an alias is not a note query")
        XCTAssertEqual(Completions.tagContext("Filed under #wo"), CompletionContext(query: "wo", start: 13))
        XCTAssertEqual(Completions.tagContext("#work/pro"), CompletionContext(query: "work/pro", start: 1))
        XCTAssertNil(Completions.tagContext("Filed under #"), "needs a character first")
        XCTAssertNil(Completions.tagContext("## Heading #wo"), "headings do not hold tags")
        XCTAssertNil(Completions.tagContext("https://x.test/#frag"))
        XCTAssertNil(Completions.tagContext("C#"))
        XCTAssertNil(Completions.tagContext("&#12"))
    }

    func testContextStartIsAUTF16Offset() {
        XCTAssertEqual(Completions.wikiLinkContext("😀 [[Pro"), CompletionContext(query: "Pro", start: 5))
    }

    func testRanksNotesByTitleAliasAndFileNameSkippingTrashedNotes() {
        let byTitle = Completions.noteCompletions(notes, query: "proj")
        XCTAssertEqual(byTitle[0].label, "Project Plan")
        XCTAssertEqual(byTitle[0].insert, "Project Plan")
        XCTAssertNil(byTitle[0].alias)

        let byAlias = Completions.noteCompletions(notes, query: "road")
        XCTAssertEqual(byAlias[0].label, "Roadmap")
        XCTAssertEqual(byAlias[0].insert, "Project Plan")
        XCTAssertEqual(byAlias[0].alias, "Roadmap")
        XCTAssertEqual(byAlias[0].detail, "→ Project Plan")

        let duplicates = Completions.noteCompletions(notes, query: "meeting")
        XCTAssertEqual(duplicates.map(\.insert), ["one", "two"], "duplicate titles insert their unique link text, newest first")
        XCTAssertEqual(duplicates.map { $0.alias ?? "" }, ["Meeting", "Meeting"])
        XCTAssertEqual(duplicates.map(\.detail), ["a", "b"])

        XCTAssertFalse(Completions.noteCompletions(notes, query: "").contains { $0.path == "/l/gone.md" })
        XCTAssertEqual(Completions.noteCompletions(notes, query: "zzz").count, 0)
        XCTAssertGreaterThan(Completions.matchScore("Project Plan", "plan"), Completions.matchScore("Explanation", "plan"), "word start beats mid-word")
        XCTAssertEqual(Completions.noteCompletions(notes, query: "").count, 3)
        XCTAssertEqual(Completions.noteCompletions(notes, query: "", limit: 1).count, 1)
    }

    func testMatchScoreTiers() {
        XCTAssertEqual(Completions.matchScore("Plan", "pl"), 996)
        XCTAssertEqual(Completions.matchScore("Big Plan", "plan"), 800 - 4)
        XCTAssertEqual(Completions.matchScore("Explanation", "plan"), 600 - 2)
        XCTAssertEqual(Completions.matchScore("Project", "pjt"), 8)
        XCTAssertEqual(Completions.matchScore("abc", "x"), -1)
        XCTAssertEqual(Completions.matchScore("abc", "  "), 0)
        XCTAssertEqual(Completions.matchScore("", "a"), -1)
    }

    func testOffersExistingTagsByPrefixThenSegmentWithoutTheExactMatch() {
        let tags = [TagCount(tag: "work", count: 9), TagCount(tag: "work/projects", count: 3), TagCount(tag: "homework", count: 1), TagCount(tag: "ideas", count: 4)]
        XCTAssertEqual(Completions.tagCompletions(tags, query: "work").map(\.insert), ["work/projects", "homework"])
        XCTAssertEqual(Completions.tagCompletions(tags, query: "pro").map(\.insert), ["work/projects"])
        XCTAssertEqual(Completions.tagCompletions(tags, query: "i").map(\.insert), ["ideas"])
        XCTAssertEqual(Completions.tagCompletions(tags, query: "o").map(\.insert), ["work", "work/projects", "homework"], "then by usage")
        XCTAssertEqual(Completions.tagCompletions(tags, query: "pro").map(\.detail), ["3"])
    }

    func testInsertingALinkReusesTypedClosingBracketsAndKeepsAliasesAndAnchors() {
        let plain = (insert: "Project Plan", alias: String?.none)
        let aliased = (insert: "one", alias: String?.some("Meeting"))
        func make(_ o: (insert: String, alias: String?), _ after: String) -> WikiInsertion {
            Completions.wikiInsertion(insert: o.insert, alias: o.alias, after: after)
        }
        XCTAssertEqual(make(plain, "]] and more"), WikiInsertion(text: "Project Plan", replace: 0, cursor: 14))
        XCTAssertEqual(make(aliased, "]]"), WikiInsertion(text: "one|Meeting", replace: 0, cursor: 13))
        XCTAssertEqual(make(plain, "ect old]] tail"), WikiInsertion(text: "Project Plan", replace: 7, cursor: 14))
        XCTAssertEqual(make(aliased, "x|shown]]"), WikiInsertion(text: "one", replace: 1, cursor: 3))
        XCTAssertEqual(make(plain, "#Goals]]"), WikiInsertion(text: "Project Plan", replace: 0, cursor: 12))
        XCTAssertEqual(make(plain, " and text"), WikiInsertion(text: "Project Plan]]", replace: 0, cursor: 14))
    }
}
