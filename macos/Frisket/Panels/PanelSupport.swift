import AppKit
import FrisketServices
import ObjectiveC

/// Target-action bridge so controls can take closures.
@MainActor
final class ActionTarget: NSObject {
    let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) {
        if let control = sender as? NSControl { handler(control) }
    }
}

private var actionTargetKey: UInt8 = 0

/// Small AppKit construction helpers shared by the panels.
@MainActor
enum UI {
    static func onAction(_ control: NSControl, _ handler: @escaping (NSControl) -> Void) {
        let target = ActionTarget(handler)
        control.target = target
        control.action = #selector(ActionTarget.fire(_:))
        objc_setAssociatedObject(control, &actionTargetKey, target, .OBJC_ASSOCIATION_RETAIN)
    }

    static func label(_ text: String, font: NSFont = .systemFont(ofSize: 13), color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = wraps
        if !wraps { field.lineBreakMode = .byTruncatingTail }
        return field
    }

    static func secondary(_ text: String, wraps: Bool = true) -> NSTextField {
        label(text, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: wraps)
    }

    static func heading(_ text: String) -> NSTextField {
        label(text, font: .systemFont(ofSize: 13, weight: .semibold))
    }

    @discardableResult
    static func button(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], primary: Bool = false,
                       handler: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        if !key.isEmpty {
            button.keyEquivalent = key
            button.keyEquivalentModifierMask = modifiers
        }
        if primary && key.isEmpty { button.keyEquivalent = "\r" }
        onAction(button) { _ in handler() }
        return button
    }

    static func checkbox(_ title: String, handler: @escaping (Bool) -> Void) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        onAction(box) { handler(($0 as? NSButton)?.state == .on) }
        return box
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        return view
    }

    /// A right-aligned row of buttons, optionally with views (a spinner, a status) at the left.
    static func buttonRow(_ buttons: [NSView], leading: [NSView] = []) -> NSStackView {
        let row = NSStackView(views: leading + [spacer()] + buttons)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 10, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    /// A read-only scrolling text view.
    static func textScroll(mono: Bool = false) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return (scroll, textView)
    }

    /// Added lines green, removed lines red, collapsed runs as a grey note.
    static func diffText(_ rows: [DiffRow]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString()
        func append(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            var all: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            all.merge(attributes) { $1 }
            result.append(NSAttributedString(string: text + "\n", attributes: all))
        }
        for row in rows {
            switch row {
            case .line(let op):
                switch op.kind {
                case .same: append("  " + op.text, [.foregroundColor: NSColor.secondaryLabelColor])
                case .add: append("+ " + op.text, [.backgroundColor: NSColor.systemGreen.withAlphaComponent(0.22)])
                case .del: append("\u{2212} " + op.text, [.backgroundColor: NSColor.systemRed.withAlphaComponent(0.22)])
                }
            case .skip(let count):
                append("\u{22EF} \(count) unchanged line\(count == 1 ? "" : "s")", [.foregroundColor: NSColor.tertiaryLabelColor])
            }
        }
        return result
    }

    static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The window an alert should attach to: the top-most sheet already on `window`.
    static func topmost(_ window: NSWindow) -> NSWindow {
        var current = window
        while let sheet = current.attachedSheet { current = sheet }
        return current
    }

    static func alert(_ title: String, _ info: String = "", style: NSAlert.Style = .informational, parent: NSWindow?,
                      buttons: [String] = ["OK"], destructiveFirst: Bool = false,
                      completion: ((Int) -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = style
        for title in buttons { alert.addButton(withTitle: title) }
        if destructiveFirst { alert.buttons[0].hasDestructiveAction = true }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion?(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
        if let parent, parent.isVisible {
            alert.beginSheetModal(for: topmost(parent), completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    static func error(_ title: String, _ error: Error, parent: NSWindow?) {
        alert(title, error.localizedDescription, style: .warning, parent: parent)
    }
}

// MARK: - Window wrapper

/// A sheet, floating panel or ordinary window that keeps itself alive until dismissed.
@MainActor
class PanelController: NSObject, NSWindowDelegate {
    private static var live: [PanelController] = []

    let window: NSWindow
    private let floating: Bool
    private var isSheet = false
    var onClose: (() -> Void)?

    init(title: String, size: NSSize, resizable: Bool = true, floating: Bool = false, minSize: NSSize? = nil) {
        self.floating = floating
        var mask: NSWindow.StyleMask = [.titled, .closable]
        if resizable { mask.insert(.resizable) }
        let rect = NSRect(origin: .zero, size: size)
        if floating {
            let panel = NSPanel(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = NSWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
        }
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize ?? (resizable ? NSSize(width: size.width * 0.7, height: size.height * 0.6) : size)
        super.init()
        window.delegate = self
    }

    var contentView: NSView { window.contentView! }

    /// Pin `view` inside the window with standard margins.
    func install(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// Show as a sheet on `parent`, or as a free window when there is none.
    func present(on parent: NSWindow?) {
        PanelController.live.append(self)
        if let parent, !floating {
            isSheet = true
            UI.topmost(parent).beginSheet(window, completionHandler: nil)
        } else {
            if let parent {
                let frame = parent.frame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2 + 80))
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func dismiss() {
        if isSheet {
            isSheet = false
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
            finish()
        } else {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) { finish() }

    private func finish() {
        guard let index = PanelController.live.firstIndex(where: { $0 === self }) else { return }
        PanelController.live.remove(at: index)
        onClose?()
        onClose = nil
    }
}

// MARK: - A simple list

/// Rows of a title with an optional detail line and an optional per-row button.
@MainActor
final class ListTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var title: String
        var detail: String?
        var action: (title: String, handler: () -> Void)?
        var color: NSColor?
        init(title: String, detail: String? = nil, color: NSColor? = nil, action: (title: String, handler: () -> Void)? = nil) {
            self.title = title
            self.detail = detail
            self.color = color
            self.action = action
        }
    }

    let scrollView = NSScrollView()
    let table = NSTableView()
    var onSelect: ((Int?) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var rows: [Row] = [] {
        didSet { table.reloadData() }
    }

    init(rowHeight: CGFloat = 40) {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    var selectedIndex: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let data = rows[row]
        let container = NSView()
        let title = UI.label(data.title, color: data.color ?? .labelColor)
        title.lineBreakMode = .byTruncatingMiddle
        var lines: [NSView] = [title]
        if let detail = data.detail {
            let field = UI.label(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            field.lineBreakMode = .byTruncatingMiddle
            lines.append(field)
        }
        let stack = UI.vstack(lines, spacing: 1)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ]
        if let action = data.action {
            let button = UI.button(action.title, handler: action.handler)
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            container.addSubview(button)
            constraints += [
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            ]
        } else {
            constraints.append(stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedIndex)
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        if row >= 0 { onDoubleClick?(row) }
    }
}
