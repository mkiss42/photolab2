// SettingsHelp.swift  (PhotoLab)
// Settings stay short: the long explanations under the controls are hidden and become the tooltip of
// the control they explain; the "?" button shows them all again (remembered). The search field finds
// any setting by its words (titles, menu choices, explanations): matching sections are marked in the
// list on the left and the first match in a section is scrolled to and outlined for a moment.
// Works on the built views, so every section (and any added later) takes part without changes.

import AppKit

final class SettingsHelp {
    static var shown: Bool {
        get { return UserDefaults.standard.bool(forKey: "settingsHelpShown") }
        set { UserDefaults.standard.set(newValue, forKey: "settingsHelpShown") }
    }

    /// An explanation and what to hide when explanations are off (the text, or its indented row).
    private struct Note { let view: NSView; let text: String }
    private var notes: [Note] = []

    /// Is this a long explanation (not a label, a value or a heading)?
    private static func isExplanation(_ t: NSTextField) -> Bool {
        if t.isEditable { return false }
        let s = t.stringValue
        guard s.count >= 70 else { return false }
        let wraps = (t.cell?.wraps ?? false) || t.maximumNumberOfLines != 1
        return wraps
    }

    /// The control an explanation belongs to: the arranged view before it in its stack (going up
    /// through one-item "indent" rows), else nothing.
    private static func target(for v: NSView) -> (hide: NSView, control: NSView?) {
        var item: NSView = v
        if let row = v.superview as? NSStackView, row.orientation == .horizontal, row.arrangedSubviews.count <= 2,
            row.arrangedSubviews.last === v {
            item = row
        }
        guard let stack = item.superview as? NSStackView, let i = stack.arrangedSubviews.index(where: { $0 === item }), i > 0 else {
            return (item, nil)
        }
        var prev: NSView? = stack.arrangedSubviews[i - 1]
        // A row: its first real control.
        if let r = prev as? NSStackView, r.orientation == .horizontal {
            prev = r.arrangedSubviews.first { $0 is NSControl && !($0 is NSTextField) } ?? r.arrangedSubviews.first
        }
        return (item, prev)
    }

    /// Collect the explanations on these pages, give their controls tooltips, and hide or show them.
    func install(pages: [NSView]) {
        notes.removeAll()
        for page in pages {
            var stack: [NSView] = [page]
            while let v = stack.popLast() {
                if let t = v as? NSTextField, SettingsHelp.isExplanation(t) {
                    let (hide, control) = SettingsHelp.target(for: t)
                    if let c = control, (c.toolTip ?? "").isEmpty { c.toolTip = t.stringValue }
                    if t.toolTip == nil { t.toolTip = t.stringValue }
                    notes.append(Note(view: hide, text: t.stringValue))
                    continue
                }
                if !(v is NSTableView) { stack.append(contentsOf: v.subviews) }
            }
        }
        apply()
    }

    func apply() {
        for n in notes { n.view.isHidden = !SettingsHelp.shown }
    }

    // MARK: Search

    /// Every searchable view on a page with its words.
    static func words(on page: NSView) -> [(view: NSView, text: String)] {
        var out: [(NSView, String)] = []
        var stack: [NSView] = [page]
        while let v = stack.popLast() {
            var t = ""
            if let b = v as? NSPopUpButton {
                t = b.itemTitles.joined(separator: " ")
            } else if let b = v as? NSButton {
                t = b.title
            } else if let f = v as? NSTextField, !f.isEditable {
                t = f.stringValue
            } else if let seg = v as? NSSegmentedControl {
                t = (0..<seg.segmentCount).compactMap { seg.label(forSegment: $0) }.joined(separator: " ")
            }
            if let tip = v.toolTip { t += " " + tip }
            if !t.trimmingCharacters(in: .whitespaces).isEmpty { out.append((v, t)) }
            if !(v is NSTableView) { stack.append(contentsOf: v.subviews) }
        }
        return out
    }

    /// Views on `page` whose words contain every word of `query`.
    static func matches(_ query: String, on page: NSView) -> [NSView] {
        let parts = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if parts.isEmpty { return [] }
        return words(on: page).filter { w in
            let low = w.text.lowercased()
            return parts.allSatisfyCompat { low.contains($0) }
        }.map { $0.view }
    }

    /// Scroll to `v` and outline it for a moment.
    static func flash(_ v: NSView) {
        v.scrollToVisible(v.bounds.insetBy(dx: -20, dy: -40))
        v.wantsLayer = true
        guard let l = v.layer else { return }
        let old = (l.borderWidth, l.borderColor, l.cornerRadius)
        l.borderWidth = 2
        l.borderColor = ThemeManager.shared.accent.cgColor
        l.cornerRadius = 4
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            l.borderWidth = old.0; l.borderColor = old.1; l.cornerRadius = old.2
        }
    }
}
