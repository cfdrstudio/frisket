import Foundation
import FrisketBase

/// Rewrites local `<img src>` values to `data:` URIs so an exported file stands alone.
/// Remote (`http`, `https`, `//`) and `data:` sources are left alone. A local file is
/// only read when it lies inside `allowedRoot` once symlinks are resolved; anything else
/// (including absolute paths and `..` escapes) is left as written.
public struct ImageEmbedder {
    public var noteDirectory: URL?
    public var allowedRoot: URL?
    /// Larger files are linked by `file:` URL instead of embedded (exporter.js: 12 MB).
    public var maxBytes: Int

    public init(noteDirectory: URL?, allowedRoot: URL? = nil, maxBytes: Int = 12 * 1024 * 1024) {
        self.noteDirectory = noteDirectory
        self.allowedRoot = allowedRoot
        self.maxBytes = maxBytes
    }

    private static let imgSrc = Rx("(<img\\b[^>]*?\\bsrc\\s*=\\s*)(?:\"([^\"]*)\"|'([^']*)')", [.caseInsensitive])

    static let mimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "bmp": "image/bmp", "avif": "image/avif",
    ]

    public func embed(in html: String) -> String {
        guard html.contains("<img") || html.contains("<IMG") else { return html }
        return ImageEmbedder.imgSrc.replace(html) { match, ns in
            let whole = ns.substring(with: match.range)
            let raw = match.group(2, in: ns) ?? match.group(3, in: ns) ?? ""
            guard let replacement = self.resolve(decodeHTMLEntities(raw)) else { return whole }
            let prefix = match.group(1, in: ns) ?? ""
            return prefix + "\"" + escapeHTML(replacement) + "\""
        }
    }

    /// The replacement for `src`, or nil to leave it as it is.
    public func resolve(_ src: String) -> String? {
        let trimmed = src.jsTrimmed
        if trimmed.isEmpty { return nil }
        if Rx("^(?:https?:|data:|//|mailto:)", [.caseInsensitive]).test(trimmed) { return nil }
        let file: URL
        if trimmed.lowercased().hasPrefix("file:") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            file = url
        } else {
            let path = trimmed.removingPercentEncoding ?? trimmed
            let cleaned = Rx("[?#].*$").replace(path, template: "")
            if cleaned.hasPrefix("/") {
                file = URL(fileURLWithPath: cleaned)
            } else {
                guard let base = noteDirectory else { return nil }
                file = base.appendingPathComponent(cleaned)
            }
        }
        guard let root = allowedRoot ?? noteDirectory else { return nil }
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        guard FileOps.isWithinResolved(root, real) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let size = (try? real.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxBytes { return real.absoluteString }
        guard let data = try? Data(contentsOf: real) else { return nil }
        let mime = ImageEmbedder.mimeTypes[real.pathExtension.lowercased()] ?? "application/octet-stream"
        return "data:" + mime + ";base64," + data.base64EncodedString()
    }
}
