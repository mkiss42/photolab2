// FileListController.swift
// Finder-style list view with disclosure triangles: Name / Date Modified / Size / Kind.
// - Expanding a folder asks the window to list it in the background; if that takes longer than
//   0.15 s a "Loading..." row with a small spinner appears under the folder.
// - Re-listing keeps expanded subfolders open and the selection (by path): folder nodes are
//   reused by path, so NSOutlineView keeps their state.
// - No disk access on the main thread: icons and kinds come from the file extension only.

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

    init(entry: FileEntry, placeholder: Bool = false) {
        self.entry = entry
        self.isPlaceholder = placeholder
    }

    var isExpandableFolder: Bool { return !isPlaceholder && entry.isDirectory && !entry.isPackage }
}

final class FileOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76]    // Return, keypad Enter
        if returnKeys.contains(event.keyCode) && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onOpen?()
            return
        }
        super.keyDown(with: event)
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

final class FileListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
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

    /// Double-click, Return.
    var onOpen: (([FileEntry]) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// The window lists `path` in the background and then calls setChildren(...).
    var onNeedChildren: ((String) -> Void)?
    /// The set of expanded folders changed (the window watches them).
    var onExpandedChange: ((Set<String>) -> Void)?

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
            ("name", "Name", 300, .name), ("modified", "Date Modified", 165, .modified),
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
        table.sortDescriptors = [NSSortDescriptor(key: EntrySort.Key.name.rawValue, ascending: true)]

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

    private func visible(_ entries: [FileEntry]) -> [FileEntry] {
        let v = showHidden ? entries : entries.filter { !$0.isHidden }
        return EntrySort.sort(v, by: sortKey, ascending: ascending, foldersFirst: foldersFirst)
    }

    /// Nodes for `entries`, reusing existing folder nodes with the same path (keeps their
    /// expansion and children).
    private func nodes(for entries: [FileEntry]) -> [FileNode] {
        return visible(entries).map { e -> FileNode in
            if e.isDirectory, let prev = nodesByPath[e.path] {
                prev.entry = e
                return prev
            }
            return FileNode(entry: e)
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
    }

    /// Children of an expanded folder arrived (error text when it could not be read).
    func setChildren(path: String, entries: [FileEntry], error: String?) {
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

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        openSelection()
    }

    func openSelection() {
        let sel = selectedEntries()
        if !sel.isEmpty { onOpen?(sel) }
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
            else { cell.textField?.stringValue = e.name }
            cell.imageView?.image = FileIcons.icon(for: e)
            cell.textField?.textColor = e.isHidden ? NSColor.secondaryLabelColor : NSColor.labelColor
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

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier.rawValue == "name", let n = item as? FileNode, !n.isPlaceholder else { return nil }
        return n.entry.name
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
