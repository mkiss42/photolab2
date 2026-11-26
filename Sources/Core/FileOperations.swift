// FileOperations.swift
// User-file operations: rename (one file or a whole raw+jpg+xmp set), new folder, Trash, put
// back, copy and move (the transfer engine), and the recovery journals. One of the three source
// files allowed to change files.
//
// Contract (docs/PLAN.md section 7): nothing is deleted permanently (Trash only), nothing is
// overwritten (exclusive renames), multi-step operations are journaled and all-or-nothing.
// Call these on a background queue: they touch the disk, which may be a slow share.

import Foundation
import Darwin

struct OpFailure: Error {
    let code: String       // E-OPS-n
    let message: String    // for the user
}

enum FileOperations {
    // MARK: Sets (same as PhotoLab 1: raws + jpg/jpeg/heic/heif + xmp/acr group by name;
    // tif/psd/png never do, they are derivatives)

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "nif", "arw", "sr2", "srf", "srw", "dng", "raf", "x-raw", "rw2",
        "orf", "orfz", "bay", "pef", "ptx", "3fr", "fff", "iiq", "x3f", "mdc", "dcr", "k25", "kdc",
        "spx", "erf", "braw", "zraw", "r3d"]
    static let groupable: Set<String> = rawExtensions.union(["xmp", "acr", "jpg", "jpeg", "heic", "heif"])

    /// Settings: treat files of a set as one (default on).
    static var useSets: Bool {
        get { return UserDefaults.standard.object(forKey: "fileSets") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fileSets") }
    }

    /// "IMG_1.CR3" -> ("IMG_1", "CR3"); no extension -> (name, "").
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[name.startIndex..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Every file of the set `path` belongs to, read from disk now (includes `path`).
    static func setMembers(of path: String, sets: Bool = useSets) -> [String] {
        let (stem, ext) = split(Paths.name(path))
        guard sets, groupable.contains(ext.lowercased()) else { return [path] }
        let listing = DirectoryReader.read(Paths.parent(path))
        var out = listing.entries.filter { e in
            !e.isDirectory && groupable.contains(e.ext) && split(e.name).stem == stem
        }.map { $0.path }
        if !out.contains(path) { out.append(path) }
        return out.sorted()
    }

    // MARK: Rename

    static func validate(_ name: String) -> OpFailure? {
        if name.isEmpty || name == "." || name == ".." {
            return OpFailure(code: "E-OPS-1", message: "That name can't be used.")
        }
        if name.contains("/") || name.contains("\u{0}") {
            return OpFailure(code: "E-OPS-1", message: "Names can't contain \"/\".")
        }
        if name.utf8.count > 255 {
            return OpFailure(code: "E-OPS-1", message: "That name is too long.")
        }
        return nil
    }

    /// The (from, to) pairs renaming `path` to `newName` means. With sets, every member gets the
    /// new stem and keeps its own extension, unless the extension itself was changed.
    static func renamePlan(_ path: String, to newName: String, sets: Bool = useSets) -> [(String, String)] {
        let dir = Paths.parent(path)
        let old = split(Paths.name(path))
        let new = split(newName)
        var pairs: [(String, String)] = [(path, Paths.join(dir, newName))]
        if sets && old.ext.lowercased() == new.ext.lowercased() && groupable.contains(old.ext.lowercased()) {
            for m in setMembers(of: path, sets: true) where m != path {
                let mExt = split(Paths.name(m)).ext
                pairs.append((m, Paths.join(dir, new.stem + (mExt.isEmpty ? "" : "." + mExt))))
            }
        }
        return pairs.filter { $0.0 != $0.1 }
    }

    /// Rename all-or-nothing. Returns the pairs done (for undo).
    static func rename(_ path: String, to newName: String, sets: Bool = useSets) -> Result<[(String, String)], OpFailure> {
        if let f = validate(newName) { return .failure(f) }
        let pairs = renamePlan(path, to: newName, sets: sets)
        return applyRenames(pairs, what: "rename")
    }

    /// Rename many items exactly as given (undo of a rename uses this with the pairs reversed).
    static func applyRenames(_ pairs: [(String, String)], what: String) -> Result<[(String, String)], OpFailure> {
        if pairs.isEmpty { return .success([]) }
        // Every target must be free (or be the same item under another case) before anything moves.
        for (from, to) in pairs {
            var a = stat(), b = stat()
            if lstat(from, &a) != 0 {
                return .failure(OpFailure(code: "E-OPS-1", message: "\"\(Paths.name(from))\" is no longer there. Nothing was renamed."))
            }
            if lstat(to, &b) == 0 && !(a.st_dev == b.st_dev && a.st_ino == b.st_ino) && !pairs.contains(where: { $0.0 == to }) {
                return .failure(OpFailure(code: "E-OPS-1", message: "\"\(Paths.name(to))\" already exists. Nothing was renamed."))
            }
        }
        AppFiles.writeJournal(op: what, pairs: pairs)
        var done: [(String, String)] = []
        for (from, to) in pairs {
            let e = Platform.renameExclusive(from, to)
            if e != 0 {
                // Undo what was done so the set stays together.
                var rollbackFailed: [String] = []
                for (f, t) in done.reversed() where Platform.renameExclusive(t, f) != 0 { rollbackFailed.append(Paths.name(t)) }
                AppFiles.clearJournal()
                let why = String(cString: strerror(e))
                Log.error("E-OPS-1 \(what) failed at \(from) -> \(to): \(why); rolled back \(done.count - rollbackFailed.count) of \(done.count)")
                if rollbackFailed.isEmpty {
                    return .failure(OpFailure(code: "E-OPS-1", message: "\"\(Paths.name(from))\" could not be renamed: \(why). Nothing was changed."))
                }
                return .failure(OpFailure(code: "E-OPS-1", message: "Renaming stopped: \(why). These could not be put back: \(rollbackFailed.joined(separator: ", "))."))
            }
            done.append((from, to))
        }
        AppFiles.clearJournal()
        Log.info("\(what): " + done.map { "\(Paths.name($0.0)) -> \(Paths.name($0.1))" }.joined(separator: ", ") + " in \(Paths.parent(done[0].0))")
        return .success(done)
    }

    // MARK: New folder

    static func newFolder(in dir: String) -> Result<String, OpFailure> {
        for i in 1...200 {
            let name = i == 1 ? "untitled folder" : "untitled folder \(i)"
            let p = Paths.join(dir, name)
            let e = Platform.makeFolder(p)
            if e == 0 { Log.info("new folder \(p)"); return .success(p) }
            if e != EEXIST {
                let why = String(cString: strerror(e))
                Log.error("E-OPS-3 new folder in \(dir) failed: \(why)")
                return .failure(OpFailure(code: "E-OPS-3", message: "The folder could not be created: \(why)."))
            }
        }
        return .failure(OpFailure(code: "E-OPS-3", message: "Too many untitled folders here already."))
    }

    // MARK: Trash

    struct Trashed {
        let original: String
        let inTrash: String
    }

    /// Move items (and, with sets, their set members) to the Trash. Nothing is deleted here.
    /// `noTrash`: items on network volumes whose server has no Trash (the caller may offer
    /// deletePermanently after an explicit confirmation, like Finder).
    static func trash(_ paths: [String], sets: Bool = useSets) -> (done: [Trashed], failures: [String], noTrash: [String]) {
        var all: [String] = []
        for p in paths {
            for m in setMembers(of: p, sets: sets) where !all.contains(m) { all.append(m) }
        }
        var done: [Trashed] = []
        var failures: [String] = []
        var noTrash: [String] = []
        for p in all {
            let r = Platform.moveToTrash(p)
            if let t = r.trashed {
                done.append(Trashed(original: p, inTrash: t))
            } else if Volumes.isNetwork(p) {
                noTrash.append(p)
                Log.info("no Trash on this share for \(p): \(r.error ?? "?")")
            } else {
                failures.append("\(Paths.name(p)): \(r.error ?? "unknown error")")
                Log.error("E-OPS-2 not moved to Trash: \(p): \(r.error ?? "?")")
            }
        }
        if !done.isEmpty { Log.info("moved to Trash: \(done.count) item(s) from \(Paths.parent(done[0].original))") }
        return (done, failures, noTrash)
    }

    /// Delete for good. Only after the user confirmed, for items on shares without a Trash
    /// (lab decision 2026-11-25, Finder's behaviour). Folders go with their contents.
    static func deletePermanently(_ paths: [String]) -> [String] {
        var failures: [String] = []
        for p in paths {
            do {
                try FileManager.default.removeItem(atPath: p)
                Log.warn("W-OPS-2 deleted permanently (share has no Trash, user confirmed): \(p)")
            } catch {
                let why = (error as NSError).localizedDescription
                failures.append("\(Paths.name(p)): \(why)")
                Log.error("E-OPS-5 permanent delete failed: \(p): \(why)")
            }
        }
        return failures
    }

    /// Undo of trash: move items back where they were (never over something new there).
    static func putBack(_ items: [Trashed]) -> [String] {
        var failures: [String] = []
        for it in items.reversed() {
            let e = Platform.renameExclusive(it.inTrash, it.original)
            if e != 0 {
                let why = e == EEXIST ? "something with that name is there now" : String(cString: strerror(e))
                failures.append("\(Paths.name(it.original)): \(why)")
                Log.error("E-OPS-4 put back failed: \(it.original): \(why)")
            }
        }
        Log.info("put back from Trash: \(items.count - failures.count) of \(items.count)")
        return failures
    }

    /// Undo of "new folder": only an empty folder goes (to the Trash).
    static func removeNewFolder(_ path: String) -> String? {
        let l = DirectoryReader.read(path)
        if !l.entries.isEmpty { return "\"\(Paths.name(path))\" is no longer empty, so it was left in place." }
        let r = Platform.moveToTrash(path)
        return r.trashed == nil ? (r.error ?? "could not be moved to the Trash") : nil
    }

    // MARK: Recovery

    /// At launch: a journal left behind means PhotoLab stopped in the middle of a multi-step
    /// rename. Put every already-renamed item back, so the set is whole again.
    static func recoverJournal(quiet: Bool = false) -> String? {
        guard let j = AppFiles.readJournal() else { return nil }
        var restored = 0
        for (from, to) in j.pairs.reversed() {
            var a = stat(), b = stat()
            if lstat(to, &b) == 0 && lstat(from, &a) != 0 && Platform.renameExclusive(to, from) == 0 { restored += 1 }
        }
        AppFiles.clearJournal()
        let text = "W-OPS-1 an interrupted \(j.op) was found at launch; \(restored) item(s) put back to their old names"
        if quiet { Log.info("self-test: journal recovery put back \(restored) item(s)") } else { Log.warn(text) }
        return restored > 0 ? "PhotoLab was stopped in the middle of a rename. \(restored) file(s) were given back their old names, so nothing is half-renamed." : nil
    }

    // MARK: Copy and move (docs/PLAN.md section 7)
    //
    // - Every top-level item is written under a hidden name (Transfers.partialPrefix) and renamed
    //   to its real name only when complete and verified; the hidden name is journaled, so an
    //   interrupted copy never shows up half-written and is removed at the next launch.
    // - Never overwrites: a taken name means "keep both" (numbered name) or "skip".
    // - Sets travel whole: members are skipped or renamed together.
    // - Each file: same-volume clone when the volume can, else a byte copy; then the size of the
    //   copy and the unchanged size+date of the source are checked.
    // - Same-volume moves are renames (all-or-nothing, undoable). Cross-volume moves copy, verify,
    //   then remove exactly the originals that were copied and did not change meanwhile.

    struct TransferPlan {
        var items: [TransferItem] = []
        var clashes: [String] = []          // names already taken in the destination
        var problem: String?                // refuse the whole job
        var duplicate = false               // copy into the items' own folder
    }

    private static func why(_ e: Int32) -> String { return String(cString: strerror(e)) }

    private static func isFolder(_ st: stat) -> Bool {
        return UInt32(st.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR)
    }

    private static func kindOf(_ st: stat) -> FileEntry.Kind {
        switch UInt32(st.st_mode) & UInt32(S_IFMT) {
        case UInt32(S_IFDIR): return .directory
        case UInt32(S_IFREG): return .file
        case UInt32(S_IFLNK): return .symlink
        default: return .other
        }
    }

    private static func resolved(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// Sources grouped into sets, each parent folder read once. A path already in a group is not
    /// repeated (dragging the RAW and its JPG gives one set).
    static func expandSets(_ paths: [String], sets: Bool = useSets) -> [[String]] {
        var listings: [String: [FileEntry]] = [:]
        var seen = Set<String>()
        var groups: [[String]] = []
        for p in paths where !seen.contains(p) {
            var members = [p]
            let (stem, ext) = split(Paths.name(p))
            if sets && groupable.contains(ext.lowercased()) {
                let dir = Paths.parent(p)
                if listings[dir] == nil { listings[dir] = DirectoryReader.read(dir).entries }
                let more = listings[dir]!.filter { e in
                    !e.isDirectory && groupable.contains(e.ext) && split(e.name).stem == stem && e.path != p
                }.map { $0.path }
                members = ([p] + more).sorted()
            }
            let fresh = members.filter { !seen.contains($0) }
            for m in fresh { seen.insert(m) }
            if !fresh.isEmpty { groups.append(fresh) }
        }
        return groups
    }

    /// What a copy or move of `paths` into `dest` means. Background queue: reads the disk.
    static func planTransfer(_ paths: [String], to dest: String, kind: TransferKind, sets: Bool = useSets) -> TransferPlan {
        var plan = TransferPlan()
        var ds = stat()
        guard lstat(dest, &ds) == 0, isFolder(ds) else {
            plan.problem = "\"\(Paths.name(dest))\" can't be reached as a folder right now. Nothing was changed."
            return plan
        }
        let realDest = resolved(dest)
        var group = 0
        var allHere = true
        for members in expandSets(paths, sets: sets) {
            var added = false
            for src in members {
                var ss = stat()
                guard lstat(src, &ss) == 0 else { continue }          // gone since it was picked
                let folder = isFolder(ss)
                if folder && Transfers.intoItself(source: resolved(src), destination: realDest) {
                    let verb = kind == .copy ? "copied" : "moved"
                    return TransferPlan(items: [], clashes: [], problem: "\"\(Paths.name(src))\" can't be \(verb) into itself. Nothing was changed.", duplicate: false)
                }
                let here = Paths.parent(src) == dest || resolved(Paths.parent(src)) == realDest
                if !here { allHere = false }
                if kind == .move && here { continue }                 // already there
                plan.items.append(TransferItem(source: src, group: group, isFolder: folder, crossDevice: ss.st_dev != ds.st_dev))
                added = true
                var ts = stat()
                if lstat(Paths.join(dest, Paths.name(src)), &ts) == 0 { plan.clashes.append(Paths.name(src)) }
            }
            if added { group += 1 }
        }
        plan.duplicate = kind == .copy && allHere && !plan.items.isEmpty
        return plan
    }

    /// Run one job on the calling background queue: state, progress and results go into `job`.
    static func runTransfer(_ job: TransferJob) {
        let t0 = Date()
        job.update { $0.started = t0; $0.state = .scanning }
        if job.isCancelled { finish(job, t0); return }
        Log.info("\(job.kind.rawValue) \(job.id) start: \(job.items.count) item(s) -> \(job.destination)")
        let renames = job.kind == .move ? job.items.filter { !$0.crossDevice } : []
        let copies = job.kind == .move ? job.items.filter { $0.crossDevice } : job.items
        var reserved = Set<String>()
        if !renames.isEmpty { moveByRenaming(renames, job, &reserved) }
        if !copies.isEmpty && !job.isCancelled { copyItems(copies, job, &reserved) }
        finish(job, t0)
    }

    private static func grouped(_ items: [TransferItem]) -> [[TransferItem]] {
        var out: [[TransferItem]] = []
        for it in items {
            if let last = out.last?.last, last.group == it.group { out[out.count - 1].append(it) } else { out.append([it]) }
        }
        return out
    }

    /// Final names for one group, checked against the disk now, or nil to skip the group.
    /// `reserved` holds names given to earlier groups of this job (lowercased: most volumes ignore case).
    private static func targetNames(_ group: [TransferItem], _ job: TransferJob, _ reserved: inout Set<String>) -> [String]? {
        let dest = job.destination
        let names = group.map { Paths.name($0.source) }
        func free(_ ns: [String]) -> Bool {
            return ns.allSatisfy { n in
                var s = stat()
                return !reserved.contains(n.lowercased()) && lstat(Paths.join(dest, n), &s) != 0
            }
        }
        var chosen: [String]?
        if free(names) {
            chosen = names
        } else if job.clash == .keepBoth || job.duplicate {
            for n in (job.duplicate ? 1 : 2)...9999 {
                let ns = zip(group, names).map { Transfers.numberedName($0.1, n, duplicate: job.duplicate, isFolder: $0.0.isFolder) }
                if free(ns) { chosen = ns; break }
            }
        }
        if let c = chosen { for n in c { reserved.insert(n.lowercased()) } }
        return chosen
    }

    private static func moveByRenaming(_ items: [TransferItem], _ job: TransferJob, _ reserved: inout Set<String>) {
        job.update { $0.state = .running; $0.totalFiles += items.count }
        var pairs: [(String, String)] = []
        for g in grouped(items) {
            guard let names = targetNames(g, job, &reserved) else {
                job.update { $0.skipped += g.count; $0.totalFiles -= g.count }
                continue
            }
            for (it, n) in zip(g, names) { pairs.append((it.source, Paths.join(job.destination, n))) }
        }
        switch applyRenames(pairs, what: "move") {
        case .success(let done):
            job.moved = done
            job.update { $0.doneFiles += done.count }
        case .failure(let f):
            job.update { $0.failures.append(f.message) }
        }
    }

    private struct ScanNode {
        let rel: String          // "" for the item itself
        let kind: FileEntry.Kind
        let size: Int64
        let modified: Double
        let created: Double
    }

    /// AppleDouble files ("._x") carry the metadata copyfile writes for the main file; copying
    /// them as files races the OS (PhotoLab 1 lesson). Our own partial copies never travel.
    private static func skipInCopy(_ name: String) -> Bool {
        return name.hasPrefix("._") || name.hasPrefix(Transfers.partialPrefix)
    }

    /// Everything inside one item, parents before children; one (bulk) listing per folder.
    private static func scan(_ path: String, _ job: TransferJob) -> (nodes: [ScanNode], error: String?) {
        var st = stat()
        if lstat(path, &st) != 0 { return ([], "it is no longer there") }
        let kind = kindOf(st)
        var nodes = [ScanNode(rel: "", kind: kind, size: kind == .file ? Int64(st.st_size) : 0,
                              modified: DirectoryReader.seconds(st.st_mtimespec), created: DirectoryReader.seconds(st.st_birthtimespec))]
        if kind == .other { return ([], "it is not a file or folder") }
        guard kind == .directory else { return (nodes, nil) }
        var stack = [""]
        while let rel = stack.popLast() {
            if job.isCancelled { return (nodes, nil) }
            let dir = rel.isEmpty ? path : path + "/" + rel
            let l = DirectoryReader.read(dir)
            if l.error != 0 { return (nodes, "the folder \"\(Paths.name(dir))\" could not be read (\(l.errorText))") }
            for e in l.entries where !skipInCopy(e.name) && e.kind != .other {
                let r = rel.isEmpty ? e.name : rel + "/" + e.name
                nodes.append(ScanNode(rel: r, kind: e.kind, size: e.size, modified: e.modified, created: e.created))
                if e.kind == .directory { stack.append(r) }
            }
        }
        return (nodes, nil)
    }

    private static func files(_ nodes: [ScanNode]) -> (count: Int, bytes: Int64) {
        let f = nodes.filter { $0.kind != .directory }
        return (f.count, f.reduce(Int64(0)) { $0 + $1.size })
    }

    private static func copyItems(_ items: [TransferItem], _ job: TransferJob, _ reserved: inout Set<String>) {
        // 1. Scan first: totals for the progress bar, and the exact list of what is copied.
        var scans: [String: [ScanNode]] = [:]
        var scanErrors: [String: String] = [:]
        for it in items {
            if job.isCancelled { return }
            job.update { $0.current = Paths.name(it.source) }
            let r = scan(it.source, job)
            if let e = r.error { scanErrors[it.source] = e; continue }
            scans[it.source] = r.nodes
            let f = files(r.nodes)
            job.update { $0.totalFiles += f.count; $0.totalBytes += f.bytes }
        }
        job.testHookAfterScan?(job)
        if job.isCancelled { return }
        job.update { $0.state = .running }

        // 2. Copy, a set at a time.
        var metaWarned = false
        var k = 0
        for g in grouped(items) {
            if job.isCancelled { break }
            if let bad = g.first(where: { scanErrors[$0.source] != nil }) {
                let text = "\(Paths.name(bad.source)): \(scanErrors[bad.source]!)" + (g.count > 1 ? " (its set was not \(job.kind == .copy ? "copied" : "moved"))" : "")
                job.update { $0.failures.append(text) }
                Log.error("E-OPS-6 \(job.kind.rawValue) \(job.id): \(bad.source): \(scanErrors[bad.source]!)")
                for it in g { if let n = scans[it.source] { let f = files(n); job.update { $0.totalFiles -= f.count; $0.totalBytes -= f.bytes } } }
                continue
            }
            guard let names = targetNames(g, job, &reserved) else {
                for it in g { let f = files(scans[it.source]!); job.update { $0.skipped += 1; $0.totalFiles -= f.count; $0.totalBytes -= f.bytes } }
                Log.info("\(job.kind.rawValue) \(job.id): skipped \(g.count) item(s), name taken: \(Paths.name(g[0].source))")
                continue
            }
            var groupOK = true
            var finals: [String] = []
            for (it, name) in zip(g, names) {
                if job.isCancelled { groupOK = false; break }
                let final = Paths.join(job.destination, name)
                let temp = Paths.join(job.destination, Transfers.partialPrefix + job.id + "-\(k)")
                k += 1
                AppFiles.notePartial(temp, active: true)
                var problem = copyTree(it, scans[it.source]!, to: temp, job, &metaWarned)
                if problem == nil && !job.isCancelled {
                    let e = Platform.renameExclusive(temp, final)
                    if e != 0 { problem = e == EEXIST ? "\"\(name)\" appeared in the destination meanwhile" : why(e) }
                }
                if problem != nil || job.isCancelled { _ = removePartial(temp) }
                AppFiles.notePartial(temp, active: false)
                if job.isCancelled { groupOK = false; break }
                if let p = problem {
                    groupOK = false
                    job.update { $0.failures.append("\(Paths.name(it.source)): \(p)") }
                    Log.error("E-OPS-6 \(job.kind.rawValue) \(job.id): \(it.source): \(p)")
                    continue
                }
                job.created.append(final)
                finals.append(final)
            }
            // A move removes the originals only when the whole set arrived and was verified.
            if job.kind == .move && groupOK && !job.isCancelled {
                var left = 0
                for it in g { left += removeOriginals(it, scans[it.source]!) }
                job.removedOriginals += g.count
                if left > 0 {
                    let note = "\(left) item(s) stayed in the original folder because they changed during the move."
                    job.update { $0.notes.append(note) }
                    Log.warn("W-OPS-4 move \(job.id): \(left) original(s) kept, changed during the move: \(g[0].source)")
                }
            }
            if !finals.isEmpty { Log.info("\(job.kind.rawValue) \(job.id): " + finals.map { Paths.name($0) }.joined(separator: ", ")) }
        }
    }

    /// Copy one scanned item to `temp`. Returns nil or the reason it failed.
    private static func copyTree(_ item: TransferItem, _ nodes: [ScanNode], to temp: String, _ job: TransferJob, _ metaWarned: inout Bool) -> String? {
        let src = item.source
        for n in nodes {
            if job.isCancelled { return "stopped" }
            let from = n.rel.isEmpty ? src : src + "/" + n.rel
            let to = n.rel.isEmpty ? temp : temp + "/" + n.rel
            let shown = n.rel.isEmpty ? Paths.name(src) : n.rel
            switch n.kind {
            case .directory:
                let e = Platform.makeFolder(to)
                if e != 0 { return "the folder \"\(shown)\" could not be created (\(why(e)))" }
            case .symlink:
                let e = Platform.copySymlink(from, to)
                if e != 0 { return "the link \"\(shown)\" could not be copied (\(why(e)))" }
                job.update { $0.doneFiles += 1 }
            case .file:
                if let p = copyFile(from, to, n, sameDevice: !item.crossDevice, job, &metaWarned) {
                    return n.rel.isEmpty ? p : "\"\(shown)\": \(p)"
                }
            case .other:
                continue
            }
        }
        // Folder dates last: adding the contents changed them.
        for n in nodes.reversed() where n.kind == .directory {
            let from = n.rel.isEmpty ? src : src + "/" + n.rel
            let to = n.rel.isEmpty ? temp : temp + "/" + n.rel
            if Platform.copyMetadata(from, to) != 0 && !metaWarned {
                metaWarned = true
                Log.warn("W-OPS-5 \(job.kind.rawValue) \(job.id): tags/permissions not copied for some items (first: \(from))")
            }
            _ = Platform.setDates(to, created: n.created, modified: n.modified)
        }
        return nil
    }

    private static func copyFile(_ from: String, _ to: String, _ n: ScanNode, sameDevice: Bool, _ job: TransferJob, _ metaWarned: inout Bool) -> String? {
        job.update { $0.current = Paths.name(from) }
        var cloned = false
        if sameDevice {
            if Platform.cloneFile(from, to) == 0 {
                cloned = true
                job.update { $0.doneBytes += n.size }
            } else {
                var s = stat()
                if lstat(to, &s) == 0 { _ = Platform.removeFile(to) }     // our own half clone, if any
            }
        }
        var copied: Int64 = 0
        if !cloned {
            let e = Platform.copyData(from, to) { bytes in
                copied += bytes
                job.update { $0.doneBytes += bytes }
                return !job.isCancelled
            }
            if e != 0 {
                job.update { $0.doneBytes -= copied }
                return e == ECANCELED ? "stopped" : "could not be copied (\(why(e)))"
            }
        }
        // Verify: the copy has the size the source had, and the source did not change meanwhile.
        var d = stat(), s = stat()
        let haveCopy = lstat(to, &d) == 0
        let sourceSame = lstat(from, &s) == 0 && Int64(s.st_size) == n.size
            && abs(DirectoryReader.seconds(s.st_mtimespec) - n.modified) < 1.0
        if !haveCopy || Int64(d.st_size) != n.size || !sourceSame {
            if haveCopy { _ = Platform.removeFile(to) }
            job.update { $0.doneBytes -= cloned ? n.size : copied }
            if !sourceSame { return "it changed while it was being copied" }
            return haveCopy ? "the copy came out at the wrong size (\(d.st_size) of \(n.size) bytes)" : "the copy is missing after writing"
        }
        if !cloned && Platform.copyMetadata(from, to) != 0 && !metaWarned {
            metaWarned = true
            Log.warn("W-OPS-5 \(job.kind.rawValue) \(job.id): tags/permissions not copied for some items (first: \(from))")
        }
        _ = Platform.setDates(to, created: n.created, modified: n.modified)
        job.update { $0.doneFiles += 1 }
        return nil
    }

    /// Remove one of PhotoLab's own hidden partial copies (stopped, failed or interrupted).
    @discardableResult
    private static func removePartial(_ path: String) -> Bool {
        guard Paths.name(path).hasPrefix(Transfers.partialPrefix) else { return false }
        do { try FileManager.default.removeItem(atPath: path); return true } catch {
            Log.error("E-OPS-7 partial copy not removed: \(path): \((error as NSError).localizedDescription)")
            return false
        }
    }

    /// Cross-volume move, after the copy is in place and verified: remove exactly the originals
    /// that were copied, children first, and only if unchanged since the scan. Folders go only
    /// when empty. Returns how many originals were kept.
    private static func removeOriginals(_ item: TransferItem, _ nodes: [ScanNode]) -> Int {
        var kept = 0
        for n in nodes.reversed() {
            let p = n.rel.isEmpty ? item.source : item.source + "/" + n.rel
            var s = stat()
            guard lstat(p, &s) == 0 else { continue }
            switch n.kind {
            case .directory:
                _ = Platform.removeEmptyFolder(p)
            case .file:
                if Int64(s.st_size) != n.size || abs(DirectoryReader.seconds(s.st_mtimespec) - n.modified) >= 1.0 { kept += 1; continue }
                if Platform.removeFile(p) != 0 { kept += 1 }
            default:
                if Platform.removeFile(p) != 0 { kept += 1 }
            }
        }
        var s = stat()
        if kept == 0 && lstat(item.source, &s) == 0 { kept = 1 }   // something new appeared inside
        return kept
    }

    private static func finish(_ job: TransferJob, _ t0: Date) {
        let state: TransferJob.State = job.isCancelled ? .stopped : (job.progress.failures.isEmpty ? .done : .failed)
        job.update { $0.state = state; $0.finished = Date(); $0.current = "" }
        let p = job.progress
        let secs = Date().timeIntervalSince(t0)
        let mb = Double(p.doneBytes) / 1_000_000
        Log.info(String(format: "%@ %@ %@: %ld file(s), %.1f MB in %.1f s (%.1f MB/s), %ld skipped, %ld failed",
                        job.kind.rawValue, job.id, state.rawValue, p.doneFiles, mb, secs, secs > 0 ? mb / secs : 0,
                        p.skipped, p.failures.count))
        if state == .stopped {
            Log.warn("W-OPS-3 \(job.kind.rawValue) \(job.id) stopped by the user after \(p.doneFiles) file(s); the unfinished item was removed")
        }
        Stats.noteTransfer(files: p.doneFiles, bytes: p.doneBytes, seconds: secs,
                           network: Volumes.isNetwork(job.destination), failed: p.failures.count)
    }

    /// At launch: hidden partial copies left by a stop in the middle of a copy are removed.
    /// The originals were never touched (a move removes them only after the copy is complete).
    static func recoverTransfers(quiet: Bool = false) -> String? {
        let temps = AppFiles.readTransferJournal()
        if temps.isEmpty { return nil }
        var removed = 0
        for t in temps {
            var s = stat()
            if lstat(t, &s) == 0 && removePartial(t) { removed += 1 }
            AppFiles.notePartial(t, active: false)
        }
        if quiet {
            Log.info("self-test: transfer recovery removed \(removed) partial copy(ies)")
        } else {
            Log.warn("W-OPS-6 an interrupted copy was found at launch; \(removed) unfinished item(s) removed")
        }
        return removed > 0 && !quiet ? "PhotoLab was stopped in the middle of a copy. \(removed) unfinished item(s) were removed, so no half-copied files are left. The originals were not touched: copy them again to finish." : nil
    }

    // MARK: Finder tags

    /// Add or remove one colour tag on items (the caller expands sets). Other tags stay. Returns
    /// each changed item's tags before and after (for undo and the display) and the failures.
    static func changeTag(_ paths: [String], color: Int, add: Bool) -> (changed: [(path: String, before: [FinderTag], after: [FinderTag])], failed: [String]) {
        var changed: [(String, [FinderTag], [FinderTag])] = []
        var failed: [String] = []
        for p in paths {
            guard let before = FinderTags.read(p) else { failed.append(Paths.name(p)); continue }
            var after = before.filter { $0.color != color }
            if add { after.append(FinderTags.colorTag(color)) }
            if after == before { continue }
            if setTags(p, after) { changed.append((p, before, after)) } else { failed.append(Paths.name(p)) }
        }
        if !changed.isEmpty { Log.info("tags: \(add ? "added" : "removed") \(FinderTags.colorNames[color]) on \(changed.count) item(s)") }
        return (changed, failed)
    }

    /// Finder's tag click: remove the colour when every item has it, else add it to all - decided
    /// from the items' tags as they are on disk now, not from what the menu showed.
    static func toggleTag(_ paths: [String], color: Int) -> (changed: [(path: String, before: [FinderTag], after: [FinderTag])], failed: [String], added: Bool) {
        let all = paths.allSatisfy { p in FinderTags.read(p)?.contains { $0.color == color } ?? false }
        let r = changeTag(paths, color: color, add: !all)
        return (r.changed, r.failed, !all)
    }

    /// Write an item's whole tag list (undo uses this).
    @discardableResult
    static func setTags(_ path: String, _ tags: [FinderTag]) -> Bool {
        let e = Platform.setAttribute(path, FinderTags.xattrName, tags.isEmpty ? Data() : FinderTags.encode(tags))
        if e != 0 { Log.error("E-TAG-1 tags not written: \(path): \(String(cString: strerror(e)))") }
        return e == 0
    }
}
