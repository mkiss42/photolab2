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
        guard let t = Thumbnails.shared.load(req), t.width == 512, abs(t.height - 341) <= 1 else {
            return [SelfTestResult(name: n, status: .fail, detail: "made thumbnail has the wrong size")]
        }
        let cached = AppFiles.thumbnailPath(Thumbnails.hash(req.key))
        guard FileManager.default.fileExists(atPath: cached), let again = Thumbnails.shared.load(req), again.width == 512 else {
            return [SelfTestResult(name: n, status: .fail, detail: "disk cache did not round-trip")]
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        return [SelfTestResult(name: n, status: .ok, detail: String(format: "%.0f ms", ms))]
    }
}
