import AppKit
import FrisketExport

/// The Settings window: toolbar tabs, every control writes `AppSettings` immediately.
@MainActor
enum PreferencesWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func item(_ controller: NSViewController, _ label: String, _ symbol: String) {
            let tab = NSTabViewItem(viewController: controller)
            tab.label = label
            tab.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(tab)
        }
        item(GeneralPane(), "General", "gearshape")
        item(EditorPane(), "Editor", "text.cursor")
        item(AppearancePane(), "Appearance", "paintpalette")
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        Closer.shared.attach(to: window) { PreferencesWindow.window = nil }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private final class Closer: NSObject, NSWindowDelegate {
        static let shared = Closer()
        var handler: (() -> Void)?
        @MainActor func attach(to window: NSWindow, _ handler: @escaping () -> Void) {
            self.handler = handler
            window.delegate = self
        }
        func windowWillClose(_ notification: Notification) { handler?(); handler = nil }
    }
}

@MainActor
class PrefsPane: NSViewController {
    let settings = AppSettings.shared
    private let grid = NSGridView()
    private var updaters: [() -> Void] = []
    private var observers: [NSObjectProtocol] = []

    override func loadView() {
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            container.widthAnchor.constraint(equalToConstant: 540),
        ])
        view = container
        build()
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        for name in [Notification.Name.frisketSettingsChanged, .frisketLibraryOpened] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
        container.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 540, height: container.fittingSize.height)
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func build() {}

    func refresh() { updaters.forEach { $0() } }

    func update(_ block: @escaping () -> Void) { updaters.append(block) }

    func row(_ title: String?, _ control: NSView) {
        let label = title.map { UI.label($0 + ":", color: .secondaryLabelColor) } ?? NSView()
        grid.addRow(with: [label, control])
    }

    func note(_ text: String) {
        let field = UI.secondary(text)
        field.preferredMaxLayoutWidth = 340
        grid.addRow(with: [NSView(), field])
    }

    func toggle(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let box = UI.checkbox(title) { set($0) }
        update { box.state = get() ? .on : .off }
        return box
    }

    func number(get: @escaping () -> Double, set: @escaping (Double) -> Void, min: Double, max: Double, step: Double,
                decimals: Int, suffix: String = "") -> NSView {
        let field = NSTextField()
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.minimum = NSNumber(value: min)
        formatter.maximum = NSNumber(value: max)
        field.formatter = formatter
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let stepper = NSStepper()
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = step
        stepper.valueWraps = false
        UI.onAction(field) { control in
            set((control as? NSTextField)?.doubleValue ?? get())
        }
        UI.onAction(stepper) { control in set((control as? NSStepper)?.doubleValue ?? get()) }
        update {
            field.doubleValue = get()
            stepper.doubleValue = get()
        }
        let row = NSStackView(views: [field, stepper] + (suffix.isEmpty ? [] : [UI.secondary(suffix, wraps: false)]))
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    func chooseFile(title: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
}

@MainActor
final class GeneralPane: PrefsPane {
    override func build() {
        row("Library", libraryControls())
        row("Saving", toggle("Save automatically as you type", get: { self.settings.autoSave }, set: { self.settings.autoSave = $0 }))
        row(nil, toggle("Show status bar", get: { self.settings.showStatusBar }, set: { self.settings.showStatusBar = $0 }))
        row("Pandoc", pandocControls())
        note("Pandoc is only needed to export Word, EPUB, LaTeX and other formats. Frisket looks for it in the usual install folders.")
    }

    private func libraryControls() -> NSView {
        let path = UI.label("", color: .labelColor)
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false
        path.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let change = UI.button("Change\u{2026}") {
            let panel = NSOpenPanel()
            panel.title = "Choose Library Folder"
            panel.message = "Choose the folder that holds your notes."
            panel.prompt = "Open Library"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.begin { response in
                if response == .OK, let url = panel.url { LibraryController.open(url) }
            }
        }
        update { path.stringValue = LibraryController.current?.root.path ?? self.settings.libraryURL?.path ?? "No library open" }
        let stack = UI.vstack([path, change], spacing: 6)
        return stack
    }

    private func pandocControls() -> NSView {
        let status = UI.label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, wraps: true)
        status.preferredMaxLayoutWidth = 340
        let choose = UI.button("Choose\u{2026}") { [weak self] in
            self?.chooseFile(title: "Choose the Pandoc executable") { self?.settings.pandocPath = $0.path }
        }
        let reset = UI.button("Use Auto-Detect") { [weak self] in self?.settings.pandocPath = "" }
        update {
            let custom = self.settings.pandocPath
            if let found = Pandoc.locate(customPath: custom) {
                status.stringValue = (!custom.isEmpty && found.path == custom ? "Custom: " : "Auto-detected: ") + found.path
            } else {
                status.stringValue = "Pandoc not found."
            }
            reset.isEnabled = !custom.isEmpty
        }
        let buttons = NSStackView(views: [choose, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        return UI.vstack([status, buttons], spacing: 6)
    }
}

@MainActor
final class EditorPane: PrefsPane {
    override func build() {
        row("Font size", number(get: { Double(self.settings.fontSize) }, set: { self.settings.fontSize = CGFloat($0) }, min: 10, max: 40, step: 1, decimals: 0, suffix: "pt"))
        row("Line height", number(get: { Double(self.settings.lineHeight) }, set: { self.settings.lineHeight = CGFloat($0) }, min: 1.1, max: 2.6, step: 0.05, decimals: 2))
        row("Content width", number(get: { Double(self.settings.contentWidth) }, set: { self.settings.contentWidth = CGFloat($0) }, min: 420, max: 1600, step: 20, decimals: 0, suffix: "pt"))
        row("Modes", toggle("Focus mode", get: { self.settings.focusMode }, set: { self.settings.focusMode = $0 }))
        row(nil, toggle("Typewriter mode", get: { self.settings.typewriterMode }, set: { self.settings.typewriterMode = $0 }))
        row(nil, toggle("Source code mode", get: { self.settings.sourceMode }, set: { self.settings.sourceMode = $0 }))
        row("Writing", toggle("Check spelling while typing", get: { self.settings.spellCheck }, set: { self.settings.spellCheck = $0 }))
        row(nil, toggle("Close brackets and quotes automatically", get: { self.settings.autoPair }, set: { self.settings.autoPair = $0 }))
    }
}

@MainActor
final class AppearancePane: PrefsPane {
    private let themePopup = NSPopUpButton()
    private let appearancePopup = NSPopUpButton()

    override func build() {
        UI.onAction(themePopup) { [weak self] _ in
            if let name = self?.themePopup.selectedItem?.representedObject as? String { self?.settings.theme = name }
        }
        row("Theme", themePopup)
        for option in AppearanceSetting.allCases {
            let title = option == .system ? "Follow System" : option.rawValue.capitalized
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = option.rawValue
            appearancePopup.menu?.addItem(item)
        }
        UI.onAction(appearancePopup) { [weak self] _ in
            if let raw = self?.appearancePopup.selectedItem?.representedObject as? String, let value = AppearanceSetting(rawValue: raw) {
                self?.settings.appearance = value
            }
        }
        row("Appearance", appearancePopup)
        let open = UI.button("Open Theme Folder") {
            let folder = ThemeStore.shared.userThemeFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
        let reload = UI.button("Reload Themes") { [weak self] in
            ThemeStore.shared.reload()
            self?.refresh()
        }
        let buttons = NSStackView(views: [open, reload])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        row("Custom themes", buttons)
        note("Drop a theme .css file into the theme folder, then choose Reload Themes.")
        update { [weak self] in self?.syncPopups() }
    }

    private func syncPopups() {
        themePopup.removeAllItems()
        for theme in ThemeStore.shared.themes {
            let item = NSMenuItem(title: theme.displayName, action: nil, keyEquivalent: "")
            item.representedObject = theme.name
            themePopup.menu?.addItem(item)
        }
        if let index = themePopup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == settings.theme }) {
            themePopup.selectItem(at: index)
        }
        if let index = appearancePopup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == settings.appearance.rawValue }) {
            appearancePopup.selectItem(at: index)
        }
        appearancePopup.isEnabled = !ThemeStore.shared.theme(named: settings.theme).fixedAppearance
    }
}
