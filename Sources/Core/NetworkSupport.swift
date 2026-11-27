// NetworkSupport.swift
// Phase 6: network-aware helpers that never touch the network themselves.
// - VolumeRegistry: which mounted volumes are network shares (and how to reconnect them), filled in the
//   background so the main thread never asks a possibly dead server anything.
// - ListingCache: short-lived memory of network folder listings. Coming back to a folder costs one stat
//   of the folder ("has it changed?") instead of reading it again. 2 minutes, 40 folders, memory only.

import Foundation

struct VolumeRecord {
    let name: String
    let path: String
    let isLocal: Bool
    let isRoot: Bool
    let isRemovable: Bool
    /// smb://... (or afp://...) to mount it again after a disconnection.
    let remountURL: String?
    /// Where it is mounted from, as the mount table says (e.g. "//anna@192.168.1.10/Shoots"); read
    /// without asking the server. 0.14.
    let source: String?

    init(name: String, path: String, isLocal: Bool, isRoot: Bool, isRemovable: Bool, remountURL: String?, source: String? = nil) {
        self.name = name
        self.path = path
        self.isLocal = isLocal
        self.isRoot = isRoot
        self.isRemovable = isRemovable
        self.remountURL = remountURL
        self.source = source
    }
}

/// Which mounted volume is a given server's share (0.14). macOS names the folder after the share, but
/// not always exactly ("Share-1" when /Volumes/Share was taken), and a share connected in Finder may be
/// known by the server's name rather than the address typed. Checked in order:
///  1. its reconnect address (same server and share);
///  2. the mount table's "mounted from" (same server and share);
///  3. the share's name (also "Name-1", "Name-2"...) - only if exactly one network volume has it, so a
///     share is never confused with a same-named share on another server.
enum ShareMatch {
    static func bareHost(_ h: String) -> String {
        var x = (h.split(separator: "@").last.map(String.init) ?? h).lowercased()
        if let c = x.index(of: ":") { x = String(x[x.startIndex..<c]) }
        for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", ".local"] where x.hasSuffix(suffix) {
            x = String(x.dropLast(suffix.count))
        }
        return x
    }

    /// "//user@host/share" (smbfs), "host:/export" (nfs), "afp_xxx" etc. -> (host, share).
    static func parseSource(_ src: String) -> (host: String, share: String)? {
        if src.hasPrefix("//") {
            let parts = src.dropFirst(2).split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let share = parts[1].removingPercentEncoding ?? parts[1]
            return (bareHost(parts[0]), share.split(separator: "/").first.map(String.init) ?? share)
        }
        if let u = NetworkAddress.parse(src), let sh = u.share { return (bareHost(u.host), sh) }
        return nil
    }

    static func nameMatches(_ folder: String, share: String) -> Bool {
        let f = folder.lowercased(), s = share.lowercased()
        if f == s { return true }
        guard f.hasPrefix(s + "-") else { return false }
        let tail = f.dropFirst(s.count + 1)
        return !tail.isEmpty && tail.count <= 3 && Int(tail) != nil
    }

    static func find(host: String, share: String, scheme: String, in volumes: [VolumeRecord]) -> String? {
        let shares = volumes.filter { !$0.isLocal && !$0.isRoot }
        let h = bareHost(host), sh = share.lowercased()
        if share.isEmpty {
            // FTP: the whole server. Its reconnect address or mount-table source names the server;
            // otherwise macOS names the folder after the server.
            for v in shares {
                for u in [v.remountURL, v.source].compactMap({ $0 }) {
                    if let o = NetworkAddress.parse(u), o.scheme == scheme, bareHost(o.host) == h { return v.path }
                }
            }
            let byName = shares.filter { nameMatches(Paths.lastComponent($0.path), share: h) }
            return byName.count == 1 ? byName[0].path : nil
        }
        for v in shares {
            if let u = v.remountURL, let o = NetworkAddress.parse(u), let os = o.share,
               o.scheme == scheme, bareHost(o.host) == h, os.lowercased() == sh { return v.path }
        }
        for v in shares {
            if let src = v.source, let p = parseSource(src), p.host == h, p.share.lowercased() == sh { return v.path }
        }
        // By name: only one candidate, and never one known to be on a different IP address.
        let byName = shares.filter { v in
            guard nameMatches(Paths.lastComponent(v.path), share: share) else { return false }
            if NetworkAddress.isIPv4(h) {
                let known = [v.remountURL.flatMap { NetworkAddress.parse($0)?.host }, v.source.flatMap { parseSource($0)?.host }]
                    .compactMap { $0 }.map { bareHost($0) }
                if known.contains(where: { NetworkAddress.isIPv4($0) && $0 != h }) { return false }
            }
            return true
        }
        return byName.count == 1 ? byName[0].path : nil
    }
}

final class VolumeRegistry {
    static let shared = VolumeRegistry()
    private let lock = NSLock()
    private var records: [VolumeRecord] = []
    private var filled = false

    /// All mounted volumes as last seen (never blocks).
    var volumes: [VolumeRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    var isFilled: Bool {
        lock.lock(); defer { lock.unlock() }
        return filled
    }

    func set(_ r: [VolumeRecord]) {
        lock.lock()
        records = r
        filled = true
        // Remember how to reconnect shares even after they disappear.
        for v in r where !v.isLocal { if let u = v.remountURL { remembered[v.path] = u } }
        lock.unlock()
    }

    private var remembered: [String: String] = [:]

    /// How to reconnect a share that is not mounted now (e.g. one a reopened window was showing).
    func remember(root: String, remountURL: String) {
        lock.lock(); defer { lock.unlock() }
        if remembered[root] == nil { remembered[root] = remountURL }
    }

    /// The volume a path is on: "/Volumes/Name" for anything below it, "/" otherwise.
    static func volumeRoot(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2 && parts[0] == "Volumes" { return "/Volumes/" + parts[1] }
        return "/"
    }

    /// true = network share, false = local, nil = not known (treat paths under /Volumes as network to be safe).
    func isNetwork(_ path: String) -> Bool? {
        let root = VolumeRegistry.volumeRoot(path)
        if root == "/" { return false }
        lock.lock(); defer { lock.unlock() }
        if let v = records.first(where: { $0.path == root }) { return !v.isLocal }
        return nil
    }

    /// Network, or unknown under /Volumes: don't do anything slow or chatty with it on the main thread.
    func treatAsNetwork(_ path: String) -> Bool {
        return isNetwork(path) ?? (VolumeRegistry.volumeRoot(path) != "/")
    }

    func isMounted(_ root: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return records.contains { $0.path == root }
    }

    func remountURL(_ path: String) -> String? {
        let root = VolumeRegistry.volumeRoot(path)
        lock.lock(); defer { lock.unlock() }
        return records.first(where: { $0.path == root })?.remountURL ?? remembered[root]
    }
}

/// Listing memory for network folders (0.12: "show at once, check in the background").
/// A remembered listing is shown immediately when you come back to a folder; the folder is read again in
/// the background and the list updated only if something changed. `lifetime`: how long a listing may be
/// shown that way (Settings > Network). Bounded by folders and by the total number of items.
final class ListingCache {
    static let shared = ListingCache()
    static var lifetime: Double = 600
    static let capacity = 300
    static let maxItems = 300_000

    private struct Slot {
        let stamp: Double        // folder modified time when read
        let inode: UInt64
        let result: FolderReadResult
        let time: Date
    }
    private var slots: [String: Slot] = [:]
    private let lock = NSLock()

    private func key(_ path: String, _ hidden: Bool) -> String { return (hidden ? "H:" : "V:") + path }

    /// A remembered listing, if younger than `lifetime` and the folder's stat still matches.
    /// `folderInfo` is the caller's fresh stat of the folder (one round trip).
    func get(_ path: String, includeHidden: Bool, folderInfo: StatInfo, now: Date = Date()) -> FolderReadResult? {
        lock.lock(); defer { lock.unlock() }
        guard let s = slots[key(path, includeHidden)] else { return nil }
        if now.timeIntervalSince(s.time) > ListingCache.lifetime || s.stamp != folderInfo.modified || s.inode != folderInfo.inode {
            slots[key(path, includeHidden)] = nil
            return nil
        }
        return s.result
    }

    func put(_ path: String, includeHidden: Bool, folderInfo: StatInfo, result: FolderReadResult, now: Date = Date()) {
        if result.folderError != nil || result.cancelled { return }
        lock.lock(); defer { lock.unlock() }
        slots[key(path, includeHidden)] = Slot(stamp: folderInfo.modified, inode: folderInfo.inode, result: result, time: now)
        changedSinceSave = true
        // Oldest out first, until within both limits.
        var total = slots.values.reduce(0) { $0 + $1.result.entries.count }
        while slots.count > ListingCache.capacity || (total > ListingCache.maxItems && slots.count > 1) {
            guard let oldest = slots.min(by: { $0.value.time < $1.value.time }) else { break }
            total -= oldest.value.result.entries.count
            slots[oldest.key] = nil
        }
    }

    /// The remembered listing, without asking the server anything (nil if none or older than `lifetime`).
    func peek(_ path: String, includeHidden: Bool, now: Date = Date()) -> FolderReadResult? {
        lock.lock(); defer { lock.unlock() }
        guard let s = slots[key(path, includeHidden)] else { return nil }
        if now.timeIntervalSince(s.time) > ListingCache.lifetime {
            slots[key(path, includeHidden)] = nil
            return nil
        }
        return s.result
    }

    /// Same items (name, kind, size, modified) - used to skip redrawing when nothing changed.
    static func sameListing(_ a: FolderReadResult, _ b: FolderReadResult) -> Bool {
        if a.entries.count != b.entries.count || (a.folderError == nil) != (b.folderError == nil) { return false }
        func sig(_ r: FolderReadResult) -> [String] {
            return r.entries.map { "\($0.name)|\($0.kind)|\($0.size)|\($0.modified)|\($0.added)" }.sorted()
        }
        return sig(a) == sig(b)
    }

    // MARK: Kept between launches (0.17.1)

    /// Something was remembered or forgotten since the last save.
    private(set) var changedSinceSave = false

    private struct SavedEntry: Codable {
        let n: String; let k: Int; let s: Int64; let m: Double; let c: Double; let h: Bool; let l: Bool
        let d: UInt64; let i: UInt64; let p: UInt32; let a: Double
    }
    private struct SavedSlot: Codable {
        let path: String; let hidden: Bool; let stamp: Double; let inode: UInt64; let time: Double; let entries: [SavedEntry]
    }

    /// The remembered listings as data (newest folders first, at most `maxItems` items in all), so
    /// coming back to a folder is instant also after Find was quit.
    func export(maxItems: Int = 120_000) -> Data? {
        lock.lock()
        let all = slots.sorted { $0.value.time > $1.value.time }
        changedSinceSave = false
        lock.unlock()
        var out: [SavedSlot] = []
        var total = 0
        for (k, v) in all {
            if total + v.result.entries.count > maxItems { continue }
            total += v.result.entries.count
            let es = v.result.entries.map { SavedEntry(n: $0.name, k: $0.kind.rawValue, s: $0.size, m: $0.modified, c: $0.created, h: $0.isHidden,
                                                       l: $0.linkToDirectory, d: $0.device, i: $0.inode, p: $0.permissions, a: $0.added) }
            out.append(SavedSlot(path: String(k.dropFirst(2)), hidden: k.hasPrefix("H:"), stamp: v.stamp, inode: v.inode,
                                 time: v.time.timeIntervalSince1970, entries: es))
        }
        return try? JSONEncoder().encode(out)
    }

    /// Bring back listings saved by `export` (ones older than `lifetime` are left out).
    @discardableResult
    func importSaved(_ data: Data, now: Date = Date()) -> Int {
        guard let saved = try? JSONDecoder().decode([SavedSlot].self, from: data) else { return 0 }
        var n = 0
        lock.lock(); defer { lock.unlock() }
        for sl in saved {
            let t = Date(timeIntervalSince1970: sl.time)
            if now.timeIntervalSince(t) > ListingCache.lifetime { continue }
            var r = FolderReadResult()
            r.entries = sl.entries.map { e in
                var f = FileEntry(name: e.n, path: Paths.join(sl.path, e.n), kind: EntryKind(rawValue: e.k) ?? .other, size: e.s,
                                  modified: e.m, created: e.c, isHidden: e.h, linkToDirectory: e.l, device: e.d, inode: e.i, permissions: e.p)
                f.added = e.a
                return f
            }
            slots[key(sl.path, sl.hidden)] = Slot(stamp: sl.stamp, inode: sl.inode, result: r, time: t)
            n += 1
        }
        return n
    }

    /// Cmd-R and Find's own changes: forget a folder.
    func forget(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        slots["H:" + path] = nil
        slots["V:" + path] = nil
        changedSinceSave = true
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        slots.removeAll()
        changedSinceSave = true
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return slots.count
    }
}

/// A network address typed in the path field, the way Windows Explorer takes them:
///   \\192.168.1.10\Shoots\2026     \\server\share     //server/share/sub
///   smb://server/share/sub          cifs://...  afp://server/share   nfs://server/export
///   192.168.1.10   192.168.1.10\Shoots   (a server name needs \\ or smb:// in front)
/// Anything else (a normal path, a folder name) is not an address.
struct NetworkAddress: Equatable {
    var scheme: String          // smb, afp, nfs or ftp ("cifs" becomes smb)
    var user: String?
    var host: String            // may include ":port"
    var share: String?          // the shared folder (nil: just the server - macOS asks which share;
                                // "" for FTP: the whole server, connected at its top folder)
    var subpath: [String]       // folders below the share

    /// What macOS mounts: scheme://[user@]host[/share].
    var mountURL: String {
        var u = scheme + "://"
        if let us = user, !us.isEmpty { u += (us.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? us) + "@" }
        u += host
        if let sh = share { u += "/" + (sh.addingPercentEncoding(withAllowedCharacters: NetworkAddress.pathPart) ?? sh) }
        return u
    }

    /// For messages and the log: \\server\share\sub for SMB, the URL otherwise.
    var display: String {
        if scheme == "smb" {
            var d = "\\\\" + host
            if let sh = share { d += "\\" + sh }
            for p in subpath { d += "\\" + p }
            return d
        }
        var d = mountURL
        for p in subpath { d += "/" + p }
        return d
    }

    private static var pathPart: CharacterSet {
        var c = CharacterSet.urlPathAllowed
        c.remove(charactersIn: "/")
        return c
    }

    static func parse(_ typed: String) -> NetworkAddress? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        if s.isEmpty { return nil }
        var scheme = "smb"
        var rest: String
        if let r = s.range(of: "://") {
            let sch = s[s.startIndex..<r.lowerBound].lowercased()
            switch sch {
            case "smb", "cifs": scheme = "smb"
            case "afp": scheme = "afp"
            case "nfs": scheme = "nfs"
            case "ftp": scheme = "ftp"
            default: return nil
            }
            rest = String(s[r.upperBound...])
        } else if s.hasPrefix("\\\\") || (s.hasPrefix("//") && !s.hasPrefix("///")) {
            rest = String(s.dropFirst(2))
        } else {
            // A bare server: only an IPv4 address (a name needs \\ or smb:// first, as in Explorer -
            // so a folder called "photos.local" is never mistaken for a server).
            let first = String(s.split(whereSeparator: { $0 == "/" || $0 == "\\" }).first ?? "")
            if s.hasPrefix("/") || s.hasPrefix("\\") || s.hasPrefix("~") || s.hasPrefix(".") { return nil }
            guard NetworkAddress.isIPv4(first) else { return nil }
            rest = s
        }
        let parts = rest.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard var authority = parts.first, !authority.isEmpty else { return nil }
        var user: String? = nil
        if let at = authority.index(of: "@") {
            user = String(authority[authority.startIndex..<at]).removingPercentEncoding
            authority = String(authority[authority.index(after: at)...])
        }
        let hostOnly = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !hostOnly.isEmpty, !hostOnly.unicodeScalars.contains(where: { !allowed.contains($0) }) else { return nil }
        let below = parts.dropFirst().map { $0.removingPercentEncoding ?? $0 }
        if scheme == "ftp" {
            // FTP has no shared folders: the whole server is connected, and folders follow.
            return NetworkAddress(scheme: scheme, user: user, host: authority, share: "", subpath: Array(below))
        }
        if scheme == "nfs" {
            // NFS exports are whole paths; the export is mounted as given.
            return NetworkAddress(scheme: scheme, user: user, host: authority, share: below.isEmpty ? nil : below.joined(separator: "/"), subpath: [])
        }
        return NetworkAddress(scheme: scheme, user: user, host: authority, share: below.first, subpath: Array(below.dropFirst()))
    }

    static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return false }
        for x in p {
            guard !x.isEmpty, x.count <= 3, let n = Int(x), n >= 0, n <= 255 else { return false }
        }
        return true
    }

    /// Is this mounted volume's reconnect address the same server and share?
    func matches(remountURL: String) -> Bool {
        guard let other = NetworkAddress.parse(remountURL), let mine = share, let theirs = other.share else { return false }
        func bareHost(_ h: String) -> String { return (h.split(separator: ":").first.map(String.init) ?? h).lowercased() }
        return other.scheme == scheme && bareHost(other.host) == bareHost(host) && theirs.lowercased() == mine.lowercased()
    }
}

/// Help > Network Report (0.14): what macOS reports about mounted shares and how Find matches them to
/// saved servers. Plain ASCII, one fact per line, numbered, with a total. No passwords (none are kept
/// in these places; anything between ':' and '@' in an address is removed anyway).
enum NetworkReport {
    static func hidePassword(_ s: String) -> String {
        guard let at = s.range(of: "@") else { return s }
        let head = String(s[s.startIndex..<at.lowerBound])
        let start = head.range(of: "://")?.upperBound ?? (head.hasPrefix("//") ? head.index(head.startIndex, offsetBy: 2) : head.startIndex)
        guard let colon = head[start...].index(of: ":") else { return s }
        return String(head[head.startIndex..<colon]) + ":***" + String(s[at.lowerBound...])
    }

    static func lines(_ volumes: [VolumeRecord], saved: [SavedServer], typed: NetworkAddress? = nil) -> [String] {
        var out: [String] = []
        func add(_ t: String) { out.append(Ascii.clean(t)) }
        if let a = typed { add("Address asked for: \(hidePassword(a.mountURL)) (share \(a.share.map { $0.isEmpty ? "whole server" : $0 } ?? "none"))") }
        let shares = volumes.filter { !$0.isLocal && !$0.isRoot }
        add("Network volumes mounted: \(shares.count)")
        for v in shares {
            add("Volume \(v.path): name \(v.name); reconnect \(v.remountURL.map(hidePassword) ?? "unknown"); mounted from \(v.source.map(hidePassword) ?? "unknown")")
        }
        let local = volumes.filter { $0.isLocal && !$0.isRoot }
        add("Other volumes: \(local.isEmpty ? "none" : local.map { $0.path }.joined(separator: ", "))")
        add("Saved servers: \(saved.count)")
        for s in saved {
            let a = s.parsed
            let m = ServerList.mountedPath(s, volumes: volumes)
            add("Saved \(s.name): \(hidePassword(s.address)); type \(a?.scheme ?? "not an address"); account \(s.user.isEmpty ? "none" : s.user); connect at start \(s.autoConnect ? "yes" : "no"); matched \(m?.root ?? "NOT CONNECTED or not recognised")")
        }
        return out.enumerated().map { String(format: "N%03d ", $0.offset + 1) + $0.element } + ["Total: \(out.count) lines"]
    }
}
