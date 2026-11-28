// BrowserPane.swift
// One browser pane: tabs, navigation, path bar, search, view buttons, file list / grid, status bar.
// A Find window (BrowserWindowController) holds one or more panes side by side, plus the sidebar
// and the inspector, which serve whichever pane has the focus. As a view controller the pane sits in
// the responder chain behind its views, so menu commands reach the pane that has the keyboard.

import AppKit

final class BrowserTab {
    var path: String
    var back: [String] = []
    var forward: [String] = []
    var selection: [String] = []

    init(path: String) {
        self.path = path
    }
}

final class BrowserPane: NSViewController, FileTableActions, PathBarDelegate, TabBarDelegate {

    /// The window this pane lives in.
    weak var host: BrowserWindowController?
    private let fallbackUndo = UndoManager()
    /// One undo history per window, shared by its panes.
    var undoStack: UndoManager { return host?.undoStack ?? fallbackUndo }
    var window: NSWindow? { return view.window }   // the view is made in init (viewIfLoaded is 10.14+)
    private(set) var tabs: [BrowserTab] = []
    private(set) var active = 0
    let list = FileListController()
    let pathBar = PathBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
    let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
    let search = SearchBarController()
    let grid = ThumbnailGrid(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let gridScroll = NSScrollView()
    /// Blue frame over the thumbnails in Photography Mode (drawn on top; clicks pass through).
    let photoOutline = OutlineOverlay()
    let photoBar = PhotoBar(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
    var photoBarHeight: NSLayoutConstraint!
    var viewMode = Prefs.viewMode
    /// 0.17.1: closed (teardown done) - late callbacks do nothing.
    var isClosed = false
    var photoFilter = PhotoFilter()
    var photoFacts: [String: PhotoFacts] = [:]
    var photoFactsFolder = ""
    /// After a rating/metadata change: read the facts again without blanking the stars meanwhile.
    var keepFactsOnReload = false
    /// The metadata editor window open for this pane, if any.
    var metadataEditor: MetadataEditorWindow?
    /// 0.18: the open Find and Replace window of this pane.
    var findReplace: FindReplaceWindow?
    var factsProgress = (done: 0, total: 0)
    var syncingSelection = false
    var inlineEditor: InlineEditor?
    /// A new folder to start renaming in place once the list shows it.
    var pendingInlineRename: String?
    /// Scroll position per folder (list and grid), restored when coming back to it.
    var scrollMemory: [String: CGFloat] = [:]
    var pendingScroll: (path: String, y: CGFloat)?
    var gridShownPath = ""
    /// Opens another pane (the split-box button) and closes this one (the circled x).
    let splitButton = NSButton(image: ViewIcons.split, target: nil, action: nil)
    /// Opens another pane stacked (box with a horizontal divider).
    let stackButton = NSButton(image: ViewIcons.stack, target: nil, action: nil)
    /// Move this pane one place earlier / later (bottom right of the pane).
    private var moveEarlier: ThemedButton!
    private var moveLater: ThemedButton!
    let closeButton = NSButton(title: "", target: nil, action: nil)
    private(set) var isFocused = false
    let viewButtons = NSSegmentedControl(images: [ViewIcons.list, ViewIcons.grid, ViewIcons.camera],
                                         trackingMode: .selectOne, target: nil, action: nil)
    var searchEngine: SearchEngine?
    var lastSummary: SearchSummary?
    /// 0.16 Include subfolders: on/off, the folder whose tree is shown, and the current walk.
    var subfoldersOn = false
    /// 0.16: the FTP server this pane shows (nil: a local folder).
    var ftpBrowser: FTPBrowser?
    var recursiveRoot: String?
    var recursiveToken = 0
    var searchStatus = ""
    var pendingSearchFolders: [String] = []
    var lastFolderSizeOption = Prefs.calculateFolderSizes
    let mainPane = FillView()
    /// 0.17.4: Glass behind the list / thumbnails (its own setting), under the list area.
    private let contentGlassHost = FillView()
    private var contentGlass: GlassBacking?
    private let navRow = FillView()
    private let statusBar = FillView()
    /// 0.16: dim veil / focus glow over the whole pane (several panes only).
    let paneOverlay = PaneOverlay()
    private let statusLabel = makeLabel("")
    /// 0.17: turns while a remembered listing (FTP or network share) is checked in the background.
    let backgroundSpinner = NSProgressIndicator()
    var backgroundWrites = 0
    private var backgroundChecks = 0
    private let problemButton = makeButton("", nil, #selector(BrowserPane.showProblems(_:)))
    let overlay = makeLabel("")
    /// Shown under the message when a network share is disconnected.
    let reconnectButton: NSButton = {
        let b = NSButton(title: "Reconnect", target: nil, action: #selector(BrowserPane.reconnectShare(_:)))
        b.bezelStyle = .rounded
        b.toolTip = "Connect to the server again, at the same address"
        return b
    }()
    /// The network share (volume root) this pane lost, while the pane is still showing its place.
    var disconnectedRoot: String?
    /// "Connecting to ..." panel while a share is being connected, and which attempt it belongs to.
    var connectingPanel: ConnectingPanel?
    var connectTicket = 0
    private var backButton: ThemedButton!
    private var forwardButton: ThemedButton!
    private var upButton: ThemedButton!
    private var tabBarHeight: NSLayoutConstraint!
    private var freeSpaceText = ""
    private var observers: [NSObjectProtocol] = []


    var currentPath: String { return tabs.isEmpty ? NSHomeDirectory() : tabs[active].path }

    init(path: String, host: BrowserWindowController) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        view = mainPane
        mainPane.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        buildUI()
        tabs = [BrowserTab(path: path)]
        active = 0
        observe()
        applyTheme()
        showTab(0, select: [])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Layout

    private func buildUI() {
        navRow.isBar = true
        statusBar.isBar = true
        backButton = makeButton("\u{2190}", self, #selector(goBack(_:)), tip: "Back (Cmd-[)")
        forwardButton = makeButton("\u{2192}", self, #selector(goForward(_:)), tip: "Forward (Cmd-])")
        upButton = makeButton("\u{2191}", self, #selector(goUp(_:)), tip: "Enclosing Folder (Cmd-Up)")
        let navStack = NSStackView(views: [backButton, forwardButton, upButton])
        navStack.orientation = .horizontal
        navStack.spacing = 10
        navRow.addSubview(navStack)
        navRow.addSubview(pathBar)
        navRow.addSubview(search.field)
        navRow.addSubview(viewButtons)
        navRow.addSubview(splitButton)
        navRow.addSubview(stackButton)
        stackButton.target = self
        stackButton.action = #selector(openNewPaneStacked(_:))
        stackButton.isBordered = false
        stackButton.imageScaling = .scaleNone
        stackButton.toolTip = "Open another pane, panes stacked top to bottom"
        stackButton.translatesAutoresizingMaskIntoConstraints = false
        navRow.addSubview(closeButton)
        splitButton.target = self
        splitButton.action = #selector(openNewPane(_:))
        splitButton.isBordered = false
        splitButton.imageScaling = .scaleNone
        splitButton.toolTip = "Open another pane, panes side by side (Option-click a sidebar item to open it in a new pane)"
        splitButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(closePaneCommand(_:))
        closeButton.isBordered = false
        closeButton.toolTip = "Close this pane"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        viewButtons.target = self
        viewButtons.action = #selector(viewButtonClicked(_:))
        viewButtons.controlSize = .small
        viewButtons.segmentStyle = .texturedRounded
        viewButtons.setToolTip("as List (Cmd-1)", forSegment: 0)
        viewButtons.setToolTip("as Thumbnails (Cmd-2)", forSegment: 1)
        viewButtons.setToolTip("Photography Mode (Cmd-3)", forSegment: 2)
        viewButtons.translatesAutoresizingMaskIntoConstraints = false
        pathBar.delegate = self
        navStack.translatesAutoresizingMaskIntoConstraints = false
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        search.field.translatesAutoresizingMaskIntoConstraints = false
        // 0.17: two rows - the path bar alone on top (full width), everything else on the row below:
        // Back / Forward / Up on the left; views, new-pane buttons, search and close on the right.
        let row2 = navRow.bottomAnchor
        NSLayoutConstraint.activate([
            pathBar.leadingAnchor.constraint(equalTo: navRow.leadingAnchor, constant: 8),
            pathBar.trailingAnchor.constraint(equalTo: navRow.trailingAnchor, constant: -8),
            pathBar.topAnchor.constraint(equalTo: navRow.topAnchor, constant: 4),
            pathBar.heightAnchor.constraint(equalToConstant: 26),
            navStack.leadingAnchor.constraint(equalTo: navRow.leadingAnchor, constant: 10),
            navStack.centerYAnchor.constraint(equalTo: row2, constant: -15),
            viewButtons.leadingAnchor.constraint(greaterThanOrEqualTo: navStack.trailingAnchor, constant: 12),
            viewButtons.trailingAnchor.constraint(equalTo: splitButton.leadingAnchor, constant: -6),
            viewButtons.centerYAnchor.constraint(equalTo: row2, constant: -15),
            splitButton.trailingAnchor.constraint(equalTo: stackButton.leadingAnchor, constant: -2),
            splitButton.centerYAnchor.constraint(equalTo: row2, constant: -15),
            splitButton.widthAnchor.constraint(equalToConstant: 22),
            stackButton.trailingAnchor.constraint(equalTo: search.field.leadingAnchor, constant: -8),
            stackButton.centerYAnchor.constraint(equalTo: row2, constant: -15),
            stackButton.widthAnchor.constraint(equalToConstant: 22),
            search.field.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            search.field.centerYAnchor.constraint(equalTo: row2, constant: -15),
            closeButton.trailingAnchor.constraint(equalTo: navRow.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: row2, constant: -15),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            search.field.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            search.field.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])

        statusBar.addSubview(statusLabel)
        statusBar.addSubview(problemButton)
        backgroundSpinner.style = .spinning
        backgroundSpinner.controlSize = .small
        backgroundSpinner.isIndeterminate = true
        backgroundSpinner.isDisplayedWhenStopped = false
        backgroundSpinner.toolTip = "Checking this folder on the server in the background (the list shown is the one remembered from last time; it updates by itself if anything changed)"
        backgroundSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(backgroundSpinner)
        moveEarlier = makeButton("\u{25C0}", self, #selector(movePaneEarlier(_:)), tip: "Move this pane one place to the left (up when stacked)")
        moveLater = makeButton("\u{25B6}", self, #selector(movePaneLater(_:)), tip: "Move this pane one place to the right (down when stacked)")
        statusBar.addSubview(moveEarlier)
        statusBar.addSubview(moveLater)
        problemButton.target = self
        problemButton.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        problemButton.translatesAutoresizingMaskIntoConstraints = false
        moveEarlier.translatesAutoresizingMaskIntoConstraints = false
        moveLater.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            problemButton.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            problemButton.trailingAnchor.constraint(equalTo: backgroundSpinner.leadingAnchor, constant: -8),
            backgroundSpinner.trailingAnchor.constraint(equalTo: moveEarlier.leadingAnchor, constant: -8),
            backgroundSpinner.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            backgroundSpinner.widthAnchor.constraint(equalToConstant: 14),
            backgroundSpinner.heightAnchor.constraint(equalToConstant: 14),
            problemButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            moveEarlier.trailingAnchor.constraint(equalTo: moveLater.leadingAnchor, constant: -4),
            moveEarlier.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            moveLater.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            moveLater.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        statusLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 200), for: .horizontal)

        tabBar.delegate = self
        let wantWide = search.field.widthAnchor.constraint(equalToConstant: 220)
        wantWide.priority = NSLayoutConstraint.Priority(rawValue: 250)
        wantWide.isActive = true
        pathBar.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 300), for: .horizontal)
        contentGlassHost.translatesAutoresizingMaskIntoConstraints = false
        mainPane.addSubview(contentGlassHost)
        for v in [tabBar, navRow, search.bar, photoBar, list.scroll, gridScroll, statusBar] as [NSView] {
            mainPane.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        photoBarHeight = photoBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: mainPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            tabBarHeight,
            navRow.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            navRow.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            navRow.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            navRow.heightAnchor.constraint(equalToConstant: 62),
            search.bar.topAnchor.constraint(equalTo: navRow.bottomAnchor),
            search.bar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            search.bar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            search.heightConstraint,
            photoBar.topAnchor.constraint(equalTo: search.bar.bottomAnchor),
            photoBar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            photoBar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            photoBarHeight,
            list.scroll.topAnchor.constraint(equalTo: photoBar.bottomAnchor),
            gridScroll.topAnchor.constraint(equalTo: list.scroll.topAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: list.scroll.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: list.scroll.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: list.scroll.bottomAnchor),
            contentGlassHost.topAnchor.constraint(equalTo: list.scroll.topAnchor),
            contentGlassHost.bottomAnchor.constraint(equalTo: list.scroll.bottomAnchor),
            contentGlassHost.leadingAnchor.constraint(equalTo: list.scroll.leadingAnchor),
            contentGlassHost.trailingAnchor.constraint(equalTo: list.scroll.trailingAnchor),
            list.scroll.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            list.scroll.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            list.scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])

        mainPane.addSubview(photoOutline)
        photoOutline.translatesAutoresizingMaskIntoConstraints = false
        photoOutline.isHidden = true
        NSLayoutConstraint.activate([
            photoOutline.topAnchor.constraint(equalTo: gridScroll.topAnchor),
            photoOutline.bottomAnchor.constraint(equalTo: gridScroll.bottomAnchor),
            photoOutline.leadingAnchor.constraint(equalTo: gridScroll.leadingAnchor),
            photoOutline.trailingAnchor.constraint(equalTo: gridScroll.trailingAnchor),
        ])

        // 0.16: the dim veil / focus glow covers the whole pane; clicks go through it.
        mainPane.addSubview(paneOverlay)
        paneOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            paneOverlay.topAnchor.constraint(equalTo: mainPane.topAnchor),
            paneOverlay.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor),
            paneOverlay.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            paneOverlay.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
        ])

        overlay.alignment = .center
        overlay.isHidden = true
        overlay.maximumNumberOfLines = 4
        overlay.lineBreakMode = .byWordWrapping
        mainPane.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: list.scroll.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: list.scroll.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: list.scroll.widthAnchor, constant: -40),
        ])
        reconnectButton.target = self
        reconnectButton.isHidden = true
        mainPane.addSubview(reconnectButton)
        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            reconnectButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            reconnectButton.topAnchor.constraint(equalTo: overlay.bottomAnchor, constant: 14),
        ])

        list.table.actions = self
        list.table.onFocus = { [weak self] in self?.tookFocus() }
        list.table.onOptionClick = { [weak self] row in
            guard let s = self, let n = s.list.table.item(atRow: row) as? FileNode, n.entry.isFolderLike else { return false }
            s.openInNewPane(n.entry)
            return true
        }
        grid.onOptionClick = { [weak self] e in
            guard let s = self, e.isFolderLike else { return false }
            s.openInNewPane(e)
            return true
        }
        grid.onFocus = { [weak self] in self?.tookFocus() }
        list.onLoaded = { [weak self] in self?.listLoaded() }
        list.onRowsChanged = { [weak self] in self?.updateStatus() }
        list.factsProvider = { [weak self] p in self?.photoFacts[p] }
        list.onBackgroundCheck = { [weak self] on in self?.backgroundCheck(on) }
        list.holdReloads = { [weak self] in self?.inlineEditor != nil }
        list.onSelectionChanged = { [weak self] in
            guard let s = self else { return }
            s.updateStatus()
            s.updateInspector()
            if !s.syncingSelection && s.viewMode != "list" { s.grid.setSelection(paths: s.list.selectedPaths()) }
        }
        list.onRootsChanged = { [weak self] in self?.refreshGrid() }
        list.onOpen = { [weak self] e in self?.openClicked(e) }
        list.onFolderGone = { [weak self] p in self?.folderGone(p) }
        search.onSearch = { [weak self] in self?.startSearch() }
        search.onStop = { [weak self] in self?.stopSearch() }
        search.onClear = { [weak self] in self?.endSearchUI() }
        // The search options appear with the first letter typed, so scope, kind, size and so on can be
        // set before the search starts (Enter or Search starts it). Cleared again before searching: hidden.
        search.onTextChanged = { [weak self] text in
            guard let s = self else { return }
            if !text.isEmpty {
                if !s.search.isShown { s.search.show(true) }
            } else if !s.list.resultsMode && !s.search.running && s.search.isShown {
                s.search.show(false)
            }
        }
        setUpGrid()

    }

    /// Called once the window has its final frame (after placement).
    func finishLayout() {
        list.fitColumns()
    }

    private func observe() {
        let nc = NotificationCenter.default
        list.onDrop = { [weak self] paths, dest, move in self?.dropFiles(paths, into: dest, move: move) }
        // Files were dropped somewhere: panes showing a folder that changed reload it (the watcher would
        // too, but it is paused on some network shares).
        observers.append(nc.addObserver(forName: .findFoldersChanged, object: nil, queue: .main) { [weak self] n in
            guard let s = self, (n.object as? BrowserPane) !== s, !s.list.resultsMode,
                let folders = n.userInfo?["folders"] as? [String] else { return }
            let here = s.currentPath
            if folders.contains(where: { $0 == here || Paths.isInside($0, root: here) }) {
                s.refreshList(select: s.list.selectedPaths())
            }
        })
        observers.append(nc.addObserver(forName: .findThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        })
        observers.append(nc.addObserver(forName: .findPrefsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let s = self else { return }
            s.photoBar.refreshColorClassMenu()
            s.grid.needsDisplay = true
            s.list.spec.foldersFirst = Prefs.foldersFirst
            if s.lastFolderSizeOption != Prefs.calculateFolderSizes {
                s.lastFolderSizeOption = Prefs.calculateFolderSizes
                s.list.folderSizeOptionChanged()
                return
            }
            s.list.reload(showHidden: Prefs.showHidden)
        })
    }

    func applyTheme() {
        let tm = ThemeManager.shared
        mainPane.fillColor = tm.background
        navRow.fillColor = tm.sidebar
        paneOverlay.needsDisplay = true
        statusBar.needsDisplay = true
        navRow.bottomLine = isFocused && (host?.panes.count ?? 1) > 1 ? tm.accent : tm.separator
        closeButton.attributedTitle = attributed("\u{24E7}", font: NSFont.systemFont(ofSize: 14), color: tm.secondaryText)
        closeButton.isHidden = (host?.panes.count ?? 1) < 2
        moveEarlier.applyTheme("\u{25C0}")
        moveLater.applyTheme("\u{25B6}")
        moveEarlier.isHidden = (host?.panes.count ?? 1) < 2
        moveLater.isHidden = (host?.panes.count ?? 1) < 2
        statusBar.fillColor = tm.sidebar
        statusBar.topLine = tm.separator
        statusLabel.font = tm.smallFont
        statusLabel.textColor = tm.secondaryText
        overlay.font = tm.font
        overlay.textColor = tm.secondaryText
        backButton.applyTheme("\u{2190}")
        forwardButton.applyTheme("\u{2192}")
        upButton.applyTheme("\u{2191}")
        updateNavButtons()
        pathBar.applyTheme()
        search.applyTheme()
        list.applyTheme()
        photoBar.applyTheme()
        gridScroll.backgroundColor = tm.background
        applyContentGlass()
        grid.needsDisplay = true
        updateTabBar()
        updateStatus()
    }

    // MARK: Tabs

    func saveTabState() {
        guard active < tabs.count else { return }
        tabs[active].selection = list.resultsMode ? [] : list.selectedPaths()
    }

    private func showTab(_ i: Int, select: [String]) {
        guard i >= 0 && i < tabs.count else { return }
        active = i
        let t = tabs[i]
        endSearchUI(reload: false)
        list.load(t.path, selectPaths: select.isEmpty ? t.selection : select.map { Paths.join(t.path, $0) }, showHidden: Prefs.showHidden)
        pathBar.setPath(t.path)
        if isFocused { host?.paneChangedFolder(self) }
        updateTabBar()
        updateNavButtons()
        updateTitle()
    }

    private func updateTabBar() {
        let titles = tabs.map { Paths.lastComponent($0.path) == "/" ? "Computer" : Paths.lastComponent($0.path) }
        tabBar.setTabs(titles, active: active)
        tabBarHeight.constant = tabs.count > 1 ? 28 : 0
        tabBar.isHidden = tabs.count <= 1
    }

    func newTab(path: String) {
        saveTabState()
        tabs.insert(BrowserTab(path: path), at: active + 1)
        showTab(active + 1, select: [])
    }

    // MARK: Reopening (0.13)

    /// This pane as saved for the next start of Find.
    func savedState(size: Double) -> SavedPane {
        return SavedPane(tabs: tabs.map { SavedTab(path: $0.path) }, active: active, viewMode: viewMode, size: size)
    }

    /// Put back saved tabs. The pane was made showing the active tab's folder, so nothing is read twice.
    func restoreTabs(_ paths: [String], active a: Int) {
        guard !paths.isEmpty, a >= 0, a < paths.count else { return }
        let current = tabs.isEmpty ? nil : tabs[active]
        tabs = paths.enumerated().map { i, p in (i == a && current?.path == p) ? current! : BrowserTab(path: p) }
        active = a
        if tabs[a].path != current?.path { showTab(a, select: []) } else { updateTabBar(); updateNavButtons() }
    }

    /// Put back a saved view mode without changing the default for new windows.
    func restoreViewMode(_ m: String) {
        guard ["list", "grid", "photo"].contains(m), m != viewMode else { return }
        viewMode = m
        applyViewMode(focus: false)
    }

    func tabBarSelect(_ index: Int) {
        if index == active { return }
        saveTabState()
        showTab(index, select: [])
    }

    func tabBarClose(_ index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        if tabs.count == 1 {
            // Last tab: close this pane, or the window if it is the only pane.
            if let h = host, h.panes.count > 1 { h.closePane(self) } else { window?.performClose(nil) }
            return
        }
        saveTabState()
        tabs.remove(at: index)
        var next = active
        if index < active { next = active - 1 } else if index == active { next = min(index, tabs.count - 1) }
        showTab(next, select: [])
    }

    func tabBarNew() {
        newTab(path: currentPath)
    }

    // MARK: Navigation

    /// Go to a folder in the current tab.
    func navigate(to path: String, select: [String] = [], addHistory: Bool = true) {
        StallWatch.mark("going to \(path) (from \(currentPath))")
        // 0.17.2: a favourite that is a folder on an FTP server.
        if FTPFavorite.isFavorite(path) { openFTPFavorite(path); return }
        // A local folder chosen while the pane shows an FTP server: back to local folders.
        if isFTP { leaveFTP(reload: false) }
        endSearchUI(reload: false)
        let tab = tabs[active]
        if path == tab.path {
            list.load(path, select: select, showHidden: Prefs.showHidden)
            return
        }
        saveTabState()
        rememberScroll()
        if addHistory {
            tab.back.append(tab.path)
            if tab.back.count > 100 { tab.back.removeFirst() }
            tab.forward.removeAll()
        }
        tab.path = path
        tab.selection = []
        restoreScroll(for: path)
        list.load(path, select: select, showHidden: Prefs.showHidden)
        pathBar.setPath(path)
        Prefs.noteVisit(path)
        if isFocused { host?.paneChangedFolder(self) }
        updateNavButtons()
        updateTabBar()
        updateTitle()
    }

    @objc func goBack(_ sender: Any?) {
        if let b = ftpBrowser {
            // FTP: the previous FTP folder; at the first one, back to this pane's local folder.
            if !b.goBack() { leaveFTP(reload: true) }
            return
        }
        let tab = tabs[active]
        guard let prev = tab.back.popLast() else { NSSound.beep(); return }
        let from = tab.path
        tab.forward.append(from)
        navigate(to: prev, select: [Paths.lastComponent(from)], addHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        if let b = ftpBrowser { b.goForward(); return }
        let tab = tabs[active]
        guard let next = tab.forward.popLast() else { NSSound.beep(); return }
        tab.back.append(tab.path)
        navigate(to: next, addHistory: false)
    }

    @objc func goUp(_ sender: Any?) {
        if let tv = window?.firstResponder as? NSTextView {
            tv.moveToBeginningOfDocument(nil)
            return
        }
        if let b = ftpBrowser { b.goUp(); return }
        let p = currentPath
        if p == "/" { NSSound.beep(); return }
        navigate(to: Paths.parent(p), select: [Paths.lastComponent(p)])
    }

    private func updateNavButtons() {
        guard active < tabs.count else { return }
        if let b = ftpBrowser {
            backButton.isEnabled = true
            forwardButton.isEnabled = b.canGoForward
            upButton.isEnabled = !b.path.isEmpty
            return
        }
        backButton.isEnabled = !tabs[active].back.isEmpty
        forwardButton.isEnabled = !tabs[active].forward.isEmpty
        upButton.isEnabled = currentPath != "/"
    }

    /// Window title for this pane's folder ("title" itself belongs to NSViewController).
    var folderTitle: String {
        if let b = ftpBrowser { return b.title }
        let p = currentPath
        return p == "/" ? "Computer" : Paths.lastComponent(p)
    }

    func updateTitle() {
        if isFocused { host?.paneTitleChanged(self) }
    }

    /// 1.0.0-alpha.6: files dropped on a path bar folder.
    func pathBarDrop(_ paths: [String], into folder: String, move: Bool) {
        dropFiles(paths, into: folder, move: move)
    }

    func pathBarNavigate(_ path: String) {
        if let b = ftpBrowser, path.hasPrefix("ftp-crumb:") { b.crumbClicked(path); return }
        if BrowserPane.commandClick && !path.hasPrefix("ftp-crumb:") { openInNewWindow(path); return }
        navigate(to: path)
    }

    /// Typed path: checked off the main thread (network paths can be slow), then opened.
    func pathBarSubmit(_ text: String) {
        // A network address (\\server\share, smb://..., an IP address), as in Windows Explorer.
        if let addr = NetworkAddress.parse(text) {
            openNetworkAddress(addr)
            return
        }
        let p = Paths.normalize(text, home: NSHomeDirectory())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var e: Int32 = 0
            let info = Sys.statInfo(p, &e)
            DispatchQueue.main.async {
                guard let s = self else { return }
                if let i = info {
                    if i.isDirectory {
                        s.navigate(to: p)
                    } else {
                        s.navigate(to: Paths.parent(p), select: [Paths.lastComponent(p)])
                    }
                    s.window?.makeFirstResponder(s.focusView)
                } else {
                    s.showMessage("Can't go to \"\(p)\"", "\(Sys.errorText(e)) (code \(e)).")
                }
            }
        }
    }


    /// Before a volume is ejected: leave it (every tab), so Find doesn't keep it busy.
    func leaveVolume(_ root: String) {
        stopSearch()
        let home = NSHomeDirectory()
        for (i, t) in tabs.enumerated() where t.path == root || Paths.isInside(t.path, root: root) {
            if i == active {
                navigate(to: home)
            } else {
                t.path = home
                t.selection = []
            }
        }
        if list.resultsMode { endSearchUI() }
        updateTabBar()
    }


    private func folderGone(_ p: String) {
        guard p == currentPath else { return }
        // On a network share, "gone" may mean the server went away rather than the folder being deleted.
        // Check the share itself in the background (never on the main thread).
        if VolumeRegistry.shared.treatAsNetwork(p) {
            let root = VolumeRegistry.volumeRoot(p)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var e: Int32 = 0
                let rootThere = Sys.statInfo(root, &e) != nil && Paths.parent(root) == "/Volumes"
                let stillMounted = rootThere && Sys.statInfo(root, &e)?.device != Sys.statInfo("/Volumes", &e)?.device
                DispatchQueue.main.async {
                    guard let s = self, s.currentPath == p else { return }
                    if stillMounted {
                        s.folderReallyGone(p)
                    } else {
                        s.markDisconnected(root, reason: "the share is no longer mounted")
                    }
                }
            }
            return
        }
        folderReallyGone(p)
    }

    private func folderReallyGone(_ p: String) {
        var up = Paths.parent(p)
        while up != "/" && !Sys.exists(up) { up = Paths.parent(up) }
        Log.shared?.info("Folder moved or deleted while shown: \(p); going to \(up)")
        navigate(to: up)
        showMessage("The folder \"\(Paths.lastComponent(p))\" was moved or deleted.", "PhotoLab went to the nearest folder that still exists: \(up)")
    }

    // MARK: Quick Look and inspector

    /// Edit > Copy Info as Text (also on the right-click menu): numbered plain lines for AutoType,
    /// for the selected items (or the current folder), including photo metadata.
    @objc func copyInfoAsText(_ sender: Any?) {
        var entries = list.selectedEntries()
        if entries.isEmpty {
            var err: Int32 = 0
            if let e = FileEntry.make(path: currentPath, err: &err) { entries = [e] }
        }
        if entries.isEmpty { return }
        let limited = Array(entries.prefix(200))
        statusLabel.stringValue = "Collecting info for \(limited.count) item\(limited.count == 1 ? "" : "s")\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var all: [MetaSection] = []
            for e in limited { all += InspectorController.allSections(for: e) }
            let text = InspectorController.numberedText(all)
            DispatchQueue.main.async {
                guard let s = self else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                let more = entries.count > limited.count ? " (first \(limited.count) of \(entries.count))" : ""
                s.statusLabel.stringValue = "Copied info for \(limited.count) item\(limited.count == 1 ? "" : "s")\(more) as plain text"
                Log.shared?.info("Copy Info as Text: \(limited.count) items")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak s] in s?.updateStatus() }
            }
        }
    }

    @objc func fastPreview(_ sender: Any?) {
        if window?.firstResponder !== focusView { window?.makeFirstResponder(focusView) }
        list.quickLook.close()
        FastPreview.shared.toggle(for: list)
    }

    @objc func quickLook(_ sender: Any?) {
        FastPreview.shared.close()
        // The panel asks the focused view for its items, so the list must have focus.
        if window?.firstResponder !== focusView { window?.makeFirstResponder(focusView) }
        list.quickLook.toggle()
    }


    /// Remember how far down the current folder was scrolled (list and grid separately).
    func rememberScroll() {
        guard active < tabs.count, !list.resultsMode else { return }
        let p = tabs[active].path
        if viewMode == "list" {
            scrollMemory["L:" + p] = list.scrollY
        } else {
            scrollMemory["G:" + p] = gridScroll.contentView.bounds.origin.y
        }
        if scrollMemory.count > 1000 { scrollMemory.removeAll() }
    }

    /// Ask for the remembered scroll position of `path` to be restored once it has loaded.
    func restoreScroll(for path: String) {
        list.pendingScrollY = nil
        pendingScroll = nil
        if viewMode == "list" {
            if let y = scrollMemory["L:" + path] { list.pendingScrollY = y }
        } else if let y = scrollMemory["G:" + path] {
            pendingScroll = (path, y)
        }
    }

    /// The view that takes the keyboard: the list, or the thumbnail grid.
    var focusView: NSView {
        if let b = ftpBrowser { return b.table }
        return viewMode == "list" ? list.table : grid
    }

    func setStatusText(_ s: String) {
        statusLabel.stringValue = s
    }

    /// The window's inspector follows the focused pane.
    func updateInspector() {
        if isFocused { host?.updateInspector() }
    }

    // MARK: Status

    private func listLoaded() {
        updateInspector()
        if let p = pendingInlineRename, !list.loading, list.node(forPath: p) != nil {
            pendingInlineRename = nil
            let entry = list.node(forPath: p)!.entry
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                if s.viewMode != "list" { s.refreshGrid() }
                s.beginInlineRename(entry)
            }
        }
        let r = list.result
        let shareRoot = VolumeRegistry.volumeRoot(currentPath)
        let shareNotMounted = shareRoot != "/" && !VolumeRegistry.shared.isMounted(shareRoot) && VolumeRegistry.shared.remountURL(currentPath) != nil
            || shareRoot != "/" && !VolumeRegistry.shared.isMounted(shareRoot) && Prefs.savedServers.contains(where: { $0.parsed?.share?.lowercased() == Paths.lastComponent(shareRoot).lowercased() })
        if let fe = r.folderError, !list.resultsMode, fe.code == ENOENT && shareNotMounted {
            // A share that isn't connected (e.g. a window reopened before its server connected).
            markDisconnected(shareRoot, reason: "not connected")
            updateStatus()
            return
        }
        if let fe = r.folderError, !list.resultsMode, NetErrors.isConnectionLost(fe.code), VolumeRegistry.shared.treatAsNetwork(currentPath) {
            // The server stopped answering while this folder was read.
            markDisconnected(VolumeRegistry.volumeRoot(currentPath), reason: "\(fe.reason) (code \(fe.code))")
            updateStatus()
            return
        }
        if disconnectedRoot != nil && r.folderError == nil {
            clearDisconnected()
        }
        if let fe = r.folderError {
            overlay.stringValue = "Can't open this folder.\n\(fe.reason) (code \(fe.code))"
            overlay.textColor = ThemeManager.shared.warning
            overlay.isHidden = false
        } else if list.rootCount == 0 && !list.loading {
            if list.resultsMode {
                overlay.isHidden = true
                updateStatus()
                return
            }
            overlay.stringValue = r.hiddenSkipped > 0 ? "No visible items (\(r.hiddenSkipped) hidden)" : "This folder is empty"
            overlay.textColor = ThemeManager.shared.secondaryText
            overlay.isHidden = false
        } else {
            overlay.isHidden = true
        }
        updateStatus()
        if list.resultsMode { return }
        // 0.16: Photography mode with Include subfolders: this folder's whole tree.
        if r.folderError == nil && subfoldersOn && viewMode == "photo" {
            recursiveRoot = nil
            DispatchQueue.main.async { [weak self] in self?.recursiveAfterLoad() }
        }
        let p = currentPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let free = Volumes.freeSpace(p)
            DispatchQueue.main.async {
                guard let s = self, s.currentPath == p else { return }
                s.freeSpaceText = free.map { Listing.sizeText($0) + " available" } ?? ""
                s.updateStatus()
            }
        }
    }

    /// A temporary message in the status bar (the next updateStatus replaces it).
    func statusLabelText(_ t: String) {
        statusLabel.stringValue = t
    }

    /// 0.17.4: Glass behind this pane's list, thumbnails and FTP list (Settings > Appearance).
    func applyContentGlass() {
        let tm = ThemeManager.shared
        let g = Finish.contentGlass
        if contentGlass == nil { contentGlass = GlassBacking(in: contentGlassHost) }
        contentGlassHost.isHidden = g <= 0
        contentGlass?.apply(base: tm.background, strength: g)
        list.applyTheme()
        gridScroll.drawsBackground = g <= 0
        grid.glassBehind = g > 0
        grid.needsDisplay = true
        ftpBrowser?.applyTheme()
    }

    /// Background checks (network shares): the spinner turns while any is running.
    func backgroundCheck(_ on: Bool) {
        backgroundChecks = max(0, backgroundChecks + (on ? 1 : -1))
        setSpinner(backgroundChecks > 0 || (ftpBrowser?.refreshing ?? false))
    }

    /// 0.18.10: pictures of this pane whose ratings / colour classes are still being written behind.
    func metadataWriting(_ delta: Int) {
        backgroundWrites = max(0, backgroundWrites + delta)
        setSpinner(backgroundChecks > 0 || (ftpBrowser?.refreshing ?? false))
    }

    private func setSpinner(_ on: Bool) {
        let any = on || backgroundWrites > 0
        backgroundSpinner.toolTip = backgroundWrites > 0
            ? "Writing \(backgroundWrites) picture\(backgroundWrites == 1 ? "" : "s")' ratings / colour classes in the background (you can go on working; PhotoLab finishes them before it quits)"
            : "Checking this folder on the server in the background (the list shown is the one remembered from last time; it updates by itself if anything changed)"
        if any { backgroundSpinner.startAnimation(nil) } else { backgroundSpinner.stopAnimation(nil) }
    }

    func updateStatus() {
        if let b = ftpBrowser {
            setSpinner(b.refreshing || b.busy)
            statusLabel.textColor = ThemeManager.shared.secondaryText
            statusLabel.stringValue = b.status
            problemButton.isHidden = true
            updateNavButtons()
            return
        }
        if list.resultsMode {
            let tm = ThemeManager.shared
            statusLabel.stringValue = searchStatus
            let sel = list.table.selectedRowIndexes.count
            if sel > 0 { statusLabel.stringValue += "  \u{00B7}  \(sel) selected" }
            if let s = lastSummary, searchEngine == nil {
                problemButton.isHidden = false
                problemButton.attributedTitle = attributed(s.isComplete ? "Search details" : "What wasn't searched \u{2014} details",
                                                           font: tm.smallFont, color: s.isComplete ? tm.accent : tm.warning)
                statusLabel.textColor = s.isComplete ? tm.secondaryText : tm.warning
            } else {
                problemButton.isHidden = true
                statusLabel.textColor = tm.secondaryText
            }
            return
        }
        statusLabel.textColor = ThemeManager.shared.secondaryText
        let r = list.result
        var parts: [String] = []
        if list.loading {
            parts.append("Loading\u{2026} \(list.rootCount) items so far")
        } else {
            // 0.18.15: in the list, the items shown - with opened folders' contents - and, when that differs,
            // how many are in this folder itself.
            let shown = viewMode == "list" ? list.table.numberOfRows : list.rootCount
            let sc = list.setCounts
            if list.groupSets && sc.sets > 0 && shown == list.rootCount {
                // PhotoLab: "7 items (1 set, 9 total)"
                parts.append("\(shown) item\(shown == 1 ? "" : "s") (\(sc.sets) set\(sc.sets == 1 ? "" : "s"), \(sc.files) total)")
            } else {
                parts.append("\(shown) item\(shown == 1 ? "" : "s")" + (shown != list.rootCount ? " shown (\(list.rootCount) in this folder)" : ""))
            }
        }
        let sel = list.table.selectedRowIndexes.count
        if sel > 0 { parts.append("\(sel) selected") }
        if r.hiddenSkipped > 0 { parts.append("\(r.hiddenSkipped) hidden") }
        if !freeSpaceText.isEmpty { parts.append(freeSpaceText) }
        statusLabel.stringValue = parts.joined(separator: "  \u{00B7}  ")
        let tm = ThemeManager.shared
        let probs = r.problems.count + (r.folderError == nil ? 0 : 1)
        if probs > 0 && !list.loading {
            problemButton.isHidden = false
            problemButton.attributedTitle = attributed("\(probs) problem\(probs == 1 ? "" : "s") \u{2014} details", font: tm.smallFont, color: tm.warning)
        } else {
            problemButton.isHidden = true
        }
    }

    @objc func showProblems(_ sender: Any?) {
        if list.resultsMode, let s = lastSummary {
            showSearchReport(s)
            return
        }
        let r = list.result
        var lines: [String] = []
        if let fe = r.folderError { lines.append("Folder: \(fe.reason) (code \(fe.code))") }
        for p in r.problems.prefix(40) { lines.append("\(Paths.lastComponent(p.path)): \(p.reason)") }
        if r.problems.count > 40 { lines.append("\u{2026} and \(r.problems.count - 40) more (see the log)") }
        for p in r.problems { Log.shared?.warn("Unreadable item \(p.path): \(p.reason) (code \(p.code))") }
        showMessage("Some items in this folder could not be read", lines.joined(separator: "\n"))
    }

    func showMessage(_ title: String, _ info: String, style: NSAlert.Style = .warning) {
        let a = ThemedAlert()
        a.messageText = title
        a.informativeText = info
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: Table actions

    func tableRename() { renameSelected(nil) }
    func tableOpen() { openSelected(nil) }
    func tableGoUp() { goUp(nil) }
    func tableContextMenu() -> NSMenu? { return buildContextMenu() }
    func tableExpandAll() { list.expandSelectedRecursively() }
    func tableCollapseAll() { list.collapseSelectedRecursively() }

    // MARK: Focus and lifecycle

    /// The list or grid of this pane got the keyboard.
    func tookFocus() {
        host?.focus(self)
    }

    func setFocused(_ f: Bool) {
        if isFocused == f { return }
        isFocused = f
        paneOverlay.focused = f
        let tm = ThemeManager.shared
        navRow.bottomLine = f && (host?.panes.count ?? 1) > 1 ? tm.accent : tm.separator
        navRow.needsDisplay = true
    }

    func panesChanged() {
        let tm = ThemeManager.shared
        paneOverlay.several = (host?.panes.count ?? 1) > 1
        paneOverlay.focused = isFocused
        closeButton.isHidden = (host?.panes.count ?? 1) < 2
        let i = host?.panes.index(where: { $0 === self }) ?? 0
        let n = host?.panes.count ?? 1
        moveEarlier.isHidden = n < 2
        moveLater.isHidden = n < 2
        moveEarlier.isEnabled = i > 0
        moveLater.isEnabled = i < n - 1
        navRow.bottomLine = isFocused && (host?.panes.count ?? 1) > 1 ? tm.accent : tm.separator
        navRow.needsDisplay = true
    }

    /// The split-box buttons: a new pane at the start folder (Option-click: at this pane's folder),
    /// side by side or stacked (that becomes the window's layout).
    @objc func openNewPane(_ sender: Any?) {
        let alt = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        host?.addPane(path: alt ? currentPath : Prefs.startPath, after: self, stacked: false)
    }

    @objc func openNewPaneStacked(_ sender: Any?) {
        let alt = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        host?.addPane(path: alt ? currentPath : Prefs.startPath, after: self, stacked: true)
    }

    @objc func movePaneEarlier(_ sender: Any?) { host?.movePane(self, by: -1) }
    @objc func movePaneLater(_ sender: Any?) { host?.movePane(self, by: 1) }

    @objc func closePaneCommand(_ sender: Any?) {
        host?.closePane(self)
    }

    /// Narrowest useful width: 10 characters of a name plus the visible columns at their narrowest
    /// (and room for the pane's own path bar, view buttons and search field).
    var minimumWidth: CGFloat {
        return max(360, list.minimumUsefulWidth)
    }

    // An FTP pane disables the menu commands that would act on its hidden local list (0.16).
    #if swift(>=4.2)
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { return paneAllows(menuItem) }
    #else
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { return paneAllows(menuItem) }
    #endif

    /// Stop everything before the pane is removed.
    func teardown() {
        ftpBrowser?.stopRequested = true
        searchEngine?.cancel()
        if let b = ftpBrowser {
            b.table.delegate = nil
            b.table.dataSource = nil
            b.onChange = nil
        }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        list.shutdown()
        grid.shutdown()
        ExifToolKeeper.paneLeftPhotography("\(ObjectIdentifier(self).hashValue)")
        isClosed = true
    }

    // MARK: Undo / redo menu commands (used if the window doesn't handle undo: itself)

    @objc func undo(_ sender: Any?) {
        if let tv = window?.firstResponder as? NSTextView, let um = tv.undoManager, um.canUndo {
            um.undo()
            return
        }
        if undoStack.canUndo { undoStack.undo() } else { NSSound.beep() }
    }

    @objc func redo(_ sender: Any?) {
        if undoStack.canRedo { undoStack.redo() } else { NSSound.beep() }
    }
}

