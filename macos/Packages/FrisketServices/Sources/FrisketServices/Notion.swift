import Foundation
import FrisketBase

/// Notion "Markdown & CSV" export reader. Accepts the export `.zip` (including
/// the zip-of-zips Notion produces for large workspaces) or an extracted
/// folder. Zips are unpacked by `/usr/bin/ditto` into a temporary folder that
/// is removed when the import finishes. Notion appends a 32-character ID to
/// every file and folder name; the importer strips it and rewrites links.
public enum NotionExport {
    /// A Notion name without its trailing ID: `Plan 0123…cdef` becomes `Plan`.
    public static func stripNotionId(_ stem: String) -> String {
        let clean = Rx("\\s+[0-9a-f]{32}\\z", [.caseInsensitive]).replace(stem, template: "").jsTrimmed
        return clean.isEmpty ? stem.jsTrimmed : clean
    }

    /// Parse CSV text (quoted fields, doubled quotes, CR/LF/CRLF rows); blank rows are dropped.
    public static func parseCsv(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let char = scalars[i]
            if quoted {
                if char == "\"", i + 1 < scalars.count, scalars[i + 1] == "\"" { field.append("\""); i += 1 }
                else if char == "\"" { quoted = false }
                else { field.append(char) }
            } else if char == "\"" {
                quoted = true
            } else if char == "," {
                row.append(String(field)); field = String.UnicodeScalarView()
            } else if char == "\n" || char == "\r" {
                if char == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                row.append(String(field)); rows.append(row); row = []; field = String.UnicodeScalarView()
            } else {
                field.append(char)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(String(field)); rows.append(row) }
        return rows.filter { cells in cells.contains { !$0.jsTrimmed.isEmpty } }
    }

    /// A CSV database export as a Markdown table, or "" when it has no rows.
    public static func csvToMarkdownTable(_ text: String) -> String {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let rows = parseCsv(source)
        if rows.isEmpty { return "" }
        let width = rows.map(\.count).max() ?? 0
        func cell(_ value: String?) -> String {
            let flat = Rx("\\r?\\n").replace(value ?? "", template: "<br>")
            let escaped = Rx("\\|").replace(flat) { _, _ in "\\|" }.jsTrimmed
            return escaped.isEmpty ? " " : escaped
        }
        func line(_ cells: [String]) -> String {
            "| " + (0..<width).map { cell($0 < cells.count ? cells[$0] : nil) }.joined(separator: " | ") + " |"
        }
        let rule = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        return ([line(rows[0]), rule] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    /// Read an export (folder or zip) into notes. Convenience for callers that
    /// do not import: the temporary extraction is cleaned up before returning.
    public static func readNotes(from source: URL) throws -> [ImportedNote] {
        let tree = try NotionTree.load(source)
        defer { tree.cleanup() }
        return try notes(in: tree)
    }

    static func notes(in tree: NotionTree) throws -> [ImportedNote] {
        var notes: [ImportedNote] = []
        for key in tree.sortedKeys {
            let ext = posixExtname(key).lowercased()
            if ext != ".md" && ext != ".csv" { continue }
            if ext == ".csv", Rx("_all\\.csv\\z", [.caseInsensitive]).test(key),
               tree.files[Rx("_all\\.csv\\z", [.caseInsensitive]).replace(key, template: ".csv")] != nil { continue }
            let dir = posixDirname(key)
            let folder = dir == "." ? [] : jsSplit(dir, "/").map(stripNotionId)
            let base = posixBasename(key)
            let stem = stripNotionId(Rx("_all\\z", [.caseInsensitive]).replace(String(base.dropLast(ext.count)), template: ""))
            guard let url = tree.files[key] else { continue }
            var text = try FileOps.readText(url)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            if ext == ".csv" {
                let table = csvToMarkdownTable(text)
                if !table.isEmpty {
                    notes.append(ImportedNote(key: key, title: stem, markdown: "# " + stem + "\n\n" + table + "\n", folder: folder, isDatabase: true))
                }
                continue
            }
            let title = Rx("^#\\s+(.+?)\\s*$", [.anchorsMatchLines]).first(text).flatMap { $0.group(1, in: text) } ?? stem
            notes.append(ImportedNote(key: key, title: title, fileStem: stem, markdown: text, folder: folder))
        }
        return notes
    }
}

/// A Notion export as a map of `relative/path` to a file on disk.
final class NotionTree {
    var files: [String: URL] = [:]
    private var temporaryRoot: URL?

    var sortedKeys: [String] { files.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) } }

    /// Remove any temporary extraction.
    func cleanup() {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }

    static func load(_ source: URL) throws -> NotionTree {
        let tree = NotionTree()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ImportError("The Notion export could not be found.")
        }
        do {
            if isDirectory.boolValue {
                try tree.walk(source)
            } else {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-import-" + UUID().uuidString, isDirectory: true)
                tree.temporaryRoot = temp
                let outer = temp.appendingPathComponent("outer", isDirectory: true)
                try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
                try extractZip(source, into: outer)
                var folder = outer
                let probe = NotionTree()
                try probe.walk(outer)
                // Large Notion exports are a zip of zips; read through one level.
                if !probe.files.isEmpty, probe.files.keys.allSatisfy({ $0.lowercased().hasSuffix(".zip") }) {
                    let merged = temp.appendingPathComponent("merged", isDirectory: true)
                    try FileManager.default.createDirectory(at: merged, withIntermediateDirectories: true)
                    for key in probe.sortedKeys { try extractZip(probe.files[key]!, into: merged) }
                    folder = merged
                }
                try tree.walk(folder)
            }
        } catch {
            tree.cleanup()
            throw error
        }
        tree.dropExportWrapper()
        return tree
    }

    private func walk(_ root: URL) throws {
        let fm = FileManager.default
        func visit(_ directory: URL, _ prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: directory.path) {
                if name.hasPrefix(".") || (prefix.isEmpty && name == "__MACOSX") { continue }
                let url = directory.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                if values?.isSymbolicLink == true { continue }
                let key = prefix.isEmpty ? name : prefix + "/" + name
                if values?.isDirectory == true { try visit(url, key) }
                else if values?.isRegularFile == true { files[key] = url }
            }
        }
        try visit(root, "")
    }

    /// Drop Notion's single `Export-<uuid>` wrapper folder.
    private func dropExportWrapper() {
        let tops = Set(files.keys.map { $0.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0] })
        guard tops.count == 1, let top = tops.first.map(String.init),
              Rx("^Export-[0-9a-f-]{8,}\\z", [.caseInsensitive]).test(top),
              files.keys.allSatisfy({ $0.contains("/") }) else { return }
        var unwrapped: [String: URL] = [:]
        for (key, value) in files { unwrapped[String(key.dropFirst(top.count + 1))] = value }
        files = unwrapped
    }

    /// Unpack a zip with `ditto`, after refusing names that would escape the folder.
    private static func extractZip(_ zip: URL, into directory: URL) throws {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip"),
           let listing = try? runProcessBlocking("/usr/bin/unzip", ["-Z1", zip.path], timeout: 120), listing.status == 0 {
            let names = String(decoding: listing.stdout, as: UTF8.self)
            for name in jsSplit(names, "\n") where !name.isEmpty {
                let normalized = name.replacingOccurrences(of: "\\", with: "/")
                if normalized.hasPrefix("/") || Rx("^[a-zA-Z]:").test(normalized) || jsSplit(normalized, "/").contains("..") {
                    throw ImportError("This archive contains unsafe file names, so it was not opened.")
                }
            }
        }
        let result: ProcessResult
        do { result = try runProcessBlocking("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path], timeout: 1800) }
        catch { throw ImportError("Could not unpack the archive: \(error.localizedDescription)") }
        if result.status != 0 { throw ImportError("This is not a ZIP archive, or it is damaged.") }
    }
}
