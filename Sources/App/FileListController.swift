// FileListController.swift
// The list view of a folder: Name / Date Modified / Size / Kind. No disk access on the main
// thread: icons and kinds come from the file extension only.

import AppKit

final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76]    // Return, keypad Enter
        if returnKeys.contains(event.keyCode) && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onOpen?()
            return
        }
        super.keyDown(with: event)
    }
}

enum FileIcons {
    private static var byExt: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]

    static func icon(for e: FileEntry) -> NSImage? {
        if e.isDirectory && !e.isPackage { return NSImage(named: NSImage.folderName) }
        let key = e.isPackage ? e.ext : (e.ext.isEmpty ? "public.data" : e.ext)
        if let i = byExt[key] { return i }
        let i = NSWorkspace.shared.icon(forFileType: key)
        i.size = NSSize(width: 16, height: 16)
        byExt[key] = i
        return i
    }

    static func kind(for e: FileEntry) -> String {
        if e.isDirectory && !e.isPackage { return "Folder" }
        if e.kind == .symlink { return "Alias" }
        let ext = e.ext
        if ext.isEmpty { return "Document" }
        if let k = kinds[ext] { return k }
        var text = ext.uppercased() + " file"
        if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, nil)?.takeRetainedValue(),
            let d = UTTypeCopyDescription(uti)?.takeRetainedValue() as String?, !d.isEmpty {
            text = d.prefix(1).uppercased() + d.dropFirst()
        }
        kinds[ext] = text
        return text
    }
}

final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scroll = NSScrollView()
    let table = FileTableView()
    private let message = NSTextField(labelWithString: "")
    private(set) var entries: [FileEntry] = []

    var sortKey: EntrySort.Key = .name
    var ascending = true
    var foldersFirst = true

    /// Double-click, Return.
    var onOpen: (([FileEntry]) -> Void)?
    var onSelectionChange: (() -> Void)?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    override init() {
        super.init()
        let columns: [(String, String, CGFloat, EntrySort.Key)] = [
            ("name", "Name", 320, .name), ("modified", "Date Modified", 170, .modified),
            ("size", "Size", 80, .size), ("kind", "Kind", 140, .kind)]
        for (id, title, width, key) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            table.addTableColumn(c)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.onOpen = { [weak self] in self?.openSelection() }
        table.sortDescriptors = [NSSortDescriptor(key: EntrySort.Key.name.rawValue, ascending: true)]

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        message.alignment = .center
        message.textColor = NSColor.secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        scroll.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
    }

    // MARK: Content

    /// Replace the rows. Keeps the selection by name unless `select` is given.
    func setEntries(_ new: [FileEntry], select: [String]? = nil) {
        let keep = select ?? selectedEntries().map { $0.name }
        entries = EntrySort.sort(new, by: sortKey, ascending: ascending, foldersFirst: foldersFirst)
        table.reloadData()
        let wanted = Set(keep)
        var rows = IndexSet()
        for (i, e) in entries.enumerated() where wanted.contains(e.name) { rows.insert(i) }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
        else if select != nil { table.scrollRowToVisible(0) }
    }

    func showMessage(_ text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
    }

    func selectedEntries() -> [FileEntry] {
        return table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        openSelection()
    }

    func openSelection() {
        let sel = selectedEntries()
        if !sel.isEmpty { onOpen?(sel) }
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < entries.count else { return nil }
        let e = entries[row]
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = e.name
            cell.imageView?.image = FileIcons.icon(for: e)
            cell.textField?.textColor = e.isHidden ? NSColor.secondaryLabelColor : NSColor.labelColor
        case "modified":
            cell.textField?.stringValue = e.modified > 0 ? dateFormatter.string(from: Date(timeIntervalSince1970: e.modified)) : "--"
        case "size":
            cell.textField?.stringValue = e.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)
        default:
            cell.textField?.stringValue = FileIcons.kind(for: e)
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingMiddle
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            if id.rawValue == "size" { tf.alignment = .right }
            if id.rawValue != "name" { tf.textColor = NSColor.secondaryLabelColor }
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key, let key = EntrySort.Key(rawValue: k) else { return }
        sortKey = key
        ascending = d.ascending
        setEntries(entries)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == "name", row < entries.count else { return nil }
        return entries[row].name
    }
}
