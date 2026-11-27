// FolderCompare.swift
// Compare two folders (optionally with all subfolders): what is only on one side, what differs, what is
// the same. Matching is by relative path. "Same" means same kind and size, plus either the same
// modified date (quick) or identical contents (byte-for-byte, when asked). Read-only.

import Foundation

enum CompareStatus: Int {
    case onlyLeft = 0, onlyRight, different, same
    static let titles = ["Only in left", "Only in right", "Different", "Same"]
}

struct CompareRow {
    let relPath: String
    let status: CompareStatus
    let left: FileEntry?
    let right: FileEntry?
    /// Why "different": "size", "date", "contents", "kind".
    let why: String
}

struct CompareResult {
    var rows: [CompareRow] = []
    var problems: [ReadProblem] = []
    var cancelled = false
    var foldersScanned = 0
    func count(_ s: CompareStatus) -> Int { return rows.filter { $0.status == s }.count }
}

enum FolderCompare {
    /// Compare `left` and `right`. `checkContents` reads both files when size matches (slow on big files).
    /// Folders present on one side only are listed once (their contents are not listed separately).
    static func compare(_ left: String, _ right: String, recursive: Bool, checkContents: Bool,
                        includeHidden: Bool = false, isCancelled: () -> Bool = { return false },
                        progress: ((Int) -> Void)? = nil) -> CompareResult {
        var result = CompareResult()
        var queue: [String] = [""]   // relative folders to compare
        while !queue.isEmpty {
            if isCancelled() { result.cancelled = true; return result }
            let rel = queue.removeFirst()
            let l = DirectoryReader.read(rel.isEmpty ? left : Paths.join(left, rel), includeHidden: includeHidden, isCancelled: isCancelled)
            let r = DirectoryReader.read(rel.isEmpty ? right : Paths.join(right, rel), includeHidden: includeHidden, isCancelled: isCancelled)
            result.foldersScanned += 1
            progress?(result.foldersScanned)
            if let e = l.folderError { result.problems.append(e) }
            if let e = r.folderError { result.problems.append(e) }
            result.problems += l.problems + r.problems
            var lm: [String: FileEntry] = [:], rm: [String: FileEntry] = [:]
            for e in l.entries { lm[e.name.precomposedStringWithCanonicalMapping] = e }
            for e in r.entries { rm[e.name.precomposedStringWithCanonicalMapping] = e }
            let names = Set(lm.keys).union(rm.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for n in names {
                let relPath = rel.isEmpty ? n : rel + "/" + n
                let a = lm[n], b = rm[n]
                if let a = a, b == nil {
                    result.rows.append(CompareRow(relPath: relPath, status: .onlyLeft, left: a, right: nil, why: ""))
                    continue
                }
                if let b = b, a == nil {
                    result.rows.append(CompareRow(relPath: relPath, status: .onlyRight, left: nil, right: b, why: ""))
                    continue
                }
                guard let x = a, let y = b else { continue }
                let xDir = x.kind == .directory, yDir = y.kind == .directory
                if xDir != yDir {
                    result.rows.append(CompareRow(relPath: relPath, status: .different, left: x, right: y, why: "kind"))
                    continue
                }
                if xDir {
                    if recursive { queue.append(relPath) }
                    continue
                }
                if x.size != y.size {
                    result.rows.append(CompareRow(relPath: relPath, status: .different, left: x, right: y, why: "size"))
                } else if checkContents {
                    let same = FileCompare.identical(x.path, y.path, isCancelled: isCancelled)
                    result.rows.append(CompareRow(relPath: relPath, status: same == true ? .same : .different, left: x, right: y,
                                                  why: same == nil ? "could not be read" : (same! ? "" : "contents")))
                } else if abs(x.modified - y.modified) > 2.0 {
                    // 2 s slack: FAT/exFAT and some network shares store times coarsely.
                    result.rows.append(CompareRow(relPath: relPath, status: .different, left: x, right: y, why: "date"))
                } else {
                    result.rows.append(CompareRow(relPath: relPath, status: .same, left: x, right: y, why: ""))
                }
            }
        }
        return result
    }

    /// Plain numbered ASCII report (AutoType-safe).
    static func report(_ r: CompareResult, left: String, right: String, recursive: Bool, checkContents: Bool) -> String {
        let rep = Report(title: "Find Folder Comparison")
        rep.addSummary("LEFT \(left)")
        rep.addSummary("RIGHT \(right)")
        rep.addSummary("MODE \(recursive ? "with subfolders" : "this folder only"), \(checkContents ? "contents compared byte for byte" : "size and date")")
        for s in [CompareStatus.onlyLeft, .onlyRight, .different, .same] {
            rep.addSummary("\(CompareStatus.titles[s.rawValue].uppercased()) \(r.count(s))")
        }
        rep.addSummary("FOLDERS COMPARED \(r.foldersScanned)")
        if !r.problems.isEmpty { rep.addSummary("UNREADABLE \(r.problems.count)") }
        if r.cancelled { rep.addSummary("STOPPED BEFORE THE END") }
        for row in r.rows where row.status != .same {
            rep.add("\(CompareStatus.titles[row.status.rawValue].uppercased())\(row.why.isEmpty ? "" : " (" + row.why + ")") \(row.relPath)")
        }
        for p in r.problems { rep.add("UNREADABLE \(p.path): \(p.reason)") }
        return rep.render()
    }
}

enum FileCompare {
    /// Byte-for-byte comparison. nil when either file can't be read.
    static func identical(_ a: String, _ b: String, isCancelled: () -> Bool = { return false }) -> Bool? {
        guard let fa = FileHandle(forReadingAtPath: a), let fb = FileHandle(forReadingAtPath: b) else { return nil }
        var ra: Int64 = 0, rb: Int64 = 0
        defer { fa.closeFile(); fb.closeFile(); IOLog.smallRead(a, bytes: ra); IOLog.smallRead(b, bytes: rb) }
        let chunk = 1 << 20
        while true {
            if isCancelled() { return nil }
            let da = fa.readData(ofLength: chunk)
            let db = fb.readData(ofLength: chunk)
            ra += Int64(da.count); rb += Int64(db.count)
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }
}
