// SettingsWindow.swift
// PhotoLab > Settings (Cmd-,). Grows one option at a time; every value lives in UserDefaults.

import AppKit

final class SettingsWindow: NSWindowController {
    private static var shared: SettingsWindow?
    private let pathBarBottom = NSButton(checkboxWithTitle: "Path bar below the list (instead of above)", target: nil, action: nil)
    private let dropsInSheet = NSButton(checkboxWithTitle: "Folders and files dropped on the app icon open in the contact sheet (instead of the list)", target: nil, action: nil)
    private let fileSets = NSButton(checkboxWithTitle: "Treat raw + jpg + xmp with the same name as one set (one row; rename, copy and Trash all of them)", target: nil, action: nil)

    static func show() {
        let w = shared ?? SettingsWindow()
        shared = w
        w.refresh()
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        super.init(window: win)

        let title = NSTextField(labelWithString: "Browser windows")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        pathBarBottom.target = self
        pathBarBottom.action = #selector(changed(_:))
        fileSets.target = self
        fileSets.action = #selector(changed(_:))
        dropsInSheet.target = self
        dropsInSheet.action = #selector(changed(_:))
        let filesTitle = NSTextField(labelWithString: "Files")
        filesTitle.font = NSFont.boldSystemFont(ofSize: 13)
        let stack = NSStackView(views: [title, pathBarBottom, dropsInSheet, filesTitle, fileSets])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        win.contentView = stack
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        pathBarBottom.state = BrowserWindowController.pathBarAtBottom ? .on : .off
        fileSets.state = FileOperations.useSets ? .on : .off
        dropsInSheet.state = UserDefaults.standard.bool(forKey: "dropsOpenInSheet") ? .on : .off
    }

    @objc private func changed(_ sender: Any?) {
        if (sender as? NSButton) === dropsInSheet {
            UserDefaults.standard.set(dropsInSheet.state == .on, forKey: "dropsOpenInSheet")
            return
        }
        if (sender as? NSButton) === fileSets {
            FileOperations.useSets = fileSets.state == .on
            Log.info("setting: file sets \(FileOperations.useSets ? "on" : "off")")
            for c in BrowserWindowController.open { c.reapply() }      // one row per set, or not
            return
        }
        BrowserWindowController.pathBarAtBottom = pathBarBottom.state == .on
        Log.info("setting: path bar \(BrowserWindowController.pathBarAtBottom ? "below" : "above") the list")
        NotificationCenter.default.post(name: .layoutSettingsChanged, object: nil)
    }
}
