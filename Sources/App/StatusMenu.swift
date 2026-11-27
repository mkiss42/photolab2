// StatusMenu.swift  (ported from PhotoLab 2 0.9.2)
// The menu bar icon (there while PhotoLab runs): Favorites, Devices, Network shares and Servers as in
// the sidebar. A click opens the place in a new window; Option-click shows it in the front window.
// Built when opened, from memory only (preferences, the mount table PhotoLab already keeps): opening
// it never waits on a share. Also: what folders dropped on the Dock icon open as.

import AppKit

final class StatusMenu: NSObject, NSMenuDelegate {
    static var shared: StatusMenu?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    /// Dock / Open With drops: "list" (tree) or "photo" (contact sheet).
    static var dropOpens: String {
        get { return UserDefaults.standard.string(forKey: "dropOpens") ?? "list" }
        set { UserDefaults.standard.set(newValue, forKey: "dropOpens") }
    }

    static let glyph: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 16))
        img.lockFocus()
        NSColor.black.setStroke()
        let outer = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 13), xRadius: 2, yRadius: 2)
        outer.lineWidth = 1.4
        outer.stroke()
        NSColor.black.setFill()
        for (x, y) in [(4.0, 8.5), (10.0, 8.5), (4.0, 3.5), (10.0, 3.5)] {
            NSBezierPath(rect: NSRect(x: x, y: y, width: 4, height: 3.5)).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }()

    override init() {
        super.init()
        item.button?.image = StatusMenu.glyph
        item.button?.toolTip = "PhotoLab"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    private static func small(_ name: NSImage.Name) -> NSImage? {
        guard let i = NSImage(named: name)?.copy() as? NSImage else { return nil }
        i.size = NSSize(width: 16, height: 16)
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func header(_ t: String) {
            if menu.numberOfItems > 0 { menu.addItem(NSMenuItem.separator()) }
            let h = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        func place(_ title: String, _ path: String, _ icon: NSImage?) {
            let i = NSMenuItem(title: title, action: #selector(go(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = path
            i.image = icon
            menu.addItem(i)
        }
        let names = Prefs.favoriteNames
        let favs = Prefs.favorites.filter { !FTPFavorite.isFavorite($0) }
        if !favs.isEmpty {
            header("Favorites")
            let folder = StatusMenu.small(NSImage.folderName)
            for p in favs { place(names[p].flatMap { $0.isEmpty ? nil : $0 } ?? Paths.lastComponent(p), p, folder) }
        }
        let vols = Volumes.mounted()
        let local = vols.filter { $0.isLocal }
        if !local.isEmpty {
            header("Devices")
            for v in local { place(v.name, v.path, StatusMenu.small(v.isRoot ? NSImage.computerName : NSImage.folderName)) }
        }
        let shares = vols.filter { !$0.isLocal }
        if !shares.isEmpty {
            header("Network")
            for v in shares { place(v.name, v.path, StatusMenu.small(NSImage.networkName)) }
        }
        let servers = Prefs.savedServers
        if !servers.isEmpty {
            header("Servers")
            let records = VolumeRegistry.shared.volumes
            for (i, s) in servers.enumerated() {
                let it = NSMenuItem(title: s.name, action: #selector(server(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                it.image = StatusMenu.small(NSImage.networkName)
                if ServerList.mountedPath(s, volumes: records) == nil { it.title = s.name + " (connect)" }
                menu.addItem(it)
            }
        }
        menu.addItem(NSMenuItem.separator())
        let nw = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        nw.target = self
        menu.addItem(nw)
        let drop = NSMenuItem(title: "Folders Dropped on the Dock Icon Open As", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (t, m) in [("List", "list"), ("Contact Sheet", "photo")] {
            let x = NSMenuItem(title: t, action: #selector(setDrop(_:)), keyEquivalent: "")
            x.target = self
            x.representedObject = m
            x.state = StatusMenu.dropOpens == m ? .on : .off
            sub.addItem(x)
        }
        drop.submenu = sub
        menu.addItem(drop)
        let q = NSMenuItem(title: "Quit PhotoLab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(q)
        let hint = NSMenuItem(title: "Option-click a place: use the front window", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    private var delegate: AppDelegate? { return NSApp.delegate as? AppDelegate }

    private func frontWindow() -> BrowserWindowController? {
        guard let d = delegate else { return nil }
        return d.windowControllers.first { $0.window?.isKeyWindow == true }
            ?? d.windowControllers.first { $0.window?.isMainWindow == true } ?? d.windowControllers.last
    }

    @objc private func go(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        if NSEvent.modifierFlags.contains(.option), let w = frontWindow() {
            w.window?.makeKeyAndOrderFront(nil)
            w.pane.navigate(to: p)
        } else {
            delegate?.newWindow(path: p)
        }
    }

    @objc private func server(_ sender: NSMenuItem) {
        let servers = Prefs.savedServers
        guard sender.tag >= 0, sender.tag < servers.count else { return }
        NSApp.activate(ignoringOtherApps: true)
        let w: BrowserWindowController?
        if NSEvent.modifierFlags.contains(.option), let f = frontWindow() { w = f } else { w = delegate?.newWindow(path: Prefs.startPath) }
        w?.window?.makeKeyAndOrderFront(nil)
        w?.sidebarOpenServer(servers[sender.tag])
    }

    @objc private func setDrop(_ sender: NSMenuItem) {
        if let m = sender.representedObject as? String { StatusMenu.dropOpens = m }
    }

    @objc private func newWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        delegate?.newWindow(path: Prefs.startPath)
    }
}
