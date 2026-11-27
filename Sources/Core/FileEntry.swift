// FileEntry.swift
// One row in a folder listing. Kept small: name, kind, size, dates, flags.

import Foundation

enum EntryKind: Int {
    case file = 0
    case directory = 1
    case symlink = 2
    case other = 3
}

struct FileEntry {
    let name: String
    let path: String
    let kind: EntryKind
    /// Bytes for files; -1 for folders until (optionally) calculated.
    var size: Int64
    let modified: Double
    let created: Double
    /// Dot-name or the macOS hidden flag.
    let isHidden: Bool
    /// For symlinks: true when the link points at a folder.
    let linkToDirectory: Bool
    let device: UInt64
    let inode: UInt64
    let permissions: UInt32
    /// Date added to its folder (macOS only; 0 when unknown or not requested).
    var added: Double = 0
    /// "Similar to" search: mistakes in the match (0 = exact); -1 otherwise.
    var matchDistance: Int = -1

    /// Lower-cased file extension without the dot ("" when none). Folders return their extension too (e.g. "app").
    var ext: String {
        return Paths.fileExtension(name)
    }

    /// True for folders and links to folders (navigable).
    var isFolderLike: Bool {
        return kind == .directory || (kind == .symlink && linkToDirectory)
    }

    /// Precomputed key for natural sorting (see NaturalSort).
    let sortKey: [UInt32]

    init(name: String, path: String, kind: EntryKind, size: Int64, modified: Double, created: Double,
         isHidden: Bool, linkToDirectory: Bool, device: UInt64, inode: UInt64, permissions: UInt32) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created
        self.isHidden = isHidden
        self.linkToDirectory = linkToDirectory
        self.device = device
        self.inode = inode
        self.permissions = permissions
        self.sortKey = NaturalSort.key(name)
    }

    /// Build an entry for any path by lstat. Returns nil if it can't be read.
    static func make(path: String, err: inout Int32) -> FileEntry? {
        guard let info = Sys.lstatInfo(path, &err) else { return nil }
        let name = Paths.lastComponent(path)
        return make(name: name, path: path, info: info)
    }

    static func make(name: String, path: String, info: StatInfo) -> FileEntry {
        var kind = EntryKind.other
        if info.isDirectory { kind = .directory }
        else if info.isSymlink { kind = .symlink }
        else if info.isRegular { kind = .file }
        var linkDir = false
        if kind == .symlink {
            var e: Int32 = 0
            if let target = Sys.statInfo(path, &e) { linkDir = target.isDirectory }
        }
        let hidden = name.hasPrefix(".") || info.hasHiddenFlag
        return FileEntry(name: name, path: path, kind: kind,
                         size: kind == .file ? info.size : -1,
                         modified: info.modified, created: info.created,
                         isHidden: hidden, linkToDirectory: linkDir,
                         device: info.device, inode: info.inode,
                         permissions: info.permissions)
    }
}

/// Path helpers on plain strings (POSIX paths).
enum Paths {
    static func join(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    static func lastComponent(_ path: String) -> String {
        if path == "/" { return "/" }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        if let r = p.range(of: "/", options: .backwards) {
            return String(p[r.upperBound...])
        }
        return p
    }

    static func parent(_ path: String) -> String {
        if path == "/" { return "/" }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        guard let r = p.range(of: "/", options: .backwards) else { return "." }
        let head = String(p[..<r.lowerBound])
        return head.isEmpty ? "/" : head
    }

    /// Lower-cased extension of a name ("" if none). A leading dot alone is not an extension.
    static func fileExtension(_ name: String) -> String {
        guard let r = name.range(of: ".", options: .backwards) else { return "" }
        if r.lowerBound == name.startIndex { return "" }
        let ext = name[r.upperBound...]
        if ext.isEmpty || ext.contains(" ") { return "" }
        return ext.lowercased()
    }

    /// Name without its extension.
    static func baseName(_ name: String) -> String {
        let ext = fileExtension(name)
        if ext.isEmpty { return name }
        return String(name.dropLast(ext.count + 1))
    }

    /// Expand ~, collapse "//", resolve "." and ".." textually. Does not touch the disk.
    static func normalize(_ input: String, home: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "~" { s = home }
        else if s.hasPrefix("~/") { s = home + String(s.dropFirst(1)) }
        if !s.hasPrefix("/") { s = "/" + s }
        var parts: [String] = []
        for comp in s.components(separatedBy: "/") {
            if comp.isEmpty || comp == "." { continue }
            if comp == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(comp)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Components for a breadcrumb: [("/", "/"), ("Users", "/Users"), ...]
    static func crumbs(_ path: String) -> [(name: String, path: String)] {
        var out: [(name: String, path: String)] = [("/", "/")]
        var acc = ""
        for comp in path.components(separatedBy: "/") where !comp.isEmpty {
            acc += "/" + comp
            out.append((comp, acc))
        }
        return out
    }

    /// True when `path` is `root` or inside it (textual check on normalized absolute paths).
    static func isInside(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let r = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(r)
    }
}
