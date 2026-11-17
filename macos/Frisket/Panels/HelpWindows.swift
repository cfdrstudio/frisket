import AppKit

/// Markdown reference and keyboard shortcuts: non-modal, single-instance windows.
@MainActor
enum HelpWindows {
    private static var reference: NSWindow?
    private static var shortcuts: NSWindow?

    static func showReference() {
        if let reference { reference.makeKeyAndOrderFront(nil); return }
        reference = makeWindow(title: "Markdown Reference", size: NSSize(width: 560, height: 640), text: referenceText()) { reference = nil }
    }

    static func showShortcuts() {
        if let shortcuts { shortcuts.makeKeyAndOrderFront(nil); return }
        shortcuts = makeWindow(title: "Keyboard Shortcuts", size: NSSize(width: 520, height: 640), text: shortcutText()) { shortcuts = nil }
    }

    private final class Closer: NSObject, NSWindowDelegate {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        func windowWillClose(_ notification: Notification) { handler() }
    }
    private static var closers: [ObjectIdentifier: Closer] = [:]

    private static func makeWindow(title: String, size: NSSize, text: NSAttributedString, onClose: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 400, height: 300)
        let (scroll, textView) = UI.textScroll()
        scroll.borderType = .noBorder
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(text)
        window.contentView = scroll
        let id = ObjectIdentifier(window)
        let closer = Closer { closers[id] = nil; onClose() }
        closers[id] = closer
        window.delegate = closer
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    // MARK: Content

    private static func heading(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 14
        style.paragraphSpacing = 4
        return NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                                     .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }

    private static func body(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        return NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                     .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }

    private static func code(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        return NSAttributedString(string: text + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                                     .foregroundColor: NSColor.labelColor,
                                                                     .backgroundColor: NSColor.quaternaryLabelColor, .paragraphStyle: style])
    }

    private static func referenceText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let title = NSAttributedString(string: "Markdown Reference\n", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.labelColor])
        out.append(title)
        out.append(body("Frisket hides the syntax below as soon as your cursor leaves it. Type it as shown."))
        let sections: [(String, String?, String?)] = [
            ("Text", nil, "**bold**, *italic*, ***both***, ~~strikethrough~~, ==highlight==, `inline code`,\nH~2~O and E = mc^2^."),
            ("Headings", "Type # through ###### followed by a space, or press \u{2318}1 \u{2026} \u{2318}6. \u{2318}0 returns to a paragraph.", "# Heading 1\n## Heading 2"),
            ("Lists", "\u{21E7}\u{2318}U, \u{21E7}\u{2318}L and \u{21E7}\u{2318}X toggle bulleted, numbered and task lists.", "- A bullet list\n- With a second item\n  - And a nested one\n\n1. Numbered lists\n2. Renumber as you go\n\n- [ ] A task\n- [x] A finished task"),
            ("Blockquote", "\u{2325}\u{2318}Q", "> A blockquote, for when someone else said it better."),
            ("Links and images", "\u{2318}K inserts a link, \u{21E7}\u{2318}I an image. \u{2318}-click a link to open it.", "[A link](https://example.com)\n![An image](assets/example.png)"),
            ("Linking between notes", "\u{2318}-click any of these to follow them. If the target doesn\u{2019}t exist yet, Frisket offers to create it.", "[[another-note]]\n[[another-note|shown as this]]\n[a normal link](another-note.md)"),
            ("Tables", "\u{2318}T inserts a table; Tab moves to the next cell.", "| Column | Meaning |\n| --- | --- |\n| \u{2318}T | Insert a table |\n| Tab | Next cell |"),
            ("Code", "\u{21E7}\u{2318}K inserts a fenced code block; \u{21E7}\u{2318}C marks inline code.", "```swift\nlet greeting = \"Hello\"\n```"),
            ("Math", "\u{21E7}\u{2318}D for inline math, \u{21E7}\u{2318}M for a math block.", "Inline $E = mc^2$ and display:\n\n$$\n\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}\n$$"),
            ("Diagrams", "Mermaid fences are kept as code blocks in exports.", "```mermaid\ngraph LR\n  Draft --> Edit --> Publish\n```"),
            ("Dividers", "\u{21E7}\u{2318}\u{2212} inserts a horizontal rule.", "---"),
        ]
        for (name, text, sample) in sections {
            out.append(heading(name))
            if let text { out.append(body(text)) }
            if let sample { out.append(code(sample)) }
        }
        return out
    }

    private static func shortcutText() -> NSAttributedString {
        let groups: [(String, [(String, String)])] = [
            ("File", [("New Note", "\u{2318}N"), ("New Window", "\u{21E7}\u{2318}N"), ("New Tab", "\u{2325}\u{2318}T"),
                      ("Quick Capture", "\u{21E7}\u{2318}J"), ("Open\u{2026}", "\u{2318}O"), ("Open Library\u{2026}", "\u{21E7}\u{2318}O"),
                      ("Quick Open", "\u{2318}P"), ("Save", "\u{2318}S"), ("Save As\u{2026}", "\u{21E7}\u{2318}S"),
                      ("Open Today\u{2019}s Note", "\u{21E7}\u{2318}T"), ("Print", "\u{2325}\u{2318}P"),
                      ("Show in Finder", "\u{21E7}\u{2318}R"), ("Close", "\u{2318}W"), ("Settings", "\u{2318},")]),
            ("Edit and Find", [("Undo / Redo", "\u{2318}Z / \u{21E7}\u{2318}Z"), ("Paste as Plain Text", "\u{2325}\u{21E7}\u{2318}V"),
                               ("Find", "\u{2318}F"), ("Find and Replace", "\u{2325}\u{2318}R"), ("Find Next / Previous", "\u{2318}G / \u{21E7}\u{2318}G"),
                               ("Use Selection for Find", "\u{2318}E"), ("Jump to Selection", "\u{2318}J"), ("Search All Notes", "\u{21E7}\u{2318}F")]),
            ("Paragraph", [("Heading 1\u{2013}6", "\u{2318}1 \u{2026} \u{2318}6"), ("Paragraph", "\u{2318}0"),
                           ("Increase / Decrease Heading Level", "\u{2318}= / \u{2318}\u{2212}"), ("Bulleted List", "\u{21E7}\u{2318}U"),
                           ("Numbered List", "\u{21E7}\u{2318}L"), ("Task List", "\u{21E7}\u{2318}X"), ("Blockquote", "\u{2325}\u{2318}Q"),
                           ("Code Block", "\u{21E7}\u{2318}K"), ("Math Block", "\u{21E7}\u{2318}M"), ("Table", "\u{2318}T"),
                           ("Horizontal Rule", "\u{21E7}\u{2318}\u{2212}"), ("Indent / Outdent", "\u{2318}] / \u{2318}[")]),
            ("Format", [("Bold", "\u{2318}B"), ("Italic", "\u{2318}I"), ("Underline", "\u{2318}U"), ("Strikethrough", "\u{2303}\u{2318}X"),
                        ("Highlight", "\u{21E7}\u{2318}H"), ("Inline Code", "\u{21E7}\u{2318}C"), ("Inline Math", "\u{21E7}\u{2318}D"),
                        ("Link", "\u{2318}K"), ("Image", "\u{21E7}\u{2318}I"), ("Clear Formatting", "\u{2318}\\")]),
            ("View", [("Show Sidebar", "\u{2303}\u{2318}S"), ("Show Note List", "\u{21E7}\u{2318}B"), ("Show Inspector", "\u{2303}\u{2318}I"),
                      ("Outline", "\u{21E7}\u{2318}1"), ("Note Info", "\u{21E7}\u{2318}2"), ("Backlinks", "\u{2325}\u{2318}B"),
                      ("Back / Forward", "\u{2325}\u{2318}\u{2190} / \u{2325}\u{2318}\u{2192}"), ("Source Code Mode", "\u{2318}/"),
                      ("Focus Mode", "\u{2325}\u{2318}F"), ("Typewriter Mode", "\u{2303}\u{2318}T"),
                      ("Distraction-Free Mode", "\u{21E7}\u{2318}\u{21A9}"), ("Zoom In / Out / Actual Size", "\u{2325}\u{2318}= / \u{2325}\u{2318}\u{2212} / \u{2325}\u{2318}0")]),
            ("Tools", [("Style Check", "\u{21E7}\u{2318}E")]),
            ("Writing", [("Link to a note", "[["), ("Tag", "#"), ("Accept suggestion", "\u{21A9}"), ("Next / previous table cell", "Tab / \u{21E7}Tab")]),
        ]
        let out = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 300)]
        style.defaultTabInterval = 300
        for (group, items) in groups {
            out.append(heading(group))
            for (label, keys) in items {
                out.append(NSAttributedString(string: "\(label)\t\(keys)\n", attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                                         .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
            }
        }
        return out
    }
}
