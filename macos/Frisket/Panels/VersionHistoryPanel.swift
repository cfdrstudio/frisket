import AppKit
import FrisketBase
import FrisketLibrary
import FrisketServices

/// Version history: stored snapshots on the left, a line diff to the current text on the right.
@MainActor
final class VersionHistoryPanel: PanelController {
    private let url: URL
    private let currentText: String
    private let libraryRoot: URL?
    private let fallbackRoot: URL
    private let restore: (String) -> Void

    private let list = ListTable(rowHeight: 40)
    private let summary = UI.label("Choose a version.", color: .secondaryLabelColor)
    private let diffScroll: NSScrollView
    private let diffView: NSTextView
    private let restoreButton: NSButton
    private let splitContainer = NSView()
    private let emptyLabel = UI.label("Loading versions…", color: .secondaryLabelColor, wraps: true)
    private var versions: [HistoryVersion] = []
    private var selectedText: String?
    private var generation = 0

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func show(for url: URL, currentText: String, libraryRoot: URL?, parent: NSWindow, restore: @escaping (String) -> Void) {
        let panel = VersionHistoryPanel(url: url, currentText: currentText, libraryRoot: libraryRoot, restore: restore)
        panel.present(on: parent)
        panel.load()
    }

    private init(url: URL, currentText: String, libraryRoot: URL?, restore: @escaping (String) -> Void) {
        self.url = url
        self.currentText = currentText
        self.libraryRoot = libraryRoot
        self.fallbackRoot = EditorViewController.historyFallbackRoot
        self.restore = restore
        (diffScroll, diffView) = UI.textScroll(mono: true)
        restoreButton = NSButton(title: "Restore This Version", target: nil, action: nil)
        super.init(title: "Version History", size: NSSize(width: 800, height: 560), minSize: NSSize(width: 640, height: 420))
        buildUI()
    }

    private func buildUI() {
        restoreButton.bezelStyle = .rounded
        restoreButton.isEnabled = false
        UI.onAction(restoreButton) { [weak self] _ in
            guard let self, let text = self.selectedText else { return }
            self.dismiss()
            self.restore(text)
        }
        let close = UI.button("Close", key: "\u{1b}") { [weak self] in self?.dismiss() }

        let title = UI.label("Version History", font: .systemFont(ofSize: 15, weight: .semibold))
        let sub = UI.secondary("\(url.lastPathComponent) \u{00B7} newest first. The diff shows what has changed since that version.")

        list.onSelect = { [weak self] index in
            if let index { self?.choose(index) }
        }
        list.scrollView.translatesAutoresizingMaskIntoConstraints = false
        list.scrollView.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let right = UI.vstack([summary, diffScroll], spacing: 8, alignment: .width)
        diffScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let split = NSStackView(views: [list.scrollView, right])
        split.orientation = .horizontal
        split.spacing = 12
        split.alignment = .top
        split.distribution = .fill
        split.translatesAutoresizingMaskIntoConstraints = false
        splitContainer.translatesAutoresizingMaskIntoConstraints = false
        splitContainer.addSubview(split)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        splitContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: splitContainer.topAnchor),
            split.bottomAnchor.constraint(equalTo: splitContainer.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: splitContainer.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: splitContainer.trailingAnchor),
            right.heightAnchor.constraint(equalTo: split.heightAnchor),
            list.scrollView.heightAnchor.constraint(equalTo: split.heightAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: splitContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: splitContainer.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: splitContainer.widthAnchor, constant: -40),
        ])
        split.isHidden = true
        splitContainer.identifier = NSUserInterfaceItemIdentifier("history-split")
        splitHolder = split

        let buttons = UI.buttonRow([close, restoreButton])
        let root = UI.vstack([title, sub, splitContainer, buttons], spacing: 10, alignment: .width)
        splitContainer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        install(root)
    }

    private var splitHolder: NSView?

    func load() {
        let url = self.url, text = currentText, root = libraryRoot, fallback = fallbackRoot
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[HistoryVersion], Error> in
                Result { try HistoryStore.list(file: url, text: text, libraryRoot: root, fallbackRoot: fallback) }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emptyLabel.stringValue = "Version history is not available: " + error.localizedDescription
            case .success(let found):
                self.versions = found.sorted { $0.time > $1.time }
                if self.versions.isEmpty {
                    self.emptyLabel.stringValue = "No earlier versions yet. Frisket keeps one as you edit and save."
                } else {
                    self.emptyLabel.isHidden = true
                    self.splitHolder?.isHidden = false
                    self.list.rows = self.versions.map {
                        ListTable.Row(title: Self.dateFormatter.string(from: $0.time), detail: UI.formatBytes($0.size))
                    }
                    self.list.select(0)
                }
            }
        }
    }

    private func choose(_ index: Int) {
        guard versions.indices.contains(index) else { return }
        generation += 1
        let token = generation
        selectedText = nil
        restoreButton.isEnabled = false
        summary.stringValue = "Loading…"
        diffView.string = ""
        let version = versions[index]
        let url = self.url, text = currentText, root = libraryRoot, fallback = fallbackRoot
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(String, [DiffRow], Int, Int), Error> in
                Result {
                    let old = try HistoryStore.read(file: url, text: text, id: version.id, libraryRoot: root, fallbackRoot: fallback)
                    let ops = LineDiff.diff(old, text)
                    let stats = LineDiff.stats(ops)
                    return (old, LineDiff.withContext(ops), stats.added, stats.removed)
                }
            }.value
            guard let self, token == self.generation else { return }
            switch result {
            case .failure(let error):
                self.summary.stringValue = error.localizedDescription
            case .success(let (old, rows, added, removed)):
                self.selectedText = old
                if added == 0 && removed == 0 {
                    self.summary.stringValue = "This version matches the note as it is now."
                } else {
                    self.summary.stringValue = "Since this version: +\(added) and \u{2212}\(removed) line\(added + removed == 1 ? "" : "s"). Restoring undoes these changes."
                }
                self.diffView.textStorage?.setAttributedString(UI.diffText(rows))
                self.diffView.scrollToBeginningOfDocument(nil)
                self.restoreButton.isEnabled = added != 0 || removed != 0
            }
        }
    }
}
