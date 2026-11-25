// Volumes.swift
// Mounted volumes from the kernel mount table (getfsstat with MNT_NOWAIT: never asks a server
// anything, so a dead share cannot block us). Refreshed on mount/unmount notifications.

import Foundation
import Darwin

struct VolumeInfo {
    let mountPoint: String
    let source: String        // "/dev/disk3s1", "//anna@nas.local/Shoots"
    let fsType: String        // "apfs", "smbfs", ...
    let isLocal: Bool
    let isBrowsable: Bool     // not MNT_DONTBROWSE (system, VM, recovery volumes)
    let isRoot: Bool

    var isNetwork: Bool { return !isLocal }

    var displayName: String {
        if isRoot { return "Macintosh HD" }
        return Paths.name(mountPoint)
    }
}

enum Volumes {
    private static let lock = NSLock()
    private static var cached: [VolumeInfo] = []

    static func refresh() {
        let fresh = readMountTable()
        lock.lock(); cached = fresh; lock.unlock()
    }

    static var all: [VolumeInfo] {
        lock.lock()
        let current = cached
        lock.unlock()
        if !current.isEmpty { return current }
        refresh()
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Volumes to show in the sidebar: the start-up disk plus browsable mounts.
    static var browsable: [VolumeInfo] {
        return all.filter { $0.isRoot || ($0.isBrowsable && $0.mountPoint.hasPrefix("/Volumes/")) }
    }

    /// The volume a path lives on (longest mount-point prefix).
    static func volume(for path: String) -> VolumeInfo? {
        var best: VolumeInfo?
        for v in all {
            let mp = v.mountPoint
            let under = mp == "/" || path == mp || path.hasPrefix(mp.hasSuffix("/") ? mp : mp + "/")
            if under && mp.count > (best?.mountPoint.count ?? -1) { best = v }
        }
        return best
    }

    static func isNetwork(_ path: String) -> Bool {
        return volume(for: path)?.isNetwork ?? false
    }

    private static func string<T>(_ tuple: inout T) -> String {
        return withUnsafePointer(to: &tuple) { p -> String in
            return p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    static func readMountTable() -> [VolumeInfo] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buf = [statfs](repeating: statfs(), count: Int(count) + 8)
        let got = buf.withUnsafeMutableBufferPointer { p -> Int32 in
            return getfsstat(p.baseAddress, Int32(p.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard got > 0 else { return [] }
        var out: [VolumeInfo] = []
        for i in 0..<Int(got) {
            var s = buf[i]
            let mp = string(&s.f_mntonname)
            let type = string(&s.f_fstypename)
            if ["devfs", "autofs", "nullfs", "lifs"].contains(type) { continue }
            let flags = UInt32(s.f_flags)
            out.append(VolumeInfo(mountPoint: mp, source: string(&s.f_mntfromname), fsType: type,
                                  isLocal: flags & UInt32(MNT_LOCAL) != 0,
                                  isBrowsable: flags & UInt32(MNT_DONTBROWSE) == 0,
                                  isRoot: mp == "/"))
        }
        return out
    }
}
