// FileSets.swift  (ported from PhotoLab 2 0.9.2; PhotoLab 1's GROUPABLE_EXTENSIONS)
// One row per set in the list (lab decision 2026-11-25): the files of a set - a RAW, its JPEG/HEIC
// and its XMP/ACR sidecar with the same name - are shown as one row, by a representative member
// (the RAW if there is one, else the JPEG/HEIC, else the sidecar), with the members' total size and
// an Ext label like "NEF+JPG+XMP". Commands on that row (copy, move, trash, rename, drag) act on
// every member. Pure: works on listings only, no file is read.

import Foundation

struct SetRow {
    /// The representative; its size is all members together.
    let entry: FileEntry
    /// Ordinary files and folders: empty. A set: every member, in rank order (representative first).
    let members: [FileEntry]
}

enum FileSets {
    /// Settings: show sets as one row (default on).
    static var enabled: Bool {
        get { return UserDefaults.standard.object(forKey: "fileSets") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fileSets") }
    }

    static let others: Set<String> = ["xmp", "acr", "jpg", "jpeg", "heic", "heif"]

    static func groupable(_ name: String) -> Bool {
        return PhotoFormats.isRaw(name) || others.contains(Paths.fileExtension(name).lowercased())
    }

    /// "DSC_1" and "NEF" from "DSC_1.NEF" (the last dot; a leading dot is part of the name).
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[name.startIndex..<dot]), String(name[name.index(after: dot)...]))
    }

    /// 0 RAW, 1 JPEG/HEIC, 2 sidecar: representative choice and Ext order.
    static func rank(_ name: String) -> Int {
        if PhotoFormats.isRaw(name) { return 0 }
        let e = Paths.fileExtension(name).lowercased()
        return e == "xmp" || e == "acr" ? 2 : 1
    }

    static func rows(_ entries: [FileEntry]) -> [SetRow] {
        var byStem: [String: [FileEntry]] = [:]
        var order: [String] = []
        var out: [SetRow] = []
        for e in entries {
            guard e.kind == .file, groupable(e.name) else {
                out.append(SetRow(entry: e, members: []))
                continue
            }
            let stem = split(e.name).stem
            if byStem[stem] == nil { order.append(stem) }
            byStem[stem, default: []].append(e)
        }
        for stem in order {
            let m = byStem[stem]!.sorted { a, b in
                let ra = rank(a.name), rb = rank(b.name)
                return ra != rb ? ra < rb : a.name < b.name
            }
            if m.count == 1 { out.append(SetRow(entry: m[0], members: [])); continue }
            var rep = m[0]
            rep.size = m.reduce(Int64(0)) { $0 + max(0, $1.size) }
            out.append(SetRow(entry: rep, members: m))
        }
        return out
    }

    /// "NEF+JPG+XMP" (members in rank order); a single file: its extension.
    static func extLabel(_ name: String, members: [FileEntry]) -> String {
        if members.isEmpty { return split(name).ext.uppercased() }
        return members.map { split($0.name).ext.uppercased() }.joined(separator: "+")
    }

    /// Renaming a set's row to `newName`: every member gets the new stem, keeping its own extension.
    /// Nil when the extension of the row itself would change (then only that file is renamed).
    static func renames(members: [FileEntry], repName: String, newName: String) -> [(path: String, newName: String)]? {
        let old = split(repName), new = split(newName)
        guard old.ext.lowercased() == new.ext.lowercased(), !new.stem.isEmpty else { return nil }
        return members.map { m in
            let ext = split(m.name).ext
            return (m.path, new.stem + (ext.isEmpty ? "" : "." + ext))
        }
    }

    /// "7 items (1 set, 9 total)" parts: rows, sets, files.
    static func counts(_ rows: [(entry: FileEntry, members: [FileEntry])]) -> (rows: Int, sets: Int, files: Int) {
        var sets = 0, files = 0
        for r in rows {
            if r.members.isEmpty { files += 1 } else { sets += 1; files += r.members.count }
        }
        return (rows.count, sets, files)
    }
}
