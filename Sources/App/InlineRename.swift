// InlineRename.swift
// Rename in place, like Finder: an editing field opens over the item's name in the list or the grid,
// with the name (without extension) selected. Return or clicking away commits, Escape cancels.
// The rename itself still goes through FileOperations (no overwrite, undoable).

import AppKit

final class InlineEditor: NSResponder, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    let entry: FileEntry
    private var finished = false
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(entry: FileEntry, text: String) {
        self.entry = entry
        super.init()
        let tm = ThemeManager.shared
        field.stringValue = text
        field.font = tm.font
        field.textColor = tm.text
        field.backgroundColor = tm.background
        field.drawsBackground = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Put the field over `rect` in `view` and start editing.
    func begin(in view: NSView, rect: NSRect) {
        // 0.17: let the list make its rows first. A just-made item (New Folder) has no row view yet; one
        // made after the field was added is drawn OVER it, so the typing didn't show.
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        field.frame = rect
        view.addSubview(field)
        view.window?.makeFirstResponder(field)
        // Select the name without its extension (folders: everything), like Finder.
        let name = field.stringValue
        let len = entry.isFolderLike ? name.utf16.count : Paths.baseName(name).utf16.count
        if let ed = field.currentEditor() { ed.selectedRange = NSRange(location: 0, length: len) }
        for delay in [0.15, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.keepOnTop() }
        }
    }

    /// If anything was added over the field since, bring the field back to the top (text, cursor and
    /// selection kept).
    func keepOnTop() {
        guard !finished, let host = field.superview, host.subviews.last !== field else { return }
        let text = field.currentEditor()?.string ?? field.stringValue
        let range = field.currentEditor()?.selectedRange
        let d = field.delegate
        field.delegate = nil   // moving the field must not count as "editing ended"
        host.addSubview(field, positioned: .above, relativeTo: nil)
        field.stringValue = text
        host.window?.makeFirstResponder(field)
        if let r = range, let ed = field.currentEditor() { ed.selectedRange = r }
        field.delegate = d
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finish(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finish(commit: false)
            return true
        }
        return false
    }

    // Clicking elsewhere ends editing: commit, as Finder does.
    // Informal NSObject method in the 10.13 SDK (needs `override`); a protocol method in later SDKs.
    #if swift(>=4.2)
    func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: true)
    }
    #else
    override func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: true)
    }
    #endif

    func finish(commit: Bool) {
        if finished { return }
        finished = true
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        if commit { onCommit?(text) } else { onCancel?() }
    }
}

extension BrowserPane {

    /// Start renaming `e` in place (list or grid). Falls back to the dialog only if the item isn't shown.
    func beginInlineRename(_ e: FileEntry, text: String? = nil) {
        inlineEditor?.finish(commit: true)
        let host: NSView
        var rect: NSRect
        if viewMode == "list" {
            guard let node = list.node(forPath: e.path) else { renameWithDialog(e); return }
            let row = list.table.row(forItem: node)
            if row < 0 { renameWithDialog(e); return }
            list.table.scrollRowToVisible(row)
            let cell = list.table.frameOfCell(atColumn: 0, row: row)
            // The outline column's cell frame is already indented for nested rows; the name starts after the icon.
            let x = cell.minX + 22
            let h = max(20, ThemeManager.shared.font.pointSize + 9)
            rect = NSRect(x: x, y: cell.midY - h / 2, width: max(160, cell.maxX - x - 4), height: h)
            host = list.table
        } else {
            guard let r = grid.nameRect(forPath: e.path) else { renameWithDialog(e); return }
            rect = r
            host = grid
        }
        let ed = InlineEditor(entry: e, text: text ?? e.name)
        ed.onCommit = { [weak self] newName in
            guard let s = self else { return }
            s.inlineEditor = nil
            s.window?.makeFirstResponder(s.focusView)
            // Retry in place when the name needs changing (invalid, or a confirmation was declined).
            if let again = s.applyRename(e, to: newName) {
                DispatchQueue.main.async { s.beginInlineRename(e, text: again) }
            }
        }
        ed.onCancel = { [weak self] in
            guard let s = self else { return }
            s.inlineEditor = nil
            s.window?.makeFirstResponder(s.focusView)
        }
        inlineEditor = ed
        ed.begin(in: host, rect: rect)
    }
}
