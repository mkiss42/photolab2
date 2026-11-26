// NetworkWindow.swift
// Sidebar > Network (and Go > Connect to Server, Cmd-K): file servers announced on the local
// network (Bonjour: SMB, AFP), a field for an address, and the servers used before. Connecting
// uses macOS's own mounting (NetFS) with its usual sign-in dialog and keychain; when the share
// is mounted, it opens in PhotoLab. Nothing here touches a share on the main thread.

import AppKit
import NetFS

final class NetworkWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NetServiceBrowserDelegate {
    private static var shared: NetworkWindow?
    private let table = NSTableView()
    private let address = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private var browsers: [NetServiceBrowser] = []
    private var found: [(name: String, url: String)] = []
    private var rows: [(title: String, url: String, recent: Bool)] = []
    /// Where a mounted share opens: the window that asked (nil = a new window).
    private weak var target: BrowserWindowController?

    private static var recents: [String] {
        get { return UserDefaults.standard.stringArray(forKey: "recentServers") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: "recentServers") }
    }

    static func show(for window: BrowserWindowController?) {
        let w = shared ?? NetworkWindow()
        shared = w
        w.target = window
        w.startBrowsing()
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Network"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        col.title = "Servers on the network and recent servers"
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(connectSelected(_:))
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        address.placeholderString = "smb://server/share  (or server name)"
        address.target = self
        address.action = #selector(connectAddress(_:))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectAddress(_:)))
        connect.keyEquivalent = "\r"
        status.textColor = NSColor.secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 11)
        let field = NSStackView(views: [address, connect])
        field.orientation = .horizontal
        let stack = NSStackView(views: [scroll, field, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in [scroll, field] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        win.contentView = stack
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func startBrowsing() {
        browsers.forEach { $0.stop() }
        browsers = []
        found = []
        for type in ["_smb._tcp.", "_afpovertcp._tcp."] {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(b)
        }
        status.stringValue = "Looking for servers..."
        rebuild()
    }

    private func rebuild() {
        var r = found.map { (title: $0.name, url: $0.url, recent: false) }
        for u in NetworkWindow.recents where !r.contains(where: { $0.url == u }) { r.append((title: u, url: u, recent: true)) }
        rows = r
        table.reloadData()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let scheme = service.type.hasPrefix("_smb") ? "smb" : "afp"
        let host = service.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? service.name
        let url = "\(scheme)://\(host).local"
        if !found.contains(where: { $0.url == url }) { found.append((name: "\(service.name)  (\(scheme.uppercased()))", url: url)) }
        if !moreComing { status.stringValue = "\(found.count) server(s) found"; rebuild() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        found.removeAll { $0.name.hasPrefix(service.name + "  ") }
        if !moreComing { rebuild() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { return rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tf = NSTextField(labelWithString: rows[row].recent ? "Recent: " + rows[row].title : rows[row].title)
        tf.lineBreakMode = .byTruncatingMiddle
        return tf
    }

    @objc private func connectSelected(_ sender: Any?) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < rows.count else { return }
        connect(rows[r].url)
    }

    @objc private func connectAddress(_ sender: Any?) {
        var s = address.stringValue.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { connectSelected(nil); return }
        if !s.contains("://") { s = "smb://" + s }
        connect(s)
    }

    /// Mount with macOS's sign-in UI; on success open the share (first mount point) in PhotoLab.
    private func connect(_ s: String) {
        guard let url = URL(string: s) else { status.stringValue = "Not an address: \(s)"; return }
        status.stringValue = "Connecting to \(url.host ?? s)..."
        Log.info("network: connecting to a server")
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let r = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &request, DispatchQueue.main) { [weak self] st, _, points in
            guard let me = self else { return }
            let mounts = (points as? [String]) ?? []
            if st == 0, let mp = mounts.first {
                NetworkWindow.recents = [s] + NetworkWindow.recents.filter { $0 != s }
                me.status.stringValue = "Connected"
                Log.info("network: mounted")
                Volumes.refresh()
                NotificationCenter.default.post(name: .volumesChanged, object: nil)
                if let t = me.target, BrowserWindowController.open.contains(where: { $0 === t }) {
                    t.window?.makeKeyAndOrderFront(nil)
                    t.navigate(to: mp)
                } else {
                    BrowserWindowController.openWindow(at: mp)
                }
                me.close()
            } else if st == ECANCELED || st == -128 {          // -128 = userCanceledErr
                me.status.stringValue = "Cancelled"
            } else {
                me.status.stringValue = "Could not connect (error \(st))"
                Log.error("E-NET-1 mount failed: \(st)")
            }
        }
        if r != 0 { status.stringValue = "Could not start connecting (error \(r))" }
    }

    override func close() {
        browsers.forEach { $0.stop() }
        browsers = []
        super.close()
    }
}
