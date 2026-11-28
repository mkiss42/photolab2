// ThemeManager.swift
// Holds the active theme and hands out ready-made NSColor/NSFont values.
// Every view reads its colors and fonts from here; nothing else hard-codes a color.

import AppKit

extension Notification.Name {
    static let findThemeChanged = Notification.Name("FindThemeChanged")
    static let findPrefsChanged = Notification.Name("FindPrefsChanged")
    /// 0.16: Depth / Glow / Glass / Dim changed: redraw only (no theme rebuild).
    static let findFinishChanged = Notification.Name("FindFinishChanged")
    static let findVolumesChanged = Notification.Name("FindVolumesChanged")
    /// Colour tags read in the background: userInfo["paths"] = [String].
    static let findTagsRead = Notification.Name("FindTagsRead")
}

final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var theme: Theme = Theme.graphite

    private(set) var background = NSColor.black
    private(set) var sidebar = NSColor.black
    private(set) var alternateRow = NSColor.black
    private(set) var text = NSColor.white
    private(set) var secondaryText = NSColor.white
    private(set) var accent = NSColor.white
    private(set) var selection = NSColor.white
    private(set) var separator = NSColor.white
    private(set) var warning = NSColor.white
    private(set) var error = NSColor.white
    private(set) var font = NSFont.systemFont(ofSize: 13)
    private(set) var boldFont = NSFont.boldSystemFont(ofSize: 13)
    private(set) var smallFont = NSFont.systemFont(ofSize: 11)
    private(set) var smallBoldFont = NSFont.boldSystemFont(ofSize: 11)

    private init() {
        var t = Theme.graphite
        if let json = UserDefaults.standard.string(forKey: Prefs.Key.currentTheme),
            let data = json.data(using: .utf8),
            let saved = try? JSONDecoder().decode(Theme.self, from: data) {
            t = saved.repaired()
        }
        build(t)
    }

    static func color(_ hex: String) -> NSColor {
        guard let c = Theme.rgb(hex) else { return NSColor.magenta }
        return NSColor(srgbRed: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1)
    }

    static func hex(of color: NSColor) -> String {
        guard let c = color.usingColorSpace(NSColorSpace.sRGB) else { return "#000000" }
        return Theme.hex(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private func makeFont(_ family: String, _ size: CGFloat, bold: Bool) -> NSFont {
        if !family.isEmpty,
            let f = NSFontManager.shared.font(withFamily: family, traits: bold ? [.boldFontMask] : [], weight: bold ? 9 : 5, size: size) {
            return f
        }
        return bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    }

    private func build(_ t: Theme) {
        theme = t.repaired()
        background = ThemeManager.color(theme.background)
        sidebar = ThemeManager.color(theme.sidebar)
        alternateRow = ThemeManager.color(theme.alternateRow)
        text = ThemeManager.color(theme.text)
        secondaryText = ThemeManager.color(theme.secondaryText)
        accent = ThemeManager.color(theme.accent)
        selection = ThemeManager.color(theme.selection)
        separator = ThemeManager.color(theme.separator)
        warning = ThemeManager.color(theme.warning)
        error = ThemeManager.color(theme.error)
        let size = CGFloat(theme.fontSize)
        font = makeFont(theme.fontFamily, size, bold: false)
        boldFont = makeFont(theme.fontFamily, size, bold: true)
        smallFont = makeFont(theme.fontFamily, max(10, size - 2), bold: false)
        smallBoldFont = makeFont(theme.fontFamily, max(10, size - 2), bold: true)
        if isNative {
            // PhotoLab "Native": the system's own colours (they follow light / dark mode).
            background = .controlBackgroundColor
            sidebar = .windowBackgroundColor
            alternateRow = NSColor.controlAlternatingRowBackgroundColors.count > 1 ? NSColor.controlAlternatingRowBackgroundColors[1] : .controlBackgroundColor
            text = .labelColor
            secondaryText = .secondaryLabelColor
            accent = .keyboardFocusIndicatorColor
            selection = .selectedTextBackgroundColor
            separator = .gridColor
            warning = .systemOrange
            error = .systemRed
        }
    }

    /// PhotoLab: the Native theme - standard macOS look, no colours of PhotoLab's own.
    var isNative: Bool { return theme.name == Theme.nativeName }

    var rowHeight: CGFloat { return CGFloat(theme.rowHeight) }

    var appearance: NSAppearance? {
        if isNative { return nil }   // whatever macOS is set to
        return NSAppearance(named: theme.dark ? NSAppearance.Name.vibrantDark : NSAppearance.Name.aqua)
    }

    /// Switch theme, remember it, and tell every window to redraw.
    func apply(_ t: Theme) {
        build(t)
        if let data = try? JSONEncoder().encode(theme), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: Prefs.Key.currentTheme)
        }
        NotificationCenter.default.post(name: .findThemeChanged, object: nil)
    }
}
