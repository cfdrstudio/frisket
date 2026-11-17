import AppKit
import FrisketBase
import FrisketMarkdown
import FrisketServices

/// What the text view needs from the window around it.
protocol MarkdownTextViewHost: AnyObject {
    /// Follow a link the writer clicked with ⌘ (or a plain click on a link that is not being edited).
    func markdownTextView(_ view: MarkdownTextView, openLink target: String, wiki: Bool)
    /// `[[` completions for `query`.
    func markdownTextView(_ view: MarkdownTextView, noteCompletionsFor query: String) -> [CompletionItem]
    /// `#tag` completions for `query`.
    func markdownTextView(_ view: MarkdownTextView, tagCompletionsFor query: String) -> [CompletionItem]
    /// Store pasted or dropped data beside the note and return the Markdown to insert.
    func markdownTextView(_ view: MarkdownTextView, insertAssets urls: [URL]) -> String?
    func markdownTextView(_ view: MarkdownTextView, insertImageData data: Data, fileExtension: String) -> String?
}

struct CompletionItem {
    var label: String
    var detail: String
    /// Text that replaces the query.
    var insert: String
    var alias: String? = nil
    var isWiki: Bool
}

/// The editor surface: an NSTextView on top of `MarkdownTextStorage` and
/// `LivePreviewLayoutManager`, with Markdown-aware typing (list continuation,
/// auto-pairing, smart backspace, Tab to indent list items) and widget clicks.
final class MarkdownTextView: NSTextView {
    weak var host: MarkdownTextViewHost?
    var autoPair = true
    var typewriterMode = false { didSet { updateInsets(); if typewriterMode { centerCaret() } } }
    var focusMode = false { didSet { updateFocusDimming() } }
    var contentWidth: CGFloat = 780 { didSet { updateInsets() } }

    var livePreview: LivePreviewLayoutManager { layoutManager as! LivePreviewLayoutManager }
    var markdownStorage: MarkdownTextStorage { textStorage as! MarkdownTextStorage }

    private var completion: CompletionPopup?
    private var lastCaret = 0

    // MARK: Construction

    static func make(storage: MarkdownTextStorage, palette: ThemePalette, widgets: WidgetRenderer, fontSize: CGFloat) -> MarkdownTextView {
        let manager = LivePreviewLayoutManager(palette: palette, fontSize: fontSize, widgets: widgets)
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.drawsBackground = true
        view.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        widgets.onAsyncLoad = { [weak view] in view?.relayoutWidgets() }
        return view
    }

    func apply(palette: ThemePalette, styler: MarkdownStyler) {
        backgroundColor = palette.bg
        insertionPointColor = palette.accent
        selectedTextAttributes = [.backgroundColor: palette.selection]
        linkTextAttributes = [:]
        typingAttributes = styler.baseAttributes
        livePreview.palette = palette
        livePreview.fontSize = styler.fontSize
        livePreview.sourceMode = styler.sourceMode
        livePreview.widgets.palette = palette
        livePreview.widgets.theme = styler.theme
        livePreview.widgets.fontSize = styler.fontSize
        markdownStorage.styler = styler
        updateFocusDimming()
        needsDisplay = true
    }

    func relayoutWidgets() {
        let all = NSRange(location: 0, length: markdownStorage.length)
        livePreview.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        needsDisplay = true
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private let topInset: CGFloat = 36

    /// Centre a column of `contentWidth`; typewriter mode adds room to scroll the last line to the middle.
    func updateInsets() {
        let side = max(28, floor((bounds.width - contentWidth) / 2))
        let bottom = typewriterMode ? max(120, (enclosingScrollView?.contentSize.height ?? 400) * 0.5) : 120
        // NSTextView pads top and bottom equally; `textContainerOrigin` moves the text back up.
        let inset = NSSize(width: side, height: ceil((topInset + bottom) / 2))
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let container = textContainer else { return }
        let origin = textContainerOrigin
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -60)
        let glyphs = livePreview.glyphRange(forBoundingRect: local, in: container)
        livePreview.drawBlockDecorations(forGlyphRange: glyphs, at: origin)
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: topInset)
    }

    override func didChangeText() {
        super.didChangeText()
        if typewriterMode { centerCaret() }
        updateFocusDimming()
        updateCompletion()
    }

    // MARK: Selection

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var adjusted = ranges
        if ranges.count == 1, ranges[0].rangeValue.length == 0, markdownStorage.length > 0 {
            let caret = ranges[0].rangeValue.location
            let snapped = snapOutOfWidgets(caret, forward: caret >= lastCaret)
            if snapped != caret { adjusted = [NSValue(range: NSRange(location: snapped, length: 0))] }
        }
        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelecting)
        let selection = selectedRanges.map(\.rangeValue)
        lastCaret = selection.first?.location ?? 0
        livePreview.setSelection(selection)
        if !stillSelecting {
            if typewriterMode { centerCaret() }
            updateFocusDimming()
            NotificationCenter.default.post(name: .frisketSelectionChanged, object: self)
        }
    }

    /// The caret never rests inside a checkbox, which is drawn as one widget.
    private func snapOutOfWidgets(_ caret: Int, forward: Bool) -> Int {
        for hide in markdownStorage.document.hides(in: NSRange(location: max(0, caret - 3), length: 6)) where hide.mode == .never {
            let start = hide.range.location, end = start + hide.range.length
            if caret > start && caret < end { return forward ? end : start }
        }
        return caret
    }

    func centerCaret() {
        guard let scroll = enclosingScrollView, let manager = layoutManager, markdownStorage.length > 0 else { return }
        let caret = selectedRange().location
        let glyph = manager.glyphIndexForCharacter(at: min(caret, markdownStorage.length - 1))
        var rect = manager.lineFragmentRect(forGlyphAt: min(glyph, max(0, manager.numberOfGlyphs - 1)), effectiveRange: nil)
        if caret >= markdownStorage.length, !manager.extraLineFragmentRect.isEmpty { rect = manager.extraLineFragmentRect }
        let y = rect.midY + textContainerOrigin.y - scroll.contentSize.height / 2
        let clip = scroll.contentView
        let target = NSPoint(x: clip.bounds.origin.x, y: max(0, min(y, frame.height - scroll.contentSize.height)))
        if abs(clip.bounds.origin.y - target.y) > 1 {
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Focus mode dims every paragraph except the one with the caret.
    func updateFocusDimming() {
        guard let manager = layoutManager else { return }
        let all = NSRange(location: 0, length: markdownStorage.length)
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard focusMode, all.length > 0 else { return }
        let text = markdownStorage.string as NSString
        let caret = min(selectedRange().location, text.length)
        var first = text.lineRange(for: NSRange(location: caret, length: 0))
        var last = first
        while first.location > 0 {
            let previous = text.lineRange(for: NSRange(location: first.location - 1, length: 0))
            if text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            first = previous
        }
        while last.location + last.length < text.length {
            let next = text.lineRange(for: NSRange(location: last.location + last.length, length: 0))
            if text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            last = next
        }
        let keep = NSRange(location: first.location, length: last.location + last.length - first.location)
        let dim = livePreview.palette.fgFaint
        if keep.location > 0 {
            manager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: 0, length: keep.location))
        }
        let end = keep.location + keep.length
        if end < text.length {
            manager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: end, length: text.length - end))
        }
    }

    // MARK: Editing helpers

    var nsString: NSString { markdownStorage.string as NSString }

    /// Apply several replacements as one undoable step. Ranges are in the current text.
    @discardableResult
    func edit(_ changes: [(range: NSRange, text: String)], select: NSRange? = nil) -> Bool {
        let sorted = changes.sorted { $0.range.location < $1.range.location }
        guard !sorted.isEmpty else { return false }
        guard shouldChangeText(inRanges: sorted.map { NSValue(range: $0.range) }, replacementStrings: sorted.map(\.text)) else { return false }
        markdownStorage.beginEditing()
        for change in sorted.reversed() {
            markdownStorage.replaceCharacters(in: change.range, with: change.text)
        }
        markdownStorage.endEditing()
        didChangeText()
        if let select { setSelectedRange(select) }
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// The line ranges (without terminators) touched by the selection.
    func selectedLineRanges() -> [NSRange] {
        let text = nsString
        var seen = Set<Int>()
        var result: [NSRange] = []
        for value in selectedRanges {
            let range = value.rangeValue
            var location = range.location
            repeat {
                var start = 0, end = 0, contentsEnd = 0
                text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(location, text.length), length: 0))
                if seen.insert(start).inserted { result.append(NSRange(location: start, length: contentsEnd - start)) }
                if end >= range.location + range.length || end <= location { break }
                location = end
            } while location < range.location + range.length
        }
        return result.sorted { $0.location < $1.location }
    }

    func lineRange(at location: Int) -> NSRange {
        var start = 0, end = 0, contentsEnd = 0
        nsString.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(location, nsString.length), length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    // MARK: Typing

    static let bulletRx = Rx("^(\\s*)([-*+])(\\s+)(\\[[ xX]\\]\\s+)?")
    static let orderedRx = Rx("^(\\s*)(\\d+)([.)])(\\s+)")
    static let quoteRx = Rx("^(\\s*)>\\s?")
    private static let pairs: [String: String] = ["*": "*", "_": "_", "`": "`", "~": "~", "$": "$", "=": "=", "(": ")", "[": "]", "{": "}"]
    private static let closers: Set<String> = [")", "]", "}"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if autoPair, replacementRange.location == NSNotFound, !hasMarkedText(), text.utf16.count == 1, handlePair(text) {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Port of `markdownAutoPair` plus the bracket closer: pairs `* _ ` ~ $ =` and brackets,
    /// wraps a selection, and steps over a closing half that is already there.
    private func handlePair(_ text: String) -> Bool {
        let range = selectedRange()
        let all = nsString
        let symmetric = Self.pairs[text] == text
        if range.length == 0, range.location < all.length, symmetric || Self.closers.contains(text),
           all.substring(with: NSRange(location: range.location, length: 1)) == text {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return true
        }
        guard let close = Self.pairs[text] else { return false }
        if range.length > 0 {
            let selected = all.substring(with: range)
            edit([(range, text + selected + close)], select: NSRange(location: range.location + 1, length: (selected as NSString).length))
            return true
        }
        let previous = range.location > 0 ? all.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let next = range.location < all.length ? all.substring(with: NSRange(location: range.location, length: 1)) : ""
        if symmetric {
            // Don't pair mid-word (`can't`, `foo_bar`, `2*3`), and let `**` / `$$` be typed as doubles.
            if let scalar = previous.unicodeScalars.first, CharacterSet.alphanumerics.contains(scalar) || previous == "_" { return false }
            if previous == text { return false }
        } else if let scalar = next.unicodeScalars.first, CharacterSet.alphanumerics.contains(scalar) {
            return false
        }
        edit([(range, text + close)], select: NSRange(location: range.location + 1, length: 0))
        return true
    }

    override func doCommand(by selector: Selector) {
        if let completion, completion.isVisible {
            switch selector {
            case #selector(moveUp(_:)): completion.move(-1); return
            case #selector(moveDown(_:)): completion.move(1); return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                acceptCompletion(); return
            case #selector(cancelOperation(_:)):
                hideCompletion(); return
            default: break
            }
        }
        super.doCommand(by: selector)
    }

    override func insertNewline(_ sender: Any?) {
        if smartEnter() { return }
        super.insertNewline(sender)
        if typewriterMode { centerCaret() }
    }

    override func deleteBackward(_ sender: Any?) {
        if smartBackspace() { return }
        // Deleting the opening half of an empty pair removes both.
        let range = selectedRange()
        if autoPair, range.length == 0, range.location > 0, range.location < nsString.length {
            let previous = nsString.substring(with: NSRange(location: range.location - 1, length: 1))
            let next = nsString.substring(with: NSRange(location: range.location, length: 1))
            if let close = Self.pairs[previous], close == next, previous != "_" {
                edit([(NSRange(location: range.location - 1, length: 2), "")], select: NSRange(location: range.location - 1, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        if indentListItems(outdent: false) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if indentListItems(outdent: true) { return }
        super.insertBacktab(sender)
    }

    private func smartEnter() -> Bool {
        let range = selectedRange()
        guard range.length == 0, !hasMarkedText() else { return false }
        let line = lineRange(at: range.location)
        let lineText = nsString.substring(with: line)
        let before = nsString.substring(with: NSRange(location: line.location, length: range.location - line.location))
        let trimmedLine = lineText.trimmingCharacters(in: .whitespaces)
        if let match = Self.bulletRx.first(before) {
            let marker = match.group(0, in: before) ?? ""
            if before.trimmingCharacters(in: .whitespaces) == marker.trimmingCharacters(in: .whitespaces), trimmedLine == marker.trimmingCharacters(in: .whitespaces) {
                return endBlock(line)
            }
            let next = "\n" + (match.group(1, in: before) ?? "") + (match.group(2, in: before) ?? "-") + (match.group(3, in: before) ?? " ") + (match.group(4, in: before) != nil ? "[ ] " : "")
            return edit([(range, next)], select: NSRange(location: range.location + next.utf16Length, length: 0))
        }
        if let match = Self.orderedRx.first(before) {
            let marker = match.group(0, in: before) ?? ""
            if before.trimmingCharacters(in: .whitespaces) == marker.trimmingCharacters(in: .whitespaces), trimmedLine == marker.trimmingCharacters(in: .whitespaces) {
                return endBlock(line)
            }
            let number = (Int(match.group(2, in: before) ?? "0") ?? 0) + 1
            let next = "\n" + (match.group(1, in: before) ?? "") + String(number) + (match.group(3, in: before) ?? ".") + (match.group(4, in: before) ?? " ")
            return edit([(range, next)], select: NSRange(location: range.location + next.utf16Length, length: 0))
        }
        if let match = Self.quoteRx.first(before) {
            if trimmedLine == ">" { return endBlock(line) }
            let next = "\n" + (match.group(1, in: before) ?? "") + "> "
            return edit([(range, next)], select: NSRange(location: range.location + next.utf16Length, length: 0))
        }
        return false
    }

    /// An empty list item or quote line ends the block.
    private func endBlock(_ line: NSRange) -> Bool {
        let atEnd = line.location + line.length >= nsString.length
        let insert = atEnd ? "\n" : ""
        return edit([(line, insert)], select: NSRange(location: line.location + insert.utf16Length, length: 0))
    }

    private func smartBackspace() -> Bool {
        let range = selectedRange()
        guard range.length == 0 else { return false }
        let line = lineRange(at: range.location)
        let text = nsString.substring(with: line)
        guard let match = Self.bulletRx.first(text) ?? Self.orderedRx.first(text) else { return false }
        let marker = match.range.length
        guard range.location == line.location + marker else { return false }
        let indent = (match.group(1, in: text) ?? "").utf16Length
        return edit([(NSRange(location: line.location + indent, length: marker - indent), "")], select: NSRange(location: line.location + indent, length: 0))
    }

    @discardableResult
    func indentListItems(outdent: Bool) -> Bool {
        let lines = selectedLineRanges().filter { line in
            let text = nsString.substring(with: line)
            return Self.bulletRx.test(text) || Self.orderedRx.test(text)
        }
        guard !lines.isEmpty else { return false }
        let unit = "    "
        var changes: [(range: NSRange, text: String)] = []
        for line in lines {
            let text = nsString.substring(with: line)
            let indent = String(text.prefix { $0 == " " || $0 == "\t" })
            if outdent {
                var trimmed = indent
                if indent.hasPrefix(unit) { trimmed = String(indent.dropFirst(4)) }
                else if indent.hasPrefix("\t") { trimmed = String(indent.dropFirst()) }
                else { trimmed = Rx("^ {1,4}").replace(indent, template: "") }
                if trimmed != indent { changes.append((NSRange(location: line.location, length: indent.utf16Length), trimmed)) }
            } else {
                changes.append((NSRange(location: line.location, length: 0), unit))
            }
        }
        guard !changes.isEmpty else { return false }
        let old = selectedRange()
        let firstLine = lines[0]
        let delta = changes.first { $0.range.location == firstLine.location }.map { $0.text.utf16Length - $0.range.length } ?? 0
        edit(changes)
        let shifted = max(firstLine.location, old.location + delta)
        let total = changes.reduce(0) { $0 + $1.text.utf16Length - $1.range.length }
        setSelectedRange(NSRange(location: shifted, length: max(0, old.length + (old.length > 0 ? total - delta : 0))))
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        if !livePreview.sourceMode, event.clickCount == 1, let checkbox = livePreview.checkbox(at: containerPoint) {
            toggleCheckbox(checkbox)
            return
        }
        if event.modifierFlags.contains(.command), let target = linkTarget(at: point) {
            host?.markdownTextView(self, openLink: target.target, wiki: target.wiki)
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(_ hide: MDHide) {
        guard case .checkbox(let checked) = hide.widget else { return }
        let inner = NSRange(location: hide.range.location + 1, length: 1)
        let keep = selectedRanges
        edit([(inner, checked ? " " : "x")])
        selectedRanges = keep
    }

    /// The link under `point` (view coordinates), if any.
    func linkTarget(at point: NSPoint) -> (target: String, wiki: Bool)? {
        let index = characterIndexForInsertion(at: point)
        guard index <= markdownStorage.length else { return nil }
        return linkTarget(atCharacter: index)
    }

    func linkTarget(atCharacter index: Int) -> (target: String, wiki: Bool)? {
        let doc = markdownStorage.document
        let probe = NSRange(location: max(0, index - 1), length: 2)
        let spans = doc.styles(in: probe)
        let text = nsString
        func contains(_ span: MDStyleSpan) -> Bool { index >= span.range.location && index <= span.range.location + span.range.length }
        if let wiki = spans.first(where: { $0.style == .wikiLink && contains($0) }) {
            let inner = NSRange(location: wiki.range.location + 2, length: max(0, wiki.range.length - 4))
            var target = text.substring(with: inner)
            if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
            return (target.trimmingCharacters(in: .whitespaces), true)
        }
        if let link = spans.first(where: { $0.style == .link && contains($0) }) {
            if let url = doc.styles(in: link.range).first(where: { $0.style == .url && $0.range.location >= link.range.location && $0.range.location + $0.range.length <= link.range.location + link.range.length }) {
                return (text.substring(with: url.range), false)
            }
        }
        if let auto = spans.first(where: { $0.style == .autolink && contains($0) }) {
            var target = text.substring(with: auto.range)
            if target.hasPrefix("<") { target = String(target.dropFirst().dropLast()) }
            return (target, false)
        }
        if let url = spans.first(where: { $0.style == .url && contains($0) }) {
            return (text.substring(with: url.range), false)
        }
        return nil
    }

    // MARK: Paste and drop

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let markdown = assetMarkdown(from: pboard) {
            insertText(markdown, replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        if let markdown = assetMarkdown(from: board) {
            let index = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: index, length: 0))
            insertText(markdown, replacementRange: selectedRange())
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Files and image data on the pasteboard become assets beside the note.
    private func assetMarkdown(from board: NSPasteboard) -> String? {
        guard let host else { return nil }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return host.markdownTextView(self, insertAssets: urls)
        }
        if board.string(forType: .string) == nil {
            if let png = board.data(forType: .png) { return host.markdownTextView(self, insertImageData: png, fileExtension: "png") }
            if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                return host.markdownTextView(self, insertImageData: png, fileExtension: "png")
            }
        }
        return nil
    }

    // MARK: Completion

    private func completionContext() -> (start: Int, query: String, wiki: Bool)? {
        let range = selectedRange()
        guard range.length == 0 else { return nil }
        let line = lineRange(at: range.location)
        let before = nsString.substring(with: NSRange(location: line.location, length: range.location - line.location))
        if let context = Completions.wikiLinkContext(before) {
            return (line.location + context.start, context.query, true)
        }
        if let context = Completions.tagContext(before) {
            return (line.location + context.start, context.query, false)
        }
        return nil
    }

    private var acceptingCompletion = false

    func updateCompletion() {
        guard !acceptingCompletion else { return }
        guard let context = completionContext(), let host, window != nil else { hideCompletion(); return }
        let items = context.wiki
            ? host.markdownTextView(self, noteCompletionsFor: context.query)
            : host.markdownTextView(self, tagCompletionsFor: context.query)
        guard !items.isEmpty else { hideCompletion(); return }
        let popup = completion ?? CompletionPopup()
        completion = popup
        popup.onAccept = { [weak self] in self?.acceptCompletion() }
        let caretRect = firstRect(forCharacterRange: NSRange(location: context.start, length: 0), actualRange: nil)
        popup.show(items: items, below: caretRect, parent: window!)
    }

    func hideCompletion() {
        completion?.hide()
    }

    private func acceptCompletion() {
        guard let popup = completion, let item = popup.selectedItem, let context = completionContext() else { hideCompletion(); return }
        hideCompletion()
        acceptingCompletion = true
        defer { acceptingCompletion = false }
        let caret = selectedRange().location
        let replace = NSRange(location: context.start, length: caret - context.start)
        if item.isWiki {
            let line = lineRange(at: caret)
            let after = nsString.substring(with: NSRange(location: caret, length: line.location + line.length - caret))
            let insertion = Completions.wikiInsertion(insert: item.insert, alias: item.alias, after: after)
            let range = NSRange(location: replace.location, length: replace.length + insertion.replace)
            edit([(range, insertion.text)], select: NSRange(location: replace.location + insertion.cursor, length: 0))
        } else {
            edit([(replace, item.insert)], select: NSRange(location: replace.location + item.insert.utf16Length, length: 0))
        }
    }

    override func resignFirstResponder() -> Bool {
        hideCompletion()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideCompletion() }
        super.viewWillMove(toWindow: newWindow)
    }
}

extension Notification.Name {
    static let frisketSelectionChanged = Notification.Name("FrisketSelectionChanged")
}

/// A small list of completions under the caret.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private var items: [CompletionItem] = []
    var onAccept: (() -> Void)?
    private weak var parent: NSWindow?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        scroll.documentView = table
        effect.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }
    var selectedItem: CompletionItem? { table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil }

    func show(items: [CompletionItem], below rect: NSRect, parent: NSWindow) {
        self.items = items
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let height = min(CGFloat(items.count), 8) * table.rowHeight + 8
        let frame = NSRect(x: rect.minX - 8, y: rect.minY - height - 4, width: 320, height: height)
        panel.setFrame(frame, display: true)
        if self.parent !== parent {
            self.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            self.parent = parent
        }
        panel.orderFront(nil)
        table.scrollRowToVisible(0)
    }

    func hide() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func doubleClicked() { onAccept?() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: item.label)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, detail])
        stack.orientation = .horizontal
        stack.spacing = 8
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
