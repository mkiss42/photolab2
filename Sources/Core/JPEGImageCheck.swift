// JPEGImageCheck.swift
// 0.18.7: proves a rewritten JPEG holds exactly the same picture as the original, natively and fast:
// the picture of a JPEG is everything from its first SOS (start of scan) marker up to and including
// its EOI marker - the compressed image data and the tables between the scans. A metadata change
// (XMP, IPTC, EXIF - all in segments BEFORE the first scan) must leave those bytes identical.
// This replaces ExifTool's ImageDataHash for JPEGs (which ExifTool computes in Perl - reported on the
// ExifTool forum as about 5 times slower than an MD5 of the whole file - and twice per file).
// Read-only. nil = not a JPEG this check understands (the caller falls back to ExifTool's hash).

import Foundation

enum JPEGImageCheck {
    /// Byte range of the picture data (first SOS ... EOI) in a JPEG, or nil.
    /// 0.18.14: where the picture data starts (the first SOS marker), walking only the marker segments
    /// before it. nil = not a sound JPEG header.
    static func pictureStart(_ b: ByteView) -> Int? {
        let n = b.count
        guard n >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 1 < n {
            guard b[i] == 0xFF else { return nil }
            var j = i + 1
            var m = b[j]
            while m == 0xFF && j + 1 < n { j += 1; m = b[j] }      // fill bytes
            if m == 0xDA { return j - 1 }
            if m == 0xD9 { return nil }
            if m == 0x01 || (m >= 0xD0 && m <= 0xD7) { i = j + 1; continue }
            guard j + 2 < n else { return nil }
            let len = Int(b[j + 1]) << 8 | Int(b[j + 2])
            guard len >= 2, j + 1 + len <= n else { return nil }
            i = j + 1 + len
        }
        return nil
    }

    static func pictureRange(_ d: Data) -> Range<Int>? {
        let n = d.count
        return d.withUnsafeBytes { (p: UnsafePointer<UInt8>) -> Range<Int>? in
            guard n >= 4, p[0] == 0xFF, p[1] == 0xD8 else { return nil }
            var i = 2
            var start: Int? = nil
            // Marker segments before (and between) the scans.
            while i + 1 < n {
                guard p[i] == 0xFF else { return nil }
                var m = p[i + 1]
                var j = i + 1
                while m == 0xFF && j + 1 < n { j += 1; m = p[j] }      // fill bytes
                let markerAt = j - 1
                if m == 0xD9 { return start.map { $0..<(j + 1) } }   // EOI
                if m == 0x01 || (m >= 0xD0 && m <= 0xD7) { i = j + 1; continue }   // standalone
                guard j + 2 < n else { return nil }
                let len = Int(p[j + 1]) << 8 | Int(p[j + 2])
                guard len >= 2, j + 1 + len <= n else { return nil }
                if m == 0xDA {
                    if start == nil { start = markerAt }
                    // Entropy-coded data: up to the next marker that is not FF00 or RSTn.
                    var k = j + 1 + len
                    while k + 1 < n {
                        if p[k] == 0xFF {
                            let x = p[k + 1]
                            if x == 0x00 || (x >= 0xD0 && x <= 0xD7) || x == 0xFF { k += (x == 0xFF ? 1 : 2); continue }
                            break
                        }
                        k += 1
                    }
                    if k + 1 >= n { return nil }
                    i = k
                } else {
                    i = j + 1 + len
                }
            }
            return nil
        }
    }

    /// true = both files hold byte-for-byte the same picture data; false = they differ; nil = can't tell.
    static func samePicture(_ a: String, _ b: String) -> Bool? {
        guard let da = try? Data(contentsOf: URL(fileURLWithPath: a), options: .alwaysMapped),
            let db = try? Data(contentsOf: URL(fileURLWithPath: b), options: .alwaysMapped),
            let ra = pictureRange(da), let rb = pictureRange(db) else { return nil }
        IOLog.smallRead(a, bytes: Int64(ra.count))
        IOLog.smallRead(b, bytes: Int64(rb.count))
        if ra.count != rb.count { return false }
        return da.withUnsafeBytes { (pa: UnsafePointer<UInt8>) -> Bool in
            db.withUnsafeBytes { (pb: UnsafePointer<UInt8>) -> Bool in
                memcmp(pa + ra.lowerBound, pb + rb.lowerBound, ra.count) == 0
            }
        }
    }

    static func isJPEG(_ path: String) -> Bool {
        let e = Paths.fileExtension(path).lowercased()
        return e == "jpg" || e == "jpeg" || e == "jpe"
    }
}
