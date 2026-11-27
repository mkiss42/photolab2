// SysCompat.swift
// Small POSIX helpers that differ between macOS (Darwin) and Linux (Glibc).
// Linux is only used to compile and test the engine; Find itself runs on macOS.

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

/// Basic facts about one filesystem object, read with lstat (links are not followed).
struct StatInfo {
    let mode: UInt32
    let size: Int64
    let modified: Double
    let created: Double
    let flags: UInt32
    let device: UInt64
    let inode: UInt64
    /// Status-change time (ctime) with nanoseconds. Changes whenever a folder's entries change and
    /// can't be set back by programs, so it is the index's "has this folder changed?" stamp.
    var changed: Double = 0

    var isDirectory: Bool { return (mode & 0o170000) == 0o040000 }
    var isSymlink: Bool { return (mode & 0o170000) == 0o120000 }
    var isRegular: Bool { return (mode & 0o170000) == 0o100000 }
    /// The macOS "hidden" file flag (UF_HIDDEN, 0x8000). Always false on Linux.
    var hasHiddenFlag: Bool { return (flags & 0x8000) != 0 }
    /// POSIX permission bits, e.g. 0o755.
    var permissions: UInt32 { return mode & 0o7777 }
}

enum Sys {
    /// Current errno value.
    static var lastError: Int32 { return errno }

    /// Human-readable text for an errno value, plain ASCII.
    static func errorText(_ code: Int32) -> String {
        guard let p = strerror(code) else { return "error \(code)" }
        return String(cString: p)
    }

    /// lstat a path. Returns nil and sets `err` on failure.
    static func lstatInfo(_ path: String, _ err: inout Int32) -> StatInfo? {
        var st = stat()
        if lstat(path, &st) != 0 {
            err = errno
            return nil
        }
        return makeInfo(st)
    }

    /// stat a path (follows symlinks).
    static func statInfo(_ path: String, _ err: inout Int32) -> StatInfo? {
        var st = stat()
        if stat(path, &st) != 0 {
            err = errno
            return nil
        }
        return makeInfo(st)
    }

    static func exists(_ path: String) -> Bool {
        var e: Int32 = 0
        return lstatInfo(path, &e) != nil
    }

    private static func makeInfo(_ st: stat) -> StatInfo {
        #if os(Linux)
        return StatInfo(mode: UInt32(st.st_mode),
                        size: Int64(st.st_size),
                        modified: Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9,
                        created: Double(st.st_ctim.tv_sec),
                        flags: 0,
                        device: UInt64(st.st_dev),
                        inode: UInt64(st.st_ino),
                        changed: Double(st.st_ctim.tv_sec) + Double(st.st_ctim.tv_nsec) / 1e9)
        #else
        return StatInfo(mode: UInt32(st.st_mode),
                        size: Int64(st.st_size),
                        modified: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                        created: Double(st.st_birthtimespec.tv_sec),
                        flags: UInt32(st.st_flags),
                        device: UInt64(UInt32(bitPattern: st.st_dev)),
                        inode: UInt64(st.st_ino),
                        changed: Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1e9)
        #endif
    }

    /// Resolve symlinks and "..". Returns nil if the path does not exist.
    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func readLink(_ path: String) -> String? {
        var buf = [Int8](repeating: 0, count: 4097)
        let n = readlink(path, &buf, 4096)
        if n < 0 { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    static var userID: UInt32 { return UInt32(getuid()) }

    /// The top folder of the drive holding `path` ("/" or "/Volumes/Name"): walk up while the device stays the same.
    static func volumeRoot(of path: String) -> String {
        var e: Int32 = 0
        guard let info = statInfo(path, &e) else { return path }
        var p = path
        while p != "/" {
            let up = Paths.parent(p)
            guard let ui = statInfo(up, &e), ui.device == info.device else { break }
            p = up
        }
        return p
    }
}

/// Run a block with an autorelease pool on macOS. Linux has no autorelease pools.
func withPool<T>(_ body: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try body()
    #else
    return try autoreleasepool { try body() }
    #endif
}
