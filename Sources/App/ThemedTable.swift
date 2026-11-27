// ThemedTable.swift
// Table pieces drawn in theme colors: row backgrounds, selection, cells, column headers.

import AppKit
import Quartz

/// Row view: alternating background and theme selection color.
final class ThemedRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        let tm = ThemeManager.shared
        // Row index looked up at draw time: rows move when folders expand or collapse.
        let table = superview as? NSTableView
        let row = table?.row(for: self) ?? 0
        // 0.17.4: a list with Glass behind it: plain rows stay see-through, every other row a light band.
        if let t = table, Finish.glassTables.contains(t) {
            if row >= 0 && row % 2 == 1 {
                tm.alternateRow.withAlphaComponent(0.35).setFill()
                bounds.fill()
            }
            return
        }
        let c = (row >= 0 && row % 2 == 1) ? tm.alternateRow : tm.background
        c.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let tm = ThemeManager.shared
        let c = isEmphasized ? tm.selection : tm.selection.withAlphaComponent(0.6)
        Finish.drawSelection(bounds, base: c, rounded: false)
    }

    /// Tells cells whether they sit on a dark or light background, so standard text adapts correctly.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return ThemeManager.shared.theme.dark ? .dark : .light
    }
}

/// Text cell with an optional icon and colour-label dots. Laid out by hand so the icon and text are
/// always centred vertically in the row, whatever the row height, font or indentation.
final class ThemedCellView: NSTableCellView {
    var secondary = false
    /// Optional control at the right end (the sidebar's eject button).
    var accessory: NSView? {
        didSet {
            if oldValue !== accessory { oldValue?.removeFromSuperview() }
            if let a = accessory, a.superview !== self { addSubview(a) }
            needsLayout = true
        }
    }
    private let dots = TagDotsView(frame: NSRect(x: 0, y: 0, width: 0, height: 10))

    /// Colour-label indexes (into ColorLabel.names) to show after the name.
    var labelColors: [Int] = [] {
        didSet {
            if labelColors != oldValue {
                dots.colors = labelColors
                needsLayout = true
            }
        }
    }

    static func make(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) -> ThemedCellView {
        let v = ThemedCellView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        v.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingMiddle
        tf.usesSingleLineMode = true
        tf.maximumNumberOfLines = 1
        v.addSubview(tf)
        v.textField = tf
        if withIcon {
            let iv = NSImageView(frame: NSRect(x: 4, y: 2, width: 16, height: 16))
            iv.imageScaling = .scaleProportionallyDown
            v.addSubview(iv)
            v.imageView = iv
            v.addSubview(v.dots)
        }
        return v
    }

    // Cells are made 20 points tall and then given the real row height by the table; on 10.13 that
    // resize doesn't always trigger layout(), which left some names drawn too high (clipped). Any size
    // change now lays the cell out again.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 4
        if let iv = imageView {
            iv.frame = NSRect(x: 4, y: floor((h - 16) / 2), width: 16, height: 16)
            x = 25
        }
        let dw = dots.preferredWidth
        var right = bounds.width - 4
        if let a = accessory {
            a.frame = NSRect(x: bounds.width - 22, y: floor((h - 18) / 2), width: 18, height: 18)
            right -= 22
        }
        if dw > 0 {
            dots.frame = NSRect(x: bounds.width - 4 - dw, y: floor((h - 10) / 2), width: dw, height: 10)
            right -= dw + 4
        } else {
            dots.frame = .zero
        }
        if let tf = textField {
            let th = ceil(tf.intrinsicContentSize.height)
            tf.frame = NSRect(x: x, y: floor((h - th) / 2), width: max(0, right - x), height: th)
        }
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        textField?.font = secondary ? tm.smallFont : tm.font
        textField?.textColor = secondary ? tm.secondaryText : tm.text
        dots.needsDisplay = true
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTheme() }
    }
}

/// Small overlapping colour dots, like Finder's tag dots.
final class TagDotsView: NSView {
    static let palette: [String] = ["#FC605C", "#FDA840", "#F8CE3A", "#34C84A", "#3E8BF5", "#B067D8", "#9B9B9B"]

    var colors: [Int] = [] {
        didSet { needsDisplay = true }
    }

    var preferredWidth: CGFloat {
        return colors.isEmpty ? 0 : CGFloat(10 + (colors.count - 1) * 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ring = ThemeManager.shared.background
        for (i, c) in colors.enumerated() where c >= 0 && c < TagDotsView.palette.count {
            let r = NSRect(x: CGFloat(i * 6), y: 0, width: 10, height: 10)
            ring.setFill()
            NSBezierPath(ovalIn: r).fill()
            ThemeManager.color(TagDotsView.palette[c]).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        }
    }
}

/// The colour-label row in context menus (Finder style): click a dot to add or remove that colour.
final class ColorLabelMenuView: NSView {
    var onPick: ((Int) -> Void)?
    /// Colours every selected item already has (drawn with a ring).
    var applied = Set<Int>()
    private let titleText = "Tags:"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func dotRect(_ i: Int) -> NSRect {
        return NSRect(x: 58 + CGFloat(i) * 24, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = NSAttributedString(string: titleText, attributes: [AttrKey.font: NSFont.menuFont(ofSize: 0), AttrKey.foregroundColor: NSColor.labelColor])
        let ts = t.size()
        t.draw(at: NSPoint(x: 20, y: (bounds.height - ts.height) / 2))
        for i in 0..<ColorLabel.names.count {
            let r = dotRect(i)
            ThemeManager.color(TagDotsView.palette[i]).setFill()
            NSBezierPath(ovalIn: r).fill()
            if applied.contains(i) {
                NSColor.labelColor.setStroke()
                let ringPath = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                ringPath.lineWidth = 1.5
                ringPath.stroke()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0..<ColorLabel.names.count where dotRect(i).insetBy(dx: -4, dy: -4).contains(p) {
            enclosingMenuItem?.menu?.cancelTracking()
            onPick?(i)
            return
        }
    }
}

/// Column header drawn in theme colors with a small sort arrow.
final class ThemedHeaderCell: NSTableHeaderCell {
    /// nil = not the sort column.
    var sortAscending: Bool? = nil

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let tm = ThemeManager.shared
        tm.sidebar.setFill()
        cellFrame.fill()
        tm.separator.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 3, width: 1, height: cellFrame.height - 6).fill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        let font = sortAscending == nil ? tm.smallFont : tm.smallBoldFont
        let color = sortAscending == nil ? tm.secondaryText : tm.text
        let titleText = attributed(stringValue, font: font, color: color)
        let h = titleText.size().height
        let r = NSRect(x: cellFrame.minX + 6, y: cellFrame.midY - h / 2, width: max(0, cellFrame.width - 24), height: h)
        titleText.draw(with: r, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], context: nil)
        if let asc = sortAscending {
            let arrow = attributed(asc ? "\u{25B2}" : "\u{25BC}", font: NSFont.systemFont(ofSize: 8), color: tm.accent)
            let s = arrow.size()
            arrow.draw(at: NSPoint(x: cellFrame.maxX - s.width - 8, y: cellFrame.midY - s.height / 2))
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // All drawing happens in draw(withFrame:in:).
    }
}

/// The file list table: keyboard shortcuts Finder users expect, and a context menu for the clicked row.
protocol FileTableActions: class {
    func tableRename()
    func tableOpen()
    func tableGoUp()
    func tableContextMenu() -> NSMenu?
    func tableExpandAll()
    func tableCollapseAll()
}

final class FileTableView: NSOutlineView {
    weak var actions: FileTableActions?
    weak var quickLook: QuickLookSource?
    /// Space (Fast Preview or Quick Look, per Settings), Option-Space (fill the screen), Escape.
    var onSpace: (() -> Void)?
    var onOptionSpace: (() -> Void)?
    var onEscape: (() -> Bool)?
    /// Tab: go to the other pane. Returns false when there is none.
    var onTab: (() -> Bool)?
    /// Told when the list gets the keyboard (its pane becomes the focused pane).
    var onFocus: (() -> Void)?
    /// Option-click on a row's name or icon (not its disclosure triangle). Returns true if handled.
    var onOptionClick: ((Int) -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    // Quick Look: macOS asks the responder chain who controls the preview panel.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return quickLook != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLook?.begin(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLook?.end(panel)
    }

    // MARK: Drag files from their name, sweep-select from anywhere else (Finder style)

    /// True when `p` is over the icon or the drawn text of a row's name (not the empty space after it).
    func isOverNameOrIcon(_ p: NSPoint, row: Int) -> Bool {
        guard row >= 0, column(at: p) == 0 else { return false }
        let cell = frameOfCell(atColumn: 0, row: row)
        guard let v = view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView, let tf = v.textField else {
            return p.x < cell.minX + 22
        }
        let textStart = tf.convert(NSPoint.zero, to: self).x
        let textWidth = min(tf.frame.width, ceil(tf.attributedStringValue.size().width) + 6)
        return p.x >= cell.minX && p.x <= textStart + textWidth
    }

    /// Only a press on the icon or name starts dragging files; anywhere else a drag selects rows.
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let row = self.row(at: mouseDownPoint)
        return isOverNameOrIcon(mouseDownPoint, row: row) && super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    // MARK: Click a selected name again to rename (Finder style)

    private var clickRenameRow = -1

    /// At least a second (or the system double-click time, if longer), so a double-click never renames.
    static var clickRenameDelay: Double { return max(1.0, NSEvent.doubleClickInterval) }

    func cancelClickRename() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clickRenameFired), object: nil)
        clickRenameRow = -1
    }

    /// A drag started from the last press: never rename because of that press.
    private var dragBeganSincePress = false

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        dragBeganSincePress = true
        cancelClickRename()
        FileDrag.photoDrag = nil   // a list drag never brings hidden sidecars along
        super.draggingSession(session, willBeginAt: screenPoint)
        FileDrag.addFilenames(session.draggingPasteboard, nil)
    }

    @objc private func clickRenameFired() {
        let r = clickRenameRow
        clickRenameRow = -1
        guard !dragBeganSincePress, NSEvent.pressedMouseButtons & 1 == 0, r >= 0, selectedRowIndexes.count == 1, selectedRow == r, window?.firstResponder === self else { return }
        actions?.tableRename()
    }

    override func mouseDown(with event: NSEvent) {
        cancelClickRename()
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        let col = self.column(at: p)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let alreadyOnlySelected = row >= 0 && selectedRowIndexes.count == 1 && selectedRow == row && window?.firstResponder === self
        // Option-click a folder: open it in a new pane (Option on the triangle still opens all subfolders).
        if flags == .option, row >= 0, !frameOfOutlineCell(atRow: row).contains(p), isOverNameOrIcon(p, row: row),
            onOptionClick?(row) == true {
            return
        }
        dragBeganSincePress = false
        super.mouseDown(with: event)
        // super.mouseDown returns when the button comes up, or when a drag has started. If the mouse moved
        // (a drag, even a short one) this was not a click: no rename.
        var moved = false
        if let w = window {
            let now = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            moved = hypot(now.x - p.x, now.y - p.y) > 3
        }
        // A single click on the name of the item that was already the only selection: rename after a pause.
        if event.clickCount == 1 && alreadyOnlySelected && flags.isEmpty && col == 0 && !moved && !dragBeganSincePress {
            let cell = frameOfCell(atColumn: 0, row: row)
            if p.x > cell.minX + 22 && isOverNameOrIcon(p, row: row) {
                clickRenameRow = row
                perform(#selector(clickRenameFired), with: nil, afterDelay: FileTableView.clickRenameDelay)
            }
        }
    }

    /// 0.18.15: the I key (no modifiers) opens Edit Metadata for the selected pictures; false = not
    /// handled (no pictures selected), and the key goes on to type-to-select as usual.
    var onKeyI: (() -> Bool)?
    private var lastTyped = Date.distantPast

    override func keyDown(with event: NSEvent) {
        cancelClickRename()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        // I: Edit Metadata - unless a name is being typed to jump to it (another letter less than a second ago).
        if event.keyCode == 34 && (flags.isEmpty || flags == .capsLock) && Date().timeIntervalSince(lastTyped) > 1.0 {
            if onKeyI?() == true { return }
        }
        if flags.subtracting([.shift, .capsLock]).isEmpty, let ch = event.characters, !ch.isEmpty,
            ch.unicodeScalars.allSatisfyCompat({ CharacterSet.alphanumerics.contains($0) }) {
            lastTyped = Date()
        }
        switch event.keyCode {
        case 49: // Space: preview, as in Finder - unless a name is being typed (PhotoLab: "DSC 0" works)
            if Date().timeIntervalSince(lastTyped) < 1.0 && flags.isEmpty { lastTyped = Date(); break }
            if flags.isEmpty || flags == .shift { onSpace?(); return }
            if flags == .option { onOptionSpace?(); return }
        case 48: // Tab: other pane
            if flags.isEmpty, onTab?() == true { return }
        case 53: // Escape closes the preview
            if flags.isEmpty, onEscape?() == true { return }
        case 36, 76: // Return, Enter
            if flags.isEmpty { actions?.tableRename(); return }
        case 125: // Down arrow
            if cmd { actions?.tableOpen(); return }
            super.keyDown(with: event)
            keepAhead(down: true)
            return
        case 126: // Up arrow
            if cmd { actions?.tableGoUp(); return }
            super.keyDown(with: event)
            keepAhead(down: false)
            return
        case 124: // Right arrow: Option opens the folder and all its subfolders
            if flags.contains(.option) { actions?.tableExpandAll(); return }
        case 123: // Left arrow: Option closes the folder and all its subfolders
            if flags.contains(.option) { actions?.tableCollapseAll(); return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    // MARK: Scrolling that knows about the column header
    // On High Sierra the column header floats OVER the top of the list. NSTableView's own
    // scrollRowToVisible counts the strip under the header as visible, so "scroll to row 0" left the
    // first row hidden under the header (every newly opened folder, and arrowing up to the top).
    // Every scroll of this list goes through the two functions below instead.

    /// Height of the list hidden under the column header.
    var headerCover: CGFloat {
        guard let sv = enclosingScrollView else { return 0 }
        var cover = sv.contentInsets.top
        if let h = headerView, h.window != nil, !h.isHidden, let w = window, sv.contentView.window === w {
            let hr = h.convert(h.bounds, to: nil)
            let cr = sv.contentView.convert(sv.contentView.bounds, to: nil)
            let overlap = hr.intersection(cr)
            if !overlap.isNull && overlap.height > 0 { cover = max(cover, overlap.height) }
        }
        return max(0, cover)
    }

    /// Scroll the list so its top edge (y in list coordinates) shows just below the header.
    func scrollListTo(y: CGFloat) {
        guard let sv = enclosingScrollView else { return }
        let clip = sv.contentView
        let cover = headerCover
        let top = -cover
        let maxY = max(top, frame.height - clip.bounds.height)
        let target = min(max(top, y), maxY)
        if abs(clip.bounds.origin.y - target) < 0.5 { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        sv.reflectScrolledClipView(clip)
    }

    /// Show the whole first row (used when a folder opens).
    func scrollToTop() {
        layoutSubtreeIfNeeded()
        scrollListTo(y: -headerCover)
    }

    override func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < numberOfRows, let sv = enclosingScrollView else { return }
        let clip = sv.contentView
        let r = rect(ofRow: row)
        let cover = headerCover
        let visibleTop = clip.bounds.origin.y + cover
        let visibleBottom = clip.bounds.origin.y + clip.bounds.height
        if r.minY < visibleTop {
            scrollListTo(y: r.minY - cover)
        } else if r.maxY > visibleBottom {
            scrollListTo(y: r.maxY - clip.bounds.height)
        }
    }

    /// Keep one more row in view beyond the selection, in the direction of travel.
    private func keepAhead(down: Bool) {
        let sel = selectedRowIndexes
        guard let edge = down ? sel.last : sel.first else { return }
        let target = down ? min(numberOfRows - 1, edge + 1) : max(0, edge - 1)
        scrollRowToVisible(target)
        scrollRowToVisible(edge)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelClickRename()
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if row < 0 { deselectAll(nil) }
        return actions?.tableContextMenu()
    }

    // Services (e.g. "New Terminal at Folder") for the selected items.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, let t = sendType, (t == .fileURL || t == .string), !selectedRowIndexes.isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // Services asks for the selection with this Objective-C message. Declared by its exact selector so it works
    // the same with every SDK (the 10.13 SDK has no superclass method to override).
    @objc(writeSelectionToPasteboard:types:)
    func writeSelectionForServices(_ pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        return writeSelectedFiles(to: pboard)
    }

    private func writeSelectedFiles(to pboard: NSPasteboard) -> Bool {
        var urls: [NSURL] = []
        for i in selectedRowIndexes {
            if let n = item(atRow: i) as? FileNode { urls.append(NSURL(fileURLWithPath: n.path)) }
        }
        if urls.isEmpty { return false }
        pboard.clearContents()
        pboard.writeObjects(urls)
        return true
    }
}

/// Scroll bar drawn in theme colors: background track with a barely visible divider line and a soft knob.
final class ThemedScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool {
        return true
    }

    private var isVertical: Bool { return bounds.height >= bounds.width }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        let tm = ThemeManager.shared
        tm.background.setFill()
        bounds.fill()
        tm.separator.withAlphaComponent(0.6).setFill()
        if isVertical {
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    override func drawKnob() {
        let tm = ThemeManager.shared
        var r = rect(for: .knob)
        r = isVertical ? r.insetBy(dx: 3.5, dy: 2) : r.insetBy(dx: 2, dy: 3.5)
        if r.width <= 0 || r.height <= 0 { return }
        let radius = min(r.width, r.height) / 2
        tm.secondaryText.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
}
