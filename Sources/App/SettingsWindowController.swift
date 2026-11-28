// SettingsWindowController.swift
// Settings: General and Appearance (colors, font, size, density, accent; saved themes).

import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private struct ColorRole {
        let title: String
        let get: (Theme) -> String
        let set: (inout Theme, String) -> Void
    }

    private let roles: [ColorRole] = [
        ColorRole(title: "Background", get: { $0.background }, set: { $0.background = $1 }),
        ColorRole(title: "Sidebar and bars", get: { $0.sidebar }, set: { $0.sidebar = $1 }),
        ColorRole(title: "Alternate rows", get: { $0.alternateRow }, set: { $0.alternateRow = $1 }),
        ColorRole(title: "Text", get: { $0.text }, set: { $0.text = $1 }),
        ColorRole(title: "Secondary text", get: { $0.secondaryText }, set: { $0.secondaryText = $1 }),
        ColorRole(title: "Highlight accent", get: { $0.accent }, set: { $0.accent = $1 }),
        ColorRole(title: "Selected row", get: { $0.selection }, set: { $0.selection = $1 }),
        ColorRole(title: "Separators", get: { $0.separator }, set: { $0.separator = $1 }),
        ColorRole(title: "Warnings", get: { $0.warning }, set: { $0.warning = $1 }),
        ColorRole(title: "Errors", get: { $0.error }, set: { $0.error = $1 }),
    ]

    private var working = ThemeManager.shared.theme
    private var wells: [NSColorWell] = []
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let densityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeSlider = NSSlider(value: 13, minValue: 10, maxValue: 18, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "13 pt")
    private let darkCheck = NSButton(checkboxWithTitle: "Dark system controls (scroll bars, menus, text fields)", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Theme", target: nil, action: nil)

    private let startPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startPathLabel = NSTextField(labelWithString: "")
    private let hiddenCheck = NSButton(checkboxWithTitle: "Show hidden files", target: nil, action: nil)
    private let foldersCheck = NSButton(checkboxWithTitle: "Keep folders on top when sorting by name or kind", target: nil, action: nil)
    private let sizesCheck = NSButton(checkboxWithTitle: "Calculate folder sizes (counted in the background after the list appears)", target: nil, action: nil)
    private let qlCheck = NSButton(checkboxWithTitle: "Space bar opens macOS Quick Look instead of PhotoLab's Fast Preview", target: nil, action: nil)
    private let reopenCheck = NSButton(checkboxWithTitle: "Reopen windows where and how they were when PhotoLab was quit", target: nil, action: nil)
    private let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
    private let sidebarRows = NSStackView()
    private let recentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let frequentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let indexSettings = IndexSettingsController()
    private let storageSettings = StorageSettingsController()
    private let networkSettings = NetworkSettingsController()
    private let keysSettings = KeysSettingsController()
    let advancedSettings = AdvancedSettingsController()
    private var prefsObserver: NSObjectProtocol?
    private var sidebarObserver: NSObjectProtocol?

    private let sections = SectionList()
    private var themeObserver: NSObjectProtocol?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "PhotoLab Settings"
        // 0.17.3: resizable, and every section scrolls when it doesn't fit (nothing is cut off).
        w.minSize = NSSize(width: 720, height: 420)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = scrollWrap(buildGeneral())
        let appearance = NSTabViewItem(identifier: "appearance")
        appearance.label = "Appearance"
        appearance.view = scrollWrap(buildAppearance())
        let sidebarTab = NSTabViewItem(identifier: "sidebar")
        sidebarTab.label = "Sidebar"
        sidebarTab.view = scrollWrap(buildSidebar())
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(appearance)
        tabs.addTabViewItem(sidebarTab)
        let photoTab = NSTabViewItem(identifier: "photo")
        photoTab.label = "Photography"
        photoTab.view = scrollWrap(buildPhotography())
        tabs.addTabViewItem(photoTab)
        let keysTab = NSTabViewItem(identifier: "keys")
        keysTab.label = "Keys"
        keysTab.view = scrollWrap(keysSettings.view)
        tabs.addTabViewItem(keysTab)
        let indexTab = NSTabViewItem(identifier: "index")
        indexTab.label = "Search Index"
        indexTab.view = scrollWrap(indexSettings.view)
        tabs.addTabViewItem(indexTab)
        let storageTab = NSTabViewItem(identifier: "storage")
        storageTab.label = "Storage & Maintenance"
        storageTab.view = scrollWrap(storageSettings.view)
        tabs.addTabViewItem(storageTab)
        let networkTab = NSTabViewItem(identifier: "network")
        networkTab.label = "Network"
        networkTab.view = scrollWrap(networkSettings.view)
        tabs.addTabViewItem(networkTab)
        let advancedTab = NSTabViewItem(identifier: "advanced")
        advancedTab.label = "Advanced"
        advancedTab.view = scrollWrap(advancedSettings.view)
        tabs.addTabViewItem(advancedTab)
        storageSettings.onRebuildIndexes = { [weak self] in
            guard let s = self else { return }
            s.tabs.selectTabViewItem(withIdentifier: "index")
            s.indexSettings.rebuildAll()
        }
        // 0.17.5: each section is put in its scroll view before it is added (0.17.3/0.17.4 moved the
        // first section, General, after it was already showing, and it stayed empty).
        tabs.delegate = self
        // 0.14: sections listed down the left in the theme's colours (no system tab strip).
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        let content = FillView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        content.fillColor = ThemeManager.shared.background
        sections.setTitles(tabs.tabViewItems.map { $0.label })
        sections.onSelect = { [weak self] i in self?.tabs.selectTabViewItem(at: i) }
        for v in [sections, tabs] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sections.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sections.topAnchor.constraint(equalTo: content.topAnchor),
            sections.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sections.widthAnchor.constraint(equalToConstant: 200),
            tabs.leadingAnchor.constraint(equalTo: sections.trailingAnchor, constant: 8),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        w.contentView = content
        themeObserver = NotificationCenter.default.addObserver(forName: .findThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.restyle()
        }
        restyle()
        w.center()
        refreshGeneral()
        refreshAppearance()
        prefsObserver = NotificationCenter.default.addObserver(forName: .findPrefsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshGeneral()
        }
        sidebarObserver = NotificationCenter.default.addObserver(forName: .findVolumesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSidebar()
        }
        refreshSidebar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        if let o = prefsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = sidebarObserver { NotificationCenter.default.removeObserver(o) }
        if let o = themeObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// The window in the current theme (again after rows are rebuilt or the theme changes).
    func restyle() {
        guard let w = window else { return }
        (w.contentView as? FillView)?.fillColor = ThemeManager.shared.background
        sections.needsDisplay = true
        ThemeStyler.style(window: w)
    }

    override func showWindow(_ sender: Any?) {
        working = ThemeManager.shared.theme
        refreshAppearance()
        refreshGeneral()
        indexSettings.refresh()
        storageSettings.refresh()
        networkSettings.refresh()
        advancedSettings.refresh()
        super.showWindow(sender)
        restyle()
        advancedSettings.setVisible(tabs.selectedTabViewItem?.identifier as? String == "advanced")
        // 0.17.5: a line in the log about each section's size (in case one shows empty again).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let s = self else { return }
            s.fitSections(nil)
            for (i, sc) in s.scrolls.enumerated() {
                let f = sc.page.frame, v = sc.scroll.frame
                App.log.info("Settings section \(i + 1): page \(Int(f.width))x\(Int(f.height)), shown in \(Int(v.width))x\(Int(v.height)), \(sc.page.subviews.count) parts, in window: \(sc.scroll.window != nil ? "yes" : "no")")
            }
        }
    }

    // MARK: Scrolling sections (0.17.3)

    private final class SectionScroll {
        let scroll: NSScrollView
        let page: NSView
        let width: NSLayoutConstraint
        let height: NSLayoutConstraint
        init(scroll: NSScrollView, page: NSView, width: NSLayoutConstraint, height: NSLayoutConstraint) {
            self.scroll = scroll; self.page = page; self.width = width; self.height = height
        }
    }
    private var scrolls: [SectionScroll] = []

    /// A section in a scroll view: as big as the window allows, bigger (scrolling) when its contents need it.
    private func scrollWrap(_ page: NSView) -> NSView {
        let sv = NSScrollView(frame: page.frame)
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        let doc = FlippedView(frame: page.frame)
        doc.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(page)
        sv.documentView = doc
        let w = page.widthAnchor.constraint(equalToConstant: page.frame.width)
        let h = page.heightAnchor.constraint(equalToConstant: page.frame.height)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: doc.topAnchor),
            page.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.topAnchor.constraint(equalTo: sv.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
            w, h,
        ])
        scrolls.append(SectionScroll(scroll: sv, page: page, width: w, height: h))
        NotificationCenter.default.addObserver(self, selector: #selector(fitSections(_:)), name: NSView.frameDidChangeNotification, object: sv)
        sv.postsFrameChangedNotifications = true
        return sv
    }

    /// Each section's page: at least the visible size, and as large as what is on it.
    @objc private func fitSections(_ sender: Any?) {
        for sc in scrolls {
            let visible = sc.scroll.contentView.bounds.size
            sc.page.layoutSubtreeIfNeeded()
            var needW: CGFloat = 0, needH: CGFloat = 0
            let b = sc.page.bounds
            // Every control on the page (also ones sticking out of their row), in page coordinates.
            var stack: [NSView] = sc.page.subviews
            var seen = 0
            while let v = stack.popLast(), seen < 3000 {
                seen += 1
                if v.isHidden { continue }
                let f = v.convert(v.bounds, to: sc.page)
                needW = max(needW, f.maxX + 24)
                needH = max(needH, (sc.page.isFlipped ? f.maxY : b.maxY - f.minY) + 24)
                if !(v is NSScrollView) && !(v is NSTableView) { stack.append(contentsOf: v.subviews) }
            }
            let w = max(visible.width, needW)
            let h = max(visible.height, needH)
            if abs(sc.width.constant - w) > 0.5 { sc.width.constant = w }
            if abs(sc.height.constant - h) > 0.5 { sc.height.constant = h }
        }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        DispatchQueue.main.async { [weak self] in self?.fitSections(nil) }
        let id = tabViewItem?.identifier as? String ?? ""
        advancedSettings.setVisible(id == "advanced")
        if id == "storage" { storageSettings.refresh() }
        if id == "network" { networkSettings.refresh() }
        if id == "index" { indexSettings.refresh() }
        if id == "keys" { keysSettings.refresh() }
        if let item = tabViewItem { sections.select(tabView.indexOfTabViewItem(item)) }
        restyle()
    }

    func windowWillClose(_ notification: Notification) {
        advancedSettings.setVisible(false)
        for w in wells + classWells { w.deactivate() }
        NSColorPanel.shared.orderOut(nil)
    }

    // MARK: Photography (0.14): colour class names and colours, as in Photo Mechanic

    private var classFields: [NSTextField] = []
    private let sidecarCheck = NSButton(checkboxWithTitle: "1  XMP sidecar of RAW pictures (.xmp beside the RAW)", target: nil, action: nil)
    private let embXMPCheck = NSButton(checkboxWithTitle: "2  Embedded XMP inside RAW files", target: nil, action: nil)
    private let embIPTCCheck = NSButton(checkboxWithTitle: "3  Embedded IPTC (inside the picture file)", target: nil, action: nil)
    private var modeRadios: [NSButton] = []
    private var etModeRadios: [NSButton] = []
    private let setsCheck = NSButton(checkboxWithTitle: "List view: a RAW, its JPEG and its .xmp sidecar are one row (Ext column \u{201C}NEF+JPG+XMP\u{201D})", target: nil, action: nil)
    private let twinCheck = NSButton(checkboxWithTitle: "Photography Mode: a RAW and its JPEG are one picture (the RAW, with a \u{201C}NEF+JPG\u{201D} badge)", target: nil, action: nil)
    private let twinMetaCheck = NSButton(checkboxWithTitle: "The hidden JPEG gets the same stars, colour classes and metadata", target: nil, action: nil)
    private let thumbMemPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thumbAheadPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thumbThreadsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let memChoices = [128, 256, 512, 1024, 2048]
    private static let aheadChoices = [0, 1, 2, 4]
    private static let threadChoices = [2, 4, 6, 8]
    private let previewDelayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let delayChoices = [0, 50, 100, 150, 250, 400, 600]
    private let etCountPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let etIdlePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let idleChoices = [1, 2, 5, 10, 15, 30, 60]
    private let inPlaceFastCheck = NSButton(checkboxWithTitle: "Faster check: PhotoLab reads back the bytes it wrote (instead of ExifTool reading every value back)", target: nil, action: nil)
    private let nativeReadCheck = NSButton(checkboxWithTitle: "Read the old values with PhotoLab's own reader (sidecars, JPEG, NEF/NRW/DNG/ARW/PEF/TIFF)", target: nil, action: nil)
    private let nativeSidecarCheck = NSButton(checkboxWithTitle: "Write .xmp sidecars with PhotoLab's own writer", target: nil, action: nil)
    private let nativeDoubleCheck = NSButton(checkboxWithTitle: "Also have ExifTool read back every sidecar PhotoLab wrote itself", target: nil, action: nil)
    private var flushRadios: [NSButton] = []
    private let inPlaceCheck = NSButton(checkboxWithTitle: "Faster: change only the metadata part of the file, in place, when possible", target: nil, action: nil)
    private let stepCheck = NSButton(checkboxWithTitle: "Arrow keys step through thumbnails in whole rows, without animation", target: nil, action: nil)
    private var classWells: [NSColorWell] = []

    private func buildPhotography() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 2500))
        let intro = NSTextField(wrappingLabelWithString: "Colour classes are written into Photo Mechanic's own field (in the picture, or in the .xmp sidecar for RAW files), so Photo Mechanic shows them. Set the names and colours to match Photo Mechanic > Preferences > General; only the number is written, so names and colours here are just how PhotoLab shows them.\n\nKeys in Photography mode (thumbnails selected), as set in Settings > Keys: Cmd-1 to Cmd-8 set a colour class, Cmd-0 removes it; Ctrl-1 to Ctrl-5 (or 1 to 5) set stars, Ctrl-0 (or 0) removes them. With Cmd for colour classes, Cmd-1/2/3 don't switch views in Photography mode: use the view buttons.")
        intro.textColor = NSColor.secondaryLabelColor
        var rows: [NSView] = [intro]
        let names = Prefs.colorClassNames, colors = Prefs.colorClassColors
        for i in 0..<8 {
            let num = NSTextField(labelWithString: "\(i + 1)")
            num.translatesAutoresizingMaskIntoConstraints = false
            num.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
            well.color = ThemeManager.color(colors[i])
            well.target = self
            well.action = #selector(classChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let field = NSTextField(string: names[i])
            field.target = self
            field.action = #selector(classChanged(_:))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
            classWells.append(well)
            classFields.append(field)
            rows.append(row([num, well, field]))
        }
        let reset = NSButton(title: "Default Names and Colours", target: self, action: #selector(resetClasses(_:)))
        rows.append(reset)
        stepCheck.state = Prefs.photoArrowSteps ? .on : .off
        stepCheck.target = self
        stepCheck.action = #selector(stepChanged(_:))
        rows.append(stepCheck)
        // 0.17: the explanation on its own wrapped line, so nothing runs past the window.
        let stepNote = NSTextField(wrappingLabelWithString: "The mouse and trackpad still scroll smoothly.")
        stepNote.textColor = NSColor.secondaryLabelColor
        stepNote.font = NSFont.systemFont(ofSize: 11)
        stepNote.translatesAutoresizingMaskIntoConstraints = false
        stepNote.widthAnchor.constraint(equalToConstant: 600).isActive = true
        rows.append(stepNote)

        // 0.18.5: how metadata is written - RAW files, and how rewritten files are checked.
        func note(_ s: String, indent: Bool = true) -> NSView {
            let l = NSTextField(wrappingLabelWithString: s)
            l.textColor = NSColor.secondaryLabelColor
            l.font = NSFont.systemFont(ofSize: 11)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: indent ? 580 : 620).isActive = true
            if !indent { return l }
            let pad = NSView()
            pad.translatesAutoresizingMaskIntoConstraints = false
            pad.widthAnchor.constraint(equalToConstant: 20).isActive = true
            return row([pad, l])
        }
        // 0.18.10: RAW + JPEG pairs. PhotoLab: one heading for both kinds of sets (list rows, photo pictures).
        let setHead = NSTextField(labelWithString: "Sets: files with the same name (DSC_1.NEF, DSC_1.JPG, DSC_1.xmp)")
        setHead.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        rows.append(setHead)
        setsCheck.state = FileSets.enabled ? .on : .off
        setsCheck.target = self
        setsCheck.action = #selector(setsChanged(_:))
        rows.append(setsCheck)
        rows.append(note("Copy, move, drag, Trash and rename act on the whole set; stars and metadata go to its RAW and JPEG. A DNG is never in a set with another RAW."))
        twinCheck.state = Prefs.hideJPEGTwins ? .on : .off
        twinCheck.target = self
        twinCheck.action = #selector(twinChanged(_:))
        twinMetaCheck.state = Prefs.twinsShareMetadata ? .on : .off
        twinMetaCheck.target = self
        twinMetaCheck.action = #selector(twinChanged(_:))
        rows.append(twinCheck)
        rows.append(twinMetaCheck)
        rows.append(note("Photography Mode (plain thumbnails show every file): a JPEG with a RAW of the same name in the same folder is hidden; the RAW shows the badge. Copying, moving, dragging, Move to Trash and Delete go to both. Folders with JPEGs only show them as always. The two boxes are separate: each view has its own."))

        // 0.18.10: thumbnails - memory, preparing ahead, decoding.
        let thHead = NSTextField(labelWithString: "Thumbnails and scrolling (thumbnail view and Photography Mode)")
        thHead.font = NSFont.boldSystemFont(ofSize: 13)
        rows.append(thHead)
        rows.append(note("Each thumbnail is drawn once and kept ready in memory, so scrolling only copies finished pictures. More memory = more of a big folder stays ready (fewer redraws when you scroll back); preparing ahead = smoother fast scrolling, more work right after opening a folder.", indent: false))
        thumbMemPopup.addItems(withTitles: SettingsWindowController.memChoices.map { $0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB" })
        thumbMemPopup.selectItem(at: SettingsWindowController.memChoices.index(of: Prefs.thumbMemoryMB) ?? 2)
        thumbAheadPopup.addItems(withTitles: SettingsWindowController.aheadChoices.map { $0 == 0 ? "Only what is in view" : "\($0) screen\($0 == 1 ? "" : "s") above and below" })
        thumbAheadPopup.selectItem(at: SettingsWindowController.aheadChoices.index(of: Prefs.thumbPrepareScreens) ?? 2)
        thumbThreadsPopup.addItems(withTitles: SettingsWindowController.threadChoices.map { "\($0)" })
        thumbThreadsPopup.selectItem(at: SettingsWindowController.threadChoices.index(of: Prefs.thumbThreads) ?? 1)
        previewDelayPopup.addItems(withTitles: SettingsWindowController.delayChoices.map { $0 == 0 ? "none" : "\($0) ms" })
        previewDelayPopup.selectItem(at: SettingsWindowController.delayChoices.index(of: FastPreview.previewDelayMs) ?? 3)
        for pop in [thumbMemPopup, thumbAheadPopup, thumbThreadsPopup, previewDelayPopup] {
            pop.target = self
            pop.action = #selector(thumbChanged(_:))
        }
        rows.append(row([NSTextField(labelWithString: "Memory for ready thumbnails:"), thumbMemPopup,
                         NSTextField(labelWithString: "(512 MB holds about 2,000 at the middle size)")]))
        rows.append(row([NSTextField(labelWithString: "Prepare thumbnails ahead:"), thumbAheadPopup]))
        rows.append(row([NSTextField(labelWithString: "Pictures read at the same time:"), thumbThreadsPopup,
                         NSTextField(labelWithString: "(more = faster to fill, busier disk/network; from the next folder)")]))
        rows.append(row([NSTextField(labelWithString: "Preview delay (Space window):"), previewDelayPopup,
                         NSTextField(labelWithString: "(the preview reads only after the selection rests this long)")]))

        let head = NSTextField(labelWithString: "Writing metadata (stars, colour classes, Edit Metadata, Find and Replace)")
        head.font = NSFont.boldSystemFont(ofSize: 13)
        rows.append(head)
        rows.append(note("Where the values are written - all three by default, each with the same complete set. Writing inside a picture (2 or 3) always rewrites the whole file; a sidecar is a few KB, so writing only sidecars is the FASTEST for RAW pictures, even thousands on a slow share.", indent: false))
        for (b, on) in [(sidecarCheck, Prefs.metaSidecar), (embXMPCheck, Prefs.metaEmbeddedXMP), (embIPTCCheck, Prefs.metaEmbeddedIPTC)] {
            b.state = on ? .on : .off
            b.target = self
            b.action = #selector(placesChanged(_:))
        }
        rows.append(sidecarCheck)
        rows.append(note("On: a RAW without a sidecar gets one. Off: no new sidecars - but a sidecar that already exists is always kept up to date (Photo Mechanic reads it first, so an old one would show old values)."))
        rows.append(embXMPCheck)
        rows.append(note("The XMP inside the RAW file itself. JPEG, TIFF, PNG always get their XMP inside - it is their only XMP. Stars and colour classes exist only in XMP, so 1 or 2 always stays on."))
        rows.append(embIPTCCheck)
        rows.append(note("IPTC inside every picture that can hold it (JPEG, TIFF; RAW where its type has IPTC) - the older standard many newsroom and agency systems still read: caption, headline, keywords, credit..."))
        rows.append(note("With 2 or 3 on, RAW files are rewritten too (checked, then the previous version is removed - PhotoLab keeps no copy in the Trash); with only 1 on, RAW files are never touched.", indent: false))
        let modes: [(MetaWriteMode, String, String)] = [
            (.workingCopy, "Safest, slowest: separate working copy + picture fingerprint",
             "Each file is first copied, the copy is changed, and its picture data is compared with the original's. About 4 reads + 2 writes of every file. No safer than the next one; for comparison or a share that misbehaves."),
            (.fingerprint, "Safe (recommended): picture fingerprint, no extra copy",
             "ExifTool writes the new version straight beside the original; PhotoLab checks every value AND that the picture data is identical before it takes the original's place. About 3 reads + 1 write of every file."),
            (.fingerprintLocal, "Fingerprint on this Mac's disks; fast on network shares",
             "Full check on your own disks; on shares the fastest way below. About 1 read + 1 write on shares."),
            (.fast, "Fastest: no picture fingerprint",
             "Every value is still read back and checked, and the original stays untouched until then; only the proof that the picture data is identical is skipped. 1 read + 1 write of every file."),
        ]
        inPlaceCheck.state = Prefs.metaInPlace ? .on : .off
        inPlaceCheck.target = self
        inPlaceCheck.action = #selector(inPlaceChanged(_:))
        rows.append(inPlaceCheck)
        rows.append(note("FASTEST (off by default). NEF, NRW, DNG, ARW, PEF and TIFF: only the new XMP / IPTC block (a few KB) and the small directory entry pointing to it are written - the rest of the file, the picture included, is never written. JPEG: only when the new values fit into the space the old ones take (often after a first normal write); otherwise the normal way below. Before each change PhotoLab notes the bytes it will overwrite; it reads every value back, and puts the old bytes back if anything isn't as asked or PhotoLab stops half way (at the next start). The file isn't copied first; Undo puts the old values back."))
        inPlaceFastCheck.state = Prefs.inPlaceExifToolCheck ? .off : .on
        inPlaceFastCheck.target = self
        inPlaceFastCheck.action = #selector(inPlaceFastChanged(_:))
        rows.append(inPlaceFastCheck)
        rows.append(note("Off (default, SAFEST): after each in-place change ExifTool reads every value back - an independent check. On (FASTEST): PhotoLab reads back exactly the bytes it wrote, checks that the file's structure is sound, and (0.18.11) reads every value back with its own reader; only the second program's opinion is skipped."))
        rows.append(NSTextField(labelWithString: "Files that are rewritten (2 and 3 above, when not changed in place), how carefully:"))
        for (m, title, desc) in modes {
            let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(modeChanged(_:)))
            b.tag = m.rawValue
            b.state = Prefs.metaWriteMode == m ? .on : .off
            modeRadios.append(b)
            rows.append(b)
            rows.append(note(desc))
        }
        rows.append(note("In every mode the original stays as it was until the new version has been written and checked; Undo puts the old values back.", indent: false))

        // 0.18.11: Find's own reader and writer (no ExifTool in the common case).
        let nHead = NSTextField(labelWithString: "Speed: PhotoLab's own reader and writer")
        nHead.font = NSFont.boldSystemFont(ofSize: 13)
        rows.append(nHead)
        rows.append(note("Asking ExifTool costs time per file, even when it is kept running. PhotoLab can do the common jobs itself. Each box is its own choice; anything PhotoLab's reader or writer isn't sure of (an unusual file, a property written in two ways) goes to ExifTool automatically.", indent: false))
        let nativeBoxes: [(NSButton, Bool, String)] = [
            (nativeReadCheck, Prefs.metaNativeRead, "On (default, FASTER): before a change PhotoLab reads the current values itself (needed for Undo, and so a RAW and its sidecar get the same full set). Off (SLOWER): ExifTool reads every file first. Equally safe: these values are only read."),
            (nativeSidecarCheck, Prefs.metaNativeSidecar, "On (default, FASTER): PhotoLab writes the sidecar's new version itself, beside the old one: only the fields you changed are changed, everything else in it (Camera Raw / Capture One settings, Photo Mechanic's own fields) is kept exactly. PhotoLab then reads it back byte for byte and value for value before it takes the old one's place. Off: ExifTool writes every sidecar (slower, an independent program's work)."),
            (nativeDoubleCheck, Prefs.metaNativeDoubleCheck, "Off (default, FASTER): PhotoLab's own reading-back is the check. On (SAFEST, slower): ExifTool also reads back every sidecar PhotoLab wrote, as a second opinion, before it takes the old one's place."),
        ]
        for (box, on, desc) in nativeBoxes {
            box.state = on ? .on : .off
            box.target = self
            box.action = #selector(nativeChanged(_:))
            rows.append(box)
            rows.append(note(desc))
        }
        // 0.18.14: how each change is put on the disk - three choices.
        let fHead = NSTextField(labelWithString: "After each changed file")
        fHead.font = NSFont.boldSystemFont(ofSize: 12)
        rows.append(fHead)
        let flushes: [(FlushMode, String, String)] = [
            (.full, "Thorough flush (default, SAFEST)", "PhotoLab waits until the drive confirms each change is on the disk itself, past its own cache: safe even against a power cut a moment later. The slowest: on a local SSD about 15 ms per RAW."),
            (.normal, "Normal flush (FASTER)", "PhotoLab waits until each change is handed to the drive. A power cut in the second after a change could still lose it, or leave that file's new metadata half-written."),
            (.none, "No flush (FASTEST, as ExifTool and most apps do)", "PhotoLab goes straight on; macOS writes the changes within seconds. Safe if PhotoLab or another app stops or crashes. A power cut or macOS crash in those seconds can leave the metadata of the files changed last half-written - in the worst case such a RAW won't open until repaired (PhotoLab puts the old bytes back at its next start if its note reached the disk). The picture data itself is never written by a metadata change."),
        ]
        for (m, title, desc) in flushes {
            let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(flushChanged(_:)))
            b.tag = m.rawValue
            b.state = Prefs.metaFlush == m ? .on : .off
            flushRadios.append(b)
            rows.append(b)
            rows.append(note(desc))
        }
        rows.append(note("On a network share the server decides when the data reaches its disks, whatever is chosen here.", indent: false))

        // 0.18.9: ExifTool Behavior.
        let etHead = NSTextField(labelWithString: "ExifTool Behavior")
        etHead.font = NSFont.boldSystemFont(ofSize: 13)
        rows.append(etHead)
        rows.append(note("PhotoLab keeps ExifTool running and sends it one job after another, so it doesn't start anew (about a second on this iMac) for each job. When should it run?", indent: false))
        let etModes: [(Int, String, String)] = [
            (0, "Ready at all times: started with PhotoLab, kept until PhotoLab quits",
             "The first rating or caption of the day is as quick as the rest. Uses a little memory (about 20-30 MB per ExifTool) all day."),
            (1, "With Photography Mode (recommended): started when a pane enters Photography Mode",
             "Kept while any pane is in Photography Mode (for as long as that pane is open); stopped when the last one leaves it or closes."),
            (2, "Only when needed: started by the first metadata job",
             "The first job waits for ExifTool to start; stopped after the idle time below."),
        ]
        for (tag, title, desc) in etModes {
            let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(etModeChanged(_:)))
            b.tag = tag
            b.state = Prefs.exifToolMode == tag ? .on : .off
            etModeRadios.append(b)
            rows.append(b)
            rows.append(note(desc))
        }
        etCountPopup.addItems(withTitles: ["1", "2", "3", "4"])
        etCountPopup.selectItem(at: Prefs.exifToolCount - 1)
        etCountPopup.target = self
        etCountPopup.action = #selector(etCountChanged(_:))
        rows.append(row([NSTextField(labelWithString: "ExifTools working side by side:"), etCountPopup,
                         NSTextField(labelWithString: "(4 = fastest on this iMac's 4 cores; applies after PhotoLab restarts)")]))
        etIdlePopup.addItems(withTitles: SettingsWindowController.idleChoices.map { "\($0) min" })
        etIdlePopup.selectItem(at: SettingsWindowController.idleChoices.index(of: Prefs.exifToolIdleMinutes) ?? 2)
        etIdlePopup.target = self
        etIdlePopup.action = #selector(etIdleChanged(_:))
        rows.append(row([NSTextField(labelWithString: "Stop after no work for:"), etIdlePopup,
                         NSTextField(labelWithString: "(when nothing above keeps it running)")]))
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        v.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            intro.widthAnchor.constraint(equalToConstant: 620),
        ])
        return v
    }

    @objc private func classChanged(_ sender: Any?) {
        Prefs.colorClassNames = classFields.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
        Prefs.colorClassColors = classWells.map { ThemeManager.hex(of: $0.color) }
    }

    @objc private func placesChanged(_ sender: NSButton) {
        // Stars and colour classes need XMP somewhere: the sidecar or embedded XMP stays on.
        if sidecarCheck.state == .off && embXMPCheck.state == .off {
            (sender === sidecarCheck ? embXMPCheck : sidecarCheck).state = .on
        }
        Prefs.metaSidecar = sidecarCheck.state == .on
        Prefs.metaEmbeddedXMP = embXMPCheck.state == .on
        Prefs.metaEmbeddedIPTC = embIPTCCheck.state == .on
        App.log.info("Metadata places: sidecar \(Prefs.metaSidecar ? "ON" : "OFF"), embedded XMP \(Prefs.metaEmbeddedXMP ? "ON" : "OFF"), embedded IPTC \(Prefs.metaEmbeddedIPTC ? "ON" : "OFF")")
    }

    @objc private func etModeChanged(_ sender: NSButton) {
        Prefs.exifToolMode = sender.tag
        for b in etModeRadios { b.state = b.tag == sender.tag ? .on : .off }
        ExifToolKeeper.apply()
    }

    @objc private func etCountChanged(_ sender: NSPopUpButton) {
        Prefs.exifToolCount = sender.indexOfSelectedItem + 1
        App.log.info("ExifTool: \(Prefs.exifToolCount) side by side from the next start of PhotoLab")
    }

    @objc private func etIdleChanged(_ sender: NSPopUpButton) {
        let i = max(0, sender.indexOfSelectedItem)
        Prefs.exifToolIdleMinutes = SettingsWindowController.idleChoices[min(i, SettingsWindowController.idleChoices.count - 1)]
        ExifToolKeeper.apply()
    }

    @objc private func nativeChanged(_ sender: NSButton) {
        let on = sender.state == .on
        if sender === nativeReadCheck { Prefs.metaNativeRead = on }
        if sender === nativeSidecarCheck { Prefs.metaNativeSidecar = on }
        if sender === nativeDoubleCheck { Prefs.metaNativeDoubleCheck = on }
        App.log.info("Metadata: PhotoLab's own reader \(Prefs.metaNativeRead ? "ON" : "OFF"), own sidecar writer \(Prefs.metaNativeSidecar ? "ON" : "OFF"), ExifTool double check \(Prefs.metaNativeDoubleCheck ? "ON" : "OFF")")
    }

    @objc private func flushChanged(_ sender: NSButton) {
        guard let m = FlushMode(rawValue: sender.tag) else { return }
        for b in flushRadios { b.state = b === sender ? .on : .off }
        Prefs.metaFlush = m
        App.log.info("Metadata: after each changed file - " + ["thorough flush", "normal flush", "no flush"][m.rawValue])
    }

    @objc private func inPlaceFastChanged(_ sender: NSButton) {
        Prefs.inPlaceExifToolCheck = sender.state == .off
        App.log.info("Metadata in place: check by \(Prefs.inPlaceExifToolCheck ? "ExifTool" : "PhotoLab (bytes)")")
    }

    @objc private func inPlaceChanged(_ sender: NSButton) {
        Prefs.metaInPlace = sender.state == .on
        App.log.info("Metadata: change in place \(Prefs.metaInPlace ? "ON" : "OFF")")
    }

    @objc private func modeChanged(_ sender: NSButton) {
        guard let m = MetaWriteMode(rawValue: sender.tag) else { return }
        Prefs.metaWriteMode = m
        for b in modeRadios { b.state = b.tag == m.rawValue ? .on : .off }
        App.log.info("Metadata: write mode \(m.rawValue)")
    }

    @objc private func setsChanged(_ sender: NSButton) {
        FileSets.enabled = setsCheck.state == .on
        App.log.info("List view: sets as one row \(FileSets.enabled ? "ON" : "OFF")")
        for w in (NSApp.delegate as? AppDelegate)?.windowControllers ?? [] {
            for p in w.panes { p.applySetsSetting() }
        }
    }

    @objc private func twinChanged(_ sender: NSButton) {
        Prefs.hideJPEGTwins = twinCheck.state == .on
        Prefs.twinsShareMetadata = twinMetaCheck.state == .on
        App.log.info("Photography: RAW + JPEG as one \(Prefs.hideJPEGTwins ? "ON" : "OFF"), JPEG gets the metadata \(Prefs.twinsShareMetadata ? "ON" : "OFF")")
        NotificationCenter.default.post(name: .findPrefsChanged, object: nil)
    }

    @objc private func thumbChanged(_ sender: NSPopUpButton) {
        Prefs.thumbMemoryMB = SettingsWindowController.memChoices[max(0, thumbMemPopup.indexOfSelectedItem)]
        Prefs.thumbPrepareScreens = SettingsWindowController.aheadChoices[max(0, thumbAheadPopup.indexOfSelectedItem)]
        Prefs.thumbThreads = SettingsWindowController.threadChoices[max(0, thumbThreadsPopup.indexOfSelectedItem)]
        UserDefaults.standard.set(SettingsWindowController.delayChoices[max(0, previewDelayPopup.indexOfSelectedItem)], forKey: "previewDelayMs")
        ThumbnailGrid.applyMemorySetting()
        App.log.info("Thumbnails: \(Prefs.thumbMemoryMB) MB, ahead \(Prefs.thumbPrepareScreens) screens, \(Prefs.thumbThreads) at a time")
    }

    @objc private func stepChanged(_ sender: NSButton) {
        Prefs.photoArrowSteps = sender.state == .on
        App.log.info("Photography: arrow keys in whole rows \(Prefs.photoArrowSteps ? "ON" : "OFF")")
    }

    @objc private func resetClasses(_ sender: Any?) {
        Prefs.colorClassNames = Prefs.defaultColorClassNames
        Prefs.colorClassColors = Prefs.defaultColorClassColors
        for i in 0..<8 {
            classFields[i].stringValue = Prefs.defaultColorClassNames[i]
            classWells[i].color = ThemeManager.color(Prefs.defaultColorClassColors[i])
        }
    }

    // MARK: General

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    private func buildGeneral() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))
        startPopup.addItems(withTitles: ["Home folder", "Last folder used", "A folder I choose\u{2026}"])
        startPopup.target = self
        startPopup.action = #selector(startChanged(_:))
        startPathLabel.textColor = NSColor.secondaryLabelColor
        startPathLabel.lineBreakMode = .byTruncatingMiddle
        hiddenCheck.target = self
        hiddenCheck.action = #selector(hiddenChanged(_:))
        foldersCheck.target = self
        foldersCheck.action = #selector(foldersChanged(_:))
        sizesCheck.target = self
        sizesCheck.action = #selector(sizesChanged(_:))
        qlCheck.target = self
        qlCheck.action = #selector(qlChanged(_:))
        reopenCheck.target = self
        reopenCheck.action = #selector(reopenChanged(_:))
        let note = NSTextField(wrappingLabelWithString: "Saved previews, caches and clean-up: see Storage & Maintenance.\n\nReopened windows go back to their position, display and desktop, with their panes, tabs, view modes, sidebar and Info panel. If a display is gone they move to the main one. macOS has no official way for an app to choose a window's desktop; if this macOS refuses, the window opens on the current desktop.\n\nNew windows open in screen quarters: top-left, then top-right, bottom-left, bottom-right. If a window has been moved or resized, the next one opens top-left. With all four taken, a new window reuses the oldest window's quarter.\n\nRemoving an item moves it to the Trash. Only where there is no Trash (most shared volumes), or with File > Delete Immediately, does PhotoLab delete permanently - and only after you confirm, as in Finder. Nothing is ever overwritten.")
        note.textColor = NSColor.secondaryLabelColor
        let stack = NSStackView(views: [
            row([NSTextField(labelWithString: "New windows open at:"), startPopup]),
            startPathLabel,
            hiddenCheck,
            foldersCheck,
            sizesCheck,
            qlCheck,
            reopenCheck,
            note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        v.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -24),
            note.widthAnchor.constraint(equalToConstant: 520),
            startPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        return v
    }

    private func refreshGeneral() {
        let mode = Prefs.d.string(forKey: Prefs.Key.startMode) ?? "home"
        startPopup.selectItem(at: mode == "last" ? 1 : (mode == "custom" ? 2 : 0))
        startPathLabel.stringValue = mode == "custom" ? (Prefs.d.string(forKey: Prefs.Key.startPath) ?? "") : ""
        startPathLabel.isHidden = mode != "custom"
        hiddenCheck.state = Prefs.showHidden ? .on : .off
        foldersCheck.state = Prefs.foldersFirst ? .on : .off
        sizesCheck.state = Prefs.calculateFolderSizes ? .on : .off
        qlCheck.state = Prefs.spaceOpensQuickLook ? .on : .off
        reopenCheck.state = Prefs.reopenWindows ? .on : .off
    }

    @objc private func reopenChanged(_ sender: NSButton) {
        Prefs.reopenWindows = sender.state == .on
        App.log.info("Reopen windows at start: \(Prefs.reopenWindows ? "ON" : "OFF")")
    }

    @objc private func qlChanged(_ sender: NSButton) {
        Prefs.spaceOpensQuickLook = sender.state == .on
    }

    @objc private func sizesChanged(_ sender: NSButton) {
        Prefs.calculateFolderSizes = sender.state == .on
    }

    // MARK: Sidebar

    func showSidebarTab() {
        tabs.selectTabViewItem(withIdentifier: "sidebar")
    }

    private func buildSidebar() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))
        sidebarRows.orientation = .vertical
        sidebarRows.alignment = .leading
        sidebarRows.spacing = 6
        recentPopup.addItems(withTitles: (0...20).map { "\($0)" })
        recentPopup.target = self
        recentPopup.action = #selector(recentCountChanged(_:))
        frequentPopup.addItems(withTitles: (0...10).map { "\($0)" })
        frequentPopup.target = self
        frequentPopup.action = #selector(frequentCountChanged(_:))
        let reset = NSButton(title: "Reset Sidebar", target: self, action: #selector(resetSidebar(_:)))
        let note = NSTextField(wrappingLabelWithString: "Tick a section to show it; use the arrows to change the order. In the sidebar, click a section's title to fold it away, and right-click a favourite to move or remove it.")
        note.textColor = NSColor.secondaryLabelColor
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Sections:"),
            sidebarRows,
            row([NSTextField(labelWithString: "Recent places shown:"), recentPopup]),
            row([NSTextField(labelWithString: "Frequent places shown:"), frequentPopup]),
            reset,
            note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        v.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -24),
            note.widthAnchor.constraint(equalToConstant: 520),
        ])
        return v
    }

    private func refreshSidebar() {
        for v in sidebarRows.arrangedSubviews {
            sidebarRows.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let order = Prefs.sidebarOrder
        let hidden = Prefs.sidebarHidden
        for (i, sec) in order.enumerated() {
            let check = NSButton(checkboxWithTitle: Prefs.sectionTitles[sec] ?? sec, target: self, action: #selector(sectionToggled(_:)))
            check.identifier = itemID(sec)
            check.state = hidden.contains(sec) ? .off : .on
            check.translatesAutoresizingMaskIntoConstraints = false
            check.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let up = NSButton(title: "\u{2191}", target: self, action: #selector(sectionUp(_:)))
            up.identifier = itemID(sec)
            up.isEnabled = i > 0
            let down = NSButton(title: "\u{2193}", target: self, action: #selector(sectionDown(_:)))
            down.identifier = itemID(sec)
            down.isEnabled = i < order.count - 1
            sidebarRows.addArrangedSubview(row([check, up, down]))
        }
        recentPopup.selectItem(at: Prefs.recentCount)
        frequentPopup.selectItem(at: Prefs.frequentCount)
        restyle()
    }

    @objc private func sectionToggled(_ sender: NSButton) {
        guard let sec = sender.identifier?.rawValue else { return }
        var h = Prefs.sidebarHidden
        if sender.state == .on { h.remove(sec) } else { h.insert(sec) }
        Prefs.sidebarHidden = h
    }

    private func moveSection(_ sec: String, by delta: Int) {
        var o = Prefs.sidebarOrder
        guard let i = o.index(of: sec) else { return }
        let j = i + delta
        guard j >= 0 && j < o.count else { return }
        o.swapAt(i, j)
        Prefs.sidebarOrder = o
    }

    @objc private func sectionUp(_ sender: NSButton) {
        if let sec = sender.identifier?.rawValue { moveSection(sec, by: -1) }
    }

    @objc private func sectionDown(_ sender: NSButton) {
        if let sec = sender.identifier?.rawValue { moveSection(sec, by: 1) }
    }

    @objc private func recentCountChanged(_ sender: NSPopUpButton) {
        Prefs.recentCount = sender.indexOfSelectedItem
    }

    @objc private func frequentCountChanged(_ sender: NSPopUpButton) {
        Prefs.frequentCount = sender.indexOfSelectedItem
    }

    @objc private func resetSidebar(_ sender: Any?) {
        Prefs.sidebarOrder = Prefs.allSections
        Prefs.sidebarHidden = []
        Prefs.sidebarCollapsed = []
        Prefs.recentCount = 6
        Prefs.frequentCount = 5
    }

    @objc private func startChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            Prefs.d.set("last", forKey: Prefs.Key.startMode)
        case 2:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let p = panel.url?.path {
                Prefs.d.set("custom", forKey: Prefs.Key.startMode)
                Prefs.d.set(p, forKey: Prefs.Key.startPath)
            }
        default:
            Prefs.d.set("home", forKey: Prefs.Key.startMode)
        }
        refreshGeneral()
    }

    @objc private func hiddenChanged(_ sender: NSButton) {
        Prefs.showHidden = sender.state == .on
    }

    @objc private func foldersChanged(_ sender: NSButton) {
        Prefs.foldersFirst = sender.state == .on
    }

    // MARK: Appearance

    private func buildAppearance() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))
        themePopup.target = self
        themePopup.action = #selector(themeChosen(_:))
        let saveAs = NSButton(title: "Save As", target: self, action: #selector(saveThemeAs(_:)))
        deleteButton.target = self
        deleteButton.action = #selector(deleteTheme(_:))
        let reset = NSButton(title: "Reset to Graphite", target: self, action: #selector(resetTheme(_:)))

        var leftRows: [NSView] = []
        var rightRows: [NSView] = []
        for (i, r) in roles.enumerated() {
            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
            well.tag = i
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.isContinuous = true
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            wells.append(well)
            let label = NSTextField(labelWithString: r.title)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let rv = row([label, well])
            if i < 5 { leftRows.append(rv) } else { rightRows.append(rv) }
        }
        let left = NSStackView(views: leftRows)
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        let right = NSStackView(views: rightRows)
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        let colors = row([left, right])
        colors.spacing = 40
        colors.alignment = .top

        fontPopup.addItem(withTitle: "System Font")
        fontPopup.menu?.addItem(NSMenuItem.separator())
        fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.numberOfTickMarks = 9
        sizeSlider.allowsTickMarkValuesOnly = true
        sizeSlider.isContinuous = true
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        densityPopup.addItems(withTitles: ["Compact", "Regular", "Spacious"])
        densityPopup.target = self
        densityPopup.action = #selector(densityChanged(_:))
        darkCheck.target = self
        darkCheck.action = #selector(darkChanged(_:))

        let hint = NSTextField(wrappingLabelWithString: "Changes apply to all PhotoLab windows immediately and are remembered. Save As keeps a named copy you can switch back to.")
        hint.textColor = NSColor.secondaryLabelColor

        // 0.16: the finish - Depth, Glow, Glass, Dim. All at 0 = the flat look of earlier versions.
        var finishRows: [NSView] = []
        let finishTitles = ["Depth (light on bars, shadows)", "Glow (selection, focused pane)", "Glass (sidebar, Info panel)", "Dim panes not in use",
                            "Glass (file lists, thumbnails)"]
        let finishValues = [Prefs.finishDepth, Prefs.finishGlow, Prefs.finishGlass, Prefs.finishDim, Prefs.finishContentGlass]
        for i in 0..<5 {
            let label = NSTextField(labelWithString: finishTitles[i])
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 210).isActive = true
            let s = NSSlider(value: Double(finishValues[i]), minValue: 0, maxValue: i == 3 ? 60 : 100, target: self, action: #selector(finishChanged(_:)))
            s.tag = i
            s.isContinuous = true
            s.translatesAutoresizingMaskIntoConstraints = false
            s.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let value = NSTextField(labelWithString: "\(finishValues[i])")
            value.translatesAutoresizingMaskIntoConstraints = false
            value.widthAnchor.constraint(equalToConstant: 36).isActive = true
            finishSliders.append(s)
            finishLabels.append(value)
            finishRows.append(row([label, s, value]))
        }
        let flat = NSButton(title: "All to 0 (flat)", target: self, action: #selector(finishFlat(_:)))
        let standard = NSButton(title: "Standard", target: self, action: #selector(finishStandard(_:)))
        let speed = NSButton(title: "Test Drawing Speed", target: self, action: #selector(testDrawingSpeed(_:)))
        speed.toolTip = "Scrolls the front PhotoLab window's list or thumbnails by itself for a moment and times the drawing"
        finishRows.append(row([flat, standard, speed]))
        // 0.17.1: macOS's own setting turns every see-through effect into plain grey.
        if Finish.systemReducesTransparency {
            let warn = NSTextField(wrappingLabelWithString: "Glass can't show the desktop on this Mac: \"Reduce transparency\" is on in System Preferences > Accessibility > Display (it makes every see-through panel plain grey). Turn it off there to see Glass.")
            warn.textColor = ThemeManager.shared.warning
            warn.translatesAutoresizingMaskIntoConstraints = false
            warn.widthAnchor.constraint(equalToConstant: 520).isActive = true
            finishRows.append(warn)
        }
        let finish = NSStackView(views: finishRows)
        finish.orientation = .vertical
        finish.alignment = .leading
        finish.spacing = 6

        let stack = NSStackView(views: [
            row([NSTextField(labelWithString: "Theme:"), themePopup, saveAs, deleteButton, reset]),
            colors,
            row([NSTextField(labelWithString: "Font:"), fontPopup]),
            row([NSTextField(labelWithString: "Text size:"), sizeSlider, sizeLabel]),
            row([NSTextField(labelWithString: "Row spacing:"), densityPopup]),
            darkCheck,
            finish,
            hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        v.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
            hint.widthAnchor.constraint(equalToConstant: 520),
        ])
        return v
    }

    private func refreshThemePopup() {
        themePopup.removeAllItems()
        let all = App.themes.allThemes()
        themePopup.addItems(withTitles: all.map { $0.name })
        if themePopup.item(withTitle: working.name) == nil {
            themePopup.addItem(withTitle: working.name)
        }
        themePopup.selectItem(withTitle: working.name)
        let isPreset = Theme.presets.contains { $0.name == working.name }
        let isSaved = App.themes.savedThemes().contains { $0.name == working.name }
        deleteButton.isEnabled = !isPreset && isSaved
    }

    /// Put every control back in step with `working`.
    private var finishSliders: [NSSlider] = []
    private var finishLabels: [NSTextField] = []

    private func setFinish(_ v: [Int]) {
        Prefs.finishDepth = v[0]
        Prefs.finishGlow = v[1]
        Prefs.finishGlass = v[2]
        Prefs.finishDim = v[3]
        Prefs.finishContentGlass = v[4]
        for i in 0..<min(5, finishSliders.count) {
            finishSliders[i].doubleValue = Double(v[i])
            finishLabels[i].stringValue = "\(v[i])"
        }
        NotificationCenter.default.post(name: .findFinishChanged, object: nil)
    }

    @objc private func finishChanged(_ sender: NSSlider) {
        var v = [Prefs.finishDepth, Prefs.finishGlow, Prefs.finishGlass, Prefs.finishDim, Prefs.finishContentGlass]
        guard sender.tag >= 0 && sender.tag < 5 else { return }
        v[sender.tag] = Int(sender.doubleValue.rounded())
        setFinish(v)
        if let e = NSApp.currentEvent, e.type == .leftMouseUp {
            App.log.info("Finish: depth \(v[0]), glow \(v[1]), glass \(v[2]), dim \(v[3]), glass behind lists \(v[4])")
        }
    }

    @objc private func finishFlat(_ sender: Any?) {
        setFinish([0, 0, 0, 0, 0])
        App.log.info("Finish: all 0 (flat)")
    }

    @objc private func finishStandard(_ sender: Any?) {
        setFinish([60, 40, 60, 20, 0])
        App.log.info("Finish: standard (60, 40, 60, 20, 0)")
    }

    /// Scroll the front Find window's list or thumbnails by itself and time the drawing.
    @objc private func testDrawingSpeed(_ sender: Any?) {
        guard let c = NSApp.orderedWindows.compactMap({ $0.windowController as? BrowserWindowController }).first else {
            let a = ThemedAlert()
            a.messageText = "Open a PhotoLab window first"
            a.informativeText = "The test scrolls a PhotoLab window's list or thumbnails (best: a big folder in Photography mode)."
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }
        let r = c.pane.drawingSpeedTest()
        let fps = r.ms > 0 ? Double(r.frames) * 1000 / r.ms : 0
        let line = "Drawing speed: \(r.frames) steps in \(Int(r.ms)) ms = \(Int(fps)) frames per second (\(r.what); depth \(Prefs.finishDepth), glow \(Prefs.finishGlow), glass \(Prefs.finishGlass), dim \(Prefs.finishDim))"
        App.log.info(line)
        let a = ThemedAlert()
        a.alertStyle = fps >= 30 ? .informational : .warning
        a.messageText = fps >= 50 ? "Smooth: \(Int(fps)) frames per second" : (fps >= 30 ? "Fine: \(Int(fps)) frames per second" : "Slow: \(Int(fps)) frames per second")
        a.informativeText = line + (fps < 30 ? "\n\nTry lowering Glass first, then Depth: they cost the most. All to 0 draws as before 0.16." : "")
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func refreshAppearance() {
        refreshThemePopup()
        for (i, r) in roles.enumerated() where i < wells.count {
            wells[i].color = ThemeManager.color(r.get(working))
        }
        if working.fontFamily.isEmpty || fontPopup.item(withTitle: working.fontFamily) == nil {
            fontPopup.selectItem(at: 0)
        } else {
            fontPopup.selectItem(withTitle: working.fontFamily)
        }
        sizeSlider.doubleValue = working.fontSize
        sizeLabel.stringValue = "\(Int(working.fontSize)) pt"
        densityPopup.selectItem(at: working.density)
        darkCheck.state = working.dark ? .on : .off
    }

    /// Editing a preset turns it into "Custom" so the preset itself stays as shipped.
    private func markEdited() {
        if Theme.presets.contains(where: { $0.name == working.name }) {
            working.name = "Custom"
        }
    }

    private func applyWorking() {
        ThemeManager.shared.apply(working)
        refreshThemePopup()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard sender.tag >= 0 && sender.tag < roles.count else { return }
        markEdited()
        roles[sender.tag].set(&working, ThemeManager.hex(of: sender.color))
        applyWorking()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        markEdited()
        working.fontFamily = sender.indexOfSelectedItem == 0 ? "" : (sender.titleOfSelectedItem ?? "")
        applyWorking()
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        let v = Double(Int(sender.doubleValue.rounded()))
        sizeLabel.stringValue = "\(Int(v)) pt"
        if v == working.fontSize { return }
        markEdited()
        working.fontSize = v
        applyWorking()
    }

    @objc private func densityChanged(_ sender: NSPopUpButton) {
        markEdited()
        working.density = max(0, min(2, sender.indexOfSelectedItem))
        applyWorking()
    }

    @objc private func darkChanged(_ sender: NSButton) {
        markEdited()
        working.dark = sender.state == .on
        applyWorking()
    }

    @objc private func themeChosen(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        if let t = App.themes.allThemes().first(where: { $0.name == name }) {
            working = t
            applyWorking()
            refreshAppearance()
        }
    }

    @objc private func saveThemeAs(_ sender: Any?) {
        let a = ThemedAlert()
        a.messageText = "Save theme as"
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = working.name == "Custom" ? "" : working.name
        a.accessoryView = field
        a.window.initialFirstResponder = field
        if a.runModal() != .alertFirstButtonReturn { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "Custom" || Theme.presets.contains(where: { $0.name == name }) {
            let e = ThemedAlert()
            e.messageText = "Please choose a different name"
            e.informativeText = "The built-in theme names and \"Custom\" are reserved."
            e.runModal()
            return
        }
        working.name = name
        if App.themes.save(working) {
            applyWorking()
            refreshAppearance()
        } else {
            let e = ThemedAlert()
            e.messageText = "The theme could not be saved"
            e.runModal()
        }
    }

    @objc private func deleteTheme(_ sender: Any?) {
        let name = working.name
        let a = ThemedAlert()
        a.messageText = "Delete the theme \"\(name)\"?"
        a.informativeText = "Only the saved theme is removed. PhotoLab switches back to Graphite."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        App.themes.delete(named: name)
        working = Theme.graphite
        applyWorking()
        refreshAppearance()
    }

    @objc private func resetTheme(_ sender: Any?) {
        working = Theme.graphite
        applyWorking()
        refreshAppearance()
    }
}
