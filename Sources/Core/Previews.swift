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

    /// The full-size tier (`px` for request/cached): loaded only when the zoom needs it. For a
    /// RAW that is its largest embedded JPEG.
    static let full = 16384
    /// A real RAW decode (the "Decode Full Image" button): the sensor's full resolution.
    static let rawDecode = 65536

    init() {
        memory.countLimit = 10
        memory.totalCostLimit = 900 << 20              // a few full-size pictures at most
    }

    static func cacheKey(_ e: FileEntry, _ px: Int) -> String {
        return "\(e.path)|\(e.size)|\(Int64(e.modified * 1000))|\(px)"
    }

    func cached(_ e: FileEntry, px: Int) -> (image: CGImage, method: String, ms: Double)? {
        guard let b = memory.object(forKey: Previews.cacheKey(e, px) as NSString) else { return nil }
        return (b.image, b.method, b.ms)
    }

    /// `items[0]` is shown now, the rest are prefetched. Older wishes are dropped. `probe`: also
    /// find items[0]'s final size (same operation, same shared reader).
    func request(_ items: [FileEntry], px: Int, probe: Bool = false) {
        lock.lock()
        wanted = items.map { Previews.cacheKey($0, px) }
        var todo = items.filter { memory.object(forKey: Previews.cacheKey($0, px) as NSString) == nil && !pending.contains(Previews.cacheKey($0, px)) }
        // The size probe needs an operation even when the picture is cached already.
        if probe, let first = items.first, !todo.contains(where: { $0.path == first.path }), sizes[Previews.cacheKey(first, 0)] == nil {
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.probe(first) }
            lock.lock()
        }
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
                if still && probe && e.path == items[0].path { me.probe(e) }
                if still {
                    let t0 = Date()
                    if let made = Previews.make(e, px: px) {
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

    // MARK: Final size (so the preview can lay the picture out at its full size at once)

    struct Sizes {
        let picture: CGSize       // what the full tier will show (RAW: its largest embedded JPEG)
        let image: CGSize?        // the real image (RAW: the sensor's output size), if larger
    }

    private var sizes: [String: Sizes] = [:]

    func knownSizes(_ e: FileEntry) -> Sizes? { lock.lock(); defer { lock.unlock() }; return sizes[Previews.cacheKey(e, 0)] }

    /// Read in the same operation as the preview (shared reader: the header is usually already
    /// there), so it is dropped with it when the user has moved on.
    private func probe(_ e: FileEntry) {
        let key = Previews.cacheKey(e, 0)
        lock.lock(); let have = sizes[key] != nil; lock.unlock()
        if have { return }
        guard let s = Previews.fullSizes(e) else { return }
        lock.lock(); sizes[key] = s; lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .previewReady, object: nil, userInfo: ["path": e.path]) }
    }

    static func fullSizes(_ e: FileEntry) -> Sizes? {
        guard let r = FileReads.reader(e.path, size: e.size, modified: e.modified) else { return nil }
        func header() -> CGSize? {
            guard let src = r.imageSource(), CGImageSourceGetCount(src) > 0,
                let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let o = (p[kCGImagePropertyOrientation] as? Int) ?? 1
            return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        if Thumbnails.route(e.ext) == .raw {
            let real = header()
            if let s = EmbeddedPreview.largestSize(r) {
                let pic = CGSize(width: s.width, height: s.height)
                let bigger = real.map { max($0.width, $0.height) > max(pic.width, pic.height) * 1.1 } ?? false
                return Sizes(picture: pic, image: bigger ? real : nil)
            }
            return real.map { Sizes(picture: $0, image: nil) }
        }
        return header().map { Sizes(picture: $0, image: nil) }
    }

    /// Screen size, full size (px == full) or a real RAW decode (px == rawDecode).
    /// Screen size: the cheapest embedded preview of at least ~1000 px and at most 1.5 MB (less
    /// than half the bytes for the same look - 0.9.1 reports); else, for non-RAW files, a decode
    /// at screen size; a RAW is never decoded for the screen.
    static func make(_ e: FileEntry, px: Int) -> (image: CGImage, method: String, bytes: Int64, reads: Int)? {
        let route = Thumbnails.route(e.ext)
        guard route != .other else { return nil }
        if px == rawDecode {
            let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: e.path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 20000,
                                         kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            guard let s = src, let img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { return nil }
            return (img, "raw-decode", e.size, 0)
        }
        guard let r = FileReads.reader(e.path, size: e.size, modified: e.modified) else { return nil }
        let r0 = r.reads, b0 = r.bytes
        func done(_ img: CGImage, _ m: String) -> (image: CGImage, method: String, bytes: Int64, reads: Int) { return (img, m, r.bytes - b0, r.reads - r0) }
        if route == .raw || route == .jpeg {
            if px >= full {
                // Full tier: the largest embedded JPEG (JPEGs: their own pixels, decoded below).
                if route == .raw, let img = EmbeddedPreview.thumbnail(r, ext: e.ext, maxPixels: px).image { return done(img, "embedded") }
            } else if let img = EmbeddedPreview.thumbnail(r, ext: e.ext, maxPixels: px, minSide: 1000, cheapLimit: 1_500_000).image {
                return done(img, "embedded")
            } else if route == .raw, let img = EmbeddedPreview.thumbnail(r, ext: e.ext, maxPixels: px).image {
                return done(img, "embedded")                     // only a big one exists: take it, still no decode
            }
            if route == .raw { return nil }
        }
        guard let src = r.imageSource(), CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: px,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return done(img, "decode")
    }
}
