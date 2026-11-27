// BatchRename.swift
// Batch rename rules and the checked plan (old name -> new name) shown in the live preview.
// Pure Foundation, tested on Linux. Renaming itself happens in FileOperations.renameBatch.

import Foundation

enum RenameMode: Int {
    case replace = 0, addText, format, changeCase
    static let titles = ["Replace Text", "Add Text", "Format (name + number)", "Change Case"]
}

enum CaseChange: Int {
    case lower = 0, upper, title
    static let titles = ["lowercase", "UPPERCASE", "Title Case"]
}

enum ExtensionCase: Int {
    case keep = 0, lower, upper
    static let titles = ["Keep extension as it is", "Extension lowercase", "Extension UPPERCASE"]
}

struct RenameRule {
    var mode = RenameMode.replace
    // Replace
    var find = ""
    var replaceWith = ""
    var caseSensitive = false
    // Add text
    var addText = ""
    var addAtStart = false
    // Format
    var baseName = ""
    var startAt = 1
    var digits = 3
    var separator = "_"
    var numberFirst = false
    // Change case
    var caseChange = CaseChange.lower
    // Extension (all modes)
    var extensionCase = ExtensionCase.keep

    /// New name for `name`, the `index`-th item (0-based) of the batch. The extension is kept apart
    /// (folders have none), so rules change the name part only.
    func apply(to name: String, index: Int, isFolder: Bool) -> String {
        // The extension as written in the name (fileExtension gives it lowercased).
        let extLen = isFolder ? 0 : Paths.fileExtension(name).count
        let ext = extLen == 0 ? "" : String(name.suffix(extLen))
        var base = isFolder || ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        switch mode {
        case .replace:
            if !find.isEmpty {
                base = base.replacingOccurrences(of: find, with: replaceWith,
                                                 options: caseSensitive ? [] : [.caseInsensitive])
            }
        case .addText:
            base = addAtStart ? addText + base : base + addText
        case .format:
            var n = String(startAt + index)
            if n.count < digits { n = String(repeating: "0", count: digits - n.count) + n }
            let b = baseName.isEmpty ? base : baseName
            base = numberFirst ? n + separator + b : b + separator + n
        case .changeCase:
            switch caseChange {
            case .lower: base = base.lowercased()
            case .upper: base = base.uppercased()
            case .title: base = base.capitalized
            }
        }
        if ext.isEmpty { return base }
        let e: String
        switch extensionCase {
        case .keep: e = ext
        case .lower: e = ext.lowercased()
        case .upper: e = ext.uppercased()
        }
        return base + "." + e
    }
}

struct RenamePlanItem {
    let path: String
    let oldName: String
    let newName: String
    /// nil = fine; otherwise why this item can't be renamed.
    var problem: String?
    var unchanged: Bool { return oldName == newName }
}

struct RenamePlan {
    var items: [RenamePlanItem] = []
    var problems: Int { return items.filter { $0.problem != nil }.count }
    var changes: Int { return items.filter { !$0.unchanged && $0.problem == nil }.count }
    var canRun: Bool { return problems == 0 && changes > 0 }

    /// Check every new name: valid, not the same as another new name in the folder, and not the name
    /// of a file that isn't part of the batch. Names are compared ignoring case (macOS volumes usually
    /// are case-insensitive). `existing` gives the names already in a folder.
    static func make(paths: [String], isFolder: (String) -> Bool, rule: RenameRule,
                     existing: (String) -> [String]) -> RenamePlan {
        var plan = RenamePlan()
        for (i, p) in paths.enumerated() {
            let old = Paths.lastComponent(p)
            plan.items.append(RenamePlanItem(path: p, oldName: old, newName: rule.apply(to: old, index: i, isFolder: isFolder(p)), problem: nil))
        }
        // Per folder: names leaving (the batch's old names) and names arriving.
        var byDir: [String: [Int]] = [:]
        for (i, it) in plan.items.enumerated() { byDir[Paths.parent(it.path), default: []].append(i) }
        for (dir, idx) in byDir {
            let leaving = Set(idx.map { plan.items[$0].oldName.lowercased() })
            let others = Set(existing(dir).map { $0.lowercased() }).subtracting(leaving)
            var seen: [String: Int] = [:]
            for i in idx {
                let n = plan.items[i].newName
                if let why = FileOperations.nameProblem(n) {
                    plan.items[i].problem = why
                    continue
                }
                let key = n.lowercased()
                if let j = seen[key] {
                    plan.items[i].problem = "same new name as \"\(plan.items[j].oldName)\""
                    if plan.items[j].problem == nil { plan.items[j].problem = "same new name as \"\(plan.items[i].oldName)\"" }
                    continue
                }
                seen[key] = i
                if !plan.items[i].unchanged && others.contains(key) {
                    plan.items[i].problem = "\"\(n)\" already exists in this folder"
                }
            }
        }
        return plan
    }
}
