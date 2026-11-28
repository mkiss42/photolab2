// SearchSelfTest.swift
// Builds a test folder with a known inventory (odd names, hidden items, nested folders, links, a package,
// an unreadable folder) inside Find's caches folder, runs searches, and compares every result with what
// must be found. Used by the Linux tests, by "Help > Run Search Self-Test" and by build.sh (--searchtest).

import Foundation

final class SearchSelfTest {
    let files: AppFiles
    let isPackage: (String, String) -> Bool
    private let report = Report(title: "PhotoLab Search Self-Test")
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
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

    private func skip(_ code: String, _ what: String, _ why: String) {
        skipped += 1
        report.add("SKIP \(code) \(what) -- \(why)")
    }

    private func p(_ rel: String) -> String { return Paths.join(root, rel) }

    /// Relative, NFC-normalized result paths.
    private func rel(_ entries: [FileEntry], base: String) -> Set<String> {
        var out = Set<String>()
        for e in entries {
            var r = e.path
            if r.hasPrefix(base + "/") { r = String(r.dropFirst(base.count + 1)) }
            out.insert(r.precomposedStringWithCanonicalMapping)
        }
        return out
    }

    /// Run one search synchronously; returns (results, summary).
    func search(_ q: SearchQuery, roots: [String], scanner: FolderScanner = PosixScanner(), cancelAfter: Int? = nil,
                rootCheck: ((String) -> Bool)? = nil) -> ([FileEntry], SearchSummary)? {
        guard let engine = try? SearchEngine(query: q, roots: roots, scanner: scanner, workers: 4, isPackage: isPackage) else { return nil }
        if let rc = rootCheck { engine.rootCheck = rc }
        let lock = NSLock()
        var results: [FileEntry] = []
        engine.onResults = { batch in
            lock.lock()
            results.append(contentsOf: batch)
            lock.unlock()
        }
        if cancelAfter != nil { engine.cancel() }
        let s = engine.run()
        lock.lock()
        let r = results
        lock.unlock()
        return (r, s)
    }

    private func expect(_ code: String, _ what: String, _ q: SearchQuery, _ expected: Set<String>, complete: Bool? = nil) {
        guard let (res, sum) = search(q, roots: [root]) else {
            check(code, what, false, "search could not start")
            return
        }
        let got = rel(res, base: root)
        var ok = got == expected
        var detail = ""
        if !ok {
            let missing = expected.subtracting(got).sorted().joined(separator: ", ")
            let extra = got.subtracting(expected).sorted().joined(separator: ", ")
            detail = "missing [\(missing)] unexpected [\(extra)]"
        }
        if let c = complete, sum.isComplete != c {
            ok = false
            detail += " completeness expected \(c) got \(sum.isComplete): \(sum.statusLine)"
        }
        if sum.matches != res.count {
            ok = false
            detail += " match count \(sum.matches) but \(res.count) results delivered"
        }
        check(code, what, ok, detail)
    }

    private func q(_ text: String, _ mode: NameMode = .contains, cs: Bool = false) -> SearchQuery {
        var x = SearchQuery()
        x.text = text
        x.mode = mode
        x.caseSensitive = cs
        return x
    }

    func run(appVersion: String, systemInfo: String) -> String {
        report.add("App version: \(appVersion)")
        report.add("System: \(systemInfo)")
        let scratch = Paths.join(files.cachesDir, "searchtest-\(Ascii.fileStamp())")
        guard files.makeDir(scratch) else {
            check("T-SEARCH-0", "create test folder", false, scratch)
            return finish(scratch)
        }
        root = Paths.join(scratch, "tree")
        _ = files.makeDir(root)
        report.add("Test folder: \(root)")

        // ---- Build the known inventory
        let fileList: [(String, String)] = [
            ("IMG_1.NEF", String(repeating: "n", count: 100)),
            ("img_2.jpg", String(repeating: "j", count: 2000)),
            ("Images/IMG_10.NEF", "x"),
            ("Images/notes.txt", "notes"),
            ("deep/a/b/c/IMG_3.dng", "d"),
            ("noext", "n"),
            ("Makefile", "m"),
            (".hidden.txt", "h"),
            (".secret/inside.txt", "s"),
            ("e\u{0301}clair.txt", "decomposed name"),
            ("trailing space .txt", "t"),
            ("  leading.txt", "l"),
            ("quote\"s.txt", "q"),
            ("star*name.txt", "s"),
            ("question?.txt", "q"),
            ("emoji \u{1F4F7}.png", "e"),
            ("UPPER.TXT", "u"),
            ("Fake.app/Contents/Info.plist", "plist"),
            ("Fake.app/Contents/MacOS/IMG_inside.NEF", "i"),
            ("old.txt", "old"),
            ("big.bin", String(repeating: "b", count: 300_000)),
            ("Wedding_Smith_2024.jpg", "w"),
            ("Caf\u{00E9} menu.pdf", "c"),
            ("cut.txt", "c"),
        ]
        for (rp, content) in fileList {
            _ = files.makeDir(Paths.parent(p(rp)))
            files.writeText(content, to: p(rp))
        }
        files.makeSymlink(p("deep/a/loop"), to: "..")
        files.makeSymlink(p("linkfile"), to: "IMG_1.NEF")
        files.setDates(p("old.txt"), modified: Date(timeIntervalSince1970: 946_684_800)) // 2000-01-01

        let built = fileList.filter { Sys.exists(p($0.0)) }.count
        check("T-SEARCH-1", "test inventory created (\(fileList.count) files, links, package)", built == fileList.count &&
              Sys.exists(p("deep/a/loop")) && Sys.exists(p("linkfile")), "\(built) of \(fileList.count)")

        // ---- Name searches
        expect("T-SEARCH-2", "contains \"img\", any case", q("img"),
               ["IMG_1.NEF", "img_2.jpg", "Images/IMG_10.NEF", "deep/a/b/c/IMG_3.dng"], complete: true)
        expect("T-SEARCH-3", "contains \"IMG\", case-sensitive", q("IMG", cs: true),
               ["IMG_1.NEF", "Images/IMG_10.NEF", "deep/a/b/c/IMG_3.dng"])
        expect("T-SEARCH-4", "name is \"NOTES.TXT\" (any case)", q("NOTES.TXT", .exact), ["Images/notes.txt"])
        expect("T-SEARCH-5", "wildcard *.nef", q("*.nef", .wildcard), ["IMG_1.NEF", "Images/IMG_10.NEF"])
        expect("T-SEARCH-6", "wildcard img_?.jpg", q("img_?.jpg", .wildcard), ["img_2.jpg"])
        expect("T-SEARCH-7", "regular expression ^img_[0-9]+\\.(nef|dng)$", q("^img_[0-9]+\\.(nef|dng)$", .regex),
               ["IMG_1.NEF", "Images/IMG_10.NEF", "deep/a/b/c/IMG_3.dng"])
        expect("T-SEARCH-8", "begins with two spaces", q("  ", .beginsWith), ["  leading.txt"])
        expect("T-SEARCH-9", "ends with \" .txt\" (space before dot)", q(" .txt", .endsWith), ["trailing space .txt"])
        expect("T-SEARCH-10", "contains * (literal)", q("*"), ["star*name.txt"])
        expect("T-SEARCH-11", "contains ? (literal)", q("?"), ["question?.txt"])
        expect("T-SEARCH-12", "contains a double quote", q("\""), ["quote\"s.txt"])
        expect("T-SEARCH-13", "contains an emoji", q("\u{1F4F7}"), ["emoji \u{1F4F7}.png"])
        expect("T-SEARCH-14", "precomposed \"\u{00E9}clair\" finds a decomposed file name", q("\u{00E9}clair"), ["\u{00E9}clair.txt"])
        expect("T-SEARCH-36", "folder names are matched too (\"imag\" finds Images)", q("imag"), ["Images"])
        expect("T-SEARCH-15", "contains \"upper\" (lower-case search, upper-case name)", q("upper"), ["UPPER.TXT"])

        // ---- Other criteria
        var ext = SearchQuery()
        ext.extensions = SearchQuery.parseExtensions("nef, .DNG")
        expect("T-SEARCH-16", "extension nef or dng", ext, ["IMG_1.NEF", "Images/IMG_10.NEF", "deep/a/b/c/IMG_3.dng"])
        var folders = SearchQuery()
        folders.kind = .folders
        expect("T-SEARCH-17", "folders only", folders, ["Images", "deep", "deep/a", "deep/a/b", "deep/a/b/c", "Fake.app"])
        var size = SearchQuery()
        size.minSize = 250_000
        expect("T-SEARCH-18", "size at least 250 KB", size, ["big.bin"])
        var date = SearchQuery()
        date.modifiedBefore = 978_307_200 // 2001-01-01
        expect("T-SEARCH-19", "modified before 2001", date, ["old.txt"])
        var any = q("notes")
        any.extensions = ["dng"]
        any.matchAll = false
        expect("T-SEARCH-20", "match ANY: name contains notes OR extension dng", any, ["Images/notes.txt", "deep/a/b/c/IMG_3.dng"])
        var top = q("img")
        top.recursive = false
        expect("T-SEARCH-21", "top level only", top, ["IMG_1.NEF", "img_2.jpg"])
        var noext = SearchQuery()
        noext.kind = .files
        noext.text = "e"
        noext.mode = .endsWith
        noext.caseSensitive = true
        expect("T-SEARCH-22", "files and links whose names end in e (no extension)", noext, ["Makefile", "linkfile"])

        // ---- Similar names (allows typos)
        expect("T-SEARCH-40", "similar: \"weding\" (missing letter) finds Wedding_Smith", q("weding", .similar), ["Wedding_Smith_2024.jpg"])
        expect("T-SEARCH-41", "similar: \"smtih weding\" (swapped letters, words in any order)", q("smtih weding", .similar), ["Wedding_Smith_2024.jpg"])
        expect("T-SEARCH-42", "similar: \"cafe menu\" ignores the accent", q("cafe menu", .similar), ["Caf\u{00E9} menu.pdf"])
        expect("T-SEARCH-43", "similar: short words must match exactly (\"cat\" does not find cut.txt)", q("cat", .similar), [])
        expect("T-SEARCH-44", "similar: unrelated text finds nothing", q("xylophone", .similar), [])
        if let (res, _) = search(q("weding smith", .similar), roots: [root]), let hit = res.first {
            check("T-SEARCH-45", "similar: match score counts mistakes (1)", res.count == 1 && hit.matchDistance == 1, "score \(hit.matchDistance)")
        } else {
            check("T-SEARCH-45", "similar: match score", false, "no result")
        }

        // ---- Hidden, packages, links
        expect("T-SEARCH-23", "hidden files excluded when off", q("hidden"), [])
        var hid = q("hidden")
        hid.includeHidden = true
        expect("T-SEARCH-24", "hidden files found when on", hid, [".hidden.txt"])
        var inside = q("inside")
        inside.includeHidden = true
        expect("T-SEARCH-25", "inside a hidden folder when hidden is on", inside, [".secret/inside.txt"])
        if let (_, s) = search(q("inside"), roots: [root]) {
            check("T-SEARCH-26", "hidden folder counted as skipped when hidden is off",
                  (s.skipped.first(where: { $0.key.hasPrefix("hidden folder") })?.value ?? 0) == 1 && s.hiddenItemsIgnored == 1,
                  "\(s.skipped) hidden items \(s.hiddenItemsIgnored)")
        }
        expect("T-SEARCH-27", "package contents not searched when off", q("IMG_inside"), [])
        var pkg = q("IMG_inside")
        pkg.includePackages = true
        expect("T-SEARCH-28", "package contents searched when on", pkg, ["Fake.app/Contents/MacOS/IMG_inside.NEF"])
        if let (_, s) = search(q("x"), roots: [root]) {
            check("T-SEARCH-29", "package and link-to-folder skips are counted",
                  s.skipped.keys.contains(where: { $0.hasPrefix("inside packages") }) &&
                  s.skipped.keys.contains(where: { $0.hasPrefix("symbolic link to a folder") }), "\(s.skipped)")
        }
        var loop = SearchQuery()
        loop.followLinks = true
        if let (res, s) = search(loop, roots: [p("deep")]) {
            check("T-SEARCH-30", "following a link loop ends, nothing listed twice",
                  res.count < 50 && s.skipped.keys.contains(where: { $0.contains("link loop") }) && s.isComplete,
                  "\(res.count) results, \(s.skipped)")
        }

        // ---- Inventory: everything, compared with an independent walk
        var all = SearchQuery()
        all.includeHidden = true
        all.includePackages = true
        if let (res, s) = search(all, roots: [root]) {
            let inv = independentInventory(root)
            let got = rel(res, base: root)
            let missing = inv.subtracting(got)
            let extra = got.subtracting(inv)
            check("T-SEARCH-31", "everything search equals an independent inventory (\(inv.count) items)",
                  missing.isEmpty && extra.isEmpty && s.isComplete,
                  "missing \(missing.sorted()) extra \(extra.sorted())")
        }

        // ---- Completeness reporting
        if let (res, s) = search(q("img"), roots: [p("does-not-exist")]) {
            check("T-SEARCH-32", "missing location: reported UNAVAILABLE, not complete, no results",
                  res.isEmpty && !s.isComplete && s.failed.count == 1 && s.outcome == .unavailable && s.statusLine.hasPrefix("UNAVAILABLE"), s.statusLine)
        }
        let failing = FailingScanner(failPath: p("Images"))
        if let (res, s) = search(q("img"), roots: [root], scanner: failing) {
            let got = rel(res, base: root)
            check("T-SEARCH-33", "unreadable folder (simulated): listed, search INCOMPLETE, other results kept",
                  !s.isComplete && s.failed.contains(where: { $0.path == p("Images") }) && got.contains("IMG_1.NEF") && !got.contains("Images/IMG_10.NEF"),
                  s.statusLine)
        }
        if let (_, s) = search(SearchQuery(), roots: [root], cancelAfter: 0) {
            check("T-SEARCH-34", "stopped search is never reported complete", !s.isComplete && s.cancelled && s.statusLine.hasPrefix("STOPPED"), s.statusLine)
        }
        // Network states (Phase 6), simulated: a share whose connection drops in the middle of a search.
        let lost = FailingScanner(failPath: p("Images"), code: ENOTCONN, under: true)
        if let (res, s) = search(q("img"), roots: [root], scanner: lost, rootCheck: { _ in false }) {
            check("T-SEARCH-36", "connection lost during a search: INTERRUPTED, never complete, results so far kept, folders left counted",
                  s.outcome == .interrupted && !s.isComplete && s.disconnectedRoots == [root] && s.notSearchedBecauseDisconnected >= 1
                    && s.statusLine.hasPrefix("INTERRUPTED") && rel(res, base: root).contains("IMG_1.NEF"), s.statusLine)
        }
        if let (_, s) = search(q("img"), roots: [root], scanner: lost, rootCheck: { _ in true }) {
            check("T-SEARCH-37", "one folder fails but the share is still there: INCOMPLETE (not reported as disconnected)",
                  s.outcome == .partial && s.disconnectedRoots.isEmpty && s.failed.contains(where: { $0.path == p("Images") }), s.statusLine)
        }
        let denied = FailingScanner(failPath: p("Images"), code: EACCES, under: false)
        if let (_, s) = search(q("img"), roots: [root], scanner: denied) {
            check("T-SEARCH-38", "only permission problems: INCOMPLETE - PERMISSION", s.outcome == .restricted && s.statusLine.hasPrefix("INCOMPLETE (permission)"), s.statusLine)
        }

        // Real permission test (not possible when running as root)
        _ = files.makeDir(p("locked"))
        files.writeText("secret", to: p("locked/secret.txt"))
        files.setPermissions(p("locked"), 0o000)
        let stillReadable = (try? FileManager.default.contentsOfDirectory(atPath: p("locked"))) != nil
        if stillReadable {
            skip("T-SEARCH-35", "real unreadable folder", "running with full privileges, folder stays readable")
        } else if let (_, s) = search(q("secret"), roots: [root]) {
            check("T-SEARCH-35", "real unreadable folder: listed with reason, search INCOMPLETE",
                  !s.isComplete && s.failed.contains(where: { $0.path == p("locked") }), s.statusLine)
        }
        files.setPermissions(p("locked"), 0o755)

        return finish(scratch)
    }

    /// Independent walk using FileManager (a different code path from the engine's readdir/lstat).
    private func independentInventory(_ base: String) -> Set<String> {
        var out = Set<String>()
        func walk(_ dir: String, _ relDir: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for n in names {
                let full = Paths.join(dir, n)
                let r = relDir.isEmpty ? n : relDir + "/" + n
                out.insert(r.precomposedStringWithCanonicalMapping)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                    let t = attrs[.type] as? FileAttributeType, t == .typeDirectory {
                    walk(full, r)
                }
            }
        }
        walk(base, "")
        return out
    }

    private func finish(_ scratch: String) -> String {
        if Sys.exists(scratch) {
            files.setPermissions(Paths.join(root, "locked"), 0o755)
            let removed = files.removeOwned(scratch)
            check("T-SEARCH-90", "test folder removed", removed && !Sys.exists(scratch))
        }
        report.addSummary("RESULT \(failed == 0 ? "ALL PASSED" : "FAILURES PRESENT")")
        report.addSummary("PASSED \(passed) FAILED \(failed) SKIPPED \(skipped)")
        for f in failures { report.addSummary(f) }
        return report.render()
    }
}

/// Test scanner: behaves like PosixScanner but reports one folder (or a whole subtree) as unreadable.
final class FailingScanner: FolderScanner {
    let failPath: String
    let code: Int32
    let under: Bool
    let real = PosixScanner()

    init(failPath: String, code: Int32 = EACCES, under: Bool = false) {
        self.failPath = failPath
        self.code = code
        self.under = under
    }

    func scan(_ dir: String, _ visit: (String, StatInfo) -> Bool) -> ScanOutcome {
        if dir == failPath || (under && Paths.isInside(dir, root: failPath)) {
            var o = ScanOutcome()
            o.folderError = ReadProblem(path: dir, code: code, reason: Sys.errorText(code) + " (simulated)")
            return o
        }
        return real.scan(dir, visit)
    }
}

/// Package test used on Linux (no LaunchServices): a folder with one of these extensions is a package.
func basicPackageCheck(_ path: String, _ ext: String) -> Bool {
    return ["app", "bundle", "framework", "plugin", "photoslibrary", "aplibrary", "fcpbundle", "rtfd", "pages", "key", "numbers", "kext", "pkg", "xcodeproj"].contains(ext)
}
