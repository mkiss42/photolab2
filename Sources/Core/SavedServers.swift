// SavedServers.swift
// Servers saved in the sidebar (0.13): they stay listed when not connected, can connect when Find starts,
// and their passwords live in the macOS Keychain (never in Find's files). Pure Foundation, tested on Linux.

import Foundation

struct SavedServer: Codable, Equatable {
    var id: String
    /// Shown in the sidebar (defaults to the share's name).
    var name: String
    /// As typed: \\server\share, smb://server/share, 192.168.1.10\Share ...
    var address: String
    /// Account name for the server ("" = macOS asks / guest / the keychain decides).
    var user: String
    /// Connect when Find starts (once per start of Find - not for each new window).
    var autoConnect: Bool

    var parsed: NetworkAddress? { return NetworkAddress.parse(address) }

    static func == (a: SavedServer, b: SavedServer) -> Bool {
        return a.id == b.id && a.name == b.name && a.address == b.address && a.user == b.user && a.autoConnect == b.autoConnect
    }

    /// The address to mount, with the account name when one is saved.
    var mountURL: String? {
        guard var a = parsed else { return nil }
        if !user.isEmpty { a.user = user }
        return a.mountURL
    }

    /// Name suggested for a new entry: the share, or the server.
    static func suggestedName(for address: String) -> String {
        guard let a = NetworkAddress.parse(address) else { return address }
        if let s = a.share, !(s.isEmpty && a.subpath.isEmpty) { return a.subpath.isEmpty ? s : a.subpath.last! }
        return a.host
    }
}

enum ServerList {
    static func decode(_ json: String) -> [SavedServer] {
        guard let d = json.data(using: .utf8), let list = try? JSONDecoder().decode([SavedServer].self, from: d) else { return [] }
        return list
    }

    static func encode(_ list: [SavedServer]) -> String {
        guard let d = try? JSONEncoder().encode(list), let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Where a saved server is mounted now (its /Volumes path, plus any folders typed after the share),
    /// from the cached volume list: (path to open, volume root). nil = not connected.
    static func mountedPath(_ s: SavedServer, volumes: [VolumeRecord]) -> (open: String, root: String)? {
        guard let a = s.parsed, a.share != nil else { return nil }
        guard let r = ShareMatch.find(host: a.host, share: a.share!, scheme: a.scheme, in: volumes) else { return nil }
        return (a.subpath.reduce(r) { Paths.join($0, $1) }, r)
    }

    /// Servers to connect when Find starts: marked "connect when Find starts", a share given, and not
    /// mounted already (by Find, Finder or anything else).
    static func toAutoConnect(_ list: [SavedServer], volumes: [VolumeRecord]) -> [SavedServer] {
        // FTP servers open in Find's FTP window when clicked: never mounted at start.
        return list.filter { $0.autoConnect && $0.parsed?.share != nil && $0.parsed?.scheme != "ftp" && mountedPath($0, volumes: volumes) == nil }
    }

    /// A saved entry for a mounted share (sidebar "Save as Server"), from its reconnect address.
    static func entry(forMounted v: VolumeRecord) -> SavedServer? {
        guard !v.isLocal, let u = v.remountURL, let a = NetworkAddress.parse(u) else { return nil }
        var plain = a
        plain.user = nil
        return SavedServer(id: UUID().uuidString, name: v.name, address: plain.display, user: a.user ?? "", autoConnect: false)
    }
}

/// Sidebar order by dragging (0.14). Pure list logic, tested on Linux.
enum SidebarOrder {
    /// Move the item at `from` so it lands before the item now at `to` (`to` == count: the end).
    static func move<T>(_ list: [T], from: Int, to: Int) -> [T] {
        guard from >= 0, from < list.count, to >= 0, to <= list.count, to != from, to != from + 1 else { return list }
        var l = list
        let x = l.remove(at: from)
        l.insert(x, at: to > from ? to - 1 : to)
        return l
    }

    /// Items in the saved order; items not in it (new drives, new shares) keep their place after them.
    static func apply(_ items: [String], order: [String]) -> [String] {
        let known = order.filter { items.contains($0) }
        return known + items.filter { !known.contains($0) }
    }
}
