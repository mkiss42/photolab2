// FastPreview.swift
// Find's own lightweight preview window (Space). Faster than Quick Look for photos:
// - RAW files show the camera's embedded JPEG (never developed), other images are decoded at
//   screen size, and the next two and previous file are prepared in the background.
// - The window never takes keyboard focus, so Space, Escape and the arrow keys keep working in the list.
// - PDFs (PDFKit), text and video/audio (AVKit) get light native viewers; anything else shows the
//   system thumbnail. Cmd-Y still opens the full macOS Quick Look.
// Read-only. Previews are kept in memory only (a few screens' worth), nothing is written to disk.

import AppKit
import Quartz
import AVKit
import AVFoundation

/// A panel that never becomes key: keystrokes stay with the file list.
final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
}

final class FastPreview: NSObject, NSWindowDelegate {
    static let shared = FastPreview()

    private var panel: PreviewPanel!
    private let content = FillView()
    private let imageView = PreviewImageView()
    private let caption = makeLabel("")
    private let note = makeLabel("")
    private var pdfView: PDFView?
    private var textScroll: NSScrollView?
    private var playerView: AVPlayerView?

    private weak var owner: FileListController?
    private var currentPath: String?
    private var generation = 0
    private let latest = AtomicInt()
    /// Clear All Disposable Caches.
    func clearMemory() { cache.removeAllObjects() }

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    private var normalFrame: NSRect?
    /// The window was reshaped for a PDF page; the user's own size is kept in the saved frame.
    private var shapedForPDF = false

    private func fitWindow(toAspect aspect: CGFloat) {
        guard normalFrame == nil, let screen = panel.screen ?? NSScreen.main, let cv = panel.contentView else { return }
        let vis = screen.visibleFrame
        let chromeH = panel.frame.height - cv.bounds.height + 40    // title bar + caption + insets
        let chromeW: CGFloat = 12 + 16                               // insets + scroll bar
        var h = vis.height * 0.9
        var w = (h - chromeH) * aspect + chromeW
        if w > vis.width * 0.95 {
            w = vis.width * 0.95
            h = (w - chromeW) / aspect + chromeH
        }
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var f = NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        f.origin.x = min(max(vis.minX, f.origin.x), vis.maxX - w)
        f.origin.y = min(max(vis.minY, f.origin.y), vis.maxY - h)
        shapedForPDF = true
        panel.setFrame(f, display: true, animate: false)
    }

    private func restoreWindowShape() {
        guard shapedForPDF else { return }
        shapedForPDF = false
        if normalFrame == nil, let f = savedFrame() { panel.setFrame(f, display: true, animate: false) }
    }

    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "3gp"]
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aac", "caf"]
    static let textExts: Set<String> = ["txt", "text", "md", "csv", "tsv", "json", "xml", "log", "swift", "py", "sh", "js",
                                        "css", "html", "htm", "yml", "yaml", "ini", "cfg", "conf", "c", "h", "m", "cpp",
                                        "java", "sql", "tex", "jsx", "ts", "rb", "pl", "php", "xmp", "srt", "vtt"]

    var isVisible: Bool { return panel?.isVisible == true }

    /// Non-image files that get a picture thumbnail in the grid (from Quick Look's thumbnailer).
    static func thumbnailable(_ name: String) -> Bool {
        return ["pdf", "mov", "mp4", "m4v", "ai", "eps"].contains(Paths.fileExtension(name).lowercased())
    }

    private override init() {
        super.init()
        cache.countLimit = 12
    }

    // MARK: Open / close

    func toggle(for list: FileListController) {
        if isVisible && owner === list {
            close()
            return
        }
        guard !list.selectedPaths().isEmpty else {
            NSSound.beep()
            return
        }
        if panel == nil { build() }
        owner = list
        applyTheme()
        if !isVisible {
            if let f = savedFrame() { panel.setFrame(f, display: false) } else { defaultFrame() }
            panel.orderFront(nil)
        }
        show(force: true)
        Log.shared?.info("Fast preview opened")
    }

    func close() {
        guard isVisible else { return }
        stopMedia()
        if normalFrame == nil && !shapedForPDF { saveFrame() }
        if shapedForPDF, let f = savedFrame() { shapedForPDF = false; panel.setFrame(f, display: false) }
        panel.orderOut(nil)
        generation += 1
        latest.value = generation
        queue.cancelAllOperations()
        currentPath = nil
    }

    /// The list's selection changed.
    func selectionChanged(from list: FileListController) {
        guard isVisible, owner === list else { return }
        if list.selectedPaths().isEmpty {
            close()
            return
        }
        show(force: false)
    }

    /// Option-Space or double-click: fill the screen / back to the normal size.
    func toggleFill() {
        guard isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        if let f = normalFrame {
            normalFrame = nil
            panel.setFrame(f, display: true, animate: false)
        } else {
            saveFrame()
            normalFrame = panel.frame
            panel.setFrame(screen.visibleFrame, display: true, animate: false)
        }
        if currentPath != nil { show(force: true) }
    }

    // MARK: Building

    private func build() {
        let p = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 320, height: 240)
        p.delegate = self
        panel = p
        p.contentView = content
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        imageView.onDoubleClick = { [weak self] in self?.toggleFill() }
        caption.alignment = .center
        note.alignment = .center
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        for v in [imageView, caption, note] as [NSView] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            imageView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -6),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            caption.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            note.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])
        imageView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)
        imageView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .vertical)
        imageView.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)
        imageView.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 100), for: .vertical)
    }

    func applyTheme() {
        guard panel != nil else { return }
        let tm = ThemeManager.shared
        panel.appearance = tm.appearance
        content.fillColor = tm.background
        caption.font = tm.smallFont
        caption.textColor = tm.secondaryText
        note.font = tm.font
        note.textColor = tm.secondaryText
    }

    private func defaultFrame() {
        guard let s = NSScreen.main?.visibleFrame else { return }
        let w = s.width * 0.6, h = s.height * 0.7
        panel.setFrame(NSRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h), display: false)
    }

    private func savedFrame() -> NSRect? {
        guard let str = UserDefaults.standard.string(forKey: Prefs.Key.previewFrame) else { return nil }
        let f = NSRectFromString(str)
        if f.width < 320 || f.height < 240 { return nil }
        // Only if it is still on a connected screen.
        for s in NSScreen.screens where s.frame.intersects(f) { return f }
        return nil
    }

    private func saveFrame() {
        guard panel != nil else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Prefs.Key.previewFrame)
    }

    func windowDidResize(_ notification: Notification) {
        if normalFrame == nil && !shapedForPDF { saveFrame() }
    }

    func windowDidMove(_ notification: Notification) {
        if normalFrame == nil && !shapedForPDF { saveFrame() }
    }

    func windowWillClose(_ notification: Notification) {
        stopMedia()
        generation += 1
        latest.value = generation
        queue.cancelAllOperations()
        currentPath = nil
    }

    // MARK: Showing

    private var maxPixels: Int {
        let scale = panel.backingScaleFactor
        let r = panel.contentView?.bounds ?? panel.frame
        let longSide = max(r.width, r.height) * scale
        // Round up to steps so a small resize reuses the cache; never more than 4096.
        let step: CGFloat = 512
        return Int(min(4096, max(1024, (longSide / step).rounded(.up) * step)))
    }

    private func key(_ e: FileEntry, _ px: Int) -> NSString {
        return NSString(string: "\(e.path)|\(e.size)|\(e.modified)|\(px)")
    }

    private func show(force: Bool) {
        guard let list = owner else { return }
        let entries = list.selectedEntries()
        guard let e = entries.first else { return }
        if !force && e.path == currentPath { return }
        currentPath = e.path
        generation += 1
        latest.value = generation
        let gen = generation
        stopMedia()
        let index = list.selectedRowIndex()
        let position = index.map { "\($0 + 1) of \(list.table.numberOfRows)" } ?? ""
        let extra = entries.count > 1 ? "  \u{00B7}  \(entries.count) selected" : ""
        panel.title = e.name
        let sizeText = e.size >= 0 ? Listing.sizeText(e.size) : ""
        let ext = e.ext.lowercased()

        if ext != "pdf" { restoreWindowShape() }
        if e.kind == .directory || e.isFolderLike {
            showInfoCard(e, gen: gen)
            caption.stringValue = [e.name, position].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ") + extra
            return
        }
        if ext == "pdf" {
            showPDF(e.path)
            caption.stringValue = [e.name, sizeText, "PDF", position].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ") + extra
            return
        }
        if FastPreview.textExts.contains(ext) {
            showText(e.path)
            caption.stringValue = [e.name, sizeText, position].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ") + extra
            return
        }
        if FastPreview.videoExts.contains(ext) || FastPreview.audioExts.contains(ext) {
            showMedia(e.path)
            caption.stringValue = [e.name, sizeText, position].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ") + extra
            return
        }

        // Pictures (and any other file: system thumbnail).
        let px = maxPixels
        let k = key(e, px)
        if let img = cache.object(forKey: k) {
            showImage(img, note: nil)
            caption.stringValue = captionText(e, sizeText, cachedSource[k as String] ?? "", position) + extra
        } else {
            showImage(nil, note: "Loading\u{2026}")
            caption.stringValue = captionText(e, sizeText, "", position) + extra
            load(e, px: px, gen: gen, priority: .veryHigh, interim: { [weak self] img in
                guard let s = self, s.generation == gen else { return }
                s.showImage(img, note: nil)
                s.caption.stringValue = s.captionText(e, sizeText, "quick thumbnail \u{00B7} reading the full picture\u{2026}", position) + extra
            }) { [weak self] img, source in
                guard let s = self, s.generation == gen else { return }
                if let img = img {
                    s.showImage(img, note: nil)
                    s.caption.stringValue = s.captionText(e, sizeText, source, position) + extra
                } else {
                    // No picture for this kind of file: a quick glance at its details instead.
                    s.showInfoCard(e, gen: gen)
                    s.caption.stringValue = s.captionText(e, "", "Cmd-Y for Quick Look", position) + extra
                }
            }
        }
        prefetch(list, around: index, px: px, gen: gen)
    }

    private var cachedSource: [String: String] = [:]

    private func captionText(_ e: FileEntry, _ size: String, _ source: String, _ pos: String) -> String {
        return [e.name, size, source, pos].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ")
    }

    private func load(_ e: FileEntry, px: Int, gen: Int, priority: Operation.QueuePriority,
                      interim: ((NSImage) -> Void)? = nil, done: ((NSImage?, String) -> Void)?) {
        let k = key(e, px)
        let flag = latest
        let slowKind = PreviewCache.worthCaching(name: e.name, size: e.size)
        let op = BlockOperation(block: {})
        op.queuePriority = priority
        op.addExecutionBlock { [weak self, weak op] in
            if op?.isCancelled == true || flag.value != gen { return }
            var r: (image: CGImage, source: String)? = nil
            if slowKind, let q = ImageMeta.preview(path: e.path, maxPixels: px, allowSlow: false) {
                if q.source == "saved preview" {
                    r = q
                } else {
                    // Photoshop's own small thumbnail at once; the full picture follows.
                    let img = NSImage(cgImage: q.image, size: NSSize(width: q.image.width, height: q.image.height))
                    DispatchQueue.main.async { if flag.value == gen { interim?(img) } }
                }
            }
            if r == nil {
                if op?.isCancelled == true || flag.value != gen { return }
                r = ImageMeta.preview(path: e.path, maxPixels: px)
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                var ns: NSImage? = nil
                if let r = r {
                    let img = NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))
                    s.cache.setObject(img, forKey: k)
                    s.cachedSource[k as String] = r.source
                    if s.cachedSource.count > 200 { s.cachedSource.removeAll() }
                    ns = img
                }
                done?(ns, r?.source ?? "")
            }
        }
        queue.addOperation(op)
    }

    /// Prepare the next two and the previous picture so arrowing through a shoot is instant.
    private func prefetch(_ list: FileListController, around index: Int?, px: Int, gen: Int) {
        guard let i = index else { return }
        for d in [1, 2, -1] {
            guard let n = list.table.item(atRow: i + d) as? FileNode else { continue }
            let e = n.entry
            if e.kind != .file || !PhotoFormats.isImage(e.name) { continue }
            // Never read big Photoshop files ahead: only what you actually look at.
            if PreviewCache.worthCaching(name: e.name, size: e.size) { continue }
            if cache.object(forKey: key(e, px)) != nil { continue }
            load(e, px: px, gen: gen, priority: .low, done: nil)
        }
    }

    // MARK: Viewers

    // MARK: Glance card (folders, apps, documents without a picture preview)

    private var infoCard: NSView?

    private func showInfoCard(_ e: FileEntry, gen: Int) {
        hideViewers()
        let tm = ThemeManager.shared
        let icon = NSImageView()
        let img = IconCache.shared.largeIcon(for: e)
        img.size = NSSize(width: 128, height: 128)
        icon.image = img
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
        let name = NSTextField(wrappingLabelWithString: e.name)
        name.font = NSFont.systemFont(ofSize: tm.font.pointSize + 3)
        name.textColor = tm.text
        name.preferredMaxLayoutWidth = 360
        func row(_ k: String, _ v: String) -> NSTextField {
            let f = NSTextField(labelWithString: "")
            f.attributedStringValue = {
                let a = NSMutableAttributedString(string: k + "  ", attributes: [AttrKey.font: tm.smallFont, AttrKey.foregroundColor: tm.secondaryText])
                a.append(NSAttributedString(string: v, attributes: [AttrKey.font: tm.font, AttrKey.foregroundColor: tm.text]))
                return a
            }()
            f.lineBreakMode = .byTruncatingMiddle
            return f
        }
        let kind = KindCache.shared.kind(e)
        let sizeRow = row("Size", e.isFolderLike ? "Calculating\u{2026}" : "\(Listing.sizeText(e.size)) (\(e.size) bytes)")
        let rows: [NSView] = [name, row("Kind", kind), sizeRow,
                              row("Created", InspectorController.dateText(e.created)),
                              row("Modified", InspectorController.dateText(e.modified)),
                              row("Where", Paths.parent(e.path))]
        let text = NSStackView(views: rows)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        let card = NSStackView(views: [icon, text])
        card.orientation = .horizontal
        card.alignment = .centerY
        card.spacing = 20
        let holder = FillView()
        holder.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor, constant: -40),
        ])
        infoCard = holder
        place(holder)
        if e.isFolderLike {
            let flag = latest
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak sizeRow] in
                let r = FolderSize.compute(e.path, isCancelled: { flag.value != gen })
                DispatchQueue.main.async {
                    guard let s = self, s.generation == gen, !r.cancelled, let f = sizeRow else { return }
                    var t = "\(Listing.sizeText(r.bytes)) \u{00B7} \(r.files) file\(r.files == 1 ? "" : "s")"
                    if r.folders > 0 { t += " in \(r.folders) folder\(r.folders == 1 ? "" : "s")" }
                    let a = NSMutableAttributedString(string: "Size  ", attributes: [AttrKey.font: tm.smallFont, AttrKey.foregroundColor: tm.secondaryText])
                    a.append(NSAttributedString(string: t, attributes: [AttrKey.font: tm.font, AttrKey.foregroundColor: tm.text]))
                    f.attributedStringValue = a
                }
            }
        }
    }

    private func hideViewers() {
        infoCard?.removeFromSuperview()
        infoCard = nil
        pdfView?.removeFromSuperview()
        pdfView = nil
        textScroll?.removeFromSuperview()
        textScroll = nil
        playerView?.removeFromSuperview()
        playerView = nil
        imageView.isHidden = false
    }

    private func showImage(_ img: NSImage?, note text: String?) {
        hideViewers()
        imageView.image = img
        note.stringValue = text ?? ""
        note.isHidden = text == nil
    }

    private func place(_ v: NSView) {
        imageView.isHidden = true
        imageView.image = nil
        note.isHidden = true
        content.addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: imageView.topAnchor),
            v.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
        ])
    }

    private func showPDF(_ path: String) {
        hideViewers()
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            showImage(nil, note: "This PDF could not be opened")
            return
        }
        let v = PDFView()
        v.displayMode = .singlePageContinuous
        v.autoScales = true
        v.backgroundColor = ThemeManager.shared.background
        v.document = doc
        pdfView = v
        place(v)
        // Shape the window like the first page (portrait, landscape, or any other size).
        if let page = doc.page(at: 0) {
            let b = page.bounds(for: .mediaBox)
            let turned = page.rotation % 180 != 0
            let w = turned ? b.height : b.width, h = turned ? b.width : b.height
            if w > 0 && h > 0 { fitWindow(toAspect: w / h) }
        }
        // The PDF view's own scroll bar ignores the theme: use Find's.
        if let sv = v.documentView?.enclosingScrollView {
            sv.verticalScroller = ThemedScroller()
            sv.hasVerticalScroller = true
            sv.drawsBackground = false
        }
        // Start at the first page, once the window has its final shape (and again just after,
        // as PDFKit settles its layout).
        panel.contentView?.layoutSubtreeIfNeeded()
        FastPreview.showTop(v)
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak v] in
                if let v = v { FastPreview.showTop(v) }
            }
        }
    }

    private func showText(_ path: String) {
        hideViewers()
        let tm = ThemeManager.shared
        var text = ""
        if let fh = FileHandle(forReadingAtPath: path) {
            let d = fh.readData(ofLength: 512 * 1024)
            fh.closeFile()
            IOLog.smallRead(path, bytes: Int64(d.count))
            text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        }
        let scroll = NSScrollView()
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 8, height: 8)
        let font = NSFont.userFixedPitchFont(ofSize: tm.smallFont.pointSize) ?? tm.smallFont
        tv.textStorage?.setAttributedString(attributed(text, font: font, color: tm.text))
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.verticalScroller = ThemedScroller()
        textScroll = scroll
        place(scroll)
    }

    private func showMedia(_ path: String) {
        hideViewers()
        let v = AVPlayerView()
        v.controlsStyle = .inline
        let player = AVPlayer(url: URL(fileURLWithPath: path))
        v.player = player
        playerView = v
        place(v)
        player.play()
    }

    /// First page, scrolled to its top.
    static func showTop(_ v: PDFView) {
        v.goToFirstPage(nil)
        guard let doc = v.documentView, let sv = doc.enclosingScrollView else { return }
        let clip = sv.contentView
        let y = doc.isFlipped ? 0 : max(0, doc.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(clip)
    }

    private func stopMedia() {
        playerView?.player?.pause()
        playerView?.player = nil
    }
}

/// Image view that reports double-clicks (fill the screen) and ignores drags.
final class PreviewImageView: NSImageView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }
}


/// Search inside PDFs (Settings-free: used when "Text in PDFs and documents" is ticked in the search
/// options). Read-only; first 300 pages, stops after about 8 million characters. Locked PDFs are skipped.
enum PDFTextReader {
    static func text(_ path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else { return nil }
        var out = ""
        let n = min(doc.pageCount, 300)
        var i = 0
        while i < n {
            if let p = doc.page(at: i), let s = p.string { out += s + "\n" }
            if out.count > 8_000_000 { break }
            i += 1
        }
        return out
    }
}
