import XCTest
import AppKit
@testable import Frisket

/// Typing behaviour of the live-preview editor: list and quote continuation,
/// auto-pairing, indentation and the Format/Paragraph commands. These drive a real
/// `MarkdownTextView` (no window needed) the way key presses and menu items do.
@MainActor
final class EditorTypingTests: XCTestCase {
    // The text view does not own its storage (TextKit 1), so keep it alive here.
    private var storage: MarkdownTextStorage!
    private var view: MarkdownTextView!

    /// A view holding `marked`, with the caret at `|` (or at the end when there is none).
    private func editor(_ marked: String) -> MarkdownTextView {
        var text = marked
        var selection = NSRange(location: NSNotFound, length: 0)
        if let caret = text.range(of: "|") {
            selection = NSRange(location: text.utf16.distance(from: text.startIndex, to: caret.lowerBound), length: 0)
            text.removeSubrange(caret)
        }
        let theme = ThemeStore.shared.theme(named: "frisket")
        let palette = theme.palette(dark: false)
        storage = MarkdownTextStorage(styler: MarkdownStyler(theme: theme, dark: false, fontSize: 17, lineHeight: 1.72, sourceMode: false))
        let widgets = WidgetRenderer(theme: theme, palette: palette, fontSize: 17)
        view = MarkdownTextView.make(storage: storage, palette: palette, widgets: widgets, fontSize: 17)
        storage.load(text)
        if selection.location == NSNotFound { selection = NSRange(location: (text as NSString).length, length: 0) }
        view.setSelectedRange(selection)
        return view
    }

    private func select(_ location: Int, _ length: Int) { view.setSelectedRange(NSRange(location: location, length: length)) }
    private func type(_ text: String) { for character in text { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
    private var text: String { view.string }
    private var caret: Int { view.selectedRange().location }

    // MARK: Return continues lists and quotes

    func testReturnContinuesBulletList() {
        _ = editor("- one")
        view.insertNewline(nil)
        XCTAssertEqual(text, "- one\n- ")
        XCTAssertEqual(caret, 8)
    }

    func testReturnContinuesTaskListUnchecked() {
        _ = editor("- [x] done")
        view.insertNewline(nil)
        XCTAssertEqual(text, "- [x] done\n- [ ] ")
    }

    func testReturnNumbersOrderedList() {
        _ = editor("  9) nine")
        view.insertNewline(nil)
        XCTAssertEqual(text, "  9) nine\n  10) ")
    }

    func testReturnContinuesQuote() {
        _ = editor("> said")
        view.insertNewline(nil)
        XCTAssertEqual(text, "> said\n> ")
    }

    func testReturnOnEmptyItemEndsList() {
        _ = editor("- a\n- ")
        view.insertNewline(nil)
        XCTAssertEqual(text, "- a\n\n")
        XCTAssertEqual(caret, 5)
    }

    func testReturnOnEmptyItemMidDocumentClearsMarker() {
        _ = editor("- a\n- |\nafter")
        view.insertNewline(nil)
        XCTAssertEqual(text, "- a\n\nafter")
        XCTAssertEqual(caret, 4)
    }

    func testReturnSplitsItemAtCaret() {
        _ = editor("- ab|cd")
        view.insertNewline(nil)
        XCTAssertEqual(text, "- ab\n- cd")
        XCTAssertEqual(caret, 7)
    }

    func testReturnInPlainParagraphIsPlain() {
        _ = editor("plain")
        view.insertNewline(nil)
        XCTAssertEqual(text, "plain\n")
    }

    // MARK: Backspace

    func testBackspaceAfterMarkerRemovesMarker() {
        _ = editor("  - |item")
        view.deleteBackward(nil)
        XCTAssertEqual(text, "  item")
        XCTAssertEqual(caret, 2)
    }

    func testBackspaceRemovesEmptyPair() {
        _ = editor("x (|)")
        view.deleteBackward(nil)
        XCTAssertEqual(text, "x ")
    }

    // MARK: Auto-pairing

    func testBracketPairsAndStepsOver() {
        _ = editor("")
        type("(")
        XCTAssertEqual(text, "()")
        XCTAssertEqual(caret, 1)
        type("a)")
        XCTAssertEqual(text, "(a)")
        XCTAssertEqual(caret, 3)
    }

    func testStarWrapsSelection() {
        _ = editor("a word here")
        select(2, 4)
        type("*")
        XCTAssertEqual(text, "a *word* here")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 4))
    }

    func testNoPairingMidWord() {
        _ = editor("foo")
        type("_")
        XCTAssertEqual(text, "foo_")
        _ = editor("2")
        type("*")
        XCTAssertEqual(text, "2*")
    }

    func testDoubleStarTypesBold() {
        _ = editor("")
        type("**")
        // The second star steps over the auto-inserted closer rather than nesting.
        XCTAssertEqual(text, "**")
        XCTAssertEqual(caret, 2)
    }

    func testBracketBeforeWordDoesNotPair() {
        _ = editor("|word")
        type("(")
        XCTAssertEqual(text, "(word")
    }

    // MARK: Tab indents list items

    func testTabIndentsAndShiftTabOutdents() {
        _ = editor("- a")
        view.insertTab(nil)
        XCTAssertEqual(text, "    - a")
        XCTAssertEqual(caret, 7)
        view.insertBacktab(nil)
        XCTAssertEqual(text, "- a")
        XCTAssertEqual(caret, 3)
    }

    func testTabIndentsEverySelectedItem() {
        _ = editor("- a\n- b\ntext")
        select(0, 7)
        view.insertTab(nil)
        XCTAssertEqual(text, "    - a\n    - b\ntext")
    }

    // MARK: Format commands

    func testBoldWrapsAndUnwraps() {
        _ = editor("make this bold")
        select(5, 4)
        view.toggleBold(nil)
        XCTAssertEqual(text, "make **this** bold")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 4))
        view.toggleBold(nil)
        XCTAssertEqual(text, "make this bold")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 4))
    }

    func testBoldWithNoSelectionInsertsMarkers() {
        _ = editor("x ")
        view.toggleBold(nil)
        XCTAssertEqual(text, "x ****")
        XCTAssertEqual(caret, 4)
    }

    func testHeadingLevels() {
        _ = editor("Title|")
        view.setHeading(2)
        XCTAssertEqual(text, "## Title")
        view.increaseHeadingLevel(nil)
        XCTAssertEqual(text, "### Title")
        view.setHeading(0)
        XCTAssertEqual(text, "Title")
    }

    func testToggleListsOverSelection() {
        _ = editor("a\n\nb")
        select(0, 4)
        view.toggleList(.ordered)
        XCTAssertEqual(text, "1. a\n\n2. b")
        select(0, (text as NSString).length)
        view.toggleList(.ordered)
        XCTAssertEqual(text, "a\n\nb")
        select(0, 4)
        view.toggleList(.task)
        XCTAssertEqual(text, "- [ ] a\n\n- [ ] b")
        select(0, (text as NSString).length)
        view.toggleList(.bullet)
        XCTAssertEqual(text, "- a\n\n- b")
    }

    func testBlockquoteToggles() {
        _ = editor("one\ntwo")
        select(0, 7)
        view.toggleBlockquote(nil)
        XCTAssertEqual(text, "> one\n> two")
        select(0, (text as NSString).length)
        view.toggleBlockquote(nil)
        XCTAssertEqual(text, "one\ntwo")
    }

    func testInsertTableAfterParagraph() {
        _ = editor("Intro")
        view.insertTable(rows: 1, columns: 2)
        XCTAssertEqual(text, "Intro\n\n| Column 1 | Column 2 |\n| --- | --- |\n|     |     |\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 9, length: 8))
    }

    func testCodeFenceWrapsSelectionOnItsOwnLines() {
        _ = editor("before let x = 1")
        select(7, 9)
        view.insertCodeFence(nil)
        XCTAssertEqual(text, "before \n\n```\nlet x = 1\n```\n")
    }

    // MARK: Links

    func testLinkTargetsUnderCaret() {
        _ = editor("See [[Other note]] and [site](https://example.com).")
        XCTAssertEqual(view.linkTarget(atCharacter: 8)?.target, "Other note")
        XCTAssertEqual(view.linkTarget(atCharacter: 8)?.wiki, true)
        XCTAssertEqual(view.linkTarget(atCharacter: 25)?.target, "https://example.com")
        XCTAssertEqual(view.linkTarget(atCharacter: 25)?.wiki, false)
        XCTAssertNil(view.linkTarget(atCharacter: 1))
    }

    // MARK: Undo

    func testOneEditIsOneUndoStep() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        _ = editor("- one")
        window.contentView = view
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.insertNewline(nil)
        XCTAssertEqual(text, "- one\n- ")
        undo.undo()
        XCTAssertEqual(text, "- one")
    }
}
