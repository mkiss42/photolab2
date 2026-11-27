// CompareFoldersWindow.swift
// Compare two folders: what is only on one side, what differs (size, date or contents), what is the same.
// Read-only. Double-click a row to show the item in its pane; Copy Report gives plain numbered text.

import AppKit

final class CompareFoldersWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [CompareFoldersWindow] = []
    private let left: String
    private let right: String
    private weak var pane: BrowserPane?
    private var result: CompareResult?
    private var shown: [CompareRow] = []
    private let cancel = AtomicInt()
    private var running = false

    private let subfolders = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    private let contents = NSButton(checkboxWithTitle: "Compare contents byte for byte (slower)", target: nil, action: nil)
    private let filter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var runButton: NSButton!

    /// From a pane: compare its folder with the next pane's folder (or a chosen folder).
    static func show(from pane: BrowserPane) {
        let left = pane.currentPath
        var right = pane.otherPane?.currentPath
        if right == nil || right == left {
            let p = NSOpenPanel()
            p.canChooseFiles = false
            p.canChooseDirectories = true
            p.allowsMultipleSelection = false
            p.prompt = "Compare"
            p.message = "Compare \"\(Paths.lastComponent(left))\" with which folder?"
            guard p.runModal() == .OK, let u = p.url?.path else { return }
            right = u
        }
        guard let r = right else { return }
        let c = CompareFoldersWindow(left: left, right: r, pane: pane)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.run(nil)
    }

    private init(left: String, right: String, pane: BrowserPane) {
        self.left = left
        self.right = right
        self.pane = pane
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Compare \u{201C}\(Paths.lastComponent(left))\u{201D} with \u{201C}\(Paths.lastComponent(right))\u{201D}"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 360)
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        window?.appearance = ThemeManager.shared.appearance
        let l1 = NSTextField(labelWithString: "Left:  \(left)")
        let l2 = NSTextField(labelWithString: "Right: \(right)")
        for l in [l1, l2] { l.lineBreakMode = .byTruncatingMiddle; l.font = NSFont.systemFont(ofSize: 11) }
        subfolders.state = .on
        runButton = NSButton(title: "Compare", target: self, action: #selector(run(_:)))
        let stop = NSButton(title: "Stop", target: self, action: #selector(stop(_:)))
        filter.addItems(withTitles: ["All differences", "Only in left", "Only in right", "Different", "Same", "Everything"])
        filter.target = self
        filter.action = #selector(refilter(_:))
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport(_:)))
        let opts = NSStackView(views: [subfolders, contents, runButton, stop])
        opts.orientation = .horizontal
        opts.spacing = 12
        let bottom = NSStackView(views: [filter, status, copy])
        bottom.orientation = .horizontal
        bottom.spacing = 12
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 200), for: .horizontal)

        for (id, title, w) in [("status", "", 150.0), ("path", "Item", 380.0), ("left", "Left", 160.0), ("right", "Right", 160.0)] {
            let c = NSTableColumn(identifier: itemID(id))
            c.title = title
            c.width = CGFloat(w)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(reveal(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let stack = NSStackView(views: [l1, l2, opts, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        content.addSubview(stack)
        stack.pinEdges(to: content, top: 12, left: 14, bottom: 12, right: 14)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc func run(_ sender: Any?) {
        if running { return }
        running = true
        runButton.isEnabled = false
        cancel.value = 0
        let rec = subfolders.state == .on, cont = contents.state == .on
        let flag = cancel
        let (l, r) = (left, right)
        status.stringValue = "Comparing\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = FolderCompare.compare(l, r, recursive: rec, checkContents: cont, isCancelled: { flag.value != 0 }) { n in
                DispatchQueue.main.async { self?.status.stringValue = "Comparing\u{2026} \(n) folder\(n == 1 ? "" : "s")" }
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.running = false
                s.runButton.isEnabled = true
                s.result = res
                App.log.info("Compare folders: \(l) vs \(r): \(res.count(.onlyLeft)) only left, \(res.count(.onlyRight)) only right, \(res.count(.different)) different, \(res.count(.same)) same")
                s.refilter(nil)
            }
        }
    }

    @objc private func stop(_ sender: Any?) {
        cancel.value = 1
    }

    @objc private func refilter(_ sender: Any?) {
        guard let r = result else { return }
        switch filter.indexOfSelectedItem {
        case 1: shown = r.rows.filter { $0.status == .onlyLeft }
        case 2: shown = r.rows.filter { $0.status == .onlyRight }
        case 3: shown = r.rows.filter { $0.status == .different }
        case 4: shown = r.rows.filter { $0.status == .same }
        case 5: shown = r.rows
        default: shown = r.rows.filter { $0.status != .same }
        }
        table.reloadData()
        var t = "\(r.count(.onlyLeft)) only in left \u{00B7} \(r.count(.onlyRight)) only in right \u{00B7} \(r.count(.different)) different \u{00B7} \(r.count(.same)) same"
        if !r.problems.isEmpty { t += " \u{00B7} \(r.problems.count) unreadable" }
        if r.cancelled { t += " \u{00B7} stopped before the end" }
        status.stringValue = t
    }

    func numberOfRows(in tableView: NSTableView) -> Int { return shown.count }

    private func describe(_ e: FileEntry?) -> String {
        guard let e = e else { return "\u{2014}" }
        if e.kind == .directory { return "folder" }
        return "\(Listing.sizeText(e.size))  \(InspectorController.dateText(e.modified))"
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < shown.count else { return nil }
        let r = shown[row]
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingMiddle
        switch col.identifier.rawValue {
        case "status":
            f.stringValue = CompareStatus.titles[r.status.rawValue] + (r.why.isEmpty ? "" : " (\(r.why))")
            f.textColor = r.status == .same ? NSColor.secondaryLabelColor : (r.status == .different ? NSColor.systemOrange : NSColor.systemBlue)
        case "path": f.stringValue = r.relPath
        case "left": f.stringValue = describe(r.left)
        default: f.stringValue = describe(r.right)
        }
        return f
    }

    /// Double-click: show the item in the pane (left side if it exists there, else right).
    @objc private func reveal(_ sender: Any?) {
        let i = table.clickedRow
        guard i >= 0, i < shown.count, let p = pane else { return }
        guard let e = shown[i].left ?? shown[i].right else { return }
        p.navigate(to: Paths.parent(e.path), select: [e.name])
        p.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyReport(_ sender: Any?) {
        guard let r = result else { return }
        let text = FolderCompare.report(r, left: left, right: right, recursive: subfolders.state == .on, checkContents: contents.state == .on)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        cancel.value = 1
        window?.delegate = nil
        DispatchQueue.main.async {
            CompareFoldersWindow.open = CompareFoldersWindow.open.filter { $0 !== self }
        }
    }
}
