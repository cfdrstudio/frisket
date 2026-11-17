import Foundation

/// Scans a note into the structure the live-preview editor needs. Block rules
/// follow CommonMark/GFM as @lezer/markdown applies them, plus Frisket's front
/// matter, `$$` math blocks and diagram fences.
public enum MarkdownScanner {
    /// Fence languages drawn as diagrams (markdown.js `DIAGRAM_LANGS`).
    public static let diagramLanguages: Set<String> = ["mermaid", "sequence", "flow", "flowchart", "gantt"]

    public static func scan(_ text: String) -> MDDocument {
        var parser = BlockParser(Array(text.utf16))
        return parser.run()
    }

    /// Inline styles and masks for a standalone snippet, such as a table cell.
    public static func inline(_ text: String) -> (styles: [MDStyleSpan], hides: [MDHide]) {
        let units = Array(text.utf16)
        var parser = InlineParser(units)
        parser.parse(0, units.count)
        return (parser.styles.sorted { $0.range.location < $1.range.location }, parser.hides.sorted { $0.range.location < $1.range.location })
    }

    /// `text` with inline syntax marks removed (`**a** [b](c)` → `a b`), for outlines and table cells.
    public static func plainText(_ text: String) -> String {
        let units = Array(text.utf16)
        var parser = InlineParser(units)
        parser.parse(0, units.count)
        var drop = [Bool](repeating: false, count: units.count)
        for hide in parser.hides where hide.widget == nil {
            for k in hide.range.location..<(hide.range.location + hide.range.length) { drop[k] = true }
        }
        var kept: [UInt16] = []
        kept.reserveCapacity(units.count)
        for (k, unit) in units.enumerated() where !drop[k] { kept.append(unit) }
        return String(decoding: kept, as: UTF16.self)
    }

    /// Split a table row into cell texts: outer pipes dropped, `\|` and pipes in code kept.
    public static func tableCells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }
}

private let imageOnly = try! NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(\\s*<?([^\\s>)]*)>?(?:\\s+[\"'(].*)?\\s*\\)$")
private let yamlKey = try! NSRegularExpression(pattern: "^\\s*(?:[A-Za-z_][\\w.-]*\\s*:|#|-\\s|---\\s*$)")
private let tableDelimiter = try! NSRegularExpression(pattern: "^\\s*\\|?\\s*:?-+:?\\s*(?:\\|\\s*:?-+:?\\s*)*\\|?\\s*$")

struct BlockParser {
    let c: [UInt16]
    var starts: [(start: Int, end: Int, next: Int)] = []
    var lines: [MDLine] = []
    var blocks: [MDBlock] = []
    var blockLines: [(first: Int, last: Int)] = []
    var inline: InlineParser
    var blockHides: [MDHide] = []
    var headings: [MDHeading] = []

    // Open paragraph (line indices), and the list item it belongs to, if any.
    var paragraph: (first: Int, last: Int, contentStart: Int, quote: Int, item: Bool)?
    // Indentation columns of the open list levels: marker column and content column.
    var listStack: [(marker: Int, content: Int)] = []
    var previousBlank = false

    init(_ chars: [UInt16]) {
        c = chars
        inline = InlineParser(chars)
        var i = 0, start = 0
        let n = chars.count
        while i < n {
            if chars[i] == U.newline {
                starts.append((start, i, i + 1)); i += 1; start = i
            } else if chars[i] == U.carriageReturn {
                let end = i
                i += (i + 1 < n && chars[i + 1] == U.newline) ? 2 : 1
                starts.append((start, end, i)); start = i
            } else { i += 1 }
        }
        starts.append((start, n, n))
    }

    // MARK: Helpers

    func text(_ from: Int, _ to: Int) -> String { String(decoding: c[from..<to], as: UTF16.self) }

    func isBlank(_ from: Int, _ to: Int) -> Bool {
        var i = from
        while i < to { if c[i] != U.space && c[i] != U.tab { return false }; i += 1 }
        return true
    }

    /// Leading whitespace in columns (tab = to next multiple of 4) and the first non-blank index.
    func indent(_ from: Int, _ to: Int) -> (columns: Int, index: Int) {
        var columns = 0, i = from
        while i < to {
            if c[i] == U.space { columns += 1 } else if c[i] == U.tab { columns += 4 - columns % 4 } else { break }
            i += 1
        }
        return (columns, i)
    }

    func matches(_ regex: NSRegularExpression, _ from: Int, _ to: Int) -> NSTextCheckingResult? {
        let string = text(from, to)
        return regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }

    func lineRange(_ k: Int) -> NSRange { NSRange(location: starts[k].start, length: starts[k].end - starts[k].start) }

    /// From the start of line `first` to the end of line `last`, without the final terminator.
    func span(_ first: Int, _ last: Int) -> NSRange {
        NSRange(location: starts[first].start, length: starts[last].end - starts[first].start)
    }

    mutating func addBlock(_ kind: MDBlockKind, _ first: Int, _ last: Int) {
        let index = blocks.count
        for k in first...last { lines[k].block = index }
        let range = NSRange(location: starts[first].start, length: starts[last].next - starts[first].start)
        blocks.append(MDBlock(range: range, kind: kind, signature: 0))
        blockLines.append((first, last))
    }

    // MARK: Run

    mutating func run() -> MDDocument {
        let n = starts.count
        lines = (0..<n).map { k in
            MDLine(range: NSRange(location: starts[k].start, length: starts[k].end - starts[k].start),
                   fullRange: NSRange(location: starts[k].start, length: starts[k].next - starts[k].start),
                   kind: .blank, quoteDepth: 0, list: nil, listDepth: nil, listContentColumn: 0, block: 0)
        }
        var k = frontMatter()
        while k < n { k = line(k) }
        closeParagraph()
        // Lines left without a block (none expected) get their own.
        for (index, block) in zip(blocks.indices, blockLines) {
            var hasher = Hasher()
            hasher.combine(blocks[index].kind.hashValue)
            for line in block.first...block.last {
                let info = lines[line]
                hasher.combine(String(describing: info.kind))
                hasher.combine(info.quoteDepth)
                hasher.combine(info.listDepth ?? -1)
                hasher.combine(info.listContentColumn)
                hasher.combine(info.list?.depth ?? -1)
            }
            let range = blocks[index].range
            c.withUnsafeBufferPointer { buffer in
                let slice = UnsafeBufferPointer(rebasing: buffer[range.location..<(range.location + range.length)])
                hasher.combine(bytes: UnsafeRawBufferPointer(slice))
            }
            blocks[index].signature = hasher.finalize()
        }
        let styles = inline.styles.sorted { $0.range.location < $1.range.location }
        let hides = inline.hides.sorted { $0.range.location < $1.range.location }
        return MDDocument(length: c.count, lines: lines, blocks: blocks, styles: styles, hides: hides,
                          blockHides: blockHides.sorted { $0.range.location < $1.range.location }, headings: headings)
    }

    // MARK: Front matter

    /// Front matter at the very top; returns the first line after it.
    mutating func frontMatter() -> Int {
        guard starts.count > 1 else { return 0 }
        let first = starts[0]
        let firstText = text(first.start, first.end)
        guard firstText.range(of: "^---\\s*$", options: .regularExpression) != nil,
              matches(yamlKey, starts[1].start, starts[1].end) != nil else { return 0 }
        var last = starts.count - 1
        for k in 1..<starts.count {
            let t = text(starts[k].start, starts[k].end)
            if t.range(of: "^(---|\\.\\.\\.)\\s*$", options: .regularExpression) != nil { last = k; break }
        }
        let whole = span(0, last)
        for k in 0...last {
            let fence = k == 0 || (k == last && last > 0 && text(starts[k].start, starts[k].end).range(of: "^(---|\\.\\.\\.)\\s*$", options: .regularExpression) != nil)
            lines[k].kind = fence ? .frontMatterFence : .frontMatter
            if fence { inline.style(starts[k].start, min(starts[k].start + 3, starts[k].end), .mark) }
        }
        _ = whole
        addBlock(.frontMatter, 0, last)
        return last + 1
    }

    // MARK: Lines

    /// Parse the block starting at line `k`; returns the next unparsed line.
    mutating func line(_ k: Int) -> Int {
        let (s, e, _) = starts[k]
        // Block quote prefix.
        var p = s
        var depth = 0
        while true {
            let (columns, first) = indent(p, e)
            if columns <= 3, first < e, c[first] == U.greater {
                var q = first + 1
                while q < e, c[q] == U.space || c[q] == U.tab { q += 1 }
                inline.mark(first, q, owner: lineRange(k), mode: .lines)
                depth += 1
                p = q
            } else { break }
        }
        lines[k].quoteDepth = depth
        let content = p

        if isBlank(content, e) {
            closeParagraph()
            lines[k].kind = .blank
            addBlock(.blank, k, k)
            previousBlank = true
            return k + 1
        }
        defer { previousBlank = false }

        let (columns, first) = indent(content, e)
        if let open = paragraph, open.quote != depth { closeParagraph() }

        // After a blank line, text indented less than the open list item's content ends the list.
        if previousBlank, paragraph == nil, let top = listStack.last, columns < top.content, !isListItem(first, e) {
            listStack = listStack.filter { $0.content <= columns }
        }
        let allowance = (listStack.last?.content ?? 0) + 3

        // Fenced code.
        if columns <= allowance, let fence = fenceOpen(first, e) {
            closeParagraph()
            return fencedCode(k, first, fence: fence)
        }
        // Math block.
        if columns <= allowance, first + 1 < e, c[first] == U.dollar, c[first + 1] == U.dollar {
            closeParagraph()
            return mathBlock(k, first)
        }
        // ATX heading.
        if columns <= 3, let level = atxLevel(first, e) {
            closeParagraph()
            heading(k, first, e, level: level)
            return k + 1
        }
        // Setext underline.
        if columns <= 3, let open = paragraph, !open.item, let level = setextLevel(first, e) {
            setext(open, underline: k, level: level, first, e)
            return k + 1
        }
        // Horizontal rule.
        if columns <= 3 + (listStack.last?.content ?? 0), isRule(first, e) {
            closeParagraph()
            lines[k].kind = .rule
            inline.style(first, e, .hrSource)
            blockHides.append(MDHide(range: lineRange(k), mode: .lines, owner: lineRange(k), widget: .rule))
            addBlock(.rule, k, k)
            return k + 1
        }
        // Table.
        if paragraph == nil, k + 1 < starts.count, contains(U.pipe, first, e), matches(tableDelimiter, starts[k + 1].start, starts[k + 1].end) != nil {
            return table(k)
        }
        // List item.
        if let item = listMarker(first, e) {
            closeParagraph()
            listItem(k, first, e, columns: columns, item: item)
            return k + 1
        }
        // HTML comment block.
        if paragraph == nil, e - first >= 4, c[first] == U.less, c[first + 1] == U.bang, c[first + 2] == U.minus, c[first + 3] == U.minus {
            return htmlBlock(k, comment: true)
        }
        // HTML block.
        if paragraph == nil, columns <= 3, isHTMLStart(first, e) {
            return htmlBlock(k, comment: false)
        }
        // Indented code (not inside a list).
        if paragraph == nil, listStack.isEmpty, columns >= 4 {
            lines[k].kind = .indentedCode
            inline.style(first, e, .inlineCode)
            addBlock(.code, k, k)
            return k + 1
        }
        // Paragraph text.
        if var open = paragraph {
            open.last = k
            paragraph = open
            lines[k].kind = .paragraph
            if open.item, !listStack.isEmpty {
                lines[k].listDepth = listStack.count - 1
                lines[k].listContentColumn = first - s
            }
        } else {
            let inItem = !listStack.isEmpty && columns >= (listStack.last?.content ?? 0)
            if !inItem { listStack = [] }
            paragraph = (k, k, first, depth, inItem)
            lines[k].kind = .paragraph
            if inItem {
                lines[k].listDepth = listStack.count - 1
                lines[k].listContentColumn = first - s
            }
        }
        return k + 1
    }

    func contains(_ unit: UInt16, _ from: Int, _ to: Int) -> Bool {
        var i = from
        while i < to { if c[i] == unit { return true }; i += 1 }
        return false
    }

    // MARK: Paragraphs

    mutating func closeParagraph() {
        guard let open = paragraph else { return }
        paragraph = nil
        let start = open.contentStart
        let end = starts[open.last].end
        if open.quote > 0 {
            for k in open.first...open.last {
                let from = k == open.first ? start : indent(contentStart(k), starts[k].end).index
                inline.parse(from, starts[k].end)
            }
        } else {
            inline.parse(start, end)
        }
        // A paragraph holding only an image renders as a figure.
        if open.first == open.last, !open.item {
            let trimmedStart = indent(start, end).index
            var trimmedEnd = end
            while trimmedEnd > trimmedStart, c[trimmedEnd - 1] == U.space || c[trimmedEnd - 1] == U.tab { trimmedEnd -= 1 }
            if trimmedEnd - trimmedStart > 4, c[trimmedStart] == U.bang,
               let match = matches(imageOnly, trimmedStart, trimmedEnd) {
                let string = text(trimmedStart, trimmedEnd) as NSString
                let alt = match.range(at: 1).location == NSNotFound ? "" : string.substring(with: match.range(at: 1))
                let src = match.range(at: 2).location == NSNotFound ? "" : string.substring(with: match.range(at: 2))
                let range = lineRange(open.first)
                blockHides.append(MDHide(range: range, mode: .lines, owner: range, widget: .image(src: src, alt: alt)))
            }
        }
        addBlock(open.item ? .listItem : .paragraph, open.first, open.last)
    }

    func contentStart(_ k: Int) -> Int {
        var p = starts[k].start
        let e = starts[k].end
        while true {
            let (columns, first) = indent(p, e)
            if columns <= 3, first < e, c[first] == U.greater {
                p = first + 1
                while p < e, c[p] == U.space || c[p] == U.tab { p += 1 }
            } else { return p }
        }
    }

    // MARK: Headings

    func atxLevel(_ first: Int, _ e: Int) -> Int? {
        var q = first
        while q < e, c[q] == U.hash { q += 1 }
        let level = q - first
        guard level >= 1, level <= 6 else { return nil }
        if q < e, c[q] != U.space, c[q] != U.tab { return nil }
        return level
    }

    mutating func heading(_ k: Int, _ first: Int, _ e: Int, level: Int) {
        lines[k].kind = .heading(level)
        let line = lineRange(k)
        var q = first + level
        while q < e, c[q] == U.space || c[q] == U.tab { q += 1 }
        inline.mark(first, q, owner: line, mode: .lines)
        // Optional closing sequence: ` ##` at the end.
        var contentEnd = e
        while contentEnd > q, c[contentEnd - 1] == U.space || c[contentEnd - 1] == U.tab { contentEnd -= 1 }
        var hashes = contentEnd
        while hashes > q, c[hashes - 1] == U.hash { hashes -= 1 }
        if hashes < contentEnd, hashes > q, c[hashes - 1] == U.space || c[hashes - 1] == U.tab {
            var closeFrom = hashes
            while closeFrom > q, c[closeFrom - 1] == U.space || c[closeFrom - 1] == U.tab { closeFrom -= 1 }
            inline.mark(closeFrom, e, owner: line, mode: .lines)
            contentEnd = closeFrom
        } else if hashes == q && contentEnd > q {
            // A heading of only hashes after the marker is all closing sequence.
            contentEnd = q
        }
        inline.parse(q, contentEnd, tags: false)
        headings.append(MDHeading(level: level, text: MarkdownScanner.plainText(text(q, contentEnd)).trimmingCharacters(in: .whitespaces), range: line))
        addBlock(.heading, k, k)
    }

    func setextLevel(_ first: Int, _ e: Int) -> Int? {
        guard first < e, c[first] == U.equals || c[first] == U.minus else { return nil }
        let ch = c[first]
        var q = first
        while q < e, c[q] == ch { q += 1 }
        while q < e, c[q] == U.space || c[q] == U.tab { q += 1 }
        guard q == e else { return nil }
        return ch == U.equals ? 1 : 2
    }

    mutating func setext(_ open: (first: Int, last: Int, contentStart: Int, quote: Int, item: Bool), underline k: Int, level: Int, _ first: Int, _ e: Int) {
        paragraph = nil
        for line in open.first...open.last { lines[line].kind = .heading(level) }
        lines[k].kind = .setextUnderline(level)
        inline.style(first, e, .setextMark)
        inline.parse(open.contentStart, starts[open.last].end, tags: false)
        headings.append(MDHeading(level: level, text: MarkdownScanner.plainText(text(open.contentStart, starts[open.last].end)).trimmingCharacters(in: .whitespacesAndNewlines), range: span(open.first, open.last)))
        addBlock(.heading, open.first, k)
    }

    // MARK: Rules, lists

    func isRule(_ first: Int, _ e: Int) -> Bool {
        let ch = c[first]
        guard ch == U.minus || ch == U.star || ch == U.underscore else { return false }
        var count = 0, q = first
        while q < e {
            if c[q] == ch { count += 1 } else if c[q] != U.space && c[q] != U.tab { return false }
            q += 1
        }
        return count >= 3
    }

    func isListItem(_ first: Int, _ e: Int) -> Bool { listMarker(first, e) != nil }

    /// `(markerEnd, ordered)` when a list marker starts at `first`.
    func listMarker(_ first: Int, _ e: Int) -> (markerEnd: Int, ordered: Bool)? {
        guard first < e else { return nil }
        let ch = c[first]
        var markerEnd: Int
        var ordered = false
        if ch == U.minus || ch == U.plus || ch == U.star {
            markerEnd = first + 1
        } else if CharClass.isDigit(ch) {
            var q = first
            while q < e, CharClass.isDigit(c[q]), q - first < 9 { q += 1 }
            guard q < e, c[q] == U.dot || c[q] == U.closeParen else { return nil }
            markerEnd = q + 1
            ordered = true
        } else { return nil }
        if markerEnd < e, c[markerEnd] != U.space, c[markerEnd] != U.tab { return nil }
        return (markerEnd, ordered)
    }

    mutating func listItem(_ k: Int, _ first: Int, _ e: Int, columns: Int, item: (markerEnd: Int, ordered: Bool)) {
        let s = starts[k].start
        var q = item.markerEnd
        while q < e, c[q] == U.space || c[q] == U.tab { q += 1 }
        let contentColumns = columns + (q - first)
        while let top = listStack.last, top.marker >= columns { listStack.removeLast() }
        let depth = listStack.count
        listStack.append((columns, max(contentColumns, columns + 2)))

        let markerRange = NSRange(location: first, length: item.markerEnd - first)
        var task: Bool? = nil
        var taskRange: NSRange? = nil
        var contentStart = q
        if q + 2 < e, c[q] == U.openBracket, c[q + 2] == U.closeBracket,
           c[q + 1] == U.space || c[q + 1] == 120 || c[q + 1] == 88,
           q + 3 == e || c[q + 3] == U.space || c[q + 3] == U.tab {
            task = c[q + 1] != U.space
            taskRange = NSRange(location: q, length: 3)
            contentStart = q + 3
            while contentStart < e, c[contentStart] == U.space || c[contentStart] == U.tab { contentStart += 1 }
        }
        let line = lineRange(k)
        if item.ordered {
            inline.style(markerRange.location, markerRange.location + markerRange.length, .orderedMark)
        } else {
            inline.hide(markerRange.location, markerRange.location + markerRange.length, owner: line, mode: .never, widget: .bullet(depth: depth))
        }
        if let taskRange, let task {
            inline.hide(taskRange.location, taskRange.location + 3, owner: line, mode: .never, widget: .checkbox(checked: task))
        }
        lines[k].kind = .paragraph
        lines[k].list = MDListInfo(depth: depth, ordered: item.ordered, markerRange: markerRange, contentStart: contentStart, task: task, taskRange: taskRange)
        lines[k].listDepth = depth
        lines[k].listContentColumn = contentStart - s
        paragraph = (k, k, contentStart, lines[k].quoteDepth, true)
    }

    // MARK: Code, math

    /// `(fence char, length, info range)` when a code fence opens at `first`.
    func fenceOpen(_ first: Int, _ e: Int) -> (char: UInt16, length: Int, infoStart: Int, infoEnd: Int)? {
        guard first < e, c[first] == U.backtick || c[first] == U.tilde else { return nil }
        let ch = c[first]
        var q = first
        while q < e, c[q] == ch { q += 1 }
        let length = q - first
        guard length >= 3 else { return nil }
        if ch == U.backtick && contains(U.backtick, q, e) { return nil }
        let infoStart = indent(q, e).index
        var infoEnd = e
        while infoEnd > infoStart, c[infoEnd - 1] == U.space || c[infoEnd - 1] == U.tab { infoEnd -= 1 }
        return (ch, length, infoStart, infoEnd)
    }

    mutating func fencedCode(_ k: Int, _ first: Int, fence: (char: UInt16, length: Int, infoStart: Int, infoEnd: Int)) -> Int {
        var last = starts.count - 1
        var closed = false
        var close = k + 1
        while close < starts.count {
            let (s, e, _) = starts[close]
            let (columns, f) = indent(contentStart(close), e)
            _ = s
            if columns <= 3 + (listStack.last?.content ?? 0), f < e, c[f] == fence.char {
                var q = f
                while q < e, c[q] == fence.char { q += 1 }
                if q - f >= fence.length, isBlank(q, e) { last = close; closed = true; break }
            }
            close += 1
        }
        let block = span(k, last)
        let fenceEnd = first + fence.length
        lines[k].kind = .codeFence
        inline.mark(first, fenceEnd, owner: block, mode: .lines)
        inline.style(fence.infoStart, fence.infoEnd, .codeInfo)
        for line in (k + 1)...max(k + 1, last) where line <= last && line < starts.count {
            lines[line].kind = .code
            lines[line].quoteDepth = lines[k].quoteDepth
        }
        if closed {
            lines[last].kind = .codeFence
            let (columns, f) = indent(contentStart(last), starts[last].end)
            _ = columns
            inline.mark(f, starts[last].end, owner: block, mode: .lines)
        }
        let info = text(fence.infoStart, fence.infoEnd)
        let lang = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map { String($0).lowercased() } ?? ""
        if MarkdownScanner.diagramLanguages.contains(lang) {
            let bodyFirst = k + 1
            let bodyLast = closed ? last - 1 : last
            let source = bodyFirst <= bodyLast ? text(starts[bodyFirst].start, starts[bodyLast].end) : ""
            blockHides.append(MDHide(range: block, mode: .lines, owner: block, widget: .diagram(lang: lang, source: source)))
        }
        addBlock(.code, k, last)
        return last + 1
    }

    mutating func mathBlock(_ k: Int, _ first: Int) -> Int {
        let e = starts[k].end
        var last = k
        var closeAt = -1
        // A one-liner such as `$$ x^2 $$`.
        var q = first + 2
        while q + 1 < e { if c[q] == U.dollar && c[q + 1] == U.dollar { closeAt = q; break }; q += 1 }
        if closeAt < 0 {
            var line = k + 1
            while line < starts.count {
                let (s, le, _) = starts[line]
                var r = s
                while r + 1 < le { if c[r] == U.dollar && c[r + 1] == U.dollar { closeAt = r; break }; r += 1 }
                if closeAt >= 0 { last = line; break }
                line += 1
            }
            if closeAt < 0 { last = starts.count - 1 }
        }
        let block = span(k, last)
        for line in k...last { lines[line].kind = (line == k || (line == last && closeAt >= 0)) ? .mathFence : .math }
        inline.style(block.location, block.location + block.length, .mathSource)
        inline.mark(first, first + 2, owner: block, mode: .lines)
        if closeAt >= 0 { inline.mark(closeAt, closeAt + 2, owner: block, mode: .lines) }
        let bodyEnd = closeAt >= 0 ? closeAt : starts[last].end
        let latex = text(first + 2, max(first + 2, bodyEnd)).trimmingCharacters(in: .whitespacesAndNewlines)
        blockHides.append(MDHide(range: block, mode: .lines, owner: block, widget: .blockMath(latex)))
        addBlock(.math, k, last)
        return last + 1
    }

    // MARK: Tables, HTML

    mutating func table(_ k: Int) -> Int {
        var last = k + 1
        while last + 1 < starts.count {
            let (s, e, _) = starts[last + 1]
            if isBlank(s, e) || !contains(U.pipe, s, e) { break }
            last += 1
        }
        lines[k].kind = .tableHeader
        lines[k + 1].kind = .tableDelimiter
        if last > k + 1 { for line in (k + 2)...last { lines[line].kind = .tableRow } }
        let header = MarkdownScanner.tableCells(text(starts[k].start, starts[k].end))
        let alignments: [MDAlignment] = MarkdownScanner.tableCells(text(starts[k + 1].start, starts[k + 1].end)).map { cell in
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            return left && right ? .center : right ? .right : left ? .left : .none
        }
        var rows: [[String]] = []
        if last > k + 1 {
            for line in (k + 2)...last { rows.append(MarkdownScanner.tableCells(text(starts[line].start, starts[line].end))) }
        }
        let block = span(k, last)
        blockHides.append(MDHide(range: block, mode: .lines, owner: block, widget: .table(MDTable(alignments: alignments, header: header, rows: rows))))
        addBlock(.table, k, last)
        return last + 1
    }

    func isHTMLStart(_ first: Int, _ e: Int) -> Bool {
        guard first + 1 < e, c[first] == U.less else { return false }
        var q = first + 1
        if c[q] == U.slash { q += 1 }
        guard q < e else { return false }
        let ch = c[q]
        guard (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) else { return false }
        while q < e, CharClass.isWord(c[q]) || c[q] == U.minus { q += 1 }
        return q == e || c[q] == U.space || c[q] == U.greater || c[q] == U.slash || c[q] == U.tab
    }

    mutating func htmlBlock(_ k: Int, comment: Bool) -> Int {
        var last = k
        if comment {
            var line = k
            while line < starts.count {
                if text(starts[line].start, starts[line].end).contains("-->") { last = line; break }
                last = line
                line += 1
            }
        } else {
            while last + 1 < starts.count, !isBlank(starts[last + 1].start, starts[last + 1].end) { last += 1 }
        }
        for line in k...last {
            lines[line].kind = comment ? .comment : .html
            inline.style(starts[line].start, starts[line].end, comment ? .comment : .html)
        }
        addBlock(.html, k, last)
        return last + 1
    }
}
