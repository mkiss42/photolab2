// MaintenanceSettings.swift
// Settings tabs for Phase 5 and 6:
// - Storage & Maintenance: every file Find keeps for itself (size, purpose, place, how long, clean-up),
//   the clean-up policy, Clean Up Now, Clear All Disposable Caches, Delete and Rebuild Indexes.
// - Network: listing memory, folder sizes and search readers on shares, what happens on a disconnect.
// - Advanced: debug logging, resource monitor, diagnostics (plain numbered text for AutoType).
// Clean-up only ever touches Find's own folders (see Maintenance.swift); none of these controls can
// remove a user file.

import AppKit

/// Plain numbered text for AutoType: "<prefix>0001 ..." lines and a closing total.
func numberedReport(_ lines: [String], prefix: String) -> String {
    var out: [String] = []
    for (i, l) in lines.enumerated() { out.append(prefix + String(format: "%04d ", i + 1) + Ascii.clean(l)) }
    out.append(prefix + String(format: "%04d END total-lines=%d", lines.count + 1, lines.count + 1))
    return out.joined(separator: "\n")
}

private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func hstack(_ views: [NSView]) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.spacing = 8
    s.alignment = .centerY
    return s
}

private func vstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    return s
}

private func secondary(_ text: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.textColor = NSColor.secondaryLabelColor
    return l
}

/// A popup whose items carry integer values.
private final class ValuePopup: NSPopUpButton {
    private var values: [Int] = []
    convenience init(_ items: [(String, Int)]) {
        self.init(frame: .zero, pullsDown: false)
        for (t, v) in items {
            addItem(withTitle: t)
            values.append(v)
        }
    }
    var value: Int {
        get { return indexOfSelectedItem >= 0 && indexOfSelectedItem < values.count ? values[indexOfSelectedItem] : 0 }
        set {
            if let i = values.index(of: newValue) {
                selectItem(at: i)
            } else if let i = values.index(where: { $0 >= newValue }) {
                selectItem(at: i)
            } else {
                selectItem(at: values.count - 1)
            }
        }
    }
}

private func pinTop(_ stack: NSView, in v: NSView, width: CGFloat) {
    v.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
        stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 22),
        stack.widthAnchor.constraint(equalToConstant: width),
    ])
}

// MARK: - Storage & Maintenance

final class StorageSettingsController: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 560))
    /// Asked to rebuild every index after they were deleted (the Search Index tab shows progress).
    var onRebuildIndexes: (() -> Void)?

    private let totalsLabel = NSTextField(wrappingLabelWithString: "Measuring\u{2026}")
    private let lastLabel = NSTextField(wrappingLabelWithString: "")
    private let busyLabel = NSTextField(labelWithString: "")
    private let detail = NSTextView(frame: NSRect(x: 0, y: 0, width: 690, height: 150))
    private let autoCheck = NSButton(checkboxWithTitle: "Clean up automatically", target: nil, action: nil)
    private let startCheck = NSButton(checkboxWithTitle: "When PhotoLab starts", target: nil, action: nil)
    private let quitCheck = NSButton(checkboxWithTitle: "When PhotoLab quits", target: nil, action: nil)
    private let everyPopup = ValuePopup([("Not on a schedule", 0), ("Every 6 hours", 6), ("Every 12 hours", 12), ("Every day", 24), ("Every week", 168)])
    private let tempPopup = ValuePopup([("1 hour", 1), ("6 hours", 6), ("1 day", 24), ("1 week", 168)])
    private let logPopup = ValuePopup([("7 days", 7), ("30 days", 30), ("90 days", 90), ("1 year", 365)])
    private let previewPopup = ValuePopup([("250 MB", 250), ("500 MB", 500), ("1 GB", 1024), ("2 GB", 2048), ("5 GB", 5120)])
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var lastReport: [String] = []

    override init() {
        super.init()
        let intro = secondary("PhotoLab keeps the files below for itself, in its own folders. Clean-up only ever removes these: never your files, RAW files, XMP sidecars, other apps' files, system files, settings, themes, saved searches or the list of indexed folders. It never runs while PhotoLab is copying, moving, renaming, searching or building an index.")
        detail.isEditable = false
        detail.isSelectable = true
        detail.font = NSFont.userFixedPitchFont(ofSize: 11)
        detail.textContainerInset = NSSize(width: 4, height: 4)
        let detailScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 690, height: 150))
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detail.autoresizingMask = [.width]
        busyLabel.textColor = NSColor.secondaryLabelColor
        for (b, sel) in [(autoCheck, #selector(policyChanged(_:))), (startCheck, #selector(policyChanged(_:))), (quitCheck, #selector(policyChanged(_:)))] {
            b.target = self
            b.action = sel
        }
        for p in [everyPopup, tempPopup, logPopup, previewPopup] {
            p.target = self
            p.action = #selector(policyChanged(_:))
        }
        let cleanNow = NSButton(title: "Clean Up Now", target: self, action: #selector(cleanNow(_:)))
        let clearAll = NSButton(title: "Clear All Disposable Caches", target: self, action: #selector(clearDisposable(_:)))
        let rebuild = NSButton(title: "Delete and Rebuild Indexes", target: self, action: #selector(rebuildIndexes(_:)))
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport(_:)))
        buttons = [cleanNow, clearAll, rebuild]
        for b in buttons + [copy] { b.bezelStyle = .rounded }
        clearAll.toolTip = "Saved previews, temporary files, test folders and memory caches. Settings, themes, indexes and logs are kept."
        rebuild.toolTip = "Deletes the index files (not the list of indexed folders) and builds them again."
        let stack = vstack([
            intro,
            totalsLabel,
            lastLabel,
            busyLabel,
            detailScroll,
            hstack([autoCheck, startCheck, quitCheck, everyPopup]),
            hstack([NSTextField(labelWithString: "Remove PhotoLab's temporary files after"), tempPopup,
                    NSTextField(labelWithString: "Keep logs for"), logPopup]),
            hstack([NSTextField(labelWithString: "Saved previews of Photoshop and large TIFF files: up to"), previewPopup]),
            hstack([cleanNow, clearAll, rebuild, copy]),
            resultLabel,
        ], spacing: 10)
        pinTop(stack, in: view, width: 696)
        detailScroll.widthAnchor.constraint(equalToConstant: 696).isActive = true
        detailScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        for l in [intro, totalsLabel, lastLabel, resultLabel] { l.widthAnchor.constraint(equalToConstant: 696).isActive = true }
    }

    func refresh() {
        let p = Prefs.maintenancePolicy
        autoCheck.state = p.automatic ? .on : .off
        startCheck.state = p.atStartup ? .on : .off
        quitCheck.state = p.atQuit ? .on : .off
        everyPopup.value = p.everyHours
        tempPopup.value = p.tempMaxAgeHours
        logPopup.value = p.logKeepDays
        previewPopup.value = p.previewLimitMB
        for c in [startCheck, quitCheck] { c.isEnabled = p.automatic }
        everyPopup.isEnabled = p.automatic
        busyLabel.stringValue = "PhotoLab is busy now with: \(Activity.shared.describe)"
        let st = App.maintenance.state
        lastLabel.stringValue = "Last clean-up: " + (st.lastRun > 0 ? "\(Ascii.timestamp(Date(timeIntervalSince1970: st.lastRun))) (\(st.lastTrigger)). \(st.lastSummary)" : "never")
            + "\nPolicy: " + p.describe
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let inv = App.maintenance.inventory()
            let report = App.maintenance.reportLines(inv, policy: p)
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.lastReport = report
                func size(_ id: String) -> String {
                    let b = inv.filter { $0.id == id }.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
                    return Listing.sizeText(b)
                }
                s.totalsLabel.stringValue = "On disk in total: \(Listing.sizeText(App.maintenance.totalBytes(inv)))   \u{00B7}   " +
                    "saved previews \(size("previews"))   \u{00B7}   search indexes \(size("indexes"))   \u{00B7}   " +
                    "temporary files \(size("temp"))   \u{00B7}   test folders \(size("scratch"))   \u{00B7}   logs \(size("logs"))"
                s.detail.string = report.joined(separator: "\n")
            }
        }
    }

    @objc private func policyChanged(_ sender: Any?) {
        let d = Prefs.d
        d.set(autoCheck.state == .on, forKey: Prefs.Key.maintAuto)
        d.set(startCheck.state == .on, forKey: Prefs.Key.maintStartup)
        d.set(quitCheck.state == .on, forKey: Prefs.Key.maintQuit)
        d.set(everyPopup.value, forKey: Prefs.Key.maintEveryHours)
        d.set(tempPopup.value, forKey: Prefs.Key.maintTempHours)
        d.set(logPopup.value, forKey: Prefs.Key.maintLogDays)
        d.set(previewPopup.value, forKey: Prefs.Key.previewLimitMB)
        App.previews.setLimit(Int64(previewPopup.value) * 1_048_576)
        App.log.info("Clean-up policy changed: \(Prefs.maintenancePolicy.describe)")
        refresh()
    }

    private func run(_ title: String, _ work: @escaping () -> MaintenanceResult, then: (() -> Void)? = nil) {
        for b in buttons { b.isEnabled = false }
        resultLabel.stringValue = title + "\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = work()
            DispatchQueue.main.async {
                guard let s = self else { return }
                for b in s.buttons { b.isEnabled = true }
                s.resultLabel.stringValue = r.summary
                s.refresh()
                if r.ran { then?() }
            }
        }
    }

    @objc private func cleanNow(_ sender: Any?) {
        run("Cleaning up", { App.maintenance.cleanUp(Prefs.maintenancePolicy, trigger: "Clean Up Now") })
    }

    @objc private func clearDisposable(_ sender: Any?) {
        let a = ThemedAlert()
        a.messageText = "Clear all disposable caches?"
        a.informativeText = "Removes PhotoLab's saved previews, temporary files and test folders, and empties its memory caches. They are made again when needed (the first look at a large Photoshop file is slower again).\n\nKept: settings, themes, window places, search indexes, logs. Your own files are never touched."
        a.addButton(withTitle: "Clear Caches")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        run("Clearing caches", { App.maintenance.clearDisposable() })
    }

    @objc private func rebuildIndexes(_ sender: Any?) {
        if App.indexes.roots.isEmpty {
            resultLabel.stringValue = "No folders are indexed (Settings > Search Index)."
            return
        }
        let a = ThemedAlert()
        a.messageText = "Delete and rebuild all search indexes?"
        a.informativeText = "The index files are deleted and built again from the folders on disk; the list of indexed folders is kept. Until a folder's index is rebuilt, searches there read the folders directly (slower). Your folders are not touched."
        a.addButton(withTitle: "Delete and Rebuild")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        run("Deleting index files", { App.maintenance.deleteIndexes() }, then: { [weak self] in self?.onRebuildIndexes?() })
    }

    @objc private func copyReport(_ sender: Any?) {
        copyToClipboard(numberedReport(lastReport, prefix: "S"))
        resultLabel.stringValue = "Report copied (\(lastReport.count + 1) numbered lines, plain text)."
    }
}

// MARK: - Network

final class NetworkSettingsController: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 560))
    private let listingPopup = ValuePopup([("Off", 0), ("2 minutes", 120), ("10 minutes", 600), ("30 minutes", 1800), ("1 hour", 3600), ("1 day", 86400), ("1 week", 604800)])
    private let sizesCheck = NSButton(checkboxWithTitle: "Calculate folder sizes on network shares too (one request per item inside every folder)", target: nil, action: nil)
    private let readersPopup = ValuePopup([("1 folder", 1), ("2 folders", 2), ("4 folders", 4), ("8 folders", 8)])
    private let stayCheck = NSButton(checkboxWithTitle: "When a share disconnects, keep the window where it was, with a Reconnect button", target: nil, action: nil)
    private let sharesLabel = NSTextField(wrappingLabelWithString: "")
    /// Saved servers (0.13): one row each, rebuilt by refresh().
    private let serverRows = NSStackView()
    private var serverObserver: NSObjectProtocol?

    override init() {
        super.init()
        serverRows.orientation = .vertical
        serverRows.alignment = .leading
        serverRows.spacing = 4
        let addButton = NSButton(title: "Add Server", target: self, action: #selector(addServer(_:)))
        let addNote = secondary("Tick \u{201C}Connect when PhotoLab starts\u{201D} for the ones to connect at start. Shares already connected (by PhotoLab, Finder or anything else) are left as they are.")
        addNote.widthAnchor.constraint(equalToConstant: 560).isActive = true
        let serversBox = vstack([
            NSTextField(labelWithString: "Saved servers (shown in the sidebar, connected or not):"),
            serverRows,
            hstack([addButton, addNote]),
            hstack([NSButton(title: "Repair Keychain Access", target: self, action: #selector(repairKeychain(_:))),
                    secondary("Stops macOS asking \u{201C}NetAuthSysAgent wants to use your confidential information\u{201D} for passwords PhotoLab saved (once is enough).")]),
        ], spacing: 6)
        serverObserver = NotificationCenter.default.addObserver(forName: .findVolumesChanged, object: nil, queue: .main) { [weak self] _ in
            // Later, not inside the click that changed the list (its button is about to be replaced).
            DispatchQueue.main.async { self?.refreshServers() }
        }
        let intro = secondary("PhotoLab never waits for a server on the window's own thread, so a share that stops answering cannot freeze PhotoLab. It does not poll servers: it reacts when macOS reports a share mounted or gone, and when you open a folder.")
        listingPopup.target = self
        listingPopup.action = #selector(changed(_:))
        readersPopup.target = self
        readersPopup.action = #selector(changed(_:))
        sizesCheck.target = self
        sizesCheck.action = #selector(changed(_:))
        stayCheck.target = self
        stayCheck.action = #selector(changed(_:))
        let states = secondary("A search on a share ends as COMPLETE, STOPPED, INTERRUPTED - CONNECTION LOST, UNAVAILABLE, INCOMPLETE - PERMISSION or INCOMPLETE (shown in the status line and the search report).")
        let stack = vstack([
            serversBox,
            intro,
            hstack([NSTextField(labelWithString: "Remember folders on shares for"), listingPopup]),
            secondary("Every folder on a share you go into is remembered (also after quitting PhotoLab). Going back to it doesn't wait for the server: the remembered list shows at once, the folder is read again in the background (spinner bottom right) and the list updates by itself if anything changed. Refresh (Cmd-R) always waits for the server."),
            sizesCheck,
            hstack([NSTextField(labelWithString: "Searching a share without an index: read"), readersPopup, NSTextField(labelWithString: "at a time")]),
            secondary("Fewer is gentler on the server and the network; more is faster on a fast server."),
            stayCheck,
            secondary("Off: the window goes to your home folder instead. Either way nothing on the share is changed, and a share that comes back is shown again by itself."),
            states,
            sharesLabel,
        ], spacing: 10)
        pinTop(stack, in: view, width: 696)
        for v in stack.arrangedSubviews where v is NSTextField && (v as! NSTextField).maximumNumberOfLines != 1 {
            v.widthAnchor.constraint(equalToConstant: 696).isActive = true
        }
    }

    private func refreshServers() {
        for v in serverRows.arrangedSubviews { serverRows.removeArrangedSubview(v); v.removeFromSuperview() }
        let list = Prefs.savedServers
        if list.isEmpty {
            serverRows.addArrangedSubview(secondary("None yet. Add one here, or right-click a connected share in the sidebar and choose Save as Server."))
            ThemeStyler.style(serverRows)
            return
        }
        let vols = VolumeRegistry.shared.volumes
        for (i, s) in list.enumerated() {
            let check = NSButton(checkboxWithTitle: "Connect when PhotoLab starts", target: self, action: #selector(autoChanged(_:)))
            check.state = s.autoConnect ? .on : .off
            check.tag = i
            let connected = ServerList.mountedPath(s, volumes: vols) != nil
            let who = s.user.isEmpty ? "guest / asks" : Ascii.clean(s.user)
            let label = NSTextField(labelWithString: "\(s.name)  -  \(Ascii.clean(s.address))  -  \(who)  -  \(connected ? "connected" : "not connected")")
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
            let edit = NSButton(title: "Edit", target: self, action: #selector(editServer(_:)))
            edit.tag = i
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeServer(_:)))
            remove.tag = i
            serverRows.addArrangedSubview(hstack([check, label, edit, remove]))
        }
        ThemeStyler.style(serverRows)
    }

    /// The saved server a row's button belongs to (rows are rebuilt whenever the list changes).
    private func server(_ sender: NSButton) -> SavedServer? {
        let list = Prefs.savedServers
        return sender.tag >= 0 && sender.tag < list.count ? list[sender.tag] : nil
    }

    @objc private func addServer(_ sender: Any?) { ServerActions.add(prefill: nil) }

    @objc private func repairKeychain(_ sender: Any?) {
        let list = Prefs.savedServers
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, missing, bad) = ServerKeychain.repair(list)
            DispatchQueue.main.async {
                App.log.info("Keychain access repaired: \(ok); no saved password: \(missing); failed: \(bad)")
                let a = ThemedAlert()
                a.alertStyle = bad == 0 ? .informational : .warning
                a.messageText = "Keychain access: \(ok) server\(ok == 1 ? "" : "s") repaired"
                a.informativeText = "No saved password: \(missing). Failed: \(bad).\n\nmacOS may ask once more for each (choose Always Allow); after that, connecting doesn't ask."
                a.addButton(withTitle: "OK")
                a.runModal()
            }
        }
    }
    @objc private func editServer(_ sender: NSButton) { if let s = server(sender) { ServerActions.edit(s) } }
    @objc private func removeServer(_ sender: NSButton) { if let s = server(sender) { ServerActions.remove(s) } }
    @objc private func autoChanged(_ sender: NSButton) {
        if let s = server(sender) { ServerActions.setAutoConnect(s.id, sender.state == .on) }
    }

    func refresh() {
        refreshServers()
        listingPopup.value = Prefs.netListingSeconds
        sizesCheck.state = Prefs.netFolderSizes ? .on : .off
        readersPopup.value = Prefs.netSearchReaders
        stayCheck.state = Prefs.netShowDisconnect ? .on : .off
        let shares = VolumeRegistry.shared.volumes.filter { !$0.isLocal }
        if shares.isEmpty {
            sharesLabel.stringValue = "No network shares are mounted now."
        } else {
            sharesLabel.stringValue = "Mounted shares:\n" + shares.map { "\($0.path)  (\($0.remountURL.map { Ascii.clean($0) } ?? "address not known"))" }.joined(separator: "\n")
        }
    }

    @objc private func changed(_ sender: Any?) {
        Prefs.netListingSeconds = listingPopup.value
        ListingCache.lifetime = Double(listingPopup.value)
        if listingPopup.value == 0 { ListingCache.shared.removeAll() }
        Prefs.netFolderSizes = sizesCheck.state == .on
        Prefs.netSearchReaders = readersPopup.value
        Prefs.netShowDisconnect = stayCheck.state == .on
        App.log.info("Network settings: listings kept \(Prefs.netListingSeconds) s, folder sizes on shares \(Prefs.netFolderSizes), search readers \(Prefs.netSearchReaders), stay on disconnect \(Prefs.netShowDisconnect)")
    }
}

// MARK: - Advanced

final class AdvancedSettingsController: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 560))
    private let debugCheck = NSButton(checkboxWithTitle: "Debug logging (more detail in the log: listings reused, clean-up steps)", target: nil, action: nil)
    private let monitor = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    /// Filled in by the app: windows and panes open now.
    var openViews: () -> String = { return "" }

    override init() {
        super.init()
        debugCheck.target = self
        debugCheck.action = #selector(debugChanged(_:))
        monitor.font = NSFont.userFixedPitchFont(ofSize: 11)
        let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics(_:)))
        let logs = NSButton(title: "Show Logs Folder", target: self, action: #selector(showLogs(_:)))
        copy.bezelStyle = .rounded
        logs.bezelStyle = .rounded
        let stack = vstack([
            debugCheck,
            NSTextField(labelWithString: "Resource monitor (updates every 2 seconds while this tab is shown):"),
            monitor,
            hstack([copy, logs]),
            resultLabel,
            secondary("When PhotoLab is idle it uses no processor time: no polling, no timers except a 10-minute check whether the scheduled clean-up is due. Folder watching uses macOS file events and stops when a folder is left; everything stops when PhotoLab quits."),
        ], spacing: 12)
        pinTop(stack, in: view, width: 696)
        for v in [monitor, resultLabel] { v.widthAnchor.constraint(equalToConstant: 696).isActive = true }
    }

    func refresh() {
        debugCheck.state = Prefs.debugLogging ? .on : .off
        update()
    }

    /// Start or stop the monitor's 2-second updates (only while the Advanced tab is visible).
    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        update()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.update() }
        #if swift(>=4.2)
        RunLoop.main.add(t, forMode: .common)
        #else
        RunLoop.main.add(t, forMode: .commonModes)
        #endif
        timer = t
    }

    private func lines() -> [String] {
        var l: [String] = []
        l.append("PhotoLab \(App.version), \(App.systemInfo)")
        l.append("Memory in use by Find: \(Listing.sizeText(Int64(ProcessStats.residentBytes())))")
        l.append(String(format: "Processor time used since start: %.1f s", ProcessStats.cpuSeconds()))
        l.append("Busy now: \(Activity.shared.describe)")
        l.append(openViews())
        l.append("Operation notes pending (interrupted-operation recovery): \(App.journal.pendingCount)")
        l.append("Thumbnails remembered: \(ThumbnailGrid.memoryCount); icons: \(IconCache.shared.count); photo details: \(PhotoFactsStore.shared.memoryCount)")
        l.append("Network listings remembered: \(ListingCache.shared.count) of \(ListingCache.capacity), kept \(Int(ListingCache.lifetime)) s")
        let shares = VolumeRegistry.shared.volumes.filter { !$0.isLocal }.map { $0.path }
        l.append("Network shares mounted: \(shares.isEmpty ? "none" : shares.joined(separator: ", "))")
        l.append("Debug logging: \(Prefs.debugLogging ? "on" : "off"); log: \(App.log.path)")
        return l
    }

    private func update() {
        monitor.stringValue = lines().joined(separator: "\n")
    }

    @objc private func debugChanged(_ sender: NSButton) {
        Prefs.debugLogging = sender.state == .on
        Log.debugEnabled = Prefs.debugLogging
        App.log.info("Debug logging \(Prefs.debugLogging ? "on" : "off")")
    }

    @objc private func copyDiagnostics(_ sender: Any?) {
        var l = lines()
        let p = Prefs.maintenancePolicy
        l += App.maintenance.reportLines(App.maintenance.inventory(), policy: p)
        for v in VolumeRegistry.shared.volumes {
            l.append("VOLUME \(v.path) \(v.isLocal ? "local" : "network")\(v.isRoot ? " startup" : "")\(v.remountURL.map { " " + $0 } ?? "")")
        }
        copyToClipboard(numberedReport(l, prefix: "D"))
        resultLabel.stringValue = "Diagnostics copied (\(l.count + 1) numbered lines, plain text) - paste into AutoType."
        App.log.info("Diagnostics copied")
    }

    @objc private func showLogs(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newWindow(path: App.files.logsDir)
    }
}
