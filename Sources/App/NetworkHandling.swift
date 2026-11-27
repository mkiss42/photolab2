// NetworkHandling.swift
// Phase 6: a network share that disconnects while a pane shows it. The pane stays where it was and says
// so plainly (not "moved or deleted"), with a Reconnect button. Nothing on the share is touched.
// When the share comes back (Reconnect, Finder, or macOS on its own) the pane reloads by itself:
// this is driven by macOS mount notifications - Find never polls the server.

import AppKit

/// "Connecting to \\server\share..." shown over the list while macOS connects a share (it can take a
/// while, and a password dialog may appear). Stop Waiting hides it and ignores the result; the
/// connection itself is left to finish or fail by itself.
final class ConnectingPanel: NSView {
    let spinner = NSProgressIndicator()
    let label = NSTextField(wrappingLabelWithString: "")
    let stopButton = NSButton(title: "Stop Waiting", target: nil, action: nil)
    private let started = Date()
    private var timer: Timer?
    private var baseText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let tm = ThemeManager.shared
        layer?.backgroundColor = tm.sidebar.cgColor
        layer?.borderColor = tm.accent.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        label.textColor = tm.text
        label.font = tm.font
        label.alignment = .center
        stopButton.bezelStyle = .rounded
        for v in [spinner, label, stopButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 380),
            spinner.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stopButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
            stopButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            stopButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func start(_ text: String) {
        baseText = text
        label.stringValue = text
        spinner.startAnimation(nil)
        timer?.invalidate()
        // Seconds so far, so it never looks stuck.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            let secs = Int(Date().timeIntervalSince(s.started))
            s.label.stringValue = s.baseText + "\n\(secs) s" + (secs >= 15 ? " - a password window may be waiting behind this one" : "")
        }
        #if swift(>=4.2)
        RunLoop.main.add(t, forMode: .common)
        #else
        RunLoop.main.add(t, forMode: .commonModes)
        #endif
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        spinner.stopAnimation(nil)
        removeFromSuperview()
    }
}

extension BrowserPane {

    /// Show the disconnected state for `root` (a /Volumes/Name share) if this pane is on it.
    func markDisconnected(_ root: String, reason: String) {
        guard currentPath == root || Paths.isInside(currentPath, root: root) else { return }
        if !Prefs.netShowDisconnect {
            App.log.warn("Share disconnected (\(reason)): \(root); pane goes to the home folder (Settings > Network)")
            leaveVolume(root)
            return
        }
        if disconnectedRoot != root { App.log.warn("Share disconnected (\(reason)): \(root); showing \(currentPath) as unavailable") }
        disconnectedRoot = root
        if list.resultsMode {
            // Keep the search results on screen: a running search ends by itself as INTERRUPTED and says
            // what wasn't searched. Leaving the results shows the disconnected folder with Reconnect.
            return
        }
        list.showUnavailable()
        if viewMode != "list" { refreshGrid() }
        let name = Paths.lastComponent(root)
        overlay.stringValue = "The network share \u{201C}\(name)\u{201D} is not available.\n" +
            "The server stopped answering or the connection was closed (\(reason)). Nothing on it was changed."
        overlay.textColor = ThemeManager.shared.warning
        overlay.isHidden = false
        let canReconnect = VolumeRegistry.shared.remountURL(root) != nil || savedServer(forShare: root) != nil
        reconnectButton.title = canReconnect ? "Reconnect" : "Reconnect (address unknown)"
        reconnectButton.isEnabled = canReconnect
        reconnectButton.isHidden = false
        statusLabelText("Disconnected: \(root)")
    }

    func clearDisconnected() {
        disconnectedRoot = nil
        reconnectButton.isHidden = true
        reconnectButton.isEnabled = true
        reconnectButton.title = "Reconnect"
    }

    /// macOS says a volume was unmounted.
    func shareUnmounted(_ root: String, wasNetwork: Bool) {
        guard wasNetwork else { return }
        markDisconnected(root, reason: "the share was unmounted")
    }

    /// macOS says a volume was mounted: if it is the one this pane lost, show it again.
    func shareMounted(_ root: String) {
        guard let lost = disconnectedRoot else { return }
        if root == lost {
            clearDisconnected()
            overlay.isHidden = true
            App.log.info("Share is back: \(root); reloading \(currentPath)")
            refresh(nil)
        }
    }

    /// The saved server whose share is mounted (or would be) at this /Volumes path.
    func savedServer(forShare root: String) -> SavedServer? {
        let name = Paths.lastComponent(root).lowercased()
        return Prefs.savedServers.first(where: { $0.parsed?.share?.lowercased() == name })
    }

    @objc func reconnectShare(_ sender: Any?) {
        guard let root = disconnectedRoot else { return }
        if VolumeRegistry.shared.remountURL(root) == nil, let s = savedServer(forShare: root) {
            // Known from the sidebar's saved servers: connect with its account and password.
            let rest = String(currentPath.dropFirst(root.count)).split(separator: "/").map(String.init)
            var withPath = s
            if var a = s.parsed { a.subpath = rest; withPath.address = a.display }
            clearDisconnected()
            openSavedServer(withPath)
            return
        }
        guard let url = VolumeRegistry.shared.remountURL(root) else {
            showMessage("Find doesn't know this share's address", "Connect with Finder (Go > Connect to Server). This pane reloads by itself when the share is back.", style: .informational)
            return
        }
        reconnectButton.isEnabled = false
        reconnectButton.title = "Reconnecting"
        App.log.info("Reconnect requested: \(root) (\(Ascii.clean(url)))")
        let ticket = beginConnecting("\u{201C}\(Paths.lastComponent(root))\u{201D}")
        Volumes.remount(url) { [weak self] error in
            guard let s = self else { return }
            guard s.finishConnecting(ticket) else {
                s.reconnectButton.isEnabled = true
                s.reconnectButton.title = "Reconnect"
                return
            }
            if let e = error {
                App.log.warn("Reconnect failed: \(root): \(e)")
                s.reconnectButton.isEnabled = true
                s.reconnectButton.title = "Reconnect"
                s.showMessage("Could not reconnect \u{201C}\(Paths.lastComponent(root))\u{201D}", e)
                return
            }
            App.log.info("Reconnected: \(root)")
            Volumes.refresh {
                NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
                // macOS may mount it under another name ("Share-1") if the old name was taken.
                let newRoot = VolumeRegistry.shared.volumes.first(where: { $0.remountURL == url })?.path ?? root
                guard s.disconnectedRoot == root else { return }
                s.clearDisconnected()
                s.overlay.isHidden = true
                if newRoot != root, s.currentPath.hasPrefix(root) {
                    s.navigate(to: newRoot + String(s.currentPath.dropFirst(root.count)))
                } else {
                    s.refresh(nil)
                }
            }
        }
    }

    // MARK: Connecting indicator

    /// Show the connecting panel; returns a ticket. `finishConnecting(ticket)` returns false when the user
    /// pressed Stop Waiting (or another connection replaced this one): the result is then ignored.
    func beginConnecting(_ what: String) -> Int {
        connectTicket += 1
        let ticket = connectTicket
        connectingPanel?.stop()
        let p = ConnectingPanel(frame: .zero)
        p.translatesAutoresizingMaskIntoConstraints = false
        mainPane.addSubview(p)
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: list.scroll.centerXAnchor),
            p.centerYAnchor.constraint(equalTo: list.scroll.centerYAnchor),
        ])
        p.stopButton.target = self
        p.stopButton.action = #selector(stopWaitingForConnection(_:))
        p.start("Connecting to \(what)\u{2026}")
        connectingPanel = p
        statusLabelText("Connecting to \(what)\u{2026}")
        return ticket
    }

    func finishConnecting(_ ticket: Int) -> Bool {
        guard ticket == connectTicket else { return false }
        connectingPanel?.stop()
        connectingPanel = nil
        updateStatus()
        return true
    }

    @objc func stopWaitingForConnection(_ sender: Any?) {
        connectTicket += 1
        connectingPanel?.stop()
        connectingPanel = nil
        updateStatus()
        App.log.info("Stopped waiting for a connection (it may still finish in the background)")
    }

    // MARK: Network addresses typed in the path field

    /// Go to a typed network address: straight there if that share is mounted, otherwise connect first
    /// (macOS asks for a password if the server needs one, and which share if none was given).
    /// A saved server from the sidebar: open it if connected, otherwise connect with its saved account
    /// and Keychain password (read in the background; macOS may ask once whether Find may use it).
    /// 0.17.7: a folder on an FTP server in a new window (Cmd-click).
    func openFTPInNewWindow(_ server: FTPServer, name: String, start: [String]) {
        guard let c = (NSApp.delegate as? AppDelegate)?.newWindow(path: currentPath) else { return }
        c.pane.enterFTP(server, name: name, start: start)
    }

    func openFTPFavoriteInNewWindow(_ fav: String) {
        guard let c = (NSApp.delegate as? AppDelegate)?.newWindow(path: currentPath) else { return }
        c.pane.openFTPFavorite(fav)
    }

    /// A sidebar favourite that is a folder on a saved FTP server (0.17.2).
    func openFTPFavorite(_ fav: String) {
        guard let f = FTPFavorite.parse(fav) else {
            showMessage("This favourite's server is gone", "Its FTP server was removed from the sidebar. Remove the favourite (right-click > Remove from Sidebar), add the server again and the folder again.", style: .informational)
            return
        }
        openSavedServer(f.server, start: f.path)
    }

    func openSavedServer(_ s: SavedServer, start: [String]? = nil) {
        guard let a = s.parsed else {
            showMessage("\u{201C}\(s.name)\u{201D} has an address Find can't read", "Edit it in the sidebar (right-click > Edit).")
            return
        }
        if a.scheme == "ftp" {
            // 0.15: FTP opens in Find's own FTP window (upload and delete), never as a read-only mount.
            var addr = a
            if !s.user.isEmpty { addr.user = s.user }
            if let st = start { addr.subpath = st }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let pw = s.user.isEmpty ? nil : ServerKeychain.password(host: a.host, user: s.user, scheme: "ftp")
                DispatchQueue.main.async { self?.openFTP(addr, password: pw, serverID: s.id, name: s.name) }
            }
            return
        }
        if let m = ServerList.mountedPath(s, volumes: VolumeRegistry.shared.volumes) {
            openInsideShare(m.root, a)
            return
        }
        var addr = a
        if !s.user.isEmpty { addr.user = s.user }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pw = ServerKeychain.password(host: a.host, user: s.user, scheme: a.scheme)
            DispatchQueue.main.async { self?.openNetworkAddress(addr, password: pw, serverID: s.id) }
        }
    }

    func openNetworkAddress(_ a: NetworkAddress, password: String? = nil, serverID: String? = nil) {
        App.log.info("Path field: network address \(Ascii.clean(a.display)) (\(Ascii.clean(a.mountURL)))")
        window?.makeFirstResponder(focusView)
        if a.scheme == "ftp" {
            openFTP(a, password: password, serverID: serverID)
            return
        }
        if a.share != nil, let v = mountedShare(for: a) {
            openInsideShare(v, a)
            return
        }
        let before = Set(VolumeRegistry.shared.volumes.map { $0.path })
        let ticket = beginConnecting(a.display)
        Volumes.mountShare(a.mountURL, user: a.user, password: password) { [weak self] error, mountedAt in
            if let id = serverID {
                if let e = error { ServerStatus.lastError[id] = e } else { ServerStatus.lastError[id] = nil }
            }
            guard let s = self else { return }
            guard s.finishConnecting(ticket) else {
                App.log.info("Connection to \(Ascii.clean(a.display)) finished after Stop Waiting: \(error ?? "connected")")
                if error == nil { Volumes.refresh { NotificationCenter.default.post(name: .findVolumesChanged, object: nil) } }
                return
            }
            if let e = error {
                App.log.warn("Could not connect to \(Ascii.clean(a.display)): \(e)")
                s.showMessage("Could not connect to \(a.display)", e)
                return
            }
            Volumes.refresh {
                NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
                let shares = VolumeRegistry.shared.volumes.filter { !$0.isLocal }
                // Where macOS says it mounted it; else the share asked for; or (a server only) the
                // share that just appeared from that server.
                var target: String? = nil
                if let m = mountedAt, m.hasPrefix("/Volumes/") { target = m }
                if target == nil { target = s.mountedShare(for: a) }
                if target == nil {
                    let fresh = shares.filter { !before.contains($0.path) }
                    target = fresh.first(where: { v in
                        guard let u = v.remountURL, let o = NetworkAddress.parse(u) else { return false }
                        return o.host.lowercased() == a.host.lowercased()
                    })?.path ?? fresh.first?.path
                }
                guard let t = target else {
                    s.updateStatus()
                    App.log.warn("Connected to \(Ascii.clean(a.display)) but its folder was not recognised (code NET-ID-1). macOS gave: \(mountedAt.map { Ascii.clean($0) } ?? "nothing")")
                    for l in NetworkReport.lines(VolumeRegistry.shared.volumes, saved: Prefs.savedServers, typed: a) { App.log.warn(l) }
                    s.showMessage("Connected to \(a.display)",
                                  "Find could not tell which folder it is (code NET-ID-1). Open it from Servers or Network in the sidebar. Help > Network Report lists what macOS reports, to send me.",
                                  style: .informational)
                    return
                }
                App.log.info("Connected: \(Ascii.clean(a.display)) is \(t)")
                s.openInsideShare(t, a)
            }
        }
    }

    /// The mounted volume (its /Volumes path) for this address's share, from the cached list.
    func mountedShare(for a: NetworkAddress) -> String? {
        guard let share = a.share else { return nil }
        return ShareMatch.find(host: a.host, share: share, scheme: a.scheme, in: VolumeRegistry.shared.volumes)
    }

    /// Open the folders typed after the share (checked in the background - it's a server).
    func openInsideShare(_ root: String, _ a: NetworkAddress) {
        if a.subpath.isEmpty {
            navigate(to: root)
            return
        }
        let target = a.subpath.reduce(root) { Paths.join($0, $1) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var e: Int32 = 0
            let info = Sys.statInfo(target, &e)
            DispatchQueue.main.async {
                guard let s = self else { return }
                if let i = info, i.isDirectory {
                    s.navigate(to: target)
                } else if info != nil {
                    s.navigate(to: Paths.parent(target), select: [Paths.lastComponent(target)])
                } else {
                    s.navigate(to: root)
                    s.showMessage("\u{201C}\(a.subpath.joined(separator: "/"))\u{201D} isn't in \(Paths.lastComponent(root))",
                                  "The share is connected and open; that folder wasn't found in it (\(Sys.errorText(e))).", style: .informational)
                }
            }
        }
    }
}


// MARK: - FTP (0.15)

extension BrowserPane {
    /// Show an FTP server in this pane. An account without a saved password: asked here (not saved).
    func openFTP(_ a: NetworkAddress, password: String?, serverID: String?, name: String? = nil) {
        let user = a.user ?? ""
        var pw = password
        if !user.isEmpty && (pw ?? "").isEmpty {
            let alert = ThemedAlert()
            alert.messageText = "Password for \(user) on \(a.host)"
            alert.informativeText = "To keep it, add the server to the sidebar (Add Server...) with its password: it is then kept in the Keychain."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            pw = field.stringValue
        }
        let server = FTPServer(host: a.host, user: user, password: pw)
        enterFTP(server, name: name ?? a.host, start: a.subpath)
    }
}
