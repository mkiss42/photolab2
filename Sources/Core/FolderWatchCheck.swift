// FolderWatchCheck.swift
// macOS folder watching (kqueue) can report "deleted" or "renamed" for a folder that is still
// there. Network shares (SMB/AFP) do this for ordinary changes such as a new item being created.
// So a watch event is only a hint. Before Find leaves a folder it is showing, it checks the disk:
// the folder must be missing twice, a moment apart. Anything else means stay and refresh.
// Read-only: this file never changes anything on disk.

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

/// Identity of a watched folder, taken when watching starts.
struct FolderIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    static func of(_ path: String) -> FolderIdentity? {
        var e: Int32 = 0
        guard let i = Sys.lstatInfo(path, &e), i.isDirectory else { return nil }
        return FolderIdentity(device: i.device, inode: i.inode)
    }

    static func == (a: FolderIdentity, b: FolderIdentity) -> Bool {
        return a.device == b.device && a.inode == b.inode
    }
}

enum WatchVerdict: Equatable {
    /// Same folder, still at its path: just refresh the list.
    case stillThere
    /// A folder is at the path but it is a different one (replaced): refresh, stay.
    case replaced
    /// Confirmed missing (twice): go to the nearest folder that exists.
    case gone
    /// The disk could not be asked (share disconnected, permission, I/O error): stay,
    /// refresh, and let the list show its "can't open this folder" notice.
    case unreachable(Int32)

    var name: String {
        switch self {
        case .stillThere: return "still-there"
        case .replaced: return "replaced"
        case .gone: return "gone"
        case .unreachable(let e): return "unreachable-errno-\(e)"
        }
    }

    static func == (a: WatchVerdict, b: WatchVerdict) -> Bool { return a.name == b.name }
}

enum FolderWatchCheck {
    /// One look at the disk. `isMissing` is true only when lstat says ENOENT/ENOTDIR,
    /// or something that is not a folder now has the name.
    static func look(_ path: String, watched: FolderIdentity?) -> (verdict: WatchVerdict, isMissing: Bool) {
        var e: Int32 = 0
        if let i = Sys.lstatInfo(path, &e) {
            if !i.isDirectory { return (.gone, true) }
            if let w = watched, w != FolderIdentity(device: i.device, inode: i.inode) { return (.replaced, false) }
            return (.stillThere, false)
        }
        if e == ENOENT || e == ENOTDIR { return (.gone, true) }
        return (.unreachable(e), false)
    }

    /// Full check after a delete/rename event. Blocking (call off the main thread).
    /// Missing must be seen twice, `pause` seconds apart, before the verdict is `.gone`.
    static func verify(_ path: String, watched: FolderIdentity?, pause: Double = 1.0) -> WatchVerdict {
        let first = look(path, watched: watched)
        if !first.isMissing { return first.verdict }
        if pause > 0 { usleep(useconds_t(pause * 1_000_000)) }
        let second = look(path, watched: watched)
        return second.verdict
    }
}
