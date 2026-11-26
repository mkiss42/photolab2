// FileListController.swift
// Finder-style list view with disclosure triangles: Name / Date Modified / Size / Kind.
// - Expanding a folder asks the window to list it in the background; if that takes longer than
//   0.15 s a "Loading..." row with a small spinner appears under the folder.
// - Re-listing keeps expanded subfolders open and the selection (by path): folder nodes are
//   reused by path, so NSOutlineView keeps their state.
// - No disk access on the main thread: icons and kinds come from the file extension only.
// - Drag and drop: rows drag out as file URLs; files dropped on a folder row go into it, dropped
//   anywhere else into the folder the row is in (or the window's folder). Like Finder: move on
//   the same volume, copy to another; Option copies, Command moves.

import AppKit

final class FileNode: NSObject {
    var entry: FileEntry
    /// nil = never listed; otherwise the listed children (unfiltered, unsorted).
    var allChildren: [FileEntry]?
    /// Sorted + filtered children shown in the outline (may hold the placeholder).
    var shown: [FileNode] = []
    var loading = false
    var showPlaceholder = false
    var error: String?
    let isPlaceholder: Bool
    /// Files of the set this row stands for (rank order), when sets are on; else empty.
    var members: [FileEntry] = []
    var isSet: Bool { return members.count > 1 }
    /// What the Name column shows: a set by its name without extension (the Ext column has them).
    var displayName: String { return isSet ? FileOperations.split(entry.name).stem : entry.name }

    init(entry: FileEntry, placeholder: Bool = false) {
        self.entry = entry
        self.isPlaceholder = placeholder
    }

    var isExpandableFolder: Bool { return !isPlaceholder && entry.isDirectory && !entry.isPackage }
}

final class FileOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private var lastTypeSelect = Date.distantPast

    /// Return or M: rename (Photo Mechanic and Finder). Cmd-E / Cmd-Down: open.
    /// Backspace / forward Delete / Cmd-Backspace: move to Trash.
    /// "m" right after other typing is type-select, not rename.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if (event.keyCode == 36 || event.keyCode == 76) && mods.isEmpty { onRename?(); return }          // Return, Enter
        if (event.keyCode == 51 || event.keyCode == 117) && (mods.isEmpty || mods == [.command]) {      // Backspace, Delete
            onTrash?(); return
        }
        if mods == [.command] && chars == "e" { onOpen?(); return }
        if mods.isEmpty && chars == "m" && Date().timeIntervalSince(lastTypeSelect) > 1.0 { onRename?(); return }
        if mods.isEmpty || mods == [.shift] { lastTypeSelect = Date() }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenu?() ?? super.menu(for: event)
    }
}

enum FileIcons {
    private static var byExt: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]

    static func icon(for e: FileEntry) -> NSImage? {
        if e.isDirectory && !e.isPackage { return NSImage(named: NSImage.folderName) }
        let key = e.isPackage ? e.ext : (e.ext.isEmpty ? "public.data" : e.ext)
        if let i = byExt[key] { return i }
        let t0 = Date()
        let i = NSWorkspace.shared.icon(forFileType: key)
        i.size = NSSize(width: 16, height: 16)
        byExt[key] = i
        let ms = Date().timeIntervalSince(t0) * 1000
        if ms > 50 {
            Stats.noteSlowIcon(ms)
            Log.info(String(format: "slow icon: .%@ took %.0f ms", key, ms))
        }
        return i
    }

    static func kind(for e: FileEntry) -> String {
        if e.isDirectory && !e.isPackage { return "Folder" }
        if e.kind == .symlink { return "Alias" }
        let ext = e.ext
        if ext.isEmpty { return "Document" }
        if let k = kinds[ext] { return k }
        var text = ext.uppercased() + " file"
        if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, nil)?.takeRetainedValue(),
            let d = UTTypeCopyDescription(uti)?.takeRetainedValue() as String?, !d.isEmpty {
            text = d.prefix(1).uppercased() + d.dropFirst()
        }
        kinds[ext] = text
        return text
    }
}

final class FileListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    /// What the window lays out: the scroll view plus an overlay (message + spinner) on top of it.
    /// The overlay must be a sibling above the scroll view: views added inside a scroll view are
    /// drawn over by the list (0.1.3-0.1.5 showed neither message nor spinner).
    let view = OverlayContainer()
    let scroll = NSScrollView()
    let table = FileOutlineView()
    private let message = PassThroughLabel(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var roots: [FileNode] = []
    private var rootEntries: [FileEntry] = []
    /// Folder path -> node, for every folder node currently in the tree.
    private var nodesByPath: [String: FileNode] = [:]
    /// > 0 while the app itself reloads or re-expands rows. AppKit posts "will expand" for those
    /// too; answering them with a new listing caused an endless reload loop (0.1.4).
    private var quiet = 0

    private func quietly(_ work: () -> Void) {
        quiet += 1
        work()
        quiet -= 1
    }

    var sortKey: EntrySort.Key = .name
    var ascending = true
    var foldersFirst = true
    var showHidden = false
    /// View > Show Folders Only.
    var foldersOnly = false

    /// Double-click, Cmd-E, Cmd-Down.
    var onOpen: (([FileEntry]) -> Void)?
    /// Cmd-double-click on a folder: it opens in a new window.
    var onOpenInNewWindow: ((FileEntry) -> Void)?
    /// Return / M, Backspace: the window decides what to rename or trash.
    var onRenameRequest: (() -> Void)?
    var onTrashRequest: (() -> Void)?
    /// A rename typed in place: (item, new name).
    var onRenameCommit: ((FileEntry, String) -> Void)?
    /// Name to start editing as soon as it shows up (new folder).
    var pendingEdit: String?
    var onSelectionChange: (() -> Void)?
    /// The window lists `path` in the background and then calls setChildren(...).
    var onNeedChildren: ((String) -> Void)?
    /// The set of expanded folders changed (the window watches them).
    var onExpandedChange: ((Set<String>) -> Void)?
    /// Files dropped: (paths, destination folder, copy or move).
    var onDrop: (([String], String, TransferKind) -> Void)?
    /// The folder the window shows (drops between top-level rows go here).
    var rootPath = "/"

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    override init() {
        super.init()
        let columns: [(String, String, CGFloat, EntrySort.Key)] = [
            ("name", "Name", 300, .name), ("ext", "Ext", 90, .ext), ("modified", "Date Modified", 165, .modified),
            ("size", "Size", 75, .size), ("kind", "Kind", 130, .kind)]
        for (id, title, width, key) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            table.addTableColumn(c)
            if id == "name" { table.outlineTableColumn = c }
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        // The Name column takes all free width; the others keep their size. Widths are not saved:
        // a user's resizing lasts as long as the window, new windows start from these defaults.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.indentationPerLevel = 14
        table.autoresizesOutlineColumn = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.onOpen = { [weak self] in self?.openSelection() }
        table.onRename = { [weak self] in self?.onRenameRequest?() }
        table.onTrash = { [weak self] in self?.onTrashRequest?() }
        table.contextMenu = { [weak self] in self?.contextMenu() }
        table.sortDescriptors = [NSSortDescriptor(key: EntrySort.Key.name.rawValue, ascending: true)]
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        setUpColumnMenu()

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        message.alignment = .center
        message.textColor = NSColor.secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        view.addSubview(message)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -10),
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
    }

    // MARK: Nodes

    /// Nodes for `entries` (hidden ones filtered, sets folded into one row when sets are on,
    /// sorted), reusing existing folder nodes with the same path (keeps their expansion and children).
    private func nodes(for entries: [FileEntry]) -> [FileNode] {
        var v = showHidden ? entries : entries.filter { !$0.isHidden }
        if foldersOnly { v = v.filter { $0.isDirectory && !$0.isPackage } }
        let rows = FileOperations.useSets ? FileSets.rows(v) : v.map { SetRow(entry: $0, members: [$0]) }
        var members: [String: [FileEntry]] = [:]
        for r in rows where r.members.count > 1 { members[r.entry.path] = r.members }
        let sorted = EntrySort.sort(rows.map { $0.entry }, by: sortKey, ascending: ascending, foldersFirst: foldersFirst)
        return sorted.map { e -> FileNode in
            if e.isDirectory, let prev = nodesByPath[e.path] {
                prev.entry = e
                return prev
            }
            let n = FileNode(entry: e)
            n.members = members[e.path] ?? []
            return n
        }
    }

    private func refreshShown(_ n: FileNode) {
        let ph = n.showPlaceholder ? [placeholder(for: n)] : []
        guard let all = n.allChildren else { n.shown = ph; return }
        n.shown = nodes(for: all) + ph
        for c in n.shown where c.isExpandableFolder { refreshShown(c) }
    }

    private func rebuildIndex() {
        var index: [String: FileNode] = [:]
        func walk(_ list: [FileNode]) {
            for n in list where n.isExpandableFolder {
                index[n.entry.path] = n
                walk(n.shown)
            }
        }
        walk(roots)
        nodesByPath = index
    }

    private func placeholder(for parent: FileNode) -> FileNode {
        let e = FileEntry.make(name: "Loading...", dir: parent.entry.path, mode: 0o100000, size: 0,
                               modified: 0, created: 0, added: 0, flags: 0, device: 0, inode: 0)
        return FileNode(entry: e, placeholder: true)
    }

    /// Expanded folders, parents first.
    var expandedFolderPaths: [String] {
        return nodesByPath.filter { table.isItemExpanded($0.value) }.map { $0.key }.sorted { $0.count < $1.count }
    }

    private func reexpand(_ paths: [String]) {
        quietly {
            for p in paths {
                if let n = nodesByPath[p], !table.isItemExpanded(n) { table.expandItem(n) }
            }
        }
    }

    // MARK: Content API (main thread)

    /// The folder on screen. Keeps expanded subfolders and the selection, unless `select`
    /// (names in this folder) is given.
    func setEntries(_ entries: [FileEntry], select: [String]? = nil) {
        if editing != nil { deferred.append { [weak self] in self?.setEntries(entries, select: select) }; return }
        let wasExpanded = expandedFolderPaths
        let keep: Set<String>
        if let names = select {
            keep = Set(entries.filter { names.contains($0.name) }.map { $0.path })
        } else {
            keep = Set(selectedEntries().map { $0.path })
        }
        rootEntries = entries
        roots = nodes(for: entries)
        for n in roots where n.isExpandableFolder { refreshShown(n) }
        rebuildIndex()
        quietly { table.reloadData() }
        reexpand(wasExpanded)
        var rows = IndexSet()
        for r in 0..<table.numberOfRows {
            if let n = table.item(atRow: r) as? FileNode, !n.isPlaceholder, keep.contains(n.entry.path) { rows.insert(r) }
        }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
        else if select != nil { table.scrollRowToVisible(0) }
        onExpandedChange?(Set(expandedFolderPaths))
        if let p = pendingEdit, rows.count == 1, let n = table.item(atRow: rows.first!) as? FileNode, n.entry.path == p {
            pendingEdit = nil
            DispatchQueue.main.async { [weak self] in self?.beginRename() }
        }
    }

    // MARK: Rename in place

    private var editing: (field: NSTextField, entry: FileEntry)?
    /// Renaming a set row: only the name is edited; the extension is added back on commit.
    private var editSetExt: String?
    private var editShown = ""
    private var editCancelled = false
    private var deferred: [() -> Void] = []

    /// Start editing the name of the single selected item; the name without its extension is
    /// selected, like Finder.
    @discardableResult
    func beginRename() -> Bool {
        let rows = table.selectedRowIndexes
        guard rows.count == 1, let r = rows.first, let n = table.item(atRow: r) as? FileNode, !n.isPlaceholder,
            let cell = table.view(atColumn: 0, row: r, makeIfNecessary: true) as? FileCell,
            let tf = cell.textField else { return false }
        table.scrollRowToVisible(r)
        editing = (tf, n.entry)
        editCancelled = false
        editSetExt = n.isSet ? FileOperations.split(n.entry.name).ext : nil
        editShown = n.displayName
        tf.stringValue = n.isSet ? n.displayName : n.entry.name
        tf.isEditable = true
        tf.isSelectable = true
        tf.drawsBackground = true
        tf.backgroundColor = NSColor.textBackgroundColor
        tf.textColor = NSColor.textColor
        tf.delegate = self
        table.window?.makeFirstResponder(tf)
        let stem = n.entry.isDirectory || n.isSet ? tf.stringValue : FileOperations.split(n.entry.name).stem
        tf.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        return true
    }

    private func endRename() {
        guard let ed = editing else { return }
        let tf = ed.field
        tf.isEditable = false
        tf.isSelectable = false
        tf.drawsBackground = false
        editing = nil
        table.window?.makeFirstResponder(table)
        let work = deferred
        deferred.removeAll()
        for w in work { w() }
    }

    private func contextMenu() -> NSMenu? {
        let m = NSMenu()
        let sel = selectedEntries()
        func add(_ title: String, _ action: String) { m.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: "")) }
        if !sel.isEmpty {
            add("Open", "openSelected:")
            let ow = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            ow.submenu = FinderActions.openWithMenu(for: sel[0])
            m.addItem(ow)
            if sel.count == 1 && sel[0].isDirectory && !sel[0].isPackage { add("Open in New Window", "openInNewWindow:") }
            add("Show in Finder", "revealInFinder:")
            add("Get Info", "getInfo:")
            if !FinderActions.ejectable(sel.map { $0.path }).isEmpty { add("Eject", "ejectVolume:") }
            m.addItem(NSMenuItem.separator())
            if sel.count == 1 { add("Rename", "renameSelected:") }
            m.addItem(NSMenuItem.separator())
            add("Copy", "copy:")
        }
        if NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            add("Paste", "paste:")
            add("Move Items Here", "pasteMoving:")
        }
        if !sel.isEmpty {
            add("Duplicate", "duplicate:")
            m.addItem(NSMenuItem.separator())
            add("Copy Path", "copyPaths:")
            m.addItem(NSMenuItem.separator())
        }
        add("New Folder", "newFolder:")
        if !sel.isEmpty {
            m.addItem(NSMenuItem.separator())
            add("Move to Trash", "moveToTrash:")
        }
        return m
    }

    /// Children of an expanded folder arrived (error text when it could not be read).
    func setChildren(path: String, entries: [FileEntry], error: String?) {
        if editing != nil { deferred.append { [weak self] in self?.setChildren(path: path, entries: entries, error: error) }; return }
        guard let n = nodesByPath[path] else { return }
        let wasExpanded = expandedFolderPaths
        n.loading = false
        n.showPlaceholder = false
        n.allChildren = entries
        n.error = error
        refreshShown(n)
        rebuildIndex()
        quietly { table.reloadItem(n, reloadChildren: true) }
        reexpand(wasExpanded)
        onExpandedChange?(Set(expandedFolderPaths))
    }

    /// Re-list an expanded folder (watcher event, refresh).
    func relist(path: String) {
        guard let n = nodesByPath[path], table.isItemExpanded(n) else { return }
        onNeedChildren?(path)
    }

    func reapplyFilterAndSort() {
        setEntries(rootEntries)
    }

    func showMessage(_ text: String?, spinning: Bool = false) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func selectedEntries() -> [FileEntry] {
        return table.selectedRowIndexes.compactMap { r -> FileEntry? in
            guard let n = table.item(atRow: r) as? FileNode, !n.isPlaceholder else { return nil }
            return n.entry
        }
    }

    var selectionCount: Int { return selectedEntries().count }

    /// Rows on screen (expanded folders included) and how many of them are sets.
    var shownCounts: (rows: Int, sets: Int) {
        var rows = 0, sets = 0
        for r in 0..<table.numberOfRows {
            guard let n = table.item(atRow: r) as? FileNode, !n.isPlaceholder else { continue }
            rows += 1
            if n.isSet { sets += 1 }
        }
        return (rows, sets)
    }

    // MARK: Columns (right-click the header; hidden columns are remembered)

    private static var hiddenColumns: Set<String> {
        get { return Set(UserDefaults.standard.stringArray(forKey: "hiddenColumns") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "hiddenColumns") }
    }

    private func setUpColumnMenu() {
        let m = NSMenu()
        let hidden = FileListController.hiddenColumns
        for c in table.tableColumns where c.identifier.rawValue != "name" {
            c.isHidden = hidden.contains(c.identifier.rawValue)
            let item = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.identifier.rawValue
            item.state = c.isHidden ? .off : .on
            m.addItem(item)
        }
        table.headerView?.menu = m
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let c = table.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        c.isHidden = !c.isHidden
        sender.state = c.isHidden ? .off : .on
        var h = FileListController.hiddenColumns
        if c.isHidden { h.insert(id) } else { h.remove(id) }
        FileListController.hiddenColumns = h
        table.sizeLastColumnToFit()
    }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        if NSEvent.modifierFlags.contains(.command), let n = table.item(atRow: table.clickedRow) as? FileNode,
            !n.isPlaceholder, n.isExpandableFolder {
            onOpenInNewWindow?(n.entry)
            return
        }
        openSelection()
    }

    func openSelection() {
        let sel = selectedEntries()
        if !sel.isEmpty { onOpen?(sel) }
    }

    /// Paths of `entries` plus the other files of their sets, from the listings in memory (no
    /// disk access: safe on the main thread). Sets off: just the entries.
    func withSetMembers(_ entries: [FileEntry]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for e in entries {
            var members = [e.path]
            if FileOperations.useSets && !e.isDirectory && FileOperations.groupable.contains(e.ext) {
                let dir = Paths.parent(e.path)
                let siblings = dir == rootPath ? rootEntries : (nodesByPath[dir]?.allChildren ?? [])
                let stem = FileOperations.split(e.name).stem
                members += siblings.filter { s in
                    !s.isDirectory && FileOperations.groupable.contains(s.ext) && FileOperations.split(s.name).stem == stem
                }.map { $0.path }
            }
            for m in members where !seen.contains(m) { seen.insert(m); out.append(m) }
        }
        return out
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard editing == nil, let n = item as? FileNode, !n.isPlaceholder else { return nil }
        return NSURL(fileURLWithPath: n.entry.path)
    }

    /// A set row drags as one row; the other files of the set are added to the drag, so Finder
    /// (and any other app) gets the whole set.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        Activity.set("drag: out")
        let extra = draggedItems.compactMap { $0 as? FileNode }.flatMap { n in n.members.filter { $0.path != n.entry.path } }
        if extra.isEmpty { return }
        let ok = session.draggingPasteboard.writeObjects(extra.map { NSURL(fileURLWithPath: $0.path) })
        Log.info("drag: \(extra.count) set member(s) added to the drag: \(ok ? "ok" : "refused")")
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Activity.set("idle")
    }

    private func droppedPaths(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { $0.path }
    }

    /// The folder a drop at (item, index) goes into: a folder row itself, otherwise the folder the
    /// row is in. Re-targets the outline's highlight to match.
    private func dropFolder(_ ov: NSOutlineView, _ item: Any?, _ index: Int) -> String {
        if let n = item as? FileNode, !n.isPlaceholder {
            if n.isExpandableFolder {
                if index != NSOutlineViewDropOnItemIndex { ov.setDropItem(n, dropChildIndex: NSOutlineViewDropOnItemIndex) }
                return n.entry.path
            }
            let parent = ov.parent(forItem: n)
            ov.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return (parent as? FileNode)?.entry.path ?? rootPath
        }
        if item != nil { ov.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        if item == nil && index != NSOutlineViewDropOnItemIndex { ov.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        return rootPath
    }

    private func dropKind(_ info: NSDraggingInfo, _ paths: [String], _ dest: String) -> TransferKind? {
        let mods = NSEvent.modifierFlags
        let same = paths.allSatisfy { Transfers.sameVolume($0, dest) }
        var kind = Transfers.dropOperation(sameVolume: same, option: mods.contains(.option), command: mods.contains(.command))
        let allowed = info.draggingSourceOperationMask
        if kind == .move && !allowed.contains(.move) && !allowed.contains(.generic) { kind = .copy }
        if kind == .copy && !allowed.contains(.copy) { return allowed.contains(.move) ? .move : nil }
        return kind
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        return Activity.during("drag: hover") { validateDropNow(outlineView, info, item, index) }
    }

    private func validateDropNow(_ outlineView: NSOutlineView, _ info: NSDraggingInfo, _ item: Any?, _ index: Int) -> NSDragOperation {
        let paths = droppedPaths(info)
        guard !paths.isEmpty, editing == nil else { return [] }
        let dest = dropFolder(outlineView, item, index)
        if paths.contains(dest) { return [] }                                   // onto itself
        guard let kind = dropKind(info, paths, dest) else { return [] }
        if kind == .move && paths.allSatisfy({ Paths.parent($0) == dest }) { return [] }   // already there
        return kind == .copy ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        return Activity.during("drag: drop") { acceptDropNow(info, item) }
    }

    private func acceptDropNow(_ info: NSDraggingInfo, _ item: Any?) -> Bool {
        let paths = droppedPaths(info)
        let dest = (item as? FileNode)?.entry.path ?? rootPath
        guard !paths.isEmpty, let kind = dropKind(info, paths, dest) else { return false }
        Log.info("drop: \(paths.count) item(s), \(kind.rawValue) -> \(dest)")
        onDrop?(paths, dest, kind)
        return true
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? FileNode else { return roots.count }
        return n.shown.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? FileNode else { return roots[index] }
        return n.shown[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? FileNode)?.isExpandableFolder ?? false
    }

    // MARK: Expansion

    func outlineViewItemWillExpand(_ notification: Notification) {
        if quiet > 0 { return }
        guard let n = notification.userInfo?["NSObject"] as? FileNode, n.isExpandableFolder, !n.loading else { return }
        n.loading = true
        let path = n.entry.path
        // "Loading..." only if the folder is slow: no flicker for quick folders.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let me = self, let node = me.nodesByPath[path], node.loading, me.table.isItemExpanded(node) else { return }
            node.showPlaceholder = true
            me.refreshShown(node)
            me.quietly { me.table.reloadItem(node, reloadChildren: true) }
        }
        onNeedChildren?(path)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        onExpandedChange?(Set(expandedFolderPaths))
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        onExpandedChange?(Set(expandedFolderPaths))
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let col = tableColumn, let n = item as? FileNode else { return nil }
        let id = col.identifier
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FileCell) ?? FileCell(id: id)
        let e = n.entry
        if n.isPlaceholder {
            cell.textField?.stringValue = id.rawValue == "name" ? "Loading..." : ""
            cell.textField?.textColor = NSColor.secondaryLabelColor
            cell.imageView?.image = nil
            cell.spinning = id.rawValue == "name"
            return cell
        }
        cell.spinning = false
        switch id.rawValue {
        case "name":
            if let err = n.error { cell.textField?.stringValue = "\(e.name)  (\(err))" }
            else { cell.textField?.stringValue = n.displayName }
            cell.imageView?.image = FileIcons.icon(for: e)
            cell.textField?.textColor = e.isHidden ? NSColor.secondaryLabelColor : NSColor.labelColor
            cell.toolTip = n.isSet ? n.members.map { $0.name }.joined(separator: "\n") : e.path
        case "ext":
            cell.textField?.stringValue = e.isDirectory && !e.isPackage ? "" : (n.isSet ? FileSets.extLabel(n.members) : e.ext.uppercased())
        case "modified":
            cell.textField?.stringValue = e.modified > 0 ? dateFormatter.string(from: Date(timeIntervalSince1970: e.modified)) : "--"
        case "size":
            cell.textField?.stringValue = e.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)
        default:
            cell.textField?.stringValue = FileIcons.kind(for: e)
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return !((item as? FileNode)?.isPlaceholder ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let k = d.key, let key = EntrySort.Key(rawValue: k) else { return }
        sortKey = key
        ascending = d.ascending
        reapplyFilterAndSort()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    // MARK: Text field (rename)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let ed = editing, ed.field === control {
            let tf = ed.field
            editCancelled = true
            tf.stringValue = editShown
            tf.abortEditing()
            endRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let ed = editing, (obj.object as? NSTextField) === ed.field else { return }
        let tf = ed.field
        let entry = ed.entry
        var newName = tf.stringValue
        if let ext = editSetExt, !newName.lowercased().hasSuffix("." + ext.lowercased()) { newName += "." + ext }
        tf.stringValue = editShown           // the reload after the rename shows the new name
        endRename()
        if !editCancelled && newName != entry.name { onRenameCommit?(entry, newName) }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier.rawValue == "name", let n = item as? FileNode, !n.isPlaceholder else { return nil }
        return n.displayName
    }
}

/// Holds the scroll view and, above it, the overlay message + spinner.
final class OverlayContainer: NSView {}

/// A label that never takes clicks (overlay over the list).
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }
}

/// Table cell with icon, text and an optional small spinner (for the "Loading..." row).
final class FileCell: NSTableCellView {
    private let spinner = NSProgressIndicator()

    var spinning: Bool = false {
        didSet {
            if spinning == oldValue { return }
            if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingMiddle
        tf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tf)
        textField = tf
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            imageView = iv
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                spinner.centerXAnchor.constraint(equalTo: iv.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
            if id.rawValue == "size" { tf.alignment = .right }
            tf.textColor = NSColor.secondaryLabelColor
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
