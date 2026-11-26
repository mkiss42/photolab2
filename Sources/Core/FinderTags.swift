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

/// Background tag reads with a memory cache. Asked for rows on screen; reads that are no longer
/// wanted (scrolled away, folder left) are dropped before they cost a round trip.
final class TagLoader {
    static let shared = TagLoader()
    private let lock = NSLock()
    private var cache: [String: (tags: [FinderTag], at: Date)] = [:]
    private var wanted: [ObjectIdentifier: Set<String>] = [:]
    private var queues: [String: DispatchQueue] = [:]
    private var inFlight = Set<String>()
    let maxAge: TimeInterval = 120

    func cached(_ path: String) -> [FinderTag]? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[path], Date().timeIntervalSince(c.at) < maxAge else { return nil }
        return c.tags
    }

    func store(_ path: String, _ tags: [FinderTag]) {
        lock.lock(); cache[path] = (tags, Date()); lock.unlock()
    }

    /// A folder was read again from disk: its items' tags are read again too.
    func forgetFolder(_ dir: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        for k in cache.keys where k.hasPrefix(prefix) && !k.dropFirst(prefix.count).contains("/") { cache.removeValue(forKey: k) }
        if cache.count > 20_000 { cache.removeAll() }
    }

    /// Read tags for `paths` (owner = one list); `done` runs on the main thread per batch read.
    func request(_ paths: [String], owner: AnyObject, done: @escaping ([String]) -> Void) {
        let key = ObjectIdentifier(owner)
        lock.lock()
        let missing = paths.filter { p in
            guard let c = cache[p] else { return !inFlight.contains(p) }
            return Date().timeIntervalSince(c.at) >= maxAge && !inFlight.contains(p)
        }
        wanted[key] = Set(paths)
        for p in missing { inFlight.insert(p) }
        var byVolume: [String: [String]] = [:]
        for p in missing { byVolume[Volumes.volume(for: p)?.mountPoint ?? "/", default: []].append(p) }
        var qs: [(DispatchQueue, [String])] = []
        for (v, ps) in byVolume {
            let q = queues[v] ?? DispatchQueue(label: "photolab.tags.\(queues.count)", qos: .utility)
            queues[v] = q
            qs.append((q, ps))
        }
        lock.unlock()
        for (q, ps) in qs {
            q.async { [weak self] in
                guard let me = self else { return }
                var read: [String] = []
                for p in ps {
                    me.lock.lock(); let still = me.wanted[key]?.contains(p) ?? false; me.lock.unlock()
                    if still, let t = FinderTags.read(p) { me.store(p, t); read.append(p) }
                    me.lock.lock(); me.inFlight.remove(p); me.lock.unlock()
                }
                if !read.isEmpty { DispatchQueue.main.async { done(read) } }
            }
        }
    }

    func release(owner: AnyObject) {
        lock.lock(); wanted.removeValue(forKey: ObjectIdentifier(owner)); lock.unlock()
    }
}
