// SidebarController.swift
// Left sidebar: Favorites, Frequent, Recent, Devices, Network.

import AppKit

protocol SidebarDelegate: class {
    func sidebarNavigate(_ path: String)
    func sidebarOpenInNewTab(_ path: String)
    func sidebarEject(_ path: String)
    /// Files dropped on a place: (paths, destination folder, move).
    func sidebarDrop(_ paths: [String], into dest: String, move: Bool)
    /// A saved server was clicked: open it (connecting first if needed).
    func sidebarOpenServer(_ server: SavedServer)
    func sidebarOpenServerInNewPane(_ server: SavedServer)
}

/// What happened when a saved server last tried to connect (this run of Find), for its tooltip.
enum ServerStatus {
    static var lastError: [String: String] = [:]
}

final class SidebarController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Item {
        case header(title: String, section: String, collapsed: Bool)
        case place(title: String, path: String, section: String)
        /// A saved server; `open`/`root` when it is connected.
        case server(SavedServer, open: String?, root: String?)
        /// A clickable line such as "Add Server..."
        case action(title: String, id: String)
    }

    let table = SidebarTableView()
    let scroll = NSScrollView()
    weak var delegate: SidebarDelegate?
    private(set) var items: [Item] = []
    private var syncing = false
    private var volumeNames: [String: String] = [:]

    override init() {
        super.init()
        let col = NSTableColumn(identifier: itemID("place"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.floatsGroupRows = false
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.sidebar = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.rowSizeStyle = .custom
        table.registerForDraggedTypes(FileDrag.types + [SidebarController.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller = ThemedScroller()
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        applyTheme()
    }

    /// 0.16: glass on or off without rebuilding the rows.
    func applyFinish() {
        let glass = Finish.glass > 0
        table.backgroundColor = glass ? .clear : ThemeManager.shared.sidebar
        scroll.drawsBackground = !glass
        table.needsDisplay = true
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        // 0.16 Glass: clear, so the blurred desktop and the tint under the table show.
        let glass = Finish.glass > 0
        table.backgroundColor = glass ? .clear : tm.sidebar
        scroll.backgroundColor = tm.sidebar
        scroll.drawsBackground = !glass
        scroll.scrollerKnobStyle = tm.theme.dark ? .light : .dark
        table.reloadData()
    }

    private func displayName(_ path: String) -> String {
        if path == "/" {
            if let n = volumeNames["/"] { return n }
            return "Computer"
        }
        if path == NSHomeDirectory() { return Paths.lastComponent(path) }
        return Paths.lastComponent(path)
    }

    func rebuild(currentPath: String?) {
        var list: [Item] = []
        let vols = Volumes.mounted()
        volumeNames = [:]
        for v in vols { volumeNames[v.path] = v.name }
        let hidden = Prefs.sidebarHidden
        let collapsed = Prefs.sidebarCollapsed
        let servers = Prefs.savedServers
        let records = VolumeRegistry.shared.volumes
        var serverRoots = Set<String>()
        for s in servers { if let m = ServerList.mountedPath(s, volumes: records) { serverRoots.insert(m.root) } }

        for section in Prefs.sidebarOrder where !hidden.contains(section) {
            var places: [(String, String)] = []
            switch section {
            case "fav":
                // 0.17.2: a favourite can have its own name (shown here only); FTP folders are favourites too.
                let names = Prefs.favoriteNames
                places = Prefs.favorites.map { p in
                    if let n = names[p], !n.isEmpty { return (n, p) }
                    return (FTPFavorite.isFavorite(p) ? FTPFavorite.title(p) : displayName(p), p)
                }
            case "freq":
                places = Prefs.frequent.map { (displayName($0), $0) }
            case "recent":
                places = Prefs.recents.prefix(Prefs.recentCount).map { (displayName($0), $0) }
            case "dev":
                places = ordered(vols.filter { $0.isLocal }.map { ($0.name, $0.path) }, section)
            case "net":
                // Shares that belong to a saved server are listed under Servers instead.
                places = ordered(vols.filter { !$0.isLocal && !serverRoots.contains($0.path) }.map { ($0.name, $0.path) }, section)
            case "srv":
                let isCollapsed = collapsed.contains(section)
                list.append(.header(title: Prefs.sectionTitles[section] ?? section, section: section, collapsed: isCollapsed))
                if !isCollapsed {
                    for s in servers {
                        let m = ServerList.mountedPath(s, volumes: records)
                        list.append(.server(s, open: m?.open, root: m?.root))
                    }
                    list.append(.action(title: "Add Server\u{2026}", id: "addServer"))
                }
                continue
            default:
                break
            }
            if places.isEmpty { continue }
            let isCollapsed = collapsed.contains(section)
            list.append(.header(title: Prefs.sectionTitles[section] ?? section, section: section, collapsed: isCollapsed))
            if !isCollapsed {
                for (t, p) in places { list.append(.place(title: t, path: p, section: section)) }
            }
        }
        // Rebuilding changes rows under the selection; don't treat that as the user clicking a place.
        let wasSyncing = syncing
        syncing = true
        items = list
        table.reloadData()
        if let p = currentPath { sync(to: p) } else { table.deselectAll(nil) }
        syncing = wasSyncing
    }

    /// Clicking a section header collapses or expands it.
    @objc func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        if row >= 0, row < items.count, case .action(_, let id) = items[row], id == "addServer" {
            addServer(nil)
            return
        }
        guard row >= 0, row < items.count, case .header(_, let section, _) = items[row] else { return }
        var c = Prefs.sidebarCollapsed
        if c.contains(section) { c.remove(section) } else { c.insert(section) }
        Prefs.sidebarCollapsed = c
    }

    /// Highlight the row for the current folder, if it's listed.
    func sync(to path: String) {
        let wasSyncing = syncing
        syncing = true
        var found = -1
        for (i, it) in items.enumerated() {
            if case .place(_, let p, _) = it, p == path {
                found = i
                break
            }
            if case .server(_, let open, _) = it, open == path {
                found = i
                break
            }
        }
        if found >= 0 {
            table.selectRowIndexes(IndexSet(integer: found), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        syncing = wasSyncing
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    // MARK: Changing the order by dragging (0.14)
    // Favorites, Devices, Network and Servers rows move within their own section; a section heading
    // moves the whole section. Only the order changes - nothing on disk. Recent and Frequent keep their
    // own order (most recent / most used first).

    static let rowType = NSPasteboard.PasteboardType("com.find.sidebar-row")

    private func ordered(_ places: [(String, String)], _ section: String) -> [(String, String)] {
        let order = SidebarOrder.apply(places.map { $0.1 }, order: Prefs.sidebarItemOrder(section))
        return order.compactMap { p in places.first(where: { $0.1 == p }) }
    }

    /// The section a row belongs to, and whether it can be dragged.
    private func dragInfo(_ row: Int) -> (section: String, isHeader: Bool)? {
        guard row >= 0, row < items.count else { return nil }
        switch items[row] {
        case .header(_, let section, _): return (section, true)
        case .place(_, _, let section): return ["fav", "dev", "net"].contains(section) ? (section, false) : nil
        case .server: return ("srv", false)
        case .action: return nil
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard dragInfo(row) != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: SidebarController.rowType)
        return item
    }

    private func draggedRow(_ info: NSDraggingInfo) -> Int? {
        #if swift(>=4.2)
        let pb = info.draggingPasteboard
        #else
        let pb = info.draggingPasteboard()
        #endif
        guard let s = pb.string(forType: SidebarController.rowType), let r = Int(s) else { return nil }
        return r
    }

    /// Rows of one section (not its heading): indexes into `items`.
    private func rows(of section: String) -> [Int] {
        return items.indices.filter { i in
            if case .header = items[i] { return false }
            if case .action = items[i] { return false }
            return dragInfo(i)?.section == section
        }
    }

    private func headerRows() -> [Int] {
        return items.indices.filter { if case .header = items[$0] { return true }; return false }
    }

    /// Where a dragged row would go: (new order for its section) or nil if not allowed there.
    private func reorder(from: Int, to row: Int) -> (section: String, isHeader: Bool, from: Int, to: Int)? {
        guard let d = dragInfo(from) else { return nil }
        if d.isHeader {
            // Dropped above a heading (or at the very end): the section goes before that one.
            let heads = headerRows()
            guard let fi = heads.index(of: from) else { return nil }
            let ti: Int
            if row >= items.count { ti = heads.count } else if let h = heads.index(of: row) { ti = h } else { return nil }
            return (d.section, true, fi, ti)
        }
        let rs = rows(of: d.section)
        guard let fi = rs.index(of: from), let first = rs.first, let last = rs.last, row >= first, row <= last + 1 else { return nil }
        let ti = row == last + 1 ? rs.count : (rs.index(of: row) ?? -1)
        guard ti >= 0 else { return nil }
        return (d.section, false, fi, ti)
    }

    private func applyReorder(_ r: (section: String, isHeader: Bool, from: Int, to: Int)) {
        if r.isHeader {
            // Headings shown are the visible sections in their order; hidden ones keep their place.
            let shown = headerRows().compactMap { i -> String? in
                if case .header(_, let s, _) = items[i] { return s }
                return nil
            }
            let moved = SidebarOrder.move(shown, from: r.from, to: r.to)
            var full = Prefs.sidebarOrder
            var k = 0
            for (i, s) in full.enumerated() where shown.contains(s) {
                full[i] = moved[k]
                k += 1
            }
            Prefs.sidebarOrder = full
            App.log.info("Sidebar sections reordered: \(full.joined(separator: ", "))")
            return
        }
        switch r.section {
        case "fav":
            Prefs.favorites = SidebarOrder.move(Prefs.favorites, from: r.from, to: r.to)
        case "srv":
            Prefs.savedServers = SidebarOrder.move(Prefs.savedServers, from: r.from, to: r.to)
        default:
            let paths = rows(of: r.section).compactMap { i -> String? in
                if case .place(_, let p, _) = items[i] { return p }
                return nil
            }
            Prefs.setSidebarItemOrder(r.section, SidebarOrder.move(paths, from: r.from, to: r.to))
        }
        App.log.info("Sidebar: \(Prefs.sectionTitles[r.section] ?? r.section) reordered")
    }

    // MARK: Dropping files on a place (folder, drive, share)

    private func dropPath(_ row: Int) -> String? {
        guard row >= 0, row < items.count else { return nil }
        if case .place(_, let path, _) = items[row] { return FTPFavorite.isFavorite(path) ? nil : path }
        if case .server(_, let open, _) = items[row] { return open }   // only when connected
        return nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if let from = draggedRow(info) {
            // A sidebar row being moved: only between rows of its own section (headings: between sections).
            guard dropOperation == .above, reorder(from: from, to: row) != nil else { return [] }
            return .move
        }
        // Between two rows: use the row below (or above, at the very end).
        var r = row
        if dropOperation == .above && dropPath(r) == nil { r = row - 1 }
        guard let dest = dropPath(r) else { return [] }
        let op = FileDrag.operation(info, sources: FileDrag.paths(info), dest: dest)
        if op.isEmpty { return [] }
        tableView.setDropRow(r, dropOperation: .on)
        return op
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if let from = draggedRow(info) {
            guard dropOperation == .above, let r = reorder(from: from, to: row) else { return false }
            applyReorder(r)
            return true
        }
        guard let dest = dropPath(row) else { return false }
        let sources = FileDrag.paths(info)
        let op = FileDrag.operation(info, sources: sources, dest: dest)
        if op.isEmpty { return false }
        delegate?.sidebarDrop(sources, into: dest, move: op == .move)
        return true
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = items[row] { return false }
        if case .action = items[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 24 }
        return max(22, ThemeManager.shared.rowHeight + 2)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = SidebarRowView()
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tm = ThemeManager.shared
        switch items[row] {
        case .header(let title, _, let collapsed):
            let id = itemID("sbHeader")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? ThemedCellView) ?? ThemedCellView.make(identifier: id, withIcon: false)
            v.secondary = true
            v.applyTheme()
            v.textField?.stringValue = (collapsed ? "\u{25B8} " : "\u{25BE} ") + title.uppercased()
            v.textField?.font = tm.smallBoldFont
            v.textField?.textColor = tm.secondaryText
            v.toolTip = collapsed ? "Click to show" : "Click to hide"
            return v
        case .place(let title, let path, let section):
            let ejectable = (section == "dev" || section == "net") && Volumes.isEjectable(path)
            let id = itemID(ejectable ? "sbVolume" : "sbPlace")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? ThemedCellView) ?? ThemedCellView.make(identifier: id, withIcon: true)
            if ejectable {
                let b = v.accessory as? EjectButton ?? EjectButton(sidebar: self)
                b.path = path
                b.applyTheme()
                v.accessory = b
            }
            v.secondary = false
            v.textField?.stringValue = title
            if FTPFavorite.isFavorite(path) {
                v.imageView?.image = namedImage("NSNetwork") ?? IconCache.shared.icon(forPath: "/")
                v.toolTip = FTPFavorite.tooltip(path)
                v.applyTheme()
                return v
            }
            v.imageView?.image = IconCache.shared.icon(forPath: path)
            v.toolTip = Prefs.favoriteNames[path].map { "\($0) = \(path)" } ?? path
            v.applyTheme()
            // Dim places that aren't there. On a share: from the cached volume list only (a stat would
            // wait for the server, and this runs on the main thread).
            let reg = VolumeRegistry.shared
            let missing = reg.treatAsNetwork(path) ? !reg.isMounted(VolumeRegistry.volumeRoot(path)) : !Sys.exists(path)
            if missing { v.textField?.textColor = tm.secondaryText }
            return v
        case .server(let s, let open, let root):
            let id = itemID(root != nil ? "sbServerOn" : "sbServerOff")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? ThemedCellView) ?? ThemedCellView.make(identifier: id, withIcon: true)
            if let r = root {
                let b = v.accessory as? EjectButton ?? EjectButton(sidebar: self)
                b.path = r
                b.applyTheme()
                v.accessory = b
            }
            v.secondary = false
            v.textField?.stringValue = s.name
            v.imageView?.image = namedImage("NSNetwork") ?? IconCache.shared.icon(forPath: "/Volumes")
            var tip = s.address + (s.user.isEmpty ? "" : "  (account \(s.user))")
            tip += open != nil ? "\nConnected: \(open!)" : "\nNot connected - click to connect"
            if s.autoConnect { tip += "\nConnects when Find starts" }
            if root == nil, let err = ServerStatus.lastError[s.id] { tip += "\nLast try: \(err)" }
            v.toolTip = tip
            v.applyTheme()
            if root == nil { v.textField?.textColor = tm.secondaryText }
            return v
        case .action(let title, _):
            let id = itemID("sbAction")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? ThemedCellView) ?? ThemedCellView.make(identifier: id, withIcon: false)
            v.secondary = true
            v.applyTheme()
            v.textField?.stringValue = "   " + title
            v.textField?.textColor = tm.secondaryText
            v.toolTip = "Save a server address (with its account and password) so it stays in the sidebar"
            return v
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if syncing { return }
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        if case .server(let s, _, _) = items[row] {
            delegate?.sidebarOpenServer(s)
            return
        }
        guard case .place(_, let path, _) = items[row] else { return }
        delegate?.sidebarNavigate(path)
    }

    // MARK: Saved servers

    private func serverMenu(_ s: SavedServer, open: String?, root: String?) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ obj: Any?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.representedObject = obj
            m.addItem(i)
            return i
        }
        _ = add(open != nil ? "Open" : "Connect", #selector(openServerFromMenu(_:)), s.id)
        _ = add("Open in New Pane", #selector(openServerInNewPane(_:)), s.id)
        if let r = root { _ = add("Eject \u{201C}\(s.name)\u{201D}", #selector(ejectFromMenu(_:)), r) }
        if let o = open { _ = add("Open in New Tab", #selector(openInNewTab(_:)), o) }
        m.addItem(NSMenuItem.separator())
        let auto = add("Connect When Find Starts", #selector(toggleAutoConnect(_:)), s.id)
        auto.state = s.autoConnect ? .on : .off
        _ = add("Edit\u{2026}", #selector(editServer(_:)), s.id)
        _ = add("Remove Saved Server\u{2026}", #selector(removeServer(_:)), s.id)
        m.addItem(NSMenuItem.separator())
        _ = add("Add Server\u{2026}", #selector(addServer(_:)), nil)
        return m
    }

    private func server(_ id: Any?) -> SavedServer? {
        guard let i = id as? String else { return nil }
        return Prefs.savedServers.first(where: { $0.id == i })
    }

    @objc func openServerInNewPane(_ sender: NSMenuItem) {
        if let s = server(sender.representedObject) { delegate?.sidebarOpenServerInNewPane(s) }
    }

    @objc func openServerFromMenu(_ sender: NSMenuItem) {
        if let s = server(sender.representedObject) { delegate?.sidebarOpenServer(s) }
    }

    @objc func addServer(_ sender: Any?) {
        ServerActions.add(prefill: nil)
    }

    @objc func saveAsServer(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String,
            let v = VolumeRegistry.shared.volumes.first(where: { $0.path == p }),
            let entry = ServerList.entry(forMounted: v) else { return }
        ServerActions.add(prefill: entry)
    }

    @objc func editServer(_ sender: NSMenuItem) {
        if let s = server(sender.representedObject) { ServerActions.edit(s) }
    }

    @objc func toggleAutoConnect(_ sender: NSMenuItem) {
        if let s = server(sender.representedObject) { ServerActions.setAutoConnect(s.id, !s.autoConnect) }
    }

    @objc func removeServer(_ sender: NSMenuItem) {
        if let s = server(sender.representedObject) { ServerActions.remove(s) }
    }

    // MARK: Context menu

    func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        if case .header(let title, let section, _) = items[row] {
            let m = NSMenu()
            if section == "srv" || section == "net" {
                let add = NSMenuItem(title: "Add Server\u{2026}", action: #selector(addServer(_:)), keyEquivalent: "")
                add.target = self
                m.addItem(add)
                m.addItem(NSMenuItem.separator())
            }
            let hide = NSMenuItem(title: "Hide \(title)", action: #selector(hideSection(_:)), keyEquivalent: "")
            hide.target = self
            hide.representedObject = section
            m.addItem(hide)
            let settings = NSMenuItem(title: "Sidebar Settings\u{2026}", action: #selector(AppDelegate.openSidebarSettings(_:)), keyEquivalent: "")
            settings.target = NSApp.delegate
            m.addItem(settings)
            return m
        }
        if case .server(let s, let open, let root) = items[row] {
            return serverMenu(s, open: open, root: root)
        }
        if case .action = items[row] { return nil }
        guard case .place(let title, let path, let section) = items[row] else { return nil }
        let m = NSMenu()
        if section == "net", let v = VolumeRegistry.shared.volumes.first(where: { $0.path == path }), ServerList.entry(forMounted: v) != nil {
            let save = NSMenuItem(title: "Save as Server\u{2026}", action: #selector(saveAsServer(_:)), keyEquivalent: "")
            save.target = self
            save.representedObject = path
            m.addItem(save)
        }
        if (section == "dev" || section == "net") && Volumes.isEjectable(path) {
            let ej = NSMenuItem(title: "Eject \u{201C}\(title)\u{201D}", action: #selector(ejectFromMenu(_:)), keyEquivalent: "")
            ej.target = self
            ej.representedObject = path
            m.addItem(ej)
            m.addItem(NSMenuItem.separator())
        }
        let open = NSMenuItem(title: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = path
        m.addItem(open)
        if section == "fav" {
            let rn = NSMenuItem(title: "Name in Sidebar\u{2026}", action: #selector(nameFavorite(_:)), keyEquivalent: "")
            rn.target = self
            rn.representedObject = path
            m.addItem(rn)
            let rm = NSMenuItem(title: "Remove from Sidebar", action: #selector(removeFavorite(_:)), keyEquivalent: "")
            rm.target = self
            rm.representedObject = path
            m.addItem(rm)
            let favs = Prefs.favorites
            if let i = favs.index(of: path) {
                if i > 0 {
                    let upItem = NSMenuItem(title: "Move Up", action: #selector(moveFavoriteUp(_:)), keyEquivalent: "")
                    upItem.target = self
                    upItem.representedObject = path
                    m.addItem(upItem)
                }
                if i < favs.count - 1 {
                    let downItem = NSMenuItem(title: "Move Down", action: #selector(moveFavoriteDown(_:)), keyEquivalent: "")
                    downItem.target = self
                    downItem.representedObject = path
                    m.addItem(downItem)
                }
            }
        } else {
            let add = NSMenuItem(title: "Add to Favorites", action: #selector(addFavorite(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = path
            m.addItem(add)
        }
        if section == "recent" || section == "freq" {
            let clr = NSMenuItem(title: "Clear Recent and Frequent", action: #selector(clearRecents(_:)), keyEquivalent: "")
            clr.target = self
            m.addItem(clr)
        }
        return m
    }

    @objc func ejectFromMenu(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { delegate?.sidebarEject(p) }
    }

    func eject(_ path: String) {
        delegate?.sidebarEject(path)
    }

    @objc func openInNewTab(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { delegate?.sidebarOpenInNewTab(p) }
    }

    @objc func removeFavorite(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        var names = Prefs.favoriteNames
        if names[p] != nil { names[p] = nil; Prefs.favoriteNames = names }
        Prefs.favorites = Prefs.favorites.filter { $0 != p }
    }

    /// 0.17.2: give a favourite its own name - only how it is shown in the sidebar; the folder itself
    /// is not renamed. Empty = its own name again.
    @objc func nameFavorite(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        let real = FTPFavorite.isFavorite(p) ? FTPFavorite.title(p) : displayName(p)
        let a = ThemedAlert()
        a.messageText = "Name in the sidebar"
        a.informativeText = "Shown only in Favorites; the folder itself keeps its name (\(real)). Leave empty for its own name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = Prefs.favoriteNames[p] ?? real
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = Prefs.favoriteNames
        names[p] = (n.isEmpty || n == real) ? nil : n
        Prefs.favoriteNames = names
    }

    @objc func hideSection(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        var h = Prefs.sidebarHidden
        h.insert(s)
        Prefs.sidebarHidden = h
    }

    private func moveFavorite(_ path: String, by delta: Int) {
        var favs = Prefs.favorites
        guard let i = favs.index(of: path) else { return }
        let j = i + delta
        guard j >= 0 && j < favs.count else { return }
        favs.swapAt(i, j)
        Prefs.favorites = favs
    }

    @objc func moveFavoriteUp(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { moveFavorite(p, by: -1) }
    }

    @objc func moveFavoriteDown(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String { moveFavorite(p, by: 1) }
    }

    @objc func addFavorite(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        if !Prefs.favorites.contains(p) { Prefs.favorites = Prefs.favorites + [p] }
    }

    @objc func clearRecents(_ sender: NSMenuItem) {
        Prefs.recents = []
        Prefs.visitCounts = [:]
        NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
    }
}

/// Sidebar rows use the sidebar color and the theme selection color.
final class SidebarRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        // 0.16 Glass: the sidebar behind shows through (its tint is drawn under the table).
        if Finish.glass > 0 { return }
        ThemeManager.shared.sidebar.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let tm = ThemeManager.shared
        Finish.drawSelection(bounds.insetBy(dx: 4, dy: 1), base: tm.selection, rounded: true)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return ThemeManager.shared.theme.dark ? .dark : .light
    }
}

/// Table subclass that asks the controller for a per-row context menu.
final class SidebarTableView: NSTableView {
    weak var sidebar: SidebarController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return sidebar?.contextMenu(forRow: row(at: p))
    }
}

/// The small eject button at the end of a volume's row.
final class EjectButton: NSButton {
    weak var sidebar: SidebarController?
    var path = ""

    convenience init(sidebar: SidebarController) {
        self.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        self.sidebar = sidebar
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked(_:))
        toolTip = "Eject"
    }

    func applyTheme() {
        attributedTitle = attributed("\u{23CF}", font: NSFont.systemFont(ofSize: 12), color: ThemeManager.shared.secondaryText)
    }

    @objc func clicked(_ sender: Any?) {
        sidebar?.eject(path)
    }
}
