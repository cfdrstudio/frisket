import AppKit
import SwiftMath
import FrisketMarkdown

/// Draws the figures that stand in for masked blocks: tables, math, images.
/// Results are cached per theme, size and width.
final class WidgetRenderer {
    var palette: ThemePalette { didSet { clearRenderedCaches() } }
    var theme: Theme { didSet { clearRenderedCaches() } }
    var fontSize: CGFloat { didSet { clearRenderedCaches() } }
    var documentURL: URL?
    /// Called on the main thread when an image finishes loading, so the view can re-lay-out.
    var onAsyncLoad: (() -> Void)?

    private var images: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var loading: Set<String> = []
    private var tables: [String: NSImage] = [:]
    private var maths: [String: (image: NSImage, descent: CGFloat)] = [:]

    init(theme: Theme, palette: ThemePalette, fontSize: CGFloat) {
        self.theme = theme
        self.palette = palette
        self.fontSize = fontSize
    }

    private func clearRenderedCaches() {
        tables.removeAll()
        maths.removeAll()
    }

    // MARK: Sizes and drawing

    func blockSize(_ widget: MDWidget, maxWidth: CGFloat) -> NSSize {
        switch widget {
        case .table(let table): return tableImage(table, maxWidth: maxWidth).size
        case .blockMath(let latex): return blockMath(latex, maxWidth: maxWidth).size
        case .image(let src, _):
            guard let image = image(src) else { return NSSize(width: min(maxWidth, 420), height: round(fontSize * 2.4)) }
            return fitted(image.size, maxWidth: maxWidth)
        case .rule: return NSSize(width: maxWidth, height: fontSize)
        default: return .zero
        }
    }

    func drawBlock(_ widget: MDWidget, in rect: NSRect, maxWidth: CGFloat) {
        switch widget {
        case .table(let table):
            tableImage(table, maxWidth: maxWidth).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .blockMath(let latex):
            blockMath(latex, maxWidth: maxWidth).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .image(let src, let alt):
            if let image = image(src) {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                NSGraphicsContext.restoreGraphicsState()
            } else {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                path.setLineDash([4, 3], count: 2, phase: 0)
                palette.borderStrong.setStroke()
                path.stroke()
                let loadingNow = loading.contains(resolvedKey(src) ?? src)
                let label = (loadingNow ? "Loading image… " : "Image not found: ") + (alt.isEmpty ? src : alt)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize * 0.75), .foregroundColor: palette.fgMuted]
                let size = (label as NSString).size(withAttributes: attributes)
                (label as NSString).draw(at: NSPoint(x: rect.minX + 12, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        default:
            break
        }
    }

    private func fitted(_ size: NSSize, maxWidth: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: 1, height: 1) }
        let scale = min(1, maxWidth / size.width)
        return NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }

    // MARK: Math

    func inlineMath(_ latex: String, size: CGFloat) -> (image: NSImage, descent: CGFloat)? {
        let key = "i|\(size)|\(latex)"
        if let cached = maths[key] { return cached }
        var math = MathImage(latex: latex, fontSize: size, textColor: palette.fg, labelMode: .text, textAlignment: .left)
        let (error, image, info) = math.asImage()
        guard error == nil, let image else { return nil }
        let result = (image, info?.descent ?? 0)
        maths[key] = result
        return result
    }

    private func blockMath(_ latex: String, maxWidth: CGFloat) -> NSImage {
        let key = "b|\(fontSize)|\(latex)"
        if let cached = maths[key] { return scaled(cached.image, maxWidth: maxWidth) }
        var math = MathImage(latex: latex.isEmpty ? "\\square" : latex, fontSize: fontSize * 1.25, textColor: latex.isEmpty ? palette.fgFaint : palette.fg, labelMode: .display, textAlignment: .center)
        let (error, image, info) = math.asImage()
        let result: NSImage
        if let image, error == nil {
            result = image
        } else {
            let message = "Math error: " + (error?.localizedDescription ?? latex)
            let attributes: [NSAttributedString.Key: Any] = [.font: theme.monoFont(size: fontSize * 0.82), .foregroundColor: NSColor.systemRed]
            let size = (message as NSString).size(withAttributes: attributes)
            result = NSImage(size: NSSize(width: ceil(size.width) + 4, height: ceil(size.height) + 4), flipped: false) { _ in
                (message as NSString).draw(at: NSPoint(x: 2, y: 2), withAttributes: attributes)
                return true
            }
        }
        maths[key] = (result, info?.descent ?? 0)
        return scaled(result, maxWidth: maxWidth)
    }

    private func scaled(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        guard image.size.width > maxWidth, maxWidth > 0 else { return image }
        let copy = image.copy() as! NSImage
        copy.size = fitted(image.size, maxWidth: maxWidth)
        return copy
    }

    // MARK: Images

    private func resolvedKey(_ src: String) -> String? {
        if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("data:") { return src }
        let decoded = src.removingPercentEncoding ?? src
        let clean = decoded.split(separator: "?", maxSplits: 1).first.map(String.init) ?? decoded
        if clean.hasPrefix("file://") { return URL(string: clean)?.path }
        if clean.hasPrefix("/") { return clean }
        if clean.hasPrefix("~") { return (clean as NSString).expandingTildeInPath }
        guard let base = documentURL?.deletingLastPathComponent() else { return nil }
        return base.appendingPathComponent(clean).standardized.path
    }

    func image(_ src: String) -> NSImage? {
        guard let key = resolvedKey(src) else { return nil }
        if let cached = images[key] { return cached }
        if failed.contains(key) || loading.contains(key) { return nil }
        if key.hasPrefix("data:") {
            if let comma = key.firstIndex(of: ","), let data = Data(base64Encoded: String(key[key.index(after: comma)...])), let image = NSImage(data: data) {
                images[key] = image
                return image
            }
            failed.insert(key)
            return nil
        }
        if key.hasPrefix("http://") || key.hasPrefix("https://") {
            guard let url = URL(string: key) else { failed.insert(key); return nil }
            loading.insert(key)
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(key)
                    if let image { self.images[key] = image } else { self.failed.insert(key) }
                    self.onAsyncLoad?()
                }
            }.resume()
            return nil
        }
        if let image = NSImage(contentsOfFile: key) {
            images[key] = image
            return image
        }
        failed.insert(key)
        return nil
    }

    /// Forget images that failed (for example after an attachment was added).
    func retryMissingImages() { failed.removeAll() }

    // MARK: Tables

    private func tableImage(_ table: MDTable, maxWidth: CGFloat) -> NSImage {
        let key = "\(Int(maxWidth))|\(table.header)|\(table.rows)|\(table.alignments)"
        if let cached = tables[key] { return cached }
        let palette = self.palette
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0, 1)
        let size = fontSize * 0.9
        let body = theme.bodyFont(size: size)
        let bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        let padX = round(size * 0.7), padY = round(size * 0.45)
        func cell(_ text: String, header: Bool, column: Int) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            let alignment = column < table.alignments.count ? table.alignments[column] : .none
            paragraph.alignment = alignment == .center ? .center : alignment == .right ? .right : .natural
            return inlineAttributed(text, font: header ? bold : body, color: palette.fg, paragraph: paragraph)
        }
        let rows: [[NSAttributedString]] = [table.header] .map { row in (0..<columns).map { cell($0 < row.count ? row[$0] : "", header: true, column: $0) } }
            + table.rows.map { row in (0..<columns).map { cell($0 < row.count ? row[$0] : "", header: false, column: $0) } }
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in rows {
            for (index, text) in row.enumerated() {
                widths[index] = max(widths[index], ceil(text.size().width) + padX * 2)
            }
        }
        widths = widths.map { max($0, size * 3) }
        let total = widths.reduce(0, +)
        if total > maxWidth, maxWidth > 0 {
            let scale = maxWidth / total
            widths = widths.map { max(size * 3, floor($0 * scale)) }
        }
        let tableWidth = min(widths.reduce(0, +), max(maxWidth, size * 3))
        var heights: [CGFloat] = []
        for row in rows {
            var height: CGFloat = 0
            for (index, text) in row.enumerated() {
                let bounds = text.boundingRect(with: NSSize(width: widths[index] - padX * 2, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
                height = max(height, ceil(bounds.height) + padY * 2)
            }
            heights.append(max(height, ceil(body.ascender - body.descender) + padY * 2))
        }
        let imageSize = NSSize(width: ceil(tableWidth) + 1, height: ceil(heights.reduce(0, +)) + 1)
        let image = NSImage(size: imageSize, flipped: true) { _ in
            var y: CGFloat = 0.5
            for (rowIndex, row) in rows.enumerated() {
                var x: CGFloat = 0.5
                if rowIndex == 0 {
                    palette.tableHeadBg.setFill()
                    NSRect(x: x, y: y, width: tableWidth, height: heights[0]).fill()
                }
                for (index, text) in row.enumerated() {
                    let rect = NSRect(x: x, y: y, width: widths[index], height: heights[rowIndex])
                    palette.tableBorder.setStroke()
                    let border = NSBezierPath(rect: rect)
                    border.lineWidth = 1
                    border.stroke()
                    text.draw(with: rect.insetBy(dx: padX, dy: padY), options: [.usesLineFragmentOrigin, .usesFontLeading])
                    x += widths[index]
                }
                y += heights[rowIndex]
            }
            return true
        }
        tables[key] = image
        return image
    }

    /// Inline Markdown rendered with its marks removed (bold, italic, code, links).
    func inlineAttributed(_ text: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        if let paragraph { result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length)) }
        let (styles, hides) = MarkdownScanner.inline(text)
        for span in styles {
            switch span.style {
            case .strong, .emphasis:
                result.enumerateAttribute(.font, in: span.range) { value, range, _ in
                    guard let current = value as? NSFont else { return }
                    result.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: span.style == .strong ? .boldFontMask : .italicFontMask), range: range)
                }
            case .inlineCode:
                result.addAttributes([.font: theme.monoFont(size: font.pointSize * 0.88), .foregroundColor: palette.inlineCodeFg], range: span.range)
            case .link, .wikiLink, .autolink, .tag:
                result.addAttribute(.foregroundColor, value: palette.accent, range: span.range)
            case .strike:
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .highlight:
                result.addAttribute(.backgroundColor, value: palette.markBg, range: span.range)
            default: break
            }
        }
        for hide in hides.reversed() where hide.widget == nil && hide.range.location + hide.range.length <= result.length {
            result.deleteCharacters(in: hide.range)
        }
        return result
    }
}
