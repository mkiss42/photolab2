// TransfersPanel.swift
// The copy progress window (PhotoLab 1's fs_ops panel): one row per job with a bar, counts,
// speed and a Stop button. Appears when a job takes longer than 0.6 s, so quick copies don't
// flash it; finished rows stay 4 s, then the panel closes by itself. Reads job progress on a
// 0.25 s timer (no callbacks from the copy threads).

import AppKit

final class TransfersPanel: NSObject, NSWindowDelegate {
    static let shared = TransfersPanel()

    private var panel: NSPanel?
    private let stack = NSStackView()
    private var rows: [ObjectIdentifier: TransferRow] = [:]
    private var timer: Timer?
    private var finishedAt: [ObjectIdentifier: Date] = [:]

    func jobAdded() {
        startTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let me = self else { return }
            if TransferController.shared.jobs.contains(where: { !$0.isFinished }) { me.show() }
        }
    }

    func jobFinished() {
        tick()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 90),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            p.title = "Copy"
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.delegate = self
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            p.contentView = stack
            if let s = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: s.maxX - 480, y: s.maxY - 20))
            }
            panel = p
        }
        tick()
        panel?.orderFront(nil)
    }

    private func tick() {
        Activity.during("copy: panel") { tickNow() }
    }

    private func tickNow() {
        let jobs = TransferController.shared.jobs
        let now = Date()
        for job in jobs {
            let id = ObjectIdentifier(job)
            if job.isFinished && finishedAt[id] == nil { finishedAt[id] = now }
            if let t = finishedAt[id], now.timeIntervalSince(t) > 4 {
                rows[id]?.removeFromSuperview()
                rows.removeValue(forKey: id)
                finishedAt.removeValue(forKey: id)
                TransferController.shared.forget(job)
                continue
            }
            let row: TransferRow
            if let r = rows[id] { row = r } else {
                row = TransferRow(job: job)
                rows[id] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 432).isActive = true
            }
            row.refresh()
        }
        if TransferController.shared.jobs.isEmpty {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
        } else if let p = panel, p.isVisible {
            let h = stack.fittingSize.height
            if abs(p.contentRect(forFrameRect: p.frame).height - h) > 1 {
                var f = p.frame
                let newFrame = p.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 460, height: h))
                f.origin.y += f.height - newFrame.height
                f.size = newFrame.size
                p.setFrame(f, display: true)
            }
        }
    }

    /// Closing the window hides it; the jobs keep running.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

final class TransferRow: NSStackView {
    let job: TransferJob
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let stop = NSButton()

    init(job: TransferJob) {
        self.job = job
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = NSColor.secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        stop.bezelStyle = .regularSquare
        stop.isBordered = false
        stop.image = NSImage(named: NSImage.stopProgressFreestandingTemplateName)
        stop.imagePosition = .imageOnly
        stop.target = self
        stop.action = #selector(stopPressed(_:))
        stop.toolTip = "Stop: the item being copied is removed, finished items stay"
        let barRow = NSStackView(views: [bar, stop])
        barRow.orientation = .horizontal
        barRow.spacing = 6
        bar.widthAnchor.constraint(equalToConstant: 404).isActive = true
        for v in [title, barRow, detail] as [NSView] { addArrangedSubview(v) }
        title.widthAnchor.constraint(equalToConstant: 432).isActive = true
        detail.widthAnchor.constraint(equalToConstant: 432).isActive = true
        bar.startAnimation(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func stopPressed(_ sender: Any?) {
        job.cancel()
        Log.info("\(job.kind.rawValue) \(job.id): Stop pressed")
        refresh()
    }

    func refresh() {
        let p = job.progress
        title.stringValue = job.title
        let bytes = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch p.state {
        case .waiting:
            detail.stringValue = job.isCancelled ? "Stopping..." : "Waiting for the copy before it on this volume..."
        case .scanning:
            detail.stringValue = job.isCancelled ? "Stopping..." : "Counting files... \(p.totalFiles)"
        case .running:
            var s = "\(p.doneFiles) of \(p.totalFiles) file\(p.totalFiles == 1 ? "" : "s")"
            if p.totalBytes > 0 { s += " - \(bytes(p.doneBytes)) of \(bytes(p.totalBytes))" }
            if let t0 = p.started {
                let secs = Date().timeIntervalSince(t0)
                if secs > 1 && p.doneBytes > 0 { s += String(format: " - %.0f MB/s", Double(p.doneBytes) / 1_000_000 / secs) }
            }
            if job.isCancelled { s = "Stopping... " + s } else if !p.current.isEmpty { s += " - " + p.current }
            detail.stringValue = s
        case .done:
            detail.stringValue = "Done: \(p.doneFiles) file\(p.doneFiles == 1 ? "" : "s")" + (p.skipped > 0 ? ", \(p.skipped) skipped" : "")
        case .stopped:
            detail.stringValue = "Stopped after \(p.doneFiles) file\(p.doneFiles == 1 ? "" : "s"). Nothing half-copied was left."
        case .failed:
            detail.stringValue = "\(p.failures.count) problem\(p.failures.count == 1 ? "" : "s"), \(p.doneFiles) file\(p.doneFiles == 1 ? "" : "s") done"
        }
        let running = p.state == .running && p.totalBytes > 0
        if running {
            if bar.isIndeterminate { bar.isIndeterminate = false; bar.stopAnimation(nil) }
            bar.doubleValue = Double(p.doneBytes) / Double(max(p.totalBytes, 1))
        } else if job.isFinished {
            bar.isIndeterminate = false
            bar.stopAnimation(nil)
            bar.doubleValue = p.state == .done ? 1 : bar.doubleValue
        }
        stop.isEnabled = !job.isFinished && !job.isCancelled
    }
}
