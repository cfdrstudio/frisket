import AppKit
import FrisketBase
import FrisketMarkdown
import FrisketLibrary
import FrisketServices

/// One Frisket window: library sidebar, note list, editor and inspector.
/// Windows can be merged into native tabs; each tab edits one note.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static private(set) var all: [MainWindowController] = []

    let splitController = NSSplitViewController()
    let sidebar = SidebarViewController()
    let noteList = NoteListViewController()
    let editor = EditorViewController()
    let inspector = InspectorViewController()
    private var sidebarItem: NSSplitViewItem!
    private var listItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var observers: [NSObjectProtocol] = []
    private var back: [(URL, Int)] = []
    private var forward: [(URL, Int)] = []
    private var contextTask: Task<Void, Never>?
    private var outlineTimer: Timer?

    var library: LibraryController? { LibraryController.current }

    // MARK: Creation

    @discardableResult
    static func newWindow(tabbedWith existing: NSWindow? = nil) -> MainWindowController {
        let controller = MainWindowController()
        all.append(controller)
        if let existing {
            existing.addTabbedWindow(controller.window!, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// The frontmost Frisket window, if any.
    static var front: MainWindowController? {
        (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? all.last
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 420)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "FrisketNote"
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        buildSplit()
        window.contentViewController = splitController
        // Assigning the content view controller shrinks the window to fit it: restore or set a size after.
        if !window.setFrameUsingName("FrisketMainWindow") {
            window.setContentSize(NSSize(width: 1320, height: 860))
            window.center()
        }
        window.setFrameAutosaveName("FrisketMainWindow")
        let toolbar = NSToolbar(identifier: "FrisketToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        wire()
        editor.openUntitled()
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func buildSplit() {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        listItem = NSSplitViewItem(contentListWithViewController: noteList)
        listItem.minimumThickness = 230
        listItem.maximumThickness = 420
        listItem.canCollapse = true
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 360
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 200
        inspectorItem.maximumThickness = 340
        inspectorItem.isCollapsed = !AppSettings.shared.backlinksVisible
        for item in [sidebarItem!, listItem!, editorItem, inspectorItem!] { splitController.addSplitViewItem(item) }
        splitController.splitView.autosaveName = "FrisketSplit"
        if LibraryController.current == nil {
            listItem.isCollapsed = true
        }
    }

    private func wire() {
        sidebar.delegate = self
        noteList.delegate = self
        inspector.delegate = self
        editor.host = self
        editor.onStateChange = { [weak self] in self?.updateTitle() }
        editor.onSaved = { [weak self] url, manual in self?.didSave(url, manual: manual) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .frisketLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshContext()
        })
        observers.append(center.addObserver(forName: .frisketLibraryOpened, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.listItem.animator().isCollapsed = self.library == nil
            self.editor.libraryRoot = self.libraryRoot(for: self.editor.url)
            self.refreshContext()
            self.updateTitle()
        })
        observers.append(center.addObserver(forName: .frisketFilesChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let url = self.editor.url, let paths = note.userInfo?["paths"] as? [String] else { return }
            let path = url.canonicalPath
            if paths.contains(where: { $0 == path || $0 == url.path }) { self.checkDisk() }
        })
        observers.append(center.addObserver(forName: .frisketSelectionChanged, object: editor.textView, queue: .main) { [weak self] _ in
            self?.scheduleOutline()
        })
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: editor.textView, queue: .main) { [weak self] _ in
            self?.scheduleOutline()
        })
    }

    // MARK: Title and state

    func updateTitle() {
        guard let window else { return }
        let title = editor.url == nil && editor.text.isEmpty ? "Untitled" : editor.documentTitle
        window.title = title
        window.tab.title = title
        if let url = editor.url {
            if let library, library.contains(url) {
                let relative = url.canonicalPath.replacingOccurrences(of: library.root.path + "/", with: "")
                window.subtitle = library.name + " › " + relative
            } else {
                window.subtitle = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            }
        } else {
            window.subtitle = library?.name ?? ""
        }
        window.representedURL = editor.url
        window.isDocumentEdited = editor.isDirty
    }

    private func libraryRoot(for url: URL?) -> URL? {
        guard let url, let library, library.contains(url) else { return nil }
        return library.root
    }

    private func scheduleOutline() {
        outlineTimer?.invalidate()
        outlineTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.inspector.update(headings: self.editor.headings, caret: self.editor.textView.selectedRange().location)
        }
    }

    /// Backlinks, properties and attachments for the open note.
    func refreshContext() {
        contextTask?.cancel()
        scheduleOutline()
        let info = noteInfo()
        guard let library, let url = editor.url, library.contains(url) else {
            inspector.update(context: nil, info: info)
            return
        }
        contextTask = Task { @MainActor [weak self] in
            let context = await library.query { await $0.context(for: url) }
            guard let self, !Task.isCancelled, self.editor.url == url else { return }
            self.inspector.update(context: context, info: info)
        }
    }

    private func noteInfo() -> [(String, String)] {
        var info: [(String, String)] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let url = editor.url {
            info.append(("File", (url.path as NSString).abbreviatingWithTildeInPath))
            if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                if let created = values.creationDate { info.append(("Created", formatter.string(from: created))) }
                if let modified = values.contentModificationDate { info.append(("Modified", formatter.string(from: modified))) }
            }
        }
        let properties = parseFrontMatter(editor.text)
        if !properties.tags.isEmpty { info.append(("Tags", properties.tags.map { "#" + $0 }.joined(separator: " "))) }
        return info
    }

    // MARK: Opening notes

    /// Save or confirm leaving the current note. Calls `proceed` with false to stay.
    func leaveCurrentNote(_ proceed: @escaping (Bool) -> Void) {
        guard editor.isDirty else { proceed(true); return }
        if editor.url != nil {
            editor.save(manual: false) { proceed($0 == .saved) }
            return
        }
        guard let window else { proceed(false); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to this note?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.editor.save(manual: true) { proceed($0 == .saved) }
            case .alertSecondButtonReturn: proceed(true)
            default: proceed(false)
            }
        }
    }

    /// Open `url` here (or bring forward the window that already has it).
    func open(_ url: URL, at offset: Int? = nil, length: Int = 0, recordHistory: Bool = true) {
        let target = url.standardizedFileURL
        if let current = editor.url, sameFile(current, target) {
            if let offset { editor.reveal(offset: offset, length: length) }
            return
        }
        if let other = MainWindowController.all.first(where: { $0 !== self && sameFile($0.editor.url, target) }) {
            other.window?.makeKeyAndOrderFront(nil)
            if let offset { other.editor.reveal(offset: offset, length: length) }
            return
        }
        leaveCurrentNote { [weak self] proceed in
            guard let self, proceed else { return }
            let previous = self.editor.url.map { ($0, self.editor.textView.selectedRange().location) }
            do {
                self.editor.libraryRoot = self.libraryRoot(for: target)
                try self.editor.open(target)
            } catch {
                self.presentAlert("Could not open “\(target.lastPathComponent)”", error.localizedDescription)
                return
            }
            if recordHistory, let previous {
                self.back.append(previous)
                self.forward.removeAll()
            }
            if let offset { self.editor.reveal(offset: offset, length: length) }
            self.window?.makeFirstResponder(self.editor.textView)
            self.noteList.setActive(target)
            AppSettings.shared.lastNotePath = target.path
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            self.updateTitle()
            self.refreshContext()
        }
    }

    func openUntitled(_ text: String = "") {
        leaveCurrentNote { [weak self] proceed in
            guard let self, proceed else { return }
            self.editor.libraryRoot = nil
            self.editor.openUntitled(text)
            self.noteList.setActive(nil)
            self.window?.makeFirstResponder(self.editor.textView)
            self.updateTitle()
            self.refreshContext()
        }
    }

    private func checkDisk() {
        guard editor.checkDisk(), let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "“\(editor.displayName)” changed on disk"
        alert.informativeText = "Another app or device saved a different version while you were editing. Reload it and lose your unsaved changes, or keep your version (saving will ask before overwriting)."
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Reload from Disk")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.editor.reloadFromDisk() }
        }
    }

    private func didSave(_ url: URL, manual: Bool) {
        noteList.setActive(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        AppSettings.shared.lastNotePath = url.path
        library?.refresh()
        updateTitle()
        if manual { offerTitleLinkUpdate(url) }
    }

    /// After a title change, offer to point links that still use the old title at the new one.
    private func offerTitleLinkUpdate(_ url: URL) {
        guard let library, library.contains(url) else { return }
        Task { @MainActor [weak self] in
            let change = await library.query { index -> TitleChange? in
                await index.refresh()
                return await index.titleChange(for: url)
            }
            guard let self, let change, change.links > 0, let window = self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = "Update links to this note?"
            let files = change.files.count
            alert.informativeText = "“\(change.from)” is now “\(change.to)”. \(change.links) \(change.links == 1 ? "link" : "links") in \(files) \(files == 1 ? "note" : "notes") still use the old title."
            alert.addButton(withTitle: "Update Links")
            alert.addButton(withTitle: "Leave Them")
            alert.addButton(withTitle: "Not Now")
            alert.beginSheetModal(for: window) { response in
                Task { @MainActor in
                    if response == .alertFirstButtonReturn {
                        let result = try? await library.perform { await $0.updateTitleLinks(for: url) }
                        if let result, !result.skipped.isEmpty {
                            self.presentAlert("Some links were not updated", "\(result.skipped.count) note(s) changed on disk and were left alone.")
                        }
                    } else if response == .alertSecondButtonReturn {
                        _ = await library.query { await $0.dismissTitleChange(for: url) }
                    }
                }
            }
        }
    }

    func presentAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editor.isDirty else { return true }
        leaveCurrentNote { [weak self] proceed in
            guard proceed, let self else { return }
            self.editor.openUntitled()
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        MainWindowController.all.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        checkDisk()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {}

    // MARK: Toolbar

    private enum ToolbarID {
        static let newNote = NSToolbarItem.Identifier("newNote")
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let quickOpen = NSToolbarItem.Identifier("quickOpen")
        static let sourceMode = NSToolbarItem.Identifier("sourceMode")
        static let today = NSToolbarItem.Identifier("today")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.newNote, ToolbarID.navigation, .flexibleSpace,
         ToolbarID.today, ToolbarID.quickOpen, ToolbarID.sourceMode, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case ToolbarID.newNote: return button(id, "New Note", "square.and.pencil", #selector(newNote(_:)))
        case ToolbarID.today: return button(id, "Today", "calendar", #selector(openDailyNote(_:)))
        case ToolbarID.quickOpen: return button(id, "Quick Open", "magnifyingglass", #selector(quickOpen(_:)))
        case ToolbarID.sourceMode: return button(id, "Source Mode", "chevron.left.forwardslash.chevron.right", #selector(AppDelegate.toggleSourceMode(_:)))
        case ToolbarID.navigation:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!,
            ], selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navigate(_:)))
            group.label = "Back/Forward"
            group.paletteLabel = "Back/Forward"
            group.controlRepresentation = .expanded
            return group
        default: return nil
        }
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { goBack(sender) } else { goForward(sender) }
    }

    // MARK: Commands

    @objc func newNote(_ sender: Any?) {
        guard let library else { openUntitled(); return }
        Task { @MainActor [weak self] in
            do {
                let url = try await library.perform { try await $0.createNote(title: nil) }
                self?.sidebar.select(.notes)
                self?.open(url)
                // Select the placeholder title so typing replaces it.
                if let self, let range = (self.editor.text as NSString).range(of: "Untitled", options: .backwards).nilIfNotFound {
                    self.editor.textView.setSelectedRange(range)
                }
            } catch {
                self?.presentAlert("Could not create a note", error.localizedDescription)
            }
        }
    }

    @objc override func newWindowForTab(_ sender: Any?) {
        MainWindowController.newWindow(tabbedWith: window)
    }

    @objc func saveDocument(_ sender: Any?) { editor.save(manual: true) }
    @objc func saveDocumentAs(_ sender: Any?) { editor.save(manual: true, saveAs: true) }

    @objc func openDailyNote(_ sender: Any?) {
        guard let library else { requireLibrary(); return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        Task { @MainActor [weak self] in
            do {
                let templates = await library.query { try? await $0.templates() }
                let daily = templates?.first { $0.name.lowercased() == "daily" }
                let body = daily.map { StyleCheck.applyTemplate($0.contents, title: date) }
                let result = try await library.perform { try await $0.dailyNote(date: date, body: body) }
                self?.open(result.url, at: (try? FileOps.readText(result.url)).map { ($0 as NSString).length })
            } catch {
                self?.presentAlert("Could not open today’s note", error.localizedDescription)
            }
        }
    }

    @objc func togglePin(_ sender: Any?) {
        guard let library, let url = editor.url, library.contains(url) else { NSSound.beep(); return }
        let pinned = parseFrontMatter(editor.text).properties["frisket-pinned"]?.isTruthy ?? false
        setPinned(url, !pinned)
    }

    private func setPinned(_ url: URL, _ pinned: Bool) {
        guard let library else { return }
        let save: () -> Void = {
            Task { @MainActor [weak self] in
                do {
                    try await library.perform { try await $0.setPinned(url, pinned: pinned) }
                    if sameFile(self?.editor.url, url) { self?.editor.reloadFromDisk() }
                } catch {
                    self?.presentAlert("Could not change the pin", error.localizedDescription)
                }
            }
        }
        // Pinning rewrites the file: save pending edits first.
        if sameFile(editor.url, url), editor.isDirty {
            editor.save(manual: false) { if $0 == .saved { save() } }
        } else {
            save()
        }
    }

    @objc func showVersionHistory(_ sender: Any?) {
        guard let url = editor.url, let window else { NSSound.beep(); return }
        showHistory(for: url, in: window)
    }

    private func showHistory(for url: URL, in window: NSWindow) {
        let isOpen = sameFile(editor.url, url)
        let text = isOpen ? editor.text : ((try? FileOps.readText(url)) ?? "")
        Panels.showVersionHistory(for: url, currentText: text, libraryRoot: libraryRoot(for: url), parent: window) { [weak self] restored in
            guard let self else { return }
            if isOpen {
                // Restoring is an edit: it can be undone, and saving records the old text first.
                let all = NSRange(location: 0, length: (self.editor.text as NSString).length)
                self.editor.textView.edit([(all, restored)], select: NSRange(location: 0, length: 0))
                self.editor.save(manual: true)
            } else {
                _ = try? HistoryStore.record(file: url, text: text, libraryRoot: self.libraryRoot(for: url), fallbackRoot: EditorViewController.historyFallbackRoot, reason: .beforeChange)
                try? FileOps.replaceFile(url, text: restored)
                self.library?.refresh()
            }
        }
    }

    @objc func showSync(_ sender: Any?) {
        guard let window else { return }
        Panels.showSync(library: library, parent: window) { [weak self] url in self?.open(url) }
    }

    @objc func quickOpen(_ sender: Any?) {
        guard let window else { return }
        QuickOpenPanel.show(in: window, library: library) { [weak self] url in self?.open(url) }
    }

    @objc func quickCapture(_ sender: Any?) {
        guard let library else { requireLibrary(); return }
        Panels.showQuickCapture(library: library, parent: window)
    }

    @objc func newFromTemplate(_ sender: Any?) {
        guard let library, let window else { requireLibrary(); return }
        Panels.chooseTemplate(library: library, parent: window) { [weak self] template in
            guard let template, let self else { return }
            Task { @MainActor in
                do {
                    let title = template.name
                    let url = try await library.perform { try await $0.createNote(title: title) }
                    let created = (try? FileOps.readText(url)) ?? ""
                    let split = splitFrontMatter(created)
                    let body = StyleCheck.applyTemplate(template.contents, title: title)
                    try FileOps.replaceFile(url, text: (created as NSString).substring(to: split.bodyOffset) + "\n" + body)
                    self.open(url)
                } catch {
                    self.presentAlert("Could not create a note", error.localizedDescription)
                }
            }
        }
    }

    @objc func insertTemplate(_ sender: Any?) {
        guard let library, let window else { requireLibrary(); return }
        Panels.chooseTemplate(library: library, parent: window) { [weak self] template in
            guard let template, let self else { return }
            let textView = self.editor.textView!
            let selection = (textView.string as NSString).substring(with: textView.selectedRange())
            textView.insertMarkdown(StyleCheck.applyTemplate(template.contents, title: self.editor.documentTitle, selection: selection))
        }
    }

    @objc func saveSnippet(_ sender: Any?) {
        guard let library, let window else { requireLibrary(); return }
        let textView = editor.textView!
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        guard !selected.isEmpty else { presentAlert("Select some text first", "The selection is saved as a template you can insert later."); return }
        Panels.saveSnippet(text: selected, library: library, parent: window)
    }

    @objc func styleCheck(_ sender: Any?) {
        guard let window else { return }
        Panels.showStyleCheck(textView: editor.textView, parent: window)
    }

    @objc func attachmentAudit(_ sender: Any?) {
        guard let library, let window else { requireLibrary(); return }
        Panels.showAttachmentAudit(library: library, parent: window) { [weak self] url in self?.open(url) }
    }

    @objc func showConflicts(_ sender: Any?) {
        showSync(sender)
    }

    @objc func importNotes(_ sender: NSMenuItem) {
        guard let library, let window else { requireLibrary(); return }
        guard let kind = ImportKind(rawValue: sender.representedObject as? String ?? "") else { return }
        Panels.runImport(kind: kind, library: library, parent: window) { [weak self] folder in
            self?.library?.refresh()
            _ = folder
        }
    }

    @objc func exportDocument(_ sender: NSMenuItem) {
        guard let window, let format = sender.representedObject as? String else { return }
        ExportController.export(format: format, editor: editor, library: library, parent: window)
    }

    @objc func exportWithLayout(_ sender: Any?) {
        guard let window else { return }
        ExportController.exportWithLayout(editor: editor, library: library, parent: window)
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window else { return }
        ExportController.print(editor: editor, library: library, parent: window)
    }

    @objc func copyAsHTML(_ sender: Any?) {
        ExportController.copyAsHTML(editor: editor, library: library)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = editor.url else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func goBack(_ sender: Any?) {
        guard let (url, caret) = back.popLast() else { NSSound.beep(); return }
        if let current = editor.url { forward.append((current, editor.textView.selectedRange().location)) }
        open(url, at: caret, recordHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let (url, caret) = forward.popLast() else { NSSound.beep(); return }
        if let current = editor.url { back.append((current, editor.textView.selectedRange().location)) }
        open(url, at: caret, recordHistory: false)
    }

    @objc func toggleNoteList(_ sender: Any?) {
        listItem.animator().isCollapsed.toggle()
    }

    @objc func showOutline(_ sender: Any?) { showInspector(.outline) }
    @objc func showBacklinks(_ sender: Any?) { showInspector(.backlinks) }
    @objc func showNoteInfo(_ sender: Any?) { showInspector(.info) }

    private func showInspector(_ tab: InspectorViewController.Tab) {
        if inspectorItem.isCollapsed || inspector.tab != tab {
            inspector.show(tab)
            inspectorItem.animator().isCollapsed = false
            AppSettings.shared.backlinksVisible = true
        } else {
            inspectorItem.animator().isCollapsed = true
            AppSettings.shared.backlinksVisible = false
        }
        refreshContext()
    }

    @objc func searchNotes(_ sender: Any?) {
        guard library != nil else { requireLibrary(); return }
        if listItem.isCollapsed { listItem.animator().isCollapsed = false }
        noteList.focusSearch()
    }

    @objc func emptyTrash(_ sender: Any?) {
        guard let library, let window else { return }
        let trashed = (library.snapshot?.summaries ?? []).filter(\.isTrashed)
        guard !trashed.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Delete \(trashed.count) \(trashed.count == 1 ? "note" : "notes") permanently?"
        alert.informativeText = "This can’t be undone. The last version of each note stays in version history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                for note in trashed {
                    let url = note.url
                    _ = try? await library.perform { try await $0.deleteNote(url) }
                }
            }
        }
    }

    private func requireLibrary() {
        presentAlert("No library open", "Choose File › Open Library… to use a folder of Markdown notes as your library.")
    }
}

// MARK: - Menu validation

extension MainWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        validate(item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action)
    }

    private func validate(_ action: Selector?) -> Bool {
        switch action {
        case #selector(goBack(_:)): return !back.isEmpty
        case #selector(goForward(_:)): return !forward.isEmpty
        case #selector(togglePin(_:)): return editor.url.map { library?.contains($0) ?? false } ?? false
        case #selector(showVersionHistory(_:)), #selector(revealInFinder(_:)): return editor.url != nil
        case #selector(openDailyNote(_:)), #selector(quickCapture(_:)), #selector(newFromTemplate(_:)),
             #selector(insertTemplate(_:)), #selector(saveSnippet(_:)), #selector(attachmentAudit(_:)),
             #selector(importNotes(_:)), #selector(emptyTrash(_:)):
            return library != nil
        default: return true
        }
    }
}

// MARK: - Sidebar, list and inspector

extension MainWindowController: SidebarDelegate, NoteListDelegate, InspectorDelegate {
    func sidebar(_ sidebar: SidebarViewController, didSelect filter: LibraryFilter) {
        if listItem.isCollapsed { listItem.animator().isCollapsed = false }
        noteList.search("")
        noteList.show(filter)
    }

    func sidebar(_ sidebar: SidebarViewController, didSelectSearch query: String) {
        if listItem.isCollapsed { listItem.animator().isCollapsed = false }
        noteList.show(.notes)
        noteList.search(query)
    }

    func noteList(_ list: NoteListViewController, open url: URL, match: Int?) {
        open(url, at: match)
    }

    func noteList(_ list: NoteListViewController, perform action: NoteListViewController.Action, on note: NoteSummary) {
        guard let library, let window else { return }
        let url = note.url
        let isOpen = sameFile(editor.url, url)
        switch action {
        case .pin, .unpin:
            setPinned(url, action == .pin)
        case .history:
            showHistory(for: url, in: window)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyLink:
            let target = note.linkText ?? note.title
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("[[" + target + "]]", forType: .string)
        case .trash:
            let move: () -> Void = {
                Task { @MainActor [weak self] in
                    do {
                        let moved = try await library.perform { try await $0.trashNote(url) }
                        if isOpen { self?.editor.fileMoved(to: moved) }
                    } catch { self?.presentAlert("Could not move the note to the Trash", error.localizedDescription) }
                }
            }
            if isOpen && editor.isDirty { editor.save(manual: false) { if $0 == .saved { move() } } } else { move() }
        case .restore:
            Task { @MainActor [weak self] in
                do {
                    let restored = try await library.perform { try await $0.restoreNote(url) }
                    if isOpen { self?.editor.fileMoved(to: restored) }
                } catch { self?.presentAlert("Could not restore the note", error.localizedDescription) }
            }
        case .delete:
            let alert = NSAlert()
            alert.messageText = "Delete “\(note.title)” permanently?"
            alert.informativeText = "This can’t be undone. The last version stays in version history."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                Task { @MainActor in
                    do {
                        try await library.perform { try await $0.deleteNote(url) }
                        if isOpen { self?.editor.openUntitled() }
                    } catch { self?.presentAlert("Could not delete the note", error.localizedDescription) }
                }
            }
        case .resolveConflict:
            Panels.resolveConflict(note: note, library: library, parent: window) { [weak self] kept in
                if let kept { self?.open(kept) }
            }
        }
    }

    func inspector(_ inspector: InspectorViewController, revealOffset offset: Int) {
        editor.reveal(offset: offset)
    }

    func inspector(_ inspector: InspectorViewController, open url: URL, at offset: Int?) {
        open(url, at: offset)
    }

    func inspector(_ inspector: InspectorViewController, link mention: UnlinkedMention) {
        guard let library, let target = editor.url else { return }
        let source = mention.url
        // The mention may be in the open note of another window: save that first.
        Task { @MainActor [weak self] in
            do {
                let result = try await library.perform {
                    try await $0.linkMention(in: source, pos: mention.pos, length: mention.length, expected: mention.text, target: target)
                }
                if !result.ok { self?.presentAlert("The mention changed", "That note was edited since the mention was found. Try again.") }
                for controller in MainWindowController.all where sameFile(controller.editor.url, source) {
                    controller.editor.checkDisk()
                }
                self?.refreshContext()
            } catch {
                self?.presentAlert("Could not add the link", error.localizedDescription)
            }
        }
    }
}

// MARK: - Editor host

extension MainWindowController: MarkdownTextViewHost {
    func markdownTextView(_ view: MarkdownTextView, openLink target: String, wiki: Bool) {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if !wiki, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        if !wiki, trimmed.lowercased().hasPrefix("www.") {
            if let url = URL(string: "https://" + trimmed) { NSWorkspace.shared.open(url) }
            return
        }
        if trimmed.hasPrefix("#") {
            revealHeading(String(trimmed.dropFirst()))
            return
        }
        guard let library else {
            openRelative(trimmed)
            return
        }
        let source = editor.url
        Task { @MainActor [weak self] in
            let resolution = await library.query { await $0.resolveLink(trimmed, from: source) }
            guard let self else { return }
            switch resolution {
            case .note(let brief, let anchor):
                self.open(brief.url)
                if let anchor { self.revealHeading(anchor) }
            case .ambiguous(let notes, _):
                self.chooseAmbiguous(notes)
            case .anchorOnly(let anchor):
                if let anchor { self.revealHeading(anchor) }
            case .external:
                if let url = URL(string: trimmed) { NSWorkspace.shared.open(url) }
            case .missing(let name, _, let trashed):
                self.offerCreate(name: name, trashed: trashed, wiki: wiki, target: trimmed)
            }
        }
    }

    private func openRelative(_ target: String) {
        let decoded = target.removingPercentEncoding ?? target
        guard let base = editor.url?.deletingLastPathComponent() else { NSSound.beep(); return }
        let url = base.appendingPathComponent(decoded).standardized
        if isMarkdownFile(url) { open(url) } else { NSWorkspace.shared.open(url) }
    }

    private func revealHeading(_ anchor: String) {
        let slug = anchor.lowercased()
        if let heading = editor.headings.first(where: { headingAnchor($0.text) == slug || $0.text.lowercased() == slug }) {
            editor.reveal(offset: heading.range.location)
        }
    }

    private func headingAnchor(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }

    private func chooseAmbiguous(_ notes: [NoteBrief]) {
        let menu = NSMenu(title: "Several notes match")
        for note in notes {
            let item = NSMenuItem(title: note.title + "  —  " + note.relative, action: #selector(openFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = note.url
            menu.addItem(item)
        }
        let textView = editor.textView!
        let rect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        guard let window else { return }
        let point = window.convertPoint(fromScreen: rect.origin)
        menu.popUp(positioning: nil, at: textView.convert(point, from: nil), in: textView)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    private func offerCreate(name: String, trashed: NoteBrief?, wiki: Bool, target: String) {
        guard let window, let library else { return }
        let alert = NSAlert()
        alert.messageText = "“\(name)” doesn’t exist yet"
        alert.informativeText = trashed != nil ? "A note with that name is in the Trash." : "Create a new note with this title?"
        alert.addButton(withTitle: "Create Note")
        if trashed != nil { alert.addButton(withTitle: "Restore from Trash") }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                if response == .alertFirstButtonReturn {
                    // Wiki links create the note in Notes/; path links next to the linking note.
                    let folder: URL
                    if wiki || self?.editor.url == nil {
                        folder = library.root.appendingPathComponent("Notes", isDirectory: true)
                    } else {
                        folder = self!.editor.url!.deletingLastPathComponent()
                    }
                    let fileName = wiki ? FileOps.safeName(name) + ".md" : (target.removingPercentEncoding ?? target)
                    let destination = folder.appendingPathComponent(fileName).standardized
                    guard FileOps.isWithin(library.root, destination) else {
                        self?.presentAlert("Can’t create that note", "Links can only create notes inside the library.")
                        return
                    }
                    do {
                        let created = try await library.perform { try await $0.createLinkedNote(at: destination, title: name) }
                        self?.open(created)
                    } catch {
                        self?.presentAlert("Could not create the note", error.localizedDescription)
                    }
                } else if response == .alertSecondButtonReturn, let trashed {
                    let url = trashed.url
                    if let restored = try? await library.perform({ try await $0.restoreNote(url) }) { self?.open(restored) }
                }
            }
        }
    }

    func markdownTextView(_ view: MarkdownTextView, noteCompletionsFor query: String) -> [CompletionItem] {
        guard let snapshot = library?.snapshot else { return [] }
        let current = editor.url?.canonicalPath
        let notes = snapshot.summaries.filter { !$0.isTrashed && $0.path != current }.map {
            CompletionNote(title: $0.title, linkText: $0.linkText, name: $0.name, relative: $0.relative, path: $0.path, aliases: $0.aliases, modifiedAt: isoTimestamp($0.modifiedAt))
        }
        return Completions.noteCompletions(notes, query: query, limit: 40).map {
            CompletionItem(label: $0.label, detail: $0.detail, insert: $0.insert, alias: $0.alias, isWiki: true)
        }
    }

    func markdownTextView(_ view: MarkdownTextView, tagCompletionsFor query: String) -> [CompletionItem] {
        guard let tags = library?.snapshot?.tags else { return [] }
        let counts = tags.map { FrisketServices.TagCount(tag: $0.tag, count: $0.count) }
        return Completions.tagCompletions(counts, query: query).map {
            CompletionItem(label: "#" + $0.label, detail: $0.detail, insert: $0.insert, isWiki: false)
        }
    }

    func markdownTextView(_ view: MarkdownTextView, insertAssets urls: [URL]) -> String? {
        do {
            return try urls.map { url -> String in
                let stored = try AssetStore.importFile(url, besideNote: editor.url)
                return stored.markdown
            }.joined(separator: "\n")
        } catch {
            presentAlert("Could not add the file", error.localizedDescription)
            return nil
        }
    }

    func markdownTextView(_ view: MarkdownTextView, insertImageData data: Data, fileExtension: String) -> String? {
        do {
            return try AssetStore.saveImage(data, fileExtension: fileExtension, besideNote: editor.url).markdown
        } catch {
            presentAlert("Could not save the image", error.localizedDescription)
            return nil
        }
    }
}

private extension NSRange {
    var nilIfNotFound: NSRange? { location == NSNotFound ? nil : self }
}
