// FileEntry.swift
// One item in a folder listing. Built from a bulk listing record or from lstat.

import Foundation
import Darwin

struct FileEntry {
    enum Kind { case file, directory, symlink, other }

    let name: String
    let path: String
    let kind: Kind
    let size: Int64          // bytes; 0 for folders
    let modified: Double     // seconds since 1970
    let created: Double      // 0 when unknown
    var added: Double        // Date Added, 0 when unknown
    let flags: UInt32        // st_flags (UF_HIDDEN, ...)
    let permissions: UInt16
    let device: UInt64
    let inode: UInt64

    var isDirectory: Bool { return kind == .directory }
    /// Dot-names and the UF_HIDDEN flag, like Finder - except /Volumes, which is always shown so
    /// shares can be reached from "/".
    var isHidden: Bool {
        if path == "/Volumes" { return false }
        return name.hasPrefix(".") || (flags & UInt32(UF_HIDDEN)) != 0
    }

    /// Lowercased extension without the dot ("" when none).
    var ext: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Bundles that Finder shows as one item (apps, Photos libraries...).
    var isPackage: Bool {
        guard isDirectory else { return false }
        return FileEntry.packageExtensions.contains(ext)
    }

    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary",
                                                  "lrlibrary", "cocatalog", "plugin", "rtfd", "pages",
                                                  "numbers", "key", "fcpbundle", "logicx", "band"]

    static func make(name: String, dir: String, mode: UInt32, size: Int64, modified: Double,
                     created: Double, added: Double, flags: UInt32, device: UInt64, inode: UInt64) -> FileEntry {
        let kind: Kind
        switch mode & UInt32(S_IFMT) {
        case UInt32(S_IFDIR): kind = .directory
        case UInt32(S_IFREG): kind = .file
        case UInt32(S_IFLNK): kind = .symlink
        default: kind = .other
        }
        return FileEntry(name: name, path: Paths.join(dir, name), kind: kind,
                         size: kind == .directory ? 0 : size, modified: modified, created: created,
                         added: added, flags: flags, permissions: UInt16(mode & 0o7777),
                         device: device, inode: inode)
    }
}

enum Paths {
    static func join(_ dir: String, _ name: String) -> String {
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    static func parent(_ path: String) -> String {
        if path == "/" { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        if slash == trimmed.startIndex { return "/" }
        return String(trimmed[trimmed.startIndex..<slash])
    }

    static func name(_ path: String) -> String {
        if path == "/" { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// "/a/b/c" -> ["/", "/a", "/a/b", "/a/b/c"]
    static func ancestry(_ path: String) -> [String] {
        var out: [String] = []
        var p = path
        while true {
            out.append(p)
            if p == "/" { break }
            p = parent(p)
        }
        return out.reversed()
    }
}

/// Finder-like ordering: natural number order, case-insensitive; optionally folders first.
enum EntrySort {
    enum Key: String { case name, ext, modified, size, kind }

    static func sort(_ entries: [FileEntry], by key: Key, ascending: Bool, foldersFirst: Bool) -> [FileEntry] {
        return entries.sorted { a, b in
            if foldersFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
            let r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .modified: r = a.modified == b.modified ? a.name.localizedStandardCompare(b.name)
                : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            case .size: r = a.size == b.size ? a.name.localizedStandardCompare(b.name)
                : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .kind, .ext:
                let k = a.ext.compare(b.ext)
                r = k == .orderedSame ? a.name.localizedStandardCompare(b.name) : k
            }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}
