// ImageMeta.swift
// Read-only photo metadata and thumbnails using Apple's ImageIO and Quick Look (built into macOS).
// ImageIO reads only the parts of a file it needs (header, embedded preview), never develops RAW
// data and never writes. ExifTool, if installed, is run read-only for "All metadata".

import Foundation
import ImageIO
import QuickLook
import CoreServices

enum ImageMeta {
    /// Read the metadata sections for one image. Blocking: call off the main thread.
    static func read(path: String) -> [MetaSection] {
        let opts = [kCGImageSourceShouldCache as String: false] as CFDictionary
        guard let src = source(path) else {
            return [MetaSection("Image", [("Metadata", "macOS could not read this file's image data")])]
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [String: Any] else {
            var s = MetaSection("Image")
            s.add("Metadata", "macOS can't read this format's details on this system")
            if let t = CGImageSourceGetType(src) { s.add("Format seen", t as String) }
            return [s]
        }
        let exif = props["{Exif}"] as? [String: Any] ?? [:]
        let aux = props["{ExifAux}"] as? [String: Any] ?? [:]
        let tiff = props["{TIFF}"] as? [String: Any] ?? [:]
        let gps = props["{GPS}"] as? [String: Any] ?? [:]
        let iptc = props["{IPTC}"] as? [String: Any] ?? [:]

        var image = MetaSection("Image")
        let w = int(props["PixelWidth"]), h = int(props["PixelHeight"])
        if let w = w, let h = h {
            image.add("Dimensions", "\(w) x \(h) pixels")
            image.add("Megapixels", MetaFormat.megapixels(w, h))
            image.add("Aspect ratio", MetaFormat.aspect(w, h))
        }
        if let dx = double(props["DPIWidth"]) {
            let dy = double(props["DPIHeight"]) ?? dx
            image.add("Resolution", dx == dy ? "\(clean(dx)) ppi" : "\(clean(dx)) x \(clean(dy)) ppi")
        }
        image.add("Color profile", props["ProfileName"] as? String)
        image.add("Color model", props["ColorModel"] as? String)
        if let d = int(props["Depth"]) { image.add("Bit depth", "\(d) bits per channel") }
        if let o = int(props["Orientation"]), o != 1 { image.add("Orientation", orientation(o)) }
        let count = CGImageSourceGetCount(src)
        if count > 1 { image.add("Images in file", "\(count)") }

        var camera = MetaSection("Camera")
        camera.add("Make", tiff["Make"] as? String)
        camera.add("Model", tiff["Model"] as? String)
        camera.add("Lens", (exif["LensModel"] as? String) ?? (aux["LensModel"] as? String))
        if let f = double(exif["FocalLength"]) { camera.add("Focal length", MetaFormat.focal(f, equiv35: double(exif["FocalLenIn35mmFilm"]))) }
        if let a = double(exif["FNumber"]) { camera.add("Aperture", MetaFormat.aperture(a)) }
        if let t = double(exif["ExposureTime"]) { camera.add("Shutter speed", MetaFormat.shutter(t)) }
        if let isoList = exif["ISOSpeedRatings"] as? [Any], let iso = int(isoList.first) { camera.add("ISO", "\(iso)") }
        if let b = double(exif["ExposureBiasValue"]) { camera.add("Exposure comp.", MetaFormat.exposureBias(b)) }
        if let p = int(exif["ExposureProgram"]) { camera.add("Program", exposureProgram(p)) }
        if let m = int(exif["MeteringMode"]) { camera.add("Metering", metering(m)) }
        if let fl = int(exif["Flash"]) { camera.add("Flash", (fl & 1) == 1 ? "Fired" : "Did not fire") }
        camera.add("Taken", exif["DateTimeOriginal"] as? String)
        camera.add("Serial number", (exif["BodySerialNumber"] as? String) ?? (aux["SerialNumber"] as? String))
        camera.add("Software", tiff["Software"] as? String)

        var location = MetaSection("Location")
        if let la = double(gps["Latitude"]), let lo = double(gps["Longitude"]) {
            let laR = gps["LatitudeRef"] as? String ?? "N", loR = gps["LongitudeRef"] as? String ?? "E"
            location.add("GPS", MetaFormat.gps(lat: la, latRef: laR, lon: lo, lonRef: loR))
            location.add("Decimal", MetaFormat.gpsDecimal(lat: la, latRef: laR, lon: lo, lonRef: loR))
            if let alt = double(gps["Altitude"]) { location.add("Altitude", "\(clean(alt)) m") }
        }
        location.add("City", iptc["City"] as? String)
        location.add("Country", iptc["Country/PrimaryLocationName"] as? String)

        var desc = MetaSection("Description (embedded IPTC / XMP)")
        var rating: Int? = int(iptc["StarRating"])
        var label: String? = nil
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            if let r = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) { rating = Int(r as String) ?? rating }
            if let l = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Label" as CFString) { label = l as String }
        }
        if let r = rating { desc.add("Rating", MetaFormat.stars(r)) }
        desc.add("Label", label)
        desc.add("Title", iptc["ObjectName"] as? String)
        desc.add("Description", iptc["Caption/Abstract"] as? String)
        if let k = iptc["Keywords"] as? [String], !k.isEmpty { desc.add("Keywords", k.joined(separator: ", ")) }
        let byline = (iptc["Byline"] as? [String])?.joined(separator: ", ") ?? (tiff["Artist"] as? String)
        desc.add("Creator", byline)
        desc.add("Copyright", (iptc["CopyrightNotice"] as? String) ?? (tiff["Copyright"] as? String))

        return [image, camera, location, desc].filter { !$0.rows.isEmpty }
    }

    /// Preview image no larger than `maxPixels` on its long side.
    /// RAW: the camera's embedded JPEG (fast, never develops the RAW). Other images: ImageIO, decoding
    /// at reduced size (it never uses the tiny EXIF thumbnail). Other files: Quick Look's thumbnail.
    /// Thumbnails never wait for a slow full read (Photoshop): saved preview or Photoshop's own thumbnail.
    /// PhotoLab: kept on disk between launches (Caches/PhotoLab/Thumbs) when size and date are given.
    static func thumbnail(path: String, maxPixels: Int, size: Int64? = nil, modified: Double? = nil) -> CGImage? {
        if let sz = size, let m = modified, let store = App.thumbs {
            let key = path + "|\(maxPixels)"
            if let d = store.get(path: key, size: sz, modified: m), let img = decodeStored(d) { return img }
            guard let made = preview(path: path, maxPixels: maxPixels, allowSlow: false, size: sz, modified: m)?.image else { return nil }
            if let d = jpegData(made, quality: 0.8) { store.put(d, path: key, size: sz, modified: m) }
            return made
        }
        return preview(path: path, maxPixels: maxPixels, allowSlow: false)?.image
    }

    private static func decodeStored(_ d: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// ImageIO's type hint from the extension (sources made from a reader have no file name).
    static func typeHint(_ path: String) -> CFString? {
        let e = Paths.fileExtension(path).lowercased()
        if e.isEmpty { return nil }
        return UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, e as CFString, nil)?.takeRetainedValue()
    }

    /// An ImageIO source reading through the file's shared reader (PhotoLab: every part of a file
    /// crosses the network once, whoever asks - thumbnail, facts, inspector, preview).
    /// Not for RAWs: macOS's RAW support reads the WHOLE file through a reader (alpha.3 measured 34 MB per
    /// file); given the file itself it reads only what it needs. RAW previews come from CameraPreviews.
    static func source(_ path: String, size: Int64? = nil, modified: Double? = nil) -> CGImageSource? {
        if !PhotoFormats.isRaw(path), let r = FileReads.reader(path, size: size, modified: modified),
            let s = r.imageSource(hint: typeHint(path)) { return s }
        let opts = [kCGImageSourceShouldCache as String: false] as CFDictionary
        IOLog.smallRead(path, bytes: -1)   // macOS reads the file itself (I/O logs; size not known)
        return CGImageSourceCreateWithURL(NSURL(fileURLWithPath: path) as CFURL, opts)
    }

    /// Same as `thumbnail`, plus a word on where the picture came from ("embedded camera preview").
    /// `allowSlow` false: for files that are slow to decode (PSD/PSB, huge TIFF), answer at once from the
    /// saved preview or Photoshop's own small thumbnail instead of reading the whole file.
    /// PhotoLab: the camera's/Photoshop's embedded JPEGs come first - the smallest that is big enough,
    /// read through the shared reader (CameraPreviews); ImageIO also reads through it.
    static func preview(path: String, maxPixels: Int, allowSlow: Bool = true, size: Int64? = nil, modified: Double? = nil) -> (image: CGImage, source: String)? {
        let url = NSURL(fileURLWithPath: path)
        let ext = Paths.fileExtension(path).lowercased()
        var serr: Int32 = 0
        let info: (size: Int64, modified: Double)? = size.flatMap { sz in modified.map { (sz, $0) } }
            ?? Sys.lstatInfo(path, &serr).map { ($0.size, $0.modified) }
        // Only pictures and PDFs are read by PhotoLab itself (others go to Quick Look, which opens them anyway).
        let reader = PhotoFormats.isImage(path) || ext == "pdf" ? FileReads.reader(path, size: info?.size, modified: info?.modified) : nil
        let layered = PhotoFormats.photoshop.contains(ext) || PhotoFormats.tiff.contains(ext)
        let thumbOpts: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxPixels,
            kCGImageSourceShouldCacheImmediately as String: true,
        ]
        if let info = info, PreviewCache.worthCaching(name: path, size: info.size), let cache = App.previews {
            if let d = cache.get(path: path, size: info.size, modified: info.modified),
                let img = decode(NSData(data: d) as CFData, maxPixels: maxPixels, tiffOrientation: 1) {
                return (img, "saved preview")
            }
            if !allowSlow {
                // Photoshop's own thumbnail, or a preview inside the TIFF: a few small reads.
                if let r = reader, let img = CameraPreviews.thumbnail(r, ext: ext, maxPixels: maxPixels, minSide: min(maxPixels, 160)).image {
                    return (img, "quick thumbnail")
                }
                return nil
            }
            // Full read once, at screen size; saved so the next look is instant.
            let srcOpts = [kCGImageSourceShouldCache as String: false] as CFDictionary
            if let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) {
                var opts = thumbOpts
                opts[kCGImageSourceThumbnailMaxPixelSize as String] = PreviewCache.pixels
                if let full = CGImageSourceCreateThumbnailAtIndex(src, 0, NSDictionary(dictionary: opts) as CFDictionary) {
                    if let jpeg = jpegData(full, quality: 0.85) { cache.put(jpeg, path: path, size: info.size, modified: info.modified) }
                    IOLog.smallRead(path, bytes: info.size)   // a full read of the picture (I/O logs)
                    return (full, "image (preview saved for next time)")
                }
            }
        }
        // Embedded JPEGs: RAW (camera preview), camera JPEG (EXIF/MPF, thumbnails only), PSD/TIFF.
        let isJPEG = PhotoFormats.jpeg.contains(ext)
        if let r = reader, PhotoFormats.isRaw(path) || layered || (isJPEG && maxPixels <= 640) {
            let e = CameraPreviews.thumbnail(r, ext: ext, maxPixels: maxPixels)
            if let img = e.image {
                if PhotoFormats.isRaw(path) { return (img, "embedded camera preview") }
                // Not a RAW: only when it is big enough (else the picture itself is decoded).
                if max(img.width, img.height) >= maxPixels / 2 {
                    return (img, isJPEG ? "camera preview inside the JPEG" : "embedded preview")
                }
            }
        }
        if PhotoFormats.isImage(path), let src = source(path, size: info?.size, modified: info?.modified) {
            if PhotoFormats.isRaw(path) {
                // A RAW without a usable embedded JPEG: ImageIO's own thumbnail before developing.
                var o = thumbOpts
                o.removeValue(forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                o[kCGImageSourceCreateThumbnailFromImageIfAbsent as String] = true
                if let t = CGImageSourceCreateThumbnailAtIndex(src, 0, NSDictionary(dictionary: o) as CFDictionary),
                    max(t.width, t.height) >= maxPixels / 2 {
                    return (t, "embedded camera preview")
                }
            }
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, NSDictionary(dictionary: thumbOpts) as CFDictionary) {
                return (img, PhotoFormats.isRaw(path) ? "developed by macOS" : "image")
            }
        }
        // PDF: page 1 drawn by CoreGraphics, reading only what that page needs.
        if ext == "pdf", let r = reader, let img = pdfPage(r, maxPixels: maxPixels) { return (img, "PDF page 1") }
        let qsize = CGSize(width: maxPixels, height: maxPixels)
        if let u = QLThumbnailImageCreate(kCFAllocatorDefault, url as CFURL, qsize, nil) {
            IOLog.smallRead(path, bytes: -1)
            return (u.takeRetainedValue(), "Quick Look thumbnail")
        }
        return nil
    }

    /// PhotoLab: the size the biggest version of this picture will have, upright - from the header
    /// (RAW: the largest embedded preview, which is what the preview shows; others: the image).
    static func finalSize(_ path: String, size: Int64? = nil, modified: Double? = nil) -> CGSize? {
        guard let r = FileReads.reader(path, size: size, modified: modified) else { return nil }
        if PhotoFormats.isRaw(path), let s = CameraPreviews.largestSize(r) { return CGSize(width: s.width, height: s.height) }
        if PhotoFormats.isRaw(path) { return nil }
        guard let src = r.imageSource(hint: typeHint(path)),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [String: Any],
            let w = (props["PixelWidth"] as? NSNumber)?.intValue, let h = (props["PixelHeight"] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        let o = (props["Orientation"] as? NSNumber)?.intValue ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func pdfPage(_ r: BlockReader, maxPixels: Int) -> CGImage? {
        guard let provider = r.dataProvider(), let doc = CGPDFDocument(provider), !doc.isEncrypted || doc.isUnlocked,
            let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let rot = (page.rotationAngle % 180 + 180) % 180 == 90
        let pw = rot ? box.height : box.width, ph = rot ? box.width : box.height
        guard pw > 0, ph > 0 else { return nil }
        let k = CGFloat(maxPixels) / max(pw, ph)
        let w = max(1, Int(pw * k)), h = max(1, Int(ph * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// JPEG bytes for an image (previews saved to the cache, contact sheets).
    static func jpegData(_ img: CGImage, quality: Double) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props = NSDictionary(dictionary: [kCGImageDestinationLossyCompressionQuality as String: quality])
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Data(referencing: d)
    }

    /// Decode JPEG bytes at reduced size. If the JPEG has no orientation of its own, the RAW file's
    /// TIFF orientation is applied.
    static func decode(_ data: CFData, maxPixels: Int, tiffOrientation: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        let own = (props?["Orientation"] as? NSNumber)?.intValue ?? 0
        let opts: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxPixels,
            kCGImageSourceShouldCacheImmediately as String: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, NSDictionary(dictionary: opts) as CFDictionary) else { return nil }
        if own > 1 || tiffOrientation <= 1 { return img }
        return rotate(img, tiffOrientation)
    }

    /// Apply TIFF orientation 3 (180), 6 (90 CW) or 8 (90 CCW). Mirrored values are left as they are.
    static func rotate(_ img: CGImage, _ o: Int) -> CGImage {
        guard o == 3 || o == 6 || o == 8 else { return img }
        let w = img.width, h = img.height
        let ow = o == 3 ? w : h, oh = o == 3 ? h : w
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        switch o {
        case 3:
            ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
            ctx.rotate(by: CGFloat.pi)
        case 6:
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -CGFloat.pi / 2)
        default:
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: CGFloat.pi / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }
}

/// Rating, label, camera, lens and size for photography mode's badges and filters.
enum PhotoFactsReader {
    /// What macOS itself can read. `readable` is false when macOS has no camera details for it
    /// (then ExifTool is asked, in batches).
    static func readNative(path: String) -> (facts: PhotoFacts, readable: Bool) {
        var f = PhotoFacts()
        let opts = [kCGImageSourceShouldCache as String: false] as CFDictionary
        guard let src = ImageMeta.source(path),   // PhotoLab: the shared reader (counted there)
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [String: Any] else { return (f, false) }
        let tiff = props["{TIFF}"] as? [String: Any] ?? [:]
        let exif = props["{Exif}"] as? [String: Any] ?? [:]
        let aux = props["{ExifAux}"] as? [String: Any] ?? [:]
        let iptc = props["{IPTC}"] as? [String: Any] ?? [:]
        f.width = (props["PixelWidth"] as? NSNumber)?.intValue ?? 0
        f.height = (props["PixelHeight"] as? NSNumber)?.intValue ?? 0
        f.camera = ExifSummary.cameraName(make: tiff["Make"] as? String, model: tiff["Model"] as? String)
        f.lens = (exif["LensModel"] as? String) ?? (aux["LensModel"] as? String)
        if let r = (iptc["StarRating"] as? NSNumber)?.intValue { f.rating = r; f.ratingSource = "embedded" }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            if let r = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString), let v = Int(r as String) {
                f.rating = v
                f.ratingSource = "embedded"
            }
            if let l = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Label" as CFString) { f.label = l as String }
            f.colorClass = ImageMetaColorClass.read(meta)
            if let d = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:MetadataDate" as CFString) { f.metadataDate = MetaPlan.xmpDate(d as String) }
        }
        let readable = f.camera != nil || (!PhotoFormats.isRaw(path) && f.width > 0)
        return (f, readable)
    }

    /// ExifTool for many files in one run (much faster than one run per file).
    static func readBatchExifTool(_ paths: [String]) -> [String: PhotoFacts] {
        if paths.isEmpty { return [:] }
        guard let data = ExifTool.runBatch(["-j", "-q", "-fast"] + ExifSummary.factTags.map { "-" + $0 }, files: paths, timeout: 60) else { return [:] }
        return ExifSummary.facts(fromJSON: data)
    }
}

/// ExifTool: the copy bundled inside Find.app (run with macOS's own /usr/bin/perl), or an installed one.
/// Always run read-only: fixed arguments, no write options, "-config" "" so no personal config file is
/// loaded, and the file path is always absolute (starts with "/") so it can't be taken for an option.
enum ExifTool {
    static let installed = ["/usr/local/bin/exiftool", "/opt/homebrew/bin/exiftool", "/usr/bin/exiftool", "/opt/local/bin/exiftool"]

    static var bundledScript: String? {
        guard let r = Bundle.main.resourcePath else { return nil }
        let p = r + "/exiftool/exiftool"
        return access(p, R_OK) == 0 && access("/usr/bin/perl", X_OK) == 0 ? p : nil
    }

    /// (program, leading arguments), or nil if no ExifTool is available.
    static var command: (String, [String])? {
        if let b = bundledScript { return ("/usr/bin/perl", [b]) }
        for c in installed where access(c, X_OK) == 0 { return (c, []) }
        return nil
    }

    static var path: String? {
        guard let c = command else { return nil }
        return c.1.first ?? c.0
    }

    static var isBundled: Bool { return bundledScript != nil }

    /// All metadata as "[Group] Tag : value" lines.
    static func allMetadata(of file: String, timeout: Double = 20) -> (lines: [String], error: String?) {
        let r = run(["-G1", "-a", "-q", file], file: file, timeout: timeout)
        guard let data = r.data else { return ([], r.error) }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return (text.split(separator: "\n").map { String($0) }, nil)
    }

    /// The inspector's summary sections, for files macOS can't read itself.
    static func summary(of file: String, timeout: Double = 15) -> (sections: [MetaSection], error: String?) {
        let r = run(["-j", "-q", "-fast"] + ExifSummary.tags.map { "-" + $0 } + [file], file: file, timeout: timeout)
        guard let data = r.data else { return ([], r.error) }
        guard let secs = ExifSummary.sections(fromJSON: data) else { return ([], "ExifTool output could not be read") }
        return (secs, nil)
    }

    /// Several files at once (JSON output). Every path must be absolute.
    static func runBatch(_ args: [String], files: [String], timeout: Double) -> Data? {
        guard !files.isEmpty, files.allSatisfyCompat({ $0.hasPrefix("/") }) else { return nil }
        return run(args + files, file: files[0], timeout: timeout).data
    }

    /// WRITING (metadata only): used solely by FileOperations.writeMetadata, and only ever on Find's own
    /// hidden working copies (".find-partial-..."), never on an original. Arguments come from MetaPlan.
    /// 0.18.5: ExifTool reads each original and writes the changed version as a NEW file beside it
    /// (`prefix` + name; -o never replaces an existing file). The originals are only read. Every
    /// "-overwrite_original..." option is removed first: with -o it would ERASE the original.
    static func runWriteBeside(_ args: [String], files: [String], prefix: String, timeout: Double) -> String? {
        guard prefix.hasPrefix(".find-partial-"), !prefix.contains("/"), !prefix.contains("%"),
            !files.isEmpty, files.allSatisfyCompat({ $0.hasPrefix("/") && !Paths.fileExtension($0).isEmpty }) else {
            return "refused: not PhotoLab's own hidden output names"
        }
        let safe = args.filter { !$0.lowercased().hasPrefix("-overwrite") && !$0.lowercased().hasPrefix("-delete_original") && $0 != "-o" && $0 != "-out" }
        if safe.contains(where: { $0.lowercased().contains("overwrite_original") }) { return "refused: overwrite option" }
        let r = run(["-q"] + safe + ["-o", "%d" + prefix + "%f.%e"] + files, file: files[0], timeout: timeout)
        return r.error
    }

    static func runWrite(_ args: [String], files: [String], timeout: Double) -> String? {
        guard !files.isEmpty, files.allSatisfyCompat({ $0.hasPrefix("/") && Paths.lastComponent($0).hasPrefix(".find-partial-") }) else {
            return "refused: ExifTool writes only PhotoLab's own working copies"
        }
        let r = run(["-q"] + args + files, file: files[0], timeout: timeout)
        return r.error
    }

    /// 0.18.6: through a kept-running ExifTool (ExifToolPool); a one-time ExifTool only if none can run.
    private static func run(_ args: [String], file: String, timeout: Double) -> (data: Data?, error: String?) {
        guard file.hasPrefix("/") else { return (nil, "Not an absolute path") }
        if let r = ExifToolPool.shared.run(args, timeout: timeout) { return r }
        return runOnce(args, file: file, timeout: timeout)
    }

    /// One ExifTool started for this command alone (before 0.18.6 every command; now the fallback).
    private static func runOnce(_ args: [String], file: String, timeout: Double) -> (data: Data?, error: String?) {
        guard let (program, lead) = command else { return (nil, "ExifTool is not available") }
        guard file.hasPrefix("/") else { return (nil, "Not an absolute path") }
        let p = Process()
        p.launchPath = program
        p.arguments = lead + ["-config", ""] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        var data = Data()
        var errData = Data()
        let done = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        p.launch()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            _ = errDone.wait(timeout: .now() + 1)
            return (nil, "ExifTool did not finish within \(Int(timeout)) seconds")
        }
        p.waitUntilExit()
        _ = errDone.wait(timeout: .now() + 2)
        if p.terminationStatus != 0 && data.isEmpty {
            let e = String(data: errData, encoding: .utf8) ?? ""
            return (nil, "ExifTool error \(p.terminationStatus): \(e.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (data, nil)
    }
}

private func int(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String { return Int(s) }
    return nil
}

private func double(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

private func clean(_ d: Double) -> String {
    return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
}

private func orientation(_ o: Int) -> String {
    switch o {
    case 3: return "Rotated 180"
    case 6: return "Rotated 90 CW"
    case 8: return "Rotated 90 CCW"
    case 2, 4, 5, 7: return "Mirrored (\(o))"
    default: return "\(o)"
    }
}

private func exposureProgram(_ p: Int) -> String {
    let names = [1: "Manual", 2: "Program", 3: "Aperture priority", 4: "Shutter priority", 5: "Creative",
                 6: "Action", 7: "Portrait", 8: "Landscape"]
    return names[p] ?? "Other (\(p))"
}

private func metering(_ m: Int) -> String {
    let names = [1: "Average", 2: "Center-weighted", 3: "Spot", 4: "Multi-spot", 5: "Matrix / pattern", 6: "Partial"]
    return names[m] ?? "Other (\(m))"
}


/// Ratings and metadata through the bundled ExifTool (see FileOperations.writeMetadata for the procedure).
final class ExifToolMetadata: MetadataTool {
    /// 0.18.2: ExifTool runs on one core; a batch is split over up to 4 ExifTools running at once
    /// (the iMac has 4 cores), which makes big metadata jobs several times faster.
    static var workers = 4

    private func records(_ data: Data?) -> [[String: Any]] {
        guard let d = data, let arr = (try? JSONSerialization.jsonObject(with: d, options: [])) as? [[String: Any]] else { return [] }
        return arr
    }

    /// `files` in up to `workers` parts (at least 2 files a part), each handled at the same time.
    private func inParallel<T>(_ files: [String], _ work: ([String]) -> T) -> [T] {
        let n = max(1, min(ExifToolMetadata.workers, files.count / 2))
        if n == 1 { return [work(files)] }
        let size = (files.count + n - 1) / n
        let parts = stride(from: 0, to: files.count, by: size).map { Array(files[$0..<min(files.count, $0 + size)]) }
        var out = [T?](repeating: nil, count: parts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: parts.count) { i in
            let r = work(parts[i])
            lock.lock(); out[i] = r; lock.unlock()
        }
        return out.compactMap { $0 }
    }

    func imageHashes(_ files: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for data in inParallel(files, { part in
            ExifTool.runBatch(["-j", "-q", "-api", "ImageHashType=MD5", "-ImageDataHash"], files: part,
                              timeout: 120 + Double(part.count) * 10)
        }) {
            for r in records(data) {
                if let f = r["SourceFile"] as? String, let h = r["ImageDataHash"] as? String, !h.isEmpty { out[f] = h }
            }
        }
        return out
    }

    func writeBeside(_ args: [String], files: [String], prefix: String) -> String? {
        let errors = inParallel(files, { part in ExifTool.runWriteBeside(args, files: part, prefix: prefix, timeout: 120 + Double(part.count) * 10) }).compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: " | ")
    }

    func write(_ args: [String], files: [String]) -> String? {
        let errors = inParallel(files, { part in ExifTool.runWrite(args, files: part, timeout: 120 + Double(part.count) * 10) }).compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: " | ")
    }

    func read(_ tags: [String], files: [String]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for data in inParallel(files, { part in ExifTool.runBatch(["-j", "-G1", "-q"] + tags, files: part, timeout: 60 + Double(part.count) * 2) }) {
            for r in records(data) {
                if let f = r["SourceFile"] as? String { out[f] = r }
            }
        }
        return out
    }
}


/// Photo Mechanic's colour class from embedded XMP (0.14). Its namespace isn't one macOS knows by
/// prefix, so the tags are looked through by namespace and name.
enum ImageMetaColorClass {
    static let namespace = "http://ns.camerabits.com/photomechanic/1.0/"

    static func read(_ meta: CGImageMetadata) -> Int? {
        #if os(macOS)
        guard let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return nil }
        for t in tags {
            guard let ns = CGImageMetadataTagCopyNamespace(t) as String?, ns == namespace,
                let name = CGImageMetadataTagCopyName(t) as String?, name == "ColorClass",
                let v = CGImageMetadataTagCopyValue(t) else { continue }
            let str = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
            if let n = Int(str.trimmingCharacters(in: .whitespaces)), n > 0, n <= 8 { return n }
        }
        #endif
        return nil
    }
}
