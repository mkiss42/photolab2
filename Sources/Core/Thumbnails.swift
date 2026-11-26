// Thumbnails.swift
// Contact sheet thumbnails (256 px on the long side), made in the background and kept twice:
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
// Two tracks per volume (2 at a time per share, 4 per local disk): urgent = tiles on screen and
// a screen ahead, newest request first, dropped when scrolled away; background = the rest of
// the folder, only when no urgent work waits, so an idle sheet fills itself in.

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
        self.key = "\(source)|\(size)|\(Int64(modified * 1000))|\(Thumbnails.maxPixels)"
        self.ext = FileOperations.split(Paths.name(source)).ext.lowercased()
    }
}

extension Notification.Name {
    /// Thumbnails became available; userInfo["keys"] = [String]. Main thread.
    static let thumbnailsReady = Notification.Name("PhotoLabThumbnailsReady")
}

final class Thumbnails {
    static let shared = Thumbnails()
    static let maxPixels = 256

    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let memory = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var wanted: [ObjectIdentifier: Set<String>] = [:]
    private var wantedLater: [ObjectIdentifier: Set<String>] = [:]
    private var failed = Set<String>()          // no picture possible: draw the icon, don't retry

    private final class Lane {
        var stack: [ThumbRequest] = []
        var background: [ThumbRequest] = []
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
        memory.totalCostLimit = 500 << 20          // about 500 MB of decoded thumbnails (~3000 at 256 px)
    }

    func image(_ key: String) -> CGImage? { return memory.object(forKey: key as NSString)?.image }
    func hasNoPicture(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return failed.contains(key) }

    /// Ask for thumbnails (owner = one view; its previous wish lists are replaced). `background`
    /// runs only when no urgent request waits on that volume.
    func request(_ reqs: [ThumbRequest], background: [ThumbRequest] = [], owner: AnyObject) {
        lock.lock()
        let id = ObjectIdentifier(owner)
        wanted[id] = Set(reqs.map { $0.key })
        wantedLater[id] = Set(background.map { $0.key })
        // Background track: rebuilt from this request (nearest first = popped first).
        var bg: [String: [ThumbRequest]] = [:]
        for r in background where memory.object(forKey: r.key as NSString) == nil && !failed.contains(r.key) {
            let vol = Volumes.volume(for: r.source)
            bg[vol?.mountPoint ?? "/", default: []].append(r)
        }
        for (name, list) in bg {
            let vol = Volumes.volume(for: list[0].source)
            let lane = lanes[name] ?? Lane(max: (vol?.isNetwork ?? false) ? 2 : 4, label: "photolab.thumbs.\(lanes.count)")
            lanes[name] = lane
            lane.background = list.reversed()
        }
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

    func release(owner: AnyObject) {
        lock.lock()
        wanted.removeValue(forKey: ObjectIdentifier(owner))
        wantedLater.removeValue(forKey: ObjectIdentifier(owner))
        lock.unlock()
    }

    private func isWanted(_ key: String) -> Bool {
        for s in wanted.values where s.contains(key) { return true }
        return false
    }

    private func isWantedLater(_ key: String) -> Bool {
        for s in wantedLater.values where s.contains(key) { return true }
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
        // Nothing urgent waiting: one background item per free slot.
        while lane.running < lane.max, lane.stack.isEmpty, let r = lane.background.popLast() {
            if queued.contains(r.key) || memory.object(forKey: r.key as NSString) != nil || failed.contains(r.key) || !isWantedLater(r.key) { continue }
            queued.insert(r.key)
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
            Stats.noteThumb(method: "cache", ms: 0, bytes: 0, reads: 0)
            return i
        }
        let t0 = Date()
        guard let made = Thumbnails.make(r.source, ext: r.ext) else { return nil }
        Stats.noteThumb(method: r.ext + "/" + made.method, ms: Date().timeIntervalSince(t0) * 1000, bytes: made.bytes, reads: made.reads)
        if let d = Thumbnails.encode(made.image) { AppFiles.storeThumbnail(d, at: file) }
        return made.image
    }

    enum Route { case raw, jpeg, heic, layered, plain, other }

    /// Which method suits which file type (from the Short Report numbers):
    ///   raw      our embedded-preview reader, then ImageIO (embedded only), then Quick Look
    ///   jpeg     the camera's MPF/EXIF preview if >= 128 px, else a reduced-size decode (whole file)
    ///   heic     ImageIO's embedded thumbnail, else a decode
    ///   layered  PSD/PSB/TIFF: ImageIO's embedded thumbnail, else Quick Look (never the full composite)
    ///   plain    PNG/GIF/BMP/WebP...: a reduced-size decode
    ///   other    PDF, video, documents...: Quick Look (it reads only what the first page/frame needs)
    static func route(_ ext: String) -> Route {
        if FileOperations.rawExtensions.contains(ext) { return .raw }
        switch ext {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "heic", "heif", "hif", "avif": return .heic
        case "psd", "psb", "tif", "tiff": return .layered
        case "png", "gif", "bmp", "webp", "jp2", "tga", "ico", "icns": return .plain
        default: return .other
        }
    }

    /// The picture and how it was got (for the Short Report).
    static func make(_ path: String, ext: String) -> (image: CGImage, method: String, bytes: Int64, reads: Int)? {
        let url = URL(fileURLWithPath: path)
        let route = self.route(ext)
        func imageIO(_ always: Bool, _ r: BlockReader?) -> CGImage? {
            var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                         kCGImageSourceShouldCacheImmediately: true]
            opts[always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            let src = r?.imageSource() ?? CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            guard let s = src, CGImageSourceGetCount(s) > 0 else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary)
        }
        switch route {
        case .raw, .jpeg:
            if let r = BlockReader(path) {
                let e = EmbeddedPreview.thumbnail(r, ext: ext, maxPixels: maxPixels)
                if let img = e.image { return (img, route == .raw ? "embedded" : "jpeg-preview", r.bytes, r.reads) }
                Stats.noteThumbMiss(ext: ext, reason: e.miss)
            }
            if route == .jpeg, let r = BlockReader(path), let t = imageIO(true, r) { return (t, "decode", r.bytes, r.reads) }
            if route == .raw, let r = BlockReader(path), let t = imageIO(false, r), max(t.width, t.height) >= maxPixels / 2 {
                return (t, "imageio-thumb", r.bytes, r.reads)
            }
        case .heic:
            if let r = BlockReader(path), let t = imageIO(false, r) {
                if max(t.width, t.height) >= maxPixels * 3 / 4 { return (t, "imageio-thumb", r.bytes, r.reads) }
                if let r2 = BlockReader(path), let d = imageIO(true, r2) { return (d, "decode", r.bytes + r2.bytes, r.reads + r2.reads) }
            }
        case .layered:
            if let r = BlockReader(path), let t = imageIO(false, r), max(t.width, t.height) >= 128 {
                return (t, "imageio-thumb", r.bytes, r.reads)
            }
        case .plain:
            if let r = BlockReader(path), let t = imageIO(true, r) { return (t, "decode", r.bytes, r.reads) }
        case .other:
            break
        }
        let t0 = Date()
        if let q = quickLook(url) { _ = t0; return (q, "quicklook", 0, 0) }
        // Quick Look had nothing: one ImageIO try from the file, then the type icon (drawn by the view).
        if route == .other || route == .raw, let t = imageIO(false, nil) { return (t, "imageio-thumb", 0, 0) }
        return nil
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
