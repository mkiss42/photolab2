// InfoWindowController.swift
// Get Info (Cmd-I): the same contents as the inspector, in its own window, with a larger preview,
// photo metadata, Copy Info and (for folders) the folder size counted in the background. Read-only.

import AppKit

final class InfoWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [InfoWindowController] = []
    private let entry: FileEntry
    /// Position in the tiling: left to right from the top-left of the screen, then the next row down.
    private var slot = -1
    static let size = NSSize(width: 360, height: 600)
    private let inspector = InspectorController(previewHeight: 260)

    static func show(_ e: FileEntry) {
        let c = InfoWindowController(entry: e)
        c.tile()
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    init(entry: FileEntry) {
        self.entry = entry
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: InfoWindowController.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "\(entry.name) Info"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 300, height: 400)
        super.init(window: w)
        shouldCascadeWindows = false
        w.delegate = self
        let tm = ThemeManager.shared
        w.appearance = tm.appearance
        w.backgroundColor = tm.sidebar
        inspector.countsFolderSizes = true
        if let content = w.contentView {
            content.addSubview(inspector.view)
            inspector.view.pinEdges(to: content)
        }
        inspector.view.leftLine = nil
        inspector.show(entries: [entry], folder: Paths.parent(entry.path))
    }

    /// Take the first free slot: windows sit edge to edge from the top-left, wrapping to the next row
    /// (flush under the row above). When the screen is full, the tiling starts again at the top-left.
    private func tile() {
        guard let w = window, let vis = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame else { return }
        let f = w.frame
        let cols = max(1, Int(vis.width / f.width))
        let rows = max(1, Int(vis.height / f.height))
        let taken = Set(InfoWindowController.open.filter { $0.window?.isVisible == true }.map { $0.slot })
        var k = 0
        while taken.contains(k) { k += 1 }
        slot = k
        let col = k % cols
        let row = (k / cols) % rows
        w.setFrameOrigin(NSPoint(x: vis.minX + CGFloat(col) * f.width, y: vis.maxY - CGFloat(row + 1) * f.height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func windowWillClose(_ notification: Notification) {
        inspector.clear()
        window?.delegate = nil
        DispatchQueue.main.async {
            InfoWindowController.open = InfoWindowController.open.filter { $0 !== self }
        }
    }
}
