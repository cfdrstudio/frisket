import Foundation

public enum FileOpsError: LocalizedError {
    case changedOnDisk(URL)
    case exists(URL)
    case noUniqueName(String)
    case outsideRoot(URL)

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk(let url): return "\(url.lastPathComponent) changed on disk."
        case .exists(let url): return "\(url.lastPathComponent) already exists."
        case .noUniqueName(let name): return "Could not choose a unique name for \(name)."
        case .outsideRoot(let url): return "\(url.path) is outside the library."
        }
    }
}

/// File operations shared by the library, history and importers. Port of files.js.
public enum FileOps {
    /// Read a UTF-8 text file, tolerating a byte-order mark.
    public static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if var text = String(data: data, encoding: .utf8) {
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The file's modification date, or nil when it cannot be read.
    /// Read from disk every time: `URL` caches resource values, which would hide a concurrent edit.
    public static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Replace `url` atomically: write a hidden temporary file beside it, then
    /// rename over it. With `expectedModificationDate`, refuse (and leave the
    /// file alone) if it changed on disk since then.
    public static func replaceFile(_ url: URL, text: String, expectedModificationDate: Date? = nil) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970 * 1000)).tmp")
        try Data(text.utf8).write(to: temporary, options: [.withoutOverwriting])
        do {
            if let expected = expectedModificationDate {
                let current = modificationDate(url)
                if let current, abs(current.timeIntervalSince(expected)) > 0.002 { throw FileOpsError.changedOnDisk(url) }
            }
            if rename(temporary.path, url.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Write a new file, failing if one already exists (`flag: 'wx'`).
    public static func writeNewFile(_ url: URL, text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Data(text.utf8).write(to: url, options: [.withoutOverwriting])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw FileOpsError.exists(url)
        }
    }

    /// Is `candidate` inside (or equal to) `root`? `.` and `..` are resolved lexically;
    /// symlinks (including `/var` → `/private/var`) are not, so the answer does not
    /// depend on which paths exist yet.
    public static func isWithin(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = root.standardized.path
        let candidatePath = candidate.standardized.path
        if candidatePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    /// Is `candidate` inside `root` once both are resolved through symlinks?
    public static func isWithinResolved(_ root: URL, _ candidate: URL) -> Bool {
        isWithin(root.resolvingSymlinksInPath(), candidate.resolvingSymlinksInPath())
    }

    /// A file or folder name that is safe on Windows, macOS and Linux.
    public static func safeName(_ name: String, fallback: String = "Untitled", max: Int = 120) -> String {
        var clean = Rx("[<>:\"/\\\\|?*\\x00-\\x1f]+").replace(name, template: " ")
        clean = Rx("\\s+").replace(clean, template: " ").jsTrimmed
        clean = Rx("[. ]+$").replace(clean, template: "")
        if clean.utf16Length > max { clean = clean.utf16Slice(0, max) }
        clean = clean.jsTrimmed
        if clean.isEmpty || Rx("^\\.+$").test(clean) || Rx("^(?:con|prn|aux|nul|com\\d|lpt\\d)$", [.caseInsensitive]).test(clean) {
            return fallback
        }
        return clean
    }

    /// The first `<dir>/<stem><ext>`, `<stem> 2<ext>`, … that does not exist and is
    /// not in `reserved` (lower-cased paths; the chosen path is added to it).
    public static func uniqueURL(in directory: URL, stem: String, ext: String, reserved: inout Set<String>) throws -> URL {
        for n in 1..<10000 {
            let candidate = directory.appendingPathComponent(stem + (n == 1 ? "" : " \(n)") + ext)
            let key = candidate.path.lowercased()
            if reserved.contains(key) { continue }
            if !FileManager.default.fileExists(atPath: candidate.path) {
                reserved.insert(key)
                return candidate
            }
        }
        throw FileOpsError.noUniqueName(stem + ext)
    }

    public static func uniqueURL(in directory: URL, stem: String, ext: String) throws -> URL {
        var reserved = Set<String>()
        return try uniqueURL(in: directory, stem: stem, ext: ext, reserved: &reserved)
    }

    /// Create `root/name` as a regular folder (not a symlink) if needed and return it.
    public static func managedFolder(_ root: URL, _ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true || values.isDirectory != true {
            throw NSError(domain: "Frisket", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) must be a regular folder."])
        }
        return directory
    }
}

/// Markdown file extensions Frisket lists as notes.
public let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "txt"]

public func isMarkdownFile(_ url: URL) -> Bool {
    markdownExtensions.contains(url.pathExtension.lowercased())
}

/// Folders never walked when scanning a library.
public let ignoredDirectoryNames: Set<String> = [".git", "node_modules", ".obsidian", ".vscode", "$RECYCLE.BIN", "System Volume Information"]
