// AppDelegate.swift
// Starts the brain and the first browser window; owns the menu bar.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var brain: BrainClient!

    static var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFiles.ensureDirectories()
        Log.info("PhotoLab \(AppDelegate.appVersion) starting, \(SystemInfo.summary)")
        FreezeWatchdog.start()
        Volumes.refresh()
        buildMenu()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            ws.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }

        let last = UserDefaults.standard.string(forKey: "lastFolder")
        openFirstWindow(preferred: last)

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
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
        item(file, "Open", #selector(BrowserWindowController.openSelected(_:)), down)
        file.addItem(NSMenuItem.separator())
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu(main, "Edit")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu(main, "View")
        item(view, "Show Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s", [.command, .option])
        view.addItem(NSMenuItem.separator())
        item(view, "Show Hidden Files", #selector(BrowserWindowController.toggleHidden(_:)), ".", [.command, .shift])
        item(view, "Keep Folders on Top", #selector(BrowserWindowController.toggleFoldersFirst(_:)))
        view.addItem(NSMenuItem.separator())
        item(view, "Refresh", #selector(BrowserWindowController.refresh(_:)), "r")

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
