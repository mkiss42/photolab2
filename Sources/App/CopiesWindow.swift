// CopiesWindow.swift
// 0.17: copies, moves and FTP transfers run in the background and show in a separate Copies window,
// never blocking the window you work in. Each one shows:
//   - an overall bar and "File x of y, 1.2 GB of 4.0 GB, 45 MB/s, 1 min 20 s left";
//   - a bar for the file (or folder) in progress, with its name;
//   - Stop (the item in progress stops safely: its unfinished copy is removed the usual way);
//   - "Show diagnostics": a time-stamped list of every step (remembered on or off).
// The copy queue is listed below the running copies, in the same window (Window > Copies).
// The window opens by itself when something takes longer than a moment, and closes by itself when
// everything it opened for is finished (unless you opened it yourself).

import AppKit

final class CopyTask {
    let id = UUID().uuidString
    let title: String
    let progress = TransferProgress()
    let cancel = AtomicInt()
    /// running, done, failed, stopped
    var state = "running"
    var resultLine = ""
    var endedAt: Date?
    /// Duplicate, Compress: no byte counts, just a moving bar.
    let indeterminate: Bool
    /// Stop: by default sets `cancel`; the copy queue pauses its copy instead.
    var onStop: (() -> Void)?
    fileprivate var samples: [(Date, Int64)] = []
    fileprivate var partialBytes: Int64 = 0
    fileprivate var partialCheckedAt = Date.distantPast

    init(title: String, indeterminate: Bool = false) {
        self.title = title
        self.indeterminate = indeterminate
        // Stop is checked by the copy before every file (0.17.1), not only between the items.
        let c = cancel
        progress.stopCheck = { c.value != 0 }
    }

    var isCancelled: () -> Bool {
        let c = cancel
        return { c.value != 0 }
    }
}

final class CopiesCenter {
    static let shared = CopiesCenter()
    private(set) var tasks: [CopyTask] = []
    /// The window was opened by Find (not by you): it closes when everything is finished.
    fileprivate var autoOpened = false
    var onChange: (() -> Void)?

    var activeCount: Int { return tasks.filter { $0.state == "running" }.count }

    /// Register a task that is running (the work is started by the caller).
    func add(_ t: CopyTask) {
        tasks.append(t)
        t.progress.note("Started: \(t.title)")
        App.log.info("Copies: started \(Ascii.clean(t.title))")
        // Shown if it is still running after a moment (quick copies don't flash a window).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let s = self, t.state == "running" else { return }
            if !(CopyQueueWindowController.shared?.window?.isVisible ?? false) { s.autoOpened = true }
            CopyQueueWindowController.show(focus: false)
        }
        notify()
    }

    func finish(_ t: CopyTask, state: String, line: String) {
        t.state = state
        t.resultLine = line
        t.endedAt = Date()
        t.progress.note("Finished: \(line)")
        App.log.info("Copies: \(state) \(Ascii.clean(t.title)) - \(Ascii.clean(line))")
        notify()
        // Finished ones stay listed a little while, then go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let s = self else { return }
            s.tasks = s.tasks.filter { $0 !== t || $0.state == "running" }
            s.notify()
        }
        // Opened by Find and nothing else running or queued: close after a short look.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let s = self, s.autoOpened, s.activeCount == 0, !CopyQueueManager.shared.isRunning else { return }
            s.autoOpened = false
            CopyQueueWindowController.shared?.window?.orderOut(nil)
        }
    }

    /// Opened by you (Window > Copies): it stays open.
    func autoOpenedReset() { autoOpened = false }

    func notify() {
        onChange?()
        NotificationCenter.default.post(name: .findCopiesChanged, object: nil)
    }

    /// Run `work` in the background as a task. `done` is called on the main thread.
    func run(_ title: String, indeterminate: Bool = false, work: @escaping (CopyTask) -> BatchReport,
             done: @escaping (BatchReport) -> Void) {
        let t = CopyTask(title: title, indeterminate: indeterminate)
        add(t)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work(t)
            DispatchQueue.main.async {
                let line = "\(r.done.count) done" + (r.skipped.isEmpty ? "" : ", \(r.skipped.count) skipped")
                    + (r.failed.isEmpty ? "" : ", \(r.failed.count) failed") + (r.cancelled ? ", stopped" : "")
                self.finish(t, state: r.cancelled ? "stopped" : (r.failed.isEmpty ? "done" : "failed"), line: line)
                done(r)
            }
        }
    }
}

extension Notification.Name {
    static let findCopiesChanged = Notification.Name("FindCopiesChanged")
}

/// One running (or just finished) copy in the Copies window.
final class CopyTaskView: NSView {
    let task: CopyTask
    private let title = NSTextField(labelWithString: "")
    private let overall = NSProgressIndicator()
    private let line1 = NSTextField(labelWithString: "")
    private let current = NSProgressIndicator()
    private let line2 = NSTextField(labelWithString: "")
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let diagCheck = NSButton(checkboxWithTitle: "Show diagnostics", target: nil, action: nil)
    private let logScroll = NSScrollView()
    private let logView = NSTextView()
    private var logShown = 0
    private var logHeight: NSLayoutConstraint!

    init(_ t: CopyTask) {
        task = t
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 110))
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        title.stringValue = t.title
        for b in [overall, current] {
            b.style = .bar
            b.isIndeterminate = t.indeterminate
            b.minValue = 0
            b.maxValue = 1
            b.controlSize = .small
        }
        if t.indeterminate { overall.startAnimation(nil) }
        current.isHidden = t.indeterminate
        line2.isHidden = t.indeterminate
        for l in [line1, line2] {
            l.font = NSFont.systemFont(ofSize: 11)
            l.lineBreakMode = .byTruncatingMiddle
        }
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.target = self
        stop.action = #selector(stopPressed(_:))
        diagCheck.controlSize = .small
        diagCheck.font = NSFont.systemFont(ofSize: 11)
        diagCheck.state = Prefs.copyDiagnostics ? .on : .off
        diagCheck.target = self
        diagCheck.action = #selector(diagToggled(_:))
        logView.isEditable = false
        logView.font = NSFont.userFixedPitchFont(ofSize: 10)
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logView.autoresizingMask = [.width]
        for v in [title, overall, line1, current, line2, stop, diagCheck, logScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        logHeight = logScroll.heightAnchor.constraint(equalToConstant: Prefs.copyDiagnostics ? 120 : 0)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: stop.leadingAnchor, constant: -8),
            stop.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            stop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            overall.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            overall.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            overall.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line1.topAnchor.constraint(equalTo: overall.bottomAnchor, constant: 3),
            line1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            current.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 6),
            current.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            current.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line2.topAnchor.constraint(equalTo: current.bottomAnchor, constant: 3),
            line2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line2.trailingAnchor.constraint(equalTo: diagCheck.leadingAnchor, constant: -8),
            diagCheck.centerYAnchor.constraint(equalTo: line2.centerYAnchor),
            diagCheck.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            logScroll.topAnchor.constraint(equalTo: line2.bottomAnchor, constant: 6),
            logScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            logHeight,
            logScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        logScroll.isHidden = !Prefs.copyDiagnostics
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func stopPressed(_ sender: Any?) {
        task.progress.note("Stop pressed: the item in progress stops safely")
        if let s = task.onStop { s() } else { task.cancel.value = 1 }
        stop.isEnabled = false
        line2.stringValue = "Stopping safely\u{2026}"
    }

    @objc private func diagToggled(_ sender: NSButton) {
        Prefs.copyDiagnostics = sender.state == .on
        logScroll.isHidden = sender.state != .on
        logHeight.constant = sender.state == .on ? 120 : 0
        NotificationCenter.default.post(name: .findCopiesChanged, object: nil)
    }

    /// Update the bars and lines (every half second while the window is open).
    func refresh() {
        let t = task
        if t.state != "running" {
            stop.isHidden = true
            overall.stopAnimation(nil)
            overall.isIndeterminate = false
            overall.doubleValue = 1
            current.isHidden = true
            line1.stringValue = (t.state == "done" ? "Finished: " : (t.state == "stopped" ? "Stopped: " : "Finished with problems: ")) + t.resultLine
            line2.stringValue = ""
            appendLog()
            return
        }
        if t.indeterminate {
            line1.stringValue = "Working\u{2026} \(TransferProgress.timeText(Date().timeIntervalSince(t.progress.startedAt)))"
            appendLog()
            return
        }
        let s = t.progress.state()
        let now = Date()
        // How far the item in progress is:
        //  - a copy reports each file inside it (0.17.1): finished files + the size of the file being
        //    written now (one quick look at one file);
        //  - FTP: curl's own percentage;
        //  - otherwise the size of its unfinished copy (looked at less often for big folders).
        var cur: Int64 = 0
        var fileDone: Int64 = 0, fileTotal: Int64 = 0, fileName = s.name
        if let inner = s.innerCopy {
            if now.timeIntervalSince(t.partialCheckedAt) > 0.25 {
                var e: Int32 = 0
                t.partialBytes = Sys.lstatInfo(inner, &e).map { $0.isDirectory ? 0 : $0.size } ?? 0
                t.partialCheckedAt = now
            }
            fileDone = min(t.partialBytes, s.innerSize)
            fileTotal = s.innerSize
            fileName = s.innerName
            cur = s.innerBytesDone + fileDone
        } else if s.currentDone > 0 || s.partial == nil {
            cur = s.currentDone
            fileDone = s.currentDone
            fileTotal = s.currentTotal
            t.partialBytes = 0
        } else if let p = s.partial {
            if now.timeIntervalSince(t.partialCheckedAt) > (s.currentFiles > 50 ? 2 : 0.5) {
                t.partialBytes = TransferProgress.bytesNow(p)
                t.partialCheckedAt = now
            }
            cur = t.partialBytes
            fileDone = cur
            fileTotal = s.currentTotal
        }
        cur = min(cur, s.currentTotal)
        let done = s.bytesDone + cur
        t.samples.append((now, done))
        t.samples = t.samples.filter { now.timeIntervalSince($0.0) <= 6 }
        var speed = 0.0
        if let first = t.samples.first, now.timeIntervalSince(first.0) > 0.8 {
            speed = Double(done - first.1) / now.timeIntervalSince(first.0)
        }
        let total = max(s.bytesTotal, 1)
        overall.doubleValue = Double(done) / Double(total)
        let left = speed > 0 ? Double(s.bytesTotal - done) / speed : Double.nan
        let fileNo = min(s.filesTotal, s.filesDone + s.innerFilesDone + (s.name.isEmpty ? 0 : 1))
        line1.stringValue = "File \(fileNo) of \(s.filesTotal)  \u{00B7}  \(TransferProgress.bytesText(done)) of \(TransferProgress.bytesText(s.bytesTotal))"
            + (speed > 0 ? "  \u{00B7}  \(TransferProgress.bytesText(Int64(speed)))/s  \u{00B7}  \(TransferProgress.timeText(left)) left" : "")
        // The second bar is the single file being copied now - only worth showing when there are several.
        let several = s.filesTotal > 1
        current.isHidden = !several
        if s.name.isEmpty || !several {
            current.doubleValue = 0
            line2.stringValue = s.name.isEmpty || several ? "" : "\(s.name)"
        } else {
            current.doubleValue = fileTotal > 0 ? Double(fileDone) / Double(fileTotal) : 0
            line2.stringValue = "This file: \(fileName)  \u{00B7}  \(TransferProgress.bytesText(fileDone)) of \(TransferProgress.bytesText(fileTotal))"
        }
        appendLog()
    }

    private func appendLog() {
        guard !logScroll.isHidden else { return }
        let lines = task.progress.logLines(from: logShown)
        guard !lines.isEmpty else { return }
        logShown += lines.count
        let text = lines.map { String(format: "+%7.1fs  ", $0.0) + Ascii.clean($0.1) }.joined(separator: "\n") + "\n"
        let tm = ThemeManager.shared
        logView.textStorage?.append(NSAttributedString(string: text, attributes: [.foregroundColor: tm.text, .font: NSFont.userFixedPitchFont(ofSize: 10) ?? NSFont.systemFont(ofSize: 10)]))
        logView.scrollToEndOfDocument(nil)
    }

    /// The diagnostics as numbered plain lines (Copy Report).
    func reportLines() -> [String] {
        let all = task.progress.logLines(from: 0)
        return all.enumerated().map { String(format: "C%03d +%.1fs ", $0.offset + 1, $0.element.0) + Ascii.clean($0.element.1) } + ["Total: \(all.count) lines"]
    }
}


/// A top-to-bottom document view for the list of running copies.
final class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}
