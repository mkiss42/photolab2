// Compat.swift
// Names that changed between Swift 4.1 (Xcode 9.4, High Sierra) and later Swift versions.
// build.sh compiles with -swift-version 4 on Xcode 9.x and -swift-version 5 on newer compilers,
// so `#if swift(>=4.2)` picks the right spelling in both cases.

import AppKit

#if swift(>=4.2)
typealias AttrKey = NSAttributedString.Key
#else
typealias AttrKey = NSAttributedStringKey
#endif

func attributed(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
    return NSAttributedString(string: s, attributes: [AttrKey.font: font, AttrKey.foregroundColor: color])
}

func namedImage(_ name: String) -> NSImage? {
    #if swift(>=4.2)
    return NSImage(named: name)
    #else
    return NSImage(named: NSImage.Name(rawValue: name))
    #endif
}

func itemID(_ s: String) -> NSUserInterfaceItemIdentifier {
    return NSUserInterfaceItemIdentifier(rawValue: s)
}

extension NSView {
    /// Pin all four edges to `container` with optional insets. Turns off autoresizing-mask constraints.
    func pinEdges(to container: NSView, top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: left),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -right),
        ])
    }
}

/// A plain view that fills itself with a color (no layer tricks, works on 10.13).
class FillView: NSView {
    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    /// Optional 1-point line along the bottom (or top) edge.
    var bottomLine: NSColor? = nil {
        didSet { needsDisplay = true }
    }
    var topLine: NSColor? = nil {
        didSet { needsDisplay = true }
    }
    /// 0.16: a bar (toolbar, status line) that gets the Depth light.
    var isBar = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
        if isBar { Finish.drawBarLight(bounds, flipped: isFlipped) }
        if let c = bottomLine {
            c.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if let c = topLine {
            c.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

/// Borderless text button drawn in theme colors.
final class ThemedButton: NSButton {
    var isAccent = false

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1.0 : 0.35 }
    }

    func applyTheme(_ title: String? = nil) {
        let tm = ThemeManager.shared
        let t = title ?? self.title
        isBordered = false
        let color = isAccent ? tm.accent : tm.text
        attributedTitle = attributed(t, font: tm.font, color: color)
    }
}

func makeButton(_ title: String, _ target: AnyObject?, _ action: Selector, tip: String? = nil) -> ThemedButton {
    let b = ThemedButton(title: title, target: target, action: action)
    b.isBordered = false
    b.setButtonType(.momentaryChange)
    b.toolTip = tip
    b.applyTheme(title)
    return b
}

func makeLabel(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.lineBreakMode = .byTruncatingTail
    return l
}
