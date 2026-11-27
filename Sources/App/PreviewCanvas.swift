// PreviewCanvas.swift  (ported from PhotoLab 2 0.9.2, PhotoLab 1's culling behaviour)
// The picture in the preview window, on a CALayer: fit or 1:1 (Z / double-click), Cmd +/-/0 in
// steps, Cmd-scroll and pinch zoom at the pointer, drag or scroll to pan. The zoom is kept as an
// intent (fit / 100% / a multiple of fit) and the pan as a fraction of the picture, so both carry
// over from shot to shot; Z out and Z in again comes back to the same detail. The final pixel size
// (from the file's header) lays the frame out at once - Z goes straight to the final size, soft
// until the sharp version arrives.

import AppKit
import QuartzCore

final class PreviewCanvas: NSView {
    enum Intent: Equatable { case fit, actual, relative(CGFloat) }    // relative = multiple of fit
    private(set) var intent: Intent = .fit
    private var panX: CGFloat = 0, panY: CGFloat = 0                    // -0.5...0.5 of the picture
    private let picture = CALayer()
    private var image: CGImage?
    private var refSize = CGSize.zero          // the biggest version held of this picture, in pixels
    private var held: CGFloat = 0              // long side of the version on screen
    private var dragFrom: NSPoint?
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
    override var acceptsFirstResponder: Bool { return false }   // the list keeps the keys (Find's rule)
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
        finalKnown = false
        image = nil
    }

    private var finalKnown = false
    var hasPicture: Bool { return image != nil }

    /// The size the full picture will have (from the file's header): the frame is laid out at
    /// that size from now on, and every smaller version is stretched into it - Z goes straight
    /// to the final size (soft until the sharp version replaces it, without moving).
    func setFinalSize(_ s: CGSize) {
        guard s.width > 0, s.height > 0, refSize != s else { return }
        refSize = s
        finalKnown = true
        realize()
        if wantsFull { onNeedsDetail?() }
    }

    func setImage(_ img: CGImage, isFull: Bool) {
        if image === img { return }
        // Versions of one picture differ slightly in aspect; the biggest held is the reference.
        let size = CGSize(width: img.width, height: img.height)
        if !finalKnown && size.width * size.height >= refSize.width * refSize.height { refSize = size }
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

    /// The pan of the last zoomed-in view: Z out to glance at the whole shot, Z in again and
    /// you are back on the same detail (PhotoLab 1).
    private var savedPan: (CGFloat, CGFloat) = (0, 0)

    private func setIntent(_ i: Intent) {
        if intent != .fit && i == .fit { savedPan = (panX, panY) }
        if intent == .fit && i != .fit { (panX, panY) = savedPan }
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
