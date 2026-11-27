// Index.swift
// Optional search index for local folders the user chooses (Phase 2b).
//
// How it stays correct:
//  - The index stores, for each folder, its listing plus the folder's change stamp (ctime, nanoseconds).
//    Adding, removing or renaming anything in a folder changes that stamp, and programs can't set it back.
//  - Every indexed search checks each folder's stamp as it goes. A changed (or new, or unknown) folder is
//    read straight from disk and the index is updated. Unchanged folders are answered from the index.
//  - Every match is checked against the disk before it is shown.
//  - Searches with size or date conditions never use the index (file details can change without the
//    folder changing), and "Search without index" always reads everything directly.
//  - The disk is always the truth: a missing, damaged or out-of-place index simply means a direct search.

import Foundation

struct IndexedEntry {
    let name: String
    let info: StatInfo
}

final class DirRecord {
    let changed: Double
    let device: UInt64
    let inode: UInt64
    let entries: [IndexedEntry]

    init(changed: Double, device: UInt64, inode: UInt64, entries: [IndexedEntry]) {
        self.changed = changed
        self.device = device
        self.inode = inode
        self.entries = entries
    }
}

/// The index for one chosen folder.
final class FolderIndex {
    let root: String
    var excluded: [String]
    var rootDevice: UInt64
    var rootInode: UInt64
    var builtAt: Double
    private var dirs: [String: DirRecord] = [:]
    private let lock = NSLock()
    private(set) var dirty = false

    init(root: String, excluded: [String], rootDevice: UInt64, rootInode: UInt64, builtAt: Double) {
        self.root = root
        self.excluded = excluded
        self.rootDevice = rootDevice
        self.rootInode = rootInode
        self.builtAt = builtAt
    }

    func covers(_ path: String) -> Bool {
        return Paths.isInside(path, root: root)
    }

    func isExcluded(_ path: String) -> Bool {
        for x in excluded where Paths.isInside(path, root: x) { return true }
        return false
    }

    func record(_ dir: String) -> DirRecord? {
        lock.lock()
        defer { lock.unlock() }
        return dirs[dir]
    }

    func store(_ dir: String, _ rec: DirRecord) {
        lock.lock()
        // Sub-folders that disappeared from this folder: drop their records too.
        if let old = dirs[dir] {
            let newNames = Set(rec.entries.filter { $0.info.isDirectory }.map { $0.name })
            for e in old.entries where e.info.isDirectory && !newNames.contains(e.name) {
                removeSubtreeLocked(Paths.join(dir, e.name))
            }
        }
        dirs[dir] = rec
        dirty = true
        lock.unlock()
    }

    func removeSubtree(_ dir: String) {
        lock.lock()
        removeSubtreeLocked(dir)
        lock.unlock()
    }

    private func removeSubtreeLocked(_ dir: String) {
        let prefix = dir + "/"
        for k in Array(dirs.keys) where k == dir || k.hasPrefix(prefix) {
            dirs[k] = nil
            dirty = true
        }
    }

    var folderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dirs.count
    }

    var itemCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dirs.values.reduce(0) { $0 + $1.entries.count }
    }

    func markSaved() {
        lock.lock()
        dirty = false
        lock.unlock()
    }

    // MARK: File format (binary, versioned, checked while reading so a damaged file is rejected, never trusted)

    static let magic: [UInt8] = Array("FINDIDX1".utf8)

    func encode() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var w = ByteWriter()
        w.bytes(FolderIndex.magic)
        w.string(root)
        w.u64(rootDevice)
        w.u64(rootInode)
        w.f64(builtAt)
        w.u32(UInt32(excluded.count))
        for x in excluded { w.string(x) }
        w.u32(UInt32(dirs.count))
        for (path, rec) in dirs {
            w.string(path)
            w.f64(rec.changed)
            w.u64(rec.device)
            w.u64(rec.inode)
            w.u32(UInt32(rec.entries.count))
            for e in rec.entries {
                w.string(e.name)
                w.u32(e.info.mode)
                w.u64(UInt64(bitPattern: e.info.size))
                w.f64(e.info.modified)
                w.f64(e.info.created)
                w.f64(e.info.changed)
                w.u32(e.info.flags)
                w.u64(e.info.device)
                w.u64(e.info.inode)
            }
        }
        w.bytes(Array("END".utf8))
        return Data(bytes: w.buf)
    }

    static func decode(_ data: Data) -> FolderIndex? {
        var r = ByteReader(Array(data))
        guard let m = r.bytes(magic.count), m == magic,
            let root = r.string(), let dev = r.u64(), let ino = r.u64(), let built = r.f64(),
            let exCount = r.u32(), exCount < 10_000 else { return nil }
        var excluded: [String] = []
        for _ in 0..<exCount {
            guard let x = r.string() else { return nil }
            excluded.append(x)
        }
        let idx = FolderIndex(root: root, excluded: excluded, rootDevice: dev, rootInode: ino, builtAt: built)
        guard let dirCount = r.u32() else { return nil }
        var dirs: [String: DirRecord] = [:]
        dirs.reserveCapacity(Int(dirCount))
        for _ in 0..<dirCount {
            guard let path = r.string(), let ch = r.f64(), let dd = r.u64(), let di = r.u64(), let n = r.u32() else { return nil }
            var entries: [IndexedEntry] = []
            entries.reserveCapacity(Int(min(n, 1_000_000)))
            for _ in 0..<n {
                guard let name = r.string(), let mode = r.u32(), let size = r.u64(), let mod = r.f64(), let cr = r.f64(),
                    let chg = r.f64(), let flags = r.u32(), let edev = r.u64(), let eino = r.u64() else { return nil }
                let info = StatInfo(mode: mode, size: Int64(bitPattern: size), modified: mod, created: cr, flags: flags,
                                    device: edev, inode: eino, changed: chg)
                entries.append(IndexedEntry(name: name, info: info))
            }
            dirs[path] = DirRecord(changed: ch, device: dd, inode: di, entries: entries)
        }
        guard let end = r.bytes(3), end == Array("END".utf8), r.atEnd else { return nil }
        idx.dirs = dirs
        return idx
    }
}

struct ByteWriter {
    var buf: [UInt8] = []

    mutating func bytes(_ b: [UInt8]) { buf.append(contentsOf: b) }

    mutating func u32(_ v: UInt32) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { buf.append(contentsOf: $0) }
    }

    mutating func u64(_ v: UInt64) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { buf.append(contentsOf: $0) }
    }

    mutating func f64(_ v: Double) { u64(v.bitPattern) }

    mutating func string(_ s: String) {
        let b = Array(s.utf8)
        u32(UInt32(b.count))
        buf.append(contentsOf: b)
    }
}

struct ByteReader {
    let buf: [UInt8]
    var pos = 0

    init(_ b: [UInt8]) {
        buf = b
    }

    var atEnd: Bool { return pos == buf.count }

    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, pos + n <= buf.count else { return nil }
        let out = Array(buf[pos..<(pos + n)])
        pos += n
        return out
    }

    mutating func u32() -> UInt32? {
        guard pos + 4 <= buf.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(buf[pos + i]) << UInt32(8 * i) }
        pos += 4
        return v
    }

    mutating func u64() -> UInt64? {
        guard pos + 8 <= buf.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(buf[pos + i]) << UInt64(8 * i) }
        pos += 8
        return v
    }

    mutating func f64() -> Double? {
        guard let b = u64() else { return nil }
        return Double(bitPattern: b)
    }

    mutating func string() -> String? {
        guard let n = u32(), n <= 1_000_000, let b = bytes(Int(n)) else { return nil }
        return String(bytes: b, encoding: .utf8)
    }
}

/// Serves folder listings from indexes when a folder is unchanged; reads (and records) it from disk otherwise.
final class IndexScanner: FolderScanner {
    let indexes: [FolderIndex]
    let real: FolderScanner
    /// Building: every folder is read from disk and recorded; excluded folders are not walked at all.
    let building: Bool
    private let lock = NSLock()
    private(set) var foldersFromIndex = 0
    private(set) var foldersFromDisk = 0

    init(indexes: [FolderIndex], real: FolderScanner = PosixScanner(), building: Bool = false) {
        self.indexes = indexes
        self.real = real
        self.building = building
    }

    private func index(for dir: String) -> FolderIndex? {
        // The deepest index that covers this folder.
        var best: FolderIndex? = nil
        for i in indexes where i.covers(dir) {
            if best == nil || i.root.count > best!.root.count { best = i }
        }
        return best
    }

    private func count(fromIndex: Bool) {
        lock.lock()
        if fromIndex { foldersFromIndex += 1 } else { foldersFromDisk += 1 }
        lock.unlock()
    }

    func scan(_ dir: String, _ visit: (String, StatInfo) -> Bool) -> ScanOutcome {
        guard let idx = index(for: dir) else {
            count(fromIndex: false)
            return real.scan(dir, visit)
        }
        if idx.isExcluded(dir) {
            if building { return ScanOutcome() }
            count(fromIndex: false)
            return real.scan(dir, visit)
        }
        var e: Int32 = 0
        guard let dinfo = Sys.lstatInfo(dir, &e) else {
            idx.removeSubtree(dir)
            count(fromIndex: false)
            return real.scan(dir, visit)
        }
        if !building, let rec = idx.record(dir),
            rec.changed == dinfo.changed, rec.inode == dinfo.inode, rec.device == dinfo.device {
            count(fromIndex: true)
            var out = ScanOutcome()
            for en in rec.entries {
                var info = en.info
                if info.isDirectory {
                    // Folders: use their current details (hidden flag, device) so the search rules see the truth.
                    var e2: Int32 = 0
                    if let fresh = Sys.lstatInfo(Paths.join(dir, en.name), &e2) {
                        info = fresh
                    } else if e2 == ENOENT {
                        continue
                    }
                }
                if !visit(en.name, info) {
                    out.stoppedEarly = true
                    return out
                }
            }
            return out
        }
        // Changed, new or unknown folder: read it from disk and record what was read.
        count(fromIndex: false)
        var collected: [IndexedEntry] = []
        let out = real.scan(dir) { name, info in
            collected.append(IndexedEntry(name: name, info: info))
            return visit(name, info)
        }
        if out.folderError == nil && !out.stoppedEarly && out.entryProblems.isEmpty {
            // Some drives (HFS+) keep change stamps to the second only. A folder changed in the last
            // two seconds could change again with the same stamp, so it is recorded as "unsettled"
            // (stamp -1, never matches) and simply read again next time.
            let settled = dinfo.changed < Date().timeIntervalSince1970 - 2.0
            idx.store(dir, DirRecord(changed: settled ? dinfo.changed : -1, device: dinfo.device, inode: dinfo.inode, entries: collected))
        } else if out.folderError != nil {
            idx.removeSubtree(dir)
        }
        return out
    }
}

/// Status of one indexed folder, for Settings.
struct IndexStatus {
    let root: String
    let excluded: [String]
    let exists: Bool
    let valid: Bool
    let reason: String
    let folders: Int
    let items: Int
    let bytesOnDisk: Int64
    let builtAt: Double
}

/// The list of indexed folders and their files, in Find's own folder.
final class IndexStore {
    struct Config: Codable {
        var enabled: Bool
        var roots: [RootConfig]
    }

    struct RootConfig: Codable {
        var root: String
        var excluded: [String]
    }

    let files: AppFiles
    let folder: String
    private(set) var config = Config(enabled: true, roots: [])
    private var loaded: [String: FolderIndex] = [:]
    private let lock = NSLock()

    init(files: AppFiles, folder: String) {
        self.files = files
        self.folder = folder
        _ = files.makeDir(folder)
        if let d = FileManager.default.contents(atPath: configPath), let c = try? JSONDecoder().decode(Config.self, from: d) {
            config = c
        }
    }

    private var configPath: String { return Paths.join(folder, "config.json") }

    private func saveConfig() {
        if let d = try? JSONEncoder().encode(config) { files.writeData(d, to: configPath) }
    }

    /// FNV-1a hash of the folder path, used as the index file name.
    static func fileName(for root: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in root.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h) + ".findidx"
    }

    func indexPath(_ root: String) -> String {
        return Paths.join(folder, IndexStore.fileName(for: root))
    }

    var enabled: Bool {
        get { return config.enabled }
        set {
            config.enabled = newValue
            saveConfig()
        }
    }

    var roots: [RootConfig] { return config.roots }

    /// Add a folder to index. Returns a reason if refused.
    func addRoot(_ root: String) -> String? {
        if config.roots.contains(where: { $0.root == root }) { return "That folder is already indexed." }
        for r in config.roots {
            if Paths.isInside(root, root: r.root) { return "It is already inside the indexed folder \(r.root)." }
            if Paths.isInside(r.root, root: root) { return "It contains the indexed folder \(r.root). Remove that one first." }
        }
        config.roots.append(RootConfig(root: root, excluded: []))
        saveConfig()
        return nil
    }

    func removeRoot(_ root: String) {
        config.roots = config.roots.filter { $0.root != root }
        saveConfig()
        lock.lock()
        loaded[root] = nil
        lock.unlock()
        files.removeOwned(indexPath(root))
    }

    func setExcluded(_ root: String, _ excluded: [String]) {
        guard let i = config.roots.index(where: { $0.root == root }) else { return }
        config.roots[i].excluded = excluded
        saveConfig()
        lock.lock()
        loaded[root]?.excluded = excluded
        lock.unlock()
    }

    /// Delete every index file (the list of folders is kept, so they can be rebuilt).
    func deleteAllIndexFiles() {
        lock.lock()
        loaded.removeAll()
        lock.unlock()
        for n in files.list(folder) where n.hasSuffix(".findidx") { files.removeOwned(Paths.join(folder, n)) }
    }

    /// Load (once) and check an index: it must belong to the same folder on the same drive.
    func index(_ root: String) -> FolderIndex? {
        lock.lock()
        if let l = loaded[root] {
            lock.unlock()
            return validOrNil(l)
        }
        lock.unlock()
        guard let d = FileManager.default.contents(atPath: indexPath(root)), let idx = FolderIndex.decode(d), idx.root == root else { return nil }
        if let cfg = config.roots.first(where: { $0.root == root }) { idx.excluded = cfg.excluded }
        idx.markSaved()
        lock.lock()
        loaded[root] = idx
        lock.unlock()
        return validOrNil(idx)
    }

    private func validOrNil(_ idx: FolderIndex) -> FolderIndex? {
        var e: Int32 = 0
        guard let info = Sys.statInfo(idx.root, &e), info.isDirectory, info.device == idx.rootDevice, info.inode == idx.rootInode else {
            return nil
        }
        return idx
    }

    func status(_ root: String) -> IndexStatus {
        let cfg = config.roots.first(where: { $0.root == root })
        let path = indexPath(root)
        var e: Int32 = 0
        let size = Sys.lstatInfo(path, &e)?.size ?? 0
        let exists = size > 0
        if !exists {
            return IndexStatus(root: root, excluded: cfg?.excluded ?? [], exists: false, valid: false, reason: "Not built yet",
                               folders: 0, items: 0, bytesOnDisk: 0, builtAt: 0)
        }
        guard let idx = index(root) else {
            return IndexStatus(root: root, excluded: cfg?.excluded ?? [], exists: true, valid: false,
                               reason: "Needs rebuilding (damaged, or the folder was replaced or moved)",
                               folders: 0, items: 0, bytesOnDisk: size, builtAt: 0)
        }
        return IndexStatus(root: root, excluded: idx.excluded, exists: true, valid: true, reason: "Ready",
                           folders: idx.folderCount, items: idx.itemCount, bytesOnDisk: size, builtAt: idx.builtAt)
    }

    /// Build (or rebuild) one index. Runs on the calling thread; returns a summary of what was read.
    func build(_ root: String, workers: Int = 4, onProgress: ((SearchProgress) -> Void)? = nil,
               cancel: ((SearchEngine) -> Void)? = nil) -> SearchSummary? {
        var e: Int32 = 0
        guard let info = Sys.statInfo(root, &e), info.isDirectory else { return nil }
        let excluded = config.roots.first(where: { $0.root == root })?.excluded ?? []
        let idx = FolderIndex(root: root, excluded: excluded, rootDevice: info.device, rootInode: info.inode,
                              builtAt: Date().timeIntervalSince1970)
        var q = SearchQuery()
        q.matchNothing = true
        q.includeHidden = true
        q.includeSystem = true
        q.includePackages = true
        q.followLinks = false
        let scanner = IndexScanner(indexes: [idx], building: true)
        guard let engine = try? SearchEngine(query: q, roots: [root], scanner: scanner, workers: workers,
                                             isPackage: { _, _ in false }) else { return nil }
        engine.onProgress = onProgress
        cancel?(engine)
        let summary = engine.run()
        if summary.cancelled { return summary }
        lock.lock()
        loaded[root] = idx
        lock.unlock()
        save(idx)
        return summary
    }

    func save(_ idx: FolderIndex) {
        if files.writeData(idx.encode(), to: indexPath(idx.root)) { idx.markSaved() }
    }

    /// Save indexes that searches have updated.
    func saveDirty() {
        lock.lock()
        let all = Array(loaded.values)
        lock.unlock()
        for i in all where i.dirty { save(i) }
    }

    /// A scanner for these search roots, or nil when no index applies (then search directly).
    func scanner(for searchRoots: [String]) -> IndexScanner? {
        guard config.enabled else { return nil }
        var useful: [FolderIndex] = []
        for r in config.roots {
            let overlaps = searchRoots.contains { Paths.isInside($0, root: r.root) || Paths.isInside(r.root, root: $0) }
            if overlaps, let idx = index(r.root) { useful.append(idx) }
        }
        return useful.isEmpty ? nil : IndexScanner(indexes: useful)
    }

    var totalBytesOnDisk: Int64 {
        var t: Int64 = 0
        var e: Int32 = 0
        for n in files.list(folder) where n.hasSuffix(".findidx") {
            t += Sys.lstatInfo(Paths.join(folder, n), &e)?.size ?? 0
        }
        return t
    }
}
