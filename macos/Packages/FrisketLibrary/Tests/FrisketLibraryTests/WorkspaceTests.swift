import XCTest
import FrisketBase
@testable import FrisketLibrary

final class WorkspaceTests: XCTestCase {
    func testIndexesFrontmatterNestedLinksQuickOpenAndUnlinkedMentions() throws {
        let root = try makeTempDir()
        let target = try write(root, "Research/Atlas.md", [
            "---", "title: \"Atlas Notes\"", "status: draft", "priority: 2", "tags: [maps, \"field work\"]", "---", "# Body title",
        ].joined(separator: "\n"))
        let source = try write(root, "Journal/Today.md", [
            "---", "tags:", "  - field work", "  - journal", "---",
            "Read [[../Research/Atlas|the atlas]] and [the report](../Research/Atlas.md#history).",
            "Atlas Notes still needs a review.",
            "`Atlas` appears inline as code.",
        ].joined(separator: "\n"))
        let scan = try scanWorkspace(folder: u(root))
        XCTAssertFalse(scan.truncated)
        XCTAssertEqual(scan.notes.count, 2)
        let atlas = try XCTUnwrap(scan.notes.first { $0.path == target })
        XCTAssertEqual(atlas.title, "Atlas Notes")
        XCTAssertEqual(atlas.tags, ["maps", "field work"])
        XCTAssertEqual(atlas.properties, ["title": .string("Atlas Notes"), "status": .string("draft"), "priority": .number(2)])
        let today = try XCTUnwrap(scan.notes.first { $0.path == source })
        XCTAssertEqual(today.links, ["../Research/Atlas", "../Research/Atlas.md#history"])
        XCTAssertEqual(today.title, "Today")

        let backlinks = getBacklinks(notes: scan.notes, targetPath: target, root: scan.root)
        XCTAssertEqual(backlinks.linked.count, 2)
        XCTAssertGreaterThan(backlinks.linked[0].pos, 0)
        XCTAssertEqual(backlinks.unlinked.count, 1)
        XCTAssertTrue(backlinks.unlinked[0].excerpt.contains("Atlas Notes still needs"))
        XCTAssertEqual(filterNotes(scan.notes, query: "atn").first?.path, target)
        XCTAssertEqual(getTags(scan.notes), [
            TagCount(tag: "field work", count: 2), TagCount(tag: "journal", count: 1), TagCount(tag: "maps", count: 1),
        ])
    }

    func testReportsLocalAttachmentsAndMissingReferencesIgnoringRemoteImages() throws {
        let root = try makeTempDir()
        try write(root, "notes/images/diagram.png", "png")
        let notePath = try write(root, "notes/Plan.md", [
            "![diagram](images/diagram.png)", "![missing](images/absent.png)", "![remote](https://example.test/photo.png)",
        ].joined(separator: "\n"))
        let scan = try scanWorkspace(folder: u(root))
        let result = inspectAttachments(notes: scan.notes, root: scan.root, targetPath: notePath)
        XCTAssertEqual(result.referenced.count, 1)
        XCTAssertEqual(result.referenced[0].reference, "images/diagram.png")
        XCTAssertEqual(result.referenced[0].size, 3)
        XCTAssertEqual(result.missing.count, 1)
        XCTAssertEqual(result.missing[0].reference, "images/absent.png")
    }

    func testEnforcesDepthCountAndPerFileByteBoundsAndSkipsHiddenTrees() throws {
        let root = try makeTempDir()
        try write(root, "root.md", "# Root")
        try write(root, "one/two/three/four/five/six/deep.md", "# Too deep")
        try write(root, "large.md", "12345")
        try write(root, ".secret/hidden.md", "# Hidden")
        try write(root, ".git/config.md", "# Hidden")
        try write(root, "a.md", "# A")
        try write(root, "b.md", "# B")
        let scan = try scanWorkspace(folder: u(root), limits: ScanLimits(maxDepth: 2, maxFiles: 2, maxFileBytes: 4, maxTotalBytes: 64 << 20))
        XCTAssertEqual(scan.notes.count, 2)
        XCTAssertFalse(scan.notes.contains { $0.name == "deep.md" })
        XCTAssertFalse(scan.notes.contains { $0.name == "hidden.md" })
        XCTAssertFalse(scan.notes.contains { $0.name == "large.md" })
        XCTAssertTrue(scan.truncated)
    }

    func testSkipsSymlinks() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        try write(outside, "secret.md", "# Secret")
        try write(root, "real.md", "# Real")
        try FileManager.default.createSymbolicLink(atPath: root + "/link.md", withDestinationPath: outside + "/secret.md")
        try FileManager.default.createSymbolicLink(atPath: root + "/dir", withDestinationPath: outside)
        let scan = try scanWorkspace(folder: u(root))
        XCTAssertEqual(scan.notes.map(\.name), ["real.md"])
    }

    func testDoesNotReportAnAttachmentThatEscapesTheWorkspace() throws {
        let root = try makeTempDir()
        let notePath = try write(root, "notes.md", "![escape](../secret.png)")
        let scan = try scanWorkspace(folder: u(root))
        let result = inspectAttachments(notes: scan.notes, root: scan.root, targetPath: notePath)
        XCTAssertEqual(result.referenced.count, 0)
        XCTAssertEqual(result.missing[0].reason, "outside-workspace")
    }

    func testCapsCumulativeWorkspaceText() throws {
        let root = try makeTempDir()
        try write(root, "a.md", "# Alpha")
        try write(root, "b.md", "# Beta")
        let scan = try scanWorkspace(folder: u(root), limits: ScanLimits(maxDepth: 6, maxFiles: 2000, maxFileBytes: 4 << 20, maxTotalBytes: 8))
        XCTAssertEqual(scan.notes.count, 1)
        XCTAssertTrue(scan.truncated)
    }

    func testUnlinkedMentionsMatchWholeWordsRatherThanTitleSubstrings() throws {
        let root = try makeTempDir()
        let target = try write(root, "AI.md", "# AI")
        try write(root, "Rain.md", "The rain falls. AI matters.")
        let scan = try scanWorkspace(folder: u(root))
        let result = getBacklinks(notes: scan.notes, targetPath: target, root: scan.root)
        XCTAssertEqual(result.unlinked.count, 1)
        XCTAssertTrue(result.unlinked[0].excerpt.contains("AI matters"))
    }

    func testBacklinksAndAttachmentAuditIgnoreCodeAndResolveReferenceImages() throws {
        let root = try makeTempDir()
        let target = try write(root, "Target.md", "# Target")
        let source = try write(root, "Source.md", [
            "```md", "[[Target]]", "![code](missing-code.png)", "```",
            "`[[Target]]` and `![inline](missing-inline.png)`",
            "![chart][fig]", "", "[fig]: assets/chart.png",
        ].joined(separator: "\n"))
        let scan = try scanWorkspace(folder: u(root))
        let backlinks = getBacklinks(notes: scan.notes, targetPath: target, root: scan.root)
        XCTAssertEqual(backlinks.linked.count, 0)
        XCTAssertEqual(backlinks.unlinked.count, 0)
        let attachments = inspectAttachments(notes: scan.notes, root: scan.root, targetPath: source)
        XCTAssertEqual(attachments.missing.map(\.reference), ["assets/chart.png"])
    }

    func testFrontmatterListPropertiesAppearInTheIndex() throws {
        let root = try makeTempDir()
        try write(root, "Lists.md", "---\naliases:\n  - Alpha\n  - Beta\npeople: [Ada, Bob]\n---\n# Lists")
        let scan = try scanWorkspace(folder: u(root))
        XCTAssertEqual(scan.notes[0].properties["aliases"], .list([.string("Alpha"), .string("Beta")]))
        XCTAssertEqual(scan.notes[0].properties["people"], .list([.string("Ada"), .string("Bob")]))
    }

    func testIndexesProseTagsWhileExcludingHeadingsCodeEscapedHashesURLsAndHTML() throws {
        let root = try makeTempDir()
        try write(root, "Tags.md", [
            "# Heading #not-a-tag",
            "Use #work/projects# with #Ideas; escaped \\#hidden.",
            "URL https://example.test/#web-tag and www.example.test/#web-too",
            "<span data-tag=\"#html-attribute\">visible text</span>",
            "`#inline-code`", "```md", "#fenced-code", "```",
        ].joined(separator: "\n"))
        let scan = try scanWorkspace(folder: u(root))
        XCTAssertEqual(scan.notes[0].tags, ["work/projects", "Ideas"])
        XCTAssertEqual(getTags(scan.notes), [
            TagCount(tag: "Ideas", count: 1), TagCount(tag: "work", count: 1), TagCount(tag: "work/projects", count: 1),
        ])
    }

    func testBuildsPortableSummariesAndAppliesTagTodoTrashAndSearchFilters() throws {
        let root = try makeTempDir()
        try write(root, "Library/Plan.md", [
            "---", "frisket-id: plan-uuid", "frisket-created: 2024-01-02T03:04:05.000Z", "frisket-cover: media/cover.webp",
            "tags: [work]", "---", "# Plan title", "A useful project target #work/projects# with detail.",
            "- [ ] unfinished task", "- [x] finished task", "![inline image](media/image.png)", "[reference PDF](files/brief.pdf)",
        ].joined(separator: "\n"))
        try write(root, "Loose.md", "A note without tags.")
        try write(root, "Trash.md", ["---", "frisket-trashed-at: 2025-03-04T00:00:00Z", "---", "A trashed note."].joined(separator: "\n"))

        let scan = try scanWorkspace(folder: u(root))
        let summaries = summarizeNotes(scan.notes)
        let plan = try XCTUnwrap(summaries.first { $0.title == "Plan title" })
        XCTAssertEqual(plan.id, "plan-uuid")
        XCTAssertEqual(isoTimestamp(plan.createdAt), "2024-01-02T03:04:05.000Z")
        XCTAssertEqual(plan.modifiedAt, scan.notes.first { $0.title == "Plan title" }?.mtime)
        XCTAssertEqual(plan.imagePreview, "media/cover.webp")
        XCTAssertEqual(plan.tags, ["work", "work/projects"])
        XCTAssertEqual(plan.tasksDone, 1)
        XCTAssertEqual(plan.tasksTotal, 2)
        XCTAssertTrue(plan.hasImages)
        XCTAssertTrue(plan.hasAttachments)
        XCTAssertTrue(plan.excerpt.contains("useful project target"))

        XCTAssertTrue(try XCTUnwrap(summaries.first { $0.title == "Loose" }).id.hasPrefix("legacy-"))
        let titles = { (list: [NoteSummary]) in list.map(\.title) }
        XCTAssertEqual(titles(filterLibraryNotes(scan.notes, filter: .untagged)), ["Loose"])
        XCTAssertEqual(titles(filterLibraryNotes(scan.notes, filter: .todo)), ["Plan title"])
        XCTAssertEqual(titles(filterLibraryNotes(scan.notes, filter: .trash)), ["Trash"])
        XCTAssertEqual(titles(filterLibraryNotes(scan.notes, filter: .tag("WORK"))), ["Plan title"])
        XCTAssertEqual(titles(searchLibrary(scan.notes, query: "@todo @images #work target")), ["Plan title"])
        XCTAssertEqual(titles(searchLibrary(scan.notes, query: "#work/projects#")), ["Plan title"])
        XCTAssertEqual(titles(searchLibrary(scan.notes, query: "@images")), ["Plan title"])
    }

    func testLegacyIDIsTheSHA256PrefixOfThePath() {
        // Matches `crypto.createHash('sha256').update('Loose.md')` in workspace.js.
        let record = parseNote(file: "/x/Loose.md", root: "/x", text: "hi", mtime: Date())
        XCTAssertEqual(summaryFor(record).id, "legacy-9a59c91308c08bd2944f4fe3")
    }

    // MARK: Text helpers and UTF-16 positions

    func testMaskingKeepsLengthsAndLineBreaks() {
        let body = "a `code` b\n```\nfence\n```\n    indented\n#tag \\#no <b>x</b> https://x.y/#z"
        let masked = maskNonProse(body)
        XCTAssertEqual(masked.utf16.count, body.utf16.count)
        XCTAssertEqual(masked.filter { $0 == "\n" }.count, body.filter { $0 == "\n" }.count)
        XCTAssertEqual(extractInlineTags(body), ["tag"])
    }

    func testLinkPositionsAreUTF16AfterEmoji() {
        let text = "---\nfrisket-id: a\n---\n😀😀 see [[Target]] and 🎉 [x](other.md)\n"
        let extracted = extractLinks(text)
        let wiki = extracted.links.first { $0.kind == .wiki }!
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: extracted.bodyOffset + wiki.start, length: wiki.end - wiki.start)), "[[Target]]")
        let md = extracted.links.first { $0.kind == .markdown }!
        XCTAssertEqual(ns.substring(with: NSRange(location: extracted.bodyOffset + md.start, length: md.end - md.start)), "[x](other.md")
        XCTAssertEqual(extracted.bodyOffset, 22)
        XCTAssertEqual(wiki.start, 2 * 2 + " see ".count)
    }

    func testSearchMatchPositionAfterEmojiIsUTF16() {
        let text = "😀 first line\n🎉🎉 find the NEEDLE here\n"
        let match = findSearchMatch(text, query: parseSearchQuery("needle"))
        XCTAssertEqual(match.line, 2)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: match.pos, length: match.length)), "NEEDLE")
        XCTAssertEqual(match.column, "🎉🎉 find the ".utf16.count)
        let tag = findSearchMatch("🎉 hello #Work/Plan end", query: parseSearchQuery("#work"))
        XCTAssertEqual(tag.pos, "🎉 hello ".utf16.count)
        XCTAssertEqual(tag.length, 5)
    }

    func testBacklinkAndMentionPositionsAreUTF16() throws {
        let root = try makeTempDir()
        let target = try write(root, "Project Plan.md", "# Project Plan\n")
        let source = try write(root, "daily.md", "😀😀 talked about the Project Plan today\n🎉 [[Project Plan]]\n")
        let scan = try scanWorkspace(folder: u(root))
        let backlinks = getBacklinks(notes: scan.notes, targetPath: target, root: scan.root)
        let text = try read(source) as NSString
        XCTAssertEqual(backlinks.unlinked.count, 1)
        let mention = backlinks.unlinked[0]
        XCTAssertEqual(text.substring(with: NSRange(location: mention.pos, length: mention.length)), "Project Plan")
        XCTAssertEqual(backlinks.linked.count, 1)
        XCTAssertEqual(text.substring(with: NSRange(location: backlinks.linked[0].pos, length: 14)), "[[Project Plan")
    }

    func testRewriteWikiLinksAfterEmojiAndCodeSkipping() {
        let source = "😀 See [[Old Title]], [[old title#Goals|the plan]].\n`[[Old Title]]` stays.\n"
        let result = rewriteWikiLinks(source, matching: { $0.lowercased() == "old title" }, replacement: "New Title")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.text, "😀 See [[New Title]], [[New Title#Goals|the plan]].\n`[[Old Title]]` stays.\n")
    }

    func testTagsInEmojiText() {
        XCTAssertEqual(extractInlineTags("😀#glued 😀 #real and #日本語"), ["glued", "real", "日本語"])
    }

    func testFuzzyAndTagCounts() {
        XCTAssertEqual(fuzzyScore("Atlas Notes", "atl"), 1003)
        XCTAssertEqual(fuzzyScore("Atlas Notes", "zzz"), -1)
        let notes = [parseNote(file: "/r/a.md", root: "/r", text: "#work/plan #Work", mtime: Date())]
        XCTAssertEqual(getTags(notes), [TagCount(tag: "Work", count: 1), TagCount(tag: "work/plan", count: 1)])
    }

    func testLinkTargetParsing() {
        XCTAssertNil(parseLinkTarget("https://example.test"))
        XCTAssertNil(parseLinkTarget("//host/x"))
        XCTAssertEqual(parseLinkTarget("<My Note#Heading>"), LinkTargetParts(name: "My Note", anchor: "Heading"))
        XCTAssertEqual(parseLinkTarget("C:\\notes\\a.md")?.name, "C:\\notes\\a.md")
        XCTAssertEqual(parseLinkTarget("#Only"), LinkTargetParts(name: "", anchor: "Only"))
        XCTAssertEqual(parseLinkTarget("a.md?x=1#"), LinkTargetParts(name: "a.md", anchor: nil))
    }

    func testExcerptStripsMarkdown() {
        XCTAssertEqual(makeExcerpt("# Heading\n\n- [ ] **bold** [link](x) and [[Wiki|label]]\n"), "bold link and label")
        let long = makeExcerpt(String(repeating: "word ", count: 80))
        XCTAssertEqual(long.utf16.count, 178)
        XCTAssertTrue(long.hasSuffix("word wo…"))
    }

    func testSearchQueryParsing() {
        let q = parseSearchQuery("Hello  @TODO #work/plan# World @images")
        XCTAssertEqual(q, SearchQuery(terms: ["hello", "world"], tags: ["work/plan"], todo: true, images: true))
    }
}
