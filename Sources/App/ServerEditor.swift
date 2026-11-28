// ServerEditor.swift
// Add / edit a saved server (sidebar > Servers): name, address, account, password (Keychain), and
// whether it connects when Find starts.

import AppKit

enum ServerEditor {
    /// Returns the saved entry, or nil when cancelled. The password (if typed) goes to the Keychain here.
    static func run(_ existing: SavedServer?, prefill: SavedServer?) -> SavedServer? {
        let base = existing ?? prefill
        let a = ThemedAlert()
        a.messageText = existing == nil ? "Add a Server" : "Edit \u{201C}\(existing!.name)\u{201D}"
        a.informativeText = "The server stays in the sidebar when it isn't connected. Click it to connect. The password is kept in the macOS Keychain (the same place Finder keeps server passwords)."
        a.addButton(withTitle: existing == nil ? "Add" : "Save")
        a.addButton(withTitle: "Cancel")

        let name = NSTextField(string: base?.name ?? "")
        let address = NSTextField(string: base?.address ?? "")
        address.placeholderString = "\\\\192.168.1.10\\Share   smb://server/share   ftp://192.168.1.20"
        let user = NSTextField(string: base?.user ?? "")
        user.placeholderString = "account name (empty: ask, or guest)"
        let pass = NSSecureTextField(string: "")
        pass.placeholderString = existing != nil && !(existing!.user.isEmpty) ? "(unchanged)" : "password"
        let auto = NSButton(checkboxWithTitle: "Connect when PhotoLab starts (not for each new window; skipped if already connected)", target: nil, action: nil)
        auto.state = (base?.autoConnect ?? false) ? .on : .off
        let rows: [(String, NSView)] = [("Name", name), ("Address", address), ("Account", user), ("Password", pass)]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (t, f) in rows {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let r = NSStackView(views: [l, f])
            r.orientation = .horizontal
            r.spacing = 8
            stack.addArrangedSubview(r)
        }
        stack.addArrangedSubview(auto)
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 150)
        a.accessoryView = stack
        a.window.initialFirstResponder = base == nil ? address : name

        while true {
            if a.runModal() != .alertFirstButtonReturn { return nil }
            let addr = address.stringValue.trimmingCharacters(in: .whitespaces)
            guard let parsed = NetworkAddress.parse(addr) else {
                problem("That isn't a network address", "Type it like \\\\192.168.1.10\\Shoots or smb://server/share.")
                continue
            }
            if auto.state == .on && parsed.scheme == "ftp" {
                problem("Not for FTP", "FTP servers open in their own PhotoLab window when you click them; there is nothing to connect when PhotoLab starts. Untick \u{201C}Connect when PhotoLab starts\u{201D}.")
                continue
            }
            if auto.state == .on && parsed.share == nil {
                problem("Which shared folder?", "To connect when PhotoLab starts, the address needs the shared folder too, e.g. \\\\\(parsed.host)\\Shoots.")
                continue
            }
            var s = existing ?? SavedServer(id: UUID().uuidString, name: "", address: "", user: "", autoConnect: false)
            let n = name.stringValue.trimmingCharacters(in: .whitespaces)
            s.name = n.isEmpty ? SavedServer.suggestedName(for: addr) : n
            s.address = addr
            s.user = user.stringValue.trimmingCharacters(in: .whitespaces)
            s.autoConnect = auto.state == .on
            if !pass.stringValue.isEmpty {
                if s.user.isEmpty {
                    problem("Which account?", "A password is saved for an account name: type the account too.")
                    continue
                }
                if let err = ServerKeychain.save(pass.stringValue, host: parsed.host, user: s.user, scheme: parsed.scheme) {
                    problem("The password was not saved", err)
                    continue
                }
                App.log.info("Password for \(s.user) on \(parsed.host) saved in the Keychain")
            }
            return s
        }
    }

    private static func problem(_ title: String, _ text: String) {
        let a = ThemedAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}


/// Adding, changing and removing saved servers: the same steps from the sidebar and from Settings.
enum ServerActions {
    @discardableResult
    static func add(prefill: SavedServer?) -> SavedServer? {
        guard let s = ServerEditor.run(nil, prefill: prefill) else { return nil }
        Prefs.savedServers = Prefs.savedServers + [s]
        App.log.info("Server saved: \(s.name) \(Ascii.clean(s.address))\(s.autoConnect ? " (connects when PhotoLab starts)" : "")")
        return s
    }

    static func edit(_ old: SavedServer) {
        guard let s = ServerEditor.run(old, prefill: nil) else { return }
        Prefs.savedServers = Prefs.savedServers.map { $0.id == s.id ? s : $0 }
        App.log.info("Server changed: \(s.name) \(Ascii.clean(s.address))\(s.autoConnect ? " (connects when PhotoLab starts)" : "")")
    }

    static func setAutoConnect(_ id: String, _ on: Bool) {
        Prefs.savedServers = Prefs.savedServers.map { var x = $0; if x.id == id { x.autoConnect = on }; return x }
        if let s = Prefs.savedServers.first(where: { $0.id == id }) {
            App.log.info("Server \(s.name): connect when PhotoLab starts \(on ? "ON" : "OFF")")
        }
    }

    static func remove(_ s: SavedServer) {
        let a = ThemedAlert()
        a.messageText = "Remove \u{201C}\(s.name)\u{201D} from the saved servers?"
        a.informativeText = "Only the saved entry is removed: the server and its files are not touched, and a connected share stays connected."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        let forget = NSButton(checkboxWithTitle: "Also delete its saved password from the Keychain", target: nil, action: nil)
        if !s.user.isEmpty { a.accessoryView = forget }
        if a.runModal() != .alertFirstButtonReturn { return }
        if forget.state == .on, let p = s.parsed { ServerKeychain.delete(host: p.host, user: s.user, scheme: p.scheme) }
        Prefs.savedServers = Prefs.savedServers.filter { $0.id != s.id }
        App.log.info("Server removed: \(s.name)")
    }
}
