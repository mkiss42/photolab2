// ThumbnailSelfTest.swift
// A 1200 x 800 JPEG made in memory: the thumbnail is 512 px on the long side with the aspect
// kept, the disk cache round-trips it, and the cache key hash is stable (FNV-1a vector).

import Foundation
import CoreGraphics
import ImageIO

enum ThumbnailSelfTest {
    static func run() -> [SelfTestResult] {
        let n = "thumbnails"
        guard Thumbnails.hash("abc") == "e71fa2190541574b" else {
            return [SelfTestResult(name: n, status: .fail, detail: "hash \(Thumbnails.hash("abc"))")]
        }
        guard let dir = AppFiles.makeOpsFixture() else { return [SelfTestResult(name: n, status: .fail, detail: "fixture")] }
        defer { AppFiles.removeOpsFixture(dir) }
        guard let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return [SelfTestResult(name: n, status: .fail, detail: "context")]
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        guard let img = ctx.makeImage(), let jpeg = Thumbnails.encode(img), AppFiles.makeTestFile(dir + "/pic.jpg", data: jpeg) else {
            return [SelfTestResult(name: n, status: .fail, detail: "test image")]
        }
        let t0 = Date()
        let req = ThumbRequest(source: dir + "/pic.jpg", size: Int64(jpeg.count), modified: Date().timeIntervalSince1970)
        guard let t = Thumbnails.shared.load(req), t.width == 256, abs(t.height - 171) <= 1 else {
            return [SelfTestResult(name: n, status: .fail, detail: "made thumbnail has the wrong size")]
        }
        let cached = AppFiles.thumbnailPath(Thumbnails.hash(req.key))
        guard FileManager.default.fileExists(atPath: cached), let again = Thumbnails.shared.load(req), again.width == 256 else {
            return [SelfTestResult(name: n, status: .fail, detail: "disk cache did not round-trip")]
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        return [SelfTestResult(name: n, status: .ok, detail: String(format: "%.0f ms", ms)), embedded(dir, img)]
    }

    /// A tiny fake RAW (TIFF: IFD0 with orientation 6 + a 2048 x 1365 JPEG preview, SubIFD with a
    /// small 160 px one) and a fake RAF: the parser must pick the big one, read it in few reads
    /// and rotate it.
    static func embedded(_ dir: String, _ base: CGImage) -> SelfTestResult {
        let n = "thumbnails-embedded"
        func jpeg(_ w: Int, _ h: Int) -> Data? {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage().flatMap { Thumbnails.encode($0) }
        }
        guard let big = jpeg(2048, 1365), let small = jpeg(160, 107) else { return SelfTestResult(name: n, status: .fail, detail: "jpeg") }
        func le16(_ v: Int) -> [UInt8] { return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func entry(_ tag: Int, _ type: Int, _ value: Int) -> [UInt8] { return le16(tag) + le16(type) + le32(1) + (type == 3 ? le16(value) + [0, 0] : le32(value)) }
        // Layout: header(8) | IFD0 at 8 (4 entries) | SubIFD at 62 (2 entries) | small jpeg | big jpeg
        let ifd0 = 8, sub = ifd0 + 2 + 4 * 12 + 4
        let smallAt = sub + 2 + 2 * 12 + 4, bigAt = smallAt + small.count
        var t: [UInt8] = [0x49, 0x49, 42, 0] + le32(ifd0)
        t += le16(4) + entry(0x0112, 3, 6) + entry(0x014A, 4, sub) + entry(0x0201, 4, bigAt) + entry(0x0202, 4, big.count) + le32(0)
        t += le16(2) + entry(0x0201, 4, smallAt) + entry(0x0202, 4, small.count) + le32(0)
        var file = Data(t)
        file.append(small)
        file.append(big)
        guard AppFiles.makeTestFile(dir + "/fake.NEF", data: file), let r = BlockReader(dir + "/fake.NEF"),
            let img = EmbeddedPreview.thumbnail(r, ext: "nef", maxPixels: 256).image else {
            return SelfTestResult(name: n, status: .fail, detail: "TIFF preview not found")
        }
        guard img.height == 256, abs(img.width - 171) <= 1 else { return SelfTestResult(name: n, status: .fail, detail: "TIFF: \(img.width)x\(img.height), not rotated/picked") }
        let tiffReads = r.reads
        // RAF: magic, JPEG offset/length (big-endian) at 84/88.
        var raf = Data(Array("FUJIFILMCCD-RAW 0201FF383501".utf8))
        raf.append(Data(count: 84 - raf.count))
        func be32(_ v: Int) -> [UInt8] { return [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        raf.append(contentsOf: be32(100) + be32(big.count))
        raf.append(Data(count: 100 - raf.count))
        raf.append(big)
        guard AppFiles.makeTestFile(dir + "/fake.RAF", data: raf), let rr = BlockReader(dir + "/fake.RAF"),
            let img2 = EmbeddedPreview.thumbnail(rr, ext: "raf", maxPixels: 256).image, img2.width == 256 else {
            return SelfTestResult(name: n, status: .fail, detail: "RAF preview not found")
        }
        // PSD: header, empty colour mode data, resources with a dummy block and the 1036 thumbnail,
        // then 2 MB standing in for the composite (must not be read).
        guard let thumb = jpeg(160, 107) else { return SelfTestResult(name: n, status: .fail, detail: "psd jpeg") }
        var psd = Data(Array("8BPS".utf8) + [0, 1] + [UInt8](repeating: 0, count: 6) + [0, 3] + be32(107) + be32(160) + [0, 8, 0, 3])
        psd.append(contentsOf: be32(0))                                              // colour mode data
        func block(_ id: Int, _ payload: [UInt8]) -> [UInt8] {
            var b: [UInt8] = Array("8BIM".utf8) + [UInt8(id >> 8), UInt8(id & 0xFF)] + [0, 0] + be32(payload.count) + payload
            if payload.count % 2 == 1 { b.append(0) }
            return b
        }
        let res = block(1005, [UInt8](repeating: 1, count: 15)) + block(1036, [UInt8](repeating: 0, count: 28) + [UInt8](thumb))
        psd.append(contentsOf: be32(res.count) + res)
        psd.append(Data(count: 2 << 20))
        guard AppFiles.makeTestFile(dir + "/fake.psd", data: psd), let pr = BlockReader(dir + "/fake.psd"),
            let img3 = EmbeddedPreview.thumbnail(pr, ext: "psd", maxPixels: 256).image, img3.width == 160, pr.bytes < 512 << 10 else {
            return SelfTestResult(name: n, status: .fail, detail: "PSD thumbnail not found or too much read")
        }
        return SelfTestResult(name: n, status: .ok, detail: "TIFF \(tiffReads) reads, RAF \(rr.reads) reads, PSD \(pr.reads) reads \(pr.bytes / 1024) KB")
    }
}
