import AppKit
import FrisketMarkdown

/// Turns scanned Markdown into fonts, colours and paragraph styles — the native
/// counterpart of editor.css. One styler per theme/appearance/size combination.
struct MarkdownStyler {
    let theme: Theme
    let palette: ThemePalette
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let sourceMode: Bool

    let body: NSFont
    let mono: NSFont

    init(theme: Theme, dark: Bool, fontSize: CGFloat, lineHeight: CGFloat, sourceMode: Bool) {
        self.theme = theme
        self.palette = theme.palette(dark: dark)
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.sourceMode = sourceMode
        self.body = sourceMode ? theme.monoFont(size: fontSize * 0.92) : theme.bodyFont(size: fontSize)
        self.mono = theme.monoFont(size: fontSize * 0.86)
    }

    static let headingScale: [CGFloat] = [1.95, 1.55, 1.26, 1.1, 1.0, 0.92]
    static let headingLineHeight: [CGFloat] = [1.28, 1.32, 1.38, 1.44, 1.6, 1.6]
    static let headingMarginTop: [CGFloat] = [1.5, 1.35, 1.2, 1.1, 1.0, 1.0]
    static let headingMarginBottom: [CGFloat] = [0.35, 0.3, 0.25, 0.2, 0.2, 0.2]

    /// The width the list hanging indent and code padding are measured in.
    var em: CGFloat { fontSize }

    func headingFont(_ level: Int) -> NSFont {
        let size = fontSize * MarkdownStyler.headingScale[max(0, min(5, level - 1))]
        let font = theme.headingFont(size: size)
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    func paragraphStyle(lineHeight multiple: CGFloat, font: NSFont, before: CGFloat = 0, after: CGFloat = 0,
                        head: CGFloat = 0, firstHead: CGFloat = 0, tail: CGFloat = 0, maxHeight: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let natural = ceil(font.ascender - font.descender + font.leading)
        let target = font.pointSize * multiple
        style.lineSpacing = max(0, target - natural)
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = head
        style.firstLineHeadIndent = firstHead
        style.tailIndent = tail
        if let maxHeight {
            style.maximumLineHeight = maxHeight
            style.lineSpacing = 0
        }
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Typing attributes for an empty note.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: palette.fg, .paragraphStyle: paragraphStyle(lineHeight: lineHeight, font: body)]
    }

    // MARK: Applying

    /// Style block `index` of `document` in `text` from scratch.
    func apply(to text: NSMutableAttributedString, block index: Int, document: MDDocument) {
        let block = document.blocks[index]
        let full = block.range
        text.setAttributes(baseAttributes, range: full)
        if sourceMode {
            applySource(text, document: document, block: full)
            return
        }
        var lineIndex = document.lineIndex(at: full.location)
        while lineIndex < document.lines.count, document.lines[lineIndex].fullRange.location < full.location + full.length {
            styleLine(text, document.lines[lineIndex], previous: lineIndex > 0 ? document.lines[lineIndex - 1] : nil,
                      next: lineIndex + 1 < document.lines.count ? document.lines[lineIndex + 1] : nil)
            lineIndex += 1
        }
        let spans = document.styles(in: full).filter { $0.range.location + $0.range.length <= full.location + full.length }
        // Structural styles first, marks last so they win.
        for span in spans where span.style != .mark { styleSpan(text, span) }
        for span in spans where span.style == .mark { styleSpan(text, span) }
        // Bullet glyphs take the accent colour; deeper levels are muted.
        for hide in document.hides(in: full) {
            if case .bullet(let depth)? = hide.widget {
                text.addAttribute(.foregroundColor, value: depth == 0 ? palette.accent : palette.fgMuted, range: hide.range)
            }
        }
    }

    private func styleLine(_ text: NSMutableAttributedString, _ line: MDLine, previous: MDLine?, next: MDLine?) {
        let range = line.fullRange
        guard range.length > 0 || line.range.location < text.length else { return }
        let ranged = NSRange(location: range.location, length: min(range.length, text.length - range.location))
        guard ranged.length > 0 else { return }
        let quoteIndent = CGFloat(line.quoteDepth) * em * 1.1
        switch line.kind {
        case .heading(let level), .setextUnderline(let level):
            let font = headingFont(level)
            let i = max(0, min(5, level - 1))
            var color = palette.fg
            if level >= 5 { color = palette.fgMuted }
            let isUnderline: Bool = { if case .setextUnderline = line.kind { return true }; return false }()
            let style = paragraphStyle(lineHeight: MarkdownStyler.headingLineHeight[i], font: font,
                                       before: isUnderline ? 0 : font.pointSize * MarkdownStyler.headingMarginTop[i] * 0.6,
                                       after: font.pointSize * MarkdownStyler.headingMarginBottom[i],
                                       head: quoteIndent, firstHead: quoteIndent)
            text.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: -0.012 * font.pointSize], range: ranged)
            if level == 6 { text.addAttribute(.kern, value: 0.05 * font.pointSize, range: ranged) }

        case .code, .codeFence, .indentedCode:
            text.addAttributes([.font: mono, .foregroundColor: palette.codeFg, .fkBlockBox: 1,
                                .paragraphStyle: boxStyle(line: line, previous: previous, next: next, kind: [.code, .codeFence, .indentedCode], quoteIndent: quoteIndent)],
                               range: ranged)

        case .math, .mathFence:
            text.addAttributes([.font: mono, .foregroundColor: palette.accent, .fkBlockBox: 4,
                                .paragraphStyle: boxStyle(line: line, previous: previous, next: next, kind: [.math, .mathFence], quoteIndent: quoteIndent)],
                               range: ranged)

        case .frontMatter, .frontMatterFence:
            text.addAttributes([.font: theme.monoFont(size: fontSize * 0.82), .foregroundColor: palette.fgMuted, .fkBlockBox: 2,
                                .paragraphStyle: boxStyle(line: line, previous: previous, next: next, kind: [.frontMatter, .frontMatterFence], quoteIndent: 0)],
                               range: ranged)

        case .tableHeader, .tableDelimiter, .tableRow:
            text.addAttributes([.font: theme.monoFont(size: fontSize * 0.82), .foregroundColor: palette.fgMuted, .fkBlockBox: 3,
                                .paragraphStyle: boxStyle(line: line, previous: previous, next: next, kind: [.tableHeader, .tableDelimiter, .tableRow], quoteIndent: quoteIndent)],
                               range: ranged)

        case .blank:
            let previousBlank = previous.map { $0.kind == .blank } ?? true
            let height = ceil(body.pointSize * lineHeight * (previousBlank ? 1 : 0.7))
            text.addAttribute(.paragraphStyle, value: paragraphStyle(lineHeight: lineHeight, font: body, maxHeight: height), range: ranged)

        case .rule:
            text.addAttribute(.paragraphStyle, value: paragraphStyle(lineHeight: lineHeight, font: body, before: em * 0.3, after: em * 0.3), range: ranged)

        case .html, .comment, .paragraph:
            var head = quoteIndent
            var first = quoteIndent
            if let depth = line.listDepth {
                _ = depth
                let prefix = (text.string as NSString).substring(with: NSRange(location: line.range.location, length: min(line.listContentColumn, line.range.length)))
                head += hangingIndent(prefix: prefix, line: line)
                first = quoteIndent
            }
            let style = paragraphStyle(lineHeight: lineHeight, font: body, head: head, firstHead: first)
            text.addAttribute(.paragraphStyle, value: style, range: ranged)
        }
        if line.quoteDepth > 0 {
            text.addAttributes([.fkQuote: line.quoteDepth, .foregroundColor: palette.quoteFg], range: ranged)
            text.addAttribute(.font, value: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask), range: ranged)
            if case .heading(let level) = line.kind {
                text.addAttribute(.font, value: NSFontManager.shared.convert(headingFont(level), toHaveTrait: .italicFontMask), range: ranged)
            }
        }
    }

    /// Width of a list line's prefix as it is displayed (bullet and task box drawn as widgets).
    private func hangingIndent(prefix: String, line: MDLine) -> CGFloat {
        var shown = prefix
        if let list = line.list {
            let marker = (prefix as NSString)
            let markerOffset = list.markerRange.location - line.range.location
            if !list.ordered, markerOffset >= 0, markerOffset < marker.length {
                shown = marker.replacingCharacters(in: NSRange(location: markerOffset, length: 1), with: "•")
            }
            if let task = list.taskRange {
                let taskOffset = task.location - line.range.location
                let ns = shown as NSString
                if taskOffset >= 0, taskOffset + 3 <= ns.length {
                    let before = ns.substring(to: taskOffset)
                    let after = ns.substring(from: taskOffset + 3)
                    return width(before) + LivePreviewLayoutManager.checkboxWidth(fontSize: fontSize) + width(after)
                }
            }
        }
        return width(shown)
    }

    private func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: body]).width)
    }

    private func boxStyle(line: MDLine, previous: MDLine?, next: MDLine?, kind: [MDLineKind], quoteIndent: CGFloat) -> NSParagraphStyle {
        let isFirst = previous.map { !kind.contains($0.kind) } ?? true
        let isLast = next.map { !kind.contains($0.kind) } ?? true
        let pad = em * 0.9
        return paragraphStyle(lineHeight: 1.55, font: mono, before: isFirst ? em * 0.55 : 0, after: isLast ? em * 0.55 : 0,
                              head: quoteIndent + pad, firstHead: quoteIndent + pad, tail: -pad)
    }

    private func styleSpan(_ text: NSMutableAttributedString, _ span: MDStyleSpan) {
        let range = span.range
        guard range.location + range.length <= text.length, range.length > 0 else { return }
        switch span.style {
        case .strong: addTrait(text, range, .boldFontMask)
        case .emphasis: addTrait(text, range, .italicFontMask)
        case .strike:
            text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: palette.fgMuted], range: range)
        case .highlight:
            text.addAttributes([.fkHighlight: true, .foregroundColor: palette.markFg], range: range)
        case .superscript: scale(text, range, 0.78, baseline: 0.35)
        case .subscript: scale(text, range, 0.78, baseline: -0.18)
        case .inlineCode:
            text.addAttributes([.font: theme.monoFont(size: currentSize(text, range) * 0.88), .foregroundColor: palette.inlineCodeFg, .fkInlineCode: true], range: range)
        case .mathSource:
            text.addAttributes([.font: theme.monoFont(size: currentSize(text, range) * 0.88), .foregroundColor: palette.accent], range: range)
        case .link, .wikiLink, .wikiTarget:
            text.addAttributes([.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: palette.accentSoft], range: range)
        case .autolink:
            text.addAttributes([.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .url:
            text.addAttributes([.foregroundColor: palette.fgFaint, .font: theme.monoFont(size: currentSize(text, range) * 0.84), .underlineStyle: 0], range: range)
        case .imageSource:
            text.addAttribute(.foregroundColor, value: palette.fgMuted, range: range)
        case .tag:
            text.addAttribute(.foregroundColor, value: palette.accent, range: range)
        case .comment, .html:
            text.addAttribute(.foregroundColor, value: palette.fgFaint, range: range)
        case .codeInfo:
            text.addAttributes([.font: NSFont.systemFont(ofSize: fontSize * 0.74, weight: .medium), .foregroundColor: palette.fgFaint, .kern: 0.6], range: range)
        case .escape:
            break
        case .mark:
            let size = currentSize(text, range)
            let isHeading = size > fontSize * 1.05
            text.addAttributes([.font: theme.monoFont(size: isHeading ? max(fontSize * 0.75, size * 0.5) : size * 0.86),
                                .foregroundColor: palette.fgFaint.withAlphaComponent(0.85),
                                .underlineStyle: 0, .strikethroughStyle: 0], range: range)
            text.removeAttribute(.fkHighlight, range: range)
        case .orderedMark:
            text.addAttributes([.foregroundColor: palette.accent, .font: NSFont.systemFont(ofSize: fontSize * 0.9)], range: range)
        case .setextMark:
            text.addAttributes([.foregroundColor: palette.fgFaint, .font: theme.monoFont(size: fontSize * 0.7)], range: range)
        case .hrSource:
            text.addAttributes([.foregroundColor: palette.fgFaint, .kern: fontSize * 0.3], range: range)
        }
    }

    private func currentSize(_ text: NSMutableAttributedString, _ range: NSRange) -> CGFloat {
        (text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? fontSize
    }

    private func addTrait(_ text: NSMutableAttributedString, _ range: NSRange, _ trait: NSFontTraitMask) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }

    private func scale(_ text: NSMutableAttributedString, _ range: NSRange, _ factor: CGFloat, baseline: CGFloat) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let scaled = NSFontManager.shared.convert(font, toSize: font.pointSize * factor)
            text.addAttributes([.font: scaled, .baselineOffset: font.pointSize * baseline], range: subrange)
        }
    }

    // MARK: Source mode

    /// Raw Markdown in one monospaced size, with quiet syntax colouring.
    private func applySource(_ text: NSMutableAttributedString, document: MDDocument, block: NSRange) {
        var lineIndex = document.lineIndex(at: block.location)
        while lineIndex < document.lines.count, document.lines[lineIndex].fullRange.location < block.location + block.length {
            let line = document.lines[lineIndex]
            let range = NSRange(location: line.fullRange.location, length: min(line.fullRange.length, text.length - line.fullRange.location))
            if range.length > 0 {
                switch line.kind {
                case .heading:
                    text.addAttributes([.font: NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask), .foregroundColor: palette.fg], range: range)
                case .code, .codeFence, .indentedCode, .math, .mathFence:
                    text.addAttribute(.foregroundColor, value: palette.codeFg, range: range)
                case .frontMatter, .frontMatterFence, .comment, .html:
                    text.addAttribute(.foregroundColor, value: palette.fgMuted, range: range)
                default: break
                }
            }
            lineIndex += 1
        }
        for span in document.styles(in: block) where span.range.location + span.range.length <= text.length {
            switch span.style {
            case .mark, .url, .setextMark, .hrSource: text.addAttribute(.foregroundColor, value: palette.fgFaint, range: span.range)
            case .link, .wikiLink, .autolink, .tag, .orderedMark: text.addAttribute(.foregroundColor, value: palette.accent, range: span.range)
            case .inlineCode: text.addAttribute(.foregroundColor, value: palette.inlineCodeFg, range: span.range)
            case .strong: addTrait(text, span.range, .boldFontMask)
            case .emphasis: addTrait(text, span.range, .italicFontMask)
            default: break
            }
        }
    }
}
