// FileReads.swift  (ported from PhotoLab 2 0.9.2)
// One reader per file, shared by everything that reads it: thumbnail, photo facts (rating, label,
// camera), the inspector and the preview. The file stays open while in use (on SMB an open is round
// trips too) and what was read stays in memory, so each part of a file crosses the network once.
// BlockReader: 64 KB blocks (256 KB for the first - headers, maker notes and image directories of
// most RAWs in one round trip); reads of 256 KB or more are kept as spans. ImageIO and CGPDFDocument
// read through it too (CGDataProvider), so their reads are batched and counted.
// Read-only: files are opened O_RDONLY. DarwinPlatform lets go of a file before changing it.

import Foundation
import Darwin
import ImageIO
import CoreGraphics

final class BlockReader {
    let size: Int64
    let path: String
    private var fd: Int32
    private var lastUse = Date()
    private var blocks: [Int64: Data] = [:]
    private var spans: [(offset: Int64, data: Data)] = []
    private let block: Int64 = 64 << 10
    private var nextBlock: Int64 = -1
    private let lock = NSLock()
    private(set) var reads = 0
    private(set) var bytes: Int64 = 0
    /// Bytes held (for FileReads' memory cap).
    private(set) var held: Int64 = 0

    init?(_ path: String) {
        self.path = path
        fd = open(path, O_RDONLY)
        if fd < 0 { return nil }
        var st = stat()
        if fstat(fd, &st) != 0 { close(fd); return nil }
        size = Int64(st.st_size)
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Close the file when idle (an open file on a share can keep other Macs from renaming or
    /// deleting it). What was read stays; the file is reopened if more is needed.
    func closeIfIdle(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 && Date().timeIntervalSince(lastUse) > seconds { close(fd); fd = -1 }
    }

    private func ensureOpen() -> Bool {
        if fd >= 0 { return true }
        fd = open(path, O_RDONLY)
        if fd < 0 { return false }
        var st = stat()
        if fstat(fd, &st) != 0 || Int64(st.st_size) != size { close(fd); fd = -1; return false }    // changed meanwhile
        return true
    }

    private func pread(_ offset: Int64, _ count: Int) -> Data? {
        guard count > 0, offset >= 0, offset < size else { return Data() }
        lastUse = Date()
        guard ensureOpen() else { return nil }
        let n = Int(min(Int64(count), size - offset))
        var d = Data(count: n)
        let got = IOLog.waiting(path) { d.withUnsafeMutableBytes { p -> Int in
            var done = 0
            while done < n {
                let r = Darwin.pread(fd, p.baseAddress!.advanced(by: done), n - done, off_t(offset) + off_t(done))
                if r < 0 { if errno == EINTR { continue }; return -1 }
                if r == 0 { break }
                done += r
            }
            return done
        } }
        if got < 0 { return nil }
        reads += 1
        bytes += Int64(got)
        FileReads.note(path, bytes: Int64(got), first: reads == 1)
        if got < n { d.count = got }
        return d
    }

    /// `count` bytes at `offset` (fewer at the end of the file), nil on a read error.
    func read(_ offset: Int64, _ count: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard offset >= 0, offset < size, count > 0 else { return Data() }
        let end = min(size, offset + Int64(count))
        // Inside a span already read?
        for s in spans where offset >= s.offset && end <= s.offset + Int64(s.data.count) {
            let a = Int(offset - s.offset)
            return s.data.subdata(in: a..<(a + Int(end - offset)))
        }
        if count >= 256 << 10 {
            guard let d = pread(offset, count) else { return nil }
            if d.count <= 64 << 20 {
                spans.append((offset, d))
                held += Int64(d.count)
                while spans.count > 3 { held -= Int64(spans.removeFirst().data.count) }
            }
            return d
        }
        var first = offset / block, last = (end - 1) / block
        if first == 0 && last < 3 { last = 3 }                     // first read: 256 KB
        // Reading on from where the last read ended (ImageIO decoding a whole picture): 1 MB at a time,
        // not one round trip per 64 KB block.
        if first > 0 && first == nextBlock && last < first + 15 { last = min(first + 15, (size - 1) / block) }
        nextBlock = last + 1
        var missing: [Int64] = []
        for b in first...last where blocks[b] == nil { missing.append(b) }
        if let lo = missing.first, let hi = missing.last {
            guard let d = pread(lo * block, Int((hi - lo + 1) * block)) else { return nil }
            var b = lo
            while b <= hi {
                let s = Int((b - lo) * block)
                if s >= d.count { break }
                let piece = d.subdata(in: s..<min(d.count, s + Int(block)))
                if blocks[b] == nil { held += Int64(piece.count) }
                blocks[b] = piece
                b += 1
            }
        }
        first = offset / block
        var out = Data(capacity: Int(end - offset))
        var pos = offset
        while pos < end {
            let b = pos / block
            guard let chunk = blocks[b] else { break }
            let s = Int(pos - b * block)
            let e = min(chunk.count, s + Int(end - pos))
            if s >= e { break }
            out.append(chunk.subdata(in: s..<e))
            pos += Int64(e - s)
        }
        return out
    }

    /// For CGDataProvider: copy into ImageIO's buffer.
    func copy(into buffer: UnsafeMutableRawPointer, offset: Int64, count: Int) -> Int {
        guard let d = read(offset, count) else { return 0 }
        d.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: d.count)
        return d.count
    }

    /// A CGDataProvider reading through this reader (ImageIO, CGPDFDocument).
    func dataProvider() -> CGDataProvider? {
        var cb = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, pos, count in
                guard let info = info else { return 0 }
                return Unmanaged<BlockReader>.fromOpaque(info).takeUnretainedValue().copy(into: buffer, offset: Int64(pos), count: count)
            },
            releaseInfo: { info in if let info = info { Unmanaged<BlockReader>.fromOpaque(info).release() } })
        return CGDataProvider(directInfo: Unmanaged.passRetained(self).toOpaque(), size: off_t(size), callbacks: &cb)
    }

    /// An ImageIO source reading through this reader.
    func imageSource(hint: CFString? = nil) -> CGImageSource? {
        var cb = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, pos, count in
                guard let info = info else { return 0 }
                return Unmanaged<BlockReader>.fromOpaque(info).takeUnretainedValue().copy(into: buffer, offset: Int64(pos), count: count)
            },
            releaseInfo: { info in if let info = info { Unmanaged<BlockReader>.fromOpaque(info).release() } })
        guard let provider = CGDataProvider(directInfo: Unmanaged.passRetained(self).toOpaque(), size: off_t(size), callbacks: &cb) else { return nil }
        var opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let h = hint { opts[kCGImageSourceTypeIdentifierHint] = h }
        return CGImageSourceCreateWithDataProvider(provider, opts as CFDictionary)
    }
}


enum FileReads {
    private static let lock = NSLock()
    private static var readers: [String: (r: BlockReader, size: Int64, mtime: Int64, used: Date)] = [:]

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

    static func note(_ path: String, bytes: Int64, first: Bool) {
        // Find's I/O logs: one "small read" per file, its bytes as they come.
        if first { IOLog.smallRead(path, bytes: bytes) } else { IOLog.smallReadBytes(path, bytes: bytes) }
        let net = IOLog.isNetworkPath(path)
        lock.lock()
        var t = net ? netTally : localTally
        if first { t.files += 1 }
        t.reads += 1
        t.bytes += bytes
        if net { netTally = t } else { localTally = t }
        lock.unlock()
    }

    private struct Tally { var files = 0, reads = 0, bytes: Int64 = 0 }
    private static var netTally = Tally(), localTally = Tally()

    /// " reads/file=2.1 KB/file=410 (session)" for the I/O logs' MINUTE lines.
    static func economy(network: Bool) -> String {
        lock.lock(); let t = network ? netTally : localTally; lock.unlock()
        guard t.files > 0 else { return "" }
        let n = Double(t.files)
        return String(format: " reads/file=%.1f KB/file=%.0f (session, %ld files)", Double(t.reads) / n, Double(t.bytes) / n / 1024, t.files)
    }

    /// "READS 812 files, 2.1 reads/file, 410 KB/file" (network volumes; thumbnails, facts, previews together).
    static var reportLine: String {
        lock.lock(); let t = netTally; lock.unlock()
        guard t.files > 0 else { return "READS none" }
        let n = Double(t.files)
        return String(format: "READS %ld files, %.1f reads/file, %.0f KB/file", t.files, Double(t.reads) / n, Double(t.bytes) / n / 1024)
    }
}
