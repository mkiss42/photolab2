// CopyQueueWindow.swift
// 0.16: the copy queue (rules and runner in Core/CopyQueue.swift).
// - Add: select items, File > Add to Copy Queue... (to the other pane's folder, or one you choose),
//   now or at a set time; for a set time Find can ask macOS to wake the Mac a minute before.
// - 0.17: Window > Copies: running copies with progress on top, the queue below: with Start Now, Pause, Resume, Schedule..., Move Up/Down, Remove,
//   Clear Finished and Report (numbered plain lines for AutoType).
// - Copies run one at a time in the background with Find's checked copy; while one runs the Mac
//   doesn't go to sleep by itself. If the Mac was asleep at the set time (and not woken), the copy
//   starts as soon as Find runs again on an awake Mac. Find must be running for a copy to run.

import AppKit

final class CopyQueueManager {
    static let shared = CopyQueueManager()

    let queue: CopyQueue
    private var timer: Timer?
    private(set) var runningID: String?
    private let pauseFlag = AtomicInt()
    /// The window, told whenever something changed.
    var onChange: (() -> Void)?
    private var path: String { return Paths.join(App.files.supportDir, "copyqueue.json") }

    private init() {
        var jobs: [CopyJob] = []
        let p = Paths.join(App.files.supportDir, "copyqueue.json")
        if let d = FileManager.default.contents(atPath: p), let j = CopyQueue.decode(d) { jobs = j }
        queue = CopyQueue(jobs: jobs)
    }

    var isRunning: Bool { return runningID != nil }

    func start() {
        let waiting = queue.snapshot().filter { $0.status == .waiting || $0.status == .scheduled }.count
        if waiting > 0 { App.log.info("Copy queue: \(waiting) copies waiting or scheduled") }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func save() {
        if let d = queue.encode() { _ = App.files.writeData(d, to: path) }
        onChange?()
    }

    func add(_ j: CopyJob) {
        queue.add(j)
        App.log.info("Copy queue: added \(Ascii.clean(j.title)) (\(j.sources.count) items to \(j.destination); clash \(j.clash)\(j.startAt.map { "; at \(CopyQueueManager.dateText($0))" } ?? "; now"))")
        save()
        tick()
    }

    /// Start the next copy that is due (one at a time).
    func tick() {
        guard runningID == nil, let j = queue.nextDue(now: Date().timeIntervalSince1970) else { return }
        run(j)
    }

    private func run(_ job: CopyJob) {
        runningID = job.id
        pauseFlag.value = 0
        queue.update(job.id) { $0.status = .running }
        save()
        let assertion = Power.keepAwake("Find copy queue: \(job.title)")
        App.log.info("Copy queue: started \(Ascii.clean(job.title))")
        // 0.17: shown in the Copies window with progress; Stop there pauses the queued copy.
        let task = CopyTask(title: "Copy queue: \(job.title) to \u{201C}\(Paths.lastComponent(job.destination))\u{201D}")
        task.onStop = { [weak self] in self?.pause(job.id) }
        let pf = pauseFlag
        task.progress.stopCheck = { pf.value == 1 }
        CopiesCenter.shared.add(task)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let s = self else { return }
            let flag = s.pauseFlag
            task.progress.plan(job.remaining)
            let end = CopyQueueRunner.run(job, ops: App.ops, now: { Date().timeIntervalSince1970 },
                                          pauseRequested: { flag.value == 1 }, transfer: task.progress,
                                          progress: { j, _ in
                                              s.queue.update(j.id) { $0 = j; $0.status = .running }
                                              DispatchQueue.main.async { s.save() }
                                          })
            DispatchQueue.main.async {
                Power.release(assertion)
                CopiesCenter.shared.finish(task, state: end.status == .paused ? "stopped" : (end.status == .done ? "done" : "failed"),
                                           line: end.status == .paused ? "paused (Resume in the queue below)" : "\(end.copiedCount) copied, \(end.skippedCount) skipped, \(end.problems.count) problems")
                s.queue.update(end.id) { $0 = end }
                s.runningID = nil
                for l in CopyQueueRunner.report(end, dateText: CopyQueueManager.dateText) { App.log.info("Copy queue: \(l)") }
                NotificationCenter.default.post(name: .findFoldersChanged, object: nil, userInfo: ["folders": [end.destination]])
                s.save()
                if end.status != .paused { s.tick() }
            }
        }
    }

    func pause(_ id: String) {
        if runningID == id {
            pauseFlag.value = 1
            App.log.info("Copy queue: pausing (the item in progress stops safely)")
        } else {
            queue.update(id) { if $0.status == .waiting || $0.status == .scheduled { $0.status = .paused } }
            save()
        }
    }

    func resume(_ id: String) {
        queue.update(id) { if $0.status == .paused || $0.status == .stopped { $0.status = $0.startAt.map { $0 > Date().timeIntervalSince1970 } == true ? .scheduled : .waiting } }
        save()
        tick()
    }

    func startNow(_ id: String) {
        queue.update(id) { j in
            if j.status == .running || j.status == .done { return }
            j.startAt = nil
            j.status = .waiting
        }
        save()
        tick()
    }

    /// Set (or change) the time; with `wake`, macOS is asked (administrator password) to wake the Mac.
    func schedule(_ id: String, at t: Double, wake: Bool) -> String? {
        var note: String? = nil
        var w = wake
        if wake {
            if let e = Power.scheduleWake(CopyQueueRunner.wakeDate(t)) { note = e; w = false }
        }
        queue.update(id) { j in
            if j.status == .running || j.status == .done { return }
            j.startAt = t
            j.wake = w
            j.status = .scheduled
        }
        App.log.info("Copy queue: scheduled for \(CopyQueueManager.dateText(t))\(w ? " (Mac will wake a minute before)" : "")\(note.map { " - wake-up not set: \($0)" } ?? "")")
        save()
        return note
    }

    func remove(_ id: String) -> Bool {
        let ok = queue.remove(id)
        save()
        return ok
    }

    /// Quitting: a running copy is stopped safely (its item starts again next time). Waits at most 15 s.
    func stopForQuit() {
        guard runningID != nil else { return }
        pauseFlag.value = 1
        let until = Date().addingTimeInterval(15)
        while runningID != nil && Date() < until {
            #if swift(>=4.2)
            RunLoop.current.run(mode: RunLoop.Mode.default, before: Date().addingTimeInterval(0.1))
            #else
            RunLoop.current.run(mode: RunLoopMode.defaultRunLoopMode, before: Date().addingTimeInterval(0.1))
            #endif
        }
        // Whatever happens, next time it is in the list again, waiting.
        queue.update(runningID ?? "") { $0.status = .waiting }
        save()
    }

    static func dateText(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

// MARK: - The window

final class CopyQueueWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static var shared: CopyQueueWindowController?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var jobs: [CopyJob] = []
    private var buttons: [String: NSButton] = [:]

    /// 0.17: running copies (top) and the copy queue (below).
    private let tasksStack = NSStackView()
    private let tasksScroll = NSScrollView()
    private let noTasks = NSTextField(labelWithString: "Nothing is being copied right now.")
    private var taskViews: [CopyTaskView] = []
    private var timer: Timer?

    /// `focus`: bring it to the front and make it the key window (Window > Copies); false when it opens
    /// by itself during a copy, so the window you work in stays the active one.
    static func show(focus: Bool = true) {
        if shared == nil { shared = CopyQueueWindowController() }
        if focus {
            CopiesCenter.shared.autoOpenedReset()
            shared?.showWindow(nil)
            shared?.window?.makeKeyAndOrderFront(nil)
        } else {
            shared?.window?.orderFront(nil)
        }
        shared?.reload()
        shared?.syncTasks()
    }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Copies"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 600, height: 420)
        super.init(window: w)
        build()
        w.center()
        CopyQueueManager.shared.onChange = { [weak self] in self?.reload() }
        CopiesCenter.shared.onChange = { [weak self] in self?.syncTasks() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let s = self, s.window?.isVisible == true else { return }
            for v in s.taskViews { v.refresh() }
        }
    }

    /// One view per running (or just finished) copy.
    func syncTasks() {
        let tasks = CopiesCenter.shared.tasks
        for v in taskViews where !tasks.contains(where: { $0 === v.task }) {
            tasksStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        taskViews = taskViews.filter { v in tasks.contains(where: { $0 === v.task }) }
        for t in tasks where !taskViews.contains(where: { $0.task === t }) {
            let v = CopyTaskView(t)
            v.translatesAutoresizingMaskIntoConstraints = false
            tasksStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: tasksStack.widthAnchor).isActive = true
            taskViews.append(v)
        }
        noTasks.isHidden = !taskViews.isEmpty
        for v in taskViews { v.refresh() }
        if let w = window { ThemeStyler.style(window: w) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        tasksStack.orientation = .vertical
        tasksStack.alignment = .leading
        tasksStack.spacing = 1
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        tasksStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(tasksStack)
        doc.addSubview(noTasks)
        noTasks.translatesAutoresizingMaskIntoConstraints = false
        tasksScroll.documentView = doc
        tasksScroll.hasVerticalScroller = true
        tasksScroll.borderType = .noBorder
        tasksScroll.drawsBackground = false
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: tasksScroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: tasksScroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: tasksScroll.contentView.topAnchor),
            tasksStack.topAnchor.constraint(equalTo: doc.topAnchor),
            tasksStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            tasksStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            tasksStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            noTasks.topAnchor.constraint(equalTo: doc.topAnchor, constant: 14),
            noTasks.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            doc.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        let queueTitle = NSTextField(labelWithString: "Copy queue (File > Add to Copy Queue\u{2026})")
        queueTitle.font = NSFont.boldSystemFont(ofSize: 12)
        for v in [tasksScroll, queueTitle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tasksScroll.topAnchor.constraint(equalTo: content.topAnchor),
            tasksScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tasksScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tasksScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            queueTitle.topAnchor.constraint(equalTo: tasksScroll.bottomAnchor, constant: 8),
            queueTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
        ])
        for (id, title, width) in [("copy", "Copy", 330), ("when", "When", 170), ("status", "Status", 230)] as [(String, String, CGFloat)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.headerCell = ThemedHeaderCell(textCell: title)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 0)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        var row: [NSView] = []
        for (id, title) in [("now", "Start Now"), ("pause", "Pause"), ("resume", "Resume"), ("schedule", "Schedule\u{2026}"),
                            ("up", "Move Up"), ("down", "Move Down"), ("remove", "Remove"), ("clear", "Clear Finished"), ("report", "Report")] {
            let b = NSButton(title: title, target: self, action: #selector(clicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(id)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            buttons[id] = b
            row.append(b)
        }
        let bar = NSStackView(views: row)
        bar.orientation = .horizontal
        bar.spacing = 4
        for v in [scroll, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: queueTitle.bottomAnchor, constant: 6),
            scroll.heightAnchor.constraint(equalToConstant: 170),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    func reload() {
        let keep = table.selectedRow >= 0 && table.selectedRow < jobs.count ? jobs[table.selectedRow].id : nil
        jobs = CopyQueueManager.shared.queue.snapshot()
        let tm = ThemeManager.shared
        table.backgroundColor = tm.background
        table.rowHeight = tm.rowHeight + 4
        table.reloadData()
        if let k = keep, let i = jobs.index(where: { $0.id == k }) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
        updateButtons()
    }

    private var selected: CopyJob? {
        let r = table.selectedRow
        return r >= 0 && r < jobs.count ? jobs[r] : nil
    }

    private func updateButtons() {
        let j = selected
        let st = j?.status
        buttons["now"]?.isEnabled = st == .waiting || st == .scheduled || st == .paused || st == .stopped
        buttons["pause"]?.isEnabled = st == .running || st == .waiting || st == .scheduled
        buttons["resume"]?.isEnabled = st == .paused || st == .stopped
        buttons["schedule"]?.isEnabled = st == .waiting || st == .scheduled || st == .paused
        buttons["up"]?.isEnabled = j != nil
        buttons["down"]?.isEnabled = j != nil
        buttons["remove"]?.isEnabled = j != nil && st != .running
        buttons["report"]?.isEnabled = j != nil
        buttons["clear"]?.isEnabled = jobs.contains(where: { $0.status == .done || $0.status == .failed || $0.status == .stopped })
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func numberOfRows(in tableView: NSTableView) -> Int { return jobs.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { return ThemedRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < jobs.count else { return nil }
        let j = jobs[row]
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ThemedCellView) ?? ThemedCellView.make(identifier: id, withIcon: false)
        switch id.rawValue {
        case "copy":
            cell.textField?.stringValue = j.title
            cell.toolTip = j.sources.joined(separator: "\n") + "\n\u{2192} " + j.destination
            cell.secondary = false
        case "when":
            cell.textField?.stringValue = j.startAt.map { CopyQueueManager.dateText($0) + (j.wake ? "  (wakes Mac)" : "") } ?? "When its turn comes"
            cell.secondary = true
        default:
            var t = j.status.rawValue.capitalized
            if j.status == .running || j.status == .paused || j.status == .done || j.status == .failed {
                t += "  \(j.finished.count)/\(j.sources.count) items, \(j.copiedCount) copied"
                if j.skippedCount > 0 { t += ", \(j.skippedCount) skipped" }
                if !j.problems.isEmpty { t += ", \(j.problems.count) problem\(j.problems.count == 1 ? "" : "s")" }
            }
            cell.textField?.stringValue = t
            cell.secondary = true
        }
        cell.applyTheme()
        if id.rawValue == "status" && (j.status == .failed) { cell.textField?.textColor = ThemeManager.shared.warning }
        return cell
    }

    @objc private func clicked(_ sender: NSButton) {
        let m = CopyQueueManager.shared
        let id = sender.identifier?.rawValue ?? ""
        if id == "clear" { m.queue.clearFinished(); m.save(); return }
        guard let j = selected else { return }
        switch id {
        case "now": m.startNow(j.id)
        case "pause": m.pause(j.id)
        case "resume": m.resume(j.id)
        case "up": m.queue.move(j.id, by: -1); m.save()
        case "down": m.queue.move(j.id, by: 1); m.save()
        case "remove":
            if !m.remove(j.id) { NSSound.beep() } else { App.log.info("Copy queue: removed \(Ascii.clean(j.title))") }
        case "schedule":
            if let (t, wake) = CopyQueueUI.askTime(initial: j.startAt, wake: j.wake) {
                if let note = m.schedule(j.id, at: t, wake: wake) { CopyQueueUI.message("Scheduled, without waking the Mac", note) }
            }
        case "report":
            let lines = CopyQueueRunner.report(j, dateText: CopyQueueManager.dateText)
            App.lastReport = "FIND COPY QUEUE REPORT\n" + lines.joined(separator: "\n") + "\n"
            let a = ThemedAlert()
            a.messageText = j.title
            a.informativeText = lines.prefix(25).joined(separator: "\n")
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Copy Report")
            if a.runModal() == .alertSecondButtonReturn { (NSApp.delegate as? AppDelegate)?.copyLastReport(nil) }
        default: break
        }
    }
}

// MARK: - Asking (add, schedule)

enum CopyQueueUI {
    static func message(_ title: String, _ text: String) {
        let a = ThemedAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// A date and time (now + 1 hour to start with) and "wake the Mac". nil = cancelled.
    static func askTime(initial: Double?, wake: Bool) -> (Double, Bool)? {
        let a = ThemedAlert()
        a.messageText = "When should this copy start?"
        a.informativeText = "Find has to be running then. Waking the Mac asks for an administrator password (macOS asks)."
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        picker.datePickerElements = NSDatePicker.ElementFlags(rawValue: 0x00EC)   // date, hours and minutes (raw: same on every SDK)
        picker.dateValue = Date(timeIntervalSince1970: initial ?? (Date().timeIntervalSince1970 + 3600))
        picker.minDate = Date()
        let wakeCheck = NSButton(checkboxWithTitle: "Wake the Mac a minute before, if it is asleep", target: nil, action: nil)
        wakeCheck.state = wake || initial == nil ? .on : .off
        let stack = NSStackView(views: [picker, wakeCheck])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        a.accessoryView = stack
        a.addButton(withTitle: "Schedule")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let t = max(Date().timeIntervalSince1970 + 60, picker.dateValue.timeIntervalSince1970)
        return (t, wakeCheck.state == .on)
    }
}

extension BrowserPane {
    /// File > Add to Copy Queue...: the selected items, to the other pane's folder (or a chosen one).
    @objc func addToCopyQueue(_ sender: Any?) {
        let items = selection.map { $0.path }
        if isFTP || items.isEmpty {
            NSSound.beep()
            showMessage("Select what to copy", "Select files or folders in a local pane, then Add to Copy Queue.", style: .informational)
            return
        }
        // 0.17: the destination is shown and can be changed (Choose...); it starts as the other pane's folder.
        let picker = QueueDestinationPicker(host?.panes.first(where: { $0 !== self && !$0.isFTP })?.currentPath)
        let a = ThemedAlert()
        a.messageText = "Add to the copy queue: \(items.count == 1 ? Paths.lastComponent(items[0]) : "\(items.count) items")"
        a.informativeText = "Copied with Find's checked copy; nothing at the destination is ever overwritten. The queue and its progress are in Window > Copies."
        let clash = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24), pullsDown: false)
        clash.addItems(withTitles: ["Name already there: skip it", "Name already there: keep both (numbered name)"])
        let when = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24), pullsDown: false)
        when.addItems(withTitles: ["Start when its turn comes", "Start at a set time\u{2026}"])
        let stack = NSStackView(views: [picker.row, clash, when])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 96)
        a.accessoryView = stack
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        var d = ""
        while true {
            guard a.runModal() == .alertFirstButtonReturn else { return }
            var e: Int32 = 0
            if let p = picker.path, let info = Sys.statInfo(p, &e), info.isDirectory { d = p; break }
            CopyQueueUI.message("Choose where to copy to", "Click Choose\u{2026} and pick the destination folder.")
        }
        var startAt: Double? = nil
        var wake = false
        if when.indexOfSelectedItem == 1 {
            guard let (t, w) = CopyQueueUI.askTime(initial: nil, wake: true) else { return }
            startAt = t
            wake = w
        }
        let j = CopyJob(id: UUID().uuidString, sources: items, destination: d, clash: clash.indexOfSelectedItem == 1 ? "keepBoth" : "skip",
                        startAt: startAt, wake: false, now: Date().timeIntervalSince1970)
        CopyQueueManager.shared.add(j)
        if let t = startAt, wake, let note = CopyQueueManager.shared.schedule(j.id, at: t, wake: true) {
            CopyQueueUI.message("Scheduled, without waking the Mac", note)
        }
        CopyQueueWindowController.show()
    }
}


/// The destination line in Add to Copy Queue: the folder, and Choose... to change it.
final class QueueDestinationPicker: NSObject {
    private(set) var path: String?
    let row: NSStackView
    private let label = NSTextField(labelWithString: "")

    init(_ start: String?) {
        path = start
        let button = NSButton(title: "Choose", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        label.lineBreakMode = .byTruncatingMiddle
        label.font = NSFont.systemFont(ofSize: 11)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        row = NSStackView(views: [NSTextField(labelWithString: "To:"), label, button])
        row.orientation = .horizontal
        row.spacing = 6
        super.init()
        button.target = self
        button.action = #selector(choose(_:))
        update()
    }

    private func update() {
        label.stringValue = path ?? "(not chosen yet - click Choose\u{2026})"
        label.toolTip = path
    }

    @objc private func choose(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Copy Here"
        p.message = "Where should the queued copy go?"
        if let cur = path { p.directoryURL = URL(fileURLWithPath: cur) }
        if p.runModal() == .OK, let u = p.url { path = u.path; update() }
    }
}
