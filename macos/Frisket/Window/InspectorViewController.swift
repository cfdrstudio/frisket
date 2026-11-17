import AppKit
import FrisketBase
import FrisketMarkdown
import FrisketLibrary

protocol InspectorDelegate: AnyObject {
    func inspector(_ inspector: InspectorViewController, revealOffset offset: Int)
    func inspector(_ inspector: InspectorViewController, open url: URL, at offset: Int?)
    func inspector(_ inspector: InspectorViewController, link mention: UnlinkedMention)
}

/// The right-hand panel: the note's outline, its backlinks and its details.
final class InspectorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Tab: Int { case outline, backlinks, info }

    private enum Row {
        case heading(MDHeading)
        case section(String)
        case linked(LinkedBacklink)
        case unlinked(UnlinkedMention)
        case info(String, String)
        case message(String)
    }

    weak var delegate: InspectorDelegate?
    private let segmented = NSSegmentedControl(labels: ["Outline", "Backlinks", "Info"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private var rows: [Row] = []
    private(set) var tab: Tab = .outline
    private var headings: [MDHeading] = []
    private var context: NoteContext?
    private var info: [(String, String)] = []
    private var currentHeading = -1

    override func loadView() {
        let root = NSView()
        segmented.target = self
        segmented.action = #selector(tabChanged)
        segmented.selectedSegment = 0
        segmented.segmentStyle = .automatic
        segmented.controlSize = .small
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.selectionHighlightStyle = .regular
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for view in [segmented, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            segmented.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func show(_ tab: Tab) {
        self.tab = tab
        segmented.selectedSegment = tab.rawValue
        rebuild()
    }

    @objc private func tabChanged() {
        tab = Tab(rawValue: segmented.selectedSegment) ?? .outline
        rebuild()
    }

    // MARK: Updates

    func update(headings: [MDHeading], caret: Int) {
        let current = headings.lastIndex { $0.range.location <= caret } ?? -1
        let changed = headings != self.headings
        self.headings = headings
        if tab == .outline {
            if changed { rebuild() }
            if current != currentHeading || changed {
                currentHeading = current
                if current >= 0 { table.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false); table.scrollRowToVisible(current) }
                else { table.deselectAll(nil) }
            }
        }
    }

    func update(context: NoteContext?, info: [(String, String)]) {
        self.context = context
        self.info = info
        if tab != .outline { rebuild() }
    }

    private func rebuild() {
        switch tab {
        case .outline:
            rows = headings.isEmpty ? [.message("Headings in this note appear here.")] : headings.map { .heading($0) }
        case .backlinks:
            guard let context else {
                rows = [.message(LibraryControllerCheck.hasLibrary ? "Save the note in the library to see its backlinks." : "Open a library to see backlinks.")]
                break
            }
            var result: [Row] = [.section("Linked mentions (\(context.backlinks.linked.count))")]
            result += context.backlinks.linked.isEmpty ? [.message("No notes link here yet.")] : context.backlinks.linked.map { .linked($0) }
            result.append(.section("Unlinked mentions (\(context.backlinks.unlinked.count))"))
            result += context.backlinks.unlinked.isEmpty ? [.message("No other notes mention this title.")] : context.backlinks.unlinked.map { .unlinked($0) }
            rows = result
        case .info:
            var result: [Row] = info.map { .info($0.0, $0.1) }
            if let context {
                let properties = context.properties.filter { !$0.key.hasPrefix("frisket-") }.sorted { $0.key < $1.key }
                if !properties.isEmpty {
                    result.append(.section("Properties"))
                    result += properties.map { .info($0.key, $0.value.text) }
                }
                let attachments = context.attachments
                if !attachments.referenced.isEmpty || !attachments.missing.isEmpty {
                    result.append(.section("Attachments"))
                    result += attachments.referenced.map { .info(($0.reference as NSString).lastPathComponent, ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)) }
                    result += attachments.missing.map { .info(($0.reference as NSString).lastPathComponent, "⚠︎ " + ($0.reason ?? "missing")) }
                }
            }
            rows = result
        }
        table.reloadData()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .heading, .linked, .unlinked: return true
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        var leading: CGFloat = 12
        func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, wrap: Bool = false) -> NSTextField {
            let field = wrap ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
            if wrap { field.maximumNumberOfLines = 3 }
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        switch rows[row] {
        case .heading(let heading):
            leading += CGFloat(max(0, heading.level - 1)) * 12
            stack.addArrangedSubview(label(heading.text.isEmpty ? "Untitled" : heading.text, weight: heading.level <= 2 ? .medium : .regular,
                                           color: heading.level <= 2 ? .labelColor : .secondaryLabelColor))
        case .section(let title):
            stack.addArrangedSubview(label(title.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor))
        case .linked(let link):
            stack.addArrangedSubview(label(link.title, weight: .medium))
            stack.addArrangedSubview(label(link.excerpt, size: 11, color: .secondaryLabelColor, wrap: true))
        case .unlinked(let mention):
            let title = label(mention.title, weight: .medium)
            let button = NSButton(title: "Link", target: self, action: #selector(linkMention(_:)))
            button.controlSize = .small
            button.bezelStyle = .inline
            button.tag = row
            let top = NSStackView(views: [title, button])
            top.spacing = 6
            stack.addArrangedSubview(top)
            stack.addArrangedSubview(label(mention.excerpt, size: 11, color: .secondaryLabelColor, wrap: true))
        case .info(let key, let value):
            stack.addArrangedSubview(label(key, size: 10, weight: .semibold, color: .secondaryLabelColor))
            stack.addArrangedSubview(label(value, wrap: true))
        case .message(let text):
            stack.addArrangedSubview(label(text, size: 11, color: .tertiaryLabelColor, wrap: true))
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: cell.widthAnchor, constant: -leading - 10),
        ])
        return cell
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .heading(let heading): delegate?.inspector(self, revealOffset: heading.range.location)
        case .linked(let link): delegate?.inspector(self, open: link.url, at: link.pos)
        case .unlinked(let mention): delegate?.inspector(self, open: mention.url, at: mention.pos)
        default: break
        }
    }

    @objc private func linkMention(_ sender: NSButton) {
        guard sender.tag < rows.count, case .unlinked(let mention) = rows[sender.tag] else { return }
        delegate?.inspector(self, link: mention)
    }
}

/// Lets views ask whether a library is open without touching the main-actor class directly.
enum LibraryControllerCheck {
    static var hasLibrary: Bool { MainActor.assumeIsolated { LibraryController.current != nil } }
}
