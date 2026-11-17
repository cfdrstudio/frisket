import AppKit
import FrisketBase
import FrisketMarkdown
import FrisketLibrary

/// One open note: its editor, scroll view and status bar, and the file it is saved to.
/// Save semantics follow the Windows app: atomic replace, refuse to overwrite a file
/// that changed on disk, auto-save 1.5 s after typing stops, and a history snapshot
/// on open and on every save.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    private(set) var url: URL?
    private(set) var savedText = ""
    private var modificationDate: Date?
    private var autoSaveTimer: Timer?
    private var countTimer: Timer?
    private var saving = false
    private var wordMode = 0

    weak var host: MarkdownTextViewHost? { didSet { textView.host = host } }
    /// The library this note belongs to (for history snapshots and asset rules).
    var libraryRoot: URL?
    /// Called when the title, path or dirty state changes.
    var onStateChange: (() -> Void)?
    /// Called after a successful save (`manual` for ⌘S).
    var onSaved: ((URL, Bool) -> Void)?

    let storage: MarkdownTextStorage
    let widgets: WidgetRenderer
    private(set) var textView: MarkdownTextView!
    private let scrollView = NSScrollView()
    private let statusBar = NSStackView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let wordsButton = NSButton(title: "0 words", target: nil, action: nil)
    private let readingLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "Ln 1, Col 1")
    private var statusHeight: NSLayoutConstraint!
    /// Each note keeps its own undo history, even when it shares a window.
    private let undo = UndoManager()
    private var settingsObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?

    static var historyFallbackRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Frisket", isDirectory: true)
    }

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        let settings = AppSettings.shared
        let theme = ThemeStore.shared.theme(named: settings.theme)
        let dark = settings.isDark(for: NSApp.effectiveAppearance)
        let palette = theme.palette(dark: dark)
        storage = MarkdownTextStorage(styler: MarkdownStyler(theme: theme, dark: dark, fontSize: settings.fontSize, lineHeight: settings.lineHeight, sourceMode: settings.sourceMode))
        widgets = WidgetRenderer(theme: theme, palette: palette, fontSize: settings.fontSize)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        autoSaveTimer?.invalidate()
        countTimer?.invalidate()
    }

    // MARK: View

    override func loadView() {
        let root = NSView()
        let settings = AppSettings.shared
        textView = MarkdownTextView.make(storage: storage, palette: widgets.palette, widgets: widgets, fontSize: settings.fontSize)
        textView.delegate = self
        textView.host = host
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)

        for label in [pathLabel, readingLabel, positionLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wordsButton.isBordered = false
        wordsButton.font = .systemFont(ofSize: 11)
        wordsButton.contentTintColor = .secondaryLabelColor
        wordsButton.target = self
        wordsButton.action = #selector(cycleWordMode)
        wordsButton.toolTip = "Click to switch between words, characters and lines"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [pathLabel, spacer, wordsButton, readingLabel, positionLabel] { statusBar.addArrangedSubview(view) }
        statusBar.orientation = .horizontal
        statusBar.spacing = 14
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(statusBar)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        statusHeight = statusBar.heightAnchor.constraint(equalToConstant: settings.showStatusBar ? 24 : 0)
        statusHeight.isActive = true
        statusBar.isHidden = !settings.showStatusBar
        view = root
        applySettings()
        settingsObserver = NotificationCenter.default.addObserver(forName: .frisketSettingsChanged, object: nil, queue: .main) { [weak self] note in
            self?.settingsChanged(note.userInfo?["key"] as? String)
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
        updateCounts()
        updatePosition()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        textView.updateInsets()
    }

    private static let visualKeys: Set<String> = ["theme", "appearance", "focusMode", "typewriterMode", "sourceMode",
                                                  "fontSize", "lineHeight", "contentWidth", "spellCheck", "autoPair"]

    private func settingsChanged(_ key: String?) {
        if let key, !Self.visualKeys.contains(key), key != "showStatusBar" { return }
        if key == "showStatusBar" {
            let show = AppSettings.shared.showStatusBar
            statusBar.isHidden = !show
            statusHeight.constant = show ? 24 : 0
            return
        }
        applySettings()
    }

    /// Theme, appearance, font size and modes from the settings.
    func applySettings() {
        let settings = AppSettings.shared
        let theme = ThemeStore.shared.theme(named: settings.theme)
        let dark = settings.isDark(for: NSApp.effectiveAppearance)
        let palette = theme.palette(dark: dark)
        let styler = MarkdownStyler(theme: theme, dark: dark, fontSize: settings.fontSize, lineHeight: settings.lineHeight, sourceMode: settings.sourceMode)
        textView.apply(palette: palette, styler: styler)
        textView.autoPair = settings.autoPair
        textView.isContinuousSpellCheckingEnabled = settings.spellCheck
        textView.focusMode = settings.focusMode
        textView.typewriterMode = settings.typewriterMode
        textView.contentWidth = settings.contentWidth
        scrollView.backgroundColor = palette.bg
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = palette.bg.cgColor
    }

    // MARK: Document

    var text: String { storage.string }
    var isDirty: Bool { text != savedText }
    var displayName: String { url?.lastPathComponent ?? "Untitled" }

    /// The note's title: front matter `title`, else its first heading, else the file name.
    var documentTitle: String {
        let text = self.text
        return noteTitle(text, fallback: url.map { $0.deletingPathExtension().lastPathComponent } ?? "Untitled", properties: parseFrontMatter(text).properties)
    }

    /// Open `url`. Throws if it cannot be read.
    func open(_ url: URL) throws {
        let contents = try FileOps.readText(url)
        self.url = url
        widgets.documentURL = url
        load(contents, modificationDate: FileOps.modificationDate(url))
        snapshot(reason: .open)
        textView.setSelectedRange(NSRange(location: initialCaret(contents), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Start an unsaved note with `contents`.
    func openUntitled(_ contents: String = "") {
        url = nil
        widgets.documentURL = nil
        load(contents, modificationDate: nil)
        savedText = ""
        onStateChange?()
    }

    /// The caret goes after the front matter and title heading, where writing continues.
    private func initialCaret(_ contents: String) -> Int {
        let split = splitFrontMatter(contents)
        return min(split.bodyOffset, (contents as NSString).length)
    }

    private func load(_ contents: String, modificationDate: Date?) {
        storage.load(contents)
        undo.removeAllActions()
        savedText = contents
        self.modificationDate = modificationDate
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.relayoutWidgets()
        updateCounts()
        updatePosition()
        onStateChange?()
    }

    /// Replace the text with what is on disk (after an outside edit).
    func reloadFromDisk() {
        guard let url, let contents = try? FileOps.readText(url) else { return }
        let caret = textView.selectedRange()
        load(contents, modificationDate: FileOps.modificationDate(url))
        let length = (contents as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
    }

    /// The file moved (rename, trash, restore): keep editing it at its new place.
    func fileMoved(to newURL: URL) {
        url = newURL
        widgets.documentURL = newURL
        modificationDate = FileOps.modificationDate(newURL)
        onStateChange?()
    }

    /// Check the file on disk; reload silently when there are no local edits.
    /// Returns true if the disk copy differs and the note has unsaved edits.
    @discardableResult
    func checkDisk() -> Bool {
        guard let url, !saving else { return false }
        guard let date = FileOps.modificationDate(url) else { return false }
        if let known = modificationDate, abs(date.timeIntervalSince(known)) <= 0.002 { return false }
        guard let contents = try? FileOps.readText(url) else { return false }
        if contents == savedText { modificationDate = date; return false }
        if !isDirty {
            reloadFromDisk()
            return false
        }
        return true
    }

    private func snapshot(reason: HistoryReason) {
        guard let url else { return }
        let text = self.text, library = libraryRoot, fallback = Self.historyFallbackRoot
        DispatchQueue.global(qos: .utility).async {
            _ = try? HistoryStore.record(file: url, text: text, libraryRoot: library, fallbackRoot: fallback, reason: reason)
        }
    }

    // MARK: Saving

    enum SaveResult { case saved, cancelled, failed }

    /// Save to the current file, or ask where when there is none (`saveAs` always asks).
    func save(manual: Bool, saveAs: Bool = false, completion: ((SaveResult) -> Void)? = nil) {
        guard !saving else { completion?(.cancelled); return }
        if saveAs || url == nil {
            chooseSaveLocation { [weak self] target in
                guard let self, let target else { completion?(.cancelled); return }
                completion?(self.write(to: target, manual: true))
            }
            return
        }
        completion?(write(to: url!, manual: manual))
    }

    private func chooseSaveLocation(_ done: @escaping (URL?) -> Void) {
        guard let window = view.window else { done(nil); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.allowsOtherFileTypes = true
        let suggested = url?.lastPathComponent ?? (FileOps.safeName(String(documentTitle.prefix(60))) + ".md")
        panel.nameFieldStringValue = suggested
        if let directory = url?.deletingLastPathComponent() ?? libraryRoot?.appendingPathComponent("Notes") { panel.directoryURL = directory }
        panel.beginSheetModal(for: window) { response in
            done(response == .OK ? panel.url : nil)
        }
    }

    private func write(to target: URL, manual: Bool) -> SaveResult {
        saving = true
        defer { saving = false }
        let text = self.text
        let samePlace = url.map { $0.standardizedFileURL == target.standardizedFileURL } ?? false
        do {
            if samePlace {
                try FileOps.replaceFile(target, text: text, expectedModificationDate: modificationDate)
            } else if FileManager.default.fileExists(atPath: target.path) {
                try FileOps.replaceFile(target, text: text)
            } else {
                try FileOps.writeNewFile(target, text: text)
            }
        } catch FileOpsError.changedOnDisk {
            resolveConflict()
            return .failed
        } catch {
            presentError(error, title: "Save failed")
            return .failed
        }
        url = target
        widgets.documentURL = target
        savedText = text
        modificationDate = FileOps.modificationDate(target)
        snapshot(reason: manual ? .save : .autosave)
        onStateChange?()
        onSaved?(target, manual)
        return .saved
    }

    /// The file was changed by another device or app since it was opened.
    private func resolveConflict() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "File changed on disk"
        alert.informativeText = "“\(displayName)” was saved by another device or app. Reload it, or save your draft as a separate file."
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Save a Copy…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.reloadFromDisk()
            case .alertSecondButtonReturn: self?.save(manual: true, saveAs: true)
            default: break
            }
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        onStateChange?()
        scheduleCounts()
        autoSaveTimer?.invalidate()
        guard AppSettings.shared.autoSave, url != nil else { return }
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.isDirty, self.view.window != nil else { return }
            self.save(manual: false)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updatePosition()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: Status bar

    private func scheduleCounts() {
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.updateCounts() }
    }

    private static let wordRx = Rx("[\\p{L}\\p{N}'’\\-]+")

    func updateCounts() {
        let text = self.text
        let words = Self.wordRx.matches(text).count
        let characters = (text as NSString).length
        let noSpaces = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        let lines = text.isEmpty ? 1 : text.components(separatedBy: "\n").count
        func format(_ value: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) }
        let labels: [String] = [
            format(words) + (words == 1 ? " word" : " words"),
            format(characters) + " characters",
            format(noSpaces) + " chars (no spaces)",
            format(lines) + (lines == 1 ? " line" : " lines"),
        ]
        wordsButton.title = labels[wordMode % 4]
        readingLabel.stringValue = words > 0 ? "\(max(1, Int((Double(words) / 220).rounded()))) min read" : ""
        pathLabel.stringValue = url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
    }

    @objc private func cycleWordMode() {
        wordMode += 1
        updateCounts()
    }

    func updatePosition() {
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        let caret = min(selection.location, text.length)
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: lineStart), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let column = caret - lineStart + 1
        let selected = textView.selectedRanges.reduce(0) { $0 + $1.rangeValue.length }
        positionLabel.stringValue = selected > 0 ? "\(selected) selected" : "Ln \(line), Col \(column)"
    }

    // MARK: Outline

    var headings: [MDHeading] { storage.document.headings }

    func reveal(offset: Int, length: Int = 0) {
        view.window?.makeFirstResponder(textView)
        textView.reveal(NSRange(location: offset, length: length))
    }
}
