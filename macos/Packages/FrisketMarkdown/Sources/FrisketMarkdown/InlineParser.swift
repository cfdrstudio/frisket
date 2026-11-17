import Foundation

/// Inline constructs inside one block: code spans, math, links, wiki links,
/// images, autolinks, HTML, escapes, tags, and emphasis-like delimiters
/// (CommonMark's delimiter algorithm for `*`/`_`, GFM `~~`, Pandoc `~sub~` and
/// `^sup^`, and `==highlight==`). Follows the node shapes of @lezer/markdown
/// plus Frisket's extensions in markdownMath.js, so the masking rules of
/// livePreview.js carry over one to one.
struct InlineParser {
    let c: [UInt16]
    var styles: [MDStyleSpan] = []
    var hides: [MDHide] = []

    init(_ chars: [UInt16]) { c = chars }

    private struct Delimiter {
        var char: UInt16
        var start: Int
        var length: Int
        let originalLength: Int
        let canOpen: Bool
        let canClose: Bool
        var active = true
    }

    private func at(_ i: Int, _ end: Int) -> UInt16? { i >= 0 && i < end ? c[i] : nil }

    mutating func style(_ from: Int, _ to: Int, _ style: MDStyle) {
        if to > from { styles.append(MDStyleSpan(range: NSRange(location: from, length: to - from), style: style)) }
    }

    /// A syntax mark: dimmed while revealed, hidden otherwise.
    mutating func mark(_ from: Int, _ to: Int, owner: NSRange, mode: MDRevealMode = .touch) {
        guard to > from else { return }
        style(from, to, .mark)
        hides.append(MDHide(range: NSRange(location: from, length: to - from), mode: mode, owner: owner, widget: nil))
    }

    mutating func hide(_ from: Int, _ to: Int, owner: NSRange, mode: MDRevealMode = .touch, widget: MDWidget? = nil) {
        guard to > from else { return }
        hides.append(MDHide(range: NSRange(location: from, length: to - from), mode: mode, owner: owner, widget: widget))
    }

    /// Parse `[start, end)`. `tags` is false in headings, which hold no tags.
    mutating func parse(_ start: Int, _ end: Int, tags: Bool = true) {
        var delimiters: [Delimiter] = []
        var p = start
        while p < end {
            let ch = c[p]
            switch ch {
            case U.backslash:
                if p + 1 < end, CharClass.isASCIIPunctuation(c[p + 1]) {
                    let owner = NSRange(location: p, length: 2)
                    style(p, p + 2, .escape)
                    hide(p, p + 1, owner: owner)
                    p += 2
                } else { p += 1 }

            case U.backtick:
                p = codeSpan(p, end) ?? (p + run(p, end, U.backtick))

            case U.dollar:
                p = inlineMath(p, end) ?? (p + (at(p + 1, end) == U.dollar ? 2 : 1))

            case U.less:
                p = angle(p, end) ?? (p + 1)

            case U.bang where at(p + 1, end) == U.openBracket:
                p = linkLike(p, p + 1, end, image: true) ?? (p + 2)

            case U.openBracket:
                if at(p + 1, end) == U.openBracket, let next = wikiLink(p, end) { p = next }
                else { p = linkLike(p, p, end, image: false) ?? (p + 1) }

            case U.star, U.underscore:
                let length = run(p, end, ch)
                let before = at(p - 1, end)
                let after = at(p + length, end)
                let (left, right) = flanking(before, after)
                let canOpen: Bool, canClose: Bool
                if ch == U.star {
                    canOpen = left; canClose = right
                } else {
                    canOpen = left && (!right || CharClass.isPunctuation(before))
                    canClose = right && (!left || CharClass.isPunctuation(after))
                }
                delimiters.append(Delimiter(char: ch, start: p, length: length, originalLength: length, canOpen: canOpen, canClose: canClose))
                p += length

            case U.tilde:
                let length = run(p, end, U.tilde)
                if length == 2 {
                    let (left, right) = flanking(at(p - 1, end), at(p + 2, end))
                    delimiters.append(Delimiter(char: U.tilde, start: p, length: 2, originalLength: 2, canOpen: left, canClose: right))
                } else if length == 1, let next = pandocSpan(p, end, U.tilde, .subscript) {
                    p = next; continue
                }
                p += length

            case U.caret:
                p = pandocSpan(p, end, U.caret, .superscript) ?? (p + 1)

            case U.equals where at(p + 1, end) == U.equals:
                p = highlight(p, end) ?? (p + 2)

            case U.hash where tags:
                p = tag(p, start, end) ?? (p + 1)

            case 104, 72, 119, 87: // h H w W
                p = bareURL(p, start, end) ?? (p + 1)

            default:
                p += 1
            }
        }
        processEmphasis(&delimiters)
    }

    private func run(_ p: Int, _ end: Int, _ ch: UInt16) -> Int {
        var q = p
        while q < end && c[q] == ch { q += 1 }
        return q - p
    }

    private func flanking(_ before: UInt16?, _ after: UInt16?) -> (left: Bool, right: Bool) {
        let left = !CharClass.isWhitespace(after) &&
            (!CharClass.isPunctuation(after) || CharClass.isWhitespace(before) || CharClass.isPunctuation(before))
        let right = !CharClass.isWhitespace(before) &&
            (!CharClass.isPunctuation(before) || CharClass.isWhitespace(after) || CharClass.isPunctuation(after))
        return (left, right)
    }

    // MARK: Code spans and math

    private mutating func codeSpan(_ p: Int, _ end: Int) -> Int? {
        let length = run(p, end, U.backtick)
        var q = p + length
        while q < end {
            if c[q] == U.backtick {
                let closing = run(q, end, U.backtick)
                if closing == length {
                    let owner = NSRange(location: p, length: q + closing - p)
                    style(p, q + closing, .inlineCode)
                    mark(p, p + length, owner: owner)
                    mark(q, q + closing, owner: owner)
                    return q + closing
                }
                q += closing
            } else { q += 1 }
        }
        return nil
    }

    private mutating func inlineMath(_ p: Int, _ end: Int) -> Int? {
        if at(p + 1, end) == U.dollar { return nil }
        guard let after = at(p + 1, end), after != U.space, after != U.tab, after != U.newline else { return nil }
        var i = p + 1
        while i < end {
            let ch = c[i]
            if ch == U.backslash { i += 2; continue }
            if ch == U.newline || ch == U.carriageReturn { return nil }
            if ch != U.dollar { i += 1; continue }
            let before = c[i - 1]
            if before == U.space || before == U.tab { return nil }
            if i == p + 1 { return nil }
            let body = String(decoding: c[(p + 1)..<i], as: UTF16.self)
            if body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0 == " " || $0 == "+" || $0 == "-" || $0 == "\t" }) { return nil }
            let owner = NSRange(location: p, length: i + 1 - p)
            style(p, i + 1, .mathSource)
            style(p, p + 1, .mark)
            style(i, i + 1, .mark)
            hide(p, i + 1, owner: owner, widget: .inlineMath(body))
            return i + 1
        }
        return nil
    }

    // MARK: Pandoc-style ~sub~ / ^sup^ and ==highlight==

    private mutating func pandocSpan(_ p: Int, _ end: Int, _ ch: UInt16, _ kind: MDStyle) -> Int? {
        var i = p + 1
        while i < end {
            let unit = c[i]
            if unit == U.backslash { i += 2; continue }
            if CharClass.isWhitespace(unit) { return nil }
            if unit == ch {
                if i == p + 1 { return nil }
                let owner = NSRange(location: p, length: i + 1 - p)
                style(p, i + 1, kind)
                mark(p, p + 1, owner: owner)
                mark(i, i + 1, owner: owner)
                return i + 1
            }
            i += 1
        }
        return nil
    }

    private mutating func highlight(_ p: Int, _ end: Int) -> Int? {
        var i = p + 2
        while i < end - 1 {
            if c[i] == U.newline || c[i] == U.carriageReturn { return nil }
            if c[i] == U.equals && c[i + 1] == U.equals {
                if i == p + 2 { return nil }
                let owner = NSRange(location: p, length: i + 2 - p)
                style(p, i + 2, .highlight)
                mark(p, p + 2, owner: owner)
                mark(i, i + 2, owner: owner)
                return i + 2
            }
            i += 1
        }
        return nil
    }

    // MARK: Autolinks and HTML

    private mutating func angle(_ p: Int, _ end: Int) -> Int? {
        // <!-- comment -->
        if at(p + 1, end) == U.bang, at(p + 2, end) == U.minus, at(p + 3, end) == U.minus {
            var i = p + 4
            while i + 2 < end {
                if c[i] == U.minus && c[i + 1] == U.minus && c[i + 2] == U.greater {
                    style(p, i + 3, .comment)
                    return i + 3
                }
                i += 1
            }
            return nil
        }
        // <scheme:...> or <user@host>
        var i = p + 1
        var sawColon = false, sawAt = false
        while i < end {
            let ch = c[i]
            if ch == U.greater { break }
            if ch == U.less || CharClass.isWhitespace(ch) { i = -1; break }
            if ch == U.colon { sawColon = true }
            if ch == 64 { sawAt = true }
            i += 1
        }
        if i > p + 1, i < end, (sawColon || sawAt), let first = at(p + 1, end), (first >= 65 && first <= 90) || (first >= 97 && first <= 122) {
            let owner = NSRange(location: p, length: i + 1 - p)
            style(p, i + 1, .autolink)
            mark(p, p + 1, owner: owner)
            mark(i, i + 1, owner: owner)
            return i + 1
        }
        // <tag ...>, </tag>
        var q = p + 1
        if at(q, end) == U.slash { q += 1 }
        guard let first = at(q, end), (first >= 65 && first <= 90) || (first >= 97 && first <= 122) else { return nil }
        var inQuote: UInt16? = nil
        while q < end {
            let ch = c[q]
            if let open = inQuote { if ch == open { inQuote = nil } }
            else if ch == U.quote || ch == U.apostrophe { inQuote = ch }
            else if ch == U.greater { style(p, q + 1, .html); return q + 1 }
            else if ch == U.less || ch == U.newline { return nil }
            q += 1
        }
        return nil
    }

    private mutating func bareURL(_ p: Int, _ start: Int, _ end: Int) -> Int? {
        if p > start {
            let before = c[p - 1]
            let allowed = CharClass.isWhitespace(before) || before == U.openParen || before == U.star || before == U.underscore || before == U.tilde
            if !allowed { return nil }
        }
        let prefixes: [String] = ["https://", "http://", "www."]
        var matched = 0
        for prefix in prefixes {
            let units = Array(prefix.utf16)
            if p + units.count <= end {
                var ok = true
                for (k, unit) in units.enumerated() {
                    var ch = c[p + k]
                    if ch >= 65 && ch <= 90 { ch += 32 }
                    if ch != unit { ok = false; break }
                }
                if ok { matched = units.count; break }
            }
        }
        guard matched > 0 else { return nil }
        var q = p + matched
        var parens = 0
        while q < end {
            let ch = c[q]
            if CharClass.isWhitespace(ch) || ch == U.less { break }
            if ch == U.openParen { parens += 1 }
            if ch == U.closeParen { if parens == 0 { break }; parens -= 1 }
            q += 1
        }
        // Trailing punctuation is not part of the URL.
        while q > p + matched, let last = at(q - 1, end), [U.dot, 44, U.colon, 59, U.bang, 63, U.star, U.underscore, U.tilde, U.quote, U.apostrophe].contains(last) { q -= 1 }
        guard q > p + matched else { return nil }
        style(p, q, .autolink)
        return q
    }

    // MARK: Tags

    private mutating func tag(_ p: Int, _ start: Int, _ end: Int) -> Int? {
        if p > start {
            let before = c[p - 1]
            if CharClass.isWord(before) || before == U.slash || before == U.hash || before == U.backslash || before == U.ampersand { return nil }
        }
        var q = p + 1
        var segmentStart = q
        while q < end {
            let ch = c[q]
            if CharClass.isWord(ch) || ch == U.minus { q += 1; continue }
            if ch == U.slash, q > segmentStart, let next = at(q + 1, end), CharClass.isWord(next) || next == U.minus {
                q += 1; segmentStart = q; continue
            }
            break
        }
        guard q > p + 1 else { return nil }
        var tagEnd = q
        if at(q, end) == U.hash { tagEnd = q + 1 }
        if let after = at(tagEnd, end), CharClass.isWord(after) || after == U.slash || after == U.minus { return nil }
        style(p, tagEnd, .tag)
        return tagEnd
    }

    // MARK: Wiki links

    private mutating func wikiLink(_ p: Int, _ end: Int) -> Int? {
        var close = -1
        var i = p + 2
        while i < end - 1 {
            let ch = c[i]
            if ch == U.newline || ch == U.carriageReturn { return nil }
            if ch == U.closeBracket && c[i + 1] == U.closeBracket { close = i; break }
            i += 1
        }
        guard close > p + 2 else { return nil }
        let owner = NSRange(location: p, length: close + 2 - p)
        style(p, close + 2, .wikiLink)
        mark(p, p + 2, owner: owner)
        var bar = -1
        for k in (p + 2)..<close where c[k] == U.pipe { bar = k; break }
        if bar >= 0 {
            style(p + 2, bar, .wikiTarget)
            // With an alias the target is plumbing: it goes with the brackets.
            hide(p + 2, bar, owner: owner)
            mark(bar, bar + 1, owner: owner)
            style(bar + 1, close, .wikiTarget)
        } else {
            style(p + 2, close, .wikiTarget)
        }
        mark(close, close + 2, owner: owner)
        return close + 2
    }

    // MARK: Links and images

    /// `[text](dest "title")` or `![alt](src)`. `open` is the `[`.
    private mutating func linkLike(_ start: Int, _ open: Int, _ end: Int, image: Bool) -> Int? {
        // Matching `]`, skipping code spans and escapes.
        var depth = 0
        var i = open
        var close = -1
        while i < end {
            let ch = c[i]
            if ch == U.backslash { i += 2; continue }
            if ch == U.backtick {
                let length = run(i, end, U.backtick)
                var q = i + length
                var found = false
                while q < end {
                    if c[q] == U.backtick {
                        let n = run(q, end, U.backtick)
                        if n == length { i = q + n; found = true; break }
                        q += n
                    } else { q += 1 }
                }
                if !found { i += length }
                continue
            }
            if ch == U.openBracket { depth += 1 }
            else if ch == U.closeBracket {
                depth -= 1
                if depth == 0 { close = i; break }
            }
            i += 1
        }
        guard close > 0, at(close + 1, end) == U.openParen else { return nil }
        var q = close + 2
        while q < end, c[q] == U.space || c[q] == U.tab || c[q] == U.newline { q += 1 }
        let destStart = q
        var destEnd = q
        if at(q, end) == U.less {
            while q < end, c[q] != U.greater, c[q] != U.newline { q += 1 }
            guard at(q, end) == U.greater else { return nil }
            q += 1
            destEnd = q
        } else {
            var parens = 0
            while q < end {
                let ch = c[q]
                if ch == U.backslash { q += 2; continue }
                if CharClass.isWhitespace(ch) { break }
                if ch == U.openParen { parens += 1 }
                if ch == U.closeParen { if parens == 0 { break }; parens -= 1 }
                q += 1
            }
            destEnd = min(q, end)
        }
        while q < end, c[q] == U.space || c[q] == U.tab || c[q] == U.newline { q += 1 }
        var titleStart = -1, titleEnd = -1
        if let ch = at(q, end), ch == U.quote || ch == U.apostrophe || ch == U.openParen {
            let closer = ch == U.openParen ? U.closeParen : ch
            titleStart = q
            q += 1
            while q < end, c[q] != closer { if c[q] == U.backslash { q += 1 }; q += 1 }
            guard q < end else { return nil }
            q += 1
            titleEnd = q
            while q < end, c[q] == U.space || c[q] == U.tab || c[q] == U.newline { q += 1 }
        }
        guard at(q, end) == U.closeParen else { return nil }
        let finish = q + 1
        let owner = NSRange(location: start, length: finish - start)
        style(start, finish, image ? .imageSource : .link)
        mark(start, open + 1, owner: owner)
        mark(close, close + 2, owner: owner)
        if destEnd > destStart {
            style(destStart, destEnd, .url)
            hide(destStart, destEnd, owner: owner)
        }
        if titleStart >= 0 {
            style(titleStart, titleEnd, .url)
            hide(titleStart, titleEnd, owner: owner)
        }
        // Whitespace between the parts goes with them.
        hide(close + 2, destStart, owner: owner)
        hide(destEnd, titleStart >= 0 ? titleStart : q, owner: owner)
        if titleStart >= 0 { hide(titleEnd, q, owner: owner) }
        mark(q, finish, owner: owner)
        if !image {
            var inner = InlineParser(c)
            inner.parse(open + 1, close)
            styles.append(contentsOf: inner.styles)
            hides.append(contentsOf: inner.hides)
        }
        return finish
    }

    // MARK: Emphasis

    private mutating func processEmphasis(_ delimiters: inout [Delimiter]) {
        var bottom: [UInt16: Int] = [:]
        var closerIndex = 0
        while closerIndex < delimiters.count {
            let closer = delimiters[closerIndex]
            guard closer.active, closer.canClose, closer.length > 0 else { closerIndex += 1; continue }
            var openerIndex = closerIndex - 1
            var found = false
            let floor = bottom[closer.char] ?? 0
            while openerIndex >= floor {
                let opener = delimiters[openerIndex]
                if opener.active, opener.char == closer.char, opener.canOpen, opener.length > 0 {
                    if closer.char == U.tilde {
                        if opener.length == closer.length { found = true; break }
                    } else {
                        let oddMatch = (opener.canClose || closer.canOpen)
                            && (opener.originalLength + closer.originalLength) % 3 == 0
                            && !(opener.originalLength % 3 == 0 && closer.originalLength % 3 == 0)
                        if !oddMatch { found = true; break }
                    }
                }
                openerIndex -= 1
            }
            guard found else {
                bottom[closer.char] = closerIndex
                if !closer.canOpen { delimiters[closerIndex].active = false }
                closerIndex += 1
                continue
            }
            let opener = delimiters[openerIndex]
            let use: Int
            let kind: MDStyle
            if closer.char == U.tilde {
                use = 2; kind = .strike
            } else {
                use = (opener.length >= 2 && closer.length >= 2) ? 2 : 1
                kind = use == 2 ? .strong : .emphasis
            }
            let openFrom = opener.start + opener.length - use
            let closeTo = closer.start + use
            let owner = NSRange(location: openFrom, length: closeTo - openFrom)
            style(openFrom, closeTo, kind)
            mark(openFrom, openFrom + use, owner: owner)
            mark(closer.start, closeTo, owner: owner)
            delimiters[openerIndex].length -= use
            delimiters[closerIndex].start += use
            delimiters[closerIndex].length -= use
            for k in (openerIndex + 1)..<closerIndex { delimiters[k].active = false }
            if delimiters[closerIndex].length == 0 { closerIndex += 1 }
        }
    }
}

extension U {
    static let ampersand: UInt16 = 38
}
