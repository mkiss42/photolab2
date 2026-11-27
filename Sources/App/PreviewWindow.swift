// PreviewWindow.swift
// The preview for reviewing and culling (PhotoLab 1's preview, not Finder's Quick Look): one
// window following the selection of the browser window it was opened from.
//
// Images: the thumbnail at once, then a screen-size picture, then - only when the zoom needs
// more pixels than that - the full-size one (RAW: the largest embedded JPEG; others: a full
// decode). Zoom and pan are kept as an "intent" (fit / 100% / a multiple of fit) and a pan
// position stored as a fraction of the picture, so they stay put while the sharper versions
// arrive and when you move to the next shot (PhotoLab 1's design).
//   Z or double-click: fit <-> 100%   Cmd + / Cmd -: zoom steps   Cmd 0: fit
//   Cmd-scroll / pinch: zoom at the pointer   scroll or drag: pan
//   arrows: previous / next   Space or Esc: close   Cmd-E: open in the default app
// Everything else (PDF - every page, Word/Excel/text, video...): macOS's Quick Look view inside
// this window, so a mixed folder never needs a second window.

import AppKit
import Quartz

final class PreviewWindow: NSWindowController, NSWindowDelegate {
    static let shared = PreviewWindow()

    private let canvas = PreviewCanvas()
    private let info = NSTextField(labelWithString: "")
    private var quickLook: QLPreviewView?
    private weak var source: BrowserWindowController?
    private var entry: FileEntry?

    var isOpen: Bool { return window?.isVisible ?? false }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Preview"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("PhotoLabPreview")
        super.init(window: w)
        w.delegate = self
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        info.textColor = NSColor(white: 0.75, alpha: 1)
        info.font = NSFont.systemFont(ofSize: 11)
        info.lineBreakMode = .byTruncatingMiddle
        info.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(info)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -4),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            info.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        w.contentView = content
        if w.frame.origin == .zero { w.center() }
        canvas.onKey = { [weak self] e in self?.key(e) ?? false }
        canvas.onNeedsDetail = { [weak self] in self?.loadFull() }
        canvas.onZoomChange = { [weak self] in self?.updateInfo() }
        NotificationCenter.default.addObserver(forName: .previewReady, object: nil, queue: .main) { [weak self] n in
            if let p = n.userInfo?["path"] as? String, p == self?.entry?.path { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pixels a screen-size preview needs (the window's screen, retina included), capped.
    private var screenPixels: Int {
        let s = window?.screen ?? NSScreen.main
        let f = s?.frame.size ?? NSSize(width: 1920, height: 1080)
        return min(3072, Int(max(f.width, f.height) * (s?.backingScaleFactor ?? 1)))
    }

    /// Show `e` (prefetching its neighbours) for `from`. The preview becomes the key window:
    /// its keys (arrows, zoom, Esc) work at once.
    func show(_ e: FileEntry, neighbours: [FileEntry], from: BrowserWindowController) {
        Activity.during("preview: show") {
            source = from
            if entry?.path != e.path { canvas.newPicture() }
            entry = e
            if Thumbnails.route(e.ext) == .other {
                showQuickLook(e)
            } else {
                hideQuickLook()
                // Neighbours are prefetched - but not PSD/TIFF composites (hundreds of MB each).
                let pre = neighbours.filter { let r = Thumbnails.route($0.ext); return r != .other && r != .layered }
                Previews.shared.request([e] + pre, px: screenPixels)
                if canvas.wantsFull { loadFull() }
                refresh()
            }
            window?.title = e.name
            if !isOpen { showWindow(nil) }
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(quickLook == nil || quickLook!.isHidden ? canvas : quickLook)
        }
    }

    private func loadFull() {
        guard let e = entry, Thumbnails.route(e.ext) != .other else { return }
        Previews.shared.request([e], px: Previews.full)
    }

    private func refresh() {
        guard let e = entry, quickLook?.isHidden ?? true else { return }
        if let f = Previews.shared.cached(e, px: Previews.full) {
            canvas.setImage(f.image, isFull: true)
            lastMethod = "\(f.method), \(Int(f.ms)) ms (full size)"
        } else if let p = Previews.shared.cached(e, px: screenPixels) {
            canvas.setImage(p.image, isFull: false)
            lastMethod = "\(p.method), \(Int(p.ms)) ms"
        } else if let t = Thumbnails.shared.image(ThumbRequest(source: e.path, size: e.size, modified: e.modified).key) {
            canvas.setImage(t, isFull: false)
            lastMethod = "loading..."
        } else {
            lastMethod = "loading..."
        }
        updateInfo()
    }

    private var lastMethod = ""

    private func updateInfo() {
        guard let e = entry else { return }
        let size = ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)
        if quickLook != nil && !(quickLook!.isHidden) {
            info.stringValue = "\(e.name)   \(size)   Quick Look"
            return
        }
        info.stringValue = "\(e.name)   \(canvas.zoomLabel)   \(canvas.pixelsLabel)   \(size)   \(lastMethod)"
    }

    // MARK: Quick Look inside the window (non-image files)

    private func showQuickLook(_ e: FileEntry) {
        canvas.isHidden = true
        if quickLook == nil, let content = window?.contentView, let q = QLPreviewView(frame: canvas.frame, style: .normal) {
            q.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(q)
            NSLayoutConstraint.activate([
                q.topAnchor.constraint(equalTo: canvas.topAnchor), q.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
                q.leadingAnchor.constraint(equalTo: canvas.leadingAnchor), q.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            ])
            quickLook = q
        }
        quickLook?.isHidden = false
        quickLook?.previewItem = URL(fileURLWithPath: e.path) as NSURL
        updateInfo()
    }

    private func hideQuickLook() {
        guard let q = quickLook else { canvas.isHidden = false; return }
        q.previewItem = nil
        q.isHidden = true
        canvas.isHidden = false
    }

    // MARK: Keys

    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch e.keyCode {
        case 49, 53: closeAndReturn(); return true                                          // Space, Esc
        case 123, 126: source?.previewStep(-1); return true                                 // left, up
        case 124, 125: source?.previewStep(1); return true                                  // right, down
        default: break
        }
        if mods.isEmpty && ch == "z" { canvas.toggleZoom(); return true }
        if mods == [.command] && (ch == "=" || ch == "+") { canvas.stepZoom(up: true); return true }
        if mods == [.command] && ch == "-" { canvas.stepZoom(up: false); return true }
        if mods == [.command] && ch == "0" { canvas.fit(); return true }
        if mods == [.command] && (ch == "e" || ch == "o"), let p = entry?.path {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
            return true
        }
        return false
    }

    func closeAndReturn() {
        close()
        source?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        entry = nil
        canvas.clear()
        hideQuickLook()
    }
}

/// The picture with persistent zoom and pan (PhotoLab 1's _ImageView): a layer moved and scaled
/// on the GPU. State: `intent` + pan as a fraction of the picture from its centre.
final class PreviewCanvas: NSView {
    enum Intent: Equatable { case fit, actual, relative(CGFloat) }    // relative = multiple of fit
    private(set) var intent: Intent = .fit
    private var panX: CGFloat = 0, panY: CGFloat = 0                    // -0.5...0.5 of the picture
    private let picture = CALayer()
    private var image: CGImage?
    private var refSize = CGSize.zero          // the biggest version held of this picture, in pixels
    private var held: CGFloat = 0              // long side of the version on screen
    private var dragFrom: NSPoint?
    var onKey: ((NSEvent) -> Bool)?
    var onNeedsDetail: (() -> Void)?
    var onZoomChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        picture.minificationFilter = .trilinear
        picture.magnificationFilter = .linear
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var acceptsFirstResponder: Bool { return true }
    override var isFlipped: Bool { return true }

    /// Does the current intent need the full-size picture?
    var wantsFull: Bool {
        guard image != nil else { return intent != .fit }
        return scale * backing * refSize.width > CGFloat(image!.width) * 1.05
    }

    private var backing: CGFloat { return window?.backingScaleFactor ?? 2 }

    /// Points per picture pixel (of the reference size).
    private var fitScale: CGFloat {
        guard refSize.width > 0, refSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / refSize.width, bounds.height / refSize.height)
    }

    private var scale: CGFloat {
        switch intent {
        case .fit: return fitScale
        case .actual: return 1 / backing
        case .relative(let r): return fitScale * r
        }
    }

    var zoomLabel: String {
        if intent == .fit { return "Fit" }
        return "\(Int((scale * backing * 100).rounded()))%"
    }

    var pixelsLabel: String {
        guard let i = image else { return "" }
        return "\(i.width) x \(i.height)"
    }

    /// A different file: forget its sizes, keep the zoom intent and pan (between shots).
    func newPicture() {
        refSize = .zero
        image = nil
    }

    func setImage(_ img: CGImage, isFull: Bool) {
        if image === img { return }
        // Versions of one picture differ slightly in aspect; the biggest held is the reference.
        let size = CGSize(width: img.width, height: img.height)
        if size.width * size.height >= refSize.width * refSize.height { refSize = size }
        image = img
        held = max(size.width, size.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.contents = img
        CATransaction.commit()
        realize()
        if !isFull && wantsFull { onNeedsDetail?() }
    }

    func clear() {
        picture.contents = nil
        image = nil
        refSize = .zero
    }

    /// Place the picture for the current intent and pan; pan is clamped for display only (the
    /// stored pan is not changed, so a later, bigger version can reach the edges).
    private func realize() {
        guard refSize.width > 0 else { return }
        let s = scale
        let w = refSize.width * s, h = refSize.height * s
        let maxX = max(0, (w - bounds.width) / 2), maxY = max(0, (h - bounds.height) / 2)
        let dx = max(-maxX, min(maxX, panX * w)), dy = max(-maxY, min(maxY, panY * h))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        picture.position = CGPoint(x: bounds.midX - dx, y: bounds.midY - dy)
        CATransaction.commit()
        onZoomChange?()
    }

    override func layout() { super.layout(); realize() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); realize() }

    private func setIntent(_ i: Intent) {
        intent = i
        if i == .fit { panX = 0; panY = 0 }
        realize()
        if wantsFull { onNeedsDetail?() }
    }

    func toggleZoom() { setIntent(intent == .fit ? .actual : .fit) }
    func fit() { setIntent(.fit) }

    /// Cmd + / Cmd -: the next stop past the current magnification.
    func stepZoom(up: Bool) {
        let stops: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 1, 1.5, 2, 3, 4, 6, 8]
        let mag = scale * backing
        let fitMag = fitScale * backing
        if up {
            guard let s = stops.first(where: { $0 > mag + 0.001 }) else { return }
            setIntent(abs(s - 1) < 0.001 ? .actual : .relative(s / fitMag))
        } else {
            guard let s = stops.last(where: { $0 < mag - 0.001 }), s > fitMag else { setIntent(.fit); return }
            setIntent(abs(s - 1) < 0.001 ? .actual : .relative(s / fitMag))
        }
    }

    // MARK: Mouse

    override func keyDown(with event: NSEvent) { if !(onKey?(event) ?? false) { super.keyDown(with: event) } }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { toggleZoom(); return }
        dragFrom = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom, intent != .fit, refSize.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        pan(by: CGSize(width: from.x - p.x, height: from.y - p.y))
        dragFrom = p
    }

    override func mouseUp(with event: NSEvent) { dragFrom = nil }

    private func pan(by d: CGSize) {
        let s = scale
        let w = refSize.width * s, h = refSize.height * s
        let maxX = max(0, (w - bounds.width) / 2) / max(w, 1), maxY = max(0, (h - bounds.height) / 2) / max(h, 1)
        // Clamp the stored pan to what this zoom can show (no dead travel at the edges).
        panX = max(-maxX, min(maxX, panX + d.width / max(w, 1)))
        panY = max(-maxY, min(maxY, panY + d.height / max(h, 1)))
        realize()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1), at: convert(event.locationInWindow, from: nil))
        } else if intent != .fit {
            pan(by: CGSize(width: -event.scrollingDeltaX, height: -event.scrollingDeltaY))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    /// Free zoom anchored at the pointer: the picture point under it stays under it.
    private func zoom(by factor: CGFloat, at p: NSPoint) {
        guard refSize.width > 0, factor > 0 else { return }
        let old = scale
        let rel = max(1, min(40, (old * factor) / fitScale))
        let new = fitScale * rel
        // Picture point under the pointer, as a fraction from the centre, before the zoom.
        let ox = (p.x - picture.position.x) / (refSize.width * old), oy = (p.y - picture.position.y) / (refSize.height * old)
        intent = rel <= 1.0001 ? .fit : .relative(rel)
        // Keep that point under the pointer: centre offset = point - pointer offset from centre.
        panX = ox - (p.x - bounds.midX) / (refSize.width * new)
        panY = oy - (p.y - bounds.midY) / (refSize.height * new)
        if intent == .fit { panX = 0; panY = 0 }
        realize()
        if wantsFull { onNeedsDetail?() }
    }
}
