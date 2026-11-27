// BatchRenameSheet.swift
// Rename several items at once (Return or Rename... with more than one item selected): replace text,
// add text, name + number, or change case, with a live preview of every old -> new name and any
// problem marked. Nothing is renamed until every new name checks out; then it is all or nothing,
// and one Undo puts the whole batch back (FileOperations.renameBatch).

import AppKit

final class BatchRenameSheet: NSResponder, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let panel: NSPanel
    private let entries: [FileEntry]
    private weak var pane: BrowserPane?
    private var plan = RenamePlan()
    private var existingCache: [String: [String]] = [:]
    private static var current: BatchRenameSheet?

    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let extPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let findField = NSTextField(string: "")
    private let replaceField = NSTextField(string: "")
    private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let addField = NSTextField(string: "")
    private let addWhere = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseField = NSTextField(string: "")
    private let startField = NSTextField(string: "1")
    private let digitsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sepField = NSTextField(string: "_")
    private let numberFirst = NSButton(checkboxWithTitle: "Number before the name", target: nil, action: nil)
    private let casePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var modeRows: [[NSView]] = []
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private var renameButton: NSButton!

    static func show(_ entries: [FileEntry], from pane: BrowserPane) {
        guard let w = pane.window else { return }
        let s = BatchRenameSheet(entries: entries, pane: pane)
        current = s
        w.beginSheet(s.panel) { _ in BatchRenameSheet.current = nil }
    }

    private init(entries: [FileEntry], pane: BrowserPane) {
        self.entries = entries
        self.pane = pane
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .resizable],
                        backing: .buffered, defer: false)
        super.init()
        panel.minSize = NSSize(width: 520, height: 400)
        build()
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 90).isActive = true
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
        guard let content = panel.contentView else { return }
        let title = NSTextField(labelWithString: "Rename \(entries.count) items")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        modePopup.addItems(withTitles: RenameMode.titles)
        extPopup.addItems(withTitles: ExtensionCase.titles)
        addWhere.addItems(withTitles: ["after the name", "before the name"])
        digitsPopup.addItems(withTitles: (1...6).map { "\($0) digit\($0 == 1 ? "" : "s")" })
        digitsPopup.selectItem(at: 2)
        casePopup.addItems(withTitles: CaseChange.titles)
        baseField.placeholderString = "empty = keep each original name"
        for f in [findField, replaceField, addField, baseField, startField, sepField] {
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        for f in [findField, replaceField, addField, baseField] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        startField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        sepField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for c in [modePopup, extPopup, addWhere, digitsPopup, casePopup] as [NSPopUpButton] {
            c.target = self
            c.action = #selector(changed(_:))
        }
        for c in [matchCase, numberFirst] {
            c.target = self
            c.action = #selector(changed(_:))
        }
        let replaceRows: [NSView] = [row([label("Find:"), findField]), row([label("Replace with:"), replaceField, matchCase])]
        let addRows: [NSView] = [row([label("Text:"), addField, addWhere])]
        let formatRows: [NSView] = [row([label("Name:"), baseField]),
                                    row([label("Start at:"), startField, digitsPopup, NSTextField(labelWithString: "Separator:"), sepField]),
                                    row([label(""), numberFirst])]
        let caseRows: [NSView] = [row([label("Make names:"), casePopup])]
        modeRows = [replaceRows, addRows, formatRows, caseRows]

        let cols: [(String, String, CGFloat)] = [("old", "Now", 230), ("new", "Becomes", 230), ("note", "", 140)]
        for (id, t, w) in cols {
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

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        renameButton = NSButton(title: "Rename", target: self, action: #selector(runBatch(_:)))
        renameButton.keyEquivalent = "\r"
        let buttons = row([summary, cancel, renameButton])
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 200), for: .horizontal)

        var all: [NSView] = [title, row([label("Rename by:"), modePopup])]
        for rows in modeRows { all += rows }
        all.append(row([label("Extension:"), extPopup]))
        let top = NSStackView(views: all)
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
        showModeRows()
        panel.initialFirstResponder = findField
    }

    private func showModeRows() {
        let m = max(0, modePopup.indexOfSelectedItem)
        for (i, rows) in modeRows.enumerated() { for r in rows { r.isHidden = i != m } }
    }

    private var rule: RenameRule {
        var r = RenameRule()
        r.mode = RenameMode(rawValue: max(0, modePopup.indexOfSelectedItem)) ?? .replace
        r.find = findField.stringValue
        r.replaceWith = replaceField.stringValue
        r.caseSensitive = matchCase.state == .on
        r.addText = addField.stringValue
        r.addAtStart = addWhere.indexOfSelectedItem == 1
        r.baseName = baseField.stringValue
        r.startAt = Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        r.digits = 1 + max(0, digitsPopup.indexOfSelectedItem)
        r.separator = sepField.stringValue
        r.numberFirst = numberFirst.state == .on
        r.caseChange = CaseChange(rawValue: max(0, casePopup.indexOfSelectedItem)) ?? .lower
        r.extensionCase = ExtensionCase(rawValue: max(0, extPopup.indexOfSelectedItem)) ?? .keep
        return r
    }

    private func existing(_ dir: String) -> [String] {
        if let c = existingCache[dir] { return c }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        existingCache[dir] = names
        return names
    }

    private func update() {
        let folders = Set(entries.filter { $0.isFolderLike }.map { $0.path })
        plan = RenamePlan.make(paths: entries.map { $0.path }, isFolder: { folders.contains($0) }, rule: rule,
                               existing: { [weak self] d in self?.existing(d) ?? [] })
        table.reloadData()
        let unchanged = plan.items.filter { $0.unchanged && $0.problem == nil }.count
        var t = "\(plan.changes) will be renamed"
        if unchanged > 0 { t += " \u{00B7} \(unchanged) unchanged" }
        if plan.problems > 0 { t += " \u{00B7} \(plan.problems) problem\(plan.problems == 1 ? "" : "s") (fix them to continue)" }
        summary.stringValue = t
        summary.textColor = plan.problems > 0 ? NSColor.systemRed : NSColor.secondaryLabelColor
        renameButton.isEnabled = plan.canRun
    }

    @objc private func changed(_ sender: Any?) {
        showModeRows()
        update()
    }

    #if swift(>=4.2)
    func controlTextDidChange(_ obj: Notification) { update() }
    #else
    override func controlTextDidChange(_ obj: Notification) { update() }
    #endif

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { return plan.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < plan.items.count else { return nil }
        let it = plan.items[row]
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingMiddle
        switch col.identifier.rawValue {
        case "old":
            f.stringValue = it.oldName
        case "new":
            f.stringValue = it.newName
            f.textColor = it.problem != nil ? NSColor.systemRed : (it.unchanged ? NSColor.secondaryLabelColor : NSColor.labelColor)
        default:
            f.stringValue = it.problem ?? (it.unchanged ? "unchanged" : "")
            f.textColor = it.problem != nil ? NSColor.systemRed : NSColor.secondaryLabelColor
            f.toolTip = it.problem
        }
        return f
    }

    // MARK: Buttons

    @objc private func cancel(_ sender: Any?) {
        panel.sheetParent?.endSheet(panel)
    }

    @objc private func runBatch(_ sender: Any?) {
        guard plan.canRun, let p = pane else { return }
        let work = plan.items.filter { !$0.unchanged }.map { (path: $0.path, newName: $0.newName) }
        renameButton.isEnabled = false
        summary.stringValue = "Renaming \(work.count) items\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: Result
            do {
                let (pairs, rec) = try App.ops.renameBatch(work)
                result = .done(pairs, rec)
            } catch {
                result = .failed(error)
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.panel.sheetParent?.endSheet(s.panel)
                switch result {
                case .done(let pairs, let rec):
                    p.registerUndo(rec)
                    p.refreshList(select: pairs.map { $0.to })
                    App.log.info("Batch rename: \(pairs.count) items")
                case .failed(let e):
                    p.showFailure("Batch rename did not run \u{2014} every item kept its name", e)
                }
            }
        }
    }

    private enum Result {
        case done([(from: String, to: String)], UndoRecord)
        case failed(Error)
    }
}
