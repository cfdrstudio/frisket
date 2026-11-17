import XCTest
import FrisketBase
@testable import FrisketLibrary

/// The shared parser contract in fixtures/parser-cases.json, also checked by tests/parserFixtures.test.cjs.
final class ParserFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Expect: Decodable {
            var title: String
            var tags: [String]
            var tasksDone: Int
            var tasksTotal: Int
            var hasImages: Bool
            var trashed: Bool
            var pinned: Bool
        }
        var name: String
        var fileName: String?
        var markdown: String
        var expect: Expect
    }

    private struct File: Decodable { var cases: [Fixture] }

    private func loadFixtures() throws -> [Fixture] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }   // file, tests, Tests, package, Packages, macos -> repo root
        url.appendPathComponent("fixtures/parser-cases.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    func testEveryFixtureCase() throws {
        let fixtures = try loadFixtures()
        XCTAssertGreaterThan(fixtures.count, 10)
        let tagSet = { (tags: [String]) in tags.map { $0.precomposedStringWithCanonicalMapping.lowercased() }.sorted() }
        for fixture in fixtures {
            let root = try makeTempDir("frisket-fixture")
            try write(root, fixture.fileName ?? "note.md", fixture.markdown)
            let scan = try scanWorkspace(folder: u(root))
            let note = try XCTUnwrap(scan.notes.first, fixture.name)
            let summary = summaryFor(note)
            let expect = fixture.expect
            XCTAssertEqual(note.title, expect.title, fixture.name)
            XCTAssertEqual(tagSet(summary.tags), tagSet(expect.tags), fixture.name)
            XCTAssertEqual(summary.tags.count, expect.tags.count, "no case-variant duplicates: \(fixture.name)")
            XCTAssertEqual(summary.tasksDone, expect.tasksDone, fixture.name)
            XCTAssertEqual(summary.tasksTotal, expect.tasksTotal, fixture.name)
            XCTAssertEqual(summary.hasImages, expect.hasImages, fixture.name)
            XCTAssertEqual(note.isTrashed, expect.trashed, fixture.name)
            XCTAssertEqual(summary.pinned, expect.pinned, fixture.name)
        }
    }
}
