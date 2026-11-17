import AppKit
import FrisketMarkdown

/// The frisket itself: masks Markdown syntax that the selection is not
/// touching, swaps bullets and task boxes for drawn widgets, collapses tables,
/// math blocks and image paragraphs into rendered figures, and paints code
/// boxes, quote rules and inline-code backgrounds. One per text view, so two
/// views of one note reveal syntax around their own carets.
final class LivePreviewLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// The owning view's selection, which decides what is revealed.
    private(set) var selection: [NSRange] = [NSRange(location: 0, length: 0)]
    var sourceMode = false
    var palette: ThemePalette
    var fontSize: CGFloat
    let widgets: WidgetRenderer

    init(palette: ThemePalette, fontSize: CGFloat, widgets: WidgetRenderer) {
        self.palette = palette
        self.fontSize = fontSize
        self.widgets = widgets
        super.init()
        delegate = self
        usesFontLeading = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func checkboxWidth(fontSize: CGFloat) -> CGFloat { round(fontSize * 1.3) }

    var document: MDDocument { (textStorage as? MarkdownTextStorage)?.document ?? .empty }

    /// Is `hide` masked right now?
    func isActive(_ hide: MDHide) -> Bool {
        if sourceMode { return false }
        if case .diagram? = hide.widget { return false } // diagrams show as code
        return !document.isRevealed(hide, by: selection)
    }

    func documentDidChange() {}

    /// Update the selection and re-lay-out the blocks whose masking changed.
    func setSelection(_ ranges: [NSRange]) {
        let old = selection
        selection = ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges
        guard !sourceMode, let storage = textStorage else { return }
        let doc = document
        guard !doc.blocks.isEmpty else { return }
        var blockIndexes = Set<Int>()
        for range in old + selection {
            let start = doc.blockIndex(at: range.location)
            let end = doc.blockIndex(at: range.location + range.length)
            for index in start...max(start, end) { blockIndexes.insert(index) }
            // A caret at the start of a block also touches the end of the previous one.
            if start > 0 { blockIndexes.insert(start - 1) }
        }
        for index in blockIndexes where index < doc.blocks.count {
            let blockRange = doc.blocks[index].range
            var changed = false
            for hide in doc.hides(in: blockRange) + doc.blockHides(in: blockRange) where hide.mode != .never {
                if doc.isRevealed(hide, by: old) != doc.isRevealed(hide, by: selection) { changed = true; break }
            }
            if changed {
                let range = NSIntersectionRange(blockRange, NSRange(location: 0, length: storage.length))
                invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                for container in textContainers { container.textView?.setNeedsDisplay(container.textView?.visibleRect ?? .zero) }
            }
        }
    }

    /// The active inline widget whose first character is `charIndex`.
    func inlineWidget(at charIndex: Int) -> MDHide? {
        guard !sourceMode else { return nil }
        for hide in document.hides(in: NSRange(location: charIndex, length: 1)) where hide.range.location == charIndex {
            guard let widget = hide.widget else { continue }
            switch widget {
            case .checkbox, .inlineMath: if isActive(hide) { return hide }
            default: continue
            }
        }
        return nil
    }

    func inlineWidgetSize(_ hide: MDHide, at charIndex: Int) -> NSSize {
        switch hide.widget {
        case .checkbox?:
            return NSSize(width: LivePreviewLayoutManager.checkboxWidth(fontSize: fontSize), height: fontSize)
        case .inlineMath(let latex)?:
            return widgets.inlineMath(latex, size: inlineMathPointSize(hide))?.image.size ?? .zero
        default:
            return .zero
        }
    }

    /// Inline math matches the text it sits in: the `$` delimiter is styled as a mark,
    /// so measure the source just inside it, which keeps the paragraph's (or heading's) size.
    func inlineMathPointSize(_ hide: MDHide) -> CGFloat {
        guard let storage = textStorage, hide.range.length > 2 else { return fontSize }
        let inside = min(hide.range.location + 1, storage.length - 1)
        let font = storage.attribute(.font, at: inside, effectiveRange: nil) as? NSFont
        return (font?.pointSize ?? fontSize * 0.88) / 0.88
    }

    // MARK: Glyph generation

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !sourceMode, glyphRange.length > 0 else { return 0 }
        let count = glyphRange.length
        let first = charIndexes[0]
        let last = charIndexes[count - 1]
        let charRange = NSRange(location: first, length: last - first + 1)
        let doc = document
        let inline = doc.hides(in: charRange)
        let blocks = doc.blockHides(in: charRange)
        if inline.isEmpty && blocks.isEmpty { return 0 }

        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProps = Array(UnsafeBufferPointer(start: props, count: count))
        var changed = false
        // Character index → glyph slot, for the (usual) one-to-one case.
        func forEachGlyph(in range: NSRange, _ body: (Int, Int) -> Void) {
            let start = range.location, end = range.location + range.length
            for slot in 0..<count {
                let ci = charIndexes[slot]
                if ci >= start && ci < end { body(slot, ci) }
            }
        }
        for hide in blocks where isActive(hide) {
            if case .rule? = hide.widget {} // a rule keeps its line; only the dashes go
            forEachGlyph(in: hide.range) { slot, _ in newProps[slot] = .null; changed = true }
        }
        for hide in inline where isActive(hide) {
            switch hide.widget {
            case .bullet(let depth)?:
                let symbol: UniChar = depth == 0 ? 0x2022 : (depth == 1 ? 0x25E6 : 0x25AA)
                var character = symbol
                var glyph: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(aFont as CTFont, &character, &glyph, 1), glyph != 0 {
                    forEachGlyph(in: hide.range) { slot, _ in
                        if newProps[slot] != .null { newGlyphs[slot] = glyph; changed = true }
                    }
                }
            case .checkbox?, .inlineMath?:
                forEachGlyph(in: hide.range) { slot, ci in
                    if newProps[slot] == .null { return }
                    newProps[slot] = ci == hide.range.location ? .controlCharacter : .null
                    changed = true
                }
            default:
                forEachGlyph(in: hide.range) { slot, _ in newProps[slot] = .null; changed = true }
            }
        }
        guard changed else { return 0 }
        newGlyphs.withUnsafeBufferPointer { g in
            newProps.withUnsafeBufferPointer { p in
                setGlyphs(g.baseAddress!, properties: p.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            }
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        inlineWidget(at: charIndex) != nil ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let hide = inlineWidget(at: charIndex) else { return NSRect(origin: glyphPosition, size: .zero) }
        let size = inlineWidgetSize(hide, at: charIndex)
        return NSRect(x: glyphPosition.x, y: glyphPosition.y, width: size.width + 2, height: size.height)
    }

    // MARK: Line heights for rendered blocks

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !sourceMode else { return false }
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        for hide in document.blockHides(in: charRange) where isActive(hide) {
            guard let widget = hide.widget else { continue }
            if case .rule = widget { continue }
            let start = hide.range.location
            if charRange.location <= start && start < charRange.location + max(charRange.length, 1) {
                let width = lineFragmentRect.pointee.width - textContainer.lineFragmentPadding * 2
                let size = widgets.blockSize(widget, maxWidth: width)
                let padding = round(fontSize * 0.45)
                let height = ceil(size.height + padding * 2)
                lineFragmentRect.pointee.size.height = height
                lineFragmentUsedRect.pointee.size.height = height
                baselineOffset.pointee = height - padding
                return true
            } else if charRange.location > start {
                lineFragmentRect.pointee.size.height = 0
                lineFragmentUsedRect.pointee.size.height = 0
                baselineOffset.pointee = 0
                return true
            }
        }
        return false
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, storage.length > 0 {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawInlineCode(in: charRange, storage: storage, origin: origin)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Code/front-matter/table/math boxes and quote rules. The text view calls this from
    /// `drawBackground(in:)`, because boxes reach above the first line, outside the clip
    /// NSTextView sets for the layout manager's own background drawing.
    func drawBlockDecorations(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0, glyphs.length > 0 else { return }
        let charRange = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        drawBoxes(in: charRange, storage: storage, origin: origin)
        drawQuoteRules(in: charRange, storage: storage, origin: origin)
    }

    private func coveredByActiveBlock(_ range: NSRange) -> Bool {
        document.blockHides(in: range).contains { hide in
            if case .rule? = hide.widget { return false }
            if case .diagram? = hide.widget { return false }
            return isActive(hide) && NSIntersectionRange(hide.range, range).length > 0
        }
    }

    private func drawBoxes(in charRange: NSRange, storage: NSTextStorage, origin: NSPoint) {
        guard let container = textContainers.first else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var location = charRange.location
        let end = min(charRange.location + charRange.length, storage.length)
        while location < end {
            var effective = NSRange()
            let value = storage.attribute(.fkBlockBox, at: location, longestEffectiveRange: &effective, in: whole) as? Int
            defer { location = max(location + 1, effective.location + effective.length) }
            guard let kind = value, effective.length > 0, !coveredByActiveBlock(effective) else { continue }
            // Leave out the final terminator so the box ends with the last line.
            var boxRange = effective
            let text = storage.string as NSString
            while boxRange.length > 1, let last = Unicode.Scalar(text.character(at: boxRange.location + boxRange.length - 1)),
                  CharacterSet.newlines.contains(last) { boxRange.length -= 1 }
            let glyphs = glyphRange(forCharacterRange: boxRange, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let firstFrag = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let style = storage.attribute(.paragraphStyle, at: boxRange.location, effectiveRange: nil) as? NSParagraphStyle
            let pad = round(fontSize * 0.9)
            let left = firstFrag.minX + container.lineFragmentPadding + (style?.firstLineHeadIndent ?? pad) - pad
            let right = firstFrag.minX + container.size.width - container.lineFragmentPadding
            // Measure from the glyphs' baselines: TextKit skips the first paragraph's
            // spacing-before at the top of the text, so fragment heights can't be trusted.
            let firstFont = storage.attribute(.font, at: boxRange.location, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: fontSize)
            let lastGlyph = glyphs.location + glyphs.length - 1
            let lastChar = characterIndexForGlyph(at: lastGlyph)
            let lastFont = storage.attribute(.font, at: min(lastChar, storage.length - 1), effectiveRange: nil) as? NSFont ?? firstFont
            let lastFrag = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let top = firstFrag.minY + self.location(forGlyphAt: glyphs.location).y - firstFont.ascender - round(fontSize * 0.55)
            let bottom = lastFrag.minY + self.location(forGlyphAt: lastGlyph).y - lastFont.descender + round(fontSize * 0.55)
            let rect = NSRect(x: left + origin.x, y: top + origin.y, width: right - left, height: bottom - top)
            let color: NSColor
            switch kind {
            case 2: color = palette.bgElevated.blended(withFraction: 0.35, of: palette.codeBg) ?? palette.codeBg
            case 4: color = palette.accentSoft.withAlphaComponent(0.06)
            default: color = palette.codeBg
            }
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            if kind == 2 || kind == 4 {
                palette.border.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func drawQuoteRules(in charRange: NSRange, storage: NSTextStorage, origin: NSPoint) {
        guard let container = textContainers.first else { return }
        storage.enumerateAttribute(.fkQuote, in: charRange) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            palette.quoteBorder.setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                for level in 0..<depth {
                    let x = rect.minX + container.lineFragmentPadding + CGFloat(level) * self.fontSize * 1.1 + 1
                    NSRect(x: x + origin.x, y: rect.minY + origin.y, width: 3, height: rect.height).fill()
                }
            }
        }
    }

    /// Rounded backgrounds that hug the glyphs (inline code, highlights) rather than
    /// filling the whole line fragment, which includes the line spacing.
    private func drawInlineCode(in charRange: NSRange, storage: NSTextStorage, origin: NSPoint) {
        drawTightBackground(.fkInlineCode, color: palette.inlineCodeBg, padX: 2, padY: 1.5, in: charRange, storage: storage, origin: origin)
        drawTightBackground(.fkHighlight, color: palette.markBg, padX: 1, padY: 1, in: charRange, storage: storage, origin: origin)
    }

    private func drawTightBackground(_ key: NSAttributedString.Key, color: NSColor, padX: CGFloat, padY: CGFloat,
                                     in charRange: NSRange, storage: NSTextStorage, origin: NSPoint) {
        guard let container = textContainers.first else { return }
        storage.enumerateAttribute(key, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            color.setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                let char = self.characterIndexForGlyph(at: part.location)
                let font = storage.attribute(.font, at: min(char, storage.length - 1), effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: self.fontSize)
                let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                let box = NSRect(x: bounds.minX - padX + origin.x, y: baseline - font.ascender - padY + origin.y,
                                 width: bounds.width + padX * 2, height: font.ascender - font.descender + padY * 2)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard !sourceMode, let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let doc = document
        for hide in doc.blockHides(in: charRange) where isActive(hide) {
            guard let widget = hide.widget else { continue }
            let glyph = glyphIndexForCharacter(at: hide.range.location)
            guard glyph < numberOfGlyphs else { continue }
            let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let style = storage.attribute(.paragraphStyle, at: hide.range.location, effectiveRange: nil) as? NSParagraphStyle
            let indent = style?.firstLineHeadIndent ?? 0
            let left = frag.minX + container.lineFragmentPadding + origin.x
            let width = frag.width - container.lineFragmentPadding * 2
            if case .rule = widget {
                palette.borderStrong.setFill()
                NSRect(x: left + indent, y: frag.midY + origin.y, width: width - indent, height: 1).fill()
                continue
            }
            let padding = round(fontSize * 0.45)
            let size = widgets.blockSize(widget, maxWidth: width)
            var x = left
            if case .blockMath = widget { x = left + max(0, (width - size.width) / 2) }
            let rect = NSRect(x: x, y: frag.minY + origin.y + padding, width: size.width, height: size.height)
            widgets.drawBlock(widget, in: rect, maxWidth: width)
        }
        for hide in doc.hides(in: charRange) where isActive(hide) {
            guard let widget = hide.widget else { continue }
            switch widget {
            case .checkbox(let checked):
                let glyph = glyphIndexForCharacter(at: hide.range.location)
                guard glyph < numberOfGlyphs else { continue }
                let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let location = self.location(forGlyphAt: glyph)
                let box = round(fontSize * 1.0)
                let baseline = frag.minY + location.y + origin.y
                let rect = NSRect(x: frag.minX + location.x + origin.x + 1, y: baseline - box * 0.86, width: box, height: box)
                drawCheckbox(checked, in: rect)
            case .inlineMath(let latex):
                let glyph = glyphIndexForCharacter(at: hide.range.location)
                guard glyph < numberOfGlyphs else { continue }
                guard let rendered = widgets.inlineMath(latex, size: inlineMathPointSize(hide)) else { continue }
                let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let location = self.location(forGlyphAt: glyph)
                let baseline = frag.minY + location.y + origin.y
                let rect = NSRect(x: frag.minX + location.x + origin.x + 1, y: baseline - rendered.image.size.height + rendered.descent,
                                  width: rendered.image.size.width, height: rendered.image.size.height)
                rendered.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            default:
                break
            }
        }
    }

    private func drawCheckbox(_ checked: Bool, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        if checked {
            palette.accent.setFill()
            path.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.52))
            tick.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.72))
            tick.line(to: NSPoint(x: rect.minX + rect.width * 0.77, y: rect.minY + rect.height * 0.3))
            tick.lineWidth = max(1.5, rect.width * 0.11)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            palette.fgFaint.setStroke()
            path.stroke()
        }
    }

    /// The rectangle of the active checkbox containing `charIndex`, in container coordinates.
    func checkbox(at point: NSPoint) -> MDHide? {
        guard let container = textContainers.first, !sourceMode else { return nil }
        var fraction: CGFloat = 0
        let glyph = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < numberOfGlyphs else { return nil }
        let charIndex = characterIndexForGlyph(at: glyph)
        for candidate in [charIndex, charIndex - 1] where candidate >= 0 {
            if let hide = inlineWidget(at: candidate), case .checkbox = hide.widget {
                let rect = boundingRect(forGlyphRange: NSRange(location: glyphIndexForCharacter(at: candidate), length: 1), in: container)
                if rect.insetBy(dx: -3, dy: -2).contains(point) { return hide }
            }
        }
        return nil
    }
}
