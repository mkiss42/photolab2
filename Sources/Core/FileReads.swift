// FileReads.swift
// One reader per file, shared by everything that reads it: thumbnail, ratings/labels, the
// preview's size check and both preview sizes. The file stays open (on SMB an open is round
// trips too) and what was read stays in memory, so each part of a file crosses the network
// once. LRU: at most 64 files and 256 MB held; a reader for a file that changed (other size or
// date) is replaced. Also the "files read" figure of the Short Report.

import Foundation

enum FileReads {
    private static let lock = NSLock()
    private static var readers: [String: (r: BlockReader, size: Int64, mtime: Int64, used: Date)] = [:]
    private static var perFile: [String: (reads: Int, bytes: Int64)] = [:]
    private static var totalReads = 0, totalBytes: Int64 = 0

    private static let sweeper: DispatchSourceTimer = {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler {
            lock.lock(); let all = readers.values.map { $0.r }; lock.unlock()
            for r in all { r.closeIfIdle(3) }
        }
        t.resume()
        return t
    }()

    /// PhotoLab is about to rename, move, trash or delete `path`: let go of it first.
    static func forget(_ paths: [String]) {
        lock.lock()
        for p in paths {
            readers.removeValue(forKey: p)
            let prefix = p.hasSuffix("/") ? p : p + "/"
            for k in readers.keys where k.hasPrefix(prefix) { readers.removeValue(forKey: k) }
        }
        lock.unlock()
    }

    /// Settings > Preview delay: the selection must rest this long before the preview asks for
    /// anything (arrowing past 300 shots at key-repeat speed queues nothing). Milliseconds.
    static var previewDelayMs: Int {
        let v = UserDefaults.standard.integer(forKey: "previewDelayMs")
        return v > 0 ? v : 150
    }

    /// The shared reader for a file (size/modified from the listing tell a changed file apart).
    static func reader(_ path: String, size: Int64? = nil, modified: Double? = nil) -> BlockReader? {
        let m = modified.map { Int64($0 * 1000) } ?? -1
        lock.lock()
        if let c = readers[path], size == nil || c.size == size!, m < 0 || c.mtime == m {
            readers[path]?.used = Date()
            lock.unlock()
            return c.r
        }
        lock.unlock()
        _ = sweeper
        guard let r = BlockReader(path) else { return nil }
        lock.lock()
        readers[path] = (r, size ?? r.size, m, Date())
        // Evict: oldest first, while too many files or too much held.
        var held = readers.values.reduce(Int64(0)) { $0 + $1.r.held }
        while readers.count > 64 || held > 256 << 20 {
            guard let oldest = readers.min(by: { $0.value.used < $1.value.used }), oldest.key != path else { break }
            held -= oldest.value.r.held
            readers.removeValue(forKey: oldest.key)
        }
        lock.unlock()
        return r
    }

    static func note(_ path: String, bytes: Int64) {
        lock.lock()
        var p = perFile[path] ?? (0, 0)
        p.reads += 1; p.bytes += bytes
        perFile[path] = p
        totalReads += 1; totalBytes += bytes
        if perFile.count > 200_000 { perFile.removeAll() }
        lock.unlock()
    }

    /// "READS 812 files, 2.1 reads/file, 410 KB/file" (thumbnails, labels and previews together).
    static var reportLine: String {
        lock.lock(); defer { lock.unlock() }
        guard !perFile.isEmpty else { return "READS none" }
        let n = Double(perFile.count)
        return String(format: "READS %ld files, %.1f reads/file, %.0f KB/file", perFile.count, Double(totalReads) / n,
                      Double(totalBytes) / n / 1024)
    }
}
