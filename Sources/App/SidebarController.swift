// SidebarController.swift
// Favorites and Volumes. Built from the cached mount table: no disk access for network volumes.

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

final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scroll = NSScrollView()
    let outline = NSOutlineView()
    private var groups: [SidebarItem] = []
    private var settingSelection = false

    var onSelect: ((String) -> Void)?

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
        reload()
    }

    func reload() {
        let home = NSHomeDirectory()
        let folder = NSImage(named: NSImage.folderName)
        let favorites = SidebarItem(title: "FAVORITES", path: nil, icon: nil, children: [
            SidebarItem(title: NSUserName(), path: home, icon: folder),
            SidebarItem(title: "Desktop", path: home + "/Desktop", icon: folder),
            SidebarItem(title: "Documents", path: home + "/Documents", icon: folder),
            SidebarItem(title: "Downloads", path: home + "/Downloads", icon: folder),
            SidebarItem(title: "Pictures", path: home + "/Pictures", icon: folder),
        ])
        var vols: [SidebarItem] = []
        for v in Volumes.browsable {
            let icon: NSImage?
            if v.isNetwork { icon = NSImage(named: NSImage.networkName) }
            else if v.isRoot { icon = NSImage(named: NSImage.computerName) }
            else { icon = NSWorkspace.shared.icon(forFile: v.mountPoint) }   // local disk: cheap
            vols.append(SidebarItem(title: v.displayName, path: v.mountPoint, icon: icon))
        }
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

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if settingSelection { return }
        guard let it = outline.item(atRow: outline.selectedRow) as? SidebarItem, let p = it.path else { return }
        onSelect?(p)
    }
}
