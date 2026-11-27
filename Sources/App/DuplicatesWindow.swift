// DuplicatesWindow.swift
// Find files with identical contents (checked byte for byte) and, if wanted, move extra copies to the
// Trash. Safety: never removes the last copy of a group; asks first; Trash only (undoable).

import AppKit

final class DuplicatesWindow: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static var open: [DuplicatesWindow] = []
    private weak var pane: BrowserPane?
    private var roots: [String]
    private var result = DuplicateResult()
    private let cancel = AtomicInt()
    private var running = false

    private let includeOthers = NSButton(checkboxWithTitle: "Also search the other panes' folders", target: nil, action: nil)
    private let minSize = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outline = NSOutlineView()
    private let status = NSTextField(labelWithString: "")
    private var runButton: NSButton!
    private let minSizes: [Int64] = [1, 100 * 1024, 1024 * 1024, 10 * 1024 * 1024, 100 * 1024 * 1024]

    /// A group row in the outline (files are FileEntry wrapped in DupFile).
    private final class DupGroup { var group: DuplicateGroup; init(_ g: DuplicateGroup) { group = g } }
    private final class DupFile { let entry: FileEntry; init(_ e: FileEntry) { entry = e } }
    private var groupItems: [DupGroup] = []
    private var fileItems: [ObjectIdentifier: [DupFile]] = [:]

    static func show(from pane: BrowserPane) {
        let c = DuplicatesWindow(pane: pane)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(pane: BrowserPane) {
        self.pane = pane
        roots = [pane.currentPath]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Duplicates in \u{201C}\(Paths.lastComponent(pane.currentPath))\u{201D}"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 600, height: 360)
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        guard let content = window?.contentView, let p = pane else { return }
        window?.appearance = ThemeManager.shared.appearance
        let where_ = NSTextField(labelWithString: "Folder (with all subfolders): \(p.currentPath)")
        where_.lineBreakMode = .byTruncatingMiddle
        includeOthers.isEnabled = (p.host?.panes.count ?? 1) > 1
        minSize.addItems(withTitles: ["Any size", "100 KB or larger", "1 MB or larger", "10 MB or larger", "100 MB or larger"])
        minSize.selectItem(at: 2)
        runButton = NSButton(title: "Find Duplicates", target: self, action: #selector(run(_:)))
        let stop = NSButton(title: "Stop", target: self, action: #selector(stop(_:)))
        let opts = NSStackView(views: [includeOthers, minSize, runButton, stop])
        opts.orientation = .horizontal
        opts.spacing = 12

        for (id, title, w) in [("name", "File", 520.0), ("date", "Modified", 160.0), ("size", "Size", 90.0)] {
            let c = NSTableColumn(identifier: itemID(id))
            c.title = title
            c.width = CGFloat(w)
            outline.addTableColumn(c)
            if id == "name" { outline.outlineTableColumn = c }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.target = self
        outline.doubleAction = #selector(reveal(_:))
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let keepOld = NSButton(title: "Select Extra Copies (keep oldest)", target: self, action: #selector(selectKeepOldest(_:)))
        let keepNew = NSButton(title: "Select Extra Copies (keep newest)", target: self, action: #selector(selectKeepNewest(_:)))
        let trash = NSButton(title: "Move Selected to Trash", target: self, action: #selector(trashSelected(_:)))
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport(_:)))
        let actions = NSStackView(views: [keepOld, keepNew, trash, copy])
        actions.orientation = .horizontal
        actions.spacing = 10
        status.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [where_, opts, scroll, status, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        content.addSubview(stack)
        stack.pinEdges(to: content, top: 12, left: 14, bottom: 12, right: 14)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.stringValue = "Choose the options and click Find Duplicates. Files are compared byte for byte before they are listed."
    }

    @objc private func run(_ sender: Any?) {
        guard !running, let p = pane else { return }
        roots = [p.currentPath]
        if includeOthers.state == .on, let h = p.host {
            for q in h.panes where q !== p && !q.list.resultsMode { roots.append(q.currentPath) }
        }
        running = true
        runButton.isEnabled = false
        cancel.value = 0
        let flag = cancel
        let rs = roots
        let minimum = minSizes[max(0, minSize.indexOfSelectedItem)]
        status.stringValue = "Listing\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = Duplicates.find(in: rs, minSize: minimum, isCancelled: { flag.value != 0 }) { phase, n in
                DispatchQueue.main.async { self?.status.stringValue = "\(phase)\u{2026} \(n) files" }
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.running = false
                s.runButton.isEnabled = true
                s.result = res
                App.log.info("Duplicates: \(res.groups.count) groups, \(res.reclaimable) bytes in extra copies, \(res.filesScanned) files checked")
                s.reloadGroups()
            }
        }
    }

    @objc private func stop(_ sender: Any?) {
        cancel.value = 1
    }

    private func reloadGroups() {
        groupItems = result.groups.map { DupGroup($0) }
        fileItems = [:]
        for g in groupItems { fileItems[ObjectIdentifier(g)] = g.group.files.map { DupFile($0) } }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        var t = "\(result.groups.count) group\(result.groups.count == 1 ? "" : "s") of identical files \u{00B7} "
            + "\(Listing.sizeText(result.reclaimable)) in extra copies \u{00B7} \(result.filesScanned) files checked"
        if !result.problems.isEmpty { t += " \u{00B7} \(result.problems.count) unreadable" }
        if result.cancelled { t += " \u{00B7} stopped before the end" }
        status.stringValue = t
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groupItems.count }
        if let g = item as? DupGroup { return fileItems[ObjectIdentifier(g)]?.count ?? 0 }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let g = item as? DupGroup { return fileItems[ObjectIdentifier(g)]![index] }
        return groupItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is DupGroup
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let col = tableColumn else { return nil }
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingMiddle
        if let g = item as? DupGroup {
            switch col.identifier.rawValue {
            case "name":
                f.stringValue = "\(g.group.files.count) identical copies"
                f.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            case "size": f.stringValue = Listing.sizeText(g.group.size) + " each"
            default: f.stringValue = ""
            }
        } else if let d = item as? DupFile {
            switch col.identifier.rawValue {
            case "name": f.stringValue = d.entry.path
            case "date": f.stringValue = InspectorController.dateText(d.entry.modified)
            default: f.stringValue = Listing.sizeText(d.entry.size)
            }
        }
        return f
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return item is DupFile
    }

    // MARK: Actions

    private func selectPaths(_ paths: Set<String>) {
        var rows = IndexSet()
        for r in 0..<outline.numberOfRows {
            if let d = outline.item(atRow: r) as? DupFile, paths.contains(d.entry.path) { rows.insert(r) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    @objc private func selectKeepOldest(_ sender: Any?) {
        selectPaths(Set(Duplicates.selectAllButOne(result.groups, keepNewest: false)))
    }

    @objc private func selectKeepNewest(_ sender: Any?) {
        selectPaths(Set(Duplicates.selectAllButOne(result.groups, keepNewest: true)))
    }

    @objc private func trashSelected(_ sender: Any?) {
        let picked = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? DupFile)?.entry }
        if picked.isEmpty { NSSound.beep(); return }
        let paths = Set(picked.map { $0.path })
        let emptied = Duplicates.groupsLeftEmpty(result.groups, removing: paths)
        if !emptied.isEmpty {
            let a = ThemedAlert()
            a.messageText = "Every copy of \(emptied.count) file\(emptied.count == 1 ? "" : "s") is selected"
            a.informativeText = "Find always keeps at least one copy. Deselect one copy in each of these groups:\n"
                + emptied.prefix(5).map { Paths.lastComponent($0.files[0].path) }.joined(separator: "\n")
            a.runModal()
            return
        }
        let bytes = picked.reduce(Int64(0)) { $0 + $1.size }
        let a = ThemedAlert()
        a.messageText = "Move \(picked.count) duplicate\(picked.count == 1 ? "" : "s") to the Trash?"
        a.informativeText = "\(Listing.sizeText(bytes)). At least one copy of each file stays where it is. Edit > Undo puts them back."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        let r = App.ops.trash(picked.map { $0.path })
        if let u = r.undo { pane?.registerUndo(u) }
        App.log.info("Duplicates: moved \(r.done.count) of \(picked.count) to the Trash")
        // Drop what was trashed; groups with one copy left are no longer duplicates.
        let gone = Set(r.done.map { $0.from })
        result.groups = result.groups.compactMap { g in
            var g2 = g
            g2.files = g.files.filter { !gone.contains($0.path) }
            return g2.files.count > 1 ? g2 : nil
        }
        reloadGroups()
        pane?.refreshList(select: [])
        if !r.failed.isEmpty { pane?.showReport("Move to Trash", r) }
    }

    @objc private func reveal(_ sender: Any?) {
        guard let d = outline.item(atRow: outline.clickedRow) as? DupFile, let p = pane else { return }
        p.navigate(to: Paths.parent(d.entry.path), select: [d.entry.name])
        p.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyReport(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Duplicates.report(result, roots: roots), forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        cancel.value = 1
        window?.delegate = nil
        DispatchQueue.main.async {
            DuplicatesWindow.open = DuplicatesWindow.open.filter { $0 !== self }
        }
    }
}
