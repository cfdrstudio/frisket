import AppKit
import FrisketBase
import FrisketLibrary

protocol NoteListDelegate: AnyObject {
    /// Open a note; `match` is the offset of a search hit to reveal.
    func noteList(_ list: NoteListViewController, open url: URL, match: Int?)
    func noteList(_ list: NoteListViewController, perform action: NoteListViewController.Action, on note: NoteSummary)
}

/// The middle column: the notes in the selected view, newest first, with a search field.
final class NoteListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    enum Action { case pin, unpin, trash, restore, delete, history, reveal, copyLink, resolveConflict }

    weak var delegate: NoteListDelegate?
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let titleLabel = NSTextField(labelWithString: "Notes")
    private let countLabel = NSTextField(labelWithString: "")
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")

    private(set) var filter: LibraryFilter = .notes
    private var notes: [NoteSummary] = []
    private var matches: [String: SearchMatch] = [:]
    private var terms: [String] = []
    private var searchGeneration = 0
    private var searchTimer: Timer?
    private var activePath: String?
    private var observers: [NSObjectProtocol] = []
    private var suppressSelection = false

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces) }

    override func loadView() {
        let root = NSView()
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        sortPopup.addItems(withTitles: ["Modified", "Created", "Title"])
        sortPopup.controlSize = .small
        sortPopup.font = .systemFont(ofSize: 11)
        sortPopup.isBordered = false
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        sortPopup.selectItem(at: ["modified", "created", "title"].firstIndex(of: AppSettings.shared.librarySort) ?? 0)
        searchField.placeholderString = "Search notes  (#tag  @todo  @images)"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        let save = NSButton(image: NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Save search")!, target: self, action: #selector(saveSearch))
        save.isBordered = false
        save.toolTip = "Save this search to the sidebar"

        let titles = NSStackView(views: [titleLabel, countLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        let head = NSStackView(views: [titles, NSView(), sortPopup])
        head.spacing = 6
        let searchRow = NSStackView(views: [searchField, save])
        searchRow.spacing = 4

        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("note")))
        table.style = .inset
        table.usesAutomaticRowHeights = false
        table.rowHeight = 84
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .systemOrange
        notice.isHidden = true

        for view in [head, searchRow, notice, scroll, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            searchRow.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            notice.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 6),
            notice.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            notice.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -40),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        view = root
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .frisketLibraryChanged, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        observers.append(center.addObserver(forName: .frisketLibraryOpened, object: nil, queue: .main) { [weak self] _ in
            self?.searchField.stringValue = ""
            self?.filter = .notes
            self?.reload()
        })
        reload()
    }

    // MARK: Model

    func show(_ filter: LibraryFilter) {
        self.filter = filter
        reload()
    }

    func search(_ query: String) {
        searchField.stringValue = query
        reload()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func setActive(_ url: URL?) {
        activePath = url.map { realPath($0) }
        selectActiveRow()
    }

    private func realPath(_ url: URL) -> String { url.canonicalPath }

    private var sortMode: LibrarySort {
        switch AppSettings.shared.librarySort {
        case "created": return .created
        case "title": return .title
        default: return .modified
        }
    }

    private var filterTitle: String {
        switch filter {
        case .notes: return "Notes"
        case .untagged: return "Untagged"
        case .todo: return "Todo"
        case .pinned: return "Pinned"
        case .trash: return "Trash"
        case .tag(let tag): return "#" + tag
        case .folder(let folder): return folder.isEmpty ? "Notes" : folder
        }
    }

    func reload() {
        let library = MainActor.assumeIsolated { LibraryController.current }
        guard let library else {
            notes = []
            table.reloadData()
            titleLabel.stringValue = "Notes"
            countLabel.stringValue = ""
            emptyLabel.stringValue = "Open a folder to use it as a Frisket library.\nYour Markdown files stay where they are."
            emptyLabel.isHidden = false
            notice.isHidden = true
            return
        }
        let snapshot = MainActor.assumeIsolated { library.snapshot }
        notice.isHidden = !(snapshot?.truncated ?? false)
        notice.stringValue = "Some notes are not shown: Frisket indexes up to \(library.index.limits.maxFiles) notes, \(library.index.limits.maxDepth) folders deep."
        let query = self.query
        if query.isEmpty {
            searchGeneration += 1
            matches = [:]
            terms = []
            let filtered = filter.filter(snapshot?.summaries ?? [])
            let sorted = sortMode.sorted(filtered)
            // Pinned notes stay on top, in sort order.
            notes = sorted.filter(\.pinned) + sorted.filter { !$0.pinned }
            render()
            return
        }
        searchTimer?.invalidate()
        searchGeneration += 1
        let generation = searchGeneration
        let includeTrashed = filter == .trash
        let filter = self.filter
        Task { @MainActor [weak self] in
            let results = await library.query { await $0.search(query: query, includeTrashed: includeTrashed) }
            guard let self, generation == self.searchGeneration else { return }
            let hits = results.notes.filter { filter.matches($0.summary) }
            self.notes = hits.map(\.summary)
            self.matches = Dictionary(hits.compactMap { hit in hit.match.map { (hit.summary.path, $0) } }, uniquingKeysWith: { a, _ in a })
            self.terms = results.terms
            self.render()
        }
    }

    private func render() {
        suppressSelection = true
        table.reloadData()
        suppressSelection = false
        let searching = !query.isEmpty
        titleLabel.stringValue = searching ? "Search" : filterTitle
        let count = notes.count
        countLabel.stringValue = searching
            ? "\(count) \(count == 1 ? "result" : "results") in \(filterTitle)"
            : (count == 0 ? "" : "\(count) \(count == 1 ? "note" : "notes")")
        emptyLabel.isHidden = count > 0
        emptyLabel.stringValue = searching ? "No notes match “\(query)”." : "No notes in this view yet."
        selectActiveRow()
    }

    private func selectActiveRow() {
        guard let activePath, let index = notes.firstIndex(where: { $0.path == activePath }) else {
            suppressSelection = true
            table.deselectAll(nil)
            suppressSelection = false
            return
        }
        suppressSelection = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        suppressSelection = false
    }

    // MARK: Actions

    @objc private func sortChanged() {
        AppSettings.shared.librarySort = ["modified", "created", "title"][max(0, sortPopup.indexOfSelectedItem)]
        reload()
    }

    @objc private func searchChanged() {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in self?.reload() }
    }

    func controlTextDidChange(_ obj: Notification) { searchChanged() }

    @objc private func saveSearch() {
        let query = self.query
        guard !query.isEmpty else { NSSound.beep(); return }
        var searches = AppSettings.shared.savedSearches
        if !searches.contains(query) { searches.append(query); AppSettings.shared.savedSearches = searches }
    }

    @objc private func rowClicked() {
        openSelected()
    }

    private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < notes.count else { return }
        let note = notes[row]
        if note.conflict != nil {
            delegate?.noteList(self, perform: .resolveConflict, on: note)
            return
        }
        delegate?.noteList(self, open: note.url, match: matches[note.path]?.pos)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        // Keyboard navigation opens notes as the selection moves, like Notes and Bear.
        if NSApp.currentEvent?.type == .keyDown { openSelected() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: NoteCell.identifier, owner: nil) as? NoteCell) ?? NoteCell()
        let note = notes[row]
        cell.configure(note, match: matches[note.path], terms: terms)
        return cell
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < notes.count else { return }
        let note = notes[row]
        func add(_ title: String, _ action: Action) {
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (action, note)
            menu.addItem(item)
        }
        let open = NSMenuItem(title: "Open", action: #selector(contextOpen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = note
        menu.addItem(open)
        if note.isTrashed {
            add("Restore Note", .restore)
            menu.addItem(.separator())
            add("Delete Permanently…", .delete)
            return
        }
        if note.conflict != nil {
            add("Resolve Conflict…", .resolveConflict)
            return
        }
        add(note.pinned ? "Unpin" : "Pin to Top", note.pinned ? .unpin : .pin)
        add("Version History…", .history)
        add("Copy Link", .copyLink)
        add("Show in Finder", .reveal)
        menu.addItem(.separator())
        add("Move to Trash", .trash)
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let note = sender.representedObject as? NoteSummary else { return }
        delegate?.noteList(self, open: note.url, match: nil)
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let (action, note) = sender.representedObject as? (Action, NoteSummary) else { return }
        delegate?.noteList(self, perform: action, on: note)
    }

    /// The note under the keyboard selection, for menu commands.
    var selectedNote: NoteSummary? {
        table.selectedRow >= 0 && table.selectedRow < notes.count ? notes[table.selectedRow] : nil
    }
}

/// A note card: title, excerpt (or the search hit), date and task progress.
final class NoteCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NoteCell")
    private let title = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")!)
    private let thumbnail = NSImageView()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        excerpt.font = .systemFont(ofSize: 12)
        excerpt.textColor = .secondaryLabelColor
        excerpt.maximumNumberOfLines = 2
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.cell?.truncatesLastVisibleLine = true
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .tertiaryLabelColor
        pin.contentTintColor = .controlAccentColor
        pin.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.masksToBounds = true
        let titleRow = NSStackView(views: [pin, title])
        titleRow.spacing = 4
        let text = NSStackView(views: [titleRow, excerpt, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [text, thumbnail])
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumbnail.widthAnchor.constraint(equalToConstant: 48),
            thumbnail.heightAnchor.constraint(equalToConstant: 48),
            excerpt.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        excerpt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ note: NoteSummary, match: SearchMatch?, terms: [String]) {
        title.stringValue = note.title.isEmpty ? (note.name.isEmpty ? "Untitled" : note.name) : note.title
        pin.isHidden = !note.pinned
        if let match {
            let text = NSMutableAttributedString(string: match.text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            let ns = match.text as NSString
            for term in terms where !term.isEmpty {
                var search = NSRange(location: 0, length: ns.length)
                while true {
                    let found = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    if found.location == NSNotFound { break }
                    text.addAttributes([.foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.45)], range: found)
                    search = NSRange(location: found.location + found.length, length: ns.length - found.location - found.length)
                }
            }
            excerpt.attributedStringValue = text
        } else {
            excerpt.stringValue = note.excerpt.isEmpty ? "Empty note" : note.excerpt
        }
        var parts = [Self.relative.localizedString(for: note.trashedAt ?? note.modifiedAt, relativeTo: Date())]
        if note.tasksTotal > 0 { parts.append("☑ \(note.tasksDone)/\(note.tasksTotal)") }
        if !note.tags.isEmpty { parts.append(note.tags.prefix(3).map { "#" + $0 }.joined(separator: " ")) }
        if let conflict = note.conflict { parts.append("⚠︎ " + conflict.kind.rawValue) }
        meta.stringValue = parts.joined(separator: "  ·  ")
        thumbnail.isHidden = true
        thumbnail.image = nil
        if let reference = note.imagePreview {
            let path = note.path
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let image = NoteCell.thumbnail(reference, notePath: path)
                DispatchQueue.main.async {
                    guard let self, let image else { return }
                    self.thumbnail.image = image
                    self.thumbnail.isHidden = false
                }
            }
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    private static func thumbnail(_ reference: String, notePath: String) -> NSImage? {
        guard !reference.hasPrefix("http"), !reference.hasPrefix("data:") else { return nil }
        let decoded = reference.removingPercentEncoding ?? reference
        let base = URL(fileURLWithPath: notePath).deletingLastPathComponent()
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : base.appendingPathComponent(decoded).standardized
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: 48, height: 48))
        cache.setObject(image, forKey: key)
        return image
    }
}
