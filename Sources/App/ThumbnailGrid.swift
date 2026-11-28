// ThumbnailGrid.swift
// Thumbnail view, drawn by hand: only the cells on screen are drawn and only their thumbnails are
// loaded (RAW: the embedded camera preview), so it stays fast with thousands of pictures.
// Selection is mirrored into the list, so every command (rename, trash, info, preview...) works the same.
// Drag from a thumbnail to move/copy files (FileDrag rules); drag from empty space to select a range.

import AppKit
import Quartz

final class ThumbnailGrid: NSView {
    // MARK: Data
    private(set) var entries: [FileEntry] = []
    private var indexByPath: [String: Int] = [:]
    /// Image names that have an XMP sidecar next to them (badge).
    /// Pictures (paths) that have an XMP sidecar in their own folder.
    var sidecarPaths: Set<String> = []
    /// 0.16 Include subfolders: pictures come from many folders; each caption names its folder
    /// (relative to this one).
    var folderRoot: String? = nil
    /// Rating / label for badges (photography mode).
    var facts: [String: PhotoFacts] = [:]
    var thumbSize: CGFloat = 160 {
        didSet { relayout(); needsDisplay = true }
    }

    private(set) var selection = IndexSet()
    private var anchor: Int?
    /// 0.18.10: the moving end of a Shift-selection (arrows move from here, not from the selection's edge).
    private var cursor: Int?

    // MARK: Callbacks
    var onSelectionChanged: (([String]) -> Void)?
    var onOpen: ((FileEntry) -> Void)?
    var onSpace: (() -> Void)?
    var onOptionSpace: (() -> Void)?
    var onEscape: (() -> Bool)?
    var onTab: (() -> Bool)?
    var onFocus: (() -> Void)?
    /// Option-click on an item (folders open in a new pane). Returns true if handled.
    var onOptionClick: ((FileEntry) -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
    var onRename: (() -> Void)?
    var onGoUp: (() -> Void)?
    /// Files dropped: (paths, destination folder, move).
    var onDrop: (([String], String, Bool) -> Void)?
    /// Photography mode: keys 0-5 rate the selection.
    var onRate: ((Int) -> Void)?
    var onColorClass: ((Int) -> Void)?
    /// The folder a drop on empty space goes into (nil = no drops, e.g. search results).
    var dropFolder: (() -> String?)?

    // Mouse tracking: drag files from a thumbnail, or drag a selection rectangle from empty space.
    private var downPoint: NSPoint?
    private var downEvent: NSEvent?
    private var downIndex: Int?
    /// Plain click on an item that was already selected: the group stays selected so it can be dragged;
    /// if the mouse comes up without a drag, only that item stays selected (as in Finder).
    private var collapseOnUp: Int?
    private var dragStarted = false
    private var bandStart: NSPoint?
    private var bandRect: NSRect?
    private var bandBase = IndexSet()
    /// Photography mode (not plain thumbnails): dragged pictures take their XMP sidecars along.
    var photoMode = false
    // Drop highlight
    private var dropIndex: Int?
    private var dropOnAll = false
    var contextMenu: (() -> NSMenu?)?

    // MARK: Thumbnails
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = max(400, Prefs.thumbMemoryMB * 4)
        return c
    }()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = Prefs.thumbThreads
        q.qualityOfService = .userInitiated
        return q
    }()
    private var pending = Set<String>()
    /// Latest cached thumbnail per file (any size), for windows that want something to show at once.
    private static var latestKey: [String: String] = [:]

    /// Clear All Disposable Caches (main thread).
    static func clearMemory() {
        cache.removeAllObjects()
        cellCache.removeAllObjects()
        latestKey.removeAll()
    }

    static var memoryCount: Int { return latestKey.count }

    static func cachedThumbnail(for path: String) -> NSImage? {
        guard let k = latestKey[path] else { return nil }
        return cache.object(forKey: NSString(string: k))
    }
    private let wantedLock = NSLock()
    private var wanted = Set<String>()

    private let pad: CGFloat = 10
    /// Names wrap onto up to 3 lines (then are truncated), plus one line of badges.
    private var lineHeight: CGFloat { return ceil(ThemeManager.shared.smallFont.pointSize * 1.3) }
    private var captionHeight: CGFloat { return lineHeight * 4 + 6 }
    private var cellWidth: CGFloat { return thumbSize + 16 }
    private var cellHeight: CGFloat { return thumbSize + 12 + captionHeight }
    private var columns: Int { return max(1, Int((bounds.width - pad) / (cellWidth + pad))) }

    /// Apple's Quick Look (Cmd-Y) asks the focused view for its items.
    weak var quickLook: QuickLookSource?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return quickLook != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLook?.begin(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLook?.end(panel)
    }

    override var isFlipped: Bool { return true }
    override var acceptsFirstResponder: Bool { return true }

    // MARK: Content

    /// The pane is closing (0.17.1): stop the thumbnail reads and every callback into the pane.
    // PhotoLab: live Finder tags in the contact sheet (FSEvents + the 5 s light check on shares).
    private var tagObs: NSObjectProtocol?
    private var tagTimer: Timer?

    private func watchTags() {
        if tagObs != nil { return }
        tagObs = NotificationCenter.default.addObserver(forName: .findTagsRead, object: nil, queue: .main) { [weak self] n in
            guard let s = self, let paths = n.userInfo?["paths"] as? [String] else { return }
            for p in paths { if let i = s.indexByPath[p], i < s.entries.count { s.setNeedsDisplay(s.rect(of: i)) } }
        }
        tagTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let s = self, let w = s.window, w.isVisible, w.occlusionState.contains(.visible),
                let first = s.entries.first, IOLog.isNetworkPath(first.path) else { return }
            let vis = s.visibleRect
            let c = s.columns
            let firstRow = max(0, Int((vis.minY - s.pad) / (s.cellHeight + s.pad)))
            let lastRow = Int((vis.maxY - s.pad) / (s.cellHeight + s.pad))
            let from = min(s.entries.count, firstRow * c), to = min(s.entries.count, (lastRow + 1) * c)
            if from < to { TagCache.shared.recheck(s.entries[from..<to].map { $0.path }) }
        }
    }

    func shutdown() {
        if let o = tagObs { NotificationCenter.default.removeObserver(o); tagObs = nil }
        tagTimer?.invalidate(); tagTimer = nil
        if let o = scrollObserver { NotificationCenter.default.removeObserver(o); scrollObserver = nil }
        queue.cancelAllOperations()
        onSelectionChanged = nil; onOpen = nil; onSpace = nil; onOptionSpace = nil; onEscape = nil
        onTab = nil; onFocus = nil; onOptionClick = nil; onRename = nil
        entries = []
        indexByPath = [:]
        selection = IndexSet()
    }

    func setEntries(_ list0: [FileEntry], selected: [String]) {
        watchTags()
        // 0.18.14: a share's listing taken while files are renamed can name a file twice: shown once.
        var seen = Set<String>()
        let list = list0.filter { seen.insert($0.path).inserted }
        entries = list
        indexByPath = [:]
        for (i, e) in list.enumerated() { indexByPath[e.path] = i }
        selection = IndexSet(selected.compactMap { indexByPath[$0] })
        anchor = selection.first; cursor = anchor
        wantedLock.lock(); wanted.removeAll(); wantedLock.unlock()
        queue.cancelAllOperations()
        pending.removeAll()
        relayout()
        needsDisplay = true
    }

    /// Selection set from outside (the list); no callback.
    func setSelection(paths: [String]) {
        let s = IndexSet(paths.compactMap { indexByPath[$0] })
        if s == selection { return }
        selection = s
        anchor = s.first; cursor = anchor
        needsDisplay = true
        if let f = s.first { scrollTo(f) }
    }

    var selectedPaths: [String] { return selection.compactMap { $0 < entries.count ? entries[$0].path : nil } }

    func relayout() {
        guard let clip = superview else { return }
        let rows = (entries.count + columns - 1) / columns
        let h = max(clip.bounds.height, CGFloat(rows) * (cellHeight + pad) + pad)
        if frame.size != NSSize(width: clip.bounds.width, height: h) {
            setFrameSize(NSSize(width: clip.bounds.width, height: h))
        }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        relayout()
    }

    private func rect(of i: Int) -> NSRect {
        let c = columns
        let row = i / c, col = i % c
        let used = CGFloat(c) * cellWidth + CGFloat(c - 1) * pad
        let left = max(pad, (bounds.width - used) / 2)
        return NSRect(x: left + CGFloat(col) * (cellWidth + pad), y: pad + CGFloat(row) * (cellHeight + pad),
                      width: cellWidth, height: cellHeight)
    }

    private func index(at p: NSPoint) -> Int? {
        let c = columns
        let used = CGFloat(c) * cellWidth + CGFloat(c - 1) * pad
        let left = max(pad, (bounds.width - used) / 2)
        let col = Int((p.x - left) / (cellWidth + pad))
        let row = Int((p.y - pad) / (cellHeight + pad))
        if p.x < left || col < 0 || col >= c || row < 0 { return nil }
        let i = row * c + col
        guard i < entries.count, rect(of: i).contains(p) else { return nil }
        return i
    }

    func scrollTo(_ i: Int) {
        guard i >= 0 && i < entries.count else { return }
        scrollToVisible(rect(of: i).insetBy(dx: 0, dy: -pad))
    }

    // MARK: Drawing

    private var pixelBucket: Int {
        let scale = window?.backingScaleFactor ?? 1
        let px = thumbSize * scale
        return Int(min(1024, max(256, (px / 256).rounded(.up) * 256)))
    }

    private func key(_ e: FileEntry) -> String {
        return "\(e.path)|\(e.size)|\(e.modified)|\(pixelBucket)"
    }

    /// 0.17.4: Glass behind the thumbnails - the background is left see-through.
    var glassBehind = false

    // MARK: 0.18.10 ready-drawn cells
    // Each cell (picture, name, badges, selection) is drawn once into a bitmap at the screen's pixel size
    // and kept in memory; drawing the view while scrolling only copies those bitmaps. A cell is drawn
    // again only when something on it changes (its picture arrives, selection, stars, labels, size, theme).

    private static let cellCache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.totalCostLimit = Prefs.thumbMemoryMB * 1_048_576
        return c
    }()

    static func applyMemorySetting() {
        cellCache.totalCostLimit = Prefs.thumbMemoryMB * 1_048_576
        cache.countLimit = max(400, Prefs.thumbMemoryMB * 4)
    }

    private var themeSig = ""

    private func cellKey(_ i: Int, _ e: FileEntry, thumbKey k: String, hasImage: Bool) -> String {
        var key = k + "|" + (hasImage ? "i" : "n") + (selection.contains(i) ? "S" : "-") + "|\(thumbSize)|" + themeSig
        if let f = facts[e.path] { key += "|\(f.rating ?? 99),\(f.label ?? ""),\(f.colorClass ?? 0)" }
        if sidecarPaths.contains(e.path) { key += "|x" }
        if let t = twinBadges[e.path] { key += "|" + t }
        let colors = TagCache.shared.colors(e.path)
        if let c = colors.first { key += "|t\(c)" }
        if folderRoot != nil { key += "|r" }
        if Finish.depth > 0 || Finish.glow > 0 { key += "|f\(Finish.depth),\(Finish.glow)" }
        return key
    }

    override var isOpaque: Bool { return !glassBehind }

    // MARK: PhotoLab tiles (ported from PhotoLab 2's contact sheet)
    // Each cell on screen (and half a screen around it) is a CALayer: its caption, badges and selection
    // in one small ready-drawn bitmap, its picture as a second layer holding the thumbnail itself.
    // Scrolling moves layers on the GPU - nothing is drawn; a thumbnail arriving only sets a layer's
    // picture; a caption is drawn again only when something on it changes. The view draws nothing.

    private final class Tile: CALayer {
        let picture = CALayer()
        var captionKey: NSString?
        var pictureKey: String?
        override init() {
            super.init()
            let none: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                            "hidden": NSNull(), "opacity": NSNull(), "frame": NSNull(), "shadowOpacity": NSNull()]
            actions = none
            picture.actions = none
            picture.contentsGravity = .resize
            addSublayer(picture)
        }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Band selection and drop highlight, above the tiles.
    private final class Overlay: NSView {
        weak var grid: ThumbnailGrid?
        override var isFlipped: Bool { return true }
        override func hitTest(_ point: NSPoint) -> NSView? { return nil }
        override func draw(_ dirtyRect: NSRect) { grid?.drawOverlays() }
    }

    private var tiles: [Int: Tile] = [:]
    private var spare: [Tile] = []
    private var overlay: Overlay?
    private var tilesScheduled = false
    private var scrollObserver: NSObjectProtocol?

    override var wantsUpdateLayer: Bool { return true }

    override func updateLayer() {
        layer?.backgroundColor = glassBehind ? NSColor.clear.cgColor : ThemeManager.shared.background.cgColor
        overlay?.needsDisplay = true
        updateTiles()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        scheduleTiles()
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { scheduleTiles(); overlay?.needsDisplay = true } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        overlay?.frame = bounds
        scheduleTiles()
    }

    private func setUpLayers() {
        guard overlay == nil else { return }
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let o = Overlay(frame: bounds)
        o.grid = self
        o.autoresizingMask = [.width, .height]
        addSubview(o)
        overlay = o
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let o = scrollObserver { NotificationCenter.default.removeObserver(o); scrollObserver = nil }
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        // Scrolling: tiles for what comes into view are made at once (no blank cells, no draw calls).
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.updateTiles()
        }
    }

    private func scheduleTiles() {
        if tilesScheduled { return }
        tilesScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let s = self else { return }
            s.tilesScheduled = false
            s.updateTiles()
        }
    }

    private func updateTiles() {
        setUpLayers()
        guard let root = layer else { return }
        let tm = ThemeManager.shared
        themeSig = "\(tm.text.hashValue),\(tm.background.hashValue),\(tm.selection.hashValue),\(tm.smallFont.pointSize),\(glassBehind)"
        let scale = window?.backingScaleFactor ?? 1
        let c = columns
        let vis = visibleRect
        let rowH = cellHeight + pad
        var nowWanted = Set<String>()
        var keep = Set<Int>()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !entries.isEmpty && vis.height > 0 {
            let margin = vis.height / 2
            let firstRow = max(0, Int((vis.minY - margin - pad) / rowH))
            let lastRow = Int((vis.maxY + margin - pad) / rowH)
            let visFirst = max(0, Int((vis.minY - pad) / rowH)), visLast = Int((vis.maxY - pad) / rowH)
            let from = min(entries.count, firstRow * c), to = min(entries.count, (lastRow + 1) * c)
            // Pictures in view are asked for first, then the half screens around them.
            let order = (from..<to).sorted { a, b in
                let ra = a / c, rb = b / c
                let ia = ra >= visFirst && ra <= visLast, ib = rb >= visFirst && rb <= visLast
                return ia != ib ? ia : a < b
            }
            for i in order {
                keep.insert(i)
                let e = entries[i]
                let k = key(e)
                let thumb = ThumbnailGrid.cache.object(forKey: NSString(string: k))
                if thumb == nil && e.kind == .file && (PhotoFormats.isImage(e.name) || FastPreview.thumbnailable(e.name)) {
                    nowWanted.insert(k)
                    request(e, key: k)
                }
                let r = rect(of: i)
                let t: Tile
                if let old = tiles[i] { t = old } else {
                    t = spare.popLast() ?? Tile()
                    t.captionKey = nil; t.pictureKey = nil
                    if t.superlayer !== root {
                        if let ol = overlay?.layer { root.insertSublayer(t, below: ol) } else { root.addSublayer(t) }
                    }
                    t.isHidden = false
                    tiles[i] = t
                }
                if t.frame != r { t.frame = r }
                if t.contentsScale != scale { t.contentsScale = scale; t.picture.contentsScale = scale }
                // Caption, badges, selection: one bitmap, drawn again only when it changes.
                let ck = NSString(string: cellKey(i, e, thumbKey: k, hasImage: false) + "|cap|\(scale)|\(r.width)x\(r.height)")
                if t.captionKey != ck {
                    var box = ThumbnailGrid.cellCache.object(forKey: ck)
                    if box == nil, let img = renderCell(i, size: r.size, scale: scale) {
                        box = CGImageBox(img)
                        ThumbnailGrid.cellCache.setObject(box!, forKey: ck, cost: img.width * img.height * 4)
                    }
                    t.contents = box?.image
                    t.captionKey = ck
                }
                // The picture (or the file's icon).
                let box = NSRect(x: 8, y: 6, width: thumbSize, height: thumbSize)
                let trash = Finish.depth > 0 && facts[e.path]?.colorClass == 8
                let pk = (thumb != nil ? k : "icon|" + e.path) + "|\(thumbSize)|\(trash)|\(Finish.depth)"
                if t.pictureKey != pk {
                    if let img = thumb {
                        t.picture.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        t.picture.frame = fit(img.size, in: box)
                        t.picture.opacity = trash ? Float(1 - 0.45 * Finish.depth) : 1
                        if Finish.depth > 0 {
                            t.picture.shadowColor = NSColor.black.cgColor
                            t.picture.shadowOpacity = Float(min(0.85, 0.85 * Finish.depth))
                            t.picture.shadowRadius = 6 * Finish.depth
                            t.picture.shadowOffset = CGSize(width: 0, height: 4 * Finish.depth)
                            t.picture.shadowPath = CGPath(rect: CGRect(origin: .zero, size: t.picture.frame.size), transform: nil)
                        } else {
                            t.picture.shadowOpacity = 0
                        }
                    } else {
                        let icon = IconCache.shared.icon(for: e)
                        let sz = min(box.width, box.height) * 0.6
                        var ir = NSRect(x: 0, y: 0, width: sz, height: sz)
                        t.picture.contents = icon.cgImage(forProposedRect: &ir, context: nil, hints: nil)
                        t.picture.frame = NSRect(x: box.midX - sz / 2, y: box.midY - sz / 2, width: sz, height: sz)
                        t.picture.opacity = 0.85
                        t.picture.shadowOpacity = 0
                    }
                    t.pictureKey = pk
                }
            }
        }
        for (i, t) in tiles where !keep.contains(i) {
            t.isHidden = true
            t.contents = nil
            t.picture.contents = nil
            spare.append(t)
            tiles.removeValue(forKey: i)
        }
        if spare.count > 200 {
            for t in spare.dropFirst(200) { t.removeFromSuperlayer() }
            spare = Array(spare.prefix(200))
        }
        CATransaction.commit()
        wantedLock.lock()
        wanted = nowWanted
        wantedLock.unlock()
    }

    /// One cell into a bitmap at the screen's pixel size (nil: drawn directly instead).
    private func renderCell(_ i: Int, size: NSSize, scale: CGFloat) -> CGImage? {
        let pw = Int(ceil(size.width * scale)), ph = Int(ceil(size.height * scale))
        guard pw > 0, ph > 0,
            let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        drawCell(i, in: NSRect(origin: .zero, size: size), picture: false)   // the picture is its own layer
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Draws cell `i` with its top-left at `r.origin` (in the view, or in a cell bitmap).
    private func drawCell(_ i: Int, in r0: NSRect, picture: Bool = true) {
        let tm = ThemeManager.shared
        let e = entries[i]
        let r = r0
        let nameStyle = NSMutableParagraphStyle()
        nameStyle.alignment = .center
        nameStyle.lineBreakMode = .byWordWrapping
        let nameAttrs: [AttrKey: Any] = [AttrKey.font: tm.smallFont, AttrKey.foregroundColor: tm.text, AttrKey.paragraphStyle: nameStyle]
        let badgeAttrs: [AttrKey: Any] = [AttrKey.font: tm.smallFont, AttrKey.foregroundColor: tm.secondaryText, AttrKey.paragraphStyle: nameStyle]
        if selection.contains(i) {
            tm.selection.setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            // 0.16 Glow: an accent outline that glows softly.
            if Finish.glow > 0, let g = Finish.glowShadow(tm.accent, radius: 10) {
                NSGraphicsContext.saveGraphicsState()
                g.set()
                tm.accent.withAlphaComponent(0.7 * Finish.glow).setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                o.lineWidth = 1
                o.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let box = NSRect(x: r.minX + 8, y: r.minY + 6, width: thumbSize, height: thumbSize)
        if !picture {
            // PhotoLab tiles: the picture layer goes here.
        } else if let img = ThumbnailGrid.cache.object(forKey: NSString(string: key(e))) {
            // 0.16 Depth: a soft shadow under the picture; colour class 8 (Trash) faded.
            let shadow = Finish.thumbShadow(flipped: true)
            if let sh = shadow { NSGraphicsContext.saveGraphicsState(); sh.set() }
            let trash = Finish.depth > 0 && facts[e.path]?.colorClass == 8
            NSGraphicsContext.current?.imageInterpolation = .high
            img.draw(in: fit(img.size, in: box), from: .zero, operation: .sourceOver, fraction: trash ? 1 - 0.45 * Finish.depth : 1, respectFlipped: true, hints: nil)
            if shadow != nil { NSGraphicsContext.restoreGraphicsState() }
        } else {
            let icon = IconCache.shared.icon(for: e)
            let s = min(box.width, box.height) * 0.6
            icon.draw(in: NSRect(x: box.midX - s / 2, y: box.midY - s / 2, width: s, height: s), from: .zero,
                      operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
        }
        let nameRect = self.nameRect(cell: r, box: box)
        let nameStr = NSAttributedString(string: e.name, attributes: nameAttrs)
        nameStr.draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        var badges: [String] = []
        if let t = twinBadges[e.path] { badges.append(t) }
        if let f = facts[e.path] {
            if let rt = f.rating, rt != 0 { badges.append(rt < 0 ? "Rejected" : String(repeating: "\u{2605}", count: min(rt, 5))) }
            if let l = f.label, !l.isEmpty { badges.append(l) }
            // Photo Mechanic colour class: a coloured square at the top left, and its name.
            if let cc = f.colorClass, let col = Prefs.colorClassColor(cc) {
                col.setFill()
                let glow = Finish.glowShadow(col)
                if let g = glow { NSGraphicsContext.saveGraphicsState(); g.set() }
                NSBezierPath(roundedRect: NSRect(x: r.minX + 6, y: r.minY + 6, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
                if glow != nil { NSGraphicsContext.restoreGraphicsState() }
                badges.append(Prefs.colorClassNames[cc - 1])
            }
        }
        if sidecarPaths.contains(e.path) { badges.append("XMP") }
        if let root = folderRoot {
            let parent = Paths.parent(e.path)
            let rel = parent == root ? "" : String(parent.dropFirst(root.count).drop(while: { $0 == "/" }))
            badges.insert(rel.isEmpty ? "\u{2302} top" : "\u{25B8} " + rel, at: 0)
        }
        if !badges.isEmpty {
            let used = nameStr.boundingRect(with: nameRect.size, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            let br = NSRect(x: r.minX + 4, y: nameRect.minY + min(nameRect.height, ceil(used.height)) + 1, width: r.width - 8, height: lineHeight)
            NSString(string: badges.joined(separator: "  ")).draw(in: br, withAttributes: badgeAttrs)
        }
        let colors = TagCache.shared.colors(e.path)
        if let first = colors.first, let col = ColorLabelColors.color(first) {
            col.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 16, y: r.minY + 6, width: 9, height: 9)).fill()
        }
    }

    /// 0.18.10: "NEF+JPG" etc. for pictures whose JPEG twin is hidden in Photography Mode.
    var twinBadges: [String: String] = [:]

    fileprivate func drawOverlays() {
        let tm = ThemeManager.shared
        if let r = bandRect, r.width > 0 || r.height > 0 {
            tm.accent.withAlphaComponent(0.15).setFill()
            r.fill()
            tm.accent.setStroke()
            let b = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            b.lineWidth = 1
            b.stroke()
        }
        if let i = dropIndex, i < entries.count {
            tm.accent.setStroke()
            let b = NSBezierPath(roundedRect: rect(of: i).insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            b.lineWidth = 3
            b.stroke()
        } else if dropOnAll {
            tm.accent.setStroke()
            let b = NSBezierPath(rect: visibleRect.insetBy(dx: 2, dy: 2))
            b.lineWidth = 3
            b.stroke()
        }
    }

    private func nameRect(cell r: NSRect, box: NSRect) -> NSRect {
        return NSRect(x: r.minX + 4, y: box.maxY + 4, width: r.width - 8, height: lineHeight * 3)
    }

    /// Where an item's name is drawn (for renaming in place).
    func nameRect(forPath p: String) -> NSRect? {
        guard let i = indexByPath[p], i < entries.count else { return nil }
        scrollTo(i)
        let r = rect(of: i)
        let box = NSRect(x: r.minX + 8, y: r.minY + 6, width: thumbSize, height: thumbSize)
        let n = nameRect(cell: r, box: box)
        let h = max(20, ThemeManager.shared.font.pointSize + 9)
        return NSRect(x: r.minX - 10, y: n.minY, width: r.width + 20, height: h)
    }

    private func fit(_ s: NSSize, in box: NSRect) -> NSRect {
        if s.width <= 0 || s.height <= 0 { return box }
        let k = min(box.width / s.width, box.height / s.height)
        let w = s.width * k, h = s.height * k
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    private func request(_ e: FileEntry, key k: String) {
        if pending.contains(k) { return }
        pending.insert(k)
        let px = pixelBucket
        let path = e.path
        let size = e.size, modified = e.modified
        queue.addOperation { [weak self] in
            guard let s = self else { return }
            s.wantedLock.lock()
            let still = s.wanted.contains(k) || s.wanted.isEmpty
            s.wantedLock.unlock()
            if !still {
                DispatchQueue.main.async { s.pending.remove(k) }
                return
            }
            let cg = ImageMeta.thumbnail(path: path, maxPixels: px, size: size, modified: modified)
            DispatchQueue.main.async {
                s.pending.remove(k)
                guard let cg = cg else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                ThumbnailGrid.cache.setObject(img, forKey: NSString(string: k))
                ThumbnailGrid.latestKey[path] = k
                if ThumbnailGrid.latestKey.count > 5000 { ThumbnailGrid.latestKey.removeAll() }
                if let i = s.indexByPath[path], i < s.entries.count { s.setNeedsDisplay(s.rect(of: i)) }
            }
        }
    }

    // MARK: Mouse

    // Click the name of the only selected item again: rename after a pause (never on double-click).
    private var clickRenameIndex = -1

    private func cancelClickRename() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clickRenameFired), object: nil)
        clickRenameIndex = -1
    }

    @objc private func clickRenameFired() {
        let i = clickRenameIndex
        clickRenameIndex = -1
        guard i >= 0, !dragStarted, NSEvent.pressedMouseButtons & 1 == 0, selection == IndexSet(integer: i), window?.firstResponder === self else { return }
        onRename?()
    }

    private func resetMouse() {
        downPoint = nil
        downEvent = nil
        downIndex = nil
        collapseOnUp = nil
        dragStarted = false
        bandStart = nil
        if bandRect != nil {
            bandRect = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        cancelClickRename()
        resetMouse()
        let wasFirst = window?.firstResponder === self
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        downEvent = event
        downIndex = index(at: p)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option, let i = index(at: p),
            onOptionClick?(entries[i]) == true {
            resetMouse()
            return
        }
        if event.clickCount == 1, wasFirst, let i = index(at: p), selection == IndexSet(integer: i),
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            let r = rect(of: i)
            let box = NSRect(x: r.minX + 8, y: r.minY + 6, width: thumbSize, height: thumbSize)
            if nameRect(cell: r, box: box).insetBy(dx: 0, dy: -2).contains(p) {
                clickRenameIndex = i
                perform(#selector(clickRenameFired), with: nil, afterDelay: FileTableView.clickRenameDelay)
                return
            }
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let i = index(at: p) else {
            // Empty space: start a selection rectangle (Command or Shift adds to the selection).
            bandStart = p
            bandBase = flags.contains(.command) || flags.contains(.shift) ? selection : IndexSet()
            if selection != bandBase { selection = bandBase; changed() }
            return
        }
        if event.clickCount == 2 {
            resetMouse()
            onOpen?(entries[i])
            return
        }
        if flags.contains(.command) {
            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            anchor = i; cursor = anchor
        } else if flags.contains(.shift), let a = anchor {
            selection = IndexSet(integersIn: min(a, i)...max(a, i))
            cursor = i
        } else if selection.contains(i) {
            collapseOnUp = selection.count > 1 ? i : nil
            anchor = i; cursor = anchor
        } else {
            selection = IndexSet(integer: i)
            anchor = i; cursor = anchor
        }
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let b = bandStart {
            let r = NSRect(x: min(b.x, p.x), y: min(b.y, p.y), width: abs(p.x - b.x), height: abs(p.y - b.y))
            bandRect = r
            var s = bandBase
            for i in indices(in: r) { s.insert(i) }
            if s != selection {
                selection = s
                if let f = s.first { anchor = f; cursor = anchor }
                changed()
            } else {
                needsDisplay = true
            }
            _ = autoscroll(with: event)
            return
        }
        if dragStarted || downIndex == nil { return }
        if hypot(p.x - start.x, p.y - start.y) < 4 { return }
        guard let ev = downEvent else { return }
        dragStarted = true
        collapseOnUp = nil
        cancelClickRename()
        beginFileDrag(event: ev, at: start)
    }

    override func mouseUp(with event: NSEvent) {
        if let i = collapseOnUp, !dragStarted, i < entries.count {
            selection = IndexSet(integer: i)
            anchor = i; cursor = anchor
            changed()
        }
        resetMouse()
    }

    /// Items whose cell touches `r`.
    private func indices(in r: NSRect) -> [Int] {
        if entries.isEmpty { return [] }
        let c = columns
        let firstRow = max(0, Int((r.minY - pad) / (cellHeight + pad)))
        let lastRow = max(firstRow, Int((r.maxY - pad) / (cellHeight + pad)))
        var out: [Int] = []
        for row in firstRow...lastRow {
            for col in 0..<c {
                let i = row * c + col
                if i >= entries.count { return out }
                if rect(of: i).intersects(r) { out.append(i) }
            }
        }
        return out
    }

    // MARK: Dragging files out

    private func beginFileDrag(event: NSEvent, at start: NSPoint) {
        let idx = Array(selection).filter { $0 < entries.count }
        if idx.isEmpty { return }
        var items: [NSDraggingItem] = []
        let visible = visibleRect
        for (n, i) in idx.enumerated() {
            let e = entries[i]
            let item = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: e.path))
            let r = rect(of: i)
            let box = NSRect(x: r.minX + 8, y: r.minY + 6, width: thumbSize, height: thumbSize)
            let img = ThumbnailGrid.cache.object(forKey: NSString(string: key(e))) ?? IconCache.shared.icon(for: e)
            let frame: NSRect
            if n < 60 && visible.intersects(r) {
                frame = fit(img.size, in: box)
            } else {
                frame = NSRect(x: start.x - 32, y: start.y - 32, width: 64, height: 64)
            }
            item.setDraggingFrame(frame, contents: img)
            items.append(item)
        }
        FileDrag.photoDrag = photoMode ? Set(idx.map { entries[$0].path }) : nil
        App.log.info("DRAG \(items.count) item(s) from the thumbnail view" + (photoMode ? " (Photography: XMP sidecars go along)" : ""))
        let session = beginDraggingSession(with: items, event: event, source: self)
        FileDrag.addFilenames(session.draggingPasteboard, idx.map { entries[$0].path })
    }

    // MARK: Dropping files in

    private func setDrop(_ i: Int?, all: Bool) {
        if i == dropIndex && all == dropOnAll { return }
        dropIndex = i
        dropOnAll = all
        needsDisplay = true
    }

    private func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = convert(FileDrag.location(info), from: nil)
        let sources = FileDrag.paths(info)
        var dest: String? = nil
        var onItem: Int? = nil
        if let i = index(at: p), FileDrag.isDropFolder(entries[i]), !sources.contains(entries[i].path) {
            dest = entries[i].path
            onItem = i
        } else {
            dest = dropFolder?()
        }
        guard let d = dest else {
            setDrop(nil, all: false)
            return []
        }
        let op = FileDrag.operation(info, sources: sources, dest: d)
        setDrop(op.isEmpty ? nil : onItem, all: !op.isEmpty && onItem == nil)
        return op
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return updateDrop(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return updateDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDrop(nil, all: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let op = updateDrop(sender)
        let dest: String?
        if let i = dropIndex, i < entries.count { dest = entries[i].path } else { dest = dropOnAll ? dropFolder?() : nil }
        setDrop(nil, all: false)
        guard let d = dest, !op.isEmpty else { return false }
        onDrop?(FileDrag.paths(sender), d, op == .move)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDrop(nil, all: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelClickRename()
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p) {
            if !selection.contains(i) { selection = IndexSet(integer: i); anchor = i; cursor = anchor; changed() }
        } else if !selection.isEmpty {
            selection = IndexSet()
            changed()
        }
        return contextMenu?()
    }

    private func changed() {
        needsDisplay = true
        onSelectionChanged?(selectedPaths)
    }

    // MARK: Keyboard

    /// 0.14: Cmd + 0-8 sets the Photo Mechanic colour class in Photography mode (before the menus see
    /// it, so Cmd-1/2/3 change views everywhere else).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, photoDigit(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// 0.16: number keys in Photography mode, with the modifiers chosen in Settings > Keys:
    /// stars (0-5) and Photo Mechanic colour classes (0-8). True if the key was used.
    func photoDigit(_ event: NSEvent) -> Bool {
        guard photoMode else { return false }
        let f = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let digit: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8,
                                    82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8]
        guard let n = digit[event.keyCode] else { return false }
        func matches(_ m: String) -> Bool {
            switch m {
            case "cmd": return f == .command
            case "ctrl": return f == .control
            case "opt": return f == .option
            case "shift": return f == .shift
            default: return f.isEmpty
            }
        }
        if matches(Prefs.colourModifier), let set = onColorClass {
            set(n)
            return true
        }
        let star = Prefs.starModifier
        if n <= 5, matches(star) || (star == "ctrl" && f.isEmpty), let rate = onRate {
            rate(n)
            return true
        }
        return false
    }

    /// 0.18.15: the I key opens Edit Metadata for the selected pictures.
    var onKeyI: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        cancelClickRename()
        if FastPreview.shared.handleKey(event) { return }   // PhotoLab: Z / Cmd-0 zoom the preview
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 34 && (flags.isEmpty || flags == .capsLock), onKeyI?() == true { return }
        switch event.keyCode {
        case 49:
            if flags == .option { onOptionSpace?() } else { onSpace?() }
            return
        case 53:
            if onEscape?() == true { return }
        case 48:
            if flags.isEmpty, onTab?() == true { return }
        case 36, 76:
            if flags.isEmpty { onRename?(); return }
        case 29, 18, 19, 20, 21, 23, 22, 26, 28, 82, 83, 84, 85, 86, 87, 88, 89, 91:
            // Number keys in Photography mode: stars and colour classes, with the keys chosen in
            // Settings > Keys (0.16).
            if photoDigit(event) { return }
        case 123: move(-1, extend: flags.contains(.shift)); return
        case 124: move(1, extend: flags.contains(.shift)); return
        case 126:
            if flags.contains(.command) { onGoUp?(); return }
            move(-columns, extend: flags.contains(.shift)); return
        case 125:
            if flags.contains(.command) {
                if let i = selection.first { onOpen?(entries[i]) }
                return
            }
            move(columns, extend: flags.contains(.shift)); return
        default:
            break
        }
        super.keyDown(with: event)
    }

    private func move(_ d: Int, extend: Bool) {
        if entries.isEmpty { return }
        // From the moving end of the selection (where the last arrow or Shift-click went), as in Finder.
        var from: Int
        if let c = cursor, c >= 0, c < entries.count, selection.contains(c) {
            from = c
        } else {
            from = (d > 0 ? selection.last : selection.first) ?? (d > 0 ? -1 : entries.count)
        }
        let to = max(0, min(entries.count - 1, from + d))
        if extend, let a = anchor, a < entries.count {
            selection = IndexSet(integersIn: min(a, to)...max(a, to))
            cursor = to
        } else {
            selection = IndexSet(integer: to)
            anchor = to
            cursor = to
        }
        if Prefs.photoArrowSteps {
            // 0.16: whole rows, no scrolling animation: the view jumps only when the selection leaves it.
            stepScroll(to: to)
        } else {
            // One row of thumbnails ahead stays in view in the direction of travel.
            let ahead = d > 0 ? min(entries.count - 1, to + columns) : max(0, to - columns)
            scrollTo(ahead)
            scrollTo(to)
        }
        changed()
    }

    /// Show the row of picture `i` by jumping whole rows (no animation). Nothing moves while it is
    /// fully in view; otherwise the view is placed so the row is at the top (going up) or the bottom
    /// (going down), aligned to the rows.
    private func stepScroll(to i: Int) {
        guard let sv = enclosingScrollView else { scrollTo(i); return }
        let clip = sv.contentView
        let rowH = cellHeight + pad
        let row = i / columns
        let vis = clip.bounds
        let rowTop = pad + CGFloat(row) * rowH
        let rowBottom = rowTop + cellHeight
        if rowTop >= vis.minY && rowBottom <= vis.maxY { return }
        let visibleRows = max(1, Int((vis.height - pad) / rowH))
        let first = rowTop < vis.minY ? row : max(0, row - visibleRows + 1)
        let maxY = max(0, bounds.height - vis.height)
        let y = min(maxY, CGFloat(first) * rowH)
        clip.setBoundsOrigin(NSPoint(x: vis.minX, y: y))
        sv.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    // Edit > Select All. NSResponder declares selectAll(_:) in the 10.13 SDK, so it is overridden.
    override func selectAll(_ sender: Any?) {
        selection = IndexSet(integersIn: 0..<entries.count)
        changed()
    }
}

extension ThumbnailGrid: NSDraggingSource {
    /// Inside Find: copy or move. To other apps (Finder, Photoshop...): copy only.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? [.copy, .move, .generic] : [.copy, .link, .generic]
    }
}

/// Finder colour label number (1-7) -> colour for the small dot.
enum ColorLabelColors {
    static func color(_ n: Int) -> NSColor? {
        switch n {
        case 1: return NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        case 2: return NSColor(srgbRed: 0.3, green: 0.75, blue: 0.3, alpha: 1)
        case 3: return NSColor(srgbRed: 0.65, green: 0.4, blue: 0.8, alpha: 1)
        case 4: return NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 1)
        case 5: return NSColor(srgbRed: 0.95, green: 0.8, blue: 0.2, alpha: 1)
        case 6: return NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1)
        case 7: return NSColor(srgbRed: 0.95, green: 0.55, blue: 0.2, alpha: 1)
        default: return nil
        }
    }
}

/// A CGImage in an NSCache.
final class CGImageBox {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}
