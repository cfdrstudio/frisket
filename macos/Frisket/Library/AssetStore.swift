import AppKit
import UniformTypeIdentifiers
import FrisketBase

/// Pasted, dropped and attached files are copied into an `assets` folder beside
/// the note, as in the Windows app, and linked with a relative path.
enum AssetStore {
    struct Stored {
        var url: URL
        var relative: String
        var markdown: String
    }

    enum AssetError: LocalizedError {
        case untitled, tooLarge, notAFile
        var errorDescription: String? {
            switch self {
            case .untitled: return "Save the note first, so the file has a folder to go in."
            case .tooLarge: return "Attachments are limited to 100 MB."
            case .notAFile: return "Only files can be attached."
            }
        }
    }

    static let maxBytes = 100 * 1024 * 1024
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic"]

    private static func assetsFolder(besideNote note: URL?) throws -> URL {
        guard let note else { throw AssetError.untitled }
        let folder = note.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Paths in Markdown use `/` and percent-encode spaces so links stay valid.
    private static func encode(_ relative: String) -> String {
        relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? relative
    }

    static func importFile(_ source: URL, besideNote note: URL?) throws -> Stored {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AssetError.notAFile }
        if (values.fileSize ?? 0) > maxBytes { throw AssetError.tooLarge }
        let folder = try assetsFolder(besideNote: note)
        let stem = source.deletingPathExtension().lastPathComponent
        var safe = Rx("[^A-Za-z0-9._-]+").replace(stem, template: "-")
        safe = Rx("^-+|-+$").replace(safe, template: "")
        if safe.isEmpty { safe = "attachment" }
        if safe.count > 80 { safe = String(safe.prefix(80)) }
        let ext = Rx("[^.a-z0-9]").replace(source.pathExtension.lowercased(), template: "")
        var target = folder.appendingPathComponent(safe + (ext.isEmpty ? "" : "." + ext))
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(safe + "-\(suffix)" + (ext.isEmpty ? "" : "." + ext))
            suffix += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        let relative = "assets/" + target.lastPathComponent
        let isImage = imageExtensions.contains(ext)
        let label = source.lastPathComponent
        let markdown = isImage ? "![](\(encode(relative)))" : "[\(label)](\(encode(relative)))"
        return Stored(url: target, relative: relative, markdown: markdown)
    }

    static func saveImage(_ data: Data, fileExtension: String, besideNote note: URL?) throws -> Stored {
        let folder = try assetsFolder(besideNote: note)
        let name = "image-\(Int(Date().timeIntervalSince1970 * 1000)).\(fileExtension)"
        let target = folder.appendingPathComponent(name)
        try data.write(to: target, options: .withoutOverwriting)
        let relative = "assets/" + name
        return Stored(url: target, relative: relative, markdown: "![](\(relative))")
    }
}
