import XCTest
@testable import FrisketExport

final class PlainTextTests: XCTestCase {
    func testHeadingsParagraphsListsAndLinks() {
        let text = PlainText.from(markdown: """
        ---
        title: T
        ---
        # Title

        A paragraph with [a link](https://x.org) and **bold** and `code`.

        - one
        - two

        1. first
        2. second

        ---

        > quoted
        """)
        XCTAssertEqual(text, """
        Title

        A paragraph with a link and bold and code.

          - one
          - two

          1. first
          1. second

        \(String(repeating: "-", count: 60))

        quoted

        """)
    }

    func testTablesCodeAndMath() {
        let text = PlainText.from(markdown: "| a | b |\n|---|---|\n| 1 | 2 |\n\n```\nlet x = 1 < 2\n```\n\nEuler $e^{i\\pi}$ & more\n")
        XCTAssertTrue(text.contains("a\tb"))
        XCTAssertTrue(text.contains("1\t2"))
        XCTAssertTrue(text.contains("let x = 1 < 2"))
        XCTAssertTrue(text.contains("Euler $e^{i\\pi}$ & more"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
    }

    func testNoTripleNewlinesOrTrailingSpaces() {
        let text = PlainText.from(markdown: "# A\n\n\n\n## B  \n\ntext\n")
        XCTAssertFalse(text.contains("\n\n\n"))
        XCTAssertFalse(text.contains(" \n"))
    }
}

final class MarkdownBundleTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-bundle-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib/notes/assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib/shared"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
        try ImageEmbeddingTests.png.write(to: root.appendingPathComponent("lib/notes/assets/My Pic.png"))
        try Data("a".utf8).write(to: root.appendingPathComponent("lib/notes/assets/doc.pdf"))
        try Data("b".utf8).write(to: root.appendingPathComponent("lib/shared/other.pdf"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCopiesAttachmentsAndRewritesLinks() throws {
        let note = root.appendingPathComponent("lib/notes/Note.md")
        let output = root.appendingPathComponent("out/Exported Note.md")
        let text = "![pic](<assets/My Pic.png>) [pdf](assets/doc.pdf#page=2) [web](https://x.org) [anchor](#top) [gone](assets/none.png) [hack](../../secret.txt)\n"
        let result = try MarkdownBundle.export(noteURL: note, text: text, to: output)
        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(Set(result.skipped), ["assets/none.png", "../../secret.txt"])
        let dir = root.appendingPathComponent("out/Exported-Note-assets")
        XCTAssertEqual(result.assetsDirectory?.lastPathComponent, "Exported-Note-assets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("My-Pic.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("doc.pdf").path))
        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(written, "![pic](<Exported-Note-assets/My-Pic.png>) [pdf](Exported-Note-assets/doc.pdf) [web](https://x.org) [anchor](#top) [gone](assets/none.png) [hack](../../secret.txt)\n")
    }

    func testSecondExportGetsAFreshAssetFolder() throws {
        let note = root.appendingPathComponent("lib/notes/Note.md")
        let output = root.appendingPathComponent("out/N.md")
        let first = try MarkdownBundle.export(noteURL: note, text: "[a](assets/doc.pdf)", to: output)
        let second = try MarkdownBundle.export(noteURL: note, text: "[a](assets/doc.pdf)", to: output)
        XCTAssertEqual(first.assetsDirectory?.lastPathComponent, "N-assets")
        XCTAssertEqual(second.assetsDirectory?.lastPathComponent, "N-assets-1")
    }

    func testLibraryRootWidensWhatMayBeCopied() throws {
        let note = root.appendingPathComponent("lib/notes/Note.md")
        let output = root.appendingPathComponent("out/W.md")
        let text = "[o](../shared/other.pdf)"
        XCTAssertEqual(try MarkdownBundle.export(noteURL: note, text: text, to: output).copied, 0)
        let wide = try MarkdownBundle.export(noteURL: note, text: text, to: root.appendingPathComponent("out/W2.md"), libraryRoot: root.appendingPathComponent("lib"))
        XCTAssertEqual(wide.copied, 1)
    }

    func testDuplicateNamesAreMadeUnique() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib/notes/more"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: root.appendingPathComponent("lib/notes/more/doc.pdf"))
        let note = root.appendingPathComponent("lib/notes/Note.md")
        let result = try MarkdownBundle.export(noteURL: note, text: "[a](assets/doc.pdf) [b](more/doc.pdf)", to: root.appendingPathComponent("out/D.md"))
        XCTAssertEqual(result.copied, 2)
        let written = try String(contentsOf: root.appendingPathComponent("out/D.md"), encoding: .utf8)
        XCTAssertEqual(written, "[a](D-assets/doc.pdf) [b](D-assets/doc-1.pdf)")
    }

    func testWithoutNoteURLTextIsWrittenUnchanged() throws {
        let output = root.appendingPathComponent("out/U.md")
        let result = try MarkdownBundle.export(noteURL: nil, text: "![x](a.png)", to: output)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "![x](a.png)")
    }
}

final class PandocTests: XCTestCase {
    func testFormatMap() {
        let expected: [String: (String, String)] = [
            "docx": ("docx", "docx"), "odt": ("odt", "odt"), "rtf": ("rtf", "rtf"), "epub": ("epub", "epub3"),
            "latex": ("tex", "latex"), "rst": ("rst", "rst"), "textile": ("textile", "textile"), "mediawiki": ("wiki", "mediawiki"),
        ]
        XCTAssertEqual(Pandoc.formats.count, expected.count)
        for (id, pair) in expected {
            let format = Pandoc.format(id: id)
            XCTAssertEqual(format?.fileExtension, pair.0, id)
            XCTAssertEqual(format?.writer, pair.1, id)
        }
        XCTAssertNil(Pandoc.format(id: "pdf"))
        XCTAssertEqual(Pandoc.format(id: "docx")?.name, "Word Document")
    }

    func testArgumentsMatchExporterJS() {
        let input = URL(fileURLWithPath: "/tmp/s.md"), output = URL(fileURLWithPath: "/tmp/o.x"), dir = URL(fileURLWithPath: "/notes")
        let docx = Pandoc.arguments(input: input, output: output, format: Pandoc.format(id: "docx")!, resourcePath: dir, toc: true, title: "T")
        XCTAssertEqual(docx.first, "/tmp/s.md")
        XCTAssertTrue(docx.contains("--to=docx"))
        XCTAssertTrue(docx.contains("--mathml"))
        XCTAssertTrue(docx.contains("--toc"))
        XCTAssertTrue(docx.contains("--toc-depth=3"))
        XCTAssertTrue(docx.contains("--metadata=title:T"))
        XCTAssertTrue(docx.contains("--resource-path=/notes"))
        XCTAssertTrue(docx.contains("--wrap=preserve"))
        XCTAssertFalse(docx.contains("--standalone"))
        let latex = Pandoc.arguments(input: input, output: output, format: Pandoc.format(id: "latex")!, resourcePath: dir)
        XCTAssertTrue(latex.contains("--standalone"))
        XCTAssertFalse(latex.contains("--mathml"))
        XCTAssertTrue(latex.contains("--from=" + Pandoc.inputFormat))
        XCTAssertTrue(Pandoc.inputFormat.hasPrefix("markdown+tex_math_dollars"))
    }

    func testLocatePrefersCustomPath() {
        XCTAssertEqual(Pandoc.locate(customPath: "/bin/ls")?.path, "/bin/ls")
        // A missing custom path falls through to the normal search, never to the missing file.
        XCTAssertNotEqual(Pandoc.locate(customPath: "/nonexistent/pandoc", searchPath: "/nonexistent")?.path, "/nonexistent/pandoc")
    }

    func testLocateSearchesPATH() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-pandoc-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("pandoc")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        // The standard install folders come first, so only assert when none is installed.
        let installed = Pandoc.installDirectories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/pandoc") }
        if !installed { XCTAssertEqual(Pandoc.locate(searchPath: "/nonexistent:" + dir.path)?.path, fake.path) }
    }

    func testUnsupportedFormatThrows() async {
        do {
            try await Pandoc.convert(markdown: "x", format: "pdf", to: URL(fileURLWithPath: "/tmp/x.pdf"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PandocError, .unsupportedFormat("pdf"))
        }
    }

    func testRunReportsFailureAndTimeout() async throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let tmp = FileManager.default.temporaryDirectory
        do {
            try await Pandoc.run(executable: sh, arguments: ["-c", "echo boom >&2; exit 3"], directory: tmp, timeout: 10)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? PandocError, .failed("boom")) }
        do {
            try await Pandoc.run(executable: sh, arguments: ["-c", "sleep 5"], directory: tmp, timeout: 0.3)
            XCTFail("expected timeout")
        } catch { XCTAssertEqual(error as? PandocError, .timedOut(0.3)) }
        try await Pandoc.run(executable: sh, arguments: ["-c", "exit 0"], directory: tmp, timeout: 10)
    }

    func testRealConversionWhenPandocIsInstalled() async throws {
        guard Pandoc.locate() != nil else { throw XCTSkip("pandoc is not installed") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-" + UUID().uuidString + ".rst")
        defer { try? FileManager.default.removeItem(at: out) }
        try await Pandoc.convert(markdown: "# Hello\n\ntext **bold**\n", format: "rst", to: out)
        let rst = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(rst.contains("Hello"))
        XCTAssertTrue(rst.contains("**bold**"))
    }
}
