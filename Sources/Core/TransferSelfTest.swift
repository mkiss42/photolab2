// TransferSelfTest.swift
// Copy / move engine on a fixture in ~/Library/Caches/PhotoLab2/selftest (removed after):
//   src/A.CR3 (9 MB: more than one 8 MB chunk), A.JPG, A.xmp, B.tif,
//   src/Shoot/x.jpg, src/Shoot/Sub/y.txt, src/Shoot/link -> x.jpg
// Cross-volume behaviour is forced on one volume (items marked crossDevice), which also forces
// the byte copy instead of a clone.

import Foundation
import Darwin

enum TransferSelfTest {
    static let mtime: Double = 1_600_000_000

    static func run() -> [SelfTestResult] {
        guard let base = AppFiles.makeOpsFixture() else {
            return [SelfTestResult(name: "xfer-fixture", status: .fail, detail: "could not create fixture")]
        }
        defer { AppFiles.removeOpsFixture(base) }
        let src = base + "/src", dst = base + "/dst"
        let made = AppFiles.makeTestFolder(src + "/Shoot/Sub") && AppFiles.makeTestFolder(dst)
            && AppFiles.makeTestFile(src + "/A.CR3", bytes: 9_000_000, modified: mtime)
            && AppFiles.makeTestFile(src + "/A.JPG", bytes: 20_000, modified: mtime)
            && AppFiles.makeTestFile(src + "/A.xmp", bytes: 900, modified: mtime)
            && AppFiles.makeTestFile(src + "/B.tif", bytes: 3_000, modified: mtime)
            && AppFiles.makeTestFile(src + "/Shoot/x.jpg", bytes: 10, modified: mtime)
            && AppFiles.makeTestFile(src + "/Shoot/Sub/y.txt", bytes: 5, modified: mtime)
            && AppFiles.makeTestSymlink(src + "/Shoot/link", to: "x.jpg")
        guard made else { return [SelfTestResult(name: "xfer-fixture", status: .fail, detail: "could not fill fixture")] }
        return [names(), copySet(src, dst), keepBothAndSkip(src, dst), copyFolder(src, dst), duplicate(src),
                intoItself(src), moveSameVolume(dst), moveCrossVolume(src, base), stop(src, base), recovery(dst), tags(src)]
    }

    // MARK: Helpers

    static func fail(_ n: String, _ d: String) -> SelfTestResult { return SelfTestResult(name: n, status: .fail, detail: d) }
    static func ok(_ n: String) -> SelfTestResult { return SelfTestResult(name: n, status: .ok, detail: "") }
    static func list(_ dir: String) -> Set<String> { return Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []) }
    static func exists(_ p: String) -> Bool { var s = stat(); return lstat(p, &s) == 0 }
    static func size(_ p: String) -> Int64 { var s = stat(); return lstat(p, &s) == 0 ? Int64(s.st_size) : -1 }
    static func modified(_ p: String) -> Double { var s = stat(); return lstat(p, &s) == 0 ? DirectoryReader.seconds(s.st_mtimespec) : 0 }
    static func noPartials(_ dir: String) -> Bool { return !list(dir).contains { $0.hasPrefix(Transfers.partialPrefix) } }

    static func job(_ plan: FileOperations.TransferPlan, _ kind: TransferKind, _ dest: String,
                    _ clash: ClashChoice = .keepBoth, forceCross: Bool = false) -> TransferJob {
        let items = forceCross ? plan.items.map { TransferItem(source: $0.source, group: $0.group, isFolder: $0.isFolder, crossDevice: true) } : plan.items
        return TransferJob(kind: kind, destination: dest, items: items, clash: clash, duplicate: plan.duplicate)
    }

    // MARK: Cases

    static func names() -> SelfTestResult {
        let n = "xfer-rules"
        let cases: [(String, String)] = [
            (Transfers.numberedName("IMG_1.CR3", 2, duplicate: false, isFolder: false), "IMG_1 2.CR3"),
            (Transfers.numberedName("IMG_1.CR3", 1, duplicate: true, isFolder: false), "IMG_1 copy.CR3"),
            (Transfers.numberedName("IMG_1.CR3", 3, duplicate: true, isFolder: false), "IMG_1 copy 3.CR3"),
            (Transfers.numberedName("Shoot 1.2", 2, duplicate: false, isFolder: true), "Shoot 1.2 2"),
            (Transfers.dropOperation(sameVolume: true, option: false, command: false).rawValue, "move"),
            (Transfers.dropOperation(sameVolume: false, option: false, command: false).rawValue, "copy"),
            (Transfers.dropOperation(sameVolume: true, option: true, command: false).rawValue, "copy"),
            (Transfers.dropOperation(sameVolume: false, option: false, command: true).rawValue, "move"),
            (String(Transfers.intoItself(source: "/a/b", destination: "/a/b/c")), "true"),
            (String(Transfers.intoItself(source: "/a/b", destination: "/a/bc")), "false")]
        for (got, want) in cases where got != want { return fail(n, "\(got) != \(want)") }
        return ok(n)
    }

    /// One RAW copies its whole set, byte for byte (two chunks), dates kept, nothing partial left.
    static func copySet(_ src: String, _ dst: String) -> SelfTestResult {
        let n = "xfer-copy-set"
        let plan = FileOperations.planTransfer([src + "/A.CR3"], to: dst, kind: .copy, sets: true)
        guard plan.problem == nil, plan.items.count == 3, plan.clashes.isEmpty else {
            return fail(n, "plan: \(plan.items.count) items, problem \(plan.problem ?? "-")")
        }
        let j = job(plan, .copy, dst, forceCross: true)
        FileOperations.runTransfer(j)
        let p = j.progress
        guard p.state == .done, j.created.count == 3 else { return fail(n, "state \(p.state.rawValue): \(p.failures.joined(separator: "; "))") }
        guard list(dst) == ["A.CR3", "A.JPG", "A.xmp"] else { return fail(n, list(dst).sorted().joined(separator: "|")) }
        guard size(dst + "/A.CR3") == 9_000_000, size(dst + "/A.JPG") == 20_000 else { return fail(n, "sizes") }
        guard FileManager.default.contentsEqual(atPath: src + "/A.CR3", andPath: dst + "/A.CR3") else { return fail(n, "content differs") }
        guard abs(modified(dst + "/A.CR3") - mtime) < 1 else { return fail(n, "date not kept") }
        guard p.doneBytes == 9_020_900, p.totalBytes == p.doneBytes, p.doneFiles == 3 else {
            return fail(n, "progress \(p.doneFiles) files \(p.doneBytes)/\(p.totalBytes) bytes")
        }
        return AppFiles.readTransferJournal().isEmpty ? ok(n) : fail(n, "journal not cleared")
    }

    /// The same again: keep both numbers the whole set alike; skip leaves everything as it was.
    static func keepBothAndSkip(_ src: String, _ dst: String) -> SelfTestResult {
        let n = "xfer-keep-both-skip"
        let plan = FileOperations.planTransfer([src + "/A.JPG"], to: dst, kind: .copy, sets: true)
        guard plan.clashes.count == 3 else { return fail(n, "clashes \(plan.clashes.count)") }
        let skip = job(plan, .copy, dst, .skip)
        FileOperations.runTransfer(skip)
        guard skip.progress.state == .done, skip.progress.skipped == 3, list(dst).count == 3 else { return fail(n, "skip changed files") }
        let keep = job(plan, .copy, dst, .keepBoth)
        FileOperations.runTransfer(keep)
        let want: Set<String> = ["A.CR3", "A.JPG", "A.xmp", "A 2.CR3", "A 2.JPG", "A 2.xmp"]
        return list(dst) == want ? ok(n) : fail(n, list(dst).sorted().joined(separator: "|"))
    }

    /// A folder with a subfolder and a symlink (same volume: clones where the disk can).
    static func copyFolder(_ src: String, _ dst: String) -> SelfTestResult {
        let n = "xfer-copy-folder"
        let plan = FileOperations.planTransfer([src + "/Shoot"], to: dst, kind: .copy, sets: true)
        let j = job(plan, .copy, dst)
        FileOperations.runTransfer(j)
        guard j.progress.state == .done else { return fail(n, j.progress.failures.joined(separator: "; ")) }
        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: dst + "/Shoot/link")) ?? ""
        guard size(dst + "/Shoot/Sub/y.txt") == 5, size(dst + "/Shoot/x.jpg") == 10, link == "x.jpg" else {
            return fail(n, "tree differs, link '\(link)'")
        }
        return noPartials(dst) ? ok(n) : fail(n, "partial left")
    }

    static func duplicate(_ src: String) -> SelfTestResult {
        let n = "xfer-duplicate"
        for _ in 0..<2 {
            let plan = FileOperations.planTransfer([src + "/B.tif"], to: src, kind: .copy, sets: true)
            guard plan.duplicate else { return fail(n, "not seen as a duplicate") }
            FileOperations.runTransfer(job(plan, .copy, src))
        }
        let l = list(src)
        return l.contains("B copy.tif") && l.contains("B copy 2.tif") ? ok(n) : fail(n, l.sorted().joined(separator: "|"))
    }

    static func intoItself(_ src: String) -> SelfTestResult {
        let n = "xfer-into-itself"
        let plan = FileOperations.planTransfer([src + "/Shoot"], to: src + "/Shoot/Sub", kind: .copy, sets: true)
        return plan.problem != nil && plan.items.isEmpty ? ok(n) : fail(n, "a folder was allowed into itself")
    }

    /// Same volume: renames, the set together; the reverse renames undo it.
    static func moveSameVolume(_ dst: String) -> SelfTestResult {
        let n = "xfer-move-rename"
        let into = dst + "/Shoot/Sub"
        let plan = FileOperations.planTransfer([dst + "/A 2.CR3"], to: into, kind: .move, sets: true)
        let j = job(plan, .move, into)
        FileOperations.runTransfer(j)
        guard j.progress.state == .done, j.moved.count == 3, exists(into + "/A 2.xmp"), !exists(dst + "/A 2.JPG") else {
            return fail(n, "moved \(j.moved.count): \(j.progress.failures.joined(separator: "; "))")
        }
        let back = Array(j.moved.map { ($0.1, $0.0) }.reversed())
        guard case .success = FileOperations.applyRenames(back, what: "undo move"), exists(dst + "/A 2.JPG") else {
            return fail(n, "undo failed")
        }
        return ok(n)
    }

    /// Cross volume (forced): copy, verify, remove the originals - but a file that appears in the
    /// source folder during the move stays, with its folder.
    static func moveCrossVolume(_ src: String, _ base: String) -> SelfTestResult {
        let n = "xfer-move-cross"
        let dest = base + "/dst2"
        guard AppFiles.makeTestFolder(dest) else { return fail(n, "setup") }
        let plan = FileOperations.planTransfer([src + "/Shoot"], to: dest, kind: .move, sets: true)
        let j = job(plan, .move, dest, forceCross: true)
        j.testHookAfterScan = { _ in _ = AppFiles.makeTestFile(src + "/Shoot/new.txt", bytes: 3, modified: mtime) }
        FileOperations.runTransfer(j)
        guard j.progress.state == .done, size(dest + "/Shoot/Sub/y.txt") == 5, exists(dest + "/Shoot/link") else {
            return fail(n, "copy: \(j.progress.failures.joined(separator: "; "))")
        }
        guard !exists(dest + "/Shoot/new.txt"), list(src + "/Shoot") == ["new.txt"], j.progress.notes.count == 1 else {
            return fail(n, "originals left: " + list(src + "/Shoot").sorted().joined(separator: "|"))
        }
        return ok(n)
    }

    /// Stop after the scan: nothing is created, nothing partial is left.
    static func stop(_ src: String, _ base: String) -> SelfTestResult {
        let n = "xfer-stop"
        let dest = base + "/dst3"
        guard AppFiles.makeTestFolder(dest) else { return fail(n, "setup") }
        let plan = FileOperations.planTransfer([src + "/A.CR3"], to: dest, kind: .copy, sets: true)
        let j = job(plan, .copy, dest, forceCross: true)
        j.testHookAfterScan = { $0.cancel() }
        FileOperations.runTransfer(j)
        return j.progress.state == .stopped && list(dest).isEmpty && j.created.isEmpty ? ok(n)
            : fail(n, "state \(j.progress.state.rawValue), left " + list(dest).sorted().joined(separator: "|"))
    }

    /// Finder tags: add Red and Blue, keep a non-colour tag, remove Red, clear; and tags travel
    /// with a copy (copyfile carries extended attributes).
    static func tags(_ src: String) -> SelfTestResult {
        let n = "tags-finder"
        let f = src + "/B.tif"
        guard FileOperations.setTags(f, [FinderTag(name: "Client", color: 0)]) else { return fail(n, "write refused") }
        _ = FileOperations.changeTag([f], color: 6, add: true)
        _ = FileOperations.changeTag([f], color: 4, add: true)
        guard let t1 = FinderTags.read(f), t1.map({ $0.name }) == ["Client", "Red", "Blue"] else {
            return fail(n, "after add: " + (FinderTags.read(f) ?? []).map { "\($0.name)/\($0.color)" }.joined(separator: ","))
        }
        let copy = FileOperations.planTransfer([f], to: src, kind: .copy, sets: true)
        let j = job(copy, .copy, src, forceCross: true)
        FileOperations.runTransfer(j)
        guard let c = j.created.first, FinderTags.read(c)?.count == 3 else { return fail(n, "tags not copied") }
        _ = FileOperations.changeTag([f], color: 6, add: false)
        guard FinderTags.read(f)?.map({ $0.color }) == [0, 4] else { return fail(n, "after remove") }
        FileOperations.setTags(f, [])
        return FinderTags.read(f) == [] ? ok(n) : fail(n, "not cleared")
    }

    /// A partial copy left by a crash is removed at launch.
    static func recovery(_ dst: String) -> SelfTestResult {
        let n = "xfer-recovery"
        let partial = dst + "/" + Transfers.partialPrefix + "selftest-0"
        guard AppFiles.makeTestFolder(partial), AppFiles.makeTestFile(partial + "/half.CR3", bytes: 10, modified: mtime) else {
            return fail(n, "setup")
        }
        AppFiles.notePartial(partial, active: true)
        _ = FileOperations.recoverTransfers(quiet: true)
        return !exists(partial) && AppFiles.readTransferJournal().isEmpty ? ok(n) : fail(n, "partial copy still there")
    }
}
