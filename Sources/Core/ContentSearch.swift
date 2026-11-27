// ContentSearch.swift
// 0.12: search inside files - picture metadata (XMP, IPTC, EXIF text: captions, keywords, headline,
// photographer, camera...) and the text of PDFs and text documents. Read-only.
// Only the part of a file that holds what is searched is read: a JPEG's header segments (up to the
// picture data), the first 512 KB of other pictures, the XMP sidecar, the first 8 MB of a text file.
// PDF text comes from the Mac's PDFKit (set by the app); without it PDFs are not looked inside.

import Foundation

struct InsideScope: OptionSet {
    let rawValue: Int
    static let metadata = InsideScope(rawValue: 1)
    static let documents = InsideScope(rawValue: 2)
}

enum ContentSearch {
    /// Text documents read as text.
    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "rtf", "html", "htm",
                                              "xml", "json", "log", "srt", "vtt", "yaml", "yml", "ini", "cfg",
                                              "conf", "tex", "nfo", "eml", "xmp", "js", "css", "py", "sh", "swift"]
    /// PDF text (the Mac app sets this to PDFKit; nil = PDFs are not looked inside).
    static var pdfText: ((String) -> String?)? = nil

    /// Can this file have contents of the chosen kinds?
    static func isCandidate(_ name: String, _ scope: InsideScope) -> Bool {
        let ext = Paths.fileExtension(name).lowercased()
        if scope.contains(.metadata) && (PhotoFormats.isImage(name) || ext == "xmp") { return true }
        if scope.contains(.documents) && (textExtensions.contains(ext) || (ext == "pdf" && pdfText != nil)) { return true }
        return false
    }

    /// Does the file contain `needle` (already normalised with NameNorm) in the chosen kinds of content?
    static func contains(path: String, name: String, needle: String, caseSensitive: Bool, scope: InsideScope) -> Bool {
        if needle.isEmpty { return false }
        let ext = Paths.fileExtension(name).lowercased()
        func found(_ text: String) -> Bool {
            return NameNorm.norm(text, caseSensitive: caseSensitive).contains(needle)
        }
        if scope.contains(.metadata) && (PhotoFormats.isImage(name) || ext == "xmp") {
            if let t = metadataText(path, name: name), found(t) { return true }
        }
        if scope.contains(.documents) {
            if textExtensions.contains(ext), let t = textFile(path), found(t) { return true }
            if ext == "pdf", let reader = pdfText, let t = reader(path), found(t) { return true }
        }
        return false
    }

    /// Metadata text of a picture: its header part plus its XMP sidecar(s).
    static func metadataText(_ path: String, name: String) -> String? {
        var parts: [String] = []
        let ext = Paths.fileExtension(name).lowercased()
        if ext == "xmp" {
            if let d = readPrefix(path, max: 4 << 20) { parts.append(String(decoding: d, as: UTF8.self)) }
        } else if PhotoFormats.jpeg.contains(ext) {
            if let d = readPrefix(path, max: 1 << 20) { parts.append(String(decoding: jpegHeader(d), as: UTF8.self)) }
        } else if let d = readPrefix(path, max: 512 << 10) {
            parts.append(String(decoding: d, as: UTF8.self))
        }
        if ext != "xmp" {
            let dir = Paths.parent(path)
            for c in Sidecars.candidateNames(for: name) {
                let p = Paths.join(dir, c)
                var e: Int32 = 0
                if let i = Sys.lstatInfo(p, &e), i.isRegular, let d = readPrefix(p, max: 4 << 20) {
                    parts.append(String(decoding: d, as: UTF8.self))
                    break
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The bytes of a JPEG up to the start of the picture data (SOS): all its metadata segments.
    static func jpegHeader(_ d: Data) -> Data {
        let b = [UInt8](d)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return d }
        var i = 2
        while i + 4 <= b.count {
            if b[i] != 0xFF { break }
            let marker = b[i + 1]
            if marker == 0xDA { return d.prefix(i) }      // start of scan: the picture data follows
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if len < 2 { break }
            i += 2 + len
        }
        return d.prefix(min(b.count, i))
    }

    /// A text document (UTF-8, or UTF-16 with a byte-order mark), first 8 MB.
    static func textFile(_ path: String) -> String? {
        guard let d = readPrefix(path, max: 8 << 20) else { return nil }
        if d.count >= 2 && ((d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xFE) || (d[d.startIndex] == 0xFE && d[d.startIndex + 1] == 0xFF)) {
            return String(data: d, encoding: .utf16)
        }
        return String(decoding: d, as: UTF8.self)
    }

    static func readPrefix(_ path: String, max: Int) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { h.closeFile() }
        let d = h.readData(ofLength: max)
        IOLog.smallRead(path, bytes: Int64(d.count))   // 0.18: I/O logs
        return d
    }
}
