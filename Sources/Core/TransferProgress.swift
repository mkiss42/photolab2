// TransferProgress.swift
// 0.17: progress of a copy, move or FTP transfer, for the Copies window: files x of y, bytes done of
// total, the current file (and how far it is), speed, time left, and a time-stamped diagnostics list.
// Filled in by the work (on its own thread) and read by the window (main thread): all access is locked.
// It only observes: nothing here touches files except reading sizes.

import Foundation

final class TransferProgress {
    private let lock = NSLock()
    let startedAt = Date()

    private(set) var filesTotal = 0
    private(set) var bytesTotal: Int64 = 0
    private(set) var filesDone = 0
    private(set) var bytesDone: Int64 = 0
    /// The item in progress: its name, how many files and bytes it holds, and where its unfinished copy is
    /// (Find's hidden temporary name), so the window can see how far it has got.
    private(set) var currentName = ""
    private(set) var currentFiles = 0
    private(set) var currentTotal: Int64 = 0
    private(set) var currentPartial: String?
    /// Bytes of the current item already transferred, when the work knows it (FTP: curl's percentage).
    private(set) var currentDone: Int64 = 0
    private(set) var log: [(Double, String)] = []
    private var sizes: [String: (files: Int, bytes: Int64)] = [:]
    /// 0.17.1: the file being copied INSIDE the current item (a folder's files one by one): its name,
    /// where its copy is being written, its size; and the files/bytes of the item already finished.
    private(set) var innerName = ""
    private(set) var innerCopy: String?
    private(set) var innerSize: Int64 = 0
    private(set) var innerFilesDone = 0
    private(set) var innerBytesDone: Int64 = 0
    /// Stop: the copy checks this before each file (set by whoever shows the Stop button).
    var stopCheck: (() -> Bool)?
    var stopRequested: Bool { return stopCheck?() ?? false }

    struct Snapshot {
        var filesTotal = 0, bytesTotal: Int64 = 0, filesDone = 0, bytesDone: Int64 = 0
        var name = "", currentFiles = 0, currentTotal: Int64 = 0, currentDone: Int64 = 0, partial: String?
        var innerName = "", innerCopy: String?, innerSize: Int64 = 0, innerFilesDone = 0, innerBytesDone: Int64 = 0
    }

    func state() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var s = Snapshot()
        s.filesTotal = filesTotal; s.bytesTotal = bytesTotal; s.filesDone = filesDone; s.bytesDone = bytesDone
        s.name = currentName; s.currentFiles = currentFiles; s.currentTotal = currentTotal; s.currentDone = currentDone
        s.partial = currentPartial
        s.innerName = innerName; s.innerCopy = innerCopy; s.innerSize = innerSize
        s.innerFilesDone = innerFilesDone; s.innerBytesDone = innerBytesDone
        return s
    }

    /// The size measured for `source` when the copy was planned (nil if not planned).
    func plannedBytes(_ source: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return sizes[source]?.bytes
    }

    /// A file inside the current item starts (the previous one, if any, is finished).
    func innerFile(source: String, copy: String, size: Int64) {
        lock.lock()
        if innerCopy != nil { innerFilesDone += 1; innerBytesDone += innerSize }
        innerName = Paths.lastComponent(source)
        innerCopy = copy
        innerSize = size
        lock.unlock()
    }

    private func resetInner() {
        innerName = ""; innerCopy = nil; innerSize = 0; innerFilesDone = 0; innerBytesDone = 0
    }

    func snapshot() -> (filesTotal: Int, bytesTotal: Int64, filesDone: Int, bytesDone: Int64, name: String,
                        currentFiles: Int, currentTotal: Int64, currentDone: Int64, partial: String?) {
        lock.lock(); defer { lock.unlock() }
        return (filesTotal, bytesTotal, filesDone, bytesDone, currentName, currentFiles, currentTotal, currentDone, currentPartial)
    }

    func logLines(from i: Int) -> [(Double, String)] {
        lock.lock(); defer { lock.unlock() }
        return i < log.count ? Array(log[i...]) : []
    }

    var logCount: Int {
        lock.lock(); defer { lock.unlock() }
        return log.count
    }

    func note(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        log.append((Date().timeIntervalSince(startedAt), text))
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    /// Count what is to be copied (files and bytes, per source). Links are counted, not followed.
    func plan(_ sources: [String]) {
        var all: [String: (files: Int, bytes: Int64)] = [:]
        var files = 0
        var bytes: Int64 = 0
        for s in sources {
            let m = TransferProgress.measure(s)
            all[s] = m
            files += m.files
            bytes += m.bytes
        }
        lock.lock()
        sizes = all
        filesTotal = files
        bytesTotal = bytes
        lock.unlock()
        note("Planned: \(files) files, \(TransferProgress.bytesText(bytes)) in \(sources.count) item\(sources.count == 1 ? "" : "s")")
    }

    /// Plan from known numbers (FTP: sizes from the server's listing).
    /// 0.18.2: one more item finished by work that doesn't copy (metadata writes).
    func countDone(name: String, bytes: Int64) {
        lock.lock()
        filesDone += 1
        bytesDone += bytes
        currentName = name
        lock.unlock()
    }

    func plan(files: Int, bytes: Int64) {
        lock.lock()
        filesTotal = files
        bytesTotal = bytes
        lock.unlock()
        note("Planned: \(files) files, \(TransferProgress.bytesText(bytes))")
    }

    func begin(_ source: String, name: String? = nil, size: Int64? = nil) {
        lock.lock()
        let m = sizes[source] ?? (1, size ?? 0)
        currentName = name ?? Paths.lastComponent(source)
        currentFiles = m.files
        currentTotal = size ?? m.bytes
        currentDone = 0
        currentPartial = nil
        resetInner()
        lock.unlock()
        note("Start \(name ?? Paths.lastComponent(source)) (\(TransferProgress.bytesText(size ?? m.bytes)))")
    }

    func partial(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        currentPartial = path
    }

    func current(done: Int64) {
        lock.lock(); defer { lock.unlock() }
        currentDone = done
    }

    /// The current item finished (`ok` false: failed or skipped - counted as handled, not as copied).
    func finish(_ source: String, ok: Bool, detail: String = "") {
        lock.lock()
        let m = sizes[source] ?? (1, currentTotal)
        filesDone += m.files
        bytesDone += m.bytes
        currentPartial = nil
        currentDone = 0
        currentTotal = 0
        resetInner()
        let name = currentName
        currentName = ""
        lock.unlock()
        note("\(ok ? "Done" : "Not copied") \(name)\(detail.isEmpty ? "" : " - " + detail)")
    }

    // MARK: Helpers

    static func measure(_ path: String) -> (files: Int, bytes: Int64) {
        var e: Int32 = 0
        guard let info = Sys.lstatInfo(path, &e) else { return (0, 0) }
        if !info.isDirectory { return (1, info.size) }
        var files = 0
        var bytes: Int64 = 0
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: path) else { return (0, 0) }
        while let rel = en.nextObject() as? String {
            let p = Paths.join(path, rel)
            if let i = Sys.lstatInfo(p, &e), !i.isDirectory {
                files += 1
                bytes += i.size
            }
        }
        return (files, bytes)
    }

    /// Bytes in a file or folder now (for an unfinished copy).
    static func bytesNow(_ path: String) -> Int64 {
        return measure(path).bytes
    }

    static func bytesText(_ b: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(b)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(b) bytes" : String(format: "%.1f", v) + " " + units[i]
    }

    static func timeText(_ s: Double) -> String {
        if !s.isFinite || s < 0 { return "--" }
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\(t / 60) min \(t % 60) s" }
        return "\(t / 3600) h \((t % 3600) / 60) min"
    }
}
