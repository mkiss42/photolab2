// NaturalSort.swift
// Finder-style ordering: case-insensitive, numbers compared by value ("IMG_2" before "IMG_10").
// Keys are precomputed once per entry so sorting 50,000 names stays fast.

import Foundation

enum NaturalSort {
    /// Lower-cased Unicode scalar values of the name.
    static func key(_ name: String) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(name.unicodeScalars.count)
        for s in name.lowercased().unicodeScalars { out.append(s.value) }
        return out
    }

    @inline(__always) private static func isDigit(_ v: UInt32) -> Bool {
        return v >= 48 && v <= 57
    }

    /// -1, 0 or 1.
    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var i = 0, j = 0
        let na = a.count, nb = b.count
        while i < na && j < nb {
            let ca = a[i], cb = b[j]
            if isDigit(ca) && isDigit(cb) {
                // Skip leading zeros
                var si = i, sj = j
                while si < na && a[si] == 48 { si += 1 }
                while sj < nb && b[sj] == 48 { sj += 1 }
                var ei = si, ej = sj
                while ei < na && isDigit(a[ei]) { ei += 1 }
                while ej < nb && isDigit(b[ej]) { ej += 1 }
                let la = ei - si, lb = ej - sj
                if la != lb { return la < lb ? -1 : 1 }
                var k = 0
                while k < la {
                    if a[si + k] != b[sj + k] { return a[si + k] < b[sj + k] ? -1 : 1 }
                    k += 1
                }
                // Same value: fewer leading zeros first
                let za = si - i, zb = sj - j
                if za != zb { return za < zb ? -1 : 1 }
                i = ei
                j = ej
                continue
            }
            if ca != cb { return ca < cb ? -1 : 1 }
            i += 1
            j += 1
        }
        if i < na { return 1 }
        if j < nb { return -1 }
        return 0
    }

    /// Total order on names: natural order, then exact name as a tie-break so sorting is stable and deterministic.
    static func compareNames(_ x: FileEntry, _ y: FileEntry) -> Int {
        let c = compare(x.sortKey, y.sortKey)
        if c != 0 { return c }
        if x.name == y.name { return 0 }
        return x.name < y.name ? -1 : 1
    }
}

enum SortColumn: String {
    case name, modified, created, added, size, kind, match
}

struct SortSpec: Equatable {
    var column: SortColumn
    var ascending: Bool
    var foldersFirst: Bool

    static func == (l: SortSpec, r: SortSpec) -> Bool {
        return l.column == r.column && l.ascending == r.ascending && l.foldersFirst == r.foldersFirst
    }
}

enum Listing {
    /// Sort entries. `kindOf` gives the display kind text for the Kind column.
    static func sorted(_ entries: [FileEntry], by spec: SortSpec, kindOf: (FileEntry) -> String) -> [FileEntry] {
        var kinds: [String: String] = [:]
        if spec.column == .kind {
            for e in entries where kinds[e.path] == nil { kinds[e.path] = kindOf(e).lowercased() }
        }
        // 0.17.1: "folders on top" applies to Name and Kind only; by a date or by size, folders and
        // files are sorted together (the newest / biggest first, whatever it is).
        let foldersOnTop = spec.foldersFirst && spec.column != .modified && spec.column != .created
            && spec.column != .added && spec.column != .size
        return entries.sorted { (x, y) -> Bool in
            if foldersOnTop && x.isFolderLike != y.isFolderLike {
                return x.isFolderLike
            }
            var c = 0
            switch spec.column {
            case .name:
                c = 0
            case .modified:
                c = x.modified < y.modified ? -1 : (x.modified > y.modified ? 1 : 0)
            case .created:
                c = x.created < y.created ? -1 : (x.created > y.created ? 1 : 0)
            case .match:
                c = x.matchDistance < y.matchDistance ? -1 : (x.matchDistance > y.matchDistance ? 1 : 0)
            case .added:
                c = x.added < y.added ? -1 : (x.added > y.added ? 1 : 0)
            case .size:
                c = x.size < y.size ? -1 : (x.size > y.size ? 1 : 0)
            case .kind:
                let kx = kinds[x.path] ?? "", ky = kinds[y.path] ?? ""
                c = kx < ky ? -1 : (kx > ky ? 1 : 0)
            }
            if c == 0 { c = NaturalSort.compareNames(x, y) }
            return spec.ascending ? c < 0 : c > 0
        }
    }

    /// Default kind text, used when the system has no better description.
    static func basicKind(_ e: FileEntry) -> String {
        switch e.kind {
        case .directory:
            return e.ext.isEmpty ? "Folder" : "Folder (\(e.ext))"
        case .symlink:
            return e.linkToDirectory ? "Link to folder" : "Link"
        case .other:
            return "Special file"
        case .file:
            return e.ext.isEmpty ? "Document" : "\(e.ext.uppercased()) file"
        }
    }

    /// "1.2 MB" style sizes (decimal units, like Finder). Folders and links: "--".
    static func sizeText(_ bytes: Int64) -> String {
        if bytes < 0 { return "--" }
        if bytes < 1000 { return "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(bytes) / 1000.0
        var i = 0
        while v >= 1000.0 && i < units.count - 1 {
            v /= 1000.0
            i += 1
        }
        let s = v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return "\(s) \(units[i])"
    }
}
