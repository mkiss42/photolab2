// WindowPlacementManager.swift
// The one place that decides where new Find windows open (rules live in Core/WindowPlacement.swift).

import AppKit

final class WindowPlacementManager {
    static let shared = WindowPlacementManager()

    private struct Record {
        let quarter: Quarter
        let order: Int
    }

    private var records: [ObjectIdentifier: Record] = [:]
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var counter = 0

    static func wrect(_ r: NSRect) -> WRect {
        return WRect(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.size.width), h: Double(r.size.height))
    }

    static func nsrect(_ r: WRect) -> NSRect {
        return NSRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h))
    }

    /// Place a new browser window in the right quarter of the display used by the existing Find windows.
    @discardableResult
    func place(_ window: NSWindow, reference: NSWindow?) -> NSRect? {
        let screen = reference?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let s = screen else { return nil }
        let vis = WindowPlacementManager.wrect(s.visibleFrame)
        var existing: [PlacedWindow] = []
        var notes: [String] = []
        for (id, w) in windows where w !== window && w.isVisible && !w.isMiniaturized {
            guard let rec = records[id] else { continue }
            // Compare displays by their frame: AppKit can hand out different NSScreen objects for the same display.
            guard let ws = w.screen ?? screenContaining(w.frame), ws.frame == s.frame else {
                notes.append("other display: \(rec.quarter.label)")
                continue
            }
            let pw = PlacedWindow(quarter: rec.quarter, frame: WindowPlacementManager.wrect(w.frame), placedOrder: rec.order)
            existing.append(pw)
            let holds = WindowPlacement.holdsQuarter(pw, in: vis)
            notes.append("\(rec.quarter.label) #\(rec.order) \(holds ? "in place" : "moved/resized") frame \(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \(Int(w.frame.width))x\(Int(w.frame.height))")
        }
        let q = WindowPlacement.chooseQuarter(existing: existing, visible: vis)
        assign(window, q, vis)
        Log.shared?.info("Window placed in \(q.label) quarter. Usable area \(Int(vis.x)),\(Int(vis.y)) \(Int(vis.w))x\(Int(vis.h)). Others: " +
            (notes.isEmpty ? "none" : notes.joined(separator: "; ")))
        return WindowPlacementManager.nsrect(WindowPlacement.frame(of: q, in: vis))
    }

    private func screenContaining(_ f: NSRect) -> NSScreen? {
        let c = NSPoint(x: f.midX, y: f.midY)
        for sc in NSScreen.screens where sc.frame.contains(c) { return sc }
        return nil
    }

    /// Put a window into a specific quarter of its current display (Window menu).
    func move(_ window: NSWindow, to q: Quarter) {
        guard let s = window.screen ?? NSScreen.main else { return }
        assign(window, q, WindowPlacementManager.wrect(s.visibleFrame))
    }

    private func assign(_ window: NSWindow, _ q: Quarter, _ vis: WRect) {
        counter += 1
        let id = ObjectIdentifier(window)
        records[id] = Record(quarter: q, order: counter)
        windows[id] = window
        window.setFrame(WindowPlacementManager.nsrect(WindowPlacement.frame(of: q, in: vis)), display: true)
    }

    /// A window put back where it was last time (not in a quarter): kept on screen after display changes.
    func adopt(_ window: NSWindow) {
        windows[ObjectIdentifier(window)] = window
    }

    func forget(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        records[id] = nil
        windows[id] = nil
    }

    /// After the window is on screen: if AppKit moved or resized it, put it back.
    func confirm(_ window: NSWindow, intended: NSRect) {
        let now = WindowPlacementManager.wrect(window.frame)
        if !now.close(to: WindowPlacementManager.wrect(intended), tolerance: 1) {
            Log.shared?.warn("Window frame changed after showing (\(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)) \(Int(window.frame.width))x\(Int(window.frame.height))); restoring its quarter")
            window.setFrame(intended, display: true)
        }
    }

    /// After a display change, pull windows back inside the usable area.
    func screensChanged() {
        for (_, w) in windows {
            guard let s = w.screen ?? NSScreen.main else { continue }
            let vis = WindowPlacementManager.wrect(s.visibleFrame)
            let f = WindowPlacementManager.wrect(w.frame)
            let c = WindowPlacement.clamp(f, into: vis)
            if !(c == f) { w.setFrame(WindowPlacementManager.nsrect(c), display: true) }
        }
    }
}
