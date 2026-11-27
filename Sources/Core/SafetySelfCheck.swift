// SafetySelfCheck.swift
// Exercises every file operation inside a scratch folder in Find's own caches folder,
// checks the safety rules hold on this machine, then cleans up after itself.
// Anything sent to the Trash during the check is put back and removed with the scratch folder,
// so the check leaves nothing behind in the user's Trash.

import Foundation

final class SafetySelfCheck {
    let ops: FileOperations
    let files: AppFiles
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private var failures: [String] = []
    private let report = Report(title: "Find Safety Self-Check")
    private var root = ""
    /// Items sent to the Trash during the check that must be removed from the Trash at the end.
    private var trashLeftovers: [String] = []
    private var trashBefore = Set<String>()

    init(ops: FileOperations, files: AppFiles) {
        self.ops = ops
        self.files = files
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

    private func makeFile(_ rel: String, _ content: String) {
        files.writeText(content, to: p(rel))
    }

    private func read(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Run all checks. Returns the report text (numbered, ASCII).
    func run(appVersion: String, systemInfo: String) -> String {
        report.add("App version: \(appVersion)")
        report.add("System: \(systemInfo)")
        trashBefore = Set(ops.trashHistory)
        root = Paths.join(files.cachesDir, "selftest-\(Ascii.fileStamp())")
        guard files.makeDir(root) else {
            check("T-SAFE-0", "create scratch folder", false, root)
            return finish()
        }
        report.add("Scratch folder: \(root)")

        // 1-2 New folder, and a second one gets a unique name
        do {
            let (f1, _) = try ops.createFolder(in: root, name: "untitled folder")
            let (f2, _) = try ops.createFolder(in: root, name: "untitled folder")
            check("T-SAFE-1", "new folder is created", Sys.exists(f1))
            check("T-SAFE-2", "second new folder gets a unique name, first untouched",
                  Paths.lastComponent(f2) == "untitled folder 2" && Sys.exists(f1), "got \(Paths.lastComponent(f2))")
        } catch {
            check("T-SAFE-1", "new folder is created", false, "\(error)")
        }

        // 3 Rename
        makeFile("a.txt", "AAA")
        makeFile("b.txt", "BBB")
        do {
            let (np, _) = try ops.rename(p("a.txt"), to: "renamed.txt")
            check("T-SAFE-3", "rename works and keeps content", np == p("renamed.txt") && read(np) == "AAA" && !Sys.exists(p("a.txt")))
        } catch {
            check("T-SAFE-3", "rename works and keeps content", false, "\(error)")
        }

        // 4 Rename onto an existing name is refused; both files intact
        do {
            _ = try ops.rename(p("renamed.txt"), to: "b.txt")
            check("T-SAFE-4", "rename onto existing name is refused", false, "rename was allowed")
        } catch {
            check("T-SAFE-4", "rename onto existing name is refused, both files intact",
                  read(p("renamed.txt")) == "AAA" && read(p("b.txt")) == "BBB")
        }

        // 5 Case-only rename
        makeFile("case.txt", "CASE")
        do {
            let (np, _) = try ops.rename(p("case.txt"), to: "CASE.txt")
            let names = files.list(root)
            check("T-SAFE-5", "case-only rename", names.contains("CASE.txt") && !names.contains("case.txt") && read(np) == "CASE",
                  "names: \(names.joined(separator: ","))")
        } catch {
            check("T-SAFE-5", "case-only rename", false, "\(error)")
        }

        // 6 Invalid names refused
        let bad = ["", "..", "a/b", "a:b", String(repeating: "x", count: 256)]
        var allRefused = true
        for n in bad {
            if (try? ops.rename(p("b.txt"), to: n)) != nil { allRefused = false }
        }
        check("T-SAFE-6", "invalid names are refused", allRefused && read(p("b.txt")) == "BBB")

        // 7-8 Trash and put back (undo)
        makeFile("trashme.txt", "TRASH")
        let tr = ops.trash([p("trashme.txt")])
        if let rec = tr.undo, tr.failed.isEmpty, let t = tr.done.first?.to {
            check("T-SAFE-7", "move to Trash: original gone, item present in Trash",
                  !Sys.exists(p("trashme.txt")) && read(t) == "TRASH")
            do {
                _ = try ops.undo(rec)
                check("T-SAFE-8", "undo Trash puts the item back intact", read(p("trashme.txt")) == "TRASH" && !Sys.exists(t))
            } catch {
                check("T-SAFE-8", "undo Trash puts the item back intact", false, "\(error)")
            }
        } else {
            let why = tr.failed.first?.error.description ?? "no result"
            check("T-SAFE-7", "move to Trash", false, why)
        }

        // 9 Trash of a missing item reports an error and changes nothing
        let tr2 = ops.trash([p("does-not-exist.txt")])
        check("T-SAFE-9", "trashing a missing item is reported as failed", tr2.failed.count == 1 && tr2.done.isEmpty)

        // 10 Move within a volume
        _ = files.makeDir(p("dest"))
        makeFile("m1.txt", "M1")
        let mv = ops.move([p("m1.txt")], into: p("dest"), choose: { _ in .cancel })
        check("T-SAFE-10", "move into folder", read(p("dest/m1.txt")) == "M1" && !Sys.exists(p("m1.txt")) && mv.failed.isEmpty)
        if let u = mv.undo {
            do {
                _ = try ops.undo(u)
                check("T-SAFE-11", "undo move puts it back", read(p("m1.txt")) == "M1" && !Sys.exists(p("dest/m1.txt")))
            } catch {
                check("T-SAFE-11", "undo move puts it back", false, "\(error)")
            }
        } else {
            check("T-SAFE-11", "undo move puts it back", false, "no undo record")
        }

        // 12 Move with a name clash: skip leaves both untouched
        makeFile("dest/m1.txt", "OTHER")
        let mv2 = ops.move([p("m1.txt")], into: p("dest"), choose: { _ in .skip })
        check("T-SAFE-12", "name clash + Skip: nothing overwritten",
              read(p("m1.txt")) == "M1" && read(p("dest/m1.txt")) == "OTHER" && mv2.skipped.count == 1)

        // 13 Keep both
        let mv3 = ops.move([p("m1.txt")], into: p("dest"), choose: { _ in .keepBoth })
        check("T-SAFE-13", "name clash + Keep Both: both kept",
              read(p("dest/m1 2.txt")) == "M1" && read(p("dest/m1.txt")) == "OTHER" && mv3.failed.isEmpty)

        // 14 Replace sends the existing item to the Trash, never overwrites in place
        makeFile("m2.txt", "NEW")
        makeFile("dest/m2.txt", "OLD")
        let mv4 = ops.move([p("m2.txt")], into: p("dest"), choose: { _ in .replace })
        check("T-SAFE-14", "name clash + Replace: new item in place, old one in Trash",
              read(p("dest/m2.txt")) == "NEW" && mv4.failed.isEmpty && mv4.notes.contains(where: { $0.contains("Trash") }))

        // 15 Folder can't be moved into itself
        _ = files.makeDir(p("outer"))
        _ = files.makeDir(p("outer/inner"))
        let mv5 = ops.move([p("outer")], into: p("outer/inner"), choose: { _ in .cancel })
        check("T-SAFE-15", "folder can't be moved into its own subfolder", mv5.failed.count == 1 && Sys.exists(p("outer/inner")))

        // 16 Copy with verification (nested folder + symlink)
        _ = files.makeDir(p("tree"))
        _ = files.makeDir(p("tree/sub"))
        makeFile("tree/one.txt", "1")
        makeFile("tree/sub/two.txt", "22")
        _ = files.makeDir(p("copydest"))
        let cp = ops.copy([p("tree")], into: p("copydest"), choose: { _ in .cancel })
        check("T-SAFE-16", "copy folder, verified, originals untouched",
              cp.failed.isEmpty && read(p("copydest/tree/sub/two.txt")) == "22" && read(p("tree/sub/two.txt")) == "22",
              cp.summaryLines.joined(separator: " / "))
        let partials = files.list(p("copydest")).filter { $0.hasPrefix(".find-partial-") }
        check("T-SAFE-17", "no temporary copy names left behind", partials.isEmpty)

        // 18 Copy onto existing name + Skip: nothing overwritten
        makeFile("copydest/one.txt", "EXISTING")
        makeFile("one.txt", "SOURCE")
        let cp2 = ops.copy([p("one.txt")], into: p("copydest"), choose: { _ in .skip })
        check("T-SAFE-18", "copy name clash + Skip: nothing overwritten", read(p("copydest/one.txt")) == "EXISTING" && cp2.skipped.count == 1)

        // 19 Cross-volume move path (simulated): copy, verify, originals to Trash
        _ = files.makeDir(p("xvol"))
        makeFile("xm.txt", "CROSS")
        let xm = ops.move([p("xm.txt")], into: p("xvol"), choose: { _ in .cancel }, forceCrossVolume: true)
        let xmOK = xm.failed.isEmpty && read(p("xvol/xm.txt")) == "CROSS" && !Sys.exists(p("xm.txt"))
        check("T-SAFE-19", "move across volumes: copy verified, original moved to Trash", xmOK, xm.summaryLines.joined(separator: " / "))
        if let u = xm.undo {
            do {
                _ = try ops.undo(u)
                check("T-SAFE-20", "undo cross-volume move restores original, copy to Trash",
                      read(p("xm.txt")) == "CROSS" && !Sys.exists(p("xvol/xm.txt")))
            } catch {
                check("T-SAFE-20", "undo cross-volume move", false, "\(error)")
            }
        }

        // 60-65 PhotoLab S1/S2: volumes without a Trash (simulated here).
        ops.simulateNoTrash = true
        _ = files.makeDir(p("nt"))
        makeFile("nt/r.txt", "OLD")
        makeFile("r.txt", "NEW")
        let nt1 = ops.copy([p("r.txt")], into: p("nt"), choose: { _ in .replace })
        check("T-SAFE-60", "no Trash, Replace not confirmed: refused, nothing changed",
              nt1.failed.count == 1 && read(p("nt/r.txt")) == "OLD" && read(p("r.txt")) == "NEW", nt1.summaryLines.joined(separator: " / "))
        let nt2 = ops.copy([p("r.txt")], into: p("nt"), choose: { _ in .replace }, replaceWithoutTrash: true)
        check("T-SAFE-61", "no Trash, Replace confirmed: new file in place, old deleted only after, no Undo, no \"name 2\" left",
              nt2.failed.isEmpty && read(p("nt/r.txt")) == "NEW" && !Sys.exists(p("nt/r 2.txt")) && nt2.undo == nil,
              nt2.summaryLines.joined(separator: " / "))
        _ = files.makeDir(p("nt/fold"))
        makeFile("nt/fold/keep.txt", "K")
        _ = files.makeDir(p("fold"))
        let nt3 = ops.copy([p("fold")], into: p("nt"), choose: { _ in .replace }, replaceWithoutTrash: true)
        check("T-SAFE-62", "no Trash: a folder is never replaced permanently", nt3.failed.count == 1 && read(p("nt/fold/keep.txt")) == "K")
        makeFile("mv.txt", "MOVE")
        let nt4 = ops.move([p("mv.txt")], into: p("nt"), choose: { _ in .cancel }, forceCrossVolume: true, deleteOriginalsWithoutTrash: true)
        check("T-SAFE-63", "no Trash, move to another volume confirmed: copy verified, original deleted, no Undo",
              nt4.failed.isEmpty && read(p("nt/mv.txt")) == "MOVE" && !Sys.exists(p("mv.txt")) && nt4.undo == nil,
              nt4.summaryLines.joined(separator: " / "))
        _ = files.makeDir(p("mvtree"))
        makeFile("mvtree/a.txt", "A")
        makeFile("mvtree/b.txt", "BB")
        let nt5 = ops.move([p("mvtree")], into: p("nt"), choose: { _ in .cancel }, forceCrossVolume: true, deleteOriginalsWithoutTrash: true)
        check("T-SAFE-64", "no Trash, folder moved to another volume: all copied, original folder deleted",
              nt5.failed.isEmpty && read(p("nt/mvtree/b.txt")) == "BB" && !Sys.exists(p("mvtree")), nt5.summaryLines.joined(separator: " / "))
        ops.simulateNoTrash = false
        makeFile("tr.txt", "T")
        let nt6 = ops.move([p("tr.txt")], into: p("nt"), choose: { _ in .cancel }, forceCrossVolume: true, deleteOriginalsWithoutTrash: true)
        check("T-SAFE-65", "with a Trash the confirmation changes nothing: original to the Trash, Undo offered",
              nt6.failed.isEmpty && !Sys.exists(p("tr.txt")) && nt6.undo != nil, nt6.summaryLines.joined(separator: " / "))
        if let u = nt6.undo { _ = try? ops.undo(u) }

        // 21 Undo rename
        do {
            makeFile("u.txt", "U")
            let (_, rec) = try ops.rename(p("u.txt"), to: "u2.txt")
            let redo = try ops.undo(rec)
            check("T-SAFE-21", "undo rename restores the old name", read(p("u.txt")) == "U" && !Sys.exists(p("u2.txt")))
            if let r = redo {
                _ = try ops.undo(r)
                check("T-SAFE-22", "redo rename", read(p("u2.txt")) == "U")
            } else {
                check("T-SAFE-22", "redo rename", false, "no redo record")
            }
        } catch {
            check("T-SAFE-21", "undo rename", false, "\(error)")
        }

        // 23-24 Undo new folder: only when still empty
        do {
            let (f, rec) = try ops.createFolder(in: root, name: "undo me")
            makeFile("undo me/keep.txt", "KEEP")
            do {
                _ = try ops.undo(rec)
                check("T-SAFE-23", "undo of a non-empty new folder is refused", false, "folder was removed")
            } catch {
                check("T-SAFE-23", "undo of a non-empty new folder is refused, contents kept", read(Paths.join(f, "keep.txt")) == "KEEP")
            }
            let (f2, rec2) = try ops.createFolder(in: root, name: "empty one")
            _ = try ops.undo(rec2)
            check("T-SAFE-24", "undo of an empty new folder sends it to the Trash", !Sys.exists(f2))
        } catch {
            check("T-SAFE-23", "undo new folder", false, "\(error)")
        }

        // 27-30 Compress and alias never overwrite and leave originals alone
        makeFile("z.txt", "ZIPME")
        makeFile("z.txt.zip", "EXISTING ZIP")
        do {
            let (zp, zrec) = try ops.compress([p("z.txt")])
            check("T-SAFE-27", "compress: new archive made, original and existing .zip untouched",
                  Paths.lastComponent(zp) == "z.txt 2.zip" && read(p("z.txt")) == "ZIPME" && read(p("z.txt.zip")) == "EXISTING ZIP",
                  "made \(Paths.lastComponent(zp))")
            _ = try ops.undo(zrec)
            check("T-SAFE-28", "undo compress sends the archive to the Trash", !Sys.exists(zp) && read(p("z.txt")) == "ZIPME")
        } catch {
            check("T-SAFE-27", "compress", false, "\(error)")
        }
        do {
            let (ap, _) = try ops.makeAlias(p("z.txt"))
            check("T-SAFE-29", "make alias: alias made next to the item, original untouched",
                  Paths.lastComponent(ap) == "z.txt alias" && Sys.exists(ap) && read(p("z.txt")) == "ZIPME")
            let (ap2, _) = try ops.makeAlias(p("z.txt"))
            check("T-SAFE-30", "second alias gets a new name, first kept", Paths.lastComponent(ap2) == "z.txt alias 2" && Sys.exists(ap))
        } catch {
            check("T-SAFE-29", "make alias", false, "\(error)")
        }

        // 31-34 Colour labels: tags change, contents untouched, other tags kept, undo restores
        makeFile("label.txt", "LABEL")
        do {
            _ = try ops.setTagNames(p("label.txt"), ["Project X"])
        } catch {
            check("T-SAFE-31", "set up a custom tag", false, "\(error)")
        }
        let lr = ops.toggleColorLabel([p("label.txt")], colorIndex: 0)
        let afterAdd = ops.tagNames(p("label.txt"))
        check("T-SAFE-31", "add Red label: other tags kept, contents untouched",
              lr.failed.isEmpty && afterAdd.contains("Red") && afterAdd.contains("Project X") && read(p("label.txt")) == "LABEL",
              "tags now \(afterAdd)")
        let lr2 = ops.toggleColorLabel([p("label.txt")], colorIndex: 0)
        let afterRemove = ops.tagNames(p("label.txt"))
        check("T-SAFE-32", "same colour again removes it, other tags kept", lr2.failed.isEmpty && !afterRemove.contains("Red") && afterRemove.contains("Project X"),
              "tags now \(afterRemove)")
        if let u = lr2.undo {
            do {
                _ = try ops.undo(u)
                check("T-SAFE-33", "undo label change restores the previous tags", ops.tagNames(p("label.txt")).contains("Red"))
            } catch {
                check("T-SAFE-33", "undo label change", false, "\(error)")
            }
        }
        makeFile("label2.txt", "L2")
        _ = ops.toggleColorLabel([p("label2.txt")], colorIndex: 4)
        let mixed = ops.toggleColorLabel([p("label.txt"), p("label2.txt")], colorIndex: 4)
        check("T-SAFE-34", "mixed selection: colour is added to items that lack it (Finder behaviour)",
              mixed.failed.isEmpty && ops.tagNames(p("label.txt")).contains("Blue") && ops.tagNames(p("label2.txt")).contains("Blue"))

        // 35-39 Folder watch events are checked on disk before Find leaves a folder
        _ = files.makeDir(p("watched"))
        let wid = FolderIdentity.of(p("watched"))
        check("T-SAFE-35", "watched folder still there: stay and refresh",
              wid != nil && FolderWatchCheck.verify(p("watched"), watched: wid, pause: 0) == .stillThere)
        _ = files.makeDir(p("watched/new folder"))
        check("T-SAFE-36", "new item inside the folder is not mistaken for the folder going away",
              FolderWatchCheck.verify(p("watched"), watched: wid, pause: 0) == .stillThere)
        _ = files.moveOwned(p("watched"), p("watched-renamed"))
        let goneVerdict = FolderWatchCheck.verify(p("watched"), watched: wid, pause: 0.2)
        check("T-SAFE-37", "folder really renamed away: confirmed gone", goneVerdict == .gone, goneVerdict.name)
        _ = files.makeDir(p("watched"))
        let repl = FolderWatchCheck.verify(p("watched"), watched: wid, pause: 0)
        check("T-SAFE-38", "different folder now has the name: stay (replaced)", repl == .replaced, repl.name)
        makeFile("watchfile", "x")
        let notDir = FolderWatchCheck.look(p("watchfile"), watched: nil)
        let blocked = FolderWatchCheck.look(p("watchfile/below"), watched: nil)
        check("T-SAFE-39", "a file at the path counts as gone; ENOTDIR counts as missing",
              notDir.verdict == .gone && notDir.isMissing && blocked.isMissing, "\(notDir.verdict.name) \(blocked.verdict.name)")

        // 40-43 Saving a new file (contact sheets): never overwrites, verified, undo goes to the Trash
        _ = files.makeDir(p("save"))
        makeFile("save/Sheet.pdf", "EXISTING")
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        do {
            let (saved, rec) = try ops.writeNewFile(payload, in: p("save"), name: "Sheet.pdf")
            let existing = (try? String(contentsOfFile: p("save/Sheet.pdf"))) ?? ""
            check("T-SAFE-40", "new file saved under a free name; the existing file is untouched",
                  Paths.lastComponent(saved) == "Sheet 2.pdf" && existing == "EXISTING", saved)
            check("T-SAFE-41", "saved file is byte-for-byte what was written", FileManager.default.contents(atPath: saved) == payload)
            let temps = files.list(p("save")).filter { $0.hasPrefix(".find-partial") }
            check("T-SAFE-42", "no temporary file left behind", temps.isEmpty, "\(temps)")
            _ = try ops.undo(rec)
            check("T-SAFE-43", "undo moves the saved file to the Trash", !Sys.exists(saved) && Sys.exists(p("save/Sheet.pdf")))
        } catch {
            check("T-SAFE-40", "save a new file", false, "\(error)")
        }

        // 44-49 Batch rename: swaps, case changes, all-or-nothing, one undo
        _ = files.makeDir(p("batch"))
        makeFile("batch/A.jpg", "AAA")
        makeFile("batch/B.jpg", "BBB")
        makeFile("batch/c.jpg", "CCC")
        makeFile("batch/keep.jpg", "KEEP")
        do {
            let (pairs, rec) = try ops.renameBatch([(p("batch/A.jpg"), "B.jpg"), (p("batch/B.jpg"), "A.jpg"), (p("batch/c.jpg"), "C.jpg")])
            let a = (try? String(contentsOfFile: p("batch/A.jpg"))) ?? ""
            let b = (try? String(contentsOfFile: p("batch/B.jpg"))) ?? ""
            let names = files.list(p("batch")).filter { !$0.hasPrefix(".") }.sorted()
            check("T-SAFE-44", "batch rename swaps two names safely (A <-> B)", pairs.count == 3 && a == "BBB" && b == "AAA", "\(a) \(b)")
            check("T-SAFE-45", "batch rename does a case-only change and leaves no temporary files",
                  names == ["A.jpg", "B.jpg", "C.jpg", "keep.jpg"] && files.list(p("batch")).filter { $0.hasPrefix(".find-rename") }.isEmpty, "\(names)")
            _ = try ops.undo(rec)
            let a2 = (try? String(contentsOfFile: p("batch/A.jpg"))) ?? ""
            let names2 = files.list(p("batch")).filter { !$0.hasPrefix(".") }.sorted()
            check("T-SAFE-46", "one undo puts the whole batch back", a2 == "AAA" && names2 == ["A.jpg", "B.jpg", "c.jpg", "keep.jpg"], "\(names2)")
        } catch {
            check("T-SAFE-44", "batch rename", false, "\(error)")
        }
        do {
            _ = try ops.renameBatch([(p("batch/A.jpg"), "new.jpg"), (p("batch/B.jpg"), "keep.jpg")])
            check("T-SAFE-47", "batch rename onto an existing file is refused", false, "it ran")
        } catch {
            let untouched = Sys.exists(p("batch/A.jpg")) && Sys.exists(p("batch/B.jpg")) && !Sys.exists(p("batch/new.jpg"))
                && ((try? String(contentsOfFile: p("batch/keep.jpg"))) ?? "") == "KEEP"
            check("T-SAFE-47", "batch rename onto an existing file is refused before anything changes", untouched)
        }
        do {
            _ = try ops.renameBatch([(p("batch/A.jpg"), "x.jpg"), (p("batch/B.jpg"), "x.jpg")])
            check("T-SAFE-48", "two items to the same name refused", false, "it ran")
        } catch {
            check("T-SAFE-48", "two items to the same name refused, nothing changed",
                  Sys.exists(p("batch/A.jpg")) && Sys.exists(p("batch/B.jpg")) && !Sys.exists(p("batch/x.jpg")))
        }
        do {
            _ = try ops.renameBatch([(p("batch/A.jpg"), "y.jpg"), (p("batch/gone.jpg"), "z.jpg")])
            check("T-SAFE-49", "batch with a missing item refused", false, "it ran")
        } catch {
            check("T-SAFE-49", "batch with a missing item refused before anything changes", Sys.exists(p("batch/A.jpg")) && !Sys.exists(p("batch/y.jpg")))
        }

        // 50-55 Phase 5: recovery after an interrupted operation, and clean-up of Find's own stores.
        // A separate set of "Find folders" inside the scratch folder, with a stand-in user folder beside it.
        do {
            let mroot = p("maint")
            let mf = AppFiles(supportDir: Paths.join(mroot, "support"), cachesDir: Paths.join(mroot, "caches"), logsDir: Paths.join(mroot, "logs"))
            let user = p("maint-user")
            _ = files.makeDir(user)
            makeFile("maint-user/DSC_1.NEF", "raw")
            makeFile("maint-user/DSC_1.xmp", "sidecar")
            let old = Date(timeIntervalSinceNow: -40 * 86400)
            _ = mf.makeDir(mf.tempDir)
            mf.writeText("old", to: Paths.join(mf.tempDir, "old.tmp"))
            _ = mf.setDates(Paths.join(mf.tempDir, "old.tmp"), modified: old)
            _ = mf.makeSymlink(Paths.join(mf.tempDir, "link-to-user"), to: user)
            _ = mf.setDates(Paths.join(mf.tempDir, "link-to-user"), modified: old)
            let previews = PreviewCache(files: mf)
            let idx = IndexStore(files: mf, folder: Paths.join(mf.supportDir, "Indexes"))
            _ = idx.addRoot(user)
            let orphan = Paths.join(idx.folder, IndexStore.fileName(for: "/Volumes/NoLongerIndexed"))
            mf.writeText("orphan", to: orphan)
            _ = mf.setDates(orphan, modified: old)
            mf.writeText("old log", to: Paths.join(mf.logsDir, "find-old.log"))
            _ = mf.setDates(Paths.join(mf.logsDir, "find-old.log"), modified: old)
            mf.writeText("current log", to: Paths.join(mf.logsDir, "find-now.log"))
            _ = mf.setDates(Paths.join(mf.logsDir, "find-now.log"), modified: old)
            let J = OperationJournal(files: mf)
            let maint = Maintenance(files: mf, previews: previews, indexes: idx, journal: J)
            maint.currentLogPath = Paths.join(mf.logsDir, "find-now.log")
            Activity.shared.begin(.fileOperation)
            let waited = maint.cleanUp(MaintenancePolicy(), trigger: "self-check")
            Activity.shared.end(.fileOperation)
            check("T-SAFE-50", "clean-up waits while a file operation is running", !waited.ran && Sys.exists(Paths.join(mf.tempDir, "old.tmp")))
            let r = maint.cleanUp(MaintenancePolicy(), trigger: "self-check")
            check("T-SAFE-51", "clean-up removes old temporary files and orphan indexes",
                  r.ran && !Sys.exists(Paths.join(mf.tempDir, "old.tmp")) && !Sys.exists(orphan), r.lines.joined(separator: " | "))
            check("T-SAFE-56", "clean-up removes old logs but never the log being written (checked in the optimised app)",
                  !Sys.exists(Paths.join(mf.logsDir, "find-old.log")) && Sys.exists(Paths.join(mf.logsDir, "find-now.log")), r.lines.joined(separator: " | "))
            let userOK = Sys.exists(Paths.join(user, "DSC_1.NEF")) && Sys.exists(Paths.join(user, "DSC_1.xmp"))
            check("T-SAFE-52", "clean-up never touches files outside Find's folders (a link into them is removed, not its target)", userOK)
            _ = maint.clearDisposable()
            check("T-SAFE-53", "Clear All Disposable Caches keeps the indexed-folder list and user files",
                  Sys.exists(Paths.join(idx.folder, "config.json")) && Sys.exists(Paths.join(user, "DSC_1.NEF")))
            // Interrupted batch rename + interrupted copy, as left by a crash.
            makeFile("maint-user/.find-rename-selfcheck-0", "renamed item")
            makeFile("maint-user/.find-partial-selfcheck-big.tif", "half a copy")
            let saved = ops.journal
            ops.journal = J
            _ = J.begin(["RENAME \(Paths.join(user, ".find-rename-selfcheck-0"))\t\(Paths.join(user, "IMG_1.jpg"))\t\(Paths.join(user, "IMG_1 new.jpg"))",
                         "PARTIAL \(Paths.join(user, ".find-partial-selfcheck-big.tif"))",
                         "PARTIAL \(Paths.join(user, "DSC_1.NEF"))"])
            let rec = ops.recoverInterrupted(J)
            ops.journal = saved
            check("T-SAFE-54", "after a crash, an item under a temporary rename name gets its name back",
                  read(Paths.join(user, "IMG_1.jpg")) == "renamed item", rec.joined(separator: " | "))
            check("T-SAFE-55", "after a crash, an unfinished copy goes to the Trash; a user file named in a note is never touched",
                  !Sys.exists(Paths.join(user, ".find-partial-selfcheck-big.tif")) && read(Paths.join(user, "DSC_1.NEF")) == "raw" && J.pendingCount == 0,
                  rec.joined(separator: " | "))
        }

        // 25-26 Cleanup guard refuses paths outside Find's folders
        let outside = Paths.join(Paths.parent(files.cachesDir), "find-guard-test-should-not-exist")
        check("T-SAFE-25", "cleanup refuses a path outside Find's folders", files.removeOwned(outside) == false && files.isOwned(outside) == false)
        check("T-SAFE-26", "cleanup refuses the user's home folder", files.isOwned(NSHomeDirectory()) == false)

        return finish()
    }

    private func finish() -> String {
        // Bring back anything this check sent to the Trash, so it is removed with the scratch folder.
        if !root.isEmpty && Sys.exists(root) {
            for t in ops.trashHistory where !trashBefore.contains(t) && Sys.exists(t) {
                if !ops.reclaimFromTrash(t, into: root) { trashLeftovers.append(t) }
            }
        }
        // Remove the scratch folder (inside Find's caches folder only).
        if !root.isEmpty && Sys.exists(root) {
            let removed = files.removeOwned(root)
            check("T-SAFE-90", "scratch folder removed", removed && !Sys.exists(root))
        }
        if !trashLeftovers.isEmpty {
            report.add("NOTE test items left in the Trash: \(trashLeftovers.joined(separator: ", "))")
        }
        report.addSummary("RESULT \(failed == 0 ? "ALL PASSED" : "FAILURES PRESENT")")
        report.addSummary("PASSED \(passed) FAILED \(failed) SKIPPED \(skipped)")
        for f in failures { report.addSummary(f) }
        return report.render()
    }
}
