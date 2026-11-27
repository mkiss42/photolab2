// EmbeddedPreview.swift
// Finds the camera's own JPEG preview inside a RAW file without developing the RAW, the way
// Photo Mechanic does: a few small reads to walk the file's directory, then one read of the JPEG.
// Handles TIFF-based RAW (NEF, NRW, DNG, CR2, ARW, SR2, PEF, ORF, RW2, 3FR, ERF, IIQ, MOS...), Canon CR3
// and Fujifilm RAF. Read-only. Pure Foundation, tested on Linux.

import Foundation

struct PreviewLocation: Equatable {
    let offset: UInt64
    let length: Int
}

struct EmbeddedPreviewInfo {
    /// Largest JPEG preview found (nil if none).
    var best: PreviewLocation?
    /// All JPEG previews found, largest first.
    var all: [PreviewLocation] = []
    /// TIFF orientation of the main image (1 = normal, 3 = 180, 6 = 90 CW, 8 = 90 CCW).
    var orientation: Int = 1
}

/// Random-access reader with bounds checks; never reads more than asked.
final class FileReader {
    private let fh: FileHandle
    let size: UInt64

    private let path: String
    private var bytesRead: Int64 = 0

    init?(path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        fh = h
        self.path = path
        size = h.seekToEndOfFile()
    }

    deinit {
        fh.closeFile()
        IOLog.smallRead(path, bytes: bytesRead)   // 0.18: counted in the I/O logs
    }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        if count <= 0 || offset >= size || offset + UInt64(count) > size { return nil }
        fh.seek(toFileOffset: offset)
        let d = fh.readData(ofLength: count)
        bytesRead += Int64(d.count)
        return d.count == count ? d : nil
    }
}

enum EmbeddedPreview {
    /// Previews larger than this are refused (corrupt length fields).
    static let maxPreviewBytes = 64 * 1024 * 1024
    private static let maxIFDs = 64
    private static let maxEntries = 1000

    static func locate(path: String) -> EmbeddedPreviewInfo {
        guard let r = FileReader(path: path), let head = r.read(0, min(Int(r.size), 128)), head.count >= 16 else {
            return EmbeddedPreviewInfo()
        }
        let b = [UInt8](head)
        var info = EmbeddedPreviewInfo()
        var found: [PreviewLocation] = []
        if b.count >= 92, String(bytes: b[0..<16], encoding: .ascii) == "FUJIFILMCCD-RAW " {
            let off = be32(b, 84), len = be32(b, 88)
            add(&found, r, UInt64(off), Int(len))
        } else if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 {   // "ftyp": ISO media (CR3)
            cr3(r, &found)
        } else if let little = tiffOrder(b) {
            tiff(r, little: little, &found, &info.orientation)
        }
        found.sort { $0.length > $1.length }
        // Same JPEG reached through two tags: keep one.
        var unique: [PreviewLocation] = []
        for f in found where !unique.contains(f) { unique.append(f) }
        info.all = unique
        info.best = unique.first
        return info
    }

    /// The JPEG bytes of the largest preview, or nil.
    static func largestJPEG(path: String) -> (data: Data, orientation: Int)? {
        let info = locate(path: path)
        guard let best = info.best, let r = FileReader(path: path), let d = r.read(best.offset, best.length) else { return nil }
        return (d, info.orientation)
    }

    // MARK: Photoshop

    /// Photoshop's own thumbnail (image resource 1036, a small JPEG, about 160 px) in a PSD or PSB,
    /// plus the document's pixel size. Reads only the file's first few kilobytes to megabytes.
    static func photoshopThumbnail(path: String) -> (location: PreviewLocation?, width: Int, height: Int) {
        guard let r = FileReader(path: path), let h = r.read(0, 30) else { return (nil, 0, 0) }
        let b = [UInt8](h)
        guard b[0] == 0x38, b[1] == 0x42, b[2] == 0x50, b[3] == 0x53 else { return (nil, 0, 0) }   // "8BPS"
        let height = Int(be32(b, 14)), width = Int(be32(b, 18))
        let colorLen = UInt64(be32(b, 26))
        let resStart = 30 + colorLen
        guard let rl = r.read(resStart, 4) else { return (nil, width, height) }
        let resLen = UInt64(be32([UInt8](rl), 0))
        var off = resStart + 4
        let end = min(r.size, off + resLen)
        var blocks = 0
        while off + 12 <= end && blocks < 2000 {
            blocks += 1
            guard let head = r.read(off, 8) else { break }
            let hb = [UInt8](head)
            guard hb[0] == 0x38, hb[1] == 0x42, hb[2] == 0x49, hb[3] == 0x4D else { break }   // "8BIM"
            let id = Int(u16(hb, 4, false))
            let nameLen = UInt64(hb[6])
            var nameField = 1 + nameLen
            if nameField % 2 == 1 { nameField += 1 }
            guard let sz = r.read(off + 6 + nameField, 4) else { break }
            let size = UInt64(be32([UInt8](sz), 0))
            let data = off + 6 + nameField + 4
            if id == 1036 && size > 28, let th = r.read(data, 4), be32([UInt8](th), 0) == 1 {   // format 1 = JPEG
                let loc = PreviewLocation(offset: data + 28, length: Int(size - 28))
                if let soi = r.read(loc.offset, 2), [UInt8](soi) == [0xFF, 0xD8] { return (loc, width, height) }
            }
            off = data + size + (size % 2)
        }
        return (nil, width, height)
    }

    // MARK: TIFF-based RAW

    /// II*\0 (little), MM\0* (big), plus the variants used by Olympus (IIRO/IISR/MMOR) and Panasonic (IIU\0).
    private static func tiffOrder(_ b: [UInt8]) -> Bool? {
        if b[0] == 0x49 && b[1] == 0x49 { return true }
        if b[0] == 0x4D && b[1] == 0x4D { return false }
        return nil
    }

    private static func tiff(_ r: FileReader, little: Bool, _ found: inout [PreviewLocation], _ orientation: inout Int) {
        guard let h = r.read(0, 8) else { return }
        let first = UInt64(u32([UInt8](h), 4, little))
        var queue: [(UInt64, Bool)] = [(first, true)]   // (offset, follow next-IFD chain)
        var seen = Set<UInt64>()
        var isFirst = true
        while !queue.isEmpty && seen.count < maxIFDs {
            let (off, chain) = queue.removeFirst()
            if off < 8 || seen.contains(off) { continue }
            seen.insert(off)
            guard let cnt = r.read(off, 2) else { continue }
            let n = Int(u16([UInt8](cnt), 0, little))
            if n == 0 || n > maxEntries { continue }
            guard let raw = r.read(off + 2, n * 12 + 4) else { continue }
            let e = [UInt8](raw)
            var jpegOff: UInt64? = nil, jpegLen: Int? = nil
            var stripOff: [UInt64] = [], stripLen: [Int] = []
            var compression = 0
            for i in 0..<n {
                let p = i * 12
                let tag = u16(e, p, little), type = u16(e, p + 2, little)
                let count = Int(u32(e, p + 4, little))
                let value = u32(e, p + 8, little)
                let short = type == 3 ? UInt32(u16(e, p + 8, little)) : value
                switch tag {
                case 0x0112: if isFirst { orientation = Int(short) }
                case 0x0103: compression = Int(short)
                case 0x0201: jpegOff = UInt64(value)
                case 0x0202: jpegLen = Int(value)
                case 0x002E: add(&found, r, UInt64(value), count)                  // Panasonic JpgFromRaw
                case 0x0111: stripOff = values(r, e, p, type, count, little).map { UInt64($0) }
                case 0x0117: stripLen = values(r, e, p, type, count, little).map { Int($0) }
                case 0x014A: for v in values(r, e, p, type, count, little) { queue.append((UInt64(v), false)) }   // SubIFDs
                default: break
                }
            }
            if let o = jpegOff, let l = jpegLen { add(&found, r, o, l) }
            if (compression == 6 || compression == 7 || compression == 0) && stripOff.count == 1 && stripLen.count == 1 {
                add(&found, r, stripOff[0], stripLen[0])   // single-strip JPEG (only kept if it starts with FFD8)
            }
            if chain {
                let next = UInt64(u32(e, n * 12, little))
                if next != 0 { queue.append((next, true)) }
            }
            isFirst = false
        }
    }

    /// Values of a SHORT/LONG array entry (inline when 4 bytes or less, else at the offset).
    private static func values(_ r: FileReader, _ e: [UInt8], _ p: Int, _ type: UInt16, _ count: Int, _ little: Bool) -> [UInt32] {
        let size = type == 3 ? 2 : (type == 4 || type == 13 ? 4 : 0)
        if size == 0 || count <= 0 || count > 4096 { return [] }
        var bytes: [UInt8]
        if size * count <= 4 {
            bytes = Array(e[(p + 8)..<(p + 12)])
        } else {
            guard let d = r.read(UInt64(u32(e, p + 8, little)), size * count) else { return [] }
            bytes = [UInt8](d)
        }
        return (0..<count).map { size == 2 ? UInt32(u16(bytes, $0 * 2, little)) : u32(bytes, $0 * 4, little) }
    }

    // MARK: CR3

    /// Canon CR3: the PRVW box (about 1620 x 1080) inside the Canon uuid box.
    private static func cr3(_ r: FileReader, _ found: inout [PreviewLocation]) {
        var off: UInt64 = 0
        var boxes = 0
        while off + 8 <= r.size && boxes < 100 {
            boxes += 1
            guard let h = r.read(off, 8) else { return }
            let hb = [UInt8](h)
            var size = UInt64(be32(hb, 0))
            let type = String(bytes: hb[4..<8], encoding: .ascii) ?? ""
            var header: UInt64 = 8
            if size == 1, let ext = r.read(off + 8, 8) {
                let x = [UInt8](ext)
                size = (UInt64(be32(x, 0)) << 32) | UInt64(be32(x, 4))
                header = 16
            }
            if size == 0 { size = r.size - off }
            if size < header { return }
            if type == "uuid" {
                let bodyStart = off + header + 16
                let bodyLen = Int(min(size - header - 16, 8 * 1024 * 1024 + 64))
                // The PRVW box: 'PRVW', then a few small fields, then the JPEG.
                if bodyLen > 0, let body = r.read(bodyStart, bodyLen) {
                    let bb = [UInt8](body)
                    if let i = find(bb, [0x50, 0x52, 0x56, 0x57]), i >= 4 {   // "PRVW"
                        let boxEnd = min(i - 4 + Int(be32(bb, i - 4)), bb.count)
                        if let s = find(bb, [0xFF, 0xD8, 0xFF], from: i), s < boxEnd {
                            add(&found, r, bodyStart + UInt64(s), boxEnd - s)
                        }
                    }
                }
            }
            off += size
        }
    }

    // MARK: Helpers

    private static func add(_ found: inout [PreviewLocation], _ r: FileReader, _ off: UInt64, _ len: Int) {
        if len < 64 || len > maxPreviewBytes || off == 0 || off + UInt64(len) > r.size { return }
        guard let soi = r.read(off, 3), [UInt8](soi) == [0xFF, 0xD8, 0xFF] else { return }
        found.append(PreviewLocation(offset: off, length: len))
    }

    private static func find(_ b: [UInt8], _ pat: [UInt8], from: Int = 0) -> Int? {
        if b.count < pat.count || from > b.count - pat.count { return nil }
        var i = from
        while i <= b.count - pat.count {
            if b[i] == pat[0] {
                var ok = true
                for j in 1..<pat.count where b[i + j] != pat[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    static func u16(_ b: [UInt8], _ i: Int, _ little: Bool) -> UInt16 {
        if i + 2 > b.count { return 0 }
        return little ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    static func u32(_ b: [UInt8], _ i: Int, _ little: Bool) -> UInt32 {
        if i + 4 > b.count { return 0 }
        let a = UInt32(b[i]), c = UInt32(b[i + 1]), d = UInt32(b[i + 2]), e = UInt32(b[i + 3])
        return little ? a | c << 8 | d << 16 | e << 24 : a << 24 | c << 16 | d << 8 | e
    }

    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 { return u32(b, i, false) }
}
