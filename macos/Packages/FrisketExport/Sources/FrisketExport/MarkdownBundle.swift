import Foundation
import FrisketBase

/// Result of exporting Markdown with its attachments.
public struct MarkdownBundleResult: Equatable, Sendable {
    /// The Markdown file written.
    public var markdownURL: URL
    /// The sidecar `<name>-assets` folder, nil when nothing was copied.
    public var assetsDirectory: URL?
    public var copied: Int
    /// References that were not copied (missing, a folder, or outside the allowed root).
    public var skipped: [String]
}

/// Markdown with its attachments (exporter.js `toMarkdown` / `copyMarkdownAssets`).
public enum MarkdownBundle {
    private static let reference = Rx("(!?\\[[^\\]]*\\]\\(\\s*)(?:<([^>]+)>|([^\\s)]+))")
    private static let external = Rx("^(?:[a-z][a-z0-9+.-]*:|//|data:|#)", [.caseInsensitive])

    /// Write `text` to `outputURL` (the `.md` file) and copy the local files it links to
    /// into a new `<output name>-assets` folder beside it, rewriting the links. Files are
    /// only read from inside `libraryRoot` when the note is in it, otherwise from the
    /// note's own folder; names are sanitised and made unique; nothing is overwritten.
    /// With no `noteURL` the text is written unchanged.
    @discardableResult
    public static func export(noteURL: URL?, text: String, to outputURL: URL, libraryRoot: URL? = nil) throws -> MarkdownBundleResult {
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        guard let noteURL else {
            try Data(text.utf8).write(to: outputURL, options: .atomic)
            return MarkdownBundleResult(markdownURL: outputURL, assetsDirectory: nil, copied: 0, skipped: [])
        }
        let sourceDirectory = noteURL.deletingLastPathComponent()
        var allowedRoot = sourceDirectory
        if let libraryRoot, FileOps.isWithin(libraryRoot, sourceDirectory) { allowedRoot = libraryRoot }
        let realRoot = allowedRoot.resolvingSymlinksInPath()

        func normalized(_ reference: String) -> String {
            let decoded = reference.removingPercentEncoding ?? reference
            return Rx("[?#].*$").replace(decoded, template: "")
        }

        var references: [String] = []
        var seen = Set<String>()
        for match in reference.matches(text) {
            let raw = (match.group(2, in: text) ?? match.group(3, in: text) ?? "").jsTrimmed
            if raw.isEmpty || external.test(raw) { continue }
            let clean = normalized(raw)
            if !clean.isEmpty, seen.insert(clean).inserted { references.append(clean) }
        }

        var mappings: [String: String] = [:]
        var reserved = Set<String>()
        var assetDirectory: URL? = nil
        var copied = 0
        var skipped: [String] = []
        let stem = Rx("[^a-z0-9._-]+", [.caseInsensitive]).replace(outputURL.deletingPathExtension().lastPathComponent, template: "-")

        func ensureAssetDirectory() throws -> URL {
            if let assetDirectory { return assetDirectory }
            let base = stem.isEmpty ? "export" : stem
            for suffix in 0..<1000 {
                let candidate = outputDirectory.appendingPathComponent(base + "-assets" + (suffix == 0 ? "" : "-\(suffix)"), isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) { continue }
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                assetDirectory = candidate
                return candidate
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "Could not create a collision-safe asset export folder."])
        }

        for ref in references {
            let candidate = ref.hasPrefix("/") ? URL(fileURLWithPath: ref) : sourceDirectory.appendingPathComponent(ref)
            let real = candidate.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileOps.isWithin(realRoot, real) else {
                skipped.append(ref)
                continue
            }
            do {
                let directory = try ensureAssetDirectory()
                var fileStem = Rx("[^a-z0-9._-]+", [.caseInsensitive]).replace(real.deletingPathExtension().lastPathComponent, template: "-")
                fileStem = Rx("^-+|-+$").replace(fileStem, template: "")
                if fileStem.isEmpty { fileStem = "attachment" }
                let ext = real.pathExtension.isEmpty ? "" : "." + real.pathExtension
                var target: URL? = nil
                for suffix in 0..<1000 {
                    let name = fileStem + (suffix == 0 ? "" : "-\(suffix)") + ext
                    if reserved.contains(name) { continue }
                    let url = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) { reserved.insert(name); continue }
                    reserved.insert(name)
                    target = url
                    break
                }
                guard let target else { skipped.append(ref); continue }
                try FileManager.default.copyItem(at: real, to: target)
                mappings[ref] = directory.lastPathComponent + "/" + target.lastPathComponent
                copied += 1
            } catch {
                skipped.append(ref)
            }
        }

        let rewritten = reference.replace(text) { match, ns in
            let whole = ns.substring(with: match.range)
            let bracketed = match.group(2, in: ns)
            let raw = (bracketed ?? match.group(3, in: ns) ?? "").jsTrimmed
            guard let mapped = mappings[normalized(raw)] else { return whole }
            return (match.group(1, in: ns) ?? "") + (bracketed != nil ? "<" + mapped + ">" : mapped)
        }
        try Data(rewritten.utf8).write(to: outputURL, options: .atomic)
        return MarkdownBundleResult(markdownURL: outputURL, assetsDirectory: assetDirectory, copied: copied, skipped: skipped)
    }
}
