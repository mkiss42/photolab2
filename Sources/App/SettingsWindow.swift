// SettingsWindow.swift
// PhotoLab > Settings (Cmd-,). Grows one option at a time; every value lives in UserDefaults.

import AppKit

final class SettingsWindow: NSWindowController {
    private static var shared: SettingsWindow?
    private let pathBarBottom = NSButton(checkboxWithTitle: "Path bar below the list (instead of above)", target: nil, action: nil)

    static func show() {
        let w = shared ?? SettingsWindow()
        shared = w
        w.refresh()
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 140),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        super.init(window: win)

        let title = NSTextField(labelWithString: "Browser windows")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        pathBarBottom.target = self
        pathBarBottom.action = #selector(changed(_:))
        let stack = NSStackView(views: [title, pathBarBottom])
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
    }

    @objc private func changed(_ sender: Any?) {
        BrowserWindowController.pathBarAtBottom = pathBarBottom.state == .on
        Log.info("setting: path bar \(BrowserWindowController.pathBarAtBottom ? "below" : "above") the list")
        NotificationCenter.default.post(name: .layoutSettingsChanged, object: nil)
    }
}
