import AppKit

extension Notification.Name {
    /// Posted on any settings change; `userInfo["key"]` names the setting.
    static let frisketSettingsChanged = Notification.Name("FrisketSettingsChanged")
}

enum AppearanceSetting: String, CaseIterable {
    case system, light, dark
}

/// User preferences, the macOS counterpart of store.js's DEFAULTS, kept in UserDefaults.
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "theme": "red-graphite",
            "appearance": AppearanceSetting.system.rawValue,
            "focusMode": false,
            "typewriterMode": false,
            "sourceMode": false,
            "fontSize": 17.0,
            "lineHeight": 1.72,
            "contentWidth": 780.0,
            "spellCheck": true,
            "autoSave": true,
            "autoPair": true,
            "showStatusBar": true,
            "librarySort": "modified",
            "backlinksVisible": false,
            "pandocPath": "",
            "savedSearches": [String](),
            "recentFiles": [String](),
        ])
    }

    private func changed(_ key: String) {
        NotificationCenter.default.post(name: .frisketSettingsChanged, object: self, userInfo: ["key": key])
    }

    var theme: String {
        get { defaults.string(forKey: "theme") ?? "red-graphite" }
        set { defaults.set(newValue, forKey: "theme"); changed("theme") }
    }
    var appearance: AppearanceSetting {
        get { AppearanceSetting(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance"); changed("appearance") }
    }
    var focusMode: Bool {
        get { defaults.bool(forKey: "focusMode") }
        set { defaults.set(newValue, forKey: "focusMode"); changed("focusMode") }
    }
    var typewriterMode: Bool {
        get { defaults.bool(forKey: "typewriterMode") }
        set { defaults.set(newValue, forKey: "typewriterMode"); changed("typewriterMode") }
    }
    var sourceMode: Bool {
        get { defaults.bool(forKey: "sourceMode") }
        set { defaults.set(newValue, forKey: "sourceMode"); changed("sourceMode") }
    }
    var fontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "fontSize")) }
        set { defaults.set(Double(min(max(newValue, 10), 40)), forKey: "fontSize"); changed("fontSize") }
    }
    var lineHeight: CGFloat {
        get { CGFloat(defaults.double(forKey: "lineHeight")) }
        set { defaults.set(Double(min(max(newValue, 1.1), 2.6)), forKey: "lineHeight"); changed("lineHeight") }
    }
    var contentWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: "contentWidth")) }
        set { defaults.set(Double(min(max(newValue, 420), 1600)), forKey: "contentWidth"); changed("contentWidth") }
    }
    var spellCheck: Bool {
        get { defaults.bool(forKey: "spellCheck") }
        set { defaults.set(newValue, forKey: "spellCheck"); changed("spellCheck") }
    }
    var autoSave: Bool {
        get { defaults.bool(forKey: "autoSave") }
        set { defaults.set(newValue, forKey: "autoSave"); changed("autoSave") }
    }
    var autoPair: Bool {
        get { defaults.bool(forKey: "autoPair") }
        set { defaults.set(newValue, forKey: "autoPair"); changed("autoPair") }
    }
    var showStatusBar: Bool {
        get { defaults.bool(forKey: "showStatusBar") }
        set { defaults.set(newValue, forKey: "showStatusBar"); changed("showStatusBar") }
    }
    var librarySort: String {
        get { defaults.string(forKey: "librarySort") ?? "modified" }
        set { defaults.set(newValue, forKey: "librarySort"); changed("librarySort") }
    }
    var backlinksVisible: Bool {
        get { defaults.bool(forKey: "backlinksVisible") }
        set { defaults.set(newValue, forKey: "backlinksVisible"); changed("backlinksVisible") }
    }
    var pandocPath: String {
        get { defaults.string(forKey: "pandocPath") ?? "" }
        set { defaults.set(newValue, forKey: "pandocPath"); changed("pandocPath") }
    }
    var savedSearches: [String] {
        get { defaults.stringArray(forKey: "savedSearches") ?? [] }
        set { defaults.set(newValue, forKey: "savedSearches"); changed("savedSearches") }
    }

    /// The library folder, kept as a bookmark so a moved folder is still found.
    var libraryURL: URL? {
        get {
            guard let data = defaults.data(forKey: "libraryBookmark") else { return nil }
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        set {
            if let url = newValue, let data = try? url.bookmarkData() {
                defaults.set(data, forKey: "libraryBookmark")
            } else {
                defaults.removeObject(forKey: "libraryBookmark")
            }
            changed("library")
        }
    }

    /// The note open when the app last quit, restored on launch.
    var lastNotePath: String? {
        get { defaults.string(forKey: "lastNotePath") }
        set { defaults.set(newValue, forKey: "lastNotePath") }
    }

    /// Effective dark mode for the editor, given the theme and the appearance setting.
    func isDark(for appearance: NSAppearance) -> Bool {
        let theme = ThemeStore.shared.theme(named: self.theme)
        if theme.fixedAppearance { return theme.light.isDark }
        switch self.appearance {
        case .light: return false
        case .dark: return true
        case .system: return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    var nsAppearance: NSAppearance? {
        let theme = ThemeStore.shared.theme(named: self.theme)
        if theme.fixedAppearance { return NSAppearance(named: theme.light.isDark ? .darkAqua : .aqua) }
        switch appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
