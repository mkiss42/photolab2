// DualPane.swift
// Commands between the panes of one window: Tab moves to the next pane; F5 copies and F6 moves the
// selection into the next pane's folder (the same safe copy / verify / no-overwrite path as everything
// else); Show Same Folder in Other Pane.

import AppKit

extension BrowserPane {

    var otherPane: BrowserPane? { return host?.pane(after: self) }
    var hasPartner: Bool { return otherPane != nil }

    /// Tab: go to the next pane.
    @objc func switchToOtherPane(_ sender: Any?) {
        guard let p = otherPane else { NSSound.beep(); return }
        host?.focus(p)
        window?.makeFirstResponder(p.focusView)
    }

    @objc func copyToOtherPane(_ sender: Any?) {
        if let b = ftpBrowser { b.copyToOtherPane(nil); return }
        sendToOtherPane(move: false)
    }
    @objc func moveToOtherPane(_ sender: Any?) { sendToOtherPane(move: true) }

    private func sendToOtherPane(move: Bool) {
        guard let p = otherPane else {
            showMessage("No other pane", "Open a second pane first (the split-box button next to the view buttons).", style: .informational)
            return
        }
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        if p.list.resultsMode {
            showMessage("The other pane shows search results", "Open a folder in the other pane to \(move ? "move" : "copy") items into it.", style: .informational)
            return
        }
        let dest = p.currentPath
        if sel.contains(where: { Paths.parent($0.path) == dest }) {
            showMessage("Same folder", "These items are already in \"\(Paths.lastComponent(dest))\".", style: .informational)
            return
        }
        if sel.contains(where: { $0.isFolderLike && (dest == $0.path || Paths.isInside(dest, root: $0.path)) }) {
            showMessage("Can't \(move ? "move" : "copy") a folder into itself", "The other pane is showing a folder inside the selection.")
            return
        }
        App.log.info("\(move ? "Move" : "Copy") \(sel.count) item(s) to other pane: \(dest)")
        transfer(sel.map { $0.path }, into: dest, move: move, withSidecars: viewMode == "photo", then: { [weak p] r in
            p?.refreshList(select: r.done.map { $0.to })
        })
    }

    /// Compare this pane's folder with the next pane's (or a chosen) folder.
    @objc func compareFolders(_ sender: Any?) {
        CompareFoldersWindow.show(from: self)
    }

    /// Find identical files in this pane's folder (and, if wanted, the other panes' folders).
    @objc func findDuplicates(_ sender: Any?) {
        DuplicatesWindow.show(from: self)
    }

    /// Show this pane's folder in the next pane too.
    @objc func sameFolderInOtherPane(_ sender: Any?) {
        guard let p = otherPane else { NSSound.beep(); return }
        p.navigate(to: currentPath)
    }
}
