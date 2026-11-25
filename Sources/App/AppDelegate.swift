// AppDelegate.swift
// Phase 0: one window that shows the brain's state, plus Help > Run Self-Test / Save Report.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "Brain: not started")
    private let versionLabel = NSTextField(labelWithString: "")
    private var brain: BrainClient!

    static var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFiles.ensureDirectories()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.info("PhotoLab \(AppDelegate.appVersion) starting, \(BrainClient.archName), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        buildMenu()
        buildWindow()
        brain = BrainClient(socketPath: AppFiles.brainSocketPath)
        brain.onStateChange = { [weak self] s in self?.statusLabel.stringValue = s.text }
        brain.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        brain?.stop()
        Log.info("PhotoLab quitting")
        Log.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: UI

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PhotoLab 2"
        let content = NSView()
        window.contentView = content
        let title = NSTextField(labelWithString: "PhotoLab 2 - Phase 0 skeleton")
        title.font = NSFont.boldSystemFont(ofSize: 15)
        versionLabel.stringValue = "Version \(AppDelegate.appVersion) - \(BrainClient.archName)"
        versionLabel.textColor = NSColor.secondaryLabelColor
        for v in [title, versionLabel, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            versionLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            versionLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About PhotoLab 2", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit PhotoLab 2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let run = helpMenu.addItem(withTitle: "Run Self-Test", action: #selector(runSelfTest(_:)), keyEquivalent: "")
        run.target = self
        let report = helpMenu.addItem(withTitle: "Save Report...", action: #selector(saveReport(_:)), keyEquivalent: "")
        report.target = self
        let logs = helpMenu.addItem(withTitle: "Show Logs Folder", action: #selector(showLogs(_:)), keyEquivalent: "")
        logs.target = self
        helpItem.submenu = helpMenu

        NSApp.mainMenu = main
    }

    // MARK: Help actions

    @objc private func runSelfTest(_ sender: Any?) {
        statusLabel.stringValue = "Running self-test..."
        DispatchQueue.global(qos: .userInitiated).async {
            let results = SelfTestRunner.runAll()
            for r in results { Log.info(r.line) }
            DispatchQueue.main.async {
                self.statusLabel.stringValue = self.brain.state.text
                let alert = NSAlert()
                let failed = results.filter { $0.status == .fail }.count
                alert.messageText = failed == 0 ? "Self-test passed" : "Self-test: \(failed) failed"
                alert.informativeText = results.map { $0.line }.joined(separator: "\n")
                alert.runModal()
            }
        }
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
