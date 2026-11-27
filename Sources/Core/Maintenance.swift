// Maintenance.swift
// Phase 5: every file Find makes for itself, what it is for, where it lives, how long it is kept and how
// it is cleaned up - plus the clean-up itself.
//
// SAFETY: every removal goes through AppFiles.removeOwned (refuses anything outside Find's own three
// folders, after resolving links) AND must be inside one of the stores listed here. Nothing in a user
// folder is ever removed by maintenance: leftovers of interrupted operations in user folders are handled
// by FileOperations.recoverInterrupted (moved to the Trash or renamed back, never deleted).
// Clean-up never runs while a file operation, search or index build is running.

import Foundation

/// What Find is busy with, so maintenance never runs in the middle of it.
final class Activity {
    enum Kind: String {
        case fileOperation = "file operation"
        case search = "search or index build"
        case maintenance = "clean-up"
    }
    static let shared = Activity()
    private let lock = NSLock()
    private var counts: [Kind: Int] = [:]

    func begin(_ k: Kind) {
        lock.lock(); counts[k, default: 0] += 1; lock.unlock()
    }

    func end(_ k: Kind) {
        lock.lock(); counts[k] = max(0, (counts[k] ?? 1) - 1); lock.unlock()
    }

    func count(_ k: Kind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[k] ?? 0
    }

    /// Busy with anything a clean-up must not interrupt.
    var userWorkRunning: Bool { return count(.fileOperation) > 0 || count(.search) > 0 }

    var describe: String {
        lock.lock(); defer { lock.unlock() }
        let busy = counts.filter { $0.value > 0 }.map { "\($0.value) \($0.key.rawValue)" }.sorted()
        return busy.isEmpty ? "idle" : busy.joined(separator: ", ")
    }
}

struct MaintenancePolicy {
    /// Master switch for automatic clean-up (at startup, at quit, on the schedule).
    var automatic = true
    var atStartup = true
    var atQuit = false
    /// Every N hours while Find is open (0 = off).
    var everyHours = 24
    /// Find's temporary files older than this are removed.
    var tempMaxAgeHours = 24
    /// Find's log and test reports older than this are removed (the current log never).
    var logKeepDays = 30
    /// Size limit of the saved previews.
    var previewLimitMB = 1024

    var describe: String {
        if !automatic { return "Automatic clean-up off (only when you click Clean Up Now)" }
        var when: [String] = []
        if atStartup { when.append("at startup") }
        if atQuit { when.append("at quit") }
        if everyHours > 0 { when.append("every \(everyHours) h") }
        return "Automatic clean-up " + (when.isEmpty ? "on, but no time chosen" : when.joined(separator: ", ")) +
            "; temporary files kept \(tempMaxAgeHours) h; logs kept \(logKeepDays) days; previews up to \(previewLimitMB) MB"
    }
}

struct StoreInfo {
    let id: String
    let name: String
    let purpose: String
    let location: String
    let retention: String
    let cleanup: String
    var bytes: Int64
    var items: Int
}

struct MaintenanceResult {
    var ran = false
    var trigger = ""
    var reason = ""
    var removed = 0
    var freed: Int64 = 0
    var failures = 0
    var lines: [String] = []

    var summary: String {
        if !ran { return "Clean-up not run: \(reason)" }
        return "Clean-up (\(trigger)): \(removed) item\(removed == 1 ? "" : "s") removed, \(Listing.sizeText(freed)) freed" +
            (failures > 0 ? ", \(failures) could not be removed (see log)" : "")
    }
}

final class Maintenance {
    let files: AppFiles
    let previews: PreviewCache
    let indexes: IndexStore
    let journal: OperationJournal
    /// The log being written now (never removed).
    var currentLogPath: String? = Log.shared?.path
    /// In-memory caches registered by the app: name, short description, clear.
    var memoryCaches: [(name: String, describe: () -> String, clear: () -> Void)] = []
    /// Orphan files in the index and preview folders are only removed after this age (a store being
    /// written right now is never touched).
    var orphanMinAge: Double = 3600

    private let runLock = NSLock()

    init(files: AppFiles, previews: PreviewCache, indexes: IndexStore, journal: OperationJournal) {
        self.files = files
        self.previews = previews
        self.indexes = indexes
        self.journal = journal
    }

    static let scratchPrefixes = ["selftest-", "searchtest-", "indextest-", "phototest-"]

    private var statePath: String { return Paths.join(files.supportDir, "maintenance.txt") }

    // MARK: State (last run), in Find's support folder - never removed by clean-up

    struct State {
        var lastRun: Double = 0
        var lastTrigger = ""
        var lastSummary = ""
    }

    var state: State {
        var s = State()
        guard let text = try? String(contentsOfFile: statePath, encoding: .utf8) else { return s }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "lastRun": s.lastRun = Double(parts[1]) ?? 0
            case "lastTrigger": s.lastTrigger = parts[1]
            case "lastSummary": s.lastSummary = parts[1]
            default: break
            }
        }
        return s
    }

    private func saveState(_ r: MaintenanceResult, now: Date) {
        let text = "lastRun=\(now.timeIntervalSince1970)\nlastTrigger=\(r.trigger)\nlastSummary=\(r.summary)\n"
        _ = files.writeData(Data(text.utf8), to: statePath)
    }

    func isDue(_ policy: MaintenancePolicy, now: Date = Date()) -> Bool {
        guard policy.automatic, policy.everyHours > 0 else { return false }
        return now.timeIntervalSince1970 - state.lastRun >= Double(policy.everyHours) * 3600
    }

    // MARK: Inventory

    /// Bytes and items in the direct children of `dir` that `pick` allows (whole folders counted).
    private func measure(_ dir: String, _ pick: Pick) -> (Int64, Int) {
        var bytes: Int64 = 0, items = 0
        let names = files.list(dir)
        for n in names {
            if !picks(n, dir, pick) { continue }
            let (b, i) = Maintenance.treeSize(Paths.join(dir, n))
            bytes += b
            items += i
        }
        return (bytes, items)
    }

    private func measureIndexes() -> (Int64, Int) {
        var bytes: Int64 = 0, items = 0
        let names = files.list(indexes.folder)
        for n in names where n.hasSuffix(".findidx") {
            bytes += Maintenance.treeSize(Paths.join(indexes.folder, n)).0
            items += 1
        }
        return (bytes, items)
    }

    func inventory() -> [StoreInfo] {
        let (pb, pi) = measure(previews.dir, .all)
        let (ib, ii) = measureIndexes()
        let (tb, ti) = measure(files.tempDir, .all)
        let (sb, si) = measure(files.cachesDir, .scratch)
        let (lb, li) = measure(files.logsDir, .all)
        let (jb, ji) = measure(files.journalsDir, .all)
        var out: [StoreInfo] = [
            StoreInfo(id: "previews", name: "Saved previews",
                      purpose: "Screen-sized JPEGs of Photoshop and very large TIFF files, so they show instantly next time",
                      location: previews.dir,
                      retention: "Up to the size limit; least recently viewed removed first. A changed file gets a new preview.",
                      cleanup: "Trimmed to the limit; removed by Clear All Disposable Caches",
                      bytes: pb, items: pi),
            StoreInfo(id: "indexes", name: "Search indexes",
                      purpose: "Folder lists of the folders you chose in Settings > Search Index, for fast searching",
                      location: indexes.folder,
                      retention: "Kept while the folder is in the index list. Indexes of folders no longer in the list are removed.",
                      cleanup: "Orphans removed automatically; Delete and Rebuild Indexes rebuilds them all",
                      bytes: ib, items: ii),
            StoreInfo(id: "temp", name: "Temporary files",
                      purpose: "Short-lived work files of Find itself",
                      location: files.tempDir,
                      retention: "Removed at startup and quit, and when older than the temporary-file age",
                      cleanup: "Automatic; Clear All Disposable Caches",
                      bytes: tb, items: ti),
            StoreInfo(id: "scratch", name: "Self-test scratch folders",
                      purpose: "Test folders made by the self-checks (kept only when a check failed, for inspection)",
                      location: files.cachesDir + "/selftest-* searchtest-* indextest-* phototest-*",
                      retention: "Removed when older than the temporary-file age",
                      cleanup: "Automatic; Clear All Disposable Caches",
                      bytes: sb, items: si),
            StoreInfo(id: "logs", name: "Logs and test reports",
                      purpose: "Find's log and self-check reports (plain text)",
                      location: files.logsDir,
                      retention: "Kept for the log-keep days; the current log is never removed",
                      cleanup: "Automatic",
                      bytes: lb, items: li),
            StoreInfo(id: "journals", name: "Interrupted-operation notes",
                      purpose: "Notes about copies and renames in progress, so an interrupted one can be undone at the next start",
                      location: files.journalsDir,
                      retention: "Removed when the operation ends; handled at the next start if Find was interrupted",
                      cleanup: "Never removed by clean-up (only by the start-up recovery)",
                      bytes: jb, items: ji),
        ]
        for m in memoryCaches {
            out.append(StoreInfo(id: "memory", name: m.name, purpose: "In memory only: " + m.describe(),
                                 location: "(memory)", retention: "Until Find quits, with a fixed size limit",
                                 cleanup: "Cleared by Clear All Disposable Caches", bytes: -1, items: -1))
        }
        return out
    }

    /// Total of the disposable stores on disk (previews, temporary, scratch, logs) plus indexes.
    func totalBytes(_ inv: [StoreInfo]) -> Int64 {
        return inv.filter { $0.bytes > 0 }.reduce(Int64(0)) { $0 + $1.bytes }
    }

    static func treeSize(_ path: String) -> (Int64, Int) {
        var e: Int32 = 0
        guard let info = Sys.lstatInfo(path, &e) else { return (0, 0) }
        if !info.isDirectory { return (info.size, 1) }
        var bytes: Int64 = 0, items = 1
        var stack = [path]
        var guardCount = 0
        while let d = stack.popLast(), guardCount < 200_000 {
            guardCount += 1
            for n in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] {
                let p = Paths.join(d, n)
                guard let i = Sys.lstatInfo(p, &e) else { continue }
                items += 1
                if i.isDirectory { stack.append(p) } else { bytes += i.size }
            }
        }
        return (bytes, items)
    }

    // MARK: Clean-up

    // NOTE (0.11.1): written as plain step-by-step code on purpose. 0.11.0 passed the steps as closures
    // (with the result as an inout argument and name filters as optional closures); Swift 4.1's optimiser
    // mis-compiled that, which crashed the start-up clean-up on the iMac and made an optimised test
    // build keep an old log. No closures here now; the tests run optimised as well.

    /// Which names in a folder a clean-up step may look at.
    private enum Pick {
        case all
        case scratch                 // self-test folders in the Caches folder
        case logsExcept(String?)     // .log / .txt files, never the current log
    }

    private func picks(_ n: String, _ dir: String, _ pick: Pick) -> Bool {
        switch pick {
        case .all:
            return true
        case .scratch:
            for pre in Maintenance.scratchPrefixes where n.hasPrefix(pre) { return true }
            return false
        case .logsExcept(let current):
            if !(n.hasSuffix(".log") || n.hasSuffix(".txt")) { return false }
            if let c = current, Paths.join(dir, n) == c { return false }
            return true
        }
    }

    /// Policy clean-up: old temporary files, old scratch folders, orphan indexes, previews over the limit,
    /// old logs. Skipped (reported, nothing done) while user work is running.
    func cleanUp(_ policy: MaintenancePolicy, trigger: String, now: Date = Date()) -> MaintenanceResult {
        var r = MaintenanceResult()
        r.trigger = trigger
        if !begin(&r) { return r }
        let tempAge = Double(max(0, policy.tempMaxAgeHours)) * 3600
        removeOld(in: files.tempDir, olderThan: tempAge, now: now, r: &r,
                  why: "temporary file older than \(policy.tempMaxAgeHours) h", pick: .all)
        removeOld(in: files.cachesDir, olderThan: tempAge, now: now, r: &r,
                  why: "old self-test scratch folder", pick: .scratch)
        removeOrphanIndexes(now: now, r: &r)
        removeOrphanPreviewFiles(now: now, r: &r)
        trimPreviews(limitBytes: Int64(max(50, policy.previewLimitMB)) * 1024 * 1024, r: &r)
        let keep = Double(max(1, policy.logKeepDays)) * 86400
        let current = currentLogPath
        removeOld(in: files.logsDir, olderThan: keep, now: now, r: &r,
                  why: "log older than \(policy.logKeepDays) days", pick: .logsExcept(current))
        finish(&r, now: now)
        return r
    }

    /// Everything that can be made again: previews, temporary files, scratch folders, orphan files and
    /// the in-memory caches. Keeps settings, themes, saved searches, window places, indexes, logs and notes.
    func clearDisposable(trigger: String = "Clear All Disposable Caches", now: Date = Date()) -> MaintenanceResult {
        var r = MaintenanceResult()
        r.trigger = trigger
        if !begin(&r) { return r }
        removeOld(in: previews.dir, olderThan: -1, now: now, r: &r, why: "saved preview", pick: .all)
        removeOld(in: files.tempDir, olderThan: -1, now: now, r: &r, why: "temporary file", pick: .all)
        removeOld(in: files.cachesDir, olderThan: -1, now: now, r: &r, why: "self-test scratch folder", pick: .scratch)
        removeOrphanIndexes(now: now, r: &r)
        for m in memoryCaches {
            m.clear()
            r.lines.append("CLEARED memory cache: \(m.name)")
        }
        finish(&r, now: now)
        return r
    }

    /// Delete every index file (the list of indexed folders is kept); the app rebuilds them afterwards.
    func deleteIndexes(trigger: String = "Delete and Rebuild Indexes", now: Date = Date()) -> MaintenanceResult {
        var r = MaintenanceResult()
        r.trigger = trigger
        if !begin(&r) { return r }
        let before = files.list(indexes.folder).filter { $0.hasSuffix(".findidx") }
        var bytes: Int64 = 0
        for n in before { bytes += Maintenance.treeSize(Paths.join(indexes.folder, n)).0 }
        indexes.deleteAllIndexFiles()
        let after = Set(files.list(indexes.folder).filter { $0.hasSuffix(".findidx") })
        r.removed += before.count - after.count
        r.freed += bytes
        for n in before where !after.contains(n) { r.lines.append("REMOVED index \(Paths.join(indexes.folder, n))") }
        for n in after.sorted() {
            r.failures += 1
            r.lines.append("E-MAINT-2 could not remove index \(Paths.join(indexes.folder, n))")
        }
        finish(&r, now: now)
        return r
    }

    /// Start a run: false (with the reason in `r`) when Find is busy or another clean-up is running.
    private func begin(_ r: inout MaintenanceResult) -> Bool {
        if Activity.shared.userWorkRunning {
            r.reason = "Find is busy (\(Activity.shared.describe)); it will be done later"
            Log.shared?.info("MAINTENANCE postponed (\(r.trigger)): \(Activity.shared.describe)")
            return false
        }
        if !runLock.try() {
            r.reason = "a clean-up is already running"
            return false
        }
        Activity.shared.begin(.maintenance)
        r.ran = true
        return true
    }

    private func finish(_ r: inout MaintenanceResult, now: Date) {
        saveState(r, now: now)
        Log.shared?.info("MAINTENANCE \(r.summary)")
        for l in r.lines { Log.shared?.info("MAINTENANCE " + l) }
        Activity.shared.end(.maintenance)
        runLock.unlock()
    }

    /// Is `path` inside one of the stores clean-up may remove from? (Second guard after AppFiles.)
    private func inStore(_ path: String) -> Bool {
        for root in [previews.dir, indexes.folder, files.tempDir, files.logsDir] {
            if path != root && Paths.isInside(path, root: root) { return true }
        }
        if Paths.parent(path) == files.cachesDir {
            return picks(Paths.lastComponent(path), files.cachesDir, .scratch)
        }
        return false
    }

    private func remove(_ path: String, why: String, r: inout MaintenanceResult) {
        if !inStore(path) {
            r.failures += 1
            r.lines.append("E-MAINT-1 refused (not in a Find store): \(path)")
            return
        }
        let bytes = Maintenance.treeSize(path).0
        if files.removeOwned(path) {
            r.removed += 1
            r.freed += bytes
            r.lines.append("REMOVED \(why): \(path) (\(bytes) bytes)")
        } else {
            r.failures += 1
            r.lines.append("E-MAINT-3 could not remove \(path)")
        }
    }

    /// Remove direct children of `dir` older than `age` seconds (age < 0: all) that `pick` allows.
    private func removeOld(in dir: String, olderThan age: Double, now: Date, r: inout MaintenanceResult, why: String, pick: Pick) {
        let names = files.list(dir)
        for n in names {
            if !picks(n, dir, pick) { continue }
            let p = Paths.join(dir, n)
            var e: Int32 = 0
            guard let info = Sys.lstatInfo(p, &e) else { continue }
            if age >= 0 && now.timeIntervalSince1970 - info.modified < age { continue }
            remove(p, why: why, r: &r)
        }
    }

    /// Index files that belong to no folder in the index list (and leftovers of interrupted saves).
    private func removeOrphanIndexes(now: Date, r: inout MaintenanceResult) {
        var wanted = Set<String>()
        for c in indexes.roots { wanted.insert(IndexStore.fileName(for: c.root)) }
        let names = files.list(indexes.folder)
        for n in names {
            if n == "config.json" || wanted.contains(n) { continue }
            let p = Paths.join(indexes.folder, n)
            var e: Int32 = 0
            guard let info = Sys.lstatInfo(p, &e) else { continue }
            if now.timeIntervalSince1970 - info.modified < orphanMinAge { continue }
            remove(p, why: n.hasSuffix(".findidx") ? "index of a folder no longer indexed" : "leftover file in the index folder", r: &r)
        }
    }

    /// Anything in the preview folder that isn't a finished preview (interrupted writes).
    private func removeOrphanPreviewFiles(now: Date, r: inout MaintenanceResult) {
        let names = files.list(previews.dir)
        for n in names {
            if n.hasSuffix(".jpg") { continue }
            let p = Paths.join(previews.dir, n)
            var e: Int32 = 0
            guard let info = Sys.lstatInfo(p, &e) else { continue }
            if now.timeIntervalSince1970 - info.modified < orphanMinAge { continue }
            remove(p, why: "unfinished preview", r: &r)
        }
    }

    private func trimPreviews(limitBytes: Int64, r: inout MaintenanceResult) {
        let before = Maintenance.treeSize(previews.dir)
        previews.setLimit(limitBytes)
        previews.trim()
        let after = Maintenance.treeSize(previews.dir)
        if after.1 < before.1 {
            r.removed += before.1 - after.1
            r.freed += before.0 - after.0
            r.lines.append("TRIMMED saved previews to the \(limitBytes / 1_048_576) MB limit: \(before.1 - after.1) removed")
        }
    }

    // MARK: Report

    func reportLines(_ inv: [StoreInfo], policy: MaintenancePolicy) -> [String] {
        var l: [String] = []
        l.append("Policy: \(policy.describe)")
        let st = state
        l.append("Last clean-up: " + (st.lastRun > 0 ? "\(Ascii.timestamp(Date(timeIntervalSince1970: st.lastRun))) (\(st.lastTrigger))" : "never"))
        if !st.lastSummary.isEmpty { l.append("Last result: \(st.lastSummary)") }
        l.append("Busy now: \(Activity.shared.describe)")
        for s in inv {
            l.append("STORE \(s.name): " + (s.bytes >= 0 ? "\(Listing.sizeText(s.bytes)), \(s.items) item\(s.items == 1 ? "" : "s")" : "memory"))
            l.append("  purpose: \(s.purpose)")
            l.append("  location: \(s.location)")
            l.append("  kept: \(s.retention)")
            l.append("  clean-up: \(s.cleanup)")
        }
        l.append("Never removed by clean-up: your files, RAW files, XMP sidecars, other apps' files, system files, settings, themes, saved searches, window places, indexed-folder list")
        return l
    }
}
