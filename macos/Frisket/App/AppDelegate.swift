import AppKit
import FrisketBase

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var pendingOpen: [URL] = []
    private var launched = false
    private var settingsObserver: NSObjectProtocol?
    private var distractionFree: [ObjectIdentifier: (sidebar: Bool, list: Bool, inspector: Bool)] = [:]

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
        applyAppearance()
        settingsObserver = NotificationCenter.default.addObserver(forName: .frisketSettingsChanged, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            if key == "appearance" || key == "theme" { MainActor.assumeIsolated { self?.applyAppearance() } }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["FRISKET_LIBRARY"] { AppSettings.shared.libraryURL = URL(fileURLWithPath: path) }
        #endif
        if let library = AppSettings.shared.libraryURL, FileManager.default.fileExists(atPath: library.path) {
            LibraryController.open(library)
        }
        let controller = MainWindowController.newWindow()
        launched = true
        if !pendingOpen.isEmpty {
            open(pendingOpen)
            pendingOpen = []
        } else if let last = AppSettings.shared.lastNotePath, FileManager.default.fileExists(atPath: last) {
            controller.open(URL(fileURLWithPath: last))
        }
        runDebugHooks(controller)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.newWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func applyAppearance() {
        NSApp.appearance = AppSettings.shared.nsAppearance
    }

    // MARK: Opening files and folders

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingOpen += urls; return }
        open(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard launched else { pendingOpen.append(url); return true }
        open([url])
        return true
    }

    /// Folders become the library; Markdown files open in a tab (or the empty front window).
    private func open(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                LibraryController.open(url)
                continue
            }
            if let existing = MainWindowController.all.first(where: { sameFile($0.editor.url, url) }) {
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            if let front = MainWindowController.front, front.editor.url == nil, front.editor.text.isEmpty {
                front.open(url)
            } else {
                MainWindowController.newWindow(tabbedWith: MainWindowController.front?.window).open(url)
            }
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!, .plainText, .folder]
        panel.message = "Choose notes to open, or a folder to use as your library."
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { self?.open(panel.urls) }
        }
        if let window = MainWindowController.front?.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    @objc func openLibrary(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use as Library"
        panel.message = "Choose a folder of Markdown notes. Your files stay where they are."
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { LibraryController.open(url) }
        }
        if let window = MainWindowController.front?.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    @objc func newWindow(_ sender: Any?) {
        MainWindowController.newWindow()
    }

    // MARK: Quitting

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = MainWindowController.all.filter { $0.editor.isDirty }
        guard !dirty.isEmpty else { return .terminateNow }
        // Notes with a file are saved quietly, as auto-save would have; untitled ones ask.
        var remaining = dirty
        func next() {
            guard let controller = remaining.first else { NSApp.reply(toApplicationShouldTerminate: true); return }
            remaining.removeFirst()
            controller.window?.makeKeyAndOrderFront(nil)
            controller.leaveCurrentNote { proceed in
                if proceed { next() } else { NSApp.reply(toApplicationShouldTerminate: false) }
            }
        }
        next()
        return .terminateLater
    }

    // MARK: Settings commands

    @objc func showPreferences(_ sender: Any?) { Panels.showPreferences() }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: "The syntax is masked. The writing shows through.\nFree to use, for anything, forever.\n\nBuilt by CFDR Studio — cfdr.au",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func toggleSourceMode(_ sender: Any?) { AppSettings.shared.sourceMode.toggle() }
    @objc func toggleFocusMode(_ sender: Any?) { AppSettings.shared.focusMode.toggle() }
    @objc func toggleTypewriterMode(_ sender: Any?) { AppSettings.shared.typewriterMode.toggle() }

    @objc func zoomIn(_ sender: Any?) { AppSettings.shared.fontSize = min(40, AppSettings.shared.fontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { AppSettings.shared.fontSize = max(10, AppSettings.shared.fontSize - 1) }
    @objc func actualSize(_ sender: Any?) { AppSettings.shared.fontSize = 17 }

    @objc func setTheme(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { AppSettings.shared.theme = name }
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let value = AppearanceSetting(rawValue: raw) { AppSettings.shared.appearance = value }
    }

    /// Hide everything but the text; again to bring it back.
    @objc func toggleDistractionFree(_ sender: Any?) {
        guard let controller = MainWindowController.front else { return }
        let items = controller.splitController.splitViewItems
        let key = ObjectIdentifier(controller)
        if let saved = distractionFree.removeValue(forKey: key) {
            items[0].animator().isCollapsed = saved.sidebar
            items[1].animator().isCollapsed = saved.list
            items[3].animator().isCollapsed = saved.inspector
            controller.window?.toolbar?.isVisible = true
        } else {
            distractionFree[key] = (items[0].isCollapsed, items[1].isCollapsed, items[3].isCollapsed)
            for index in [0, 1, 3] { items[index].animator().isCollapsed = true }
            controller.window?.toolbar?.isVisible = false
        }
    }

    @objc func openThemeFolder(_ sender: Any?) {
        let folder = ThemeStore.shared.userThemeFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc func showMarkdownReference(_ sender: Any?) { Panels.showMarkdownReference() }
    @objc func showShortcuts(_ sender: Any?) { Panels.showShortcuts() }

    @objc func showLegal(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let settings = AppSettings.shared
        switch item.action {
        case #selector(toggleSourceMode(_:)): item.state = settings.sourceMode ? .on : .off
        case #selector(toggleFocusMode(_:)): item.state = settings.focusMode ? .on : .off
        case #selector(toggleTypewriterMode(_:)): item.state = settings.typewriterMode ? .on : .off
        case #selector(toggleDistractionFree(_:)):
            item.state = MainWindowController.front.map { distractionFree[ObjectIdentifier($0)] != nil } == true ? .on : .off
            return MainWindowController.front != nil
        case #selector(setAppearance(_:)): item.state = (item.representedObject as? String) == settings.appearance.rawValue ? .on : .off
        case #selector(setTheme(_:)): item.state = (item.representedObject as? String) == settings.theme ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Debug hooks (screenshots in development)

    private func runDebugHooks(_ controller: MainWindowController) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["FRISKET_OPEN"] { controller.open(URL(fileURLWithPath: path)) }
        if let caret = environment["FRISKET_CARET"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.editor.reveal(offset: caret) }
        }
        if let y = environment["FRISKET_SCROLLY"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { controller.editor.textView.scroll(NSPoint(x: 0, y: y)) }
        }
        if let shot = environment["FRISKET_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let window = controller.window, let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
                NSApp.terminate(nil)
            }
        }
        #endif
    }
}
