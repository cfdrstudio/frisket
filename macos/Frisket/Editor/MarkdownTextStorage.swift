import AppKit
import FrisketMarkdown

extension NSAttributedString.Key {
    /// Background box behind whole lines: 1 code, 2 front matter, 3 table source, 4 math source.
    static let fkBlockBox = NSAttributedString.Key("fkBlockBox")
    /// Block-quote depth of a line, for the left rules.
    static let fkQuote = NSAttributedString.Key("fkQuote")
    /// Rounded background behind inline code.
    static let fkInlineCode = NSAttributedString.Key("fkInlineCode")
    /// Marker-pen background behind `==highlight==`.
    static let fkHighlight = NSAttributedString.Key("fkHighlight")
}

/// The note's text. After every edit it rescans the Markdown and restyles only
/// the blocks whose text or context changed, so typing stays cheap in long notes.
/// Hiding syntax is not done here but per view, in `LivePreviewLayoutManager`,
/// because what is revealed depends on each view's own selection.
final class MarkdownTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    private(set) var document = MDDocument.empty
    private var pendingInvalidation: [NSRange] = []

    var styler: MarkdownStyler {
        didSet { restyleAll() }
    }

    init(styler: MarkdownStyler) {
        self.styler = styler
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { fatalError("not used") }

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    override func processEditing() {
        if editedMask.contains(.editedCharacters) {
            reparse(edited: editedRange, delta: changeInLength)
        }
        super.processEditing()
        flushInvalidation()
    }

    /// Replace the whole text without leaving an undo step (used when opening a note).
    func load(_ text: String) {
        beginEditing()
        backing.replaceCharacters(in: NSRange(location: 0, length: backing.length), with: text)
        edited(.editedCharacters, range: NSRange(location: 0, length: 0), changeInLength: (text as NSString).length - 0)
        endEditing()
        restyleAll()
    }

    // MARK: Restyling

    private struct BlockKey: Hashable { let signature: Int; let location: Int }

    private func reparse(edited: NSRange, delta: Int) {
        let old = document
        document = MarkdownScanner.scan(backing.string)
        let editEndOld = edited.location + edited.length - delta
        var unchanged = Set<BlockKey>()
        for block in old.blocks {
            let start = block.range.location
            let end = start + block.range.length
            if end <= edited.location {
                unchanged.insert(BlockKey(signature: block.signature, location: start))
            } else if start >= editEndOld {
                unchanged.insert(BlockKey(signature: block.signature, location: start + delta))
            }
        }
        let editedEnd = edited.location + edited.length
        for (index, block) in document.blocks.enumerated() {
            let key = BlockKey(signature: block.signature, location: block.range.location)
            let touchesEdit = block.range.location <= editedEnd && block.range.location + block.range.length >= edited.location
            if touchesEdit || !unchanged.contains(key) {
                style(blockAt: index)
                let range = block.range
                if range.location + range.length < edited.location || range.location > editedEnd {
                    pendingInvalidation.append(range)
                }
            }
        }
    }

    /// Restyle everything (theme, font or mode changed).
    func restyleAll() {
        guard backing.length > 0 || !document.blocks.isEmpty else { return }
        document = MarkdownScanner.scan(backing.string)
        for index in document.blocks.indices { style(blockAt: index) }
        let all = NSRange(location: 0, length: backing.length)
        for manager in layoutManagers {
            manager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            manager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        }
        for manager in layoutManagers { (manager as? LivePreviewLayoutManager)?.documentDidChange() }
    }

    private func style(blockAt index: Int) {
        let range = document.blocks[index].range
        guard range.length > 0, range.location + range.length <= backing.length else { return }
        styler.apply(to: backing, block: index, document: document)
    }

    /// Restyled ranges outside the edit were changed behind the layout managers' backs.
    private func flushInvalidation() {
        for manager in layoutManagers { (manager as? LivePreviewLayoutManager)?.documentDidChange() }
        guard !pendingInvalidation.isEmpty else { return }
        let ranges = pendingInvalidation
        pendingInvalidation = []
        for manager in layoutManagers {
            for range in ranges where range.location + range.length <= backing.length {
                manager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                manager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
        }
    }
}
