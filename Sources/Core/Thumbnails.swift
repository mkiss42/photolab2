// Thumbnails.swift
// Contact sheet thumbnails (512 px on the long side), made in the background and kept twice:
// in memory (NSCache) and as small JPEG files in ~/Library/Caches/PhotoLab2/thumbs (AppFiles
// writes them), keyed by path + size + modification time - a changed file is a new key, so a
// stale thumbnail can never show. (PLAN.md section 5: the key becomes volume id + relative path
// when the shared cache arrives.)
//
// What is read from the share:
// - RAW: ImageIO's embedded thumbnail/preview (a small part of the file); if the camera only
//   embeds a tiny one, Quick Look's thumbnail, which also uses the embedded preview.
// - JPEG/HEIC/TIFF/PNG/PSD: ImageIO decodes at reduced size.
// - A set uses its JPG when it has one (the delivered look, and a cheaper read).
// - Anything else: Quick Look's thumbnail; else the type icon (drawn by the view).
// Rows on screen are asked for; work for rows scrolled away is dropped before it starts
// (newest request first, 2 at a time per share, 4 per local disk).

import Foundation
import ImageIO
import QuickLook
import CoreGraphics

struct ThumbRequest {
    let key: String          // path|size|mtime
    let source: String       // the file the picture is made from
    let ext: String

    init(source: String, size: Int64, modified: Double) {
        self.source = source
        self.key = "\(source)|\(size)|\(Int64(modified * 1000))"
        self.ext = FileOperations.split(Paths.name(source)).ext.lowercased()
    }
}

extension Notification.Name {
    /// Thumbnails became available; userInfo["keys"] = [String]. Main thread.
    static let thumbnailsReady = Notification.Name("PhotoLabThumbnailsReady")
}

final class Thumbnails {
    static let shared = Thumbnails()
    static let maxPixels = 512

    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let memory = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var wanted: [ObjectIdentifier: Set<String>] = [:]
    private var failed = Set<String>()          // no picture possible: draw the icon, don't retry

    private final class Lane {
        var stack: [ThumbRequest] = []
        var running = 0
        let max: Int
        let queue: DispatchQueue
        init(max: Int, label: String) { self.max = max; queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent) }
    }
    private var lanes: [String: Lane] = [:]
    private var queued = Set<String>()
    private var readyBatch: [String] = []
    private var flushScheduled = false

    init() {
        memory.totalCostLimit = 400 << 20          // about 400 MB of decoded thumbnails
    }

    func image(_ key: String) -> CGImage? { return memory.object(forKey: key as NSString)?.image }
    func hasNoPicture(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return failed.contains(key) }

    /// Ask for thumbnails (owner = one view; its previous wish list is replaced).
    func request(_ reqs: [ThumbRequest], owner: AnyObject) {
        lock.lock()
        let id = ObjectIdentifier(owner)
        wanted[id] = Set(reqs.map { $0.key })
        // Pushed in reverse, so the first rows on screen are popped first.
        for r in reqs.reversed() where memory.object(forKey: r.key as NSString) == nil && !failed.contains(r.key) && !queued.contains(r.key) {
            let vol = Volumes.volume(for: r.source)
            let name = vol?.mountPoint ?? "/"
            let lane = lanes[name] ?? Lane(max: (vol?.isNetwork ?? false) ? 2 : 4, label: "photolab.thumbs.\(lanes.count)")
            lanes[name] = lane
            lane.stack.append(r)
            queued.insert(r.key)
        }
        let all = Array(lanes.values)
        lock.unlock()
        for l in all { pump(l) }
    }

    func release(owner: AnyObject) { lock.lock(); wanted.removeValue(forKey: ObjectIdentifier(owner)); lock.unlock() }

    private func isWanted(_ key: String) -> Bool {
        for s in wanted.values where s.contains(key) { return true }
        return false
    }

    private func pump(_ lane: Lane) {
        lock.lock()
        var start: [ThumbRequest] = []
        while lane.running < lane.max, let r = lane.stack.popLast() {
            if !isWanted(r.key) { queued.remove(r.key); continue }
            lane.running += 1
            start.append(r)
        }
        lock.unlock()
        for r in start {
            lane.queue.async { [weak self] in
                guard let me = self else { return }
                let img = me.load(r)
                me.lock.lock()
                lane.running -= 1
                me.queued.remove(r.key)
                if let i = img { me.memory.setObject(Box(i), forKey: r.key as NSString, cost: i.bytesPerRow * i.height) } else { me.failed.insert(r.key) }
                me.readyBatch.append(r.key)
                let schedule = !me.flushScheduled
                me.flushScheduled = true
                me.lock.unlock()
                if schedule {
                    // One notification per ~0.1 s, not one per thumbnail.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { me.flush() }
                }
                me.pump(lane)
            }
        }
    }

    private func flush() {
        lock.lock()
        let keys = readyBatch
        readyBatch = []
        flushScheduled = false
        lock.unlock()
        if !keys.isEmpty { NotificationCenter.default.post(name: .thumbnailsReady, object: nil, userInfo: ["keys": keys]) }
    }

    // MARK: Making one

    /// Disk cache first, else made from the file (and stored). Background thread.
    func load(_ r: ThumbRequest) -> CGImage? {
        let file = AppFiles.thumbnailPath(Thumbnails.hash(r.key))
        if let d = FileManager.default.contents(atPath: file), let i = Thumbnails.decode(d) {
            Stats.noteThumb(fromDisk: true, ms: 0)
            return i
        }
        let t0 = Date()
        guard let img = Thumbnails.make(r.source, ext: r.ext) else { return nil }
        Stats.noteThumb(fromDisk: false, ms: Date().timeIntervalSince(t0) * 1000)
        if let d = Thumbnails.encode(img) { AppFiles.storeThumbnail(d, at: file) }
        return img
    }

    static func make(_ path: String, ext: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        let isRaw = FileOperations.rawExtensions.contains(ext)
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(src) > 0 {
            var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                         kCGImageSourceShouldCacheImmediately: true]
            // RAW: only what the camera embedded (a full RAW decode would read the whole file).
            opts[isRaw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways] = true
            if let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                if !isRaw || max(t.width, t.height) >= 256 { return t }
                if let q = quickLook(url) , max(q.width, q.height) > max(t.width, t.height) { return q }
                return t
            }
        }
        return quickLook(url)
    }

    private static func quickLook(_ url: URL) -> CGImage? {
        let opts = [kQLThumbnailOptionIconModeKey: false] as CFDictionary
        return QLThumbnailImageCreate(kCFAllocatorDefault, url as CFURL, CGSize(width: maxPixels, height: maxPixels), opts)?.takeRetainedValue()
    }

    static func encode(_ img: CGImage) -> Data? {
        let d = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(d as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? d as Data : nil
    }

    static func decode(_ d: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// FNV-1a 64: stable across launches and machines (Swift's hashValue is not).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return String(format: "%016llx", h)
    }
}
