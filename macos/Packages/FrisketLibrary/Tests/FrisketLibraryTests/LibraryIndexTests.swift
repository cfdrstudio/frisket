import XCTest
import FrisketBase
@testable import FrisketLibrary

final class LibraryIndexTests: XCTestCase {
    private func openIndex(_ root: String, limits: ScanLimits = .library) async -> LibraryIndex {
        let index = LibraryIndex(root: u(root), limits: limits, hostName: "host")
        await index.refresh()
        return index
    }

    private func titles(_ snapshot: LibrarySnapshot) -> [String] { snapshot.summaries.map(\.title).sorted() }

    // MARK: Link resolution (libraryIndex.test.cjs)

    func testLinksResolveByPathIDFileNameTitleAndAliasInThatOrder() throws {
        let root = try makeTempDir()
        let plan = try write(root, "Notes/2026-10-14-untitled.md", "---\nfrisket-id: plan-id\naliases: [Roadmap]\n---\n\n# Project Plan\n")
        let named = try write(root, "Projects/Plan.md", "# Something else\n")
        let daily = try write(root, "Journal/daily.md", "# Daily\n")
        let scan = try scanWorkspace(folder: u(root))
        let resolver = createLinkResolver(notes: scan.notes, root: root)
        func note(_ target: String) -> String? { resolver.resolve(from: daily, target).note?.path }

        XCTAssertEqual(note("Project Plan"), plan, "title")
        XCTAssertEqual(note("project   plan#Goals"), plan, "title is case- and space-insensitive")
        if case .note(_, let anchor) = resolver.resolve(from: daily, "project plan#Goals") { XCTAssertEqual(anchor, "Goals") } else { XCTFail() }
        XCTAssertEqual(note("plan-id"), plan, "frisket-id")
        XCTAssertEqual(note("Roadmap"), plan, "alias")
        XCTAssertEqual(note("Plan"), named, "file name wins over a title tier")
        XCTAssertEqual(note("../Projects/Plan.md"), named, "relative path")
        XCTAssertEqual(note("Projects/Plan"), named, "root-relative path")
        if case .missing = resolver.resolve(from: daily, "Elsewhere/Plan") {} else { XCTFail("a path suffix must match") }
        XCTAssertEqual(resolver.resolve(from: daily, "#Heading"), .anchorOnly(anchor: "Heading"))
        XCTAssertEqual(resolver.resolve(from: daily, "https://example.test"), .external)
        XCTAssertEqual(note("Project%20Plan"), plan, "percent-encoded")
    }

    func testDuplicateTitlesAreAmbiguousAndTrashedNotesAreReportedSeparately() throws {
        let root = try makeTempDir()
        let first = try write(root, "a/one.md", "# Meeting\n")
        let second = try write(root, "b/two.md", "# Meeting\n")
        try write(root, "gone.md", "---\nfrisket-trashed-at: 2026-01-01T00:00:00Z\n---\n# Archived idea\n")
        let scan = try scanWorkspace(folder: u(root))
        let resolver = createLinkResolver(notes: scan.notes, root: root)

        guard case .ambiguous(let hits, _) = resolver.resolve(from: nil, "Meeting") else { return XCTFail() }
        XCTAssertEqual(hits.map(\.path).sorted(), [first, second].sorted())
        guard case .missing(_, _, let trashed) = resolver.resolve(from: nil, "Archived idea") else { return XCTFail() }
        XCTAssertEqual(trashed?.title, "Archived idea")
        let one = try XCTUnwrap(scan.notes.first { $0.path == first })
        XCTAssertEqual(resolver.linkText(for: one), "one", "falls back to the unique file name")
    }

    func testBacklinksFollowTitleLinksToLibraryNotesAndFlagAmbiguity() throws {
        let root = try makeTempDir()
        let plan = try write(root, "Notes/2026-10-14-untitled.md", "---\nfrisket-id: abc\n---\n\n# Project Plan\n")
        try write(root, "Notes/daily.md", "# Daily\n\nSee [[Project Plan]] for details.\n")
        let meeting = try write(root, "a/one.md", "# Meeting\n")
        try write(root, "b/two.md", "# Meeting\n")
        try write(root, "c/log.md", "From the [[Meeting]].\n")
        let scan = try scanWorkspace(folder: u(root))

        let backlinks = getBacklinks(notes: scan.notes, targetPath: plan, root: scan.root)
        XCTAssertEqual(backlinks.linked.count, 1)
        XCTAssertTrue(backlinks.linked[0].excerpt.contains("See [[Project Plan]]"))
        let ambiguous = getBacklinks(notes: scan.notes, targetPath: meeting, root: scan.root).linked
        XCTAssertEqual(ambiguous.count, 1)
        XCTAssertTrue(ambiguous[0].ambiguous)
    }

    func testRewriteWikiLinksKeepsAnchorsAndAliasesAndSkipsCode() {
        let source = ["See [[Old Title]], [[old title#Goals|the plan]] and [[Other]].", "`[[Old Title]]` stays.", "```", "[[Old Title]]", "```"].joined(separator: "\n")
        let result = rewriteWikiLinks(source, matching: { $0.lowercased() == "old title" }, replacement: "New Title")
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.text.contains("See [[New Title]], [[New Title#Goals|the plan]] and [[Other]]."))
        XCTAssertTrue(result.text.contains("`[[Old Title]]` stays."))
        XCTAssertTrue(result.text.contains("```\n[[Old Title]]\n```"))
        let aliased = rewriteWikiLinks("[[Old Title]]", matching: { _ in true }, replacement: "notes/new", alias: "New Title")
        XCTAssertEqual(aliased.text, "[[notes/new|New Title]]")
    }

    // MARK: Refresh

    func testRefreshReReadsOnlyChangedFilesAndTracksAdditionsDeletionsAndTrash() async throws {
        let root = try makeTempDir()
        let past = Date().addingTimeInterval(-60)
        let a = try write(root, "a.md", "# A\n", mtime: past)
        let b = try write(root, "b.md", "# B\n", mtime: past)
        let index = LibraryIndex(root: u(root))
        let unchangedBefore = await index.refresh()
        XCTAssertTrue(unchangedBefore)
        var snapshot = await index.snapshot()
        let version = snapshot.version

        try write(root, "a.md", "# A changed\n")
        try write(root, "c.md", "# C\n")
        let changed = await index.refresh()
        XCTAssertTrue(changed)
        snapshot = await index.snapshot()
        XCTAssertEqual(snapshot.version, version + 1)
        XCTAssertEqual(titles(snapshot), ["A changed", "B", "C"])
        let again = await index.refresh()
        XCTAssertFalse(again, "nothing changed")
        let versionAfter = await index.snapshot().version
        XCTAssertEqual(versionAfter, version + 1)

        try FileManager.default.removeItem(atPath: a)
        try FileManager.default.createDirectory(atPath: root + "/.frisket/Trash", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: b, toPath: root + "/.frisket/Trash/b.md")
        await index.refresh()
        snapshot = await index.snapshot()
        let pairs = snapshot.summaries.map { [$0.title, $0.isTrashed ? "trashed" : "active"] }.sorted { $0[0] < $1[0] }
        XCTAssertEqual(pairs, [["B", "trashed"], ["C", "active"]])
        XCTAssertEqual(snapshot.tags, [])
    }

    func testTheSnapshotReportsATruncatedIndex() async throws {
        let root = try makeTempDir()
        for name in ["a", "b", "c"] { try write(root, name + ".md", "# " + name) }
        let index = LibraryIndex(root: u(root), limits: ScanLimits(maxDepth: 12, maxFiles: 2, maxFileBytes: 4 << 20, maxTotalBytes: 96 << 20))
        let overview = await index.overview()
        XCTAssertTrue(overview.snapshot.truncated)
        XCTAssertEqual(overview.snapshot.summaries.count, 2)
    }

    func testATitleChangeOffersToUpdateLinksThatUsedTheOldTitle() async throws {
        let root = try makeTempDir()
        let past = Date().addingTimeInterval(-60)
        let plan = try write(root, "Notes/2026-10-14-untitled.md", "---\nfrisket-id: abc\n---\n\n# Project Plan\n", mtime: past)
        let daily = try write(root, "Notes/daily.md", "See [[Project Plan#Goals|the plan]] and [[Project Plan]].\n", mtime: past)
        try write(root, "Notes/other.md", "Unrelated [[Elsewhere]].\n", mtime: past)
        let index = await openIndex(root)

        try write(root, "Notes/2026-10-14-untitled.md", "---\nfrisket-id: abc\n---\n\n# Road\n")
        await index.refresh()
        try write(root, "Notes/2026-10-14-untitled.md", "---\nfrisket-id: abc\n---\n\n# Roadmap\n")
        let found = await index.titleChange(for: u(plan), refresh: true)
        let change = try XCTUnwrap(found)
        XCTAssertEqual([change.from, change.to], ["Project Plan", "Roadmap"])
        XCTAssertEqual(change.links, 2)
        XCTAssertEqual(change.files, [daily])

        let result = await index.updateTitleLinks(for: u(plan))
        XCTAssertEqual(result, UpdateTitleLinksResult(links: 2, files: 1, skipped: []))
        XCTAssertEqual(try read(daily), "See [[Roadmap#Goals|the plan]] and [[Roadmap]].\n")
        let remaining = await index.titleChange(for: u(plan))
        XCTAssertNil(remaining)
        let overview = await index.overview(for: u(plan))
        XCTAssertEqual(overview.context?.backlinks.linked.count, 2)
    }

    func testChangingATitleBackClearsThePendingChange() async throws {
        let root = try makeTempDir()
        let past = Date().addingTimeInterval(-60)
        let plan = try write(root, "plan.md", "# Alpha\n", mtime: past)
        try write(root, "ref.md", "[[Alpha]]\n", mtime: past)
        let index = await openIndex(root)
        try write(root, "plan.md", "# Beta\n")
        let pending = await index.titleChange(for: u(plan), refresh: true)
        XCTAssertEqual(pending?.links, 1)
        try write(root, "plan.md", "# Alpha\n", mtime: Date())
        let cleared = await index.titleChange(for: u(plan), refresh: true)
        XCTAssertNil(cleared)
    }

    func testDismissTitleChange() async throws {
        let root = try makeTempDir()
        let past = Date().addingTimeInterval(-60)
        let plan = try write(root, "plan.md", "# Alpha\n", mtime: past)
        try write(root, "ref.md", "[[Alpha]]\n", mtime: past)
        let index = await openIndex(root)
        try write(root, "plan.md", "# Beta\n")
        let pending = await index.titleChange(for: u(plan), refresh: true)
        XCTAssertNotNil(pending)
        await index.dismissTitleChange(for: u(plan))
        let after = await index.titleChange(for: u(plan))
        XCTAssertNil(after)
    }

    func testBacklinksForTwoThousandLinkedNotesAreFast() async throws {
        let root = try makeTempDir()
        let count = 2000
        for i in 0..<count {
            let links = (0..<5).map { "[[note-\((i * 7 + $0 * 13) % count)]]" }.joined(separator: " ")
            try write(root, "note-\(i).md", "# Note \(i)\n\n#work/p\(i % 20) Prose about note \(i). \(links)\n- [ ] task\n")
        }
        let index = LibraryIndex(root: u(root))
        await index.refresh()
        let started = Date()
        let overview = await index.overview(for: u(root + "/note-0.md"))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(overview.snapshot.summaries.count, count)
        XCTAssertGreaterThan(overview.context?.backlinks.linked.count ?? 0, 0)
        XCTAssertLessThan(elapsed, 3, "overview with backlinks took \(elapsed) s")
    }

    func testWatcherEventsIgnoreHiddenAndDependencyPathsButNotTheLibraryTrash() {
        XCTAssertTrue(LibraryIndex.isIgnoredChange(relativePath: ".git/index"))
        XCTAssertTrue(LibraryIndex.isIgnoredChange(relativePath: "notes/.a.md.123.tmp"))
        XCTAssertTrue(LibraryIndex.isIgnoredChange(relativePath: "node_modules/x/readme.md"))
        XCTAssertTrue(LibraryIndex.isIgnoredChange(relativePath: ".frisket/history/x.md"))
        XCTAssertFalse(LibraryIndex.isIgnoredChange(relativePath: ".frisket/Trash/x.md"))
        XCTAssertFalse(LibraryIndex.isIgnoredChange(relativePath: "Notes/plan.md"))
        XCTAssertTrue(LibraryIndex.isIgnoredChange(relativePath: "a\\.hidden\\b.md"))
        XCTAssertFalse(LibraryIndex.isIgnoredChange(relativePath: ""))
    }

    // MARK: Essentials

    func testSearchHitsReportTheMatchingLineTaskTagOrImage() {
        let text = "---\nfrisket-id: a\n---\n# Title\n\nIntro line.\n- [x] done\n- [ ] open task\nTagged #work/plan here.\n![img](a.png)\n"
        func at(_ query: String) -> SearchMatch { findSearchMatch(text, query: parseSearchQuery(query)) }
        XCTAssertEqual([at("intro").line, at("intro").column], [6, 0])
        XCTAssertEqual(at("intro").text, "Intro line.")
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: at("intro").pos, length: 5)), "Intro")
        XCTAssertEqual(at("@todo").line, 8)
        XCTAssertEqual(at("#work").line, 9)
        XCTAssertEqual(at("@images").line, 10)
        XCTAssertEqual(at("").line, 4, "no operator: the first body line")
    }

    func testPinningWritesFrontMatterAndSnapshotsFirst() async throws {
        let root = try makeTempDir()
        let plan = try write(root, "plan.md", "# Plan\n\nBody\n")
        let index = await openIndex(root)
        try await index.setPinned(u(plan), pinned: true)
        XCTAssertEqual(try read(plan), "---\nfrisket-pinned: true\n---\n\n# Plan\n\nBody\n")
        let pinned = await index.snapshot().summaries[0].pinned
        XCTAssertTrue(pinned)
        try await index.setPinned(u(plan), pinned: false)
        XCTAssertEqual(try read(plan), "# Plan\n\nBody\n")
        XCTAssertEqual(try HistoryStore.list(file: u(plan), text: "# Plan\n", libraryRoot: u(root)).count, 2)
    }

    func testSearchReturnsMatchesSkippingTrashUnlessAsked() async throws {
        let root = try makeTempDir()
        try write(root, "a.md", "# Alpha\n\nThe quick fox.\n")
        try write(root, "b.md", "---\nfrisket-trashed-at: 2026-01-01T00:00:00Z\n---\n# Beta\n\nAnother fox.\n")
        let index = await openIndex(root)
        let found = await index.search(query: "fox")
        XCTAssertEqual(found.notes.map { [$0.summary.title, String($0.match!.line), $0.match!.text] }, [["Alpha", "3", "The quick fox."]])
        XCTAssertEqual(found.terms, ["fox"])
        let all = await index.search(query: "fox", includeTrashed: true)
        XCTAssertEqual(all.notes.count, 2)
    }

    func testContextReturnsBacklinksAndLinkMentionTurnsAMentionIntoALink() async throws {
        let root = try makeTempDir()
        let target = try write(root, "Notes/2026-10-14-plan.md", "---\nfrisket-id: p\n---\n# Project Plan\n")
        let source = try write(root, "Notes/daily.md", "😀 Talked about the Project Plan today.\nAlso [[Project Plan]].\n")
        let index = await openIndex(root)
        let found = await index.context(for: u(target))
        let context = try XCTUnwrap(found)
        XCTAssertEqual(context.backlinks.linked.count, 1)
        XCTAssertEqual(context.backlinks.unlinked.count, 1)
        let mention = context.backlinks.unlinked[0]
        do {
            _ = try await index.linkMention(in: u(source), pos: mention.pos, length: mention.length, expected: "Something else", target: u(target))
            XCTFail("should refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed"))
        }
        _ = try await index.linkMention(in: u(source), pos: mention.pos, length: mention.length, expected: mention.text, target: u(target))
        XCTAssertEqual(try read(source), "😀 Talked about the [[Project Plan]] today.\nAlso [[Project Plan]].\n")
        let after = await index.context(for: u(target))
        XCTAssertEqual([after?.backlinks.linked.count, after?.backlinks.unlinked.count], [2, 0])
        let missing = await index.context(for: u(root + "/missing.md"))
        XCTAssertNil(missing)
    }

    func testConflictCopiesAreRecognisedByNameAndByDuplicateID() {
        XCTAssertEqual(conflictCopyOf("Plan (Sam's conflicted copy 2026-10-15)", hostName: "host"), ConflictCopy(kind: .conflictedCopy, base: "Plan"))
        XCTAssertEqual(conflictCopyOf("Plan (conflicted copy 2026-10-15 101010)", hostName: "host"), ConflictCopy(kind: .conflictedCopy, base: "Plan"))
        XCTAssertEqual(conflictCopyOf("Plan.sync-conflict-20261015-101010-ABCDEFG", hostName: "host"), ConflictCopy(kind: .syncthing, base: "Plan"))
        XCTAssertEqual(conflictCopyOf("Plan-DESKTOP-4F2K9QZ", hostName: "host"), ConflictCopy(kind: .onedrive, base: "Plan"))
        XCTAssertEqual(conflictCopyOf("Plan-studio-mac", hostName: "Studio-Mac.local"), ConflictCopy(kind: .onedrive, base: "Plan"))
        XCTAssertNil(conflictCopyOf("topic-pc", hostName: "pc"), "short device names are not matched")
        XCTAssertNil(conflictCopyOf("Plan", hostName: "host"))
    }

    func testConflictsLeaveTheNormalViewsAndResolveWithoutSilentOverwrites() async throws {
        let root = try makeTempDir()
        let past = Date().addingTimeInterval(-60)
        let plan = try write(root, "Plan.md", "---\nfrisket-id: plan\n---\n# Plan\n\nOriginal line.\n", mtime: past)
        let planCopy = try write(root, "Plan (Sam's conflicted copy 2026-10-15).md", "---\nfrisket-id: plan\n---\n# Plan\n\nEdited elsewhere.\n", mtime: past)
        let orphan = try write(root, "Old.sync-conflict-20261015-101010-ABCDEFG.md", "# Old\n", mtime: past)
        let idea = try write(root, "Idea.md", "---\nfrisket-id: idea\n---\n# Idea\n#tagged\n", mtime: past)
        let ideaCopy = try write(root, "Idea 2.md", "---\nfrisket-id: idea\n---\n# Idea\n#tagged\n", mtime: past)
        try write(root, "links.md", "See [[Plan]] and [[Idea]].\n", mtime: past)
        let index = await openIndex(root)

        let snapshot = await index.snapshot()
        XCTAssertEqual(snapshot.conflicts, 3)
        let byName = Dictionary(uniqueKeysWithValues: snapshot.summaries.map { ($0.name, $0.conflict) })
        XCTAssertEqual(byName["Plan (Sam's conflicted copy 2026-10-15).md"], NoteConflict(kind: .conflictedCopy, originalPath: plan))
        XCTAssertEqual(byName["Old.sync-conflict-20261015-101010-ABCDEFG.md"], NoteConflict(kind: .syncthing, originalPath: nil))
        XCTAssertEqual(byName["Idea 2.md"], NoteConflict(kind: .duplicateID, originalPath: idea))
        XCTAssertNil(byName["Idea.md"] ?? nil)
        XCTAssertEqual(snapshot.tags, [TagCount(tag: "tagged", count: 1)], "copies do not double tag counts")
        let resolved = await index.resolveLink("Plan", from: u(root + "/links.md"))
        XCTAssertEqual(resolved.note?.path, plan, "copies do not make links ambiguous")

        // Keep this copy: the original takes the copy's text (and is snapshotted), the copy goes to Trash.
        try await index.resolveConflict(u(planCopy), action: .keepCopy)
        XCTAssertTrue(try read(plan).contains("Edited elsewhere."))
        XCTAssertTrue(try read(planCopy).contains("frisket-trashed-at: "))
        let versions = try HistoryStore.list(file: u(plan), text: try read(plan), libraryRoot: u(root))
        XCTAssertEqual(try HistoryStore.read(file: u(plan), text: "---\nfrisket-id: plan\n---\n", id: versions.last!.id, libraryRoot: u(root)),
                       "---\nfrisket-id: plan\n---\n# Plan\n\nOriginal line.\n")

        // Keep both: a duplicate gets a new frisket-id; a named copy is renamed.
        try await index.resolveConflict(u(ideaCopy), action: .keepBoth)
        XCTAssertFalse(try read(ideaCopy).contains("frisket-id: idea\n"))
        let kept = try await index.resolveConflict(u(orphan), action: .keepBoth)
        XCTAssertEqual(kept.lastPathComponent, "Old (copy).md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan))
        let remaining = await index.snapshot().conflicts
        XCTAssertEqual(remaining, 0)
        do {
            try await index.resolveConflict(u(plan), action: .keepOriginal)
            XCTFail("not a conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer a conflict copy"))
        }
    }

    func testSnapshotCarriesLinkTextAndSortsByPath() async throws {
        let root = try makeTempDir()
        try write(root, "b/Two.md", "# Beta title\n")
        try write(root, "a/One.md", "# Alpha title\n")
        let index = await openIndex(root)
        let snapshot = await index.snapshot()
        XCTAssertEqual(snapshot.summaries.map(\.relative), ["a/One.md", "b/Two.md"])
        XCTAssertEqual(snapshot.summaries.map(\.linkText), ["Alpha title", "Beta title"])
        XCTAssertEqual(snapshot.root.path, root)
    }
}
