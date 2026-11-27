// QuickProgress.swift
// 0.18.7: the small progress sheet for metadata writes - one bar, "N of M", Stop. It appears at once and
// disappears the moment the work ends. The work only bumps a counter; the sheet looks at it 10 times a
// second, so showing progress costs the work nothing (no message to the screen per file).

import AppKit

final class QuickProgress: NSObject {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let stopButton: NSButton
    private weak var parent: NSWindow?
    private var timer: Timer?
    private let lock = NSLock()
    private var done = 0
    private var total = 0
    private var stopped = false
    private let title: String
    private var asSheet = false

    init(title: String, total: Int, parent: NSWindow?) {
        self.title = title
        self.total = total
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        stopButton = NSButton(title: "Stop", target: nil, action: nil)
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        let v = panel.contentView!
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(1, total))
        bar.doubleValue = 0
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        stopButton.keyEquivalent = "\u{1b}"
        label.lineBreakMode = .byTruncatingTail
        for x in [bar, label, stopButton] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
        ])
        updateUI()
    }

    func show() {
        if let w = parent, w.attachedSheet == nil {
            asSheet = true
            w.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.orderFront(nil)
        }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateUI() }
        RunLoop.main.add(t, forMode: .commonModes)
        timer = t
    }

    /// From any thread.
    func set(done d: Int, total t: Int) {
        lock.lock(); done = d; total = t; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    @objc private func stop(_ sender: Any?) {
        lock.lock(); stopped = true; lock.unlock()
        stopButton.isEnabled = false
        label.stringValue = "Stopping after the pictures being written now\u{2026}"
    }

    private func updateUI() {
        lock.lock(); let d = done, t = total, s = stopped; lock.unlock()
        if s { return }
        bar.maxValue = Double(max(1, t))
        bar.doubleValue = Double(min(d, t))
        label.stringValue = "\(title): \(d) of \(t)"
    }

    /// At once, when the work is done.
    func close() {
        timer?.invalidate()
        timer = nil
        if asSheet, let w = parent { w.endSheet(panel) } else { panel.orderOut(nil) }
    }
}
