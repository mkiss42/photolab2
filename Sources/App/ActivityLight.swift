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
        IOLog.waitBegin = { begin(network: $0) }
        IOLog.waitEnd = { end($0) }
    }

    // MARK: Waiting (red): a read on a share that has not come back for over 0.7 s.
    private static var waits: [Int: (start: Date, net: Bool)] = [:]
    private static var nextToken = 0
    private static var checking = false
    static let stallSeconds = 0.7

    static func begin(network: Bool) -> Int {
        lock.lock()
        nextToken += 1
        let t = nextToken
        if network { waits[t] = (Date(), true) }
        let start = network && !checking
        if start { checking = true }
        lock.unlock()
        if start { DispatchQueue.main.async { scheduleCheck() } }
        return t
    }

    static func end(_ t: Int) {
        lock.lock()
        waits.removeValue(forKey: t)
        lock.unlock()
    }

    /// Seconds the oldest unfinished share read has been waiting (0: none).
    static var waitingFor: Double {
        lock.lock(); defer { lock.unlock() }
        guard let oldest = waits.values.map({ $0.start }).min() else { return 0 }
        return Date().timeIntervalSince(oldest)
    }

    /// Main thread: while share reads are under way, look every 0.25 s (stops when none is left).
    private static func scheduleCheck() {
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
            NotificationCenter.default.post(name: changed, object: nil)
            lock.lock()
            let more = !waits.isEmpty
            if !more { checking = false }
            lock.unlock()
            if more { scheduleCheck() }
        }
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
        let wait = ActivityLight.waitingFor
        let stalled = wait >= ActivityLight.stallSeconds
        let net = ActivityLight.netUntil > now || wait > 0, disk = ActivityLight.diskUntil > now
        let c: NSColor = stalled ? .systemRed : (net ? .systemOrange : (disk ? .systemBlue : ThemeManager.shared.secondaryText.withAlphaComponent(0.25)))
        c.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        // What it is doing: PhotoLab's own label for bigger jobs; otherwise what the light saw.
        let job = Activity.shared.describe
        let known = !job.isEmpty && job.lowercased() != "idle"
        if stalled {
            toolTip = String(format: "Waiting for the server: no answer for %.1f s", wait) + (known ? " (" + job + ")" : "")
        } else if net || disk {
            toolTip = known ? "Busy: " + job : (net ? "Reading / writing on a network volume" : "Reading / writing on this Mac's disks")
        } else {
            toolTip = "Idle. Orange = network volume, blue = this Mac's disks, red = waiting for a server"
        }
    }
}
