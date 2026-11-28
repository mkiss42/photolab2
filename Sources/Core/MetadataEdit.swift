// MetadataEdit.swift
// Star ratings and IPTC/XMP metadata, written so Photo Mechanic (and Lightroom, Bridge, Capture One)
// read them:
// - RAW files (NEF, CR2, CR3, ARW, RAF, DNG ...): 0.18 - into the RAW itself (its IPTC/XMP fields only;
//   the picture data is never changed) AND into its XMP sidecar (DSC_1.xmp) if it has one; both are
//   written with the same complete set of values, so they agree afterwards. No sidecar: the RAW only
//   (a new sidecar is made only if the RAW type can't be written).
// - JPEG and TIFF: embedded, as XMP and IPTC (both, the way Photo Mechanic writes them).
// - PNG and HEIC: embedded XMP.
// - Photoshop (PSD/PSB) and other formats: not written (reported) - their picture data can't be
//   fingerprinted, so a write could not be proved harmless.
// This file only plans and checks; the writing itself is FileOperations.writeMetadata (copy, write the
// copy, verify, swap). Pure Foundation, tested on Linux.

import Foundation

/// The editable fields: each is written to XMP, and to IPTC as well where the file has IPTC.
enum MetaField: String {
    case headline, caption, keywords, creator, credit, copyright, title, city, state, country, location,
         event, instructions, source, jobID
    // 0.18.13: the rest of Photo Mechanic's IPTC fields (the user's IPTC template).
    case category, suppCategories, captionWriter, dateCreated, copyrightURL, copyrightMarked, usageTerms,
         countryCode, personsShown, featuredOrg,
         contactAddress, contactCity, contactState, contactZip, contactCountry, contactPhone, contactEmail,
         lcSublocation, lcCity, lcState, lcCountry

    static let all: [MetaField] = [.headline, .caption, .captionWriter, .keywords, .category, .suppCategories,
                                   .title, .event, .personsShown, .featuredOrg, .instructions, .jobID, .dateCreated,
                                   .creator, .credit, .source, .copyright, .copyrightMarked, .copyrightURL, .usageTerms,
                                   .location, .city, .state, .country, .countryCode,
                                   .lcSublocation, .lcCity, .lcState, .lcCountry,
                                   .contactAddress, .contactCity, .contactState, .contactZip, .contactCountry, .contactPhone, .contactEmail]

    /// Fields Find and Replace works in (not the date or the True/False field: a replaced text there
    /// would not be a date or True/False any more).
    static var textFields: [MetaField] { return all.filter { $0 != .dateCreated && $0 != .copyrightMarked } }

    /// The editor's groups (Photo Mechanic's order), in two columns.
    static let groups: [(title: String, column: Int, fields: [MetaField])] = [
        ("Description", 0, [.caption, .captionWriter, .headline, .keywords, .category, .suppCategories, .title, .event,
                            .personsShown, .featuredOrg, .instructions, .jobID, .dateCreated]),
        ("Photographer and copyright", 1, [.creator, .credit, .source, .copyright, .copyrightMarked, .copyrightURL, .usageTerms]),
        ("Location (shown)", 1, [.location, .city, .state, .country, .countryCode]),
        ("Location created", 0, [.lcSublocation, .lcCity, .lcState, .lcCountry]),
        ("Photographer contact", 1, [.contactAddress, .contactCity, .contactState, .contactZip, .contactCountry, .contactPhone, .contactEmail]),
    ]

    var label: String {
        switch self {
        case .headline: return "Headline"
        case .caption: return "Description / Caption"
        case .keywords: return "Keywords"
        case .creator: return "Creator / Photographer"
        case .credit: return "Credit"
        case .copyright: return "Copyright"
        case .title: return "Title (Object Name)"
        case .city: return "City"
        case .state: return "State / Province"
        case .country: return "Country"
        case .location: return "Location (Sublocation)"
        case .event: return "Event"
        case .instructions: return "Special Instructions"
        case .source: return "Source"
        case .jobID: return "Job ID (Transmission Ref.)"
        case .category: return "Category"
        case .suppCategories: return "Supplemental Categories"
        case .captionWriter: return "Description Writers"
        case .dateCreated: return "Date Created"
        case .copyrightURL: return "Copyright URL"
        case .copyrightMarked: return "Copyright Marked"
        case .usageTerms: return "Rights Usage Terms"
        case .countryCode: return "ISO Country Code"
        case .personsShown: return "Persons Shown"
        case .featuredOrg: return "Featured Org. Name"
        case .contactAddress: return "Address"
        case .contactCity: return "City"
        case .contactState: return "State / Province"
        case .contactZip: return "Zip / Postal Code"
        case .contactCountry: return "Country"
        case .contactPhone: return "Phone"
        case .contactEmail: return "Email"
        case .lcSublocation: return "Sublocation"
        case .lcCity: return "City"
        case .lcState: return "State / Province"
        case .lcCountry: return "Country"
        }
    }

    /// The label with its group where the label alone is ambiguous (reports, Find & Replace).
    var fullLabel: String {
        switch self {
        case .contactAddress, .contactCity, .contactState, .contactZip, .contactCountry, .contactPhone, .contactEmail: return "Contact " + label
        case .lcSublocation, .lcCity, .lcState, .lcCountry: return "Location Created " + label
        default: return label
        }
    }

    /// ExifTool tag (group-qualified) in XMP.
    var xmp: String {
        switch self {
        case .headline: return "XMP-photoshop:Headline"
        case .caption: return "XMP-dc:Description"
        case .keywords: return "XMP-dc:Subject"
        case .creator: return "XMP-dc:Creator"
        case .credit: return "XMP-photoshop:Credit"
        case .copyright: return "XMP-dc:Rights"
        case .title: return "XMP-dc:Title"
        case .city: return "XMP-photoshop:City"
        case .state: return "XMP-photoshop:State"
        case .country: return "XMP-photoshop:Country"
        case .location: return "XMP-iptcCore:Location"
        case .event: return "XMP-iptcExt:Event"
        case .instructions: return "XMP-photoshop:Instructions"
        case .source: return "XMP-photoshop:Source"
        case .jobID: return "XMP-photoshop:TransmissionReference"
        case .category: return "XMP-photoshop:Category"
        case .suppCategories: return "XMP-photoshop:SupplementalCategories"
        case .captionWriter: return "XMP-photoshop:CaptionWriter"
        case .dateCreated: return "XMP-photoshop:DateCreated"
        case .copyrightURL: return "XMP-xmpRights:WebStatement"
        case .copyrightMarked: return "XMP-xmpRights:Marked"
        case .usageTerms: return "XMP-xmpRights:UsageTerms"
        case .countryCode: return "XMP-iptcCore:CountryCode"
        case .personsShown: return "XMP-iptcExt:PersonInImage"
        case .featuredOrg: return "XMP-iptcExt:OrganisationInImageName"
        case .contactAddress: return "XMP-iptcCore:CreatorAddress"
        case .contactCity: return "XMP-iptcCore:CreatorCity"
        case .contactState: return "XMP-iptcCore:CreatorRegion"
        case .contactZip: return "XMP-iptcCore:CreatorPostalCode"
        case .contactCountry: return "XMP-iptcCore:CreatorCountry"
        case .contactPhone: return "XMP-iptcCore:CreatorWorkTelephone"
        case .contactEmail: return "XMP-iptcCore:CreatorWorkEmail"
        case .lcSublocation: return "XMP-iptcExt:LocationCreatedSublocation"
        case .lcCity: return "XMP-iptcExt:LocationCreatedCity"
        case .lcState: return "XMP-iptcExt:LocationCreatedProvinceState"
        case .lcCountry: return "XMP-iptcExt:LocationCreatedCountryName"
        }
    }

    /// ExifTool tag in IPTC (nil: no IPTC field).
    var iptc: String? {
        switch self {
        case .headline: return "IPTC:Headline"
        case .caption: return "IPTC:Caption-Abstract"
        case .keywords: return "IPTC:Keywords"
        case .creator: return "IPTC:By-line"
        case .credit: return "IPTC:Credit"
        case .copyright: return "IPTC:CopyrightNotice"
        case .title: return "IPTC:ObjectName"
        case .city: return "IPTC:City"
        case .state: return "IPTC:Province-State"
        case .country: return "IPTC:Country-PrimaryLocationName"
        case .location: return "IPTC:Sub-location"
        case .instructions: return "IPTC:SpecialInstructions"
        case .source: return "IPTC:Source"
        case .jobID: return "IPTC:OriginalTransmissionReference"
        case .category: return "IPTC:Category"
        case .suppCategories: return "IPTC:SupplementalCategories"
        case .captionWriter: return "IPTC:Writer-Editor"
        case .dateCreated: return "IPTC:DateCreated"
        case .countryCode: return "IPTC:Country-PrimaryLocationCode"
        default: return nil
        }
    }

    /// Lists (several values).
    var isList: Bool { return [.keywords, .creator, .suppCategories, .personsShown, .featuredOrg].contains(self) }

    /// 0.18.13: a value as Find keeps it (and as ExifTool reads it): dates "YYYY:MM:DD[ HH:MM:SS[+hh:mm]]",
    /// Copyright Marked "True" / "False"; everything else trimmed.
    func canonical(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .dateCreated:
            var u = Array(t.unicodeScalars)
            for k in 0..<min(10, u.count) where u[k] == "-" { u[k] = ":" }
            if u.count > 10 && u[10] == "T" { u[10] = " " }
            var o = ""
            o.unicodeScalars.append(contentsOf: u)
            return o
        case .copyrightMarked:
            switch t.lowercased() {
            case "true", "yes", "1", "copyrighted": return "True"
            case "false", "no", "0", "public domain": return "False"
            default: return t
            }
        default:
            return t
        }
    }

    /// nil = the value can be written; else what is wrong with it (shown in the editor).
    func problem(_ v: String) -> String? {
        let c = canonical(v)
        if c.isEmpty { return nil }
        switch self {
        case .dateCreated:
            let ok = c.range(of: "^[0-9]{4}:[0-9]{2}:[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?([+-][0-9]{2}:[0-9]{2}|Z)?)?$", options: .regularExpression) != nil
            return ok ? nil : "Date Created: type it as YYYY-MM-DD (e.g. 2026-11-26), optionally with a time"
        case .copyrightMarked:
            return c == "True" || c == "False" ? nil : "Copyright Marked: True (copyrighted), False (public domain) or empty"
        default:
            return nil
        }
    }

    /// The most bytes the IPTC field holds (ExifTool cuts longer values to this; so does Find).
    var iptcMaxBytes: Int {
        switch self {
        case .caption: return 2000
        case .headline, .instructions: return 256
        case .copyright: return 128
        case .title, .keywords, .country: return 64
        case .category, .countryCode: return 3
        case .dateCreated: return 8
        default: return 32
        }
    }
}

/// 0.18.14: how a changed file is put on the disk before Find goes on.
enum FlushMode: Int {
    /// F_FULLFSYNC: on the disk itself, past the drive's own cache (safe against a power cut a moment later).
    case full = 0
    /// fsync: handed to the drive (its cache may still hold it for a moment).
    case normal = 1
    /// None: left to macOS to write within seconds, as ExifTool and most apps do (safe if Find stops;
    /// a power cut or macOS crash in those seconds can leave that file's metadata half-written).
    case none = 2
}

/// What to change. Fields not mentioned are left exactly as they are.
struct MetaChange: Equatable {
    /// 1-5 stars; 0 removes the rating; nil leaves it.
    var rating: Int? = nil
    /// Photo Mechanic colour class 1-8; 0 removes it; nil leaves it (0.14).
    var colorClass: Int? = nil
    /// New values (an empty string clears the field). Lists: values separated by commas or semicolons.
    var set: [MetaField: String] = [:]
    /// Keywords added to those already there (not replacing them).
    var addKeywords: [String] = []

    var isEmpty: Bool { return rating == nil && colorClass == nil && set.isEmpty && addKeywords.isEmpty }

    /// 0.18.10: this change followed by `later` (for changes queued in the background: one write).
    func then(_ later: MetaChange) -> MetaChange {
        var m = self
        if let r = later.rating { m.rating = r }
        if let c = later.colorClass { m.colorClass = c }
        for (k, v) in later.set { m.set[k] = v }
        if later.set[.keywords] != nil { m.addKeywords = [] }
        for k in later.addKeywords where !m.addKeywords.contains(k) { m.addKeywords.append(k) }
        return m
    }

    /// Several (picture, change) lists, in the order they were made, as one list (one change per picture).
    static func merged(_ lists: [[(image: String, change: MetaChange)]]) -> [(image: String, change: MetaChange)] {
        var order: [String] = []
        var byImage: [String: MetaChange] = [:]
        for l in lists {
            for it in l {
                if let c = byImage[it.image] { byImage[it.image] = c.then(it.change) } else { order.append(it.image); byImage[it.image] = it.change }
            }
        }
        return order.map { (image: $0, change: byImage[$0]!) }
    }

    static func == (a: MetaChange, b: MetaChange) -> Bool {
        return a.rating == b.rating && a.colorClass == b.colorClass && a.set == b.set && a.addKeywords == b.addKeywords
    }

    var describe: String {
        var parts: [String] = []
        if let r = rating { parts.append(r == 0 ? "rating removed" : "rating \(r)") }
        if let c = colorClass { parts.append(c == 0 ? "colour class removed" : "colour class \(c)") }
        for f in MetaField.all where set[f] != nil { parts.append(set[f]!.isEmpty ? "\(f.label) cleared" : "\(f.label) set") }
        if !addKeywords.isEmpty { parts.append("keywords added: \(addKeywords.joined(separator: ", "))") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }
}

/// Where one picture's metadata is written.
struct MetaTarget: Equatable {
    enum Kind: Equatable {
        case embedded(iptc: Bool)        // into the picture file itself
        case embeddedRaw                 // into a RAW file itself (IPTC + XMP fields; 0.18)
        case sidecarExisting             // update the existing .xmp
        case sidecarNew                  // create a new .xmp (none exists)
        case unsupported(String)         // reason
    }
    let image: String
    /// The file actually written (the picture or its sidecar).
    let file: String
    let kind: Kind

    var isSidecar: Bool {
        if case .sidecarExisting = kind { return true }
        if case .sidecarNew = kind { return true }
        return false
    }

    static func == (a: MetaTarget, b: MetaTarget) -> Bool { return a.image == b.image && a.file == b.file && a.kind == b.kind }
}

enum MetaPlan {
    static let embeddedXMPAndIPTC: Set<String> = ["jpg", "jpeg", "jpe", "tif", "tiff"]

    // MARK: Which set is current (0.18)

    enum Source: Equatable { case embedded, sidecar }

    /// The picture's own metadata or its sidecar's: whichever FILE was changed last. A tie (written
    /// together) counts as the sidecar - after Find writes both they hold the same values anyway.
    static func current(imageModified: Double, sidecarModified: Double?) -> Source {
        guard let s = sidecarModified else { return .embedded }
        return s >= imageModified ? .sidecar : .embedded
    }

    /// The file whose metadata is current for `image` (the picture or its sidecar).
    static func currentFile(for image: String, sidecarFor: (String) -> String? = { Sidecars.find(for: $0) }) -> (file: String, source: Source) {
        guard let sc = sidecarFor(image) else { return (image, .embedded) }
        var e: Int32 = 0
        let im = Sys.statInfo(image, &e)?.modified ?? 0
        let sm = Sys.statInfo(sc, &e)?.modified
        return current(imageModified: im, sidecarModified: sm) == .sidecar ? (sc, .sidecar) : (image, .embedded)
    }

    /// The complete set a RAW and its sidecar are both written with: everything the current set holds,
    /// with the change on top (so neither keeps a value the other lacks).
    static func complete(_ c: MetaChange, current rec: [String: Any]) -> MetaChange {
        var full = MetaChange()
        full.rating = c.rating ?? currentRating(in: rec)
        full.colorClass = c.colorClass ?? currentColorClass(in: rec)
        for f in MetaField.all { full.set[f] = c.set[f] ?? current(f, in: rec) }
        if !c.addKeywords.isEmpty {
            var kw = listValues(full.set[.keywords] ?? "")
            for k in c.addKeywords where !kw.contains(k) { kw.append(k) }
            full.set[.keywords] = kw.joined(separator: ", ")
        }
        return full
    }
    static let embeddedXMPOnly: Set<String> = ["png", "heic", "heif"]

    /// Where each picture's data goes. `sidecarFor` finds an existing sidecar (Sidecars.find; lstat only).
    /// Several pictures sharing one sidecar (RAW+... ) are written once.
    /// 0.18.6 (Settings > Photography): the three places metadata is written, all on by default:
    /// 1 the .xmp sidecar of RAW pictures (made when missing; an existing one is ALWAYS kept up to date,
    /// or Photo Mechanic would show its old values), 2 the XMP inside RAW files (JPEG/TIFF always have
    /// their XMP inside - it is their only XMP), 3 the IPTC inside every picture that can hold it.
    /// Stars and colour classes are XMP only, so a RAW always gets the sidecar or embedded XMP.
    static var writeSidecar = true
    /// 0.18.8 (Settings): change only the metadata part of RAW/TIFF/JPEG files when possible (InPlaceMeta).
    static var inPlace = false
    /// 0.18.10: how an in-place change is checked: ExifTool reads every value back (true, safest), or
    /// Find reads back the bytes it wrote and checks the file's structure (false, fastest).
    static var inPlaceExifToolCheck = true
    static var writeEmbeddedXMP = true
    static var writeEmbeddedIPTC = true
    /// 0.18.11 Find's own fast path (Settings > Photography > "Speed: Find's own reader and writer"):
    /// read the old values with Find's own reader (ExifTool only for files it can't read itself),
    static var nativeRead = true
    /// write .xmp sidecars itself (a new version beside the old, read back, then swapped in),
    static var nativeSidecar = true
    /// and also have ExifTool read back what Find wrote itself (off = Find's own reading-back only).
    static var nativeExifToolDoubleCheck = false
    /// How each changed file is put on the disk (0.18.14: three choices).
    static var flush: FlushMode = .full
    static var fullFlush: Bool { return flush == .full }
    /// Inside the file at all (RAW included).
    static var writeInsideRaw: Bool {
        get { return writeEmbeddedXMP || writeEmbeddedIPTC }
        set { writeEmbeddedXMP = newValue; writeEmbeddedIPTC = newValue }
    }

    /// What a target gets: XMP fields, IPTC fields (IPTC only inside files of types that hold it).
    static func places(for t: MetaTarget) -> (xmp: Bool, iptc: Bool) {
        switch t.kind {
        case .sidecarNew, .sidecarExisting: return (true, false)
        case .embedded(let i): return (true, i && writeEmbeddedIPTC)
        case .embeddedRaw: return (writeEmbeddedXMP || Sidecars.isDNG(t.image), writeEmbeddedIPTC)   // alpha.6: DNG XMP always inside
        case .unsupported: return (false, false)
        }
    }

    /// Does writing `c` to `t` change anything there? (e.g. a rating has no IPTC field)
    static func hasEffect(_ c: MetaChange, for t: MetaTarget) -> Bool {
        return writeArgs(c, for: t).contains { $0.hasPrefix("-") && $0.contains("=") && !$0.hasPrefix("-IPTC:CodedCharacterSet") }
    }
    /// 0.18.5 (Settings > Photography): how files that are rewritten (JPEG, TIFF, RAW inside) are checked.
    static var writeMode: MetaWriteMode = .fingerprint

    static func targets(_ images: [String], sidecarFor: (String) -> String? = { Sidecars.find(for: $0) }) -> [MetaTarget] {
        var out: [MetaTarget] = []
        var sidecarsSeen = Set<String>()
        for img in images {
            let name = Paths.lastComponent(img)
            let ext = Paths.fileExtension(name).lowercased()
            if PhotoFormats.isSidecar(name) {
                out.append(MetaTarget(image: img, file: img, kind: .unsupported("an XMP sidecar itself - rate its picture instead")))
            } else if Sidecars.isDNG(name) {
                // 1.0.0-alpha.6: a DNG is written inside only (XMP always - stars and colour classes are
                // XMP - and IPTC as set), never a sidecar, whatever the sidecar settings say.
                out.append(MetaTarget(image: img, file: img, kind: .embeddedRaw))
            } else if PhotoFormats.raw.contains(ext) {
                // 0.18.6: the three places as set - inside the RAW (embedded XMP and/or IPTC), and its
                // sidecar (made when there is none; one shared by several pictures is written once).
                // With nothing inside and no sidecar wanted, the sidecar anyway: a RAW must be written somewhere.
                if writeInsideRaw { out.append(MetaTarget(image: img, file: img, kind: .embeddedRaw)) }
                if let existing = sidecarFor(img) {
                    if !sidecarsSeen.contains(existing) {
                        sidecarsSeen.insert(existing)
                        out.append(MetaTarget(image: img, file: existing, kind: .sidecarExisting))
                    }
                } else if writeSidecar || !writeEmbeddedXMP {
                    out.append(newSidecar(for: img))
                }
            } else if embeddedXMPAndIPTC.contains(ext) {
                out.append(MetaTarget(image: img, file: img, kind: .embedded(iptc: true)))
            } else if embeddedXMPOnly.contains(ext) {
                out.append(MetaTarget(image: img, file: img, kind: .embedded(iptc: false)))
            } else if PhotoFormats.photoshop.contains(ext) {
                out.append(MetaTarget(image: img, file: img, kind: .unsupported("Photoshop files are not written yet: Find can't verify their picture data after a change")))
            } else {
                out.append(MetaTarget(image: img, file: img, kind: .unsupported("\(ext.uppercased()) files are not written")))
            }
        }
        return out
    }

    /// A new sidecar for a RAW whose own file couldn't be written (0.18 fallback).
    static func newSidecar(for img: String) -> MetaTarget {
        let name = Paths.lastComponent(img)
        return MetaTarget(image: img, file: Paths.join(Paths.parent(img), Paths.baseName(name) + ".xmp"), kind: .sidecarNew)
    }

    /// Split a typed list ("a, b; c") into values.
    static func listValues(_ s: String) -> [String] {
        return s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// ExifTool arguments for a change (the file names are added by the caller).
    static func writeArgs(_ c: MetaChange, for t: MetaTarget) -> [String] {
        // 0.18.6: XMP and IPTC as the Settings say (a RAW's IPTC where its type has it - ExifTool skips it where not).
        let (xmp, iptc) = places(for: t)
        // A new sidecar is created from nothing (ExifTool makes a new .xmp); otherwise the copy is
        // changed in place, keeping its Finder tags, labels and creation date.
        var a: [String] = t.kind == .sidecarNew ? [] : ["-overwrite_original_in_place"]
        a += ["-charset", "iptc=UTF8"]
        if iptc { a.append("-IPTC:CodedCharacterSet=UTF8") }
        if xmp, let r = c.rating {
            a.append(r <= 0 ? "-XMP-xmp:Rating=" : "-XMP-xmp:Rating=\(min(5, r))")
        }
        if xmp, let cc = c.colorClass {
            // Photo Mechanic's own field (its XMP namespace), as Photo Mechanic writes it.
            a.append(cc <= 0 ? "-XMP-photomech:ColorClass=" : "-XMP-photomech:ColorClass=\(min(8, cc))")
            // PhotoLab: ColorClass is the master; xmp:Label follows it (Bridge, Lightroom).
            a.append("-XMP-xmp:Label=" + (MetaPlan.labelName(cc) ?? ""))
        }
        for f in MetaField.all {
            guard let v = c.set[f] else { continue }
            var tags: [String] = xmp ? [f.xmp] : []
            if iptc, let i = f.iptc { tags.append(i) }
            for tag in tags {
                if f.isList {
                    a.append("-\(tag)=")                           // clear, then each value
                    for item in listValues(v) { a.append("-\(tag)=\(item)") }
                } else {
                    var w = f.canonical(v)
                    if f == .dateCreated && tag.hasPrefix("IPTC:") { w = String(w.prefix(10)) }   // IPTC: the date only
                    a.append("-\(tag)=\(w)")
                }
            }
        }
        if !c.addKeywords.isEmpty {
            var tags: [String] = xmp ? [MetaField.keywords.xmp] : []
            if iptc, let i = MetaField.keywords.iptc { tags.append(i) }
            for tag in tags {
                for k in c.addKeywords { a.append("-\(tag)-=\(k)"); a.append("-\(tag)+=\(k)") }   // no duplicates
            }
        }
        return a
    }

    /// Tags read back to check a write, and to remember old values for Undo.
    static func readTags(for t: MetaTarget) -> [String] {
        var iptc = false
        if case .embedded(let i) = t.kind { iptc = i }
        var tags = ["-XMP-xmp:Rating", "-XMP-photomech:ColorClass"]
        for f in MetaField.all {
            tags.append("-" + f.xmp)
            if iptc, let i = f.iptc { tags.append("-" + i) }
        }
        return tags
    }

    static func values(_ any: Any?) -> [String] {
        if let a = any as? [Any] { return a.map { "\($0)" } }
        if let s = any as? String { return [s] }
        if let n = any as? NSNumber { return [n.stringValue] }
        if let x = any { return ["\(x)"] }
        return []
    }

    /// One field's current value from an ExifTool JSON record (-G1), as typed in the editor.
    static func current(_ f: MetaField, in rec: [String: Any]) -> String {
        let v = values(rec[f.xmp]).filter { !$0.isEmpty }
        let use = v.isEmpty && f.iptc != nil ? values(rec[f.iptc!]) : v
        return use.map { f.canonical($0) }.joined(separator: f.isList ? ", " : " ")
    }

    /// 0.18.13: `s` cut to at most `n` UTF-8 bytes, at a character boundary (IPTC field sizes).
    static func iptcCut(_ s: String, _ n: Int) -> String {
        if s.utf8.count <= n { return s }
        var o = ""
        var bytes = 0
        for c in s.unicodeScalars {
            let k = String(c).utf8.count
            if bytes + k > n { break }
            o.unicodeScalars.append(c)
            bytes += k
        }
        return o
    }

    /// An IPTC value read back: as written, or cut to the field's size (ExifTool cuts by bytes, maybe
    /// inside a character - so a few bytes short is accepted when the rest is the same).
    static func iptcMatches(_ got: String, _ want: String, _ n: Int) -> Bool {
        if got == want { return true }
        if want.utf8.count <= n { return false }
        let g = Array(got.utf8), w = Array(want.utf8)
        return g.count <= n && g.count >= n - 3 && Array(w.prefix(g.count)) == g
    }

    static func currentRating(in rec: [String: Any]) -> Int {
        return Int(values(rec["XMP-xmp:Rating"]).first ?? "") ?? 0
    }

    /// PhotoLab: the xmp:Label written with colour class 1-8 (the colours of Photo Mechanic's default
    /// classes, as Settings shows them); nil for 0 (Label removed).
    static let labelNames = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Cyan", "Gray"]
    static func labelName(_ cc: Int) -> String? { return cc >= 1 && cc <= 8 ? labelNames[cc - 1] : nil }

    /// Colour class 0-8 (ExifTool may print "1 (Winner)": the number is what counts).
    static func currentColorClass(in rec: [String: Any]) -> Int {
        let s = values(rec["XMP-photomech:ColorClass"]).first ?? ""
        return Int(String(s.prefix(while: { $0 >= "0" && $0 <= "9" }))) ?? 0
    }

    /// Does the record read back after writing match the change? nil = yes, else the first difference.
    static func verify(_ c: MetaChange, readBack rec: [String: Any], target t: MetaTarget) -> String? {
        let xmp = places(for: t).xmp
        if xmp, let r = c.rating {
            let got = currentRating(in: rec)
            if got != max(0, min(5, r)) { return "rating is \(got), expected \(r)" }
        }
        if xmp, let cc = c.colorClass {
            let got = currentColorClass(in: rec)
            if got != max(0, min(8, cc)) { return "colour class is \(got), expected \(cc)" }
        }
        // IPTC checked inside JPEG/TIFF; inside a RAW only XMP (not every RAW type holds IPTC).
        var iptc = false
        if case .embedded = t.kind { iptc = places(for: t).iptc }
        for f in MetaField.all {
            guard let want = c.set[f] else { continue }
            var tags: [String] = xmp ? [f.xmp] : []
            if iptc, let i = f.iptc { tags.append(i) }
            for tag in tags {
                let isIPTC = tag.hasPrefix("IPTC:")
                let got = values(rec[tag]).map { f.canonical($0) }
                if f.isList {
                    let w = listValues(want).map { f.canonical($0) }
                    let ok = isIPTC ? (got.count == w.count && Array(zip(got, w)).allSatisfyCompat { iptcMatches($0.0, $0.1, f.iptcMaxBytes) }) : got == w
                    if !ok { return "\(tag) is [\(got.joined(separator: ", "))]" }
                } else {
                    var w = f.canonical(want)
                    if isIPTC && f == .dateCreated { w = String(w.prefix(10)) }
                    let g = got.first ?? ""
                    let ok = isIPTC ? iptcMatches(g, w, f.iptcMaxBytes) : g == w
                    if !ok { return "\(tag) is \"\(g)\"" }
                }
            }
        }
        if xmp && !c.addKeywords.isEmpty {
            let got = Set(values(rec[MetaField.keywords.xmp]))
            for k in c.addKeywords where !got.contains(k) { return "keyword \"\(k)\" missing" }
        }
        return nil
    }

    /// The change that puts back what the file had before (for Undo).
    static func undoChange(for c: MetaChange, before rec: [String: Any]) -> MetaChange {
        var u = MetaChange()
        if c.rating != nil { u.rating = currentRating(in: rec) }
        if c.colorClass != nil { u.colorClass = currentColorClass(in: rec) }
        for f in MetaField.all where c.set[f] != nil { u.set[f] = current(f, in: rec) }
        if !c.addKeywords.isEmpty {
            u.set[.keywords] = current(.keywords, in: rec)
        }
        return u
    }
}

/// ExifTool, as FileOperations uses it for metadata (implemented on the Mac in ImageMeta.swift).
/// 0.18.5: how a file that is rewritten is made and checked (Settings > Photography). In every mode the
/// original stays untouched until the new version has been read back with every value as asked, and
/// the swap keeps the original under a hidden name until the new one is in place.
enum MetaWriteMode: Int {
    /// Safest, slowest: a separate working copy is made first and changed; picture data fingerprinted
    /// before and after (about 4 reads + 2 writes of each file).
    case workingCopy = 0
    /// Safe (default): ExifTool writes the new version straight beside the original; picture data
    /// fingerprinted before and after (about 3 reads + 1 write).
    case fingerprint = 1
    /// Fingerprint on this Mac's disks; the fast way on network shares.
    case fingerprintLocal = 2
    /// Fastest: new version beside the original, values checked, no picture fingerprint (1 read + 1 write).
    case fast = 3
}

protocol MetadataTool: class {
    /// 0.18.5: write a NEW file beside each given file, named `prefix` + its name, with these arguments.
    /// The given files are only read, never changed. nil = ran, or an error text.
    func writeBeside(_ args: [String], files: [String], prefix: String) -> String?
    /// MD5 of the picture data only (not the metadata), per file; missing when not supported.
    func imageHashes(_ files: [String]) -> [String: String]
    /// Write: run with these arguments on these files (absolute paths). nil = ran, or an error text.
    func write(_ args: [String], files: [String]) -> String?
    /// Read tags (-G1 JSON), keyed by file path.
    func read(_ tags: [String], files: [String]) -> [String: [String: Any]]
}
