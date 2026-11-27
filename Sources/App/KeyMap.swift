// KeyMap.swift
// 0.16: custom keys (Settings > Keys).
// - Menu commands: any command in Find's menus can get your own shortcut (or none). Recorded by
//   pressing it; a shortcut already used by another command is offered to move over (that one then
//   has none). Saved as e.g. "@~k" (@ Cmd, ~ Option, ^ Control, $ Shift + the key).
// - Photography mode: which modifier sets stars and which sets colour classes (number keys).
// Keys that aren't menu commands (Space, Tab, arrows, Return, Delete in lists) keep their usual jobs.

import AppKit

enum KeyMap {
    /// Every command found in the menus: id -> (menu path, default shortcut).
    private(set) static var commands: [(id: String, title: String, defaultKey: String)] = []

    static func spec(_ key: String, _ mask: NSEvent.ModifierFlags) -> String {
        if key.isEmpty { return "" }
        var s = ""
        if mask.contains(.control) { s += "^" }
        if mask.contains(.option) { s += "~" }
        if mask.contains(.shift) { s += "$" }
        if mask.contains(.command) { s += "@" }
        return s + key.lowercased()
    }

    static func parse(_ spec: String) -> (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        var rest = Substring(spec)
        while let c = rest.first, "^~$@".contains(c), rest.count > 1 {
            switch c {
            case "^": mask.insert(.control)
            case "~": mask.insert(.option)
            case "$": mask.insert(.shift)
            default: mask.insert(.command)
            }
            rest = rest.dropFirst()
        }
        return (String(rest), mask)
    }

    /// "⌃⌥⇧⌘K" for showing.
    static func display(_ spec: String) -> String {
        if spec.isEmpty { return "\u{2014}" }
        let p = parse(spec)
        var s = ""
        if p.mask.contains(.control) { s += "\u{2303}" }
        if p.mask.contains(.option) { s += "\u{2325}" }
        if p.mask.contains(.shift) { s += "\u{21E7}" }
        if p.mask.contains(.command) { s += "\u{2318}" }
        let names: [String: String] = ["\r": "Return", "\u{7F}": "Delete", "\u{1B}": "Esc", "\t": "Tab", " ": "Space",
                                       "\u{F700}": "\u{2191}", "\u{F701}": "\u{2193}", "\u{F702}": "\u{2190}", "\u{F703}": "\u{2192}",
                                       "\u{F728}": "\u{2326}", "\u{F729}": "Home", "\u{F72B}": "End", "\u{F72C}": "Page Up", "\u{F72D}": "Page Down"]
        let k = p.key
        if let n = names[k] { return s + n }
        if let u = k.unicodeScalars.first, u.value >= 0xF704 && u.value <= 0xF70F { return s + "F\(u.value - 0xF704 + 1)" }
        return s + k.uppercased()
    }

    private static func id(_ item: NSMenuItem) -> String? {
        guard let a = item.action else { return nil }
        return NSStringFromSelector(a) + (item.tag != 0 ? "#\(item.tag)" : "")
    }

    /// Learn the commands and their built-in shortcuts from the menus (once), then apply custom keys.
    static func apply(to menu: NSMenu?) {
        guard let m = menu else { return }
        if commands.isEmpty {
            var seen = Set<String>()
            func walk(_ m: NSMenu, _ path: String) {
                for i in m.items {
                    if let sub = i.submenu { walk(sub, path.isEmpty ? i.title : path + " \u{203A} " + i.title); continue }
                    guard let k = id(i), !i.title.isEmpty, !seen.contains(k) else { continue }
                    seen.insert(k)
                    commands.append((k, (path.isEmpty ? "" : path + " \u{203A} ") + i.title, spec(i.keyEquivalent, i.keyEquivalentModifierMask)))
                }
            }
            walk(m, "")
        }
        let custom = Prefs.customKeys
        var done = Set<String>()
        func set(_ m: NSMenu) {
            for i in m.items {
                if let sub = i.submenu { set(sub); continue }
                // Only the first item of a command is listed and changed (a second one keeps its own).
                guard let k = id(i), !done.contains(k), let c = commands.first(where: { $0.id == k }) else { continue }
                done.insert(k)
                let p = parse(custom[k] ?? c.defaultKey)
                i.keyEquivalent = p.key
                i.keyEquivalentModifierMask = p.mask
            }
        }
        set(m)
    }

    static func current(_ id: String) -> String {
        return Prefs.customKeys[id] ?? commands.first(where: { $0.id == id })?.defaultKey ?? ""
    }

    /// The command that has this shortcut now (other than `except`).
    static func owner(of spec: String, except: String) -> String? {
        guard !spec.isEmpty else { return nil }
        return commands.first(where: { $0.id != except && current($0.id) == spec })?.id
    }

    static func setKey(_ id: String, _ spec: String?) {
        var c = Prefs.customKeys
        c[id] = spec
        Prefs.customKeys = c
        apply(to: NSApp.mainMenu)
    }
}

// MARK: - Settings > Keys

final class KeysSettingsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 600))
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let recordButton = NSButton(title: "Record Shortcut", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let starPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colourPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?
    static let starChoices = [("ctrl", "Control + 0-5 (plain 0-5 too)"), ("plain", "0-5 alone"), ("opt", "Option + 0-5"), ("shift", "Shift + 0-5")]
    static let colourChoices = [("cmd", "Command + 0-8"), ("ctrl", "Control + 0-8"), ("opt", "Option + 0-8")]

    override init() {
        super.init()
        for (id, title, width) in [("cmd", "Command", 430), ("key", "Shortcut", 130), ("def", "Built in", 110)] as [(String, String, CGFloat)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(record(_:))
        table.target = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        recordButton.target = self
        recordButton.action = #selector(record(_:))
        let clear = NSButton(title: "No Shortcut", target: self, action: #selector(clearKey(_:)))
        let reset = NSButton(title: "Built-in Shortcut", target: self, action: #selector(resetKey(_:)))
        let resetAll = NSButton(title: "All to Built-in", target: self, action: #selector(resetAll(_:)))
        hint.stringValue = "Select a command, then Record Shortcut (or double-click) and press the keys. Esc cancels. Space, Tab, arrows, Return and Delete in the lists keep their usual jobs."
        hint.textColor = NSColor.secondaryLabelColor
        for (k, t) in KeysSettingsController.starChoices { starPopup.addItem(withTitle: t); starPopup.lastItem?.representedObject = k }
        for (k, t) in KeysSettingsController.colourChoices { colourPopup.addItem(withTitle: t); colourPopup.lastItem?.representedObject = k }
        starPopup.target = self
        starPopup.action = #selector(photoKeysChanged(_:))
        colourPopup.target = self
        colourPopup.action = #selector(photoKeysChanged(_:))
        let buttons = NSStackView(views: [recordButton, clear, reset, resetAll])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let photo = NSStackView(views: [NSTextField(labelWithString: "Photography: stars"), starPopup,
                                        NSTextField(labelWithString: "colour classes"), colourPopup])
        photo.orientation = .horizontal
        photo.spacing = 8
        for v in [scroll, buttons, hint, photo] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            photo.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            photo.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: photo.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.widthAnchor.constraint(equalToConstant: 680),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    func refresh() {
        table.reloadData()
        starPopup.selectItem(at: KeysSettingsController.starChoices.index(where: { $0.0 == Prefs.starModifier }) ?? 0)
        colourPopup.selectItem(at: KeysSettingsController.colourChoices.index(where: { $0.0 == Prefs.colourModifier }) ?? 0)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { return KeyMap.commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < KeyMap.commands.count else { return nil }
        let c = KeyMap.commands[row]
        let tf = NSTextField(labelWithString: "")
        switch col.identifier.rawValue {
        case "cmd": tf.stringValue = c.title
        case "key":
            let cur = KeyMap.current(c.id)
            tf.stringValue = KeyMap.display(cur)
            if cur != c.defaultKey { tf.font = NSFont.boldSystemFont(ofSize: 13) }
        default:
            tf.stringValue = KeyMap.display(c.defaultKey)
            tf.textColor = NSColor.secondaryLabelColor
        }
        tf.lineBreakMode = .byTruncatingMiddle
        return tf
    }

    private var selectedID: String? {
        let r = table.selectedRow
        return r >= 0 && r < KeyMap.commands.count ? KeyMap.commands[r].id : nil
    }

    @objc private func record(_ sender: Any?) {
        guard let id = selectedID else { NSSound.beep(); return }
        stopRecording()
        recordButton.title = "Press the keys"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let s = self else { return e }
            s.stopRecording()
            if e.keyCode == 53 { return nil }   // Esc: cancel
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = (e.charactersIgnoringModifiers ?? "").lowercased()
            guard !key.isEmpty else { return nil }
            if mods.isEmpty || mods == .shift {
                CopyQueueUI.message("Add Command, Control or Option", "A shortcut needs Command, Control or Option (or a function key) so it doesn't get in the way of typing.")
                return nil
            }
            let spec = KeyMap.spec(key, mods)
            if let other = KeyMap.owner(of: spec, except: id) {
                let otherTitle = KeyMap.commands.first(where: { $0.id == other })?.title ?? other
                let a = ThemedAlert()
                a.messageText = "\(KeyMap.display(spec)) is used by \u{201C}\(otherTitle)\u{201D}"
                a.informativeText = "Move it here? \u{201C}\(otherTitle)\u{201D} then has no shortcut."
                a.addButton(withTitle: "Cancel")
                a.addButton(withTitle: "Move It Here")
                guard a.runModal() == .alertSecondButtonReturn else { return nil }
                KeyMap.setKey(other, "")
            }
            KeyMap.setKey(id, spec)
            App.log.info("Keys: \(id) = \(spec)")
            s.table.reloadData()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recordButton.title = "Record Shortcut"
    }

    @objc private func clearKey(_ sender: Any?) {
        guard let id = selectedID else { return }
        KeyMap.setKey(id, "")
        table.reloadData()
    }

    @objc private func resetKey(_ sender: Any?) {
        guard let id = selectedID else { return }
        if let d = KeyMap.commands.first(where: { $0.id == id })?.defaultKey, let other = KeyMap.owner(of: d, except: id) {
            KeyMap.setKey(other, "")
        }
        KeyMap.setKey(id, nil)
        table.reloadData()
    }

    @objc private func resetAll(_ sender: Any?) {
        Prefs.customKeys = [:]
        KeyMap.apply(to: NSApp.mainMenu)
        table.reloadData()
        App.log.info("Keys: all built-in")
    }

    @objc private func photoKeysChanged(_ sender: Any?) {
        let star = starPopup.selectedItem?.representedObject as? String ?? "ctrl"
        let colour = colourPopup.selectedItem?.representedObject as? String ?? "cmd"
        if star == colour {
            CopyQueueUI.message("Two jobs on the same keys", "Stars and colour classes need different keys. Nothing was changed.")
            refresh()
            return
        }
        Prefs.starModifier = star
        Prefs.colourModifier = colour
        App.log.info("Keys: Photography stars \(star), colour classes \(colour)")
    }
}
