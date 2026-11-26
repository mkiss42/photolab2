// FileSets.swift
// One row per set in the list (lab decision 2026-11-25): files of a set (raw + jpg/heic +
// xmp/acr with the same name, FileOperations.groupable) become one row, shown by a
// representative member - the raw if there is one, else the jpg/heic, else the sidecar - with
// the members' total size and an Ext label like "CR3+JPG+XMP". Pure: works on listings only.

import Foundation

struct SetRow {
    let entry: FileEntry          // the representative, size = all members together
    let members: [FileEntry]      // one element for ordinary files and folders
}

enum FileSets {
    /// 0 raw, 1 jpg/heic, 2 sidecar: representative choice and Ext order.
    static func rank(_ ext: String) -> Int {
        if FileOperations.rawExtensions.contains(ext) { return 0 }
        if ext == "xmp" || ext == "acr" { return 2 }
        return 1
    }

    static func rows(_ entries: [FileEntry]) -> [SetRow] {
        var byStem: [String: [FileEntry]] = [:]
        var order: [String] = []
        var out: [SetRow] = []
        for e in entries {
            guard !e.isDirectory, FileOperations.groupable.contains(e.ext) else {
                out.append(SetRow(entry: e, members: [e]))
                continue
            }
            let stem = FileOperations.split(e.name).stem
            if byStem[stem] == nil { order.append(stem) }
            byStem[stem, default: []].append(e)
        }
        for stem in order {
            let m = byStem[stem]!.sorted { a, b in
                let ra = rank(a.ext), rb = rank(b.ext)
                return ra != rb ? ra < rb : a.ext < b.ext
            }
            if m.count == 1 { out.append(SetRow(entry: m[0], members: m)); continue }
            let r = m[0]
            let total = m.reduce(Int64(0)) { $0 + $1.size }
            let newest = m.map { $0.modified }.max() ?? r.modified
            let rep = FileEntry(name: r.name, path: r.path, kind: r.kind, size: total, modified: newest,
                                created: r.created, added: r.added, flags: r.flags, permissions: r.permissions,
                                device: r.device, inode: r.inode)
            out.append(SetRow(entry: rep, members: m))
        }
        return out
    }

    /// "CR3+JPG+XMP" (members are already in rank order).
    static func extLabel(_ members: [FileEntry]) -> String {
        return members.map { FileOperations.split($0.name).ext.uppercased() }.joined(separator: "+")
    }
}
