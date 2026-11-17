import AppKit
import FrisketServices
import UniformTypeIdentifiers

/// Import from Evernote, Notion or Apple Notes with a progress sheet and a summary.
@MainActor
enum ImportFlow {
    static func run(kind: ImportKind, library: LibraryController, parent: NSWindow, done: @escaping (URL?) -> Void) {
        switch kind {
        case .evernote:
            let panel = NSOpenPanel()
            panel.title = "Import from Evernote"
            panel.message = "Choose one or more Evernote export files (.enex)."
            panel.prompt = "Import"
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            if let type = UTType(filenameExtension: "enex") { panel.allowedContentTypes = [type] }
            panel.beginSheetModal(for: UI.topmost(parent)) { response in
                guard response == .OK, !panel.urls.isEmpty else { done(nil); return }
                start(kind: kind, source: .files(panel.urls), library: library, parent: parent, done: done)
            }
        case .notion:
            let panel = NSOpenPanel()
            panel.title = "Import from Notion"
            panel.message = "Choose the .zip Notion exported (Markdown & CSV), or the folder you extracted it to."
            panel.prompt = "Import"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.zip, .folder]
            panel.beginSheetModal(for: UI.topmost(parent)) { response in
                guard response == .OK, let url = panel.url else { done(nil); return }
                start(kind: kind, source: .folderOrZip(url), library: library, parent: parent, done: done)
            }
        case .appleNotes:
            UI.alert("Import from Apple Notes?",
                     "Frisket asks the Notes app for your notes. macOS will ask whether Frisket may control Notes; choose OK to allow it. Large collections can take several minutes. Your notes in Apple Notes are not changed.",
                     parent: parent, buttons: ["Import", "Cancel"]) { choice in
                if choice == 0 { start(kind: kind, source: .none, library: library, parent: parent, done: done) } else { done(nil) }
            }
        }
    }

    private static func start(kind: ImportKind, source: ImportSource, library: LibraryController, parent: NSWindow, done: @escaping (URL?) -> Void) {
        let progress = ProgressSheet(message: "Importing from \(kind.label)\u{2026}")
        let root = library.root
        Task { @MainActor in
            await Task.yield()
            progress.present(on: parent)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImportReport, Error> in
                do { return .success(try await runImport(kind: kind, source: source, root: root)) } catch { return .failure(error) }
            }.value
            progress.dismiss()
            library.refresh()
            await Task.yield()
            switch result {
            case .failure(let error):
                UI.alert("Import failed", error.localizedDescription, style: .warning, parent: parent) { _ in done(nil) }
            case .success(let report):
                var lines = ["Imported \(report.notes) note\(report.notes == 1 ? "" : "s") and \(report.attachments) attachment\(report.attachments == 1 ? "" : "s")."]
                if let folder = report.folder { lines.append("They are in \u{201C}\((folder as NSString).lastPathComponent)\u{201D} in your library.") }
                if !report.skipped.isEmpty {
                    lines.append("")
                    lines.append("\(report.skipped.count) skipped:")
                    for item in report.skipped.prefix(5) { lines.append("\u{2022} \(item.title) \u{2014} \(item.reason)") }
                    if report.skipped.count > 5 { lines.append("\u{2026}and \(report.skipped.count - 5) more.") }
                }
                let target = report.notes > 0 ? report.folder.map { URL(fileURLWithPath: $0) } : nil
                UI.alert(report.notes > 0 ? "Import complete" : "Nothing was imported", lines.joined(separator: "\n"),
                         parent: parent) { _ in done(target) }
            }
        }
    }
}

/// A small sheet with an indeterminate spinner and no buttons.
@MainActor
final class ProgressSheet: PanelController {
    private let spinner = NSProgressIndicator()

    init(message: String) {
        super.init(title: "", size: NSSize(width: 360, height: 100), resizable: false)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, UI.label(message)])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
}
