// Previews.swift
// Screen-size pictures for the preview window (PLAN.md section 6): RAW -> the smallest embedded
// JPEG that covers the screen (our reader), JPEG -> its MPF preview if big enough, else a
// reduced-size decode; other images -> ImageIO at reduced size. One queue per volume, the newest
// request first; the item on screen, then the next two and the previous one (prefetch). A small
// memory cache (a few screens) - previews are not kept on disk.

import Foundation
import ImageIO
import CoreGraphics

extension Notification.Name {
    /// A preview is ready; userInfo["path"] = String. Main thread.
    static let previewReady = Notification.Name("PhotoLabPreviewReady")
}

final class Previews {
    static let shared = Previews()
    private final class Box { let image: CGImage; let method: String; let ms: Double
        init(_ i: CGImage, _ m: String, _ t: Double) { image = i; method = m; ms = t } }
    private let memory = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var queues: [String: OperationQueue] = [:]
    private var wanted: [String] = []
    private var pending = Set<String>()

    /// The full-size tier (`px` for request/cached): loaded only when the zoom needs it.
    static let full = 16384

    init() {
        memory.countLimit = 10
        memory.totalCostLimit = 900 << 20              // a few full-size pictures at most
    }

    static func cacheKey(_ e: FileEntry, _ px: Int) -> String { return "\(e.path)|\(e.size)|\(Int64(e.modified * 1000))|\(px)" }

    func cached(_ e: FileEntry, px: Int) -> (image: CGImage, method: String, ms: Double)? {
        guard let b = memory.object(forKey: Previews.cacheKey(e, px) as NSString) else { return nil }
        return (b.image, b.method, b.ms)
    }

    /// `items[0]` is shown now, the rest are prefetched. Older wishes are dropped.
    func request(_ items: [FileEntry], px: Int) {
        lock.lock()
        wanted = items.map { Previews.cacheKey($0, px) }
        let todo = items.filter { memory.object(forKey: Previews.cacheKey($0, px) as NSString) == nil && !pending.contains(Previews.cacheKey($0, px)) }
        for e in todo { pending.insert(Previews.cacheKey(e, px)) }
        lock.unlock()
        for e in todo {
            let vol = Volumes.volume(for: e.path)?.mountPoint ?? "/"
            lock.lock()
            // Two at a time per volume: one slow PSD composite cannot hold up the next shot.
            let q = queues[vol] ?? { let o = OperationQueue(); o.maxConcurrentOperationCount = 2; o.qualityOfService = .userInitiated; return o }()
            queues[vol] = q
            lock.unlock()
            q.addOperation { [weak self] in
                guard let me = self else { return }
                let key = Previews.cacheKey(e, px)
                me.lock.lock(); let still = me.wanted.contains(key); me.lock.unlock()
                if still {
                    let t0 = Date()
                    if let made = Previews.make(e.path, ext: e.ext, px: px) {
                        let ms = Date().timeIntervalSince(t0) * 1000
                        me.memory.setObject(Box(made.image, made.method, ms), forKey: key as NSString,
                                            cost: made.image.bytesPerRow * made.image.height)
                        Stats.noteThumb(method: "preview " + e.ext + "/" + made.method, ms: ms, bytes: made.bytes, reads: made.reads)
                        DispatchQueue.main.async { NotificationCenter.default.post(name: .previewReady, object: nil, userInfo: ["path": e.path]) }
                    }
                }
                me.lock.lock(); me.pending.remove(key); me.lock.unlock()
            }
        }
    }

    static func make(_ path: String, ext: String, px: Int) -> (image: CGImage, method: String, bytes: Int64, reads: Int)? {
        let route = Thumbnails.route(ext)
        if route == .raw || route == .jpeg, let r = BlockReader(path) {
            let e = EmbeddedPreview.thumbnail(r, ext: ext, maxPixels: px)
            // Screen tier: good enough when it covers most of the screen. Full tier of a RAW: the
            // largest embedded JPEG is the full picture we show (no RAW decode).
            if let img = e.image, max(img.width, img.height) >= px * 3 / 4 || (px >= full && route == .raw) {
                return (img, "embedded", r.bytes, r.reads)
            }
        }
        guard route != .other, let r = BlockReader(path), let src = r.imageSource(), CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: px,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return (img, "decode", r.bytes, r.reads)
    }
}
