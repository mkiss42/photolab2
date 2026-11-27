// PhotoTree.swift
// 0.16: Photography mode "Include subfolders" - every picture in a folder tree in one grid. Read-only:
// folders are listed (DirectoryReader), nothing is opened for writing. Links to folders are not
// followed (no loops, nothing outside the tree), packages (.app, .photoslibrary...) are not entered,
// hidden folders are skipped unless hidden files are shown. Each picture keeps its own folder; XMP
// sidecars are collected too so each picture finds its own (same folder only).

import Foundation

struct PhotoTreeSummary {
    var folders = 0
    var pictures = 0
    var sidecars = 0
    var problems: [ReadProblem] = []
    var cancelled = false
    /// Stopped at the limit (too many pictures to show at once).
    var limited = false
}

enum PhotoTree {
    static let maxPictures = 100_000
    static let maxDepth = 64

    /// Walk `root`. `batch` gets pictures (and sidecars) in groups as folders are read, on this thread.
    static func collect(_ root: String, includeHidden: Bool,
                        isPackage: (String, String) -> Bool,
                        isCancelled: () -> Bool,
                        batch: ([FileEntry]) -> Void) -> PhotoTreeSummary {
        var s = PhotoTreeSummary()
        var queue: [(String, Int)] = [(root, 0)]
        var pending: [FileEntry] = []
        while !queue.isEmpty {
            if isCancelled() { s.cancelled = true; break }
            let (dir, depth) = queue.removeFirst()
            let r = DirectoryReader.read(dir, includeHidden: includeHidden, isCancelled: isCancelled)
            if r.cancelled || isCancelled() { s.cancelled = true; break }
            if let e = r.folderError { s.problems.append(e); continue }
            s.problems += r.problems
            s.folders += 1
            var subdirs: [String] = []
            for e in r.entries {
                if e.kind == .directory {
                    if depth < maxDepth && !isPackage(e.path, e.ext) { subdirs.append(e.path) }
                    continue
                }
                guard e.kind == .file else { continue }      // links (to folders or files) are not followed
                if PhotoFormats.isImage(e.name) {
                    s.pictures += 1
                    pending.append(e)
                } else if PhotoFormats.isSidecar(e.name) {
                    s.sidecars += 1
                    pending.append(e)
                }
            }
            // Subfolders in name order, before the next folder at this level's siblings (depth first).
            let sorted = subdirs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, depth + 1) }
            queue.insert(contentsOf: sorted, at: 0)
            if pending.count >= 500 || queue.isEmpty {
                batch(pending)
                pending.removeAll(keepingCapacity: true)
            }
            if s.pictures >= maxPictures { s.limited = true; break }
        }
        if !pending.isEmpty { batch(pending) }
        return s
    }

    /// Images that have an XMP sidecar in their own folder (paths), from a mixed list of many folders.
    static func picturesWithSidecars(_ entries: [FileEntry]) -> Set<String> {
        var byFolder: [String: [String]] = [:]
        for e in entries where e.kind == .file { byFolder[Paths.parent(e.path), default: []].append(e.name) }
        var out = Set<String>()
        for (dir, names) in byFolder {
            for n in Sidecars.associate(names).pairs.keys { out.insert(Paths.join(dir, n)) }
        }
        return out
    }
}
