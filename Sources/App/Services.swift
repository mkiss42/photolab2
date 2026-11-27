// Services.swift
// Shared objects: file operations, Find's own files, log, theme store; kind and icon caches.

import AppKit
import CoreServices

enum App {
    static let version = "1.0.0-alpha.2"
    static var files: AppFiles!
    static var log: Log!
    static var ops: FileOperations!
    static var themes: ThemeStore!
    static var indexes: IndexStore!
    static var previews: PreviewCache!
    /// PhotoLab: contact-sheet thumbnails kept between launches (Caches/PhotoLab/Thumbs, 1 GB, oldest out).
    static var thumbs: PreviewCache?
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
    private var queued = Set<String>()
    private var waiting: [String] = []
    private var running = false
    private let queue = DispatchQueue(label: "find.tags", qos: .userInitiated)
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
            var got: [(String, [Int])] = []
            for p in batch { got.append((p, FinderTags.colorIndexes(p))) }
            DispatchQueue.main.async {
                guard let s = self else { return }
                var changed: [String] = []
                for (p, c) in got {
                    s.queued.remove(p)
                    s.cache[p] = c
                    if !c.isEmpty { changed.append(p) }
                }
                if s.cache.count > 20_000 { s.cache.removeAll() }
                s.running = false
                if !changed.isEmpty { s.onUpdate?(changed) }
                s.pump()
            }
        }
    }

    func forget(_ paths: [String]) {
        for p in paths { cache[p] = nil }
    }

    func clear() {
        cache.removeAll()
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
