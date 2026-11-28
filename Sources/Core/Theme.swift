// Theme.swift
// Colors, font, size and density for Find's interface. Pure data; the AppKit layer turns it into NSColor/NSFont.

import Foundation

struct Theme: Codable, Equatable {
    var name: String
    var background: String      // main file list
    var sidebar: String         // sidebar, path bar, tab bar, status bar
    var alternateRow: String
    var text: String
    var secondaryText: String
    var accent: String          // highlight accent: focus, active tab, buttons
    var selection: String       // selected row fill
    var separator: String
    var warning: String
    var error: String
    var fontFamily: String      // "" = system font
    var fontSize: Double        // 10...18
    var density: Int            // 0 compact, 1 regular, 2 spacious
    var dark: Bool              // use the dark system appearance for standard controls

    static func == (a: Theme, b: Theme) -> Bool {
        return a.name == b.name && a.background == b.background && a.sidebar == b.sidebar &&
            a.alternateRow == b.alternateRow && a.text == b.text && a.secondaryText == b.secondaryText &&
            a.accent == b.accent && a.selection == b.selection && a.separator == b.separator &&
            a.warning == b.warning && a.error == b.error && a.fontFamily == b.fontFamily &&
            a.fontSize == b.fontSize && a.density == b.density && a.dark == b.dark
    }

    /// Row height for the file list.
    var rowHeight: Double {
        let base = fontSize + 7
        switch density {
        case 0: return base
        case 2: return base + 8
        default: return base + 4
        }
    }

    /// Default: dark grey, white text, light but dull blue accent.
    static let graphite = Theme(name: "Graphite",
                                background: "#2A2C2F", sidebar: "#232528", alternateRow: "#2F3134",
                                text: "#FFFFFF", secondaryText: "#B8BCC2",
                                accent: "#8EA8C3", selection: "#4A5866", separator: "#3A3D41",
                                warning: "#C9A45C", error: "#C96B6B",
                                fontFamily: "", fontSize: 13, density: 0, dark: true)

    static let light = Theme(name: "Light",
                             background: "#FFFFFF", sidebar: "#F0F1F3", alternateRow: "#F6F7F8",
                             text: "#1E1F21", secondaryText: "#6B7075",
                             accent: "#4F7AA6", selection: "#C9D8E8", separator: "#D6D8DB",
                             warning: "#A87B1F", error: "#B33A3A",
                             fontFamily: "", fontSize: 13, density: 0, dark: false)

    static let navy = Theme(name: "Navy",
                            background: "#1B2330", sidebar: "#151C27", alternateRow: "#202938",
                            text: "#F2F5F8", secondaryText: "#9FAEC0",
                            accent: "#6FB3B8", selection: "#2F4A5C", separator: "#2C3646",
                            warning: "#D2B15E", error: "#D27070",
                            fontFamily: "", fontSize: 13, density: 0, dark: true)

    static let highContrast = Theme(name: "High Contrast",
                                    background: "#000000", sidebar: "#0D0D0D", alternateRow: "#141414",
                                    text: "#FFFFFF", secondaryText: "#DDDDDD",
                                    accent: "#9CC3FF", selection: "#2D4F80", separator: "#555555",
                                    warning: "#FFD166", error: "#FF6B6B",
                                    fontFamily: "", fontSize: 14, density: 1, dark: true)

    static let presets: [Theme] = [graphite, light, navy, highContrast]

    /// Parse "#RRGGBB" into 0...1 components. nil if malformed.
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255.0, Double((v >> 8) & 0xFF) / 255.0, Double(v & 0xFF) / 255.0)
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ x: Double) -> Int { return max(0, min(255, Int((x * 255.0).rounded()))) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// Fill any malformed values from Graphite and clamp ranges, so a damaged theme file can't break the interface.
    func repaired() -> Theme {
        var t = self
        let g = Theme.graphite
        if Theme.rgb(t.background) == nil { t.background = g.background }
        if Theme.rgb(t.sidebar) == nil { t.sidebar = g.sidebar }
        if Theme.rgb(t.alternateRow) == nil { t.alternateRow = g.alternateRow }
        if Theme.rgb(t.text) == nil { t.text = g.text }
        if Theme.rgb(t.secondaryText) == nil { t.secondaryText = g.secondaryText }
        if Theme.rgb(t.accent) == nil { t.accent = g.accent }
        if Theme.rgb(t.selection) == nil { t.selection = g.selection }
        if Theme.rgb(t.separator) == nil { t.separator = g.separator }
        if Theme.rgb(t.warning) == nil { t.warning = g.warning }
        if Theme.rgb(t.error) == nil { t.error = g.error }
        if !(t.fontSize >= 10 && t.fontSize <= 18) { t.fontSize = 13 }
        if t.density < 0 || t.density > 2 { t.density = 0 }
        if t.name.trimmingCharacters(in: .whitespaces).isEmpty { t.name = "Custom" }
        return t
    }
}

/// Saved themes: one JSON file per theme in ~/Library/Application Support/PhotoLab/Themes.
final class ThemeStore {
    let files: AppFiles

    init(files: AppFiles) {
        self.files = files
        _ = files.makeDir(files.themesDir)
    }

    private func fileName(for name: String) -> String {
        var safe = ""
        for u in name.unicodeScalars {
            let v = u.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 32 || v == 45 || v == 95
            safe += ok ? String(u) : "_"
        }
        if safe.isEmpty { safe = "theme" }
        return safe + ".json"
    }

    func savedThemes() -> [Theme] {
        var out: [Theme] = []
        for n in files.list(files.themesDir) where n.hasSuffix(".json") {
            let p = Paths.join(files.themesDir, n)
            if let data = FileManager.default.contents(atPath: p),
                let t = try? JSONDecoder().decode(Theme.self, from: data) {
                out.append(t.repaired())
            }
        }
        return out
    }

    /// All themes: presets first, then saved ones (a saved theme with a preset's name is skipped).
    func allThemes() -> [Theme] {
        let presetNames = Set(Theme.presets.map { $0.name })
        return Theme.presets + savedThemes().filter { !presetNames.contains($0.name) }
    }

    @discardableResult
    func save(_ theme: Theme) -> Bool {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(theme.repaired()), let text = String(data: data, encoding: .utf8) else { return false }
        return files.writeText(text, to: Paths.join(files.themesDir, fileName(for: theme.name)))
    }

    @discardableResult
    func delete(named name: String) -> Bool {
        return files.removeOwned(Paths.join(files.themesDir, fileName(for: name)))
    }

    func encode(_ theme: Theme) -> String {
        guard let data = try? JSONEncoder().encode(theme), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    func decode(_ text: String) -> Theme? {
        guard let data = text.data(using: .utf8), let t = try? JSONDecoder().decode(Theme.self, from: data) else { return nil }
        return t.repaired()
    }
}
