// FindReplaceWindow.swift
// 0.18: Find and Replace (Option-Command-F) - in file names or in picture metadata, over the selected
// items or a whole folder (optionally with everything in its subfolders). Works in list, thumbnail and
// Photography mode. Preview shows every change first (optional: Replace works it out itself); names go
// through the checked batch rename (all or nothing, folders inside folders safe), metadata through the
// checked metadata writer (copy, verify, swap). One Undo for the whole run, also for names + metadata.
// 0.18.2: names AND metadata in one go; the selection is the pane's selection at the moment you press
// Preview / Replace (not when the window opened); the texts and choices are remembered.

import AppKit

final class FindReplaceWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private weak var pane: BrowserPane?
    /// The pane's selection and folder right now (the window stays open while you work in the pane).
    private var selected: [FileEntry] { return pane?.selection ?? [] }
    private var folder: String { return pane?.currentPath ?? NSHomeDirectory() }

    // Remembered between uses (and after Find quits).
    private static let d = UserDefaults.standard
    private static var lastFind: String { get { return d.string(forKey: "FindReplace.find") ?? "" } set { d.set(newValue, forKey: "FindReplace.find") } }
    private static var lastReplace: String { get { return d.string(forKey: "FindReplace.replace") ?? "" } set { d.set(newValue, forKey: "FindReplace.replace") } }
    private static var lastTarget: Int { get { return d.object(forKey: "FindReplace.target") as? Int ?? 0 } set { d.set(newValue, forKey: "FindReplace.target") } }
    private static var lastCase: Bool { get { return d.bool(forKey: "FindReplace.case") } set { d.set(newValue, forKey: "FindReplace.case") } }

    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let findField = NSTextField(string: "")
    private let replaceField = NSTextField(string: "")
    private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subfolders = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    private let folderNames = NSButton(checkboxWithTitle: "Folder names too", target: nil, action: nil)
    private var fieldBoxes: [(MetaField, NSButton)] = []
    private var fieldsRow: NSStackView!
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var previewButton: NSButton!
    private var replaceButton: NSButton!

    /// The preview: one row per change.
    private struct Row {
        let item: String
        let field: String
        let old: String
        let new: String
        let problem: String?
    }
    /// A worked-out set of changes (Preview shows it; Replace carries it out).
    private struct Plan {
        var rows: [Row] = []
        var names: [(path: String, newName: String)] = []
        var metas: [(image: String, change: MetaChange)] = []
        var summary = ""
        var isEmpty: Bool { return names.isEmpty && metas.isEmpty }
    }
    private var plan: Plan?
    private var previewToken = 0
    private var busy = false

    init(pane: BrowserPane) {
        self.pane = pane
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Find and Replace"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 620, height: 420)
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
        changed(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return l
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    private func build() {
        guard let content = window?.contentView else { return }
        targetPopup.addItems(withTitles: ["File names", "Metadata (caption, keywords, ...)", "File names and metadata"])
        targetPopup.selectItem(at: max(0, min(2, FindReplaceWindow.lastTarget)))
        scopePopup.addItems(withTitles: ["Selected items", "Everything in the folder"])
        scopePopup.autoenablesItems = false
        scopePopup.selectItem(at: selected.isEmpty ? 1 : 0)
        findField.stringValue = FindReplaceWindow.lastFind
        replaceField.stringValue = FindReplaceWindow.lastReplace
        matchCase.state = FindReplaceWindow.lastCase ? .on : .off
        for f in [findField, replaceField] {
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        findField.placeholderString = "text to find"
        replaceField.placeholderString = "empty = remove the text"
        for c in [targetPopup, scopePopup] as [NSPopUpButton] {
            c.target = self
            c.action = #selector(changed(_:))
        }
        for c in [matchCase, subfolders, folderNames] {
            c.target = self
            c.action = #selector(changed(_:))
        }
        // Metadata fields: all on by default.
        var cols: [NSStackView] = []
        var col: [NSView] = []
        for f in MetaField.textFields {
            let b = NSButton(checkboxWithTitle: f.fullLabel, target: self, action: #selector(changed(_:)))
            b.state = .on
            fieldBoxes.append((f, b))
            col.append(b)
            if col.count == 9 {
                let s = NSStackView(views: col); s.orientation = .vertical; s.alignment = .leading; s.spacing = 3
                cols.append(s); col = []
            }
        }
        if !col.isEmpty { let s = NSStackView(views: col); s.orientation = .vertical; s.alignment = .leading; s.spacing = 3; cols.append(s) }
        let allOn = NSButton(title: "All", target: self, action: #selector(allFields(_:)))
        let allOff = NSButton(title: "None", target: self, action: #selector(noFields(_:)))
        let allCol = NSStackView(views: [allOn, allOff]); allCol.orientation = .vertical; allCol.alignment = .leading
        fieldsRow = row([label("In fields:") as NSView] + (cols as [NSView]) + [allCol as NSView])
        fieldsRow.alignment = .top

        let tcols: [(String, String, CGFloat)] = [("item", "Item", 200), ("field", "Field", 110), ("old", "Now", 190), ("new", "Becomes", 190)]
        for (id, t, w) in tcols {
            let c = NSTableColumn(identifier: itemID(id))
            c.title = t
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\u{1b}"
        previewButton = NSButton(title: "Preview", target: self, action: #selector(preview(_:)))
        replaceButton = NSButton(title: "Replace", target: self, action: #selector(replace(_:)))
        replaceButton.keyEquivalent = "\r"
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 200), for: .horizontal)
        let buttons = row([status, close, previewButton, replaceButton])

        let top = NSStackView(views: [row([label("Replace in:"), targetPopup]),
                                      row([label("Find:"), findField, matchCase]),
                                      row([label("Replace with:"), replaceField]),
                                      row([label("Look at:"), scopePopup]),
                                      row([label(""), subfolders, folderNames]),
                                      fieldsRow])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 8
        for v in [top, scroll, buttons] as [NSView] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window?.initialFirstResponder = findField
    }

    private var doNames: Bool { return targetPopup.indexOfSelectedItem != 1 }
    private var doMeta: Bool { return targetPopup.indexOfSelectedItem >= 1 }
    private var wholeFolder: Bool { return scopePopup.indexOfSelectedItem == 1 }

    private var query: FindReplaceQuery {
        var q = FindReplaceQuery()
        q.find = findField.stringValue
        q.replaceWith = replaceField.stringValue
        q.caseSensitive = matchCase.state == .on
        q.fields = fieldBoxes.filter { $0.1.state == .on }.map { $0.0 }
        return q
    }

    /// The scope menu names what it means right now (the pane's selection and folder may have changed).
    private func refreshScope() {
        let n = selected.count
        scopePopup.item(at: 0)?.title = "The \(n) selected item\(n == 1 ? "" : "s")"
        scopePopup.item(at: 0)?.isEnabled = n > 0
        scopePopup.item(at: 1)?.title = "Everything in \u{201C}\(Paths.lastComponent(folder))\u{201D}"
        if n == 0 && scopePopup.indexOfSelectedItem == 0 { scopePopup.selectItem(at: 1) }
    }

    /// Anything changed: the old preview no longer applies.
    @objc private func changed(_ sender: Any?) {
        refreshScope()
        fieldsRow.isHidden = !doMeta
        folderNames.isHidden = !doNames
        subfolders.isEnabled = wholeFolder
        previewToken += 1
        plan = nil
        table.reloadData()
        let ready = !busy && !findField.stringValue.isEmpty && (!doMeta || !query.fields.isEmpty)
        replaceButton.isEnabled = ready
        previewButton.isEnabled = ready
        FindReplaceWindow.lastFind = findField.stringValue
        FindReplaceWindow.lastReplace = replaceField.stringValue
        FindReplaceWindow.lastTarget = targetPopup.indexOfSelectedItem
        FindReplaceWindow.lastCase = matchCase.state == .on
        if !busy {
            status.stringValue = findField.stringValue.isEmpty ? "Type the text to find." : "Preview shows every change first; Replace does it now."
            status.textColor = NSColor.secondaryLabelColor
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from the pane: the selection may be different now.
        if !busy { changed(nil) }
    }

    @objc private func allFields(_ sender: Any?) { for (_, b) in fieldBoxes { b.state = .on }; changed(nil) }
    @objc private func noFields(_ sender: Any?) { for (_, b) in fieldBoxes { b.state = .off }; changed(nil) }

    #if swift(>=4.2)
    func controlTextDidChange(_ obj: Notification) { changed(nil) }
    #else
    override func controlTextDidChange(_ obj: Notification) { changed(nil) }
    #endif

    @objc private func closeWindow(_ sender: Any?) { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        previewToken += 1
        if pane?.findReplace === self { pane?.findReplace = nil }
    }

    // MARK: Working out the changes

    /// The items to look at (files; folders only for names with "Folder names too").
    private static func gather(selected: [FileEntry], folder: String, whole: Bool, deep: Bool, folders: Bool)
        -> (paths: [String], folderSet: Set<String>, truncated: Bool) {
        var folderSet = Set<String>()
        if !whole {
            var paths: [String] = []
            let chosen = Set(selected.map { $0.path })
            for e in selected {
                let isFolder = e.isFolderLike && !KindCache.shared.isPackage(e)
                if isFolder {
                    if folders { paths.append(e.path); folderSet.insert(e.path) }
                    continue
                }
                paths.append(e.path)
                // A picture's sidecar goes with it (names), so the two keep matching names.
                if let sc = Sidecars.find(for: e.path), !chosen.contains(sc), !paths.contains(sc) { paths.append(sc) }
            }
            return (paths, folderSet, false)
        }
        let r = FindReplace.collect(folder: folder, subfolders: deep, includeFolders: folders) { dir in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            var out: [(name: String, isFolder: Bool)] = []
            for n in names {
                let p = Paths.join(dir, n)
                var e: Int32 = 0
                guard let st = Sys.lstatInfo(p, &e) else { continue }
                if st.isSymlink { out.append((n, false)); continue }   // a link: its own name only, never followed
                let isDir = st.isDirectory && !KindCache.shared.isPackage(path: p, ext: Paths.fileExtension(n).lowercased())
                if isDir { folderSet.insert(p) }
                out.append((n, isDir))
            }
            return out
        }
        return (r.paths, folderSet, r.truncated)
    }

    /// Work out every change (in the background), then `then` on the main thread - unless anything was
    /// changed in the window meanwhile.
    private func makePlan(then: @escaping (Plan) -> Void) {
        let q = query
        if q.isEmpty || busy { return }
        previewToken += 1
        let token = previewToken
        let names = doNames, meta = doMeta, whole = wholeFolder, deep = subfolders.state == .on, folders = folderNames.state == .on
        let sel = selected, dir = folder
        if !whole && sel.isEmpty {
            status.stringValue = "Nothing is selected in the window behind. Select items, or choose \u{201C}Everything in the folder\u{201D}."
            return
        }
        busy = true
        previewButton.isEnabled = false
        replaceButton.isEnabled = false
        status.stringValue = whole ? "Looking through \u{201C}\(Paths.lastComponent(dir))\u{201D}\u{2026}" : "Looking\u{2026}"
        status.textColor = NSColor.secondaryLabelColor
        App.log.info("Find and Replace: \(names ? "names" : "")\(names && meta ? "+" : "")\(meta ? "metadata" : "") in \(whole ? dir + (deep ? " +subfolders" : "") : "\(sel.count) selected")")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let g = FindReplaceWindow.gather(selected: sel, folder: dir, whole: whole, deep: deep, folders: folders && names)
            var plan = Plan()
            var parts: [String] = []
            if meta {
                // Pictures only; each one's CURRENT set (its own metadata or its sidecar, whichever is newer).
                var pics: [String] = []
                var unsupported = 0
                for t in MetaPlan.targets(g.paths.filter { !g.folderSet.contains($0) && PhotoFormats.isImage(Paths.lastComponent($0)) }) {
                    if case .unsupported = t.kind {
                        if !PhotoFormats.isSidecar(Paths.lastComponent(t.image)) { unsupported += 1 }
                        continue
                    }
                    if !pics.contains(t.image) { pics.append(t.image) }
                }
                var recs: [String: [String: Any]] = [:]
                let tags = MetaPlan.readTags(for: MetaTarget(image: "", file: "", kind: .embedded(iptc: true)))
                var start = 0
                while start < pics.count {
                    if self?.previewToken != token { return }
                    let chunk = Array(pics[start..<min(pics.count, start + 96)])
                    let files = chunk.map { MetaPlan.currentFile(for: $0).file }
                    let got = App.ops.metadataTool?.read(tags, files: files) ?? [:]
                    for (img, f) in zip(chunk, files) { recs[img] = got[f] ?? [:] }
                    start += 96
                    let n = min(start, pics.count), total = pics.count
                    DispatchQueue.main.async {
                        guard let s = self, s.previewToken == token else { return }
                        s.status.stringValue = "Reading metadata: \(n)/\(total)\u{2026}"
                    }
                }
                for it in FindReplace.metadataPlan(records: recs, order: pics, query: q) {
                    for f in it.fields {
                        plan.rows.append(Row(item: FindReplaceWindow.shortPath(it.image, under: dir), field: f.field.fullLabel, old: f.old, new: f.new, problem: nil))
                    }
                    plan.metas.append((it.image, it.change))
                }
                var t = "\(plan.metas.count) picture\(plan.metas.count == 1 ? "" : "s")' metadata (of \(pics.count) read)"
                if unsupported > 0 { t += ", \(unsupported) file\(unsupported == 1 ? "" : "s") Find doesn't write (PSD and others) left out" }
                if App.ops.metadataTool == nil { t = "metadata: ExifTool could not be started (Help > Run Photo Self-Test shows why)" }
                parts.append(t)
            }
            if names {
                var cache: [String: [String]] = [:]
                let np = FindReplace.namesPlan(paths: g.paths, isFolder: { g.folderSet.contains($0) }, query: q, existing: { d in
                    if let c = cache[d] { return c }
                    let n = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
                    cache[d] = n
                    return n
                })
                for it in np.items where !it.unchanged || it.problem != nil {
                    plan.rows.append(Row(item: FindReplaceWindow.shortPath(it.path, under: dir), field: "Name", old: it.oldName,
                                         new: it.newName, problem: it.problem))
                    if it.problem == nil { plan.names.append((it.path, it.newName)) }
                }
                let problems = np.items.filter { $0.problem != nil }.count
                var t = "\(plan.names.count) name\(plan.names.count == 1 ? "" : "s") (of \(g.paths.count) looked at)"
                if problems > 0 { t += ", \(problems) can't (red) and will be left as they are" }
                parts.append(t)
            }
            plan.summary = "Will change: " + parts.joined(separator: " \u{00B7} ")
            if g.truncated { plan.summary += " \u{00B7} stopped at \(g.paths.count) items" }
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.busy = false
                guard s.previewToken == token else { s.changed(nil); return }
                s.previewButton.isEnabled = true
                s.replaceButton.isEnabled = true
                then(plan)
            }
        }
    }

    @objc private func preview(_ sender: Any?) {
        makePlan { [weak self] p in
            guard let s = self else { return }
            s.plan = p
            s.table.reloadData()
            s.status.stringValue = p.rows.isEmpty ? "Nothing found \u{2013} nothing would change." : p.summary
            s.status.textColor = NSColor.secondaryLabelColor
            s.replaceButton.isEnabled = !p.isEmpty
        }
    }

    private static func shortPath(_ p: String, under dir: String) -> String {
        if p.hasPrefix(dir + "/") { return String(p.dropFirst(dir.count + 1)) }
        return Paths.lastComponent(p)
    }

    // MARK: Replace

    /// Carries out the previewed changes, or - without a preview - works them out and carries them out.
    @objc private func replace(_ sender: Any?) {
        if busy { return }
        if let p = plan {
            run(p)
        } else {
            makePlan { [weak self] p in
                guard let s = self else { return }
                if p.isEmpty {
                    s.plan = p
                    s.table.reloadData()
                    s.status.stringValue = "Nothing found \u{2013} nothing was changed."
                    return
                }
                s.run(p)
            }
        }
    }

    /// Metadata first (on the pictures' present names), then the names; one Undo for both.
    private func run(_ p: Plan) {
        guard let pane = pane, !p.isEmpty else { return }
        busy = true
        previewButton.isEnabled = false
        replaceButton.isEnabled = false
        plan = p
        table.reloadData()
        func renames(_ metaUndo: UndoRecord?, _ metaReport: BatchReport?) {
            if p.names.isEmpty {
                if let u = metaUndo { pane.registerUndo(u) }
                finished(renamed: 0, meta: metaReport, failure: nil)
                return
            }
            status.stringValue = "Renaming \(p.names.count) items\u{2026}"
            let work = p.names
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var pairs: [(from: String, to: String)] = []
                var rec: UndoRecord?
                var failure: Error?
                do { let r = try App.ops.renameNested(work); pairs = r.0; rec = r.1 } catch { failure = error }
                DispatchQueue.main.async {
                    var parts: [UndoRecord] = []
                    if let u = metaUndo { parts.append(u) }
                    if let r = rec { parts.append(r) }
                    if parts.count == 1 { pane.registerUndo(parts[0]) }
                    if parts.count > 1 { pane.registerUndo(.group(parts, label: "Find and Replace")) }
                    if let e = failure {
                        pane.showFailure("Find and Replace did not rename anything \u{2014} every item kept its name", e)
                    } else {
                        App.log.info("Find and Replace: \(pairs.count) items renamed")
                    }
                    pane.refreshList(select: pairs.map { $0.to }.filter { Paths.parent($0) == pane.currentPath })
                    self?.finished(renamed: pairs.count, meta: metaReport, failure: failure)
                }
            }
        }
        if p.metas.isEmpty {
            renames(nil, nil)
        } else {
            status.stringValue = "Writing \(p.metas.count) pictures\u{2026}"
            pane.applyMetadata(items: p.metas, title: "Find and Replace", progress: { [weak self] n, total in
                self?.status.stringValue = "Metadata: \(n)/\(total) written and checked\u{2026}"
            }, registerUndo: false, done: { r in renames(r.undo, r) })
            if App.ops.metadataTool == nil { busy = false; changed(nil) }
        }
    }

    private func finished(renamed: Int, meta: BatchReport?, failure: Error?) {
        busy = false
        var parts: [String] = []
        if let r = meta {
            var t = "\(r.done.count) file\(r.done.count == 1 ? "" : "s") written and checked"
            if !r.failed.isEmpty { t += ", \(r.failed.count) failed" }
            if r.cancelled { t += " (stopped)" }
            parts.append(t)
        }
        if doNames { parts.append(failure == nil ? "\(renamed) renamed" : "nothing renamed") }
        let summary = parts.joined(separator: " \u{00B7} ")
        // Ready for the next one, on the pane's selection as it is now.
        changed(nil)
        status.stringValue = "Done: " + summary + ". Edit > Undo puts it all back."
        status.textColor = (meta?.failed.isEmpty ?? true) && failure == nil ? NSColor.secondaryLabelColor : NSColor.systemRed
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { return plan?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let rows = plan?.rows, row < rows.count else { return nil }
        let r = rows[row]
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingMiddle
        switch col.identifier.rawValue {
        case "item": f.stringValue = r.item; f.toolTip = r.item
        case "field": f.stringValue = r.field
        case "old": f.stringValue = r.old; f.toolTip = r.old
        default:
            f.stringValue = r.problem.map { "\u{2715} " + $0 } ?? r.new
            f.toolTip = r.problem ?? r.new
            f.textColor = r.problem != nil ? NSColor.systemRed : NSColor.labelColor
        }
        return f
    }
}

extension BrowserPane {
    /// File > Find and Replace... (Option-Command-F).
    @objc func findAndReplace(_ sender: Any?) {
        if isFTP { NSSound.beep(); return }
        if list.resultsMode && !subfoldersOn {
            showMessage("Find and Replace works in a folder", "Leave the search results first (Esc), then open the folder to work in.", style: .informational)
            return
        }
        if let w = findReplace {
            w.showWindow(nil)   // already open: bring it forward (it follows the selection)
            return
        }
        let w = FindReplaceWindow(pane: self)
        findReplace = w
        w.showWindow(nil)
    }
}
