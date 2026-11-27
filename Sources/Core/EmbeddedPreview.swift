// EmbeddedPreview.swift
// The cheapest way to a RAW thumbnail over a slow share: read the start of the file in one
// block, parse the RAW's own structure for the JPEGs the camera embedded, pick the smallest one
// that is still big enough, and read exactly its bytes - a few round trips in all, instead of
// ImageIO's many small reads (and, for some cameras, its read of the full-size preview).
//   TIFF family (NEF, CR2, ARW, DNG, ORF, RW2, PEF, SRW, 3FR, IIQ...): IFD chain + SubIFDs,
//     JPEGInterchangeFormat/Length and single-strip JPEG IFDs (not raw CFA/linear data);
//     orientation from IFD0.
//   RAF: the JPEG offset/length in the header.
//   CR3: the PRVW box (about 1620 px), orientation from CMT1 (a TIFF IFD0 inside moov).
// Anything that does not parse returns nil, and Thumbnails falls back to ImageIO.
// BlockReader also backs ImageIO (CGDataProvider), so those reads are counted and batched too.

import Foundation
import Darwin
import ImageIO
import CoreGraphics

/// Reads a file in 64 KB blocks (256 KB for the first: enough for the headers, maker notes and
/// image directories of most RAWs in one round trip), cached for the life of the reader; reads
/// of 256 KB or more go straight to the file and are kept as spans (a JPEG decoded for the
/// screen is not read again for 100%). Thread-safe; shared through FileReads. Counts round
/// trips and bytes.
final class BlockReader {
    let size: Int64
    let path: String
    private var fd: Int32
    private var lastUse = Date()
    private var blocks: [Int64: Data] = [:]
    private var spans: [(offset: Int64, data: Data)] = []
    private let block: Int64 = 64 << 10
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
        let got = d.withUnsafeMutableBytes { p -> Int in
            var done = 0
            while done < n {
                let r = Darwin.pread(fd, p.baseAddress!.advanced(by: done), n - done, off_t(offset) + off_t(done))
                if r < 0 { if errno == EINTR { continue }; return -1 }
                if r == 0 { break }
                done += r
            }
            return done
        }
        if got < 0 { return nil }
        reads += 1
        bytes += Int64(got)
        FileReads.note(path, bytes: Int64(got))
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
    func imageSource() -> CGImageSource? {
        var cb = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, pos, count in
                guard let info = info else { return 0 }
                return Unmanaged<BlockReader>.fromOpaque(info).takeUnretainedValue().copy(into: buffer, offset: Int64(pos), count: count)
            },
            releaseInfo: { info in if let info = info { Unmanaged<BlockReader>.fromOpaque(info).release() } })
        guard let provider = CGDataProvider(directInfo: Unmanaged.passRetained(self).toOpaque(), size: off_t(size), callbacks: &cb) else { return nil }
        return CGImageSourceCreateWithDataProvider(provider, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

enum EmbeddedPreview {
    struct Candidate { let offset: Int64; let length: Int }

    /// Thumbnail (long side <= maxPixels) from the best embedded JPEG, or nil with the reason
    /// (for the Short Report: which files need which method).
    static func thumbnail(_ r: BlockReader, ext: String, maxPixels: Int, minSide: Int? = nil, cheapLimit: Int = .max) -> (image: CGImage?, miss: String) {
        let minSide = minSide ?? maxPixels
        guard let head = r.read(0, 64), head.count >= 16 else { return (nil, "short-file") }
        var cands: [Candidate] = []
        var orientation = 1
        let layered = ["psd", "psb", "tif", "tiff"].contains(ext)
        if Array(head[0..<4]) == Array("8BPS".utf8) {                             // PSD / PSB: thumbnail resource
            guard let c = psd(r) else { return (nil, "psd-no-thumbnail") }
            cands = [c]
        } else if head[0] == 0xFF && head[1] == 0xD8 {                            // JPEG: EXIF + MPF + Photoshop previews
            let j = jpegPreviews(r)
            cands = j.candidates
            orientation = j.orientation
            if cands.isEmpty { return (nil, "no-preview") }
        } else if head.starts(with: Array("FUJIFILMCCD-RAW".utf8)) {
            guard let h = r.read(84, 8), h.count == 8 else { return (nil, "raf-header") }
            cands = [Candidate(offset: Int64(be32(h, 0)), length: Int(be32(h, 4)))]
        } else if Array(head[4..<8]) == Array("ftyp".utf8) {
            guard let c = cr3(r) else { return (nil, "cr3-no-prvw") }
            cands = [c.preview]
            orientation = c.orientation
        } else if head[0] == head[1], head[0] == 0x49 || head[0] == 0x4D {        // II / MM
            guard let t = tiff(r, base: 0) else { return (nil, "tiff-header") }
            cands = t.candidates
            orientation = t.orientation
        } else {
            return (nil, "unknown-format")
        }
        var jpeg = pick(r, cands, minSide: minSide, cheapLimit: cheapLimit)
        if jpeg == nil || (jpegLongSide(jpeg!) ?? 0) < minSide / 2, ext != "jpg", ext != "jpeg", !layered {
            // PwCarve's idea, as the last resort: JPEGs in the first 2 MB, found by their markers.
            let carved = carve(r, window: 2 << 20)
            if let c = pick(r, carved, minSide: minSide, cheapLimit: cheapLimit) { jpeg = c }
        }
        guard let data = jpeg else { return (nil, cands.isEmpty ? "no-candidates" : "no-usable-jpeg") }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, "bad-jpeg") }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return (nil, "decode-failed") }
        if ext == "jpg" || ext == "jpeg", max(img.width, img.height) < min(maxPixels / 2, minSide) { return (nil, "preview-too-small") }
        // Embedded previews rarely carry their own orientation; the container's applies then.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let own = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
        return (own == 1 && orientation != 1 ? rotate(img, orientation) : img, "")
    }

    // MARK: JPEG (camera JPEGs: EXIF thumbnail, MPF previews)

    /// Previews a camera put into its JPEG: the EXIF thumbnail (IFD1, usually 160 px) and the MPF
    /// images (APP2 "MPF": Nikon ~640 px, Sony ~1616 px...), all located in the first few KB.
    static func jpegPreviews(_ r: BlockReader) -> (candidates: [Candidate], orientation: Int) {
        var cands: [Candidate] = []
        var orientation = 1
        var pos: Int64 = 2
        for _ in 0..<40 {
            guard let m = r.read(pos, 4), m.count == 4, m[0] == 0xFF else { break }
            let marker = m[1]
            if marker == 0xDA || marker == 0xD9 { break }                       // image data: no more headers
            let len = Int64(Int(m[2]) << 8 | Int(m[3]))
            if marker == 0xE1, let id = r.read(pos + 4, 6), Array(id) == Array("Exif\0\0".utf8),
                let t = tiff(r, base: pos + 10) {
                cands += t.candidates
                orientation = t.orientation
            } else if marker == 0xE2, let id = r.read(pos + 4, 4), Array(id) == Array("MPF\0".utf8) {
                cands += mpf(r, base: pos + 8)
            } else if marker == 0xED, let id = r.read(pos + 4, 14), Array(id) == Array("Photoshop 3.0\0".utf8) {
                if let c = photoshopThumbnail(r, start: pos + 18, end: pos + 2 + len) { cands.append(c) }   // exports from Photoshop
            }
            pos += 2 + len
        }
        return (cands, orientation)
    }

    /// MPF index (CIPA DC-007): tag 0xB002 = 16-byte entries; images after the first are previews.
    /// Offsets are relative to the MPF TIFF header.
    private static func mpf(_ r: BlockReader, base: Int64) -> [Candidate] {
        guard let h = r.read(base, 8), h.count == 8 else { return [] }
        let le = h[0] == 0x49
        func u16(_ d: Data, _ o: Int) -> Int { return le ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32(_ d: Data, _ o: Int) -> Int64 {
            let a = Int64(d[o]), b = Int64(d[o + 1]), c = Int64(d[o + 2]), e = Int64(d[o + 3])
            return le ? a | b << 8 | c << 16 | e << 24 : a << 24 | b << 16 | c << 8 | e
        }
        let ifd = u32(h, 4)
        guard let ch = r.read(base + ifd, 2), ch.count == 2 else { return [] }
        let n = u16(ch, 0)
        guard n > 0, n < 64, let d = r.read(base + ifd + 2, n * 12), d.count == n * 12 else { return [] }
        for i in 0..<n where u16(d, i * 12) == 0xB002 {
            let count = Int(u32(d, i * 12 + 4)), at = u32(d, i * 12 + 8)
            guard count >= 32, count <= 16 * 16, let e = r.read(base + at, count), e.count == count else { return [] }
            var out: [Candidate] = []
            for k in 1..<(count / 16) {
                let size = Int(u32(e, k * 16 + 4)), off = u32(e, k * 16 + 8)
                if size > 0 && off > 0 { out.append(Candidate(offset: base + off, length: size)) }
            }
            return out
        }
        return []
    }

    // MARK: Photoshop (PSD, PSB, and the same resources inside TIFF and JPEG files)

    /// PSD/PSB: 26-byte header, colour mode data (length + data), then the image resources -
    /// all near the start; the big composite and layers come after and are never read.
    static func psd(_ r: BlockReader) -> Candidate? {
        guard let cm = r.read(26, 4), cm.count == 4 else { return nil }
        let resLenAt = 26 + 4 + Int64(be32(cm, 0))
        guard let rl = r.read(resLenAt, 4), rl.count == 4 else { return nil }
        return photoshopThumbnail(r, start: resLenAt + 4, end: resLenAt + 4 + Int64(be32(rl, 0)))
    }

    /// Image resource 1036 (the thumbnail Photoshop saves, a JFIF JPEG up to ~160 px) among the
    /// "8BIM" blocks in [start, end). Big-endian; names and data are padded to even lengths.
    static func photoshopThumbnail(_ r: BlockReader, start: Int64, end: Int64) -> Candidate? {
        var pos = start
        for _ in 0..<400 {
            guard pos + 12 <= end, let h = r.read(pos, 8 + 256), h.count >= 12, Array(h[0..<4]) == Array("8BIM".utf8) else { return nil }
            let id = Int(h[4]) << 8 | Int(h[5])
            let nameLen = Int(h[6])
            let nameField = (1 + nameLen + 1) & ~1                             // length byte + name, even
            guard 6 + nameField + 4 <= h.count else { return nil }
            let size = Int64(be32(h, 6 + nameField))
            let data = pos + 6 + Int64(nameField) + 4
            if id == 1036 && size > 28 {
                return Candidate(offset: data + 28, length: Int(size - 28))      // 28-byte header, then the JPEG
            }
            pos = data + ((size + 1) & ~1)
        }
        return nil
    }

    // MARK: Carving (last resort)

    /// JPEGs found by their markers in the first `window` bytes: SOI, segments up to SOS, then the
    /// entropy data up to EOI (FF D9; FF 00 and restart markers are data).
    static func carve(_ r: BlockReader, window: Int) -> [Candidate] {
        guard let d = r.read(0, min(window, Int(r.size))) else { return [] }
        let b = [UInt8](d)
        var out: [Candidate] = []
        var i = 0
        while i + 4 < b.count, out.count < 8 {
            guard b[i] == 0xFF, b[i + 1] == 0xD8, b[i + 2] == 0xFF else { i += 1; continue }
            var j = i + 2
            var ok = false
            while j + 4 < b.count {                                            // header segments
                guard b[j] == 0xFF else { break }
                let m = b[j + 1]
                if m == 0xDA { j += 2 + (Int(b[j + 2]) << 8 | Int(b[j + 3])); ok = true; break }
                j += 2 + (Int(b[j + 2]) << 8 | Int(b[j + 3]))
            }
            guard ok else { i += 2; continue }
            var end = -1
            while j + 1 < b.count {                                            // entropy data
                if b[j] == 0xFF, b[j + 1] == 0xD9 { end = j + 2; break }
                j += 1
            }
            guard end > 0 else { break }                                       // runs past the window
            out.append(Candidate(offset: Int64(i), length: end - i))
            i = end
        }
        return out
    }

    // MARK: Choosing and reading the JPEG

    /// The smallest candidate whose long side is at least `minSide` (else the biggest). Each
    /// candidate up to 8 MB is read whole in one request - checking its size first and then
    /// reading it would be two round trips. `cheapLimit`: never take one bigger than that (Quick
    /// previews: the cheapest usable one, not the full-size JPEG).
    private static func pick(_ r: BlockReader, _ cands: [Candidate], minSide: Int, cheapLimit: Int = .max) -> Data? {
        let ok = cands.filter { $0.length > 512 && $0.offset > 0 && $0.offset + Int64($0.length) <= r.size && $0.length <= cheapLimit }
        var best: (Data, Int)?
        for c in ok.sorted(by: { $0.length < $1.length }) {
            let whole = c.length <= 8 << 20
            guard let start = r.read(c.offset, whole ? c.length : 64 << 10), start.count > 4, start[0] == 0xFF, start[1] == 0xD8 else { continue }
            let side = jpegLongSide(start) ?? 0
            if side >= minSide || best == nil || side > best!.1 {
                guard let d = whole ? start : r.read(c.offset, c.length) else { continue }
                best = (d, side)
                if side >= minSide { break }
            }
        }
        return best?.0
    }

    /// Long side from the JPEG's SOF marker (in the first bytes), nil if not found.
    static func jpegLongSide(_ d: Data) -> Int? {
        guard let s = jpegSize(d) else { return nil }
        return max(s.width, s.height)
    }

    /// Size of the largest embedded JPEG of a RAW (what the full-size preview will be), upright.
    static func largestSize(_ r: BlockReader) -> (width: Int, height: Int)? {
        guard let head = r.read(0, 64), head.count >= 16 else { return nil }
        var cands: [Candidate] = []
        var orientation = 1
        if head.starts(with: Array("FUJIFILMCCD-RAW".utf8)) {
            guard let h = r.read(84, 8), h.count == 8 else { return nil }
            cands = [Candidate(offset: Int64(be32(h, 0)), length: Int(be32(h, 4)))]
        } else if Array(head[4..<8]) == Array("ftyp".utf8) {
            guard let c = cr3(r) else { return nil }
            cands = [c.preview]
            orientation = c.orientation
        } else if head[0] == head[1], head[0] == 0x49 || head[0] == 0x4D, let t = tiff(r, base: 0) {
            cands = t.candidates
            orientation = t.orientation
        }
        var best: (Int, Int)?
        for c in cands where c.length > 512 && c.offset > 0 && c.offset + Int64(c.length) <= r.size {
            guard let start = r.read(c.offset, min(c.length, 64 << 10)), start.count > 4, start[0] == 0xFF, start[1] == 0xD8,
                let s = jpegSize(start) else { continue }
            if best == nil || s.width * s.height > best!.0 * best!.1 { best = (s.width, s.height) }
        }
        guard let b = best else { return nil }
        return orientation >= 5 ? (b.1, b.0) : (b.0, b.1)
    }

    static func jpegSize(_ d: Data) -> (width: Int, height: Int)? {
        var i = 2
        let b = [UInt8](d)
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let m = b[i + 1]
            if m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) { i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(m) && m != 0xC4 && m != 0xC8 && m != 0xCC {
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6]), w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return (w, h)
            }
            i += 2 + len
        }
        return nil
    }

    // MARK: TIFF

    /// `nikon`: inside a Nikon maker note, where tag 0x0011 points to the PreviewIFD.
    static func tiff(_ r: BlockReader, base: Int64, nikon: Bool = false) -> (candidates: [Candidate], orientation: Int)? {
        guard let h = r.read(base, 8), h.count == 8 else { return nil }
        let le = h[0] == 0x49
        func u16(_ d: Data, _ o: Int) -> Int { return le ? Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 : Int(d[d.startIndex + o]) << 8 | Int(d[d.startIndex + o + 1]) }
        func u32(_ d: Data, _ o: Int) -> Int64 {
            let a = Int64(d[d.startIndex + o]), b = Int64(d[d.startIndex + o + 1]), c = Int64(d[d.startIndex + o + 2]), e = Int64(d[d.startIndex + o + 3])
            return le ? a | b << 8 | c << 16 | e << 24 : a << 24 | b << 16 | c << 8 | e
        }
        var queue: [Int64] = [u32(h, 4)]
        var seen = Set<Int64>()
        var cands: [Candidate] = []
        var orientation = 1
        var first = true
        while let off = queue.first, seen.count < 24 {
            queue.removeFirst()
            guard off > 0, !seen.contains(off), base + off < r.size, let ch = r.read(base + off, 2), ch.count == 2 else { first = false; continue }
            seen.insert(off)
            let n = u16(ch, 0)
            guard n > 0, n < 1000, let d = r.read(base + off + 2, n * 12 + 4), d.count == n * 12 + 4 else { first = false; continue }
            var tags: [Int: (type: Int, count: Int64, value: Int64, raw: Int)] = [:]
            for i in 0..<n {
                let e = i * 12
                let tag = u16(d, e), type = u16(d, e + 2), count = u32(d, e + 4)
                let value = type == 3 && count == 1 ? Int64(u16(d, e + 8)) : u32(d, e + 8)
                tags[tag] = (type, count, value, e + 8)
            }
            if first, let o = tags[0x0112] { orientation = Int(o.value) }
            first = false
            if let jo = tags[0x0201], let jl = tags[0x0202] { cands.append(Candidate(offset: base + jo.value, length: Int(jl.value))) }
            let comp = tags[0x0103]?.value ?? 1
            let photo = tags[0x0106]?.value ?? 2
            if (comp == 6 || comp == 7), photo != 32803, photo != 34892,
                let so = tags[0x0111], let sc = tags[0x0117], so.count == 1, sc.count == 1 {
                cands.append(Candidate(offset: base + so.value, length: Int(sc.value)))
            }
            // Photoshop's image resources inside a TIFF (tag 34377): its thumbnail.
            if let ps = tags[34377], ps.count > 12, let c = photoshopThumbnail(r, start: base + ps.value, end: base + ps.value + ps.count) {
                cands.append(c)
            }
            // Panasonic RW2: the JPEG is the value of tag 0x002E itself.
            if let p = tags[0x002E], p.count > 2048 { cands.append(Candidate(offset: base + p.value, length: Int(p.count))) }
            if let ex = tags[0x8769] { queue.append(ex.value) }                // Exif IFD (holds the maker note)
            if nikon, let pv = tags[0x0011] { queue.append(pv.value) }         // Nikon PreviewIFD
            if !nikon, let mn = tags[0x927C], let hdr = r.read(base + mn.value, 10), hdr.count == 10,
                Array(hdr[0..<6]) == Array("Nikon\0".utf8),
                let t = tiff(r, base: base + mn.value + 10, nikon: true) {
                cands += t.candidates                                          // ~640 px PreviewImage
            }
            if let sub = tags[0x014A] {
                if sub.count == 1 { queue.append(sub.value) }
                else if sub.count < 16, let arr = r.read(base + sub.value, Int(sub.count) * 4), arr.count == Int(sub.count) * 4 {
                    for k in 0..<Int(sub.count) { queue.append(u32(arr, k * 4)) }
                }
            }
            let next = u32(d, n * 12)
            if next != 0 { queue.append(next) }
        }
        return (cands, orientation)
    }

    // MARK: CR3 (ISO base media file)

    private static let prvwUUID: [UInt8] = [0xea, 0xf4, 0x2b, 0x5e, 0x1c, 0x98, 0x4b, 0x88, 0xb9, 0xfb, 0xb7, 0xdc, 0x40, 0x6e, 0x4d, 0x16]
    private static let canonUUID: [UInt8] = [0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0, 0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48]

    /// Boxes inside [start, end): (type, payload start, box end).
    private static func boxes(_ r: BlockReader, _ start: Int64, _ end: Int64) -> [(type: String, payload: Int64, end: Int64, uuid: [UInt8])] {
        var out: [(String, Int64, Int64, [UInt8])] = []
        var pos = start
        while pos + 8 <= end, out.count < 64 {
            guard let h = r.read(pos, 32), h.count >= 8 else { break }
            var size = Int64(be32(h, 0))
            let type = String(bytes: h[4..<8], encoding: .ascii) ?? "????"
            var header: Int64 = 8
            if size == 1, h.count >= 16 { size = Int64(be32(h, 8)) << 32 | Int64(be32(h, 12)); header = 16 }
            if size == 0 { size = end - pos }
            guard size >= header, pos + size <= end else { break }
            var uuid: [UInt8] = []
            if type == "uuid", h.count >= Int(header) + 16 { uuid = Array(h[Int(header)..<Int(header) + 16]); header += 16 }
            out.append((type, pos + header, pos + size, uuid))
            pos += size
        }
        return out
    }

    static func cr3(_ r: BlockReader) -> (preview: Candidate, orientation: Int)? {
        let top = boxes(r, 0, r.size)
        var orientation = 1
        if let moov = top.first(where: { $0.type == "moov" }),
            let canon = boxes(r, moov.payload, moov.end).first(where: { $0.type == "uuid" && $0.uuid == canonUUID }),
            let cmt1 = boxes(r, canon.payload, canon.end).first(where: { $0.type == "CMT1" }),
            let t = tiff(r, base: cmt1.payload) {
            orientation = t.orientation
        }
        guard let pv = top.first(where: { $0.type == "uuid" && $0.uuid == prvwUUID }) else { return nil }
        // 8 bytes, then the PRVW box; its JPEG starts a few bytes in (find the SOI marker).
        guard let prvw = boxes(r, pv.payload + 8, pv.end).first(where: { $0.type == "PRVW" }),
            let head = r.read(prvw.payload, 64) else { return nil }
        let b = [UInt8](head)
        for i in 0..<(b.count - 2) where b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF {
            let off = prvw.payload + Int64(i)
            return (Candidate(offset: off, length: Int(prvw.end - off)), orientation)
        }
        return nil
    }

    // MARK: Helpers

    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        let s = d.startIndex + o
        return UInt32(d[s]) << 24 | UInt32(d[s + 1]) << 16 | UInt32(d[s + 2]) << 8 | UInt32(d[s + 3])
    }

    /// Apply an EXIF orientation (1-8).
    static func rotate(_ img: CGImage, _ o: Int) -> CGImage {
        guard (2...8).contains(o) else { return img }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let swap = o >= 5
        let ow = swap ? h : w, oh = swap ? w : h
        guard let ctx = CGContext(data: nil, width: Int(ow), height: Int(oh), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return img }
        var t = CGAffineTransform.identity
        switch o {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: break
        }
        ctx.concatenate(t)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }
}
