// DirectoryReader.swift
// Reads one folder with readdir + lstat. Read-only: opens nothing for writing.
// Every entry that can't be read is reported, never dropped silently.

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

struct ReadProblem {
    let path: String
    let code: Int32
    let reason: String
}

struct FolderReadResult {
    var entries: [FileEntry] = []
    /// Set when the folder itself could not be opened.
    var folderError: ReadProblem? = nil
    /// Entries that were listed but could not be examined.
    var problems: [ReadProblem] = []
    var cancelled = false
    /// Count of hidden entries left out because hidden files are not shown.
    var hiddenSkipped = 0
}

/// One entry from a bulk listing (macOS getattrlistbulk): everything needed without a per-item lstat.
struct BulkItem {
    let name: String
    let info: StatInfo
    /// Date Added (0 when the file system doesn't keep it).
    let added: Double
}

/// What a bulk listing reported. `ok` false with nothing emitted means "use readdir instead".
struct BulkOutcome {
    let ok: Bool
    let error: Int32
    let emitted: Int
}

enum DirectoryReader {
    /// Set by the macOS layer at start-up (getattrlistbulk: many entries per request, which matters most
    /// on network shares). nil on Linux and whenever it has been switched off: readdir + lstat is used.
    static var bulkLister: ((String, () -> Bool, (BulkItem) -> Void) -> BulkOutcome)? = nil

    /// Read `dir`. `batch` is called with partial results every `batchSize` entries (may be nil).
    /// `isCancelled` is checked between entries.
    static func read(_ dir: String,
                     includeHidden: Bool,
                     batchSize: Int = 1000,
                     batch: (([FileEntry]) -> Void)? = nil,
                     isCancelled: () -> Bool = { return false },
                     addedDate: ((String) -> Double)? = nil) -> FolderReadResult {
        // 0.18: a folder read on a share is a line in the network I/O log (items, time).
        guard let log = IOLog.network, IOLog.isNetworkPath(dir) else {
            return readInner(dir, includeHidden: includeHidden, batchSize: batchSize, batch: batch, isCancelled: isCancelled, addedDate: addedDate)
        }
        let t0 = Date()
        let r = readInner(dir, includeHidden: includeHidden, batchSize: batchSize, batch: batch, isCancelled: isCancelled, addedDate: addedDate)
        let n = r.entries.count + r.hiddenSkipped
        log.record("FOLDER-READ items=\(n)" + (r.cancelled ? " (stopped)" : ""), seconds: Date().timeIntervalSince(t0), detail: dir,
                   error: r.folderError != nil ? "E-READ" : nil)
        return r
    }

    private static func readInner(_ dir: String,
                     includeHidden: Bool,
                     batchSize: Int,
                     batch: (([FileEntry]) -> Void)?,
                     isCancelled: () -> Bool,
                     addedDate: ((String) -> Double)?) -> FolderReadResult {
        var result = FolderReadResult()
        // 0.18.14: a name the server lists twice (it happens on shares while files are renamed) is listed once.
        var seenNames = Set<String>()
        if let bulk = bulkLister {
            var pending: [FileEntry] = []
            let out = bulk(dir, isCancelled) { item in
                if !seenNames.insert(item.name).inserted { return }
                let path = Paths.join(dir, item.name)
                var entry = FileEntry.make(name: item.name, path: path, info: item.info)
                entry.added = item.added
                if entry.isHidden && !includeHidden {
                    result.hiddenSkipped += 1
                    return
                }
                result.entries.append(entry)
                if let b = batch {
                    pending.append(entry)
                    if pending.count >= batchSize {
                        b(pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
            }
            if out.ok {
                if isCancelled() { result.cancelled = true }
                return result
            }
            if out.emitted > 0 {
                result.problems.append(ReadProblem(path: dir, code: out.error,
                                                   reason: "folder listing stopped early: " + Sys.errorText(out.error)))
                return result
            }
            // Nothing listed: fall back to readdir + lstat (it also reports a folder that can't be opened).
            result = FolderReadResult()
            seenNames.removeAll()
        }
        guard let d = opendir(dir) else {
            let e = errno
            result.folderError = ReadProblem(path: dir, code: e, reason: Sys.errorText(e))
            return result
        }
        defer { closedir(d) }
        var pending: [FileEntry] = []
        while true {
            if isCancelled() {
                result.cancelled = true
                break
            }
            errno = 0
            guard let ent = readdir(d) else {
                let e = errno
                if e != 0 {
                    result.problems.append(ReadProblem(path: dir, code: e,
                                                       reason: "folder listing stopped early: " + Sys.errorText(e)))
                }
                break
            }
            let nameOpt: String? = withUnsafePointer(to: &ent.pointee.d_name) { ptr -> String? in
                return ptr.withMemoryRebound(to: CChar.self, capacity: 1024) { cs -> String? in
                    return String(validatingUTF8: cs)
                }
            }
            guard let name = nameOpt else {
                result.problems.append(ReadProblem(path: dir, code: 0, reason: "an entry has a name that is not valid UTF-8"))
                continue
            }
            if name == "." || name == ".." { continue }
            if !seenNames.insert(name).inserted { continue }
            let path = Paths.join(dir, name)
            var err: Int32 = 0
            guard let info = Sys.lstatInfo(path, &err) else {
                if err == ENOENT { continue } // removed between readdir and lstat: not an error
                result.problems.append(ReadProblem(path: path, code: err, reason: Sys.errorText(err)))
                continue
            }
            var entry = FileEntry.make(name: name, path: path, info: info)
            if let ad = addedDate { entry.added = ad(path) }
            if entry.isHidden && !includeHidden {
                result.hiddenSkipped += 1
                continue
            }
            result.entries.append(entry)
            if let b = batch {
                pending.append(entry)
                if pending.count >= batchSize {
                    b(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        return result
    }
}
