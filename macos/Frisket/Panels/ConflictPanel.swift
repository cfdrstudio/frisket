import AppKit
import FrisketBase
import FrisketLibrary
import FrisketServices

/// Shows a sync-conflict copy against its original and lets the user pick which to keep.
@MainActor
final class ConflictPanel: PanelController {
    private let note: NoteSummary
    private let library: LibraryController
    private let done: (URL?) -> Void
    private var finished = false
    private let summary = UI.label("Loading…", color: .secondaryLabelColor)
    private let diffScroll: NSScrollView
    private let diffView: NSTextView
    private var actionButtons: [NSButton] = []
    private let spinner = NSProgressIndicator()

    private static let kindNames: [ConflictKind: String] = [
        .conflictedCopy: "a conflicted copy made by Dropbox or Nextcloud",
        .syncthing: "a Syncthing conflict copy",
        .onedrive: "a copy OneDrive made on another device",
        .duplicateID: "a second note with the same Frisket ID (iCloud or a manual copy)",
    ]

    static func show(note: NoteSummary, library: LibraryController, parent: NSWindow, done: @escaping (URL?) -> Void) {
        guard note.conflict != nil else {
            UI.alert("That note is no longer a conflict copy.", parent: parent)
            done(nil)
            return
        }
        let panel = ConflictPanel(note: note, library: library, done: done)
        panel.present(on: parent)
        panel.load()
    }

    private init(note: NoteSummary, library: LibraryController, done: @escaping (URL?) -> Void) {
        self.note = note
        self.library = library
        self.done = done
        (diffScroll, diffView) = UI.textScroll(mono: true)
        super.init(title: "Resolve Sync Conflict", size: NSSize(width: 760, height: 560), minSize: NSSize(width: 600, height: 400))
        onClose = { [weak self] in self?.finishIfNeeded(nil) }
        buildUI()
    }

    private var hasOriginal: Bool { note.conflict?.originalPath != nil }

    private func buildUI() {
        let conflict = note.conflict!
        let copyName = note.url.lastPathComponent
        var sub = "\u{201C}\(copyName)\u{201D} is " + (Self.kindNames[conflict.kind] ?? "a conflict copy")
        if let original = conflict.originalPath {
            sub += " of \u{201C}\((original as NSString).lastPathComponent)\u{201D}. Lines marked + are only in the copy; \u{2212} only in the original."
        } else {
            sub += ". The original is missing."
        }
        let title = UI.label("Resolve Sync Conflict", font: .systemFont(ofSize: 15, weight: .semibold))
        let subLabel = UI.secondary(sub)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let cancel = UI.button("Cancel", key: "\u{1b}") { [weak self] in self?.dismissWith(nil) }
        let openCopy = UI.button("Open Copy") { [weak self] in
            guard let self else { return }
            self.dismissWith(self.note.url)
        }
        var buttons: [NSButton] = [cancel, openCopy]
        if hasOriginal {
            let keepOriginal = UI.button("Keep Original") { [weak self] in self?.resolve(.keepOriginal) }
            keepOriginal.toolTip = "Moves the copy to Trash."
            let keepCopy = UI.button("Keep This Copy") { [weak self] in self?.resolve(.keepCopy) }
            keepCopy.toolTip = "Replaces the original; its text is kept in version history."
            actionButtons += [keepOriginal, keepCopy]
            buttons += [keepOriginal, keepCopy]
        }
        let keepBoth = UI.button("Keep Both", primary: !hasOriginal) { [weak self] in self?.resolve(.keepBoth) }
        keepBoth.toolTip = "Makes the copy an ordinary note."
        actionButtons.append(keepBoth)
        buttons.append(keepBoth)
        actionButtons.forEach { $0.isEnabled = false }

        diffScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let root = UI.vstack([title, subLabel, summary, diffScroll, UI.buttonRow(buttons, leading: [spinner])], spacing: 10, alignment: .width)
        install(root)
    }

    func load() {
        let copyURL = note.url
        let originalPath = note.conflict?.originalPath
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<([DiffRow]?, Int, Int), Error> in
                Result {
                    let copy = try FileOps.readText(copyURL)
                    guard let originalPath else { return (nil, 0, 0) }
                    let original = try FileOps.readText(URL(fileURLWithPath: originalPath))
                    let ops = LineDiff.diff(original, copy)
                    let stats = LineDiff.stats(ops)
                    return (LineDiff.withContext(ops), stats.added, stats.removed)
                }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.summary.stringValue = "Could not read the notes: " + error.localizedDescription
            case .success(let (text, added, removed)):
                if let text {
                    self.summary.stringValue = "The copy adds \(added) and removes \(removed) line\(removed == 1 ? "" : "s")."
                    self.diffView.textStorage?.setAttributedString(UI.diffText(text))
                } else {
                    self.summary.stringValue = "There is nothing to compare it with."
                }
                self.actionButtons.forEach { $0.isEnabled = true }
            }
        }
    }

    private func resolve(_ action: ConflictResolution) {
        actionButtons.forEach { $0.isEnabled = false }
        spinner.startAnimation(nil)
        let copyURL = note.url
        Task { [weak self, library] in
            do {
                let url = try await library.perform { try await $0.resolveConflict(copyURL, action: action) }
                self?.spinner.stopAnimation(nil)
                self?.dismissWith(url)
            } catch {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                self.actionButtons.forEach { $0.isEnabled = true }
                UI.alert("Could not resolve the conflict", error.localizedDescription, style: .warning, parent: self.window)
            }
        }
    }

    private func dismissWith(_ url: URL?) {
        finishIfNeeded(url)
        dismiss()
    }

    private func finishIfNeeded(_ url: URL?) {
        guard !finished else { return }
        finished = true
        done(url)
    }
}
