// FinderTags.swift
// Finder tags (the com.apple.metadata:_kMDItemUserTags extended attribute: a binary plist array
// of "Name\n<colour>" strings) - read side. Writing is FileOperations.changeTag (via Platform).
// XMP colour labels are a different thing and belong to the contact sheet (Phase 2).
// Reading costs one round trip per file on a share, so the list only asks for rows on screen,
// in the background, one volume at a time (TagLoader).

import Foundation
import Darwin

struct FinderTag: Equatable {
    let name: String
    let color: Int          // 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange
}

enum FinderTags {
    static let xattrName = "com.apple.metadata:_kMDItemUserTags"
    static let colorNames = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
    /// Finder's menu order.
    static let menuOrder = [6, 7, 5, 2, 4, 3, 1]

    static func parse(_ data: Data) -> [FinderTag] {
        guard let arr = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String] else { return [] }
        return arr.map { s in
            let parts = s.components(separatedBy: "\n")
            if parts.count >= 2, let c = Int(parts[parts.count - 1]), (0...7).contains(c) {
                return FinderTag(name: parts.dropLast().joined(separator: "\n"), color: c)
            }
            return FinderTag(name: s, color: 0)
        }
    }

    static func encode(_ tags: [FinderTag]) -> Data {
        let arr = tags.map { $0.color > 0 ? "\($0.name)\n\($0.color)" : $0.name }
        return (try? PropertyListSerialization.data(fromPropertyList: arr, format: .binary, options: 0)) ?? Data()
    }

    /// The tag a colour stands for in Finder's menu ("Red", colour 6).
    static func colorTag(_ color: Int) -> FinderTag { return FinderTag(name: colorNames[color], color: color) }

    /// Tags of one item; [] when it has none; nil when the attribute can't be read.
    static func read(_ path: String) -> [FinderTag]? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = getxattr(path, xattrName, &buf, buf.count, 0, XATTR_NOFOLLOW)
        if n < 0 {
            if errno == ENOATTR { return [] }
            if errno == ERANGE {
                let size = getxattr(path, xattrName, nil, 0, 0, XATTR_NOFOLLOW)
                guard size > 0 else { return nil }
                buf = [UInt8](repeating: 0, count: size)
                let m = getxattr(path, xattrName, &buf, size, 0, XATTR_NOFOLLOW)
                return m < 0 ? nil : parse(Data(buf[0..<m]))
            }
            return nil
        }
        return parse(Data(buf[0..<n]))
    }
}

extension Notification.Name {
    /// Tags of some items were (re)read; userInfo["paths"] = [String]. Posted on the main thread.
    static let tagsChanged = Notification.Name("PhotoLabTagsChanged")
}

/// Background tag reads with a memory cache. The list asks for rows on screen; reads that are no
/// longer wanted (scrolled away, folder left) are dropped before they cost a round trip.
/// Entries do not expire by age: they are replaced when the file's change time (ctime) moves -
/// writing a tag moves it - or when FSEvents reports the change, or when the folder is re-read.
final class TagLoader {
    static let shared = TagLoader()
    private let lock = NSLock()
    private var cache: [String: (tags: [FinderTag], ctime: Double)] = [:]
    private var wanted: [ObjectIdentifier: Set<String>] = [:]
    private var queues: [String: DispatchQueue] = [:]
    private var inFlight = Set<String>()
    private var recheckBusy = Set<String>()

    func cached(_ path: String) -> [FinderTag]? {
        lock.lock(); defer { lock.unlock() }
        return cache[path]?.tags
    }

    static func ctime(_ path: String) -> Double? {
        var st = stat()
        return lstat(path, &st) == 0 ? DirectoryReader.seconds(st.st_ctimespec) : nil
    }

    /// Store after our own write (the ctime is read again on the next check anyway).
    func store(_ path: String, _ tags: [FinderTag]) {
        let c = TagLoader.ctime(path) ?? 0
        lock.lock(); cache[path] = (tags, c); lock.unlock()
    }

    private func readOne(_ path: String) -> Bool {
        let c = TagLoader.ctime(path)
        guard let t = FinderTags.read(path) else { return false }
        lock.lock(); cache[path] = (t, c ?? 0); lock.unlock()
        return true
    }

    /// A folder was read again from disk: its items' tags are read again too.
    func forgetFolder(_ dir: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        for k in cache.keys where k.hasPrefix(prefix) && !k.dropFirst(prefix.count).contains("/") { cache.removeValue(forKey: k) }
        if cache.count > 20_000 { cache.removeAll() }
    }

    private func queue(for p: String) -> (String, DispatchQueue) {
        let v = Volumes.volume(for: p)?.mountPoint ?? "/"
        if let q = queues[v] { return (v, q) }
        let q = DispatchQueue(label: "photolab.tags.\(queues.count)", qos: .utility)
        queues[v] = q
        return (v, q)
    }

    private static func post(_ paths: [String]) {
        if paths.isEmpty { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .tagsChanged, object: nil, userInfo: ["paths": paths]) }
    }

    /// Read tags not yet known for `paths` (owner = one list).
    func request(_ paths: [String], owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        lock.lock()
        wanted[key] = Set(paths)
        let missing = paths.filter { cache[$0] == nil && !inFlight.contains($0) }
        for p in missing { inFlight.insert(p) }
        var byQueue: [String: (DispatchQueue, [String])] = [:]
        for p in missing { let (v, q) = queue(for: p); byQueue[v, default: (q, [])].1.append(p) }
        lock.unlock()
        for (_, (q, ps)) in byQueue {
            q.async { [weak self] in
                guard let me = self else { return }
                var read: [String] = []
                for p in ps {
                    me.lock.lock(); let still = me.wanted[key]?.contains(p) ?? false; me.lock.unlock()
                    if still && me.readOne(p) { read.append(p) }
                    me.lock.lock(); me.inFlight.remove(p); me.lock.unlock()
                }
                TagLoader.post(read)
            }
        }
    }

    /// FSEvents said these changed: read them again if we know them.
    func reread(_ paths: [String]) {
        lock.lock()
        let known = paths.filter { cache[$0] != nil }
        var byQueue: [String: (DispatchQueue, [String])] = [:]
        for p in known { let (v, q) = queue(for: p); byQueue[v, default: (q, [])].1.append(p) }
        lock.unlock()
        for (_, (q, ps)) in byQueue {
            q.async { [weak self] in
                guard let me = self else { return }
                TagLoader.post(ps.filter { me.readOne($0) })
            }
        }
    }

    /// The light check for shares (other Macs' changes are not reported by macOS): one stat per
    /// row on screen - usually answered from the SMB client's attribute cache - and a tag read
    /// only where the change time moved. Skipped while the previous check of that volume runs.
    func recheck(_ paths: [String]) {
        lock.lock()
        var byQueue: [String: (DispatchQueue, [String])] = [:]
        for p in paths where cache[p] != nil { let (v, q) = queue(for: p); byQueue[v, default: (q, [])].1.append(p) }
        let run = byQueue.filter { !recheckBusy.contains($0.key) }
        for v in run.keys { recheckBusy.insert(v) }
        lock.unlock()
        for (v, (q, ps)) in run {
            q.async { [weak self] in
                guard let me = self else { return }
                var changed: [String] = []
                for p in ps {
                    me.lock.lock(); let old = me.cache[p]?.ctime; me.lock.unlock()
                    guard let c = TagLoader.ctime(p), c != old else { continue }
                    if me.readOne(p) { changed.append(p) }
                }
                me.lock.lock(); me.recheckBusy.remove(v); me.lock.unlock()
                TagLoader.post(changed)
            }
        }
    }

    func release(owner: AnyObject) {
        lock.lock(); wanted.removeValue(forKey: ObjectIdentifier(owner)); lock.unlock()
    }
}

/// FSEvents for the folders on screen (each window's folder and its expanded folders): reports
/// tag (xattr) changes made on this Mac, on local disks and on shares, with no polling.
/// macOS does not report changes made by other Macs on a share; TagLoader.recheck covers those.
final class TagWatcher {
    static let shared = TagWatcher()
    private var stream: FSEventStreamRef?
    private var folders: [ObjectIdentifier: Set<String>] = [:]
    private var current = Set<String>()
    private let queue = DispatchQueue(label: "photolab.fsevents", qos: .utility)
    private(set) var events = 0

    /// Main thread.
    func update(owner: AnyObject, folders f: Set<String>) {
        folders[ObjectIdentifier(owner)] = f
        let all = folders.values.reduce(Set<String>()) { $0.union($1) }
        if all != current { current = all; restart() }
    }

    func remove(owner: AnyObject) { update(owner: owner, folders: []); folders.removeValue(forKey: ObjectIdentifier(owner)) }

    fileprivate func changed(_ paths: [String]) {
        events += paths.count
        TagLoader.shared.reread(paths)
    }

    private func restart() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        guard !current.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info = info else { return }
            let me = Unmanaged<TagWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            let mask = UInt32(kFSEventStreamEventFlagItemXattrMod) | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
            var hit: [String] = []
            for i in 0..<min(count, arr.count) where flags[i] & mask != 0 { hit.append(arr[i]) }
            if !hit.isEmpty { me.changed(hit) }
        }
        let createFlags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, Array(current) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, createFlags) else {
            Log.warn("W-TAG-1 FSEvents stream not created for \(current.count) folder(s); tags update on refresh")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }
}
