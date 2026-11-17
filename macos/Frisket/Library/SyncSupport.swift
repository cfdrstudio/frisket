import Foundation
import FrisketServices

/// Small helpers over FrisketServices for views that only need a label.
enum SyncProvidersBridge {
    /// "iCloud Drive", "Dropbox", … when `folder` is inside a known sync folder.
    static func providerLabel(for folder: URL) -> String? {
        SyncProviders.providerFor(folder, known: SyncProviders.detectSyncFolders())?.label
    }
}
