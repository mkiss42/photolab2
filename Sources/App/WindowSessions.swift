// WindowSessions.swift
// 0.13: saving the open windows (session.json in Find's support folder) and reopening them at the next
// start: position, size, display, desktop (Space), panes, tabs, view modes, sidebar, Info panel, order.
// Saved when Find is quit, when it stops being the front app, and when a window opens or closes.
//
// Desktops (Spaces): macOS has no public way to ask or set which desktop a window is on. Find uses the
// same private CoreGraphics calls that window managers use, looked up at run time (dlsym): if a call is
// missing or refused (newer macOS versions may refuse), the window simply opens on the current desktop.
// Nothing about files depends on this.

import AppKit
#if os(macOS)
import Darwin
#endif

enum WindowSessions {
    static var path: String { return Paths.join(App.files.supportDir, "session.json") }

    static func load() -> WindowSessionFile? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return SessionFit.decode(d)
    }

    @discardableResult
    static func save(_ controllers: [BrowserWindowController]) -> Int {
        let file = snapshot(controllers)
        guard let data = SessionFit.encode(file), App.files.writeData(data, to: path) else {
            App.log.warn("Windows could not be saved for next time (code SESS-01): \(path)")
            return -1
        }
        return file.windows.count
    }

    /// The open windows as they are now (front-most first).
    static func snapshot(_ controllers: [BrowserWindowController]) -> WindowSessionFile {
        // Front-most first, as macOS orders them now.
        let order = NSApp.orderedWindows
        let sorted = controllers.sorted { a, b in
            let ia = a.window.flatMap { w in order.index(where: { $0 === w }) } ?? Int.max
            let ib = b.window.flatMap { w in order.index(where: { $0 === w }) } ?? Int.max
            return ia < ib
        }
        var list: [SavedWindow] = []
        for c in sorted {
            guard let w = c.window, var s = c.savedState() else { continue }
            if let sc = w.screen ?? NSScreen.main {
                s.display = displayID(sc)
                s.displayFrame = SessionFit.array(wrect(sc.frame))
            }
            s.space = Spaces.desktopNumber(of: w, display: s.display)
            var shares: [String: String] = [:]
            for p in s.panes { for t in p.tabs {
                let root = VolumeRegistry.volumeRoot(t.path)
                if root != "/", let u = VolumeRegistry.shared.remountURL(t.path), VolumeRegistry.shared.isNetwork(t.path) != false { shares[root] = u }
            } }
            s.shares = shares.isEmpty ? nil : shares
            list.append(s)
        }
        return WindowSessionFile(version: 1, savedAt: Date().timeIntervalSince1970, windows: list)
    }

    // MARK: Named workspaces (0.16)

    static var workspacesDir: String { return Paths.join(App.files.supportDir, "Workspaces") }

    static func workspaceNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: workspacesDir)) ?? []
        return files.compactMap { WorkspaceNames.name(fromFile: $0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func loadWorkspace(_ name: String) -> WindowSessionFile? {
        guard let f = WorkspaceNames.fileName(for: name),
            let d = FileManager.default.contents(atPath: Paths.join(workspacesDir, f)) else { return nil }
        return SessionFit.decode(d)
    }

    static func saveWorkspace(_ name: String, _ controllers: [BrowserWindowController]) -> Bool {
        guard let f = WorkspaceNames.fileName(for: name), let data = SessionFit.encode(snapshot(controllers)) else { return false }
        return App.files.writeData(data, to: Paths.join(workspacesDir, f))
    }

    static func deleteWorkspace(_ name: String) -> Bool {
        guard let f = WorkspaceNames.fileName(for: name) else { return false }
        return App.files.removeOwned(Paths.join(workspacesDir, f))
    }

    static func displays() -> [DisplayInfo] {
        return NSScreen.screens.map { DisplayInfo(id: displayID($0), frame: wrect($0.frame), visible: wrect($0.visibleFrame)) }
    }

    static func wrect(_ r: NSRect) -> WRect {
        return WRect(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.width), h: Double(r.height))
    }

    static func nsrect(_ r: WRect) -> NSRect {
        return NSRect(x: r.x, y: r.y, width: r.w, height: r.h)
    }

    /// The display's lasting id (UUID), the same after a restart.
    static func displayID(_ s: NSScreen) -> String? {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return Spaces.displayUUID(n.uint32Value)
    }
}

/// Desktops (Spaces), through private CoreGraphics calls found at run time. Every function here may
/// return nil / false; callers carry on without it.
enum Spaces {
    #if os(macOS)
    private typealias MainConn = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias MoveToSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias DisplayUUID = @convention(c) (UInt32) -> Unmanaged<CFUUID>?

    private static func sym<T>(_ name: String, _ t: T.Type) -> T? {
        guard let h = dlopen(nil, RTLD_NOW), let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: t)
    }

    private static let mainConn = sym("CGSMainConnectionID", MainConn.self)
    private static let copySpaces = sym("CGSCopySpacesForWindows", CopySpacesForWindows.self)
    private static let copyDisplaySpaces = sym("CGSCopyManagedDisplaySpaces", CopyDisplaySpaces.self)
    private static let moveToSpace = sym("CGSMoveWindowsToManagedSpace", MoveToSpace.self)
    private static let uuidOf = sym("CGDisplayCreateUUIDFromDisplayID", DisplayUUID.self)
    #endif

    static func displayUUID(_ displayNumber: UInt32) -> String? {
        #if os(macOS)
        guard let f = uuidOf, let u = f(displayNumber)?.takeRetainedValue(), let str = CFUUIDCreateString(nil, u) else { return nil }
        return str as String
        #else
        return nil
        #endif
    }

    /// Ordinary desktops per display: (display UUID or "Main", [space ids in order]).
    private static func managedDesktops() -> [(display: String, spaces: [UInt64])] {
        #if os(macOS)
        guard let c = mainConn, let f = copyDisplaySpaces, let arr = f(c())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out: [(display: String, spaces: [UInt64])] = []
        for d in arr {
            let name = d["Display Identifier"] as? String ?? ""
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { sp -> UInt64? in
                // type 0 = an ordinary desktop (full-screen apps have their own spaces, skipped).
                if let t = sp["type"] as? NSNumber, t.intValue != 0 { return nil }
                return (sp["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (sp["id64"] as? NSNumber)?.uint64Value
            }
            out.append((display: name, spaces: spaces))
        }
        return out
        #else
        return []
        #endif
    }

    private static func spaceID(of w: NSWindow) -> UInt64? {
        #if os(macOS)
        guard let c = mainConn, let f = copySpaces, w.windowNumber > 0 else { return nil }
        let ids = [NSNumber(value: w.windowNumber)] as CFArray
        guard let arr = f(c(), 7, ids)?.takeRetainedValue() as? [NSNumber], let first = arr.first else { return nil }
        return first.uint64Value
        #else
        return nil
        #endif
    }

    /// Desktop number (1 = first) of the window on its display, or nil if unknown.
    static func desktopNumber(of w: NSWindow, display: String?) -> Int? {
        guard let sid = spaceID(of: w) else { return nil }
        for d in managedDesktops() {
            if let i = d.spaces.index(of: sid) { return i + 1 }
        }
        return nil
    }

    /// Move the window to desktop `number` of its display. Returns true if macOS reports it there afterwards.
    @discardableResult
    static func move(_ w: NSWindow, toDesktop number: Int, display: String?) -> Bool {
        #if os(macOS)
        guard number >= 1, let c = mainConn, let mv = moveToSpace, w.windowNumber > 0 else { return false }
        let all = managedDesktops()
        // The window's display entry: by UUID, or the only one ("Main") when displays share desktops.
        let entry = all.first(where: { display != nil && $0.display.caseInsensitiveCompare(display!) == .orderedSame })
            ?? (all.count == 1 ? all.first : nil)
        guard let e = entry, number <= e.spaces.count else { return false }
        let target = e.spaces[number - 1]
        if spaceID(of: w) == target { return true }
        mv(c(), [NSNumber(value: w.windowNumber)] as CFArray, target)
        return spaceID(of: w) == target
        #else
        return false
        #endif
    }
}
