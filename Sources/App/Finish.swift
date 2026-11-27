// Finish.swift
// 0.16: the visual finish - four settings in Settings > Appearance, each 0-100:
//   Depth  - soft light on the bars (a gentle gradient and a highlight line), shadows under thumbnails
//   Glow   - accent glow on the selection, the focused pane's outline and colour-class squares
//   Glass  - the sidebar and Info panel let the desktop show through, blurred (macOS vibrancy)
//   Dim    - with several panes, the ones you aren't using are dimmed
// 0.17: every effect is about twice as strong at the same setting (and Glass actually shows the
// desktop: a lighter material and a thinner tint). All four at 0 draw exactly as before 0.16. Nothing here is drawn per row or per file beyond what
// was drawn already: the effects cost a few extra fills on the visible rows only.

import AppKit

enum Finish {
    static var depth: CGFloat { return CGFloat(max(0, min(100, Prefs.finishDepth))) / 100 }
    static var glow: CGFloat { return CGFloat(max(0, min(100, Prefs.finishGlow))) / 100 }
    static var glass: CGFloat { return CGFloat(max(0, min(100, Prefs.finishGlass))) / 100 }
    /// 0.17.4: Glass behind the file lists and thumbnails (its own setting).
    static var contentGlass: CGFloat { return CGFloat(max(0, min(100, Prefs.finishContentGlass))) / 100 }
    /// Lists that show the content glass: their rows leave the background see-through.
    static var glassTables = GlassTableSet()
    static var dim: CGFloat { return CGFloat(max(0, min(60, Prefs.finishDim))) / 100 * 1.25 }

    /// Soft light on a bar: brighter at the top, fading out; a 1-point highlight along the top edge.
    static func drawBarLight(_ r: NSRect, flipped: Bool) {
        let d = depth
        guard d > 0 else { return }
        if let g = NSGradient(starting: NSColor(white: 1, alpha: 0.13 * d), ending: NSColor(white: 1, alpha: 0)) {
            g.draw(in: r, angle: flipped ? 90 : -90)
        }
        NSColor(white: 1, alpha: 0.16 * d).setFill()
        NSRect(x: r.minX, y: flipped ? r.minY : r.maxY - 1, width: r.width, height: 1).fill()
    }

    /// A selected row: the selection colour, an accent light fading to the right, an accent edge.
    static func drawSelection(_ r: NSRect, base: NSColor, rounded: Bool) {
        let path = rounded ? NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4) : NSBezierPath(rect: r)
        base.setFill()
        path.fill()
        let g = glow
        guard g > 0 else { return }
        let acc = ThemeManager.shared.accent
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let grad = NSGradient(starting: acc.withAlphaComponent(0.6 * g), ending: acc.withAlphaComponent(0)) {
            grad.draw(in: r, angle: 0)
        }
        acc.withAlphaComponent(g).setFill()
        NSRect(x: r.minX, y: r.minY, width: 2 + g, height: r.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A soft glow of `color` around whatever is drawn while it is set (nil when Glow is 0).
    static func glowShadow(_ color: NSColor, radius: CGFloat = 11) -> NSShadow? {
        let g = glow
        guard g > 0 else { return nil }
        let s = NSShadow()
        s.shadowColor = color.withAlphaComponent(min(1, 1.2 * g))
        s.shadowBlurRadius = radius * g
        s.shadowOffset = .zero
        return s
    }

    /// The shadow under a thumbnail (nil when Depth is 0).
    static func thumbShadow(flipped: Bool) -> NSShadow? {
        let d = depth
        guard d > 0 else { return nil }
        let s = NSShadow()
        s.shadowColor = NSColor(white: 0, alpha: min(0.85, 0.85 * d))
        s.shadowBlurRadius = 12 * d
        s.shadowOffset = NSSize(width: 0, height: (flipped ? 4 : -4) * d)
        return s
    }

    /// The desktop-through material for the theme (vibrancy). 0.17: "dark" (2) / "light" (1) by number,
    /// the same on every macOS; 0.16's "ultra dark" was nearly black, so nothing showed through.
    static func material() -> NSVisualEffectView.Material {
        return NSVisualEffectView.Material(rawValue: ThemeManager.shared.theme.dark ? 2 : 1) ?? .light
    }

    /// macOS's "Reduce transparency" (Accessibility > Display) is on: no desktop can show through.
    static var systemReducesTransparency: Bool {
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// The matching vibrant appearance, so the blur is light or dark like the theme.
    static func vibrantAppearance() -> NSAppearance? {
        return NSAppearance(named: ThemeManager.shared.theme.dark ? .vibrantDark : .vibrantLight)
    }
}

/// Over a pane: with several panes, a dim veil on the panes you aren't using and a glowing outline on
/// the one you are. Clicks go through.
final class PaneOverlay: NSView {
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    var several = false { didSet { if several != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard several else { return }
        let tm = ThemeManager.shared
        if !focused {
            let d = Finish.dim
            if d > 0 {
                tm.background.withAlphaComponent(d).setFill()
                bounds.fill()
            }
            return
        }
        let g = Finish.glow
        guard g > 0 else { return }
        for (inset, width, alpha) in [(CGFloat(0.5), CGFloat(1), CGFloat(0.95)), (2, 2, 0.4), (4.5, 3, 0.16), (7.5, 3, 0.06)] {
            tm.accent.withAlphaComponent(min(1, alpha * g)).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            p.lineWidth = width
            p.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

/// Glass for a panel (sidebar, Info panel): macOS's blurred desktop-through material with the theme
/// colour over it as a tint. Glass 0: hidden, and the panel is filled with its colour as before.
final class GlassBacking {
    private let effect = NSVisualEffectView()
    private let tint = GlassTint()
    private weak var host: FillView?

    /// Put the glass under everything already in `host`.
    init(in host: FillView) {
        self.host = host
        for v in [effect, tint] as [NSView] {
            v.frame = host.bounds
            v.autoresizingMask = [.width, .height]
        }
        effect.blendingMode = .behindWindow
        effect.state = .active
        host.addSubview(tint, positioned: .below, relativeTo: host.subviews.first)
        host.addSubview(effect, positioned: .below, relativeTo: tint)
    }

    /// `base`: the panel's theme colour. `leftLine`: the separator drawn at its left edge, if any.
    func apply(base: NSColor, leftLine: NSColor? = nil, strength: CGFloat? = nil) {
        guard let h = host else { return }
        let g = strength ?? Finish.glass
        if g > 0 {
            // 0.17.1: the panel itself must NOT be layer-backed: macOS only blends the desktop through
            // when the effect view is not inside the first layer-backed view (0.16/0.17.0 did that, so
            // only the plain grey material showed). The effect view layer-backs itself.
            effect.material = Finish.material()
            effect.appearance = Finish.vibrantAppearance()
            effect.isHidden = false
            tint.isHidden = false
            // 0.17: Glass 100 leaves a 12% tint; 0.16 kept 50% plus a very dark material, which hid it.
            tint.fillColor = base.withAlphaComponent(1 - 0.88 * g)
            tint.leftLine = leftLine
            h.fillColor = .clear
        } else {
            effect.isHidden = true
            tint.isHidden = true
            h.fillColor = base
        }
        tint.needsDisplay = true
        h.needsDisplay = true
    }
}

final class GlassTint: FillView {
    var leftLine: NSColor? = nil

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let c = leftLine {
            c.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}


extension BrowserPane {
    /// Settings > Appearance > Test Drawing Speed: scroll this pane's list or thumbnails 60 steps,
    /// drawing each one, and time it. Puts the view back where it was. Changes nothing else.
    func drawingSpeedTest() -> (frames: Int, ms: Double, what: String) {
        let sv: NSScrollView = viewMode == "list" ? list.scroll : gridScroll
        guard let w = sv.window, let doc = sv.documentView else { return (0, 0, "no window") }
        let clip = sv.contentView
        let start = clip.bounds.origin
        let room = max(0, doc.bounds.height - clip.bounds.height)
        let steps = 60
        let stepSize = max(8, min(60, room / CGFloat(steps)))
        let t0 = Date()
        var y = start.y
        var down = true
        for _ in 0..<steps {
            if room > 0 {
                y += down ? stepSize : -stepSize
                if y > room { y = room; down = false }
                if y < 0 { y = 0; down = true }
                clip.setBoundsOrigin(NSPoint(x: start.x, y: y))
                sv.reflectScrolledClipView(clip)
            }
            sv.needsDisplay = true
            w.displayIfNeeded()
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        clip.setBoundsOrigin(start)
        sv.reflectScrolledClipView(clip)
        let what = viewMode == "list" ? "list, \(list.rootCount) items" : "thumbnails, \(grid.entries.count) shown"
        return (steps, ms, what)
    }
}


/// The lists drawn with Glass behind them (by identity; only decides how row backgrounds are drawn).
struct GlassTableSet {
    private var ids = Set<ObjectIdentifier>()
    mutating func add(_ t: NSTableView) { ids.insert(ObjectIdentifier(t)) }
    mutating func remove(_ t: NSTableView) { ids.remove(ObjectIdentifier(t)) }
    func contains(_ t: NSTableView) -> Bool { return ids.contains(ObjectIdentifier(t)) }
}
