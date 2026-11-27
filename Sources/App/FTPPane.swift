// FTPPane.swift
// 0.16: an FTP server as a Find pane (plain FTP through macOS's curl - see Core/FTP.swift).
// It acts like a folder as far as FTP allows:
// - Open: click the server in the sidebar or type ftp://... in the path field. Any number of panes
//   can show FTP servers. Double-click or Return opens a folder; Back, Up (Cmd-Up) and the path bar
//   work; Cmd-R re-reads the folder.
// - Upload: drag files or folders in from another pane or Finder (onto a folder row: into it).
// - Download: drag files or folders out into another Find pane (or onto a sidebar folder), or
//   right-click > Copy to Other Pane. Downloads go through Find's usual checked copy.
// - Rename in place (Return, or click a selected name again) and Delete (permanent - FTP has no Trash):
//   files and, since 0.17, folders - where the server allows it (in practice inside your own folder).
// - 0.17: each folder's last listing is shown at once and re-read quietly (spinner bottom right);
//   uploads and downloads show in the Copies window with progress, never blocking the pane.
// Never overwritten: anything that is already there (a clash asks Keep Both / Skip / Stop).
// Whatever the server refuses is reported, never worked around.

import AppKit

/// FTP connections by server and account, so a drag from an FTP pane can be downloaded where it is dropped.
enum FTPSessions {
    private static var clients: [String: FTPClient] = [:]
    private static var names: [String: String] = [:]

    static func key(_ s: FTPServer) -> String { return s.host.lowercased() + "|" + s.user }

    static func register(_ c: FTPClient, name: String) {
        clients[key(c.server)] = c
        names[key(c.server)] = name
    }

    static func client(_ key: String) -> FTPClient? { return clients[key] }
    static func name(_ key: String) -> String { return names[key] ?? "FTP server" }
}

/// 0.17: the remembered FTP listings, kept in Find's support folder between launches.
enum FTPMemory {
    static var file: String { return Paths.join(App.files.supportDir, "ftp-listings.json") }
    static let shared: FTPListingMemory = {
        if let d = FileManager.default.contents(atPath: file), let m = FTPListingMemory.decode(d) { return m }
        return FTPListingMemory()
    }()
    private static var saveQueued = false

    static func server(_ c: FTPClient) -> String { return FTPSessions.key(c.server) }

    /// Saved a few seconds after the last change (one write for many folders).
    static func saveSoon() {
        if saveQueued { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            saveQueued = false
            DispatchQueue.global(qos: .utility).async {
                if let d = shared.encode(), !App.files.writeData(d, to: file) {
                    App.log.warn("FTP: could not save the remembered listings (FTP-MEM)")
                }
            }
        }
    }
}

/// What is on the pasteboard while FTP items are dragged (inside Find only).
struct FTPDragItem: Codable {
    let path: [String]
    let isDir: Bool
    let size: Int64?
}

struct FTPDragPayload: Codable {
    let key: String
    let items: [FTPDragItem]

    static let type = NSPasteboard.PasteboardType("com.find.ftp-items")

    static func read(_ pb: NSPasteboard) -> FTPDragPayload? {
        guard let s = pb.string(forType: type), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FTPDragPayload.self, from: d)
    }

    var text: String? {
        guard let d = try? JSONEncoder().encode(self) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// The FTP list inside a pane.
final class FTPBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let client: FTPClient
    let serverName: String
    private(set) var path: [String] = []
    private(set) var entries: [FTPEntry] = []
    private(set) var busy = false
    /// 0.17: re-reading the folder in the background while the remembered listing shows.
    private(set) var refreshing = false
    private var loadToken = 0
    /// Rename in place: the row being edited.
    private var editingRow = -1
    /// Click-twice rename: the row that was already selected when the click came.
    private var clickTimer: Timer?
    private lazy var nameDelegate: FTPNameFieldDelegate = {
        let d = FTPNameFieldDelegate()
        d.onEnd = { [weak self] n in self?.nameEditEnded(n) }
        d.onEscape = { [weak self] in self?.cancelInlineEdit() }
        return d
    }()
    private(set) var status = ""
    var stopRequested = false
    private var back: [[String]] = []
    private var forward: [[String]] = []

    let scroll = NSScrollView()
    let table = FTPTableView()
    /// Told whenever the folder, the busy state or the status line changes.
    var onChange: (() -> Void)?
    /// The folder of another pane in the same window (Copy to Other Pane).
    var otherPaneFolder: (() -> String?)?
    weak var pane: BrowserPane?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(server: FTPServer, name: String) {
        client = FTPClient(server: server)
        serverName = name
        super.init()
        FTPSessions.register(client, name: name)
        // 0.17.1: as in a local folder - Date and Size stay at the right edge with their own widths and
        // Name takes all the rest, following the pane's width.
        for (id, title, width, minW) in [("name", "Name", 320, 120), ("date", "Date Modified", 150, 90), ("size", "Size", 80, 54)] as [(String, String, CGFloat, CGFloat)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = minW
            c.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            c.headerCell = ThemedHeaderCell(textCell: title)
            table.addTableColumn(c)
        }
        // "First column only" is raw value 5; its Swift name differs between SDKs, the number does not.
        if let firstOnly = NSTableView.ColumnAutoresizingStyle(rawValue: 5) { table.columnAutoresizingStyle = firstOnly }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.action = #selector(rowClicked(_:))
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.browser = self
        table.registerForDraggedTypes([.fileURL, FTPDragPayload.type])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 0)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = ThemedScroller()
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Name fills whatever the pane leaves, every time the pane changes size.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fitColumns(_:)), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        applyTheme()
        App.log.info("FTP \(Ascii.clean(name)): opened (\(Ascii.clean(server.host)), account \(server.user.isEmpty ? "anonymous" : Ascii.clean(server.user)))")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Date and Size keep their widths at the right edge; Name gets all the rest.
    @objc func fitColumns(_ sender: Any?) {
        let cols = table.tableColumns
        guard let name = cols.first(where: { $0.identifier.rawValue == "name" }) else { return }
        let others = cols.filter { $0 !== name }.reduce(CGFloat(0)) { $0 + $1.width }
        let w = scroll.contentView.bounds.width - others - 2
        if w >= name.minWidth && abs(name.width - w) > 0.5 { name.width = w }
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        let glass = Finish.contentGlass > 0
        if glass { Finish.glassTables.add(table) } else { Finish.glassTables.remove(table) }
        table.backgroundColor = glass ? .clear : tm.background
        scroll.backgroundColor = tm.background
        scroll.drawsBackground = !glass
        table.rowHeight = tm.rowHeight
        table.reloadData()
    }

    // MARK: Folder

    var crumbs: [(name: String, path: String)] {
        var out: [(name: String, path: String)] = [(serverName, "ftp-crumb:0")]
        for (i, p) in path.enumerated() { out.append((p, "ftp-crumb:\(i + 1)")) }
        return out
    }

    var addressText: String { return client.url(path, dir: true) }
    var title: String { return path.last ?? serverName }
    var canGoBack: Bool { return true }
    var canGoForward: Bool { return !forward.isEmpty }

    private func setStatus(_ s: String) {
        status = s
        onChange?()
    }

    /// 0.17: a folder seen before shows its remembered listing at once; the server is read again in the
    /// background (spinner bottom right) and the list is updated quietly when the answer comes, keeping
    /// the selection. A folder never seen before is read as before.
    func load(_ p: [String], select: String? = nil, history: Bool = true) {
        cancelInlineEdit()
        if history && p != path && !entries.isEmpty { back.append(path); forward.removeAll() }
        loadToken += 1
        let token = loadToken
        let mem = FTPMemory.server(client)
        if let cached = FTPMemory.shared.get(mem, p) {
            let wasHere = p == path
            path = p
            show(cached, select: select.map { [$0] } ?? (wasHere ? selectedNames : []), keepScroll: wasHere)
            refreshing = true
            setStatus(itemsLine + "  \u{00B7}  checking the server\u{2026}")
        } else {
            refreshing = false
            setBusy(true, "Reading \(p.last ?? serverName)\u{2026}")
        }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let s = self else { return }
            let r = s.client.list(p)
            DispatchQueue.main.async {
                guard token == s.loadToken else { return }   // another folder was opened meanwhile
                let quiet = s.refreshing
                s.busy = false
                s.refreshing = false
                switch r {
                case .ok(let list):
                    FTPMemory.shared.put(mem, p, list)
                    FTPMemory.saveSoon()
                    // While a name is being edited the list is not redrawn (the edit would be lost).
                    let changed = s.editingRow < 0 && !quiet || s.editingRow < 0 && list.sorted(by: { $0.name < $1.name }) != s.entries.sorted(by: { $0.name < $1.name })
                    s.path = p
                    if changed {
                        s.show(list, select: quiet ? s.selectedNames : (select.map { [$0] } ?? []), keepScroll: quiet)
                    }
                    App.log.info("FTP \(Ascii.clean(s.serverName)): read /\(Ascii.clean(p.joined(separator: "/"))) - \(list.count) items in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(quiet ? (changed ? ", list updated" : ", unchanged") : "")")
                    s.setStatus(s.itemsLine)
                case .failed(let f):
                    App.log.warn("FTP \(Ascii.clean(s.serverName)): could not open /\(Ascii.clean(p.joined(separator: "/"))) - \(f.code) \(Ascii.clean(f.text))")
                    if quiet {
                        // The remembered list stays; say it could not be checked.
                        s.setStatus(s.itemsLine + "  \u{00B7}  not checked: \(f.code)")
                    } else {
                        s.setStatus("\(f.code): \(f.text)")
                        s.message("Could not open \(p.last ?? s.serverName)", "\(f.text)\n\nCode \(f.code).")
                    }
                }
            }
        }
    }

    private var itemsLine: String {
        return "\(entries.count) item\(entries.count == 1 ? "" : "s")  \u{00B7}  FTP \(serverName)"
    }

    private var selectedNames: [String] { return selectedEntries.map { $0.name } }

    private func show(_ list: [FTPEntry], select names: [String], keepScroll: Bool) {
        let visible = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
        entries = list.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        table.reloadData()
        let rows = IndexSet(entries.indices.filter { names.contains(entries[$0].name) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let pe = pendingEdit, let i = entries.index(where: { $0.name == pe }) {
            pendingEdit = nil
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            table.scrollRowToVisible(i)
            DispatchQueue.main.async { [weak self] in self?.beginInlineEdit(i) }
            return
        }
        if keepScroll {
            table.enclosingScrollView?.contentView.scroll(to: visible)
            table.enclosingScrollView?.reflectScrolledClipView(table.enclosingScrollView!.contentView)
        } else if let first = rows.first {
            table.scrollRowToVisible(first)
        } else {
            table.scrollRowToVisible(0)
        }
    }

    /// After a change on the server: forget the remembered listing of `dir` and read it again.
    private func changed(_ dir: [String], select: String? = nil) {
        FTPMemory.shared.forget(FTPMemory.server(client), dir)
        FTPMemory.saveSoon()
        if dir == path { load(dir, select: select, history: false) }
    }

    func refresh() { load(path, history: false) }

    /// Back: the previous FTP folder; at the first one, false (the pane goes back to its local folder).
    func goBack() -> Bool {
        guard let prev = back.popLast() else { return false }
        forward.append(path)
        load(prev, select: path.last, history: false)
        return true
    }

    func goForward() {
        guard let next = forward.popLast() else { NSSound.beep(); return }
        back.append(path)
        load(next, history: false)
    }

    func goUp() {
        guard !path.isEmpty else { NSSound.beep(); return }
        load(Array(path.dropLast()), select: path.last)
    }

    func crumbClicked(_ id: String) {
        guard let n = Int(id.replacingOccurrences(of: "ftp-crumb:", with: "")), n <= path.count else { return }
        if BrowserPane.commandClick { pane?.openFTPInNewWindow(client.server, name: serverName, start: Array(path.prefix(n))); return }
        load(Array(path.prefix(n)))
    }

    @objc func openSelected(_ sender: Any?) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < entries.count, entries[r].isDir else { return }
        // 0.17.7: Cmd-double-click a folder = that folder in a new window (same server, no new sign-in).
        if BrowserPane.commandClick { pane?.openFTPInNewWindow(client.server, name: serverName, start: path + [entries[r].name]); return }
        load(path + [entries[r].name])
    }

    private func setBusy(_ b: Bool, _ text: String?) {
        busy = b
        if b { stopRequested = false }
        if let t = text { status = t }
        onChange?()
    }

    func stop() {
        stopRequested = true
        if busy { setStatus("Stopping after the current file\u{2026}") }
    }

    private var selectedEntries: [FTPEntry] {
        return table.selectedRowIndexes.filter { $0 < entries.count }.map { entries[$0] }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { return entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { return ThemedRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < entries.count else { return nil }
        let e = entries[row]
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ThemedCellView)
            ?? ThemedCellView.make(identifier: id, withIcon: id.rawValue == "name")
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = e.name
            let ext = Paths.fileExtension(e.name)
            cell.imageView?.image = NSWorkspace.shared.icon(forFileType: e.isDir ? "public.folder" : (ext.isEmpty ? "public.data" : ext))
            cell.secondary = false
        case "date":
            cell.textField?.stringValue = e.modified.map { dateFormatter.string(from: $0) } ?? "--"
            cell.secondary = true
        default:
            cell.textField?.stringValue = e.isDir ? "--" : (e.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "--")
            cell.textField?.alignment = .right
            cell.secondary = true
        }
        cell.applyTheme()
        return cell
    }

    // MARK: Drag out (download where it is dropped, inside Find)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < entries.count else { return nil }
        // Every selected row is dragged; each row writes the whole selection once (the first row only).
        let rows = tableView.selectedRowIndexes.contains(row) ? Array(tableView.selectedRowIndexes) : [row]
        guard row == rows.first else {
            let empty = NSPasteboardItem()
            empty.setString("", forType: NSPasteboard.PasteboardType("com.find.ftp-more"))
            return empty
        }
        let items = rows.filter { $0 < entries.count }.map { FTPDragItem(path: path + [entries[$0].name], isDir: entries[$0].isDir, size: entries[$0].size) }
        let payload = FTPDragPayload(key: FTPSessions.key(client.server), items: items)
        let pi = NSPasteboardItem()
        pi.setString(payload.text ?? "", forType: FTPDragPayload.type)
        return pi
    }

    // MARK: Drop in (upload)

    /// Server items dragged inside this same server (0.17.1: put into another folder there).
    private func serverPayload(_ info: NSDraggingInfo) -> FTPDragPayload? {
        guard let p = FTPDragPayload.read(FileDrag.pasteboard(info)), p.key == FTPSessions.key(client.server) else { return nil }
        return p
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if let p = serverPayload(info) {
            // Onto a folder row that isn't one of the dragged items (or inside one of them).
            guard dropOperation == .on, row >= 0, row < entries.count, entries[row].isDir else { return [] }
            let target = path + [entries[row].name]
            if p.items.contains(where: { target.count >= $0.path.count && Array(target.prefix($0.path.count)) == $0.path }) { return [] }
            return .move
        }
        guard !busy, !FileDrag.paths(info).isEmpty else { return [] }
        if dropOperation == .on, row >= 0, row < entries.count, entries[row].isDir { return .copy }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if let p = serverPayload(info) {
            guard dropOperation == .on, row >= 0, row < entries.count, entries[row].isDir else { return false }
            moveOnServer(p.items.map { $0.path }, into: path + [entries[row].name])
            return true
        }
        let locals = FileDrag.paths(info)
        guard !busy, !locals.isEmpty else { return false }
        var dir = path
        if dropOperation == .on, row >= 0, row < entries.count, entries[row].isDir { dir = path + [entries[row].name] }
        upload(locals, into: dir)
        return true
    }

    /// Upload in the background: progress, Stop and diagnostics are in the Copies window.
    func upload(_ locals: [String], into dir: [String]) {
        let where_ = (dir.isEmpty ? [serverName] : dir).joined(separator: "/")
        let c = client, name = serverName
        let what = locals.count == 1 ? "\u{201C}\(Paths.lastComponent(locals[0]))\u{201D}" : "\(locals.count) items"
        let t = CopyTask(title: "Uploading \(what) to \(name): \(where_)")
        CopiesCenter.shared.add(t)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let existing: [String]
            switch c.list(dir) {
            case .ok(let l): existing = l.map { $0.name }
            case .failed(let f):
                t.progress.note("Could not list \(where_): \(f.code) \(f.text)")
                DispatchQueue.main.async {
                    CopiesCenter.shared.finish(t, state: "failed", line: "nothing uploaded (\(f.code))")
                    self?.message("Nothing was uploaded", "Find could not list \(where_) first (it checks every name before uploading).\n\n\(f.text)\nCode \(f.code).")
                }
                return
            }
            let plan = FTPUploadPlan.make(locals, into: dir, existing: existing, choose: { n in
                var ch = ConflictChoice.skip
                DispatchQueue.main.sync { ch = FTPBrowser.askClash(n, where_, nothingOverwritten: "on the server") }
                return ch
            })
            t.progress.plan(files: plan.items.count, bytes: plan.items.reduce(Int64(0)) { $0 + $1.size })
            var done = 0, failed: [String] = []
            var bytes: Int64 = 0
            for item in plan.items {
                if t.isCancelled() { t.progress.note("Stopped before \(item.name)"); break }
                let remote = (item.remoteDir + [item.name]).joined(separator: "/")
                CrashCapture.note("FTP upload \(done + failed.count + 1) of \(plan.items.count): \(item.local) -> /\(remote) (\(item.size) bytes)")
                t.progress.begin(item.local, name: remote, size: item.size)
                let size = item.size
                if let f = c.upload(item, progress: { frac in t.progress.current(done: Int64(Double(size) * frac)) }) {
                    failed.append("\(remote): \(f.code) \(f.text)")
                    t.progress.finish(item.local, ok: false, detail: "\(f.code) \(f.text)")
                    App.log.warn("FTP \(Ascii.clean(name)): upload FAILED \(Ascii.clean(item.local)) -> /\(Ascii.clean(remote)): \(f.code) \(Ascii.clean(f.text))")
                    if f.code == "FTP-67" || f.code == "FTP-07" || f.code == "FTP-06" { break }
                } else {
                    done += 1
                    bytes += item.size
                    t.progress.finish(item.local, ok: true, detail: "size checked on the server")
                    App.log.info("FTP \(Ascii.clean(name)): uploaded \(Ascii.clean(item.local)) -> /\(Ascii.clean(remote)) (\(item.size) bytes, size checked)")
                }
            }
            CrashCapture.note("")
            let left = plan.items.count - done - failed.count
            DispatchQueue.main.async {
                self?.changed(dir)
                var lines = ["Uploaded and checked: \(done) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))",
                             "Failed: \(failed.count)", "Skipped: \(plan.skipped.count)"]
                if left > 0 { lines.append("Not uploaded (stopped): \(left)") }
                lines += failed.map { "FAILED " + $0 } + plan.skipped.map { "SKIPPED " + $0 }
                for l in lines { App.log.info("FTP upload report: \(Ascii.clean(l))") }
                let state = left > 0 || plan.cancelled ? "stopped" : (failed.isEmpty ? "done" : "failed")
                CopiesCenter.shared.finish(t, state: state, line: "\(done) uploaded" + (failed.isEmpty ? "" : ", \(failed.count) failed") + (plan.skipped.isEmpty ? "" : ", \(plan.skipped.count) skipped"))
                if !failed.isEmpty || !plan.skipped.isEmpty || left > 0 || plan.cancelled {
                    FTPBrowser.report(plan.cancelled ? "Upload stopped" : "Upload to \(dir.last ?? name)", lines, server: name)
                }
            }
        }
    }

    static func askClash(_ name: String, _ where_: String, nothingOverwritten: String) -> ConflictChoice {
        let a = ThemedAlert()
        a.messageText = "\u{201C}\(name)\u{201D} is already in \(where_)."
        a.informativeText = "Nothing \(nothingOverwritten) is ever overwritten. Keep Both adds a number to the new item's name."
        a.addButton(withTitle: "Keep Both")
        a.addButton(withTitle: "Skip")
        a.addButton(withTitle: "Stop")
        switch a.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .skip
        default: return .cancel
        }
    }

    // MARK: Move within the server, New Folder (0.17.1)

    /// Put items into another folder on this server (drag onto a folder row). The server decides where
    /// that is allowed; a name already there is never replaced.
    func moveOnServer(_ items: [[String]], into dest: [String]) {
        let c = client, name = serverName
        let from = path
        setStatus("Moving \(items.count) item\(items.count == 1 ? "" : "s") into \(dest.last ?? name)\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done = 0
            var failed: [String] = []
            for it in items {
                if let f = c.moveOnServer(it, into: dest) {
                    failed.append("\(it.last ?? ""): \(f.code) \(f.text)")
                    App.log.warn("FTP \(Ascii.clean(name)): move FAILED /\(Ascii.clean(it.joined(separator: "/"))) -> /\(Ascii.clean(dest.joined(separator: "/"))): \(f.code) \(Ascii.clean(f.text))")
                } else {
                    done += 1
                    App.log.info("FTP \(Ascii.clean(name)): moved /\(Ascii.clean(it.joined(separator: "/"))) into /\(Ascii.clean(dest.joined(separator: "/"))) (confirmed)")
                    FTPMemory.shared.forget(FTPMemory.server(c), it)
                }
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                FTPMemory.shared.forget(FTPMemory.server(c), dest)
                s.changed(from)
                if !failed.isEmpty {
                    FTPBrowser.report("Move on \(name)", ["Moved: \(done)", "Not moved: \(failed.count)"] + failed.map { "FAILED " + $0 }, server: name)
                }
            }
        }
    }

    /// New Folder (Shift-Cmd-N) in the FTP pane: "untitled folder" (numbered if taken), then its name
    /// opens for typing, as in a local folder.
    func newFolder() {
        let taken = Set(entries.map { $0.name })
        let n = FTPNames.unique("untitled folder", existing: taken)
        let c = client, dir = path
        setStatus("Making a new folder\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = c.makeFolderOnServer(dir, name: n)
            DispatchQueue.main.async {
                guard let s = self else { return }
                if let f = err {
                    App.log.warn("FTP \(Ascii.clean(s.serverName)): new folder FAILED in /\(Ascii.clean(dir.joined(separator: "/"))): \(f.code) \(Ascii.clean(f.text))")
                    s.setStatus("\(f.code): \(f.text)")
                    s.message("No folder was made", "\(f.text)\n\nCode \(f.code).")
                    return
                }
                App.log.info("FTP \(Ascii.clean(s.serverName)): made folder /\(Ascii.clean((dir + [n]).joined(separator: "/")))")
                s.pendingEdit = n
                s.changed(dir, select: n)
            }
        }
    }

    /// After New Folder: the name to edit as soon as the list shows it.
    private var pendingEdit: String?

    // MARK: Delete (permanent: files, and folders where the server allows it)

    @objc func deleteSelected(_ sender: Any?) {
        guard !busy else { return }
        cancelInlineEdit()
        let picked = selectedEntries
        if picked.isEmpty { NSSound.beep(); return }
        let files = picked.filter { !$0.isDir }
        let folders = picked.filter { $0.isDir }
        let a = ThemedAlert()
        a.alertStyle = .critical
        var what: [String] = []
        if !files.isEmpty { what.append("\(files.count) file\(files.count == 1 ? "" : "s")") }
        if !folders.isEmpty { what.append("\(folders.count) folder\(folders.count == 1 ? "" : "s") and everything in \(folders.count == 1 ? "it" : "them")") }
        a.messageText = "Delete \(what.joined(separator: " and ")) from \(serverName) permanently?"
        var info = "An FTP server has no Trash: deleted items can't be put back.\n\n"
        info += picked.prefix(12).map { "\u{2022} " + $0.name + ($0.isDir ? "  (folder, with everything in it)" : "") }.joined(separator: "\n")
        if picked.count > 12 { info += "\n\u{2026} and \(picked.count - 12) more" }
        if !folders.isEmpty {
            info += "\n\nFolders are only deleted where the server allows it (your own folder). The first thing the server refuses stops the delete; whatever was not deleted stays as it was."
        }
        a.informativeText = info
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Delete Permanently")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        let dir = path
        let c = client, name = serverName
        let t = CopyTask(title: "Deleting \(what.joined(separator: " and ")) on \(name): /\(dir.joined(separator: "/"))", indeterminate: true)
        CopiesCenter.shared.add(t)
        setStatus("Deleting\u{2026} (see Window > Copies)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var doneFiles = 0, doneFolders = 0, failed: [String] = []
            var stopped = false
            for e in picked {
                if t.isCancelled() { stopped = true; break }
                let target = dir + [e.name]
                let remote = target.joined(separator: "/")
                if e.isDir {
                    let r = c.deleteFolder(target, isCancelled: t.isCancelled, onItem: { t.progress.note("Deleting /\($0)") })
                    doneFiles += r.files
                    doneFolders += r.folders
                    if let f = r.failure {
                        failed.append("\(e.name)/: \(f.code) \(f.text)")
                        App.log.warn("FTP \(Ascii.clean(name)): folder delete STOPPED /\(Ascii.clean(remote)) after \(r.files) files, \(r.folders) folders: \(f.code) \(Ascii.clean(f.text))")
                        if f.code == "FTP-STOP" { stopped = true }
                        break   // the first refusal stops everything
                    }
                    App.log.info("FTP \(Ascii.clean(name)): deleted folder /\(Ascii.clean(remote)) (\(r.files) files, \(r.folders) folders, confirmed gone)")
                } else {
                    t.progress.note("Deleting /\(remote)")
                    if let err = c.deleteFile(target, isDir: false) {
                        failed.append("\(e.name): \(err.code) \(err.text)")
                        App.log.warn("FTP \(Ascii.clean(name)): delete FAILED /\(Ascii.clean(remote)): \(err.code) \(Ascii.clean(err.text))")
                    } else {
                        doneFiles += 1
                        App.log.info("FTP \(Ascii.clean(name)): deleted /\(Ascii.clean(remote)) (confirmed gone)")
                    }
                }
            }
            DispatchQueue.main.async {
                let line = "deleted \(doneFiles) file\(doneFiles == 1 ? "" : "s"), \(doneFolders) folder\(doneFolders == 1 ? "" : "s")" + (failed.isEmpty ? "" : ", stopped at a refusal")
                CopiesCenter.shared.finish(t, state: stopped ? "stopped" : (failed.isEmpty ? "done" : "failed"), line: line)
                self?.changed(dir)
                if !failed.isEmpty || stopped {
                    FTPBrowser.report("Delete on \(name)", ["Files deleted: \(doneFiles)", "Folders deleted: \(doneFolders)",
                                                           "Problems: \(failed.count)", stopped ? "Stopped by you" : "Not stopped"] + failed.map { "FAILED " + $0 }, server: name)
                }
            }
        }
    }

    // MARK: Rename in place (files and folders, where the server allows it)

    /// Return, or Rename in the menu: edit the name right in the list.
    @objc func renameSelected(_ sender: Any?) {
        guard !busy else { return }
        let rows = table.selectedRowIndexes
        guard rows.count == 1, let r = rows.first, r < entries.count else { NSSound.beep(); return }
        beginInlineEdit(r)
    }

    /// A click on a name that was already selected (and nothing else selected) starts the rename after a
    /// moment - the same rule as Finder; a double-click opens instead.
    @objc func rowClicked(_ sender: Any?) {
        clickTimer?.invalidate()
        let r = table.clickedRow
        guard r >= 0, r == table.selectedBeforeClick, table.selectedRowIndexes.count == 1, editingRow < 0,
            let ev = NSApp.currentEvent, ev.clickCount == 1,
            table.clickedColumn == table.column(withIdentifier: NSUserInterfaceItemIdentifier("name")) else { return }
        clickTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval + 0.05, repeats: false) { [weak self] _ in
            guard let s = self, s.table.selectedRow == r, s.table.selectedRowIndexes.count == 1 else { return }
            s.beginInlineEdit(r)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if editingRow >= 0 { cancelInlineEdit() }
    }

    private func nameField(_ row: Int) -> NSTextField? {
        let col = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard col >= 0, row >= 0, row < table.numberOfRows else { return nil }
        return (table.view(atColumn: col, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField
    }

    private func beginInlineEdit(_ row: Int) {
        guard row < entries.count, let f = nameField(row) else { return }
        clickTimer?.invalidate()
        editingRow = row
        table.scrollRowToVisible(row)
        f.isEditable = true
        f.isSelectable = true
        f.delegate = nameDelegate
        f.drawsBackground = true
        f.backgroundColor = ThemeManager.shared.background
        f.textColor = ThemeManager.shared.text
        table.window?.makeFirstResponder(f)
        // Select the name without its extension, as Finder does.
        if let ed = f.currentEditor() {
            let n = entries[row].name.utf16.count
            let ext = entries[row].isDir ? "" : Paths.fileExtension(entries[row].name)
            ed.selectedRange = NSRange(location: 0, length: ext.isEmpty || ext.utf16.count + 1 >= n ? n : n - ext.utf16.count - 1)
        }
    }

    private func endFieldEditing(_ f: NSTextField) {
        f.isEditable = false
        f.isSelectable = false
        f.drawsBackground = false
        f.delegate = nil
    }

    /// Escape, another selection or another folder: nothing is renamed. (Return or a click elsewhere
    /// keeps the new name, as in Finder.)
    func cancelInlineEdit() {
        clickTimer?.invalidate()
        guard editingRow >= 0 else { return }
        let r = editingRow
        editingRow = -1
        if let f = nameField(r) {
            _ = f.abortEditing()
            if r < entries.count { f.stringValue = entries[r].name }
            endFieldEditing(f)
        }
        table.window?.makeFirstResponder(table)
    }

    private func nameEditEnded(_ obj: Notification) {
        guard editingRow >= 0, let f = obj.object as? NSTextField else { return }
        let r = editingRow
        editingRow = -1
        endFieldEditing(f)
        table.window?.makeFirstResponder(table)
        guard r < entries.count else { return }
        let e = entries[r]
        let newName = f.stringValue.trimmingCharacters(in: .whitespaces)
        if newName.isEmpty || newName == e.name { f.stringValue = e.name; return }
        guard FTPNames.isSafe(newName) else {
            f.stringValue = e.name
            message("That name can't be used", "Names can't contain / or line breaks.")
            return
        }
        if entries.contains(where: { $0.name == newName }) {
            f.stringValue = e.name
            message("Not renamed", "\u{201C}\(newName)\u{201D} is already in this folder. Nothing is ever replaced.")
            return
        }
        // Shown at once; put back if the server refuses.
        let dir = path
        let c = client, name = serverName
        setStatus("Renaming\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = c.renameFile(dir + [e.name], isDir: e.isDir, to: newName)
            DispatchQueue.main.async {
                guard let s = self else { return }
                let from = (dir + [e.name]).joined(separator: "/")
                if let fl = err {
                    App.log.warn("FTP \(Ascii.clean(name)): rename FAILED /\(Ascii.clean(from)) -> \(Ascii.clean(newName)): \(fl.code) \(Ascii.clean(fl.text))")
                    if s.path == dir, r < s.entries.count, s.entries[r].name == e.name { s.nameField(r)?.stringValue = e.name }
                    s.message("Not renamed", "\(fl.text)\n\nCode \(fl.code).")
                    s.changed(dir, select: e.name)
                } else {
                    App.log.info("FTP \(Ascii.clean(name)): renamed /\(Ascii.clean(from)) -> \(Ascii.clean(newName))")
                    if e.isDir { FTPMemory.shared.forget(FTPMemory.server(c), dir + [e.name]) }
                    s.changed(dir, select: newName)
                }
            }
        }
    }

    // MARK: Context menu

    func menu(forRow row: Int) -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: t, action: enabled ? sel : nil, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        if row >= 0 && row < entries.count && !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let sel = selectedEntries
        if sel.count == 1, sel[0].isDir { add("Open", #selector(openSelected(_:))) }
        if !sel.isEmpty, let other = otherPaneFolder?() {
            add("Copy to \u{201C}\(Paths.lastComponent(other))\u{201D} (Other Pane)", #selector(copyToOtherPane(_:)), enabled: !busy)
        }
        if !sel.isEmpty { m.addItem(NSMenuItem.separator()) }
        add("Rename", #selector(renameSelected(_:)), enabled: sel.count == 1 && !busy)
        add("Delete\u{2026}", #selector(deleteSelected(_:)), enabled: !sel.isEmpty && !busy)
        m.addItem(NSMenuItem.separator())
        add("New Folder", #selector(newFolderCommand(_:)))
        if sel.count == 1 && sel[0].isDir {
            add("Add \u{201C}\(sel[0].name)\u{201D} to Favorites", #selector(addSelectedToFavorites(_:)))
        } else {
            add("Add This Folder to Favorites", #selector(addCurrentToFavorites(_:)))
        }
        add("Upload\u{2026}", #selector(chooseUpload(_:)))
        if !FileDragPasteCheck.localPaths().isEmpty { add("Paste (Upload Here)", #selector(pasteHere(_:))) }
        add("Refresh", #selector(refreshCommand(_:)))
        if busy { add("Stop", #selector(stopCommand(_:))) }
        return m
    }

    @objc func refreshCommand(_ sender: Any?) { refresh() }
    @objc func newFolderCommand(_ sender: Any?) { newFolder() }
    @objc func addSelectedToFavorites(_ sender: Any?) {
        if let e = selectedEntries.first, e.isDir { addFavorite(path + [e.name]) }
    }
    @objc func addCurrentToFavorites(_ sender: Any?) { addFavorite(path) }

    /// Put an FTP folder in the sidebar's Favorites (the server must be saved in the sidebar, so its
    /// password is in the Keychain).
    func addFavorite(_ p: [String]) {
        guard let srv = FTPFavorite.savedServer(for: client) else {
            message("Save the server first", "Add this FTP server to the sidebar (Servers > Add Server..., with its password) - then its folders can be favourites.")
            return
        }
        let f = FTPFavorite.make(serverID: srv.id, path: p)
        if !Prefs.favorites.contains(f) { Prefs.favorites = Prefs.favorites + [f] }
        App.log.info("Favorites: added FTP folder \(Ascii.clean(FTPFavorite.tooltip(f)))")
        setStatus("Added to Favorites - right-click it in the sidebar to give it its own name")
    }
    @objc func pasteHere(_ sender: Any?) {
        let local = FileDragPasteCheck.localPaths()
        if !local.isEmpty { upload(local, into: path) }
    }
    @objc func stopCommand(_ sender: Any?) { stop() }

    /// Edit > Copy in an FTP pane: the selected server items, for Paste in a local pane (download).
    func copyToClipboard() {
        let sel = selectedEntries
        if sel.isEmpty { NSSound.beep(); return }
        let payload = FTPDragPayload(key: FTPSessions.key(client.server), items: sel.map { FTPDragItem(path: path + [$0.name], isDir: $0.isDir, size: $0.size) })
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload.text ?? "", forType: FTPDragPayload.type)
        setStatus("Copied \(sel.count) item\(sel.count == 1 ? "" : "s") - Paste in a folder on this Mac to download")
    }

    @objc func copyToOtherPane(_ sender: Any?) {
        guard let dest = otherPaneFolder?(), let p = pane else { return }
        let items = selectedEntries.map { FTPDragItem(path: path + [$0.name], isDir: $0.isDir, size: $0.size) }
        p.downloadFTP(FTPDragPayload(key: FTPSessions.key(client.server), items: items), into: dest)
    }

    @objc func chooseUpload(_ sender: Any?) {
        guard let w = table.window else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Upload"
        p.message = "Upload to \((path.isEmpty ? [serverName] : path).joined(separator: "/")) (nothing on the server is overwritten)"
        p.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .OK, let s = self else { return }
            s.upload(p.urls.map { $0.path }, into: s.path)
        }
    }

    // MARK: Messages

    func message(_ title: String, _ text: String) {
        let a = ThemedAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// A numbered plain-text report (for AutoType), also offered on the clipboard.
    func report(_ title: String, _ lines: [String]) {
        FTPBrowser.report(title, lines, server: serverName)
    }

    static func report(_ title: String, _ lines: [String], server: String) {
        let numbered = lines.enumerated().map { String(format: "F%03d ", $0.offset + 1) + Ascii.clean($0.element) } + ["Total: \(lines.count) lines"]
        App.lastReport = "FIND FTP REPORT - \(Ascii.clean(server))\n" + numbered.joined(separator: "\n") + "\n"
        let a = ThemedAlert()
        a.messageText = title
        a.informativeText = numbered.prefix(20).joined(separator: "\n") + (numbered.count > 20 ? "\n\u{2026} (all of it in the log)" : "")
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Copy Report")
        if a.runModal() == .alertSecondButtonReturn { (NSApp.delegate as? AppDelegate)?.copyLastReport(nil) }
    }
}

/// The FTP list: Cmd-Down (or double-click) opens, Return renames in place, Delete deletes (with
/// confirmation), right-click menu.
final class FTPTableView: NSTableView {
    weak var browser: FTPBrowser?
    /// The single row that was selected when the mouse went down (click-twice rename), else -1.
    private(set) var selectedBeforeClick = -1

    override func mouseDown(with event: NSEvent) {
        selectedBeforeClick = selectedRowIndexes.count == 1 ? selectedRow : -1
        super.mouseDown(with: event)
    }

    /// Clicking into the FTP list makes its pane the active one (sidebar, title, Info panel follow).
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let p = browser?.pane { p.host?.focus(p) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: browser?.renameSelected(nil); return          // Return renames (as in Finder)
        case 125 where flags.contains(.command): browser?.openSelected(nil); return   // Cmd-Down opens
        case 31 where flags.contains(.command): browser?.openSelected(nil); return    // Cmd-O opens
        case 126 where flags.contains(.command): browser?.goUp(); return
        case 51, 117: browser?.deleteSelected(nil); return
        default: break
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return browser?.menu(forRow: row(at: p))
    }
}

// MARK: - The pane side

extension BrowserPane {
    var isFTP: Bool { return ftpBrowser != nil }

    /// Show an FTP server in this pane (its local folder and tabs stay, for Back at the top).
    func enterFTP(_ server: FTPServer, name: String, start: [String]) {
        endSearchUI(reload: false)
        if recursiveRoot != nil { stopRecursive(reload: false) }
        leaveFTP(reload: false)
        let b = FTPBrowser(server: server, name: name)
        b.pane = self
        b.otherPaneFolder = { [weak self] in
            guard let s = self, let h = s.host else { return nil }
            return h.panes.first(where: { $0 !== s && !$0.isFTP })?.currentPath
        }
        b.onChange = { [weak self] in self?.ftpChanged() }
        ftpBrowser = b
        list.scroll.isHidden = true
        gridScroll.isHidden = true
        photoOutline.isHidden = true
        photoBar.isHidden = true
        photoBarHeight.constant = 0
        viewButtons.isEnabled = false
        mainPane.addSubview(b.scroll, positioned: .below, relativeTo: paneOverlay)
        b.scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.scroll.topAnchor.constraint(equalTo: list.scroll.topAnchor),
            b.scroll.bottomAnchor.constraint(equalTo: list.scroll.bottomAnchor),
            b.scroll.leadingAnchor.constraint(equalTo: list.scroll.leadingAnchor),
            b.scroll.trailingAnchor.constraint(equalTo: list.scroll.trailingAnchor),
        ])
        window?.makeFirstResponder(b.table)
        mainPane.layoutSubtreeIfNeeded()
        b.fitColumns(nil)
        b.load(start)
        ftpChanged()
    }

    /// Back to this pane's local folder.
    func leaveFTP(reload: Bool) {
        guard let b = ftpBrowser else { return }
        b.stopRequested = true
        b.scroll.removeFromSuperview()
        ftpBrowser = nil
        viewButtons.isEnabled = true
        list.scroll.isHidden = false
        applyViewMode(focus: false)
        pathBar.setPath(currentPath)
        if reload { list.load(currentPath, selectPaths: [], showHidden: Prefs.showHidden) }
        updateStatus()
        updateTitle()
        App.log.info("FTP \(Ascii.clean(b.serverName)): pane closed, back to \(currentPath)")
    }

    func ftpChanged() {
        guard let b = ftpBrowser else { return }
        pathBar.setCrumbs(b.crumbs, editText: b.addressText)
        updateStatus()
        updateTitle()
    }

    /// Download FTP items into `dest` (a local folder): into Find's own temporary folder first, each
    /// file's size checked, then Find's usual checked copy into place (a name clash asks).
    /// 0.17: runs in the background with progress in the Copies window.
    func downloadFTP(_ payload: FTPDragPayload, into dest: String) {
        guard let c = FTPSessions.client(payload.key) else {
            showMessage("The FTP server isn't open any more", "Open it again, then drag again.")
            return
        }
        let server = FTPSessions.name(payload.key)
        let what = payload.items.count == 1 ? "\u{201C}\(payload.items[0].path.last ?? "")\u{201D}" : "\(payload.items.count) items"
        let t = CopyTask(title: "Downloading \(what) from \(server) to \u{201C}\(Paths.lastComponent(dest))\u{201D}")
        CopiesCenter.shared.add(t)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tmp = Paths.join(App.files.tempDir, "ftp-" + UUID().uuidString)
            _ = App.files.makeDir(tmp)
            var tops: [String] = [], failed: [String] = []
            // First list everything (folders are walked), so the totals are known.
            var work: [(remote: [String], local: String, size: Int64?)] = []
            var folderOK: [String: Bool] = [:]   // top folder (local) -> walked completely
            var topOf: [String: String] = [:]    // local file -> its top item
            var plainTops: [String] = []
            var failedLocals = Set<String>()
            for item in payload.items {
                if t.isCancelled() { break }
                guard let name = item.path.last else { continue }
                let localTop = Paths.join(tmp, name)
                if !item.isDir {
                    work.append((item.path, localTop, item.size))
                    topOf[localTop] = localTop
                    plainTops.append(localTop)
                    continue
                }
                _ = App.files.makeDir(localTop)
                t.progress.note("Listing \(item.path.joined(separator: "/"))/")
                switch c.walk(item.path, isCancelled: t.isCancelled) {
                case .failed(let f):
                    failed.append("\(name): \(f.code) \(f.text)")
                    t.progress.note("Could not list \(name): \(f.code) \(f.text)")
                case .ok(let inside):
                    folderOK[localTop] = true
                    for (p, e) in inside {
                        let local = Paths.join(localTop, p.dropFirst(item.path.count).joined(separator: "/"))
                        if e.isDir { _ = App.files.makeDir(local); continue }
                        work.append((p, local, e.size))
                        topOf[local] = localTop
                    }
                    plainTops.append(localTop)
                }
            }
            t.progress.plan(files: work.count, bytes: work.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
            for w in work {
                if t.isCancelled() { break }
                let name = w.remote.joined(separator: "/")
                CrashCapture.note("FTP download: /\(name) -> \(w.local)")
                t.progress.begin(w.local, name: name, size: w.size ?? 0)
                let size = w.size ?? 0
                if let err = c.download(w.remote, to: w.local, expected: w.size, progress: { frac in t.progress.current(done: Int64(Double(size) * frac)) }) {
                    failed.append("\(name): \(err.code) \(err.text)")
                    t.progress.finish(w.local, ok: false, detail: "\(err.code) \(err.text)")
                    failedLocals.insert(w.local)
                    if let top = topOf[w.local] { folderOK[top] = false }
                } else {
                    t.progress.finish(w.local, ok: true, detail: "size checked")
                }
            }
            CrashCapture.note("")
            let stopped = t.isCancelled()
            if !stopped {
                for top in plainTops {
                    if let ok = folderOK[top] {
                        // A folder is only copied into place if all of it arrived.
                        if ok { tops.append(top) } else { failed.append("\(Paths.lastComponent(top)): folder not copied (not all of it arrived)") }
                    } else if !failedLocals.contains(top) {
                        tops.append(top)   // a single file that arrived complete
                    }
                }
            }
            t.progress.note(stopped ? "Stopped: nothing is put in place" : "Putting \(tops.count) item(s) in place (checked copy)")
            let r = App.ops.copy(tops, into: dest, choose: { n in
                var ch = ConflictChoice.skip
                DispatchQueue.main.sync { ch = FTPBrowser.askClash(n, "\u{201C}\(Paths.lastComponent(dest))\u{201D}", nothingOverwritten: "here") }
                return ch
            })
            _ = App.files.removeOwned(tmp)
            DispatchQueue.main.async {
                let lines = ["Downloaded from \(server) into \(dest): \(r.done.count)", "Failed: \(failed.count + r.failed.count)", "Skipped: \(r.skipped.count)"]
                    + (stopped ? ["Stopped by you: nothing was put in place"] : [])
                    + failed.map { "FAILED " + $0 } + Array(r.summaryLines.dropFirst())
                for l in lines { App.log.info("FTP download report: \(Ascii.clean(l))") }
                let bad = !failed.isEmpty || !r.failed.isEmpty
                CopiesCenter.shared.finish(t, state: stopped ? "stopped" : (bad ? "failed" : "done"),
                                           line: "\(r.done.count) put in place" + (bad ? ", \(failed.count + r.failed.count) failed" : "") + (r.skipped.isEmpty ? "" : ", \(r.skipped.count) skipped"))
                NotificationCenter.default.post(name: .findFoldersChanged, object: self, userInfo: ["folders": [dest]])
                self?.updateStatus()
                if bad || !r.skipped.isEmpty || stopped { FTPBrowser.report("Download from \(server)", lines, server: server) }
            }
        }
    }
}


// MARK: - Menu commands in an FTP pane

extension BrowserPane {
    /// In an FTP pane only these menu commands work (the others would act on the local list hidden
    /// behind it). Move to Trash, Rename and Copy to Other Pane go to the FTP versions.
    static let ftpCommands: Set<String> = ["refresh:", "goBack:", "goForward:", "goUp:", "closePaneCommand:", "movePaneEarlier:",
                                           "movePaneLater:", "openNewPane:", "openNewPaneStacked:", "switchToOtherPane:",
                                           "moveWindowToQuarter:", "goApplications:", "goComputer:", "goDesktop:", "goDocuments:",
                                           "goDownloads:", "goHome:", "goPictures:", "goVolumes:", "goToFolder:",
                                           "trashSelected:", "deleteImmediatelySelected:", "renameSelected:", "copyToOtherPane:", "copy:", "paste:", "newFolder:"]

    func paneAllows(_ item: NSMenuItem) -> Bool {
        guard isFTP, let a = item.action else { return true }
        return BrowserPane.ftpCommands.contains(NSStringFromSelector(a))
    }
}


/// The FTP list's name field while it is edited in place: Escape cancels, the end of editing renames.
final class FTPNameFieldDelegate: NSResponder, NSTextFieldDelegate {
    var onEnd: ((Notification) -> Void)?
    var onEscape: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }

    // Informal NSObject method in the 10.13 SDK (needs `override`); a protocol method in later SDKs.
    #if swift(>=4.2)
    func controlTextDidEndEditing(_ obj: Notification) { onEnd?(obj) }
    #else
    override func controlTextDidEndEditing(_ obj: Notification) { onEnd?(obj) }
    #endif
}


/// File paths on the clipboard (copied in Finder or a local Find pane).
enum FileDragPasteCheck {
    static func localPaths() -> [String] {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return [] }
        return urls.map { $0.path }
    }
}


/// 0.17.2: a folder on a saved FTP server as a sidebar favourite. Kept in the favourites list as
/// "ftpfav:<saved server id>|<folder/path>" (the password stays in the Keychain with the server).
enum FTPFavorite {
    static let prefix = "ftpfav:"

    static func make(serverID: String, path: [String]) -> String {
        return prefix + serverID + "|" + path.joined(separator: "/")
    }

    static func parse(_ s: String) -> (server: SavedServer, path: [String])? {
        guard s.hasPrefix(prefix) else { return nil }
        let rest = String(s.dropFirst(prefix.count))
        guard let bar = rest.index(of: "|") else { return nil }
        let id = String(rest[..<bar])
        let p = String(rest[rest.index(after: bar)...]).components(separatedBy: "/").filter { !$0.isEmpty }
        guard let srv = Prefs.savedServers.first(where: { $0.id == id }) else { return nil }
        return (srv, p)
    }

    static func isFavorite(_ s: String) -> Bool { return s.hasPrefix(prefix) }

    /// Shown in the sidebar when no own name was given: the folder's name and the server's.
    static func title(_ s: String) -> String {
        guard let f = parse(s) else { return "FTP folder (server removed)" }
        return (f.path.last ?? f.server.name) + (f.path.isEmpty ? "" : " (\(f.server.name))")
    }

    static func tooltip(_ s: String) -> String {
        guard let f = parse(s) else { return "The saved FTP server of this favourite is no longer in the sidebar" }
        return "FTP \(f.server.name): /" + f.path.joined(separator: "/")
    }

    /// The saved server an open FTP connection belongs to (same address and account).
    static func savedServer(for c: FTPClient) -> SavedServer? {
        return Prefs.savedServers.first { s in
            guard let a = s.parsed, a.scheme == "ftp" else { return false }
            return a.host.lowercased() == c.server.host.lowercased() && (s.user == c.server.user || (s.user.isEmpty && c.server.user.isEmpty))
        }
    }
}
