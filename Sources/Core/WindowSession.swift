// WindowSession.swift
// 0.13: Find reopens its windows where and how they were when it was quit: position, size, display,
// desktop (Space, where macOS allows it), panes (side by side or stacked, their sizes), tabs and folders,
// view mode, sidebar and Info panel. Saved in Find's support folder (session.json). Pure Foundation:
// the rules for fitting a saved window onto the displays connected now are tested on Linux.

import Foundation

struct SavedTab: Codable, Equatable {
    var path: String
}

struct SavedPane: Codable, Equatable {
    var tabs: [SavedTab]
    var active: Int
    var viewMode: String
    /// Width (side by side) or height (stacked) of the pane, in points.
    var size: Double
}

struct SavedWindow: Codable, Equatable {
    /// x, y, width, height in screen coordinates (origin bottom-left of the main display).
    var frame: [Double]
    /// The display it was on (macOS display UUID) and that display's frame then.
    var display: String?
    var displayFrame: [Double]?
    /// Desktop (Space) number on that display, 1 = first; nil = unknown.
    var space: Int?
    var sidebarCollapsed: Bool
    var sidebarWidth: Double
    var inspector: Bool
    var stacked: Bool
    var panes: [SavedPane]
    var focused: Int
    var minimized: Bool
    /// Network shares its tabs were on: share folder -> address to reconnect it (0.13).
    var shares: [String: String]? = nil
}

struct WindowSessionFile: Codable {
    var version = 1
    var savedAt: Double
    /// Front-most window first.
    var windows: [SavedWindow]
}

struct DisplayInfo {
    let id: String?
    let frame: WRect
    let visible: WRect
}

enum SessionFit {
    static func rect(_ a: [Double]?) -> WRect? {
        guard let a = a, a.count == 4, a[2] > 50, a[3] > 50 else { return nil }
        return WRect(x: a[0], y: a[1], w: a[2], h: a[3])
    }

    static func array(_ r: WRect) -> [Double] { return [r.x, r.y, r.w, r.h] }

    /// The display to use: the same one (by id, else by its frame) if still connected, else the first
    /// (main) display. Returns its index in `displays`.
    static func display(for w: SavedWindow, in displays: [DisplayInfo]) -> Int {
        if let id = w.display, let i = displays.index(where: { $0.id == id }) { return i }
        if let f = rect(w.displayFrame), let i = displays.index(where: { $0.frame == f }) { return i }
        if let f = rect(w.frame), let i = displays.index(where: { $0.frame.contains(f.midX, f.midY) }) { return i }
        return 0
    }

    /// Where the window goes now: its saved frame, fully inside the usable area of its display
    /// (moved, and made smaller only if it doesn't fit). A missing display: same relative place on the main one.
    static func frame(for w: SavedWindow, in displays: [DisplayInfo]) -> WRect? {
        guard !displays.isEmpty, var f = rect(w.frame) else { return nil }
        let i = display(for: w, in: displays)
        let d = displays[i]
        let sameDisplay = (w.display != nil && d.id == w.display) || rect(w.displayFrame).map { $0 == d.frame } ?? false
            || d.frame.contains(f.midX, f.midY)
        if !sameDisplay, let old = rect(w.displayFrame) {
            // Keep its relative position and size on the display it moves to.
            let rx = (f.x - old.x) / old.w, ry = (f.y - old.y) / old.h
            let rw = f.w / old.w, rh = f.h / old.h
            f = WRect(x: d.visible.x + rx * d.visible.w, y: d.visible.y + ry * d.visible.h, w: rw * d.visible.w, h: rh * d.visible.h)
        }
        return WindowPlacement.clamp(f, into: d.visible)
    }

    /// A folder to open: the saved one if it is there, else its nearest existing parent. Paths on network
    /// shares are kept as they are (the share may connect a moment later; the pane then shows Reconnect).
    static func usablePath(_ p: String, exists: (String) -> Bool, isNetwork: (String) -> Bool, home: String) -> String {
        if isNetwork(p) { return p }
        var cur = p
        while cur != "/" && !cur.isEmpty {
            if exists(cur) { return cur }
            cur = Paths.parent(cur)
        }
        return exists("/") ? (p == "/" ? "/" : home) : home
    }

    static func encode(_ s: WindowSessionFile) -> Data? {
        let e = JSONEncoder()
        return try? e.encode(s)
    }

    static func decode(_ d: Data) -> WindowSessionFile? {
        return try? JSONDecoder().decode(WindowSessionFile.self, from: d)
    }
}

/// Named workspaces (0.16): saved window sets, one file each in Find's support folder
/// ("Workspaces/<name>.findworkspace"). Names are kept to characters that are safe as file names.
enum WorkspaceNames {
    static let suffix = ".findworkspace"

    static func clean(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var count = 0
        for u in t.unicodeScalars {
            if u == "/" || u == ":" || u.value < 32 || u.value == 127 { continue }
            if count >= 60 { break }
            out.unicodeScalars.append(u)
            count += 1
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func fileName(for name: String) -> String? {
        let c = clean(name)
        if c.isEmpty || c.hasPrefix(".") { return nil }
        return c + suffix
    }

    static func name(fromFile f: String) -> String? {
        guard f.hasSuffix(suffix), !f.hasPrefix(".") else { return nil }
        let n = String(f.dropLast(suffix.count))
        return n.isEmpty ? nil : n
    }
}
