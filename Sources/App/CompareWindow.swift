// CompareWindow.swift
// 2 to 4 pictures side by side, each with its key camera details. Uses the same fast previews as
// Fast Preview (RAW: embedded camera JPEG). Read-only.

import AppKit

final class CompareWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [CompareWindowController] = []
    private let entries: [FileEntry]
    private var imageViews: [NSImageView] = []
    private var captions: [NSTextField] = []
    private var cancelled = AtomicInt()

    static func show(_ entries: [FileEntry]) {
        let c = CompareWindowController(entries: entries)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    init(entries: [FileEntry]) {
        self.entries = entries
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: screen.width, height: screen.height),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Compare \(entries.count) Pictures"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 500, height: 300)
        super.init(window: w)
        shouldCascadeWindows = true
        w.delegate = self
        build()
        // Fill the screen (the whole usable area, below the menu bar and beside the Dock).
        w.setFrame(screen, display: false)
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        guard let w = window, let content = w.contentView else { return }
        let tm = ThemeManager.shared
        w.appearance = tm.appearance
        w.backgroundColor = tm.background
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for e in entries {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.isEditable = false
            let icon = IconCache.shared.largeIcon(for: e)
            icon.size = NSSize(width: 128, height: 128)
            iv.image = icon
            iv.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)
            iv.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .vertical)
            let cap = NSTextField(wrappingLabelWithString: e.name)
            cap.font = tm.smallFont
            cap.textColor = tm.text
            cap.alignment = .center
            cap.isSelectable = true
            let col = NSStackView(views: [iv, cap])
            col.orientation = .vertical
            col.spacing = 6
            imageViews.append(iv)
            captions.append(cap)
            row.addArrangedSubview(col)
        }
        content.addSubview(row)
        row.pinEdges(to: content, top: 10, left: 10, bottom: 10, right: 10)
    }

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2   // two reads at a time: quicker overall, kinder to network shares
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Pictures first (instant thumbnail, then a decode sized to the window's share of the screen),
    /// camera details after.
    private func load() {
        let flag = cancelled
        let scale = window?.backingScaleFactor ?? 1
        let frame = window?.frame.size ?? NSSize(width: 1600, height: 1000)
        let px = Int(min(2048, max(800, max(frame.width / CGFloat(max(1, entries.count)), frame.height) * scale)))
        for (i, e) in entries.enumerated() {
            if let t = ThumbnailGrid.cachedThumbnail(for: e.path) { imageViews[i].image = t }
            queue.addOperation { [weak self] in
                if flag.value != 0 { return }
                let slow = PreviewCache.worthCaching(name: e.name, size: e.size)
                if slow, let q = ImageMeta.preview(path: e.path, maxPixels: px, allowSlow: false) {
                    let img = NSImage(cgImage: q.image, size: NSSize(width: q.image.width, height: q.image.height))
                    DispatchQueue.main.async { if flag.value == 0, let s = self, i < s.imageViews.count { s.imageViews[i].image = img } }
                    if q.source == "saved preview" { return }
                }
                if flag.value != 0 { return }
                guard let pv = ImageMeta.preview(path: e.path, maxPixels: px) else { return }
                let img = NSImage(cgImage: pv.image, size: NSSize(width: pv.image.width, height: pv.image.height))
                DispatchQueue.main.async { if flag.value == 0, let s = self, i < s.imageViews.count { s.imageViews[i].image = img } }
            }
        }
        for (i, e) in entries.enumerated() {
            queue.addOperation { [weak self] in
                if flag.value != 0 { return }
                let secs = InspectorController.details(for: e, stillWanted: { flag.value == 0 }).sections
                var rows: [String: String] = [:]
                for s in secs { for (k, v) in s.rows { rows[k] = rows[k] ?? v } }
                let line1 = [rows["Model"], rows["Lens"]].compactMap { $0 }.joined(separator: "  \u{00B7}  ")
                let line2 = [rows["Focal length"], rows["Aperture"], rows["Shutter speed"], rows["ISO"].map { "ISO " + $0 },
                             rows["Exposure comp."]].compactMap { $0 }.joined(separator: "  ")
                let line3 = [rows["Dimensions"], rows["Rating"], rows["Label"]].compactMap { $0 }.joined(separator: "  \u{00B7}  ")
                DispatchQueue.main.async {
                    guard let s = self, flag.value == 0, i < s.captions.count else { return }
                    s.captions[i].stringValue = ([e.name, line1, line2, line3].filter { !$0.isEmpty }).joined(separator: "\n")
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelled.value = 1
        queue.cancelAllOperations()
        window?.delegate = nil
        DispatchQueue.main.async {
            CompareWindowController.open = CompareWindowController.open.filter { $0 !== self }
        }
    }
}
