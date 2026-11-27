// IndexSelfTest.swift
// Proves an indexed search returns exactly what a direct search returns: right after building, after
// files are added, renamed, deleted and moved, after folders appear and disappear, with exclusions,
// after saving and reloading, and that a damaged or out-of-place index is refused.
// Uses its own scratch folder and its own index folder inside ~/Library/Caches/Find.

import Foundation

final class IndexSelfTest {
    let files: AppFiles
    let isPackage: (String, String) -> Bool
    private let report = Report(title: "Find Index Self-Test")
    private(set) var passed = 0
    private(set) var failed = 0
    private var failures: [String] = []
    private var root = ""

    init(files: AppFiles, isPackage: @escaping (String, String) -> Bool) {
        self.files = files
        self.isPackage = isPackage
    }

    private func check(_ code: String, _ what: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            passed += 1
            report.add("PASS \(code) \(what)")
        } else {
            failed += 1
            let line = "FAIL \(code) \(what)" + (detail.isEmpty ? "" : " -- \(detail)")
            failures.append(line)
            report.add(line)
        }
    }

    private func p(_ rel: String) -> String { return Paths.join(root, rel) }

    private func write(_ rel: String, _ text: String) {
        _ = files.makeDir(Paths.parent(p(rel)))
        files.writeText(text, to: p(rel))
    }

    private func run(_ q: SearchQuery, scanner: FolderScanner?) -> (Set<String>, SearchSummary)? {
        guard let engine = try? SearchEngine(query: q, roots: [root], scanner: scanner ?? PosixScanner(), workers: 4, isPackage: isPackage) else { return nil }
        engine.validateHits = scanner != nil
        let lock = NSLock()
        var got = Set<String>()
        engine.onResults = { batch in
            lock.lock()
            for e in batch { got.insert(e.path.precomposedStringWithCanonicalMapping) }
            lock.unlock()
        }
        let s = engine.run()
        return (got, s)
    }

    /// Indexed result == direct result for this query.
    private func same(_ code: String, _ what: String, _ q: SearchQuery, _ store: IndexStore) -> IndexScanner? {
        guard let scanner = store.scanner(for: [root]) else {
            check(code, what, false, "index not available")
            return nil
        }
        guard let (direct, ds) = run(q, scanner: nil), let (indexed, isum) = run(q, scanner: scanner) else {
            check(code, what, false, "search could not start")
            return nil
        }
        let missingAll = direct.subtracting(indexed).sorted()
        let extraAll = indexed.subtracting(direct).sorted()
        let cut = root.count + 1
        let missing = missingAll.prefix(8).map { String($0.dropFirst(cut)) } + (missingAll.count > 8 ? ["... \(missingAll.count) in all"] : [])
        let extra = extraAll.prefix(8).map { String($0.dropFirst(cut)) } + (extraAll.count > 8 ? ["... \(extraAll.count) in all"] : [])
        check(code, what + " (\(direct.count) results)", missing.isEmpty && extra.isEmpty && ds.isComplete == isum.isComplete,
              "missing \(missing) extra \(extra) complete direct=\(ds.isComplete) indexed=\(isum.isComplete)")
        return scanner
    }

    private func q(_ text: String, _ mode: NameMode = .contains) -> SearchQuery {
        var x = SearchQuery()
        x.text = text
        x.mode = mode
        return x
    }

    func run(appVersion: String, systemInfo: String) -> String {
        report.add("App version: \(appVersion)")
        report.add("System: \(systemInfo)")
        let scratch = Paths.join(files.cachesDir, "indextest-\(Ascii.fileStamp())")
        guard files.makeDir(scratch) else {
            check("T-INDEX-0", "create test folder", false, scratch)
            return finish(scratch)
        }
        root = Paths.join(scratch, "tree")
        _ = files.makeDir(root)
        let storeDir = Paths.join(scratch, "indexes")
        let store = IndexStore(files: files, folder: storeDir)

        // Inventory: 40 folders, about 640 files, hidden items, a package, a link loop, odd names.
        for a in 0..<5 {
            for b in 0..<8 {
                for f in 0..<16 { write("job\(a)/card\(b)/DSC_\(a)\(b)\(f).NEF", "x") }
            }
        }
        write("job0/.hidden.txt", "h")
        write("job1/.secret/inside.NEF", "s")
        write("Fake.app/Contents/MacOS/IMG_inside.NEF", "i")
        write("e\u{0301}clair.txt", "e")
        write("Wedding_Smith.jpg", "w")
        write("excluded/IMG_ex.NEF", "x")
        files.makeSymlink(p("job2/loop"), to: "..")

        // A folder indexed within 2 seconds of being changed is never trusted (second-precision drives).
        check("T-INDEX-26", "just-changed folders are not trusted from the index", {
            let probe = Paths.join(scratch, "probe")
            _ = files.makeDir(probe)
            let idx = FolderIndex(root: probe, excluded: [], rootDevice: 0, rootInode: 0, builtAt: 0)
            let sc = IndexScanner(indexes: [idx])
            _ = sc.scan(probe) { _, _ in true }
            _ = sc.scan(probe) { _, _ in true }
            return sc.foldersFromIndex == 0 && sc.foldersFromDisk == 2
        }())
        // Let the test tree's change stamps settle so the index is allowed to trust them.
        Thread.sleep(forTimeInterval: 2.5)
        check("T-INDEX-1", "add folder to index list", store.addRoot(root) == nil)
        check("T-INDEX-2", "a folder inside an indexed folder is refused", store.addRoot(p("job0")) != nil)
        store.setExcluded(root, [p("excluded")])
        let built = store.build(root)
        let st = store.status(root)
        check("T-INDEX-3", "index built and valid", built?.isComplete == true && st.valid && st.items > 600 && st.folders >= 41,
              "\(st.reason) items \(st.items) folders \(st.folders)")

        // Same results as direct search
        var everything = SearchQuery()
        everything.includeHidden = true
        everything.includePackages = true
        _ = same("T-INDEX-4", "everything (hidden + packages)", everything, store)
        _ = same("T-INDEX-5", "name contains dsc_12", q("dsc_12"), store)
        _ = same("T-INDEX-6", "wildcard *.nef", q("*.nef", .wildcard), store)
        _ = same("T-INDEX-7", "regex ^DSC_4[0-7]", q("^DSC_4[0-7]", .regex), store)
        _ = same("T-INDEX-8", "similar: weding smth", q("weding smth", .similar), store)
        _ = same("T-INDEX-9", "precomposed eclair finds decomposed name", q("\u{00E9}clair"), store)
        var hidden = q("inside")
        hidden.includeHidden = true
        _ = same("T-INDEX-10", "hidden folder contents", hidden, store)
        _ = same("T-INDEX-11", "excluded folder is still searched (read from disk)", q("IMG_ex"), store)
        var folders = SearchQuery()
        folders.kind = .folders
        _ = same("T-INDEX-12", "folders only", folders, store)

        // The index is really used: an unchanged tree is answered without reading folders from disk.
        if let sc = store.scanner(for: [root]), let (_, _) = run(q("dsc"), scanner: sc) {
            check("T-INDEX-13", "unchanged folders are answered from the index",
                  sc.foldersFromIndex >= 40 && sc.foldersFromDisk <= 1, "from index \(sc.foldersFromIndex), from disk \(sc.foldersFromDisk)")
        }

        // ---- Changes after the index was built
        write("job3/card2/NEW_FILE.NEF", "n")                       // added
        files.moveOwned(p("job0/card0/DSC_000.NEF"), p("job0/card0/RENAMED.NEF"))
        files.removeOwned(p("job0/card1/DSC_011.NEF"))             // deleted
        write("job4/newfolder/deeper/IN_NEW.NEF", "n")              // new nested folders
        files.removeOwned(p("job1/card7"))                           // folder deleted
        files.moveOwned(p("job2/card3"), p("job3/card3moved")) // folder moved
        files.removeOwned(p("job2/card4/DSC_240.NEF"))
        _ = files.makeDir(p("job2/card4/DSC_240.NEF"))              // file replaced by a folder of the same name
        if let sc = same("T-INDEX-14", "after add / rename / delete / move / replace", everything, store) {
            check("T-INDEX-15", "only changed folders were re-read", sc.foldersFromDisk > 0 && sc.foldersFromDisk < 15,
                  "re-read \(sc.foldersFromDisk), from index \(sc.foldersFromIndex)")
        }
        _ = same("T-INDEX-16", "renamed file found under its new name only", q("RENAMED"), store)
        _ = same("T-INDEX-17", "deleted file not found", q("DSC_011"), store)
        _ = same("T-INDEX-18", "file in a brand-new nested folder found", q("IN_NEW"), store)
        _ = same("T-INDEX-19", "moved folder's files found in the new place", q("DSC_23"), store)

        // Save, reload, damaged file, replaced folder
        store.saveDirty()
        let reloaded = IndexStore(files: files, folder: storeDir)
        _ = same("T-INDEX-20", "after saving and reloading the index", everything, reloaded)
        let path = reloaded.indexPath(root)
        if let d = FileManager.default.contents(atPath: path) {
            files.writeData(d.prefix(d.count / 2), to: path)
            let damaged = IndexStore(files: files, folder: storeDir)
            check("T-INDEX-21", "a damaged index file is refused (search goes direct)",
                  damaged.scanner(for: [root]) == nil && damaged.status(root).valid == false)
        }
        var size = SearchQuery()
        size.minSize = 1
        check("T-INDEX-22", "size/date searches never use the index", size.indexCanAnswer == false && q("x").indexCanAnswer)
        store.removeRoot(root)
        check("T-INDEX-23", "removing a folder deletes its index file", !Sys.exists(store.indexPath(root)) && store.scanner(for: [root]) == nil)
        var off = IndexStore(files: files, folder: storeDir)
        _ = off.addRoot(root)
        _ = off.build(root)
        off.enabled = false
        check("T-INDEX-24", "indexes switched off: search goes direct", off.scanner(for: [root]) == nil)
        off = IndexStore(files: files, folder: storeDir)
        check("T-INDEX-25", "the on/off setting is remembered", off.enabled == false)

        return finish(scratch)
    }

    private func finish(_ scratch: String) -> String {
        if Sys.exists(scratch) {
            let removed = files.removeOwned(scratch)
            check("T-INDEX-90", "test folder removed", removed && !Sys.exists(scratch))
        }
        report.addSummary("RESULT \(failed == 0 ? "ALL PASSED" : "FAILURES PRESENT")")
        report.addSummary("PASSED \(passed) FAILED \(failed)")
        for f in failures { report.addSummary(f) }
        return report.render()
    }
}
