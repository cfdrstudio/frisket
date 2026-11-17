import AppKit
import FrisketBase
import FrisketLibrary

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelect filter: LibraryFilter)
    func sidebar(_ sidebar: SidebarViewController, didSelectSearch query: String)
}

/// The library source list: Notes, Untagged, Todo, Pinned, Trash, the tag tree and saved searches.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Item: NSObject {
        enum Kind { case section, filter(LibraryFilter), tag(String), search(String) }
        let kind: Kind
        let title: String
        let symbol: String?
        var count: Int?
        var children: [Item] = []
        init(_ kind: Kind, _ title: String, symbol: String? = nil, count: Int? = nil) {
            self.kind = kind
            self.title = title
            self.symbol = symbol
            self.count = count
        }
        var isSection: Bool { if case .section = kind { return true }; return false }
    }

    weak var delegate: SidebarDelegate?
    private let outline = NSOutlineView()
    private let header = NSTextField(labelWithString: "No library")
    private let syncButton = NSButton(title: "", target: nil, action: nil)
    private var roots: [Item] = []
    private var expandedTags = Set<String>()
    private(set) var selection: LibraryFilter = .notes
    private var selectedSearch: String?
    private var observers: [NSObjectProtocol] = []

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.addTableColumn(NSTableColumn(identifier: .init("main")))
        outline.dataSource = self
        outline.delegate = self
        outline.autosaveExpandedItems = false
        outline.menu = NSMenu()
        outline.menu?.delegate = self

        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.lineBreakMode = .byTruncatingMiddle
        let open = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Open library")!, target: nil, action: #selector(AppDelegate.openLibrary(_:)))
        open.isBordered = false
        open.toolTip = "Open a folder as your library"
        syncButton.isBordered = false
        syncButton.font = .systemFont(ofSize: 11)
        syncButton.contentTintColor = .secondaryLabelColor
        syncButton.imagePosition = .imageLeading
        syncButton.action = #selector(MainWindowController.showSync(_:))
        let top = NSStackView(views: [header, open])
        top.spacing = 6
        let headerStack = NSStackView(views: [top, syncButton])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 10)

        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        for view in [headerStack, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            top.widthAnchor.constraint(equalTo: headerStack.widthAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .frisketLibraryChanged, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        observers.append(center.addObserver(forName: .frisketLibraryOpened, object: nil, queue: .main) { [weak self] _ in
            self?.selection = .notes
            self?.reload()
        })
        observers.append(center.addObserver(forName: .frisketSettingsChanged, object: nil, queue: .main) { [weak self] note in
            if note.userInfo?["key"] as? String == "savedSearches" { self?.reload() }
        })
        reload()
    }

    // MARK: Model

    func reload() {
        let library = MainActor.assumeIsolated { LibraryController.current }
        let snapshot = MainActor.assumeIsolated { library?.snapshot }
        header.stringValue = library?.name ?? "No library"
        header.toolTip = library?.root.path
        updateSyncLabel(library?.root, conflicts: snapshot?.conflicts ?? 0)
        let summaries = snapshot?.summaries ?? []
        let active = summaries.filter { !$0.isTrashed }
        func count(_ filter: LibraryFilter) -> Int { filter.filter(summaries).count }
        let library_ = Item(.section, "Library")
        library_.children = [
            Item(.filter(.notes), "Notes", symbol: "note.text", count: active.count),
            Item(.filter(.pinned), "Pinned", symbol: "pin", count: count(.pinned)),
            Item(.filter(.untagged), "Untagged", symbol: "tag.slash", count: count(.untagged)),
            Item(.filter(.todo), "Todo", symbol: "checklist", count: count(.todo)),
            Item(.filter(.trash), "Trash", symbol: "trash", count: count(.trash)),
        ]
        roots = [library_]
        if let tags = snapshot?.tags, !tags.isEmpty {
            let section = Item(.section, "Tags")
            section.children = tagTree(tags)
            roots.append(section)
        }
        let searches = AppSettings.shared.savedSearches
        if !searches.isEmpty {
            let section = Item(.section, "Saved Searches")
            section.children = searches.map { Item(.search($0), $0, symbol: "magnifyingglass") }
            roots.append(section)
        }
        outline.reloadData()
        for item in roots { outline.expandItem(item) }
        expandTags(in: roots)
        restoreSelection()
    }

    private func updateSyncLabel(_ root: URL?, conflicts: Int) {
        guard let root else { syncButton.isHidden = true; return }
        syncButton.isHidden = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let provider = SyncProvidersBridge.providerLabel(for: root)
            DispatchQueue.main.async {
                guard let self else { return }
                let label = provider.map { "Synced · \($0)" } ?? "Only on this Mac"
                self.syncButton.title = label + (conflicts > 0 ? "  ·  \(conflicts) conflict\(conflicts == 1 ? "" : "s")" : "")
                self.syncButton.image = NSImage(systemSymbolName: provider == nil ? "desktopcomputer" : "icloud", accessibilityDescription: nil)
                self.syncButton.contentTintColor = conflicts > 0 ? .systemOrange : .secondaryLabelColor
                self.syncButton.toolTip = provider == nil
                    ? "This library is only on this computer. Click to set up sync."
                    : "This library is in \(provider!), so it syncs to your other devices."
            }
        }
    }

    /// `work/projects` nests under `work`.
    private func tagTree(_ tags: [FrisketLibrary.TagCount]) -> [Item] {
        var nodes: [String: Item] = [:]
        var top: [Item] = []
        for tag in tags.sorted(by: { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }) {
            let parts = tag.tag.split(separator: "/").map(String.init)
            var path = ""
            var parent: Item?
            for (index, part) in parts.enumerated() {
                path = path.isEmpty ? part : path + "/" + part
                if let existing = nodes[path] {
                    parent = existing
                    if index == parts.count - 1 { existing.count = tag.count }
                    continue
                }
                let node = Item(.tag(path), part, symbol: "number", count: index == parts.count - 1 ? tag.count : nil)
                nodes[path] = node
                if let parent { parent.children.append(node) } else { top.append(node) }
                parent = node
            }
        }
        return top
    }

    private func expandTags(in items: [Item]) {
        for item in items {
            if case .tag(let path) = item.kind, expandedTags.contains(path) { outline.expandItem(item) }
            expandTags(in: item.children)
        }
    }

    private func restoreSelection() {
        func find(_ items: [Item]) -> Item? {
            for item in items {
                switch item.kind {
                case .filter(let filter) where selectedSearch == nil && filter == selection: return item
                case .tag(let tag) where selectedSearch == nil && selection == .tag(tag): return item
                case .search(let query) where selectedSearch == query: return item
                default: break
                }
                if let found = find(item.children) { return found }
            }
            return nil
        }
        guard let item = find(roots) else { return }
        let row = outline.row(forItem: item)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    func select(_ filter: LibraryFilter) {
        selection = filter
        selectedSearch = nil
        restoreSelection()
        delegate?.sidebar(self, didSelect: filter)
    }

    // MARK: Outline view

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Item)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? Item)?.isSection ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        if item.isSection {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            cell.textField = label
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.symbol ?? "circle", accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: item.title)
        label.lineBreakMode = .byTruncatingTail
        let badge = NSTextField(labelWithString: item.count.map(String.init) ?? "")
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badge.textColor = .tertiaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.imageView = image
        cell.textField = label
        for view in [image, label, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
        switch item.kind {
        case .filter(let filter):
            selection = filter
            selectedSearch = nil
            delegate?.sidebar(self, didSelect: filter)
        case .tag(let tag):
            selection = .tag(tag)
            selectedSearch = nil
            delegate?.sidebar(self, didSelect: .tag(tag))
        case .search(let query):
            selectedSearch = query
            delegate?.sidebar(self, didSelectSearch: query)
        case .section:
            break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item, case .tag(let path) = item.kind { expandedTags.insert(path) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item, case .tag(let path) = item.kind { expandedTags.remove(path) }
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? Item else { return }
        if case .search(let query) = item.kind {
            let remove = NSMenuItem(title: "Remove Saved Search", action: #selector(removeSearch(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = query
            menu.addItem(remove)
        }
        if case .filter(.trash) = item.kind {
            let empty = NSMenuItem(title: "Empty Trash…", action: #selector(MainWindowController.emptyTrash(_:)), keyEquivalent: "")
            menu.addItem(empty)
        }
    }

    @objc private func removeSearch(_ sender: NSMenuItem) {
        guard let query = sender.representedObject as? String else { return }
        AppSettings.shared.savedSearches.removeAll { $0 == query }
    }
}
