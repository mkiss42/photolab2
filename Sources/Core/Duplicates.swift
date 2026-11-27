// Duplicates.swift
// Find files with identical contents under one or more folders. Steps: same size -> same quick hash of the
// start and end -> same full hash -> byte-for-byte equal to the group's first file. Only files that pass
// all four are reported, so a hash coincidence can never make different files look alike. Read-only.

import Foundation

struct DuplicateGroup {
    let size: Int64
    var files: [FileEntry]
    /// Space that removing all but one copy would free.
    var reclaimable: Int64 { return size * Int64(max(0, files.count - 1)) }
}

struct DuplicateResult {
    var groups: [DuplicateGroup] = []
    var filesScanned = 0
    var problems: [ReadProblem] = []
    var cancelled = false
    var reclaimable: Int64 { return groups.reduce(Int64(0)) { $0 + $1.reclaimable } }
}

enum Duplicates {
    /// `minSize`: smaller files are ignored (0-byte files are always ignored).
    static func find(in roots: [String], minSize: Int64 = 1, includeHidden: Bool = false,
                     isCancelled: () -> Bool = { return false },
                     progress: ((String, Int) -> Void)? = nil) -> DuplicateResult {
        var result = DuplicateResult()
        // 1. Every file, by size (same file reached twice through overlapping roots counts once).
        var bySize: [Int64: [FileEntry]] = [:]
        var seen = Set<String>()
        var queue = roots
        while !queue.isEmpty {
            if isCancelled() { result.cancelled = true; return result }
            let dir = queue.removeFirst()
            let r = DirectoryReader.read(dir, includeHidden: includeHidden, isCancelled: isCancelled)
            if let e = r.folderError { result.problems.append(e) }
            result.problems += r.problems
            for e in r.entries {
                if e.kind == .directory { queue.append(e.path); continue }
                guard e.kind == .file, e.size >= max(1, minSize) else { continue }
                let id = "\(e.device):\(e.inode)"
                if seen.contains(id) { continue }
                seen.insert(id)
                bySize[e.size, default: []].append(e)
                result.filesScanned += 1
            }
            progress?("Listing", result.filesScanned)
        }
        var checked = 0
        for (size, files) in bySize where files.count > 1 {
            if isCancelled() { result.cancelled = true; return result }
            // 2. Quick hash of the first and last 64 KB.
            var byQuick: [UInt64: [FileEntry]] = [:]
            for f in files {
                guard let h = hash(f.path, quick: true) else {
                    result.problems.append(ReadProblem(path: f.path, code: 0, reason: "could not be read"))
                    continue
                }
                byQuick[h, default: []].append(f)
            }
            for (_, q) in byQuick where q.count > 1 {
                // 3. Full hash (skipped for small files: the quick hash already read all of them).
                var byFull: [UInt64: [FileEntry]] = [:]
                if size <= 128 * 1024 {
                    byFull[0] = q
                } else {
                    for f in q {
                        if isCancelled() { result.cancelled = true; return result }
                        guard let h = hash(f.path, quick: false) else { continue }
                        byFull[h, default: []].append(f)
                    }
                }
                // 4. Byte-for-byte against each group's first file.
                for (_, cands) in byFull where cands.count > 1 {
                    var remaining = cands
                    while remaining.count > 1 {
                        let first = remaining.removeFirst()
                        var group = [first], rest: [FileEntry] = []
                        for c in remaining {
                            if FileCompare.identical(first.path, c.path, isCancelled: isCancelled) == true { group.append(c) } else { rest.append(c) }
                        }
                        if group.count > 1 { result.groups.append(DuplicateGroup(size: size, files: group)) }
                        remaining = rest
                    }
                }
            }
            checked += files.count
            progress?("Comparing", checked)
        }
        result.groups.sort { $0.reclaimable > $1.reclaimable }
        return result
    }

    /// 64-bit FNV-1a of the whole file, or of its first and last 64 KB (plus its size) when `quick`.
    static func hash(_ path: String, quick: Bool) -> UInt64? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        var h: UInt64 = 0xcbf29ce484222325
        var readBytes: Int64 = 0
        defer { IOLog.smallRead(path, bytes: readBytes) }   // 0.18: I/O logs
        func feed(_ d: Data) {
            readBytes += Int64(d.count)
            for b in d {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
        }
        if quick {
            let size = fh.seekToEndOfFile()
            fh.seek(toFileOffset: 0)
            feed(fh.readData(ofLength: 65536))
            if size > 131072 {
                fh.seek(toFileOffset: size - 65536)
                feed(fh.readData(ofLength: 65536))
            } else if size > 65536 {
                feed(fh.readData(ofLength: Int(size) - 65536))
            }
            return h ^ size
        }
        while true {
            let d = fh.readData(ofLength: 1 << 20)
            if d.isEmpty { break }
            feed(d)
        }
        return h
    }

    /// Which copies "keep oldest" / "keep newest" would select for removal: every copy except one per group.
    static func selectAllButOne(_ groups: [DuplicateGroup], keepNewest: Bool) -> [String] {
        var out: [String] = []
        for g in groups {
            let keep = g.files.max { keepNewest ? $0.modified < $1.modified : $0.modified > $1.modified }
            out += g.files.filter { $0.path != keep?.path }.map { $0.path }
        }
        return out
    }

    /// Safety rule: refuse a removal that would leave a group with no copy at all.
    static func groupsLeftEmpty(_ groups: [DuplicateGroup], removing paths: Set<String>) -> [DuplicateGroup] {
        return groups.filter { g in g.files.allSatisfyCompat { paths.contains($0.path) } }
    }

    static func report(_ r: DuplicateResult, roots: [String]) -> String {
        let rep = Report(title: "Find Duplicate Files")
        for root in roots { rep.addSummary("FOLDER \(root)") }
        rep.addSummary("FILES CHECKED \(r.filesScanned)")
        rep.addSummary("DUPLICATE GROUPS \(r.groups.count)")
        rep.addSummary("SPACE IN EXTRA COPIES \(r.reclaimable) bytes")
        if r.cancelled { rep.addSummary("STOPPED BEFORE THE END") }
        for (i, g) in r.groups.enumerated() {
            rep.add("GROUP \(i + 1) \(g.files.count) copies of \(g.size) bytes")
            for f in g.files { rep.add("  \(f.path)") }
        }
        for p in r.problems { rep.add("UNREADABLE \(p.path): \(p.reason)") }
        return rep.render()
    }
}
