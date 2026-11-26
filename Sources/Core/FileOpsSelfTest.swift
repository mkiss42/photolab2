// FileOpsSelfTest.swift
// File operations on a fixture folder in ~/Library/Caches/PhotoLab2/selftest (removed after):
// set rename, clash refusal, case-only rename, new folder naming, Trash + put back, journal recovery.

import Foundation

enum FileOpsSelfTest {
    static func run() -> [SelfTestResult] {
        guard let dir = AppFiles.makeOpsFixture() else {
            return [SelfTestResult(name: "ops-fixture", status: .fail, detail: "could not create fixture")]
        }
        defer { AppFiles.removeOpsFixture(dir) }
        return [renameSet(dir), clash(dir), caseOnly(dir), single(dir), newFolder(dir), trash(dir), journal(dir)]
    }

    static func exists(_ p: String) -> Bool { return FileManager.default.fileExists(atPath: p) }
    static func names(_ dir: String) -> Set<String> {
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    }
    static func fail(_ n: String, _ d: String) -> SelfTestResult { return SelfTestResult(name: n, status: .fail, detail: d) }
    static func ok(_ n: String) -> SelfTestResult { return SelfTestResult(name: n, status: .ok, detail: "") }

    static func renameSet(_ dir: String) -> SelfTestResult {
        let n = "ops-rename-set"
        switch FileOperations.rename(dir + "/IMG_1.CR3", to: "Smith_1.CR3", sets: true) {
        case .failure(let f): return fail(n, f.message)
        case .success(let pairs):
            let want: Set<String> = ["Smith_1.CR3", "Smith_1.JPG", "Smith_1.xmp", "IMG_1.psd", "IMG_2.CR3"]
            guard names(dir).isSuperset(of: want), pairs.count == 3 else { return fail(n, names(dir).sorted().joined(separator: "|")) }
            return ok(n)
        }
    }

    static func clash(_ dir: String) -> SelfTestResult {
        let n = "ops-rename-clash"
        let before = names(dir)
        if case .success = FileOperations.rename(dir + "/Smith_1.CR3", to: "IMG_2.CR3", sets: true) {
            return fail(n, "renamed onto an existing file")
        }
        return names(dir) == before ? ok(n) : fail(n, "files changed after a refused rename")
    }

    static func caseOnly(_ dir: String) -> SelfTestResult {
        let n = "ops-rename-case"
        switch FileOperations.rename(dir + "/Smith_1.CR3", to: "smith_1.CR3", sets: true) {
        case .failure(let f): return fail(n, f.message)
        case .success:
            let now = names(dir)
            guard now.contains("smith_1.CR3"), now.contains("smith_1.JPG"), now.contains("smith_1.xmp") else {
                return fail(n, now.sorted().joined(separator: "|"))
            }
            return ok(n)
        }
    }

    static func single(_ dir: String) -> SelfTestResult {
        let n = "ops-rename-single"
        // Sets off: only the named file moves.
        switch FileOperations.rename(dir + "/smith_1.JPG", to: "alone.JPG", sets: false) {
        case .failure(let f): return fail(n, f.message)
        case .success:
            let now = names(dir)
            guard now.contains("alone.JPG"), now.contains("smith_1.CR3"), now.contains("smith_1.xmp") else {
                return fail(n, now.sorted().joined(separator: "|"))
            }
            if case .success = FileOperations.rename(dir + "/alone.JPG", to: "a/b.JPG", sets: false) { return fail(n, "slash accepted") }
            return ok(n)
        }
    }

    static func newFolder(_ dir: String) -> SelfTestResult {
        let n = "ops-new-folder"
        guard case .success(let a) = FileOperations.newFolder(in: dir),
            case .success(let b) = FileOperations.newFolder(in: dir) else { return fail(n, "create failed") }
        guard Paths.name(a) == "untitled folder", Paths.name(b) == "untitled folder 2" else { return fail(n, "\(a) \(b)") }
        if FileOperations.removeNewFolder(a) != nil { return fail(n, "empty folder not removed") }
        return ok(n)
    }

    static func trash(_ dir: String) -> SelfTestResult {
        let n = "ops-trash-putback"
        let r = FileOperations.trash([dir + "/IMG_2.CR3"], sets: true)
        if r.done.isEmpty {
            return SelfTestResult(name: n, status: .skip, detail: "no Trash here: \(r.failures.first ?? "")")
        }
        guard !exists(dir + "/IMG_2.CR3"), r.done.count == 1 else { return fail(n, "not moved") }
        let back = FileOperations.putBack(r.done)
        guard back.isEmpty, exists(dir + "/IMG_2.CR3") else { return fail(n, "put back: \(back.joined(separator: ", "))") }
        // A set goes to the Trash together, the PSD stays.
        let s = FileOperations.trash([dir + "/smith_1.CR3"], sets: true)
        guard s.done.count == 2, exists(dir + "/IMG_1.psd") else { return fail(n, "set trash moved \(s.done.count)") }
        _ = FileOperations.putBack(s.done)
        return exists(dir + "/smith_1.CR3") ? ok(n) : fail(n, "set not put back")
    }

    static func journal(_ dir: String) -> SelfTestResult {
        let n = "ops-journal-recovery"
        // As if PhotoLab stopped right after renaming IMG_2.CR3 -> half.CR3.
        guard case .success = FileOperations.applyRenames([(dir + "/IMG_2.CR3", dir + "/half.CR3")], what: "test") else {
            return fail(n, "setup")
        }
        AppFiles.writeTestJournal(from: dir + "/IMG_2.CR3", to: dir + "/half.CR3")
        _ = FileOperations.recoverJournal()
        guard exists(dir + "/IMG_2.CR3"), !exists(dir + "/half.CR3"), AppFiles.readJournal() == nil else {
            return fail(n, names(dir).sorted().joined(separator: "|"))
        }
        return ok(n)
    }
}
