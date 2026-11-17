import Foundation
import FrisketBase

/// What the export HTML is for: a file the user keeps, or the page the app prints to PDF.
public enum ExportMode: String, Sendable {
    case html
    case pdf
}

/// Paper sizes the print path accepts (the names Electron's `printToPDF` took).
public enum PageSize: String, CaseIterable, Sendable {
    case a3 = "A3"
    case a4 = "A4"
    case a5 = "A5"
    case legal = "Legal"
    case letter = "Letter"
    case tabloid = "Tabloid"

    /// Lenient parse (case-insensitive); anything unknown is A4.
    public init(name: String?) {
        let wanted = (name ?? "").jsTrimmed.lowercased()
        self = PageSize.allCases.first { $0.rawValue.lowercased() == wanted } ?? .a4
    }
}

/// Look of the exported document (exportDoc.js `PRESENTATION_PRESETS`).
public enum ExportPreset: String, CaseIterable, Sendable {
    case standard
    case manuscript
    case report
}

/// Title page, contents page and preset (exportDoc.js `normalizePresentation`).
/// Every initialiser normalises: unknown presets become `.standard`, text is trimmed.
public struct ExportPresentation: Equatable, Sendable {
    public var preset: ExportPreset
    public var titlePage: Bool
    public var toc: Bool
    public var author: String
    public var subtitle: String

    public init(preset: ExportPreset = .standard, titlePage: Bool = false, toc: Bool = false, author: String = "", subtitle: String = "") {
        self.preset = preset
        self.titlePage = titlePage
        self.toc = toc
        self.author = author.jsTrimmed
        self.subtitle = subtitle.jsTrimmed
    }

    /// From loosely typed values (for example decoded JSON or UI state). Only a real
    /// boolean `true` turns a flag on, as in the JavaScript (`toc: 1` stays off).
    public init(normalizing value: [String: Any]?) {
        let value = value ?? [:]
        func flag(_ key: String) -> Bool {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return (value[key] as? Bool) == true
            }
            return number.boolValue
        }
        self.init(
            preset: ExportPreset(rawValue: value["preset"] as? String ?? "") ?? .standard,
            titlePage: flag("titlePage"),
            toc: flag("toc"),
            author: value["author"] as? String ?? "",
            subtitle: value["subtitle"] as? String ?? ""
        )
    }
}

/// Layout options for an export document. `validated()` clamps every number to a sane range.
public struct ExportOptions: Equatable, Sendable {
    public var mode: ExportMode
    public var pageSize: PageSize
    public var landscape: Bool
    /// Page margin in inches (PDF).
    public var margin: Double
    /// Body font size in CSS pixels.
    public var fontSize: Double
    /// Maximum content width in CSS pixels (HTML).
    public var contentWidth: Double
    /// Inline local images as `data:` URIs (applies to both modes).
    public var embedImages: Bool
    public var dark: Bool
    /// nil keeps the legacy layout with no title page, contents or preset.
    public var presentation: ExportPresentation?
    /// Local images are only read from inside this folder (e.g. the library root).
    /// nil means the note's own folder.
    public var allowedRoot: URL?

    public static let defaultMargin = 0.6
    public static let defaultFontSize = 17.0
    public static let defaultContentWidth = 780.0

    public init(
        mode: ExportMode = .html,
        pageSize: PageSize = .a4,
        landscape: Bool = false,
        margin: Double = ExportOptions.defaultMargin,
        fontSize: Double = ExportOptions.defaultFontSize,
        contentWidth: Double = ExportOptions.defaultContentWidth,
        embedImages: Bool = true,
        dark: Bool = false,
        presentation: ExportPresentation? = nil,
        allowedRoot: URL? = nil
    ) {
        self.mode = mode
        self.pageSize = pageSize
        self.landscape = landscape
        self.margin = margin
        self.fontSize = fontSize
        self.contentWidth = contentWidth
        self.embedImages = embedImages
        self.dark = dark
        self.presentation = presentation
        self.allowedRoot = allowedRoot
    }

    /// Margin 0...3 in (default 0.6 when not finite), font 8...48 px, width 320...2400 px.
    public func validated() -> ExportOptions {
        func clamp(_ value: Double, _ low: Double, _ high: Double, _ fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(high, max(low, value))
        }
        var copy = self
        copy.margin = clamp(margin, 0, 3, ExportOptions.defaultMargin)
        copy.fontSize = clamp(fontSize, 8, 48, ExportOptions.defaultFontSize)
        copy.contentWidth = clamp(contentWidth, 320, 2400, ExportOptions.defaultContentWidth)
        return copy
    }
}
