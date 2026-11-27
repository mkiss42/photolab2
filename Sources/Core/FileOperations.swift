// FileOperations.swift
// THE ONLY CODE IN FIND THAT CHANGES USER FILES.
//
// Safety rules (see the architecture document, "File safety guarantees"):
//  - Nothing is ever permanently deleted. Removal = move to Trash.
//  - Nothing is ever overwritten. Renames and moves use an exclusive rename that fails if the target exists.
//  - Copies go to a hidden temporary name first, are verified, then renamed into place exclusively.
//  - Cross-volume moves: copy, verify every file, then move the originals to the Trash.
//  - Every change returns an UndoRecord so it can be reversed.
//
// build.sh refuses to build if any other source file uses a file-changing API.

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

enum FileOpError: Error, CustomStringConvertible {
    case targetExists(String)
    case notFound(String)
    case invalidName(String, String)
    case trashUnavailable(String, String)
    case system(String, Int32, String)
    case verifyFailed(String, String)
    case refused(String)
    case cancelled

    var description: String {
        switch self {
        case .targetExists(let p): return "An item named \"\(Paths.lastComponent(p))\" already exists in that location. Nothing was replaced."
        case .notFound(let p): return "\"\(p)\" no longer exists."
        case .invalidName(let n, let why): return "\"\(n)\" can't be used as a name: \(why)."
        case .trashUnavailable(let p, let why): return "\"\(Paths.lastComponent(p))\" could not be moved to the Trash (\(why)). It was left untouched."
        case .system(let op, let code, let p): return "\(op) failed for \"\(p)\": \(Sys.errorText(code)) (code \(code))."
        case .verifyFailed(let p, let why): return "Verification failed for \"\(p)\": \(why). The original was kept."
        case .refused(let why): return why
        case .cancelled: return "Cancelled."
        }
    }

    /// Short machine code for logs (E-OP-n).
    var code: String {
        switch self {
        case .targetExists: return "E-OP-EXISTS"
        case .notFound: return "E-OP-NOTFOUND"
        case .invalidName: return "E-OP-NAME"
        case .trashUnavailable: return "E-OP-NOTRASH"
        case .system: return "E-OP-SYS"
        case .verifyFailed: return "E-OP-VERIFY"
        case .refused: return "E-OP-REFUSED"
        case .cancelled: return "E-OP-CANCEL"
        }
    }
}

/// The OS-specific primitives FileOperations needs. macOS: DarwinPlatform. Tests: LinuxTestPlatform.
protocol FilePlatform: class {
    /// Free space where `path` is, if known (0.17.3: checked before a copy starts).
    func freeBytes(_ path: String) -> Int64?
    /// Rename within one volume. MUST fail (EEXIST) instead of replacing an existing target.
    func exclusiveRename(_ src: String, _ dst: String) throws
    /// Move an item to the Trash. Returns its new path inside the Trash.
    func moveToTrash(_ path: String) throws -> String
    /// Copy one item (recursively for folders) to a path that does not exist yet. Must not overwrite.
    /// 0.17.1: `onFile(source file, its copy, size)` is called before each file is copied; returning
    /// false stops the copy (nothing more is copied) and the call throws FileOpError.cancelled.
    func copyItem(_ src: String, _ dst: String, onFile: ((String, String, Int64) -> Bool)?) throws
    /// 0.18.5: give `to` (a new version Find just wrote) the Finder tags, labels, comments and other
    /// extended attributes, permissions and creation date of `from`. Never the dates of change.
    func carryAttributes(from: String, to: String)
    /// 0.18.8: write `data` at each offset of an existing file - never moving or shortening it - and make
    /// sure it is on the disk. Only the in-place metadata change uses this (within the old metadata
    /// blocks, past the old end, or a directory entry / pointer).
    func patchFile(_ path: String, writes: [(offset: Int64, data: Data)]) throws
    /// 0.18.8: shorten a file back to `length` (only when an in-place change is put back).
    func truncateFile(_ path: String, to length: Int64) throws
    /// Make an alias file at `path` (which must not exist) pointing to `target`.
    func makeAlias(target: String, at path: String) throws
    /// Permanent removal of Find's own temporary: the previous version of a file whose metadata was just
    /// rewritten, after the new version was verified (same picture data, the intended metadata) and put
    /// in its place. Must refuse any name not starting with ".find-rename-" (Find's own temporary name).
    func removeReplacedOriginal(_ path: String) throws
    /// 0.18.14: a verified new version (".find-partial-...") takes the place of a sidecar / JPEG / TIFF in one
    /// rename that replaces it (either the old or the new file is there at every moment). Never a RAW (its
    /// previous version goes to the Trash). Throws if the volume can't do it: the two-rename way is used.
    func replaceWithVerified(_ temp: String, _ target: String) throws
    /// 0.18.4: Finder's "Delete Immediately" - ONLY after you confirmed it in a dialog that names the items
    /// (FileOperations.deleteImmediately checks the paths first). Folders with everything in them.
    func deletePermanently(_ path: String) throws
    /// Finder tag names on an item (colour labels are tags such as "Red").
    func tagNames(_ path: String) -> [String]
    /// Replace an item's Finder tags. Changes metadata only, never the file's contents.
    func setTagNames(_ path: String, _ names: [String]) throws
}

extension FilePlatform {
    func replaceWithVerified(_ temp: String, _ target: String) throws { throw FileOpError.refused("not supported here") }
    /// The checks every replaceWithVerified makes before renaming.
    func replaceAllowed(_ temp: String, _ target: String) -> Bool {
        guard Paths.parent(temp) == Paths.parent(target), Paths.lastComponent(temp).hasPrefix(".find-partial-"),
            !PhotoFormats.isRaw(Paths.lastComponent(target)) else { return false }
        var e: Int32 = 0
        guard let a = Sys.lstatInfo(temp, &e), a.isRegular, let b = Sys.lstatInfo(target, &e), b.isRegular else { return false }
        return true
    }
    func copyItem(_ src: String, _ dst: String) throws { try copyItem(src, dst, onFile: nil) }
    func freeBytes(_ path: String) -> Int64? { return nil }
    func carryAttributes(from: String, to: String) {}
}

/// Finder's seven colour labels, in Finder's menu order, with Finder's colour numbers.
enum ColorLabel {
    static let names = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
    static let finderNumbers = [6, 7, 5, 2, 4, 3, 1]

    /// Colour number (1...7) -> index in `names`, or nil.
    static func index(ofFinderNumber n: Int) -> Int? {
        return finderNumbers.index(of: n)
    }
}

/// A record of a completed change, enough to reverse it.
enum UndoRecord {
    case renamed(from: String, to: String)
    /// Batch rename: every (from, to) pair; undo renames them all back as one batch.
    case renamedMany([(from: String, to: String)])
    case createdFolder(path: String)
    /// original path -> path inside Trash
    case trashed([(original: String, trashed: String)])
    /// same-volume move
    case moved([(from: String, to: String)])
    /// cross-volume move: copy now at `copy`, original in Trash at `trashedOriginal`
    case movedAcrossVolumes([(original: String, copy: String, trashedOriginal: String)])
    case copied([String])
    /// New items made by Find (archive, alias): undo sends them to the Trash.
    case createdItems([String], label: String)
    /// Tags before a colour-label change: undo puts them back.
    case tagsChanged([(path: String, names: [String])])
    /// Ratings / metadata before a change: undo writes the old values back (same safe way).
    case metadata([(image: String, change: MetaChange)])
    /// 0.18.2: several changes made as one (Find and Replace in names AND metadata): undone last
    /// first, as one Undo.
    case group([UndoRecord], label: String)

    var actionName: String {
        switch self {
        case .renamed: return "Rename"
        case .renamedMany(let pairs): return "Rename \(pairs.count) Items"
        case .createdFolder: return "New Folder"
        case .trashed: return "Move to Trash"
        case .moved, .movedAcrossVolumes: return "Move"
        case .copied: return "Copy"
        case .createdItems(_, let label): return label
        case .tagsChanged: return "Color Label"
        case .metadata: return "Metadata"
        case .group(_, let label): return label
        }
    }
}

enum ConflictChoice {
    case keepBoth
    case skip
    case replace
    case cancel
}

/// Outcome of a multi-item operation: what happened to each item.
struct BatchReport {
    var done: [(from: String, to: String)] = []
    var skipped: [String] = []
    var failed: [(path: String, error: FileOpError)] = []
    var notes: [String] = []
    var cancelled = false
    var undo: UndoRecord? = nil

    var summaryLines: [String] {
        var out: [String] = []
        out.append("Completed: \(done.count). Skipped: \(skipped.count). Failed: \(failed.count).\(cancelled ? " Stopped early (cancelled)." : "")")
        for f in failed { out.append("FAILED \(f.error.code): \(f.error.description)") }
        for s in skipped { out.append("SKIPPED: \(s)") }
        for n in notes { out.append("NOTE: \(n)") }
        return out
    }
}

final class FileOperations {
    let platform: FilePlatform
    /// Called with a one-line description of every change and failure (for the log).
    var logger: ((String) -> Void)?
    /// Notes about temporary items in user folders while an operation runs (recovery after a crash).
    var journal: OperationJournal?

    /// ExifTool, for ratings and metadata (set by the app; nil = not available).
    var metadataTool: MetadataTool?

    private func noteBegin(_ lines: [String]) -> String? { return journal?.begin(lines) }
    private func noteEnd(_ token: String?) { if let t = token { journal?.end(t) } }

    init(platform: FilePlatform) {
        self.platform = platform
    }

    private func log(_ s: String) { logger?(s) }

    /// Every path this instance has put in the Trash (used by the self-check to clean up after itself).
    /// Operations may run on several threads, so access is locked.
    private var trashHistoryStore: [String] = []
    private let historyLock = NSLock()

    var trashHistory: [String] {
        historyLock.lock()
        defer { historyLock.unlock() }
        return trashHistoryStore
    }

    private func toTrash(_ path: String) throws -> String {
        let t = try platform.moveToTrash(path)
        historyLock.lock()
        trashHistoryStore.append(t)
        if trashHistoryStore.count > 500 { trashHistoryStore.removeFirst(100) }
        historyLock.unlock()
        return t
    }

    // MARK: - Names

    /// nil if the name is usable, otherwise the reason.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "the name is empty" }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "the name is only spaces" }
        if name == "." || name == ".." { return "\".\" and \"..\" are reserved" }
        if name.contains("/") { return "it contains \"/\"" }
        if name.contains(":") { return "it contains \":\"" }
        if name.unicodeScalars.contains(where: { $0.value == 0 }) { return "it contains a null character" }
        if name.utf8.count > 255 { return "it is longer than 255 bytes" }
        return nil
    }

    /// "name 2.ext", "name 3.ext", ... first one not present in `dir`.
    static func uniqueName(for name: String, in dir: String) -> String {
        if !Sys.exists(Paths.join(dir, name)) { return name }
        let ext = Paths.fileExtension(name)
        // keep the original extension case
        let base: String
        let extPart: String
        if ext.isEmpty {
            base = name
            extPart = ""
        } else {
            base = String(name.dropLast(ext.count + 1))
            extPart = String(name.suffix(ext.count + 1))
        }
        var n = 2
        while true {
            let candidate = "\(base) \(n)\(extPart)"
            if !Sys.exists(Paths.join(dir, candidate)) { return candidate }
            n += 1
        }
    }

    // MARK: - Rename

    /// Rename an item in place. Returns the new path.
    func rename(_ path: String, to newName: String) throws -> (String, UndoRecord) {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        if let why = FileOperations.nameProblem(newName) { throw FileOpError.invalidName(newName, why) }
        var err: Int32 = 0
        guard let srcInfo = Sys.lstatInfo(path, &err) else {
            throw err == ENOENT ? FileOpError.notFound(path) : FileOpError.system("Rename", err, path)
        }
        let dir = Paths.parent(path)
        let newPath = Paths.join(dir, newName)
        if newPath == path { return (path, .renamed(from: path, to: path)) }
        // Case-only change on a case-insensitive volume: the "existing" target is the same file.
        var e2: Int32 = 0
        if let dstInfo = Sys.lstatInfo(newPath, &e2) {
            if dstInfo.device == srcInfo.device && dstInfo.inode == srcInfo.inode {
                var rErr: Int32 = 0
                if !FileOperations.plainRename(path, newPath, &rErr) {
                    throw FileOpError.system("Rename", rErr, path)
                }
                log("RENAME (case change) \(path) -> \(newPath)")
                return (newPath, .renamed(from: path, to: newPath))
            }
            throw FileOpError.targetExists(newPath)
        }
        try platform.exclusiveRename(path, newPath)
        log("RENAME \(path) -> \(newPath)")
        return (newPath, .renamed(from: path, to: newPath))
    }

    // MARK: - Batch rename

    /// Rename many items at once (each stays in its folder). Two steps, both with the no-overwrite
    /// rename: every item first gets a unique temporary name, then its new name. So swaps (A <-> B) and
    /// case-only changes are safe. If any step fails, everything done so far is put back exactly as it
    /// was and the error is thrown: all or nothing.
    /// 0.18: a batch that may hold folders AND items inside them (Find & Replace over subfolders).
    /// Renamed level by level, deepest first, so every path is still right when its turn comes; each level
    /// is a checked renameBatch. If a level fails, the levels already done are put back. The pairs give
    /// every item's original path and its FINAL path (with its renamed folders), so Undo (also deepest
    /// first) finds everything. A batch without nesting is exactly one renameBatch.
    func renameNested(_ items: [(path: String, newName: String)]) throws -> ([(from: String, to: String)], UndoRecord) {
        let work = items.filter { Paths.lastComponent($0.path) != $0.newName }
        if work.isEmpty { return ([], .renamedMany([])) }
        func depth(_ p: String) -> Int { return p.split(separator: "/").count }
        let levels = Set(work.map { depth($0.path) }).sorted(by: >)
        var doneLevels: [[(from: String, to: String)]] = []
        for lv in levels {
            let group = work.filter { depth($0.path) == lv }
            do {
                let (pairs, _) = try renameBatch(group)
                doneLevels.append(pairs)
            } catch {
                for pairs in doneLevels.reversed() {
                    _ = try? renameBatch(pairs.map { (path: $0.to, newName: Paths.lastComponent($0.from)) })
                }
                if !doneLevels.isEmpty { log("NESTED RENAME failed at depth \(lv); the deeper levels were put back") }
                throw error
            }
        }
        // Final paths: apply the renamed folders to every new path, deepest folder first, then its parents.
        var folderMoves: [(from: String, to: String)] = []
        for pairs in doneLevels { folderMoves += pairs }
        func final(_ p: String) -> String {
            var out = p
            for m in folderMoves where out.hasPrefix(m.from + "/") {
                out = m.to + String(out.dropFirst(m.from.count))
            }
            return out
        }
        var all: [(from: String, to: String)] = []
        for pairs in doneLevels {
            for pr in pairs { all.append((from: pr.from, to: final(pr.to))) }
        }
        return (all, .renamedMany(all))
    }

    func renameBatch(_ items: [(path: String, newName: String)]) throws -> ([(from: String, to: String)], UndoRecord) {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        let work = items.filter { Paths.lastComponent($0.path) != $0.newName }
        if work.isEmpty { return ([], .renamedMany([])) }
        for it in work {
            if let why = FileOperations.nameProblem(it.newName) { throw FileOpError.invalidName(it.newName, why) }
            var e: Int32 = 0
            if Sys.lstatInfo(it.path, &e) == nil {
                throw e == ENOENT ? FileOpError.notFound(it.path) : FileOpError.system("Rename", e, it.path)
            }
        }
        // New names must not collide with each other or with items that aren't being renamed.
        var finalKeys = Set<String>()
        let leaving = Set(work.map { $0.path.lowercased() })
        for it in work {
            let target = Paths.join(Paths.parent(it.path), it.newName)
            let key = target.lowercased()
            if finalKeys.contains(key) { throw FileOpError.refused("Two items would both be named \"\(it.newName)\". Nothing was renamed.") }
            finalKeys.insert(key)
            if !leaving.contains(key) && Sys.exists(target) { throw FileOpError.targetExists(target) }
        }
        let token = UUID().uuidString.prefix(8)
        var temps: [String] = []
        let tempNames = work.enumerated().map { Paths.join(Paths.parent($0.element.path), ".find-rename-\(token)-\($0.offset)") }
        // Note every temporary name first: if Find is interrupted, the next start renames them back.
        let note = noteBegin(work.enumerated().map {
            "RENAME \(tempNames[$0.offset])\t\($0.element.path)\t\(Paths.join(Paths.parent($0.element.path), $0.element.newName))"
        })
        defer { noteEnd(note) }
        // Step 1: originals -> temporary names.
        for (i, it) in work.enumerated() {
            let t = tempNames[i]
            do {
                try platform.exclusiveRename(it.path, t)
                temps.append(t)
            } catch {
                for k in stride(from: temps.count - 1, through: 0, by: -1) { try? platform.exclusiveRename(temps[k], work[k].path) }
                log("BATCH RENAME failed at step 1 (\(it.path)); all put back")
                throw error
            }
        }
        // Step 2: temporary names -> new names.
        var finals: [String] = []
        for (i, it) in work.enumerated() {
            let f = Paths.join(Paths.parent(it.path), it.newName)
            do {
                try platform.exclusiveRename(temps[i], f)
                finals.append(f)
            } catch {
                // Back out: new names -> temporary names, then temporary names -> original names.
                for k in stride(from: finals.count - 1, through: 0, by: -1) { try? platform.exclusiveRename(finals[k], temps[k]) }
                for k in stride(from: temps.count - 1, through: 0, by: -1) { try? platform.exclusiveRename(temps[k], work[k].path) }
                log("BATCH RENAME failed at step 2 (\(it.newName)); all put back")
                throw error
            }
        }
        var pairs: [(from: String, to: String)] = []
        for (i, it) in work.enumerated() {
            pairs.append((it.path, finals[i]))
            log("RENAME \(it.path) -> \(finals[i])")
        }
        log("BATCH RENAME \(pairs.count) items done")
        return (pairs, .renamedMany(pairs))
    }

    // MARK: - New folder

    func createFolder(in dir: String, name: String = "untitled folder") throws -> (String, UndoRecord) {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        if let why = FileOperations.nameProblem(name) { throw FileOpError.invalidName(name, why) }
        var attemptName = name
        for _ in 0..<1000 {
            let p = Paths.join(dir, attemptName)
            var err: Int32 = 0
            if FileOperations.makeDirectory(p, &err) {
                log("NEWFOLDER \(p)")
                return (p, .createdFolder(path: p))
            }
            if err != EEXIST { throw FileOpError.system("New Folder", err, p) }
            attemptName = FileOperations.uniqueName(for: name, in: dir)
        }
        throw FileOpError.refused("Could not find a free folder name in \(dir).")
    }

    // MARK: - Trash

    func trash(_ paths: [String]) -> BatchReport {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        var report = BatchReport()
        var records: [(original: String, trashed: String)] = []
        for p in paths {
            if !Sys.exists(p) {
                report.failed.append((p, .notFound(p)))
                continue
            }
            do {
                let t = try toTrash(p)
                report.done.append((p, t))
                if t.isEmpty {
                    report.notes.append("\"\(Paths.lastComponent(p))\" is in the Trash, but macOS did not report where, so this can't be undone from Find. Use Put Back in the Trash.")
                } else {
                    records.append((p, t))
                }
                log("TRASH \(p) -> \(t.isEmpty ? "(Trash)" : t)")
            } catch let e as FileOpError {
                report.failed.append((p, e))
                log("TRASH FAILED \(p): \(e.description)")
            } catch {
                let fe = FileOpError.trashUnavailable(p, "\(error)")
                report.failed.append((p, fe))
                log("TRASH FAILED \(p): \(error)")
            }
        }
        if !records.isEmpty { report.undo = .trashed(records) }
        return report
    }

    // MARK: - Delete Immediately (0.18.4)

    /// Why a path may never be deleted outright (nil = allowed): the top of the disk, a disk or share
    /// itself, your home folder or a folder it sits in, and the main folders inside it.
    static func deleteRefusal(_ p: String) -> String? {
        let parts = p.split(separator: "/").map(String.init)
        let home = NSHomeDirectory()
        if p == "/" || parts.isEmpty { return "the top of the disk" }
        if parts.count < 2 || (parts[0] == "Volumes" && parts.count < 3) { return "a whole disk or shared volume" }
        if p == home || home.hasPrefix(p + "/") { return "your home folder" }
        if Paths.parent(p) == home { return "one of the main folders of your home folder" }
        if ["System", "Library", "Applications", "Users", "bin", "sbin", "usr", "private", "etc", "var"].contains(parts[0]) && parts.count < 3 {
            return "a system folder"
        }
        return nil
    }

    /// Finder's "Delete Immediately": for items that can't go to the Trash (most shared volumes have
    /// none). Called ONLY after you confirmed it in a dialog that lists the items. No Undo.
    func deleteImmediately(_ paths: [String]) -> BatchReport {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        var report = BatchReport()
        for p in paths {
            if let why = FileOperations.deleteRefusal(p) {
                report.failed.append((p, .refused("E-GUARD-3 \"\(Paths.lastComponent(p))\" was not deleted: it is \(why).")))
                log("DELETE REFUSED \(p): \(why)")
                continue
            }
            var e: Int32 = 0
            guard Sys.lstatInfo(p, &e) != nil else {
                report.failed.append((p, .notFound(p)))
                continue
            }
            do {
                try platform.deletePermanently(p)
                report.done.append((p, ""))
                log("DELETE IMMEDIATELY \(p)")
            } catch let fe as FileOpError {
                report.failed.append((p, fe))
                log("DELETE FAILED \(p): \(fe.description)")
            } catch {
                report.failed.append((p, .system("Delete", EIO, p)))
                log("DELETE FAILED \(p): \(error)")
            }
        }
        return report
    }

    // MARK: - Move and copy

    /// Plan a move/copy: which items would clash with existing names in `destDir`.
    static func conflicts(_ sources: [String], into destDir: String) -> [String] {
        return sources.filter { Sys.exists(Paths.join(destDir, Paths.lastComponent($0))) }
    }

    /// Move items into `destDir`. `choose` is asked for each name clash (on the calling thread).
    /// `forceCrossVolume` is only for tests.
    func move(_ sources: [String], into destDir: String,
              choose: (String) -> ConflictChoice,
              isCancelled: () -> Bool = { return false },
              forceCrossVolume: Bool = false, progress: TransferProgress? = nil) -> BatchReport {
        return transfer(sources, into: destDir, isMove: true, choose: choose,
                        isCancelled: isCancelled, forceCrossVolume: forceCrossVolume, progress: progress)
    }

    func copy(_ sources: [String], into destDir: String,
              choose: (String) -> ConflictChoice,
              isCancelled: () -> Bool = { return false }, progress: TransferProgress? = nil) -> BatchReport {
        return transfer(sources, into: destDir, isMove: false, choose: choose,
                        isCancelled: isCancelled, forceCrossVolume: false, progress: progress)
    }

    /// `progress` (0.17): told which item is in progress, where its unfinished copy is and when it is
    /// finished, for the Copies window. It only observes.
    private func transfer(_ sources: [String], into destDir: String, isMove: Bool,
                          choose: (String) -> ConflictChoice,
                          isCancelled: () -> Bool,
                          forceCrossVolume: Bool, progress: TransferProgress? = nil) -> BatchReport {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        var report = BatchReport()
        var moved: [(from: String, to: String)] = []
        var crossMoved: [(original: String, copy: String, trashedOriginal: String)] = []
        var copied: [String] = []
        var replacedTrash: [(original: String, trashed: String)] = []

        var dErr: Int32 = 0
        guard let destInfo = Sys.statInfo(destDir, &dErr), destInfo.isDirectory else {
            report.failed.append((destDir, dErr == 0 ? .refused("The destination is not a folder.") : .system("Open destination", dErr, destDir)))
            return report
        }
        let destReal = Sys.realPath(destDir) ?? destDir

        for src in sources {
            if isCancelled() {
                report.cancelled = true
                progress?.note("Stopped before \(Paths.lastComponent(src))")
                break
            }
            progress?.begin(src)
            let doneBefore = report.done.count
            defer { progress?.finish(src, ok: report.done.count > doneBefore) }
            var sErr: Int32 = 0
            guard let srcInfo = Sys.lstatInfo(src, &sErr) else {
                report.failed.append((src, sErr == ENOENT ? .notFound(src) : .system("Read", sErr, src)))
                continue
            }
            // Refuse moving/copying a folder into itself or its own subfolder.
            if srcInfo.isDirectory, let srcReal = Sys.realPath(src), Paths.isInside(destReal, root: srcReal) {
                report.failed.append((src, .refused("\"\(Paths.lastComponent(src))\" can't be put inside itself.")))
                continue
            }
            let name = Paths.lastComponent(src)
            var target = Paths.join(destDir, name)
            if isMove && Paths.parent(src) == destDir {
                report.skipped.append("\(name) (already in this folder)")
                continue
            }
            if Sys.exists(target) {
                switch choose(name) {
                case .cancel:
                    report.cancelled = true
                case .skip:
                    report.skipped.append(name)
                    continue
                case .keepBoth:
                    target = Paths.join(destDir, FileOperations.uniqueName(for: name, in: destDir))
                case .replace:
                    // Replace = move the existing item to the Trash first. Never overwrite.
                    do {
                        let t = try toTrash(target)
                        replacedTrash.append((target, t))
                        report.notes.append("The existing \"\(name)\" was moved to the Trash before being replaced.")
                        log("REPLACE: existing \(target) -> Trash \(t)")
                    } catch {
                        report.failed.append((src, .trashUnavailable(target, "\(error)")))
                        continue
                    }
                }
                if report.cancelled { break }
            }
            let sameVolume = !forceCrossVolume && srcInfo.device == destInfo.device
            if isMove && sameVolume {
                do {
                    try platform.exclusiveRename(src, target)
                    moved.append((src, target))
                    report.done.append((src, target))
                    log("MOVE \(src) -> \(target)")
                } catch let e as FileOpError {
                    report.failed.append((src, e))
                } catch {
                    report.failed.append((src, .refused("\(error)")))
                }
                continue
            }
            // Copy path (copy, or move across volumes): temp name, verify, exclusive rename.
            do {
                let finalPath = try copyVerified(src, to: target, progress: progress)
                if isMove {
                    // Originals go to the Trash only after the copy is verified.
                    do {
                        let t = try toTrash(src)
                        crossMoved.append((src, finalPath, t))
                        report.done.append((src, finalPath))
                        log("MOVE (across volumes) \(src) -> \(finalPath); original -> Trash \(t)")
                    } catch {
                        copied.append(finalPath)
                        report.done.append((src, finalPath))
                        report.notes.append("\"\(name)\" was copied and verified, but the original could not be moved to the Trash (\(error)). Both copies now exist.")
                        log("MOVE (across volumes) copy ok but original kept: \(src): \(error)")
                    }
                } else {
                    copied.append(finalPath)
                    report.done.append((src, finalPath))
                    log("COPY \(src) -> \(finalPath)")
                }
            } catch FileOpError.cancelled {
                report.cancelled = true
                log("COPY STOPPED by user in \(src); unfinished copy moved to the Trash")
                break
            } catch let e as FileOpError {
                report.failed.append((src, e))
                log("COPY FAILED \(src): \(e.description)")
            } catch {
                report.failed.append((src, .refused("\(error)")))
            }
        }

        if !moved.isEmpty { report.undo = .moved(moved) }
        if !crossMoved.isEmpty { report.undo = .movedAcrossVolumes(crossMoved) }
        if !copied.isEmpty && moved.isEmpty && crossMoved.isEmpty { report.undo = .copied(copied) }
        if !replacedTrash.isEmpty {
            report.notes.append("Items replaced: \(replacedTrash.count). They are in the Trash and can be put back from there.")
        }
        return report
    }

    /// Copy `src` to `target` via a hidden temporary name, verify, then rename into place without overwriting.
    /// If the final name became taken meanwhile, a "name 2" variant is used. Returns the final path.
    /// Room kept free on the destination beyond the copy itself.
    static let spaceMargin: Int64 = 64 * 1024 * 1024

    static func sizeWords(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    func copyVerified(_ src: String, to target: String, progress: TransferProgress? = nil) throws -> String {
        // 0.18: every copy goes into the network / disk I/O logs (size, time, rate, error code).
        let t0 = Date()
        var e: Int32 = 0
        let known: Int64? = progress?.plannedBytes(src) ?? Sys.lstatInfo(src, &e).flatMap { $0.isRegular ? $0.size : nil }
        func size(_ final: String?) -> Int64 {
            if let k = known { return k }
            // A folder nobody measured: measure the side on this Mac (never walk a share just for the log).
            if !IOLog.isNetworkPath(src) { return TransferProgress.measure(src).bytes }
            if let f = final, !IOLog.isNetworkPath(f) { return TransferProgress.measure(f).bytes }
            return -1
        }
        do {
            let final = try copyVerifiedInner(src, to: target, progress: progress)
            if IOLog.network != nil || IOLog.disk != nil {
                IOLog.copy("COPY", src: src, dst: final, bytes: size(final), seconds: Date().timeIntervalSince(t0))
            }
            return final
        } catch {
            if IOLog.network != nil || IOLog.disk != nil {
                let code = (error as? FileOpError)?.code ?? "E-COPY"
                var stopped = false
                if case FileOpError.cancelled? = error as? FileOpError { stopped = true }
                IOLog.copy(stopped ? "COPY-STOPPED" : "COPY-FAILED", src: src, dst: target,
                           bytes: known ?? -1, seconds: Date().timeIntervalSince(t0), error: code)
            }
            throw error
        }
    }

    private func copyVerifiedInner(_ src: String, to target: String, progress: TransferProgress? = nil) throws -> String {
        let dir = Paths.parent(target)
        // 0.17.3: not started at all when it can't fit (rather than filling the disk and failing late).
        var e: Int32 = 0
        let need: Int64? = progress?.plannedBytes(src) ?? Sys.lstatInfo(src, &e).flatMap { $0.isRegular ? $0.size : nil }
        if let n = need, let free = platform.freeBytes(dir), n + FileOperations.spaceMargin > free {
            throw FileOpError.refused("Not enough free space for \"\(Paths.lastComponent(src))\": it needs \(FileOperations.sizeWords(n)), the destination has \(FileOperations.sizeWords(max(0, free))) free. Nothing was copied.")
        }
        let temp = Paths.join(dir, ".find-partial-\(UUID().uuidString)-\(Paths.lastComponent(target))")
        progress?.partial(temp)
        let note = noteBegin(["PARTIAL " + temp])
        defer { noteEnd(note) }
        do {
            // 0.17.1: each file inside is reported (the Copies window's second bar) and Stop is checked
            // before each one - a folder stops between files, not only after the whole folder.
            try platform.copyItem(src, temp, onFile: progress == nil ? nil : { s, d, size in
                guard let pr = progress else { return true }
                if pr.stopRequested { return false }
                if size >= 0 { pr.innerFile(source: s, copy: d, size: size) }   // -1: only "go on?"
                return true
            })
        } catch {
            discardPartial(temp)
            if case FileOpError.cancelled = error { progress?.note("Stopped in \(Paths.lastComponent(src)): its unfinished copy went to the Trash") }
            if let fe = error as? FileOpError { throw fe }
            throw FileOpError.refused("Copy of \"\(Paths.lastComponent(src))\" failed: \(error)")
        }
        progress?.note("Checking \(Paths.lastComponent(src))")
        if let why = FileOperations.compareTrees(src, temp) {
            discardPartial(temp)
            throw FileOpError.verifyFailed(src, why)
        }
        var finalPath = target
        do {
            try platform.exclusiveRename(temp, finalPath)
        } catch {
            finalPath = Paths.join(dir, FileOperations.uniqueName(for: Paths.lastComponent(target), in: dir))
            do {
                try platform.exclusiveRename(temp, finalPath)
            } catch {
                discardPartial(temp)
                throw FileOpError.refused("The copy of \"\(Paths.lastComponent(src))\" could not be given its final name.")
            }
        }
        return finalPath
    }

    /// A failed partial copy is moved to the Trash (never deleted), so nothing is lost even then.
    private func discardPartial(_ temp: String) {
        guard Sys.exists(temp) else { return }
        do {
            let t = try toTrash(temp)
            log("PARTIAL COPY moved to Trash: \(t)")
        } catch {
            log("PARTIAL COPY left in place (could not trash): \(temp)")
        }
    }

    /// nil when `b` matches `a`: same relative paths, kinds, file sizes and link targets.
    static func compareTrees(_ a: String, _ b: String) -> String? {
        var ea: Int32 = 0, eb: Int32 = 0
        guard let ia = Sys.lstatInfo(a, &ea) else { return "source unreadable (\(Sys.errorText(ea)))" }
        guard let ib = Sys.lstatInfo(b, &eb) else { return "copy missing (\(Sys.errorText(eb)))" }
        if ia.isDirectory != ib.isDirectory || ia.isSymlink != ib.isSymlink || ia.isRegular != ib.isRegular {
            return "item type differs at \(a)"
        }
        if ia.isRegular && ia.size != ib.size {
            return "size differs at \(Paths.lastComponent(a)) (\(ia.size) vs \(ib.size) bytes)"
        }
        if ia.isSymlink {
            if Sys.readLink(a) != Sys.readLink(b) { return "link target differs at \(a)" }
            return nil
        }
        if ia.isDirectory {
            guard let na = try? FileManager.default.contentsOfDirectory(atPath: a) else { return "source folder unreadable: \(a)" }
            guard let nb = try? FileManager.default.contentsOfDirectory(atPath: b) else { return "copied folder unreadable: \(b)" }
            if Set(na) != Set(nb) {
                let missing = Set(na).subtracting(Set(nb))
                return "folder contents differ in \(Paths.lastComponent(a)) (\(missing.count) missing)"
            }
            for n in na {
                if let why = compareTrees(Paths.join(a, n), Paths.join(b, n)) { return why }
            }
        }
        return nil
    }

    // MARK: - Colour labels (Finder tags)

    func tagNames(_ path: String) -> [String] {
        return platform.tagNames(path)
    }

    /// Replace an item's tags (metadata only). Returns an undo record.
    func setTagNames(_ path: String, _ names: [String]) throws -> UndoRecord {
        let old = platform.tagNames(path)
        try platform.setTagNames(path, names)
        log("TAGS \(path): \(old) -> \(names)")
        return .tagsChanged([(path, old)])
    }

    /// Finder behaviour: if every item already has this colour, remove it from all; otherwise add it to all.
    /// Other tags on the items are kept.
    func toggleColorLabel(_ paths: [String], colorIndex: Int) -> BatchReport {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        var report = BatchReport()
        guard colorIndex >= 0 && colorIndex < ColorLabel.names.count else { return report }
        let name = ColorLabel.names[colorIndex]
        let current = paths.map { (p: $0, names: platform.tagNames($0)) }
        let allHave = !current.isEmpty && current.allSatisfyCompat { $0.names.contains(name) }
        var undo: [(path: String, names: [String])] = []
        for c in current {
            var newNames = c.names.filter { $0 != name }
            if !allHave { newNames.append(name) }
            if newNames == c.names { continue }
            do {
                try platform.setTagNames(c.p, newNames)
                undo.append((c.p, c.names))
                report.done.append((c.p, c.p))
                log("LABEL \(allHave ? "removed" : "added") \(name): \(c.p)")
            } catch let e as FileOpError {
                report.failed.append((c.p, e))
            } catch {
                report.failed.append((c.p, .refused("\(error)")))
            }
        }
        if !undo.isEmpty { report.undo = .tagsChanged(undo) }
        return report
    }

    // MARK: - Compress and alias

    /// Zip items that share one folder. One item: "<name>.zip" made with ditto (keeps Mac metadata, like Finder);
    /// several: "Archive.zip". Written under a temporary name, then renamed without overwriting.
    func compress(_ paths: [String]) throws -> (String, UndoRecord) {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        guard let first = paths.first else { throw FileOpError.refused("Nothing to compress.") }
        let dir = Paths.parent(first)
        for p in paths where Paths.parent(p) != dir {
            throw FileOpError.refused("Items from different folders can't be compressed together.")
        }
        let base = paths.count == 1 ? Paths.lastComponent(first) + ".zip" : "Archive.zip"
        let temp = Paths.join(dir, ".find-partial-\(UUID().uuidString).zip")
        let note = noteBegin(["PARTIAL " + temp])
        defer { noteEnd(note) }
        let task = Process()
        task.currentDirectoryPath = dir
        let ditto = "/usr/bin/ditto"
        if paths.count == 1 && Sys.exists(ditto) {
            task.launchPath = ditto
            task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", Paths.lastComponent(first), temp]
        } else {
            task.launchPath = "/usr/bin/zip"
            task.arguments = ["-q", "-r", "-y", temp] + paths.map { Paths.lastComponent($0) }
        }
        task.launch()
        task.waitUntilExit()
        var e: Int32 = 0
        guard task.terminationStatus == 0, let info = Sys.lstatInfo(temp, &e), info.size > 0 else {
            discardPartial(temp)
            throw FileOpError.refused("Compressing failed (\(task.launchPath ?? "") exit code \(task.terminationStatus)). Nothing was changed.")
        }
        var final = Paths.join(dir, FileOperations.uniqueName(for: base, in: dir))
        do {
            try platform.exclusiveRename(temp, final)
        } catch {
            final = Paths.join(dir, FileOperations.uniqueName(for: base, in: dir))
            do {
                try platform.exclusiveRename(temp, final)
            } catch {
                discardPartial(temp)
                throw error
            }
        }
        log("COMPRESS \(paths.count) item(s) -> \(final)")
        return (final, .createdItems([final], label: "Compress"))
    }

    /// Save new content (e.g. a contact sheet PDF) as a new file in `dir`. Never overwrites: a taken name
    /// becomes "name 2.pdf". Written under a hidden temporary name with O_EXCL, read back and compared,
    /// then renamed into place with the no-overwrite rename. Undo moves the new file to the Trash.
    func writeNewFile(_ data: Data, in dir: String, name: String) throws -> (String, UndoRecord) {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        if let why = FileOperations.nameProblem(name) { throw FileOpError.invalidName(name, why) }
        var di: Int32 = 0
        guard let dinfo = Sys.statInfo(dir, &di), dinfo.isDirectory else { throw FileOpError.notFound(dir) }
        let temp = Paths.join(dir, ".find-partial-\(UUID().uuidString)-\(name)")
        let note = noteBegin(["PARTIAL " + temp])
        defer { noteEnd(note) }
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 { throw FileOpError.system("Save", errno, temp) }
        var written = 0
        var writeError: Int32 = 0
        data.withUnsafeBytes { (raw: UnsafePointer<UInt8>) -> Void in
            while written < data.count {
                let n = write(fd, raw.advanced(by: written), data.count - written)
                if n <= 0 { writeError = errno; break }
                written += n
            }
        }
        let syncOK = fsync(fd) == 0
        close(fd)
        if written != data.count || !syncOK {
            discardPartial(temp)
            throw FileOpError.refused("Saving \"\(name)\" failed (\(Sys.errorText(writeError)), code \(writeError)). Nothing was changed.")
        }
        guard let back = FileManager.default.contents(atPath: temp), back == data else {
            discardPartial(temp)
            throw FileOpError.verifyFailed(temp, "the saved file did not read back identical")
        }
        var final = Paths.join(dir, FileOperations.uniqueName(for: name, in: dir))
        do {
            try platform.exclusiveRename(temp, final)
        } catch {
            final = Paths.join(dir, FileOperations.uniqueName(for: name, in: dir))
            do {
                try platform.exclusiveRename(temp, final)
            } catch {
                discardPartial(temp)
                throw error
            }
        }
        log("SAVE NEW FILE \(final) (\(data.count) bytes, verified)")
        return (final, .createdItems([final], label: "Save"))
    }

    /// Make a Finder alias next to the item ("<name> alias").
    func makeAlias(_ path: String) throws -> (String, UndoRecord) {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        guard Sys.exists(path) else { throw FileOpError.notFound(path) }
        let dir = Paths.parent(path)
        let temp = Paths.join(dir, ".find-partial-\(UUID().uuidString)")
        let note = noteBegin(["PARTIAL " + temp])
        defer { noteEnd(note) }
        do {
            try platform.makeAlias(target: path, at: temp)
        } catch {
            discardPartial(temp)
            throw error
        }
        let final = Paths.join(dir, FileOperations.uniqueName(for: Paths.lastComponent(path) + " alias", in: dir))
        do {
            try platform.exclusiveRename(temp, final)
        } catch {
            discardPartial(temp)
            throw error
        }
        log("ALIAS \(final) -> \(path)")
        return (final, .createdItems([final], label: "Make Alias"))
    }

    // MARK: - Ratings and metadata (Photography mode) - see MetadataEdit.swift

    /// Write a rating / metadata change to pictures, the way Photo Mechanic reads it (RAW: 0.18 - the RAW's
    /// own IPTC/XMP fields and its sidecar, with the same complete set; JPEG/TIFF: embedded XMP + IPTC;
    /// PNG/HEIC: embedded XMP). Only metadata fields are written - never the picture data. For every file:
    ///  1. a copy is made next to it under a hidden temporary name (noted for crash recovery);
    ///  2. ExifTool changes the COPY (Finder tags, labels and creation date kept);
    ///  3. the copy is read back: every value must be what was asked, and the picture data must be
    ///     bit-for-bit the same as the original's (ExifTool's image-data fingerprint) - for a RAW type
    ///     ExifTool can't fingerprint, this check is not possible and is noted in the report;
    ///  4. only then does the copy take the original's name. The previous version of a JPEG/TIFF/PNG/HEIC
    ///     (proved identical picture) is removed; the previous version of a RAW goes to the Trash as
    ///     "<name> (before metadata edit).<ext>".
    /// Any failure leaves the original exactly as it was. Groups of 50.
    func writeMetadata(_ images: [String], change: MetaChange, progress: ((Int, Int) -> Void)? = nil) -> BatchReport {
        return writeMetadata(images.map { ($0, change) }, progress: progress)
    }

    /// Each picture with its own change (Find & Replace in metadata; Undo).
    /// `transfer` (0.18.2): the Copies window's progress (pictures and bytes done, notes as they come);
    /// `isCancelled`: checked before each group - pictures already done stay done (each is complete).
    func writeMetadata(_ items: [(image: String, change: MetaChange)], progress: ((Int, Int) -> Void)? = nil,
                       transfer: TransferProgress? = nil, isCancelled: () -> Bool = { false }) -> BatchReport {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        var report = BatchReport()
        guard let tool = metadataTool else {
            report.notes.append("ExifTool is not available, so nothing was written.")
            return report
        }
        // 0.18.14: one picture is written once per run, whatever the list says (a share's folder listing
        // taken during renames can name a file twice; 0.18.13 then changed one NEF twice in one group).
        // The same picture listed twice gets its changes merged, in order; paths are compared as the files
        // they are (device + file number), so other spellings of one file count as one.
        var seenFile: [String: Int] = [:]
        var uniq: [(image: String, change: MetaChange)] = []
        for it in items where !it.change.isEmpty {
            var e: Int32 = 0
            let k = Sys.statInfo(it.image, &e).map { "\($0.device):\($0.inode)" } ?? Paths.normalize(it.image, home: "/").precomposedStringWithCanonicalMapping
            if let i = seenFile[k] {
                uniq[i].change = uniq[i].change.then(it.change)
                log("METADATA listed twice, written once: \(it.image)")
            } else {
                seenFile[k] = uniq.count
                uniq.append(it)
            }
        }
        let items = uniq
        if items.isEmpty { return report }
        let readTags = MetaPlan.readTags(for: MetaTarget(image: "", file: "", kind: .embedded(iptc: true)))
        // 0.18.11: Find's own reader for the files it can read (sidecars, JPEG, TIFF-type RAWs); ExifTool
        // for the rest (and for anything Find's reader isn't sure of).
        var nativeReads = 0, exifToolReads = 0
        // 0.18.13: where the time goes, by step (one TIMING line in the log per run).
        var tm: [String: Double] = [:]
        var tmCount: [String: Int] = [:]
        let tStart = Date()
        func timed<T>(_ k: String, _ n: Int = 1, _ f: () -> T) -> T {
            let t0 = Date()
            let r = f()
            tm[k, default: 0] += Date().timeIntervalSince(t0)
            tmCount[k, default: 0] += n
            return r
        }
        // 0.18.13: what was read for a RAW's full set is reused for Undo (same file, same run, not yet written).
        var readCache: [String: [String: Any]] = [:]
        func readValues(_ files: [String]) -> [String: [String: Any]] {
            var out: [String: [String: Any]] = [:]
            var rest: [String] = []
            for f in files {
                if let r = readCache[f] { out[f] = r; continue }
                if MetaPlan.nativeRead, NativeMeta.canRead(f), Sys.exists(f), let r = NativeMeta.read(f) { out[f] = r; nativeReads += 1 } else { rest.append(f) }
            }
            if !rest.isEmpty {
                exifToolReads += rest.count
                for (k, v) in tool.read(readTags, files: rest) { out[k] = v }
            }
            for (k, v) in out { readCache[k] = v }
            return out
        }
        // RAW pictures: the current set (the newer of the RAW's own and its sidecar's) is read first, so
        // the RAW and its sidecar can both be written with the same complete values.
        var changeFor: [String: MetaChange] = [:]
        var undoFor: [String: MetaChange] = [:]
        for it in items { changeFor[it.image] = it.change }
        let raws = items.map { $0.image }.filter { PhotoFormats.isRaw($0) }
        var currentFileOf: [String: String] = [:]
        for r in raws { currentFileOf[r] = MetaPlan.currentFile(for: r).file }
        var start0 = 0
        while start0 < raws.count {
            let chunk = Array(raws[start0..<min(raws.count, start0 + 50)])
            start0 += 50
            let recs = timed("RAW pre-read", chunk.count) { readValues(chunk.compactMap { currentFileOf[$0] }) }
            for r in chunk {
                let rec = recs[currentFileOf[r] ?? r] ?? [:]
                if let c = changeFor[r] {
                    changeFor[r] = MetaPlan.complete(c, current: rec)
                    undoFor[r] = MetaPlan.complete(MetaChange(), current: rec)   // Undo: the full set as it was
                }
            }
        }
        let targets = MetaPlan.targets(items.map { $0.image })
        var work: [(t: MetaTarget, change: MetaChange)] = []
        for t in targets {
            if case .unsupported(let why) = t.kind {
                report.skipped.append("\(Paths.lastComponent(t.image)): \(why)")
            } else if let c = changeFor[t.image], MetaPlan.hasEffect(c, for: t) {
                work.append((t, c))
            }
        }
        // 0.18.14: and never two jobs on one file (two of them changing it in place in one group, each
        // checking against the other's bytes, was the 0.18.13 E-OP-VERIFY on a share).
        var seenTargets = Set<String>()
        work = work.filter { w in
            var e: Int32 = 0
            let k = Sys.statInfo(w.t.file, &e).map { "\($0.device):\($0.inode)" } ?? Paths.normalize(w.t.file, home: "/")
            if seenTargets.contains(k) {
                if w.t.kind == .sidecarNew { report.skipped.append("\(Paths.lastComponent(w.t.image)): another picture's new sidecar has the same name (\(Paths.lastComponent(w.t.file)))") }
                log("METADATA written once, not twice: \(w.t.file)")
                return false
            }
            seenTargets.insert(k)
            return true
        }
        log("METADATA \(items.count == 1 ? items[0].change.describe : "\(items.count) pictures") - \(work.count) file(s) to write")
        if let tp = transfer {
            var e: Int32 = 0
            tp.plan(files: work.count, bytes: work.reduce(Int64(0)) { $0 + (Sys.lstatInfo($1.t.file, &e)?.size ?? 0) })
        }
        var undoItems: [(image: String, change: MetaChange)] = []
        var undoDone = Set<String>()
        var rawFailed: [String: Bool] = [:]     // RAW image -> its own file was not written
        var finished = 0
        let total = work.count
        var start = 0
        var queue = work
        var fallbackAdded = false
        var fallbackImages = Set<String>()
        while true {
            if isCancelled() {
                report.cancelled = true
                transfer?.note("Stopped: the pictures already written keep their new values (each one is complete)")
                break
            }
            if start >= queue.count {
                // RAWs whose own file couldn't be written and that have no sidecar: a new sidecar instead (once).
                if fallbackAdded { break }
                fallbackAdded = true
                start = queue.count
                for (img, failed) in rawFailed where failed && Sidecars.find(for: img) == nil {
                    if let c = changeFor[img] {
                        queue.append((MetaPlan.newSidecar(for: img), c))
                        fallbackImages.insert(img)
                    }
                }
                if start >= queue.count { break }
            }
            // 0.18.2: groups of 24 (ExifTool runs 4 at a time on 6 each): progress moves steadily.
            var group = Array(queue[start..<min(queue.count, start + 24)])
            start += 24
            // 1. Old values (for Undo) and picture fingerprints of the originals (as the setting asks).
            let mode = MetaPlan.writeMode
            func needsPrint(_ file: String) -> Bool {
                switch mode {
                case .workingCopy, .fingerprint: return true
                case .fingerprintLocal: return !IOLog.isNetworkPath(file)
                case .fast: return false
                }
            }
            let existing = group.filter { $0.t.kind != .sidecarNew }.map { $0.t.file }
            let before = existing.isEmpty ? [:] : timed("old values", existing.count) { readValues(existing) }
            // 0.18.8 "Faster: change the metadata in place" (Settings): only the metadata part of the file is
            // written. What can't be done that way (or doesn't check out) goes the normal way below.
            if MetaPlan.inPlace {
                var patched: [(w: (t: MetaTarget, change: MetaChange), plan: InPlacePlan, note: String?)] = []
                for w in group {
                    let isFile: Bool
                    switch w.t.kind { case .embedded, .embeddedRaw: isFile = true; default: isFile = false }
                    guard isFile, InPlaceMeta.canTry(w.t.file) else { continue }
                    let pl = MetaPlan.places(for: w.t)
                    let vals = InPlaceValues(w.change, current: before[w.t.file] ?? [:])
                    // A RAW type's IPTC is written only where the file already has the IPTC entry or is a TIFF/NEF/DNG.
                    guard let plan = timed("in place: plan", 1, { InPlaceMeta.plan(path: w.t.file, values: vals, xmp: pl.xmp, iptc: pl.iptc) }) else { continue }
                    let tPatch = Date()
                    defer { tm["in place: write", default: 0] += Date().timeIntervalSince(tPatch); tmCount["in place: write", default: 0] += 1 }
                    let note = noteBegin(["PATCH " + w.t.file + "\t\(plan.originalLength)\t" +
                        plan.saved.map { "\($0.offset):" + Hex.lower($0.data) }.joined(separator: ",")])
                    do {
                        try platform.patchFile(w.t.file, writes: plan.blocks)
                        if !plan.pointers.isEmpty { try platform.patchFile(w.t.file, writes: plan.pointers) }
                        patched.append((w, plan, note))
                        log("METADATA IN PLACE \(plan.summary): \(w.t.file)")
                        IOLog.onFile("METADATA in place", path: w.t.file, read: 0,
                                     written: Int64(plan.blocks.reduce(0) { $0 + $1.data.count } + plan.pointers.reduce(0) { $0 + $1.data.count }), seconds: 0)
                    } catch {
                        restoreInPlace(w.t.file, plan)
                        noteEnd(note)
                        log("METADATA IN PLACE refused (\(error)), the normal way instead: \(w.t.file)")
                    }
                }
                if !patched.isEmpty {
                    // 0.18.10: ExifTool reads every value back (default), or the fast check of the bytes written.
                    let tCheck = Date()
                    defer { tm["in place: check", default: 0] += Date().timeIntervalSince(tCheck); tmCount["in place: check", default: 0] += patched.count }
                    let back: [String: [String: Any]] = MetaPlan.inPlaceExifToolCheck ? tool.read(readTags, files: patched.map { $0.w.t.file }) : [:]
                    var done = Set<String>()
                    for p in patched {
                        let rec = back[p.w.t.file] ?? [:]
                        // 0.18.11: the fast check also reads every value back with Find's own reader.
                        let ok = MetaPlan.inPlaceExifToolCheck
                            ? (back[p.w.t.file] != nil && MetaPlan.verify(p.w.change, readBack: rec, target: p.w.t) == nil)
                            : (InPlaceMeta.readsBack(p.w.t.file, p.plan) &&
                               (NativeMeta.read(p.w.t.file).map { MetaPlan.verify(p.w.change, readBack: $0, target: p.w.t) == nil } ?? false))
                        if !ok {
                            // Not as asked: the old bytes go back, and the normal way is used.
                            restoreInPlace(p.w.t.file, p.plan)
                            noteEnd(p.note)
                            log("METADATA IN PLACE did not check out (\(MetaPlan.inPlaceExifToolCheck ? (MetaPlan.verify(p.w.change, readBack: rec, target: p.w.t) ?? "unreadable") : "bytes / structure")), put back; the normal way instead: \(p.w.t.file)")
                            continue
                        }
                        noteEnd(p.note)
                        done.insert(p.w.t.file)
                        report.done.append((p.w.t.image, p.w.t.file))
                        if !undoDone.contains(p.w.t.image) {
                            undoDone.insert(p.w.t.image)
                            let u = undoFor[p.w.t.image] ?? MetaPlan.undoChange(for: p.w.change, before: before[p.w.t.file] ?? [:])
                            undoItems.append((p.w.t.image, u))
                        }
                        finished += 1
                        progress?(finished, max(total, queue.count))
                    }
                    group = group.filter { !done.contains($0.t.file) }
                }
            }
            // 0.18.7: JPEGs are checked natively after writing (JPEGImageCheck), not with ExifTool's slow hash.
            let picFiles = group.filter { if case .embedded = $0.t.kind { return true }; return $0.t.kind == .embeddedRaw }
                .map { $0.t.file }.filter { needsPrint($0) && !JPEGImageCheck.isJPEG($0) }
            let hashBefore = picFiles.isEmpty ? [:] : timed("picture fingerprints before", picFiles.count) { tool.imageHashes(picFiles) }
            // 2. The working copies (0.18.5: only in the "working copy" mode; otherwise ExifTool writes the new
            //    version straight beside the original in step 3, under the same kind of hidden name).
            var jobs: [(t: MetaTarget, change: MetaChange, temp: String, note: String?)] = []
            var beside = Set<String>()          // temps ExifTool makes itself from the original
            var nativeAfter: [String: [String: Any]] = [:]   // 0.18.11: sidecars Find wrote itself, as read back
            let groupPrefix = ".find-partial-\(UUID().uuidString.prefix(12))-"
            for w in group {
                let t = w.t
                let dir = Paths.parent(t.file)
                let temp = Paths.join(dir, groupPrefix + Paths.lastComponent(t.file))
                if case .embedded = t.kind, needsPrint(t.file), !JPEGImageCheck.isJPEG(t.file), hashBefore[t.file] == nil {
                    report.failed.append((t.image, .refused("\(Paths.lastComponent(t.image)): its picture data could not be fingerprinted, so a change could not be verified. Nothing was written.")))
                    continue
                }
                if t.kind == .sidecarNew {
                    if Sys.exists(t.file) {
                        report.failed.append((t.image, .targetExists(t.file)))
                        continue
                    }
                    let note = noteBegin(["PARTIAL " + temp])
                    if MetaPlan.nativeSidecar, let rec = timed("sidecars by Find", 1, { writeSidecarNatively(t, w.change, current: [:], temp: temp) }) {
                        nativeAfter[temp] = rec
                    }
                    jobs.append((t, w.change, temp, note))
                    continue
                }
                if t.kind == .sidecarExisting && MetaPlan.nativeSidecar {
                    // 0.18.11: Find writes the new version of the sidecar itself, beside the old one.
                    let note = noteBegin(["PARTIAL " + temp])
                    if Sys.exists(temp) {
                        report.failed.append((t.image, .targetExists(temp)))
                        noteEnd(note)
                        continue
                    }
                    if let rec = timed("sidecars by Find", 1, { writeSidecarNatively(t, w.change, current: before[t.file] ?? [:], temp: temp) }) {
                        nativeAfter[temp] = rec
                        jobs.append((t, w.change, temp, note))
                        continue
                    }
                    noteEnd(note)       // not one Find can write itself: ExifTool, below
                }
                var e: Int32 = 0
                guard let info = Sys.statInfo(t.file, &e) else {
                    report.failed.append((t.image, .notFound(t.file)))
                    if t.kind == .embeddedRaw { rawFailed[t.image] = true }
                    continue
                }
                if let free = platform.freeBytes(dir), info.size + FileOperations.spaceMargin > free {
                    report.failed.append((t.image, .refused("Not enough free space next to \"\(Paths.lastComponent(t.file))\" for its working copy. Nothing was written.")))
                    if t.kind == .embeddedRaw { rawFailed[t.image] = true }
                    continue
                }
                let note = noteBegin(["PARTIAL " + temp])
                if mode != .workingCopy {
                    if Sys.exists(temp) {
                        report.failed.append((t.image, .targetExists(temp)))
                        noteEnd(note)
                        continue
                    }
                    beside.insert(temp)
                    IOLog.onFile("METADATA new version beside the original", path: t.file, read: info.size, written: info.size, seconds: 0)
                    jobs.append((t, w.change, temp, note))
                    continue
                }
                let tCopy = Date()
                do {
                    try platform.copyItem(t.file, temp)
                    // I/O logs: the working copy, and ExifTool reading and rewriting it (about the same again).
                    IOLog.onFile("METADATA working copy + ExifTool rewrite (approx.)", path: t.file, read: info.size * 2, written: info.size * 2,
                                 seconds: Date().timeIntervalSince(tCopy))
                } catch {
                    IOLog.onFile("METADATA working copy", path: t.file, read: -1, written: -1, seconds: Date().timeIntervalSince(tCopy),
                                 error: (error as? FileOpError)?.code ?? "E-OP-SYS")
                    report.failed.append((t.image, (error as? FileOpError) ?? .system("Copy", EIO, t.file)))
                    discardPartial(temp)
                    noteEnd(note)
                    if t.kind == .embeddedRaw { rawFailed[t.image] = true }
                    continue
                }
                if Sys.statInfo(temp, &e)?.size != info.size {
                    report.failed.append((t.image, .verifyFailed(t.file, "the working copy is not the same size")))
                    discardPartial(temp)
                    noteEnd(note)
                    if t.kind == .embeddedRaw { rawFailed[t.image] = true }
                    continue
                }
                jobs.append((t, w.change, temp, note))
            }
            if jobs.isEmpty { continue }
            // 3. Change the copies (one ExifTool run per distinct set of arguments).
            var kinds: [(args: [String], temps: [String])] = []
            var besideKinds: [(args: [String], originals: [String])] = []
            for j in jobs where nativeAfter[j.temp] == nil {
                let a = MetaPlan.writeArgs(j.change, for: j.t)
                if beside.contains(j.temp) {
                    if let i = besideKinds.index(where: { $0.args == a }) { besideKinds[i].originals.append(j.t.file) } else { besideKinds.append((a, [j.t.file])) }
                } else if let i = kinds.index(where: { $0.args == a }) { kinds[i].temps.append(j.temp) } else { kinds.append((a, [j.temp])) }
            }
            let tWrite = Date()
            for k in kinds {
                if let err = tool.write(k.args, files: k.temps) { log("METADATA ExifTool reported: \(err)") }
            }
            for k in besideKinds {
                if let err = tool.writeBeside(k.args, files: k.originals, prefix: groupPrefix) { log("METADATA ExifTool reported: \(err)") }
            }
            let nWrite = kinds.reduce(0) { $0 + $1.temps.count } + besideKinds.reduce(0) { $0 + $1.originals.count }
            if nWrite > 0 { tm["ExifTool writes", default: 0] += Date().timeIntervalSince(tWrite); tmCount["ExifTool writes", default: 0] += nWrite }
            // The new versions get the originals' Finder tags, labels, comments, permissions, creation date.
            for j in jobs where beside.contains(j.temp) && Sys.exists(j.temp) {
                platform.carryAttributes(from: j.t.file, to: j.temp)
            }
            // 4. Read the copies back.
            // 0.18.11: what Find wrote itself was read back already (and by ExifTool too if Settings ask).
            let temps = jobs.filter { Sys.exists($0.temp) && (nativeAfter[$0.temp] == nil || MetaPlan.nativeExifToolDoubleCheck) }.map { $0.temp }
            var after = temps.isEmpty ? [:] : timed("ExifTool read-back", temps.count) { tool.read(readTags, files: temps) }
            for (k, v) in nativeAfter where after[k] == nil && !MetaPlan.nativeExifToolDoubleCheck { after[k] = v }
            let picTemps = jobs.filter { if case .embedded = $0.t.kind { return true }; return $0.t.kind == .embeddedRaw }
                .filter { needsPrint($0.t.file) && !JPEGImageCheck.isJPEG($0.t.file) }.map { $0.temp }.filter { Sys.exists($0) }
            let hashAfter = picTemps.isEmpty ? [:] : timed("picture fingerprints after", picTemps.count) { tool.imageHashes(picTemps) }
            let tSwap = Date()
            defer { tm["check + swap in", default: 0] += Date().timeIntervalSince(tSwap); tmCount["check + swap in", default: 0] += jobs.count }
            // 5. Verified copies take the originals' place.
            for j in jobs {
                let name = Paths.lastComponent(j.t.image)
                let isRaw = j.t.kind == .embeddedRaw
                func fail(_ why: String) {
                    report.failed.append((j.t.image, .verifyFailed(j.t.file, why)))
                    discardPartial(j.temp)
                    noteEnd(j.note)
                    if isRaw { rawFailed[j.t.image] = true }
                }
                guard Sys.exists(j.temp), let rec = after[j.temp] else {
                    fail(isRaw ? "ExifTool could not write this RAW type" : "ExifTool did not write the metadata")
                    continue
                }
                if let problem = MetaPlan.verify(j.change, readBack: rec, target: j.t) {
                    fail(isRaw ? "this RAW type did not keep the values (\(problem))" : "after writing, \(problem)")
                    continue
                }
                if case .embedded = j.t.kind, needsPrint(j.t.file) {
                    var same: Bool
                    if JPEGImageCheck.isJPEG(j.t.file), let native = timed("JPEG picture check", 1, { JPEGImageCheck.samePicture(j.t.file, j.temp) }) {
                        same = native     // the original is still untouched, so it can be compared now
                    } else if let h0 = hashBefore[j.t.file], let h1 = hashAfter[j.temp] {
                        same = h0 == h1
                    } else {
                        // A JPEG the native check can't read: ExifTool's hash of both, now.
                        let h = tool.imageHashes([j.t.file, j.temp])
                        same = h[j.t.file] != nil && h[j.t.file] == h[j.temp]
                    }
                    if !same {
                        fail("the picture data would have changed")
                        continue
                    }
                }
                if isRaw && needsPrint(j.t.file) {
                    if let h0 = hashBefore[j.t.file] {
                        guard let h1 = hashAfter[j.temp], h0 == h1 else {
                            fail("the picture data would have changed")
                            continue
                        }
                    } else {
                        report.notes.append("\(name): ExifTool can't fingerprint this RAW type's picture data, so only the metadata could be checked; the previous version is in the Trash.")
                    }
                }
                if j.t.kind == .sidecarNew {
                    do {
                        try platform.exclusiveRename(j.temp, j.t.file)
                    } catch {
                        report.failed.append((j.t.image, .targetExists(j.t.file)))
                        discardPartial(j.temp)
                        noteEnd(j.note)
                        continue
                    }
                } else if !isRaw && (try? platform.replaceWithVerified(j.temp, j.t.file)) != nil {
                    // 0.18.14: one rename (on a share: one request instead of four); the old version was to be removed anyway.
                } else {
                    let dir = Paths.parent(j.t.file)
                    let old = Paths.join(dir, ".find-rename-\(UUID().uuidString.prefix(8))-0")
                    // If Find stops between the two renames, the next start puts the original back.
                    let note2 = noteBegin(["RENAME \(old)\t\(j.t.file)\t\(j.t.file)"])
                    do {
                        try platform.exclusiveRename(j.t.file, old)
                    } catch {
                        report.failed.append((j.t.image, .system("Rename", EIO, j.t.file)))
                        discardPartial(j.temp)
                        noteEnd(note2)
                        noteEnd(j.note)
                        if isRaw { rawFailed[j.t.image] = true }
                        continue
                    }
                    do {
                        try platform.exclusiveRename(j.temp, j.t.file)
                    } catch {
                        if (try? platform.exclusiveRename(old, j.t.file)) != nil {
                            noteEnd(note2)
                        } else {
                            report.notes.append("\(name): the original is safe under the hidden name \(old); Find puts it back at its next start.")
                        }
                        report.failed.append((j.t.image, .system("Rename", EIO, j.t.file)))
                        discardPartial(j.temp)
                        noteEnd(j.note)
                        if isRaw { rawFailed[j.t.image] = true }
                        continue
                    }
                    if isRaw {
                        // A RAW's previous version is never deleted: it goes to the Trash under a name you
                        // can recognise.
                        do {
                            let inTrash = try platform.moveToTrash(old)
                            let visible = Paths.join(Paths.parent(inTrash), FileOperations.uniqueName(
                                for: Paths.baseName(Paths.lastComponent(j.t.file)) + " (before metadata edit)." + Paths.fileExtension(j.t.file),
                                in: Paths.parent(inTrash)))
                            if (try? platform.exclusiveRename(inTrash, visible)) == nil {
                                report.notes.append("\(name): the previous version is in the Trash as \(Paths.lastComponent(inTrash)).")
                            }
                        } catch {
                            // No Trash there (most shares): a previous version proved to hold the same picture
                            // is removed like a JPEG's; without that proof it is kept, hidden.
                            if needsPrint(j.t.file) && hashBefore[j.t.file] != nil && (try? platform.removeReplacedOriginal(old)) != nil {
                                // removed
                            } else {
                                report.notes.append("\(name): the previous version could not be moved to the Trash and is kept hidden as \(Paths.lastComponent(old)).")
                            }
                        }
                    } else {
                        do {
                            try platform.removeReplacedOriginal(old)
                        } catch {
                            report.notes.append("\(name): the previous version could not be removed and is kept hidden as \(Paths.lastComponent(old)).")
                        }
                    }
                    noteEnd(note2)
                }
                noteEnd(j.note)
                log("METADATA \(j.change.describe): \(j.t.file)")
                report.done.append((j.t.image, j.t.file))
                if let tp = transfer {
                    var e: Int32 = 0
                    tp.countDone(name: Paths.lastComponent(j.t.file), bytes: Sys.lstatInfo(j.t.file, &e)?.size ?? 0)
                }
                if j.t.kind == .sidecarNew && fallbackImages.contains(j.t.image) {
                    report.notes.append("\(name): its own file could not be written, so the values went into a new sidecar, \"\(Paths.lastComponent(j.t.file))\".")
                }
                if !undoDone.contains(j.t.image) {
                    undoDone.insert(j.t.image)
                    let u = undoFor[j.t.image] ?? MetaPlan.undoChange(for: j.change, before: before[j.t.file] ?? [:])
                    undoItems.append((j.t.image, u))
                }
                finished += 1
                progress?(finished, max(total, queue.count))
            }
        }
        if !undoItems.isEmpty { report.undo = .metadata(undoItems) }
        if nativeReads + exifToolReads > 0 {
            log("METADATA old values read: \(nativeReads) by Find itself, \(exifToolReads) by ExifTool")
        }
        // 0.18.13: one line, short enough to retype: total, then each step's seconds and file count.
        let steps = ["RAW pre-read", "old values", "in place: plan", "in place: write", "in place: check", "picture fingerprints before",
                     "sidecars by Find", "ExifTool writes", "ExifTool read-back", "picture fingerprints after", "JPEG picture check", "check + swap in"]
        let parts = steps.filter { tm[$0] != nil }.map { "\($0) " + String(format: "%.1fs/%d", tm[$0] ?? 0, tmCount[$0] ?? 0) }
        // 0.18.15: with the settings that decide the speed, so a line says what it measured.
        let flushName = ["thorough flush", "normal flush", "no flush"][MetaPlan.flush.rawValue]
        let setup = "[\(flushName), in place \(MetaPlan.inPlace ? "on" : "off"), check \(MetaPlan.inPlaceExifToolCheck ? "ExifTool" : "fast"), mode \(MetaPlan.writeMode)]"
        log(String(format: "METADATA TIMING %.1fs for %d files ", Date().timeIntervalSince(tStart), total) + setup + ": " + parts.joined(separator: ", "))
        return report
    }

    /// 0.18.13: current values of several files for the editor: Find's own reader where it can, ExifTool
    /// for the rest (keyed by path; a file neither could read is missing).
    func readMetadataValues(_ files: [String]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        var rest: [String] = []
        for f in files {
            if MetaPlan.nativeRead, NativeMeta.canRead(f), Sys.exists(f), let r = NativeMeta.read(f) { out[f] = r } else { rest.append(f) }
        }
        if !rest.isEmpty, let tool = metadataTool {
            let tags = MetaPlan.readTags(for: MetaTarget(image: "", file: "", kind: .embedded(iptc: true)))
            for (k, v) in tool.read(tags, files: rest) { out[k] = v }
        }
        return out
    }

    /// 0.18.11: a sidecar's new version written by Find itself (no ExifTool): the old text with only our
    /// fields changed (XMPEditor), written under the hidden temporary name (O_EXCL: never over anything),
    /// flushed, then read back byte for byte and value for value. It takes the old one's place in step 5
    /// like ExifTool's would. nil = not done, nothing left behind (ExifTool writes it instead).
    private func writeSidecarNatively(_ t: MetaTarget, _ c: MetaChange, current: [String: Any], temp: String) -> [String: Any]? {
        var old: String? = nil
        if t.kind == .sidecarExisting {
            guard let d = FileManager.default.contents(atPath: t.file), let s = String(data: d, encoding: .utf8) else { return nil }
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { old = s }
        }
        guard let data = XMPEditor.edit(old, InPlaceValues(c, current: current).xmpChanges()) else { return nil }
        let t0 = Date()
        if let err = writeExclusive(temp, data) {
            if err != EEXIST { discardPartial(temp) }
            log("METADATA Find could not write the sidecar itself (\(Sys.errorText(err)), code \(err)), ExifTool instead: \(t.file)")
            return nil
        }
        if t.kind == .sidecarExisting { platform.carryAttributes(from: t.file, to: temp) }
        // Read back once (0.18.14: the values come from the same bytes - on a share one read instead of two).
        guard let back = FileManager.default.contents(atPath: temp), back == data,
            let text = String(data: back, encoding: .utf8), let rec = XMPEditor.read(text),
            MetaPlan.verify(c, readBack: rec, target: t) == nil else {
            discardPartial(temp)
            log("METADATA the sidecar Find wrote itself did not read back as asked, ExifTool instead: \(t.file)")
            return nil
        }
        IOLog.onFile("METADATA sidecar written by Find", path: t.file, read: Int64(back.count), written: Int64(data.count),
                     seconds: Date().timeIntervalSince(t0))
        return rec
    }

    /// Write `data` as a new file at `path` (which must not exist), then flush it to the disk (the full
    /// flush if Settings ask). nil = done; else the error number (EEXIST: something was already there).
    private func writeExclusive(_ path: String, _ data: Data) -> Int32? {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 { return errno }
        var written = 0
        var writeError: Int32 = 0
        data.withUnsafeBytes { (raw: UnsafePointer<UInt8>) -> Void in
            while written < data.count {
                let n = write(fd, raw.advanced(by: written), data.count - written)
                if n <= 0 { writeError = errno; break }
                written += n
            }
        }
        var synced = MetaPlan.flush == .none        // 0.18.14: no flush asked for
        #if os(macOS)
        if !synced && MetaPlan.flush == .full && fcntl(fd, F_FULLFSYNC) == 0 { synced = true }
        #endif
        if !synced { synced = fsync(fd) == 0 }
        close(fd)
        if written != data.count { return writeError == 0 ? EIO : writeError }
        if !synced { return EIO }
        return nil
    }

    /// 0.18.8: put a file changed in place back as it was (its saved bytes, its old length).
    private func restoreInPlace(_ path: String, _ plan: InPlacePlan) {
        do {
            if !plan.saved.isEmpty { try platform.patchFile(path, writes: plan.saved) }
            var e: Int32 = 0
            if let st = Sys.lstatInfo(path, &e), st.size > plan.originalLength { try platform.truncateFile(path, to: plan.originalLength) }
        } catch {
            log("METADATA IN PLACE E-INPLACE-1 could not put back \(path): \(error) - the note stays for the next start")
        }
    }

    // MARK: - Recovery after an interrupted operation (called once at launch, before anything else runs)

    /// Finish what an interrupted operation left in user folders, from the operation notes:
    /// - an item still under a batch-rename temporary name (".find-rename-...") gets its original name
    ///   back (or its intended new name, or "name 2" if both are taken) - nothing is hidden or lost;
    /// - a partial copy / save (".find-partial-...") goes to the Trash (never deleted).
    /// Only items whose names have Find's temporary prefix, in the folder the note names, are touched.
    /// Notes of another Find that is still running are left alone. Returns one line per action.
    func recoverInterrupted(_ journal: OperationJournal) -> [String] {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        var out: [String] = []
        for lo in journal.leftovers() {
            if journal.belongsToRunningProcess(lo.token) {
                out.append("RECOVERY skipped note \(lo.token): another Find is running")
                continue
            }
            var keep = false
            // 0.18.8: a picture whose metadata was being changed in place: its old bytes and length back.
            for p in lo.patches {
                var e: Int32 = 0
                guard p.path.hasPrefix("/"), let st = Sys.lstatInfo(p.path, &e), st.isRegular, st.size >= p.length else {
                    out.append("RECOVERY E-RECOVER-3 in-place change not put back (file missing or changed since): \(p.path)")
                    continue
                }
                do {
                    if !p.saved.isEmpty { try platform.patchFile(p.path, writes: p.saved) }
                    if st.size > p.length { try platform.truncateFile(p.path, to: p.length) }
                    out.append("RECOVERY metadata change put back as it was: \(p.path)")
                    log("RECOVERY PATCH \(p.path)")
                } catch {
                    keep = true
                    out.append("RECOVERY E-RECOVER-4 could not put back (tried again next start): \(p.path)")
                }
            }
            for r in lo.renames {
                let temp = r.temp, dir = Paths.parent(r.temp)
                guard Paths.lastComponent(temp).hasPrefix(".find-rename-"), Paths.parent(r.original) == dir,
                    FileOperations.nameProblem(Paths.lastComponent(r.original)) == nil else {
                    out.append("RECOVERY E-RECOVER-1 ignored a note line that does not look like Find's: \(temp)")
                    continue
                }
                var e: Int32 = 0
                if Sys.lstatInfo(temp, &e) == nil { continue }   // that item was already finished or put back
                var targets = [r.original]
                if let f = r.final, Paths.parent(f) == dir, FileOperations.nameProblem(Paths.lastComponent(f)) == nil { targets.append(f) }
                var done = false
                for t in targets where !Sys.exists(t) {
                    if (try? platform.exclusiveRename(temp, t)) != nil {
                        out.append("RECOVERY renamed back: \(temp) -> \(t)")
                        log("RECOVERY RENAME \(temp) -> \(t)")
                        done = true
                        break
                    }
                }
                if !done {
                    let t = Paths.join(dir, FileOperations.uniqueName(for: Paths.lastComponent(r.original), in: dir))
                    if (try? platform.exclusiveRename(temp, t)) != nil {
                        out.append("RECOVERY renamed back under a free name: \(temp) -> \(t)")
                        log("RECOVERY RENAME \(temp) -> \(t)")
                    } else {
                        keep = true
                        out.append("RECOVERY E-RECOVER-2 could not rename back (tried again next start): \(temp)")
                    }
                }
            }
            for p in lo.partials {
                guard Paths.lastComponent(p).hasPrefix(".find-partial-") else {
                    out.append("RECOVERY E-RECOVER-1 ignored a note line that does not look like Find's: \(p)")
                    continue
                }
                var e: Int32 = 0
                if Sys.lstatInfo(p, &e) == nil { continue }
                do {
                    let t = try toTrash(p)
                    out.append("RECOVERY unfinished copy moved to the Trash: \(p)" + (t.isEmpty ? "" : " -> \(t)"))
                    log("RECOVERY PARTIAL to Trash \(p)")
                } catch {
                    keep = true
                    out.append("RECOVERY E-RECOVER-3 could not move an unfinished copy to the Trash (tried again next start): \(p)")
                }
            }
            if !keep { journal.end(lo.token) }
        }
        return out
    }

    /// Self-check only: move an item this instance put in the Trash back into a scratch folder.
    func reclaimFromTrash(_ trashed: String, into dir: String) -> Bool {
        guard trashHistory.contains(trashed) else { return false }
        let back = Paths.join(dir, "returned-\(UUID().uuidString)")
        return (try? platform.exclusiveRename(trashed, back)) != nil
    }

    // MARK: - Raw primitives (only used from this file)

    /// mkdir: fails with EEXIST if the name is taken; never replaces anything.
    static func makeDirectory(_ path: String, _ err: inout Int32) -> Bool {
        if mkdir(path, 0o755) != 0 {
            err = errno
            return false
        }
        return true
    }

    /// Plain rename(2). Only used for case-only renames, after confirming source and target are the same file.
    static func plainRename(_ src: String, _ dst: String, _ err: inout Int32) -> Bool {
        #if os(Linux)
        let rc = Glibc.rename(src, dst)
        #else
        let rc = Darwin.rename(src, dst)
        #endif
        if rc != 0 {
            err = errno
            return false
        }
        return true
    }

    // MARK: - Undo

    /// Reverse a change. Returns the record that would redo it.
    func undo(_ record: UndoRecord) throws -> UndoRecord? {
        Activity.shared.begin(.fileOperation)
        defer { Activity.shared.end(.fileOperation) }
        switch record {
        case .renamedMany(let pairs):
            if pairs.isEmpty { return nil }
            let back = pairs.map { (path: $0.to, newName: Paths.lastComponent($0.from)) }
            let (done, _) = try renameNested(back)
            return .renamedMany(done)

        case .renamed(let from, let to):
            if from == to { return nil }
            guard Sys.exists(to) else { throw FileOpError.notFound(to) }
            let (back, _) = try rename(to, to: Paths.lastComponent(from))
            // Redo = rename `back` to the name it had after the original change.
            return .renamed(from: to, to: back)

        case .createdFolder(let path):
            guard Sys.exists(path) else { throw FileOpError.notFound(path) }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            if !contents.isEmpty {
                throw FileOpError.refused("\"\(Paths.lastComponent(path))\" is no longer empty, so it was not removed.")
            }
            let r = trash([path])
            if let f = r.failed.first { throw f.error }
            return nil

        case .trashed(let items):
            var restored: [(from: String, to: String)] = []
            var problems: [String] = []
            for it in items {
                if Sys.exists(it.original) {
                    problems.append("\"\(Paths.lastComponent(it.original))\": something with that name is already back in its folder")
                    continue
                }
                do {
                    try platform.exclusiveRename(it.trashed, it.original)
                    restored.append((it.trashed, it.original))
                    log("PUT BACK \(it.trashed) -> \(it.original)")
                } catch {
                    problems.append("\"\(Paths.lastComponent(it.original))\": \(error)")
                }
            }
            if !problems.isEmpty {
                throw FileOpError.refused("Some items could not be put back:\n" + problems.joined(separator: "\n"))
            }
            return .moved(restored)

        case .moved(let pairs):
            var back: [(from: String, to: String)] = []
            var problems: [String] = []
            for p in pairs.reversed() {
                if Sys.exists(p.from) {
                    problems.append("\"\(Paths.lastComponent(p.from))\" already exists in its original folder")
                    continue
                }
                do {
                    try platform.exclusiveRename(p.to, p.from)
                    back.append((p.to, p.from))
                    log("UNDO MOVE \(p.to) -> \(p.from)")
                } catch {
                    problems.append("\"\(Paths.lastComponent(p.to))\": \(error)")
                }
            }
            if !problems.isEmpty {
                throw FileOpError.refused("Some items could not be moved back:\n" + problems.joined(separator: "\n"))
            }
            return .moved(back)

        case .movedAcrossVolumes(let items):
            // Put the original back from the Trash, then send the copy to the Trash.
            var problems: [String] = []
            for it in items {
                if Sys.exists(it.original) {
                    problems.append("\"\(Paths.lastComponent(it.original))\" already exists in its original folder")
                    continue
                }
                do {
                    try platform.exclusiveRename(it.trashedOriginal, it.original)
                    log("UNDO CROSS-MOVE: original restored \(it.original)")
                } catch {
                    problems.append("\"\(Paths.lastComponent(it.original))\" could not be put back from the Trash: \(error)")
                    continue
                }
                let r = trash([it.copy])
                if let f = r.failed.first {
                    problems.append("The copy \"\(it.copy)\" was kept: \(f.error.description)")
                }
            }
            if !problems.isEmpty {
                throw FileOpError.refused("Undo was only partly possible:\n" + problems.joined(separator: "\n"))
            }
            return nil

        case .group(let parts, let label):
            // Last change first. If one part can't be undone, the parts already undone are redone, so
            // nothing is left half way, and the error is passed on.
            var redos: [UndoRecord] = []
            for part in parts.reversed() {
                do {
                    if let r = try undo(part) { redos.append(r) }
                } catch {
                    for r in redos.reversed() { _ = try? undo(r) }
                    throw error
                }
            }
            return redos.isEmpty ? nil : .group(redos, label: label)
        case .metadata(let items):
            // Write the old values back (same safe procedure).
            var redo: [(image: String, change: MetaChange)] = []
            var problems: [String] = []
            let r = writeMetadata(items)
            if case .metadata(let back)? = r.undo { redo += back }
            for f in r.failed { problems.append(f.error.description) }
            if !problems.isEmpty { throw FileOpError.refused("Some metadata could not be put back:\n" + problems.joined(separator: "\n")) }
            return redo.isEmpty ? nil : .metadata(redo)
        case .tagsChanged(let items):
            var redo: [(path: String, names: [String])] = []
            var problems: [String] = []
            for it in items {
                let now = platform.tagNames(it.path)
                do {
                    try platform.setTagNames(it.path, it.names)
                    redo.append((it.path, now))
                } catch {
                    problems.append("\(Paths.lastComponent(it.path)): \(error)")
                }
            }
            if !problems.isEmpty { throw FileOpError.refused("Some labels could not be restored:\n" + problems.joined(separator: "\n")) }
            return .tagsChanged(redo)

        case .copied(let paths), .createdItems(let paths, _):
            let r = trash(paths)
            if !r.failed.isEmpty {
                throw FileOpError.refused(r.summaryLines.joined(separator: "\n"))
            }
            return nil
        }
    }
}

extension Array {
    /// `allSatisfy` arrived in Swift 4.2; this works in Swift 4.1.
    func allSatisfyCompat(_ test: (Element) -> Bool) -> Bool {
        for e in self where !test(e) { return false }
        return true
    }
}

/// 0.18.15: bytes as lower-case hex, fast (0.18.8-14 formatted each byte with String(format:), about
/// 10 ms for a JPEG's 60 KB metadata area - most of "in place: write" in the TIMING line).
enum Hex {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)
    static func lower(_ d: Data) -> String {
        var out = [UInt8](repeating: 0, count: d.count * 2)
        var k = 0
        for b in d {
            out[k] = digits[Int(b >> 4)]
            out[k + 1] = digits[Int(b & 0x0F)]
            k += 2
        }
        return String(decoding: out, as: UTF8.self)
    }
}
