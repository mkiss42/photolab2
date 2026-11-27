// FileListController.swift
// The file list: an outline (folders expand in place with disclosure triangles, like Finder's list view).
// Loads folders off the main thread, sorts, shows columns, watches for changes.
// Also shows search results (a flat list with an extra "Folder" column).

import AppKit

/// One row in the outline.
final class FileNode {
    var entry: FileEntry
    weak var parent: FileNode?
    /// nil = not loaded yet.
    var children: [FileNode]? = nil
    var loading = false
    var error: ReadProblem? = nil

    init(_ entry: FileEntry, parent: FileNode?) {
        self.entry = entry
        self.parent = parent
    }

    var path: String { return entry.path }
}

final class FileListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    struct ColumnDef {
        let id: String
        let title: String
        let width: CGFloat
        let minWidth: CGFloat
        let sortKey: SortColumn?
    }

    /// Name first and widest; the others are compact by default and sit on the right edge.
    static let columns: [ColumnDef] = [
        ColumnDef(id: "name", title: "Name", width: 400, minWidth: 140, sortKey: .name),
        ColumnDef(id: "folder", title: "Folder", width: 180, minWidth: 60, sortKey: nil),
        ColumnDef(id: "match", title: "Match", width: 64, minWidth: 44, sortKey: .match),
        ColumnDef(id: "modified", title: "Modified", width: 74, minWidth: 54, sortKey: .modified),
        ColumnDef(id: "created", title: "Created", width: 74, minWidth: 54, sortKey: .created),
        ColumnDef(id: "added", title: "Added", width: 74, minWidth: 54, sortKey: .added),
        ColumnDef(id: "size", title: "Size", width: 64, minWidth: 44, sortKey: .size),
        ColumnDef(id: "kind", title: "Kind", width: 70, minWidth: 44, sortKey: .kind),
    ]

    let table = FileTableView()
    let scroll = NSScrollView()
    private(set) var path = ""
    private(set) var roots: [FileNode] = [] {
        didSet { scheduleRootsChanged() }
    }
    /// Told (once per run-loop turn) whenever the top-level items change: the thumbnail grid follows it.
    var onRootsChanged: (() -> Void)?
    private var rootsChangePending = false

    private func scheduleRootsChanged() {
        if rootsChangePending { return }
        rootsChangePending = true
        DispatchQueue.main.async { [weak self] in
            self?.rootsChangePending = false
            self?.onRootsChanged?()
        }
    }

    /// Narrowest useful width: the name column showing about 10 characters (after the icon) plus every
    /// other visible column at its narrowest, the scroll bar and the column gaps.
    var minimumUsefulWidth: CGFloat {
        let charW = ThemeManager.shared.font.pointSize * 0.6
        var w: CGFloat = 26 + 10 * charW + 16
        for c in table.tableColumns where !c.isHidden && c.identifier.rawValue != "name" {
            w += c.minWidth + table.intercellSpacing.width
        }
        return ceil(w)
    }

    /// Top-level items in their current order (the folder's contents, or search results).
    var rootEntries: [FileEntry] { return roots.map { $0.entry } }
    private(set) var result = FolderReadResult()
    private(set) var loading = false
    private(set) var loadMillis = 0
    var spec: SortSpec = Prefs.sortSpec

    /// Search results mode: flat list, nothing expands, "Folder" column shown.
    private(set) var resultsMode = false
    /// "Similar to" searches show how close each match is.
    var showMatchColumn = false

    var onLoaded: (() -> Void)?
    /// 0.17: a remembered network listing is being checked in the background (spinner bottom right).
    var onBackgroundCheck: ((Bool) -> Void)?
    /// 0.17: true while a name is being edited in place - background reloads wait until it is done.
    var holdReloads: (() -> Bool)?
    var onSelectionChanged: (() -> Void)?
    /// 0.18.15: rows shown changed (a folder opened or closed in the list): the item count follows.
    var onRowsChanged: (() -> Void)?
    var onOpen: ((FileEntry) -> Void)?
    var onFolderGone: ((String) -> Void)?

    private var token = 0 {
        didSet { currentToken.value = token }
    }
    private let currentToken = AtomicInt()
    private var expandedPaths = Set<String>()
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    let quickLook = QuickLookSource()
    private var tagObserver: NSObjectProtocol?

    /// Colour tags arrived for some paths: redraw just those visible rows' names.
    private func tagsRead(_ paths: Set<String>) {
        let visible = table.rows(in: table.visibleRect)
        if visible.length <= 0 { return }
        var rows = IndexSet()
        for r in visible.location..<(visible.location + visible.length) {
            if let n = table.item(atRow: r) as? FileNode, paths.contains(n.path) { rows.insert(r) }
        }
        if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
    }
    /// Files dropped: (paths, destination folder, move). Set by the pane.
    var onDrop: (([String], String, Bool) -> Void)?

    /// Set before loading a folder to restore its earlier scroll position.
    var pendingScrollY: CGFloat?
    private var restoredScroll = false

    func scrollTo(y: CGFloat) {
        table.layoutSubtreeIfNeeded()
        // Header-aware: the top is one header-height above 0 (see FileTableView.scrollListTo).
        table.scrollListTo(y: y)
        restoredScroll = true
    }

    var scrollY: CGFloat { return scroll.contentView.bounds.origin.y }
    /// Folders whose watch events proved false; 3 within 10 s pauses watching that folder.
    private var falseAlarms: [String: [Date]] = [:]
    private var watchPaused: Set<String> = []
    private var reloadScheduled = Set<String>()
    private let cornerFill = FillView()

    /// Folder reads for expanded folders: a few at a time, so expanding a big tree can't flood the system.
    private let childQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Optional folder sizes: counted in the background, two folders at a time, after the list is shown.
    private let sizeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    private let sizeGeneration = AtomicInt()
    private var folderSizeCache: [String: Int64] = [:]
    private var sizeResortScheduled = false

    /// Folders being opened with Option (all subfolders too). Capped so a huge tree can't run away.
    private var recursiveRoots = Set<String>()
    private var recursiveCount = 0
    static let recursiveLimit = 3000
    /// NSOutlineView does not retain its items. Replaced nodes are kept alive until the view has moved on.
    private var retired: [[FileNode]] = []

    /// 0.17.1: the pane is closing. NSOutlineView does NOT keep its rows' items alive, so it must be
    /// emptied while its data source is still there, and the old rows kept alive a little longer - a
    /// pane closed while the view was still being drawn or a folder still loading (Cmd-W quickly, several
    /// times) otherwise pointed at rows that were already gone and Find crashed.
    func shutdown() {
        token += 1                       // every load, child read and size count still running is ignored
        childQueue.cancelAllOperations()
        sizeQueue.cancelAllOperations()
        sizeGeneration.value += 1
        stopWatching()
        if let o = tagObserver { NotificationCenter.default.removeObserver(o); tagObserver = nil }
        onRootsChanged = nil; onLoaded = nil; onSelectionChanged = nil; onRowsChanged = nil; onOpen = nil; onFolderGone = nil
        onDrop = nil; onBackgroundCheck = nil; holdReloads = nil
        let old = roots + retired.flatMap { $0 }
        FileListController.graveyard.append(old)
        roots = []
        expandedPaths.removeAll()
        loading = false
        table.reloadData()
        table.delegate = nil
        table.dataSource = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if !FileListController.graveyard.isEmpty { FileListController.graveyard.removeFirst() }
        }
    }
    private static var graveyard: [[FileNode]] = []

    private func retire(_ nodes: [FileNode]?) {
        guard let n = nodes, !n.isEmpty else { return }
        retired.append(n)
        DispatchQueue.main.async { [weak self] in
            guard let s = self, !s.retired.isEmpty else { return }
            s.retired.removeFirst()
        }
    }

    private let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    private let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    override init() {
        super.init()
        for def in FileListController.columns {
            let c = NSTableColumn(identifier: itemID(def.id))
            c.headerCell = ThemedHeaderCell(textCell: def.title)
            c.width = def.width
            c.minWidth = def.minWidth
            if let k = def.sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: k.rawValue, ascending: true) }
            c.resizingMask = def.id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(c)
        }
        table.outlineTableColumn = table.tableColumns.first
        let widths = Prefs.columnWidths
        for c in table.tableColumns where c.identifier.rawValue != "name" {
            if let w = widths[c.identifier.rawValue], w >= 40 { c.width = CGFloat(w) }
        }
        // The Name column absorbs all width changes, so the other columns stay on the right edge.
        // "First column only" is raw value 5; its Swift name differs between SDKs, the number does not.
        if let firstOnly = NSTableView.ColumnAutoresizingStyle(rawValue: 5) {
            table.columnAutoresizingStyle = firstOnly
        }
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.focusRingType = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.indentationPerLevel = 16
        table.autoresizesOutlineColumn = false
        table.selectionHighlightStyle = .regular
        table.rowSizeStyle = .custom
        table.dataSource = self
        table.delegate = self
        table.quickLook = quickLook
        tagObserver = NotificationCenter.default.addObserver(forName: .findTagsRead, object: nil, queue: .main) { [weak self] n in
            guard let s = self, let paths = n.userInfo?["paths"] as? [String] else { return }
            s.tagsRead(Set(paths))
        }
        quickLook.table = table
        quickLook.selection = { [weak self] in return self?.selectedPaths() ?? [] }
        table.onSpace = { [weak self] in self?.previewSelection() }
        table.onOptionSpace = { [weak self] in
            guard let s = self else { return }
            if !FastPreview.shared.isVisible { s.quickLook.close(); FastPreview.shared.toggle(for: s) }
            FastPreview.shared.toggleFill()
        }
        table.onEscape = {
            if FastPreview.shared.isVisible { FastPreview.shared.close(); return true }
            return false
        }
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        // 0.17.3: to other apps like Finder offers it - copy, link or "generic" (VLC, older apps accept only
        // that) - but never move (another app can't take files away from Find's folders by a drag).
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        // Inside Find: copy or move (onto folders, other panes, the sidebar).
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.registerForDraggedTypes(FileDrag.types)
        if spec.column == .name || FileListController.columns.contains(where: { $0.sortKey == spec.column }) {
            table.sortDescriptors = [NSSortDescriptor(key: spec.column.rawValue, ascending: spec.ascending)]
        }
        let headerMenu = NSMenu()
        for def in FileListController.columns where def.id != "name" && def.id != "folder" && def.id != "match" {
            let mi = NSMenuItem(title: def.title == "Modified" ? "Date Modified" : (def.title == "Created" ? "Date Created" : (def.title == "Added" ? "Date Added" : def.title)),
                                action: #selector(toggleColumn(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = def.id
            headerMenu.addItem(mi)
        }
        table.headerView?.menu = headerMenu
        table.cornerView = cornerFill
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller = ThemedScroller()
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        applyVisibleColumns()
        applyTheme()
    }

    deinit {
        stopWatching()
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        // 0.17.4: with Glass behind the lists the table and its scroll view draw no background.
        let glass = Finish.contentGlass > 0
        if glass { Finish.glassTables.add(table) } else { Finish.glassTables.remove(table) }
        table.backgroundColor = glass ? .clear : tm.background
        table.rowHeight = tm.rowHeight
        scroll.backgroundColor = tm.background
        scroll.drawsBackground = !glass
        scroll.scrollerKnobStyle = tm.theme.dark ? .light : .dark
        scroll.verticalScroller?.needsDisplay = true
        cornerFill.fillColor = tm.sidebar
        updateHeaderArrows()
        table.headerView?.needsDisplay = true
        table.reloadData()
    }

    /// Fit the columns to the current width (Name takes the rest).
    func fitColumns() {
        table.sizeToFit()
    }

    // MARK: Columns

    var visibleColumnIDs: Set<String> {
        var v = Set(Prefs.visibleColumns)
        if resultsMode { v.insert("folder") } else { v.remove("folder") }
        if resultsMode && showMatchColumn { v.insert("match") } else { v.remove("match") }
        return v
    }

    private func applyVisibleColumns() {
        let visible = visibleColumnIDs
        for c in table.tableColumns where c.identifier.rawValue != "name" {
            c.isHidden = !visible.contains(c.identifier.rawValue)
        }
        if let menu = table.headerView?.menu {
            for mi in menu.items {
                if let id = mi.representedObject as? String { mi.state = visible.contains(id) ? .on : .off }
            }
        }
        fitColumns()
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setColumn(id, visible: !Prefs.visibleColumns.contains(id))
    }

    func setColumn(_ id: String, visible: Bool) {
        var v = Prefs.visibleColumns.filter { $0 != id }
        if visible { v.append(id) }
        Prefs.visibleColumns = v
        applyVisibleColumns()
        if id == "added" && visible { reload(showHidden: Prefs.showHidden) }
    }

    private func updateHeaderArrows() {
        for c in table.tableColumns {
            guard let h = c.headerCell as? ThemedHeaderCell else { continue }
            let key = FileListController.columns.first { $0.id == c.identifier.rawValue }?.sortKey
            h.sortAscending = (key != nil && key == spec.column) ? spec.ascending : nil
        }
        table.headerView?.needsDisplay = true
    }

    /// Date Added costs one extra lookup per item, so it is only read when shown or sorted on.
    private var needsAddedDates: Bool {
        return Prefs.visibleColumns.contains("added") || spec.column == .added
    }

    // MARK: Sorting

    /// The sort to use right now (read on the main thread, then handed to background work).
    private var currentSort: SortSpec {
        return SortSpec(column: spec.column, ascending: spec.ascending, foldersFirst: Prefs.foldersFirst)
    }

    private func sortedNodes(_ entries: [FileEntry], parent: FileNode?, sort: SortSpec) -> [FileNode] {
        return Listing.sorted(entries, by: sort, kindOf: KindCache.shared.kind).map { FileNode($0, parent: parent) }
    }

    func setSort(_ column: SortColumn, ascending: Bool) {
        table.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: ascending)]
    }

    /// Re-sort everything loaded (all levels), keeping selection and expansion.
    func resort() {
        let keep = selectedPaths()
        spec.foldersFirst = Prefs.foldersFirst
        let s = spec
        func sortLevel(_ nodes: [FileNode]) -> [FileNode] {
            let entries = Listing.sorted(nodes.map { $0.entry }, by: s, kindOf: KindCache.shared.kind)
            var byPath: [String: FileNode] = [:]
            for n in nodes { byPath[n.path] = n }
            return entries.compactMap { byPath[$0.path] }
        }
        func walk(_ n: FileNode) {
            if let c = n.children {
                n.children = sortLevel(c)
                for x in n.children ?? [] { walk(x) }
            }
        }
        retire(roots)
        roots = sortLevel(roots)
        for r in roots { walk(r) }
        table.reloadData()
        restoreExpansion(roots)
        select(paths: keep, scroll: true)
        updateHeaderArrows()
        if spec.column == .added && !resultsMode { reload(showHidden: Prefs.showHidden) }
    }

    // MARK: Loading a folder

    /// Load a folder. `select` = names in that folder to select afterwards.
    func load(_ newPath: String, select: [String] = [], showHidden: Bool) {
        load(newPath, selectPaths: select.map { Paths.join(newPath, $0) }, showHidden: showHidden)
    }

    /// 0.17.6: items that should be selected but aren't in the list yet - e.g. the item just renamed
    /// inside an open subfolder (its folder is read again a moment later), or while a newer reload
    /// started before the one that selects it had finished. Selected as soon as they show up.
    private var wantSelected: [String] = []
    private var wantSelectedUntil = Date.distantPast
    /// The selection a load in progress will make (a reload started meanwhile keeps it).
    private var pendingSelect: [String] = []

    func load(_ newPath: String, selectPaths: [String], showHidden: Bool) {
        if newPath != path { wantSelected = []; pendingSelect = [] }
        if resultsMode {
            resultsMode = false
            applyVisibleColumns()
        }
        token += 1
        let myToken = token
        let samePath = newPath == path
        path = newPath
        loading = true
        if !samePath {
            retire(roots)
            roots = []
            expandedPaths.removeAll()
            recursiveRoots.removeAll()
            recursiveCount = 0
            folderSizeCache.removeAll()
            sizeGeneration.value += 1
            sizeQueue.cancelAllOperations()
            result = FolderReadResult()
            stopWatching()
            falseAlarms.removeAll()
            watchPaused.removeAll()
            table.reloadData()
            table.scrollToTop()   // a new folder starts at its first row, never with old scroll left over
        }
        let wantAdded = needsAddedDates
        let sort = currentSort
        let started = Date()
        var firstBatchShown = false
        var keepSelection = selectPaths.isEmpty && samePath ? selectedPaths() : selectPaths
        if selectPaths.isEmpty && samePath && !pendingSelect.isEmpty {
            // A reload (e.g. the folder watcher) started before the load that selects the renamed item
            // finished: keep that item's selection, not the old name's.
            keepSelection = pendingSelect
        }
        if !selectPaths.isEmpty { pendingSelect = selectPaths }
        // Network shares: going back into a folder read in the last couple of minutes reuses that
        // listing when the folder itself is unchanged (one request instead of reading every item).
        // Never for a reload of the same folder (Refresh, changes): those always read the server.
        // 0.17.1: also with the Date Added column on (it used to switch the snapshot off).
        let useCache = !samePath && ListingCache.lifetime > 0 && VolumeRegistry.shared.treatAsNetwork(newPath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let me = self else { return }
            let folderInfo: StatInfo? = nil
            if useCache, let cached = ListingCache.shared.peek(newPath, includeHidden: showHidden) {
                // Shown at once from memory (no request to the server); then read again in the background.
                let nodes = me.sortedNodes(cached.entries, parent: nil, sort: sort)
                Log.shared?.debug("Listing of \(newPath) shown from memory (\(nodes.count) items); checking the server in the background")
                DispatchQueue.main.async {
                    guard me.token == myToken else { return }
                    me.finishLoad(newPath, r: cached, nodes: nodes, ms: 0, samePath: samePath, keepSelection: keepSelection, selectPaths: selectPaths)
                    me.revalidate(newPath, cached: cached, token: myToken, includeHidden: showHidden, sort: sort, wantAdded: wantAdded)
                }
                return
            }
            let r = DirectoryReader.read(newPath, includeHidden: showHidden, batchSize: 1000, batch: { batch in
                if firstBatchShown || samePath { return }
                firstBatchShown = true
                let part = me.sortedNodes(batch, parent: nil, sort: sort)
                DispatchQueue.main.async {
                    guard me.token == myToken, me.loading else { return }
                    me.retire(me.roots)
                    me.roots = part
                    me.table.reloadData()
                    if me.pendingScrollY == nil { me.table.scrollToTop() }
                    me.onLoaded?()
                }
            }, isCancelled: { [weak self] in
                guard let s = self else { return true }
                return s.currentToken.value != myToken
            }, addedDate: wantAdded ? { p in DateAdded.get(p) } : nil)
            let nodes = me.sortedNodes(r.entries, parent: nil, sort: sort)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if VolumeRegistry.shared.treatAsNetwork(newPath) && ListingCache.lifetime > 0 {
                var e: Int32 = 0
                if let fi = folderInfo ?? Sys.statInfo(newPath, &e) {
                    ListingCache.shared.put(newPath, includeHidden: showHidden, folderInfo: fi, result: r)
                }
            }
            DispatchQueue.main.async {
                guard me.token == myToken else { return }
                me.finishLoad(newPath, r: r, nodes: nodes, ms: ms, samePath: samePath, keepSelection: keepSelection, selectPaths: selectPaths)
            }
        }
    }

    private func finishLoad(_ newPath: String, r: FolderReadResult, nodes: [FileNode], ms: Int, samePath: Bool,
                            keepSelection: [String], selectPaths: [String]) {
        let me = self
        let firstVisible = samePath ? me.table.rows(in: me.table.visibleRect).location : 0
        me.result = r
        me.retire(me.roots)
        me.applyCachedSizes(nodes)
        TagCache.shared.clear()
        me.roots = nodes
        me.loading = false
        me.loadMillis = ms
        me.table.reloadData()
        me.restoreExpansion(nodes)
        if let y = me.pendingScrollY {
            // Coming back to a folder: the same scroll position as when it was left.
            me.pendingScrollY = nil
            me.select(paths: keepSelection, scroll: false)
            me.scrollTo(y: y)
        } else {
            me.select(paths: keepSelection, scroll: !selectPaths.isEmpty)
        }
        me.pendingSelect = []
        me.rememberMissing(keepSelection)
        if me.restoredScroll {
            me.restoredScroll = false
        } else if samePath && selectPaths.isEmpty && firstVisible > 0 && firstVisible < me.table.numberOfRows {
            me.table.scrollRowToVisible(firstVisible)
        } else if !samePath && keepSelection.isEmpty && me.table.numberOfRows > 0 {
            me.table.scrollToTop()
        }
        me.watch(newPath)
        me.queueFolderSizes(nodes)
        me.onLoaded?()
        Log.shared?.info("Listed \(newPath): \(nodes.count) items in \(ms) ms" +
            (r.problems.isEmpty ? "" : ", \(r.problems.count) unreadable") +
            (r.folderError == nil ? "" : ", folder error \(r.folderError!.code) \(r.folderError!.reason)"))
    }

    /// After showing a remembered listing: read the folder again in the background and update the list
    /// in place (selection and scroll kept) only if something changed.
    private func revalidate(_ p: String, cached: FolderReadResult, token myToken: Int, includeHidden: Bool, sort: SortSpec, wantAdded: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onBackgroundCheck?(true) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { DispatchQueue.main.async { [weak self] in self?.onBackgroundCheck?(false) } }
            guard let me = self, me.currentToken.value == myToken else { return }
            let started = Date()
            let fresh = DirectoryReader.read(p, includeHidden: includeHidden, addedDate: wantAdded ? { x in DateAdded.get(x) } : nil)
            var e: Int32 = 0
            if let fi = Sys.statInfo(p, &e) { ListingCache.shared.put(p, includeHidden: includeHidden, folderInfo: fi, result: fresh) }
            if ListingCache.sameListing(fresh, cached) {
                Log.shared?.debug("Background check of \(p): unchanged")
                return
            }
            let nodes = me.sortedNodes(fresh.entries, parent: nil, sort: sort)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                guard me.token == myToken, me.path == p else { return }
                Log.shared?.info("Background check of \(p): changed on the server, list updated")
                me.finishLoad(p, r: fresh, nodes: nodes, ms: ms, samePath: true, keepSelection: me.selectedPaths(), selectPaths: [])
            }
        }
    }

    /// A network share went away: show nothing (the pane explains why) and stop reading and watching.
    func showUnavailable() {
        token += 1
        loading = false
        retire(roots)
        roots = []
        result = FolderReadResult()
        stopWatching()
        sizeQueue.cancelAllOperations()
        sizeGeneration.value += 1
        table.reloadData()
    }

    func reload(showHidden: Bool) {
        if resultsMode || path.isEmpty { return }
        load(path, selectPaths: [], showHidden: showHidden)
    }

    // MARK: Expanding folders in place

    private func isExpandable(_ n: FileNode) -> Bool {
        if resultsMode { return false }
        if !n.entry.isFolderLike { return false }
        if n.entry.ext == "app" || KindCache.shared.isPackage(n.entry) { return false }
        return true
    }

    private func loadChildren(_ node: FileNode) {
        if node.loading { return }
        node.loading = true
        let p = node.path
        let hidden = Prefs.showHidden
        let wantAdded = needsAddedDates
        let sort = currentSort
        let myToken = token
        let network = ListingCache.lifetime > 0 && VolumeRegistry.shared.treatAsNetwork(p)
        childQueue.addOperation { [weak self] in
            guard let me = self, me.currentToken.value == myToken else { return }
            // Network share: show the remembered listing at once, then read again in the background.
            let remembered = network ? ListingCache.shared.peek(p, includeHidden: hidden) : nil
            if let cached = remembered {
                let kids = me.sortedNodes(cached.entries, parent: node, sort: sort)
                DispatchQueue.main.async {
                    guard me.token == myToken else { return }
                    me.applyChildren(node, p, kids: kids, r: cached)
                    node.loading = true   // still being checked
                    me.onBackgroundCheck?(true)
                }
            }
            defer { if remembered != nil { DispatchQueue.main.async { me.onBackgroundCheck?(false) } } }
            let r = DirectoryReader.read(p, includeHidden: hidden, addedDate: wantAdded ? { x in DateAdded.get(x) } : nil)
            if network {
                var e: Int32 = 0
                if let fi = Sys.statInfo(p, &e) { ListingCache.shared.put(p, includeHidden: hidden, folderInfo: fi, result: r) }
            }
            if let cached = remembered, ListingCache.sameListing(cached, r) {
                DispatchQueue.main.async { node.loading = false }
                return
            }
            let kids = me.sortedNodes(r.entries, parent: node, sort: sort)
            DispatchQueue.main.async {
                guard me.token == myToken else { return }
                me.applyChildren(node, p, kids: kids, r: r)
            }
        }
    }

    private func applyChildren(_ node: FileNode, _ p: String, kids: [FileNode], r: FolderReadResult) {
        let me = self
        let keep = me.selectedPaths() + (Date() < me.wantSelectedUntil ? me.wantSelected : [])
        node.loading = false
        me.retire(node.children)
        me.applyCachedSizes(kids)
        node.children = kids
        node.error = r.folderError
        me.table.reloadItem(node, reloadChildren: true)
        me.onRowsChanged?()
        if me.expandedPaths.contains(p) { me.expandSafely(node) }
        me.restoreExpansion(kids)
        me.continueRecursiveExpansion(kids)
        let wantedBefore = Date() < me.wantSelectedUntil ? me.wantSelected : []
        me.select(paths: keep, scroll: false)
        if let found = wantedBefore.first(where: { me.selectedPaths().contains($0) }), let fn = me.node(forPath: found) {
            let r = me.table.row(forItem: fn)
            if r >= 0 { me.table.scrollRowToVisible(r) }
        }
        me.rememberMissing(keep)
        me.watch(p)
        me.queueFolderSizes(kids)
        if let fe = r.folderError {
            Log.shared?.warn("Could not open folder \(p): \(fe.reason) (code \(fe.code))")
        }
        me.onLoaded?()
    }

    /// Re-open folders that were expanded before a reload.
    private func restoreExpansion(_ nodes: [FileNode]) {
        if expandedPaths.isEmpty { return }
        for n in nodes where expandedPaths.contains(n.path) && isExpandable(n) {
            if n.children == nil {
                loadChildren(n)
            } else {
                expandSafely(n)
                restoreExpansion(n.children ?? [])
            }
        }
    }

    // CRASH FIX (0.10.3): macOS stops the app ("should not be expanded already") if a folder row is told
    // to expand while it is already expanding. That happened when Find re-opened folders after a reload
    // while Option was held (e.g. right after an Option-drag copy): the re-open was taken for an
    // Option-click "open all subfolders", which expanded the same row again from inside its own expansion.
    // Now: every expansion Find makes itself goes through expandSafely (never a row that is expanded or
    // expanding, and Option is ignored), and nothing is expanded from inside another row's expansion.
    private var internalExpansions = 0
    private var expandingNow = Set<ObjectIdentifier>()
    /// Last time files were dragged over this list. While dragging, macOS opens a folder you hover over;
    /// Option then means "copy", never "open all subfolders".
    private var lastDropHover = Date.distantPast

    /// Expand a row from code. Does nothing if it is already expanded or being expanded.
    private func expandSafely(_ n: FileNode) {
        let id = ObjectIdentifier(n)
        if expandingNow.contains(id) || table.isItemExpanded(n) { return }
        expandingNow.insert(id)
        internalExpansions += 1
        table.expandItem(n)
        internalExpansions -= 1
        expandingNow.remove(id)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedPaths.insert(node.path)
        let byUser = internalExpansions == 0
        let duringDrag = Date().timeIntervalSince(lastDropHover) < 1.5
        // Option-click on a triangle (or Option-Right) opens every subfolder too, like Finder.
        // Only for an expansion the user made; never for Find re-opening folders after a reload.
        if byUser && !duringDrag && NSEvent.modifierFlags.contains(.option) && !isUnderRecursive(node.path) {
            recursiveRoots.insert(node.path)
            recursiveCount = 0
            if node.children == nil {
                loadChildren(node)
            } else {
                // This row is expanding right now: open its subfolders after it has finished.
                let kids = node.children ?? []
                DispatchQueue.main.async { [weak self] in self?.continueRecursiveExpansion(kids) }
            }
            return
        }
        if node.children == nil {
            loadChildren(node)
        } else if byUser && isUnderRecursive(node.path) {
            let kids = node.children ?? []
            DispatchQueue.main.async { [weak self] in self?.continueRecursiveExpansion(kids) }
        }
    }

    // MARK: Option: expand / collapse all subfolders

    private func isUnderRecursive(_ p: String) -> Bool {
        for r in recursiveRoots where Paths.isInside(p, root: r) { return true }
        return false
    }

    private func beginRecursive(_ node: FileNode) {
        recursiveRoots.insert(node.path)
        recursiveCount = 0
        expandedPaths.insert(node.path)
        if node.children == nil {
            loadChildren(node)
        } else {
            expandSafely(node)
            continueRecursiveExpansion(node.children ?? [])
        }
    }

    /// Expand the folder children of a folder that is being opened with Option.
    private func continueRecursiveExpansion(_ kids: [FileNode]) {
        guard let first = kids.first, let parent = first.parent, isUnderRecursive(parent.path) else { return }
        for k in kids where isExpandable(k) {
            if k.entry.kind == .symlink { continue } // never follow links when opening everything
            if recursiveCount >= FileListController.recursiveLimit {
                Log.shared?.warn("Open all subfolders stopped at \(FileListController.recursiveLimit) folders")
                return
            }
            recursiveCount += 1
            expandedPaths.insert(k.path)
            if k.children == nil {
                loadChildren(k)
            } else {
                expandSafely(k)
            }
        }
    }

    /// Option-Right on the selection.
    func expandSelectedRecursively() {
        for n in selectedNodes() where isExpandable(n) { beginRecursive(n) }
    }

    /// Option-Left on the selection: close the folder and everything inside it.
    func collapseSelectedRecursively() {
        for n in selectedNodes() where table.isItemExpanded(n) {
            recursiveRoots = recursiveRoots.filter { !Paths.isInside($0, root: n.path) }
            table.collapseItem(n, collapseChildren: true)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        onRowsChanged?()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        defer { onRowsChanged?() }
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedPaths.remove(node.path)
        recursiveRoots = recursiveRoots.filter { !Paths.isInside($0, root: node.path) }
        // Forget the contents so the next expand reads the folder fresh; stop watching it and below.
        for p in Array(watchers.keys) where Paths.isInside(p, root: node.path) {
            watchers[p]?.cancel()
            watchers[p] = nil
        }
        for p in Array(expandedPaths) where Paths.isInside(p, root: node.path) { expandedPaths.remove(p) }
        retire(node.children)
        node.children = nil
        table.reloadItem(node, reloadChildren: true)
    }

    // MARK: Watching for changes

    /// A delete/rename event is only a hint: network shares send them for ordinary changes.
    /// The folder is checked on disk (FolderWatchCheck) before Find ever leaves it.
    private func watch(_ p: String) {
        if watchers[p] != nil || watchPaused.contains(p) { return }
        if watchers.count >= 64 { return }
        if VolumeRegistry.shared.treatAsNetwork(p) {
            // On a share, opening the folder is a request to the server: never on the main thread.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let identity = FolderIdentity.of(p)
                let fd = open(p, O_EVTONLY)
                DispatchQueue.main.async {
                    guard fd >= 0 else { return }
                    guard let s = self, s.watchers[p] == nil, !s.resultsMode, s.path == p || s.expandedPaths.contains(p) else {
                        close(fd)   // the pane moved on meanwhile: no watcher for a folder that isn't shown
                        return
                    }
                    s.installWatcher(p, fd: fd, identity: identity)
                }
            }
            return
        }
        let identity = FolderIdentity.of(p)
        let fd = open(p, O_EVTONLY)
        if fd < 0 { return }
        installWatcher(p, fd: fd, identity: identity)
    }

    /// Watchers of folders on shares run on their own queue: closing a share folder's handle is a request
    /// to the server (it waited for the server on the main thread each time you left a folder - 0.17.3).
    private static let networkWatchQueue = DispatchQueue(label: "find.watch.network", qos: .utility)

    private func installWatcher(_ p: String, fd: Int32, identity: FolderIdentity?) {
        let remote = VolumeRegistry.shared.treatAsNetwork(p)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link],
                                                            queue: remote ? FileListController.networkWatchQueue : DispatchQueue.main)
        src.setEventHandler { [weak self] in
            let ev = src.data
            if remote {
                DispatchQueue.main.async { self?.watchEvent(p, ev: ev, identity: identity) }
            } else {
                self?.watchEvent(p, ev: ev, identity: identity)
            }
        }
        src.setCancelHandler {
            close(fd)
        }
        watchers[p] = src
        src.resume()
    }

    private func watchEvent(_ p: String, ev: DispatchSource.FileSystemEvent, identity: FolderIdentity?) {
        do {
            let s = self
            if ev.contains(.delete) || ev.contains(.rename) {
                s.watchers[p]?.cancel()
                s.watchers[p] = nil
                s.verifyAfterEvent(p, identity: identity, event: ev.contains(.delete) ? "delete" : "rename")
                return
            }
            s.scheduleReload(p)
        }
    }

    private func verifyAfterEvent(_ p: String, identity: FolderIdentity?, event: String) {
        let myPath = path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let verdict = FolderWatchCheck.verify(p, watched: identity)
            DispatchQueue.main.async {
                guard let s = self else { return }
                Log.shared?.info("WATCH \(event) event for \(p): checked on disk, result \(verdict.name)")
                if s.path != myPath || s.resultsMode { return }
                if verdict == .gone {
                    if p == s.path {
                        s.onFolderGone?(p)
                    } else {
                        s.scheduleReload(Paths.parent(p))
                    }
                } else {
                    let now = Date()
                    let recent = (s.falseAlarms[p] ?? []).filter { now.timeIntervalSince($0) < 10 } + [now]
                    s.falseAlarms[p] = recent
                    if recent.count >= 3 {
                        s.watchPaused.insert(p)
                        Log.shared?.warn("WATCH paused for \(p): \(recent.count) false delete/rename events in 10 s (typical of network shares). Use Refresh to update this folder.")
                    }
                    // Still there (or can't be reached right now): stay and refresh. The reload
                    // watches the folder again, and shows a notice if it can't be read.
                    s.scheduleReload(p)
                }
            }
        }
    }

    private func scheduleReload(_ p: String) {
        if reloadScheduled.contains(p) { return }
        reloadScheduled.insert(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let s = self else { return }
            s.reloadScheduled.remove(p)
            if s.resultsMode { return }
            // 0.17: not while a name is being typed in place (the new rows would cover the field).
            if s.holdReloads?() == true { s.scheduleReload(p); return }
            if p == s.path {
                s.load(s.path, selectPaths: [], showHidden: Prefs.showHidden)
            } else if let node = s.node(forPath: p), node.children != nil {
                s.loadChildren(node)
            }
        }
    }

    func stopWatching() {
        StallWatch.mark("stopping folder watchers (\(watchers.count)) for \(path)")
        for (_, w) in watchers { w.cancel() }
        watchers.removeAll()
    }

    // MARK: Folder sizes (optional)

    private func applyCachedSizes(_ nodes: [FileNode]) {
        if folderSizeCache.isEmpty { return }
        for n in nodes where n.entry.kind == .directory {
            if let sz = folderSizeCache[n.path] { n.entry.size = sz }
        }
    }

    /// Forget calculated sizes (Refresh), so they are counted again.
    func clearFolderSizes() {
        folderSizeCache.removeAll()
        sizeGeneration.value += 1
        sizeQueue.cancelAllOperations()
    }

    private func queueFolderSizes(_ nodes: [FileNode]) {
        guard Prefs.calculateFolderSizes, !resultsMode else { return }
        // On a network share, counting every folder's contents means many requests to the server:
        // only when Settings > Network allows it.
        if !Prefs.netFolderSizes && VolumeRegistry.shared.treatAsNetwork(path) { return }
        let gen = sizeGeneration.value
        let flag = sizeGeneration
        for n in nodes where n.entry.kind == .directory && n.entry.size < 0 {
            let p = n.path
            if folderSizeCache[p] != nil { continue }
            sizeQueue.addOperation { [weak self] in
                if flag.value != gen { return }
                let r = FolderSize.compute(p, isCancelled: { flag.value != gen })
                if r.cancelled { return }
                DispatchQueue.main.async {
                    guard let s = self, flag.value == gen else { return }
                    s.folderSizeCache[p] = r.bytes
                    if let node = s.node(forPath: p) {
                        node.entry.size = r.bytes
                        s.table.reloadItem(node)
                    }
                    if s.spec.column == .size { s.scheduleSizeResort() }
                }
            }
        }
    }

    private func scheduleSizeResort() {
        if sizeResortScheduled { return }
        sizeResortScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let s = self else { return }
            s.sizeResortScheduled = false
            s.resort()
        }
    }

    /// Called when the folder-size option is switched.
    func folderSizeOptionChanged() {
        if Prefs.calculateFolderSizes {
            queueFolderSizes(roots)
        } else {
            clearFolderSizes()
            for i in 0..<table.numberOfRows {
                if let n = table.item(atRow: i) as? FileNode, n.entry.kind == .directory { n.entry.size = -1 }
            }
            table.reloadData()
        }
    }

    // MARK: Search results

    func beginResults() {
        token += 1
        stopWatching()
        resultsMode = true
        loading = true
        retire(roots)
        roots = []
        result = FolderReadResult()
        applyVisibleColumns()
        table.reloadData()
    }

    func appendResults(_ entries: [FileEntry]) {
        guard resultsMode else { return }
        let keep = selectedPaths()
        let s = currentSort
        retire(roots)
        if roots.count + entries.count <= 20_000 {
            let all = roots.map { $0.entry } + entries
            roots = Listing.sorted(all, by: s, kindOf: KindCache.shared.kind).map { FileNode($0, parent: nil) }
        } else {
            roots.append(contentsOf: entries.map { FileNode($0, parent: nil) })
        }
        table.reloadData()
        select(paths: keep, scroll: false)
    }

    /// After a rename inside search results: show the new name in place.
    func updateResult(_ oldPath: String, to newPath: String) {
        guard resultsMode, let n = node(forPath: oldPath) else { return }
        var e: Int32 = 0
        if let fresh = FileEntry.make(path: newPath, err: &e) {
            n.entry = fresh
            table.reloadItem(n)
        }
    }

    func endResults() {
        loading = false
        if roots.count > 20_000 { resort() }
    }

    // MARK: Selection

    var allLoadedEntries: [FileEntry] {
        var out: [FileEntry] = []
        for i in 0..<table.numberOfRows {
            if let n = table.item(atRow: i) as? FileNode { out.append(n.entry) }
        }
        return out
    }

    var rootCount: Int { return roots.count }

    func selectedNodes() -> [FileNode] {
        return table.selectedRowIndexes.compactMap { table.item(atRow: $0) as? FileNode }
    }

    func selectedEntries() -> [FileEntry] {
        return selectedNodes().map { $0.entry }
    }

    func selectedNames() -> [String] {
        return selectedEntries().map { $0.name }
    }

    /// Space: Fast Preview, or macOS Quick Look if chosen in Settings.
    func previewSelection() {
        if Prefs.spaceOpensQuickLook {
            FastPreview.shared.close()
            quickLook.toggle()
        } else {
            quickLook.close()
            FastPreview.shared.toggle(for: self)
        }
    }

    /// Row of the first selected item (for "3 of 120").
    func selectedRowIndex() -> Int? {
        let i = table.selectedRowIndexes.first
        return i
    }

    func selectedPaths() -> [String] {
        return selectedEntries().map { $0.path }
    }

    func node(forPath p: String) -> FileNode? {
        for i in 0..<table.numberOfRows {
            if let n = table.item(atRow: i) as? FileNode, n.path == p { return n }
        }
        return nil
    }

    func select(names: [String], scroll: Bool) {
        select(paths: names.map { Paths.join(path, $0) }, scroll: scroll)
    }

    /// Remember wanted items that aren't shown yet (for a few seconds).
    private func rememberMissing(_ wanted: [String]) {
        let shown = Set(selectedPaths())
        let missing = wanted.filter { !shown.contains($0) }
        wantSelected = missing
        wantSelectedUntil = missing.isEmpty ? Date.distantPast : Date().addingTimeInterval(6)
    }

    func select(paths: [String], scroll: Bool) {
        if paths.isEmpty {
            table.deselectAll(nil)
            return
        }
        let wanted = Set(paths)
        var idx = IndexSet()
        for i in 0..<table.numberOfRows {
            if let n = table.item(atRow: i) as? FileNode, wanted.contains(n.path) { idx.insert(i) }
        }
        table.selectRowIndexes(idx, byExtendingSelection: false)
        if scroll, let first = idx.first { table.scrollRowToVisible(first) }
    }

    /// Select every loaded item with the same extension as `ext` (Find addition to the context menu).
    func selectAll(withExtension ext: String) {
        var idx = IndexSet()
        for i in 0..<table.numberOfRows {
            if let n = table.item(atRow: i) as? FileNode, n.entry.kind != .directory, n.entry.ext == ext { idx.insert(i) }
        }
        table.selectRowIndexes(idx, byExtendingSelection: false)
    }

    @objc func doubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, let n = table.item(atRow: row) as? FileNode else { return }
        onOpen?(n.entry)
    }

    // MARK: Outline data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? FileNode else { return roots.count }
        return n.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? FileNode else { return roots[index] }
        return n.children?[index] ?? roots[0]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? FileNode else { return false }
        return isExpandable(n)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return ThemedRowView()
    }

    private func dateText(_ t: Double, width: CGFloat) -> String {
        if t <= 0 { return "--" }
        let d = Date(timeIntervalSince1970: t)
        if width < 110 { return shortDate.string(from: d) }
        if width < 170 { return mediumDate.string(from: d) }
        return longDate.string(from: d)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let col = tableColumn, let n = item as? FileNode else { return nil }
        let e = n.entry
        let id = col.identifier
        let isName = id.rawValue == "name"
        let v = (outlineView.makeView(withIdentifier: id, owner: nil) as? ThemedCellView) ?? ThemedCellView.make(identifier: id, withIcon: isName)
        v.secondary = !isName
        v.toolTip = nil
        switch id.rawValue {
        case "name":
            var text = e.name
            if n.loading { text += "  \u{2026}" }
            if let fe = n.error { text += "  (can't open: \(fe.reason))" }
            v.textField?.stringValue = text
            v.imageView?.image = IconCache.shared.icon(for: e)
            v.imageView?.alphaValue = e.isHidden ? 0.5 : 1.0
            v.labelColors = TagCache.shared.colors(e.path)
        case "match":
            let d = e.matchDistance
            v.textField?.stringValue = d < 0 ? "" : (d == 0 ? "exact" : "\(d) typo\(d == 1 ? "" : "s")")
        case "folder":
            v.textField?.stringValue = Paths.parent(e.path)
            v.toolTip = Paths.parent(e.path)
        case "modified":
            v.textField?.stringValue = dateText(e.modified, width: col.width)
        case "created":
            v.textField?.stringValue = dateText(e.created, width: col.width)
        case "added":
            v.textField?.stringValue = dateText(e.added, width: col.width)
        case "size":
            if e.kind == .directory && e.size < 0 && Prefs.calculateFolderSizes && !resultsMode {
                v.textField?.stringValue = "\u{2026}"
            } else {
                v.textField?.stringValue = Listing.sizeText(e.size)
            }
        case "kind":
            v.textField?.stringValue = KindCache.shared.kind(e)
        default:
            v.textField?.stringValue = ""
        }
        v.applyTheme()
        if isName && (e.isHidden || n.error != nil) {
            v.textField?.textColor = n.error != nil ? ThemeManager.shared.warning : ThemeManager.shared.secondaryText
        }
        return v
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let key = d.key, let col = SortColumn(rawValue: key) else { return }
        spec.column = col
        spec.ascending = d.ascending
        Prefs.sortSpec = spec
        resort()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // The Fast Preview follows at once (it is cheap and prepares neighbours ahead). Everything else
        // (status bar, inspector, grid, Quick Look) waits until the selection pauses for a moment, so
        // holding an arrow key with a fast key repeat moves the list smoothly on every repeat.
        FastPreview.shared.selectionChanged(from: self)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(selectionSettled), object: nil)
        perform(#selector(selectionSettled), with: nil, afterDelay: 0.05)
    }

    @objc private func selectionSettled() {
        quickLook.selectionChanged()
        onSelectionChanged?()
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        var w = Prefs.columnWidths
        for c in table.tableColumns where c.identifier.rawValue != "name" { w[c.identifier.rawValue] = Double(c.width) }
        Prefs.columnWidths = w
        // Dates switch between short and long forms with the column width.
        if let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            ["modified", "created", "added"].contains(col.identifier.rawValue) {
            let ci = table.column(withIdentifier: col.identifier)
            let rows = table.rows(in: table.visibleRect)
            if ci >= 0 && rows.length > 0 {
                table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)),
                                 columnIndexes: IndexSet(integer: ci))
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        if let c = tableColumn, c.identifier.rawValue != "name" { return nil }
        return (item as? FileNode)?.entry.name
    }

    /// Dragging files (to folders in Find, to other panes, the sidebar, or other apps).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? FileNode else { return nil }
        return NSURL(fileURLWithPath: n.path)
    }

    // MARK: Dropping files

    /// Where a drop at this spot goes: onto a folder row = into it; between the items of an open folder =
    /// into that folder; anywhere else = into the folder this list shows.
    private func dropDestination(item: Any?, childIndex: Int) -> (dest: String, onItem: FileNode?)? {
        if let n = item as? FileNode {
            guard FileDrag.isDropFolder(n.entry) else {
                // On a file: into the folder that file is in (its parent row, or the list's folder).
                if let p = n.parent { return (p.path, p) }
                return resultsMode ? nil : (path, nil)
            }
            return (n.path, n)
        }
        if resultsMode || path.isEmpty { return nil }
        return (path, nil)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        lastDropHover = Date()
        guard let target = dropDestination(item: item, childIndex: index) else { return [] }
        let op = FileDrag.operation(info, sources: FileDrag.paths(info), dest: target.dest)
        if op.isEmpty { return [] }
        // Highlight the whole folder row, or the whole list for the list's own folder.
        outlineView.setDropItem(target.onItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return op
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropDestination(item: item, childIndex: index) else { return false }
        let sources = FileDrag.paths(info)
        let op = FileDrag.operation(info, sources: sources, dest: target.dest)
        if op.isEmpty { return false }
        onDrop?(sources, target.dest, op == .move)
        return true
    }
}

/// An Int that can be read from a background thread while the main thread changes it.
final class AtomicInt {
    private let lock = NSLock()
    private var v = 0
    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return v
        }
        set {
            lock.lock()
            v = newValue
            lock.unlock()
        }
    }
}
