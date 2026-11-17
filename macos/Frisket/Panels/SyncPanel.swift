import AppKit
import FrisketLibrary
import FrisketServices

/// Sync & Devices: how the library syncs, folders it can be copied into, and conflict notes.
@MainActor
final class SyncPanel: PanelController {
    private let library: LibraryController?
    private let content = NSStackView()
    private var status: SyncStatus?
    private var loaded = false
    private var copying = false
    private var observer: NSObjectProtocol?

    /// Opens the note a resolved conflict leaves behind.
    private var onOpen: ((URL) -> Void)?

    static func show(library: LibraryController?, parent: NSWindow, open: ((URL) -> Void)? = nil) {
        let panel = SyncPanel(library: library)
        panel.onOpen = open
        panel.present(on: parent)
        panel.load()
    }

    private init(library: LibraryController?) {
        self.library = library
        super.init(title: "Sync & Devices", size: NSSize(width: 660, height: 640), minSize: NSSize(width: 560, height: 420))
        onClose = { [weak self] in
            if let observer = self?.observer { NotificationCenter.default.removeObserver(observer) }
        }
        buildUI()
        observer = NotificationCenter.default.addObserver(forName: .frisketLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.loaded == true, self?.copying == false { self?.rebuild() } }
        }
    }

    private func buildUI() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
        ])
        content.addArrangedSubview(UI.label("Checking sync status…", color: .secondaryLabelColor))
        let done = UI.button("Done", key: "\u{1b}") { [weak self] in self?.dismiss() }
        done.keyEquivalent = "\r"
        install(UI.vstack([scroll, UI.buttonRow([done])], spacing: 12, alignment: .width))
    }

    func load() {
        let root = library?.root
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) { SyncProviders.syncStatus(folder: root) }.value
            guard let self else { return }
            self.status = status
            self.loaded = true
            self.rebuild()
        }
    }

    private func clear() {
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func rebuild() {
        guard let status else { return }
        clear()
        content.addArrangedSubview(UI.heading("Sync & Devices"))
        content.addArrangedSubview(UI.secondary("Frisket does not run its own cloud. A library is an ordinary folder of Markdown files: keep it inside a folder that OneDrive, Dropbox, iCloud Drive, Google Drive or Syncthing syncs, and every device that opens that folder sees the same notes."))

        let provider = status.provider
        let available = status.available.filter { provider == nil || $0.path != provider!.root }

        // Status card.
        let card: NSStackView
        if let library {
            if let provider {
                card = UI.vstack([
                    UI.heading("This library syncs with \(provider.label)"),
                    UI.secondary(library.root.path, wraps: false),
                    UI.label("Notes upload whenever \(provider.label) is running on this Mac, and changes from your other devices appear here a few seconds after they arrive. There is nothing to switch on in Frisket.", font: .systemFont(ofSize: 12), wraps: true),
                ], spacing: 4, alignment: .width)
            } else {
                card = UI.vstack([
                    UI.heading("This library is only on this Mac"),
                    UI.secondary(library.root.path, wraps: false),
                    UI.label("To use it on other devices, keep it inside a folder that a sync app syncs. You can copy it into one below.", font: .systemFont(ofSize: 12), wraps: true),
                ], spacing: 4, alignment: .width)
            }
        } else {
            card = UI.vstack([
                UI.heading("No library is open"),
                UI.label("Open a folder of notes first; then this window shows whether it syncs.", font: .systemFont(ofSize: 12), wraps: true),
            ], spacing: 4, alignment: .width)
        }
        content.addArrangedSubview(boxed(card))

        // Folders.
        if library != nil, provider == nil {
            content.addArrangedSubview(UI.heading("Set up sync"))
            if available.isEmpty {
                content.addArrangedSubview(UI.label("No sync app was found on this Mac. Install OneDrive, Dropbox, iCloud Drive, Google Drive or Syncthing, sign in, then open this window again.", font: .systemFont(ofSize: 12), wraps: true))
            } else {
                for folder in available { content.addArrangedSubview(folderRow(folder, canMove: true)) }
                var size = ""
                if let found = status.size {
                    size = " (\(found.files.formatted()) file\(found.files == 1 ? "" : "s"), \(UI.formatBytes(found.bytes))\(found.truncated ? "+" : ""))"
                }
                content.addArrangedSubview(UI.secondary("Moving copies the library\(size) into the chosen folder and opens the copy. It never deletes anything: the original folder stays where it is, so delete it yourself once you have checked the copy. On a second device, use File \u{203A} Open Library\u{2026} once the library has synced to it."))
            }
        } else if library == nil, !available.isEmpty {
            content.addArrangedSubview(UI.heading("Synced folders on this Mac"))
            for folder in available { content.addArrangedSubview(folderRow(folder, canMove: false)) }
        }

        // Conflicts.
        if let library {
            let conflicts = (library.snapshot?.summaries ?? []).filter { $0.conflict != nil && !$0.isTrashed }
            content.addArrangedSubview(UI.heading("Sync conflicts"))
            if conflicts.isEmpty {
                content.addArrangedSubview(UI.secondary("No sync conflicts. If two devices change the same note before syncing, Frisket keeps both versions and lists them here."))
            } else {
                content.addArrangedSubview(UI.secondary("\(conflicts.count) note\(conflicts.count == 1 ? " was" : "s were") changed on two devices before they synced. Both versions are kept."))
                let table = ListTable(rowHeight: 40)
                table.rows = conflicts.map { note in
                    ListTable.Row(title: note.title, detail: note.relative, action: (title: "Resolve\u{2026}", handler: { [weak self] in
                        guard let self else { return }
                        Panels.resolveConflict(note: note, library: library, parent: self.window) { [weak self] url in
                            self?.rebuild()
                            if let url { self?.onOpen?(url) }
                        }
                    }))
                }
                table.scrollView.translatesAutoresizingMaskIntoConstraints = false
                table.scrollView.heightAnchor.constraint(equalToConstant: CGFloat(min(conflicts.count, 4)) * 40 + 4).isActive = true
                content.addArrangedSubview(table.scrollView)
                retainedTables = [table]
            }
        }

        // How it works.
        content.addArrangedSubview(UI.heading("How sync works"))
        let bullets = [
            ("Windows or Mac:", "install Frisket and the same sync app, then open this library inside the synced folder."),
            ("iPhone and iPad:", "keep the library in iCloud Drive, and open its notes with any Markdown app from the Files app."),
            ("Anything else:", "notes are plain Markdown files, so any Markdown editor can read and edit them."),
            ("Keep it offline:", "let the sync app keep the library on this device so Frisket can read every note."),
            ("History travels:", "version history is stored in the library\u{2019}s .frisket folder, so earlier versions are on every device."),
        ]
        for (strong, text) in bullets {
            let line = UI.label("\u{2022} \(strong) \(text)", font: .systemFont(ofSize: 12), wraps: true)
            content.addArrangedSubview(line)
        }
    }

    private var retainedTables: [ListTable] = []

    private func boxed(_ inner: NSView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 10, height: 8)
        box.contentView = inner
        return box
    }

    private func folderRow(_ folder: SyncFolder, canMove: Bool) -> NSView {
        let text = UI.vstack([UI.label(folder.label, font: .systemFont(ofSize: 13, weight: .medium)),
                              UI.label(folder.path.path, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)], spacing: 1)
        var views: [NSView] = [text, UI.spacer()]
        if canMove {
            let move = UI.button("Move Library Here\u{2026}") { [weak self] in self?.confirmMove(to: folder) }
            views.append(move)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    private func confirmMove(to folder: SyncFolder) {
        guard let library, !copying else { return }
        let name = library.name
        UI.alert("Copy library into \(folder.label)?",
                 "Frisket copies \u{201C}\(name)\u{201D} into \(folder.path.path) and opens the copy. Your original folder is not changed or removed.",
                 parent: window, buttons: ["Copy and Open", "Cancel"]) { [weak self] choice in
            guard choice == 0 else { return }
            self?.copyLibrary(from: library.root, to: folder)
        }
    }

    private func copyLibrary(from source: URL, to folder: SyncFolder) {
        copying = true
        clear()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, UI.label("Copying the library into \(folder.label)\u{2026}")])
        row.orientation = .horizontal
        row.spacing = 8
        content.addArrangedSubview(row)
        let destination = folder.path
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result { try SyncProviders.copyLibrary(source, to: destination) }
            }.value
            guard let self else { return }
            self.copying = false
            switch result {
            case .success(let copy):
                LibraryController.open(copy)
                self.dismiss()
            case .failure(let error):
                self.rebuild()
                UI.alert("Could not copy the library", error.localizedDescription, style: .warning, parent: self.window)
            }
        }
    }
}

/// A top-left-origin container, so scrolled content starts at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
