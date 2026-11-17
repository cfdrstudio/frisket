import AppKit
import CoreServices
import FrisketBase
import FrisketLibrary

extension Notification.Name {
    /// The library index changed (object: the LibraryController).
    static let frisketLibraryChanged = Notification.Name("FrisketLibraryChanged")
    /// Files changed on disk (userInfo "paths": [String]); open editors check their file.
    static let frisketFilesChanged = Notification.Name("FrisketFilesChanged")
    /// A different library was opened (object: the new LibraryController or nil).
    static let frisketLibraryOpened = Notification.Name("FrisketLibraryOpened")
}

/// The open library: a `LibraryIndex` kept current by an FSEvents watcher.
/// There is one library at a time, shared by every window, as in the Windows app.
@MainActor
final class LibraryController {
    static private(set) var current: LibraryController?

    let index: LibraryIndex
    var root: URL { index.root }
    var name: String { root.lastPathComponent }
    private(set) var snapshot: LibrarySnapshot?
    private var stream: FSEventStreamRef?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var debounce: Timer?

    private init(root: URL) {
        index = LibraryIndex(root: root)
    }

    /// Open `root` as the library (or close it with nil) and remember the choice.
    static func open(_ root: URL?) {
        current?.stop()
        current = nil
        if let root {
            let controller = LibraryController(root: root)
            current = controller
            AppSettings.shared.libraryURL = root
            controller.startWatching()
            controller.refresh()
        } else {
            AppSettings.shared.libraryURL = nil
        }
        NotificationCenter.default.post(name: .frisketLibraryOpened, object: current)
    }

    func contains(_ url: URL) -> Bool {
        FileOps.isWithinResolved(root, url)
    }

    // MARK: Refresh

    /// Re-scan changed files and publish a new snapshot. Calls made while a refresh
    /// is running are folded into one more refresh afterwards.
    func refresh() {
        if refreshTask != nil { pendingRefresh = true; return }
        let index = self.index
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) { () -> LibrarySnapshot in
                await index.refresh()
                return await index.snapshot()
            }.value
            guard let self else { return }
            self.refreshTask = nil
            let changed = self.snapshot?.version != snapshot.version || self.snapshot == nil
            self.snapshot = snapshot
            if changed { NotificationCenter.default.post(name: .frisketLibraryChanged, object: self) }
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.refresh()
            }
        }
    }

    /// Run `work` against the index off the main thread, then refresh the snapshot.
    func perform<T: Sendable>(_ work: @escaping @Sendable (LibraryIndex) async throws -> T) async throws -> T {
        let index = self.index
        let result = try await Task.detached(priority: .userInitiated) { try await work(index) }.value
        refresh()
        return result
    }

    /// Like `perform`, without refreshing (queries).
    func query<T: Sendable>(_ work: @escaping @Sendable (LibraryIndex) async -> T) async -> T {
        let index = self.index
        return await Task.detached(priority: .userInitiated) { await work(index) }.value
    }

    // MARK: Watching

    private func startWatching() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var streamContext = FSEventStreamContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let controller = Unmanaged<LibraryController>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { controller.filesChanged(Array(array.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &streamContext, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        debounce?.invalidate()
    }

    private func filesChanged(_ paths: [String]) {
        let rootPath = root.path
        let relevant = paths.filter { path in
            guard path.hasPrefix(rootPath) else { return true }
            let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !LibraryIndex.isIgnoredChange(relativePath: relative)
        }
        NotificationCenter.default.post(name: .frisketFilesChanged, object: self, userInfo: ["paths": paths])
        guard !relevant.isEmpty else { return }
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
