import Foundation

/// What a line is, for line-level styling (fonts, paragraph style, block backgrounds).
public enum MDLineKind: Equatable, Sendable {
    case blank
    case paragraph
    case heading(Int)
    case setextUnderline(Int)
    case codeFence
    case code
    case indentedCode
    case mathFence
    case math
    case frontMatterFence
    case frontMatter
    case tableHeader
    case tableDelimiter
    case tableRow
    case rule
    case html
    case comment
}

/// A list item's marker, recorded on the item's first line.
public struct MDListInfo: Equatable, Sendable {
    /// 0 for a top-level item.
    public var depth: Int
    public var ordered: Bool
    /// The bullet or number (`-`, `1.`).
    public var markerRange: NSRange
    /// Where the item's text starts (after the marker, its spaces and any task box).
    public var contentStart: Int
    /// nil for an ordinary item, else whether the task box is ticked.
    public var task: Bool?
    /// The task box `[ ]` / `[x]`, when there is one.
    public var taskRange: NSRange?
}

public struct MDLine: Equatable, Sendable {
    /// The line without its terminator.
    public var range: NSRange
    /// The line with its terminator.
    public var fullRange: NSRange
    public var kind: MDLineKind
    /// Number of `>` levels in front of the line.
    public var quoteDepth: Int
    /// Set on the first line of a list item.
    public var list: MDListInfo?
    /// For any line inside a list item (first or continuation): the item's depth
    /// and the offset of its text from the line start, for hanging indents.
    public var listDepth: Int?
    public var listContentColumn: Int
    /// Index into `MDDocument.blocks`.
    public var block: Int
}

/// Visual styles for inline spans. Several can cover the same character.
public enum MDStyle: Equatable, Sendable {
    case emphasis, strong, strike, highlight, superscript, `subscript`
    case inlineCode, mathSource
    case link, autolink, wikiLink, wikiTarget, url
    case imageSource, tag, comment, html, codeInfo, escape
    /// Syntax: dimmed while visible, hidden by the layout when not revealed.
    case mark
    /// `1.` in an ordered list: always visible, accent coloured.
    case orderedMark
    /// `===` / `---` under a setext heading.
    case setextMark
    case hrSource
}

public enum MDAlignment: String, Equatable, Sendable { case none, left, center, right }

public struct MDTable: Equatable, Sendable {
    public var alignments: [MDAlignment]
    public var header: [String]
    public var rows: [[String]]
}

/// What a hidden range is replaced with when it is not revealed.
public enum MDWidget: Equatable, Sendable {
    case bullet(depth: Int)
    case checkbox(checked: Bool)
    case inlineMath(String)
    case blockMath(String)
    case diagram(lang: String, source: String)
    case rule
    case table(MDTable)
    case image(src: String, alt: String)

    public var isBlock: Bool {
        switch self {
        case .blockMath, .diagram, .rule, .table, .image: return true
        default: return false
        }
    }
}

/// When a range is masked. `owner` is the construct whose contact with the
/// selection reveals it again.
public enum MDRevealMode: Equatable, Sendable {
    /// Revealed while a selection range touches `owner` (ends inclusive).
    case touch
    /// Revealed while a selection range is on any line of `owner`.
    case lines
    /// Never revealed (bullets, task boxes) — only source mode shows them.
    case never
}

public struct MDHide: Equatable, Sendable {
    public var range: NSRange
    public var mode: MDRevealMode
    public var owner: NSRange
    /// nil: the range simply disappears. Otherwise the widget is drawn in its place.
    public var widget: MDWidget?
}

public struct MDStyleSpan: Equatable, Sendable {
    public var range: NSRange
    public var style: MDStyle
}

public enum MDBlockKind: Equatable, Sendable {
    case blank, paragraph, heading, code, math, frontMatter, table, rule, html, listItem
}

public struct MDBlock: Equatable, Sendable {
    /// Whole lines, terminators included.
    public var range: NSRange
    public var kind: MDBlockKind
    /// Changes whenever the block's text or context changes; used to restyle only what changed.
    public var signature: Int
}

public struct MDHeading: Equatable, Sendable {
    public var level: Int
    public var text: String
    /// The heading's line(s), without terminator.
    public var range: NSRange
}

/// The scanned structure of one note. All ranges are UTF-16 (NSString) ranges.
public struct MDDocument: Sendable {
    public var length: Int
    public var lines: [MDLine]
    public var blocks: [MDBlock]
    /// Inline styles, sorted by location.
    public var styles: [MDStyleSpan]
    /// Short masked ranges inside a block (marks, inline widgets), sorted by location.
    public var hides: [MDHide]
    /// Whole-block widgets (tables, math, diagrams, rules, images), sorted by location.
    public var blockHides: [MDHide]
    public var headings: [MDHeading]

    public static let empty = MDDocument(length: 0, lines: [], blocks: [], styles: [], hides: [], blockHides: [], headings: [])

    /// Index of the line containing `offset` (the last line for the end of the text).
    public func lineIndex(at offset: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].fullRange.location <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Index of the block containing `offset`.
    public func blockIndex(at offset: Int) -> Int {
        guard !blocks.isEmpty else { return 0 }
        var low = 0, high = blocks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if blocks[mid].range.location <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// First index in a location-sorted array whose location is >= `offset`.
    static func lowerBound<T>(_ items: [T], _ offset: Int, location: (T) -> Int) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if location(items[mid]) < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Inline styles overlapping `range` (spans never cross a block boundary).
    public func styles(in range: NSRange) -> ArraySlice<MDStyleSpan> {
        let blockStart = blocks.isEmpty ? 0 : blocks[blockIndex(at: range.location)].range.location
        var index = Self.lowerBound(styles, blockStart) { $0.range.location }
        let start = index
        let end = range.location + range.length
        while index < styles.count, styles[index].range.location < end { index += 1 }
        return styles[start..<index]
    }

    /// Masked inline ranges overlapping `range`.
    public func hides(in range: NSRange) -> [MDHide] {
        let blockStart = blocks.isEmpty ? 0 : blocks[blockIndex(at: range.location)].range.location
        var index = Self.lowerBound(hides, blockStart) { $0.range.location }
        let end = range.location + range.length
        var out: [MDHide] = []
        while index < hides.count, hides[index].range.location < end {
            let hide = hides[index]
            if hide.range.location + hide.range.length > range.location { out.append(hide) }
            index += 1
        }
        return out
    }

    /// Block widgets overlapping `range`.
    public func blockHides(in range: NSRange) -> [MDHide] {
        let end = range.location + range.length
        return blockHides.filter { $0.range.location < end && $0.range.location + $0.range.length > range.location || ($0.range.length == 0 && $0.range.location >= range.location && $0.range.location < end) }
    }

    /// The line range (`from` of the first line to `to` of the last) that `range` spans.
    public func lineSpan(of range: NSRange) -> NSRange {
        guard !lines.isEmpty else { return range }
        let first = lines[lineIndex(at: range.location)]
        let last = lines[lineIndex(at: max(range.location, range.location + range.length))]
        return NSRange(location: first.range.location, length: last.range.location + last.range.length - first.range.location)
    }

    /// Is `hide` revealed by `selection`? Mirrors `touches` / `onLines` in livePreview.js.
    public func isRevealed(_ hide: MDHide, by selection: [NSRange]) -> Bool {
        switch hide.mode {
        case .never:
            return false
        case .touch:
            let from = hide.owner.location, to = hide.owner.location + hide.owner.length
            return selection.contains { $0.location <= to && $0.location + $0.length >= from }
        case .lines:
            let span = lineSpan(of: hide.owner)
            let from = span.location, to = span.location + span.length
            return selection.contains { $0.location <= to && $0.location + $0.length >= from }
        }
    }
}
