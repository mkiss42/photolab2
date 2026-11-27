// Inspector.swift
// Optional right-hand panel: preview, file facts at once, then photo metadata loaded in the background.
// Read-only. Works only while it is shown, waits for the selection to settle, and never reads a
// file's metadata twice unless the file changed (size or modified date).

import AppKit

final class InspectorController: NSObject {
    static let width: CGFloat = 300

    let view = InspectorPane()
    private let imageView = NSImageView()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var copyButton: ThemedButton!
    /// 0.16 Glass under the Info panel.
    private var glass: GlassBacking?
    private var exifButton: ThemedButton!

    private var generation = 0 {
        didSet { latest.value = generation }
    }
    /// Same number as `generation`, readable from the background queue so stale work is skipped.
    private let latest = AtomicInt()
    private var pending: DispatchWorkItem?
    private let work = DispatchQueue(label: "find.inspector", qos: .userInitiated)
    private static let metaCache = MetaCache<[MetaSection]>(limit: 300)
    private static let thumbCache = NSCache<NSString, NSImage>()

    /// Clear All Disposable Caches.
    static func clearMemory() {
        metaCache.removeAll()
        thumbCache.removeAllObjects()
    }
    static var memoryCount: Int { return metaCache.count }

    /// What is shown now, as plain sections (also used for Copy Info).
    private var sections: [MetaSection] = []
    private var shownPath: String?
    private var shownEntry: FileEntry?
    private var image: NSImage?

    /// Get Info windows count a folder's size; the side panel doesn't (it changes with every click).
    var countsFolderSizes = false
    private let previewHeight: CGFloat

    init(previewHeight: CGFloat = 190) {
        self.previewHeight = previewHeight
        super.init()
        InspectorController.thumbCache.countLimit = 80
        build()
    }

    private func build() {
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScroller = ThemedScroller()

        copyButton = makeButton("Copy Info", self, #selector(copyInfo(_:)), tip: "Copy everything shown here as plain text")
        exifButton = makeButton("All Metadata (ExifTool)", self, #selector(runExifTool(_:)),
                                tip: "List every tag ExifTool can read (read-only)")
        for v in [imageView, scroll, copyButton, exifButton] as [NSView] {
            view.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        // Horizontal insets may give way (the pane is 0 wide while hidden); vertical ones are fixed.
        let soft: [NSLayoutConstraint] = [
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 11),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            copyButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            exifButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
        ]
        for c in soft { c.priority = NSLayoutConstraint.Priority(rawValue: 700) }
        NSLayoutConstraint.activate(soft + [
            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            imageView.heightAnchor.constraint(equalToConstant: previewHeight),
            scroll.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -4),
            copyButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            exifButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
        ])
        imageView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)
        imageView.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 100), for: .horizontal)
        imageView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 100), for: .vertical)
        for b in [copyButton!, exifButton!] {
            b.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 600), for: .horizontal)
        }
        applyTheme()
    }

    /// 0.16: glass on or off.
    func applyFinish() {
        let tm = ThemeManager.shared
        if glass == nil { glass = GlassBacking(in: view) }
        glass?.apply(base: tm.sidebar, leftLine: tm.separator)
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        view.fillColor = tm.sidebar
        view.leftLine = tm.separator
        if glass == nil { glass = GlassBacking(in: view) }
        glass?.apply(base: tm.sidebar, leftLine: tm.separator)
        copyButton.applyTheme("Copy Info")
        exifButton.applyTheme("All Metadata (ExifTool)")
        render()
    }

    // MARK: Showing a selection

    /// Called on every selection change while the inspector is visible.
    /// `folder` is shown when nothing is selected.
    func show(entries: [FileEntry], folder: String) {
        pending?.cancel()
        generation += 1
        let gen = generation
        // Wait for the selection to settle so arrowing through a folder doesn't read every file.
        let item = DispatchWorkItem { [weak self] in self?.load(entries: entries, folder: folder, gen: gen) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Hidden: stop any work and forget the content.
    func clear() {
        pending?.cancel()
        generation += 1
        sections = []
        image = nil
        shownPath = nil
        shownEntry = nil
        render()
    }

    private func load(entries: [FileEntry], folder: String, gen: Int) {
        guard gen == generation else { return }
        if entries.count > 1 {
            showMany(entries)
            return
        }
        if let e = entries.first {
            showOne(e, gen: gen)
            return
        }
        // Nothing selected: describe the folder being shown.
        var err: Int32 = 0
        if let e = FileEntry.make(path: folder, err: &err) {
            showOne(e, gen: gen)
        } else {
            sections = [MetaSection("Folder", [("Path", folder), ("Can't read", "\(Sys.errorText(err)) (code \(err))")])]
            image = nil
            render()
        }
    }

    private func showMany(_ entries: [FileEntry]) {
        shownPath = nil
        shownEntry = nil
        var s = MetaSection("Selection")
        let folders = entries.filter { $0.kind == .directory }.count
        let files = entries.count - folders
        s.add("Items", "\(entries.count) (\(files) file\(files == 1 ? "" : "s"), \(folders) folder\(folders == 1 ? "" : "s"))")
        let bytes = entries.filter { $0.size > 0 }.reduce(Int64(0)) { $0 + $1.size }
        s.add("Size", Listing.sizeText(bytes) + (folders > 0 ? " (folders not counted unless sizes are shown)" : ""))
        var kinds: [String: Int] = [:]
        for e in entries { kinds[PhotoFormats.family(e.name) ?? KindCache.shared.kind(e), default: 0] += 1 }
        for (k, n) in kinds.sorted(by: { $0.value > $1.value }).prefix(8) { s.add(k, "\(n)") }
        let photos = entries.filter { PhotoFormats.isImage($0.name) }.count
        if photos > 0 { s.add("Photos", "\(photos) (Space shows them in Quick Look)") }
        sections = [s]
        image = IconCache.shared.largeIcon(forMany: entries)
        render()
    }

    private func showOne(_ e: FileEntry, gen: Int) {
        shownPath = e.path
        shownEntry = e
        sections = [InspectorController.generalSection(e)]
        image = InspectorController.thumbCache.object(forKey: NSString(string: thumbKey(e))) ?? IconCache.shared.largeIcon(for: e)
        render()

        let wantsThumb = e.kind == .file && InspectorController.thumbCache.object(forKey: NSString(string: thumbKey(e))) == nil
        let path = e.path
        let flag = latest
        let countFolder = countsFolderSizes && e.kind == .directory
        work.async { [weak self] in
            if flag.value != gen { return }
            let d = InspectorController.details(for: e, stillWanted: { flag.value == gen })
            DispatchQueue.main.async {
                guard let s = self, s.generation == gen, s.shownPath == path else { return }
                if !s.sections.isEmpty { s.sections[0].rows += d.general }
                s.sections += d.sections
                s.render()
            }
            if countFolder && flag.value == gen {
                let r = FolderSize.compute(path, isCancelled: { flag.value != gen })
                DispatchQueue.main.async {
                    guard let s = self, s.generation == gen, s.shownPath == path, !r.cancelled, !s.sections.isEmpty else { return }
                    var t = "\(Listing.sizeText(r.bytes)) for \(r.files) file\(r.files == 1 ? "" : "s") in \(r.folders) folder\(r.folders == 1 ? "" : "s")"
                    if r.unreadable > 0 { t += " (\(r.unreadable) could not be read)" }
                    s.sections[0].rows.insert(("Size", t), at: min(3, s.sections[0].rows.count))
                    s.render()
                }
            }
            if wantsThumb && flag.value == gen {
                let img = ImageMeta.thumbnail(path: path, maxPixels: 512)
                DispatchQueue.main.async {
                    guard let s = self, let cg = img else { return }
                    let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    InspectorController.thumbCache.setObject(ns, forKey: NSString(string: s.thumbKey(e)))
                    if s.generation == gen && s.shownPath == path {
                        s.image = ns
                        s.render()
                    }
                }
            }
        }
    }

    /// Everything that needs disk reads beyond lstat: extra general rows (Added, Owner, Tags) and the
    /// photo sections (embedded metadata, ExifTool fallback, sidecar). Blocking: call off the main thread.
    static func details(for e: FileEntry, stillWanted: () -> Bool = { return true }) -> (general: [(String, String)], sections: [MetaSection]) {
        let path = e.path
        var general: [(String, String)] = []
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let owner = [attrs?[.ownerAccountName] as? String, attrs?[.groupOwnerAccountName] as? String].compactMap { $0 }
        let added = e.added > 0 ? 0 : DateAdded.get(path)
        if added > 0 { general.append(("Added", dateFormatter.string(from: Date(timeIntervalSince1970: added)))) }
        if !owner.isEmpty { general.append(("Owner", owner.joined(separator: " / "))) }
        let tags = App.ops.tagNames(path)
        if !tags.isEmpty { general.append(("Tags", tags.joined(separator: ", "))) }

        let isImage = PhotoFormats.isImage(e.name) && e.kind != .directory
        guard isImage else { return (general, []) }
        var extra: [MetaSection]
        if let c = metaCache.get(path, size: e.size, modified: e.modified) {
            extra = c
        } else {
            extra = ImageMeta.read(path: path)
            var cacheIt = true
            // macOS couldn't read it (e.g. a newer RAW format on High Sierra): ask ExifTool.
            let unreadable = !extra.contains { $0.title == "Camera" || $0.rows.contains { $0.0 == "Dimensions" } }
            let rawWithoutCamera = PhotoFormats.isRaw(path) && !extra.contains { $0.title == "Camera" }
            if (unreadable || rawWithoutCamera) && ExifTool.command != nil && stillWanted() {
                let r = ExifTool.summary(of: path)
                if !r.sections.isEmpty {
                    extra = extra.filter { $0.title != "Image" || $0.rows.contains { $0.0 == "Dimensions" } } + r.sections
                } else if let err = r.error {
                    extra.append(MetaSection("ExifTool", [("Error", err)]))
                    cacheIt = false
                }
                Log.shared?.info("Inspector: macOS could not read details of \(path); ExifTool \(r.error ?? "gave \(r.sections.count) sections")")
            }
            if cacheIt { metaCache.put(path, size: e.size, modified: e.modified, extra) }
        }
        // 0.18: ONE set of metadata - the picture's own or its sidecar's, whichever file was changed last.
        let embeddedTitle = "Description (embedded IPTC / XMP)"
        if let sc = Sidecars.find(for: path) {
            var e2: Int32 = 0
            let scMod = Sys.lstatInfo(sc, &e2)?.modified ?? 0
            if MetaPlan.current(imageModified: e.modified, sidecarModified: scMod) == .sidecar {
                var s = MetaSection("Description (sidecar \(Paths.lastComponent(sc)))")
                if let f = XMPReader.read(path: sc) {
                    if let r = f.rating { s.add("Rating", MetaFormat.stars(r)) }
                    s.add("Label", f.label)
                    s.add("Title", f.title)
                    s.add("Description", f.description)
                    if !f.keywords.isEmpty { s.add("Keywords", f.keywords.joined(separator: ", ")) }
                    if !f.creator.isEmpty { s.add("Creator", f.creator.joined(separator: ", ")) }
                    s.add("Copyright", f.rights)
                    if f.isEmpty { s.add("Contents", "No rating, label or description") }
                } else {
                    s.add("Contents", "Could not be read")
                }
                s.add("Shown because", "the sidecar was changed after the picture file (\(MetaFormat.shortDate(scMod)) / \(MetaFormat.shortDate(e.modified)))")
                extra = extra.filter { $0.title != embeddedTitle } + [s]
            } else {
                if let i = extra.index(where: { $0.title == embeddedTitle }) {
                    extra[i].add("Shown because", "the picture file was changed after its sidecar \(Paths.lastComponent(sc)) (\(MetaFormat.shortDate(e.modified)) / \(MetaFormat.shortDate(scMod)))")
                }
            }
        }
        return (general, extra)
    }

    /// All sections for one item, ready for "Copy Info as Text". Blocking: call off the main thread.
    static func allSections(for e: FileEntry) -> [MetaSection] {
        var g = generalSection(e)
        let d = details(for: e)
        g.rows += d.general
        return [g] + d.sections
    }

    /// Numbered plain-ASCII lines (L0001 ...) with a closing total line, for AutoType.
    static func numberedText(_ sections: [MetaSection]) -> String {
        let lines = sections.flatMap { $0.asciiLines }
        var out: [String] = []
        for (i, l) in lines.enumerated() { out.append(String(format: "L%04d ", i + 1) + l) }
        out.append(String(format: "L%04d END total-lines=%d", lines.count + 1, lines.count + 1))
        return out.joined(separator: "\n")
    }

    private func thumbKey(_ e: FileEntry) -> String {
        return "\(e.path)|\(e.size)|\(e.modified)"
    }

    static func generalSection(_ e: FileEntry) -> MetaSection {
        var s = MetaSection(e.kind == .directory ? "Folder" : "File")
        s.add("Name", e.name)
        if e.kind != .directory { s.add("Extension", e.ext.isEmpty ? "(none)" : e.ext) }
        s.add("Kind", PhotoFormats.family(e.name).map { "\($0), \(KindCache.shared.kind(e))" } ?? KindCache.shared.kind(e))
        if e.size >= 0 { s.add("Size", "\(Listing.sizeText(e.size)) (\(e.size) bytes)") }
        s.add("Where", Paths.parent(e.path))
        s.add("Full path", e.path)
        s.add("Created", dateText(e.created))
        s.add("Modified", dateText(e.modified))
        if e.added > 0 { s.add("Added", dateText(e.added)) }
        s.add("Permissions", "\(permissionString(e.permissions)) (\(String(e.permissions, radix: 8)))")
        if e.kind == .symlink { s.add("Points to", Sys.readLink(e.path) ?? "(unreadable)") }
        if e.isHidden { s.add("Hidden", "Yes") }
        return s
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func dateText(_ t: Double) -> String {
        if t <= 0 { return "--" }
        return InspectorController.dateFormatter.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: Drawing

    private func render() {
        let tm = ThemeManager.shared
        imageView.image = image
        exifButton.isEnabled = ExifTool.path != nil && shownEntry.map { $0.kind == .file } == true
        exifButton.toolTip = ExifTool.path == nil
            ? "ExifTool is not available (it is normally bundled inside Find.app)."
            : "List every tag ExifTool can read (read-only)"
        let out = NSMutableAttributedString(string: "")
        let para = NSMutableParagraphStyle()
        let labelWidth: CGFloat = 96
        para.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth, options: [:])]
        para.headIndent = labelWidth
        para.paragraphSpacing = 2
        let titlePara = NSMutableParagraphStyle()
        titlePara.paragraphSpacingBefore = 8
        titlePara.paragraphSpacing = 3
        if sections.isEmpty {
            out.append(NSAttributedString(string: "Nothing to show", attributes: [AttrKey.font: tm.smallFont, AttrKey.foregroundColor: tm.secondaryText]))
        }
        for sec in sections {
            // Section headings: regular weight (bold letters ran together), a size above the rows, text colour.
            out.append(NSAttributedString(string: sec.title.uppercased() + "\n",
                                          attributes: [AttrKey.font: tm.font, AttrKey.foregroundColor: tm.text, AttrKey.paragraphStyle: titlePara]))
            for (k, v) in sec.rows {
                out.append(NSAttributedString(string: k + "\t", attributes: [AttrKey.font: tm.smallFont, AttrKey.foregroundColor: tm.secondaryText, AttrKey.paragraphStyle: para]))
                out.append(NSAttributedString(string: v + "\n", attributes: [AttrKey.font: tm.smallFont, AttrKey.foregroundColor: tm.text, AttrKey.paragraphStyle: para]))
            }
        }
        textView.textStorage?.setAttributedString(out)
        textView.scroll(NSPoint.zero)
    }

    // MARK: Buttons

    @objc func copyInfo(_ sender: Any?) {
        if sections.isEmpty { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(InspectorController.numberedText(sections), forType: .string)
        copyButton.applyTheme("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.applyTheme("Copy Info") }
    }

    @objc func runExifTool(_ sender: Any?) {
        guard let e = shownEntry, e.kind == .file else { return }
        let gen = generation
        let path = e.path
        var waiting = MetaSection("ExifTool (all metadata)")
        waiting.add("Status", "Reading\u{2026}")
        sections = sections.filter { $0.title != waiting.title } + [waiting]
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = ExifTool.allMetadata(of: path)
            DispatchQueue.main.async {
                guard let s = self, s.generation == gen, s.shownPath == path else { return }
                var sec = MetaSection("ExifTool (all metadata)")
                if let err = r.error {
                    sec.add("Error", err)
                } else {
                    for line in r.lines {
                        // "[EXIF]          Make                : NIKON CORPORATION"
                        if let colon = line.range(of: " : ") {
                            let key = line[..<colon.lowerBound].split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                            sec.add(key, String(line[colon.upperBound...]))
                        } else {
                            sec.add("-", line)
                        }
                    }
                }
                s.sections = s.sections.filter { $0.title != sec.title } + [sec]
                s.render()
                Log.shared?.info("Inspector: ExifTool read \(path): \(r.error ?? "\(r.lines.count) lines")")
            }
        }
    }
}

/// Inspector background with a 1-point line on its left edge.
final class InspectorPane: FillView {
    var leftLine: NSColor? = nil {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let c = leftLine {
            c.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}
