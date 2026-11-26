// Glyphs.swift
// Small template images drawn in code (no image files, same look on 10.13 and later).

import AppKit

enum Glyphs {
    /// Window-with-left-pane symbol for the sidebar button.
    static let sidebar: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 14))
        img.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let outer = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 12), xRadius: 2, yRadius: 2)
        outer.lineWidth = 1.2
        outer.stroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 6.5, y: 1.5))
        divider.line(to: NSPoint(x: 6.5, y: 12.5))
        divider.lineWidth = 1.2
        divider.stroke()
        for y in [9.0, 6.5, 4.0] as [CGFloat] {
            NSBezierPath(rect: NSRect(x: 2.5, y: y, width: 2.6, height: 1.1)).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }()

    static var computer: NSImage? {
        guard let i = NSImage(named: NSImage.computerName)?.copy() as? NSImage else { return nil }
        i.size = NSSize(width: 16, height: 16)
        return i
    }
}
