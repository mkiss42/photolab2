// PreviewWindow.swift
// The fast preview (Space on a file, in the list or the contact sheet): one window that follows
// the selection of the window it was opened from. The tile's thumbnail shows at once, the
// screen-size picture replaces it when ready (Core/Previews, prefetching neighbours). Arrow keys
// step through the folder; Space or Esc closes. Files that are not images open in Quick Look.

import AppKit

final class PreviewWindow: NSWindowController, NSWindowDelegate {
    static let shared = PreviewWindow()

    private let picture = CALayer()
    private let info = NSTextField(labelWithString: "")
    private weak var source: BrowserWindowController?
    private var entry: FileEntry?
    private var shownKey: String?

    var isOpen: Bool { return window?.isVisible ?? false }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Preview"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("PhotoLabPreview")
        super.init(window: w)
        w.delegate = self
        let content = PreviewContentView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        content.onKey = { [weak self] e in self?.key(e) ?? false }
        picture.contentsGravity = .resizeAspect
        picture.minificationFilter = .trilinear
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        content.layer?.addSublayer(picture)
        content.onLayout = { [weak self] b in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.picture.frame = b.insetBy(dx: 8, dy: 28).offsetBy(dx: 0, dy: 10)
            CATransaction.commit()
        }
        info.textColor = NSColor(white: 0.75, alpha: 1)
        info.font = NSFont.systemFont(ofSize: 11)
        info.lineBreakMode = .byTruncatingMiddle
        info.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(info)
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            info.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        w.contentView = content
        if w.frame.origin == .zero { w.center() }
        NotificationCenter.default.addObserver(forName: .previewReady, object: nil, queue: .main) { [weak self] n in
            if let p = n.userInfo?["path"] as? String, p == self?.entry?.path { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pixels a screen-size preview needs (the window's screen, retina included), capped.
    private var targetPixels: Int {
        let s = window?.screen ?? NSScreen.main
        let f = s?.frame.size ?? NSSize(width: 1920, height: 1080)
        return min(3072, Int(max(f.width, f.height) * (s?.backingScaleFactor ?? 1)))
    }

    /// Show `e` (and prefetch its neighbours) for `from`.
    func show(_ e: FileEntry, neighbours: [FileEntry], from: BrowserWindowController) {
        source = from
        entry = e
        shownKey = nil
        Previews.shared.request([e] + neighbours, px: targetPixels)
        refresh()
        if !isOpen {
            showWindow(nil)
            from.window?.makeKey()            // keys keep going to the browser; the preview follows
        }
    }

    private func refresh() {
        guard let e = entry else { return }
        window?.title = e.name
        let px = targetPixels
        if let p = Previews.shared.cached(e, px: px) {
            let key = Previews.cacheKey(e, px)
            if shownKey != key {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                picture.contents = p.image
                CATransaction.commit()
                shownKey = key
            }
            info.stringValue = "\(e.name)   \(p.image.width) x \(p.image.height) shown   \(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))   \(p.method), \(Int(p.ms)) ms"
            return
        }
        // Until then: the contact sheet's thumbnail, if there is one (soft, but at once).
        let t = ThumbRequest(source: e.path, size: e.size, modified: e.modified)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.contents = Thumbnails.shared.image(t.key)
        CATransaction.commit()
        info.stringValue = "\(e.name)   loading..."
    }

    private func key(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 49, 53: close(); source?.window?.makeKeyAndOrderFront(nil); return true      // Space, Esc
        case 123, 126: source?.previewStep(-1); return true                                 // left, up
        case 124, 125: source?.previewStep(1); return true                                  // right, down
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        entry = nil
        picture.contents = nil
    }
}

final class PreviewContentView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onLayout: ((NSRect) -> Void)?
    override var acceptsFirstResponder: Bool { return true }
    override func keyDown(with event: NSEvent) { if !(onKey?(event) ?? false) { super.keyDown(with: event) } }
    override func layout() { super.layout(); onLayout?(bounds) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onLayout?(bounds) }
}
