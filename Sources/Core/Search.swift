// Search.swift
// Direct filesystem search. Read-only. Correctness first:
//  - Every folder in scope ends in exactly one state: searched, skipped by a setting the user chose
//    (counted, with examples), or could not be searched (listed with the reason).
//  - A search is "complete" only if every folder in scope was read and every item examined.
//  - Names are compared in Unicode-normalized form (HFS+ stores decomposed names).

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

enum NameMode: Int {
    case contains = 0, exact, beginsWith, endsWith, wildcard, regex, similar

    static let titles = ["Name contains", "Name is", "Name begins with", "Name ends with",
                         "Name matches wildcard (* ?)", "Name matches regular expression",
                         "Name is similar to (allows typos)"]
}

enum KindFilter: Int {
    case any = 0, files, folders
}

struct SearchQuery {
    var text = ""
    var mode = NameMode.contains
    var caseSensitive = false
    /// Lower-case extensions without dots; empty = any.
    var extensions: [String] = []
    var kind = KindFilter.any
    var modifiedAfter: Double? = nil
    var modifiedBefore: Double? = nil
    var createdAfter: Double? = nil
    var createdBefore: Double? = nil
    var minSize: Int64? = nil
    var maxSize: Int64? = nil
    var folderNameContains = ""
    /// true: every condition must hold; false: any one is enough.
    var matchAll = true
    var includeHidden = false
    var includeSystem = false
    var includePackages = false
    var followLinks = false
    /// false = only the top level of each root.
    var recursive = true
    /// Used when building an index: walk everything, match nothing.
    var matchNothing = false
    /// 0.12: also look for the search text inside files (a file then matches by name OR contents).
    var lookInside: InsideScope = []
    /// 0.12: leave out files whose contents contain this (in the chosen kinds; both if none chosen).
    var excludeInsideText = ""

    /// Size and date conditions depend on file details the index can't keep current, so those searches
    /// always read the disk directly.
    var indexCanAnswer: Bool {
        return minSize == nil && maxSize == nil && modifiedAfter == nil && modifiedBefore == nil &&
            createdAfter == nil && createdBefore == nil
    }

    /// Parse "nef, .DNG jpg" into ["nef", "dng", "jpg"].
    static func parseExtensions(_ s: String) -> [String] {
        let parts = s.components(separatedBy: CharacterSet(charactersIn: ", ;"))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    /// One line describing the criteria (for reports).
    var describe: String {
        var p: [String] = []
        if !text.isEmpty { p.append("\(NameMode.titles[mode.rawValue]) \"\(text)\"\(caseSensitive ? " (case-sensitive)" : "")") }
        if !extensions.isEmpty { p.append("extension " + extensions.joined(separator: "/")) }
        if kind == .files { p.append("files only") }
        if kind == .folders { p.append("folders only") }
        if modifiedAfter != nil || modifiedBefore != nil { p.append("modified date range") }
        if createdAfter != nil || createdBefore != nil { p.append("created date range") }
        if minSize != nil || maxSize != nil { p.append("size range") }
        if !folderNameContains.isEmpty { p.append("in folders named like \"\(folderNameContains)\"") }
        if p.isEmpty { p.append("everything") }
        var s = p.joined(separator: matchAll ? " AND " : " OR ")
        s += "; hidden \(includeHidden ? "included" : "excluded"), system \(includeSystem ? "included" : "excluded")"
        s += ", packages \(includePackages ? "searched inside" : "not searched inside"), links \(followLinks ? "followed" : "not followed")"
        s += recursive ? ", subfolders included" : ", top level only"
        return s
    }
}

/// Text normalization used for all name comparisons.
enum NameNorm {
    static func isASCII(_ s: String) -> Bool {
        for b in s.utf8 where b >= 0x80 { return false }
        return true
    }

    /// NFC, optionally lower-cased.
    static func norm(_ s: String, caseSensitive: Bool) -> String {
        let n = isASCII(s) ? s : s.precomposedStringWithCanonicalMapping
        return caseSensitive ? n : n.lowercased()
    }

    static func bytesContain(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = needle.count, h = hay.count
        if n == 0 { return true }
        if n > h { return false }
        let first = needle[0]
        var i = 0
        while i <= h - n {
            if hay[i] == first {
                var j = 1
                while j < n && hay[i + j] == needle[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    /// Glob with * and ? on Unicode scalars.
    static func glob(_ pattern: [UInt32], _ s: [UInt32]) -> Bool {
        var p = 0, i = 0
        var starP = -1, starI = 0
        while i < s.count {
            if p < pattern.count && (pattern[p] == 63 || pattern[p] == s[i]) { // '?'
                p += 1
                i += 1
            } else if p < pattern.count && pattern[p] == 42 { // '*'
                starP = p
                starI = i
                p += 1
            } else if starP >= 0 {
                p = starP + 1
                starI += 1
                i = starI
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == 42 { p += 1 }
        return p == pattern.count
    }

    static func scalars(_ s: String) -> [UInt32] {
        return s.unicodeScalars.map { $0.value }
    }
}

enum SearchError: Error, CustomStringConvertible {
    case badRegex(String)
    var description: String {
        switch self {
        case .badRegex(let why): return "The regular expression is not valid: \(why)"
        }
    }
}

/// A query prepared for fast repeated matching.
final class CompiledQuery {
    let q: SearchQuery
    private var conditions: [(String, String, StatInfo) -> Bool] = []
    /// The name-text condition (also in `conditions`); kept apart for "name OR contents" searches.
    private var nameCondition: ((String, String, StatInfo) -> Bool)? = nil
    private let regex: NSRegularExpression?
    /// Set for "similar to" searches.
    let fuzzy: Fuzzy.Pattern?

    init(_ q: SearchQuery) throws {
        self.q = q
        var rx: NSRegularExpression? = nil
        var fz: Fuzzy.Pattern? = nil
        if !q.text.isEmpty {
            let cs = q.caseSensitive
            let needle = NameNorm.norm(q.text, caseSensitive: cs)
            switch q.mode {
            case .contains:
                let nb = Array(needle.utf8)
                nameCondition = { name, _, _ in NameNorm.bytesContain(Array(NameNorm.norm(name, caseSensitive: cs).utf8), nb) }
            case .exact:
                nameCondition = { name, _, _ in NameNorm.norm(name, caseSensitive: cs) == needle }
            case .beginsWith:
                nameCondition = { name, _, _ in NameNorm.norm(name, caseSensitive: cs).hasPrefix(needle) }
            case .endsWith:
                nameCondition = { name, _, _ in NameNorm.norm(name, caseSensitive: cs).hasSuffix(needle) }
            case .wildcard:
                let pat = NameNorm.scalars(needle)
                nameCondition = { name, _, _ in NameNorm.glob(pat, NameNorm.scalars(NameNorm.norm(name, caseSensitive: cs))) }
            case .similar:
                let pat = Fuzzy.prepare(q.text)
                fz = pat
                nameCondition = { name, _, _ in Fuzzy.distance(pat, name: name) != nil }
            case .regex:
                do {
                    rx = try NSRegularExpression(pattern: q.text.precomposedStringWithCanonicalMapping,
                                                 options: cs ? [] : [.caseInsensitive])
                } catch {
                    throw SearchError.badRegex("\(error)")
                }
            }
        }
        regex = rx
        fuzzy = fz
        if let r = rx {
            nameCondition = { name, _, _ in
                let n = name.precomposedStringWithCanonicalMapping
                return r.firstMatch(in: n, options: [], range: NSRange(location: 0, length: n.utf16.count)) != nil
            }
        }
        if let nc = nameCondition { conditions.append(nc) }
        if !q.extensions.isEmpty {
            let set = Set(q.extensions)
            conditions.append({ name, _, _ in set.contains(Paths.fileExtension(name)) })
        }
        if q.kind == .files {
            conditions.append({ _, _, info in !info.isDirectory })
        } else if q.kind == .folders {
            conditions.append({ _, _, info in info.isDirectory })
        }
        if q.modifiedAfter != nil || q.modifiedBefore != nil {
            let a = q.modifiedAfter ?? -Double.greatestFiniteMagnitude
            let b = q.modifiedBefore ?? Double.greatestFiniteMagnitude
            conditions.append({ _, _, info in info.modified >= a && info.modified <= b })
        }
        if q.createdAfter != nil || q.createdBefore != nil {
            let a = q.createdAfter ?? -Double.greatestFiniteMagnitude
            let b = q.createdBefore ?? Double.greatestFiniteMagnitude
            conditions.append({ _, _, info in info.created >= a && info.created <= b })
        }
        if q.minSize != nil || q.maxSize != nil {
            let a = q.minSize ?? Int64.min
            let b = q.maxSize ?? Int64.max
            conditions.append({ _, _, info in info.isRegular && info.size >= a && info.size <= b })
        }
        if q.matchNothing {
            conditions.append({ _, _, _ in false })
        }
        if !q.folderNameContains.isEmpty {
            let f = Array(NameNorm.norm(q.folderNameContains, caseSensitive: false).utf8)
            conditions.append({ _, parent, _ in
                NameNorm.bytesContain(Array(NameNorm.norm(Paths.lastComponent(parent), caseSensitive: false).utf8), f)
            })
        }
    }

    var hasConditions: Bool { return !conditions.isEmpty }

    /// Number of mistakes for a "similar to" match (0 = exact), or -1 when not a similarity search.
    func matchDistance(_ name: String) -> Int {
        guard let f = fuzzy else { return -1 }
        return Fuzzy.distance(f, name: name) ?? -1
    }

    /// For "look inside" searches: do the other conditions hold (all of them, or any one with Match any),
    /// and does the name text match (nil: no name text was given)?
    func parts(name: String, parent: String, info: StatInfo) -> (others: Bool, name: Bool?) {
        let nameOK = nameCondition.map { $0(name, parent, info) }
        // `conditions` starts with the name condition when there is one.
        let rest = nameCondition == nil ? conditions[...] : conditions.dropFirst()
        if q.matchAll {
            for c in rest where !c(name, parent, info) { return (false, nameOK) }
            return (true, nameOK)
        }
        if rest.isEmpty { return (false, nameOK) }
        for c in rest where c(name, parent, info) { return (true, nameOK) }
        return (false, nameOK)
    }

    var hasNameText: Bool { return nameCondition != nil }

    func matches(name: String, parent: String, info: StatInfo) -> Bool {
        if conditions.isEmpty { return true }
        if q.matchAll {
            for c in conditions where !c(name, parent, info) { return false }
            return true
        }
        for c in conditions where c(name, parent, info) { return true }
        return false
    }
}

/// Reads one folder for the search: calls `visit` for every entry with its lstat info.
/// `visit` returns false to stop early (cancel).
protocol FolderScanner {
    func scan(_ dir: String, _ visit: (String, StatInfo) -> Bool) -> ScanOutcome
}

struct ScanOutcome {
    var folderError: ReadProblem? = nil
    var entryProblems: [ReadProblem] = []
    var stoppedEarly = false
}

final class PosixScanner: FolderScanner {
    func scan(_ dir: String, _ visit: (String, StatInfo) -> Bool) -> ScanOutcome {
        var out = ScanOutcome()
        guard let d = opendir(dir) else {
            let e = errno
            out.folderError = ReadProblem(path: dir, code: e, reason: Sys.errorText(e))
            return out
        }
        defer { closedir(d) }
        while true {
            errno = 0
            guard let ent = readdir(d) else {
                let e = errno
                if e != 0 {
                    out.folderError = ReadProblem(path: dir, code: e, reason: "listing stopped part way: " + Sys.errorText(e))
                }
                break
            }
            let nameOpt: String? = withUnsafePointer(to: &ent.pointee.d_name) { ptr -> String? in
                return ptr.withMemoryRebound(to: CChar.self, capacity: 1024) { cs -> String? in
                    return String(validatingUTF8: cs)
                }
            }
            guard let name = nameOpt else {
                out.entryProblems.append(ReadProblem(path: dir, code: 0, reason: "an item's name is not valid UTF-8"))
                continue
            }
            if name == "." || name == ".." { continue }
            let path = Paths.join(dir, name)
            var err: Int32 = 0
            guard let info = Sys.lstatInfo(path, &err) else {
                if err == ENOENT { continue }
                out.entryProblems.append(ReadProblem(path: path, code: err, reason: Sys.errorText(err)))
                continue
            }
            if !visit(name, info) {
                out.stoppedEarly = true
                break
            }
        }
        return out
    }
}

struct SearchProgress {
    let foldersSearched: Int
    let matches: Int
    let currentFolder: String
    let seconds: Double
}

struct SearchSummary {
    var roots: [String] = []
    var query = ""
    var foldersSearched = 0
    var itemsExamined = 0
    var matches = 0
    /// reason -> count of folders not entered because of a setting
    var skipped: [String: Int] = [:]
    var skippedExamples: [String: [String]] = [:]
    var hiddenItemsIgnored = 0
    /// Folders that could not be read (or only partly).
    var failed: [ReadProblem] = []
    /// Items inside searched folders that could not be examined.
    var entryProblems: [ReadProblem] = []
    var cancelled = false
    var notSearchedBecauseCancelled = 0
    /// Search roots whose drive or server went away during the search.
    var disconnectedRoots: [String] = []
    /// Folders not searched because their drive or server went away.
    var notSearchedBecauseDisconnected = 0
    var seconds = 0.0
    /// Files whose contents were looked inside (0.12).
    var contentsRead = 0
    var method = "direct (every folder read from disk)"

    var isComplete: Bool {
        return failed.isEmpty && entryProblems.isEmpty && !cancelled && notSearchedBecauseCancelled == 0
            && disconnectedRoots.isEmpty && notSearchedBecauseDisconnected == 0
    }

    /// Which of the five states this search ended in.
    var outcome: SearchOutcome {
        if cancelled { return .stopped }
        if !disconnectedRoots.isEmpty { return .interrupted }
        if isComplete { return .complete }
        let problems = failed + entryProblems
        if foldersSearched == 0 && !failed.isEmpty && failed.allSatisfyCompat({ NetErrors.isUnavailable($0.code) }) { return .unavailable }
        if !problems.isEmpty && problems.allSatisfyCompat({ $0.code == EACCES || $0.code == EPERM }) { return .restricted }
        return .partial
    }

    var skippedTotal: Int { return skipped.values.reduce(0, +) }

    /// One-line status for the window.
    var statusLine: String {
        let t = String(format: "%.1f s", seconds)
        switch outcome {
        case .interrupted:
            return "INTERRUPTED: the connection to \(disconnectedRoots.map { Paths.lastComponent($0) }.joined(separator: ", ")) was lost. \(matches) matches so far, \(foldersSearched) folders searched, \(notSearchedBecauseDisconnected) not searched. Results are incomplete."
        case .unavailable:
            return "UNAVAILABLE: the location could not be reached (not mounted, disconnected, moved or deleted). Nothing was searched."
        case .restricted:
            let n = failed.count + entryProblems.count
            return "INCOMPLETE (permission): \(matches) matches. \(n) location\(n == 1 ? "" : "s") could not be opened because you don't have permission. \(foldersSearched) folders searched in \(t)."
        default:
            break
        }
        if cancelled {
            return "STOPPED: \(matches) matches so far. \(foldersSearched) folders searched, \(notSearchedBecauseCancelled) not searched. Results are incomplete."
        }
        if !isComplete {
            let n = failed.count + entryProblems.count
            return "INCOMPLETE: \(matches) matches. \(n) location\(n == 1 ? "" : "s") could not be searched. \(foldersSearched) folders searched in \(t)."
        }
        var s = "Complete: \(matches) match\(matches == 1 ? "" : "es"). Every folder in scope was searched (\(foldersSearched)) in \(t)."
        if skippedTotal > 0 { s += " \(skippedTotal) skipped by your settings." }
        return s
    }

    func reportLines() -> [String] {
        var l: [String] = []
        l.append("Result: \(outcome.rawValue)")
        l.append("Search method: \(method)")
        l.append("Looking for: \(query)")
        for r in roots { l.append("Scope root: \(r)") }
        l.append("Folders searched: \(foldersSearched)")
        l.append("Items examined: \(itemsExamined)")
        l.append("Matches: \(matches)")
        l.append(String(format: "Time: %.2f s", seconds))
        if hiddenItemsIgnored > 0 { l.append("Hidden items not considered (hidden files are off): \(hiddenItemsIgnored)") }
        for (reason, n) in skipped.sorted(by: { $0.key < $1.key }) {
            l.append("Skipped by setting: \(n) folder\(n == 1 ? "" : "s") - \(reason)")
            for ex in (skippedExamples[reason] ?? []).prefix(5) { l.append("  example: \(ex)") }
        }
        if contentsRead > 0 { l.append("Files looked inside (metadata / document text): \(contentsRead)") }
        if cancelled { l.append("Stopped by you. Folders not searched: \(notSearchedBecauseCancelled)") }
        for r in disconnectedRoots { l.append("CONNECTION LOST during the search: \(r)") }
        if notSearchedBecauseDisconnected > 0 { l.append("Folders not searched because the connection was lost: \(notSearchedBecauseDisconnected)") }
        for f in failed { l.append("COULD NOT SEARCH: \(f.path) - \(f.reason) (code \(f.code))") }
        for e in entryProblems.prefix(200) { l.append("COULD NOT EXAMINE ITEM: \(e.path) - \(e.reason) (code \(e.code))") }
        if entryProblems.count > 200 { l.append("... and \(entryProblems.count - 200) more items that could not be examined") }
        return l
    }
}

/// Runs one search. Create, call run() on a background thread, call cancel() from anywhere.
final class SearchEngine {
    struct Root {
        let path: String
    }

    let query: SearchQuery
    let compiled: CompiledQuery
    let roots: [String]
    let scanner: FolderScanner
    let workers: Int
    /// Is this folder (path, lower-case extension) a package (app, bundle, library)?
    let isPackage: (String, String) -> Bool
    /// Index searches: re-check every match against the disk before it is shown (drop vanished items,
    /// refresh sizes and dates, re-apply the hidden rule with the item's current flags).
    var validateHits = false
    /// Is this search root still there? (Replaceable for tests.) Asked only after a folder read fails
    /// with a connection-type error, at most once per root per 2 seconds.
    var rootCheck: (String) -> Bool = { r in
        var e: Int32 = 0
        return Sys.statInfo(r, &e) != nil
    }
    private var lastRootCheck: [String: Date] = [:]
    private var lostRoots = Set<String>()
    /// Called from worker threads with new matches (batched).
    var onResults: (([FileEntry]) -> Void)?
    /// Called from worker threads about ten times a second.
    var onProgress: ((SearchProgress) -> Void)?

    private let lock = NSCondition()
    private var stack: [(path: String, device: UInt64, depth: Int)] = []
    private var active = 0
    private var cancelFlag = false
    private var summary = SearchSummary()
    private var pending: [FileEntry] = []
    private var lastPost = Date.distantPast
    private var visitedDirs = Set<String>()
    private var started = Date()
    private var currentFolder = ""

    static let systemTopLevel: Set<String> = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/cores",
                                               "/dev", "/opt", "/etc", "/var", "/tmp", "/Network", "/net", "/home"]
    static let systemVolumeLevelNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".Trashes",
                                                      ".TemporaryItems", ".MobileBackups", ".PKInstallSandboxManager",
                                                      ".PKInstallSandboxManager-SystemSoftware", ".vol"]

    init(query: SearchQuery, roots: [String], scanner: FolderScanner = PosixScanner(), workers: Int = 4,
         isPackage: @escaping (String, String) -> Bool) throws {
        self.query = query
        self.compiled = try CompiledQuery(query)
        self.roots = roots
        self.scanner = scanner
        self.workers = max(1, min(16, workers))
        self.isPackage = isPackage
        self.insideNeedle = NameNorm.norm(query.text, caseSensitive: query.caseSensitive)
        self.excludeNeedle = NameNorm.norm(query.excludeInsideText.trimmingCharacters(in: .whitespaces), caseSensitive: query.caseSensitive)
    }

    private let insideNeedle: String
    private let excludeNeedle: String

    func cancel() {
        lock.lock()
        cancelFlag = true
        lock.broadcast()
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelFlag
    }

    private func skip(_ reason: String, _ path: String) {
        // caller holds the lock
        summary.skipped[reason] = (summary.skipped[reason] ?? 0) + 1
        var ex = summary.skippedExamples[reason] ?? []
        if ex.count < 20 {
            ex.append(path)
            summary.skippedExamples[reason] = ex
        }
    }

    /// Run to the end (or until cancelled). Blocks the calling thread.
    func run() -> SearchSummary {
        Activity.shared.begin(.search)
        defer { Activity.shared.end(.search) }
        started = Date()
        summary.roots = roots
        summary.query = query.describe
        lock.lock()
        for r in roots {
            var e: Int32 = 0
            guard let info = Sys.statInfo(r, &e) else {
                summary.failed.append(ReadProblem(path: r, code: e, reason: e == ENOENT ? "location not found (moved, deleted or disconnected)" : Sys.errorText(e)))
                continue
            }
            if !info.isDirectory {
                summary.failed.append(ReadProblem(path: r, code: 0, reason: "not a folder"))
                continue
            }
            if query.followLinks, let real = Sys.realPath(r) { visitedDirs.insert(real) }
            stack.append((r, info.device, 0))
        }
        lock.unlock()

        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.workerLoop()
                group.leave()
            }
        }
        group.wait()

        lock.lock()
        if cancelFlag {
            summary.cancelled = true
            summary.notSearchedBecauseCancelled += stack.count
            stack.removeAll()
        }
        summary.seconds = Date().timeIntervalSince(started)
        insideLock.lock()
        summary.contentsRead = contentsRead
        insideLock.unlock()
        let finalBatch = pending
        pending = []
        let result = summary
        lock.unlock()
        if !finalBatch.isEmpty { onResults?(finalBatch) }
        return result
    }

    private func workerLoop() {
        while true {
            lock.lock()
            while stack.isEmpty && active > 0 && !cancelFlag {
                lock.wait()
            }
            if cancelFlag || stack.isEmpty {
                lock.broadcast()
                lock.unlock()
                return
            }
            let job = stack.removeLast()
            active += 1
            currentFolder = job.path
            lock.unlock()

            withPool {
                process(job.path, device: job.device, depth: job.depth)
            }

            lock.lock()
            active -= 1
            lock.broadcast()
            lock.unlock()
        }
    }

    private func process(_ dir: String, device: UInt64, depth: Int) {
        var subdirs: [(String, UInt64, Int)] = []
        var hits: [FileEntry] = []
        var examined = 0
        var hiddenIgnored = 0
        var localSkips: [(String, String)] = []
        let q = query
        let atVolumeRoot = dir == "/" || Paths.parent(dir) == "/Volumes"

        let outcome = scanner.scan(dir) { name, info in
            if (examined & 255) == 0 && self.isCancelled { return false }
            examined += 1
            let path = Paths.join(dir, name)
            let hidden = name.hasPrefix(".") || info.hasHiddenFlag
            if hidden && !q.includeHidden {
                if info.isDirectory { localSkips.append(("hidden folder (Show hidden files is off)", path)) } else { hiddenIgnored += 1 }
                return true
            }
            let isDir = info.isDirectory
            if self.lookingInside ? self.matchesWithContents(name: name, path: path, parent: dir, info: info)
                                  : self.compiled.matches(name: name, parent: dir, info: info) {
                var e = FileEntry.make(name: name, path: path, info: info)
                if self.compiled.fuzzy != nil { e.matchDistance = self.compiled.matchDistance(name) }
                hits.append(e)
            }
            if !q.recursive { return true }
            if isDir {
                if !q.includeSystem && (SearchEngine.systemTopLevel.contains(path) ||
                    (atVolumeRoot && SearchEngine.systemVolumeLevelNames.contains(name))) {
                    localSkips.append(("system folder (Include System Files is off)", path))
                    return true
                }
                if info.device != device {
                    localSkips.append(("another drive mounted inside this one (searched only if chosen as a location)", path))
                    return true
                }
                let ext = Paths.fileExtension(name)
                if !q.includePackages && !ext.isEmpty && self.isPackage(path, ext) {
                    localSkips.append(("inside packages such as .app (Search inside packages is off)", path))
                    return true
                }
                subdirs.append((path, info.device, depth + 1))
            } else if info.isSymlink {
                var e: Int32 = 0
                if let target = Sys.statInfo(path, &e), target.isDirectory {
                    if !q.followLinks {
                        localSkips.append(("symbolic link to a folder (Follow links is off)", path))
                    } else {
                        subdirs.append((path, target.device, depth + 1))
                    }
                }
            }
            return true
        }

        if validateHits && !hits.isEmpty {
            hits = hits.compactMap { h -> FileEntry? in
                var e: Int32 = 0
                guard let fresh = Sys.lstatInfo(h.path, &e) else { return nil }
                let hiddenNow = h.name.hasPrefix(".") || fresh.hasHiddenFlag
                if hiddenNow && !q.includeHidden { return nil }
                if lookingInside {
                    // Found by name or by contents: re-check only the other conditions (contents were just read).
                    if q.matchAll && !compiled.parts(name: h.name, parent: dir, info: fresh).others { return nil }
                } else if !compiled.matches(name: h.name, parent: dir, info: fresh) {
                    return nil
                }
                var n = FileEntry.make(name: h.name, path: h.path, info: fresh)
                n.matchDistance = h.matchDistance
                return n
            }
        }

        // A folder failed with a connection-type error: is the whole drive / server gone?
        var lostRoot: String? = nil
        if let fe = outcome.folderError, NetErrors.isUnavailable(fe.code), let r = searchRoot(of: dir) {
            lock.lock()
            let already = lostRoots.contains(r)
            let recent = lastRootCheck[r].map { Date().timeIntervalSince($0) < 2 } ?? false
            if !already && !recent { lastRootCheck[r] = Date() }
            lock.unlock()
            if already {
                lostRoot = r
            } else if !recent && !rootCheck(r) {
                lostRoot = r
            }
        }

        lock.lock()
        if let r = lostRoot {
            if !lostRoots.contains(r) {
                lostRoots.insert(r)
                summary.disconnectedRoots.append(r)
                // Drop the queued folders of that root: every one would wait for a network timeout.
                let before = stack.count
                stack = stack.filter { !Paths.isInside($0.path, root: r) && $0.path != r }
                summary.notSearchedBecauseDisconnected += before - stack.count
            }
            summary.notSearchedBecauseDisconnected += 1
            summary.itemsExamined += examined
            summary.matches += hits.count
            pending.append(contentsOf: hits)
            lock.unlock()
            return
        }
        summary.itemsExamined += examined
        summary.hiddenItemsIgnored += hiddenIgnored
        for (reason, p) in localSkips { skip(reason, p) }
        summary.entryProblems.append(contentsOf: outcome.entryProblems)
        if let fe = outcome.folderError {
            summary.failed.append(fe)
        } else if outcome.stoppedEarly {
            summary.notSearchedBecauseCancelled += 1
        } else {
            summary.foldersSearched += 1
        }
        for s in subdirs {
            if q.followLinks {
                // Loop protection: never enter the same real folder twice.
                guard let real = Sys.realPath(s.0) else {
                    summary.failed.append(ReadProblem(path: s.0, code: 0, reason: "link target could not be resolved"))
                    continue
                }
                if visitedDirs.contains(real) {
                    skip("folder already searched through another path (link loop protection)", s.0)
                    continue
                }
                visitedDirs.insert(real)
            }
            stack.append((s.0, s.1, s.2))
        }
        summary.matches += hits.count
        pending.append(contentsOf: hits)
        var batch: [FileEntry] = []
        var progress: SearchProgress? = nil
        let now = Date()
        if now.timeIntervalSince(lastPost) >= 0.1 {
            lastPost = now
            batch = pending
            pending = []
            progress = SearchProgress(foldersSearched: summary.foldersSearched, matches: summary.matches,
                                      currentFolder: currentFolder, seconds: now.timeIntervalSince(started))
        }
        lock.unlock()
        if !batch.isEmpty { onResults?(batch) }
        if let p = progress { onProgress?(p) }
    }

    // MARK: Looking inside files (0.12)

    private var lookingInside: Bool { return !query.lookInside.isEmpty || !query.excludeInsideText.isEmpty }
    // Set once in init (the search runs on several threads; no lazy values here).
    private let insideLock = NSLock()
    private var contentsRead = 0

    /// Name OR contents (the other conditions still apply), then the "but not containing" text.
    private func matchesWithContents(name: String, path: String, parent: String, info: StatInfo) -> Bool {
        let q = query
        var ok: Bool
        let readable = info.isRegular && !info.isDirectory
        if q.lookInside.isEmpty || !compiled.hasNameText {
            ok = compiled.matches(name: name, parent: parent, info: info)
        } else {
            let (others, nameOK) = compiled.parts(name: name, parent: parent, info: info)
            if q.matchAll {
                ok = others && (nameOK ?? true)
                if !ok && others && nameOK == false && readable && ContentSearch.isCandidate(name, q.lookInside) && !isCancelled {
                    ok = readInside(path, name, insideNeedle, q.lookInside)
                }
            } else {
                ok = others || (nameOK ?? false)
                if !ok && readable && ContentSearch.isCandidate(name, q.lookInside) && !isCancelled {
                    ok = readInside(path, name, insideNeedle, q.lookInside)
                }
            }
        }
        if ok && !excludeNeedle.isEmpty && readable {
            let scope: InsideScope = q.lookInside.isEmpty ? [.metadata, .documents] : q.lookInside
            if ContentSearch.isCandidate(name, scope) && readInside(path, name, excludeNeedle, scope) { ok = false }
        }
        return ok
    }

    private func readInside(_ path: String, _ name: String, _ needle: String, _ scope: InsideScope) -> Bool {
        insideLock.lock(); contentsRead += 1; insideLock.unlock()
        return ContentSearch.contains(path: path, name: name, needle: needle, caseSensitive: query.caseSensitive, scope: scope)
    }

    /// The search root containing `dir` (longest match).
    private func searchRoot(of dir: String) -> String? {
        var best: String? = nil
        for r in roots where dir == r || Paths.isInside(dir, root: r) {
            if best == nil || r.count > best!.count { best = r }
        }
        return best
    }

}

/// Total size of a folder (read-only walk; links not followed). Used by Get Info.
enum FolderSize {
    struct Result {
        var bytes: Int64 = 0
        var files = 0
        var folders = 0
        var unreadable = 0
        var cancelled = false
    }

    /// Counts only items on the same drive as `path` (never wanders into other mounted drives or shares).
    static func compute(_ path: String, isCancelled: () -> Bool) -> Result {
        var r = Result()
        var stack = [path]
        let scanner = PosixScanner()
        var e: Int32 = 0
        let device = Sys.statInfo(path, &e)?.device
        while let dir = stack.popLast() {
            if isCancelled() {
                r.cancelled = true
                break
            }
            let out = scanner.scan(dir) { name, info in
                if info.isDirectory {
                    if let d = device, info.device != d { return true }
                    r.folders += 1
                    stack.append(Paths.join(dir, name))
                } else {
                    r.files += 1
                    if info.isRegular { r.bytes += info.size }
                }
                return true
            }
            if out.folderError != nil { r.unreadable += 1 }
            r.unreadable += out.entryProblems.count
        }
        return r
    }
}

/// "rwxr-xr-x" for POSIX permission bits.
func permissionString(_ mode: UInt32) -> String {
    let chars: [Character] = ["r", "w", "x"]
    var s = ""
    for shift in [6, 3, 0] {
        for (i, c) in chars.enumerated() {
            s.append(((mode >> UInt32(shift)) & UInt32(4 >> i)) != 0 ? c : "-")
        }
    }
    return s

}

enum SearchOutcome: String {
    case complete = "COMPLETE"
    case stopped = "STOPPED (incomplete)"
    case interrupted = "INTERRUPTED - CONNECTION LOST (incomplete)"
    case unavailable = "UNAVAILABLE"
    case restricted = "INCOMPLETE - PERMISSION"
    case partial = "INCOMPLETE"
}

/// Error codes that mean "the drive or server is not there" rather than "this one folder is unreadable".
enum NetErrors {
    static let connectionLost: Set<Int32> = [ENOTCONN, ETIMEDOUT, EIO, ENXIO, ENODEV, EHOSTDOWN, EHOSTUNREACH,
                                             ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED, ESTALE]
    static func isConnectionLost(_ code: Int32) -> Bool { return connectionLost.contains(code) }
    /// Connection loss, or the location is simply gone.
    static func isUnavailable(_ code: Int32) -> Bool { return code == ENOENT || connectionLost.contains(code) }
}
