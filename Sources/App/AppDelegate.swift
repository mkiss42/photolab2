// AppDelegate.swift
// App start-up, menus, windows, settings, self-check.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []
    private var settings: SettingsWindowController?
    private var showHiddenItem: NSMenuItem?
    private var foldersFirstItem: NSMenuItem?
    private var folderSizesItem: NSMenuItem?
    /// Checks every 10 minutes whether the scheduled clean-up is due (no disk or network activity otherwise).
    private var maintenanceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        App.start()
        StatusMenu.shared = StatusMenu()   // PhotoLab: the menu bar icon
        _ = App.launched
        // 0.17.1: keep what happened if Find ever stops unexpectedly; offer last time's report.
        let pending = Paths.join(App.files.logsDir, "crash-pending.txt")
        let lastCrash = (FileManager.default.contents(atPath: pending)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        CrashCapture.install(path: pending, version: App.version)
        App.log.info("Display: macOS Reduce transparency is \(Finish.systemReducesTransparency ? "ON (Glass shows plain grey)" : "off")")
        if !lastCrash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reportLastCrash(lastCrash) }
        _ = ThemeManager.shared
        NSApp.mainMenu = buildMenu()
        KeyMap.apply(to: NSApp.mainMenu)   // 0.16: custom keys
        NSApp.registerServicesMenuSendTypes([.fileURL, .string], returnTypes: [])
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged(_:)), name: .findPrefsChanged, object: nil)
        // 0.14: Find's dialogs and tool windows in the theme's colours.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            if let w = n.object as? NSWindow, ThemeStyler.shouldStyle(w) {
                ThemeStyler.style(window: w)
                // 0.18.2: Tab / Shift-Tab move between the fields of every dialog. Find's dialogs are
                // built in code, so they had no key-view order; AppKit now works it out from the layout
                // (top to bottom, left to right) and keeps it up to date when a dialog changes.
                if !w.autorecalculatesKeyViewLoop {
                    w.autorecalculatesKeyViewLoop = true
                    w.recalculateKeyViewLoop()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .findThemeChanged, object: nil, queue: .main) { _ in
            ThemeStyler.styleAllWindows()
        }
        if !reopenSavedWindows() { newWindow(path: Prefs.startPath) }
        NSApp.activate(ignoringOtherApps: true)
        // Full volume details (names, how to reconnect shares) in the background; then the saved servers
        // marked "connect when Find starts" that aren't connected yet (once per start of Find).
        Volumes.refresh { [weak self] in
            NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
            self?.autoConnectServers()
        }
        reportRecovery()
        startMaintenance()
        CopyQueueManager.shared.start()
    }

    // MARK: Saved servers: connect at start

    private func autoConnectServers() {
        let todo = ServerList.toAutoConnect(Prefs.savedServers, volumes: VolumeRegistry.shared.volumes)
        let already = Prefs.savedServers.filter { $0.autoConnect }.count - todo.count
        if todo.isEmpty {
            if already > 0 { App.log.info("Start-up connections: all \(already) already connected") }
            return
        }
        App.log.info("Start-up connections: \(todo.count) to connect, \(already) already connected")
        // One after another, silently (no dialogs at start-up: a server that needs a password nobody
        // saved simply stays unconnected - click it in the sidebar to connect and type it).
        DispatchQueue.global(qos: .utility).async {
            for s in todo {
                guard let a = s.parsed, let url = s.mountURL else { continue }
                let pw = ServerKeychain.password(host: a.host, user: s.user, scheme: a.scheme)
                let done = DispatchSemaphore(value: 0)
                var result: String? = nil
                DispatchQueue.main.async {
                    Volumes.mount(url, user: s.user.isEmpty ? nil : s.user, password: pw, silent: true) { err in
                        result = err
                        done.signal()
                    }
                }
                _ = done.wait(timeout: .now() + 90)
                DispatchQueue.main.async {
                    if let e = result {
                        ServerStatus.lastError[s.id] = e
                        App.log.warn("Start-up connection to \(s.name) (\(Ascii.clean(a.display))) failed: \(e)")
                    } else {
                        ServerStatus.lastError[s.id] = nil
                        App.log.info("Start-up connection to \(s.name) (\(Ascii.clean(a.display))): connected")
                    }
                }
            }
            DispatchQueue.main.async {
                Volumes.refresh { NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
            }
        }
    }

    // MARK: 0.17.1: last time's crash

    private func reportLastCrash(_ raw: String) {
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var numbered: [String] = []
        for (i, l) in lines.enumerated() { numbered.append(String(format: "X%03d ", i + 1) + Ascii.clean(l)) }
        numbered.append("Total: \(lines.count) lines")
        let text = "PHOTOLAB CRASH REPORT (from the previous run)\n" + numbered.joined(separator: "\n") + "\n"
        let saved = Paths.join(App.files.logsDir, "crash-\(Ascii.fileStamp()).txt")
        App.files.writeText(text, to: saved)
        App.log.warn("PhotoLab stopped unexpectedly last time; report saved as \(saved)")
        for l in numbered.prefix(12) { App.log.warn("CRASH \(l)") }
        App.lastReport = text
        DispatchQueue.main.async {
            let a = ThemedAlert()
            a.messageText = "PhotoLab stopped unexpectedly last time"
            let doing = lines.first(where: { $0.hasPrefix("Doing:") }) ?? ""
            a.informativeText = "A report of what happened was saved in Logs/PhotoLab (\(Paths.lastComponent(saved)))."
                + (doing.count > 7 ? "\n\n" + doing : "")
                + "\n\nCopy Report puts it on the clipboard (numbered plain lines, for AutoType) - please send it to me."
            a.addButton(withTitle: "Copy Report")
            a.addButton(withTitle: "OK")
            if a.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    // MARK: Phase 5: recovery report and automatic clean-up

    /// If the previous run was interrupted in the middle of a copy or rename, say what was put right.
    private func reportRecovery() {
        let lines = App.recoveryLines
        if lines.isEmpty { return }
        DispatchQueue.main.async {
            let a = ThemedAlert()
            a.messageText = "PhotoLab finished an interrupted operation"
            let back = lines.filter { $0.contains("renamed back") }.count
            let trashed = lines.filter { $0.contains("to the Trash") }.count
            let failed = lines.filter { $0.contains("E-RECOVER") }.count
            var info = "PhotoLab was stopped (crash, Force Quit or power cut) in the middle of a copy or rename. Nothing was deleted."
            if back > 0 { info += "\n\n\(back) item\(back == 1 ? " was" : "s were") given back \(back == 1 ? "its" : "their") name." }
            if trashed > 0 { info += "\n\(trashed) unfinished cop\(trashed == 1 ? "y was" : "ies were") moved to the Trash." }
            if failed > 0 { info += "\n\(failed) could not be handled and will be tried again next time (see the log)." }
            a.informativeText = info
            a.alertStyle = failed > 0 ? .warning : .informational
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Copy Details")
            if a.runModal() == .alertSecondButtonReturn {
                var numbered: [String] = []
                for (i, l) in lines.enumerated() { numbered.append(String(format: "R%04d ", i + 1) + l) }
                numbered.append(String(format: "R%04d END total-lines=%d", lines.count + 1, lines.count + 1))
                let text = numbered.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func startMaintenance() {
        let policy = Prefs.maintenancePolicy
        if policy.automatic && policy.atStartup {
            // A little after start, so opening the first window is never slowed down.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                _ = App.maintenance.cleanUp(Prefs.maintenancePolicy, trigger: "at startup")
            }
        }
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.maintenanceTick() }
        t.tolerance = 120
        #if swift(>=4.2)
        RunLoop.main.add(t, forMode: .common)
        #else
        RunLoop.main.add(t, forMode: .commonModes)
        #endif
        maintenanceTimer = t
    }

    private func maintenanceTick() {
        let p = Prefs.maintenancePolicy
        guard App.maintenance.isDue(p) else { return }
        DispatchQueue.global(qos: .utility).async { _ = App.maintenance.cleanUp(p, trigger: "scheduled (every \(p.everyHours) h)") }
    }

    /// PhotoLab: the browser windows (for the menu bar icon).
    var windowControllers: [BrowserWindowController] { return controllers }

    /// PhotoLab: items dropped on the Dock icon or opened with PhotoLab. A folder opens in a new
    /// window; a file opens its folder with the file selected. List or contact sheet: the menu bar
    /// icon's setting. Which is which is asked off the main thread (the item may be on a share).
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        sender.reply(toOpenOrPrint: .success)
        DispatchQueue.global(qos: .userInitiated).async {
            var e: Int32 = 0
            let kinds = filenames.map { ($0, Sys.statInfo($0, &e)?.isDirectory ?? false) }
            DispatchQueue.main.async {
                var byFolder: [String: [String]] = [:]
                var order: [String] = []
                for (p, isDir) in kinds {
                    let folder = isDir ? p : Paths.parent(p)
                    if byFolder[folder] == nil { order.append(folder); byFolder[folder] = [] }
                    if !isDir { byFolder[folder]?.append(Paths.lastComponent(p)) }
                }
                for f in order.prefix(8) {
                    let c = self.newWindow(path: f)
                    if StatusMenu.dropOpens == "photo" { c.pane.restoreViewMode("photo") }
                    if let sel = byFolder[f], !sel.isEmpty { c.pane.navigate(to: f, select: sel, addHistory: false) }
                    App.log.info("Opened from the Dock / Open With: \(f)")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || controllers.isEmpty { newWindow(path: Prefs.startPath) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 0.18.10: ratings still being written in the background are finished first.
        if BackgroundMetaWriter.shared.isBusy {
            App.log.info("Quit waits for \(BackgroundMetaWriter.shared.busy) background metadata write(s)")
            BackgroundMetaWriter.shared.onIdle.append { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        // A queued copy that is running: ask; if quitting, it is stopped safely and starts again next time.
        if CopyQueueManager.shared.isRunning {
            let a = ThemedAlert()
            a.messageText = "A queued copy is running"
            a.informativeText = "Quit anyway? The item being copied stops safely (nothing half-copied is kept) and the copy carries on from there the next time PhotoLab runs."
            a.addButton(withTitle: "Keep Running")
            a.addButton(withTitle: "Quit")
            if a.runModal() != .alertSecondButtonReturn { return .terminateCancel }
            CopyQueueManager.shared.stopForQuit()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindows("quit")
        ShareListings.saveIfChanged(wait: true)
        if let d = FTPMemory.shared.encode() { _ = App.files.writeData(d, to: FTPMemory.file) }
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        App.indexes.saveDirty()
        let policy = Prefs.maintenancePolicy
        if policy.automatic && policy.atQuit {
            _ = App.maintenance.cleanUp(policy, trigger: "at quit")
        }
        App.files.clearTemp()
        App.log.info("PhotoLab quit")
        ExifToolPool.shared.shutdown()
        IOLog.network?.close()
        IOLog.disk?.close()
        App.log.close()
    }

    @objc func volumesChanged(_ n: Notification) {
        let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        let root = url?.path ?? ""
        App.log.info("Volumes changed: \(n.name.rawValue) \(root)")
        // Known before the list is refreshed: was it a network share?
        let wasNetwork = !root.isEmpty && (VolumeRegistry.shared.isNetwork(root) ?? root.hasPrefix("/Volumes/"))
        ListingCache.shared.removeAll()
        if n.name == NSWorkspace.didUnmountNotification && !root.isEmpty {
            for c in controllers { c.shareUnmounted(root, wasNetwork: wasNetwork) }
        }
        Volumes.refresh { [weak self] in
            NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
            if n.name == NSWorkspace.didMountNotification && !root.isEmpty {
                for c in self?.controllers ?? [] { c.shareMounted(root) }
            }
        }
    }

    @objc func prefsChanged(_ n: Notification) {
        showHiddenItem?.state = Prefs.showHidden ? .on : .off
        foldersFirstItem?.state = Prefs.foldersFirst ? .on : .off
        folderSizesItem?.state = Prefs.calculateFolderSizes ? .on : .off
    }

    @objc func screensChanged(_ n: Notification) {
        WindowPlacementManager.shared.screensChanged()
    }

    // MARK: Windows

    @discardableResult
    /// PhotoLab: the contact sheet window (the front one, or a new one at its remembered size: 80% of
    /// the screen, centred, the first time). `newTab`: in a new tab of it.
    func openContactSheet(_ folder: String, select: [String] = [], newTab: Bool) {
        if let c = controllers.last(where: { $0.isContactSheet && $0.window?.isVisible == true }) {
            c.pane.showContactSheet(folder, select: select, newTab: newTab)
            c.window?.makeKeyAndOrderFront(nil)
            c.window?.makeFirstResponder(c.pane.grid)
            return
        }
        let c = BrowserWindowController(path: folder, contactSheet: true)
        c.onClose = { [weak self] ctrl in
            guard let s = self else { return }
            s.controllers = s.controllers.filter { $0 !== ctrl }
        }
        controllers.append(c)
        if let w = c.window {
            w.setFrame(BrowserWindowController.contactSheetFrame(), display: false)
            c.finishLayout()
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(c.pane.grid)
        }
        if !select.isEmpty { c.pane.showContactSheet(folder, select: select, newTab: false) }
        App.log.info("Contact sheet window opened")
    }

    func newWindow(path: String) -> BrowserWindowController {
        let reference = NSApp.keyWindow
        let c = BrowserWindowController(path: path)
        c.onClose = { [weak self] ctrl in
            guard let s = self else { return }
            if let w = ctrl.window { WindowPlacementManager.shared.forget(w) }
            s.controllers = s.controllers.filter { $0 !== ctrl }
            s.saveWindows(nil)
        }
        controllers.append(c)
        if let w = c.window {
            let intended = WindowPlacementManager.shared.place(w, reference: reference)
            c.finishLayout()
            w.makeKeyAndOrderFront(nil)
            if let r = intended { WindowPlacementManager.shared.confirm(w, intended: r) }
            w.makeFirstResponder(c.focusView)
        }
        saveWindows(nil)
        return c
    }

    // MARK: Reopening windows (0.13)

    /// True while saved windows are being reopened (nothing is saved meanwhile).
    private var reopening = false

    func applicationDidResignActive(_ notification: Notification) {
        saveWindows(nil)
    }

    private var saveSoonTimer: Timer?

    /// After a window was moved or resized: save a few seconds later (once, however many moves).
    func saveWindowsSoon() {
        guard !reopening else { return }
        saveSoonTimer?.invalidate()
        saveSoonTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.saveSoonTimer = nil
            self?.saveWindows(nil)
        }
    }

    /// Save the open windows for next time. `why` (quit) is logged; other saves are quiet.
    func saveWindows(_ why: String?) {
        guard !reopening else { return }
        if !Prefs.reopenWindows {
            if why != nil { App.log.info("Windows not saved for next time (Settings > General: Reopen windows is off)") }
            return
        }
        let n = WindowSessions.save(controllers)
        if let w = why, n >= 0 { App.log.info("Windows saved for next time (\(w)): \(n)") }
    }

    /// Open the windows saved when Find was last quit. False if there were none (or reopening is off).
    private func reopenSavedWindows() -> Bool {
        guard Prefs.reopenWindows else { return false }
        guard let file = WindowSessions.load() else { return false }
        return openSession(file)
    }

    /// Open a saved set of windows (last session or a named workspace). False if it held none.
    @discardableResult
    private func openSession(_ file: WindowSessionFile, label: String = "last time") -> Bool {
        let saved = file.windows.filter { !$0.panes.isEmpty }
        if saved.isEmpty { return false }
        reopening = true
        defer { reopening = false }
        _ = Volumes.mounted()   // the mount table, read without waiting
        for sw in saved { for (root, url) in sw.shares ?? [:] { VolumeRegistry.shared.remember(root: root, remountURL: url) } }
        let displays = WindowSessions.displays()
        let fm = FileManager.default
        let reg = VolumeRegistry.shared
        let home = NSHomeDirectory()
        func exists(_ p: String) -> Bool {
            var dir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
        }
        func isNetwork(_ p: String) -> Bool {
            let root = VolumeRegistry.volumeRoot(p)
            guard root != "/", !reg.isMounted(root) else { return false }
            if reg.remountURL(p) != nil { return true }
            let name = Paths.lastComponent(root).lowercased()
            return Prefs.savedServers.contains(where: { $0.parsed?.share?.lowercased() == name })
        }
        var lines: [String] = []
        var desktopsMissed = 0
        // Back-most first, so the front-most ends up in front.
        for sw in saved.reversed() {
            let paths: (Int) -> [String] = { i in
                guard i < sw.panes.count else { return [] }
                return sw.panes[i].tabs.map { SessionFit.usablePath($0.path, exists: exists, isNetwork: isNetwork, home: home) }
            }
            let first = paths(0)
            guard !first.isEmpty else { continue }
            let a0 = max(0, min(sw.panes[0].active, first.count - 1))
            let c = BrowserWindowController(path: first[a0])
            c.onClose = { [weak self] ctrl in
                guard let s = self else { return }
                if let w = ctrl.window { WindowPlacementManager.shared.forget(w) }
                s.controllers = s.controllers.filter { $0 !== ctrl }
                s.saveWindows(nil)
            }
            controllers.append(c)
            guard let w = c.window else { continue }
            let f = SessionFit.frame(for: sw, in: displays).map { WindowSessions.nsrect($0) } ?? w.frame
            w.setFrame(f, display: false)
            WindowPlacementManager.shared.adopt(w)
            c.finishLayout()
            c.restore(sw, paths: paths)
            w.orderFront(nil)
            if w.frame != f { w.setFrame(f, display: true) }
            var desk = "-"
            if let d = sw.space {
                if Spaces.move(w, toDesktop: d, display: sw.display) {
                    desk = "\(d)"
                } else {
                    desk = "\(d) NOT MOVED (code SESS-02)"
                    desktopsMissed += 1
                }
            }
            if sw.minimized { w.miniaturize(nil) }
            let tabs = sw.panes.reduce(0) { $0 + $1.tabs.count }
            lines.append("at \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height)); panes \(c.panes.count); tabs \(tabs); desktop \(desk)\(sw.minimized ? "; minimized" : "")")
        }
        if controllers.isEmpty { return false }
        // Make the front-most window on the current desktop the active one (never switch desktops at start).
        if let front = controllers.reversed().compactMap({ $0.window }).first(where: { $0.isOnActiveSpace && !$0.isMiniaturized }) {
            front.makeKeyAndOrderFront(nil)
            if let c = front.windowController as? BrowserWindowController { front.makeFirstResponder(c.focusView) }
        }
        App.log.info("Reopened windows from \(label):")
        for (i, l) in lines.reversed().enumerated() { App.log.info("  \(i + 1). \(l)") }
        App.log.info("  Total: \(lines.count)")
        if desktopsMissed > 0 {
            App.log.warn("\(desktopsMissed) windows could not be moved to their desktop (this macOS refused; they opened on the current desktop)")
        }
        return true
    }

    /// The folder of the Find pane used last (FTP downloads go there).
    var lastBrowserFolder: String? {
        if let c = keyController { return c.currentPath }
        for w in NSApp.orderedWindows {
            if let c = w.windowController as? BrowserWindowController { return c.currentPath }
        }
        return nil
    }

    private var keyController: BrowserWindowController? {
        return NSApp.keyWindow?.windowController as? BrowserWindowController
    }

    @objc func newWindowCommand(_ sender: Any?) {
        newWindow(path: keyController?.currentPath ?? Prefs.startPath)
    }

    @objc func openSettings(_ sender: Any?) {
        if settings == nil {
            settings = SettingsWindowController()
            settings?.advancedSettings.openViews = { [weak self] in
                let wins = self?.controllers ?? []
                let panes = wins.reduce(0) { $0 + $1.panes.count }
                return "Windows open: \(wins.count); panes: \(panes)"
            }
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleFolderSizes(_ sender: Any?) {
        Prefs.calculateFolderSizes = !Prefs.calculateFolderSizes
    }

    @objc func openSidebarSettings(_ sender: Any?) {
        openSettings(sender)
        settings?.showSidebarTab()
    }

    @objc func toggleHidden(_ sender: Any?) {
        Prefs.showHidden = !Prefs.showHidden
    }

    @objc func toggleFoldersFirst(_ sender: Any?) {
        Prefs.foldersFirst = !Prefs.foldersFirst
    }

    // MARK: Self-check and logs

    @objc func runSelfCheck(_ sender: Any?) {
        let a = ThemedAlert()
        a.messageText = "Run the Safety Self-Check?"
        a.informativeText = "PhotoLab will create, rename, move, copy and trash test files inside its own folder (~/Library/Caches/PhotoLab), check every safety rule on this Mac, then remove the test files. Your own files are not touched. Anything moved to the Trash during the check is taken back out."
        a.addButton(withTitle: "Run Check")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        let check = SafetySelfCheck(ops: App.ops, files: App.files)
        let text = check.run(appVersion: App.version, systemInfo: App.systemInfo)
        App.lastReport = text
        let path = Paths.join(App.files.logsDir, "selfcheck-\(Ascii.fileStamp()).txt")
        App.files.writeText(text, to: path)
        App.log.info("Self-check: passed \(check.passed), failed \(check.failed). Report: \(path)")
        let r = ThemedAlert()
        r.messageText = check.failed == 0 ? "Self-check passed: all \(check.passed) checks" : "Self-check: \(check.failed) check(s) FAILED"
        r.informativeText = "Report saved to \(path)\n\nUse Copy Report to put the whole report on the clipboard (for AutoType)."
        r.alertStyle = check.failed == 0 ? .informational : .critical
        r.addButton(withTitle: "OK")
        r.addButton(withTitle: "Copy Report")
        r.addButton(withTitle: "Show Report")
        let resp = r.runModal()
        if resp == .alertSecondButtonReturn { copyLastReport(nil) }
        if resp == .alertThirdButtonReturn {
            let c = keyController ?? newWindow(path: App.files.logsDir)
            c.pane.newTab(path: App.files.logsDir)
            c.pane.navigate(to: App.files.logsDir, select: [Paths.lastComponent(path)])
        }
    }

    /// Help > Network Report (0.14): what macOS reports about mounted shares and how Find matches them
    /// to saved servers. Reads nothing from any server (the volume list Find already has).
    /// PhotoLab: a few path-free lines short enough to retype from an air-gapped Mac.
    @objc func shortReport(_ sender: Any?) {
        let up = Int(Date().timeIntervalSince(App.launched) / 60)
        let sys: String = App.systemInfo.components(separatedBy: ",").first ?? App.systemInfo
        let thumbs: Int = App.thumbs?.count ?? 0
        let lines: [String] = [
            "PL " + App.version + " | " + Ascii.clean(sys) + " | up \(up) min",
            FileReads.reportLine,
            StallWatch.reportLine,
            "THUMBS on disk \(thumbs)",
        ]
        let text = lines.joined(separator: "\n")
        App.log.info("Short report: " + lines.joined(separator: " / "))
        let a = ThemedAlert()
        a.alertStyle = .informational
        a.messageText = "Short Report"
        a.informativeText = text + "\n\nNo paths, names or addresses - safe to retype."
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Copy")
        if a.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc func networkReport(_ sender: Any?) {
        Volumes.refresh { [weak self] in
            let lines = NetworkReport.lines(VolumeRegistry.shared.volumes, saved: Prefs.savedServers)
            let text = "PHOTOLAB NETWORK REPORT\nPhotoLab \(App.version)\n\(App.systemInfo)\n" + lines.joined(separator: "\n") + "\n"
            App.lastReport = text
            let path = Paths.join(App.files.logsDir, "network-\(Ascii.fileStamp()).txt")
            App.files.writeText(text, to: path)
            App.log.info("Network report written: \(path)")
            let r = ThemedAlert()
            r.alertStyle = .informational
            r.messageText = "Network report: \(VolumeRegistry.shared.volumes.filter { !$0.isLocal && !$0.isRoot }.count) network volumes, \(Prefs.savedServers.count) saved servers"
            r.informativeText = "Saved to \(path)\n\nUse Copy Report to put it on the clipboard (for AutoType). It contains addresses and account names, never passwords."
            r.addButton(withTitle: "OK")
            r.addButton(withTitle: "Copy Report")
            if r.runModal() == .alertSecondButtonReturn { self?.copyLastReport(nil) }
        }
    }

    @objc func runSearchTest(_ sender: Any?) {
        let a = ThemedAlert()
        a.messageText = "Run the Search Self-Test?"
        a.informativeText = "PhotoLab builds a test folder with known contents (odd names, hidden items, links, a package, an unreadable folder) inside ~/Library/Caches/PhotoLab, runs 36 searches and checks every result, then removes the test folder. Your own files are not touched."
        a.addButton(withTitle: "Run Test")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        let t = SearchSelfTest(files: App.files, isPackage: { p, ext in KindCache.shared.isPackage(path: p, ext: ext) })
        let text = t.run(appVersion: App.version, systemInfo: App.systemInfo)
        App.lastReport = text
        let path = Paths.join(App.files.logsDir, "searchtest-\(Ascii.fileStamp()).txt")
        App.files.writeText(text, to: path)
        App.log.info("Search self-test: passed \(t.passed), failed \(t.failed), skipped \(t.skipped)")
        let r = ThemedAlert()
        r.messageText = t.failed == 0 ? "Search self-test passed (\(t.passed) checks)" : "Search self-test: \(t.failed) check(s) FAILED"
        r.informativeText = "Report saved to \(path)" + (t.skipped > 0 ? "\n\(t.skipped) check(s) skipped (see report)." : "")
        r.alertStyle = t.failed == 0 ? .informational : .critical
        r.addButton(withTitle: "OK")
        r.addButton(withTitle: "Copy Report")
        if r.runModal() == .alertSecondButtonReturn { copyLastReport(nil) }
    }

    @objc func runIndexTest(_ sender: Any?) {
        let a = ThemedAlert()
        a.messageText = "Run the Index Self-Test?"
        a.informativeText = "PhotoLab builds a test folder and a test index inside ~/Library/Caches/PhotoLab, changes the test files (add, rename, delete, move), and checks that indexed searches always give exactly the same results as direct searches. Your own files and your real indexes are not touched."
        a.addButton(withTitle: "Run Test")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        let t = IndexSelfTest(files: App.files, isPackage: { p, ext in KindCache.shared.isPackage(path: p, ext: ext) })
        let text = t.run(appVersion: App.version, systemInfo: App.systemInfo)
        App.lastReport = text
        let path = Paths.join(App.files.logsDir, "indextest-\(Ascii.fileStamp()).txt")
        App.files.writeText(text, to: path)
        App.log.info("Index self-test: passed \(t.passed), failed \(t.failed)")
        let r = ThemedAlert()
        r.messageText = t.failed == 0 ? "Index self-test passed (\(t.passed) checks)" : "Index self-test: \(t.failed) check(s) FAILED"
        r.informativeText = "Report saved to \(path)"
        r.alertStyle = t.failed == 0 ? .informational : .critical
        r.addButton(withTitle: "OK")
        r.addButton(withTitle: "Copy Report")
        if r.runModal() == .alertSecondButtonReturn { copyLastReport(nil) }
    }

    /// Cmd-W: in a Find window close the tab (the last tab closes the pane, the last pane the window);
    /// any other window (Get Info, Compare, Settings) just closes.
    @objc func closeWindowOrTab(_ sender: Any?) {
        guard let w = NSApp.keyWindow else { return }
        if let c = w.windowController as? BrowserWindowController {
            c.pane.closeTabCommand(nil)
        } else {
            w.performClose(nil)
        }
    }

    /// Sidebar eject: windows showing the volume go home first, then macOS ejects it.
    func ejectVolume(_ path: String) {
        let name = Paths.lastComponent(path)
        FastPreview.shared.close()   // a video or picture from that volume may be open
        for c in controllers { c.leaveVolume(path) }
        App.log.info("Eject requested: \(path)")
        Volumes.eject(path) { error in
            if let e = error {
                App.log.warn("Eject failed: \(path): \(e)")
                let a = ThemedAlert()
                a.messageText = "\u{201C}\(name)\u{201D} could not be ejected"
                a.informativeText = e
                a.alertStyle = .warning
                a.runModal()
            } else {
                App.log.info("Ejected: \(path)")
                NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
            }
        }
    }

    @objc func runPhotoTest(_ sender: Any?) {
        let t = PhotoSelfTest(files: App.files)
        let text = t.run(appVersion: App.version, systemInfo: App.systemInfo)
        App.lastReport = text
        let path = Paths.join(App.files.logsDir, "phototest-\(Ascii.fileStamp()).txt")
        App.files.writeText(text, to: path)
        App.log.info("Photo metadata self-test: passed \(t.passed), failed \(t.failed), skipped \(t.skipped)")
        let r = ThemedAlert()
        r.messageText = t.failed == 0 ? "Photo metadata self-test passed (\(t.passed) checks)" : "Photo metadata self-test: \(t.failed) check(s) FAILED"
        r.informativeText = "It made a small test JPEG in ~/Library/Caches/PhotoLab, read it back, and removed it.\nReport saved to \(path)"
        r.alertStyle = t.failed == 0 ? .informational : .critical
        r.addButton(withTitle: "OK")
        r.addButton(withTitle: "Copy Report")
        if r.runModal() == .alertSecondButtonReturn { copyLastReport(nil) }
    }

    @objc func copyLastReport(_ sender: Any?) {
        var text = App.lastReport
        if text.isEmpty {
            // Fall back to the current log.
            text = App.log.snapshot()
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func copyCurrentLog(_ sender: Any?) {
        let text = App.log.snapshot()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func showLogsFolder(_ sender: Any?) {
        if let c = keyController {
            c.pane.newTab(path: App.files.logsDir)
        } else {
            newWindow(path: App.files.logsDir)
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let a = ThemedAlert()
        a.messageText = "PhotoLab \(App.version)"
        a.informativeText = "A fast, careful file browser.\nRemoval goes to the Trash; PhotoLab deletes permanently only after you confirm (shares without a Trash, Delete Immediately).\n\n\(App.systemInfo)"
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        mi.target = target
        mi.tag = tag
        return mi
    }

    private static func key(_ functionKey: Int) -> String {
        guard let u = UnicodeScalar(UInt32(functionKey)) else { return "" }
        return String(Character(u))
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let up = AppDelegate.key(NSUpArrowFunctionKey)
        let down = AppDelegate.key(NSDownArrowFunctionKey)
        let backspace = "\u{8}"

        // App menu
        let appMenu = NSMenu(title: "PhotoLab")
        appMenu.addItem(item("About PhotoLab", #selector(showAbout(_:)), "", [], target: self))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item("Settings\u{2026}", #selector(openSettings(_:)), ",", [.command], target: self))
        appMenu.addItem(NSMenuItem.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = services
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item("Hide PhotoLab", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item("Quit PhotoLab", #selector(NSApplication.terminate(_:)), "q"))
        addSubmenu(main, "PhotoLab", appMenu)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New Window", #selector(newWindowCommand(_:)), "n", [.command], target: self))
        file.addItem(item("New Tab", #selector(BrowserPane.newTabCommand(_:)), "t"))
        file.addItem(item("New Folder", #selector(BrowserPane.newFolder(_:)), "n", [.command, .shift]))
        file.addItem(NSMenuItem.separator())
        file.addItem(item("Open", #selector(BrowserPane.openSelected(_:)), "o"))
        file.addItem(item("Open Enclosed Item", #selector(BrowserPane.openSelected(_:)), down))
        file.addItem(item("Open in New Tab", #selector(BrowserPane.openSelectedInNewTab(_:)), ""))
        file.addItem(item("Open in New Window", #selector(BrowserPane.openSelectedInNewWindow(_:)), "o", [.command, .option]))
        file.addItem(item("Show Package Contents", #selector(BrowserPane.showPackageContents(_:)), ""))
        file.addItem(item("Open in Terminal", #selector(BrowserPane.openInTerminal(_:)), ""))
        file.addItem(item("Open With Other Application\u{2026}", #selector(BrowserPane.openWithOther(_:)), ""))
        file.addItem(NSMenuItem.separator())
        file.addItem(item("Close Tab", #selector(closeWindowOrTab(_:)), "w", [.command], target: self))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(NSMenuItem.separator())
        // 0.18.15: Cmd-I is the Metadata Template (the user's choice); Get Info moved to Shift-Cmd-I.
        file.addItem(item("Get Info", #selector(BrowserPane.getInfo(_:)), "i", [.command, .shift]))
        file.addItem(item("Fast Preview (Space)", #selector(BrowserPane.fastPreview(_:)), ""))
        file.addItem(item("Quick Look (macOS)", #selector(BrowserPane.quickLook(_:)), "y"))
        file.addItem(item("Compare Selected Pictures", #selector(BrowserPane.compareSelected(_:)), ""))
        file.addItem(item("Make Contact Sheet\u{2026}", #selector(BrowserPane.makeContactSheet(_:)), ""))
        file.addItem(item("Edit Metadata (key: I)", #selector(BrowserPane.editMetadata(_:)), ""))
        file.addItem(item("Metadata Template\u{2026}", #selector(BrowserPane.metadataTemplate(_:)), "i"))
        file.addItem(item("Compare Folders\u{2026}", #selector(BrowserPane.compareFolders(_:)), "k", [.command, .control]))
        file.addItem(item("Find Duplicates\u{2026}", #selector(BrowserPane.findDuplicates(_:)), ""))
        file.addItem(item("Rename\u{2026}", #selector(BrowserPane.renameSelected(_:)), ""))
        file.addItem(item("Find and Replace\u{2026}", #selector(BrowserPane.findAndReplace(_:)), "f", [.command, .option]))
        file.addItem(item("Compress", #selector(BrowserPane.compressSelected(_:)), ""))
        file.addItem(item("Make Alias", #selector(BrowserPane.makeAliasOfSelected(_:)), "l"))
        file.addItem(item("New Folder with Selection", #selector(BrowserPane.newFolderWithSelection(_:)), "n", [.command, .control]))
        file.addItem(item("Duplicate", #selector(BrowserPane.duplicateSelected(_:)), "d"))
        file.addItem(item("Add to Copy Queue\u{2026}", #selector(BrowserPane.addToCopyQueue(_:)), ""))
        file.addItem(item("Move To\u{2026}", #selector(BrowserPane.moveTo(_:)), "m", [.command, .shift]))
        file.addItem(item("Copy To\u{2026}", #selector(BrowserPane.copyTo(_:)), ""))
        file.addItem(item("Copy to Other Pane", #selector(BrowserPane.copyToOtherPane(_:)), AppDelegate.key(NSF5FunctionKey), []))
        file.addItem(item("Move to Other Pane", #selector(BrowserPane.moveToOtherPane(_:)), AppDelegate.key(NSF6FunctionKey), []))
        file.addItem(item("Move to Trash", #selector(BrowserPane.trashSelected(_:)), backspace))
        file.addItem(item("Delete Immediately\u{2026}", #selector(BrowserPane.deleteImmediatelySelected(_:)), backspace, [.command, .option]))
        file.addItem(NSMenuItem.separator())
        file.addItem(item("Add to Sidebar", #selector(BrowserPane.addToSidebar(_:)), "t", [.command, .control]))
        file.addItem(item("Show in Finder", #selector(BrowserPane.revealInFinder(_:)), "r", [.command, .shift]))
        file.addItem(NSMenuItem.separator())
        // PhotoLab: Cmd-F filters the folder shown (as in PhotoLab 2); Cmd-Shift-F searches.
        file.addItem(item("Filter\u{2026}", #selector(BrowserPane.showFilter(_:)), "f"))
        file.addItem(item("Find\u{2026}", #selector(BrowserPane.focusSearch(_:)), "f", [.command, .shift]))
        file.addItem(item("Search in Selected Folder\u{2026}", #selector(BrowserPane.searchHere(_:)), ""))
        addSubmenu(main, "File", file)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(NSMenuItem.separator())
        edit.addItem(item("Copy Info as Text", #selector(BrowserPane.copyInfoAsText(_:)), "c", [.command, .control]))
        edit.addItem(NSMenuItem.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste (Copy Items Here)", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Move Items Here", #selector(BrowserPane.moveHere(_:)), "v", [.command, .option]))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(NSMenuItem.separator())
        edit.addItem(item("Copy Path", #selector(BrowserPane.copyPath(_:)), "c", [.command, .option]))
        edit.addItem(item("Copy Name", #selector(BrowserPane.copyName(_:)), "c", [.command, .shift, .option]))
        addSubmenu(main, "Edit", edit)

        // View
        let view = NSMenu(title: "View")
        let hid = item("Show Hidden Files", #selector(toggleHidden(_:)), ".", [.command, .shift], target: self)
        hid.state = Prefs.showHidden ? .on : .off
        showHiddenItem = hid
        view.addItem(hid)
        let ff = item("Keep Folders on Top", #selector(toggleFoldersFirst(_:)), "", [], target: self)
        ff.state = Prefs.foldersFirst ? .on : .off
        foldersFirstItem = ff
        view.addItem(ff)
        let fs = item("Calculate Folder Sizes", #selector(toggleFolderSizes(_:)), "", [], target: self)
        fs.state = Prefs.calculateFolderSizes ? .on : .off
        folderSizesItem = fs
        view.addItem(fs)
        view.addItem(NSMenuItem.separator())
        let sortSub = NSMenu(title: "Sort By")
        for (t, k) in [("Name", "name"), ("Kind", "kind"), ("Date Modified", "modified"), ("Date Created", "created"), ("Date Added", "added"), ("Size", "size")] {
            let mi = item(t, #selector(BrowserPane.sortByMenu(_:)), "", [])
            mi.representedObject = k
            sortSub.addItem(mi)
        }
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = sortSub
        view.addItem(sortItem)
        let colSub = NSMenu(title: "Show Columns")
        for (t, k) in [("Date Modified", "modified"), ("Date Created", "created"), ("Date Added", "added"), ("Size", "size"), ("Kind", "kind")] {
            let mi = item(t, #selector(BrowserPane.toggleColumnMenu(_:)), "", [])
            mi.representedObject = k
            colSub.addItem(mi)
        }
        let colItem = NSMenuItem(title: "Show Columns", action: nil, keyEquivalent: "")
        colItem.submenu = colSub
        view.addItem(colItem)
        view.addItem(NSMenuItem.separator())
        view.addItem(item("as List", #selector(BrowserPane.viewAsList(_:)), "1"))
        view.addItem(item("as Thumbnails", #selector(BrowserPane.viewAsThumbnails(_:)), "2"))
        view.addItem(item("Photography Mode", #selector(BrowserPane.viewPhotography(_:)), "3"))
        view.addItem(item("Larger Thumbnails", #selector(BrowserPane.largerThumbnails(_:)), "="))
        view.addItem(item("Smaller Thumbnails", #selector(BrowserPane.smallerThumbnails(_:)), "-"))
        view.addItem(NSMenuItem.separator())
        view.addItem(item("Refresh", #selector(BrowserPane.refresh(_:)), "r"))
        view.addItem(item("Show/Hide Inspector", #selector(BrowserWindowController.toggleInspector(_:)), "i", [.command, .option]))
        view.addItem(item("Show/Hide Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s", [.command, .option]))
        view.addItem(NSMenuItem.separator())
        view.addItem(item("Next Tab", #selector(BrowserPane.nextTab(_:)), "}", [.command]))
        view.addItem(item("Previous Tab", #selector(BrowserPane.previousTab(_:)), "{", [.command]))
        addSubmenu(main, "View", view)

        // Go
        let go = NSMenu(title: "Go")
        go.addItem(item("Back", #selector(BrowserPane.goBack(_:)), "["))
        go.addItem(item("Forward", #selector(BrowserPane.goForward(_:)), "]"))
        go.addItem(item("Enclosing Folder", #selector(BrowserPane.goUp(_:)), up))
        go.addItem(NSMenuItem.separator())
        go.addItem(item("Computer", #selector(BrowserPane.goComputer(_:)), "c", [.command, .shift]))
        go.addItem(item("Home", #selector(BrowserPane.goHome(_:)), "h", [.command, .shift]))
        go.addItem(item("Desktop", #selector(BrowserPane.goDesktop(_:)), "d", [.command, .shift]))
        go.addItem(item("Documents", #selector(BrowserPane.goDocuments(_:)), "o", [.command, .shift]))
        go.addItem(item("Downloads", #selector(BrowserPane.goDownloads(_:)), "l", [.command, .option]))
        go.addItem(item("Pictures", #selector(BrowserPane.goPictures(_:)), ""))
        go.addItem(item("Applications", #selector(BrowserPane.goApplications(_:)), "a", [.command, .shift]))
        go.addItem(item("Volumes", #selector(BrowserPane.goVolumes(_:)), ""))
        go.addItem(NSMenuItem.separator())
        go.addItem(item("Go to Folder\u{2026}", #selector(BrowserPane.goToFolder(_:)), "g", [.command, .shift]))
        addSubmenu(main, "Go", go)

        // Window
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        win.addItem(NSMenuItem.separator())
        let quarters = NSMenu(title: "Move Window to Quarter")
        quarters.addItem(item("Top Left", #selector(BrowserPane.moveWindowToQuarter(_:)), "", [], tag: 0))
        quarters.addItem(item("Top Right", #selector(BrowserPane.moveWindowToQuarter(_:)), "", [], tag: 1))
        quarters.addItem(item("Bottom Left", #selector(BrowserPane.moveWindowToQuarter(_:)), "", [], tag: 2))
        quarters.addItem(item("Bottom Right", #selector(BrowserPane.moveWindowToQuarter(_:)), "", [], tag: 3))
        let qItem = NSMenuItem(title: "Move Window to Quarter", action: nil, keyEquivalent: "")
        qItem.submenu = quarters
        win.addItem(qItem)
        win.addItem(item("New Pane", #selector(BrowserPane.openNewPane(_:)), "2", [.command, .control]))
        win.addItem(item("Close Pane", #selector(BrowserPane.closePaneCommand(_:)), "w", [.command, .control]))
        win.addItem(item("Arrange Panes Side by Side", #selector(BrowserWindowController.arrangePanesSideBySide(_:)), ""))
        win.addItem(item("Arrange Panes Stacked", #selector(BrowserWindowController.arrangePanesStacked(_:)), ""))
        win.addItem(item("Move Pane Left", #selector(BrowserPane.movePaneEarlier(_:)), ""))
        win.addItem(item("Move Pane Right", #selector(BrowserPane.movePaneLater(_:)), ""))
        win.addItem(item("Go to Other Pane (Tab)", #selector(BrowserPane.switchToOtherPane(_:)), ""))
        win.addItem(item("Show Same Folder in Other Pane", #selector(BrowserPane.sameFolderInOtherPane(_:)), ""))
        win.addItem(NSMenuItem.separator())
        // 0.16: named workspaces (saved sets of windows).
        win.addItem(item("Copies and Copy Queue", #selector(showCopyQueue(_:)), "", [], target: self))
        win.addItem(NSMenuItem.separator())
        win.addItem(item("Save Windows as Workspace\u{2026}", #selector(saveWorkspace(_:)), "", [], target: self))
        let openWS = NSMenuItem(title: "Open Workspace", action: nil, keyEquivalent: "")
        openWS.submenu = NSMenu(title: "Open Workspace")
        openWS.submenu?.delegate = self
        win.addItem(openWS)
        let delWS = NSMenuItem(title: "Delete Workspace", action: nil, keyEquivalent: "")
        delWS.submenu = NSMenu(title: "Delete Workspace")
        delWS.submenu?.delegate = self
        win.addItem(delWS)
        win.addItem(NSMenuItem.separator())
        win.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        addSubmenu(main, "Window", win)
        NSApp.windowsMenu = win

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("Run Safety Self-Check\u{2026}", #selector(runSelfCheck(_:)), "", [], target: self))
        help.addItem(item("Run Search Self-Test\u{2026}", #selector(runSearchTest(_:)), "", [], target: self))
        help.addItem(item("Run Index Self-Test\u{2026}", #selector(runIndexTest(_:)), "", [], target: self))
        help.addItem(item("Run Photo Metadata Self-Test", #selector(runPhotoTest(_:)), "", [], target: self))
        help.addItem(item("Network Report", #selector(networkReport(_:)), "", [], target: self))
        help.addItem(item("Short Report (to Retype)", #selector(shortReport(_:)), "", [], target: self))
        help.addItem(item("Copy Last Report to Clipboard", #selector(copyLastReport(_:)), "", [], target: self))
        help.addItem(item("Copy Current Log to Clipboard", #selector(copyCurrentLog(_:)), "", [], target: self))
        help.addItem(item("Show Logs Folder", #selector(showLogsFolder(_:)), "", [], target: self))
        addSubmenu(main, "Help", help)

        return main
    }

    private func addSubmenu(_ main: NSMenu, _ title: String, _ sub: NSMenu) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = sub
        main.addItem(mi)
    }
}


// MARK: - Named workspaces (0.16)

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Workspace" || menu.title == "Delete Workspace" else { return }
        menu.removeAllItems()
        let names = WindowSessions.workspaceNames()
        if names.isEmpty {
            let none = NSMenuItem(title: "No workspaces yet (Save Windows as Workspace\u{2026})", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        let opening = menu.title == "Open Workspace"
        for n in names {
            let i = NSMenuItem(title: n, action: opening ? #selector(openWorkspace(_:)) : #selector(deleteWorkspace(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = n
            menu.addItem(i)
        }
    }

    @objc func showCopyQueue(_ sender: Any?) { CopyQueueWindowController.show() }

    @objc func saveWorkspace(_ sender: Any?) {
        let open = controllersInOrder()
        guard !open.isEmpty else { NSSound.beep(); return }
        let a = ThemedAlert()
        a.messageText = "Save these windows as a workspace"
        a.informativeText = "\(open.count) window\(open.count == 1 ? "" : "s"): positions, displays, desktops, panes, tabs and view modes. Open it again from Window > Open Workspace."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Name, e.g. Editing"
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = WorkspaceNames.clean(field.stringValue)
        guard WorkspaceNames.fileName(for: name) != nil else { NSSound.beep(); return }
        if WindowSessions.workspaceNames().contains(where: { $0.lowercased() == name.lowercased() }) {
            let r = ThemedAlert()
            r.messageText = "Replace the workspace \u{201C}\(name)\u{201D}?"
            r.informativeText = "Only the saved window layout is replaced; no files are touched."
            r.addButton(withTitle: "Cancel")
            r.addButton(withTitle: "Replace")
            guard r.runModal() == .alertSecondButtonReturn else { return }
        }
        if WindowSessions.saveWorkspace(name, open) {
            App.log.info("Workspace saved: \(name) (\(open.count) windows)")
        } else {
            App.log.warn("Workspace could not be saved (code SESS-03): \(name)")
            let e = ThemedAlert()
            e.messageText = "The workspace could not be saved"
            e.informativeText = "Code SESS-03. The log has details."
            e.addButton(withTitle: "OK")
            e.runModal()
        }
    }

    /// Close the open Find windows and open the workspace's (nothing on disk changes).
    @objc func openWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let file = WindowSessions.loadWorkspace(name),
            !file.windows.isEmpty else { NSSound.beep(); return }
        App.log.info("Workspace opened: \(name)")
        let old = controllers
        controllers = []
        for c in old { c.window?.close() }
        if !openSession(file, label: "workspace \(name)") { newWindow(path: Prefs.startPath) }
        saveWindows(nil)
    }

    @objc func deleteWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let a = ThemedAlert()
        a.messageText = "Delete the workspace \u{201C}\(name)\u{201D}?"
        a.informativeText = "Only the saved window layout is deleted; no folders or files are touched."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Delete")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        App.log.info("Workspace deleted: \(name) (\(WindowSessions.deleteWorkspace(name) ? "done" : "FAILED"))")
    }

    private func controllersInOrder() -> [BrowserWindowController] {
        return controllers
    }
}
