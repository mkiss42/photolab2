// BrowserWindowController.swift
// One Find window: the sidebar, one or more browser panes, and the inspector.
// - Panes sit side by side when there is room (each at least `minimumWidth`), otherwise stacked;
//   side by side each pane's width can be dragged; stacked panes keep equal heights. Opening a pane keeps the window size unless
//   the panes can't fit at all; then the window grows (never beyond the screen).
// - The sidebar collapses by dragging its divider to the left edge, or Option-Cmd-S.
// - The inspector sits at the right edge and follows the focused pane; showing it widens the window
//   instead of squeezing the panes.

import AppKit

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, SidebarDelegate {
    let undoStack = UndoManager()
    let sidebar = SidebarController()
    let inspector = InspectorController()
    private(set) var panes: [BrowserPane] = []
    private(set) weak var focusedPane: BrowserPane?

    private let outer = ThemedSplitView()
    private let sidebarPane = FillView()
    private let workArea = FillView()
    private let paneSplit = ThemedSplitView()
    private var inspectorWidth: NSLayoutConstraint!
    private var observers: [NSObjectProtocol] = []
    private var lastSidebarWidth: CGFloat = 190
    /// 0.16 Glass under the sidebar.
    private var sidebarGlass: GlassBacking?
    /// The chosen pane layout: side by side (stacks by itself when too narrow) or always stacked.
    private(set) var preferStacked = false
    static let maxPanes = 6

    var onClose: ((BrowserWindowController) -> Void)?

    /// The focused pane (there is always at least one).
    var pane: BrowserPane { return focusedPane ?? panes[0] }
    var currentPath: String { return pane.currentPath }
    var focusView: NSView { return pane.focusView }

    /// PhotoLab: a contact sheet window - Photography mode only, tabs, no sidebar, no navigation.
    let isContactSheet: Bool

    init(path: String, contactSheet: Bool = false) {
        isContactSheet = contactSheet
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 300)
        super.init(window: w)
        // AppKit would otherwise offset ("cascade") each new window, knocking it out of its quarter.
        shouldCascadeWindows = false
        w.delegate = self
        buildUI()
        let first = BrowserPane(path: path, host: self)
        panes = [first]
        paneSplit.addSubview(first.view)
        focus(first)
        observe()
        applyTheme()
        sidebar.rebuild(currentPath: path)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Layout

    private func buildUI() {
        guard let w = window, let content = w.contentView else { return }
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.delegate = self
        content.addSubview(outer)
        outer.pinEdges(to: content)
        sidebarPane.frame = NSRect(x: 0, y: 0, width: 190, height: 600)
        workArea.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        if !isContactSheet { outer.addSubview(sidebarPane) }
        outer.addSubview(workArea)
        sidebarPane.addSubview(sidebar.scroll)
        sidebar.scroll.pinEdges(to: sidebarPane)
        sidebarGlass = GlassBacking(in: sidebarPane)
        sidebar.delegate = self

        paneSplit.isVertical = true
        paneSplit.dividerStyle = .thin
        paneSplit.delegate = self
        for v in [paneSplit, inspector.view] as [NSView] {
            workArea.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        inspectorWidth = inspector.view.widthAnchor.constraint(equalToConstant: Prefs.showInspector ? InspectorController.width : 0)
        inspector.view.isHidden = !Prefs.showInspector
        NSLayoutConstraint.activate([
            paneSplit.topAnchor.constraint(equalTo: workArea.topAnchor),
            paneSplit.bottomAnchor.constraint(equalTo: workArea.bottomAnchor),
            paneSplit.leadingAnchor.constraint(equalTo: workArea.leadingAnchor),
            paneSplit.trailingAnchor.constraint(equalTo: inspector.view.leadingAnchor),
            inspector.view.topAnchor.constraint(equalTo: workArea.topAnchor),
            inspector.view.bottomAnchor.constraint(equalTo: workArea.bottomAnchor),
            inspector.view.trailingAnchor.constraint(equalTo: workArea.trailingAnchor),
            inspectorWidth,
        ])
    }

    /// Called once the window has its final frame (after placement).
    func finishLayout() {
        window?.contentView?.layoutSubtreeIfNeeded()
        outer.adjustSubviews()
        if isContactSheet { for p in panes { p.finishLayout() }; return }
        let sw = CGFloat(UserDefaults.standard.double(forKey: Prefs.Key.sidebarWidth))
        lastSidebarWidth = sw >= 120 ? sw : 190
        if UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
            outer.setPosition(0, ofDividerAt: 0)
        } else {
            outer.setPosition(lastSidebarWidth, ofDividerAt: 0)
        }
        for p in panes { p.finishLayout() }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .findThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        })
        observers.append(nc.addObserver(forName: .findFinishChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyFinish()
        })
        observers.append(nc.addObserver(forName: .findVolumesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let s = self else { return }
            s.sidebar.rebuild(currentPath: s.currentPath)
        })
    }

    /// 0.16: Depth / Glow / Glass / Dim changed - glass on or off, then everything redrawn.
    func applyFinish() {
        let tm = ThemeManager.shared
        sidebarGlass?.apply(base: tm.sidebar)
        sidebar.applyFinish()
        for p in panes { p.applyContentGlass() }
        inspector.applyFinish()
        func redraw(_ v: NSView) {
            v.needsDisplay = true
            for s in v.subviews { redraw(s) }
        }
        if let c = window?.contentView { redraw(c) }
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        window?.appearance = tm.appearance
        window?.backgroundColor = tm.sidebar
        outer.dividerTint = tm.separator
        outer.needsDisplay = true
        paneSplit.dividerTint = tm.separator
        paneSplit.needsDisplay = true
        sidebarPane.fillColor = tm.sidebar
        sidebarGlass?.apply(base: tm.sidebar)
        workArea.fillColor = tm.background
        sidebar.applyTheme()
        inspector.applyTheme()
        FastPreview.shared.applyTheme()
    }

    // MARK: Sidebar (collapse by dragging, or Option-Cmd-S)

    var sidebarCollapsed: Bool { return isContactSheet || outer.isSubviewCollapsed(sidebarPane) || sidebarPane.frame.width < 1 }

    @objc func toggleSidebar(_ sender: Any?) {
        if isContactSheet { NSSound.beep(); return }
        if sidebarCollapsed {
            outer.setPosition(lastSidebarWidth, ofDividerAt: 0)
            UserDefaults.standard.set(false, forKey: "sidebarCollapsed")
        } else {
            lastSidebarWidth = max(120, sidebarPane.frame.width)
            outer.setPosition(0, ofDividerAt: 0)
            UserDefaults.standard.set(true, forKey: "sidebarCollapsed")
        }
        for p in panes { p.finishLayout() }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return splitView === outer && subview === sidebarPane
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === outer { return 120 }
        // Stacked panes keep equal heights: panes are only resized side to side.
        if !paneSplit.isVertical { return paneSplit.subviews[dividerIndex].frame.maxY }
        // Pane dividers: keep the pane before the divider at its minimum size.
        let before = paneSplit.subviews[dividerIndex]
        let start = paneSplit.isVertical ? before.frame.minX : before.frame.minY
        return start + minimumExtent(of: dividerIndex)
    }

    /// PhotoLab (from PhotoLab 2): the sidebar divider snaps to 160 px within 10 px of it.
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === outer && !isContactSheet && proposedPosition > 1 && abs(proposedPosition - 160) <= 10 { return 160 }
        return proposedPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === outer {
            if splitView.bounds.width < 600 { return max(120, proposedMaximumPosition) }
            return min(420, splitView.bounds.width - 300)
        }
        if !paneSplit.isVertical { return paneSplit.subviews[dividerIndex].frame.maxY }
        let after = paneSplit.subviews[dividerIndex + 1]
        let end = paneSplit.isVertical ? after.frame.maxX : after.frame.maxY
        return end - minimumExtent(of: dividerIndex + 1)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        if splitView === outer { return view !== sidebarPane }
        return true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sv = notification.object as? NSSplitView else { return }
        if sv === outer && !isContactSheet {
            let w = sidebarPane.frame.width
            if w >= 120 {
                lastSidebarWidth = w
                UserDefaults.standard.set(Double(w), forKey: Prefs.Key.sidebarWidth)
                UserDefaults.standard.set(false, forKey: "sidebarCollapsed")
            } else if w < 1 {
                UserDefaults.standard.set(true, forKey: "sidebarCollapsed")
            }
        }
        for p in panes { p.list.fitColumns() }
    }

    private func minimumExtent(of index: Int) -> CGFloat {
        guard index < panes.count else { return 200 }
        return paneSplit.isVertical ? panes[index].minimumWidth : BrowserWindowController.minPaneHeight
    }

    static let minPaneHeight: CGFloat = 240

    // MARK: Panes

    /// Focus a pane: the inspector, sidebar highlight and window title follow it.
    func focus(_ p: BrowserPane) {
        if focusedPane === p { return }
        focusedPane = p
        for q in panes { q.setFocused(q === p) }
        paneChangedFolder(p)
        paneTitleChanged(p)
        updateInspector()
    }

    func paneChangedFolder(_ p: BrowserPane) {
        guard p === focusedPane else { return }
        sidebar.rebuild(currentPath: p.currentPath)
    }

    func paneTitleChanged(_ p: BrowserPane) {
        guard p === focusedPane else { return }
        window?.title = p.list.resultsMode ? (window?.title ?? p.folderTitle) : p.folderTitle
    }

    /// Open a new pane after `after` (or at the end) showing `path`.
    @discardableResult
    func addPane(path: String, after: BrowserPane? = nil, stacked: Bool? = nil) -> BrowserPane? {
        if let st = stacked { preferStacked = st }
        if panes.count >= BrowserWindowController.maxPanes {
            pane.showMessage("Up to \(BrowserWindowController.maxPanes) panes", "Close a pane (the circled x at its top right) to open another.", style: .informational)
            return nil
        }
        let p = BrowserPane(path: path, host: self)
        let index = after.flatMap { a in panes.index(where: { $0 === a }) }.map { $0 + 1 } ?? panes.count
        panes.insert(p, at: index)
        if index >= paneSplit.subviews.count {
            paneSplit.addSubview(p.view)
        } else {
            paneSplit.addSubview(p.view, positioned: .below, relativeTo: paneSplit.subviews[index])
        }
        for q in panes { q.panesChanged() }
        arrangePanes(growIfNeeded: true, equalize: true)
        focus(p)
        window?.makeFirstResponder(p.focusView)
        App.log.info("Pane opened (\(panes.count) panes): \(path)")
        return p
    }

    func closePane(_ p: BrowserPane) {
        guard panes.count > 1, let i = panes.index(where: { $0 === p }) else { return }
        p.teardown()
        p.view.removeFromSuperview()
        panes.remove(at: i)
        for q in panes { q.panesChanged() }
        arrangePanes(growIfNeeded: false, equalize: true)
        let next = panes[min(i, panes.count - 1)]
        focusedPane = nil
        focus(next)
        window?.makeFirstResponder(next.focusView)
        App.log.info("Pane closed (\(panes.count) left)")
    }

    /// Side by side when every pane gets its minimum width; otherwise stacked. If even stacking
    /// doesn't fit and `growIfNeeded`, the window grows (within the screen).
    func arrangePanes(growIfNeeded: Bool, equalize: Bool) {
        guard let w = window else { return }
        let n = CGFloat(panes.count)
        let divider = paneSplit.dividerThickness
        let needW = panes.reduce(CGFloat(0)) { $0 + $1.minimumWidth } + divider * (n - 1)
        let needH = BrowserWindowController.minPaneHeight * n + divider * (n - 1)
        var avail = paneSplit.frame.size
        if avail.width < 1 { w.contentView?.layoutSubtreeIfNeeded(); avail = paneSplit.frame.size }
        var vertical = !preferStacked && avail.width >= needW
        if preferStacked && avail.height < needH && growIfNeeded, let screen = w.screen ?? NSScreen.main {
            // Stacked by choice but too short: make the window taller, as far as the screen allows.
            let vis = screen.visibleFrame
            var f = w.frame
            let newH = min(vis.height, f.height + (needH - avail.height))
            f.origin.y = max(vis.minY, f.maxY - newH)
            f.size.height = newH
            w.setFrame(f, display: true)
            w.contentView?.layoutSubtreeIfNeeded()
            avail = paneSplit.frame.size
        }
        if !preferStacked && !vertical && avail.height < needH && growIfNeeded, let screen = w.screen ?? NSScreen.main {
            // Too small either way: widen the window (side by side), as far as the screen allows.
            let vis = screen.visibleFrame
            var f = w.frame
            let extra = needW - avail.width
            let newW = min(vis.width, f.width + extra)
            f.origin.x = max(vis.minX, min(f.origin.x, vis.maxX - newW))
            f.size.width = newW
            w.setFrame(f, display: true)
            w.contentView?.layoutSubtreeIfNeeded()
            avail = paneSplit.frame.size
            vertical = avail.width >= needW - 1
        }
        let changed = paneSplit.isVertical != vertical
        paneSplit.isVertical = vertical
        paneSplit.adjustSubviews()
        if equalize || changed || !vertical {
            let total = (vertical ? avail.width : avail.height) - divider * (n - 1)
            let each = total / n
            for i in 0..<(panes.count - 1) {
                paneSplit.setPosition(CGFloat(i + 1) * each + CGFloat(i) * divider, ofDividerAt: i)
            }
        }
        for p in panes { p.list.fitColumns(); p.refreshGridLayout() }
        updateMinSize()
    }

    /// Move a pane one place earlier (-1) or later (+1); the panes keep their sizes.
    func movePane(_ p: BrowserPane, by d: Int) {
        guard let i = panes.index(where: { $0 === p }) else { return }
        let j = i + d
        guard j >= 0 && j < panes.count else { NSSound.beep(); return }
        let vertical = paneSplit.isVertical
        var sizes = panes.map { vertical ? $0.view.frame.width : $0.view.frame.height }
        panes.swapAt(i, j)
        sizes.swapAt(i, j)
        for v in paneSplit.subviews { v.removeFromSuperview() }
        for q in panes { paneSplit.addSubview(q.view) }
        paneSplit.adjustSubviews()
        var pos: CGFloat = 0
        for k in 0..<(panes.count - 1) {
            pos += sizes[k]
            paneSplit.setPosition(pos, ofDividerAt: k)
            pos += paneSplit.dividerThickness
        }
        for q in panes { q.panesChanged(); q.list.fitColumns(); q.refreshGridLayout() }
        window?.makeFirstResponder(p.focusView)
    }

    /// Window menu: arrange the existing panes without opening a new one.
    @objc func arrangePanesSideBySide(_ sender: Any?) {
        preferStacked = false
        arrangePanes(growIfNeeded: true, equalize: true)
    }

    @objc func arrangePanesStacked(_ sender: Any?) {
        preferStacked = true
        arrangePanes(growIfNeeded: true, equalize: true)
    }

    private func updateMinSize() {
        guard let w = window else { return }
        let side = sidebarCollapsed ? 0 : sidebarPane.frame.width
        let insp = inspector.view.isHidden ? 0 : InspectorController.width
        let widest = panes.map { $0.minimumWidth }.max() ?? 360
        w.minSize = NSSize(width: max(520, side + insp + widest), height: paneSplit.isVertical ? 300 : BrowserWindowController.minPaneHeight * CGFloat(panes.count))
    }

    /// The pane after `p` (wrapping), for Tab and F5 / F6.
    func pane(after p: BrowserPane) -> BrowserPane? {
        guard panes.count > 1, let i = panes.index(where: { $0 === p }) else { return nil }
        return panes[(i + 1) % panes.count]
    }

    // MARK: Inspector

    var inspectorShown: Bool { return !inspector.view.isHidden }

    func updateInspector() {
        guard inspectorShown, let p = focusedPane else { return }
        inspector.show(entries: p.list.selectedRowEntries(), folder: p.currentPath)   // a set: its representative
    }

    /// Show/hide the inspector. Showing it widens the window (the panes keep their size) as far as the
    /// screen allows; hiding it gives the width back.
    @objc func toggleInspector(_ sender: Any?) {
        guard let w = window else { return }
        let show = inspector.view.isHidden
        Prefs.showInspector = show
        var f = w.frame
        let iw = InspectorController.width
        if let vis = (w.screen ?? NSScreen.main)?.visibleFrame {
            if show {
                let grow = min(iw, max(0, vis.width - f.width))
                f.size.width += grow
                if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }
            } else {
                f.size.width = max(w.minSize.width, f.width - iw)
            }
        }
        inspector.view.isHidden = !show
        inspectorWidth.constant = show ? iw : 0
        w.setFrame(f, display: true)
        w.contentView?.layoutSubtreeIfNeeded()
        arrangePanes(growIfNeeded: false, equalize: false)
        if show { updateInspector() } else { inspector.clear() }
        Log.shared?.info("Inspector \(show ? "shown" : "hidden")")
    }

    // MARK: Reopening (0.13)

    /// Everything about this window that is put back at the next start (not the display or desktop:
    /// the app delegate adds those).
    func savedState() -> SavedWindow? {
        guard let w = window, !isContactSheet else { return nil }   // contact sheets keep only their size
        let vertical = paneSplit.isVertical
        let ps = panes.map { $0.savedState(size: Double(vertical ? $0.view.frame.width : $0.view.frame.height)) }
        let f = w.frame
        return SavedWindow(frame: [Double(f.origin.x), Double(f.origin.y), Double(f.width), Double(f.height)],
                           display: nil, displayFrame: nil, space: nil,
                           sidebarCollapsed: sidebarCollapsed, sidebarWidth: Double(sidebarCollapsed ? lastSidebarWidth : sidebarPane.frame.width),
                           inspector: inspectorShown, stacked: preferStacked, panes: ps,
                           focused: panes.index(where: { $0 === focusedPane }) ?? 0, minimized: w.isMiniaturized, shares: nil)
    }

    /// Show or hide the Info panel without changing the window size (used when reopening: the saved
    /// window size already includes it).
    func setInspectorShown(_ show: Bool) {
        guard show != inspectorShown else { return }
        inspector.view.isHidden = !show
        inspectorWidth.constant = show ? InspectorController.width : 0
        window?.contentView?.layoutSubtreeIfNeeded()
        if show { updateInspector() } else { inspector.clear() }
    }

    /// Put back panes, tabs, view modes, sidebar, Info panel and pane sizes. The window already has its
    /// frame and its first pane (showing `paths(0)`'s active folder). `paths(i)` gives pane i's usable folders.
    func restore(_ s: SavedWindow, paths: (Int) -> [String]) {
        setInspectorShown(s.inspector)
        // Sidebar
        if s.sidebarCollapsed {
            if s.sidebarWidth >= 120 { lastSidebarWidth = CGFloat(s.sidebarWidth) }
            outer.setPosition(0, ofDividerAt: 0)
        } else {
            let sw = CGFloat(min(420, max(120, s.sidebarWidth)))
            lastSidebarWidth = sw
            outer.setPosition(sw, ofDividerAt: 0)
        }
        // Panes and tabs
        let count = min(s.panes.count, BrowserWindowController.maxPanes)
        preferStacked = s.stacked
        for i in 0..<count {
            let sp = s.panes[i]
            let ps = paths(i)
            guard !ps.isEmpty else { continue }
            let a = max(0, min(sp.active, ps.count - 1))
            let p: BrowserPane
            if i == 0 {
                p = panes[0]
            } else {
                guard let np = addPane(path: ps[a], after: panes.last, stacked: s.stacked) else { break }
                p = np
            }
            p.restoreTabs(ps, active: a)
            p.restoreViewMode(sp.viewMode)
        }
        arrangePanes(growIfNeeded: false, equalize: true)
        // Side by side: the saved widths, if they still fit.
        if paneSplit.isVertical && panes.count > 1 && s.panes.count >= panes.count {
            let sizes = s.panes.prefix(panes.count).map { CGFloat($0.size) }
            let divider = paneSplit.dividerThickness
            let total = paneSplit.frame.width - divider * CGFloat(panes.count - 1)
            var fits = sizes.reduce(0, +) <= total + 2
            for (i, p) in panes.enumerated() where sizes[i] < p.minimumWidth - 1 { fits = false }
            if fits {
                var pos: CGFloat = 0
                for k in 0..<(panes.count - 1) {
                    pos += sizes[k]
                    paneSplit.setPosition(pos, ofDividerAt: k)
                    pos += divider
                }
                for p in panes { p.list.fitColumns(); p.refreshGridLayout() }
            }
        }
        let f = max(0, min(s.focused, panes.count - 1))
        focus(panes[f])
        window?.makeFirstResponder(panes[f].focusView)
        for p in panes { p.finishLayout() }
    }

    // MARK: Sidebar delegate

    func sidebarNavigate(_ path: String) {
        // Option-click: open in a new pane. Deferred so the sidebar finishes its own selection change first.
        let newPane = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let newWindow = BrowserPane.commandClick   // 0.17.7: Cmd-click = a new window, as in Finder
        DispatchQueue.main.async { [weak self] in
            guard let s = self else { return }
            if newWindow {
                s.sidebar.sync(to: s.pane.currentPath)   // this window keeps showing where it was
                if FTPFavorite.isFavorite(path) {
                    s.pane.openFTPFavoriteInNewWindow(path)
                } else {
                    s.pane.openInNewWindow(path)
                }
                return
            }
            if FTPFavorite.isFavorite(path) {
                // A folder on an FTP server: in this pane, or (Option) in a new pane next to it.
                let target = newPane ? s.addPane(path: s.pane.currentPath, after: s.focusedPane) : s.pane
                target?.openFTPFavorite(path)
                return
            }
            if newPane {
                s.addPane(path: path, after: s.focusedPane)
            } else {
                s.pane.navigate(to: path)
                s.window?.makeFirstResponder(s.pane.focusView)
            }
        }
    }

    func sidebarOpenInNewTab(_ path: String) {
        if FTPFavorite.isFavorite(path) { pane.openFTPFavorite(path); return }
        pane.newTab(path: path)
    }

    func sidebarEject(_ path: String) {
        (NSApp.delegate as? AppDelegate)?.ejectVolume(path)
    }

    func sidebarOpenServer(_ server: SavedServer) {
        // Cmd-click (0.17.7): in a new window.
        if BrowserPane.commandClick {
            let c = (NSApp.delegate as? AppDelegate)?.newWindow(path: pane.currentPath)
            sidebar.sync(to: pane.currentPath)
            c?.pane.openSavedServer(server)
            return
        }
        // Option-click: in a new pane (any number of FTP or share panes side by side).
        if let e = NSApp.currentEvent, e.modifierFlags.contains(.option),
            let p = addPane(path: pane.currentPath, after: pane) {
            p.openSavedServer(server)
            return
        }
        pane.openSavedServer(server)
    }

    func sidebarOpenServerInNewPane(_ server: SavedServer) {
        if let p = addPane(path: pane.currentPath, after: pane) { p.openSavedServer(server) }
    }

    func sidebarDrop(_ paths: [String], into dest: String, move: Bool) {
        pane.dropFiles(paths, into: dest, move: move)
    }

    func leaveVolume(_ root: String) {
        for p in panes { p.leaveVolume(root) }
    }

    func shareUnmounted(_ root: String, wasNetwork: Bool) {
        for p in panes { p.shareUnmounted(root, wasNetwork: wasNetwork) }
    }

    func shareMounted(_ root: String) {
        for p in panes { p.shareMounted(root) }
    }

    // MARK: Menu commands go to the focused pane when the keyboard is elsewhere (e.g. the sidebar)

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let p = focusedPane, p.responds(to: action) { return p }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        return undoStack
    }

    func windowDidResize(_ notification: Notification) {
        arrangePanes(growIfNeeded: false, equalize: false)
    }

    func windowDidMove(_ notification: Notification) {
        if isContactSheet { saveContactSheetFrame(); return }
        (NSApp.delegate as? AppDelegate)?.saveWindowsSoon()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if isContactSheet { saveContactSheetFrame(); return }
        (NSApp.delegate as? AppDelegate)?.saveWindowsSoon()
    }

    // MARK: PhotoLab contact sheet window geometry (80% of the screen, centred, until moved or sized)

    static let contactSheetFrameKey = "contactSheetFrame"

    private func saveContactSheetFrame() {
        guard let f = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(f), forKey: BrowserWindowController.contactSheetFrameKey)
    }

    static func contactSheetFrame() -> NSRect {
        if let s = UserDefaults.standard.string(forKey: contactSheetFrameKey) {
            let r = NSRectFromString(s)
            if r.width >= 400 && r.height >= 300 && NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { return r }
        }
        let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w = (v.width * 0.8).rounded(), h = (v.height * 0.8).rounded()
        return NSRect(x: v.minX + (v.width - w) / 2, y: v.minY + (v.height - h) / 2, width: w, height: h)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        sidebar.rebuild(currentPath: currentPath)
    }

    func windowWillClose(_ notification: Notification) {
        for p in panes { p.teardown() }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        sidebar.table.delegate = nil
        sidebar.table.dataSource = nil
        outer.delegate = nil
        paneSplit.delegate = nil
        window?.delegate = nil
        DispatchQueue.main.async {
            self.onClose?(self)
        }
    }
}

/// Split view with a theme-colored divider.
final class ThemedSplitView: NSSplitView {
    var dividerTint: NSColor = .gray

    override var dividerColor: NSColor {
        return dividerTint
    }
}
