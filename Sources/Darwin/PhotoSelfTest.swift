// PhotoSelfTest.swift
// Checks the inspector's metadata reading on this Mac with a test JPEG whose camera values are known,
// and proves reading never changes a file. Works only inside its own scratch folder in
// ~/Library/Caches/PhotoLab (written through AppFiles), which it removes afterwards.
// Exit code for build.sh: 0 all passed, 2 a "file unchanged" check failed (stops the build),
// 1 other failures (reported as a warning; the app is still packaged).

import Foundation
import ImageIO

final class PhotoSelfTest {
    let files: AppFiles
    private let report = Report(title: "PhotoLab Photo Metadata Self-Test")
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private(set) var safetyFailed = 0
    private var failures: [String] = []
    private var root = ""

    init(files: AppFiles) { self.files = files }

    private func check(_ code: String, _ what: String, _ ok: Bool, _ detail: String = "", safety: Bool = false) {
        if ok {
            passed += 1
            report.add("PASS \(code) \(what)")
        } else {
            failed += 1
            if safety { safetyFailed += 1 }
            let line = "FAIL \(code) \(what)" + (detail.isEmpty ? "" : " -- \(detail)")
            failures.append(line)
            report.add(line)
        }
    }

    private func skip(_ code: String, _ what: String) {
        skipped += 1
        report.add("SKIP \(code) \(what)")
    }

    private func p(_ rel: String) -> String { return Paths.join(root, rel) }

    var exitCode: Int32 { return safetyFailed > 0 ? 2 : (failed > 0 ? 1 : 0) }

    func run(appVersion: String, systemInfo: String) -> String {
        report.addSummary("App \(appVersion)")
        report.addSummary("System \(systemInfo)")
        root = Paths.join(files.cachesDir, "phototest-\(Ascii.fileStamp())")
        guard files.makeDir(root) else {
            check("T-PHOTO-0", "make scratch folder", false, root)
            return finish()
        }
        report.add("Scratch folder \(root)")

        // 1 Make a 60 x 40 JPEG with known camera values (in memory, then saved through AppFiles).
        guard let jpeg = makeTestJPEG() else {
            check("T-PHOTO-1", "make test JPEG with ImageIO", false, "ImageIO could not create it")
            return finish()
        }
        let jpg = p("test.jpg")
        check("T-PHOTO-1", "test JPEG written", files.writeData(jpeg, to: jpg) && Sys.exists(jpg))
        let before = fingerprint(jpg)

        // 2-8 Read it back through the same code the inspector uses.
        let secs = ImageMeta.read(path: jpg)
        var rows: [String: String] = [:]
        for s in secs { for (k, v) in s.rows { rows[k] = v } }
        for s in secs { for l in s.asciiLines { report.add("READ \(l)") } }
        func has(_ k: String, _ v: String) -> Bool { return rows[k] == v }
        check("T-PHOTO-2", "dimensions and aspect", has("Dimensions", "60 x 40 pixels") && has("Aspect ratio", "3:2"),
              "\(rows["Dimensions"] ?? "-") \(rows["Aspect ratio"] ?? "-")")
        check("T-PHOTO-3", "camera make and model", has("Make", "FindTestCam") && has("Model", "Model T1"),
              "\(rows["Make"] ?? "-") / \(rows["Model"] ?? "-")")
        check("T-PHOTO-4", "aperture, shutter, ISO, focal length",
              has("Aperture", "f/2.8") && has("Shutter speed", "1/250 s") && has("ISO", "400") && has("Focal length", "85 mm"),
              "\(rows["Aperture"] ?? "-") \(rows["Shutter speed"] ?? "-") \(rows["ISO"] ?? "-") \(rows["Focal length"] ?? "-")")
        check("T-PHOTO-5", "exposure compensation", has("Exposure comp.", "-0.7 EV"), rows["Exposure comp."] ?? "-")
        check("T-PHOTO-6", "lens", has("Lens", "Test Lens 85mm"), rows["Lens"] ?? "-")
        let g = rows["GPS"] ?? ""
        check("T-PHOTO-7", "GPS position", g.hasPrefix("34\u{00B0}03'") && g.hasSuffix("W") && has("Decimal", "34.052300, -118.243700"),
              "\(g) | \(rows["Decimal"] ?? "-")")
        check("T-PHOTO-8", "IPTC keywords and copyright", has("Keywords", "alpha, beta") && has("Copyright", "(c) Find Test"),
              "\(rows["Keywords"] ?? "-") | \(rows["Copyright"] ?? "-")")

        // 9 Thumbnail
        let thumb = ImageMeta.thumbnail(path: jpg, maxPixels: 32)
        check("T-PHOTO-9", "thumbnail made, no larger than asked", thumb != nil && thumb!.width <= 32 && thumb!.height <= 32,
              thumb.map { "\($0.width)x\($0.height)" } ?? "none")

        // 9b Embedded RAW preview: the test JPEG inside a NEF-style file marked "rotate 90 CW".
        files.writeData(nefWrapping(jpeg, orientation: 6), to: p("wrapped.NEF"))
        let pv = ImageMeta.preview(path: p("wrapped.NEF"), maxPixels: 1024)
        check("T-PHOTO-18", "RAW preview taken from the embedded JPEG and turned upright",
              pv?.source == "embedded camera preview" && pv?.image.width == 40 && pv?.image.height == 60,
              pv.map { "\($0.source) \($0.image.width)x\($0.image.height)" } ?? "none")
        let big = ImageMeta.preview(path: jpg, maxPixels: 1024)
        check("T-PHOTO-19", "JPEG preview decoded from the image itself (not its tiny EXIF thumbnail)",
              big?.image.width == 60 && big?.image.height == 40, big.map { "\($0.image.width)x\($0.image.height)" } ?? "none")

        // 40-44 PhotoLab: embedded previews through the shared reader (CameraPreviews, FileReads).
        embeddedPreviewChecks()
        // 48 PhotoLab: sets (RAW + JPEG + sidecar as one row).
        let setDir = p("sets")
        _ = files.makeDir(setDir)
        for n in ["DSC_1.NEF", "DSC_1.JPG", "DSC_1.xmp", "DSC_2.JPG", "notes.txt", "DSC_3.xmp"] {
            _ = files.writeData(Data("x".utf8), to: Paths.join(setDir, n))
        }
        let setRows = FileSets.rows(DirectoryReader.read(setDir, includeHidden: false).entries)
        let set1 = setRows.first { $0.entry.name == "DSC_1.NEF" }
        let ren = set1.flatMap { FileSets.renames(members: $0.members, repName: "DSC_1.NEF", newName: "Job_1.NEF") } ?? []
        check("T-PHOTO-48", "sets: DSC_1 NEF+JPG+XMP one row (RAW shown), others alone; renaming the row renames all three",
              setRows.count == 4 && set1.map { FileSets.extLabel($0.entry.name, members: $0.members) } == "NEF+JPG+XMP"
                && set1?.entry.size == 3 && Set(ren.map { $0.newName }) == ["Job_1.NEF", "Job_1.JPG", "Job_1.xmp"]
                && FileSets.renames(members: set1?.members ?? [], repName: "DSC_1.NEF", newName: "Job_1.TIF") == nil,
              "\(setRows.map { $0.entry.name + "/" + "\($0.members.count)" }) \(ren.map { $0.newName })")

        // 49 A DNG is never in a set with another RAW or a sidecar (its metadata stays its own).
        let dngDir = p("sets-dng")
        _ = files.makeDir(dngDir)
        for n in ["DSC_5.NEF", "DSC_5.DNG", "DSC_5.JPG", "DSC_5.xmp", "DSC_6.DNG", "DSC_6.JPG"] {
            _ = files.writeData(Data("x".utf8), to: Paths.join(dngDir, n))
        }
        let dngRows = FileSets.rows(DirectoryReader.read(dngDir, includeHidden: false).entries)
        let dngLabels = Set(dngRows.map { FileSets.extLabel($0.entry.name, members: $0.members) + ":" + $0.entry.name })
        check("T-PHOTO-49", "sets: a DNG never shares a row with a same-named NEF or an XMP; DNG+JPG alone is a set",
              dngLabels == ["DNG:DSC_5.DNG", "NEF+JPG+XMP:DSC_5.NEF", "DNG+JPG:DSC_6.DNG"],
              dngLabels.sorted().joined(separator: " "), safety: true)

        // 45 PhotoLab: xmp:Label follows the colour class (ColorClass is the master).
        var lc = MetaChange()
        lc.colorClass = 4
        let lv = InPlaceValues(lc, current: [:]).xmpChanges()
        var lc0 = MetaChange()
        lc0.colorClass = 0
        let lv0 = InPlaceValues(lc0, current: [:]).xmpChanges()
        check("T-PHOTO-45", "colour class 4 writes xmp:Label Green; class 0 removes it",
              lv.contains { $0.0.local == "Label" && $0.1 == ["Green"] } && lv0.contains { $0.0.local == "Label" && $0.1.isEmpty },
              "\(lv.map { "\($0.0.local)=\($0.1)" }) / \(lv0.map { "\($0.0.local)=\($0.1)" })")

        // 46 Opening a selection: one request per application (one Camera Raw session for many RAWs)
        let fakeApps: [String: String] = ["nef": "/Applications/PS.app", "cr3": "/Applications/PS.app", "pdf": "/Applications/Acro.app"]
        let og = OpenGroups.group(["/V/J/a.NEF", "/V/J/b.pdf", "/V/J/c.nef", "/V/J/d.CR3", "/V/J/e.xyz", "/V/J/f.xyz"],
                                  appForExtension: { fakeApps[$0] })
        let ogWant = [OpenGroup(app: "/Applications/PS.app", paths: ["/V/J/a.NEF", "/V/J/c.nef", "/V/J/d.CR3"]),
                      OpenGroup(app: "/Applications/Acro.app", paths: ["/V/J/b.pdf"]),
                      OpenGroup(app: nil, paths: ["/V/J/e.xyz"]),
                      OpenGroup(app: nil, paths: ["/V/J/f.xyz"])]
        let ogAll = OpenGroups.all(["/V/J/a.NEF", "/V/J/b.pdf"], app: "/Applications/PS.app")
        check("T-PHOTO-46", "a selection opens with one request per application, in selection order",
              og == ogWant && ogAll.count == 1 && ogAll[0].paths.count == 2 && OpenGroups.all([], app: "x").isEmpty,
              "\(og.map { "\($0.app ?? "-"):\($0.paths.count)" })")

        // 20-22 Photography mode facts and the contact sheet
        let nf = PhotoFactsReader.readNative(path: jpg)
        check("T-PHOTO-20", "photo facts read by macOS (camera, size)",
              nf.readable && nf.facts.camera == "FindTestCam Model T1" && nf.facts.width == 60, "\(nf.facts)")
        var sheetOpts = ContactSheetOptions()
        sheetOpts.title = "Self-Test"
        var err: Int32 = 0
        let sheetEntries = [jpg, p("wrapped.NEF")].compactMap { FileEntry.make(path: $0, err: &err) }
        let pdf = ContactSheetMaker.render(sheetEntries, options: sheetOpts, progress: { _ in })
        let head = pdf.map { String(data: $0.prefix(5), encoding: .ascii) ?? "" } ?? ""
        check("T-PHOTO-21", "contact sheet PDF rendered", head == "%PDF-" && (pdf?.count ?? 0) > 1000, "\(head) \(pdf?.count ?? 0) bytes")
        check("T-PHOTO-22", "making the contact sheet left the pictures unchanged", fingerprint(jpg) == before, safety: true)

        // 24-27 Fast folder listing (getattrlistbulk) gives exactly what readdir + lstat gives.
        let ld = p("listing")
        _ = files.makeDir(ld)
        _ = files.makeDir(Paths.join(ld, "a folder"))
        files.writeText("x", to: Paths.join(ld, ".hidden"))
        files.writeText("caf\u{00E9} \u{00FC}", to: Paths.join(ld, "caf\u{00E9} \u{00FC} \u{2605}.txt"))
        files.writeData(Data(count: 123_457), to: Paths.join(ld, "big.bin"))
        _ = files.makeSymlink(Paths.join(ld, "link"), to: Paths.join(ld, "a folder"))
        for i in 0..<300 { files.writeText("\(i)", to: Paths.join(ld, String(format: "file %03d.txt", i))) }
        let d1 = BulkLister.compareWithClassic(ld)
        check("T-LIST-1", "fast listing equals classic listing (test folder, 305 items)", d1.isEmpty, d1.joined(separator: " | "), safety: true)
        let d2 = BulkLister.compareWithClassic(ld, bufferSize: 2048)
        check("T-LIST-2", "fast listing with a tiny buffer (many requests) equals classic", d2.isEmpty, d2.joined(separator: " | "), safety: true)
        let d3 = BulkLister.compareWithClassic(NSHomeDirectory())
        check("T-LIST-3", "fast listing equals classic listing (home folder; warning only, it may change meanwhile)", d3.isEmpty, d3.joined(separator: " | "))
        let d4 = BulkLister.compareWithClassic("/Applications")
        check("T-LIST-4", "fast listing equals classic listing (/Applications; warning only)", d4.isEmpty, d4.joined(separator: " | "))
        let d5 = BulkLister.checkCapturedRecords()
        check("T-LIST-5", "folder records from the lab's SMB servers (108 bytes, no size field) parse as folders", d5.isEmpty,
              d5.joined(separator: " | "), safety: true)

        // 10 Not an image inside: handled without a crash, says so.
        files.writeText("not really a raw file", to: p("fake.NEF"))
        let fake = ImageMeta.read(path: p("fake.NEF"))
        check("T-PHOTO-10", "unreadable RAW handled gracefully", !fake.isEmpty, "\(fake.count) sections")

        // 11 Sidecar beside a RAW file
        files.writeText("<x:xmpmeta><rdf:RDF><rdf:Description xmp:Rating=\"3\" xmp:Label=\"Green\"/></rdf:RDF></x:xmpmeta>", to: p("fake.xmp"))
        let sc = Sidecars.find(for: p("fake.NEF"))
        let fields = sc.flatMap { XMPReader.read(path: $0) }
        check("T-PHOTO-11", "sidecar found and read", sc == p("fake.xmp") && fields?.rating == 3 && fields?.label == "Green",
              "\(sc ?? "none") \(String(describing: fields?.rating))")

        // 47 DNGs never have a sidecar (alpha.6, user's rule): "twin.xmp" is the NEF's only, the DNG is written
        // inside itself only - also with embedded writing off in Settings - so stars/metadata never cross over.
        files.writeText("not really a raw file", to: p("twin.NEF"))
        files.writeText("not really a dng file", to: p("twin.DNG"))
        files.writeText("not really a raw file", to: p("solo.DNG"))
        files.writeText("<x:xmpmeta><rdf:RDF><rdf:Description xmp:Rating=\"4\"/></rdf:RDF></x:xmpmeta>", to: p("twin.xmp"))
        files.writeText("<x:xmpmeta><rdf:RDF><rdf:Description xmp:Rating=\"2\"/></rdf:RDF></x:xmpmeta>", to: p("solo.xmp"))
        let tNef = Sidecars.find(for: p("twin.NEF")), tDng = Sidecars.find(for: p("twin.DNG")), tSolo = Sidecars.find(for: p("solo.DNG"))
        let tAssoc = Sidecars.associate(["twin.NEF", "twin.DNG", "twin.xmp", "twin.JPG", "solo.DNG", "solo.xmp"]).pairs
        let tCopy = Sidecars.companions(of: [p("twin.DNG")], move: false) { _ in ["twin.NEF", "twin.DNG", "twin.xmp"] }.extra
        let keepXMP = MetaPlan.writeEmbeddedXMP, keepIPTC = MetaPlan.writeEmbeddedIPTC, keepSide = MetaPlan.writeSidecar
        MetaPlan.writeEmbeddedXMP = true; MetaPlan.writeEmbeddedIPTC = true; MetaPlan.writeSidecar = true
        let tIn = MetaPlan.targets([p("twin.DNG"), p("solo.DNG")])
        MetaPlan.writeEmbeddedXMP = false; MetaPlan.writeEmbeddedIPTC = false
        let tOff = MetaPlan.targets([p("twin.DNG"), p("solo.DNG")])
        let tOffXMP = tOff.allSatisfyCompat { MetaPlan.places(for: $0).xmp }
        let tNefWrite = MetaPlan.targets([p("twin.NEF")]).map { $0.file }
        MetaPlan.writeEmbeddedXMP = keepXMP; MetaPlan.writeEmbeddedIPTC = keepIPTC; MetaPlan.writeSidecar = keepSide
        let dngFiles = [p("twin.DNG"), p("solo.DNG")]
        let insideOnly: ([MetaTarget]) -> Bool = { t in
            t.map { $0.file } == dngFiles && t.allSatisfyCompat { $0.kind == .embeddedRaw } }
        check("T-PHOTO-47", "a DNG never has an XMP sidecar: read, written and copied inside itself only",
              tNef == p("twin.xmp") && tDng == nil && tSolo == nil
                && tAssoc["twin.NEF"] == "twin.xmp" && tAssoc["twin.JPG"] == "twin.xmp" && tAssoc["twin.DNG"] == nil && tAssoc["solo.DNG"] == nil
                && tCopy.isEmpty && insideOnly(tIn) && insideOnly(tOff) && tOffXMP && tNefWrite == [p("twin.xmp")],
              "nef=\(tNef == nil ? "-" : "xmp") dng=\(tDng == nil ? "-" : "xmp") solo=\(tSolo == nil ? "-" : "xmp") "
                + "assoc=\(tAssoc.count) copy=\(tCopy.count) in=\(tIn.count) off=\(tOff.count) offXMP=\(tOffXMP) nef=\(tNefWrite.count)",
              safety: true)

        // 12 Reading never changed the files.
        check("T-PHOTO-12", "reading metadata left the JPEG byte-for-byte unchanged", before != nil && fingerprint(jpg) == before, safety: true)

        // 13 ExifTool (optional)
        report.add("ExifTool: \(ExifTool.path ?? "not available")\(ExifTool.isBundled ? " (bundled)" : "")")
        if ExifTool.path != nil {
            let r = ExifTool.allMetadata(of: jpg)
            check("T-PHOTO-13", "ExifTool reads the test JPEG", r.error == nil && r.lines.contains { $0.contains("FindTestCam") },
                  r.error ?? "\(r.lines.count) lines")
            check("T-PHOTO-14", "ExifTool left the JPEG byte-for-byte unchanged", fingerprint(jpg) == before, safety: true)
            let sum = ExifTool.summary(of: jpg)
            var srows: [String: String] = [:]
            for sec in sum.sections { for (k, v) in sec.rows { srows[k] = v } }
            check("T-PHOTO-16", "ExifTool summary (used for RAW formats macOS can't read)",
                  srows["Make"] == "FindTestCam" && srows["Aperture"] == "f/2.8" && srows["Shutter speed"] == "1/250 s" && srows["ISO"] == "400",
                  sum.error ?? "\(srows)")
            check("T-PHOTO-17", "ExifTool summary left the JPEG byte-for-byte unchanged", fingerprint(jpg) == before, safety: true)
            let bf = PhotoFactsReader.readBatchExifTool([jpg, p("wrapped.NEF")])
            check("T-PHOTO-23", "ExifTool batch facts (used for RAW macOS can't read)", bf[jpg]?.camera == "FindTestCam Model T1", "\(bf)")
            // 24-30 (0.12) Ratings and metadata written with the real ExifTool, the way Find writes them:
            // copy, write the copy, verify (values + identical picture data), swap. Scratch files only.
            let platform = DarwinPlatform()
            platform.trashOverride = p("Trash")   // previous versions go here, not into your Trash
            // 0.18.5: tested with RAW written inside and the default (fingerprint) mode, whatever you set.
            // 0.18.6: all three places (sidecar, embedded XMP, embedded IPTC), whatever you set.
            let saved = (MetaPlan.writeSidecar, MetaPlan.writeEmbeddedXMP, MetaPlan.writeEmbeddedIPTC, MetaPlan.writeMode)
            let saved2 = (MetaPlan.inPlaceExifToolCheck, MetaPlan.nativeRead, MetaPlan.nativeSidecar, MetaPlan.nativeExifToolDoubleCheck, MetaPlan.inPlace)
            MetaPlan.writeSidecar = true
            MetaPlan.writeEmbeddedXMP = true
            MetaPlan.writeEmbeddedIPTC = true
            MetaPlan.writeMode = .fingerprint
            // 0.18.11: the same settings every time, whatever Settings say (the native path is tested on).
            MetaPlan.inPlaceExifToolCheck = true
            MetaPlan.nativeRead = true
            MetaPlan.nativeSidecar = true
            MetaPlan.nativeExifToolDoubleCheck = false
            // 0.18.11.1: the normal (rewrite) path first, whatever Settings say (PhotoLab: T-PHOTO-28 checks that
            // no previous version goes to the Trash). T-PHOTO-32/33 turn the in-place change on.
            MetaPlan.inPlace = false
            defer {
                (MetaPlan.writeSidecar, MetaPlan.writeEmbeddedXMP, MetaPlan.writeEmbeddedIPTC, MetaPlan.writeMode) = saved
                (MetaPlan.inPlaceExifToolCheck, MetaPlan.nativeRead, MetaPlan.nativeSidecar, MetaPlan.nativeExifToolDoubleCheck, MetaPlan.inPlace) = saved2
            }
            let ops = FileOperations(platform: platform)
            let tool = ExifToolMetadata()
            ops.metadataTool = tool
            // 0.18.3: the test's own notes folder inside its scratch folder. The shared one may hold notes
            // of a Find that is running at the same time (e.g. while you build), which made T-PHOTO-30
            // count them as left behind.
            ops.journal = OperationJournal(files: AppFiles(supportDir: p("notes"), cachesDir: files.cachesDir, logsDir: files.logsDir))
            let rate = p("rate.jpg")
            files.writeData(jpeg, to: rate)
            try? platform.setTagNames(rate, ["Red"])
            let nefBefore = fingerprint(p("wrapped.NEF"))
            let nefHashBefore = tool.imageHashes([p("wrapped.NEF")])[p("wrapped.NEF")]
            let hashBefore = tool.imageHashes([rate])[rate]
            var c = MetaChange()
            c.rating = 3
            c.set[.caption] = "Find self-test caption \u{00E9}"
            c.set[.keywords] = "one, two"
            let wr = ops.writeMetadata([rate, p("wrapped.NEF")], change: c)
            check("T-PHOTO-24", "rating, caption and keywords written to all 3 places (JPEG: XMP + IPTC inside; RAW: inside + new sidecar)",
                  wr.done.count == 3 && wr.failed.isEmpty, wr.summaryLines.joined(separator: " | "))
            let back = tool.read(MetaPlan.readTags(for: MetaTarget(image: "", file: "", kind: .embedded(iptc: true))), files: [rate])[rate] ?? [:]
            let native = PhotoFactsReader.readNative(path: rate).facts.rating
            check("T-PHOTO-25", "read back as Photo Mechanic reads them (XMP rating; XMP and IPTC caption and keywords; macOS sees the rating)",
                  MetaPlan.verify(c, readBack: back, target: MetaTarget(image: rate, file: rate, kind: .embedded(iptc: true))) == nil && native == 3,
                  "\(back) native=\(String(describing: native))")
            check("T-PHOTO-26", "the picture data is bit-for-bit unchanged after writing metadata",
                  hashBefore != nil && tool.imageHashes([rate])[rate] == hashBefore, safety: true)
            check("T-PHOTO-27", "Finder tag kept", platform.tagNames(rate).contains("Red"), "\(platform.tagNames(rate))")
            // 0.18: the RAW's own IPTC/XMP is written (not its picture data); no new sidecar; the previous
            // version kept (in the test's own Trash folder, as it would be in yours).
            let nefNow = tool.read(["-XMP-xmp:Rating", "-IPTC:Caption-Abstract"], files: [p("wrapped.NEF")])[p("wrapped.NEF")] ?? [:]
            let nefHashAfter = tool.imageHashes([p("wrapped.NEF")])[p("wrapped.NEF")]
            let kept = files.list(p("Trash")).filter { $0.hasPrefix("wrapped (before metadata edit)") }
            let keptSame = kept.first.map { fingerprint(Paths.join(p("Trash"), $0)) == nefBefore } ?? false
            let side = tool.read(["-XMP-xmp:Rating", "-XMP-dc:Description"], files: [p("wrapped.xmp")])[p("wrapped.xmp")] ?? [:]
            _ = keptSame
            check("T-PHOTO-28", "RAW: values written inside and into its new sidecar, picture data unchanged, no previous version in the Trash (PhotoLab S4)",
                  MetaPlan.currentRating(in: nefNow) == 3 && (nefHashBefore == nil || nefHashAfter == nefHashBefore)
                    && kept.isEmpty && MetaPlan.currentRating(in: side) == 3 && MetaPlan.current(.caption, in: side) == "Find self-test caption \u{00E9}",
                  "rating=\(MetaPlan.currentRating(in: nefNow)) hash \(nefHashBefore ?? "none") -> \(nefHashAfter ?? "none") kept=\(kept) sidecar=\(side)",
                  safety: true)
            report.add("INFO RAW embedded IPTC caption: " + Ascii.clean(String(describing: nefNow["IPTC:Caption-Abstract"] ?? "(none - this RAW type has no IPTC, or it was skipped)")))
            if let u = wr.undo { _ = try? ops.undo(u) }
            let undone = tool.read(["-XMP-xmp:Rating", "-XMP-dc:Description"], files: [rate])[rate] ?? [:]
            let nefUndone = tool.read(["-XMP-xmp:Rating", "-XMP-dc:Description"], files: [p("wrapped.NEF")])[p("wrapped.NEF")] ?? [:]
            check("T-PHOTO-29", "Undo puts the old values back (JPEG and RAW)",
                  MetaPlan.currentRating(in: undone) == 0 && MetaPlan.current(.caption, in: undone).isEmpty
                    && MetaPlan.currentRating(in: nefUndone) == 0 && MetaPlan.current(.caption, in: nefUndone).isEmpty,
                  "\(undone) \(nefUndone)")
            let hiddenLeft = files.list(root).filter { $0.hasPrefix(".find-") || $0.contains("_exiftool_tmp") }
            check("T-PHOTO-30", "no working copies or notes left behind", hiddenLeft.isEmpty && (ops.journal?.pendingCount ?? 0) == 0,
                  "hidden=\(hiddenLeft) notes=\(ops.journal?.pendingCount ?? 0)", safety: true)
            // 0.18.6: the kept-running ExifTool answered (no ExifTool started per command), and a caption with
            // a line break arrives exactly as typed (it is sent as a C string to the running ExifTool).
            var ml = MetaChange()
            ml.set[.caption] = "Line one\nLine two \u{00E9}"
            let mlr = ops.writeMetadata([rate], change: ml)
            check("T-PHOTO-31", "kept-running ExifTool used, multi-line caption written exactly and checked",
                  mlr.done.count == 1 && mlr.failed.isEmpty && ExifToolPool.shared.served > 0,
                  "served=\(ExifToolPool.shared.served) " + mlr.summaryLines.joined(separator: " | "))
            if let u = mlr.undo { _ = try? ops.undo(u) }
            // 0.18.8: "change in place" with the real ExifTool checking: the RAW (TIFF-based) and the JPEG
            // (its XMP has room now) - values right, picture data identical, file only grown by a few KB.
            MetaPlan.inPlace = true
            let nef = p("wrapped.NEF")
            var se: Int32 = 0
            let sizeBefore = Sys.lstatInfo(nef, &se)?.size ?? 0
            let nefHash0 = tool.imageHashes([nef])[nef]
            let jpgHash0 = tool.imageHashes([rate])[rate]
            var ip = MetaChange()
            ip.rating = 2
            ip.set[.headline] = "In place \u{00FC}"
            let ipr = ops.writeMetadata([nef, rate], change: ip)
            MetaPlan.inPlace = false
            let nefHash1 = tool.imageHashes([nef])[nef]
            let jpgHash1 = tool.imageHashes([rate])[rate]
            let nb = tool.read(["-XMP-photoshop:Headline", "-XMP-xmp:Rating", "-IPTC:Headline"], files: [nef])[nef] ?? [:]
            let grown = (Sys.lstatInfo(nef, &se)?.size ?? 0) - sizeBefore
            check("T-PHOTO-32", "in place: RAW and JPEG values right, picture data identical, RAW grew by KBs only",
                  ipr.failed.isEmpty && ipr.done.count >= 2 && MetaPlan.current(.headline, in: nb) == "In place \u{00FC}" && MetaPlan.currentRating(in: nb) == 2
                    && (nefHash0 == nil || nefHash0 == nefHash1) && jpgHash0 != nil && jpgHash0 == jpgHash1 && grown < 64 * 1024,
                  "grown=\(grown) nef \(nefHash0 ?? "-")/\(nefHash1 ?? "-") jpg \(jpgHash0 ?? "-")/\(jpgHash1 ?? "-") \(nb) " + ipr.summaryLines.joined(separator: " | "),
                  safety: true)
            report.add("INFO in place: " + Ascii.clean(String(describing: nb["IPTC:Headline"] ?? "(no IPTC headline in this RAW)")))
            if let u = ipr.undo { _ = try? ops.undo(u) }
            // 0.18.11: Find's own reader and sidecar writer, and the fast in-place check, judged by the real
            // ExifTool: every value Find wrote reads back exactly in ExifTool, and Find reads what ExifTool reads.
            MetaPlan.inPlace = true
            MetaPlan.inPlaceExifToolCheck = false
            var nv = MetaChange()
            nv.rating = 4
            nv.colorClass = 5
            nv.set[.caption] = "Native \u{00E9} & <x>\nline 2"
            nv.set[.keywords] = "n1, n\u{00E8}2"
            nv.set[.contactCity] = "Lyon"
            nv.set[.lcCity] = "Paris"
            nv.set[.dateCreated] = "2026-11-26"
            nv.set[.copyrightMarked] = "True"
            nv.set[.category] = "category"
            nv.set[.suppCategories] = "s1, s2"
            let nr = ops.writeMetadata([nef, rate], change: nv)
            MetaPlan.inPlaceExifToolCheck = true
            MetaPlan.inPlace = false
            let nSide = Sidecars.find(for: nef) ?? ""
            let nTags = MetaPlan.readTags(for: MetaTarget(image: "", file: "", kind: .embedded(iptc: true)))
            let etv = tool.read(nTags, files: [nef, rate, nSide].filter { !$0.isEmpty })
            var agree = !nSide.isEmpty
            var why = nSide.isEmpty ? " no sidecar" : ""
            for f in [nef, rate, nSide] where !f.isEmpty {
                let e = etv[f] ?? [:]
                let kind: MetaTarget.Kind = f == rate ? .embedded(iptc: true) : (f == nSide ? .sidecarExisting : .embeddedRaw)
                if let prob = MetaPlan.verify(nv, readBack: e, target: MetaTarget(image: f, file: f, kind: kind)) {
                    agree = false
                    why += " ExifTool: \(prob) in \(Paths.lastComponent(f))"
                }
                guard let n = NativeMeta.read(f) else { agree = false; why += " PhotoLab could not read \(Paths.lastComponent(f))"; continue }
                for k in nTags.map({ String($0.dropFirst()) }) {
                    let fld = MetaField.all.first { $0.xmp == k || $0.iptc == k }
                    let canon: (Any?) -> [String] = { v in MetaPlan.values(v).map { fld?.canonical($0) ?? $0 } }
                    let same = k == "XMP-photomech:ColorClass" ? MetaPlan.currentColorClass(in: e) == MetaPlan.currentColorClass(in: n) : canon(e[k]) == canon(n[k])
                    if !same { agree = false; why += " \(k) differs in \(Paths.lastComponent(f))" }
                }
            }
            check("T-PHOTO-33", "PhotoLab's own reader and writer (sidecar, fast in-place check): ExifTool reads every value exactly, and PhotoLab reads what ExifTool reads",
                  nr.failed.isEmpty && nr.done.count >= 3 && agree, Ascii.clean(why) + " " + nr.summaryLines.joined(separator: " | "), safety: true)
            if let u = nr.undo { _ = try? ops.undo(u) }
            let leftovers = files.list(root).filter { $0.hasSuffix("_original") || $0.hasSuffix(".tmp") }
            check("T-PHOTO-15", "ExifTool made no backup or temp files", leftovers.isEmpty, "\(leftovers)", safety: true)
        } else {
            check("T-PHOTO-13", "bundled ExifTool available", false, "not found inside PhotoLab.app and not installed")
        }
        return finish()
    }

    /// Minimal little-endian TIFF/NEF: IFD0 (orientation, SubIFDs) -> SubIFD with the JPEG.
    // MARK: PhotoLab embedded previews (ported from PhotoLab 2's thumbnail self-test)

    private func jpegOf(_ w: Int, _ h: Int) -> Data? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        return ImageMeta.jpegData(img, quality: 0.8)
    }

    private func embeddedPreviewChecks() {
        guard let big = jpegOf(2048, 1365), let mid = jpegOf(640, 427), let small = jpegOf(160, 107) else {
            check("T-PHOTO-40", "make test previews", false, "ImageIO could not make JPEGs")
            return
        }
        func le16(_ v: Int) -> [UInt8] { return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { return [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func entry(_ tag: Int, _ type: Int, _ value: Int) -> [UInt8] { return le16(tag) + le16(type) + le32(1) + (type == 3 ? le16(value) + [0, 0] : le32(value)) }
        // Fake NEF: IFD0 (orientation 6, SubIFDs, 2048 px preview) | SubIFD 1 (160 px) | SubIFD 2 (640 px).
        let ifd0 = 8
        let sub1 = ifd0 + 2 + 4 * 12 + 4
        let sub2 = sub1 + 2 + 2 * 12 + 4
        let arr = sub2 + 2 + 2 * 12 + 4
        let pad = 1 << 20   // the big preview lies 1 MB further on: taking it would show in the bytes read
        let smallAt = arr + 8, midAt = smallAt + small.count, bigAt = midAt + mid.count + pad
        var t: [UInt8] = [0x49, 0x49, 42, 0] + le32(ifd0)
        t += le16(4) + entry(0x0112, 3, 6) + le16(0x014A) + le16(4) + le32(2) + le32(arr) + entry(0x0201, 4, bigAt) + entry(0x0202, 4, big.count) + le32(0)
        t += le16(2) + entry(0x0201, 4, smallAt) + entry(0x0202, 4, small.count) + le32(0)
        t += le16(2) + entry(0x0201, 4, midAt) + entry(0x0202, 4, mid.count) + le32(0)
        t += le32(sub1) + le32(sub2)
        var nef = Data(t)
        nef.append(small); nef.append(mid); nef.append(Data(count: pad)); nef.append(big)
        let nefPath = p("pick.NEF")
        _ = files.writeData(nef, to: nefPath)
        FileReads.forget([nefPath])
        if let r = FileReads.reader(nefPath) {
            let img = CameraPreviews.thumbnail(r, ext: "nef", maxPixels: 256).image
            let okSize = img.map { $0.height == 256 && abs($0.width - 171) <= 1 } ?? false
            check("T-PHOTO-40", "RAW thumbnail from the smallest preview that is big enough (640 px, not the 2048 px one), upright",
                  okSize && r.bytes < 512 << 10, img.map { "\($0.width)x\($0.height), \(r.reads) reads, \(r.bytes / 1024) KB" } ?? "none")
            let before = r.reads
            _ = CameraPreviews.thumbnail(r, ext: "nef", maxPixels: 256)
            check("T-PHOTO-41", "second look at the same file reads nothing more (shared reader)", r.reads == before, "\(r.reads - before) more reads")
        } else {
            check("T-PHOTO-40", "open test NEF", false, nefPath)
        }
        // Camera JPEG with an MPF preview (APP2): the preview is found without decoding the picture.
        // Layout: SOI(0) | FF E2 + length (2) | "MPF\0" (6) | MPF TIFF header (10) ... | 640 px preview | main picture.
        var mpf: [UInt8] = Array("MPF\0".utf8)
        mpf += [0x49, 0x49, 42, 0] + le32(8)
        mpf += le16(1) + le16(0xB002) + le16(7) + le32(32) + le32(8 + 2 + 12 + 4) + le32(0)
        let appLen = 2 + mpf.count + 32
        let previewOffset = 4 + appLen - 10        // from the MPF TIFF header (file offset 10)
        mpf += le32(0x030000) + le32(0) + le32(0) + le32(0)
        mpf += le32(0x010001) + le32(mid.count) + le32(previewOffset) + le32(0)
        var cam = Data([0xFF, 0xD8, 0xFF, 0xE2, UInt8(appLen >> 8), UInt8(appLen & 0xFF)])
        cam.append(contentsOf: mpf)
        cam.append(mid)
        cam.append(big.dropFirst(2))   // the main picture (its own SOI dropped: one file, one SOI)
        let camPath = p("camera.jpg")
        _ = files.writeData(cam, to: camPath)
        if let r = FileReads.reader(camPath) {
            let c = CameraPreviews.jpegPreviews(r).candidates
            check("T-PHOTO-42", "camera JPEG: MPF preview located", c.contains { $0.length == mid.count }, "\(c.map { $0.length })")
        }
        // PSD: Photoshop's thumbnail resource, without reading the 2 MB composite.
        var psd = Data(Array("8BPS".utf8))
        psd.append(contentsOf: [0, 1, 0, 0, 0, 0, 0, 0, 0, 3] as [UInt8])
        psd.append(contentsOf: be32(107)); psd.append(contentsOf: be32(160))
        psd.append(contentsOf: [0, 8, 0, 3] as [UInt8]); psd.append(contentsOf: be32(0))
        func block(_ id: Int, _ payload: [UInt8]) -> [UInt8] {
            var b: [UInt8] = Array("8BIM".utf8)
            b += [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0] + be32(payload.count) + payload
            if payload.count % 2 == 1 { b.append(0) }
            return b
        }
        var res = block(1005, [UInt8](repeating: 1, count: 15))
        res += block(1036, [UInt8](repeating: 0, count: 28) + [UInt8](small))
        psd.append(contentsOf: be32(res.count)); psd.append(contentsOf: res)
        psd.append(Data(count: 2 << 20))
        let psdPath = p("layers.psd")
        _ = files.writeData(psd, to: psdPath)
        if let r = FileReads.reader(psdPath) {
            let img = CameraPreviews.thumbnail(r, ext: "psd", maxPixels: 256).image
            check("T-PHOTO-43", "PSD thumbnail from Photoshop's resource, composite not read",
                  img?.width == 160 && r.bytes < 512 << 10, "\(img.map { "\($0.width)" } ?? "none") \(r.bytes / 1024) KB")
        }
        // The file changes: a new reader (its old bytes are never shown).
        nef.append(Data(count: 10))
        FileReads.forget([nefPath])
        _ = files.writeData(nef, to: nefPath)
        let r1 = FileReads.reader(nefPath)
        check("T-PHOTO-44", "a changed file gets a fresh reader", r1?.size == Int64(nef.count), "\(r1?.size ?? -1) vs \(nef.count)")
    }

    private func nefWrapping(_ jpeg: Data, orientation: Int) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        func entry(_ tag: Int, _ type: Int, _ value: Int) { u16(tag); u16(type); u32(1); if type == 3 { u16(value); u16(0) } else { u32(value) } }
        let ifd0 = 8, ifd0Size = 2 + 2 * 12 + 4
        let sub = ifd0 + ifd0Size, subSize = 2 + 2 * 12 + 4
        let data = sub + subSize
        d.append(contentsOf: [0x49, 0x49, 0x2A, 0x00]); u32(ifd0)
        u16(2); entry(0x0112, 3, orientation); entry(0x014A, 4, sub); u32(0)
        u16(2); entry(0x0201, 4, data); entry(0x0202, 4, jpeg.count); u32(0)
        d.append(jpeg)
        return d
    }

    private func fingerprint(_ path: String) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        return fh.readDataToEndOfFile()
    }

    private func makeTestJPEG() -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 0.45, green: 0.55, blue: 0.7, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props: [String: Any] = [
            "{TIFF}": ["Make": "FindTestCam", "Model": "Model T1"],
            "{Exif}": ["FNumber": 2.8, "ExposureTime": 0.004, "ISOSpeedRatings": [400], "FocalLength": 85.0,
                       "ExposureBiasValue": -0.7, "LensModel": "Test Lens 85mm", "DateTimeOriginal": "2026:11:21 10:30:00"],
            "{GPS}": ["Latitude": 34.0523, "LatitudeRef": "N", "Longitude": 118.2437, "LongitudeRef": "W"],
            "{IPTC}": ["Keywords": ["alpha", "beta"], "CopyrightNotice": "(c) Find Test"],
        ]
        CGImageDestinationAddImage(dest, img, NSDictionary(dictionary: props) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Data(referencing: data)
    }

    private func finish() -> String {
        if !root.isEmpty && Sys.exists(root) {
            let removed = files.removeOwned(root)
            check("T-PHOTO-90", "test folder removed", removed && !Sys.exists(root))
        }
        report.addSummary("RESULT \(failed == 0 ? "ALL PASSED" : "FAILURES PRESENT")")
        report.addSummary("PASSED \(passed) FAILED \(failed) SKIPPED \(skipped)")
        if safetyFailed > 0 { report.addSummary("SAFETY FAILURES \(safetyFailed)") }
        for f in failures { report.addSummary(f) }
        return report.render()
    }
}
