// QuickLook.swift
// The native macOS Quick Look panel (QLPreviewPanel, public API since 10.6), fed with Find's selection.
// It uses the system's own Quick Look generators, so it previews exactly what Finder previews,
// including full screen, the index sheet for several items, and video/audio playback.
// Quick Look keeps its own preview cache inside macOS; Find adds no preview cache of its own.

import AppKit
import Quartz

final class QuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var table: FileTableView?
    /// Supplies the items to preview (the current selection).
    var selection: () -> [String] = { return [] }
    private var items: [NSURL] = []
    private(set) var controlling = false

    private var panel: QLPreviewPanel? {
        let p: QLPreviewPanel? = QLPreviewPanel.shared()
        return p
    }

    private var panelVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let p = panel else { return false }
        return p.isVisible
    }

    /// Space bar / Cmd-Y: open the panel, or close it if it is showing.
    func toggle() {
        if panelVisible {
            panel?.orderOut(nil)
            return
        }
        if selection().isEmpty {
            NSSound.beep()
            return
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        if panelVisible { panel?.orderOut(nil) }
    }

    // Called by FileTableView's panel-control methods.
    func begin(_ p: QLPreviewPanel?) {
        guard let p = p else { return }
        controlling = true
        reloadItems()
        p.dataSource = self
        p.delegate = self
        p.reloadData()
    }

    func end(_ p: QLPreviewPanel?) {
        controlling = false
        p?.dataSource = nil
        p?.delegate = nil
    }

    /// The selection changed (arrow keys, click): show the new item if the panel is open.
    func selectionChanged() {
        guard controlling, panelVisible, let p = panel else { return }
        reloadItems()
        if items.isEmpty {
            p.orderOut(nil)
            return
        }
        p.reloadData()
    }

    private func reloadItems() {
        items = selection().map { NSURL(fileURLWithPath: $0) }
    }

    // MARK: QLPreviewPanelDataSource

    @objc(numberOfPreviewItemsInPreviewPanel:)
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return items.count
    }

    @objc(previewPanel:previewItemAtIndex:)
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        if index < 0 || index >= items.count { return nil }
        return items[index]
    }

    // MARK: QLPreviewPanelDelegate

    /// Up/Down arrows move the selection in the list (as in Finder); the panel follows.
    /// Left/Right stay with the panel (it steps through several selected items itself).
    @objc(previewPanel:handleEvent:)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let e = event, e.type == .keyDown, let t = table else { return false }
        if e.keyCode == 125 || e.keyCode == 126 {
            t.keyDown(with: e)
            return true
        }
        if e.keyCode == 49 {   // Space closes, as in Finder
            close()
            return true
        }
        return false
    }
}
