// PreviewCache.swift
// Saved previews for files that are slow to decode (Photoshop PSD/PSB, very large TIFF): after the
// first full read, a screen-sized JPEG is kept in ~/Library/Caches/Find/Previews so the next look is
// instant. Keyed by path + size + modified date, so a changed file is read again. Capped (default 1 GB;
// least recently used previews go first) and clearable in Settings. Only ever touches Find's own folder.

import Foundation

final class PreviewCache {
    let files: AppFiles
    let dir: String
    var limitBytes: Int64
    private let lock = NSLock()
    private var writesSinceTrim = 0

    init(files: AppFiles, limitBytes: Int64 = 1 << 30) {
        self.files = files
        self.dir = Paths.join(files.cachesDir, "Previews")
        self.limitBytes = limitBytes
    }

    /// Long side of saved previews (enough for a 2560-pixel screen).
    static let pixels = 2560

    /// Files worth saving a preview for: Photoshop always, TIFF when big.
    static func worthCaching(name: String, size: Int64) -> Bool {
        let e = Paths.fileExtension(name).lowercased()
        if PhotoFormats.photoshop.contains(e) { return true }
        if PhotoFormats.tiff.contains(e) && size >= 50 * 1024 * 1024 { return true }
        return false
    }

    static func key(path: String, size: Int64, modified: Double) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(path)|\(size)|\(modified)".utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h) + ".jpg"
    }

    func get(path: String, size: Int64, modified: Double) -> Data? {
        let p = Paths.join(dir, PreviewCache.key(path: path, size: size, modified: modified))
        guard let d = FileManager.default.contents(atPath: p), d.count > 2 else { return nil }
        _ = files.setDates(p, modified: Date())   // most recently used
        return d
    }

    func put(_ data: Data, path: String, size: Int64, modified: Double) {
        let p = Paths.join(dir, PreviewCache.key(path: path, size: size, modified: modified))
        _ = files.makeDir(dir)
        _ = files.writeData(data, to: p)
        lock.lock()
        writesSinceTrim += 1
        let due = writesSinceTrim >= 20
        if due { writesSinceTrim = 0 }
        lock.unlock()
        if due { trim() }
    }

    private func items() -> [(path: String, size: Int64, used: Double)] {
        var out: [(String, Int64, Double)] = []
        for n in files.list(dir) where n.hasSuffix(".jpg") {
            let p = Paths.join(dir, n)
            var e: Int32 = 0
            if let i = Sys.lstatInfo(p, &e), i.isRegular { out.append((p, i.size, i.modified)) }
        }
        return out
    }

    var totalBytes: Int64 { return items().reduce(Int64(0)) { $0 + $1.size } }
    var count: Int { return items().count }

    /// Remove least recently used previews until the cache is under 90% of the limit.
    /// Change the size limit (any thread).
    func setLimit(_ bytes: Int64) {
        lock.lock()
        limitBytes = bytes
        lock.unlock()
    }

    private var currentLimit: Int64 {
        lock.lock(); defer { lock.unlock() }
        return limitBytes
    }

    func trim() {
        let limit = currentLimit
        var all = items()
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        if total <= limit { return }
        all.sort { $0.used < $1.used }
        for it in all {
            if total <= limit * 9 / 10 { break }
            if files.removeOwned(it.path) { total -= it.size }
        }
    }

    /// Settings > Clear: remove every saved preview (only Find's Previews folder).
    @discardableResult
    func clear() -> Bool {
        if !Sys.exists(dir) { return true }
        return files.removeOwned(dir)
    }
}
