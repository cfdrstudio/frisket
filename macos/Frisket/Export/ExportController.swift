import AppKit
import FrisketBase
import FrisketExport
import SwiftMath
import UniformTypeIdentifiers
import WebKit

/// Export, print and copy-as-HTML.
@MainActor
enum ExportController {
    // MARK: Entry points

    static func export(format: String, editor: EditorViewController, library: LibraryController?, parent: NSWindow) {
        let source = Source(editor: editor, library: library)
        switch format {
        case "pdf":
            exportPDF(source, options: defaultOptions(mode: .pdf), parent: parent)
        case "html":
            exportHTML(source, options: defaultOptions(mode: .html), parent: parent)
        case "markdown":
            exportMarkdown(source, parent: parent)
        case "jpg":
            exportJPEG(source, parent: parent)
        case "txt":
            exportText(source, parent: parent)
        default:
            if let pandoc = Pandoc.format(id: format) {
                exportPandoc(source, format: pandoc, parent: parent)
            } else {
                UI.alert("Unknown export format", "\u{201C}\(format)\u{201D} is not a format Frisket can export.", style: .warning, parent: parent)
            }
        }
    }

    static func exportWithLayout(editor: EditorViewController, library: LibraryController?, parent: NSWindow) {
        let source = Source(editor: editor, library: library)
        LayoutPanel.show(parent: parent) { options in
            switch options.mode {
            case .pdf: exportPDF(source, options: options, parent: parent)
            case .html: exportHTML(source, options: options, parent: parent)
            }
        }
    }

    static func print(editor: EditorViewController, library: LibraryController?, parent: NSWindow) {
        let source = Source(editor: editor, library: library)
        let options = defaultOptions(mode: .pdf)
        let page = pageSize(options)
        let margin = CGFloat(options.margin * 72)
        let html = source.build(options).html
        Task { @MainActor in
            let job = WebJob(size: NSSize(width: page.width - 2 * margin, height: page.height - 2 * margin))
            do {
                try await job.load(html: html)
            } catch {
                job.finish()
                UI.error("Could not prepare the note for printing", error, parent: parent)
                return
            }
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            let operation = job.webView.printOperation(with: info)
            operation.jobTitle = source.title
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            job.webView.frame = NSRect(x: 0, y: 0, width: info.paperSize.width - info.leftMargin - info.rightMargin,
                                       height: info.paperSize.height - info.topMargin - info.bottomMargin)
            operation.view?.frame = job.webView.bounds
            operation.runModal(for: parent, delegate: job, didRun: #selector(WebJob.printFinished(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    static func copyAsHTML(editor: EditorViewController, library: LibraryController?) {
        let source = Source(editor: editor, library: library)
        var options = ExportOptions(mode: .html, embedImages: true, allowedRoot: source.allowedRoot)
        options.dark = false
        let full = source.build(options).html
        var body = full
        if let start = full.range(of: "<article class=\"md-render\">"), let end = full.range(of: "</article>", options: .backwards), start.upperBound <= end.lowerBound {
            body = String(full[start.upperBound..<end.lowerBound])
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<meta charset=\"utf-8\">" + body, forType: .html)
        pasteboard.setString(source.markdown, forType: .string)
    }

    // MARK: Source

    /// What is exported: a snapshot of the editor taken when the command runs.
    struct Source {
        let markdown: String
        let noteURL: URL?
        let title: String
        let libraryRoot: URL?
        let themeCSS: String

        @MainActor init(editor: EditorViewController, library: LibraryController?) {
            markdown = editor.text
            noteURL = editor.url
            title = editor.documentTitle
            if let url = editor.url, let library, library.contains(url) { libraryRoot = library.root } else { libraryRoot = nil }
            themeCSS = ThemeStore.shared.theme(named: AppSettings.shared.theme).css
        }

        /// Images are only read from the library when the note is in it, else from the note's folder.
        var allowedRoot: URL? { libraryRoot ?? noteURL?.deletingLastPathComponent() }

        @MainActor func build(_ options: ExportOptions) -> ExportDocument.Result {
            var options = options
            options.allowedRoot = allowedRoot
            options.dark = false
            let renderer = MarkdownRenderer(linkResolver: nil, mathRenderer: { ExportController.mathHTML($0, display: $1) },
                                            diagramRenderer: nil, allowRawHTML: true)
            return ExportDocument.build(markdown: markdown, noteURL: noteURL, title: title, themeCSS: themeCSS, options: options, renderer: renderer)
        }

        func fileName(_ ext: String) -> String {
            FileOps.safeName(title) + "." + ext
        }
    }

    static func defaultOptions(mode: ExportMode) -> ExportOptions {
        let region = Locale.current.region?.identifier ?? ""
        let letter = ["US", "CA", "MX"].contains(region)
        return ExportOptions(mode: mode, pageSize: letter ? .letter : .a4, embedImages: true)
    }

    /// Paper size in points, portrait or landscape.
    static func pageSize(_ options: ExportOptions) -> NSSize {
        let size: NSSize
        switch options.pageSize {
        case .a3: size = NSSize(width: 842, height: 1191)
        case .a4: size = NSSize(width: 595, height: 842)
        case .a5: size = NSSize(width: 420, height: 595)
        case .legal: size = NSSize(width: 612, height: 1008)
        case .letter: size = NSSize(width: 612, height: 792)
        case .tabloid: size = NSSize(width: 792, height: 1224)
        }
        return options.landscape ? NSSize(width: size.height, height: size.width) : size
    }

    // MARK: Math

    /// LaTeX as a PNG data-URI image (alt text = the LaTeX). nil on failure, so the source shows.
    static func mathHTML(_ latex: String, display: Bool) -> String? {
        let scale: CGFloat = 2
        var math = MathImage(latex: latex, fontSize: (display ? 20 : 17) * scale, textColor: .black,
                             labelMode: display ? .display : .text, textAlignment: display ? .center : .left)
        let (error, image, info) = math.asImage()
        guard error == nil, let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let width = image.size.width / scale
        let height = image.size.height / scale
        let alt = latex
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let descent = (info?.descent ?? 0) / scale
        let align = display ? "" : "vertical-align:\(String(format: "%.2f", -descent))px;"
        let img = "<img class=\"math-image\" src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"\(alt)\" "
            + "style=\"width:\(String(format: "%.2f", width))px;height:\(String(format: "%.2f", height))px;\(align)\">"
        return display ? "<p class=\"math-display\" style=\"text-align:center\">" + img + "</p>" : img
    }

    // MARK: Save panel

    private static func askSave(name: String, ext: String, directory: URL?, parent: NSWindow) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
            if let directory { panel.directoryURL = directory }
            panel.beginSheetModal(for: UI.topmost(parent)) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    // MARK: HTML, text, Markdown

    private static func exportHTML(_ source: Source, options: ExportOptions, parent: NSWindow) {
        var options = options
        options.mode = .html
        options.embedImages = true
        Task { @MainActor in
            guard let url = await askSave(name: source.fileName("html"), ext: "html", directory: source.noteURL?.deletingLastPathComponent(), parent: parent) else { return }
            let html = source.build(options).html
            do { try Data(html.utf8).write(to: url, options: .atomic) } catch { UI.error("Could not export HTML", error, parent: parent) }
        }
    }

    private static func exportText(_ source: Source, parent: NSWindow) {
        Task { @MainActor in
            guard let url = await askSave(name: source.fileName("txt"), ext: "txt", directory: source.noteURL?.deletingLastPathComponent(), parent: parent) else { return }
            let text = PlainText.from(markdown: source.markdown)
            do { try Data(text.utf8).write(to: url, options: .atomic) } catch { UI.error("Could not export text", error, parent: parent) }
        }
    }

    private static func exportMarkdown(_ source: Source, parent: NSWindow) {
        Task { @MainActor in
            guard let url = await askSave(name: source.fileName("md"), ext: "md", directory: source.noteURL?.deletingLastPathComponent(), parent: parent) else { return }
            let noteURL = source.noteURL, text = source.markdown, root = source.libraryRoot
            let result = await Task.detached(priority: .userInitiated) { () -> Result<MarkdownBundleResult, Error> in
                Result { try MarkdownBundle.export(noteURL: noteURL, text: text, to: url, libraryRoot: root) }
            }.value
            switch result {
            case .failure(let error):
                UI.error("Could not export Markdown", error, parent: parent)
            case .success(let bundle):
                if bundle.copied > 0 || !bundle.skipped.isEmpty {
                    var lines: [String] = []
                    if bundle.copied > 0, let assets = bundle.assetsDirectory {
                        lines.append("Copied \(bundle.copied) attachment\(bundle.copied == 1 ? "" : "s") to \u{201C}\(assets.lastPathComponent)\u{201D}.")
                    }
                    if !bundle.skipped.isEmpty {
                        lines.append("\(bundle.skipped.count) not copied (missing or outside the library):")
                        lines += bundle.skipped.prefix(8).map { "\u{2022} " + $0 }
                        if bundle.skipped.count > 8 { lines.append("\u{2026}and \(bundle.skipped.count - 8) more.") }
                    }
                    UI.alert("Markdown exported", lines.joined(separator: "\n"), parent: parent)
                }
            }
        }
    }

    // MARK: PDF

    private static func exportPDF(_ source: Source, options: ExportOptions, parent: NSWindow) {
        var options = options
        options.mode = .pdf
        options.embedImages = true
        Task { @MainActor in
            guard let url = await askSave(name: source.fileName("pdf"), ext: "pdf", directory: source.noteURL?.deletingLastPathComponent(), parent: parent) else { return }
            let html = source.build(options).html
            let page = pageSize(options)
            let margin = CGFloat(options.margin.isFinite ? min(max(options.margin, 0), 3) * 72 : 43.2)
            let progress = ProgressSheet(message: "Exporting PDF\u{2026}")
            progress.present(on: parent)
            let job = WebJob(size: NSSize(width: page.width - 2 * margin, height: page.height - 2 * margin))
            defer { job.finish() }
            do {
                try await job.load(html: html)
                let info = NSPrintInfo()
                info.paperSize = page
                info.orientation = .portrait // the size above is already rotated for landscape
                info.topMargin = margin
                info.bottomMargin = margin
                info.leftMargin = margin
                info.rightMargin = margin
                info.horizontalPagination = .fit
                info.verticalPagination = .automatic
                info.isHorizontallyCentered = false
                info.isVerticallyCentered = false
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                let ok = await job.printPDF(info: info, frame: NSRect(x: 0, y: 0, width: page.width - 2 * margin, height: page.height - 2 * margin))
                progress.dismiss()
                if !ok { UI.alert("Could not export the PDF", "The print operation did not finish.", style: .warning, parent: parent) }
            } catch {
                progress.dismiss()
                UI.error("Could not export the PDF", error, parent: parent)
            }
        }
    }

    // MARK: JPEG

    private static func exportJPEG(_ source: Source, parent: NSWindow) {
        Task { @MainActor in
            guard let url = await askSave(name: source.fileName("jpg"), ext: "jpg", directory: source.noteURL?.deletingLastPathComponent(), parent: parent) else { return }
            var options = defaultOptions(mode: .html)
            options.contentWidth = 780
            let html = source.build(options).html
            let width: CGFloat = 900
            let progress = ProgressSheet(message: "Exporting image\u{2026}")
            progress.present(on: parent)
            let job = WebJob(size: NSSize(width: width, height: 800))
            defer { job.finish() }
            do {
                try await job.load(html: html)
                let measured = await job.contentHeight()
                let height = min(max(measured, 100), 16000)
                job.webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
                try? await Task.sleep(nanoseconds: 150_000_000)
                let configuration = WKSnapshotConfiguration()
                configuration.rect = NSRect(x: 0, y: 0, width: width, height: height)
                configuration.afterScreenUpdates = true
                let image = try await job.webView.takeSnapshot(configuration: configuration)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
                progress.dismiss()
                if measured > 16000 {
                    UI.alert("Image exported, but cropped", "The note is taller than 16,000 points, so the bottom was left out. Export a PDF to get all of it.", parent: parent)
                }
            } catch {
                progress.dismiss()
                UI.error("Could not export the image", error, parent: parent)
            }
        }
    }

    // MARK: Pandoc

    private static func exportPandoc(_ source: Source, format: PandocFormat, parent: NSWindow) {
        let custom = AppSettings.shared.pandocPath
        guard Pandoc.locate(customPath: custom) != nil else {
            UI.alert("Pandoc is needed for \(format.name)",
                     "Frisket uses Pandoc to export Word, EPUB and other formats, but could not find it. Install it, or choose its location in Settings.",
                     parent: parent, buttons: ["Open pandoc.org", "Cancel"]) { choice in
                if choice == 0, let url = URL(string: "https://pandoc.org/installing.html") { NSWorkspace.shared.open(url) }
            }
            return
        }
        Task { @MainActor in
            guard let url = await askSave(name: source.fileName(format.fileExtension), ext: format.fileExtension,
                                          directory: source.noteURL?.deletingLastPathComponent(), parent: parent) else { return }
            let text = source.markdown, folder = source.noteURL?.deletingLastPathComponent(), title = source.title
            let progress = ProgressSheet(message: "Exporting \(format.name)\u{2026}")
            progress.present(on: parent)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    try await Pandoc.convert(markdown: text, format: format, to: url, resourcePath: folder, customPath: custom, title: title)
                    return .success(())
                } catch { return .failure(error) }
            }.value
            progress.dismiss()
            if case .failure(let error) = result { UI.error("Could not export \(format.name)", error, parent: parent) }
        }
    }
}

// MARK: - Web view job

/// An offscreen, script-free web view that renders export HTML. Retained until `finish()`.
@MainActor
final class WebJob: NSObject, WKNavigationDelegate {
    private static var live: [WebJob] = []

    let webView: WKWebView
    private let window: NSWindow
    private var started = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    init(size: NSSize) {
        let configuration = WKWebViewConfiguration()
        // Notes can contain raw HTML: no page script may ever run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        WebJob.live.append(self)
    }

    func finish() {
        webView.navigationDelegate = nil
        window.contentView = nil
        WebJob.live.removeAll { $0 === self }
    }

    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// The document height, read with a fixed app-side script (page scripts stay disabled).
    func contentHeight() async -> CGFloat {
        let value = try? await webView.evaluateJavaScript("document.documentElement.scrollHeight")
        return CGFloat((value as? NSNumber)?.doubleValue ?? 800)
    }

    func printPDF(info: NSPrintInfo, frame: NSRect) async -> Bool {
        webView.frame = frame
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = frame
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printContinuation = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(printFinished(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc func printFinished(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let continuation = printContinuation {
            printContinuation = nil
            continuation.resume(returning: success)
        } else {
            finish() // interactive print: nothing else is waiting
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the initial load; links and any later navigation are refused.
        if started {
            decisionHandler(.cancel)
        } else {
            started = true
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resumeLoad(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resumeLoad(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resumeLoad(error) }

    private func resumeLoad(_ error: Error?) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

// MARK: - Layout sheet

/// "PDF or HTML with Layout": mirrors the original's export layout dialog.
@MainActor
final class LayoutPanel: PanelController {
    private let completion: (ExportOptions) -> Void
    private let format = NSPopUpButton()
    private let size = NSPopUpButton()
    private let orientation = NSPopUpButton()
    private let preset = NSPopUpButton()
    private let margin = NSTextField()
    private let marginStepper = NSStepper()
    private let fontSize = NSTextField()
    private let fontStepper = NSStepper()
    private let titlePage = NSButton(checkboxWithTitle: "Title page", target: nil, action: nil)
    private let toc = NSButton(checkboxWithTitle: "Table of contents", target: nil, action: nil)
    private let author = NSTextField()
    private let subtitle = NSTextField()

    static func show(parent: NSWindow, completion: @escaping (ExportOptions) -> Void) {
        let panel = LayoutPanel(completion: completion)
        panel.present(on: parent)
    }

    private init(completion: @escaping (ExportOptions) -> Void) {
        self.completion = completion
        super.init(title: "Export Layout", size: NSSize(width: 460, height: 470), resizable: false)
        buildUI()
    }

    private func buildUI() {
        format.addItems(withTitles: ["PDF", "HTML"])
        size.addItems(withTitles: PageSize.allCases.map(\.rawValue))
        size.selectItem(withTitle: ExportController.defaultOptions(mode: .pdf).pageSize.rawValue)
        orientation.addItems(withTitles: ["Portrait", "Landscape"])
        preset.addItems(withTitles: ["Standard", "Manuscript", "Report"])
        configure(margin, stepper: marginStepper, value: 0.75, min: 0, max: 3, step: 0.05, decimals: 2)
        configure(fontSize, stepper: fontStepper, value: ExportOptions.defaultFontSize, min: 8, max: 48, step: 1, decimals: 0)
        titlePage.state = .on
        toc.state = .on
        author.placeholderString = "Optional"
        subtitle.placeholderString = "Optional"
        for field in [author, subtitle] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        let pdfOnly: [NSControl] = [size, orientation, margin, marginStepper]
        UI.onAction(format) { [weak self] _ in
            let isPDF = self?.format.indexOfSelectedItem == 0
            pdfOnly.forEach { $0.isEnabled = isPDF }
        }

        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        func addRow(_ label: String?, _ view: NSView) {
            grid.addRow(with: [label.map { UI.label($0 + ":", color: .secondaryLabelColor) } ?? NSView(), view])
        }
        func pair(_ field: NSTextField, _ stepper: NSStepper, _ suffix: String) -> NSView {
            let row = NSStackView(views: [field, stepper, UI.secondary(suffix, wraps: false)])
            row.orientation = .horizontal
            row.spacing = 6
            return row
        }
        addRow("Format", format)
        addRow("Page size", size)
        addRow("Orientation", orientation)
        addRow("Margins", pair(margin, marginStepper, "inches"))
        addRow("Font size", pair(fontSize, fontStepper, "px"))
        addRow("Preset", preset)
        addRow(nil, titlePage)
        addRow(nil, toc)
        addRow("Subtitle", subtitle)
        addRow("Author", author)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let cancel = UI.button("Cancel", key: "\u{1b}") { [weak self] in self?.dismiss() }
        let export = UI.button("Export\u{2026}", primary: true) { [weak self] in self?.export() }
        install(UI.vstack([
            UI.heading("Export Layout"),
            UI.secondary("Make a standalone HTML file or a print-ready PDF."),
            grid,
            UI.spacer(),
            UI.buttonRow([cancel, export]),
        ], spacing: 14, alignment: .width))
    }

    private func configure(_ field: NSTextField, stepper: NSStepper, value: Double, min: Double, max: Double, step: Double, decimals: Int) {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.minimum = NSNumber(value: min)
        formatter.maximum = NSNumber(value: max)
        field.formatter = formatter
        field.doubleValue = value
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = step
        stepper.doubleValue = value
        UI.onAction(stepper) { control in field.doubleValue = (control as? NSStepper)?.doubleValue ?? value }
        UI.onAction(field) { control in stepper.doubleValue = (control as? NSTextField)?.doubleValue ?? value }
    }

    private func export() {
        window.makeFirstResponder(nil) // commit any field being edited
        let presetValue = ExportPreset.allCases[max(0, preset.indexOfSelectedItem)]
        let presentation = ExportPresentation(preset: presetValue, titlePage: titlePage.state == .on, toc: toc.state == .on,
                                              author: author.stringValue, subtitle: subtitle.stringValue)
        let options = ExportOptions(
            mode: format.indexOfSelectedItem == 0 ? .pdf : .html,
            pageSize: PageSize(name: size.titleOfSelectedItem),
            landscape: orientation.indexOfSelectedItem == 1,
            margin: margin.doubleValue,
            fontSize: fontSize.doubleValue,
            embedImages: true,
            presentation: presentation
        ).validated()
        let completion = self.completion
        dismiss()
        Task { @MainActor in
            await Task.yield()
            completion(options)
        }
    }
}
