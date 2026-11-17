import AppKit

/// The colours of one theme in one appearance. Read from the same CSS custom
/// properties the Windows app's themes use, so `themes/*.css` (and user themes
/// in the same format) drive both apps.
struct ThemePalette {
    var bg: NSColor
    var bgElevated: NSColor
    var fg: NSColor
    var fgMuted: NSColor
    var fgFaint: NSColor
    var accent: NSColor
    var accentSoft: NSColor
    var border: NSColor
    var borderStrong: NSColor
    var selection: NSColor
    var codeBg: NSColor
    var codeFg: NSColor
    var inlineCodeBg: NSColor
    var inlineCodeFg: NSColor
    var quoteBorder: NSColor
    var quoteFg: NSColor
    var markBg: NSColor
    var markFg: NSColor
    var tableBorder: NSColor
    var tableHeadBg: NSColor
    var tokKeyword: NSColor
    var tokString: NSColor
    var tokComment: NSColor
    var tokNumber: NSColor
    var tokFunction: NSColor
    var tokType: NSColor

    var isDark: Bool {
        guard let rgb = bg.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5
    }
}

struct Theme {
    let name: String
    let displayName: String
    let light: ThemePalette
    let dark: ThemePalette
    /// True when the theme defines one palette for both appearances (Night, Dracula…).
    let fixedAppearance: Bool
    let bodyFonts: [String]
    let headingFonts: [String]
    let monoFonts: [String]
    /// The theme's variables as CSS, for exports.
    let css: String

    func palette(dark: Bool) -> ThemePalette { fixedAppearance ? light : (dark ? self.dark : light) }

    /// The first installed family of a CSS font stack, at `size`.
    static func font(_ families: [String], size: CGFloat, fallback: NSFont) -> NSFont {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for family in families {
            switch family.lowercased() {
            case "-apple-system", "blinkmacsystemfont", "system-ui", "sans-serif", "ui-sans-serif":
                return NSFont.systemFont(ofSize: size)
            case "serif", "ui-serif":
                if let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
                    return NSFont(descriptor: descriptor, size: size) ?? fallback
                }
            case "monospace", "ui-monospace":
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default:
                if installed.contains(family), let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
                    return font
                }
            }
        }
        return fallback
    }

    func bodyFont(size: CGFloat) -> NSFont { Theme.font(bodyFonts, size: size, fallback: .systemFont(ofSize: size)) }
    func headingFont(size: CGFloat) -> NSFont { Theme.font(headingFonts, size: size, fallback: bodyFont(size: size)) }
    func monoFont(size: CGFloat) -> NSFont { Theme.font(monoFonts, size: size, fallback: .monospacedSystemFont(ofSize: size, weight: .regular)) }
}

// MARK: - Loading

enum ThemeLoader {
    /// Parse a theme stylesheet. Returns nil when it defines no colours.
    static func load(css: String, name: String) -> Theme? {
        var light: [String: String] = [:]
        var dark: [String: String] = [:]
        var sharedRoot = false
        let blockPattern = try! NSRegularExpression(pattern: "([^{}]+)\\{([^{}]*)\\}")
        let declPattern = try! NSRegularExpression(pattern: "(--[A-Za-z0-9-]+)\\s*:\\s*([^;]+);?")
        let stripped = css.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        let ns = stripped as NSString
        for block in blockPattern.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
            let selector = ns.substring(with: block.range(at: 1))
            let body = ns.substring(with: block.range(at: 2)) as NSString
            var vars: [String: String] = [:]
            for decl in declPattern.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                vars[body.substring(with: decl.range(at: 1))] = body.substring(with: decl.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let isRoot = selector.contains(":root")
            let isDark = selector.contains("data-dark")
            if isRoot && isDark { sharedRoot = true }
            if isRoot { light.merge(vars) { $1 } }
            if isDark { dark.merge(vars) { $1 } }
        }
        guard light["--bg"] != nil else { return nil }
        let darkVars = light.merging(dark) { $1 }
        func resolve(_ vars: [String: String], _ key: String, _ fallback: NSColor) -> NSColor {
            var value = vars[key]
            var guardCount = 0
            while let v = value, v.hasPrefix("var("), guardCount < 5 {
                let inner = v.dropFirst(4).prefix { $0 != ")" && $0 != "," }
                value = vars[String(inner).trimmingCharacters(in: .whitespaces)]
                guardCount += 1
            }
            return value.flatMap(parseColor) ?? fallback
        }
        func palette(_ v: [String: String]) -> ThemePalette {
            let fg = resolve(v, "--fg", .textColor)
            let bg = resolve(v, "--bg", .textBackgroundColor)
            let accent = resolve(v, "--accent", .controlAccentColor)
            return ThemePalette(
                bg: bg, bgElevated: resolve(v, "--bg-elevated", bg), fg: fg,
                fgMuted: resolve(v, "--fg-muted", fg.withAlphaComponent(0.7)),
                fgFaint: resolve(v, "--fg-faint", fg.withAlphaComponent(0.45)),
                accent: accent, accentSoft: resolve(v, "--accent-soft", accent.withAlphaComponent(0.12)),
                border: resolve(v, "--border", .separatorColor), borderStrong: resolve(v, "--border-strong", .separatorColor),
                selection: resolve(v, "--selection", .selectedTextBackgroundColor),
                codeBg: resolve(v, "--code-bg", bg), codeFg: resolve(v, "--code-fg", fg),
                inlineCodeBg: resolve(v, "--inline-code-bg", fg.withAlphaComponent(0.08)),
                inlineCodeFg: resolve(v, "--inline-code-fg", fg),
                quoteBorder: resolve(v, "--quote-border", .separatorColor), quoteFg: resolve(v, "--quote-fg", fg),
                markBg: resolve(v, "--mark-bg", .systemYellow.withAlphaComponent(0.4)), markFg: resolve(v, "--mark-fg", fg),
                tableBorder: resolve(v, "--table-border", .separatorColor), tableHeadBg: resolve(v, "--table-head-bg", bg),
                tokKeyword: resolve(v, "--tok-keyword", accent), tokString: resolve(v, "--tok-string", fg),
                tokComment: resolve(v, "--tok-comment", fg.withAlphaComponent(0.5)), tokNumber: resolve(v, "--tok-number", fg),
                tokFunction: resolve(v, "--tok-function", fg), tokType: resolve(v, "--tok-type", fg))
        }
        func fonts(_ key: String, _ fallback: [String]) -> [String] {
            var value = light[key]
            if let v = value, v.hasPrefix("var(") {
                let inner = v.dropFirst(4).prefix { $0 != ")" }
                value = light[String(inner)]
            }
            guard let stack = value else { return fallback }
            return stack.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        }
        let body = fonts("--font-body", ["-apple-system"])
        let displayName = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let cssVariables = css
        return Theme(name: name, displayName: displayName, light: palette(light), dark: palette(darkVars),
                     fixedAppearance: sharedRoot || dark.isEmpty && palette(light).isDark,
                     bodyFonts: body, headingFonts: fonts("--font-heading", body),
                     monoFonts: fonts("--font-mono", ["SF Mono", "Menlo", "monospace"]), css: cssVariables)
    }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()` and a few names.
    static func parseColor(_ raw: String) -> NSColor? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "transparent" { return .clear }
        if value == "white" { return .white }
        if value == "black" { return .black }
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
            let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
            let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
            let a = hasAlpha ? CGFloat(number & 0xff) / 255 : 1
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        if value.hasPrefix("rgb") {
            guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else { return nil }
            let parts = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { String($0) }
            guard parts.count >= 3 else { return nil }
            func component(_ text: String) -> CGFloat {
                text.hasSuffix("%") ? (CGFloat(Double(text.dropLast()) ?? 0) / 100) : CGFloat(Double(text) ?? 0) / 255
            }
            var alpha: CGFloat = 1
            if parts.count >= 4 {
                let a = parts[3]
                alpha = a.hasSuffix("%") ? CGFloat(Double(a.dropLast()) ?? 100) / 100 : CGFloat(Double(a) ?? 1)
            }
            return NSColor(srgbRed: component(parts[0]), green: component(parts[1]), blue: component(parts[2]), alpha: alpha)
        }
        return nil
    }
}

/// Bundled themes (the repo's `themes/` folder) plus the user's own in
/// ~/Library/Application Support/Frisket/themes.
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var themes: [Theme] = []

    var userThemeFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Frisket/themes", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        var found: [String: Theme] = [:]
        var folders: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("themes", isDirectory: true) { folders.append(bundled) }
        folders.append(userThemeFolder)
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "css" {
                guard let css = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                if let theme = ThemeLoader.load(css: css, name: name) { found[name] = theme }
            }
        }
        if found.isEmpty, let fallback = ThemeLoader.load(css: ":root{--bg:#ffffff;--fg:#222222;--accent:#a92336}html[data-dark=\"true\"]{--bg:#1d1b1c;--fg:#e9e3e3;--accent:#e17883}", name: "frisket") {
            found["frisket"] = fallback
        }
        themes = found.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func theme(named name: String) -> Theme {
        themes.first { $0.name == name } ?? themes.first { $0.name == "red-graphite" } ?? themes[0]
    }
}
