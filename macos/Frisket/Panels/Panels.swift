import AppKit
import FrisketLibrary
import FrisketServices

/// Entry points for the app's secondary windows and sheets. Each one lives in its own file.
@MainActor
enum Panels {
    static func showQuickCapture(library: LibraryController, parent: NSWindow?) {
        QuickCapturePanel.show(library: library, parent: parent)
    }

    static func showVersionHistory(for url: URL, currentText: String, libraryRoot: URL?, parent: NSWindow, restore: @escaping (String) -> Void) {
        VersionHistoryPanel.show(for: url, currentText: currentText, libraryRoot: libraryRoot, parent: parent, restore: restore)
    }

    static func showPreferences() { PreferencesWindow.show() }

    static func showSync(library: LibraryController?, parent: NSWindow, open: ((URL) -> Void)? = nil) {
        SyncPanel.show(library: library, parent: parent, open: open)
    }

    static func showStyleCheck(textView: MarkdownTextView, parent: NSWindow) {
        StyleCheckPanel.show(textView: textView, parent: parent)
    }

    static func chooseTemplate(library: LibraryController, parent: NSWindow, completion: @escaping (NoteTemplate?) -> Void) {
        TemplateChooserPanel.show(library: library, parent: parent, completion: completion)
    }

    static func saveSnippet(text: String, library: LibraryController, parent: NSWindow) {
        SnippetSaver.save(text: text, library: library, parent: parent)
    }

    static func showAttachmentAudit(library: LibraryController, parent: NSWindow, open: @escaping (URL) -> Void) {
        AttachmentAuditPanel.show(library: library, parent: parent, open: open)
    }

    static func resolveConflict(note: NoteSummary, library: LibraryController, parent: NSWindow, done: @escaping (URL?) -> Void) {
        ConflictPanel.show(note: note, library: library, parent: parent, done: done)
    }

    static func runImport(kind: ImportKind, library: LibraryController, parent: NSWindow, done: @escaping (URL?) -> Void) {
        ImportFlow.run(kind: kind, library: library, parent: parent, done: done)
    }

    static func showMarkdownReference() { HelpWindows.showReference() }
    static func showShortcuts() { HelpWindows.showShortcuts() }
}
