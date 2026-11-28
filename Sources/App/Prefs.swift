// Prefs.swift
// Persistent preferences (UserDefaults, i.e. ~/Library/Preferences/<bundle id>.plist).

import AppKit

enum Prefs {
    enum Key {
        static let currentTheme = "currentTheme"
        static let showHidden = "showHidden"
        static let foldersFirst = "foldersFirst"
        static let sortColumn = "sortColumn"
        static let sortAscending = "sortAscending"
        static let visibleColumns = "visibleColumns4"   // 4 (PhotoLab): Modified + Size + Ext
        static let columnWidths = "columnWidths2"
        static let favorites = "favorites"
        static let favoriteNames = "favoriteNames"
        static let recents = "recents"
        static let visitCounts = "visitCounts"
        static let startMode = "startMode"        // "home", "last", "custom"
        static let startPath = "startPath"
        static let lastPath = "lastPath"
        static let sidebarWidth = "sidebarWidth"
        static let folderSizes = "calculateFolderSizes"
        static let sidebarOrder = "sidebarOrder"
        static let sidebarItemOrder = "sidebarItemOrder"
        static let colorClassNames = "colorClassNames"
        static let photoArrowSteps = "photoArrowSteps"
        static let finishDepth = "finishDepth"
        static let customKeys = "customKeys"
        static let copyDiagnostics = "copyDiagnostics"
        static let starModifier = "starModifier"
        static let colourModifier = "colourModifier"
        static let finishGlow = "finishGlow"
        static let finishGlass = "finishGlass"
        static let finishContentGlass = "finishContentGlass"
        static let finishDim = "finishDim"
        static let colorClassColors = "colorClassColors"
        static let sidebarHidden = "sidebarHidden"
        static let sidebarCollapsed = "sidebarCollapsed"
        static let recentCount = "recentCount"
        static let frequentCount = "frequentCount"
        static let showInspector = "showInspector"
        static let spaceOpensQuickLook = "spaceOpensQuickLook"
        static let previewFrame = "fastPreviewFrame"
        static let viewMode = "viewMode"
        static let thumbSize = "thumbSize"
        // Storage & Maintenance
        static let maintAuto = "maintAutomatic"
        static let maintStartup = "maintAtStartup"
        static let maintQuit = "maintAtQuit"
        static let maintEveryHours = "maintEveryHours"
        static let maintTempHours = "maintTempHours"
        static let maintLogDays = "maintLogDays"
        static let previewLimitMB = "previewLimitMB"
        // Network
        static let netListingSeconds = "netListingSeconds"
        static let netFolderSizes = "netFolderSizes"
        static let netSearchReaders = "netSearchReaders"
        static let netShowDisconnect = "netShowDisconnect"
        // Advanced
        static let debugLogging = "debugLogging"
        // Servers (0.13) and window sessions
        static let savedServers = "savedServers"
        static let reopenWindows = "reopenWindows"
    }

    static var d: UserDefaults { return UserDefaults.standard }

    static var home: String { return NSHomeDirectory() }

    static func registerDefaults() {
        let h = home
        d.register(defaults: [
            Key.showHidden: false,
            Key.foldersFirst: false,
            Key.sortColumn: "name",
            Key.sortAscending: true,
            Key.visibleColumns: ["modified", "size", "ext"],
            Key.favorites: [h, h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures", "/Applications"],
            Key.startMode: "home",
            Key.sidebarWidth: 190.0,
            Key.folderSizes: false,
            Key.sidebarOrder: Prefs.allSections,
            Key.sidebarHidden: [String](),
            Key.sidebarCollapsed: [String](),
            Key.recentCount: 6,
            Key.frequentCount: 5,
            Key.maintAuto: true,
            Key.maintStartup: true,
            Key.maintQuit: false,
            Key.maintEveryHours: 24,
            Key.maintTempHours: 24,
            Key.maintLogDays: 30,
            Key.previewLimitMB: 1024,
            Key.netListingSeconds: 86400,
            Key.netFolderSizes: false,
            Key.netSearchReaders: 2,
            Key.netShowDisconnect: true,
            Key.debugLogging: false,
            Key.savedServers: "[]",
            Key.reopenWindows: true,
        ])
    }

    /// Storage & Maintenance settings as one policy.
    static var maintenancePolicy: MaintenancePolicy {
        var p = MaintenancePolicy()
        p.automatic = d.bool(forKey: Key.maintAuto)
        p.atStartup = d.bool(forKey: Key.maintStartup)
        p.atQuit = d.bool(forKey: Key.maintQuit)
        p.everyHours = max(0, d.integer(forKey: Key.maintEveryHours))
        p.tempMaxAgeHours = max(1, d.integer(forKey: Key.maintTempHours))
        p.logKeepDays = max(1, d.integer(forKey: Key.maintLogDays))
        p.previewLimitMB = max(50, d.integer(forKey: Key.previewLimitMB))
        return p
    }

    /// How long a network folder's listing is remembered (0 = never).
    static var netListingSeconds: Int {
        get { return max(0, d.integer(forKey: Key.netListingSeconds)) }
        set { d.set(newValue, forKey: Key.netListingSeconds) }
    }

    /// Count folder sizes on network shares too (many requests to the server).
    static var netFolderSizes: Bool {
        get { return d.bool(forKey: Key.netFolderSizes) }
        set { d.set(newValue, forKey: Key.netFolderSizes) }
    }

    /// Folders read at the same time when searching a network share without an index (1-8).
    static var netSearchReaders: Int {
        get { return min(8, max(1, d.integer(forKey: Key.netSearchReaders))) }
        set { d.set(newValue, forKey: Key.netSearchReaders) }
    }

    /// When a share disconnects: keep the pane there with a Reconnect button (true) or go home (false).
    static var netShowDisconnect: Bool {
        get { return d.bool(forKey: Key.netShowDisconnect) }
        set { d.set(newValue, forKey: Key.netShowDisconnect) }
    }

    /// Servers saved in the sidebar (no passwords here: those are in the Keychain).
    static var savedServers: [SavedServer] {
        get { return ServerList.decode(d.string(forKey: Key.savedServers) ?? "[]") }
        set {
            d.set(ServerList.encode(newValue), forKey: Key.savedServers)
            NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
        }
    }

    /// Reopen windows where and how they were when Find was last quit.
    static var reopenWindows: Bool {
        get { return d.bool(forKey: Key.reopenWindows) }
        set { d.set(newValue, forKey: Key.reopenWindows) }
    }

    /// Extra detail in the log (listings, cache use, clean-up steps).
    static var debugLogging: Bool {
        get { return d.bool(forKey: Key.debugLogging) }
        set { d.set(newValue, forKey: Key.debugLogging) }
    }

    /// false (default): Space opens Find's Fast Preview. true: Space opens macOS Quick Look.
    static var spaceOpensQuickLook: Bool {
        get { return d.bool(forKey: Key.spaceOpensQuickLook) }
        set { d.set(newValue, forKey: Key.spaceOpensQuickLook) }
    }

    /// "list", "grid" (thumbnails) or "photo" (photography mode).
    static var viewMode: String {
        get { let v = d.string(forKey: Key.viewMode) ?? "list"; return ["list", "grid", "photo"].contains(v) ? v : "list" }
        set { d.set(newValue, forKey: Key.viewMode) }
    }

    static var thumbSize: Double {
        get { let v = d.double(forKey: Key.thumbSize); return v >= 80 && v <= 480 ? v : 160 }
        set { d.set(min(480, max(80, newValue)), forKey: Key.thumbSize) }
    }

    static var showInspector: Bool {
        get { return d.bool(forKey: Key.showInspector) }
        set { d.set(newValue, forKey: Key.showInspector) }
    }

    static var showHidden: Bool {
        get { return d.bool(forKey: Key.showHidden) }
        set { d.set(newValue, forKey: Key.showHidden); NotificationCenter.default.post(name: .findPrefsChanged, object: nil) }
    }

    static var foldersFirst: Bool {
        get { return d.bool(forKey: Key.foldersFirst) }
        set { d.set(newValue, forKey: Key.foldersFirst); NotificationCenter.default.post(name: .findPrefsChanged, object: nil) }
    }

    static var sortSpec: SortSpec {
        get {
            let col = SortColumn(rawValue: d.string(forKey: Key.sortColumn) ?? "name") ?? .name
            return SortSpec(column: col, ascending: d.bool(forKey: Key.sortAscending), foldersFirst: foldersFirst)
        }
        set {
            d.set(newValue.column.rawValue, forKey: Key.sortColumn)
            d.set(newValue.ascending, forKey: Key.sortAscending)
        }
    }

    static var visibleColumns: [String] {
        get { return d.stringArray(forKey: Key.visibleColumns) ?? ["modified", "size", "ext"] }
        set { d.set(newValue, forKey: Key.visibleColumns) }
    }

    static var columnWidths: [String: Double] {
        get {
            var out: [String: Double] = [:]
            if let raw = d.dictionary(forKey: Key.columnWidths) {
                for (k, v) in raw {
                    if let n = v as? NSNumber { out[k] = n.doubleValue }
                }
            }
            return out
        }
        set { d.set(newValue, forKey: Key.columnWidths) }
    }

    /// Sidebar sections: fav, freq, recent, dev, net.
    static let allSections = ["fav", "freq", "recent", "dev", "srv", "net"]
    static let sectionTitles = ["fav": "Favorites", "freq": "Frequent", "recent": "Recent", "dev": "Devices", "srv": "Servers", "net": "Network"]

    static var sidebarOrder: [String] {
        get {
            var o = (d.stringArray(forKey: Key.sidebarOrder) ?? allSections).filter { allSections.contains($0) }
            for s in allSections where !o.contains(s) {
                // A section added in a later version goes where it is by default (Servers before Network).
                if let i = allSections.index(of: s), i + 1 < allSections.count, let at = o.index(of: allSections[i + 1]) {
                    o.insert(s, at: at)
                } else {
                    o.append(s)
                }
            }
            return o
        }
        set { d.set(newValue, forKey: Key.sidebarOrder); NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
    }

    static var sidebarHidden: Set<String> {
        get { return Set(d.stringArray(forKey: Key.sidebarHidden) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Key.sidebarHidden); NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
    }

    /// Order chosen by dragging for Devices and Network (paths). Favorites and Servers keep their own lists.
    static func sidebarItemOrder(_ section: String) -> [String] {
        return (d.dictionary(forKey: Key.sidebarItemOrder) as? [String: [String]])?[section] ?? []
    }

    static func setSidebarItemOrder(_ section: String, _ order: [String]) {
        var all = (d.dictionary(forKey: Key.sidebarItemOrder) as? [String: [String]]) ?? [:]
        all[section] = order
        d.set(all, forKey: Key.sidebarItemOrder)
        NotificationCenter.default.post(name: .findVolumesChanged, object: nil)
    }

    // MARK: Photo Mechanic colour classes (0.14)

    /// Copies window: "Show diagnostics" (0.17), remembered.
    static var copyDiagnostics: Bool {
        get { return d.bool(forKey: Key.copyDiagnostics) }
        set { d.set(newValue, forKey: Key.copyDiagnostics) }
    }

    // MARK: Custom keys (0.16)

    /// Menu command id -> shortcut ("" = none). Missing = the built-in shortcut.
    static var customKeys: [String: String] {
        get { return d.dictionary(forKey: Key.customKeys) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.customKeys) }
    }
    /// Photography: modifier for stars ("ctrl" with plain digits too, "plain", "opt", "shift").
    static var starModifier: String {
        get { return d.string(forKey: Key.starModifier) ?? "ctrl" }
        set { d.set(newValue, forKey: Key.starModifier) }
    }
    /// Photography: modifier for colour classes ("cmd", "ctrl", "opt").
    static var colourModifier: String {
        get { return d.string(forKey: Key.colourModifier) ?? "cmd" }
        set { d.set(newValue, forKey: Key.colourModifier) }
    }

    // MARK: Visual finish (0.16): 0 = as before; defaults as in the approved mock-up.
    static var finishDepth: Int {
        get { return d.object(forKey: Key.finishDepth) as? Int ?? 60 }
        set { d.set(newValue, forKey: Key.finishDepth) }
    }
    static var finishGlow: Int {
        get { return d.object(forKey: Key.finishGlow) as? Int ?? 40 }
        set { d.set(newValue, forKey: Key.finishGlow) }
    }
    /// 0.17.4: Glass behind the file lists (panes), separate from the sidebar's. Default off.
    static var finishContentGlass: Int {
        get { return d.object(forKey: Key.finishContentGlass) as? Int ?? 0 }
        set { d.set(newValue, forKey: Key.finishContentGlass) }
    }

    static var finishGlass: Int {
        get { return d.object(forKey: Key.finishGlass) as? Int ?? 60 }
        set { d.set(newValue, forKey: Key.finishGlass) }
    }
    static var finishDim: Int {
        get { return d.object(forKey: Key.finishDim) as? Int ?? 20 }
        set { d.set(newValue, forKey: Key.finishDim) }
    }

    /// Photography mode: arrow keys move the thumbnails in whole rows, without scrolling animation (0.16).
    /// 0.18.6: the three places metadata is written (all on by default).
    static var metaSidecar: Bool {
        get { return d.object(forKey: "metaSidecar") as? Bool ?? true }
        set { d.set(newValue, forKey: "metaSidecar"); MetaPlan.writeSidecar = newValue }
    }
    static var metaEmbeddedXMP: Bool {
        get { return d.object(forKey: "metaEmbeddedXMP") as? Bool ?? true }
        set { d.set(newValue, forKey: "metaEmbeddedXMP"); MetaPlan.writeEmbeddedXMP = newValue }
    }
    /// 0.18.9: Settings > ExifTool Behavior. Mode: 0 with Find, 1 with Photography Mode (default), 2 when needed.
    static var exifToolMode: Int {
        get { return d.object(forKey: "exifToolMode") as? Int ?? 1 }
        set { d.set(newValue, forKey: "exifToolMode") }
    }
    /// How many ExifTools run side by side (1-4, default 4).
    static var exifToolCount: Int {
        get { return max(1, min(4, d.object(forKey: "exifToolCount") as? Int ?? 4)) }
        set { d.set(max(1, min(4, newValue)), forKey: "exifToolCount") }
    }
    /// Minutes without work before they stop when nothing keeps them (1-120, default 5).
    static var exifToolIdleMinutes: Int {
        get { return max(1, min(120, d.object(forKey: "exifToolIdleMinutes") as? Int ?? 5)) }
        set { d.set(max(1, min(120, newValue)), forKey: "exifToolIdleMinutes") }
    }

    /// 0.18.10: in-place changes checked by ExifTool (true, default) or by Find's fast check.
    static var inPlaceExifToolCheck: Bool {
        get { return d.object(forKey: "inPlaceExifToolCheck") as? Bool ?? false }   // PhotoLab S3: the fast byte check
        set { d.set(newValue, forKey: "inPlaceExifToolCheck"); MetaPlan.inPlaceExifToolCheck = newValue }
    }
    /// 0.18.11: Find's own reader / sidecar writer / ExifTool double check / thorough flush (Settings > Photography).
    static var metaNativeRead: Bool {
        get { return d.object(forKey: "metaNativeRead") as? Bool ?? true }
        set { d.set(newValue, forKey: "metaNativeRead"); MetaPlan.nativeRead = newValue }
    }
    static var metaNativeSidecar: Bool {
        get { return d.object(forKey: "metaNativeSidecar") as? Bool ?? true }
        set { d.set(newValue, forKey: "metaNativeSidecar"); MetaPlan.nativeSidecar = newValue }
    }
    static var metaNativeDoubleCheck: Bool {
        get { return d.object(forKey: "metaNativeDoubleCheck") as? Bool ?? false }
        set { d.set(newValue, forKey: "metaNativeDoubleCheck"); MetaPlan.nativeExifToolDoubleCheck = newValue }
    }
    /// 0.18.14: Thorough / Normal / None (0.18.11-13's checkbox: on = Thorough, off = Normal).
    static var metaFlush: FlushMode {
        get {
            if let n = d.object(forKey: "metaFlush") as? Int, let m = FlushMode(rawValue: n) { return m }
            if let old = d.object(forKey: "metaFullFlush") as? Bool { return old ? .full : .normal }
            return .none   // PhotoLab S3 (user, 2026-11-28): the fastest way is the default
        }
        set { d.set(newValue.rawValue, forKey: "metaFlush"); MetaPlan.flush = newValue }
    }
    /// 0.18.10: Photography Mode shows RAW + JPEG pairs as one (the RAW, badge "NEF+JPG"); off by default.
    static var hideJPEGTwins: Bool {
        get { return d.bool(forKey: "hideJPEGTwins") }
        set { d.set(newValue, forKey: "hideJPEGTwins") }
    }
    /// ... and the hidden JPEG gets the same stars, labels and metadata (default on).
    static var twinsShareMetadata: Bool {
        get { return d.object(forKey: "twinsShareMetadata") as? Bool ?? true }
        set { d.set(newValue, forKey: "twinsShareMetadata") }
    }
    /// 0.18.10 Thumbnails: memory for ready-drawn thumbnails (MB), screens prepared ahead, decoding threads.
    static var thumbMemoryMB: Int {
        get { return d.object(forKey: "thumbMemoryMB") as? Int ?? 512 }
        set { d.set(newValue, forKey: "thumbMemoryMB") }
    }
    static var thumbPrepareScreens: Int {
        get { return d.object(forKey: "thumbPrepareScreens") as? Int ?? 2 }
        set { d.set(newValue, forKey: "thumbPrepareScreens") }
    }
    static var thumbThreads: Int {
        get { return max(1, min(8, d.object(forKey: "thumbThreads") as? Int ?? 4)) }
        set { d.set(newValue, forKey: "thumbThreads") }
    }

    /// 0.18.8: change only the metadata part of files when possible (off by default).
    static var metaInPlace: Bool {
        get { return d.object(forKey: "metaInPlace") as? Bool ?? true }   // PhotoLab S3: in place by default
        set { d.set(newValue, forKey: "metaInPlace"); MetaPlan.inPlace = newValue }
    }
    static var metaEmbeddedIPTC: Bool {
        get { return d.object(forKey: "metaEmbeddedIPTC") as? Bool ?? true }
        set { d.set(newValue, forKey: "metaEmbeddedIPTC"); MetaPlan.writeEmbeddedIPTC = newValue }
    }
    /// 0.18.5: MetaWriteMode raw value (default 1 = fingerprint, no working copy).
    static var metaWriteMode: MetaWriteMode {
        get { return MetaWriteMode(rawValue: d.object(forKey: "metaWriteMode") as? Int ?? 3) ?? .fast }   // PhotoLab S3: fastest
        set { d.set(newValue.rawValue, forKey: "metaWriteMode"); MetaPlan.writeMode = newValue }
    }

    static var photoArrowSteps: Bool {
        get { return d.object(forKey: Key.photoArrowSteps) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.photoArrowSteps) }
    }

    static let defaultColorClassNames = ["Winner", "Winner alt", "Superior", "Superior alt", "Typical", "Typical alt", "Extras", "Trash"]
    static let defaultColorClassColors = ["#E5413B", "#F08A24", "#F2CB2C", "#55B848", "#3C8CE7", "#9B59D0", "#3EC7C7", "#8E8E93"]

    /// Names of classes 1-8, as set in Photo Mechanic's Preferences > General (edit to match yours).
    /// 0.18.15: the Metadata Template (Cmd-I): field values, ticked fields, rating choice, add-keywords box.
    static var metadataTemplate: (values: [String: String], ticked: [String], rating: Int, addKeywords: Bool) {
        get {
            let m = d.dictionary(forKey: "metadataTemplate") ?? [:]
            return ((m["values"] as? [String: String]) ?? [:], (m["ticked"] as? [String]) ?? [],
                    (m["rating"] as? Int) ?? 0, (m["addKeywords"] as? Bool) ?? false)
        }
        set {
            d.set(["values": newValue.values, "ticked": newValue.ticked, "rating": newValue.rating, "addKeywords": newValue.addKeywords] as [String: Any],
                  forKey: "metadataTemplate")
        }
    }

    static var colorClassNames: [String] {
        get {
            let a = d.stringArray(forKey: Key.colorClassNames) ?? []
            return (0..<8).map { i in i < a.count && !a[i].isEmpty ? a[i] : defaultColorClassNames[i] }
        }
        set { d.set(newValue, forKey: Key.colorClassNames); NotificationCenter.default.post(name: .findPrefsChanged, object: nil) }
    }

    /// Colours of classes 1-8 (hex), shown on the thumbnails.
    static var colorClassColors: [String] {
        get {
            let a = d.stringArray(forKey: Key.colorClassColors) ?? []
            return (0..<8).map { i in i < a.count && Theme.rgb(a[i]) != nil ? a[i] : defaultColorClassColors[i] }
        }
        set { d.set(newValue, forKey: Key.colorClassColors); NotificationCenter.default.post(name: .findPrefsChanged, object: nil) }
    }

    static func colorClassColor(_ n: Int) -> NSColor? {
        guard n >= 1 && n <= 8 else { return nil }
        return ThemeManager.color(colorClassColors[n - 1])
    }

    static var sidebarCollapsed: Set<String> {
        get { return Set(d.stringArray(forKey: Key.sidebarCollapsed) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Key.sidebarCollapsed); NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
    }

    static var recentCount: Int {
        get { return max(0, min(20, d.integer(forKey: Key.recentCount))) }
        set { d.set(newValue, forKey: Key.recentCount); NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
    }

    static var frequentCount: Int {
        get { return max(0, min(10, d.integer(forKey: Key.frequentCount))) }
        set { d.set(newValue, forKey: Key.frequentCount); NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
    }

    static var calculateFolderSizes: Bool {
        get { return d.bool(forKey: Key.folderSizes) }
        set { d.set(newValue, forKey: Key.folderSizes); NotificationCenter.default.post(name: .findPrefsChanged, object: nil) }
    }

    /// 0.17.2: the name a favourite is shown with in the sidebar (only there - nothing is renamed).
    static var favoriteNames: [String: String] {
        get { return d.dictionary(forKey: Key.favoriteNames) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: Key.favoriteNames); NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
    }

    static var favorites: [String] {
        get { return d.stringArray(forKey: Key.favorites) ?? [] }
        set { d.set(newValue, forKey: Key.favorites); NotificationCenter.default.post(name: .findVolumesChanged, object: nil) }
    }

    static var recents: [String] {
        get { return d.stringArray(forKey: Key.recents) ?? [] }
        set { d.set(newValue, forKey: Key.recents) }
    }

    static var visitCounts: [String: Int] {
        get {
            var out: [String: Int] = [:]
            if let raw = d.dictionary(forKey: Key.visitCounts) {
                for (k, v) in raw {
                    if let n = v as? NSNumber { out[k] = n.intValue }
                }
            }
            return out
        }
        set { d.set(newValue, forKey: Key.visitCounts) }
    }

    /// Record a visit for Recent and Frequent lists.
    static func noteVisit(_ path: String) {
        var r = recents.filter { $0 != path }
        r.insert(path, at: 0)
        if r.count > 20 { r = Array(r.prefix(20)) }
        recents = r
        var c = visitCounts
        c[path] = (c[path] ?? 0) + 1
        if c.count > 300 {
            // keep the 200 most visited
            let keep = c.sorted { $0.value > $1.value }.prefix(200)
            var nc: [String: Int] = [:]
            for (k, v) in keep { nc[k] = v }
            c = nc
        }
        visitCounts = c
        d.set(path, forKey: Key.lastPath)
    }

    static var frequent: [String] {
        let favs = Set(favorites)
        return visitCounts.filter { !favs.contains($0.key) && $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(frequentCount).map { $0.key }
    }

    static var startPath: String {
        let mode = d.string(forKey: Key.startMode) ?? "home"
        var p = home
        if mode == "last", let l = d.string(forKey: Key.lastPath) { p = l }
        if mode == "custom", let c = d.string(forKey: Key.startPath) { p = c }
        var e: Int32 = 0
        if let info = Sys.statInfo(p, &e), info.isDirectory { return p }
        return home
    }
}
