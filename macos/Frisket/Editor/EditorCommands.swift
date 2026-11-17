import AppKit
import FrisketBase

/// Formatting commands, a port of editor/commands.js. Each is an action the
/// menus send down the responder chain to the focused editor.
extension MarkdownTextView {
    // MARK: Inline

    /// Wrap each selection in `before`/`after`, or unwrap it if it is already wrapped.
    func toggleWrap(_ before: String, _ after: String? = nil) {
        let after = after ?? before
        let text = nsString
        let b = before.utf16Length, a = after.utf16Length
        var changes: [(range: NSRange, text: String)] = []
        var selections: [NSRange] = []
        var shift = 0
        for value in selectedRanges {
            let range = value.rangeValue
            let from = range.location, to = range.location + range.length
            let outsideWrapped = from - b >= 0 && to + a <= text.length
                && text.substring(with: NSRange(location: from - b, length: b)) == before
                && text.substring(with: NSRange(location: to, length: a)) == after
            let selected = text.substring(with: range)
            let insideWrapped = range.length >= b + a && selected.hasPrefix(before) && selected.hasSuffix(after)
            if outsideWrapped {
                changes.append((NSRange(location: from - b, length: b), ""))
                changes.append((NSRange(location: to, length: a), ""))
                selections.append(NSRange(location: from - b + shift, length: range.length))
                shift -= b + a
            } else if insideWrapped {
                let inner = (selected as NSString).substring(with: NSRange(location: b, length: range.length - b - a))
                changes.append((range, inner))
                selections.append(NSRange(location: from + shift, length: inner.utf16Length))
                shift -= b + a
            } else if range.length == 0 {
                changes.append((range, before + after))
                selections.append(NSRange(location: from + shift + b, length: 0))
                shift += b + a
            } else {
                changes.append((NSRange(location: from, length: 0), before))
                changes.append((NSRange(location: to, length: 0), after))
                selections.append(NSRange(location: from + shift + b, length: range.length))
                shift += b + a
            }
        }
        if edit(changes) { selectedRanges = selections.map { NSValue(range: $0) } }
    }

    @objc func toggleBold(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleWrap("*") }
    @objc func toggleUnderlineMarkup(_ sender: Any?) { toggleWrap("<u>", "</u>") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func toggleHighlight(_ sender: Any?) { toggleWrap("==") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleWrap("`") }
    @objc func toggleInlineMath(_ sender: Any?) { toggleWrap("$") }
    @objc func toggleSuperscript(_ sender: Any?) { toggleWrap("^") }
    @objc func toggleSubscript(_ sender: Any?) { toggleWrap("~") }

    // NSTextView's own bold/italic/underline actions are retargeted to Markdown.
    override func underline(_ sender: Any?) { toggleWrap("<u>", "</u>") }

    // MARK: Headings

    private static let headingPrefix = Rx("^(\\s*)(#{1,6})(\\s+)?")

    func setHeading(_ level: Int) {
        var changes: [(range: NSRange, text: String)] = []
        for line in selectedLineRanges() {
            let text = nsString.substring(with: line)
            let match = Self.headingPrefix.first(text)
            let indent = match?.group(1, in: text) ?? String(text.prefix { $0 == " " || $0 == "\t" })
            let bodyFrom = match.map { $0.range.length } ?? indent.utf16Length
            let prefix = level > 0 ? indent + String(repeating: "#", count: level) + " " : indent
            changes.append((NSRange(location: line.location, length: bodyFrom), prefix))
        }
        let caret = selectedRange()
        let before = changes.first.map { $0.text.utf16Length - $0.range.length } ?? 0
        if edit(changes), caret.length == 0 {
            setSelectedRange(NSRange(location: max(changes[0].range.location, caret.location + before), length: 0))
        }
    }

    @objc func applyHeading(_ sender: Any?) {
        setHeading((sender as? NSMenuItem)?.tag ?? 0)
    }

    func adjustHeading(_ delta: Int) {
        let line = lineRange(at: selectedRange().location)
        let text = nsString.substring(with: line)
        let current = Self.headingPrefix.first(text)?.group(2, in: text)?.count ?? 0
        setHeading(max(0, min(6, current + delta)))
    }

    @objc func increaseHeadingLevel(_ sender: Any?) { adjustHeading(1) }
    @objc func decreaseHeadingLevel(_ sender: Any?) { adjustHeading(-1) }

    // MARK: Lists and quotes

    enum ListKind { case bullet, ordered, task }

    func toggleList(_ kind: ListKind) {
        let lines = selectedLineRanges()
        func isKind(_ text: String) -> Bool {
            let bullet = Self.bulletRx.first(text)
            switch kind {
            case .bullet: return bullet != nil && bullet?.group(4, in: text) == nil
            case .task: return bullet?.group(4, in: text) != nil
            case .ordered: return Self.orderedRx.test(text)
            }
        }
        let texts = lines.map { nsString.substring(with: $0) }
        let allMatch = !lines.isEmpty && texts.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || isKind($0) }
        var changes: [(range: NSRange, text: String)] = []
        var counter = 1
        for (line, text) in zip(lines, texts) where !text.trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = String(text.prefix { $0 == " " || $0 == "\t" })
            let strip = Self.bulletRx.first(text)?.range.length ?? Self.orderedRx.first(text)?.range.length ?? indent.utf16Length
            let range = NSRange(location: line.location, length: strip)
            if allMatch { changes.append((range, indent)); continue }
            switch kind {
            case .bullet: changes.append((range, indent + "- "))
            case .task: changes.append((range, indent + "- [ ] "))
            case .ordered: changes.append((range, indent + "\(counter). ")); counter += 1
            }
        }
        let caret = selectedRange()
        if edit(changes), caret.length == 0, lines.count == 1, let change = changes.first {
            setSelectedRange(NSRange(location: max(change.range.location + change.text.utf16Length, caret.location + change.text.utf16Length - change.range.length), length: 0))
        }
    }

    @objc func toggleBulletList(_ sender: Any?) { toggleList(.bullet) }
    @objc func toggleOrderedList(_ sender: Any?) { toggleList(.ordered) }
    @objc func toggleTaskList(_ sender: Any?) { toggleList(.task) }

    @objc func toggleBlockquote(_ sender: Any?) {
        let lines = selectedLineRanges()
        let quote = Rx("^(\\s*)>\\s?")
        let texts = lines.map { nsString.substring(with: $0) }
        let allQuoted = !lines.isEmpty && texts.allSatisfy { quote.test($0) || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        var changes: [(range: NSRange, text: String)] = []
        for (line, text) in zip(lines, texts) {
            if allQuoted {
                if let match = quote.first(text) {
                    changes.append((NSRange(location: line.location, length: match.range.length), match.group(1, in: text) ?? ""))
                }
            } else {
                changes.append((NSRange(location: line.location, length: 0), "> "))
            }
        }
        edit(changes)
    }

    @objc func indentItems(_ sender: Any?) { if !indentListItems(outdent: false) { insertTab(sender) } }
    @objc func outdentItems(_ sender: Any?) { indentListItems(outdent: true) }

    // MARK: Blocks

    private func insertBlock(open: String, close: String, body: String = "", caretOffset: Int? = nil) {
        let range = selectedRange()
        let line = lineRange(at: range.location)
        let selected = nsString.substring(with: range)
        let content = selected.isEmpty ? body : selected
        let lineText = nsString.substring(with: line)
        let needsBreak = line.location != range.location || !lineText.trimmingCharacters(in: .whitespaces).isEmpty
        let prefix = needsBreak ? "\n\n" : ""
        let text = prefix + open + "\n" + content + "\n" + close + "\n"
        let lastLine = lineRange(at: range.location + range.length)
        let insertAt = needsBreak ? max(lastLine.location + lastLine.length, range.location + range.length) : line.location
        let caret = caretOffset.map { insertAt + prefix.utf16Length + $0 }
            ?? insertAt + prefix.utf16Length + open.utf16Length + 1 + content.utf16Length
        let end = max(insertAt, range.location + range.length)
        // A selection that is moved into the block is removed from where it was.
        var changes: [(range: NSRange, text: String)] = [(NSRange(location: insertAt, length: needsBreak ? 0 : end - insertAt), text)]
        if needsBreak && range.length > 0 { changes.append((range, "")) }
        let removed = needsBreak && range.length > 0 && range.location < insertAt ? range.length : 0
        edit(changes, select: NSRange(location: caret - removed, length: 0))
    }

    @objc func insertCodeFence(_ sender: Any?) { insertBlock(open: "```", close: "```", caretOffset: 3) }
    @objc func insertMathBlock(_ sender: Any?) { insertBlock(open: "$$", close: "$$") }

    @objc func insertHorizontalRule(_ sender: Any?) {
        let line = lineRange(at: selectedRange().location)
        let prefix = nsString.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n\n"
        let end = line.location + line.length
        edit([(NSRange(location: end, length: 0), prefix + "---\n")], select: NSRange(location: end + prefix.utf16Length + 4, length: 0))
    }

    func insertTable(rows: Int = 2, columns: Int = 3) {
        let line = lineRange(at: selectedRange().location)
        let header = "| " + (1...columns).map { "Column \($0)" }.joined(separator: " | ") + " |"
        let divider = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let body = (0..<rows).map { _ in "| " + Array(repeating: "   ", count: columns).joined(separator: " | ") + " |" }.joined(separator: "\n")
        let prefix = nsString.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n\n"
        let end = line.location + line.length
        let text = prefix + header + "\n" + divider + "\n" + body + "\n"
        edit([(NSRange(location: end, length: 0), text)], select: NSRange(location: end + prefix.utf16Length + 2, length: "Column 1".utf16Length))
    }

    @objc func insertTableAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Insert Table"
        alert.informativeText = "Choose the size of the new table."
        let rows = NSTextField(string: "2"), columns = NSTextField(string: "3")
        for field in [rows, columns] { field.alignment = .right; field.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Body rows:"), rows], [NSTextField(labelWithString: "Columns:"), columns]])
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 200, height: 56)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = rows
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let r = max(1, min(50, Int(rows.stringValue) ?? 2)), c = max(1, min(20, Int(columns.stringValue) ?? 3))
            self?.insertTable(rows: r, columns: c)
        }
    }

    // MARK: Links and images

    func insertLink(url: String = "") {
        let range = selectedRange()
        let selected = nsString.substring(with: range)
        let looksLikeURL = Rx("^(https?://|mailto:|www\\.)", [.caseInsensitive]).test(selected.trimmingCharacters(in: .whitespaces))
        let label = looksLikeURL ? "" : selected
        let href = url.isEmpty ? (looksLikeURL ? selected.trimmingCharacters(in: .whitespaces) : "") : url
        let text = "[" + label + "](" + href + ")"
        let caret: Int
        if !href.isEmpty && !label.isEmpty { caret = range.location + text.utf16Length }
        else if !label.isEmpty { caret = range.location + text.utf16Length - 1 }
        else { caret = range.location + 1 }
        edit([(range, text)], select: NSRange(location: caret, length: 0))
    }

    @objc func insertLinkAction(_ sender: Any?) { insertLink() }

    func insertMarkdown(_ text: String) {
        let range = selectedRange()
        edit([(range, text)], select: NSRange(location: range.location + text.utf16Length, length: 0))
    }

    @objc func insertImageAction(_ sender: Any?) { pickAsset(images: true) }
    @objc func insertAttachmentAction(_ sender: Any?) { pickAsset(images: false) }

    private func pickAsset(images: Bool) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = images ? "Insert Image" : "Attach File"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if images { panel.allowedContentTypes = [.image] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let markdown = self.host?.markdownTextView(self, insertAssets: [url]) else { return }
            self.insertMarkdown(markdown)
        }
    }

    // MARK: Clear

    @objc func clearFormatting(_ sender: Any?) {
        var changes: [(range: NSRange, text: String)] = []
        for value in selectedRanges where value.rangeValue.length > 0 {
            var text = nsString.substring(with: value.rangeValue)
            text = Rx("^(\\s*)(#{1,6}\\s+|>\\s+|[-*+]\\s+(\\[[ xX]\\]\\s+)?|\\d+[.)]\\s+)", [.anchorsMatchLines]).replace(text, template: "$1")
            text = Rx("(\\*\\*\\*|___|\\*\\*|__|~~|==|\\*|_|`)").replace(text, template: "")
            text = Rx("\\[([^\\]]*)\\]\\([^)]*\\)").replace(text, template: "$1")
            changes.append((value.rangeValue, text))
        }
        if let first = changes.first {
            edit(changes, select: NSRange(location: first.range.location, length: first.text.utf16Length))
        }
    }

    // MARK: Navigation

    @objc func jumpToTop(_ sender: Any?) { setSelectedRange(NSRange(location: 0, length: 0)); scrollRangeToVisible(selectedRange()) }
    @objc func jumpToBottom(_ sender: Any?) {
        setSelectedRange(NSRange(location: nsString.length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Move the caret to `location` and show it near the top of the view.
    func reveal(_ range: NSRange) {
        let clamped = NSRange(location: min(range.location, nsString.length), length: min(range.length, max(0, nsString.length - range.location)))
        setSelectedRange(clamped)
        scrollRangeToVisible(clamped)
        showFindIndicator(for: clamped)
    }
}
