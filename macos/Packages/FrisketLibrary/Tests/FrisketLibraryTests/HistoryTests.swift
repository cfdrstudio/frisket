import XCTest
@testable import FrisketLibrary

final class HistoryTests: XCTestCase {
    let minute: Int64 = 60_000
    let t0 = dateFromMs(1_791_968_400_000)  // 2026-10-14T09:00:00.000Z

    func at(_ ms: Int64) -> Date { dateFromMs(1_791_968_400_000 + ms) }

    func testSnapshotsSkipIdenticalTextAndRespectTheSaveGaps() throws {
        let library = try makeTempDir()
        let note = u(library + "/Notes/plan.md")
        func record(_ text: String, _ reason: HistoryReason, _ ms: Int64) throws -> HistoryRecordResult {
            try HistoryStore.record(file: note, text: text, libraryRoot: u(library), reason: reason, now: at(ms))
        }
        XCTAssertNotNil(try record("one", .open, 0).snapshotID)
        XCTAssertEqual(try record("one", .save, minute).skipReason, .unchanged)
        XCTAssertEqual(try record("two", .save, 10_000).skipReason, .recent)
        XCTAssertNotNil(try record("two", .save, 31_000).snapshotID)
        XCTAssertEqual(try record("three", .autosave, 2 * minute).skipReason, .recent)
        XCTAssertNotNil(try record("three", .beforeChange, 2 * minute).snapshotID)

        let versions = try HistoryStore.list(file: note, text: "three", libraryRoot: u(library))
        XCTAssertEqual(versions.map(\.time), [at(2 * minute), at(31_000), at(0)])
        XCTAssertEqual(try HistoryStore.read(file: note, text: "three", id: versions[2].id, libraryRoot: u(library)), "one")
        XCTAssertThrowsError(try HistoryStore.read(file: note, text: "three", id: "../../secret.md", libraryRoot: u(library))) {
            XCTAssertTrue("\($0)".contains("Unknown version") || $0.localizedDescription.contains("Unknown version"))
        }
    }

    func testStampsAndNamesMatchTheJavaScriptFormat() throws {
        XCTAssertEqual(HistoryStore.stampFor(t0), "2026-10-14T09-00-00-000Z")
        XCTAssertEqual(HistoryStore.stampFor(at(31_007)), "2026-10-14T09-00-31-007Z")
        XCTAssertEqual(HistoryStore.timeOf("2026-10-14T09-00-31-007Z.md"), at(31_007))
        XCTAssertEqual(HistoryStore.timeOf("2026-10-14T09-00-31-007Z~002.md"), at(31_007))
        XCTAssertNil(HistoryStore.timeOf("meta.json"))
        // 1 Jan 1970 and a leap day.
        XCTAssertEqual(HistoryStore.stampFor(Date(timeIntervalSince1970: 0)), "1970-01-01T00-00-00-000Z")
        XCTAssertEqual(HistoryStore.stampFor(dateFromMs(1_709_210_096_789)), "2024-02-29T12-34-56-789Z")
    }

    func testSecondSnapshotInTheSameMillisecondGetsASuffix() throws {
        let library = try makeTempDir()
        let note = u(library + "/a.md")
        let first = try HistoryStore.record(file: note, text: "a", libraryRoot: u(library), reason: .open, now: t0)
        let second = try HistoryStore.record(file: note, text: "b", libraryRoot: u(library), reason: .open, now: t0)
        XCTAssertEqual(first.snapshotID, "2026-10-14T09-00-00-000Z.md")
        XCTAssertEqual(second.snapshotID, "2026-10-14T09-00-00-000Z~001.md")
        XCTAssertEqual(try HistoryStore.list(file: note, text: "b", libraryRoot: u(library)).map(\.id).first, "2026-10-14T09-00-00-000Z~001.md")
    }

    func testLibraryNotesAreKeyedByFrisketIDSoHistorySurvivesRenames() throws {
        let library = try makeTempDir()
        let text = "---\nfrisket-id: note-123\n---\n# Plan\n"
        try HistoryStore.record(file: u(library + "/a.md"), text: text, libraryRoot: u(library), reason: .open, now: t0)
        let moved = u(library + "/Archive/renamed.md")
        XCTAssertEqual(try HistoryStore.list(file: moved, text: text, libraryRoot: u(library)).count, 1)
        let meta = try read(library + "/.frisket/history/id-note-123/meta.json")
        XCTAssertEqual(meta, "{\n  \"path\": \"a.md\",\n  \"title\": \"Plan\",\n  \"updatedAt\": \"2026-10-14T09:00:00.000Z\"\n}")
    }

    func testPathKeysAreSHA1PrefixesOfTheRelativePath() throws {
        // Node: sha1('Notes/plan.md').hex.slice(0, 20), no lower-casing on macOS.
        let location = HistoryStore.locate(file: u("/lib/Notes/plan.md"), text: "x", libraryRoot: u("/lib"), fallbackRoot: nil)
        XCTAssertEqual(location?.key, "p-a4511ab2b3339d3b3fd1")
        XCTAssertEqual(location?.relative, "Notes/plan.md")
        XCTAssertEqual(location?.directory.path, "/lib/.frisket/history/" + (location?.key ?? ""))
    }

    func testFilesOutsideALibraryKeepHistoryInAppData() throws {
        let appData = try makeTempDir()
        let other = try makeTempDir()
        let loose = u(other + "/loose.md")
        let result = try HistoryStore.record(file: loose, text: "text", libraryRoot: nil, fallbackRoot: u(appData), reason: .open, now: t0)
        XCTAssertNotNil(result.snapshotID)
        guard case .snapshot(_, let key) = result else { return XCTFail() }
        XCTAssertTrue(key.hasPrefix("p-"))
        let names = try FileManager.default.contentsOfDirectory(atPath: appData + "/history/" + key)
        XCTAssertEqual(names.filter { $0.hasSuffix(".md") }.count, 1)
        XCTAssertEqual(try HistoryStore.record(file: loose, text: "text", reason: .open, now: t0).skipReason, .noLocation)
    }

    func testOldSnapshotsThinOutWithAge() {
        var names: [String] = []
        var age: Int64 = 0
        while age <= 3 * 24 * 60 { names.append(HistoryStore.stampFor(at(-age * minute)) + ".md"); age += 5 }
        let keep = HistoryStore.snapshotsToKeep(names, now: t0)
        let ages = keep.map { Double(msSinceEpoch(t0) - HistoryStore.timeMs($0)!) / Double(minute) }
        XCTAssertEqual(ages.filter { $0 < 60 }.count, 12, "everything from the last hour")
        let day = ages.filter { $0 >= 60 && $0 < 24 * 60 }.count
        XCTAssertTrue(day >= 90 && day <= 93, "about one per 15 minutes for the rest of the day, got \(day)")
        let older = ages.filter { $0 >= 24 * 60 }.count
        XCTAssertTrue(older >= 24 && older <= 26, "about one per 2 hours after that, got \(older)")
    }

    func testIdenticalContentComparesBytesNotCanonicalEquivalence() throws {
        let library = try makeTempDir()
        let note = u(library + "/n.md")
        try HistoryStore.record(file: note, text: "caf\u{e9}", libraryRoot: u(library), reason: .open, now: t0)
        let second = try HistoryStore.record(file: note, text: "cafe\u{301}", libraryRoot: u(library), reason: .open, now: at(1))
        XCTAssertNotNil(second.snapshotID)
    }
}
