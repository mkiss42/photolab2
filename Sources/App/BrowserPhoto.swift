// BrowserPhoto.swift
// View modes (list / thumbnails / photography), the grid's wiring, photo filters, and the photo tools:
// Contact Sheet, Compare. Read-only apart from saving a contact sheet (FileOperations).

import AppKit

extension BrowserPane {

    func setUpGrid() {
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.verticalScroller = ThemedScroller()
        gridScroll.drawsBackground = true
        gridScroll.borderType = .noBorder
        grid.autoresizingMask = [.width]
        grid.thumbSize = CGFloat(Prefs.thumbSize)
        photoBar.sizeSlider.doubleValue = Prefs.thumbSize
        grid.onSelectionChanged = { [weak self] paths in
            guard let s = self else { return }
            s.syncingSelection = true
            s.list.select(paths: paths, scroll: true)
            s.syncingSelection = false
        }
        grid.quickLook = list.quickLook
        grid.onOpen = { [weak self] e in self?.openClicked(e) }
        grid.onSpace = { [weak self] in self?.list.previewSelection() }
        grid.onBusyChanged = { [weak self] busy in
            guard let s = self else { return }
            if busy { s.thumbSpinner.startAnimation(nil) } else { s.thumbSpinner.stopAnimation(nil) }
        }
        // 0.18.16: the photo bar wraps onto more rows in a narrow pane and gets the height it needs.
        photoBar.onHeightNeeded = { [weak self] h in
            guard let s = self, s.viewMode != "list" else { return }
            if s.photoBarHeight.constant != h { s.photoBarHeight.constant = h }
        }
        // 0.18.15: I opens Edit Metadata for the selected pictures (list and thumbnails).
        let keyI: () -> Bool = { [weak self] in
            guard let s = self, !s.selectedPictures.isEmpty else { return false }
            s.editMetadata(nil)
            return true
        }
        grid.onKeyI = keyI
        list.table.onKeyI = keyI
        grid.onOptionSpace = { [weak self] in self?.list.table.onOptionSpace?() }
        grid.onEscape = { [weak self] in
            guard let s = self else { return false }
            if s.list.table.onEscape?() == true { return true }
            // PhotoLab: Esc in a contact sheet window goes back to the window before it (as Cmd-`).
            if s.isContactSheet, let w = s.window { (NSApp.delegate as? AppDelegate)?.bringPreviousWindow(before: w); return true }
            return false
        }
        grid.onRename = { [weak self] in self?.tableRename() }
        grid.onTab = { [weak self] in
            guard let s = self, s.hasPartner else { return false }
            s.switchToOtherPane(nil)
            return true
        }
        list.table.onTab = grid.onTab
        grid.onGoUp = { [weak self] in self?.tableGoUp() }
        grid.contextMenu = { [weak self] in return self?.tableContextMenu() }
        grid.registerForDraggedTypes(FileDrag.types)
        grid.dropFolder = { [weak self] in return self?.dropFolder }
        grid.onDrop = { [weak self] paths, dest, move in self?.dropFiles(paths, into: dest, move: move) }
        photoBar.onSizeChanged = { [weak self] v in
            Prefs.thumbSize = Double(v)
            self?.grid.thumbSize = v
        }
        photoBar.onFilterChanged = { [weak self] f in
            guard let s = self else { return }
            s.photoFilter = f
            s.refreshGrid()
        }
        photoBar.onContactSheet = { [weak self] in self?.makeContactSheet(nil) }
        photoBar.onCompare = { [weak self] in self?.compareSelected(nil) }
        photoBar.onRate = { [weak self] n in self?.rateSelected(n) }
        photoBar.onEditMetadata = { [weak self] in self?.editMetadata(nil) }
        photoBar.onMetadataTemplate = { [weak self] in self?.metadataTemplate(nil) }
        grid.onRate = { [weak self] n in self?.rateSelected(n) }
        grid.onColorClass = { [weak self] n in self?.colorClassSelected(n) }
        photoBar.onColorClass = { [weak self] n in self?.colorClassSelected(n) }
        photoBar.onSubfolders = { [weak self] on in self?.setIncludeSubfolders(on) }
        applyViewMode(focus: false)
    }

    // MARK: View mode

    @objc func viewButtonClicked(_ sender: Any?) {
        switch viewButtons.selectedSegment {
        case 1: setViewMode("grid")
        case 2: setViewMode("photo")
        default: setViewMode("list")
        }
    }

    func applyViewMode(focus: Bool) {
        if isFTP { return }   // an FTP pane has its own list
        // Leaving Photography mode ends Include subfolders.
        if viewMode != "photo" && (subfoldersOn || recursiveRoot != nil) {
            subfoldersOn = false
            photoBar.setSubfolders(false)
            stopRecursive(reload: true)
        }
        let gridOn = viewMode != "list"
        viewButtons.selectedSegment = viewMode == "photo" ? 2 : (gridOn ? 1 : 0)
        list.scroll.isHidden = gridOn
        gridScroll.isHidden = !gridOn
        photoBar.isHidden = !gridOn
        photoBar.setPhotoMode(viewMode == "photo")
        photoBar.layoutSubtreeIfNeeded()
        photoBarHeight.constant = gridOn ? photoBar.neededHeight : 0
        grid.photoMode = viewMode == "photo"
        // 0.18.9: ExifTool kept ready while this pane is in Photography Mode (Settings > ExifTool Behavior).
        let paneID = "\(ObjectIdentifier(self).hashValue)"
        if viewMode == "photo" { ExifToolKeeper.paneEnteredPhotography(paneID) } else { ExifToolKeeper.paneLeftPhotography(paneID) }
        // Photography mode: the thumbnail area gets a clear blue outline.
        photoOutline.isHidden = true   // PhotoLab: no frame around the thumbnails (user, 2026-11-28)
        photoOutline.needsDisplay = true
        if focus { window?.makeFirstResponder(gridOn ? grid as NSView : list.table as NSView) }
        applySetsSetting()
        if viewMode != "photo" {
            PhotoFactsStore.shared.cancel()
            photoFacts = [:]
            photoFactsFolder = ""
        }
        refreshGrid()
    }

    /// PhotoLab: sets (RAW + JPEG + XMP) are one row in the list view; the thumbnail views show files.
    func applySetsSetting() {
        let sets = viewMode == "list" && FileSets.enabled
        if list.groupSets != sets { list.groupSets = sets; list.regroup(); updateStatus() }
    }

    func setViewMode(_ m: String) {
        if viewMode == m || isContactSheet { return }
        rememberScroll()
        viewMode = m
        Prefs.viewMode = m
        Log.shared?.info("View mode: \(m)")
        applyViewMode(focus: true)
    }

    @objc func viewAsList(_ sender: Any?) { setViewMode("list") }
    @objc func viewAsThumbnails(_ sender: Any?) { setViewMode("grid") }
    @objc func viewPhotography(_ sender: Any?) { setViewMode("photo") }

    // PhotoLab: while the preview shows a picture, Cmd = / Cmd - zoom it instead.
    @objc func largerThumbnails(_ sender: Any?) { if FastPreview.shared.stepZoom(up: true) { return }; stepThumbs(1.25) }
    @objc func smallerThumbnails(_ sender: Any?) { if FastPreview.shared.stepZoom(up: false) { return }; stepThumbs(0.8) }

    private func stepThumbs(_ k: Double) {
        let v = min(480, max(80, Prefs.thumbSize * k))
        Prefs.thumbSize = v
        photoBar.sizeSlider.doubleValue = v
        grid.thumbSize = CGFloat(v)
    }

    // MARK: Grid contents

    /// The pane changed size: re-flow the thumbnails.
    func refreshGridLayout() {
        guard viewMode != "list" else { return }
        grid.relayout()
        grid.needsDisplay = true
    }

    func refreshGrid() {
        guard viewMode != "list" else { return }
        let all = list.shownRootEntries   // PhotoLab: the filter (Cmd-F) applies to the thumbnails too
        // Sidecars pair with pictures in their own folder (search results and Include subfolders mix folders).
        let withSidecar: Set<String>
        if list.resultsMode {
            withSidecar = PhotoTree.picturesWithSidecars(all)
        } else {
            let assoc = Sidecars.associate(all.filter { $0.kind != .directory }.map { $0.name })
            withSidecar = Set(assoc.pairs.keys.map { Paths.join(currentPath, $0) })
        }
        grid.sidecarPaths = withSidecar
        grid.folderRoot = recursiveRoot
        var shown: [FileEntry] = []
        var photosTotal = 0
        var waiting = 0
        var twinBadges: [String: String] = [:]
        var hiddenTwins = Set<String>()
        if viewMode == "photo" && Prefs.hideJPEGTwins {
            // 0.18.10: a JPEG with a RAW of the same name in its folder is shown as the RAW's "NEF+JPG" badge.
            var byFolder: [String: [String]] = [:]
            for e in all where e.kind == .file { byFolder[Paths.parent(e.path), default: []].append(e.name) }
            for (dir, names) in byFolder {
                for (r, j) in RawTwins.pairs(names) {
                    twinBadges[Paths.join(dir, r)] = RawTwins.badge(raw: r, jpeg: j)
                    hiddenTwins.insert(Paths.join(dir, j))
                }
            }
        }
        grid.twinBadges = twinBadges
        if viewMode == "photo" {
            loadFactsIfNeeded(all)
            photoBar.updateFormats(all.filter { !$0.isFolderLike }.map { $0.name })
            for e in all {
                if e.isFolderLike { if !isContactSheet { shown.append(e) }; continue }   // contact sheets: pictures only
                if hiddenTwins.contains(e.path) { continue }
                // Contact sheets made by Find belong with the pictures.
                if e.kind == .file && Paths.fileExtension(e.name).lowercased() == "pdf" && e.name.contains("Contact Sheet") {
                    shown.append(e)
                    continue
                }
                guard PhotoFormats.isImage(e.name) else { continue }
                photosTotal += 1
                switch photoFilter.verdict(name: e.name, hasSidecar: withSidecar.contains(e.path), facts: photoFacts[e.path]) {
                case .show: shown.append(e)
                case .waiting: waiting += 1
                case .hide: break
                }
            }
            grid.facts = photoFacts
        } else {
            shown = all
            grid.facts = [:]
        }
        grid.setEntries(shown, selected: list.selectedPaths())
        let shownKey = list.resultsMode ? "results" : currentPath
        if !list.loading && gridShownPath != shownKey {
            gridShownPath = shownKey
            grid.relayout()
            let clip = gridScroll.contentView
            var y: CGFloat = 0
            if let ps = pendingScroll, ps.path == currentPath { y = ps.y }
            pendingScroll = nil
            let maxY = max(0, grid.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
            gridScroll.reflectScrolledClipView(clip)
            if y == 0, let first = grid.selection.first { grid.scrollTo(first) }
        }
        if viewMode == "photo" {
            // Only progress while details are being read (no picture tally).
            var t = ""
            if factsProgress.total > 0 && factsProgress.done < factsProgress.total {
                t = "Reading details \(factsProgress.done)/\(factsProgress.total)"
            }
            if waiting > 0 { t += (t.isEmpty ? "" : "  \u{00B7}  ") + "\(waiting) waiting for details" }
            _ = photosTotal
            photoBar.status.stringValue = t
        } else {
            photoBar.status.stringValue = ""
        }
    }

    /// Photography mode reads rating/label/camera/lens for the folder once (remembered per file).
    private func loadFactsIfNeeded(_ all: [FileEntry]) {
        let sig = list.resultsMode ? "results:\(all.count)" : "\(currentPath):\(all.count)"
        if sig == photoFactsFolder { return }
        photoFactsFolder = sig
        if keepFactsOnReload { keepFactsOnReload = false } else { photoFacts = [:] }
        let photos = all.filter { $0.kind == .file && PhotoFormats.isImage($0.name) }
        factsProgress = (0, photos.count)
        if photos.isEmpty { return }
        PhotoFactsStore.shared.load(photos, onBatch: { [weak self] got, done, total in
            guard let s = self else { return }
            for (k, v) in got { s.photoFacts[k] = v }
            s.factsProgress = (done, total)
            if s.photoFilter.needsFacts {
                s.refreshGrid()
            } else {
                s.grid.facts = s.photoFacts
                s.grid.needsDisplay = true
                s.refreshGridStatusOnly()
            }
        }, onDone: { [weak self] in
            guard let s = self else { return }
            s.factsProgress = (s.factsProgress.total, s.factsProgress.total)
            s.refreshGrid()
        })
    }

    private func refreshGridStatusOnly() {
        photoBar.status.stringValue = factsProgress.done < factsProgress.total
            ? "Reading details \(factsProgress.done)/\(factsProgress.total)" : ""
    }

    /// Pictures the photo tools work on: the selection, or everything shown.
    private var photoTargets: [FileEntry] {
        let sel = list.selectedEntries().filter { $0.kind == .file && PhotoFormats.isImage($0.name) }
        if !sel.isEmpty { return sel }
        let source = viewMode == "list" ? list.shownRootEntries : grid.entries
        return source.filter { $0.kind == .file && PhotoFormats.isImage($0.name) }
    }

    // MARK: Compare

    @objc func compareSelected(_ sender: Any?) {
        let sel = list.selectedEntries().filter { $0.kind == .file && PhotoFormats.isImage($0.name) }
        if sel.count < 2 {
            showMessage("Select 2 to 4 pictures to compare", "Cmd-click or Shift-click pictures, then choose Compare.", style: .informational)
            return
        }
        CompareWindowController.show(Array(sel.prefix(4)))
    }

    // MARK: Contact sheet

    @objc func makeContactSheet(_ sender: Any?) {
        let pics = photoTargets
        if pics.isEmpty {
            showMessage("No pictures to put on a contact sheet", "Open a folder with pictures, or select some.", style: .informational)
            return
        }
        guard let opts = ContactSheetOptions.ask(count: pics.count, title: list.resultsMode ? "Search results" : Paths.lastComponent(currentPath)) else { return }
        let dir = list.resultsMode ? Paths.parent(pics[0].path) : currentPath
        let name = (opts.title.isEmpty ? "Contact Sheet" : opts.title + " Contact Sheet") + ".pdf"
        statusLabelText("Making contact sheet: 0 of \(ContactSheetLayout.plural(pics.count, "picture"))\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = ContactSheetMaker.render(pics, options: opts) { done in
                DispatchQueue.main.async { self?.statusLabelText("Making contact sheet: \(done) of \(pics.count)\u{2026}") }
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                guard let pdf = data else {
                    s.showMessage("The contact sheet could not be made", "Nothing was saved.")
                    s.updateStatus()
                    return
                }
                do {
                    let safeName = FileOperations.nameProblem(name) == nil ? name : "Contact Sheet.pdf"
                    let (saved, rec) = try App.ops.writeNewFile(pdf, in: dir, name: safeName)
                    s.registerUndo(rec)
                    s.refreshList(select: [saved])
                    App.log.info("Contact sheet saved: \(saved) (\(ContactSheetLayout.plural(pics.count, "picture")), \(pdf.count) bytes)")
                    let opened = ContactSheetMaker.openInAcrobat(saved)
                    s.statusLabelText("Contact sheet saved as \"\(Paths.lastComponent(saved))\" (\(Listing.sizeText(Int64(pdf.count))))" +
                                      (opened ? "" : " \u{2014} Acrobat not found, opened in the default PDF app"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak s] in s?.updateStatus() }
                } catch {
                    s.showMessage("The contact sheet could not be saved", (error as? FileOpError)?.description ?? "\(error)")
                    s.updateStatus()
                }
            }
        }
    }
}

/// Small template icons for the view buttons (drawn, so they look right in both light and dark themes).
enum ViewIcons {
    static let list: NSImage = draw { r in
        for i in 0..<3 {
            let y = r.minY + 3 + CGFloat(i) * 4
            NSBezierPath(rect: NSRect(x: r.minX + 1, y: y, width: 2, height: 2)).fill()
            NSBezierPath(rect: NSRect(x: r.minX + 5, y: y, width: 10, height: 2)).fill()
        }
    }
    static let grid: NSImage = draw { r in
        for i in 0..<2 { for j in 0..<2 {
            NSBezierPath(rect: NSRect(x: r.minX + 2 + CGFloat(i) * 7, y: r.minY + 2 + CGFloat(j) * 6, width: 5, height: 4)).fill()
        } }
    }
    static let camera: NSImage = draw { r in
        let body = NSBezierPath(roundedRect: NSRect(x: r.minX + 1, y: r.minY + 2, width: 14, height: 9), xRadius: 1.5, yRadius: 1.5)
        body.append(NSBezierPath(rect: NSRect(x: r.minX + 5, y: r.minY + 11, width: 5, height: 2)))
        body.fill()
        let lens = NSBezierPath(ovalIn: NSRect(x: r.minX + 5, y: r.minY + 3.5, width: 6, height: 6))
        NSGraphicsContext.current?.compositingOperation = .clear
        lens.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// A box with a divider line through the middle that pokes out past the top and bottom.
    static let split: NSImage = draw { r in
        let box = NSBezierPath(rect: NSRect(x: r.minX + 1.5, y: r.minY + 2.5, width: 13, height: 9))
        box.lineWidth = 1.2
        box.stroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: r.midX, y: r.minY))
        line.line(to: NSPoint(x: r.midX, y: r.maxY))
        line.lineWidth = 1.4
        line.stroke()
    }

    /// A box with a horizontal divider that pokes out past the left and right edges (stacked panes).
    static let stack: NSImage = draw { r in
        let box = NSBezierPath(rect: NSRect(x: r.minX + 2.5, y: r.minY + 1.5, width: 11, height: 11))
        box.lineWidth = 1.2
        box.stroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: r.minX, y: r.midY))
        line.line(to: NSPoint(x: r.maxX, y: r.midY))
        line.lineWidth = 1.4
        line.stroke()
    }

    private static func draw(_ body: @escaping (NSRect) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 14), flipped: false) { r in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            body(r)
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// A see-through frame drawn over another view (Photography Mode's blue outline). Never takes clicks.
final class OutlineOverlay: NSView {
    var lineWidth: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        let c = NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 1)
        c.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        path.lineWidth = lineWidth
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}


// MARK: - Ratings and metadata (Photography mode)

extension BrowserPane {
    /// The selected pictures (writing always needs an explicit selection - never "everything shown").
    var selectedPictures: [FileEntry] {
        return list.selectedEntries().filter { $0.kind == .file && PhotoFormats.isImage($0.name) && !PhotoFormats.isSidecar($0.name) }
    }

    /// Keys 0-5 / the Rate menu: star rating for the selected pictures.
    func rateSelected(_ n: Int) {
        let pics = selectedPictures
        if pics.isEmpty {
            NSSound.beep()
            photoBar.status.stringValue = "Select the pictures to rate first"
            return
        }
        var c = MetaChange()
        c.rating = n
        // The stars show at once; the write (with its checks) runs in the background.
        for p in pics {
            var f = photoFacts[p.path] ?? PhotoFacts()
            f.rating = n
            photoFacts[p.path] = f
        }
        grid.facts = photoFacts
        grid.needsDisplay = true
        FastPreview.shared.refreshCaption()
        applyMetadata(pics.map { $0.path }, c, title: n == 0 ? "Remove rating" : "Rate " + String(repeating: "\u{2605}", count: n), background: true)
    }

    /// Cmd-0..8 / the Rate menu: Photo Mechanic colour class for the selected pictures (0.14).
    func colorClassSelected(_ n: Int) {
        let pics = selectedPictures
        if pics.isEmpty {
            NSSound.beep()
            photoBar.status.stringValue = "Select the pictures first"
            return
        }
        var c = MetaChange()
        c.colorClass = n
        for p in pics {
            var f = photoFacts[p.path] ?? PhotoFacts()
            f.colorClass = n == 0 ? nil : n
            photoFacts[p.path] = f
        }
        grid.facts = photoFacts
        grid.needsDisplay = true
        FastPreview.shared.refreshCaption()
        applyMetadata(pics.map { $0.path }, c, title: n == 0 ? "Remove colour class" : "Colour class \(n) \(Prefs.colorClassNames[n - 1])", background: true)
    }

    @objc func editMetadata(_ sender: Any?) {
        let pics = selectedPictures
        if pics.isEmpty {
            NSSound.beep()
            photoBar.status.stringValue = "Select the pictures to edit first"
            return
        }
        metadataEditor?.close()
        let paths = pics.map { $0.path }
        let w = MetadataEditorWindow(mode: .selection, paths: paths, pathsNow: { paths }) { [weak self] targets, change, done in
            guard let s = self else { return }
            s.applyMetadata(targets, change, title: "Edit metadata", done: done)
        }
        metadataEditor = w
        w.showWindow(nil)
    }

    /// 0.18.15: the Metadata Template (Cmd-I): one window for the whole app, kept filled in; Apply writes
    /// to the pictures selected at that moment in the pane that opened it last.
    @objc func metadataTemplate(_ sender: Any?) {
        let w = MetadataEditorWindow.template ?? MetadataEditorWindow(mode: .template, paths: [], pathsNow: { [] }) { _, _, _ in }
        MetadataEditorWindow.template = w
        w.pathsNow = { [weak self] in self?.selectedPictures.map { $0.path } ?? [] }
        w.applyTo = { [weak self] targets, change, done in
            guard let s = self else { done(BatchReport()); return }
            s.applyMetadata(targets, change, title: "Metadata template", done: done)
        }
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    /// Write a change (FileOperations.writeMetadata: copy, write the copy, verify, swap) and show the result.
    func applyMetadata(_ paths: [String], _ c: MetaChange, title: String, background: Bool = false, done: ((BatchReport) -> Void)? = nil) {
        // 0.18.10: hidden JPEG twins get the same stars, labels and metadata (Settings > Photography).
        var all = paths
        // PhotoLab: a set row's pictures (RAW and JPEG) get the same values (its sidecar is handled with the RAW).
        if list.groupSets {
            for p in paths {
                for m in list.setMembers(of: p) where m.path != p && !PhotoFormats.isSidecar(m.name) && PhotoFormats.isImage(m.name) && !all.contains(m.path) {
                    all.append(m.path)
                }
            }
        }
        if viewMode == "photo" && Prefs.hideJPEGTwins && Prefs.twinsShareMetadata {
            all += RawTwins.twins(of: paths) { d in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []) }
        }
        if background && App.ops.metadataTool != nil {
            BackgroundMetaWriter.shared.enqueue(all.map { (image: $0, change: c) }, title: title, pane: self)
            return
        }
        applyMetadata(items: all.map { (image: $0, change: c) }, title: title, done: done)
    }

    /// 0.18: a different change per picture (Find & Replace).
    /// 0.18.7: with a small one-bar progress sheet (QuickProgress) that appears and disappears at once.
    /// A window pops up afterwards only when something failed or needs your attention; skipped files
    /// and routine notes are in Find's log.
    /// `registerUndo` false: the caller combines the Undo with its own (Find and Replace in names + metadata).
    func applyMetadata(items: [(image: String, change: MetaChange)], title: String, progress: ((Int, Int) -> Void)? = nil,
                       registerUndo: Bool = true, done: ((BatchReport) -> Void)? = nil) {
        guard App.ops.metadataTool != nil else {
            showMessage("ExifTool is not available", "Ratings and metadata are written with the ExifTool inside PhotoLab.app, which could not be started (Help > Run Photo Self-Test shows why). Nothing was written.")
            keepFactsOnReload = false
            photoFactsFolder = ""
            refreshGrid()
            return
        }
        let count = items.count
        // 0.18.7: a small sheet with one bar, at once; it goes away the moment the work ends.
        let qp = QuickProgress(title: title == "Rating" || title == "Colour class" ? "Writing" : title, total: count, parent: view.window)
        qp.show()
        let started = Date()
        // The one metadata queue: waits for background writes still running (never two on one file).
        BackgroundMetaWriter.shared.queue.async { [weak self] in
            let r = App.ops.writeMetadata(items, progress: { n, total in
                qp.set(done: n, total: total)
                if let p = progress { DispatchQueue.main.async { p(n, total) } }
            }, isCancelled: { qp.isCancelled })
            DispatchQueue.main.async {
                qp.close()
                App.log.info(String(format: "\(title): \(r.done.count) file(s) written and checked in %.1f s", Date().timeIntervalSince(started)))
                for n in r.skipped { App.log.info("Skipped: " + n) }
                for n in r.notes { App.log.info("Note: " + n) }
                self?.metadataWritten(r, title: title, registerUndo: registerUndo, done: done)
            }
        }
    }

    /// 0.18.10: a background write (ratings, colour classes) has finished.
    func backgroundWriteFinished(_ r: BatchReport, title: String, owner: Bool, stillWriting: Int) {
        if owner, let u = r.undo { registerUndo(u) }
        photoBar.status.stringValue = stillWriting > 0 ? "Writing \(stillWriting) in the background\u{2026}"
            : (r.failed.isEmpty ? "\(title): \(r.done.count) written and checked" : "\(title): \(r.failed.count) failed")
        if stillWriting > 0 && r.failed.isEmpty { return }      // the stars already show; read again at the end
        InspectorController.clearMemory()
        keepFactsOnReload = true
        photoFactsFolder = ""
        refreshGrid()
        updateInspector()
        if owner && (!r.failed.isEmpty || r.notes.contains { $0.contains("hidden") || $0.contains("could not") }) { showReport(title, r) }
    }

    /// After a metadata write: Undo, the pictures' details read again, a report only if something failed.
    private func metadataWritten(_ r: BatchReport, title: String, registerUndo: Bool, done: ((BatchReport) -> Void)?) {
        do {
            let s = self
            // 0.18.14: the steps after a write are marked, so a beachball names the right one.
            StallWatch.mark("after writing metadata: Undo for \(r.done.count) files")
            if registerUndo, let u = r.undo { s.registerUndo(u) }
            var st = "\(title): \(r.done.count) written and checked"
            if !r.skipped.isEmpty { st += ", \(r.skipped.count) skipped" }
            if r.cancelled { st += " (stopped)" }
            s.photoBar.status.stringValue = r.failed.isEmpty ? st : "\(title): \(r.failed.count) failed"
            InspectorController.clearMemory()
            // Read the details again (ratings from sidecars and files) without blanking them meanwhile.
            s.keepFactsOnReload = true
            s.photoFactsFolder = ""
            StallWatch.mark("after writing metadata: refreshing the thumbnails")
            s.refreshGrid()
            StallWatch.mark("after writing metadata: Info panel (\(s.selection.count) selected)")
            s.updateInspector()
            let attention = !r.failed.isEmpty || r.notes.contains { $0.contains("hidden") || $0.contains("could not") }
            StallWatch.mark("after writing metadata: report window")
            if attention { s.showReport(title, r) }
            done?(r)
            StallWatch.mark("(idle) after writing metadata")
        }
    }
}


// MARK: - Include subfolders (0.16)

extension BrowserPane {
    /// Photography mode: show every picture in this folder and all folders inside it, in one grid.
    /// Stays on while you move between folders in Photography mode; off when you leave the mode.
    func setIncludeSubfolders(_ on: Bool) {
        subfoldersOn = on
        photoBar.setSubfolders(on)
        if on {
            startRecursive()
        } else {
            stopRecursive(reload: true)
        }
    }

    /// After a folder has loaded (or the view mode changed): show its whole tree if asked for.
    func recursiveAfterLoad() {
        if subfoldersOn && viewMode == "photo" && !list.resultsMode && recursiveRoot == nil && !list.loading {
            startRecursive()
        }
    }

    func startRecursive() {
        guard viewMode == "photo" else { return }
        let root = currentPath
        endSearchUI(reload: false)
        recursiveToken += 1
        let token = recursiveToken
        recursiveRoot = root
        lastSummary = nil
        list.beginResults()
        searchStatus = "Including subfolders: reading\u{2026}"
        updateStatus()
        refreshGrid()
        let hidden = Prefs.showHidden
        App.log.info("Include subfolders: \(root)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sum = PhotoTree.collect(root, includeHidden: hidden,
                                        isPackage: { p, ext in KindCache.shared.isPackage(path: p, ext: ext) },
                                        isCancelled: { [weak self] in self.map { $0.recursiveToken != token } ?? true },
                                        batch: { got in
                                            DispatchQueue.main.async {
                                                guard let s = self, s.recursiveToken == token else { return }
                                                s.list.appendResults(got)
                                                s.refreshGrid()
                                            }
                                        })
            DispatchQueue.main.async {
                guard let s = self, s.recursiveToken == token else { return }
                s.list.endResults()
                var t = "\(sum.pictures) picture\(sum.pictures == 1 ? "" : "s") in \(sum.folders) folder\(sum.folders == 1 ? "" : "s") (subfolders included)"
                if sum.limited { t += " - first \(PhotoTree.maxPictures) only" }
                if !sum.problems.isEmpty { t += " - \(sum.problems.count) folder\(sum.problems.count == 1 ? "" : "s") could not be read" }
                s.searchStatus = t
                App.log.info("Include subfolders: \(t)")
                for p in sum.problems.prefix(20) { App.log.warn("Include subfolders: not read \(p.path) - \(p.reason) (code \(p.code))") }
                s.refreshGrid()
                s.updateStatus()
            }
        }
    }

    func stopRecursive(reload: Bool) {
        let was = recursiveRoot != nil
        recursiveToken += 1
        recursiveRoot = nil
        grid.folderRoot = nil
        if was && reload {
            list.load(currentPath, selectPaths: [], showHidden: Prefs.showHidden)
            updateTitle()
        }
    }
}
