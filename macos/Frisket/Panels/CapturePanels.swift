import AppKit
import FrisketLibrary

/// Quick capture, save-as-snippet and the template chooser.
@MainActor
final class QuickCapturePanel: PanelController {
    private let library: LibraryController
    private let titleField = NSTextField()
    private let bodyScroll: NSScrollView
    private let bodyView: NSTextView
    private let saveButton: NSButton
    private let spinner = NSProgressIndicator()

    static func show(library: LibraryController, parent: NSWindow?) {
        let panel = QuickCapturePanel(library: library)
        panel.present(on: parent)
        panel.window.makeFirstResponder(panel.titleField)
    }

    private init(library: LibraryController) {
        self.library = library
        bodyScroll = NSTextView.scrollableTextView()
        bodyView = bodyScroll.documentView as! NSTextView
        saveButton = NSButton(title: "Save", target: nil, action: nil)
        super.init(title: "Quick Capture", size: NSSize(width: 460, height: 340), floating: true, minSize: NSSize(width: 360, height: 260))
        buildUI()
    }

    private func buildUI() {
        titleField.placeholderString = "Title (optional)"
        bodyView.isRichText = false
        bodyView.font = .systemFont(ofSize: 14)
        bodyView.isAutomaticQuoteSubstitutionEnabled = false
        bodyView.isAutomaticDashSubstitutionEnabled = false
        bodyView.allowsUndo = true
        bodyView.textContainerInset = NSSize(width: 6, height: 6)
        bodyScroll.borderType = .bezelBorder
        bodyScroll.hasVerticalScroller = true
        bodyScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.toolTip = "Save (\u{2318}\u{21A9})"
        UI.onAction(saveButton) { [weak self] _ in self?.save() }
        let cancel = UI.button("Cancel", key: "\u{1b}") { [weak self] in self?.dismiss() }

        let hint = UI.secondary("Saved as a new note in the library\u{2019}s inbox. \u{2318}\u{21A9} saves.", wraps: false)
        install(UI.vstack([
            UI.heading("Quick Capture"), titleField, bodyScroll,
            UI.buttonRow([cancel, saveButton], leading: [spinner, hint]),
        ], spacing: 10, alignment: .width))
    }

    private func save() {
        let title = titleField.stringValue
        let body = bodyView.string
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSSound.beep()
            return
        }
        saveButton.isEnabled = false
        spinner.startAnimation(nil)
        Task { [weak self, library] in
            do {
                _ = try await library.perform { try await $0.capture(title: title, body: body) }
                self?.dismiss()
            } catch {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                self.saveButton.isEnabled = true
                UI.alert("Could not save the note", error.localizedDescription, style: .warning, parent: self.window)
            }
        }
    }
}

@MainActor
final class TemplateChooserPanel: PanelController {
    private let library: LibraryController
    private let completion: (NoteTemplate?) -> Void
    private var finished = false
    private var templates: [NoteTemplate] = []
    private let list = ListTable(rowHeight: 28)
    private let preview: NSTextView
    private let previewScroll: NSScrollView
    private let emptyLabel = UI.label("Loading templates…", color: .secondaryLabelColor, wraps: true)
    private let chooseButton: NSButton
    private let split = NSStackView()

    static func show(library: LibraryController, parent: NSWindow, completion: @escaping (NoteTemplate?) -> Void) {
        let panel = TemplateChooserPanel(library: library, completion: completion)
        panel.present(on: parent)
        panel.load()
    }

    private init(library: LibraryController, completion: @escaping (NoteTemplate?) -> Void) {
        self.library = library
        self.completion = completion
        (previewScroll, preview) = UI.textScroll(mono: true)
        chooseButton = NSButton(title: "Choose", target: nil, action: nil)
        super.init(title: "Templates", size: NSSize(width: 640, height: 440), minSize: NSSize(width: 520, height: 320))
        onClose = { [weak self] in self?.finish(nil) }
        buildUI()
    }

    private func buildUI() {
        chooseButton.bezelStyle = .rounded
        chooseButton.keyEquivalent = "\r"
        chooseButton.isEnabled = false
        UI.onAction(chooseButton) { [weak self] _ in
            guard let self, let index = self.list.selectedIndex, self.templates.indices.contains(index) else { return }
            self.dismissWith(self.templates[index])
        }
        let cancel = UI.button("Cancel", key: "\u{1b}") { [weak self] in self?.dismissWith(nil) }
        list.onSelect = { [weak self] index in
            guard let self else { return }
            self.chooseButton.isEnabled = index != nil
            if let index, self.templates.indices.contains(index) { self.preview.string = self.templates[index].contents }
        }
        list.onDoubleClick = { [weak self] index in
            guard let self, self.templates.indices.contains(index) else { return }
            self.dismissWith(self.templates[index])
        }
        list.scrollView.translatesAutoresizingMaskIntoConstraints = false
        list.scrollView.widthAnchor.constraint(equalToConstant: 200).isActive = true
        split.setViews([list.scrollView, previewScroll], in: .leading)
        split.orientation = .horizontal
        split.spacing = 12
        split.distribution = .fill
        split.isHidden = true
        list.scrollView.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        previewScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true

        let holder = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        holder.addSubview(split)
        holder.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: holder.topAnchor),
            split.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor, constant: -40),
        ])
        holder.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        install(UI.vstack([UI.heading("Templates"), holder, UI.buttonRow([cancel, chooseButton])], spacing: 10, alignment: .width))
    }

    func load() {
        Task { [weak self, library] in
            let result = await library.query { index -> Result<[NoteTemplate], Error> in
                do { return .success(try await index.templates()) } catch { return .failure(error) }
            }
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emptyLabel.stringValue = "Could not read templates: " + error.localizedDescription
            case .success(let found):
                self.templates = found
                if found.isEmpty {
                    self.emptyLabel.stringValue = "No templates yet. Any .md file you put in the library\u{2019}s Templates folder appears here, and Tools \u{203A} Save Selection as Snippet adds one for you."
                } else {
                    self.emptyLabel.isHidden = true
                    self.split.isHidden = false
                    self.list.rows = found.map { ListTable.Row(title: $0.name) }
                    self.list.select(0)
                }
            }
        }
    }

    private func dismissWith(_ template: NoteTemplate?) {
        finish(template)
        dismiss()
    }

    private func finish(_ template: NoteTemplate?) {
        guard !finished else { return }
        finished = true
        completion(template)
    }
}

@MainActor
enum SnippetSaver {
    static func save(text: String, library: LibraryController, parent: NSWindow) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            UI.alert("Select some text first", "Select the text you want to reuse, then choose Save Selection as Snippet again.", parent: parent)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save Selection as Snippet"
        alert.informativeText = "Name the snippet. It is saved as a template in the library\u{2019}s Templates folder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Snippet name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: UI.topmost(parent)) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            Task { @MainActor in
                do {
                    _ = try await library.perform { try await $0.saveTemplate(name: name, contents: text) }
                } catch {
                    UI.alert("Could not save the snippet", error.localizedDescription, style: .warning, parent: parent)
                }
            }
        }
    }
}
