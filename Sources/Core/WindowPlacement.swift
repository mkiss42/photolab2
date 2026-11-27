// WindowPlacement.swift
// Quarter-screen placement rules, as plain geometry (macOS coordinates: origin bottom-left).
//
// Rules (brief section 5 + user decision):
//  1. New windows take quarters in order: top-left, top-right, bottom-left, bottom-right.
//  2. If any open window has been moved/resized off its quarter, the new window goes top-left.
//  3. If all four quarters are taken, the new window reuses the quarter whose newest window is the oldest
//     (so the 5th window goes on the 1st window's quarter, the 6th on the 2nd's, and so on).

import Foundation

struct WRect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static func == (a: WRect, b: WRect) -> Bool {
        return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h
    }

    func close(to o: WRect, tolerance: Double) -> Bool {
        return abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance &&
            abs(w - o.w) <= tolerance && abs(h - o.h) <= tolerance
    }

    var midX: Double { return x + w / 2 }
    var midY: Double { return y + h / 2 }

    func contains(_ px: Double, _ py: Double) -> Bool {
        return px >= x && px <= x + w && py >= y && py <= y + h
    }
}

enum Quarter: Int {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3

    static let order: [Quarter] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    var label: String {
        switch self {
        case .topLeft: return "top-left"
        case .topRight: return "top-right"
        case .bottomLeft: return "bottom-left"
        case .bottomRight: return "bottom-right"
        }
    }
}

struct PlacedWindow {
    let quarter: Quarter?
    let frame: WRect
    /// Increasing number: when the window was placed.
    let placedOrder: Int
}

enum WindowPlacement {
    static let tolerance = 4.0

    /// The frame of a quarter inside the usable screen area. Whole points; left/bottom halves take any odd point.
    static func frame(of q: Quarter, in visible: WRect) -> WRect {
        let leftW = (visible.w / 2).rounded(.down)
        let rightW = visible.w - leftW
        let bottomH = (visible.h / 2).rounded(.down)
        let topH = visible.h - bottomH
        switch q {
        case .topLeft: return WRect(x: visible.x, y: visible.y + bottomH, w: leftW, h: topH)
        case .topRight: return WRect(x: visible.x + leftW, y: visible.y + bottomH, w: rightW, h: topH)
        case .bottomLeft: return WRect(x: visible.x, y: visible.y, w: leftW, h: bottomH)
        case .bottomRight: return WRect(x: visible.x + leftW, y: visible.y, w: rightW, h: bottomH)
        }
    }

    /// Does this window still occupy its assigned quarter?
    static func holdsQuarter(_ w: PlacedWindow, in visible: WRect) -> Bool {
        guard let q = w.quarter else { return false }
        return w.frame.close(to: frame(of: q, in: visible), tolerance: tolerance)
    }

    /// Choose the quarter for a new window, given the Find windows already on this display.
    static func chooseQuarter(existing: [PlacedWindow], visible: WRect) -> Quarter {
        if existing.isEmpty { return .topLeft }
        for w in existing where !holdsQuarter(w, in: visible) {
            return .topLeft
        }
        var newestInQuarter: [Int: Int] = [:]
        for w in existing {
            guard let q = w.quarter else { continue }
            newestInQuarter[q.rawValue] = max(newestInQuarter[q.rawValue] ?? Int.min, w.placedOrder)
        }
        for q in Quarter.order where newestInQuarter[q.rawValue] == nil {
            return q
        }
        // All four taken: the quarter whose newest window is the oldest. Ties go in quarter order.
        var best = Quarter.topLeft
        var bestOrder = Int.max
        for q in Quarter.order {
            let o = newestInQuarter[q.rawValue] ?? Int.max
            if o < bestOrder {
                bestOrder = o
                best = q
            }
        }
        return best
    }

    /// Keep a frame fully inside the usable area (used when displays change).
    static func clamp(_ f: WRect, into visible: WRect) -> WRect {
        var r = f
        r.w = min(r.w, visible.w)
        r.h = min(r.h, visible.h)
        r.x = max(visible.x, min(r.x, visible.x + visible.w - r.w))
        r.y = max(visible.y, min(r.y, visible.y + visible.h - r.h))
        return r
    }
}
