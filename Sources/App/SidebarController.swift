// SidebarController.swift
// Favorites and Volumes. Built from the cached mount table: no disk access for network volumes.
// Favorites are the user's (Core/Favorites.swift): drag folders in (from the list or Finder),
// drag to reorder, right-click > Remove from Sidebar.

import AppKit

final class SidebarItem: NSObject {
    let title: String
    let path: String?
    let icon: NSImage?
    var children: [SidebarItem]

    init(title: String, path: String?, icon: NSImage?, children: [SidebarItem] = []) {
        self.title = title
        self.path = path
        self.icon = icon
        self.children = children
    }

    var isGroup: Bool { return path == nil }
}

final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let favoriteType = NSPasteboard.PasteboardType("com.smp.photolab2.favorite")
    static let networkPath = "photolab:network"
    let scroll = NSScrollView()
    let outline = NSOutlineView()
    private var groups: [SidebarItem] = []
    private var settingSelection = false

    var onSelect: ((String) -> Void)?
    var onOpenInNewWindow: ((String) -> Void)?

    override init() {
        super.init()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.selectionHighlightStyle = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.registerForDraggedTypes([.fileURL, SidebarController.favoriteType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        let m = NSMenu()
        m.delegate = self
        outline.menu = m
        NotificationCenter.default.addObserver(forName: .favoritesChanged, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }

    func reload() {
        let folder = NSImage(named: NSImage.folderName)
        let favorites = SidebarItem(title: "FAVORITES", path: nil, icon: nil,
                                    children: Favorites.all.map { SidebarItem(title: $0.title, path: $0.path, icon: folder) })
        var vols: [SidebarItem] = []
        for v in Volumes.browsable {
            let icon: NSImage?
            if v.isNetwork { icon = NSImage(named: NSImage.networkName) }
            else if v.isRoot { icon = NSImage(named: NSImage.computerName) }
            else {
                let t0 = Date()
                icon = NSWorkspace.shared.icon(forFile: v.mountPoint)   // local disk
                let ms = Date().timeIntervalSince(t0) * 1000
                if ms > 50 {
                    Stats.noteSlowIcon(ms)
                    Log.info(String(format: "slow volume icon: %@ took %.0f ms", v.displayName, ms))
                }
            }
            vols.append(SidebarItem(title: v.displayName, path: v.mountPoint, icon: icon))
        }
        // "Network" (like Finder's): browse and connect to servers. Not a folder: a special path.
        vols.append(SidebarItem(title: "Network", path: SidebarController.networkPath, icon: NSImage(named: NSImage.networkName)))
        let volumes = SidebarItem(title: "VOLUMES", path: nil, icon: nil, children: vols)
        groups = [favorites, volumes]
        outline.reloadData()
        for g in groups { outline.expandItem(g) }
    }

    /// Highlight the item for `path` (exact match), without triggering navigation.
    func reflect(path: String) {
        settingSelection = true
        defer { settingSelection = false }
        for g in groups {
            for c in g.children where c.path == path {
                let row = outline.row(forItem: c)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                return
            }
        }
        outline.deselectAll(nil)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let it = item as? SidebarItem else { return groups.count }
        return it.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let it = item as? SidebarItem else { return groups[index] }
        return it.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? SidebarItem)?.isGroup ?? false
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return (item as? SidebarItem)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return !((item as? SidebarItem)?.isGroup ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let it = item as? SidebarItem else { return nil }
        let id = NSUserInterfaceItemIdentifier(it.isGroup ? "HeaderCell" : "DataCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id, header: it.isGroup)
        cell.textField?.stringValue = it.title
        cell.imageView?.image = it.icon
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, header: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        if header {
            tf.font = NSFont.boldSystemFont(ofSize: 11)
            tf.textColor = NSColor.secondaryLabelColor
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        } else {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            ])
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Editing Favorites (drag in, drag to reorder, context menu)

    private var favoritesGroup: SidebarItem? { return groups.first }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let it = item as? SidebarItem, let p = it.path, favoritesGroup?.children.contains(where: { $0 === it }) == true else { return nil }
        let pi = NSPasteboardItem()
        pi.setString(p, forType: SidebarController.favoriteType)       // internal only: never a file drag
        return pi
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let fav = favoritesGroup else { return [] }
        var idx = index
        if let it = item as? SidebarItem, it !== fav {
            guard let i = fav.children.firstIndex(where: { $0 === it }) else { return [] }   // not onto volumes
            idx = i
        } else if item == nil || idx == NSOutlineViewDropOnItemIndex {
            idx = fav.children.count
        }
        outlineView.setDropItem(fav, dropChildIndex: idx)
        return info.draggingPasteboard.types?.contains(SidebarController.favoriteType) == true ? .move : .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard
        if let p = pb.string(forType: SidebarController.favoriteType) {
            Favorites.all = Favorites.inserting([p], at: index, into: Favorites.all)
            return true
        }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let paths = urls.map { $0.path }
        guard !paths.isEmpty else { return false }
        // Only folders become favorites; checking that touches the disk, so not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let dirs = paths.filter { p in var st = stat(); return stat(p, &st) == 0 && UInt32(st.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) }
            DispatchQueue.main.async {
                if dirs.isEmpty { NSSound.beep(); return }
                Favorites.all = Favorites.inserting(dirs, at: index, into: Favorites.all)
                Log.info("sidebar: \(dirs.count) favorite(s) added by drop")
            }
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let it = outline.item(atRow: outline.clickedRow) as? SidebarItem, let p = it.path, p != SidebarController.networkPath else { return }
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = p
            menu.addItem(i)
        }
        add("Open in New Window", #selector(menuOpenNew(_:)))
        add("Show in Finder", #selector(menuReveal(_:)))
        if favoritesGroup?.children.contains(where: { $0 === it }) == true {
            menu.addItem(NSMenuItem.separator())
            add("Remove from Sidebar", #selector(menuRemove(_:)))
        } else if let v = FinderActions.ejectable([p]).first {
            menu.addItem(NSMenuItem.separator())
            add("Eject \"\(v.displayName)\"", #selector(menuEject(_:)))
        }
    }

    @objc private func menuOpenNew(_ sender: NSMenuItem) { if let p = sender.representedObject as? String { onOpenInNewWindow?(p) } }
    @objc private func menuReveal(_ sender: NSMenuItem) { if let p = sender.representedObject as? String { FinderActions.reveal([p]) } }
    @objc private func menuRemove(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        Favorites.all = Favorites.removing(p, from: Favorites.all)
        Log.info("sidebar: favorite removed")
    }
    @objc private func menuEject(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String, let v = FinderActions.ejectable([p]).first else { return }
        for c in BrowserWindowController.open where c.currentPath == p || c.currentPath.hasPrefix(p + "/") { c.navigate(to: "/Volumes") }
        FinderActions.eject(v) { problem in
            if let pr = problem { BrowserWindowController.open.first?.showProblem("\"\(v.displayName)\" was not ejected", pr) }
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if settingSelection { return }
        guard let it = outline.item(atRow: outline.selectedRow) as? SidebarItem, let p = it.path else { return }
        onSelect?(p)
    }
}
