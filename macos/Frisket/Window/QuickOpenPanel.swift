import AppKit
import FrisketBase
import FrisketLibrary

/// ⌘P: type part of a title, path or alias and press Return.
@MainActor
final class QuickOpenPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private static var current: QuickOpenPanel?

    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [NoteSummary] = []
    private var shown: [NoteSummary] = []
    private var onOpen: ((URL) -> Void)?

    static func show(in window: NSWindow, library: LibraryController?, open: @escaping (URL) -> Void) {
        current?.close()
        guard let library, let snapshot = library.snapshot else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "md")!, .plainText]
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { open(url) } }
            return
        }
        let quick = QuickOpenPanel()
        quick.onOpen = open
        quick.all = LibrarySort.modified.sorted(snapshot.summaries.filter { !$0.isTrashed })
        quick.filter()
        current = quick
        let frame = window.frame
        quick.panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - 280, y: frame.maxY - 90))
        quick.panel.makeKeyAndOrderFront(nil)
        quick.panel.makeFirstResponder(quick.field)
    }

    private override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        field.placeholderString = "Open note…"
        field.font = .systemFont(ofSize: 18)
        field.focusRingType = .none
        field.delegate = self
        field.controlSize = .large
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("note")))
        table.rowHeight = 40
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        for view in [field, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])
        panel.contentView = effect
    }

    private func filter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? Array(all.prefix(200)) : Array(filterNotes(all, query: query).prefix(200))
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { NSSound.beep(); return }
        let url = shown[row].url
        let open = onOpen
        close()
        open?(url)
    }

    private func close() {
        panel.orderOut(nil)
        if QuickOpenPanel.current === self { QuickOpenPanel.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = shown[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: note.title.isEmpty ? note.name : note.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: note.relative)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
