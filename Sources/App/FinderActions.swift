// FinderActions.swift
// Open With, Reveal in Finder, Get Info, Eject. No disk access on the main thread: the apps for a
// file come from Launch Services by file type (extension), not by reading the file; Finder and
// the eject run in the background.

import AppKit

enum FinderActions {
    /// Apps that can open files of this kind, the default one first (from Launch Services' database).
    static func apps(for e: FileEntry) -> [URL] {
        let uti: String
        if e.isDirectory && !e.isPackage {
            uti = kUTTypeFolder as String
        } else if let u = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, e.ext as CFString, nil)?.takeRetainedValue() {
            uti = u as String
        } else {
            return []
        }
        var ids: [String] = []
        if let d = LSCopyDefaultRoleHandlerForContentType(uti as CFString, .all)?.takeRetainedValue() { ids.append(d as String) }
        if let all = LSCopyAllRoleHandlersForContentType(uti as CFString, .all)?.takeRetainedValue() as? [String] {
            for id in all where !ids.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { ids.append(id) }
        }
        var seen = Set<String>()
        return ids.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.filter { seen.insert($0.path).inserted }
    }

    /// "Open With" submenu for the selection; items send openWithApp: with the app URL.
    static func openWithMenu(for e: FileEntry) -> NSMenu {
        let m = NSMenu(title: "Open With")
        let apps = self.apps(for: e)
        for (i, app) in apps.enumerated() {
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let item = NSMenuItem(title: i == 0 ? "\(name) (default)" : name, action: Selector(("openWithApp:")), keyEquivalent: "")
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            m.addItem(item)
            if i == 0 && apps.count > 1 { m.addItem(NSMenuItem.separator()) }
        }
        if !apps.isEmpty { m.addItem(NSMenuItem.separator()) }
        m.addItem(NSMenuItem(title: "Other...", action: Selector(("openWithOther:")), keyEquivalent: ""))
        return m
    }

    static func open(_ paths: [String], with app: URL) {
        Log.info("open \(paths.count) item(s) with \(app.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            do {
                _ = try NSWorkspace.shared.open(urls, withApplicationAt: app, options: [], configuration: [:])
            } catch {
                Log.error("E-OPEN-1 could not open with \(app.lastPathComponent): \((error as NSError).localizedDescription)")
            }
        }
    }

    static func reveal(_ paths: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// Finder's Get Info windows (at most 10), through osascript in the background. The first use
    /// asks once for permission to control Finder.
    static func getInfo(_ paths: [String]) {
        let picked = Array(paths.prefix(10))
        let script = ["on run argv", "tell application \"Finder\"", "activate",
                      "repeat with p in argv", "open information window of (POSIX file (contents of p) as alias)",
                      "end repeat", "end tell", "end run"]
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments = script.flatMap { ["-e", $0] } + picked
            let err = Pipe()
            p.standardError = err
            p.launch()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Log.error("E-OPEN-2 Get Info failed (status \(p.terminationStatus)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// Volumes (not the start-up disk) whose mount point is one of `paths`.
    static func ejectable(_ paths: [String]) -> [VolumeInfo] {
        let set = Set(paths)
        return Volumes.all.filter { !$0.isRoot && set.contains($0.mountPoint) }
    }

    /// Unmount (and eject) in the background; done(nil) or done(error text) on the main thread.
    static func eject(_ v: VolumeInfo, done: @escaping (String?) -> Void) {
        Log.info("eject \(v.mountPoint)")
        DispatchQueue.global(qos: .userInitiated).async {
            var problem: String?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: v.mountPoint)) } catch {
                problem = (error as NSError).localizedDescription
                Log.error("E-EJECT-1 \(v.mountPoint): \(problem!)")
            }
            DispatchQueue.main.async { done(problem) }
        }
    }
}
