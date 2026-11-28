// PhotoMeta.swift
// Photo file recognition, XMP sidecar association and parsing, and display formatting for metadata.
// Read-only: nothing here changes a file. Pure Foundation so it is tested on Linux.

import Foundation

enum PhotoFormats {
    /// Camera RAW extensions (lowercase). Find never develops or modifies these.
    static let raw: Set<String> = ["nef", "nrw", "dng", "arw", "srf", "sr2", "cr2", "cr3", "crw", "raf", "orf",
                                   "rw2", "pef", "srw", "x3f", "3fr", "fff", "iiq", "erf", "mef", "mos", "raw",
                                   "rwl", "kdc", "dcr", "gpr"]
    static let jpeg: Set<String> = ["jpg", "jpeg", "jpe"]
    static let tiff: Set<String> = ["tif", "tiff"]
    static let photoshop: Set<String> = ["psd", "psb"]
    static let otherImages: Set<String> = ["png", "heic", "heif", "gif", "bmp", "webp", "jp2", "exr", "tga"]

    static func isRaw(_ name: String) -> Bool { return raw.contains(Paths.fileExtension(name).lowercased()) }

    static func isImage(_ name: String) -> Bool {
        let e = Paths.fileExtension(name).lowercased()
        return raw.contains(e) || jpeg.contains(e) || tiff.contains(e) || photoshop.contains(e) || otherImages.contains(e)
    }

    static func isSidecar(_ name: String) -> Bool { return Paths.fileExtension(name).lowercased() == "xmp" }

    /// Short family name shown in the inspector: "RAW (NEF)", "JPEG", "TIFF", "Photoshop (PSB)".
    static func family(_ name: String) -> String? {
        let e = Paths.fileExtension(name).lowercased()
        if raw.contains(e) { return "RAW (\(e.uppercased()))" }
        if jpeg.contains(e) { return "JPEG" }
        if tiff.contains(e) { return "TIFF" }
        if photoshop.contains(e) { return "Photoshop (\(e.uppercased()))" }
        if otherImages.contains(e) { return e.uppercased() }
        if e == "xmp" { return "XMP sidecar" }
        return nil
    }
}

enum Sidecars {
    /// Sidecar names that belong to `fileName`, most common first:
    /// "DSC_0001.xmp" (Lightroom, Capture One, Photo Mechanic, Bridge) and "DSC_0001.NEF.xmp" (darktable).
    static func candidateNames(for fileName: String) -> [String] {
        let base = Paths.baseName(fileName)
        return [base + ".xmp", base + ".XMP", fileName + ".xmp", fileName + ".XMP"]
    }

    /// Existing sidecar for a file, or nil. Checks the disk with lstat only (no reading).
    /// 1.0.0-alpha.6: never for a DNG (a DNG's metadata lives inside it only).
    static func find(for path: String) -> String? {
        let dir = Paths.parent(path)
        let name = Paths.lastComponent(path)
        if isSidecarName(name) || isDNG(name) { return nil }
        for c in candidateNames(for: name) {
            let p = Paths.join(dir, c)
            var e: Int32 = 0
            if let i = Sys.lstatInfo(p, &e), i.isRegular { return p }
        }
        return nil
    }

    // MARK: DNGs have no sidecar (1.0.0-alpha.6, user's rule)
    // A DNG keeps its metadata inside the DNG, as Photo Mechanic, Lightroom and Bridge do: it is never
    // given an .xmp sidecar and never reads one. So "DSC_1.xmp" is only ever the camera RAW's (and its
    // JPEG twin's), and stars or metadata given to DSC_1.DNG can't show up on DSC_1.NEF, or the other
    // way round. (alpha.5 still let a DNG use a sidecar of its own, which clashed with the NEF's.)

    static func isDNG(_ name: String) -> Bool {
        return Paths.fileExtension(name).lowercased() == "dng"
    }

    /// The pictures a sidecar belongs to: never a DNG.
    static func owners(_ images: [String]) -> [String] {
        return images.filter { !isDNG($0) }
    }

    private static func isSidecarName(_ n: String) -> Bool { return PhotoFormats.isSidecar(n) }

    /// Given the names in one folder, pair sidecars with images. Case-insensitive base names.
    /// Returns (image name -> sidecar name), images with no sidecar (RAW only), sidecars with no image.
    static func associate(_ names: [String]) -> (pairs: [String: String], missing: [String], orphans: [String]) {
        var images: [String: [String]] = [:]   // lowercased key -> image names
        var sidecars: [String] = []
        for n in names {
            if PhotoFormats.isSidecar(n) { sidecars.append(n); continue }
            if PhotoFormats.isImage(n) {
                images[Paths.baseName(n).lowercased(), default: []].append(n)
                images[n.lowercased(), default: []].append(n)
            }
        }
        var pairs: [String: String] = [:]
        var orphans: [String] = []
        for s in sidecars {
            let key = Paths.baseName(s).lowercased()   // "dsc_0001" or "dsc_0001.nef"
            if let found = images[key] {
                for o in owners(found) where pairs[o] == nil { pairs[o] = s }
            } else {
                orphans.append(s)
            }
        }
        var missing: [String] = []
        for n in names where PhotoFormats.isRaw(n) && pairs[n] == nil { missing.append(n) }
        return (pairs, missing.sorted(), orphans.sorted())
    }

    /// Photography mode: the XMP sidecars that travel with `selected` when they are moved or copied
    /// (sidecars are not shown in that view, so the user can't select them).
    /// A sidecar belongs to every image with its base name (DSC_1.xmp -> DSC_1.NEF and DSC_1.JPG;
    /// DSC_1.NEF.xmp -> DSC_1.NEF only). Copy: it goes along if any of its images is copied.
    /// Move: only if ALL of its images are moved - otherwise it stays with the image left behind and is
    /// reported in `keptBack`. Sidecars that are themselves selected are not added twice.
    /// `list` gives the names in a folder (one call per folder).
    static func companions(of selected: [String], move: Bool, list: (String) -> [String]) -> (extra: [String], keptBack: [String]) {
        var byFolder: [String: [String]] = [:]
        for p in selected { byFolder[Paths.parent(p), default: []].append(Paths.lastComponent(p)) }
        var extra: [String] = [], kept: [String] = []
        for (dir, picked) in byFolder.sorted(by: { $0.key < $1.key }) {
            let pickedLower = Set(picked.map { $0.lowercased() })
            if !picked.contains(where: { PhotoFormats.isImage($0) }) { continue }
            let names = list(dir)
            let images = names.filter { PhotoFormats.isImage($0) && !PhotoFormats.isSidecar($0) }
            for s in names.sorted() where PhotoFormats.isSidecar(s) && !pickedLower.contains(s.lowercased()) {
                let key = Paths.baseName(s).lowercased()
                let group = Sidecars.owners(images.filter { Paths.baseName($0).lowercased() == key || $0.lowercased() == key })
                if group.isEmpty { continue }
                let chosen = group.filter { pickedLower.contains($0.lowercased()) }
                if chosen.isEmpty { continue }
                if !move || chosen.count == group.count {
                    extra.append(Paths.join(dir, s))
                } else {
                    kept.append(Paths.join(dir, s))
                }
            }
        }
        return (extra, kept)
    }
}

/// The fields Find shows from an XMP sidecar.
struct XMPFields: Equatable {
    var rating: Int?
    var label: String?
    var colorClass: Int?
    var keywords: [String] = []
    var creator: [String] = []
    var rights: String?
    var description: String?
    var title: String?
    /// PhotoLab S6: xmp:MetadataDate (seconds since 1970), when the sidecar has one.
    var metadataDate: Double?

    var isEmpty: Bool {
        return rating == nil && label == nil && colorClass == nil && keywords.isEmpty && creator.isEmpty && rights == nil && description == nil && title == nil
    }

    static func == (a: XMPFields, b: XMPFields) -> Bool {
        return a.rating == b.rating && a.label == b.label && a.colorClass == b.colorClass && a.keywords == b.keywords && a.creator == b.creator
            && a.rights == b.rights && a.description == b.description && a.title == b.title
    }
}

/// Small, tolerant XMP reader for sidecars (no XML library needed, no entity expansion beyond the basic five).
enum XMPReader {
    static let maxBytes = 4 * 1024 * 1024

    static func read(path: String) -> XMPFields? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: maxBytes)
        IOLog.smallRead(path, bytes: Int64(data.count))
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> XMPFields {
        var f = XMPFields()
        if let r = simple(text, "xmp:Rating"), let v = Int(r.trimmingCharacters(in: .whitespaces)) { f.rating = v }
        if let l = simple(text, "xmp:Label"), !l.isEmpty { f.label = l }
        if let c = simple(text, "photomechanic:ColorClass"), let v = Int(c.trimmingCharacters(in: .whitespaces)), v > 0 { f.colorClass = v }
        f.keywords = list(text, "dc:subject")
        f.creator = list(text, "dc:creator")
        f.rights = list(text, "dc:rights").first
        f.description = list(text, "dc:description").first
        f.title = list(text, "dc:title").first
        f.metadataDate = simple(text, "xmp:MetadataDate").flatMap { MetaPlan.xmpDate($0) }
        return f
    }

    /// A simple property written as an attribute (xmp:Rating="3") or element (<xmp:Rating>3</xmp:Rating>).
    static func simple(_ text: String, _ tag: String) -> String? {
        if let r = text.range(of: tag + "=\"") {
            let rest = text[r.upperBound...]
            if let end = rest.index(of: "\"") { return decode(String(rest[..<end])) }
        }
        if let r = text.range(of: tag + "='") {
            let rest = text[r.upperBound...]
            if let end = rest.index(of: "'") { return decode(String(rest[..<end])) }
        }
        if let inner = element(text, tag) {
            let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.contains("<") { return decode(t) }
        }
        return nil
    }

    /// The rdf:li values inside <tag>...</tag> (Bag, Seq or Alt).
    static func list(_ text: String, _ tag: String) -> [String] {
        guard let inner = element(text, tag) else { return [] }
        var out: [String] = []
        var rest = Substring(inner)
        while let open = rest.range(of: "<rdf:li") {
            guard let gt = rest[open.upperBound...].index(of: ">") else { break }
            let selfClosing = gt > rest.startIndex && rest[rest.index(before: gt)] == "/"
            let after = rest.index(after: gt)
            if selfClosing { rest = rest[after...]; continue }
            guard let close = rest[after...].range(of: "</rdf:li>") else { break }
            let v = decode(String(rest[after..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            if !v.isEmpty { out.append(v) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    private static func element(_ text: String, _ tag: String) -> String? {
        var search = Substring(text)
        while let open = search.range(of: "<" + tag) {
            let after = open.upperBound
            guard after < search.endIndex else { return nil }
            let c = search[after]
            // Must be the whole tag name: "<dc:subject>" or "<dc:subject attr...", not "<dc:subjectX".
            if c == ">" || c == " " || c == "\n" || c == "\t" || c == "\r" {
                guard let gt = search[after...].index(of: ">") else { return nil }
                if search[search.index(before: gt)] == "/" { return "" }
                let bodyStart = search.index(after: gt)
                guard let close = search[bodyStart...].range(of: "</" + tag + ">") else { return nil }
                return String(search[bodyStart..<close.lowerBound])
            }
            search = search[after...]
        }
        return nil
    }

    static func decode(_ s: String) -> String {
        if !s.contains("&") { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#xA;", with: "\n").replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Display formatting for camera values.
enum MetaFormat {
    /// "2026-11-24 10:15" (local time) for a file date.
    static func shortDate(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func shutter(_ seconds: Double) -> String {
        if seconds <= 0 { return "" }
        if seconds >= 0.3 {
            let r = (seconds * 10).rounded() / 10
            return (r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)) + " s"
        }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    static func aperture(_ f: Double) -> String {
        if f <= 0 { return "" }
        let r = (f * 10).rounded() / 10
        return "f/" + (r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r))
    }

    static func focal(_ mm: Double, equiv35: Double? = nil) -> String {
        if mm <= 0 { return "" }
        let r = (mm * 10).rounded() / 10
        var s = (r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)) + " mm"
        if let e = equiv35, e > 0, Int(e.rounded()) != Int(mm.rounded()) { s += " (\(Int(e.rounded())) mm in 35mm)" }
        return s
    }

    static func exposureBias(_ ev: Double) -> String {
        let r = (ev * 10).rounded() / 10
        if r == 0 { return "0 EV" }
        return (r > 0 ? "+" : "") + String(format: "%.1f", r) + " EV"
    }

    static func aspect(_ w: Int, _ h: Int) -> String {
        if w <= 0 || h <= 0 { return "" }
        func gcd(_ a: Int, _ b: Int) -> Int { return b == 0 ? a : gcd(b, a % b) }
        let g = gcd(w, h)
        let a = w / g, b = h / g
        if a <= 21 && b <= 21 { return "\(a):\(b)" }
        let big = max(w, h), small = min(w, h)
        return String(format: "%.2f:1", Double(big) / Double(small)) + (w >= h ? "" : " (portrait)")
    }

    static func megapixels(_ w: Int, _ h: Int) -> String {
        let mp = Double(w) * Double(h) / 1_000_000
        return String(format: mp >= 10 ? "%.0f MP" : "%.1f MP", mp)
    }

    /// 34.0523, "N" -> 34°03'08.3"N
    static func dms(_ value: Double, _ ref: String) -> String {
        let v = abs(value)
        let d = Int(v)
        let mTotal = (v - Double(d)) * 60
        var m = Int(mTotal)
        var s = (mTotal - Double(m)) * 60
        s = (s * 10).rounded() / 10
        var dd = d
        if s >= 60 { s -= 60; m += 1 }
        if m >= 60 { m -= 60; dd += 1 }
        return String(format: "%d\u{00B0}%02d'%04.1f\"", dd, m, s) + ref
    }

    static func gps(lat: Double, latRef: String, lon: Double, lonRef: String) -> String {
        return dms(lat, latRef) + " " + dms(lon, lonRef)
    }

    /// Signed decimal form for copying into a map: 34.052300, -118.243700
    static func gpsDecimal(lat: Double, latRef: String, lon: Double, lonRef: String) -> String {
        let la = (latRef.uppercased() == "S" ? -1 : 1) * abs(lat)
        let lo = (lonRef.uppercased() == "W" ? -1 : 1) * abs(lon)
        return String(format: "%.6f, %.6f", la, lo)
    }

    static func stars(_ rating: Int) -> String {
        if rating < 0 { return "Rejected" }
        if rating == 0 { return "No stars" }
        let n = min(rating, 5)
        return String(repeating: "\u{2605}", count: n) + String(repeating: "\u{2606}", count: 5 - n) + " (\(n))"
    }
}

/// In-memory cache of extracted metadata, keyed by path and checked against size + modified date
/// so an unchanged file is never read twice and a changed one always is.
final class MetaCache<Value> {
    private struct Slot { let size: Int64; let modified: Double; let value: Value; var used: UInt64 }
    private var slots: [String: Slot] = [:]
    private var clock: UInt64 = 0
    private let limit: Int
    private let lock = NSLock()
    private(set) var hits = 0
    private(set) var misses = 0

    init(limit: Int = 500) { self.limit = limit }

    func get(_ path: String, size: Int64, modified: Double) -> Value? {
        lock.lock(); defer { lock.unlock() }
        clock += 1
        if var s = slots[path], s.size == size, s.modified == modified {
            s.used = clock
            slots[path] = s
            hits += 1
            return s.value
        }
        misses += 1
        return nil
    }

    func put(_ path: String, size: Int64, modified: Double, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        clock += 1
        slots[path] = Slot(size: size, modified: modified, value: value, used: clock)
        if slots.count > limit {
            let drop = slots.sorted { $0.value.used < $1.value.used }.prefix(slots.count - limit)
            for (k, _) in drop { slots[k] = nil }
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return slots.count }

    func removeAll() { lock.lock(); slots.removeAll(); lock.unlock() }
}

/// One titled block of the inspector: rows of (label, value).
struct MetaSection {
    let title: String
    var rows: [(String, String)]

    init(_ title: String, _ rows: [(String, String)] = []) {
        self.title = title
        self.rows = rows
    }

    mutating func add(_ label: String, _ value: String?) {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        rows.append((label, v))
    }

    /// Plain ASCII lines for logs and "Copy" (label: value), one fact per line.
    var asciiLines: [String] {
        return rows.map { Ascii.clean("\(title) - \($0.0): \($0.1)") }
    }
}

/// Turns ExifTool's JSON (from ExifTool.summaryArguments) into the inspector's sections.
/// Used when macOS itself can't read a file's details (e.g. newer RAW formats on High Sierra).
enum ExifSummary {
    /// Numbers (#) where Find formats the value; text where ExifTool's wording is better (lens names).
    static let tags = ["Make", "Model", "LensModel", "LensID", "Lens", "FocalLength#", "FocalLengthIn35mmFormat#",
                       "FNumber#", "ExposureTime#", "ISO#", "ExposureCompensation#", "ImageWidth#", "ImageHeight#",
                       "GPSLatitude#", "GPSLongitude#", "Rating#", "Label", "Subject", "Keywords", "Creator", "Artist",
                       "By-line", "Copyright", "Rights", "CopyrightNotice", "Description", "Caption-Abstract", "Title",
                       "ObjectName", "DateTimeOriginal", "SerialNumber", "City", "Country"]

    static func sections(fromJSON data: Data) -> [MetaSection]? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [Any],
            let d = arr.first as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            guard let v = d[k] else { return nil }
            if let s = v as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
            if let a = v as? [Any] { let j = a.map { "\($0)" }.joined(separator: ", "); return j.isEmpty ? nil : j }
            return "\(v)"
        }
        func num(_ k: String) -> Double? {
            if let n = d[k] as? Double { return n }
            if let n = d[k] as? Int { return Double(n) }
            if let n = d[k] as? Int64 { return Double(n) }
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let s = d[k] as? String { return Double(s) }
            return nil
        }
        var image = MetaSection("Image (via ExifTool)")
        if let w = num("ImageWidth"), let h = num("ImageHeight"), w > 0, h > 0 {
            image.add("Dimensions", "\(Int(w)) x \(Int(h)) pixels")
            image.add("Megapixels", MetaFormat.megapixels(Int(w), Int(h)))
            image.add("Aspect ratio", MetaFormat.aspect(Int(w), Int(h)))
        }
        var camera = MetaSection("Camera (via ExifTool)")
        camera.add("Make", str("Make"))
        camera.add("Model", str("Model"))
        var lens = str("LensModel") ?? str("LensID")
        if lens == nil, let l = str("Lens"), Double(l) == nil { lens = l }
        camera.add("Lens", lens)
        if let f = num("FocalLength"), f > 0 { camera.add("Focal length", MetaFormat.focal(f, equiv35: num("FocalLengthIn35mmFormat"))) }
        if let a = num("FNumber"), a > 0 { camera.add("Aperture", MetaFormat.aperture(a)) }
        if let t = num("ExposureTime"), t > 0 { camera.add("Shutter speed", MetaFormat.shutter(t)) }
        if let i = num("ISO"), i > 0 { camera.add("ISO", "\(Int(i))") }
        if let b = num("ExposureCompensation") { camera.add("Exposure comp.", MetaFormat.exposureBias(b)) }
        camera.add("Taken", str("DateTimeOriginal"))
        camera.add("Serial number", str("SerialNumber"))
        var location = MetaSection("Location (via ExifTool)")
        if let la = num("GPSLatitude"), let lo = num("GPSLongitude") {
            location.add("GPS", MetaFormat.gps(lat: la, latRef: la < 0 ? "S" : "N", lon: lo, lonRef: lo < 0 ? "W" : "E"))
            location.add("Decimal", MetaFormat.gpsDecimal(lat: la, latRef: la < 0 ? "S" : "N", lon: lo, lonRef: lo < 0 ? "W" : "E"))
        }
        location.add("City", str("City"))
        location.add("Country", str("Country"))
        var desc = MetaSection("Description (via ExifTool)")
        if let r = num("Rating"), r != 0 { desc.add("Rating", MetaFormat.stars(Int(r))) }
        desc.add("Label", str("Label"))
        desc.add("Title", str("Title") ?? str("ObjectName"))
        desc.add("Description", str("Description") ?? str("Caption-Abstract"))
        desc.add("Keywords", str("Subject") ?? str("Keywords"))
        desc.add("Creator", str("Creator") ?? str("By-line") ?? str("Artist"))
        desc.add("Copyright", str("Rights") ?? str("CopyrightNotice") ?? str("Copyright"))
        return [image, camera, location, desc].filter { !$0.rows.isEmpty }
    }
}

/// 0.18.10: RAW + JPEG pairs (same name, same folder - the camera's RAW+JPEG mode). Photography Mode can
/// show only the RAW with a "NEF+JPG" badge; the hidden JPEG then goes along with what is done to its RAW.
enum RawTwins {
    static func isJPEG(_ name: String) -> Bool {
        let e = Paths.fileExtension(name).lowercased()
        return e == "jpg" || e == "jpeg"
    }

    /// For one folder's names: RAW name -> its JPEG twin's name.
    static func pairs(_ names: [String]) -> [String: String] {
        var raws: [String: String] = [:]     // base (lowercased) -> RAW name
        for n in names where PhotoFormats.isRaw(n) {
            let b = Paths.baseName(n).lowercased()
            if raws[b] == nil || n < raws[b]! { raws[b] = n }
        }
        var out: [String: String] = [:]
        for n in names.sorted() where isJPEG(n) {
            if let r = raws[Paths.baseName(n).lowercased()], out[r] == nil { out[r] = n }
        }
        return out
    }

    /// Badge text for a pair: "NEF+JPG".
    static func badge(raw: String, jpeg: String) -> String {
        return Paths.fileExtension(raw).uppercased() + "+" + (Paths.fileExtension(jpeg).uppercased() == "JPEG" ? "JPEG" : "JPG")
    }

    /// The JPEG twins (full paths) of the RAWs among `paths` that aren't picked themselves.
    static func twins(of paths: [String], list: (String) -> [String]) -> [String] {
        var byFolder: [String: [String]] = [:]
        for p in paths where PhotoFormats.isRaw(Paths.lastComponent(p)) { byFolder[Paths.parent(p), default: []].append(Paths.lastComponent(p)) }
        let picked = Set(paths)
        var out: [String] = []
        for (dir, rs) in byFolder.sorted(by: { $0.key < $1.key }) {
            let pr = pairs(list(dir))
            for r in rs.sorted() {
                if let j = pr[r] {
                    let jp = Paths.join(dir, j)
                    if !picked.contains(jp) && !out.contains(jp) { out.append(jp) }
                }
            }
        }
        return out
    }
}
