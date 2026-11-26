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
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static var open: [BrowserWindowController] = []
    static var brainText = "Brain: not started"

    private(set) var currentPath: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private let generation = Generation()
    private let listQueue = DispatchQueue(label: "photolab.list", qos: .userInitiated, attributes: .concurrent)
    private var watcher: FolderWatcher?
    private var lastListing: FolderListing?
    private var fromCache = false

    private let sidebar = SidebarController()
    private let list = FileListController()
    private let pathBar = NSStackView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
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
        brainLabel.stringValue = BrowserWindowController.brainText
        navigate(to: path, record: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildUI(in w: NSWindow) {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "BrowserSplit"

        let side = sidebar.scroll
        side.translatesAutoresizingMaskIntoConstraints = false
        side.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let sideWidth = side.widthAnchor.constraint(equalToConstant: 190)
        sideWidth.priority = NSLayoutConstraint.Priority(rawValue: 200)
        sideWidth.isActive = true
        sidebar.onSelect = { [weak self] p in self?.navigate(to: p) }

        let right = NSView()
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

        pathBar.orientation = .horizontal
        pathBar.spacing = 0
        pathBar.alignment = .centerY
        pathBar.setHuggingPriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)
        let top = NSStackView(views: [backButton, forwardButton, upButton, pathBar])
        top.orientation = .horizontal
        top.spacing = 6
        top.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        list.foldersFirst = BrowserWindowController.foldersFirst
        list.onOpen = { [weak self] sel in self?.open(sel) }
        list.onSelectionChange = { [weak self] in self?.updateStatus() }

        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        brainLabel.textColor = NSColor.secondaryLabelColor
        brainLabel.font = NSFont.systemFont(ofSize: 11)
        brainLabel.alignment = .right
        let bottom = NSStackView(views: [statusLabel, brainLabel])
        bottom.orientation = .horizontal
        bottom.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 4, right: 10)
        statusLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)

        for v in [top, list.scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: right.topAnchor),
            top.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            list.scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            list.scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            list.scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            list.scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: right.bottomAnchor),
        ])
        split.addSubview(side)
        split.addSubview(right)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 0)
        w.contentView = split
        w.initialFirstResponder = list.table
    }

    // MARK: Navigation

    func navigate(to path: String, record: Bool = true, select: [String]? = nil) {
        if record && path != currentPath {
            backStack.append(currentPath)
            forwardStack.removeAll()
        }
        currentPath = path
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
        load(select: select ?? [], useCache: true)
    }

    /// List the current folder in the background. `select` nil keeps the current selection.
    private func load(select: [String]?, useCache: Bool) {
        let gen = generation.next()
        let path = currentPath
        let started = Date()
        // A placeholder only if the listing takes noticeable time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let me = self, me.generation.current == gen, me.lastListingPath != path else { return }
            me.list.setEntries([], select: [])
            me.list.showMessage("Reading \(Paths.name(path))...")
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
            } else {
                listing = DirectoryReader.read(path, isCancelled: { [weak me] in me?.generation.current != gen })
                if !listing.cancelled { ListingCache.shared.store(path, listing: listing, folderMtime: mtime) }
            }
            Activity.set("idle")
            if listing.cancelled { return }
            let ms = Date().timeIntervalSince(started) * 1000
            if !cached && listing.error == 0 {
                Stats.noteListing(network: isNetwork, ms: ms, method: listing.method)
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
        lastListing = listing
        lastListingPath = path
        fromCache = cached
        let showHidden = BrowserWindowController.showHidden
        let visible = showHidden ? listing.entries : listing.entries.filter { !$0.isHidden }
        list.foldersFirst = BrowserWindowController.foldersFirst
        list.setEntries(visible, select: select)
        if listing.error != 0 {
            list.showMessage("Can't open this folder: \(listing.errorText) (E-LIST-\(listing.error))")
        } else if visible.isEmpty {
            list.showMessage(listing.entries.isEmpty ? "Empty folder" : "Only hidden items (Cmd-Shift-. shows them)")
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
        let sel = list.table.selectedRowIndexes.count
        if sel > 0 { parts.append("\(sel) selected") }
        parts.append(fromCache ? "from memory" : String(format: "%@ %.0f ms", l.method, l.milliseconds))
        if !l.problems.isEmpty { parts.append("\(l.problems.count) unreadable") }
        statusLabel.stringValue = parts.joined(separator: "  \u{00B7}  ")
    }

    private func rebuildPathBar() {
        for v in pathBar.arrangedSubviews { pathBar.removeArrangedSubview(v); v.removeFromSuperview() }
        let vol = Volumes.volume(for: currentPath)
        let root = vol?.mountPoint ?? "/"
        let chain = Paths.ancestry(currentPath).filter { $0 == root || $0.hasPrefix(root == "/" ? "/" : root + "/") }
        for (i, p) in chain.enumerated() {
            if i > 0 {
                let sep = NSTextField(labelWithString: "\u{203A}")
                sep.textColor = NSColor.tertiaryLabelColor
                pathBar.addArrangedSubview(sep)
            }
            let title = p == root ? (vol?.displayName ?? "/") : Paths.name(p)
            let b = NSButton(title: title, target: self, action: #selector(pathClicked(_:)))
            b.bezelStyle = .recessed
            b.isBordered = false
            b.identifier = NSUserInterfaceItemIdentifier(p)
            b.lineBreakMode = .byTruncatingMiddle
            b.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 200), for: .horizontal)
            if i == chain.count - 1 { b.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
            pathBar.addArrangedSubview(b)
        }
    }

    @objc private func pathClicked(_ sender: NSButton) {
        guard let p = sender.identifier?.rawValue, p != currentPath else { return }
        let child = Paths.ancestry(currentPath).first { Paths.parent($0) == p && $0 != p }
        navigate(to: p, select: child.map { [Paths.name($0)] })
    }

    private func watchFired(_ change: FolderWatcher.Change, for path: String) {
        guard path == currentPath else { return }
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
        case #selector(openSelected(_:))?: return list.table.selectedRowIndexes.count > 0
        case #selector(toggleHidden(_:))?:
            item.state = BrowserWindowController.showHidden ? .on : .off
            return true
        case #selector(toggleFoldersFirst(_:))?:
            item.state = BrowserWindowController.foldersFirst ? .on : .off
            return true
        default: return true
        }
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
        watcher?.stop()
        watcher = nil
        _ = generation.next()
        NotificationCenter.default.removeObserver(self)
        BrowserWindowController.open.removeAll { $0 === self }
    }
}
