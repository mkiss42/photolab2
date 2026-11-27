// FindReplace.swift
// 0.18: Find & Replace over a selection or a whole folder (optionally with its subfolders), in file names
// or in picture metadata (caption, headline, keywords ...). This file only works out the changes for the
// preview; renaming is FileOperations.renameBatch, metadata is FileOperations.writeMetadata (both checked,
// both one Undo). Pure Foundation, tested on Linux.

import Foundation

enum FindReplaceTarget: Int {
    case names = 0, metadata
}

struct FindReplaceQuery {
    var find = ""
    var replaceWith = ""
    var caseSensitive = false
    /// Metadata: the fields searched (default: all text fields).
    var fields: [MetaField] = MetaField.textFields

    var isEmpty: Bool { return find.isEmpty }

    /// `text` with every occurrence replaced (nil = nothing found).
    func apply(_ text: String) -> String? {
        guard !find.isEmpty, text.range(of: find, options: caseSensitive ? [] : [.caseInsensitive]) != nil else { return nil }
        return text.replacingOccurrences(of: find, with: replaceWith, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

/// One picture's metadata change for the preview: each field's old and new text.
struct MetaReplaceItem {
    let image: String
    let change: MetaChange
    let fields: [(field: MetaField, old: String, new: String)]
}

enum FindReplace {
    /// The names plan: every item whose NAME (not extension) contains the text. Uses the batch-rename
    /// checks (valid names, no clash in the folder). Items that don't contain the text are left out.
    static func namesPlan(paths: [String], isFolder: (String) -> Bool, query: FindReplaceQuery,
                          existing: (String) -> [String]) -> RenamePlan {
        var rule = RenameRule()
        rule.mode = .replace
        rule.find = query.find
        rule.replaceWith = query.replaceWith
        rule.caseSensitive = query.caseSensitive
        let hits = paths.filter { p in
            let n = Paths.lastComponent(p)
            return rule.apply(to: n, index: 0, isFolder: isFolder(p)) != n
        }
        return RenamePlan.make(paths: hits, isFolder: isFolder, rule: rule, existing: existing)
    }

    /// The metadata changes: for each picture, every chosen field whose current text contains the text.
    /// `records` = each picture's current metadata (ExifTool record of its current set), by picture path.
    static func metadataPlan(records: [String: [String: Any]], order: [String], query: FindReplaceQuery) -> [MetaReplaceItem] {
        var out: [MetaReplaceItem] = []
        guard !query.isEmpty else { return out }
        for img in order {
            guard let rec = records[img] else { continue }
            var c = MetaChange()
            var fs: [(field: MetaField, old: String, new: String)] = []
            for f in query.fields {
                let old = MetaPlan.current(f, in: rec)
                if old.isEmpty { continue }
                var replaced: String? = nil
                if f.isList {
                    // Each keyword / photographer on its own, so the separators are never touched.
                    let vals = MetaPlan.listValues(old)
                    let nv = vals.map { query.apply($0) ?? $0 }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if nv != vals { replaced = nv.joined(separator: ", ") }
                } else {
                    replaced = query.apply(old)
                }
                if let new = replaced, new != old {
                    c.set[f] = new
                    fs.append((f, old, new))
                }
            }
            if !c.isEmpty { out.append(MetaReplaceItem(image: img, change: c, fields: fs)) }
        }
        return out
    }

    /// Files to look at: the selection, or every item of the folder (and its subfolders). Hidden items,
    /// packages' insides and symbolic links are never included. `list(dir)` returns (name, isFolder).
    static func collect(folder: String, subfolders: Bool, includeFolders: Bool, limit: Int = 200_000,
                        list: (String) -> [(name: String, isFolder: Bool)]) -> (paths: [String], truncated: Bool) {
        var out: [String] = []
        var queue = [folder]
        while let dir = queue.first {
            queue.removeFirst()
            for (n, isDir) in list(dir).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                if n.hasPrefix(".") { continue }
                let p = Paths.join(dir, n)
                if isDir {
                    if includeFolders { out.append(p) }
                    if subfolders { queue.append(p) }
                } else {
                    out.append(p)
                }
                if out.count >= limit { return (out, true) }
            }
        }
        return (out, false)
    }
}
