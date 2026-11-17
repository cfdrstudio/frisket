import AppKit
import FrisketLibrary
import FrisketServices

/// Style check: a floating panel (the editor stays usable) listing advisory findings.
@MainActor
final class StyleCheckPanel: PanelController {
    private weak var textView: MarkdownTextView?
    private let list = ListTable(rowHeight: 44)
    private let summary = UI.label("Checking\u{2026}", color: .secondaryLabelColor)
    private var findings: [StyleFinding] = []
    private var findingTexts: [String] = []
    private var generation = 0
    private var observer: NSObjectProtocol?
    private static var current: StyleCheckPanel?

    static func show(textView: MarkdownTextView, parent: NSWindow) {
        if let existing = current, existing.textView === textView {
            existing.window.makeKeyAndOrderFront(nil)
            existing.analyse()
            return
        }
        current?.dismiss()
        let panel = StyleCheckPanel(textView: textView)
        current = panel
        panel.present(on: nil)
        let frame = parent.frame
        panel.window.setFrameOrigin(NSPoint(x: frame.maxX - panel.window.frame.width - 24, y: frame.maxY - panel.window.frame.height - 70))
        panel.analyse()
    }

    private init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(title: "Style Check", size: NSSize(width: 380, height: 460), floating: true, minSize: NSSize(width: 320, height: 300))
        onClose = { [weak self] in
            if let observer = self?.observer { NotificationCenter.default.removeObserver(observer) }
            if StyleCheckPanel.current === self { StyleCheckPanel.current = nil }
        }
        buildUI()
        observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAnalyse() }
        }
    }

    private var debounce: Timer?

    private func scheduleAnalyse() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.analyse() }
        }
    }

    private func buildUI() {
        list.onSelect = { [weak self] index in
            guard let self, let index, self.findings.indices.contains(index) else { return }
            self.textView?.reveal(self.findings[index].range)
        }
        list.onDoubleClick = { [weak self] index in self?.apply(index) }
        let close = UI.button("Close", key: "\u{1b}") { [weak self] in self?.dismiss() }
        let applyAll = UI.button("Apply All Suggestions") { [weak self] in self?.applyAll() }
        list.scrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        install(UI.vstack([UI.heading("Style Check"), summary, list.scrollView, UI.buttonRow([close, applyAll])], spacing: 10, alignment: .width))
    }

    func analyse() {
        guard let textView else { return }
        generation += 1
        let token = generation
        let text = textView.string
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { StyleCheck.analyze(text) }.value
            guard let self, token == self.generation else { return }
            self.show(found, in: text)
        }
    }

    private func show(_ found: [StyleFinding], in text: String) {
        findings = found
        let ns = text as NSString
        var texts: [String] = []
        for finding in found {
            let range = finding.range
            texts.append(NSMaxRange(range) <= ns.length ? ns.substring(with: range) : "")
        }
        findingTexts = texts
        if found.isEmpty {
            summary.stringValue = "No repeated words or wordy phrases found."
        } else {
            summary.stringValue = "\(found.count) suggestion\(found.count == 1 ? "" : "s"). Click one to see it in the note."
        }
        var rows: [ListTable.Row] = []
        for (index, finding) in found.enumerated() {
            let quoted: String = "\u{201C}" + texts[index].replacingOccurrences(of: "\n", with: " ") + "\u{201D}"
            var detail = quoted
            var row = ListTable.Row(title: finding.message, detail: quoted)
            if let suggestion = finding.suggestion {
                detail = quoted + " \u{2192} \u{201C}" + suggestion + "\u{201D}"
                row.detail = detail
                row.action = (title: "Apply", handler: { [weak self] in self?.apply(index) })
            }
            rows.append(row)
        }
        list.rows = rows
    }

    private func apply(_ index: Int) {
        guard let textView, findings.indices.contains(index), let suggestion = findings[index].suggestion else { return }
        let range = findings[index].range
        let ns = textView.nsString
        // The note may have changed since the analysis; only replace text that still matches.
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == findingTexts[index] else {
            analyse()
            return
        }
        textView.edit([(range: range, text: suggestion)])
        analyse()
    }

    private func applyAll() {
        guard let textView else { return }
        let ns = textView.nsString
        var changes: [(range: NSRange, text: String)] = []
        var lastEnd = 0
        for (index, finding) in findings.enumerated().sorted(by: { $0.element.from < $1.element.from }) {
            guard let suggestion = finding.suggestion, finding.from >= lastEnd,
                  NSMaxRange(finding.range) <= ns.length, ns.substring(with: finding.range) == findingTexts[index] else { continue }
            changes.append((range: finding.range, text: suggestion))
            lastEnd = NSMaxRange(finding.range)
        }
        guard !changes.isEmpty else { NSSound.beep(); return }
        textView.edit(changes)
        analyse()
    }
}

/// Attachment audit: missing attachments referenced by notes in the library.
@MainActor
final class AttachmentAuditPanel: PanelController {
    struct Missing: Sendable {
        var noteTitle: String
        var noteURL: URL
        var reference: String
        var reason: String?
    }
    struct Result: Sendable {
        var notes: Int
        var referenced: Int
        var missing: [Missing]
    }

    private let library: LibraryController
    private let open: (URL) -> Void
    private let list = ListTable(rowHeight: 44)
    private let summary = UI.label("Scanning notes with images and attachments\u{2026}", color: .secondaryLabelColor, wraps: true)
    private var missing: [Missing] = []

    static func show(library: LibraryController, parent: NSWindow, open: @escaping (URL) -> Void) {
        let panel = AttachmentAuditPanel(library: library, open: open)
        panel.present(on: parent)
        panel.scan()
    }

    private init(library: LibraryController, open: @escaping (URL) -> Void) {
        self.library = library
        self.open = open
        super.init(title: "Attachment Audit", size: NSSize(width: 640, height: 460), minSize: NSSize(width: 480, height: 320))
        let close = UI.button("Close", key: "\u{1b}") { [weak self] in self?.dismiss() }
        close.keyEquivalent = "\u{1b}"
        list.onDoubleClick = { [weak self] index in
            guard let self, self.missing.indices.contains(index) else { return }
            let url = self.missing[index].noteURL
            self.dismiss()
            self.open(url)
        }
        list.scrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        install(UI.vstack([
            UI.heading("Attachment Audit"),
            UI.secondary("Images and files linked from notes in this library. Double-click a row to open the note."),
            summary, list.scrollView, UI.buttonRow([close]),
        ], spacing: 10, alignment: .width))
    }

    private func scan() {
        let notes = (library.snapshot?.summaries ?? []).filter { ($0.hasImages || $0.hasAttachments) && !$0.isTrashed }
            .map { (title: $0.title, url: $0.url) }
        Task { [weak self, library] in
            let result = await library.query { index -> Result in
                var referenced = 0
                var missing: [Missing] = []
                for note in notes {
                    guard let context = await index.context(for: note.url) else { continue }
                    referenced += context.attachments.referenced.count
                    for item in context.attachments.missing {
                        missing.append(Missing(noteTitle: note.title, noteURL: note.url, reference: item.reference, reason: item.reason))
                    }
                }
                return Result(notes: notes.count, referenced: referenced, missing: missing)
            }
            self?.show(result)
        }
    }

    private func show(_ result: Result) {
        missing = result.missing
        let total = result.referenced + result.missing.count
        summary.stringValue = "\(result.notes) note\(result.notes == 1 ? "" : "s") with attachments \u{00B7} \(total) reference\(total == 1 ? "" : "s") \u{00B7} \(result.referenced) found \u{00B7} \(result.missing.count) missing."
        if result.missing.isEmpty {
            summary.stringValue += " Everything resolves."
        }
        list.rows = result.missing.map {
            let why = $0.reason == "outside-workspace" ? "Outside the library folder" : "File not found"
            return ListTable.Row(title: $0.reference, detail: "\($0.noteTitle) \u{00B7} \(why)", color: .systemRed)
        }
    }
}
