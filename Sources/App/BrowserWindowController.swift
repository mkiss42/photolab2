// BrowserWindowController.swift
// One browser window: sidebar | (back/forward/up + path bar, file list, status line).
// Listing happens on a background queue; the main thread only shows results. A newer
// navigation cancels the older listing (generation counter).

import AppKit

final class Generation {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

extension Notification.Name {
    static let volumesChanged = Notification.Name("PhotoLabVolumesChanged")
    static let brainStateChanged = Notification.Name("PhotoLabBrainStateChanged")
    static let layoutSettingsChanged = Notification.Name("PhotoLabLayoutSettingsChanged")
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    static var open: [BrowserWindowController] = []
    static var brainText = "Brain: not started"

    private(set) var currentPath: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private let generation = Generation()
    /// Bumped only when the window changes folder; child listings of the old folder are dropped.
    private let folderGeneration = Generation()
    private let listQueue = DispatchQueue(label: "photolab.list", qos: .userInitiated, attributes: .concurrent)
    private var watcher: FolderWatcher?
    /// Watchers for expanded subfolders, by path.
    private var childWatchers: [String: FolderWatcher] = [:]
    private var lastListing: FolderListing?
    private var fromCache = false

    private let sidebar = SidebarController()
    private let list = FileListController()
    private let pathBar = NSStackView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusSpinner = NSProgressIndicator()
    private let brainLabel = NSTextField(labelWithString: "")

    static var showHidden: Bool {
        get { return UserDefaults.standard.bool(forKey: "showHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "showHidden") }
    }
    static var foldersFirst: Bool {
        get { return UserDefaults.standard.object(forKey: "foldersFirst") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "foldersFirst") }
    }

    @discardableResult
    static func openWindow(at path: String) -> BrowserWindowController {
        let c = BrowserWindowController(path: path)
        open.append(c)
        if let last = open.dropLast().last?.window, let w = c.window {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        c.showWindow(nil)
        // Let the Name column take the free width now that the window has its real size.
        DispatchQueue.main.async { c.list.table.sizeToFit() }
        return c
    }

    init(path: String) {
        currentPath = path
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 520, height: 300)
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("BrowserWindow")
        buildUI(in: w)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged(_:)), name: .volumesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(brainChanged(_:)), name: .brainStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutSettingsChanged(_:)), name: .layoutSettingsChanged, object: nil)
        brainLabel.stringValue = BrowserWindowController.brainText
        navigate(to: path, record: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private let split = NSSplitView()
    private let rightStack = NSStackView()
    private let navBar = NSStackView()
    private let statusBar = NSStackView()
    private let sidebarButton = NSButton()
    private let pathRow = NSStackView()

    static let defaultSidebarWidth: CGFloat = 160
    static var sidebarVisible: Bool {
        get { return UserDefaults.standard.bool(forKey: "sidebarVisible") }      // hidden by default
        set { UserDefaults.standard.set(newValue, forKey: "sidebarVisible") }
    }
    static var sidebarWidth: CGFloat {
        get { let w = UserDefaults.standard.double(forKey: "sidebarWidth"); return w > 0 ? CGFloat(w) : defaultSidebarWidth }
        set { UserDefaults.standard.set(Double(newValue), forKey: "sidebarWidth") }
    }
    static var pathBarAtBottom: Bool {
        get { return UserDefaults.standard.bool(forKey: "pathBarAtBottom") }
        set { UserDefaults.standard.set(newValue, forKey: "pathBarAtBottom") }
    }

    private func buildUI(in w: NSWindow) {
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        sidebar.onSelect = { [weak self] p in self?.navigate(to: p) }

        for (b, img, sel, tip) in [(backButton, NSImage.goLeftTemplateName, #selector(goBack(_:)), "Back"),
                                   (forwardButton, NSImage.goRightTemplateName, #selector(goForward(_:)), "Forward")] {
            b.bezelStyle = .texturedRounded
            b.image = NSImage(named: img)
            b.target = self
            b.action = sel
            b.toolTip = tip
        }
        upButton.bezelStyle = .texturedRounded
        upButton.title = "Up"
        upButton.target = self
        upButton.action = #selector(goEnclosingFolder(_:))
        upButton.toolTip = "Enclosing folder (Cmd-Up)"
        sidebarButton.bezelStyle = .texturedRounded
        sidebarButton.image = Glyphs.sidebar
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.setButtonType(.pushOnPushOff)
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebar(_:))
        sidebarButton.toolTip = "Show or hide the sidebar (Cmd-Option-S)"

        pathBar.orientation = .horizontal
        pathBar.spacing = 0
        pathBar.alignment = .centerY
        pathBar.setHuggingPriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)
        for v in [sidebarButton, backButton, forwardButton, upButton] as [NSView] { navBar.addArrangedSubview(v) }
        pathRow.orientation = .horizontal
        pathRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 2, right: 8)
        navBar.orientation = .horizontal
        navBar.spacing = 6
        navBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        list.foldersFirst = BrowserWindowController.foldersFirst
        list.onOpen = { [weak self] sel in self?.open(sel) }
        list.onSelectionChange = { [weak self] in self?.updateStatus() }
        list.onNeedChildren = { [weak self] p in self?.loadChildren(p) }
        list.onRenameRequest = { [weak self] in self?.renameSelected(nil) }
        list.onTrashRequest = { [weak self] in self?.moveToTrash(nil) }
        list.onRenameCommit = { [weak self] e, name in self?.commitRename(e, name) }
        list.onExpandedChange = { [weak self] set in self?.watchExpanded(set) }
        list.onDrop = { [weak self] paths, dest, kind in
            TransferController.shared.start(paths, to: dest, kind: kind, from: self)
        }
        list.showHidden = BrowserWindowController.showHidden

        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        brainLabel.textColor = NSColor.secondaryLabelColor
        brainLabel.font = NSFont.systemFont(ofSize: 11)
        brainLabel.alignment = .right
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        for v in [statusSpinner, statusLabel, brainLabel] as [NSView] { statusBar.addArrangedSubview(v) }
        statusBar.orientation = .horizontal
        statusBar.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 4, right: 10)
        statusLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)

        rightStack.orientation = .vertical
        rightStack.spacing = 0
        rightStack.alignment = .leading
        rightStack.distribution = .fill
        list.view.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
        arrangeRightStack()

        let side = sidebar.scroll
        split.addSubview(side)
        split.addSubview(rightStack)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 0)
        w.contentView = split
        w.initialFirstResponder = list.table
        setSidebar(visible: BrowserWindowController.sidebarVisible)
    }

    /// Path bar above the list (default) or below it, from Settings.
    private func arrangeRightStack() {
        for v in rightStack.arrangedSubviews { rightStack.removeArrangedSubview(v); v.removeFromSuperview() }
        // Path bar above: one row (nav buttons + path). Below: nav buttons stay on top, the path
        // gets its own row under the list.
        for v in navBar.arrangedSubviews where v === pathBar { navBar.removeArrangedSubview(v); v.removeFromSuperview() }
        pathRow.removeFromSuperview()
        let order: [NSView]
        if BrowserWindowController.pathBarAtBottom {
            pathRow.setViews([pathBar], in: .leading)
            order = [navBar, list.view, pathRow, statusBar]
        } else {
            navBar.addArrangedSubview(pathBar)
            order = [navBar, list.view, statusBar]
        }
        for v in order {
            rightStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true
        }
    }

    private var sidebarShown = false
    var isSidebarShown: Bool { return sidebarShown }

    private func setSidebar(visible: Bool) {
        sidebarShown = visible
        sidebarButton.state = visible ? .on : .off
        let side = sidebar.scroll
        side.isHidden = !visible
        if visible {
            split.adjustSubviews()
            split.setPosition(BrowserWindowController.sidebarWidth, ofDividerAt: 0)
        } else {
            split.adjustSubviews()
        }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        setSidebar(visible: !sidebarShown)
    }

    @objc private func layoutSettingsChanged(_ n: Notification) {
        arrangeRightStack()
    }

    // MARK: Navigation

    func navigate(to path: String, record: Bool = true, select: [String]? = nil) {
        if record && path != currentPath {
            backStack.append(currentPath)
            forwardStack.removeAll()
        }
        currentPath = path
        _ = folderGeneration.next()
        UserDefaults.standard.set(path, forKey: "lastFolder")
        let vol = Volumes.volume(for: path)
        window?.title = (path == vol?.mountPoint ? vol?.displayName : nil) ?? Paths.name(path)
        rebuildPathBar()
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        upButton.isEnabled = path != "/"
        sidebar.reflect(path: path)
        watcher?.stop()
        watcher = FolderWatcher(path: path) { [weak self] change in self?.watchFired(change, for: path) }
        watchExpanded([])
        load(select: select ?? [], useCache: true)
    }

    /// List the current folder in the background. `select` nil keeps the current selection.
    private func load(select: [String]?, useCache: Bool) {
        let gen = generation.next()
        let path = currentPath
        let started = Date()
        // Spinners only if the listing takes noticeable time (no flicker for quick folders):
        // a new folder gets a big one in the list, a re-read of the folder on screen a small one
        // in the status line (its contents stay visible meanwhile).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let me = self, me.generation.current == gen else { return }
            if me.lastListingPath != path {
                me.list.setEntries([], select: [])
                me.list.showMessage("Reading \(Paths.name(path))...", spinning: true)
                me.statusLabel.stringValue = "Reading..."
            }
            me.statusSpinner.startAnimation(nil)
        }
        let isNetwork = Volumes.isNetwork(path)
        listQueue.async { [weak self] in
            guard let me = self else { return }
            Activity.set("list: \(path)")
            let mtime = ListingCache.folderMtime(path)
            var listing: FolderListing
            var cached = false
            if useCache, let c = ListingCache.shared.lookup(path, currentMtime: mtime) {
                listing = c
                cached = true
                Stats.noteCacheHit()
            } else {
                listing = DirectoryReader.read(path, isCancelled: { [weak me] in me?.generation.current != gen })
                if !listing.cancelled { ListingCache.shared.store(path, listing: listing, folderMtime: mtime) }
            }
            Activity.set("idle")
            if listing.cancelled { return }
            let ms = Date().timeIntervalSince(started) * 1000
            if !cached && listing.error == 0 {
                Stats.noteListing(network: isNetwork, ms: ms, method: listing.method, entries: listing.entries.count)
            }
            if !cached {
                Log.info(String(format: "list %@ %ld entries %.1f ms via %@%@%@", path, listing.entries.count, ms,
                                listing.method, isNetwork ? " (network)" : "",
                                listing.error != 0 ? " error \(listing.error) \(listing.errorText)" : ""))
            }
            DispatchQueue.main.async {
                guard me.generation.current == gen else { return }
                me.apply(listing, path: path, cached: cached, select: select)
            }
        }
    }

    private var lastListingPath: String?

    private func apply(_ listing: FolderListing, path: String, cached: Bool, select: [String]?) {
        Activity.set("show: \(path)")
        statusSpinner.stopAnimation(nil)
        lastListing = listing
        lastListingPath = path
        fromCache = cached
        let showHidden = BrowserWindowController.showHidden
        let visible = showHidden ? listing.entries : listing.entries.filter { !$0.isHidden }
        list.foldersFirst = BrowserWindowController.foldersFirst
        list.showHidden = showHidden
        list.rootPath = path
        list.setEntries(listing.entries, select: select)
        if listing.error != 0 {
            list.showMessage("Can't open this folder: \(listing.errorText) (E-LIST-\(listing.error))")
        } else if visible.isEmpty {
            list.showMessage(listing.entries.isEmpty ? "Empty folder"
                : "\(listing.entries.count) hidden item\(listing.entries.count == 1 ? "" : "s") only (Cmd-Shift-. shows them)")
        } else {
            list.showMessage(nil)
        }
        updateStatus()
        Activity.set("idle")
    }

    private func updateStatus() {
        guard let l = lastListing else { statusLabel.stringValue = ""; return }
        if l.error != 0 { statusLabel.stringValue = "Not readable: \(l.errorText)"; return }
        let hidden = l.entries.filter { $0.isHidden }.count
        let shown = BrowserWindowController.showHidden ? l.entries.count : l.entries.count - hidden
        var parts = ["\(shown) item\(shown == 1 ? "" : "s")"]
        if hidden > 0 && !BrowserWindowController.showHidden { parts.append("\(hidden) hidden") }
        let sel = list.selectionCount
        if sel > 0 { parts.append("\(sel) selected") }
        parts.append(fromCache ? "from memory" : String(format: "%@ %.0f ms", l.method, l.milliseconds))
        if !l.problems.isEmpty { parts.append("\(l.problems.count) unreadable") }
        statusLabel.stringValue = parts.joined(separator: "  \u{00B7}  ")
    }

    private func rebuildPathBar() {
        for v in pathBar.arrangedSubviews { pathBar.removeArrangedSubview(v); v.removeFromSuperview() }
        // The whole chain from "/" (/ > Volumes > Share > ...), every level clickable.
        let chain = Paths.ancestry(currentPath)
        let mounts = Dictionary(Volumes.all.map { ($0.mountPoint, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        for (i, p) in chain.enumerated() {
            if i > 0 {
                let sep = NSTextField(labelWithString: "\u{203A}")
                sep.textColor = NSColor.tertiaryLabelColor
                pathBar.addArrangedSubview(sep)
            }
            let title = p == "/" ? "" : (mounts[p] ?? Paths.name(p))
            let b = NSButton(title: title, target: self, action: #selector(pathClicked(_:)))
            if p == "/" {
                b.image = Glyphs.computer
                b.imagePosition = .imageOnly
                b.toolTip = "Computer"
            }
            let m = NSMenu()
            let copyHere = NSMenuItem(title: "Copy Path", action: #selector(copyPathItem(_:)), keyEquivalent: "")
            copyHere.representedObject = p
            copyHere.target = self
            let copyAll = NSMenuItem(title: "Copy Full Path", action: #selector(copyPathItem(_:)), keyEquivalent: "")
            copyAll.representedObject = currentPath
            copyAll.target = self
            m.addItem(copyHere)
            m.addItem(copyAll)
            b.menu = m
            b.bezelStyle = .recessed
            b.isBordered = false
            b.identifier = NSUserInterfaceItemIdentifier(p)
            b.lineBreakMode = .byTruncatingMiddle
            b.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 200), for: .horizontal)
            if i == chain.count - 1 { b.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
            pathBar.addArrangedSubview(b)
        }
    }

    @objc private func copyPathItem(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        BrowserWindowController.putOnClipboard([p])
    }

    static func putOnClipboard(_ paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
        Log.info("copied \(paths.count) path(s) to the clipboard")
    }

    /// Edit > Copy Path (Cmd-Shift-C): the selected items' paths, one per line; the folder itself
    /// when nothing is selected.
    @objc func copyPaths(_ sender: Any?) {
        let sel = list.selectedEntries().map { $0.path }
        BrowserWindowController.putOnClipboard(sel.isEmpty ? [currentPath] : sel)
    }

    @objc private func pathClicked(_ sender: NSButton) {
        guard let p = sender.identifier?.rawValue, p != currentPath else { return }
        let child = Paths.ancestry(currentPath).first { Paths.parent($0) == p && $0 != p }
        navigate(to: p, select: child.map { [Paths.name($0)] })
    }

    private func watchFired(_ change: FolderWatcher.Change, for path: String) {
        guard path == currentPath else { return }
        Stats.noteWatch(gone: change == .gone)
        switch change {
        case .contents:
            ListingCache.shared.invalidate(path)
            load(select: nil, useCache: false)
        case .gone:
            Log.info("folder gone: \(path); going to the nearest folder that exists")
            listQueue.async { [weak self] in
                var p = Paths.parent(path)
                var st = stat()
                while p != "/" && stat(p, &st) != 0 { p = Paths.parent(p) }
                DispatchQueue.main.async { self?.navigate(to: p) }
            }
        }
    }

    private func open(_ entries: [FileEntry]) {
        if entries.count == 1, let e = entries.first, e.isDirectory && !e.isPackage {
            navigate(to: e.path)
            return
        }
        let urls = entries.map { URL(fileURLWithPath: $0.path) }
        Log.info("open \(urls.count) item(s) with their default apps")
        DispatchQueue.global(qos: .userInitiated).async {
            for u in urls { NSWorkspace.shared.open(u) }
        }
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func goBack(_ sender: Any?) {
        guard let p = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        let child = Paths.ancestry(currentPath).first { Paths.parent($0) == p && $0 != p }
        navigate(to: p, record: false, select: child.map { [Paths.name($0)] })
    }

    @objc func goForward(_ sender: Any?) {
        guard let p = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        navigate(to: p, record: false)
    }

    @objc func goEnclosingFolder(_ sender: Any?) {
        guard currentPath != "/" else { return }
        let here = currentPath
        let vol = Volumes.volume(for: here)
        // From a volume's root, go to "/" (Computer-like view) rather than /Volumes.
        let target = (vol != nil && vol!.mountPoint == here && !vol!.isRoot) ? "/Volumes" : Paths.parent(here)
        navigate(to: target, select: [Paths.name(here)])
    }

    @objc func goHome(_ sender: Any?) { navigate(to: NSHomeDirectory()) }
    @objc func goComputer(_ sender: Any?) { navigate(to: "/") }
    @objc func goVolumes(_ sender: Any?) { navigate(to: "/Volumes") }

    @objc func goToFolder(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to the folder:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = currentPath
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var p = (field.stringValue as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        guard p.hasPrefix("/") else { return }
        listQueue.async { [weak self] in
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            DispatchQueue.main.async {
                guard let me = self else { return }
                if ok && isDir.boolValue { me.navigate(to: p) }
                else if ok { me.navigate(to: Paths.parent(p), select: [Paths.name(p)]) }
                else { NSSound.beep(); Log.info("go to folder: not found \(p)") }
            }
        }
    }

    @objc func openSelected(_ sender: Any?) { list.openSelection() }

    @objc func refresh(_ sender: Any?) {
        ListingCache.shared.invalidate(currentPath)
        load(select: nil, useCache: false)
        for p in list.expandedFolderPaths {
            ListingCache.shared.invalidate(p)
            list.relist(path: p)
        }
    }

    // MARK: File operations (background queue; results and undo on the main thread)

    private let opsQueue = DispatchQueue(label: "photolab.ops", qos: .userInitiated)

    func showProblem(_ title: String, _ text: String) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.beginSheetModal(for: w, completionHandler: nil)
    }

    /// Re-read the folders an operation touched (the window's folder and any expanded ones).
    func reloadAfterOp(_ dirs: Set<String>, select: [String]? = nil) {
        for d in dirs { ListingCache.shared.invalidate(d) }
        if dirs.contains(currentPath) { load(select: select, useCache: false) }
        for d in dirs where d != currentPath { list.relist(path: d) }
    }

    @objc func renameSelected(_ sender: Any?) {
        if !list.beginRename() { NSSound.beep() }
    }

    private func commitRename(_ entry: FileEntry, _ newName: String) {
        let dir = Paths.parent(entry.path)
        Activity.set("ops: rename")
        opsQueue.async { [weak self] in
            let r = FileOperations.rename(entry.path, to: newName)
            Activity.set("idle")
            DispatchQueue.main.async {
                guard let me = self else { return }
                switch r {
                case .failure(let f):
                    me.showProblem("Not renamed", f.message)
                case .success(let pairs):
                    me.registerUndoRename(pairs, name: pairs.count > 1 ? "Rename Set" : "Rename")
                    me.reloadAfterOp([dir], select: dir == me.currentPath ? [newName] : nil)
                }
            }
        }
    }

    /// Undo of a rename is the reverse rename; registering it inside the undo handler makes AppKit
    /// file it as the redo.
    func registerUndoRename(_ pairs: [(String, String)], name: String) {
        guard let um = window?.undoManager, !pairs.isEmpty else { return }
        um.registerUndo(withTarget: self) { me in
            let back = Array(pairs.map { ($0.1, $0.0) }.reversed())
            me.registerUndoRename(back, name: name)
            me.opsQueue.async {
                let r = FileOperations.applyRenames(back, what: "undo rename")
                DispatchQueue.main.async {
                    if case .failure(let f) = r { me.showProblem("Could not undo the rename", f.message) }
                    me.reloadAfterOp(Set(back.map { Paths.parent($0.0) }))
                }
            }
        }
        um.setActionName(name)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let sel = list.selectedEntries().map { $0.path }
        guard !sel.isEmpty else { NSSound.beep(); return }
        performTrash(sel, sets: FileOperations.useSets)
    }

    /// Trash; undo puts back, redo trashes the same items again.
    private func performTrash(_ paths: [String], sets: Bool) {
        Activity.set("ops: trash")
        opsQueue.async { [weak self] in
            let r = FileOperations.trash(paths, sets: sets)
            Activity.set("idle")
            DispatchQueue.main.async {
                guard let me = self else { return }
                if !r.done.isEmpty { me.registerUndoTrash(r.done) }
                if !r.failures.isEmpty {
                    me.showProblem("Some items were not moved to the Trash",
                                   r.failures.joined(separator: "\n") + "\n\nThey are still where they were.")
                }
                me.reloadAfterOp(Set(paths.map { Paths.parent($0) }))
                if !r.noTrash.isEmpty { me.confirmPermanentDelete(r.noTrash) }
            }
        }
    }

    /// Shares without a Trash: Finder's choice - delete immediately, after an explicit warning.
    private func confirmPermanentDelete(_ paths: [String]) {
        guard let w = window else { return }
        let a = NSAlert()
        let n = paths.count
        a.alertStyle = .critical
        a.messageText = n == 1 ? "Delete \"\(Paths.name(paths[0]))\" immediately?"
                               : "Delete these \(n) items immediately?"
        var names = paths.prefix(8).map { Paths.name($0) }.joined(separator: "\n")
        if n > 8 { names += "\n...and \(n - 8) more" }
        a.informativeText = "This share has no Trash. The items will be deleted for good. You can't undo this action.\n\n" + names
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.last?.keyEquivalent = "\u{1b}"
        a.buttons.first?.keyEquivalent = ""          // Return must not delete
        a.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let me = self else {
                Log.info("permanent delete cancelled for \(n) item(s)")
                return
            }
            me.opsQueue.async {
                let failures = FileOperations.deletePermanently(paths)
                DispatchQueue.main.async {
                    if !failures.isEmpty { me.showProblem("Some items could not be deleted", failures.joined(separator: "\n")) }
                    me.reloadAfterOp(Set(paths.map { Paths.parent($0) }))
                }
            }
        }
    }

    private func registerUndoTrash(_ items: [FileOperations.Trashed]) {
        guard let um = window?.undoManager else { return }
        um.registerUndo(withTarget: self) { me in
            // Redo = trash exactly these items again (the set was already expanded).
            um.registerUndo(withTarget: me) { me2 in me2.performTrash(items.map { $0.original }, sets: false) }
            um.setActionName("Move to Trash")
            me.opsQueue.async {
                let failures = FileOperations.putBack(items)
                DispatchQueue.main.async {
                    if !failures.isEmpty { me.showProblem("Some items could not be put back", failures.joined(separator: "\n")) }
                    me.reloadAfterOp(Set(items.map { Paths.parent($0.original) }), select: items.map { Paths.name($0.original) })
                }
            }
        }
        um.setActionName("Move to Trash")
    }

    // MARK: Copy / paste / duplicate (the transfer engine: TransferController)

    /// Cmd-C: the selected items (with their set members) go on the clipboard as files, so they
    /// paste in PhotoLab and in Finder.
    @objc func copy(_ sender: Any?) {
        let paths = list.withSetMembers(list.selectedEntries())
        guard !paths.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        Log.info("clipboard: \(paths.count) item(s)")
    }

    @objc func paste(_ sender: Any?) { pasteFiles(kind: .copy) }

    /// Cmd-Option-V (Finder's "Move Item Here").
    @objc func pasteMoving(_ sender: Any?) { pasteFiles(kind: .move) }

    private static var clipboardFiles: [String] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { $0.path }
    }

    /// Paste goes into the folder of the selection (an expanded subfolder's row pastes there), or
    /// into the window's folder when nothing is selected.
    private func pasteFiles(kind: TransferKind) {
        let paths = BrowserWindowController.clipboardFiles
        guard !paths.isEmpty else { NSSound.beep(); return }
        let dest = list.selectedEntries().first.map { Paths.parent($0.path) } ?? currentPath
        TransferController.shared.start(paths, to: dest, kind: kind, from: self)
    }

    /// Cmd-D: copies next to the originals ("IMG_1 copy.CR3"; a set stays a set).
    @objc func duplicate(_ sender: Any?) {
        let sel = list.selectedEntries()
        guard let first = sel.first else { NSSound.beep(); return }
        let dir = Paths.parent(first.path)
        let paths = list.withSetMembers(sel.filter { Paths.parent($0.path) == dir })
        TransferController.shared.start(paths, to: dir, kind: .copy, from: self)
    }

    /// Undo of a copy: the new copies go to the Trash (on a share without one, after the usual
    /// confirmation). Redo puts them back.
    func registerUndoCopy(_ created: [String], name: String) {
        guard let um = window?.undoManager, !created.isEmpty else { return }
        um.registerUndo(withTarget: self) { me in me.performTrash(created, sets: false) }
        um.setActionName(name)
    }

    @objc func newFolder(_ sender: Any?) {
        let dir = currentPath
        opsQueue.async { [weak self] in
            let r = FileOperations.newFolder(in: dir)
            DispatchQueue.main.async {
                guard let me = self else { return }
                switch r {
                case .failure(let f): me.showProblem("No new folder", f.message)
                case .success(let p):
                    if let um = me.window?.undoManager {
                        um.registerUndo(withTarget: me) { me2 in
                            me2.opsQueue.async {
                                let problem = FileOperations.removeNewFolder(p)
                                DispatchQueue.main.async {
                                    if let t = problem { me2.showProblem("The new folder was kept", t) }
                                    me2.reloadAfterOp([dir])
                                }
                            }
                        }
                        um.setActionName("New Folder")
                    }
                    me.list.pendingEdit = p
                    me.reloadAfterOp([dir], select: [Paths.name(p)])
                }
            }
        }
    }

    // MARK: Expanded subfolders

    /// List an expanded subfolder in the background (same cache and reader as the main listing).
    private func loadChildren(_ path: String) {
        let gen = folderGeneration.current
        let isNetwork = Volumes.isNetwork(path)
        listQueue.async { [weak self] in
            let started = Date()
            let mtime = ListingCache.folderMtime(path)
            var listing: FolderListing
            var cached = false
            if let c = ListingCache.shared.lookup(path, currentMtime: mtime) {
                listing = c
                cached = true
            } else {
                listing = DirectoryReader.read(path, isCancelled: { [weak self] in self?.folderGeneration.current != gen })
                if !listing.cancelled { ListingCache.shared.store(path, listing: listing, folderMtime: mtime) }
            }
            if listing.cancelled { return }
            let ms = Date().timeIntervalSince(started) * 1000
            if !cached {
                if listing.error == 0 {
                    Stats.noteListing(network: isNetwork, ms: ms, method: listing.method, entries: listing.entries.count)
                }
                Log.info(String(format: "expand %@ %ld entries %.1f ms via %@%@", path, listing.entries.count, ms,
                                listing.method, listing.error != 0 ? " error \(listing.error) \(listing.errorText)" : ""))
            }
            let result = listing
            DispatchQueue.main.async {
                guard let me = self, me.folderGeneration.current == gen else { return }
                me.list.setChildren(path: path, entries: result.entries,
                                    error: result.error != 0 ? result.errorText : nil)
            }
        }
    }

    /// One watcher per expanded subfolder; an event re-lists just that folder.
    private func watchExpanded(_ paths: Set<String>) {
        for (p, w) in childWatchers where !paths.contains(p) {
            w.stop()
            childWatchers.removeValue(forKey: p)
        }
        for p in paths where childWatchers[p] == nil {
            childWatchers[p] = FolderWatcher(path: p) { [weak self] change in
                guard let me = self else { return }
                Stats.noteWatch(gone: change == .gone)
                ListingCache.shared.invalidate(p)
                if change == .contents { me.list.relist(path: p) }
                // .gone: the parent's watcher sees it disappear and re-lists the parent.
            }
        }
    }

    @objc func toggleHidden(_ sender: Any?) {
        BrowserWindowController.showHidden = !BrowserWindowController.showHidden
        for c in BrowserWindowController.open { c.reapply() }
    }

    @objc func toggleFoldersFirst(_ sender: Any?) {
        BrowserWindowController.foldersFirst = !BrowserWindowController.foldersFirst
        for c in BrowserWindowController.open { c.reapply() }
    }

    private func reapply() {
        if let l = lastListing, let p = lastListingPath { apply(l, path: p, cached: fromCache, select: nil) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:))?: return !backStack.isEmpty
        case #selector(goForward(_:))?: return !forwardStack.isEmpty
        case #selector(goEnclosingFolder(_:))?: return currentPath != "/"
        case #selector(openSelected(_:))?: return list.selectionCount > 0
        case #selector(renameSelected(_:))?: return list.selectionCount == 1
        case #selector(moveToTrash(_:))?: return list.selectionCount > 0
        case #selector(BrowserWindowController.copy(_:))?: return list.selectionCount > 0
        case #selector(duplicate(_:))?: return list.selectionCount > 0
        case #selector(paste(_:))?, #selector(pasteMoving(_:))?:
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        case #selector(toggleHidden(_:))?:
            item.state = BrowserWindowController.showHidden ? .on : .off
            return true
        case #selector(toggleSidebar(_:))?:
            item.title = sidebarShown ? "Hide Sidebar" : "Show Sidebar"
            return true
        case #selector(toggleFoldersFirst(_:))?:
            item.state = BrowserWindowController.foldersFirst ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: Split view (sidebar width: 160 by default, remembered, snaps to 160)

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 110
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return min(420, splitView.bounds.width - 300)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let snap = BrowserWindowController.defaultSidebarWidth
        return abs(proposedPosition - snap) <= 10 ? snap : proposedPosition
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard sidebarShown, !sidebar.scroll.isHidden, window?.inLiveResize == false else { return }
        let w = sidebar.scroll.frame.width
        if w >= 100 { BrowserWindowController.sidebarWidth = w }
    }

    // MARK: Notifications / window

    @objc private func volumesChanged(_ n: Notification) {
        sidebar.reload()
        sidebar.reflect(path: currentPath)
        rebuildPathBar()
    }

    @objc private func brainChanged(_ n: Notification) {
        brainLabel.stringValue = BrowserWindowController.brainText
    }

    func windowWillClose(_ notification: Notification) {
        // The last window closed decides the sidebar state of the next launch.
        BrowserWindowController.sidebarVisible = sidebarShown
        watcher?.stop()
        watcher = nil
        watchExpanded([])
        _ = generation.next()
        NotificationCenter.default.removeObserver(self)
        BrowserWindowController.open.removeAll { $0 === self }
    }
}
