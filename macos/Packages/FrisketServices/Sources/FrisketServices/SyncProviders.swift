import Foundation
import FrisketBase

/// A sync app Frisket recognises.
public enum SyncProvider: String, Sendable, CaseIterable {
    case onedrive
    case dropbox
    case icloud
    case googleDrive = "google-drive"
    case nextcloud
    case syncthing
    case box

    public var label: String {
        switch self {
        case .onedrive: return "OneDrive"
        case .dropbox: return "Dropbox"
        case .icloud: return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .nextcloud: return "Nextcloud"
        case .syncthing: return "Syncthing"
        case .box: return "Box"
        }
    }
}

/// A synced folder found on this Mac.
public struct SyncFolder: Sendable, Equatable {
    public var provider: SyncProvider
    public var label: String
    public var path: URL
    public init(provider: SyncProvider, label: String, path: URL) {
        self.provider = provider
        self.label = label
        self.path = path
    }
}

/// The sync app a folder belongs to, and the root of its synced tree.
public struct SyncProviderInfo: Sendable, Equatable {
    public var provider: SyncProvider
    public var label: String
    public var root: URL
}

/// Files and bytes under a folder; `truncated` when counting stopped at the limit.
public struct FolderSize: Sendable, Equatable {
    public var files: Int
    public var bytes: Int
    public var truncated: Bool
}

/// How a library syncs. `size` is given only for an unsynced library, for the "copy it" prompt.
public struct SyncStatus: Sendable, Equatable {
    public var folder: URL?
    public var provider: SyncProviderInfo?
    public var available: [SyncFolder]
    public var size: FolderSize?
}

public struct SyncError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Frisket has no sync service of its own. A library syncs because it lives
/// inside a folder that a sync app already syncs: iCloud Drive, Dropbox,
/// OneDrive, Google Drive, Nextcloud, Syncthing or Box. This finds those
/// folders on this Mac, says which one (if any) a library is in, and can copy a
/// library into one. Port of syncProviders.js (macOS locations only).
public enum SyncProviders {
    public static let sizeLimit = 20000

    /// The user's real home folder; pass another to `home:` in tests.
    public static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        func norm(_ url: URL) -> String {
            var path = url.standardizedFileURL.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path.lowercased()
        }
        return norm(a) == norm(b)
    }

    /// Synced folders on this Mac: iCloud Drive, File Provider folders in
    /// `~/Library/CloudStorage` (OneDrive, Dropbox, Google Drive, Box, Nextcloud),
    /// Dropbox's own `info.json`, legacy `~/Dropbox`-style folders and Syncthing's `~/Sync`.
    public static func detectSyncFolders(home: URL = defaultHome) -> [SyncFolder] {
        var found: [SyncFolder] = []
        func add(_ provider: SyncProvider, _ folder: URL, label: String? = nil) {
            guard isDirectory(folder) else { return }
            let resolved = folder.standardizedFileURL
            if found.contains(where: { samePath($0.path, resolved) }) { return }
            found.append(SyncFolder(provider: provider, label: label ?? provider.label, path: resolved))
        }

        add(.icloud, home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true))
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? [])
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for name in entries {
            let full = storage.appendingPathComponent(name, isDirectory: true)
            if Rx("^OneDrive", [.caseInsensitive]).test(name) {
                var account = Rx("^OneDrive-?", [.caseInsensitive]).replace(name, template: "")
                account = Rx("^Personal\\z", [.caseInsensitive]).replace(account, template: "")
                add(.onedrive, full, label: account.isEmpty ? "OneDrive" : "OneDrive – " + account)
            } else if Rx("^Dropbox", [.caseInsensitive]).test(name) {
                add(.dropbox, full)
            } else if Rx("^GoogleDrive", [.caseInsensitive]).test(name) {
                let myDrive = full.appendingPathComponent("My Drive", isDirectory: true)
                add(.googleDrive, isDirectory(myDrive) ? myDrive : full)
            } else if Rx("^Box", [.caseInsensitive]).test(name) {
                add(.box, full)
            } else if Rx("^Nextcloud", [.caseInsensitive]).test(name) {
                add(.nextcloud, full)
            }
        }
        // Dropbox records where it syncs in ~/.dropbox/info.json.
        if let data = try? Data(contentsOf: home.appendingPathComponent(".dropbox/info.json")),
           let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let personal = (info["personal"] as? [String: Any])?["path"] as? String {
                add(.dropbox, URL(fileURLWithPath: personal, isDirectory: true))
            }
            if let business = (info["business"] as? [String: Any])?["path"] as? String {
                add(.dropbox, URL(fileURLWithPath: business, isDirectory: true), label: "Dropbox (work)")
            }
        }
        add(.dropbox, home.appendingPathComponent("Dropbox", isDirectory: true))
        add(.nextcloud, home.appendingPathComponent("Nextcloud", isDirectory: true))
        add(.onedrive, home.appendingPathComponent("OneDrive", isDirectory: true))
        add(.googleDrive, home.appendingPathComponent("Google Drive", isDirectory: true))
        add(.box, home.appendingPathComponent("Box", isDirectory: true))
        // Syncthing's default folder counts once Syncthing has marked it.
        if FileManager.default.fileExists(atPath: home.appendingPathComponent("Sync/.stfolder").path) {
            add(.syncthing, home.appendingPathComponent("Sync", isDirectory: true))
        }
        return found
    }

    private static func hasNextcloudMarker(_ directory: String) -> Bool {
        // Foundation hides `._*` (AppleDouble) names, which are exactly what Nextcloud's journal is called.
        guard let handle = opendir(directory) else { return false }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            names.append(withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            })
        }
        let journal = Rx("^\\._?sync_[0-9a-f]+\\.db\\z", [.caseInsensitive])
        let log = Rx("^\\.(?:owncloud|nextcloud)sync\\.log\\z", [.caseInsensitive])
        return names.contains { journal.test($0) || log.test($0) }
    }

    /// The sync app a folder belongs to, or nil. Known sync folders are checked
    /// first, then markers and well-known names in the folder's parents
    /// (Syncthing's `.stfolder`, Dropbox's `.dropbox`, Nextcloud's journal,
    /// "OneDrive…", "iCloudDrive", "My Drive").
    public static func providerFor(_ folder: URL, known: [SyncFolder] = []) -> SyncProviderInfo? {
        let resolved = folder.standardizedFileURL
        let hit = known.filter { FileOps.isWithin($0.path, resolved) }.sorted { $0.path.path.count > $1.path.path.count }.first
        if let hit { return SyncProviderInfo(provider: hit.provider, label: hit.label, root: hit.path) }
        func named(_ provider: SyncProvider, _ dir: String) -> SyncProviderInfo {
            SyncProviderInfo(provider: provider, label: provider.label, root: URL(fileURLWithPath: dir, isDirectory: true))
        }
        var dir = resolved.path
        let onedriveName = Rx("^OneDrive(?:\\s*-\\s*.+|-.+)?\\z", [.caseInsensitive])
        for _ in 0..<40 {
            let name = (dir as NSString).lastPathComponent
            let fm = FileManager.default
            if fm.fileExists(atPath: dir + "/.stfolder") { return named(.syncthing, dir) }
            if fm.fileExists(atPath: dir + "/.dropbox") { return named(.dropbox, dir) }
            if hasNextcloudMarker(dir) { return named(.nextcloud, dir) }
            if onedriveName.test(name) { return named(.onedrive, dir) }
            if name == "iCloudDrive" || name == "com~apple~CloudDocs" { return named(.icloud, dir) }
            if name == "My Drive" { return named(.googleDrive, dir) }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    /// Number of files and bytes under a folder, stopping after `sizeLimit` files.
    public static func folderSize(_ folder: URL) -> FolderSize {
        var files = 0
        var bytes = 0
        var truncated = false
        func walk(_ directory: URL) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                if files >= sizeLimit { truncated = true; return }
                if name == "node_modules" || name == ".git" { continue }
                let url = directory.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]),
                      values.isSymbolicLink != true else { continue }
                if values.isDirectory == true { walk(url) }
                else if values.isRegularFile == true { files += 1; bytes += values.fileSize ?? 0 }
            }
        }
        walk(folder)
        return FolderSize(files: files, bytes: bytes, truncated: truncated)
    }

    /// How a library syncs, plus the synced folders available to copy it into.
    public static func syncStatus(folder: URL?, home: URL = defaultHome) -> SyncStatus {
        let available = detectSyncFolders(home: home)
        guard let folder else { return SyncStatus(folder: nil, provider: nil, available: available, size: nil) }
        let provider = providerFor(folder, known: available)
        return SyncStatus(folder: folder, provider: provider, available: available, size: provider == nil ? folderSize(folder) : nil)
    }

    /// Copy a library folder into `destinationRoot` as a new folder of the same
    /// name (numbered if taken), leaving out `.git` and `node_modules`. Nothing is
    /// moved or deleted. Returns the copy's location.
    public static func copyLibrary(_ folder: URL, to destinationRoot: URL) throws -> URL {
        let source = folder.resolvingSymlinksInPath().standardizedFileURL
        let root = destinationRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(source) else { throw SyncError("The library folder is missing.") }
        guard isDirectory(root) else { throw SyncError("The sync folder is missing.") }
        if FileOps.isWithin(source, root) { throw SyncError("That sync folder is inside the library. Choose another one.") }
        if FileOps.isWithin(root, source) { throw SyncError("This library is already inside that folder.") }
        let target = try FileOps.uniqueURL(in: root, stem: FileOps.safeName(source.lastPathComponent, fallback: "Frisket Library"), ext: "")
        let fm = FileManager.default
        func copy(_ from: URL, _ to: URL) throws {
            let values = try from.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                try fm.createSymbolicLink(atPath: to.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: from.path))
            } else if values.isDirectory == true {
                try fm.createDirectory(at: to, withIntermediateDirectories: false)
                for name in try fm.contentsOfDirectory(atPath: from.path) where name != ".git" && name != "node_modules" {
                    try copy(from.appendingPathComponent(name), to.appendingPathComponent(name))
                }
            } else {
                try fm.copyItem(at: from, to: to)
            }
        }
        try copy(source, target)
        return target
    }
}
