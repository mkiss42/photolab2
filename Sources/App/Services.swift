// Services.swift
// Shared objects: file operations, Find's own files, log, theme store; kind and icon caches.

import AppKit
import CoreServices

enum App {
    static let version = "1.0.0-alpha.7"
    static var files: AppFiles!
    static var log: Log!
    static var ops: FileOperations!
    static var themes: ThemeStore!
    static var indexes: IndexStore!
    static var previews: PreviewCache!
    /// PhotoLab: contact-sheet thumbnails kept between launches (Caches/PhotoLab/Thumbs, 1 GB, oldest out).
    static var thumbs: PreviewCache?
    /// When PhotoLab started (Short Report).
    static let launched = Date()
    static var journal: OperationJournal!
    static var maintenance: Maintenance!
    /// What the start-up recovery did (shown once the first window is open).
    static var recoveryLines: [String] = []
    static var lastReport: String = ""

    static func start() {
        let h = NSHomeDirectory()
        // PhotoLab's own folders (fresh: nothing is taken over from Find).
        files = AppFiles(supportDir: h + "/Library/Application Support/PhotoLab",
                         cachesDir: h + "/Library/Caches/PhotoLab",
                         logsDir: h + "/Library/Logs/PhotoLab")
        AppFiles.shared = files
        log = Log(files: files)
        Log.shared = log
        let platform = DarwinPlatform()
        platform.log = { s in Log.shared?.info(s) }
        ops = FileOperations(platform: platform)
        ops.logger = { s in Log.shared?.info(s) }
        // 0.18: the network and disk I/O logs (Logs/Find/network-io-*.log, disk-io-*.log).
        IOLog.isNetworkPath = { p in VolumeRegistry.shared.treatAsNetwork(p) }
        // 0.18.5: how metadata is written (Settings > Photography).
        MetaPlan.writeSidecar = Prefs.metaSidecar
        MetaPlan.writeEmbeddedXMP = Prefs.metaEmbeddedXMP
        MetaPlan.writeEmbeddedIPTC = Prefs.metaEmbeddedIPTC
        MetaPlan.inPlace = Prefs.metaInPlace
        MetaPlan.inPlaceExifToolCheck = Prefs.inPlaceExifToolCheck
        MetaPlan.nativeRead = Prefs.metaNativeRead
        MetaPlan.nativeSidecar = Prefs.metaNativeSidecar
        MetaPlan.nativeExifToolDoubleCheck = Prefs.metaNativeDoubleCheck
        MetaPlan.flush = Prefs.metaFlush
        ExifToolKeeper.configure()
        MetaPlan.writeMode = Prefs.metaWriteMode
        IOLog.processDiskBytes = { ProcessDiskIO.bytes() }
        IOLog.network = IOLog(files: files, network: true, appVersion: App.version)
        IOLog.disk = IOLog(files: files, network: false, appVersion: App.version)
        IOLog.readEconomy = { FileReads.economy(network: $0) }
        Log.debugEnabled = Prefs.debugLogging
        // Phase 5: notes about operations in progress; finish what a crash or power cut interrupted,
        // before anything else can run.
        journal = OperationJournal(files: files)
        ops.journal = journal
        recoveryLines = ops.recoverInterrupted(journal)
        // Ratings and metadata are written with the bundled ExifTool (FileOperations.writeMetadata).
        if ExifTool.command != nil { ops.metadataTool = ExifToolMetadata() }
        // Search inside PDFs (search options: "Text in PDFs and documents").
        ContentSearch.pdfText = { p in PDFTextReader.text(p) }
        for l in recoveryLines { log.info(l) }
        themes = ThemeStore(files: files)
        previews = PreviewCache(files: files, limitBytes: Int64(Prefs.maintenancePolicy.previewLimitMB) * 1_048_576)
        thumbs = PreviewCache(files: files, limitBytes: 1 << 30, folder: "Thumbs")
        BulkLister.install()   // fast folder listing (getattrlistbulk); readdir + lstat if it can't be used
        indexes = IndexStore(files: files, folder: Paths.join(files.supportDir, "Indexes"))
        maintenance = Maintenance(files: files, previews: previews, indexes: indexes, journal: journal)
        // In-memory caches: listed in Settings > Storage & Maintenance, emptied by Clear All Disposable Caches.
        let onMain: (@escaping () -> Void) -> Void = { f in DispatchQueue.main.async(execute: f) }
        maintenance.memoryCaches = [
            (name: "Thumbnails (memory)", describe: { "up to 800 pictures, \(ThumbnailGrid.memoryCount) remembered" },
             clear: { onMain { ThumbnailGrid.clearMemory() } }),
            (name: "Fast Preview images (memory)", describe: { "up to 12 large previews" },
             clear: { onMain { FastPreview.shared.clearMemory() } }),
            (name: "Icons (memory)", describe: { "one per file type, \(IconCache.shared.count) now" },
             clear: { onMain { IconCache.shared.clear() } }),
            (name: "Photo ratings and labels (memory)", describe: { "up to 50,000 pictures, \(PhotoFactsStore.shared.memoryCount) now" },
             clear: { PhotoFactsStore.shared.clearMemory() }),
            (name: "Info panel details (memory)", describe: { "up to 300 files, \(InspectorController.memoryCount) now" },
             clear: { onMain { InspectorController.clearMemory() } }),
            (name: "Colour labels (memory)", describe: { "for folders shown; read again when needed" },
             clear: { onMain { TagCache.shared.clear() } }),
            (name: "Network folder listings (memory)", describe: { "\(ListingCache.shared.count) of up to \(ListingCache.capacity) folders, kept \(Int(ListingCache.lifetime)) s" },
             clear: { ListingCache.shared.removeAll() }),
        ]
        ListingCache.lifetime = Double(Prefs.netListingSeconds)
        ShareListings.start()
        StallWatch.start()
        files.clearTemp()
        log.info("Find \(version) started. macOS \(ProcessInfo.processInfo.operatingSystemVersionString). Logs: \(files.logsDir)")
    }

    static var systemInfo: String {
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB RAM"
    }
}

/// "JPEG image", "Folder", "Application" ... cached per extension. Thread-safe.
final class KindCache {
    static let shared = KindCache()
    private var byExt: [String: String] = [:]
    private var packageExt: [String: Bool] = [:]
    private let lock = NSLock()

    /// Package extensions are short words ("app", "bundle", "photoslibrary"); folder names such as
    /// "2024.11.21 Shoot" give "21 shoot", which can't be one, so the disk isn't asked.
    static func couldBePackageExt(_ ext: String) -> Bool {
        if ext.isEmpty || ext.count > 24 { return false }
        var letter = false
        for u in ext.unicodeScalars {
            if u == " " { return false }
            if CharacterSet.letters.contains(u) { letter = true }
        }
        return letter
    }

    func isPackage(_ e: FileEntry) -> Bool {
        guard e.kind == .directory, KindCache.couldBePackageExt(e.ext) else { return false }
        // 0.17.3: on a share, decided by the extension alone (asking macOS reads the item from the server).
        if VolumeRegistry.shared.treatAsNetwork(e.path) {
            lock.lock(); defer { lock.unlock() }
            return packageExt[e.ext] ?? KindCache.knownPackageExts.contains(e.ext.lowercased())
        }
        lock.lock()
        if let known = packageExt[e.ext] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let p = NSWorkspace.shared.isFilePackage(atPath: e.path)
        lock.lock()
        packageExt[e.ext] = p
        lock.unlock()
        return p
    }

    static let knownPackageExts: Set<String> = ["app", "bundle", "framework", "plugin", "kext", "pkg", "mpkg", "rtfd", "photoslibrary",
                                                "fcpbundle", "logicx", "band", "key", "pages", "numbers", "xcodeproj", "xcworkspace",
                                                "lrdata", "cocatalog", "cosessiondb", "aplibrary", "imovielibrary", "theater", "playground", "scptd", "wdgt", "lpdf"]

    /// Package check by path and extension (used by search on worker threads).
    func isPackage(path: String, ext: String) -> Bool {
        if ext == "app" { return true }
        if !KindCache.couldBePackageExt(ext) { return false }
        if VolumeRegistry.shared.treatAsNetwork(path) {
            lock.lock(); defer { lock.unlock() }
            return packageExt[ext] ?? KindCache.knownPackageExts.contains(ext.lowercased())
        }
        lock.lock()
        if let known = packageExt[ext] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let p = NSWorkspace.shared.isFilePackage(atPath: path)
        lock.lock()
        packageExt[ext] = p
        lock.unlock()
        return p
    }

    func kind(_ e: FileEntry) -> String {
        switch e.kind {
        case .symlink, .other:
            return Listing.basicKind(e)
        case .directory:
            if e.ext == "app" { return "Application" }
            if isPackage(e) { return describe(e.ext) ?? "Package" }
            return "Folder"
        case .file:
            if e.ext.isEmpty { return "Document" }
            return describe(e.ext) ?? Listing.basicKind(e)
        }
    }

    private func describe(_ ext: String) -> String? {
        lock.lock()
        if let k = byExt[ext] {
            lock.unlock()
            return k.isEmpty ? nil : k
        }
        lock.unlock()
        var desc = ""
        if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, nil)?.takeRetainedValue(),
            let d = UTTypeCopyDescription(uti)?.takeRetainedValue() {
            desc = d as String
        }
        lock.lock()
        byExt[ext] = desc
        lock.unlock()
        return desc.isEmpty ? nil : desc
    }
}

/// Small icons, one per file type (not per file) except applications and sidebar places. Main thread only.
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    let size = NSSize(width: 16, height: 16)

    private func sized(_ img: NSImage) -> NSImage {
        let copy = (img.copy() as? NSImage) ?? img
        copy.size = size
        return copy
    }

    func clear() { cache.removeAll() }
    var count: Int { return cache.count }

    func icon(for e: FileEntry) -> NSImage {
        let key: String
        let make: () -> NSImage
        // On a network share, never ask macOS for a per-item icon on the main thread: it reads the item
        // from the server, and a server that stopped answering would freeze the window.
        let remote = VolumeRegistry.shared.treatAsNetwork(e.path)
        switch e.kind {
        case .directory:
            if e.ext == "app" && remote {
                key = "type:app"
                make = { NSWorkspace.shared.icon(forFileType: "com.apple.application-bundle") }
            } else if e.ext == "app" || (!remote && KindCache.shared.isPackage(e)) {
                key = "path:" + e.path
                make = { NSWorkspace.shared.icon(forFile: e.path) }
            } else {
                key = "folder"
                make = { NSWorkspace.shared.icon(forFileType: "public.folder") }
            }
        case .symlink:
            key = e.linkToDirectory ? "folder" : "file:" + e.ext
            make = e.linkToDirectory ? { NSWorkspace.shared.icon(forFileType: "public.folder") } : { NSWorkspace.shared.icon(forFileType: e.ext) }
        default:
            key = "file:" + e.ext
            make = { NSWorkspace.shared.icon(forFileType: e.ext.isEmpty ? "public.data" : e.ext) }
        }
        if let c = cache[key] { return c }
        let img = sized(make())
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = img
        return img
    }

    /// A full-size icon for one item (Info panel, preview card). 0.17.3: on a share, by type only -
    /// asking macOS for that item's own icon reads it from the server on the main thread (this was a
    /// beachball each time a folder on a share was selected, e.g. coming back out of it).
    func largeIcon(for e: FileEntry) -> NSImage {
        if VolumeRegistry.shared.treatAsNetwork(e.path) {
            let type: String
            if e.kind == .directory || e.linkToDirectory {
                type = e.ext == "app" ? "com.apple.application-bundle" : "public.folder"
            } else {
                type = e.ext.isEmpty ? "public.data" : e.ext
            }
            // A copy: callers resize it, and macOS may hand out the same image for a type.
            return (NSWorkspace.shared.icon(forFileType: type).copy() as? NSImage) ?? NSWorkspace.shared.icon(forFileType: type)
        }
        return NSWorkspace.shared.icon(forFile: e.path)
    }

    /// Several items: on a share, a plain icon instead of macOS reading each one from the server.
    func largeIcon(forMany es: [FileEntry]) -> NSImage {
        if let f = es.first, VolumeRegistry.shared.treatAsNetwork(f.path) {
            return NSWorkspace.shared.icon(forFileType: es.contains { $0.kind == .directory } ? "public.folder" : "public.data")
        }
        let img: NSImage? = NSWorkspace.shared.icon(forFiles: es.prefix(20).map { $0.path })
        return img ?? NSWorkspace.shared.icon(forFileType: "public.data")
    }

    func icon(forPath path: String) -> NSImage {
        let key = "path:" + path
        if let c = cache[key] { return c }
        let remote = VolumeRegistry.shared.treatAsNetwork(path)
        let img: NSImage
        if remote && VolumeRegistry.volumeRoot(path) == path {
            img = sized(namedImage("NSNetwork") ?? NSWorkspace.shared.icon(forFileType: "public.folder"))
        } else if remote {
            img = sized(NSWorkspace.shared.icon(forFileType: "public.folder"))
        } else {
            img = sized(NSWorkspace.shared.icon(forFile: path))
        }
        cache[key] = img
        return img
    }
}

/// Colour-label dots per item, read on demand for visible rows only, in the background (reading tags
/// touches the disk, which made arrow-key scrolling stutter, most of all on network shares).
/// Call from the main thread; `onUpdate` is told which paths got their colours.
final class TagCache {
    static let shared = TagCache()
    private var cache: [String: [Int]] = [:]
    /// PhotoLab: each cached item's change time (ctime) when its tags were read - writing a tag moves it.
    private var ctimes: [String: Double] = [:]
    private var queued = Set<String>()
    private var waiting: [String] = []
    private var running = false
    private var rechecking = Set<String>()   // volume roots with a light check under way
    private let queue = DispatchQueue(label: "find.tags", qos: .userInitiated)
    private let checkQueue = DispatchQueue(label: "photolab.tags.check", qos: .utility)
    var onUpdate: (([String]) -> Void)? = { paths in
        NotificationCenter.default.post(name: .findTagsRead, object: nil, userInfo: ["paths": paths])
    }

    /// Known colours now; unknown ones are read in the background (empty until then).
    func colors(_ path: String) -> [Int] {
        if let c = cache[path] { return c }
        if !queued.contains(path) {
            queued.insert(path)
            waiting.append(path)
            pump()
        }
        return []
    }

    /// Synchronous read for callers that need the answer now (menus, labels being toggled).
    func colorsNow(_ path: String) -> [Int] {
        if let c = cache[path] { return c }
        let c = FinderTags.colorIndexes(path)
        cache[path] = c
        return c
    }

    private func pump() {
        if running || waiting.isEmpty { return }
        running = true
        let batch = Array(waiting.prefix(64))
        waiting.removeFirst(batch.count)
        queue.async { [weak self] in
            var got: [(String, [Int], Double?)] = []
            var e: Int32 = 0
            for p in batch {
                let ct = Sys.lstatInfo(p, &e)?.changed   // before the read: a change meanwhile is seen next time
                got.append((p, FinderTags.colorIndexes(p), ct))
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                var changed: [String] = []
                for (p, c, ct) in got {
                    s.queued.remove(p)
                    let old = s.cache[p]
                    s.cache[p] = c
                    s.ctimes[p] = ct
                    // PhotoLab: a removed tag is a change too (Find only reported items with tags).
                    if old.map({ $0 != c }) ?? !c.isEmpty { changed.append(p) }
                }
                if s.cache.count > 20_000 { s.cache.removeAll(); s.ctimes.removeAll() }
                s.running = false
                if !changed.isEmpty { s.onUpdate?(changed) }
                s.pump()
            }
        }
    }

    /// PhotoLab: these changed on disk (FSEvents): read the known ones again; the rows update when the
    /// new tags differ. Main thread.
    func reread(_ paths: [String]) {
        for p in paths where cache[p] != nil && !queued.contains(p) {
            queued.insert(p)
            waiting.append(p)
        }
        pump()
    }

    /// PhotoLab: the light check for shares (macOS does not report other Macs' changes there): one
    /// lstat per row on screen, usually answered from the SMB client's attribute cache, and a tag
    /// read only where the change time moved. Skipped while the previous check of that volume runs.
    func recheck(_ paths: [String]) {
        let known = paths.filter { cache[$0] != nil && !queued.contains($0) }
        guard let first = known.first else { return }
        let root = VolumeRegistry.volumeRoot(first)
        if rechecking.contains(root) { return }
        rechecking.insert(root)
        let before = known.map { ($0, ctimes[$0]) }
        checkQueue.async { [weak self] in
            var moved: [String] = []
            var e: Int32 = 0
            for (p, ct) in before {
                let now = Sys.lstatInfo(p, &e)?.changed
                if now != ct { moved.append(p) }
            }
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.rechecking.remove(root)
                if !moved.isEmpty { s.reread(moved) }
            }
        }
    }

    func forget(_ paths: [String]) {
        for p in paths { cache[p] = nil; ctimes[p] = nil }
    }

    func clear() {
        cache.removeAll()
        ctimes.removeAll()
    }
}

/// PhotoLab (from PhotoLab 2): FSEvents for the folders on screen - reports tag (xattr) changes made on
/// this Mac, on local disks and on shares, with no polling. macOS does not report changes made by
/// other Macs on a share; TagCache.recheck (rows on screen, every 5 s) covers those.
final class TagWatcher {
    static let shared = TagWatcher()
    private var stream: FSEventStreamRef?
    private var folders: [ObjectIdentifier: String] = [:]
    private var current = Set<String>()
    private let queue = DispatchQueue(label: "photolab.fsevents", qos: .utility)

    /// Main thread. One folder per list (FSEvents covers its subfolders too). The stream is made on its
    /// own queue: FSEventStreamCreate looks the folders up, which can wait on a slow share (alpha.3 stalls).
    func watch(owner: AnyObject, folder: String?) {
        folders[ObjectIdentifier(owner)] = folder
        let all = Set(folders.values)
        if all != current {
            current = all
            queue.async { self.restart(all) }
        }
    }

    fileprivate func changed(_ paths: [String]) {
        DispatchQueue.main.async { TagCache.shared.reread(paths) }
    }

    private func restart(_ current: Set<String>) {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        guard !current.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info = info else { return }
            let me = Unmanaged<TagWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            let mask = UInt32(kFSEventStreamEventFlagItemXattrMod) | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
            var hit: [String] = []
            for i in 0..<min(count, arr.count) where flags[i] & mask != 0 { hit.append(arr[i]) }
            if !hit.isEmpty { me.changed(hit) }
        }
        let createFlags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, Array(current) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, createFlags) else {
            App.log.warn("W-TAG-1 FSEvents stream not created for \(current.count) folder(s); tags update on refresh")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }
}


/// 0.17.1: the network-folder snapshots are kept between launches (Application Support/Find/
/// share-listings.json), so a folder on a slow share shows at once even the first time after starting
/// Find; it is still checked in the background every time.
enum ShareListings {
    static var file: String { return Paths.join(App.files.supportDir, "share-listings.json") }
    private static var timer: Timer?

    static func start() {
        if let d = FileManager.default.contents(atPath: file) {
            let n = ListingCache.shared.importSaved(d)
            App.log.info("Network folder snapshots: \(n) folders brought back from last time")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in saveIfChanged(wait: false) }
    }

    static func saveIfChanged(wait: Bool) {
        guard ListingCache.shared.changedSinceSave else { return }
        let work = {
            if let d = ListingCache.shared.export(), !App.files.writeData(d, to: file) {
                App.log.warn("Network folder snapshots could not be saved (NET-SNAP)")
            }
        }
        if wait { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }
}


/// 0.17.3: notices when the window stops responding (a beachball) and writes to the log how long it
/// was and what Find had just started doing, e.g.
///   "BEACHBALL 3.4 s - while: list: going to /Volumes/Share/Job (from /Volumes/Share/Job/Day 1)".
/// Costs nothing noticeable: a check four times a second on a background thread.
enum StallWatch {
    private static let lock = NSLock()
    private static var activity = "(idle)"
    private static var since = Date()
    private static var waiting = false
    private static var sentAt = Date()
    private static var seenDuring = ""

    // PhotoLab Short Report: stalls counted without paths (kind = the label up to its first ":").
    private static var stalls = 0
    private static var stallSeconds = 0.0
    private static var longest = (0.0, "")

    fileprivate static func count(_ secs: Double, _ what: String) {
        lock.lock()
        stalls += 1
        stallSeconds += secs
        let kind = String(what.split(separator: ":").first ?? "?").trimmingCharacters(in: .whitespaces)
        if secs > longest.0 { longest = (secs, String(kind.prefix(30))) }
        lock.unlock()
    }

    /// "STALLS 3, 4.1 s in all, longest 2.0 s (list)" - no paths.
    static var reportLine: String {
        lock.lock(); defer { lock.unlock() }
        if stalls == 0 { return "STALLS none" }
        return String(format: "STALLS %d, %.1f s in all, longest %.1f s (%@)", stalls, stallSeconds, longest.0, Ascii.clean(longest.1))
    }

    /// What the main thread is about to do (kept short).
    static func mark(_ what: String) {
        lock.lock()
        activity = what
        since = Date()
        lock.unlock()
    }

    static func start() {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock()
                if !waiting {
                    waiting = true
                    sentAt = Date()
                    seenDuring = ""
                    lock.unlock()
                    DispatchQueue.main.async {
                        lock.lock()
                        let blocked = Date().timeIntervalSince(sentAt)
                        let what = seenDuring.isEmpty ? activity : seenDuring
                        waiting = false
                        lock.unlock()
                        if blocked >= 0.8 {
                            App.log.warn(String(format: "BEACHBALL %.1f s - while: ", blocked) + Ascii.clean(what))
                            StallWatch.count(blocked, what)
                        }
                    }
                } else {
                    // Still blocked: remember what it was doing when it got stuck.
                    if seenDuring.isEmpty && Date().timeIntervalSince(sentAt) > 0.5 {
                        let age = Date().timeIntervalSince(since)
                        // 0.18.14: a label set long before the stall is probably not its cause - said so.
                        seenDuring = (age > 5 ? "not marked; the last marked step was " : "") + activity + String(format: " (started %.1f s before)", age)
                    }
                    lock.unlock()
                }
            }
        }
    }
}
