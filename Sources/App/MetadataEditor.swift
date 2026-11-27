// MetadataEditor.swift
// Edit IPTC/XMP metadata (caption, keywords, photographer ...) and the rating of the selected pictures,
// written so Photo Mechanic reads them. Shows the current values; with several pictures, a field whose
// values differ says so and is left alone unless you type in it. Only fields you change are written,
// through FileOperations.writeMetadata (copy, write the copy, verify, swap; RAW files: their IPTC/XMP fields and their sidecar, same values).

import AppKit

final class MetadataEditorWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// 0.18.15: Edit Metadata (I) shows the selected pictures' own values; Metadata Template (Cmd-I) is
    /// a form you fill in once and apply to any selection - the ticked fields are written - kept for next time.
    enum Mode { case selection, template }
    let mode: Mode
    private let paths: [String]
    /// The pictures to write to, asked when Apply is pressed (template: whatever is selected then).
    var pathsNow: () -> [String]
    /// The one Metadata Template window (kept while Find runs; its contents are kept in Settings too).
    static var template: MetadataEditorWindow?
    var applyTo: ([String], MetaChange, @escaping (BatchReport) -> Void) -> Void
    private var fields: [MetaField: NSTextField] = [:]
    private var ticks: [MetaField: NSButton] = [:]
    /// 0.18.16: the window takes the size its contents need.
    private var laidOut: NSView?
    private var initial: [MetaField: String] = [:]
    private let ratingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addKeywords = NSButton(checkboxWithTitle: "Add these keywords to the ones already there (instead of replacing them)", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Reading the current metadata\u{2026}")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    init(mode: Mode, paths: [String], pathsNow: @escaping () -> [String], apply: @escaping ([String], MetaChange, @escaping (BatchReport) -> Void) -> Void) {
        self.mode = mode
        self.paths = paths
        self.pathsNow = pathsNow
        self.applyTo = apply
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: mode == .template ? 1110 : 1060, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        if mode == .template {
            w.title = "Metadata Template"
        } else {
            w.title = paths.count == 1 ? "Edit Metadata \u{2013} \(Paths.lastComponent(paths[0]))" : "Edit Metadata \u{2013} \(paths.count) pictures"
        }
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        if let st = laidOut {
            st.layoutSubtreeIfNeeded()
            let fit = st.fittingSize
            if fit.width > 100 && fit.height > 100 { w.setContentSize(NSSize(width: fit.width + 36, height: fit.height + 34)) }
        }
        if mode == .template {
            // Where it was last time (kept as four numbers).
            if let a = UserDefaults.standard.array(forKey: "metadataTemplateFrame") as? [Double], a.count == 4, a[2] > 200, a[3] > 200 {
                // Same top-left corner as last time; the size is what the contents need now.
                let sz = w.frame.size
                w.setFrame(NSRect(x: a[0], y: a[1] + a[3] - Double(sz.height), width: Double(sz.width), height: Double(sz.height)), display: false)
            } else {
                w.center()
            }
            loadTemplate()
        } else {
            w.center()
            load()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        var rows: [NSView] = []
        func row(_ title: String, _ v: NSView) -> NSView {
            let l = NSTextField(labelWithString: title)
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let s = NSStackView(views: [l, v])
            s.orientation = .horizontal
            s.alignment = .firstBaseline
            s.spacing = 10
            return s
        }
        ratingPopup.addItems(withTitles: ["Leave as it is", "No rating", "\u{2605}", "\u{2605}\u{2605}", "\u{2605}\u{2605}\u{2605}",
                                          "\u{2605}\u{2605}\u{2605}\u{2605}", "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}"])
        // 0.18.13: Photo Mechanic's fields in its groups, two columns.
        var columns: [[NSView]] = [[row("Rating", ratingPopup)], []]
        // 0.18.16: Supplemental Categories as Photo Mechanic shows them - three fields, under Rating. The
        // value written is still the one standard list (IPTC / XMP), of the three in order.
        let supp = SuppCategoriesField(string: "")
        fields[.suppCategories] = supp
        for i in 0..<3 {
            let t = NSTextField(string: "")
            t.translatesAutoresizingMaskIntoConstraints = false
            t.widthAnchor.constraint(equalToConstant: 330).isActive = true
            t.toolTip = "Supplemental category \(i + 1) (the IPTC field holds 32 characters)"
            supp.parts.append(t)
            if mode == .template {
                t.delegate = self
                let tickOrSpace: NSView
                if i == 0 {
                    let tick = NSButton(checkboxWithTitle: "", target: self, action: #selector(templateEdited(_:)))
                    tick.title = ""
                    tick.imagePosition = .imageOnly
                    tick.toolTip = "Ticked: the three supplemental categories are written (all empty: cleared). Unticked: left as they are."
                    ticks[.suppCategories] = tick
                    tickOrSpace = tick
                } else {
                    let space = NSView()
                    space.translatesAutoresizingMaskIntoConstraints = false
                    space.widthAnchor.constraint(equalToConstant: 18).isActive = true
                    tickOrSpace = space
                }
                let pair = NSStackView(views: [tickOrSpace, t])
                pair.orientation = .horizontal
                pair.spacing = 4
                pair.alignment = .firstBaseline
                columns[0].append(row("Supplemental Category \(i + 1)", pair))
            } else {
                columns[0].append(row("Supplemental Category \(i + 1)", t))
            }
        }
        for g in MetaField.groups {
            let h = NSTextField(labelWithString: g.title)
            h.font = NSFont.boldSystemFont(ofSize: 12)
            let hs = NSStackView(views: [h])
            hs.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
            columns[g.column].append(hs)
            for f in g.fields where f != .suppCategories {
                let t = NSTextField(string: "")
                t.translatesAutoresizingMaskIntoConstraints = false
                t.widthAnchor.constraint(equalToConstant: 330).isActive = true
                if f == .caption {
                    t.heightAnchor.constraint(equalToConstant: 66).isActive = true
                    t.usesSingleLineMode = false
                    t.cell?.wraps = true
                    t.cell?.isScrollable = false
                }
                if f.isList { t.toolTip = "Several values: separate them with commas or semicolons" }
                if f == .dateCreated { t.placeholderString = "YYYY-MM-DD"; t.toolTip = "The date the picture was taken, e.g. 2026-11-26 (a time may follow: 2026-11-26 14:30:00)" }
                if f == .copyrightMarked { t.placeholderString = "True or False"; t.toolTip = "True = copyrighted, False = public domain, empty = not stated" }
                if f == .category || f == .countryCode { t.toolTip = "The IPTC field holds 3 characters (the XMP field the whole text)" }
                fields[f] = t
                if mode == .template {
                    // A tick per field: ticked = written (an empty ticked field is cleared). Typing ticks it.
                    let tick = NSButton(checkboxWithTitle: "", target: self, action: #selector(templateEdited(_:)))
                    tick.title = ""                     // 0.18.16: no "Button" text beside the box
                    tick.imagePosition = .imageOnly
                    tick.toolTip = "Ticked: this field is written to the pictures (empty: the field is cleared). Unticked: left as it is."
                    ticks[f] = tick
                    t.delegate = self
                    let pair = NSStackView(views: [tick, t])
                    pair.orientation = .horizontal
                    pair.spacing = 4
                    pair.alignment = .firstBaseline
                    columns[g.column].append(row(f.label, pair))
                } else {
                    columns[g.column].append(row(f.label, t))
                }
                if f == .keywords { columns[g.column].append(row("", addKeywords)) }
            }
        }
        let colViews: [NSView] = columns.map { views in
            let c = NSStackView(views: views)
            c.orientation = .vertical
            c.alignment = .leading
            c.spacing = 5
            return c
        }
        let twoCols = NSStackView(views: colViews)
        twoCols.orientation = .horizontal
        twoCols.alignment = .top
        twoCols.spacing = 24
        rows.append(twoCols)
        status.textColor = NSColor.secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 1000).isActive = true
        let cancel = NSButton(title: mode == .template ? "Close" : "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyChanges(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.isEnabled = false
        var buttonViews: [NSView] = []
        if mode == .template {
            applyButton.title = "Apply to Selected"
            let clear = NSButton(title: "Clear Template", target: self, action: #selector(clearTemplate(_:)))
            clear.bezelStyle = .rounded
            // 0.18.16: fill the template from an XMP file (a Photo Mechanic template, any sidecar).
            let fromXMP = NSButton(title: "Fill from XMP File", target: self, action: #selector(fillFromXMP(_:)))
            fromXMP.bezelStyle = .rounded
            fromXMP.toolTip = "Fill the template from an .xmp file - a Photo Mechanic IPTC template or a picture's sidecar. Its fields replace the template's and are ticked."
            buttonViews.append(fromXMP)
            buttonViews.append(clear)
            ratingPopup.target = self
            ratingPopup.action = #selector(templateEdited(_:))
            addKeywords.target = self
            addKeywords.action = #selector(templateEdited(_:))
        }
        for b in [cancel, applyButton] { b.bezelStyle = .rounded }
        let buttons = NSStackView(views: buttonViews + [cancel, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let note = NSTextField(wrappingLabelWithString: (mode == .template ? "A template: what you type here is kept for next time (Cmd-I). Apply to Selected writes the TICKED fields to the pictures selected at that moment - an empty ticked field is cleared, unticked fields are left as they are. The window stays open for the next selection. " : "") + "Shown: each picture's current metadata (its own, or its XMP sidecar's if that was changed later). Written to: " + [MetaPlan.writeSidecar ? "the .xmp sidecar (RAW: made when missing)" : nil, MetaPlan.writeEmbeddedXMP ? "the embedded XMP" : nil, MetaPlan.writeEmbeddedIPTC ? "the embedded IPTC" : nil].compactMap { $0 }.joined(separator: ", ") + " (Settings > Photography). Only metadata is written, never the picture, and every value is checked before a new version replaces the original. Edit > Undo puts the old values back.")
        note.textColor = NSColor.secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 11)
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 1000).isActive = true
        let stack = NSStackView(views: rows + [note, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        content.addSubview(stack)
        laidOut = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: status.trailingAnchor),
        ])
    }

    /// Current values, read in the background (ExifTool): one picture's, or the values all share.
    private func load() {
        let paths = self.paths
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let targets = MetaPlan.targets(paths)
            // 0.18: each picture's CURRENT set - its own metadata or its sidecar's, whichever was changed
            // last (the same set the Info panel shows).
            var images: [String] = []
            for t in targets {
                if case .unsupported = t.kind { continue }
                if !images.contains(t.image) { images.append(t.image) }
            }
            let files = images.map { MetaPlan.currentFile(for: $0).file }
            // 0.18.13: Find's own reader where it can (opens faster), ExifTool for the rest.
            let recs = files.isEmpty ? [:] : App.ops.readMetadataValues(files)
            let unsupported = targets.filter { if case .unsupported = $0.kind { return true }; return false }.count
            var all: [[String: Any]] = []
            for f in files { all.append(recs[f] ?? [:]) }
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.fill(all, unsupported: unsupported, writable: all.count)
            }
        }
    }

    private func fill(_ recs: [[String: Any]], unsupported: Int, writable: Int) {
        for f in MetaField.all {
            guard let t = fields[f] else { continue }
            var values = Set(recs.map { MetaPlan.current(f, in: $0) })
            if f == .dateCreated {
                // Shown as 2026-11-26 (kept as ExifTool shows it, 2026:11:26).
                values = Set(values.map { v in
                    var u = Array(v.unicodeScalars)
                    for k in 0..<min(10, u.count) where u[k] == ":" { u[k] = "-" }
                    var o = ""
                    o.unicodeScalars.append(contentsOf: u)
                    return o
                })
            }
            if values.count <= 1 {
                t.stringValue = values.first ?? ""
                initial[f] = t.stringValue
            } else {
                t.stringValue = ""
                t.placeholderString = "(different in these pictures - left as they are unless you type here)"
                initial[f] = ""
            }
        }
        let ratings = Set(recs.map { MetaPlan.currentRating(in: $0) })
        ratingPopup.toolTip = ratings.count == 1 ? nil : "The pictures have different ratings"
        var s = writable == 1 ? "1 picture can be written." : "\(writable) pictures can be written."
        if unsupported > 0 { s += " \(unsupported) can't be (e.g. Photoshop files) and will be listed." }
        if App.ops.metadataTool == nil { s = "ExifTool is not available: nothing can be written." }
        status.stringValue = s
        applyButton.isEnabled = writable > 0 && App.ops.metadataTool != nil
    }

    private func change() -> MetaChange {
        if mode == .template { return templateChange() }
        var c = MetaChange()
        let r = ratingPopup.indexOfSelectedItem
        if r >= 1 { c.rating = r - 1 }
        for f in MetaField.all {
            guard let t = fields[f] else { continue }
            let now = t.stringValue
            if now == (initial[f] ?? "") { continue }
            if f == .keywords && addKeywords.state == .on {
                c.addKeywords = MetaPlan.listValues(now)
            } else {
                c.set[f] = now
            }
        }
        if addKeywords.state == .on, let t = fields[.keywords], t.stringValue == (initial[.keywords] ?? ""), !t.stringValue.isEmpty {
            // Ticked "add" without editing: add what is shown (harmless: no duplicates).
            c.addKeywords = MetaPlan.listValues(t.stringValue)
        }
        return c
    }

    @objc private func applyChanges(_ sender: Any?) {
        let targets = pathsNow()
        if targets.isEmpty {
            status.stringValue = "Select the pictures to write to first (in the window behind)."
            return
        }
        let c = change()
        // 0.18.13: a date or True/False that can't be written is said here, before anything is written.
        for f in MetaField.all {
            if let v = c.set[f], let p = f.problem(v) {
                status.stringValue = p
                let focus = (fields[f] as? SuppCategoriesField)?.parts.first ?? fields[f]
                focus.map { window?.makeFirstResponder($0) }
                return
            }
        }
        if c.isEmpty {
            status.stringValue = "Nothing was changed."
            return
        }
        applyButton.isEnabled = false
        status.stringValue = "Writing and checking\u{2026} (\(c.describe))"
        saveTemplate()
        applyTo(targets, c) { [weak self] r in
            guard let s = self else { return }
            if r.failed.isEmpty {
                if s.mode == .template {
                    s.applyButton.isEnabled = true
                    s.status.stringValue = "Written to \(targets.count) picture\(targets.count == 1 ? "" : "s") and checked. Select others and Apply again, or Close."
                } else {
                    s.close()
                }
            } else {
                s.applyButton.isEnabled = true
                s.status.stringValue = "\(r.done.count) written, \(r.failed.count) not written (see the report)."
            }
        }
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    // MARK: Template (0.18.15)

    private func templateChange() -> MetaChange {
        var c = MetaChange()
        let r = ratingPopup.indexOfSelectedItem
        if r >= 1 { c.rating = r - 1 }
        for f in MetaField.all {
            guard let t = fields[f], ticks[f]?.state == .on else { continue }
            if f == .keywords && addKeywords.state == .on {
                let k = MetaPlan.listValues(t.stringValue)
                if !k.isEmpty { c.addKeywords = k }
            } else {
                c.set[f] = t.stringValue
            }
        }
        return c
    }

    private func loadTemplate() {
        let saved = Prefs.metadataTemplate
        for f in MetaField.all {
            fields[f]?.stringValue = saved.values[f.rawValue] ?? ""
            ticks[f]?.state = saved.ticked.contains(f.rawValue) ? .on : .off
        }
        ratingPopup.selectItem(at: max(0, min(ratingPopup.numberOfItems - 1, saved.rating)))
        addKeywords.state = saved.addKeywords ? .on : .off
        status.stringValue = App.ops.metadataTool == nil ? "ExifTool is not available: nothing can be written."
            : "Tick the fields to write, then select pictures and Apply to Selected."
        applyButton.isEnabled = App.ops.metadataTool != nil
    }

    private func saveTemplate() {
        guard mode == .template else { return }
        var values: [String: String] = [:]
        var ticked: [String] = []
        for f in MetaField.all {
            if let v = fields[f]?.stringValue, !v.isEmpty { values[f.rawValue] = v }
            if ticks[f]?.state == .on { ticked.append(f.rawValue) }
        }
        Prefs.metadataTemplate = (values, ticked, ratingPopup.indexOfSelectedItem, addKeywords.state == .on)
    }

    /// Typing in a field ticks it; every change is kept at once.
    // Informal NSObject method in the 10.13 SDK (needs `override`); a protocol method in later SDKs.
    #if swift(>=4.2)
    func controlTextDidChange(_ obj: Notification) { templateTyped(obj) }
    #else
    override func controlTextDidChange(_ obj: Notification) { templateTyped(obj) }
    #endif

    private func templateTyped(_ obj: Notification) {
        guard mode == .template, let t = obj.object as? NSTextField else { return }
        let suppPart = (fields[.suppCategories] as? SuppCategoriesField)?.parts.contains { $0 === t } ?? false
        guard let f = suppPart ? MetaField.suppCategories : fields.first(where: { $0.value === t })?.key else { return }
        ticks[f]?.state = .on
        saveTemplate()
    }

    @objc private func templateEdited(_ sender: Any?) {
        saveTemplate()
    }

    @objc private func fillFromXMP(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["xmp", "XMP"]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.message = "Choose an XMP file to fill the template from (a Photo Mechanic template or a picture's sidecar)"
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = url.path
        status.stringValue = "Reading \(Paths.lastComponent(path))\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Find's own reader, ExifTool for a file it can't read for sure. Only read, never written.
            let rec = App.ops.readMetadataValues([path])[path]
            DispatchQueue.main.async {
                guard let s = self else { return }
                guard let r = rec else {
                    s.status.stringValue = "\(Paths.lastComponent(path)) could not be read as XMP. The template is unchanged."
                    return
                }
                var n = 0
                for f in MetaField.all {
                    guard let t = s.fields[f] else { continue }
                    let v = MetadataEditorWindow.shown(f, MetaPlan.current(f, in: r))
                    t.stringValue = v
                    s.ticks[f]?.state = v.isEmpty ? .off : .on
                    if !v.isEmpty { n += 1 }
                }
                s.addKeywords.state = .off
                s.saveTemplate()
                s.status.stringValue = "Filled \(n) field\(n == 1 ? "" : "s") from \(Paths.lastComponent(path)) and ticked them; the others are empty and unticked. The rating is as it was."
            }
        }
    }

    /// A value as the editor shows it (Date Created as 2026-11-26).
    static func shown(_ f: MetaField, _ v: String) -> String {
        guard f == .dateCreated else { return v }
        var u = Array(v.unicodeScalars)
        for k in 0..<min(10, u.count) where u[k] == ":" { u[k] = "-" }
        var o = ""
        o.unicodeScalars.append(contentsOf: u)
        return o
    }

    @objc private func clearTemplate(_ sender: Any?) {
        for f in MetaField.all { fields[f]?.stringValue = ""; ticks[f]?.state = .off }
        ratingPopup.selectItem(at: 0)
        addKeywords.state = .off
        saveTemplate()
        status.stringValue = "Template cleared."
    }

    func windowWillClose(_ notification: Notification) {
        saveTemplate()
        if mode == .template, let f = window?.frame {
            UserDefaults.standard.set([Double(f.origin.x), Double(f.origin.y), Double(f.size.width), Double(f.size.height)], forKey: "metadataTemplateFrame")
        }
    }
}

/// 0.18.16: Supplemental Categories shown as three fields (Photo Mechanic's way). Not shown itself: its
/// value is the three fields' values as one list ("a, b, c"), and setting it fills them (a fourth and more
/// go into the third field). The rest of the editor treats it as any other field.
final class SuppCategoriesField: NSTextField {
    var parts: [NSTextField] = []
    override var stringValue: String {
        get {
            return parts.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        set {
            let l = MetaPlan.listValues(newValue)
            for (i, p) in parts.enumerated() {
                p.stringValue = i < parts.count - 1 ? (i < l.count ? l[i] : "") : l.dropFirst(parts.count - 1).joined(separator: ", ")
            }
        }
    }
    override var placeholderString: String? {
        get { return parts.first?.placeholderString }
        set { parts.first?.placeholderString = newValue }
    }
}
