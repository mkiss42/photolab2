// FileOperations.swift
// User-file operations: rename (one file or a whole raw+jpg+xmp set), new folder, Trash, put
// back, and the recovery journal. One of the three source files allowed to change files.
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
}
