// ThemedUI.swift
// 0.14: dialogs and the Settings window in the current theme.
// - ThemedAlert: Find's own alert (same use as NSAlert: messageText, informativeText, alertStyle,
//   addButton, accessoryView, suppression checkbox, runModal) drawn in the theme's colours.
//   Return = first button; Esc = a button named Cancel or Stop (never a button that changes files).
// - ThemeStyler: recolours a window's labels, checkboxes, text fields and text views to the theme.
// macOS's own panels (Open/Save, Keychain and server password dialogs, Print) can't be recoloured.

import AppKit

enum ThemeStyler {
    /// Each label's original role is kept in its identifier ("find.role.text" / "find.role.secondary" /
    /// "find.role.keep"), so a label recoloured once keeps its role when the theme changes.
    private static let rolePrefix = "find.role."

    static var fieldBackground: NSColor {
        let tm = ThemeManager.shared
        return tm.background.blended(withFraction: tm.theme.dark ? 0.08 : 0.03, of: tm.text) ?? tm.background
    }

    static func style(window w: NSWindow) {
        let tm = ThemeManager.shared
        w.appearance = tm.appearance
        w.backgroundColor = tm.background
        if let v = w.contentView { style(v) }
    }

    /// macOS's standard text colours (not red/orange etc., which carry a meaning and are kept).
    private static let textColorNames: Set<String> = ["labelColor", "secondaryLabelColor", "tertiaryLabelColor", "quaternaryLabelColor",
                                                      "controlTextColor", "textColor", "disabledControlTextColor", "headerTextColor"]

    private static func isSystemColor(_ c: NSColor?) -> Bool {
        guard let c = c else { return true }
        return c.type == .catalog && textColorNames.contains(c.colorNameComponent)
    }

    private static func role(_ v: NSView, _ c: NSColor?) -> String {
        if let id = v.identifier?.rawValue {
            // Views that already carry an identifier for another purpose are left as they are.
            return id.hasPrefix(rolePrefix) ? String(id.dropFirst(rolePrefix.count)) : "keep"
        }
        var r = "keep"
        if isSystemColor(c) {
            r = (c == NSColor.secondaryLabelColor || c == NSColor.tertiaryLabelColor || c == NSColor.disabledControlTextColor) ? "secondary" : "text"
        }
        v.identifier = NSUserInterfaceItemIdentifier(rolePrefix + r)
        return r
    }

    static func style(_ v: NSView) {
        let tm = ThemeManager.shared
        if let tf = v as? NSTextField {
            let r = role(tf, tf.textColor)
            if r != "keep" { tf.textColor = r == "secondary" ? tm.secondaryText : tm.text }
            if tf.isEditable {
                tf.backgroundColor = fieldBackground
                tf.drawsBackground = true
            }
        } else if let tv = v as? NSTextView {
            tv.backgroundColor = fieldBackground
            tv.textColor = tm.text
            tv.insertionPointColor = tm.text
        } else if let b = v as? NSButton, !(b is NSPopUpButton) {
            // The default button keeps macOS's look (white on the system's blue).
            if !b.title.isEmpty && b.keyEquivalent != "\r" {
                let para = NSMutableParagraphStyle()
                para.alignment = b.alignment
                b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                    .foregroundColor: tm.text, .font: b.font ?? NSFont.systemFont(ofSize: 13), .paragraphStyle: para])
            }
        } else if let box = v as? NSBox, box.boxType == .custom {
            box.fillColor = fieldBackground
            box.borderColor = tm.separator
        }
        // Tables draw their own rows (Find's tables follow the theme already).
        if v is NSTableView { return }
        for s in v.subviews { style(s) }
    }
}

/// Find's alert in the theme's colours. Use it like NSAlert.
final class ThemedAlert: NSObject {
    var messageText = ""
    var informativeText = ""
    var alertStyle: NSAlert.Style = .warning
    var accessoryView: NSView?
    var showsSuppressionButton = false
    let suppressionButton: NSButton? = NSButton(checkboxWithTitle: "Do not show this message again", target: nil, action: nil)
    private(set) var buttons: [NSButton] = []
    let window: NSPanel

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
    }

    @discardableResult
    func addButton(withTitle title: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(clicked(_:)))
        b.bezelStyle = .rounded
        b.tag = 1000 + buttons.count
        if buttons.isEmpty { b.keyEquivalent = "\r" }
        let lower = title.lowercased()
        if lower == "cancel" || lower == "stop" || lower == "don\u{2019}t connect" { b.keyEquivalent = "\u{1b}" }
        buttons.append(b)
        return b
    }

    @objc private func clicked(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
    }

    private func build() {
        if buttons.isEmpty { addButton(withTitle: "OK") }
        let tm = ThemeManager.shared
        let content = FillView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        content.fillColor = tm.background
        window.contentView = content

        // Coloured edge for warnings and errors; the app icon otherwise.
        let edge = FillView()
        edge.fillColor = alertStyle == .critical ? tm.error : (alertStyle == .warning ? tm.warning : tm.accent)
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(wrappingLabelWithString: messageText)
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.textColor = tm.text
        let info = NSTextField(wrappingLabelWithString: informativeText)
        info.font = NSFont.systemFont(ofSize: 12)
        info.textColor = tm.secondaryText
        info.isSelectable = true
        info.isHidden = informativeText.isEmpty

        var textViews: [NSView] = [title, info]
        if let acc = accessoryView {
            // Accessory views are made with a frame (as for NSAlert): keep that size in the layout.
            if acc.frame.width > 0 {
                (acc is NSStackView ? acc.widthAnchor.constraint(greaterThanOrEqualToConstant: acc.frame.width)
                    : acc.widthAnchor.constraint(equalToConstant: acc.frame.width)).isActive = true
            }
            if acc.frame.height > 0 && !(acc is NSStackView) { acc.heightAnchor.constraint(equalToConstant: acc.frame.height).isActive = true }
            textViews.append(acc)
        }
        if showsSuppressionButton, let sb = suppressionButton { textViews.append(sb) }
        let textStack = NSStackView(views: textViews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8

        // Buttons right to left: first (Return) at the right, as in macOS.
        let buttonRow = NSStackView(views: Array(buttons.reversed()))
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        for b in buttons { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true }

        let textWidth = max(360, min(620, (accessoryView?.frame.width ?? 0)))
        for v in [edge, icon, textStack, buttonRow] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            edge.topAnchor.constraint(equalTo: content.topAnchor),
            edge.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 4),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            textStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            textStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            title.widthAnchor.constraint(equalToConstant: textWidth),
            info.widthAnchor.constraint(equalToConstant: textWidth),
            buttonRow.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: icon.trailingAnchor, constant: 16),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        ThemeStyler.style(window: window)
        // The default (Return) button in the theme's accent colour.
        if let d = buttons.first {
            d.bezelColor = tm.accent
            // Dark text on a light accent, white on a dark one (readable either way).
            let lum = Theme.rgb(tm.theme.accent).map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 } ?? 0
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            d.attributedTitle = NSAttributedString(string: d.title, attributes: [
                .foregroundColor: lum > 0.45 ? NSColor.black : NSColor.white, .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: para])
        }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        if window.initialFirstResponder == nil { window.initialFirstResponder = buttons.first }
    }

    /// Show it and wait for a button. Returns .alertFirstButtonReturn (1000) for the first button, 1001...
    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        build()
        // Centred a little above the middle of the window in front (or the screen).
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent !== window {
            let pf = parent.frame, f = window.frame
            window.setFrameOrigin(NSPoint(x: pf.midX - f.width / 2, y: pf.midY - f.height / 2 + pf.height / 8))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        let r = NSApp.runModal(for: window)
        window.orderOut(nil)
        return r
    }
}

/// Which windows ThemeStyler recolours: Find's own dialogs and tool windows - not the browser windows
/// (themed already), Fast Preview, Compare, and macOS's own panels.
extension ThemeStyler {
    static func shouldStyle(_ w: NSWindow) -> Bool {
        if w.windowController is BrowserWindowController || w.windowController is CompareWindowController { return false }
        if w is PreviewPanel || w is NSSavePanel || w is NSColorPanel || w is NSFontPanel { return false }
        return true
    }

    static func styleAllWindows() {
        for w in NSApp.windows where shouldStyle(w) { style(window: w) }
    }
}

/// Settings' list of sections down the left side, in the theme's sidebar colours.
final class SectionList: FillView {
    private(set) var titles: [String] = []
    private(set) var selected = 0
    var onSelect: ((Int) -> Void)?
    private let rowHeight: CGFloat = 30
    /// PhotoLab Settings search: matches per section (nil = no search); sections without any are dimmed.
    var matchCounts: [Int]? { didSet { needsDisplay = true } }
    /// Space above the first row (the search field sits there).
    var topInset: CGFloat = 16 { didSet { needsDisplay = true } }

    func setTitles(_ t: [String]) {
        titles = t
        needsDisplay = true
    }

    func select(_ i: Int) {
        guard i >= 0 && i < titles.count else { return }
        selected = i
        needsDisplay = true
    }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        let tm = ThemeManager.shared
        fillColor = tm.sidebar
        super.draw(dirtyRect)
        for (i, t) in titles.enumerated() {
            let r = NSRect(x: 10, y: topInset + CGFloat(i) * rowHeight, width: bounds.width - 20, height: rowHeight - 4)
            let count = matchCounts.map { i < $0.count ? $0[i] : 0 }
            let dim = count == 0
            if i == selected {
                tm.selection.setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                tm.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + 5, width: 3, height: r.height - 10), xRadius: 1.5, yRadius: 1.5).fill()
            }
            let base = i == selected ? tm.text : tm.secondaryText
            let attrs: [AttrKey: Any] = [.foregroundColor: dim ? base.withAlphaComponent(0.35) : base,
                                                       .font: i == selected ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)]
            let a = NSAttributedString(string: t, attributes: attrs)
            let size = a.size()
            a.draw(with: NSRect(x: r.minX + 14, y: r.midY - size.height / 2, width: r.width - 18, height: size.height + 2), options: [.usesLineFragmentOrigin])
            if let c = count, c > 0 {
                let ca = NSAttributedString(string: "\(c)", attributes: [.foregroundColor: tm.accent, .font: NSFont.boldSystemFont(ofSize: 11)])
                let cs = ca.size()
                ca.draw(at: NSPoint(x: r.maxX - cs.width - 8, y: r.midY - cs.height / 2))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.y - topInset) / rowHeight)
        guard p.y >= topInset, i >= 0, i < titles.count, i != selected else { return }
        select(i)
        onSelect?(i)
    }
}
