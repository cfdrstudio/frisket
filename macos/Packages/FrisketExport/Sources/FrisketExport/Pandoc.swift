import Foundation

/// An output format Pandoc can write (exporter.js `FORMATS`).
public struct PandocFormat: Equatable, Sendable {
    /// Key used by the app and menus (`docx`, `latex`, …).
    public let id: String
    /// Output file extension.
    public let fileExtension: String
    /// Pandoc's `--to` writer name.
    public let writer: String
    /// Display name for save panels and menus.
    public let name: String
}

public enum PandocError: LocalizedError, Equatable {
    case notFound
    case unsupportedFormat(String)
    case failed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Pandoc was not found. Install it from pandoc.org or set its location."
        case .unsupportedFormat(let id): return "Unsupported export format: \(id)"
        case .failed(let message): return message.isEmpty ? "Pandoc failed" : message
        case .timedOut(let seconds): return "Pandoc did not finish within \(Int(seconds)) seconds."
        }
    }
}

/// Locating and running Pandoc. Pandoc is GPL, so Frisket never bundles it: it finds
/// a copy the user installed (custom path, usual install folders, then `PATH`).
public enum Pandoc {
    /// Formats in menu order.
    public static let formats: [PandocFormat] = [
        PandocFormat(id: "docx", fileExtension: "docx", writer: "docx", name: "Word Document"),
        PandocFormat(id: "odt", fileExtension: "odt", writer: "odt", name: "OpenDocument Text"),
        PandocFormat(id: "rtf", fileExtension: "rtf", writer: "rtf", name: "Rich Text Format"),
        PandocFormat(id: "epub", fileExtension: "epub", writer: "epub3", name: "EPUB eBook"),
        PandocFormat(id: "latex", fileExtension: "tex", writer: "latex", name: "LaTeX Source"),
        PandocFormat(id: "rst", fileExtension: "rst", writer: "rst", name: "reStructuredText"),
        PandocFormat(id: "textile", fileExtension: "textile", writer: "textile", name: "Textile"),
        PandocFormat(id: "mediawiki", fileExtension: "wiki", writer: "mediawiki", name: "MediaWiki Markup"),
    ]

    public static func format(id: String) -> PandocFormat? {
        formats.first { $0.id == id }
    }

    /// The Markdown dialect handed to `--from` (exporter.js `PANDOC_FROM`).
    public static let inputFormat = [
        "markdown", "tex_math_dollars", "tex_math_single_backslash", "backtick_code_blocks",
        "fenced_code_attributes", "pipe_tables", "task_lists", "strikeout", "footnotes",
        "definition_lists", "superscript", "subscript", "yaml_metadata_block", "raw_html",
        "autolink_bare_uris", "implicit_figures",
    ].joined(separator: "+")

    /// Folders searched before `PATH`.
    public static var installDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/opt/local/bin", "/bin", home + "/.local/bin", home + "/bin", "/Applications/pandoc/bin",
        ]
    }

    /// Where Pandoc is: `customPath` if it exists, the install folders, then each `PATH` entry.
    public static func locate(customPath: String? = nil, searchPath: String? = nil) -> URL? {
        let fm = FileManager.default
        if let custom = customPath?.trimmingCharacters(in: .whitespaces), !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        let onPath = (searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for directory in installDirectories + onPath {
            let candidate = directory + "/pandoc"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// The command-line arguments for converting `input` into `output`.
    public static func arguments(input: URL, output: URL, format: PandocFormat, resourcePath: URL, toc: Bool = false, title: String? = nil) -> [String] {
        var args = [
            input.path,
            "--from=" + inputFormat,
            "--to=" + format.writer,
            "--output=" + output.path,
            "--resource-path=" + resourcePath.path,
            "--wrap=preserve",
        ]
        if format.writer != "docx", format.writer != "odt" { args.append("--standalone") }
        if format.writer == "epub3" || format.writer == "docx" { args.append("--mathml") }
        if toc { args += ["--toc", "--toc-depth=3"] }
        if let title, !title.isEmpty { args.append("--metadata=title:" + title) }
        return args
    }

    /// Convert Markdown text to `format`, writing `output`. `resourcePath` is the note's
    /// folder (relative images resolve there). Throws `PandocError.notFound` when no
    /// Pandoc is installed, `.failed` with Pandoc's stderr, or `.timedOut`.
    public static func convert(
        markdown: String,
        format: PandocFormat,
        to output: URL,
        resourcePath: URL? = nil,
        customPath: String? = nil,
        toc: Bool = false,
        title: String? = nil,
        timeout: TimeInterval = 120
    ) async throws {
        guard let executable = locate(customPath: customPath) else { throw PandocError.notFound }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("frisket-export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let input = work.appendingPathComponent("source.md")
        try Data(markdown.utf8).write(to: input)
        let directory = resourcePath ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? work
        let args = arguments(input: input, output: output, format: format, resourcePath: directory, toc: toc, title: title)
        try await run(executable: executable, arguments: args, directory: directory, timeout: timeout)
    }

    /// Convenience taking the format key (`"docx"`); unknown keys throw `.unsupportedFormat`.
    public static func convert(
        markdown: String,
        format id: String,
        to output: URL,
        resourcePath: URL? = nil,
        customPath: String? = nil,
        toc: Bool = false,
        title: String? = nil,
        timeout: TimeInterval = 120
    ) async throws {
        guard let format = format(id: id) else { throw PandocError.unsupportedFormat(id) }
        try await convert(markdown: markdown, format: format, to: output, resourcePath: resourcePath,
                          customPath: customPath, toc: toc, title: title, timeout: timeout)
    }

    // MARK: process

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var timedOut = false
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
    }

    static func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout
        process.standardInput = FileHandle.nullDevice
        let errors = Collector()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errors.append(chunk) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        let gate = Gate()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                stderr.fileHandleForReading.readabilityHandler = nil
                stdout.fileHandleForReading.readabilityHandler = nil
                let rest = stderr.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { errors.append(rest) }
                if gate.timedOut {
                    continuation.resume(throwing: PandocError.timedOut(timeout))
                } else if finished.terminationStatus != 0 {
                    continuation.resume(throwing: PandocError.failed(errors.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    continuation.resume()
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    gate.markTimedOut()
                    process.terminate()
                }
            }
        }
    }
}
