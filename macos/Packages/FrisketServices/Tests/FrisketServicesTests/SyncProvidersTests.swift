import XCTest
@testable import FrisketServices

final class SyncProvidersTests: XCTestCase {
    private func under(_ home: URL, _ found: [SyncFolder]) -> [[String]] {
        found.filter { $0.path.path.hasPrefix(home.path) }
            .map { [$0.provider.rawValue, $0.label, String($0.path.path.dropFirst(home.path.count + 1))] }
    }

    func testFindsMacOSICloudDriveAndFileProviderFolders() throws {
        let home = try makeTempDirectory(self)
        _ = try dir(home, "Library", "Mobile Documents", "com~apple~CloudDocs")
        _ = try dir(home, "Library", "CloudStorage", "OneDrive-Personal")
        _ = try dir(home, "Library", "CloudStorage", "GoogleDrive-me@example.com", "My Drive")
        _ = try dir(home, "Library", "CloudStorage", "Dropbox")
        let found = SyncProviders.detectSyncFolders(home: home)
        XCTAssertEqual(found.map { [$0.provider.rawValue, $0.label] }, [
            ["icloud", "iCloud Drive"], ["dropbox", "Dropbox"], ["google-drive", "Google Drive"], ["onedrive", "OneDrive"],
        ])
        XCTAssertEqual(found[2].path.lastPathComponent, "My Drive")
    }

    func testFindsWorkAccountsDropboxSettingsAndUsualPlaces() throws {
        let home = try makeTempDirectory(self)
        _ = try dir(home, "Library", "CloudStorage", "OneDrive-Contoso")
        let dropboxHome = try dir(home, "Box Sync", "Dropbox Home")
        try write("{\"personal\": {\"path\": \"\(dropboxHome.path)\"}}", to: home.appendingPathComponent(".dropbox/info.json"))
        _ = try dir(home, "Sync", ".stfolder")
        _ = try dir(home, "Nextcloud")
        _ = try dir(home, "Google Drive")
        let found = SyncProviders.detectSyncFolders(home: home)
        XCTAssertEqual(under(home, found), [
            ["onedrive", "OneDrive – Contoso", "Library/CloudStorage/OneDrive-Contoso"],
            ["dropbox", "Dropbox", "Box Sync/Dropbox Home"],
            ["nextcloud", "Nextcloud", "Nextcloud"],
            ["google-drive", "Google Drive", "Google Drive"],
            ["syncthing", "Syncthing", "Sync"],
        ])
    }

    func testSyncthingFolderNeedsItsMarker() throws {
        let home = try makeTempDirectory(self)
        _ = try dir(home, "Sync")
        XCTAssertTrue(under(home, SyncProviders.detectSyncFolders(home: home)).isEmpty)
    }

    func testSaysWhichSyncAppALibraryIsInByFolderMarkerOrName() throws {
        let home = try makeTempDirectory(self)
        let oneDrive = try dir(home, "OneDrive")
        let known = [SyncFolder(provider: .onedrive, label: "OneDrive", path: oneDrive)]
        XCTAssertEqual(SyncProviders.providerFor(try dir(oneDrive, "Notes"), known: known),
                       SyncProviderInfo(provider: .onedrive, label: "OneDrive", root: oneDrive))

        let shared = try dir(home, "Shared")
        _ = try dir(shared, ".stfolder")
        XCTAssertEqual(SyncProviders.providerFor(try dir(shared, "deep", "Notes"))?.provider, .syncthing)
        try write("", to: try dir(home, "DB").appendingPathComponent(".dropbox"))
        XCTAssertEqual(SyncProviders.providerFor(try dir(home, "DB", "Notes"))?.provider, .dropbox)
        try write("", to: try dir(home, "NC").appendingPathComponent("._sync_0123abcd.db"))
        XCTAssertEqual(SyncProviders.providerFor(try dir(home, "NC", "Notes"))?.provider, .nextcloud)
        XCTAssertEqual(SyncProviders.providerFor(try dir(home, "OneDrive - Contoso", "Notes"))?.provider, .onedrive)
        XCTAssertEqual(SyncProviders.providerFor(try dir(home, "OneDrive - Contoso", "Notes"))?.root.lastPathComponent, "OneDrive - Contoso")
        XCTAssertEqual(SyncProviders.providerFor(try dir(home, "Mount", "My Drive", "Notes"))?.provider, .googleDrive)
        XCTAssertEqual(SyncProviders.providerFor(try dir(home, "Mobile", "com~apple~CloudDocs", "Notes"))?.provider, .icloud)
        XCTAssertNil(SyncProviders.providerFor(try dir(home, "Documents", "Notes")))
    }

    func testStatusReportsTheSizeOfAnUnsyncedLibraryForTheCopyPrompt() throws {
        let home = try makeTempDirectory(self)
        let library = try dir(home, "Documents", "Notes")
        try write("12345", to: library.appendingPathComponent("a.md"))
        try write("123", to: try dir(library, "Sub").appendingPathComponent("b.md"))
        try write("ignored", to: try dir(library, ".git").appendingPathComponent("HEAD"))
        let status = SyncProviders.syncStatus(folder: library, home: home)
        XCTAssertNil(status.provider)
        XCTAssertEqual(status.size, FolderSize(files: 2, bytes: 8, truncated: false))
        XCTAssertNil(SyncProviders.syncStatus(folder: nil, home: home).folder)

        let synced = try dir(home, "Library", "Mobile Documents", "com~apple~CloudDocs", "Notes")
        let syncedStatus = SyncProviders.syncStatus(folder: synced, home: home)
        XCTAssertEqual(syncedStatus.provider?.provider, .icloud)
        XCTAssertNil(syncedStatus.size)
    }

    func testCopyingALibraryCopiesEverythingButGitAndNeverOverwrites() throws {
        let home = try makeTempDirectory(self)
        let library = try dir(home, "Notes")
        try write("# A", to: library.appendingPathComponent("a.md"))
        try write("old", to: try dir(library, ".frisket", "history", "id-x").appendingPathComponent("v.md"))
        try write("ref", to: try dir(library, ".git").appendingPathComponent("HEAD"))
        let cloud = try dir(home, "OneDrive")
        _ = try dir(cloud, "Notes")

        let copy = try SyncProviders.copyLibrary(library, to: cloud)
        XCTAssertEqual(copy.path, cloud.appendingPathComponent("Notes 2").path)
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("a.md"), encoding: .utf8), "# A")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent(".frisket/history/id-x/v.md"), encoding: .utf8), "old")
        XCTAssertFalse(exists(copy.appendingPathComponent(".git")))
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("a.md"), encoding: .utf8), "# A", "the original stays")
        XCTAssertThrowsError(try SyncProviders.copyLibrary(library, to: try dir(library, "Inside"))) {
            XCTAssertTrue($0.localizedDescription.contains("inside the library"))
        }
        XCTAssertThrowsError(try SyncProviders.copyLibrary(copy, to: cloud)) {
            XCTAssertTrue($0.localizedDescription.contains("already inside"))
        }
    }
}
