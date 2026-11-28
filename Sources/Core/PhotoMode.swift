// PhotoMode.swift
// Photography mode logic: per-photo facts, filters, the sidecar check report and contact-sheet layout.
// Pure Foundation, tested on Linux. Read-only.

import Foundation

/// What photography mode knows about one picture (read in the background).
struct PhotoFacts: Equatable {
    var rating: Int? = nil          // -1 rejected, 0 none, 1-5 stars
    var colorClass: Int? = nil      // Photo Mechanic colour class 1-8 (0.14)
    var label: String? = nil
    var camera: String? = nil
    var lens: String? = nil
    var width: Int = 0
    var height: Int = 0
    /// PhotoLab S6: the picture's own xmp:MetadataDate (seconds since 1970), if it has one.
    var metadataDate: Double? = nil
    /// Where the rating came from: "sidecar" or "embedded".
    var ratingSource: String? = nil

    static func == (a: PhotoFacts, b: PhotoFacts) -> Bool {
        return a.rating == b.rating && a.label == b.label && a.camera == b.camera && a.lens == b.lens
            && a.width == b.width && a.height == b.height && a.ratingSource == b.ratingSource && a.colorClass == b.colorClass
    }

    /// 0.18: the sidecar is the current set (it was changed after the picture file): its rating, label
    /// and colour class are used as they are - also where it has none - and the file's own are not.
    mutating func use(sidecar f: XMPFields) {
        rating = f.rating
        label = f.label
        colorClass = f.colorClass
        ratingSource = f.rating == nil ? nil : "sidecar"
    }

    /// A sidecar's rating and label take priority over what is embedded in the file
    /// (that is what Photo Mechanic, Lightroom and Capture One write to for RAW files).
    mutating func apply(sidecar f: XMPFields) {
        if let r = f.rating { rating = r; ratingSource = "sidecar" }
        if let l = f.label { label = l }
        if let c = f.colorClass { colorClass = c }
    }
}

enum PhotoFormatFilter: Int {
    case all = 0, raw, jpeg, tiff, photoshop, other

    static let titles = ["All formats", "RAW", "JPEG", "TIFF", "PSD / PSB", "Other images"]

    func matches(_ name: String) -> Bool {
        let e = Paths.fileExtension(name).lowercased()
        switch self {
        case .all: return PhotoFormats.isImage(name)
        case .raw: return PhotoFormats.raw.contains(e)
        case .jpeg: return PhotoFormats.jpeg.contains(e)
        case .tiff: return PhotoFormats.tiff.contains(e)
        case .photoshop: return PhotoFormats.photoshop.contains(e)
        case .other: return PhotoFormats.otherImages.contains(e)
        }
    }
}

enum SidecarFilter: Int {
    case any = 0, with, missing
    static let titles = ["Any sidecar", "Has sidecar", "Missing sidecar (RAW)"]
}

struct PhotoFilter: Equatable {
    var format = PhotoFormatFilter.all
    /// 0.17: the file types picked in the bar (lower-case extensions); empty = every picture.
    var extensions: Set<String> = []
    /// 0 = any; 1-5 = at least that many stars; -1 = rejected only; -2 = unrated only.
    var minRating = 0
    /// 0.17: with minRating 1-5, exactly that many stars instead of at least.
    var exactRating = false
    var label = ""          // "" = any
    /// 0.17: Photo Mechanic colour classes picked as dots (1-8); empty = any. A picture matches if its
    /// colour class is one of them, or its label is one of `classNames` (other programs write labels).
    var colorClasses: Set<Int> = []
    var classNames: [Int: String] = [:]
    var sidecar = SidecarFilter.any
    var text = ""           // camera or lens contains (case-insensitive)

    static func == (a: PhotoFilter, b: PhotoFilter) -> Bool {
        return a.format == b.format && a.extensions == b.extensions && a.minRating == b.minRating && a.exactRating == b.exactRating
            && a.label == b.label && a.colorClasses == b.colorClasses && a.classNames == b.classNames && a.sidecar == b.sidecar && a.text == b.text
    }

    /// True when the filter needs facts read from the files (not just names).
    var needsFacts: Bool {
        return minRating != 0 || !label.isEmpty || !colorClasses.isEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isActive: Bool { return format != .all || !extensions.isEmpty || sidecar != .any || needsFacts }

    enum Verdict { case show, hide, waiting }

    /// The file types present among `names` (pictures only): lower-case extension -> count, for the
    /// Formats menu (0.17: only what is there).
    static func formatsPresent(_ names: [String]) -> [(ext: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in names where PhotoFormats.isImage(n) {
            counts[Paths.fileExtension(n).lowercased(), default: 0] += 1
        }
        return counts.map { (ext: $0.key, count: $0.value) }.sorted { $0.ext < $1.ext }
    }

    /// Decide for one picture. `facts` nil = not read yet (only matters when `needsFacts`).
    func verdict(name: String, hasSidecar: Bool, facts: PhotoFacts?) -> Verdict {
        if !format.matches(name) { return .hide }
        if !extensions.isEmpty && !extensions.contains(Paths.fileExtension(name).lowercased()) { return .hide }
        switch sidecar {
        case .any: break
        case .with: if !hasSidecar { return .hide }
        case .missing: if hasSidecar || !PhotoFormats.isRaw(name) || Sidecars.isDNG(name) { return .hide }   // alpha.6: DNGs have none
        }
        if !needsFacts { return .show }
        guard let f = facts else { return .waiting }
        let r = f.rating ?? 0
        switch minRating {
        case 0: break
        case -1: if r >= 0 { return .hide }
        case -2: if r != 0 { return .hide }
        default: if exactRating ? r != minRating : r < minRating { return .hide }
        }
        if !label.isEmpty && (f.label ?? "").lowercased() != label.lowercased() { return .hide }
        if !colorClasses.isEmpty {
            var hit = false
            if let c = f.colorClass, colorClasses.contains(c) { hit = true }
            if !hit, let l = f.label?.lowercased(), !l.isEmpty {
                hit = colorClasses.contains(where: { classNames[$0]?.lowercased() == l })
            }
            if !hit { return .hide }
        }
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if !t.isEmpty {
            let hay = ((f.camera ?? "") + " " + (f.lens ?? "")).lowercased()
            if !hay.contains(t) { return .hide }
        }
        return .show
    }
}

/// Contact sheet page layout in points (origin top-left; the renderer flips for PDF).
/// The page is a grid of `columns` x `rows` cells. Each cell holds the picture with its caption below;
/// captions wrap with no line limit, so the picture area shrinks to make room (see `pictureBox`).
struct ContactSheetLayout {
    let pageWidth: Double
    let pageHeight: Double
    let columns: Int
    let rows: Int
    let margin: Double = 36
    let headerHeight: Double = 28
    let footerHeight: Double = 20
    let gap: Double = 10

    init(pageWidth: Double, pageHeight: Double, columns: Int, rows: Int) {
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    var cellWidth: Double { return (pageWidth - 2 * margin - Double(columns - 1) * gap) / Double(columns) }
    var cellHeight: Double {
        let avail = pageHeight - 2 * margin - headerHeight - footerHeight
        return (avail - Double(rows - 1) * gap) / Double(rows)
    }
    var perPage: Int { return rows * columns }

    func pages(for count: Int) -> Int { return count == 0 ? 0 : (count + perPage - 1) / perPage }

    /// Cell rectangle for item `i` on its page, y from the top of the page.
    func cell(_ i: Int) -> (page: Int, row: Int, x: Double, y: Double, w: Double, h: Double) {
        let page = i / perPage
        let k = i % perPage
        let row = k / columns, col = k % columns
        let x = margin + Double(col) * (cellWidth + gap)
        let y = margin + headerHeight + Double(row) * (cellHeight + gap)
        return (page, row, x, y, cellWidth, cellHeight)
    }

    /// The picture area of a cell when its row's captions need `captionHeight` points.
    /// The picture keeps at least a quarter of the cell even for very long names.
    func pictureBox(x: Double, y: Double, w: Double, h: Double, captionHeight: Double) -> (x: Double, y: Double, w: Double, h: Double) {
        let ph = max(h * 0.25, h - captionHeight - 3)
        return (x, y, w, ph)
    }

    /// Fit an image of w x h into a box, centred.
    func fit(imageWidth w: Double, height h: Double, inBox b: (x: Double, y: Double, w: Double, h: Double)) -> (x: Double, y: Double, w: Double, h: Double) {
        if w <= 0 || h <= 0 { return b }
        let s = min(b.w / w, b.h / h)
        let fw = w * s, fh = h * s
        return (b.x + (b.w - fw) / 2, b.y + (b.h - fh) / 2, fw, fh)
    }

    static func plural(_ n: Int, _ word: String) -> String { return "\(n) \(word)\(n == 1 ? "" : "s")" }
}

extension ExifSummary {
    static let factTags = ["Make", "Model", "LensModel", "LensID", "Rating#", "Label", "ImageWidth#", "ImageHeight#", "ColorClass#"]

    /// ExifTool JSON for many files at once -> facts keyed by the path ExifTool reports (SourceFile).
    static func facts(fromJSON data: Data) -> [String: PhotoFacts] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [Any] else { return [:] }
        var out: [String: PhotoFacts] = [:]
        for case let d as [String: Any] in arr {
            guard let src = d["SourceFile"] as? String else { continue }
            func str(_ k: String) -> String? {
                guard let v = d[k] else { return nil }
                let s = (v as? String) ?? "\(v)"
                return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
            }
            func num(_ k: String) -> Int? {
                if let n = d[k] as? Int { return n }
                if let n = d[k] as? Double { return Int(n) }
                if let n = d[k] as? NSNumber { return n.intValue }
                if let s = d[k] as? String { return Int(s) }
                return nil
            }
            var f = PhotoFacts()
            f.camera = cameraName(make: str("Make"), model: str("Model"))
            f.lens = str("LensModel") ?? str("LensID")
            if let r = num("Rating") { f.rating = r; f.ratingSource = "embedded" }
            f.label = str("Label")
            if let c = num("ColorClass"), c > 0 { f.colorClass = c }
            f.width = num("ImageWidth") ?? 0
            f.height = num("ImageHeight") ?? 0
            out[src] = f
        }
        return out
    }

    /// "NIKON Z 8" stays as it is; make "Canon" + model "EOS R5" -> "Canon EOS R5".
    static func cameraName(make: String?, model: String?) -> String? {
        guard let m = model else { return make }
        guard let mk = make, let first = mk.split(separator: " ").first else { return m }
        return m.lowercased().contains(first.lowercased()) ? m : mk + " " + m
    }
}
