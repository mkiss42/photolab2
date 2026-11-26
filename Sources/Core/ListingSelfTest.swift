// ListingSelfTest.swift
// Listing, sorting, cache, volumes and path helpers. The fixture folder lives in
// ~/Library/Caches/PhotoLab2/selftest and is removed afterwards.

import Foundation

enum ListingSelfTest {
    static func run() -> [SelfTestResult] {
        var out: [SelfTestResult] = [paths(), naturalSort(), setRows(), favorites(), cache(), volumes(), realRecords()]
        guard let dir = AppFiles.makeListingFixture() else {
            out.append(SelfTestResult(name: "listing-fixture", status: .fail, detail: "could not create fixture"))
            return out
        }
        defer { AppFiles.removeListingFixture(dir) }
        out.append(fixture(dir))
        var compared: [String] = [dir]
        for d in ["/usr/bin", "/Applications", "/System/Library/CoreServices"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue { compared.append(d) }
        }
        out.append(bulkMatchesClassic(compared))
        out.append(networkShares())
        return out
    }

    static func fail(_ n: String, _ d: String) -> SelfTestResult { return SelfTestResult(name: n, status: .fail, detail: d) }
    static func ok(_ n: String, _ d: String = "") -> SelfTestResult { return SelfTestResult(name: n, status: .ok, detail: d) }

    static func paths() -> SelfTestResult {
        let n = "paths"
        guard Paths.parent("/a/b/c") == "/a/b", Paths.parent("/a") == "/", Paths.parent("/") == "/",
            Paths.parent("/a/b/") == "/a", Paths.name("/a/b") == "b", Paths.name("/") == "/",
            Paths.join("/", "x") == "/x", Paths.join("/a", "x") == "/a/x",
            Paths.ancestry("/a/b") == ["/", "/a", "/a/b"] else { return fail(n, "helper mismatch") }
        return ok(n)
    }

    static func entry(_ name: String, dir: Bool = false, size: Int64 = 0, mtime: Double = 0) -> FileEntry {
        return FileEntry.make(name: name, dir: "/t", mode: dir ? 0o040755 : 0o100644, size: size,
                              modified: mtime, created: 0, added: 0, flags: 0, device: 1, inode: 1)
    }

    /// One row per set: raw is the representative, sizes add up, Ext in raw/jpg/sidecar order;
    /// a lone JPG, a PSD of the same name and a folder stay rows of their own.
    static func setRows() -> SelfTestResult {
        let n = "set-rows"
        func f(_ name: String, _ size: Int64, dir: Bool = false) -> FileEntry {
            return FileEntry.make(name: name, dir: "/t", mode: dir ? 0o040755 : 0o100644, size: size, modified: 1,
                                  created: 0, added: 0, flags: 0, device: 0, inode: 0)
        }
        let rows = FileSets.rows([f("A.xmp", 1), f("A.JPG", 10), f("A.CR3", 100), f("A.psd", 5), f("B.JPG", 7), f("A", 0, dir: true)])
        let byName = Dictionary(rows.map { ($0.entry.name, $0) }, uniquingKeysWith: { a, _ in a })
        guard rows.count == 4, let a = byName["A.CR3"], a.entry.size == 111, FileSets.extLabel(a.members) == "CR3+JPG+XMP",
            byName["A.psd"]?.members.count == 1, byName["B.JPG"]?.members.count == 1, byName["A"] != nil else {
            return SelfTestResult(name: n, status: .fail, detail: rows.map { "\($0.entry.name)/\($0.members.count)" }.joined(separator: " "))
        }
        return SelfTestResult(name: n, status: .ok, detail: "")
    }

    /// Favorites: add at a position, re-add moves (no duplicates), reorder, remove.
    static func favorites() -> SelfTestResult {
        let n = "sidebar-favorites"
        let a = Favorite(title: "A", path: "/a"), b = Favorite(title: "B", path: "/b"), c = Favorite(title: "C", path: "/c")
        var l = Favorites.inserting(["/x/Job"], at: 1, into: [a, b, c])
        guard l.map({ $0.title }) == ["A", "Job", "B", "C"] else { return SelfTestResult(name: n, status: .fail, detail: "insert") }
        l = Favorites.inserting(["/a"], at: 3, into: l)                    // drag A below B
        guard l.map({ $0.title }) == ["Job", "B", "A", "C"] else { return SelfTestResult(name: n, status: .fail, detail: l.map { $0.title }.joined()) }
        l = Favorites.removing("/b", from: l)
        return l.map({ $0.title }) == ["Job", "A", "C"] ? SelfTestResult(name: n, status: .ok, detail: "")
            : SelfTestResult(name: n, status: .fail, detail: "remove")
    }

    static func naturalSort() -> SelfTestResult {
        let n = "natural-sort"
        let e = [entry("IMG 10.JPG"), entry("img 9.jpg"), entry("Zeta", dir: true), entry("alpha.txt")]
        let names = EntrySort.sort(e, by: .name, ascending: true, foldersFirst: true).map { $0.name }
        guard names == ["Zeta", "alpha.txt", "img 9.jpg", "IMG 10.JPG"] else { return fail(n, names.joined(separator: "|")) }
        let mixed = EntrySort.sort(e, by: .name, ascending: false, foldersFirst: false).map { $0.name }
        guard mixed == ["Zeta", "IMG 10.JPG", "img 9.jpg", "alpha.txt"] else { return fail(n, "descending: " + mixed.joined(separator: "|")) }
        let bySize = EntrySort.sort([entry("b", size: 5), entry("a", size: 9), entry("c", size: 5)],
                                    by: .size, ascending: true, foldersFirst: false).map { $0.name }
        guard bySize == ["b", "c", "a"] else { return fail(n, "size: " + bySize.joined(separator: "|")) }
        guard entry("x.JPG").ext == "jpg", entry(".hidden").ext == "", entry(".hidden").isHidden else { return fail(n, "ext/hidden") }
        return ok(n)
    }

    static func cache() -> SelfTestResult {
        let n = "listing-cache"
        let c = ListingCache()
        var l = FolderListing(); l.entries = [entry("a")]
        let t0 = Date()
        c.store("/x", listing: l, folderMtime: 10, now: t0)
        guard c.lookup("/x", currentMtime: 10, now: t0.addingTimeInterval(5))?.entries.count == 1 else { return fail(n, "fresh miss") }
        guard c.lookup("/x", currentMtime: 11, now: t0.addingTimeInterval(5)) == nil else { return fail(n, "changed folder served") }
        c.store("/x", listing: l, folderMtime: 10, now: t0)
        guard c.lookup("/x", currentMtime: 10, now: t0.addingTimeInterval(500)) == nil else { return fail(n, "expired served") }
        var bad = FolderListing(); bad.error = EACCES
        c.store("/y", listing: bad, folderMtime: 1, now: t0)
        guard c.lookup("/y", currentMtime: 1, now: t0) == nil else { return fail(n, "error listing cached") }
        for i in 0..<50 { c.store("/f\(i)", listing: l, folderMtime: 1, now: t0) }
        guard c.lookup("/f0", currentMtime: 1, now: t0) == nil, c.lookup("/f49", currentMtime: 1, now: t0) != nil else { return fail(n, "LRU bound") }
        return ok(n)
    }

    static func volumes() -> SelfTestResult {
        let n = "volumes"
        Volumes.refresh()
        let all = Volumes.all
        guard let root = all.first(where: { $0.isRoot }) else { return fail(n, "no root volume in \(all.count) mounts") }
        guard root.isLocal, Volumes.volume(for: "/usr/bin")?.isRoot == true else { return fail(n, "root not local/lookup") }
        let net = all.filter { $0.isNetwork }.count
        return ok(n, "\(all.count) mounts, \(net) network, \(Volumes.browsable.count) shown")
    }

    /// Records captured from the lab's SMB servers (0.1.1 log): folders without the size field,
    /// 112 bytes, name at offset 108. These must parse as folders, never as broken.
    static let capturedRecords: [(hex: String, name: String, perm: UInt16, hidden: Bool, inode: UInt64)] = [
        ("70000000 0b0606a2 00000000 00000000 00000000 00000000 00000000 50000000 04000000 03000036 02000000 06110166 00000000 00000000 00000000 7e5b1268 00000000 00000000 00000000 c0410000 00800000 ffffd4ba fad1e783 00000000 00000000 00000000 00000000 2e393900",
         ".99", 0o700, true, 0x83e7_d1fa_bad4_ffff),
        ("70000000 0b0606a2 00000000 00000000 00000000 00000000 00000000 50000000 04000000 02000036 02000000 a0772c64 00000000 00000000 00000000 b44afa6a 00000000 00000000 00000000 c0410000 00000000 6c1a82e3 d6d22d84 00000000 00000000 00000000 00000000 64656c00",
         "del", 0o700, false, 0x842d_d2d6_e382_1a6c),
        ("70000000 0b0606a2 00000000 00000000 00000000 00000000 00000000 50000000 04000000 04000036 02000000 e3bdf059 00000000 00000000 00000000 c8350f5a 00000000 00000000 00000000 ed410000 00800000 b89c7de3 d0d22b84 00000000 00000000 00000000 00000000 62696e00",
         "bin", 0o755, true, 0x842b_d2d0_e37d_9cb8),
    ]

    static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.replacingOccurrences(of: " ", with: ""))
        var out: [UInt8] = []
        var i = 0
        while i + 1 < digits.count {
            out.append(UInt8(String(digits[i...i + 1]), radix: 16) ?? 0)
            i += 2
        }
        return out
    }

    static func realRecords() -> SelfTestResult {
        let n = "listing-smb-records"
        for r in capturedRecords {
            let (e, problem) = BulkLister.parseForTest(bytes(r.hex), dir: "/Volumes/T")
            if let p = problem { return fail(n, "\(r.name): \(p)") }
            guard let entry = e else { return fail(n, "\(r.name): no entry") }
            guard entry.name == r.name, entry.isDirectory, entry.size == 0, entry.permissions == r.perm,
                entry.isHidden == r.hidden, entry.inode == r.inode, entry.modified > 1_400_000_000,
                entry.path == "/Volumes/T/" + r.name else { return fail(n, "\(r.name): fields wrong") }
        }
        // A file record that claims a size but has no room for it must not be read past its end.
        var short = bytes(capturedRecords[0].hex)
        short[16] = 0x00; short[17] = 0x02     // fileattr: DATALENGTH returned
        if BulkLister.parseForTest(short, dir: "/Volumes/T").problem == nil { return fail(n, "missing size field accepted") }
        return ok(n, "\(capturedRecords.count) captured records")
    }

    static func fixture(_ dir: String) -> SelfTestResult {
        let n = "listing-fixture"
        let l = DirectoryReader.read(dir)
        guard l.error == 0 else { return fail(n, "error \(l.errorText)") }
        let byName = Dictionary(l.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let want: Set<String> = ["a.txt", ".hidden", "Folder", "IMG 10.JPG", "IMG 9.JPG", "caf\u{e9}.txt"]
        let got = Set(byName.keys.map { $0.precomposedStringWithCanonicalMapping })
        guard got == Set(want.map { $0.precomposedStringWithCanonicalMapping }) else {
            return fail(n, "names: " + got.sorted().joined(separator: "|"))
        }
        guard byName["a.txt"]?.size == 5, byName["a.txt"]?.kind == .file, byName["Folder"]?.isDirectory == true,
            byName[".hidden"]?.isHidden == true, byName["a.txt"]?.isHidden == false,
            (byName["a.txt"]?.modified ?? 0) > 1_500_000_000 else { return fail(n, "attributes") }
        return ok(n, "\(l.method), \(String(format: "%.1f", l.milliseconds)) ms")
    }

    /// Both methods must agree on every entry (names, kind, size, dates, ids, flags, permissions).
    static func bulkMatchesClassic(_ dirs: [String]) -> SelfTestResult {
        let n = "listing-bulk-vs-readdir"
        if let why = compare(dirs) { return fail(n, why) }
        return ok(n, "\(dirs.count) folders identical")
    }

    /// The top folder of every mounted network share, both ways (read-only, one folder each).
    /// SMB may legitimately report some details differently, so differences are WARN, not FAIL.
    static func networkShares() -> SelfTestResult {
        let n = "listing-network-shares"
        let shares = Volumes.browsable.filter { $0.isNetwork }.map { $0.mountPoint }
        if shares.isEmpty { return SelfTestResult(name: n, status: .skip, detail: "no network share mounted") }
        var notes: [String] = []
        for sh in shares {
            if let why = compare([sh]) {
                let fs = Volumes.volume(for: sh)?.fsType ?? "?"
                notes.append("\(fs) " + why)
            }
        }
        if notes.isEmpty { return ok(n, "\(shares.count) share(s) identical") }
        return SelfTestResult(name: n, status: .warn, detail: notes.joined(separator: " | "))
    }

    /// nil when bulk and readdir agree on every folder, else the first difference.
    static func compare(_ dirs: [String]) -> String? {
        for d in dirs {
            let bulk = DirectoryReader.read(d, method: .bulk)
            let classic = DirectoryReader.read(d, method: .classic)
            if bulk.method != "bulk" { return "\(d): \(bulk.method): \(DirectoryReader.lastOddity(d))" }
            if bulk.error != classic.error { return "\(d): error \(bulk.error) vs \(classic.error)" }
            let b = Dictionary(bulk.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let c = Dictionary(classic.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            if Set(b.keys) != Set(c.keys) {
                let extra = Set(b.keys).subtracting(c.keys).sorted().prefix(3)
                let missing = Set(c.keys).subtracting(b.keys).sorted().prefix(3)
                return "\(d): extra \(Array(extra)) missing \(Array(missing))"
            }
            for (name, ce) in c {
                guard let be = b[name] else { continue }
                var why: [String] = []
                if be.kind != ce.kind { why.append("kind") }
                if be.size != ce.size { why.append("size \(be.size)/\(ce.size)") }
                if abs(be.modified - ce.modified) > 0.000_01 { why.append("mtime") }
                if ce.created != 0 && abs(be.created - ce.created) > 0.000_01 { why.append("ctime") }
                if be.inode != ce.inode { why.append("inode") }
                if be.device != ce.device { why.append("device \(be.device)/\(ce.device)") }
                if be.flags != ce.flags { why.append("flags") }
                if be.permissions != ce.permissions { why.append("perm") }
                if !why.isEmpty { return "\(d)/\(name): " + why.joined(separator: ",") }
            }
        }
        return nil
    }
}
