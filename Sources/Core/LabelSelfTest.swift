// LabelSelfTest.swift
// XMP ratings / colour classes: attribute and element forms, Photo Mechanic's ColorClass as the
// master over xmp:Label, Bridge names, MicrosoftPhoto:Rating ignored; and the packet found in
// a JPEG (APP1) and in a TIFF-based file (tag 700).

import Foundation

enum LabelSelfTest {
    static func run() -> [SelfTestResult] {
        let n = "labels-xmp"
        let a = XMPReader.parse(#"<rdf:Description xmp:Rating="4" photomechanic:ColorClass="2" xmp:Label="Blue" MicrosoftPhoto:Rating="75"/>"#)
        let b = XMPReader.parse("<xmp:Rating>3</xmp:Rating><xmp:Label>Purple</xmp:Label>")
        let c = XMPReader.parse(#"<x xap:Rating="-1"/>"#)
        guard a.rating == 4, a.colorClass == 2, b.rating == 3, b.colorClass == 5, c.rating == -1 else {
            return [SelfTestResult(name: n, status: .fail, detail: "parse \(a) \(b) \(c)")]
        }
        guard let dir = AppFiles.makeOpsFixture() else { return [SelfTestResult(name: n, status: .fail, detail: "fixture")] }
        defer { AppFiles.removeOpsFixture(dir) }
        let packet = Array(#"<x:xmpmeta><rdf:Description xmp:Rating="5" photomechanic:ColorClass="3"/></x:xmpmeta>"#.utf8)
        // JPEG: SOI, APP1 with the Adobe XMP id, EOI.
        let id = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
        let len = 2 + id.count + packet.count
        var jpg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)]
        jpg += id
        jpg += packet
        jpg += [0xFF, 0xD9]
        // TIFF (little-endian): IFD0 with one entry, tag 700 -> the packet after the IFD.
        let at = 8 + 2 + 12 + 4
        var tif: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0xBC, 0x02, 7, 0]
        tif += [UInt8(packet.count & 0xFF), UInt8(packet.count >> 8 & 0xFF), 0, 0, UInt8(at), 0, 0, 0, 0, 0, 0, 0]
        tif += packet
        guard AppFiles.makeTestFile(dir + "/x.jpg", data: Data(jpg)), AppFiles.makeTestFile(dir + "/x.dng", data: Data(tif)),
            let rj = BlockReader(dir + "/x.jpg"), let rt = BlockReader(dir + "/x.dng") else {
            return [SelfTestResult(name: n, status: .fail, detail: "files")]
        }
        let lj = XMPReader.embeddedXMP(rj).map { XMPReader.parse($0) }
        let lt = XMPReader.embeddedXMP(rt).map { XMPReader.parse($0) }
        guard lj?.rating == 5, lj?.colorClass == 3, lt?.rating == 5, lt?.colorClass == 3 else {
            return [SelfTestResult(name: n, status: .fail, detail: "embedded: jpg \(String(describing: lj)) tiff \(String(describing: lt))")]
        }
        return [SelfTestResult(name: n, status: .ok, detail: "")]
    }
}
