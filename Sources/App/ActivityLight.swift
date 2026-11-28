// ActivityLight.swift  (PhotoLab, P15)
// A small light in each pane's status bar: orange while PhotoLab reads or writes on a network volume,
// blue on this Mac's disks, off when idle. Driven by the I/O logs' own counting (IOLog.activity), at
// most 4 updates a second, and one timer to switch it off - nothing at all runs while idle.
// The tooltip says what PhotoLab is busy with.

import AppKit

final class ActivityLight: NSView {
    static let changed = Notification.Name("PhotoLabActivity")
    private static let lock = NSLock()
    private static var last = Date.distantPast
    private static var lastNet = false
    /// When the light was last told about each kind of activity (main thread).
    private(set) static var netUntil = Date.distantPast
    private(set) static var diskUntil = Date.distantPast

    /// From any thread: something was read or written.
    static func pulse(network: Bool) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(last) >= 0.25 || network != lastNet
        if due { last = now; lastNet = network }
        lock.unlock()
        guard due else { return }
        DispatchQueue.main.async {
            let until = Date().addingTimeInterval(0.6)
            if network { netUntil = until } else { diskUntil = until }
            NotificationCenter.default.post(name: changed, object: nil)
            offTimer?.invalidate()
            offTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { _ in
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
    }
    private static var offTimer: Timer?

    static func install() {
        IOLog.activity = { pulse(network: $0) }
    }

    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        observer = NotificationCenter.default.addObserver(forName: ActivityLight.changed, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        toolTip = "Activity: orange = reading/writing on a network volume, blue = on this Mac's disks"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        let net = ActivityLight.netUntil > now, disk = ActivityLight.diskUntil > now
        let c: NSColor = net ? .systemOrange : (disk ? .systemBlue : ThemeManager.shared.secondaryText.withAlphaComponent(0.25))
        c.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        if net || disk { toolTip = "Busy: " + Activity.shared.describe }
    }
}
