import AppKit
import FrisketExport

/// The menu bar, a port of main/menu.js with macOS conventions: the application
/// menu, a Window menu, and shortcuts that don't collide with system ones.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(paragraphMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(toolsMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, object: Any? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.representedObject = object
        item.target = target
        menu.addItem(item)
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Frisket")
        add(menu, "About Frisket", #selector(AppDelegate.showAbout(_:)))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(AppDelegate.showPreferences(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        add(menu, "Services", nil).submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        add(menu, "Hide Frisket", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit Frisket", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        add(menu, "New Note", #selector(MainWindowController.newNote(_:)), "n")
        add(menu, "New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift])
        add(menu, "New Tab", #selector(NSResponder.newWindowForTab(_:)), "t", [.command, .option])
        add(menu, "New from Template…", #selector(MainWindowController.newFromTemplate(_:)))
        add(menu, "Quick Capture…", #selector(MainWindowController.quickCapture(_:)), "j", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Open…", #selector(AppDelegate.openDocument(_:)), "o")
        add(menu, "Open Library…", #selector(AppDelegate.openLibrary(_:)), "o", [.command, .shift])
        add(menu, "Quick Open…", #selector(MainWindowController.quickOpen(_:)), "p")
        let recent = NSMenu(title: "Open Recent")
        add(recent, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
        add(menu, "Open Recent", nil).submenu = recent
        menu.addItem(.separator())
        add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(menu, "Save", #selector(MainWindowController.saveDocument(_:)), "s")
        add(menu, "Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Open Today’s Note", #selector(MainWindowController.openDailyNote(_:)), "t", [.command, .shift])
        add(menu, "Pin or Unpin Note", #selector(MainWindowController.togglePin(_:)))
        add(menu, "Version History…", #selector(MainWindowController.showVersionHistory(_:)))
        add(menu, "Sync & Devices…", #selector(MainWindowController.showSync(_:)))
        menu.addItem(.separator())
        let imports = NSMenu(title: "Import")
        add(imports, "Evernote (.enex)…", #selector(MainWindowController.importNotes(_:)), object: "evernote")
        add(imports, "Notion Export…", #selector(MainWindowController.importNotes(_:)), object: "notion")
        add(imports, "Apple Notes…", #selector(MainWindowController.importNotes(_:)), object: "apple-notes")
        add(menu, "Import", nil).submenu = imports
        let exports = NSMenu(title: "Export")
        add(exports, "PDF…", #selector(MainWindowController.exportDocument(_:)), object: "pdf")
        add(exports, "HTML (Self-Contained)…", #selector(MainWindowController.exportDocument(_:)), object: "html")
        add(exports, "Markdown…", #selector(MainWindowController.exportDocument(_:)), object: "markdown")
        add(exports, "JPEG Image…", #selector(MainWindowController.exportDocument(_:)), object: "jpg")
        add(exports, "PDF or HTML with Layout…", #selector(MainWindowController.exportWithLayout(_:)))
        add(exports, "Plain Text (.txt)…", #selector(MainWindowController.exportDocument(_:)), object: "txt")
        exports.addItem(.separator())
        for format in Pandoc.formats {
            add(exports, format.name + "…", #selector(MainWindowController.exportDocument(_:)), object: format.id)
        }
        add(menu, "Export", nil).submenu = exports
        add(menu, "Print…", #selector(MainWindowController.printDocument(_:)), "p", [.command, .option])
        menu.addItem(.separator())
        add(menu, "Show in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .shift])
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add(menu, "Undo", Selector(("undo:")), "z")
        add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(menu, "Paste as Plain Text", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(menu, "Delete", #selector(NSText.delete(_:)))
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        add(menu, "Copy as HTML", #selector(MainWindowController.copyAsHTML(_:)))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        add(find, "Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
        add(find, "Find and Replace…", finder, "r", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue)
        add(find, "Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue)
        add(find, "Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
        add(find, "Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue)
        add(find, "Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
        add(menu, "Find", nil).submenu = find
        add(menu, "Search All Notes…", #selector(MainWindowController.searchNotes(_:)), "f", [.command, .shift])
        menu.addItem(.separator())
        let spelling = NSMenu(title: "Spelling and Grammar")
        add(spelling, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":")
        add(spelling, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";")
        spelling.addItem(.separator())
        add(spelling, "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)))
        add(spelling, "Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)))
        add(menu, "Spelling and Grammar", nil).submenu = spelling
        let transformations = NSMenu(title: "Transformations")
        add(transformations, "Make Upper Case", #selector(NSResponder.uppercaseWord(_:)))
        add(transformations, "Make Lower Case", #selector(NSResponder.lowercaseWord(_:)))
        add(transformations, "Capitalize", #selector(NSResponder.capitalizeWord(_:)))
        add(menu, "Transformations", nil).submenu = transformations
        return menu
    }

    private static func paragraphMenu() -> NSMenu {
        let menu = NSMenu(title: "Paragraph")
        for level in 1...6 {
            add(menu, "Heading \(level)", #selector(MarkdownTextView.applyHeading(_:)), "\(level)", tag: level)
        }
        add(menu, "Paragraph", #selector(MarkdownTextView.applyHeading(_:)), "0", tag: 0)
        menu.addItem(.separator())
        add(menu, "Increase Heading Level", #selector(MarkdownTextView.increaseHeadingLevel(_:)), "=")
        add(menu, "Decrease Heading Level", #selector(MarkdownTextView.decreaseHeadingLevel(_:)), "-")
        menu.addItem(.separator())
        add(menu, "Bulleted List", #selector(MarkdownTextView.toggleBulletList(_:)), "u", [.command, .shift])
        add(menu, "Numbered List", #selector(MarkdownTextView.toggleOrderedList(_:)), "l", [.command, .shift])
        add(menu, "Task List", #selector(MarkdownTextView.toggleTaskList(_:)), "x", [.command, .shift])
        add(menu, "Blockquote", #selector(MarkdownTextView.toggleBlockquote(_:)), "q", [.command, .option])
        menu.addItem(.separator())
        add(menu, "Code Block", #selector(MarkdownTextView.insertCodeFence(_:)), "k", [.command, .shift])
        add(menu, "Math Block", #selector(MarkdownTextView.insertMathBlock(_:)), "m", [.command, .shift])
        add(menu, "Table…", #selector(MarkdownTextView.insertTableAction(_:)), "t")
        add(menu, "Horizontal Rule", #selector(MarkdownTextView.insertHorizontalRule(_:)), "-", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Indent", #selector(MarkdownTextView.indentItems(_:)), "]")
        add(menu, "Outdent", #selector(MarkdownTextView.outdentItems(_:)), "[")
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        add(menu, "Bold", #selector(MarkdownTextView.toggleBold(_:)), "b")
        add(menu, "Italic", #selector(MarkdownTextView.toggleItalic(_:)), "i")
        add(menu, "Underline", #selector(MarkdownTextView.toggleUnderlineMarkup(_:)), "u")
        add(menu, "Strikethrough", #selector(MarkdownTextView.toggleStrikethrough(_:)), "x", [.command, .control])
        add(menu, "Highlight", #selector(MarkdownTextView.toggleHighlight(_:)), "h", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Inline Code", #selector(MarkdownTextView.toggleInlineCode(_:)), "c", [.command, .shift])
        add(menu, "Inline Math", #selector(MarkdownTextView.toggleInlineMath(_:)), "d", [.command, .shift])
        add(menu, "Superscript", #selector(MarkdownTextView.toggleSuperscript(_:)))
        add(menu, "Subscript", #selector(MarkdownTextView.toggleSubscript(_:)))
        menu.addItem(.separator())
        add(menu, "Link…", #selector(MarkdownTextView.insertLinkAction(_:)), "k")
        add(menu, "Image…", #selector(MarkdownTextView.insertImageAction(_:)), "i", [.command, .shift])
        add(menu, "File Attachment…", #selector(MarkdownTextView.insertAttachmentAction(_:)))
        menu.addItem(.separator())
        add(menu, "Clear Formatting", #selector(MarkdownTextView.clearFormatting(_:)), "\\")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        add(menu, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        add(menu, "Show Note List", #selector(MainWindowController.toggleNoteList(_:)), "b", [.command, .shift])
        add(menu, "Show Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .control])
        add(menu, "Outline", #selector(MainWindowController.showOutline(_:)), "1", [.command, .shift])
        add(menu, "Backlinks", #selector(MainWindowController.showBacklinks(_:)), "b", [.command, .option])
        add(menu, "Note Info", #selector(MainWindowController.showNoteInfo(_:)), "2", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Back", #selector(MainWindowController.goBack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        add(menu, "Forward", #selector(MainWindowController.goForward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        menu.addItem(.separator())
        add(menu, "Source Code Mode", #selector(AppDelegate.toggleSourceMode(_:)), "/")
        add(menu, "Focus Mode", #selector(AppDelegate.toggleFocusMode(_:)), "f", [.command, .option])
        add(menu, "Typewriter Mode", #selector(AppDelegate.toggleTypewriterMode(_:)), "t", [.command, .control])
        add(menu, "Distraction-Free Mode", #selector(AppDelegate.toggleDistractionFree(_:)), "\r", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Zoom In", #selector(AppDelegate.zoomIn(_:)), "=", [.command, .option])
        add(menu, "Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-", [.command, .option])
        add(menu, "Actual Size", #selector(AppDelegate.actualSize(_:)), "0", [.command, .option])
        menu.addItem(.separator())
        let themes = NSMenu(title: "Theme")
        themes.delegate = ThemeMenuDelegate.shared
        add(menu, "Theme", nil).submenu = themes
        let appearance = NSMenu(title: "Appearance")
        add(appearance, "Follow System", #selector(AppDelegate.setAppearance(_:)), object: AppearanceSetting.system.rawValue)
        add(appearance, "Light", #selector(AppDelegate.setAppearance(_:)), object: AppearanceSetting.light.rawValue)
        add(appearance, "Dark", #selector(AppDelegate.setAppearance(_:)), object: AppearanceSetting.dark.rawValue)
        add(menu, "Appearance", nil).submenu = appearance
        menu.addItem(.separator())
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tools")
        add(menu, "Style Check…", #selector(MainWindowController.styleCheck(_:)), "e", [.command, .shift])
        add(menu, "Insert Template…", #selector(MainWindowController.insertTemplate(_:)))
        add(menu, "Save Selection as Snippet…", #selector(MainWindowController.saveSnippet(_:)))
        add(menu, "Attachment Audit…", #selector(MainWindowController.attachmentAudit(_:)))
        add(menu, "Sync Conflicts…", #selector(MainWindowController.showConflicts(_:)))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        add(menu, "Markdown Reference", #selector(AppDelegate.showMarkdownReference(_:)))
        add(menu, "Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)))
        add(menu, "How Sync Works", #selector(MainWindowController.showSync(_:)))
        menu.addItem(.separator())
        add(menu, "Open Theme Folder", #selector(AppDelegate.openThemeFolder(_:)))
        menu.addItem(.separator())
        add(menu, "Licence", #selector(AppDelegate.showLegal(_:)), object: "LICENSE")
        add(menu, "Third-Party Notices", #selector(AppDelegate.showLegal(_:)), object: "THIRD-PARTY-NOTICES.md")
        return menu
    }
}

/// Fills View › Theme from the theme store each time it opens, so new user themes appear.
@MainActor
final class ThemeMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ThemeMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        ThemeStore.shared.reload()
        menu.removeAllItems()
        for theme in ThemeStore.shared.themes {
            let item = NSMenuItem(title: theme.displayName, action: #selector(AppDelegate.setTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.name
            item.state = theme.name == AppSettings.shared.theme ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Theme Folder", action: #selector(AppDelegate.openThemeFolder(_:)), keyEquivalent: ""))
    }
}
