// ContactSheet.swift
// The contact sheet: a hand-drawn grid of tiles (thumbnail, name, extensions). Only tiles on
// screen are drawn and asked for; thumbnails come from Core/Thumbnails (background, cached).
// One tile per set while sets are on (same rule as the list). Selection, keys and drag and drop
// follow the list: click / Cmd-click / Shift-click, arrows (Shift extends), Cmd-A; double-click,
// Cmd-E, Cmd-O, Cmd-Down open; Return or M renames; Backspace trashes; Space on a folder opens it.
// Display: each tile is a Core Animation layer (thumbnail, name, extensions) - scrolling moves
// layers on the GPU and the GPU scales the pictures; nothing is redrawn while scrolling.

import AppKit

final class SheetItem {
    let entry: FileEntry
    let members: [FileEntry]
    let request: ThumbRequest?

    init(entry: FileEntry, members: [FileEntry]) {
        self.entry = entry
        self.members = members
        if entry.isDirectory && !entry.isPackage {
            request = nil
        } else {
            // A set shows its JPG/HEIC (the delivered look, a cheaper read), else the file itself.
            let pic = members.first { ["jpg", "jpeg", "heic", "heif"].contains($0.ext) } ?? entry
            let size = members.count > 1 ? pic.size : entry.size
            request = ThumbRequest(source: pic.path, size: size, modified: pic.modified)
        }
    }

    var isSet: Bool { return members.count > 1 }
    var isFolder: Bool { return entry.isDirectory && !entry.isPackage }
    var displayName: String { return isSet ? FileOperations.split(entry.name).stem : entry.name }
    var extText: String {
        if isFolder { return "" }
        return isSet ? FileSets.extLabel(members) : entry.ext.uppercased()
    }
}

final class ContactSheetController: NSObject {
    let view = NSView()
    let scroll = NSScrollView()
    let grid = ContactSheetView()
    private let message = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    var showHidden = false
    var foldersOnly = false
    var foldersFirst = true
    var filterText = ""
    var rootPath = "/" { didSet { grid.rootPath = rootPath } }

    static var tileSize: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "sheetTileSize"); return v >= 80 ? CGFloat(v) : 160 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "sheetTileSize") }
    }

    override init() {
        super.init()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.controlBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        message.alignment = .center
        message.textColor = NSColor.secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        view.addSubview(message)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor), message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
        ])
        grid.tile = ContactSheetController.tileSize
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.grid.scheduleThumbRequest()
        }
        nc.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.grid.relayout()
        }
        nc.addObserver(forName: .thumbnailsReady, object: nil, queue: .main) { [weak self] n in
            if let keys = n.userInfo?["keys"] as? [String] { self?.grid.thumbnailsArrived(keys) }
        }
    }

    func setTileSize(_ s: CGFloat) {
        if s == grid.tile { return }
        ContactSheetController.tileSize = s
        grid.tile = s
        grid.relayout()
    }

    func setEntries(_ entries: [FileEntry], select: [String]?) {
        var v = showHidden ? entries : entries.filter { !$0.isHidden }
        if foldersOnly { v = v.filter { $0.isDirectory && !$0.isPackage } }
        let rows = FileOperations.useSets ? FileSets.rows(v) : v.map { SetRow(entry: $0, members: [$0]) }
        var members: [String: [FileEntry]] = [:]
        for r in rows { members[r.entry.path] = r.members }
        let sorted = EntrySort.sort(rows.map { $0.entry }, by: .name, ascending: true, foldersFirst: foldersFirst)
        var items = sorted.map { SheetItem(entry: $0, members: members[$0.path] ?? [$0]) }
        if !filterText.isEmpty {
            items = items.filter { it in it.members.contains { $0.name.localizedCaseInsensitiveContains(filterText) } || it.entry.name.localizedCaseInsensitiveContains(filterText) }
        }
        grid.setItems(items, select: select)
    }

    func showMessage(_ text: String?, spinning: Bool = false) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func selectedEntries() -> [FileEntry] { return grid.selectedItems.map { $0.entry } }
    var selectionCount: Int { return grid.selection.count }

    /// Paths of the selection with every file of its sets.
    func withSetMembers() -> [String] {
        var out: [String] = []
        for it in grid.selectedItems { out += it.isSet ? it.members.map { $0.path } : [it.entry.path] }
        return out
    }

    var shownCounts: (rows: Int, sets: Int, total: Int) {
        let items = grid.items
        return (items.count, items.filter { $0.isSet }.count, items.reduce(0) { $0 + max(1, $1.members.count) })
    }

    func stop() { Thumbnails.shared.release(owner: grid) }
}

final class ContactSheetView: NSView, NSDraggingSource {
    private(set) var items: [SheetItem] = []
    private var indexByKey: [String: [Int]] = [:]
    private(set) var selection = Set<Int>()
    private var anchor: Int?
    private var cursor: Int?
    var tile: CGFloat = 160
    var rootPath = "/"
    private var cols = 1
    private var cellW: CGFloat = 176, cellH: CGFloat = 200, marginX: CGFloat = 8
    private var dropTarget: Int?
    private var downPoint: NSPoint?
    private var downIndex: Int?
    private var lastTyped = Date.distantPast
    // Tiles are Core Animation layers: scrolling moves layers on the GPU, nothing is redrawn.
    private var tileLayers: [Int: TileLayer] = [:]
    private var spareLayers: [TileLayer] = []
    /// Keys whose thumbnail (or "no picture") is known: the background progress.
    private(set) var doneKeys = Set<String>()
    var onThumbProgress: ((Int, Int) -> Void)?

    var onOpen: (([FileEntry]) -> Void)?
    var onTrash: (() -> Void)?
    var onRename: (() -> Void)?
    var onSpace: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onDrop: (([String], String, TransferKind) -> Void)?
    var onMenu: (() -> NSMenu?)?

    override var isFlipped: Bool { return true }
    override var acceptsFirstResponder: Bool { return true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never           // the view itself draws nothing: tiles are layers
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        registerForDraggedTypes([.fileURL])
    }

    override var wantsUpdateLayer: Bool { return true }
    override func updateLayer() { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }

    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedItems: [SheetItem] { return selection.sorted().compactMap { $0 < items.count ? items[$0] : nil } }

    func setItems(_ new: [SheetItem], select: [String]?) {
        let keepPaths: Set<String>
        if let names = select { keepPaths = Set(new.filter { it in names.contains(it.entry.name) || it.members.contains { names.contains($0.name) } }.map { $0.entry.path }) }
        else { keepPaths = Set(selectedItems.map { $0.entry.path }) }
        let cursorPath = cursor.flatMap { $0 < items.count ? items[$0].entry.path : nil }
        items = new
        for (_, t) in tileLayers { t.index = -1 }
        indexByKey = [:]
        for (i, it) in items.enumerated() { if let k = it.request?.key { indexByKey[k, default: []].append(i) } }
        selection = Set(items.indices.filter { keepPaths.contains(items[$0].entry.path) })
        cursor = items.indices.first { items[$0].entry.path == cursorPath } ?? selection.min()
        anchor = cursor
        doneKeys = Set(indexByKey.keys.filter { Thumbnails.shared.image($0) != nil || Thumbnails.shared.hasNoPicture($0) })
        relayout()
        reportProgress()
        if select != nil, let first = selection.min() { scrollToVisible(rect(first)) }
        onSelectionChange?()
    }

    // MARK: Layout

    func relayout() {
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        cellW = tile + 16
        cellH = tile + 40
        cols = max(1, Int((width - 8) / cellW))
        marginX = max(4, (width - CGFloat(cols) * cellW) / 2)
        let rows = (items.count + cols - 1) / cols
        let h = max(CGFloat(rows) * cellH + 8, enclosingScrollView?.contentSize.height ?? 0)
        setFrameSize(NSSize(width: width, height: h))
        for (_, t) in tileLayers { t.index = -1 }          // positions changed: re-place every tile
        updateTiles()
        scheduleThumbRequest()
    }

    func rect(_ i: Int) -> NSRect {
        return NSRect(x: marginX + CGFloat(i % cols) * cellW, y: 4 + CGFloat(i / cols) * cellH, width: cellW, height: cellH)
    }

    private func imageRect(_ i: Int) -> NSRect {
        let r = rect(i)
        return NSRect(x: r.minX + 8, y: r.minY + 6, width: tile, height: tile)
    }

    func index(at p: NSPoint) -> Int? {
        let c = Int((p.x - marginX) / cellW), r = Int((p.y - 4) / cellH)
        guard p.x >= marginX, c >= 0, c < cols, r >= 0 else { return nil }
        let i = r * cols + c
        return i < items.count ? i : nil
    }

    private func visibleRange(extra: CGFloat = 0) -> Range<Int> {
        guard !items.isEmpty else { return 0..<0 }
        let vr = visibleRect.insetBy(dx: 0, dy: -extra)
        let first = max(0, Int((vr.minY - 4) / cellH)) * cols
        let last = min(items.count, (Int((vr.maxY - 4) / cellH) + 1) * cols)
        return first < last ? first..<last : 0..<0
    }

    // MARK: Thumbnails

    private var thumbPending = false
    private var retryCount = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { relayout() }
    }

    /// Tiles on screen first, then a screen ahead.
    func scheduleThumbRequest() {
        if thumbPending { return }
        thumbPending = true
        DispatchQueue.main.async { [weak self] in
            guard let me = self else { return }
            me.thumbPending = false
            // Not on screen yet (new window, view just switched): try again shortly, so the
            // thumbnails start without a scroll.
            guard me.window != nil, !me.isHiddenOrHasHiddenAncestor, me.visibleRect.height > 0 else {
                if !me.items.isEmpty && me.retryCount < 20 {
                    me.retryCount += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { me.scheduleThumbRequest() }
                }
                return
            }
            me.retryCount = 0
            let now = me.visibleRange(), ahead = me.visibleRange(extra: me.visibleRect.height)
            let order = Array(now) + ahead.filter { !now.contains($0) }
            // The rest of the folder, nearest first, on the low-priority track.
            let center = now.isEmpty ? 0 : now.lowerBound
            let rest = me.items.indices.filter { !ahead.contains($0) }.sorted { abs($0 - center) < abs($1 - center) }
            Thumbnails.shared.request(order.compactMap { me.items[$0].request }, background: rest.compactMap { me.items[$0].request }, owner: me)
            me.updateTiles()
        }
    }

    private var iconCache: [String: NSImage] = [:]
    private func icon(for it: SheetItem) -> NSImage? {
        let k = it.isFolder ? "/folder" : (it.entry.ext.isEmpty ? "public.data" : it.entry.ext)
        if let i = iconCache[k] { return i }
        let i = it.isFolder ? NSImage(named: NSImage.folderName) : NSWorkspace.shared.icon(forFileType: k)
        iconCache[k] = i
        return i
    }

    func thumbnailsArrived(_ keys: [String]) {
        var changed = false
        for k in keys where indexByKey[k] != nil {
            if doneKeys.insert(k).inserted { changed = true }
            for i in indexByKey[k] ?? [] { if let t = tileLayers[i] { configure(t, i, force: true) } }
        }
        if changed { reportProgress() }
    }

    private var thumbTotal: Int { return indexByKey.count }

    private func reportProgress() {
        onThumbProgress?(doneKeys.count, thumbTotal)
    }

    // MARK: Tiles (layers)

    private static let nameFont = NSFont.systemFont(ofSize: 11)
    private static let extFont = NSFont.systemFont(ofSize: 9)

    /// Give every tile within a screen of the visible area a layer, recycle the rest. Cheap:
    /// only frames and contents are set, and only when they change.
    func updateTiles() {
        guard let root = layer else { return }
        let t0 = Date()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let range = visibleRange(extra: visibleRect.height)
        for (i, t) in tileLayers where !range.contains(i) {
            t.isHidden = true
            spareLayers.append(t)
            tileLayers.removeValue(forKey: i)
        }
        let scale = window?.backingScaleFactor ?? 2
        for i in range {
            let t: TileLayer
            if let have = tileLayers[i] { t = have } else {
                t = spareLayers.popLast() ?? TileLayer()
                if t.superlayer == nil { root.addSublayer(t) }
                t.isHidden = false
                t.index = -1
                tileLayers[i] = t
            }
            t.setScale(scale)
            configure(t, i, force: false)
        }
        CATransaction.commit()
        Stats.noteSheetDraw(Date().timeIntervalSince(t0) * 1000)
    }

    private func configure(_ t: TileLayer, _ i: Int, force: Bool) {
        guard i < items.count else { return }
        let it = items[i]
        let r = rect(i)
        let newItem = t.index != i || t.path != it.entry.path
        if newItem || t.frame != r {
            t.frame = r
            t.layout(tile: tile)
        }
        if newItem {
            t.index = i
            t.path = it.entry.path
            t.nameLayer.string = it.displayName
            t.extLayer.string = it.extText
            t.image.contents = nil
            t.shownKey = nil
        }
        let sel = selection.contains(i), drop = dropTarget == i
        let bg = sel || drop ? NSColor.alternateSelectedControlColor.withAlphaComponent(drop ? 0.45 : 0.25).cgColor : nil
        if t.backgroundColor != bg { t.backgroundColor = bg }
        if newItem || force || t.shownKey == nil {
            if let k = it.request?.key, let cg = Thumbnails.shared.image(k) {
                if t.shownKey != k {
                    t.image.contents = cg
                    t.image.contentsGravity = .resizeAspect
                    t.image.borderWidth = 0
                    t.shownKey = k
                }
            } else if it.request == nil || Thumbnails.shared.hasNoPicture(it.request!.key) {
                if t.shownKey != "icon" {
                    t.image.contents = icon(for: it)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    t.image.contentsGravity = .center
                    t.shownKey = "icon"
                }
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateTiles()
    }

    // MARK: Selection

    private func select(_ set: Set<Int>, cursor c: Int?) {
        selection = set
        cursor = c
        updateTiles()
        if let c = c { scrollToVisible(rect(c)) }
        onSelectionChange?()
    }

    /// Arrow keys in the preview: the next/previous tile.
    func step(_ d: Int) {
        guard !items.isEmpty else { return }
        let n = max(0, min(items.count - 1, (cursor ?? -1) + d))
        anchor = n
        select([n], cursor: n)
    }

    func neighbours(of path: String, before: Int, after: Int) -> [FileEntry] {
        guard let at = items.firstIndex(where: { $0.entry.path == path }) else { return [] }
        let files = { (r: Range<Int>) in r.map { self.items[$0] }.filter { !$0.isFolder }.map { self.picture($0) } }
        return files(min(items.count, at + 1)..<min(items.count, at + 1 + after)) + files(max(0, at - before)..<at).reversed()
    }

    func picture(_ it: SheetItem) -> FileEntry {
        return it.members.first { ["jpg", "jpeg", "heic", "heif"].contains($0.ext) } ?? it.entry
    }

    override func selectAll(_ sender: Any?) { select(Set(items.indices), cursor: cursor) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        let mods = event.modifierFlags
        downPoint = p
        downIndex = i
        if event.clickCount == 2, let i = i {
            select(selection.contains(i) ? selection : [i], cursor: i)
            onOpen?(selectedItems.map { $0.entry })
            return
        }
        guard let idx = i else {
            if !mods.contains(.command) && !mods.contains(.shift) { select([], cursor: nil) }
            return
        }
        if mods.contains(.command) {
            var s = selection
            if s.contains(idx) { s.remove(idx) } else { s.insert(idx) }
            anchor = idx
            select(s, cursor: idx)
        } else if mods.contains(.shift), let a = anchor ?? cursor {
            select(Set(min(a, idx)...max(a, idx)), cursor: idx)
        } else if !selection.contains(idx) {
            anchor = idx
            select([idx], cursor: idx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A click on an already selected tile (no drag) selects just that tile.
        let mods = event.modifierFlags
        if let i = downIndex, downPoint != nil, !mods.contains(.command), !mods.contains(.shift), event.clickCount == 1, selection.count > 1 {
            anchor = i
            select([i], cursor: i)
        }
        downPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let i = downIndex, selection.contains(i) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downPoint = nil
        var dragItems: [NSDraggingItem] = []
        for idx in selection.sorted() {
            let it = items[idx]
            let paths = it.isSet ? it.members : [it.entry]
            for (n, e) in paths.enumerated() {
                let d = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: e.path, isDirectory: e.isDirectory))
                var image: NSImage?
                if n == 0, let k = it.request?.key, let cg = Thumbnails.shared.image(k) { image = NSImage(cgImage: cg, size: .zero) }
                else if n == 0 { image = it.isFolder ? NSImage(named: NSImage.folderName) : NSWorkspace.shared.icon(forFileType: it.entry.ext) }
                d.setDraggingFrame(imageRect(idx), contents: image)
                dragItems.append(d)
            }
        }
        Activity.set("drag: out")
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? [.copy, .move] : [.copy, .move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Activity.set("idle")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let i = index(at: convert(event.locationInWindow, from: nil)), !selection.contains(i) {
            anchor = i
            select([i], cursor: i)
        }
        return onMenu?()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 123, 124, 125, 126:                                   // left right down up
            guard !items.isEmpty else { return }
            let c = cursor ?? -1
            var n: Int
            switch event.keyCode {
            case 123: n = c - 1
            case 124: n = c + 1
            case 125: n = c < 0 ? 0 : c + cols
            default: n = c - cols
            }
            n = max(0, min(items.count - 1, n))
            if mods.contains(.shift), let a = anchor { select(Set(min(a, n)...max(a, n)), cursor: n) }
            else if mods.contains(.command) { super.keyDown(with: event) }       // Cmd-Up / Cmd-Down: menus
            else { anchor = n; select([n], cursor: n) }
        // (`case a, b where x` would apply x to b only: plain checks instead.)
        case 36, 76:                                               // Return, Enter: rename (like the list)
            if mods.isEmpty { onRename?() } else { super.keyDown(with: event) }
        case 51, 117:                                              // Backspace, Delete: Trash
            if mods.isEmpty || mods == [.command] { onTrash?() } else { super.keyDown(with: event) }
        case 49:                                                   // Space
            if mods.isEmpty { onSpace?() } else { super.keyDown(with: event) }
        default:
            if mods == [.command] && chars == "e" { onOpen?(selectedItems.map { $0.entry }); return }   // Cmd-E (Cmd-O, Cmd-Down: menu)
            if mods.isEmpty && chars == "m" && Date().timeIntervalSince(lastTyped) > 1 { onRename?(); return }
            if mods.isEmpty, let ch = chars.first, ch.isLetter || ch.isNumber { lastTyped = Date(); typeSelect(String(ch)); return }
            super.keyDown(with: event)
        }
    }

    /// Type a letter: the next tile whose name starts with it (same letter again cycles), or the
    /// nearest one when none does (like the list).
    private func typeSelect(_ s: String) {
        guard !items.isEmpty else { return }
        let start = (cursor ?? -1) + 1
        for k in 0..<items.count {
            let i = (start + k) % items.count
            if items[i].displayName.range(of: s, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil {
                anchor = i; select([i], cursor: i); return
            }
        }
        var best: Int?
        for (i, it) in items.enumerated() where it.displayName.localizedStandardCompare(s) == .orderedAscending {
            if best == nil || it.displayName.localizedStandardCompare(items[best!].displayName) == .orderedDescending { best = i }
        }
        let i = best ?? 0
        anchor = i; select([i], cursor: i)
    }

    // MARK: Drop

    private func droppedPaths(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { $0.path }
    }

    private func dropDestination(_ info: NSDraggingInfo) -> (dest: String, tile: Int?) {
        let p = convert(info.draggingLocation, from: nil)
        if let i = index(at: p), items[i].isFolder { return (items[i].entry.path, i) }
        return (rootPath, nil)
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

    private func evaluate(_ info: NSDraggingInfo) -> NSDragOperation {
        let paths = droppedPaths(info)
        let (dest, tile) = dropDestination(info)
        let target = paths.contains(dest) ? nil : tile
        if target != dropTarget { dropTarget = target; updateTiles() }
        guard !paths.isEmpty, !paths.contains(dest), let kind = dropKind(info, paths, dest) else { return [] }
        if kind == .move && paths.allSatisfy({ Paths.parent($0) == dest }) { return [] }
        return kind == .copy ? .copy : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { return Activity.during("drag: hover") { evaluate(sender) } }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { return Activity.during("drag: hover") { evaluate(sender) } }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = nil; updateTiles() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget = nil
        updateTiles()
        let paths = droppedPaths(sender)
        let (dest, _) = dropDestination(sender)
        guard !paths.isEmpty, !paths.contains(dest), let kind = dropKind(sender, paths, dest) else { return false }
        Log.info("drop on sheet: \(paths.count) item(s), \(kind.rawValue) -> \(dest)")
        onDrop?(paths, dest, kind)
        return true
    }
}


/// One tile: selection background (the layer itself), picture, name, extensions.
final class TileLayer: CALayer {
    let image = CALayer()
    let nameLayer = CATextLayer()
    let extLayer = CATextLayer()
    var index = -1
    var path = ""
    var shownKey: String?

    override init() {
        super.init()
        cornerRadius = 6
        image.minificationFilter = .trilinear
        image.magnificationFilter = .linear
        for t in [nameLayer, extLayer] {
            t.alignmentMode = .center
            t.truncationMode = .middle
            t.isWrapped = false
        }
        nameLayer.font = NSFont.systemFont(ofSize: 11)
        nameLayer.fontSize = 11
        nameLayer.foregroundColor = NSColor.labelColor.cgColor
        extLayer.font = NSFont.systemFont(ofSize: 9)
        extLayer.fontSize = 9
        extLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        for l in [image, nameLayer, extLayer] { addSublayer(l) }
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        for l in [image, nameLayer, extLayer] as [CALayer] { l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull()] }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setScale(_ s: CGFloat) {
        if contentsScale != s { for l in [self, image, nameLayer, extLayer] as [CALayer] { l.contentsScale = s } }
    }

    /// Geometry inside the tile (the hosting view is flipped: y grows downwards).
    func layout(tile: CGFloat) {
        let w = bounds.width
        image.frame = CGRect(x: 8, y: 6, width: tile, height: tile)
        nameLayer.frame = CGRect(x: 4, y: 6 + tile + 4, width: w - 8, height: 15)
        extLayer.frame = CGRect(x: 4, y: 6 + tile + 19, width: w - 8, height: 13)
    }
}
