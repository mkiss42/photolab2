// PhotoBar.swift
// The bar above the thumbnails: size slider (thumbnail and photography views) and, in photography
// mode, the filters and photo tools.
// 0.17 filters: file types present in the folder (menu), star rating (click the stars), Photo Mechanic
// colour classes (click the dots); camera or lens text. The sidecar filter is gone.

import AppKit

final class PhotoBar: FillView, NSTextFieldDelegate {
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The extension of each Formats menu item after "All types".
    private var formatExts: [String] = []
    let stars = StarFilterView(frame: NSRect(x: 0, y: 0, width: 96, height: 18))
    let dots = ColorDotsFilterView(frame: NSRect(x: 0, y: 0, width: 8 * 15 + 4, height: 18))
    let textField = NSTextField(string: "")
    let sizeSlider = NSSlider(value: 160, minValue: 80, maxValue: 480, target: nil, action: nil)
    let status = makeLabel("")
    private var buttons: [NSButton] = []
    private var filterViews: [NSView] = []
    /// 0.18.16: the bar flows - its items go left to right and wrap onto more rows when the pane is
    /// narrow (0.18.15 and before: one row, the rest cut off). The pane gives it the height it asks for.
    private var items: [NSView] = []
    private var fixedWidth: [ObjectIdentifier: CGFloat] = [:]
    private(set) var neededHeight: CGFloat = 32
    var onHeightNeeded: ((CGFloat) -> Void)?

    var onFilterChanged: ((PhotoFilter) -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?
    var onContactSheet: (() -> Void)?
    var onCompare: (() -> Void)?
    /// Rate the selected pictures (0 = no rating, 1-5 stars).
    var onRate: ((Int) -> Void)?
    /// Photo Mechanic colour class for the selected pictures (0 = none, 1-8). 0.14.
    var onColorClass: ((Int) -> Void)?
    var onEditMetadata: (() -> Void)?
    var onMetadataTemplate: (() -> Void)?
    /// Include subfolders on/off (0.16).
    var onSubfolders: ((Bool) -> Void)?
    private let subfoldersButton = NSButton(checkboxWithTitle: "Subfolders", target: nil, action: nil)
    private let rateMenu = NSPopUpButton(frame: .zero, pullsDown: true)


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func build() {
        formatPopup.addItem(withTitle: "All types")
        formatPopup.target = self
        formatPopup.action = #selector(filterChanged(_:))
        formatPopup.controlSize = .small
        formatPopup.font = NSFont.systemFont(ofSize: 11)
        formatPopup.toolTip = "Show one file type (only the types in this folder are listed)"
        for v in [stars, dots] as [NSView] { fixedWidth[ObjectIdentifier(v)] = v.frame.width }
        stars.onChange = { [weak self] in self?.filterChanged(nil) }
        dots.onChange = { [weak self] in self?.filterChanged(nil) }
        textField.placeholderString = "Camera or lens"
        textField.controlSize = .small
        textField.font = NSFont.systemFont(ofSize: 11)
        textField.delegate = self
        textField.target = self
        textField.action = #selector(filterChanged(_:))
        fixedWidth[ObjectIdentifier(textField)] = 120
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.controlSize = .small
        fixedWidth[ObjectIdentifier(sizeSlider)] = 110
        sizeSlider.toolTip = "Thumbnail size (Cmd-Plus / Cmd-Minus)"
        // Proper push buttons (they read as buttons, not text).
        let sheet = NSButton(title: "Contact Sheet", target: self, action: #selector(contactSheet(_:)))
        sheet.toolTip = "Save the shown (or selected) pictures as a PDF contact sheet"
        let compare = NSButton(title: "Compare", target: self, action: #selector(compare(_:)))
        compare.toolTip = "Show 2 to 4 selected pictures side by side"
        for b in [sheet, compare] {
            b.bezelStyle = .texturedRounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
        }
        // Rate: a pull-down (the title stays "Rate"); keys 0-5 do the same in the thumbnails.
        rateMenu.addItem(withTitle: "Rate")
        let rateTitles = ["No rating", "\u{2605}", "\u{2605}\u{2605}", "\u{2605}\u{2605}\u{2605}", "\u{2605}\u{2605}\u{2605}\u{2605}", "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}"]
        for (i, t) in rateTitles.enumerated() {
            rateMenu.addItem(withTitle: "\(t)   (Ctrl-\(i))")
            rateMenu.lastItem?.tag = i
            rateMenu.lastItem?.target = self
            rateMenu.lastItem?.action = #selector(rate(_:))
        }
        rateMenu.menu?.addItem(NSMenuItem.separator())
        rateMenu.addItem(withTitle: "No colour class   (Cmd-0)")
        rateMenu.lastItem?.tag = 100
        rateMenu.lastItem?.target = self
        rateMenu.lastItem?.action = #selector(colorClass(_:))
        for i in 1...8 {
            rateMenu.addItem(withTitle: "\(i)  \(Prefs.colorClassNames[i - 1])   (Cmd-\(i))")
            rateMenu.lastItem?.tag = 100 + i
            rateMenu.lastItem?.target = self
            rateMenu.lastItem?.action = #selector(colorClass(_:))
            if let c = Prefs.colorClassColor(i) { rateMenu.lastItem?.image = PhotoBar.swatch(c) }
        }
        rateMenu.toolTip = "Star rating (Ctrl-0 to 5, or 0 to 5) and Photo Mechanic colour class (Cmd-0 to 8) for the selected pictures"
        // 0.18.15: the two metadata windows (no "..." in button names).
        let meta = NSButton(title: "Edit Metadata", target: self, action: #selector(editMetadata(_:)))
        meta.toolTip = "The selected pictures' own caption, keywords and other IPTC fields, to edit (key: I)"
        let template = NSButton(title: "Metadata Template", target: self, action: #selector(metadataTemplate(_:)))
        template.toolTip = "Your template, kept from last time: write its ticked fields to the selected pictures (Cmd-I)"
        for b in [rateMenu, meta, template] as [NSButton] {
            b.bezelStyle = .texturedRounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
        }
        buttons = [sheet, compare, meta, template]
        subfoldersButton.target = self
        subfoldersButton.action = #selector(subfoldersClicked(_:))
        subfoldersButton.controlSize = .small
        subfoldersButton.font = NSFont.systemFont(ofSize: 11)
        subfoldersButton.toolTip = "Show the pictures of all folders inside this one too, in one grid (each caption names its folder)"
        filterViews = [subfoldersButton, formatPopup, stars, dots, textField, rateMenu, template, meta, sheet, compare]
        status.lineBreakMode = .byTruncatingTail
        items = [sizeSlider] + filterViews + [status]
        for v in items {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
    }

    override func layout() {
        super.layout()
        flow()
    }

    /// Lay the items out in rows of the bar's width; ask the pane for the height that takes.
    private func flow() {
        let margin: CGFloat = 10, gap: CGFloat = 8, rowH: CGFloat = 26, pad: CGFloat = 3
        let maxX = max(bounds.width - margin, 200)
        var rows: [[(NSView, CGSize)]] = [[]]
        var x = margin
        for v in items where !v.isHidden {
            var sz = v.intrinsicContentSize
            if let w = fixedWidth[ObjectIdentifier(v)] { sz.width = w }
            if sz.width < 0 { sz.width = v.fittingSize.width > 0 ? v.fittingSize.width : 80 }
            if sz.height < 0 || sz.height > rowH { sz.height = min(max(v.fittingSize.height, 18), rowH - 4) }
            if v === status {
                // The status line takes what is left of the row, or a row of its own if that is too little.
                if maxX - x < 140 && x > margin { rows.append([]); x = margin }
                sz.width = maxX - x
            } else if x > margin && x + sz.width > maxX {
                rows.append([])
                x = margin
            }
            rows[rows.count - 1].append((v, sz))
            x += sz.width + gap
        }
        if rows.count > 1 && rows[rows.count - 1].isEmpty { rows.removeLast() }
        let height = CGFloat(rows.count) * rowH + 2 * pad
        for (r, row) in rows.enumerated() {
            let top = bounds.height - pad - CGFloat(r + 1) * rowH        // not flipped: y counts from the bottom
            var cx = margin
            for (v, sz) in row {
                v.frame = NSRect(x: cx, y: top + (rowH - sz.height) / 2, width: sz.width, height: sz.height)
                cx += sz.width + gap
            }
        }
        if abs(height - neededHeight) > 0.5 {
            neededHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                s.onHeightNeeded?(s.neededHeight)
            }
        }
    }

    /// Photography mode shows the filters and tools; the plain thumbnail view only the size slider.
    func setPhotoMode(_ on: Bool) {
        for v in filterViews { v.isHidden = !on }
        needsLayout = true
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        fillColor = tm.sidebar
        bottomLine = tm.separator
        status.font = tm.smallFont
        status.textColor = tm.secondaryText
        stars.needsDisplay = true
        dots.needsDisplay = true
    }

    var filter: PhotoFilter {
        var f = PhotoFilter()
        let i = formatPopup.indexOfSelectedItem
        if i > 0 && i - 1 < formatExts.count { f.extensions = [formatExts[i - 1]] }
        f.minRating = stars.value
        f.exactRating = stars.exact
        f.colorClasses = dots.picked
        let names = Prefs.colorClassNames
        for c in 1...8 where c - 1 < names.count { f.classNames[c] = names[c - 1] }
        f.text = textField.stringValue
        return f
    }

    /// The Formats menu lists only the picture types in the folder (with how many). A type that is
    /// picked stays picked while it is there; when it is gone the menu goes back to All types.
    func updateFormats(_ names: [String]) {
        let present = PhotoFilter.formatsPresent(names)
        let exts = present.map { $0.ext }
        let picked = formatPopup.indexOfSelectedItem > 0 && formatPopup.indexOfSelectedItem - 1 < formatExts.count ? formatExts[formatPopup.indexOfSelectedItem - 1] : nil
        let titles = present.map { "\($0.ext.uppercased())  (\($0.count))" }
        let current = (1..<max(1, formatPopup.numberOfItems)).map { formatPopup.item(at: $0)?.title ?? "" }
        if exts == formatExts && titles == current { return }
        formatExts = exts
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: ["All types"] + titles)
        if let p = picked, let k = exts.index(of: p) {
            formatPopup.selectItem(at: k + 1)
        } else {
            formatPopup.selectItem(at: 0)
            // The picked type is gone: show all again (after this refresh).
            if picked != nil { DispatchQueue.main.async { [weak self] in self?.filterChanged(nil) } }
        }
    }

    @objc func filterChanged(_ sender: Any?) {
        onFilterChanged?(filter)
    }

    // Informal NSObject method in the 10.13 SDK (needs `override`); a protocol method in later SDKs.
    #if swift(>=4.2)
    func controlTextDidChange(_ obj: Notification) {
        onFilterChanged?(filter)
    }
    #else
    override func controlTextDidChange(_ obj: Notification) {
        onFilterChanged?(filter)
    }
    #endif

    @objc func sizeChanged(_ sender: Any?) {
        onSizeChanged?(CGFloat(sizeSlider.doubleValue))
    }

    @objc func contactSheet(_ sender: Any?) { onContactSheet?() }
    @objc private func rate(_ sender: NSMenuItem) { onRate?(sender.tag) }
    @objc private func colorClass(_ sender: NSMenuItem) { onColorClass?(sender.tag - 100) }
    @objc private func subfoldersClicked(_ sender: NSButton) { onSubfolders?(sender.state == .on) }
    func setSubfolders(_ on: Bool) { subfoldersButton.state = on ? .on : .off }

    /// Colour-class names and colours changed in Settings: update the menu.
    func refreshColorClassMenu() {
        dots.needsDisplay = true
        for i in 1...8 {
            guard let item = rateMenu.menu?.items.first(where: { $0.tag == 100 + i }) else { continue }
            item.title = "\(i)  \(Prefs.colorClassNames[i - 1])   (Cmd-\(i))"
            if let c = Prefs.colorClassColor(i) { item.image = PhotoBar.swatch(c) }
        }
    }

    static func swatch(_ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12))
        img.lockFocus()
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
        img.unlockFocus()
        return img
    }
    @objc private func editMetadata(_ sender: Any?) { onEditMetadata?() }
    @objc private func metadataTemplate(_ sender: Any?) { onMetadataTemplate?() }
    @objc func compare(_ sender: Any?) { onCompare?() }
}


/// Rating filter: five stars. Click a star: pictures with that many stars or more; click it again: off.
/// Option-click: exactly that many.
final class StarFilterView: NSView {
    private(set) var value = 0
    private(set) var exact = false
    var onChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateTip()
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func updateTip() {
        toolTip = value == 0 ? "Filter by stars: click a star for that many or more; Option-click for exactly that many"
            : "Showing \(value) star\(value == 1 ? "" : "s")\(exact ? " exactly" : " or more") - click the same star again to show all"
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let n = max(1, min(5, Int(p.x / 16) + 1))
        let wantExact = event.modifierFlags.contains(.option)
        if n == value && wantExact == exact {
            value = 0
            exact = false
        } else {
            value = n
            exact = wantExact
        }
        updateTip()
        needsDisplay = true
        onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let tm = ThemeManager.shared
        let font = NSFont.systemFont(ofSize: 13)
        for i in 0..<5 {
            let on = i < value
            let color = on ? tm.accent : tm.secondaryText.withAlphaComponent(0.55)
            let glyph = on ? "\u{2605}" : "\u{2606}"
            NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color]).draw(at: NSPoint(x: CGFloat(i) * 16 + 1, y: 0))
        }
        if value > 0 && value < 5 {
            let mark = exact ? "=" : "+"
            NSAttributedString(string: mark, attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: tm.accent]).draw(at: NSPoint(x: 81, y: 1))
        }
    }
}

/// Colour-class filter: the eight Photo Mechanic colour classes as dots. Click dots to show only
/// pictures with those classes; click again to remove; none picked shows everything.
final class ColorDotsFilterView: NSView {
    private(set) var picked: Set<Int> = []
    var onChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateTip()
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func updateTip() {
        let names = Prefs.colorClassNames
        let list = (1...8).map { "\($0) \($0 - 1 < names.count ? names[$0 - 1] : "")" }.joined(separator: ", ")
        toolTip = (picked.isEmpty ? "Filter by colour class - click dots to pick (" : "Showing: " + picked.sorted().map { "\($0) \($0 - 1 < names.count ? names[$0 - 1] : "")" }.joined(separator: ", ") + " - click to change (")
            + list + ")"
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let n = max(1, min(8, Int((p.x - 2) / 15) + 1))
        if picked.contains(n) { picked.remove(n) } else { picked.insert(n) }
        updateTip()
        needsDisplay = true
        onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let tm = ThemeManager.shared
        for i in 1...8 {
            let r = NSRect(x: 2 + CGFloat(i - 1) * 15 + 1.5, y: (bounds.height - 11) / 2, width: 11, height: 11)
            let c = Prefs.colorClassColor(i) ?? tm.secondaryText
            let dim = !picked.isEmpty && !picked.contains(i)
            c.withAlphaComponent(dim ? 0.3 : 1).setFill()
            NSBezierPath(ovalIn: r).fill()
            if picked.contains(i) {
                tm.text.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }
}
