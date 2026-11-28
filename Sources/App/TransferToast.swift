// TransferToast.swift  (PhotoLab, from PhotoLab 2's transfers panel)
// Copies, moves and FTP transfers in a small panel at the bottom right of the screen (a "toaster"):
// what is being copied, one bar, the bytes and time left, Stop, and Details... which opens the full
// Copies window. It does not take the keyboard and goes away a moment after everything is finished.
// Window > "Copy Progress": Small Panel (default) or Copies Window (Find's, opened by itself).

import AppKit

final class TransferToast: NSObject {
    static let shared = TransferToast()

    /// "toast" (default) or "window".
    static var style: String {
        get { return UserDefaults.standard.string(forKey: "transferProgressStyle") ?? "toast" }
        set { UserDefaults.standard.set(newValue, forKey: "transferProgressStyle") }
    }

    private var panel: NSPanel?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let detailsButton = NSButton(title: "Details\u{2026}", target: nil, action: nil)
    private var timer: Timer?
    private var hideAt: Date?

    private func build() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
                        styleMask: [.titled, .utilityWindow, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
        p.title = "Copying"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.level = .floating
        let v = p.contentView!
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = NSColor.secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        stopButton.controlSize = .small
        stopButton.bezelStyle = .rounded
        detailsButton.target = self
        detailsButton.action = #selector(details(_:))
        detailsButton.controlSize = .small
        detailsButton.bezelStyle = .rounded
        for x in [title, detail, bar, stopButton, detailsButton] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            detailsButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detailsButton.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: detailsButton.leadingAnchor, constant: -6),
            stopButton.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
        ])
        return p
    }

    /// A copy started (CopiesCenter): show the panel while anything runs.
    func taskStarted() {
        if panel == nil { panel = build() }
        guard let p = panel else { return }
        hideAt = nil
        if !p.isVisible {
            let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.minY + 16))
            p.orderFront(nil)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.update() }
        }
        update()
    }

    private func update() {
        guard let p = panel else { return }
        let running = CopiesCenter.shared.tasks.filter { $0.state == "running" }
        if running.isEmpty {
            if hideAt == nil {
                hideAt = Date().addingTimeInterval(2.5)
                let last = CopiesCenter.shared.tasks.last
                title.stringValue = last.map { "Done: " + $0.title } ?? "Done"
                detail.stringValue = last?.resultLine ?? ""
                bar.doubleValue = 1
                stopButton.isEnabled = false
            } else if Date() >= hideAt! {
                p.orderOut(nil)
                timer?.invalidate(); timer = nil
                hideAt = nil
            }
            return
        }
        stopButton.isEnabled = true
        let t = running[0]
        let s = t.progress.state()
        title.stringValue = running.count > 1 ? "\(t.title)  (+\(running.count - 1) more)" : t.title
        if t.indeterminate || s.bytesTotal <= 0 {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            detail.stringValue = s.name.isEmpty ? "Working\u{2026}" : Paths.lastComponent(s.name)
        } else {
            bar.isIndeterminate = false
            bar.doubleValue = Double(s.bytesDone) / Double(max(1, s.bytesTotal))
            let file = s.filesTotal > 0 ? "File \(min(s.filesDone + 1, s.filesTotal)) of \(s.filesTotal)" : ""
            detail.stringValue = [file, Listing.sizeText(s.bytesDone) + " of " + Listing.sizeText(s.bytesTotal)]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    @objc private func stop(_ sender: Any?) {
        for t in CopiesCenter.shared.tasks where t.state == "running" {
            if let f = t.onStop { f() } else { t.cancel.value = 1 }
        }
    }

    @objc private func details(_ sender: Any?) {
        CopyQueueWindowController.show(focus: true)
    }
}
