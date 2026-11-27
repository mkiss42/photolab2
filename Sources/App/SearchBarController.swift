// SearchBarController.swift
// The search field (in the toolbar row) and the compact search bar shown under it while searching.

import AppKit

enum SearchScope: Int {
    case thisFolderOnly = 0, thisFolderAndSubfolders, selectedFolders, thisDrive, allLocalDrives, thisNetworkLocation, allLocations

    static let titles = ["This folder only", "This folder and subfolders", "Selected folders and subfolders",
                         "This drive", "All local drives", "This network location", "All locations (local and network)"]
}

// NSResponder (an NSObject) so the 10.13-style `override func controlTextDidChange` is modelled by the
// Linux type-check stand-ins too; nothing else changes.
final class SearchBarController: NSResponder, NSSearchFieldDelegate {
    let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
    let bar = FillView()
    private(set) var heightConstraint: NSLayoutConstraint!
    private(set) var isShown = false
    private var expanded = false

    let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let caseCheck = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let systemCheck = NSButton(checkboxWithTitle: "Include System Files", target: nil, action: nil)
    let hiddenCheck = NSButton(checkboxWithTitle: "Hidden files", target: nil, action: nil)
    let indexCheck = NSButton(checkboxWithTitle: "Use index", target: nil, action: nil)
    private var moreButton: ThemedButton!
    private var goButton: ThemedButton!
    private let scopeLabel = makeLabel("Search:")

    let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let allAnyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let extField = NSTextField(frame: NSRect(x: 0, y: 0, width: 110, height: 22))
    let minSizeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    let maxSizeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    let afterCheck = NSButton(checkboxWithTitle: "Modified after", target: nil, action: nil)
    let afterPicker = NSDatePicker()
    let beforeCheck = NSButton(checkboxWithTitle: "before", target: nil, action: nil)
    let beforePicker = NSDatePicker()
    let folderField = NSTextField(frame: NSRect(x: 0, y: 0, width: 110, height: 22))
    let packagesCheck = NSButton(checkboxWithTitle: "Inside packages (.app etc.)", target: nil, action: nil)
    let linksCheck = NSButton(checkboxWithTitle: "Follow folder links", target: nil, action: nil)
    let insideMetaCheck = NSButton(checkboxWithTitle: "Picture metadata", target: nil, action: nil)
    let insideDocsCheck = NSButton(checkboxWithTitle: "Text in PDFs and documents", target: nil, action: nil)
    let excludeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
    private let advancedRow = NSStackView()
    private let advancedRow2 = NSStackView()
    private let advancedRow3 = NSStackView()
    private var labels: [NSTextField] = []

    var onSearch: (() -> Void)?
    var onStop: (() -> Void)?
    var onClear: (() -> Void)?
    /// Typing in the field (each change). The pane shows the bar as soon as there is text.
    var onTextChanged: ((String) -> Void)?
    /// A search has run since the bar appeared (button says "Search Again" instead of "Search").
    private var searchedOnce = false

    var running = false {
        didSet {
            if running { searchedOnce = true }
            updateGoButton()
        }
    }

    override init() {
        super.init()
        field.placeholderString = "Search"
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(fieldAction(_:))
        field.delegate = self

        scopePopup.addItems(withTitles: SearchScope.titles)
        scopePopup.selectItem(at: SearchScope.thisFolderAndSubfolders.rawValue)
        modePopup.addItems(withTitles: NameMode.titles)
        kindPopup.addItems(withTitles: ["Files and folders", "Files only", "Folders only"])
        allAnyPopup.addItems(withTitles: ["Match all conditions", "Match any condition"])
        extField.placeholderString = "nef, dng, jpg"
        minSizeField.placeholderString = "min MB"
        maxSizeField.placeholderString = "max MB"
        folderField.placeholderString = "folder name"
        for p in [afterPicker, beforePicker] {
            // Text field with stepper is the default style. Year-month-day is 0x00E0 (same in every SDK).
            p.datePickerElements = NSDatePicker.ElementFlags(rawValue: 0x00E0)
            p.dateValue = Date()
        }
        systemCheck.toolTip = "Also search system folders such as /System, /Library and /usr. Folders protected by macOS are reported, never bypassed."
        hiddenCheck.toolTip = "Also search hidden files and folders (names starting with a dot, or marked hidden)."
        indexCheck.state = .on
        indexCheck.toolTip = "Use search indexes where you have set them up (Settings > Search Index). Changed folders are always re-read; untick to read every folder directly."
        packagesCheck.toolTip = "Look inside applications and other package folders."
        insideMetaCheck.toolTip = "Also find pictures whose metadata contains the search text: caption, headline, keywords, title, photographer, copyright, place, camera, lens (in the picture and its XMP sidecar). Only the metadata part of each picture is read."
        insideDocsCheck.toolTip = "Also find PDFs and text documents (txt, csv, rtf, html, xml, md, log ...) whose text contains the search text. Word and Pages files are not read."
        excludeField.placeholderString = "text"
        excludeField.toolTip = "Leave out files whose contents contain this text (in the kinds ticked; both kinds if none is ticked)."
        insideMetaCheck.target = self
        insideMetaCheck.action = #selector(insideChanged(_:))
        insideDocsCheck.target = self
        insideDocsCheck.action = #selector(insideChanged(_:))
        linksCheck.toolTip = "Follow symbolic links to folders. Loops are detected and each folder is searched only once."

        moreButton = makeButton("More \u{25BE}", self, #selector(toggleMore(_:)), tip: "More search criteria")
        goButton = makeButton("Search", self, #selector(goClicked(_:)), tip: "Run the search again / Stop")
        goButton.isAccent = true

        let row1 = NSStackView(views: [scopeLabel, scopePopup, modePopup, caseCheck, systemCheck, hiddenCheck, indexCheck, moreButton, goButton])
        row1.orientation = .horizontal
        row1.spacing = 10
        let kindL = makeLabel("Kind:"), extL = makeLabel("Extensions:"), sizeL = makeLabel("Size:"), toL = makeLabel("to")
        let inL = makeLabel("In folders named:")
        let insideL = makeLabel("Look inside:")
        let excludeL = makeLabel("but not files containing:")
        labels = [scopeLabel, kindL, extL, sizeL, toL, inL, insideL, excludeL]
        for v in [advancedRow, advancedRow2, advancedRow3] {
            v.orientation = .horizontal
            v.spacing = 8
        }
        for v in [kindL, kindPopup, extL, extField, sizeL, minSizeField, toL, maxSizeField, inL, folderField] as [NSView] {
            advancedRow.addArrangedSubview(v)
        }
        for v in [afterCheck, afterPicker, beforeCheck, beforePicker, packagesCheck, linksCheck, allAnyPopup] as [NSView] {
            advancedRow2.addArrangedSubview(v)
        }
        for v in [insideL, insideMetaCheck, insideDocsCheck, excludeL, excludeField] as [NSView] {
            advancedRow3.addArrangedSubview(v)
        }
        excludeField.translatesAutoresizingMaskIntoConstraints = false
        excludeField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        excludeField.target = self
        excludeField.action = #selector(goClicked(_:))
        for f in [extField, minSizeField, maxSizeField, folderField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: f === extField || f === folderField ? 110 : 64).isActive = true
            f.target = self
            f.action = #selector(goClicked(_:))
        }
        let all = NSStackView(views: [row1, advancedRow, advancedRow2, advancedRow3])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 6
        all.detachesHiddenViews = true
        bar.addSubview(all)
        all.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            all.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            all.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -10),
        ])
        advancedRow.isHidden = true
        advancedRow2.isHidden = true
        advancedRow3.isHidden = true
        heightConstraint = bar.heightAnchor.constraint(equalToConstant: 0)
        bar.isHidden = true
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        bar.fillColor = tm.sidebar
        bar.bottomLine = tm.separator
        for l in labels {
            l.textColor = tm.secondaryText
            l.font = tm.smallFont
        }
        moreButton.applyTheme(expanded ? "Fewer \u{25B4}" : "More \u{25BE}")
        updateGoButton()
    }

    private func updateGoButton() {
        goButton.applyTheme(running ? "Stop" : (searchedOnce ? "Search Again" : "Search"))
    }

    func show(_ yes: Bool) {
        if !yes { searchedOnce = false }
        isShown = yes
        bar.isHidden = !yes
        heightConstraint.constant = yes ? (expanded ? 126 : 34) : 0
    }

    /// Looking inside reads files: say so where the user ticks it.
    @objc private func insideChanged(_ sender: Any?) {
        let on = insideMetaCheck.state == .on || insideDocsCheck.state == .on
        indexCheck.toolTip = on ? "Indexes find the files; their contents are always read from the disk (slower on network shares)." : "Use search indexes where you have set them up (Settings > Search Index). Changed folders are always re-read; untick to read every folder directly."
    }

    @objc private func toggleMore(_ sender: Any?) {
        expanded = !expanded
        advancedRow.isHidden = !expanded
        advancedRow2.isHidden = !expanded
        advancedRow3.isHidden = !expanded
        applyTheme()
        show(isShown)
    }

    @objc private func goClicked(_ sender: Any?) {
        if running {
            onStop?()
        } else {
            onSearch?()
        }
    }

    @objc private func fieldAction(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty {
            onClear?()
        } else {
            onSearch?()
        }
    }

    var useIndex: Bool { return indexCheck.state == .on }

    var scope: SearchScope {
        return SearchScope(rawValue: scopePopup.indexOfSelectedItem) ?? .thisFolderAndSubfolders
    }

    func setScope(_ s: SearchScope) {
        scopePopup.selectItem(at: s.rawValue)
    }

    private func megabytes(_ f: NSTextField) -> Int64? {
        let t = f.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v >= 0 else { return nil }
        return Int64(v * 1_000_000)
    }

    /// The query as set in the controls.
    func query() -> SearchQuery {
        var q = SearchQuery()
        q.text = field.stringValue
        q.mode = NameMode(rawValue: modePopup.indexOfSelectedItem) ?? .contains
        q.caseSensitive = caseCheck.state == .on
        q.includeSystem = systemCheck.state == .on
        q.includeHidden = hiddenCheck.state == .on
        q.recursive = scope != .thisFolderOnly
        if expanded {
            q.kind = KindFilter(rawValue: kindPopup.indexOfSelectedItem) ?? .any
            q.extensions = SearchQuery.parseExtensions(extField.stringValue)
            q.minSize = megabytes(minSizeField)
            q.maxSize = megabytes(maxSizeField)
            if afterCheck.state == .on { q.modifiedAfter = afterPicker.dateValue.timeIntervalSince1970 }
            if beforeCheck.state == .on { q.modifiedBefore = beforePicker.dateValue.timeIntervalSince1970 }
            q.folderNameContains = folderField.stringValue.trimmingCharacters(in: .whitespaces)
            q.includePackages = packagesCheck.state == .on
            q.followLinks = linksCheck.state == .on
            q.matchAll = allAnyPopup.indexOfSelectedItem == 0
            var inside: InsideScope = []
            if insideMetaCheck.state == .on { inside.insert(.metadata) }
            if insideDocsCheck.state == .on { inside.insert(.documents) }
            q.lookInside = inside
            q.excludeInsideText = excludeField.stringValue.trimmingCharacters(in: .whitespaces)
        }
        return q
    }

    // Informal NSObject method in the 10.13 SDK (needs `override`); a protocol method in later SDKs.
    #if swift(>=4.2)
    func controlTextDidChange(_ obj: Notification) {
        onTextChanged?(field.stringValue)
    }
    #else
    override func controlTextDidChange(_ obj: Notification) {
        onTextChanged?(field.stringValue)
    }
    #endif

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === field && commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            field.stringValue = ""
            onClear?()
            return true
        }
        return false
    }
}
