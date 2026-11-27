// XMPReader.swift
// Ratings and colour classes, read natively (no ExifTool) so a whole folder can be shown fast:
//   - a set with an .xmp sidecar: the sidecar (small, one read);
//   - otherwise the XMP packet inside the file, found near its start: JPEG APP1 (Adobe XMP),
//     TIFF-based RAWs/DNG/TIFF (tag 700), CR3 (XMP uuid box), PSD (resource 1060), PNG (iTXt).
// Fields (PhotoLab 1 / Photo Mechanic): xmp:Rating 0-5 (-1 = reject); XMP:ColorClass 0-8 is the
// master (photomechanic:ColorClass); xmp:Label ("Red"...) is only used when ColorClass is absent,
// and is kept in step by the writer (lab decision 2026-11-26).

import Foundation

struct ImageLabels: Equatable {
    var rating = 0          // -1 reject, 0 none, 1-5 stars
    var colorClass = 0      // 0 none, 1 Red, 2 Yellow, 3 Green, 4 Blue, 5 Violet, 6 Cyan, 7 Brown, 8 Gray
    var source = ""         // "sidecar", "embedded", "none"
}

enum XMPReader {
    static let colorNames = ["None", "Red", "Yellow", "Green", "Blue", "Violet", "Cyan", "Brown", "Gray"]

    /// Labels from an XMP packet (attribute or element form, any namespace prefix for ColorClass;
    /// xmp/xap for Rating and Label - MicrosoftPhoto:Rating is 0-99 and ignored).
    static func parse(_ xmp: String) -> ImageLabels {
        var l = ImageLabels()
        func value(_ prefixes: [String]?, _ name: String) -> String? {
            let p = prefixes.map { "(?:" + $0.joined(separator: "|") + ")" } ?? "[A-Za-z][A-Za-z0-9_]*"
            for pattern in ["\(p):\(name)\\s*=\\s*[\"']([^\"']*)[\"']", "<\(p):\(name)>\\s*([^<]*?)\\s*</"] {
                if let re = try? NSRegularExpression(pattern: pattern, options: []),
                    let m = re.firstMatch(in: xmp, options: [], range: NSRange(xmp.startIndex..., in: xmp)),
                    let r = Range(m.range(at: 1), in: xmp) {
                    return String(xmp[r]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        if let r = value(["xmp", "xap"], "Rating"), let v = Double(r) { l.rating = max(-1, min(5, Int(v))) }
        if let c = value(nil, "ColorClass") {
            // Photo Mechanic writes the number, sometimes "2 - Yellow"-style text.
            if let n = Int(c.prefix { $0.isNumber }), (0...8).contains(n) { l.colorClass = n }
            else if let i = colorIndex(c) { l.colorClass = i }
        } else if let label = value(["xmp", "xap"], "Label"), let i = colorIndex(label) {
            l.colorClass = i
        }
        return l
    }

    /// "Red" / "red" / "Purple" (Bridge's name for violet) -> 1...8.
    static func colorIndex(_ name: String) -> Int? {
        let n = name.lowercased()
        if n == "purple" { return 5 }
        if n == "grey" { return 8 }
        return colorNames.firstIndex { $0.lowercased() == n }.flatMap { $0 == 0 ? nil : $0 }
    }

    /// The labels of one row: its sidecar if the set has one, else the representative file's
    /// embedded XMP. Background thread.
    static func read(entry: FileEntry, members: [FileEntry]) -> ImageLabels {
        if let side = members.first(where: { $0.ext == "xmp" }) {
            if let d = FileManager.default.contents(atPath: side.path), let s = String(data: d, encoding: .utf8) {
                var l = parse(s); l.source = "sidecar"; return l
            }
        }
        guard let r = BlockReader(entry.path), let s = embeddedXMP(r) else { return ImageLabels(rating: 0, colorClass: 0, source: "none") }
        var l = parse(s)
        l.source = "embedded"
        return l
    }

    // MARK: Finding the packet

    private static let jpegXMPID = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    private static let cr3XMP: [UInt8] = [0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8, 0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac]

    static func embeddedXMP(_ r: BlockReader) -> String? {
        guard let head = r.read(0, 64), head.count >= 16 else { return nil }
        if head[0] == 0xFF && head[1] == 0xD8 { return jpeg(r) }
        if head[0] == head[1], head[0] == 0x49 || head[0] == 0x4D { return tiff(r) }
        if Array(head[0..<4]) == Array("8BPS".utf8) { return psd(r) }
        if Array(head[4..<8]) == Array("ftyp".utf8) { return cr3(r) }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return png(r) }
        return nil
    }

    private static func text(_ d: Data?) -> String? {
        guard let d = d, !d.isEmpty else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    private static func jpeg(_ r: BlockReader) -> String? {
        var pos: Int64 = 2
        for _ in 0..<40 {
            guard let m = r.read(pos, 4), m.count == 4, m[0] == 0xFF else { return nil }
            if m[1] == 0xDA || m[1] == 0xD9 { return nil }
            let len = Int64(Int(m[2]) << 8 | Int(m[3]))
            if m[1] == 0xE1, let id = r.read(pos + 4, jpegXMPID.count), Array(id) == jpegXMPID {
                return text(r.read(pos + 4 + Int64(jpegXMPID.count), Int(len) - 2 - jpegXMPID.count))
            }
            pos += 2 + len
        }
        return nil
    }

    /// IFD0 tag 700 (XMP) of a TIFF-based file.
    private static func tiff(_ r: BlockReader) -> String? {
        guard let h = r.read(0, 8), h.count == 8 else { return nil }
        let le = h[0] == 0x49
        func u16(_ d: Data, _ o: Int) -> Int { return le ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32(_ d: Data, _ o: Int) -> Int64 {
            let a = Int64(d[o]), b = Int64(d[o + 1]), c = Int64(d[o + 2]), e = Int64(d[o + 3])
            return le ? a | b << 8 | c << 16 | e << 24 : a << 24 | b << 16 | c << 8 | e
        }
        let ifd = u32(h, 4)
        guard let ch = r.read(ifd, 2), ch.count == 2 else { return nil }
        let n = u16(ch, 0)
        guard n > 0, n < 1000, let d = r.read(ifd + 2, n * 12), d.count == n * 12 else { return nil }
        for i in 0..<n where u16(d, i * 12) == 700 {
            let count = Int(u32(d, i * 12 + 4)), off = u32(d, i * 12 + 8)
            guard count > 0, count < 8 << 20 else { return nil }
            return text(count <= 4 ? nil : r.read(off, count))
        }
        return nil
    }

    private static func psd(_ r: BlockReader) -> String? {
        guard let cm = r.read(26, 4), cm.count == 4 else { return nil }
        let at = 26 + 4 + Int64(EmbeddedPreview.be32(cm, 0))
        guard let rl = r.read(at, 4), rl.count == 4 else { return nil }
        var pos = at + 4
        let end = pos + Int64(EmbeddedPreview.be32(rl, 0))
        for _ in 0..<400 {
            guard pos + 12 <= end, let h = r.read(pos, 8 + 256), h.count >= 12, Array(h[0..<4]) == Array("8BIM".utf8) else { return nil }
            let id = Int(h[4]) << 8 | Int(h[5])
            let nameField = (1 + Int(h[6]) + 1) & ~1
            let size = Int64(EmbeddedPreview.be32(h, 6 + nameField))
            let data = pos + 6 + Int64(nameField) + 4
            if id == 1060 { return text(r.read(data, Int(size))) }
            pos = data + ((size + 1) & ~1)
        }
        return nil
    }

    private static func cr3(_ r: BlockReader) -> String? {
        var pos: Int64 = 0
        for _ in 0..<64 {
            guard let h = r.read(pos, 24), h.count >= 24 else { return nil }
            let size = Int64(EmbeddedPreview.be32(h, 0))
            guard size >= 8 else { return nil }
            if String(bytes: h[4..<8], encoding: .ascii) == "uuid", Array(h[8..<24]) == cr3XMP {
                return text(r.read(pos + 24, Int(size - 24)))
            }
            pos += size
            if pos >= r.size { return nil }
        }
        return nil
    }

    private static func png(_ r: BlockReader) -> String? {
        var pos: Int64 = 8
        for _ in 0..<64 {
            guard let h = r.read(pos, 8), h.count == 8 else { return nil }
            let len = Int64(EmbeddedPreview.be32(h, 0))
            let type = String(bytes: h[4..<8], encoding: .ascii) ?? ""
            if type == "IDAT" || type == "IEND" { return nil }
            if type == "iTXt", let d = r.read(pos + 8, Int(min(len, 8 << 20))), let s = text(d), s.hasPrefix("XML:com.adobe.xmp") {
                return s
            }
            pos += 12 + len
        }
        return nil
    }
}

extension Notification.Name {
    /// Labels were read; userInfo["paths"] = [String] (row paths). Main thread.
    static let labelsReady = Notification.Name("PhotoLabLabelsReady")
}

/// Background reading of labels: rows on screen first, the rest of the folder after (PhotoLab
/// 1's progress), 2 at a time per share. Cached by the file read (path + size + mtime).
final class LabelLoader {
    static let shared = LabelLoader()
    private let lock = NSLock()
    private var cache: [String: ImageLabels] = [:]
    private var queues: [String: OperationQueue] = [:]
    private var wanted: [ObjectIdentifier: Set<String>] = [:]
    private var inFlight = Set<String>()

    /// Key: the file the labels come from (sidecar or the file), with its size and date.
    static func key(_ entry: FileEntry, _ members: [FileEntry]) -> String {
        let f = members.first { $0.ext == "xmp" } ?? entry
        return "\(entry.path)|\(f.path)|\(f.size)|\(Int64(f.modified * 1000))"
    }

    func cached(_ key: String) -> ImageLabels? { lock.lock(); defer { lock.unlock() }; return cache[key] }

    /// After our own write: show the new values at once.
    func store(_ key: String, _ l: ImageLabels) { lock.lock(); cache[key] = l; lock.unlock() }

    /// `rows` in priority order (on screen first). Older wishes of this owner are dropped.
    func request(_ rows: [(entry: FileEntry, members: [FileEntry])], owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        lock.lock()
        wanted[id] = Set(rows.map { LabelLoader.key($0.entry, $0.members) })
        var todo: [(String, FileEntry, [FileEntry])] = []
        for r in rows {
            let k = LabelLoader.key(r.entry, r.members)
            if cache[k] == nil && !inFlight.contains(k) { inFlight.insert(k); todo.append((k, r.entry, r.members)) }
        }
        lock.unlock()
        var batch: [String: [(String, FileEntry, [FileEntry])]] = [:]
        for t in todo { batch[Volumes.volume(for: t.1.path)?.mountPoint ?? "/", default: []].append(t) }
        for (vol, items) in batch {
            lock.lock()
            let q = queues[vol] ?? { let o = OperationQueue(); o.maxConcurrentOperationCount = Volumes.volume(for: vol)?.isNetwork ?? false ? 2 : 4
                o.qualityOfService = .utility; return o }()
            queues[vol] = q
            lock.unlock()
            // Chunks of 20: one notification per chunk, and stale wishes are dropped between them.
            stride(from: 0, to: items.count, by: 20).forEach { start in
                let chunk = Array(items[start..<min(items.count, start + 20)])
                q.addOperation { [weak self] in
                    guard let me = self else { return }
                    var done: [String] = []
                    for (k, e, m) in chunk {
                        me.lock.lock(); let still = me.wanted.values.contains { $0.contains(k) }; me.lock.unlock()
                        if still {
                            let l = XMPReader.read(entry: e, members: m)
                            me.lock.lock(); me.cache[k] = l; me.lock.unlock()
                            done.append(e.path)
                        }
                        me.lock.lock(); me.inFlight.remove(k); me.lock.unlock()
                    }
                    if !done.isEmpty { DispatchQueue.main.async { NotificationCenter.default.post(name: .labelsReady, object: nil, userInfo: ["paths": done]) } }
                }
            }
        }
    }

    func release(owner: AnyObject) { lock.lock(); wanted.removeValue(forKey: ObjectIdentifier(owner)); lock.unlock() }
}
