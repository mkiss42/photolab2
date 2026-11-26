// AppDelegate.swift
// Starts the brain and the first browser window; owns the menu bar.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var brain: BrainClient!
    private var napBlocker: NSObjectProtocol?

    /// A rename interrupted by a crash or power loss is rolled back at launch; hidden partial
    /// copies left by an interrupted copy are removed.
    private func recoverInterruptedOperations() {
        DispatchQueue.global(qos: .userInitiated).async {
            let renamed = FileOperations.recoverJournal()
            let copied = FileOperations.recoverTransfers()
            for (title, text) in [("An interrupted rename was undone", renamed), ("An interrupted copy was cleaned up", copied)] {
                guard let t = text else { continue }
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = title
                    a.informativeText = t
                    a.runModal()
                }
            }
        }
    }

    static var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Stats.started            // a static let starts lazily: start the uptime clock now
        AppFiles.ensureDirectories()
        Log.info("PhotoLab \(AppDelegate.appVersion) starting, \(SystemInfo.summary)")
        FreezeWatchdog.start()
        // No App Nap: folder polling and the watchdog must keep their timing in the background.
        napBlocker = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                           reason: "Watching folders for changes")
        recoverInterruptedOperations()
        Activity.set("launch: volumes")
        Volumes.refresh()
        Activity.set("launch: menu")
        buildMenu()
        installKeyMonitor()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            ws.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }

        statusMenu = StatusMenu()
        DispatchQueue.global(qos: .utility).async { AppFiles.pruneThumbnails() }
        let last = UserDefaults.standard.string(forKey: "lastFolder")
        Activity.set("launch: window")
        if !openedWithItems { openFirstWindow(preferred: last) }
        DispatchQueue.main.async { Activity.set("idle") }

        brain = BrainClient(socketPath: AppFiles.brainSocketPath)
        brain.onStateChange = { s in
            BrowserWindowController.brainText = s.text
            NotificationCenter.default.post(name: .brainStateChanged, object: nil)
        }
        brain.start()
    }

    /// Last folder if it still exists (checked off the main thread: it may be on a dead share).
    private func openFirstWindow(preferred: String?) {
        guard let p = preferred, p != NSHomeDirectory() else {
            BrowserWindowController.openWindow(at: NSHomeDirectory())
            return
        }
        var answered = false
        let timeout = DispatchWorkItem {
            if answered { return }
            answered = true
            Log.info("last folder did not answer within 1 s, opening home: \(p)")
            BrowserWindowController.openWindow(at: NSHomeDirectory())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
            DispatchQueue.main.async {
                if answered { return }
                answered = true
                timeout.cancel()
                BrowserWindowController.openWindow(at: ok ? p : NSHomeDirectory())
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        brain?.stop()
        Log.info("PhotoLab quitting")
        Log.flush()
    }

    /// PhotoLab keeps running with no window (the menu bar icon stays); Cmd-Q or the icon's
    /// Quit ends it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Dock icon clicked with no window open: open one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if BrowserWindowController.open.isEmpty { openFirstWindow(preferred: UserDefaults.standard.string(forKey: "lastFolder")) }
        return true
    }

    private var statusMenu: StatusMenu?
    private var openedWithItems = false

    /// Items dropped on the Dock icon (or "Open With > PhotoLab" in Finder): a folder opens in a
    /// new window; files open their folder in a new window with them selected. Checking which is
    /// which touches the disk, so it runs in the background.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openedWithItems = true
        sender.reply(toOpenOrPrint: .success)
        Log.info("open from Finder/Dock: \(filenames.count) item(s)")
        DispatchQueue.global(qos: .userInitiated).async {
            var folders: [String] = []
            var files: [String: [String]] = [:]
            for p in filenames {
                var st = stat()
                if stat(p, &st) == 0 && UInt32(st.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) && !FileEntry.packageExtensions.contains(FileOperations.split(Paths.name(p)).ext.lowercased()) {
                    folders.append(p)
                } else {
                    files[Paths.parent(p), default: []].append(Paths.name(p))
                }
            }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let sheet = UserDefaults.standard.bool(forKey: "dropsOpenInSheet")
                for f in folders { let c = BrowserWindowController.openWindow(at: f); c.setMode(sheet ? .sheet : .list, remember: false) }
                for (dir, names) in files.sorted(by: { $0.key < $1.key }) {
                    let c = BrowserWindowController.openWindow(at: dir, select: names)
                    c.setMode(sheet ? .sheet : .list, remember: false)
                }
            }
        }
    }

    @objc private func volumesChanged(_ n: Notification) {
        Log.info("volumes changed: \(n.name.rawValue)")
        DispatchQueue.global(qos: .userInitiated).async {
            Volumes.refresh()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .volumesChanged, object: nil)
            }
        }
    }

    // MARK: Menu

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        menu.addItem(i)
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let holder = NSMenuItem()
        main.addItem(holder)
        let m = NSMenu(title: title)
        holder.submenu = m
        return m
    }

    private func buildMenu() {
        let main = NSMenu()
        let up = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
        let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))

        let app = submenu(main, "PhotoLab")
        item(app, "About PhotoLab 2", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(NSMenuItem.separator())
        item(app, "Settings...", #selector(showSettings(_:)), ",", [.command], target: self)
        app.addItem(NSMenuItem.separator())
        item(app, "Hide PhotoLab", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(NSMenuItem.separator())
        item(app, "Quit PhotoLab 2", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(main, "File")
        item(file, "New Window", #selector(newWindow(_:)), "n", [.command], target: self)
        item(file, "New Folder", #selector(BrowserWindowController.newFolder(_:)), "n", [.command, .shift])
        item(file, "Open", #selector(BrowserWindowController.openSelected(_:)), down)
        // Cmd-O opens too (hidden: the key works, the menu shows Cmd-Down).
        let cmdO = NSMenuItem(title: "Open", action: #selector(BrowserWindowController.openSelected(_:)), keyEquivalent: "o")
        cmdO.isHidden = true
        cmdO.allowsKeyEquivalentWhenHidden = true
        file.addItem(cmdO)
        item(file, "Open in New Window", #selector(BrowserWindowController.openInNewWindow(_:)), down, [.command, .option])
        item(file, "Show in Finder", #selector(BrowserWindowController.revealInFinder(_:)), "r", [.command, .shift])
        item(file, "Add to Sidebar", #selector(BrowserWindowController.addToSidebar(_:)), "t", [.command, .control])
        item(file, "Get Info", #selector(BrowserWindowController.getInfo(_:)), "i")
        item(file, "Rename", #selector(BrowserWindowController.renameSelected(_:)), "", [])
        item(file, "Duplicate", #selector(BrowserWindowController.duplicate(_:)), "d")
        file.addItem(NSMenuItem.separator())
        item(file, "Move to Trash", #selector(BrowserWindowController.moveToTrash(_:)), String(Character(UnicodeScalar(8))))
        file.addItem(NSMenuItem.separator())
        item(file, "Eject", #selector(BrowserWindowController.ejectVolume(_:)))
        file.addItem(NSMenuItem.separator())
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu(main, "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(NSMenuItem.separator())
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Move Items Here", #selector(BrowserWindowController.pasteMoving(_:)), "v", [.command, .option])
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        item(edit, "Filter...", #selector(BrowserWindowController.showFilter(_:)), "f")
        edit.addItem(NSMenuItem.separator())
        item(edit, "Copy Path", #selector(BrowserWindowController.copyPaths(_:)), "c", [.command, .option])

        let view = submenu(main, "View")
        item(view, "Show Sidebar", #selector(toggleSidebarMenu(_:)), "s", [.command, .option], target: self)
        view.addItem(NSMenuItem.separator())
        item(view, "as List", #selector(BrowserWindowController.showAsList(_:)), "1")
        item(view, "as Contact Sheet", #selector(BrowserWindowController.showAsSheet(_:)), "2")
        view.addItem(NSMenuItem.separator())
        item(view, "Show Hidden Files", #selector(BrowserWindowController.toggleHidden(_:)), ".", [.command, .shift])
        item(view, "Keep Folders on Top", #selector(BrowserWindowController.toggleFoldersFirst(_:)))
        item(view, "Show Folders Only", #selector(BrowserWindowController.toggleFoldersOnly(_:)))
        view.addItem(NSMenuItem.separator())
        item(view, "Refresh", #selector(BrowserWindowController.refresh(_:)), "r")
        // Cmd-/ also refreshes (PhotoLab 1's key); hidden from the menu, the key still works.
        let slash = NSMenuItem(title: "Refresh", action: #selector(BrowserWindowController.refresh(_:)), keyEquivalent: "/")
        slash.isHidden = true
        slash.allowsKeyEquivalentWhenHidden = true
        view.addItem(slash)

        let go = submenu(main, "Go")
        item(go, "Back", #selector(BrowserWindowController.goBack(_:)), "[")
        item(go, "Forward", #selector(BrowserWindowController.goForward(_:)), "]")
        item(go, "Enclosing Folder", #selector(BrowserWindowController.goEnclosingFolder(_:)), up)
        go.addItem(NSMenuItem.separator())
        item(go, "Computer", #selector(BrowserWindowController.goComputer(_:)), "c", [.command, .shift])
        item(go, "Home", #selector(BrowserWindowController.goHome(_:)), "h", [.command, .shift])
        item(go, "Volumes", #selector(BrowserWindowController.goVolumes(_:)), "v", [.command, .shift])
        go.addItem(NSMenuItem.separator())
        item(go, "Go to Folder...", #selector(BrowserWindowController.goToFolder(_:)), "g", [.command, .shift])
        item(go, "Network / Connect to Server...", #selector(BrowserWindowController.connectToServer(_:)), "k")

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        item(help, "Run Self-Test", #selector(runSelfTest(_:)), "", [], target: self)
        item(help, "Short Report", #selector(shortReport(_:)), "", [], target: self)
        item(help, "Save Report...", #selector(saveReport(_:)), "", [], target: self)
        item(help, "Show Logs Folder", #selector(showLogs(_:)), "", [], target: self)

        NSApp.mainMenu = main
    }

    // MARK: Sidebar shortcut

    private var keyMonitor: Any?

    /// Cmd-Option shortcuts are caught here by physical key, before the menu: the menu key
    /// equivalent alone did not fire on the lab's Macs (0.1.5; Option changes the typed character
    /// on some keyboard layouts).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == [.command, .option], let me = self else { return e }
            switch e.keyCode {
            case 1:  me.toggleSidebarMenu(nil); return nil                  // S
            case 8:  me.keyBrowser?.copyPaths(nil); return nil              // C
            case 9:  me.keyBrowser?.pasteMoving(nil); return nil          // V
            default: return e
            }
        }
    }

    private var keyBrowser: BrowserWindowController? {
        return (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
    }

    @objc private func toggleSidebarMenu(_ sender: Any?) {
        keyBrowser?.toggleSidebar(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSidebarMenu(_:)) {
            guard let b = keyBrowser else { return false }
            item.title = b.isSidebarShown ? "Hide Sidebar" : "Show Sidebar"
        }
        return true
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindow.show()
    }

    @objc private func newWindow(_ sender: Any?) {
        let start = (NSApp.keyWindow?.windowController as? BrowserWindowController)?.currentPath ?? NSHomeDirectory()
        BrowserWindowController.openWindow(at: start)
    }

    // MARK: Help actions

    @objc private func runSelfTest(_ sender: Any?) {
        Log.info("self-test started from the Help menu")
        DispatchQueue.global(qos: .userInitiated).async {
            let results = SelfTestRunner.runAll()
            for r in results { Log.info(r.line) }
            DispatchQueue.main.async {
                let failed = results.filter { $0.status == .fail }.count
                let title = failed == 0 ? "Self-Test passed" : "Self-Test: \(failed) failed"
                ReportWindow.show(title: title, text: results.map { $0.line }.joined(separator: "\n"))
            }
        }
    }

    /// About ten lines with no paths or names: safe to retype from an air-gapped Mac.
    @objc private func shortReport(_ sender: Any?) {
        let text = Stats.shortReport(version: AppDelegate.appVersion, brain: BrowserWindowController.brainText)
        Log.info("short report shown")
        ReportWindow.show(title: "Short Report", text: text)
    }

    @objc private func saveReport(_ sender: Any?) {
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "PhotoLab-report-\(f.string(from: Date())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let err = AppFiles.saveReport(to: url.path) {
            Log.error("E-REPORT-1 report not saved: \(err)")
            let a = NSAlert()
            a.messageText = "The report could not be saved"
            a.informativeText = err
            a.runModal()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func showLogs(_ sender: Any?) {
        AppFiles.ensureDirectories()
        NSWorkspace.shared.open(URL(fileURLWithPath: AppFiles.logsDir))
    }
}
