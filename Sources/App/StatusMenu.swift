// StatusMenu.swift
// The menu bar icon (always there while PhotoLab runs): Favorites and Volumes like the sidebar
// (FTP later), Network, New Window, Quit. Choosing a place opens it in a new window; Option-click
// shows it in the front window instead. Built when opened, from memory only (mount table,
// favorites): opening it never waits on a share.

import AppKit

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = Glyphs.menuBar
        item.button?.toolTip = "PhotoLab"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func header(_ t: String) {
            let h = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        func place(_ title: String, _ path: String, _ icon: NSImage?) {
            let i = NSMenuItem(title: title, action: #selector(go(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = path
            if let ic = icon?.copy() as? NSImage { ic.size = NSSize(width: 16, height: 16); i.image = ic }
            i.toolTip = path
            menu.addItem(i)
        }
        header("Favorites")
        let folder = NSImage(named: NSImage.folderName)
        for f in Favorites.all { place(f.title, f.path, folder) }
        menu.addItem(NSMenuItem.separator())
        header("Volumes")
        for v in Volumes.browsable {
            place(v.displayName, v.mountPoint, NSImage(named: v.isNetwork ? NSImage.networkName : (v.isRoot ? NSImage.computerName : NSImage.folderName)))
        }
        let net = NSMenuItem(title: "Network...", action: #selector(network(_:)), keyEquivalent: "")
        net.target = self
        net.image = NSImage(named: NSImage.networkName)?.copy() as? NSImage
        net.image?.size = NSSize(width: 16, height: 16)
        menu.addItem(net)
        menu.addItem(NSMenuItem.separator())
        let nw = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        nw.target = self
        menu.addItem(nw)
        let q = NSMenuItem(title: "Quit PhotoLab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(q)
        let hint = NSMenuItem(title: "Option-click a place: use the front window", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    @objc private func go(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let front = BrowserWindowController.open.first { $0.window?.isKeyWindow == true } ?? BrowserWindowController.open.last
        if let w = front, NSEvent.modifierFlags.contains(.option) {
            w.window?.makeKeyAndOrderFront(nil)
            w.navigate(to: p)
        } else {
            BrowserWindowController.openWindow(at: p)
        }
    }

    @objc private func network(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NetworkWindow.show(for: nil)
    }

    @objc private func newWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        BrowserWindowController.openWindow(at: UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory())
    }
}
