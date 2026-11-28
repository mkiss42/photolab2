// FileCommands.swift
// Menu and context-menu commands for a browser window. All changes go through App.ops (FileOperations).

import AppKit
import CoreServices

extension BrowserPane {

    // MARK: Helpers

    /// The selected local items. An FTP pane has none (its hidden local list is never acted on).
    var selection: [FileEntry] { return isFTP ? [] : list.selectedEntries() }

    /// Where new items go: the folder holding the selection (it may be an expanded subfolder), else the current folder.
    var targetFolder: String {
        if list.resultsMode { return currentPath }
        if let first = selection.first { return Paths.parent(first.path) }
        return currentPath
    }

    /// True when a text field is being edited: file commands then leave the keyboard to the text field.
    private var editingText: NSTextView? {
        return window?.firstResponder as? NSTextView
    }

    func registerUndo(_ record: UndoRecord) {
        let name = record.actionName
        undoStack.registerUndo(withTarget: self) { target in
            target.performUndo(record, name: name)
        }
        undoStack.setActionName(name)
    }

    private func performUndo(_ record: UndoRecord, name: String) {
        do {
            let redo = try App.ops.undo(record)
            if let r = redo {
                undoStack.registerUndo(withTarget: self) { target in
                    target.performUndo(r, name: name)
                }
                undoStack.setActionName(name)
            }
        } catch {
            App.log.warn("Undo \(name) failed: \(error)")
            showMessage("\(name) could not be undone", "\(error)")
        }
        refreshList(select: [])
    }

    /// Reload the list (keeps expanded folders) and select these full paths.
    func refreshList(select paths: [String]) {
        if list.resultsMode { return }
        // 0.17: a reload while a name is typed in place would cover the field (new rows are drawn over
        // it - the "typing not shown" after New Folder). Wait until the name is done.
        if inlineEditor != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshList(select: paths) }
            return
        }
        list.load(currentPath, selectPaths: paths, showHidden: Prefs.showHidden)
    }

    func showFailure(_ title: String, _ error: Error) {
        let text = (error as? FileOpError)?.description ?? "\(error)"
        App.log.warn("\(title): \(text)")
        showMessage(title, text)
    }

    /// Show a batch result if anything went wrong or needs mentioning.
    func showReport(_ title: String, _ r: BatchReport) {
        for l in r.summaryLines { App.log.info("\(title): \(l)") }
        if r.failed.isEmpty && r.notes.isEmpty && !r.cancelled { return }
        var lines = r.summaryLines
        if lines.count > 25 { lines = Array(lines.prefix(25)) + ["\u{2026} (full list in the log)"] }
        showMessage(title, lines.joined(separator: "\n"), style: r.failed.isEmpty ? .informational : .warning)
    }

    /// Ask for a name. Returns nil if cancelled.
    func promptName(title: String, info: String, initial: String, button: String) -> String? {
        let a = ThemedAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initial
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        a.accessoryView = field
        a.window.initialFirstResponder = field
        // Select the name without its extension, like Finder.
        let baseLen = Paths.baseName(initial).utf16.count
        DispatchQueue.main.async {
            if let ed = field.currentEditor() {
                ed.selectedRange = NSRange(location: 0, length: baseLen)
            }
        }
        let resp = a.runModal()
        if resp != .alertFirstButtonReturn { return nil }
        return field.stringValue
    }

    private func isPlainFolder(_ e: FileEntry) -> Bool {
        return e.isFolderLike && e.ext != "app" && !KindCache.shared.isPackage(e)
    }

    private func isPackageLike(_ e: FileEntry) -> Bool {
        return e.kind == .directory && (e.ext == "app" || KindCache.shared.isPackage(e))
    }

    // MARK: Open

    @objc func openSelected(_ sender: Any?) {
        if let tv = editingText {
            tv.moveToEndOfDocument(nil)
            return
        }
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        open(sel)
    }

    /// 0.17.7: Cmd held while clicking (a double-click on a folder, a sidebar item, a path bar part) opens
    /// that folder in a new window, as in Finder. Only for mouse clicks: Cmd-Down / Cmd-O stay "open here".
    static var commandClick: Bool {
        guard let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseUp else { return false }
        return e.modifierFlags.contains(.command)
    }

    func openInNewWindow(_ path: String) {
        StallWatch.mark("opening \(path) in a new window")
        (NSApp.delegate as? AppDelegate)?.newWindow(path: path)
    }

    func open(_ items: [FileEntry]) {
        let folders = items.filter { isPlainFolder($0) }
        let others = items.filter { !isPlainFolder($0) }
        if BrowserPane.commandClick && !folders.isEmpty {
            for f in folders { openInNewWindow(f.path) }
        } else if folders.count == 1 && others.isEmpty {
            navigate(to: folders[0].path)
        } else {
            for f in folders { newTab(path: f.path) }
        }
        openFiles(others, with: nil)
    }

    /// 1.0.0-alpha.4: a double-click (or Cmd-Down in the contact sheet) on a file that is part of a larger
    /// selection opens all the selected files, as Finder does. Folders keep Find's behaviour.
    func openClicked(_ e: FileEntry) {
        let sel = selection
        if !isPlainFolder(e), sel.count > 1, sel.contains(where: { $0.path == e.path }) {
            open(sel.filter { !isPlainFolder($0) })
        } else {
            open([e])
        }
    }

    /// 1.0.0-alpha.4: files go to their application in ONE request per application, so Photoshop opens
    /// a range of RAWs in one Camera Raw session instead of one Camera Raw dialog after another.
    /// `chosenApp` nil = each file's default application (looked up by type, never by reading the file).
    func openFiles(_ files: [FileEntry], with chosenApp: String?) {
        if files.isEmpty { return }
        let paths = files.map { $0.path }
        let groups = chosenApp.map { OpenGroups.all(paths, app: $0) }
            ?? OpenGroups.group(paths, appForExtension: BrowserPane.defaultApp(forExtension:))
        var failed: [String] = []
        for g in groups {
            // A single file with no chosen app keeps NSWorkspace.open (honours a per-file "Open with").
            if let app = g.app, g.paths.count > 1 || chosenApp != nil {
                if BrowserPane.openTogether(g.paths, app: app) {
                    Log.shared?.info("OPEN \(g.paths.count) file(s) in one request to \(Paths.lastComponent(app))")
                    continue
                }
                Log.shared?.warn("W-OPEN-1 one-request open refused by macOS (\(g.paths.count) files, \(Paths.lastComponent(app))); opening one by one")
            }
            for p in g.paths {
                let ok = chosenApp.map { NSWorkspace.shared.openFile(p, withApplication: $0) }
                    ?? NSWorkspace.shared.open(URL(fileURLWithPath: p))
                if !ok { failed.append(Paths.lastComponent(p)) }
            }
        }
        if failed.isEmpty { return }
        let appPart = chosenApp.map { " with \(Paths.lastComponent($0))" } ?? ""
        let why = chosenApp == nil ? "macOS has no application set to open \(failed.count == 1 ? "it" : "them"), or the application failed to start." : ""
        let what = failed.count == 1 ? "\"\(failed[0])\"" : "\(failed.count) items"
        showMessage("\(what) could not be opened\(appPart)", why)
    }

    /// The default application for a file extension, from the type alone (no file access, safe on shares).
    static func defaultApp(forExtension ext: String) -> String? {
        guard let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, nil)?.takeRetainedValue(),
            let url = LSCopyDefaultApplicationURLForContentType(uti, .all, nil)?.takeRetainedValue() else { return nil }
        return (url as URL).path
    }

    /// Opens all the paths with one application in a single request (one Apple Event listing every
    /// file), by application path so the chosen copy of the app is used even when several versions
    /// share a bundle id. Available since 10.0; returns false if macOS refused.
    static func openTogether(_ paths: [String], app: String) -> Bool {
        let appURL = NSURL(fileURLWithPath: app) as CFURL
        let items = (paths.map { NSURL(fileURLWithPath: $0) } as NSArray) as CFArray
        var spec = LSLaunchURLSpec(appURL: Unmanaged.passUnretained(appURL),
                                   itemURLs: Unmanaged.passUnretained(items),
                                   passThruParams: nil,
                                   launchFlags: LSLaunchFlags(rawValue: 0x00000001),   // kLSLaunchDefaults
                                   asyncRefCon: nil)
        let status = withExtendedLifetime((appURL, items)) { LSOpenFromURLSpec(&spec, nil) }
        return status == noErr
    }

    @objc func openSelectedInNewTab(_ sender: Any?) {
        for e in selection where isPlainFolder(e) { newTab(path: e.path) }
    }

    @objc func openSelectedInNewPane(_ sender: Any?) {
        let folders = selection.filter { isPlainFolder($0) }
        if folders.isEmpty { host?.addPane(path: currentPath, after: self); return }
        var after: BrowserPane? = self
        for f in folders { after = host?.addPane(path: f.path, after: after) ?? after }
    }

    /// PhotoLab: folders in the contact sheet window (each in a tab); a file: its folder, file selected.
    @objc func openInContactSheet(_ sender: Any?) {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        let rows = isFTP ? [] : list.selectedRowEntries()
        let folders = rows.filter { isPlainFolder($0) }
        if !folders.isEmpty {
            for (i, f) in folders.enumerated() { d.openContactSheet(f.path, newTab: i > 0) }
            return
        }
        if let f = rows.first { d.openContactSheet(Paths.parent(f.path), select: [f.name], newTab: true) }
    }

    @objc func openSelectedInNewWindow(_ sender: Any?) {
        let folders = selection.filter { isPlainFolder($0) }
        if folders.isEmpty {
            (NSApp.delegate as? AppDelegate)?.newWindow(path: currentPath)
            return
        }
        for f in folders { (NSApp.delegate as? AppDelegate)?.newWindow(path: f.path) }
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let e = selection.first(where: { isPackageLike($0) }) else { NSSound.beep(); return }
        navigate(to: e.path)
    }

    @objc func showInEnclosingFolder(_ sender: Any?) {
        guard let e = selection.first else { NSSound.beep(); return }
        endSearchUI()
        navigate(to: Paths.parent(e.path), select: [e.name])
    }

    @objc func openInTerminal(_ sender: Any?) {
        var folders = selection.filter { isPlainFolder($0) }.map { $0.path }
        if folders.isEmpty { folders = [selection.first.map { Paths.parent($0.path) } ?? currentPath] }
        for f in folders where !NSWorkspace.shared.openFile(f, withApplication: "Terminal") {
            showMessage("Terminal could not be opened at \"\(f)\"", "")
        }
    }

    /// Applications that can open a file (default first).
    func applicationsFor(_ path: String) -> [String] {
        let url = NSURL(fileURLWithPath: path) as CFURL
        var out: [String] = []
        if let def = LSCopyDefaultApplicationURLForURL(url, .all, nil)?.takeRetainedValue(), let p = (def as NSURL).path {
            out.append(p)
        }
        if let cfArr = LSCopyApplicationURLsForURL(url, .all)?.takeRetainedValue() {
            let arr = cfArr as NSArray
            for case let u as NSURL in arr {
                if let p = u.path, !out.contains(p) { out.append(p) }
            }
        }
        return out
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        openFiles(selection, with: app)
    }

    @objc func openWithOther(_ sender: Any?) {
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["app"]
        panel.prompt = "Open"
        panel.message = "Choose an application to open the selected item\(sel.count == 1 ? "" : "s")"
        if panel.runModal() == .OK, let app = panel.url?.path {
            openFiles(sel, with: app)
        }
    }

    // MARK: Rename

    @objc func renameSelected(_ sender: Any?) {
        if let b = ftpBrowser { b.renameSelected(nil); return }
        // PhotoLab: one set row is one item to rename (in place; all its files follow the new name).
        let rows = isFTP ? [] : list.selectedRowEntries()
        if rows.count > 1 {
            BatchRenameSheet.show(selection, from: self)
            return
        }
        guard let e = rows.first else {
            NSSound.beep()
            return
        }
        beginInlineRename(e)
    }

    /// Option-click on a folder (list or grid): open it in a new pane.
    func openInNewPane(_ e: FileEntry) {
        guard isPlainFolder(e) else { return }
        host?.addPane(path: e.path, after: self)
    }

    /// The old dialog, used only when the item isn't on screen.
    func renameWithDialog(_ e: FileEntry) {
        var proposed = e.name
        while true {
            guard let newName = promptName(title: "Rename \"\(e.name)\"", info: "Enter a new name.", initial: proposed, button: "Rename") else { return }
            guard let again = applyRename(e, to: newName) else { return }
            proposed = again
        }
    }

    /// Check and perform a rename. Returns nil when finished (renamed, unchanged or cancelled),
    /// or the typed name when the user should keep editing it.
    func applyRename(_ e: FileEntry, to newName: String) -> String? {
        if newName == e.name || newName.isEmpty { return nil }
        if let why = FileOperations.nameProblem(newName) {
            showMessage("That name can't be used", "\"\(newName)\": \(why).")
            return newName
        }
        let oldExt = Paths.fileExtension(e.name), newExt = Paths.fileExtension(newName)
        if e.kind == .file && oldExt != newExt {
            let a = ThemedAlert()
            a.messageText = oldExt.isEmpty ? "Add the extension \".\(newExt)\"?" :
                (newExt.isEmpty ? "Remove the extension \".\(oldExt)\"?" : "Change the extension from \".\(oldExt)\" to \".\(newExt)\"?")
            a.informativeText = "The file's contents are not converted; other apps may treat it differently."
            a.addButton(withTitle: "Keep .\(oldExt.isEmpty ? "(none)" : oldExt)")
            a.addButton(withTitle: "Use .\(newExt.isEmpty ? "(none)" : newExt)")
            if a.runModal() == .alertFirstButtonReturn { return newName }
        }
        if newName.hasPrefix(".") && !e.name.hasPrefix(".") {
            let a = ThemedAlert()
            a.messageText = "Names starting with \".\" are hidden"
            a.informativeText = "\"\(newName)\" will be hidden unless Show Hidden Files is on."
            a.addButton(withTitle: "Use This Name")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return nil }
        }
        // PhotoLab: renaming a set's row renames every member (DSC_1.NEF/.JPG/.xmp -> Job_1.NEF/.JPG/.xmp).
        let members = list.groupSets ? list.setMembers(of: e.path) : []
        if members.count > 1, let work = FileSets.renames(members: members, repName: e.name, newName: newName) {
            do {
                let (pairs, rec) = try App.ops.renameBatch(work)
                registerUndo(rec)
                let newRep = pairs.first { $0.from == e.path }?.to ?? Paths.join(Paths.parent(e.path), newName)
                App.log.info("RENAME SET \(members.count) files -> \(FileSets.split(newName).stem)")
                refreshList(select: [newRep])
            } catch {
                showFailure("Rename failed", error)
            }
            return nil
        }
        do {
            let (newPath, rec) = try App.ops.rename(e.path, to: newName)
            registerUndo(rec)
            if list.resultsMode {
                list.updateResult(e.path, to: newPath)
            } else {
                refreshList(select: [newPath])
            }
        } catch {
            showFailure("Rename failed", error)
        }
        return nil
    }

    // MARK: New folder

    @objc func newFolder(_ sender: Any?) {
        if let b = ftpBrowser { b.newFolder(); return }
        let dir = targetFolder
        do {
            let (p, rec) = try App.ops.createFolder(in: dir)
            registerUndo(rec)
            pendingInlineRename = p
            refreshList(select: [p])
        } catch {
            showFailure("New folder failed", error)
        }
    }

    /// Finder's "New Folder with Selection": a new folder next to the items, with the items moved into it.
    @objc func newFolderWithSelection(_ sender: Any?) {
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let dir = Paths.parent(sel[0].path)
        if sel.contains(where: { Paths.parent($0.path) != dir }) {
            showMessage("Items are in different folders", "New Folder with Selection needs items from one folder.")
            return
        }
        do {
            let (p, rec) = try App.ops.createFolder(in: dir, name: "New Folder With Items")
            registerUndo(rec)
            let r = App.ops.move(sel.map { $0.path }, into: p, choose: { _ in .skip })
            if let u = r.undo { registerUndo(u) }
            pendingInlineRename = p
            refreshList(select: [p])
            showReport("New Folder with Selection", r)
        } catch {
            showFailure("New folder failed", error)
        }
    }

    // MARK: Trash

    @objc func trashSelected(_ sender: Any?) {
        // FTP pane: delete on the server (files only, asks first) - never the local list behind it.
        if let b = ftpBrowser { b.deleteSelected(nil); return }
        if let tv = editingText {
            tv.deleteToBeginningOfLine(nil)
            return
        }
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let r = App.ops.trash(withHiddenTwins(sel.map { $0.path }))
        if let u = r.undo { registerUndo(u) }
        if list.resultsMode {
            showMessage("Moved \(r.done.count) item\(r.done.count == 1 ? "" : "s") to the Trash", "Search results are not updated automatically; run the search again to refresh them.", style: .informational)
        } else {
            refreshList(select: [])
        }
        App.log.info("Trashed \(r.done.count) of \(sel.count) selected")
        // 0.18.4: like Finder - items that can't go to the Trash (a shared volume usually has none) can be
        // deleted immediately, after you confirm.
        let noTrash = r.failed.filter { if case .trashUnavailable = $0.error { return true }; return false }.map { $0.path }
        var rest = r
        rest.failed = r.failed.filter { f in !noTrash.contains(f.path) }
        if !rest.failed.isEmpty || !rest.notes.isEmpty { showReport("Move to Trash", rest) }
        if !noTrash.isEmpty { deleteImmediately(noTrash, becauseNoTrash: true) }
    }

    /// File > Delete Immediately... (Option-Cmd-Backspace), as in Finder.
    @objc func deleteImmediatelySelected(_ sender: Any?) {
        if let b = ftpBrowser { b.deleteSelected(nil); return }
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        deleteImmediately(withHiddenTwins(sel.map { $0.path }), becauseNoTrash: false)
    }

    /// 0.18.10: in Photography Mode with "Show RAW + JPEG pairs as one" on, the hidden JPEG twins of the
    /// picked RAWs go along (trash, delete, copy, move, drag).
    func withHiddenTwins(_ paths: [String]) -> [String] {
        guard viewMode == "photo", Prefs.hideJPEGTwins else { return paths }
        let t = RawTwins.twins(of: paths) { d in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []) }
        for x in t { App.log.info("JPEG twin goes along: \(x)") }
        return paths + t
    }

    /// Asks first (names the items), then deletes them permanently. No Undo.
    func deleteImmediately(_ paths: [String], becauseNoTrash: Bool) {
        let refused = paths.compactMap { p in FileOperations.deleteRefusal(p).map { (p, $0) } }
        if !refused.isEmpty {
            showMessage("Not deleted", refused.prefix(6).map { "\u{2022} \(Paths.lastComponent($0.0)): it is \($0.1)" }.joined(separator: "\n")
                        + "\n\nPhotoLab never deletes these. Nothing was deleted.")
            return
        }
        let names = paths.map { Paths.lastComponent($0) }
        var isFolder: [Bool] = []
        for p in paths { var e: Int32 = 0; isFolder.append(Sys.lstatInfo(p, &e)?.isDirectory ?? false) }
        let a = ThemedAlert()
        a.alertStyle = .critical
        let volume = Paths.lastComponent(VolumeRegistry.volumeRoot(paths[0]))
        a.messageText = paths.count == 1
            ? "Are you sure you want to delete \u{201C}\(names[0])\u{201D}?"
            : "Are you sure you want to delete these \(paths.count) items?"
        var info = becauseNoTrash
            ? "\(paths.count == 1 ? "This item" : "These items") can't be moved to the Trash" + (volume.isEmpty || volume == "/" ? "" : " on \u{201C}\(volume)\u{201D}") + ", so \(paths.count == 1 ? "it" : "they") will be deleted immediately. You can't undo this action.\n\n"
            : "\(paths.count == 1 ? "This item" : "These items") will be deleted immediately. You can't undo this action.\n\n"
        info += zip(names, isFolder).prefix(12).map { "\u{2022} " + $0.0 + ($0.1 ? "  (folder, with everything in it)" : "") }.joined(separator: "\n")
        if paths.count > 12 { info += "\n\u{2026} and \(paths.count - 12) more" }
        a.informativeText = info
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Delete")
        guard a.runModal() == .alertSecondButtonReturn else {
            App.log.info("Delete Immediately cancelled (\(paths.count) items)")
            return
        }
        runTask(title: "Deleting " + (paths.count == 1 ? "\u{201C}\(names[0])\u{201D}" : "\(paths.count) items"), indeterminate: true, work: { _ in
            App.ops.deleteImmediately(paths)
        }, done: { [weak self] r in
            guard let s = self else { return }
            App.log.info("Deleted immediately \(r.done.count) of \(paths.count)")
            if s.list.resultsMode {
                s.showMessage("Deleted \(r.done.count) item\(r.done.count == 1 ? "" : "s")", "Search results are not updated automatically; run the search again to refresh them.", style: .informational)
            } else {
                s.refreshList(select: [])
            }
            if !r.failed.isEmpty { s.showReport("Delete Immediately", r) }
        })
    }

    // MARK: Duplicate, compress, alias

    @objc func duplicateSelected(_ sender: Any?) {
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let jobs = sel.map { e -> (String, String, String) in
            let ext = Paths.fileExtension(e.name)
            let base = Paths.baseName(e.name)
            let copyName = ext.isEmpty || e.kind == .directory ? "\(e.name) copy" : "\(base) copy.\(String(e.name.suffix(ext.count)))"
            return (e.path, Paths.parent(e.path), copyName)
        }
        runTask(title: "Duplicating " + (jobs.count == 1 ? "\"\(Paths.lastComponent(jobs[0].0))\"" : "\(jobs.count) items"), work: { t in
            var report = BatchReport()
            var made: [String] = []
            t.progress.plan(jobs.map { $0.0 })
            for (src, dir, wanted) in jobs {
                if t.isCancelled() { report.cancelled = true; break }
                let target = Paths.join(dir, FileOperations.uniqueName(for: wanted, in: dir))
                t.progress.begin(src)
                do {
                    let p = try App.ops.copyVerified(src, to: target, progress: t.progress)
                    t.progress.finish(src, ok: true)
                    made.append(p)
                    report.done.append((src, p))
                } catch let e as FileOpError {
                    t.progress.finish(src, ok: false, detail: e.description)
                    report.failed.append((src, e))
                } catch {
                    t.progress.finish(src, ok: false)
                    report.failed.append((src, FileOpError.refused("\(error)")))
                }
            }
            if !made.isEmpty { report.undo = .copied(made) }
            return report
        }, done: { [weak self] r in
            guard let s = self else { return }
            if let u = r.undo { s.registerUndo(u) }
            s.refreshList(select: r.done.map { $0.to })
            s.showReport("Duplicate", r)
        })
    }

    @objc func compressSelected(_ sender: Any?) {
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let paths = sel.map { $0.path }
        var made = ""
        runBatch(title: "Compressing " + (paths.count == 1 ? "\"\(Paths.lastComponent(paths[0]))\"" : "\(paths.count) items"), work: { _ in
            var report = BatchReport()
            do {
                let (z, rec) = try App.ops.compress(paths)
                made = z
                report.done.append((paths[0], z))
                report.undo = rec
            } catch let e as FileOpError {
                report.failed.append((paths[0], e))
            } catch {
                report.failed.append((paths[0], FileOpError.refused("\(error)")))
            }
            return report
        }, done: { [weak self] r in
            guard let s = self else { return }
            if let u = r.undo { s.registerUndo(u) }
            s.refreshList(select: made.isEmpty ? [] : [made])
            s.showReport("Compress", r)
        })
    }

    @objc func makeAliasOfSelected(_ sender: Any?) {
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        var made: [String] = []
        for e in sel {
            do {
                let (a, rec) = try App.ops.makeAlias(e.path)
                registerUndo(rec)
                made.append(a)
            } catch {
                showFailure("Make Alias failed for \"\(e.name)\"", error)
            }
        }
        refreshList(select: made)
    }

    // MARK: Clipboard: copy, paste (copy here), move here

    @objc func copy(_ sender: Any?) {
        // 0.17.1: in an FTP pane, Copy remembers the server items; Paste in a local pane downloads them.
        if let b = ftpBrowser { b.copyToClipboard(); return }
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(sel.map { NSURL(fileURLWithPath: $0.path) })
        // Copied in Photography mode: Paste / Move Here bring the XMP sidecars along.
        FileDrag.photoClipboardStamp = viewMode == "photo" ? pb.changeCount : -1
    }

    /// The clipboard still holds what was copied in Photography mode.
    private var clipboardFromPhotoMode: Bool {
        return FileDrag.photoClipboardStamp >= 0 && FileDrag.photoClipboardStamp == NSPasteboard.general.changeCount
    }

    private func pasteboardPaths() -> [String] {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return [] }
        return urls.map { $0.path }
    }

    @objc func paste(_ sender: Any?) {
        // 0.17.1: Paste into an FTP pane uploads the copied files and folders (same as dragging them in).
        if let b = ftpBrowser {
            if FTPDragPayload.read(NSPasteboard.general) != nil {
                showMessage("Can't paste server items here", "Copying from one FTP folder to another isn't possible. Paste them into a folder on this Mac instead.", style: .informational)
                return
            }
            let local = pasteboardPaths()
            if local.isEmpty { NSSound.beep(); return }
            b.upload(local, into: b.path)
            return
        }
        // Copied in an FTP pane: download here.
        if let payload = FTPDragPayload.read(NSPasteboard.general) {
            downloadFTP(payload, into: targetFolder)
            return
        }
        let paths = pasteboardPaths()
        if paths.isEmpty { NSSound.beep(); return }
        transfer(paths, into: targetFolder, move: false, withSidecars: clipboardFromPhotoMode)
    }

    @objc func moveHere(_ sender: Any?) {
        let paths = pasteboardPaths()
        if paths.isEmpty { NSSound.beep(); return }
        transfer(paths, into: targetFolder, move: true, withSidecars: clipboardFromPhotoMode)
        NSPasteboard.general.clearContents()
    }

    @objc func moveTo(_ sender: Any?) {
        chooseDestination(move: true)
    }

    @objc func copyTo(_ sender: Any?) {
        chooseDestination(move: false)
    }

    private func chooseDestination(move: Bool) {
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: currentPath)
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = "\(move ? "Move" : "Copy") \(sel.count) item\(sel.count == 1 ? "" : "s") to:"
        guard panel.runModal() == .OK, let dest = panel.url?.path else { return }
        transfer(sel.map { $0.path }, into: dest, move: move, withSidecars: viewMode == "photo")
    }

    /// Copy or move items into a folder. Name clashes are decided up front, then the work runs in the background.
    /// `withSidecars`: Photography mode - the XMP sidecars of the pictures go along (Sidecars.companions).
    func transfer(_ picked: [String], into dest: String, move: Bool, withSidecars: Bool = false,
                  then: ((BatchReport) -> Void)? = nil) {
        var sources = picked
        var sidecarNotes: [String] = []
        if withSidecars && Prefs.hideJPEGTwins {
            // 0.18.10: the hidden JPEG twins of the RAWs go along.
            let t = RawTwins.twins(of: picked) { d in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []) }
            for x in t { App.log.info("JPEG twin goes along (\(move ? "move" : "copy")): \(x)") }
            sources += t
        }
        if withSidecars {
            let (extra, kept) = Sidecars.companions(of: sources, move: move, list: { d in
                ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [])
            })
            for x in extra { App.log.info("SIDECAR goes along (\(move ? "move" : "copy")): \(x)") }
            sources += extra
            for k in kept {
                App.log.info("SIDECAR kept back (not all its pictures are moved): \(k)")
                sidecarNotes.append("XMP sidecar \"\(Paths.lastComponent(k))\" stayed in \"\(Paths.lastComponent(Paths.parent(k)))\": a picture with the same name (e.g. the RAW) was not moved, and the sidecar stays with it.")
            }
        }
        let clashes = FileOperations.conflicts(sources, into: dest).map { Paths.lastComponent($0) }
            .filter { n in !(move && sources.contains(Paths.join(dest, n))) }
        var decisions: [String: ConflictChoice] = [:]
        var applyAll: ConflictChoice? = nil
        // PhotoLab S1: a share has no Trash - Replace then deletes the old FILE permanently, after the new
        // one is in place and verified. The dialog says so; choosing Replace there is the confirmation.
        let destNoTrash = !App.ops.hasTrash(dest)
        for name in clashes {
            if let all = applyAll {
                decisions[name] = all
                continue
            }
            let a = ThemedAlert()
            a.messageText = "An item named \"\(name)\" already exists in \"\(Paths.lastComponent(dest))\"."
            if destNoTrash {
                a.informativeText = "Keep Both adds a number to the new item's name. \"\(Paths.lastComponent(dest))\" is on a volume without a Trash: Replace deletes the existing file permanently, only after the new one is copied in and verified. It can't be undone. Folders are never replaced here."
            } else {
                a.informativeText = "Keep Both adds a number to the new item's name. Replace moves the existing item to the Trash first; nothing is overwritten."
            }
            a.addButton(withTitle: "Keep Both")
            a.addButton(withTitle: "Skip")
            a.addButton(withTitle: destNoTrash ? "Replace (Delete Old)" : "Replace")
            a.addButton(withTitle: "Stop")
            if clashes.count > 1 {
                a.showsSuppressionButton = true
                a.suppressionButton?.title = "Apply to all \(clashes.count) name clashes"
            }
            let resp = a.runModal()
            let choice: ConflictChoice
            switch resp {
            case .alertFirstButtonReturn: choice = .keepBoth
            case .alertSecondButtonReturn: choice = .skip
            case .alertThirdButtonReturn: choice = .replace
            default: choice = .cancel
            }
            if choice == .cancel {
                App.log.info("Transfer stopped by user at name clash \(name)")
                return
            }
            decisions[name] = choice
            if a.suppressionButton?.state == .on { applyAll = choice }
        }
        let replaceWithoutTrash = destNoTrash && decisions.values.contains(.replace)
        // PhotoLab S2: moving to another volume from a share without a Trash - the originals are deleted
        // after their copies are verified (if they did not change meanwhile). Asked once.
        var moveNow = move
        var deleteOriginals = false
        let destRoot = VolumeRegistry.volumeRoot(dest)
        let noTrashOrigins = move ? sources.filter { VolumeRegistry.volumeRoot($0) != destRoot && !App.ops.hasTrash($0) } : []
        if !noTrashOrigins.isEmpty {
            let a = ThemedAlert()
            let vol = Paths.lastComponent(VolumeRegistry.volumeRoot(noTrashOrigins[0]))
            a.messageText = "Move \(noTrashOrigins.count == 1 ? "\"\(Paths.lastComponent(noTrashOrigins[0]))\"" : "\(noTrashOrigins.count) items") from \"\(vol)\", which has no Trash?"
            a.informativeText = "Each original is deleted only after its copy is verified, and only if it did not change while it was copied. This can't be undone. Copy Instead keeps the originals."
            a.addButton(withTitle: "Move")
            a.addButton(withTitle: "Copy Instead")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: deleteOriginals = true
            case .alertSecondButtonReturn: moveNow = false
            default:
                App.log.info("Move from a volume without a Trash cancelled by user")
                return
            }
            App.log.info(deleteOriginals ? "Move from a volume without a Trash confirmed: \(noTrashOrigins.count) originals deleted after verified copies"
                                         : "Move from a volume without a Trash: copying instead")
        }
        let move = moveNow
        let verb = move ? "Moving" : "Copying"
        let what = sources.count == 1 ? "\"\(Paths.lastComponent(sources[0]))\"" : "\(sources.count) items"
        runTask(title: "\(verb) \(what) to \"\(Paths.lastComponent(dest))\"", work: { t in
            // A clash that appears after the questions (something new arrived) is skipped, never overwritten.
            let choose: (String) -> ConflictChoice = { n in decisions[n] ?? .skip }
            t.progress.plan(sources)
            if move {
                return App.ops.move(sources, into: dest, choose: choose, isCancelled: t.isCancelled, progress: t.progress,
                                    replaceWithoutTrash: replaceWithoutTrash, deleteOriginalsWithoutTrash: deleteOriginals)
            }
            return App.ops.copy(sources, into: dest, choose: choose, isCancelled: t.isCancelled, progress: t.progress,
                                replaceWithoutTrash: replaceWithoutTrash)
        }, done: { [weak self] result in
            guard let s = self else { return }
            var r = result
            r.notes.append(contentsOf: sidecarNotes)
            if let u = r.undo { s.registerUndo(u) }
            s.refreshList(select: r.done.map { $0.to })
            s.showReport(move ? "Move" : "Copy", r)
            then?(r)
        })
    }

    /// 0.17: file work runs in the background and shows in the Copies window (Window > Copies) with
    /// progress bars, Stop and diagnostics; the window you work in is never blocked.
    /// Stop takes effect safely: an item being copied is finished or its unfinished copy is removed.
    func runBatch(title: String, work: @escaping (@escaping () -> Bool) -> BatchReport, done: @escaping (BatchReport) -> Void) {
        runTask(title: title, indeterminate: true, work: { t in work(t.isCancelled) }, done: done)
    }

    /// As runBatch, with byte progress (copies and moves).
    func runTask(title: String, indeterminate: Bool = false, work: @escaping (CopyTask) -> BatchReport, done: @escaping (BatchReport) -> Void) {
        let started = Date()
        CopiesCenter.shared.run(title, indeterminate: indeterminate, work: work, done: { r in
            App.log.info("\(title) finished in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            done(r)
        })
    }

    // MARK: Colour labels

    /// Finder-style row of colour dots for the context menu.
    func colorLabelItem(_ sel: [FileEntry]) -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let view = ColorLabelMenuView(frame: NSRect(x: 0, y: 0, width: 58 + 7 * 24 + 12, height: 28))
        var applied = Set<Int>()
        let perItem = sel.map { Set(TagCache.shared.colorsNow($0.path)) }
        for i in 0..<ColorLabel.names.count where !perItem.isEmpty && perItem.allSatisfyCompat({ $0.contains(i) }) {
            applied.insert(i)
        }
        view.applied = applied
        let paths = sel.map { $0.path }
        view.onPick = { [weak self] idx in
            // Run after the menu has closed.
            DispatchQueue.main.async { self?.applyColorLabel(paths, idx) }
        }
        item.view = view
        return item
    }

    func applyColorLabel(_ paths: [String], _ idx: Int) {
        let r = App.ops.toggleColorLabel(paths, colorIndex: idx)
        if let u = r.undo { registerUndo(u) }
        TagCache.shared.forget(paths)
        list.table.reloadData()
        if !r.failed.isEmpty { showReport("Color Label", r) }
    }

    // MARK: Paths, names, info

    @objc func copyPath(_ sender: Any?) {
        let sel = selection
        let paths = sel.isEmpty ? [currentPath] : sel.map { $0.path }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copyName(_ sender: Any?) {
        let sel = selection
        if sel.isEmpty { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sel.map { $0.name }.joined(separator: "\n"), forType: .string)
    }

    @objc func revealInFinder(_ sender: Any?) {
        let sel = selection
        let urls = sel.isEmpty ? [URL(fileURLWithPath: currentPath)] : sel.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func addToSidebar(_ sender: Any?) {
        let sel = selection.filter { $0.isFolderLike }
        let paths = sel.isEmpty ? [currentPath] : sel.map { $0.path }
        var favs = Prefs.favorites
        for p in paths where !favs.contains(p) { favs.append(p) }
        Prefs.favorites = favs
    }

    @objc func getInfo(_ sender: Any?) {
        let sel = selection
        var targets: [FileEntry] = sel
        if targets.isEmpty {
            var e: Int32 = 0
            if let me = FileEntry.make(path: currentPath, err: &e) { targets = [me] }
        }
        for t in targets.prefix(10) { InfoWindowController.show(t) }
    }

    @objc func selectAllOfKind(_ sender: Any?) {
        guard let e = selection.first, e.kind != .directory else { NSSound.beep(); return }
        list.selectAll(withExtension: e.ext)
    }

    // MARK: View and Go

    @objc func refresh(_ sender: Any?) {
        if let b = ftpBrowser { b.refresh(); return }   // Cmd-R in an FTP pane re-reads the server folder
        ListingCache.shared.forget(currentPath)
        list.clearFolderSizes()
        TagCache.shared.clear()
        photoFactsFolder = ""   // photography mode re-checks ratings (unchanged files come from memory)
        list.reload(showHidden: Prefs.showHidden)
        host?.sidebar.rebuild(currentPath: currentPath)
    }

    @objc func sortByMenu(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let col = SortColumn(rawValue: key) else { return }
        let asc = list.spec.column == col ? !list.spec.ascending : (col == .name || col == .kind)
        if col == .added && !Prefs.visibleColumns.contains("added") { list.setColumn("added", visible: true) }
        list.setSort(col, ascending: asc)
    }

    @objc func toggleColumnMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        list.setColumn(id, visible: !Prefs.visibleColumns.contains(id))
    }

    @objc func goToFolder(_ sender: Any?) {
        pathBar.beginEditing()
    }

    @objc func goHome(_ sender: Any?) { navigate(to: NSHomeDirectory()) }
    @objc func goDesktop(_ sender: Any?) { navigate(to: NSHomeDirectory() + "/Desktop") }
    @objc func goDocuments(_ sender: Any?) { navigate(to: NSHomeDirectory() + "/Documents") }
    @objc func goDownloads(_ sender: Any?) { navigate(to: NSHomeDirectory() + "/Downloads") }
    @objc func goPictures(_ sender: Any?) { navigate(to: NSHomeDirectory() + "/Pictures") }
    @objc func goApplications(_ sender: Any?) { navigate(to: "/Applications") }
    @objc func goComputer(_ sender: Any?) { navigate(to: "/") }
    @objc func goVolumes(_ sender: Any?) { navigate(to: "/Volumes") }

    @objc func newTabCommand(_ sender: Any?) { newTab(path: currentPath) }
    @objc func closeTabCommand(_ sender: Any?) { tabBarClose(active) }

    @objc func nextTab(_ sender: Any?) {
        if tabs.count < 2 { return }
        tabBarSelect((active + 1) % tabs.count)
    }

    @objc func previousTab(_ sender: Any?) {
        if tabs.count < 2 { return }
        tabBarSelect((active - 1 + tabs.count) % tabs.count)
    }

    @objc func moveWindowToQuarter(_ sender: NSMenuItem) {
        guard let w = window, let q = Quarter(rawValue: sender.tag) else { return }
        WindowPlacementManager.shared.move(w, to: q)
    }

    // MARK: Context menus (Finder's items plus a few Find additions)

    private func menuItem(_ title: String, _ action: Selector, _ represented: Any? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = represented
        return mi
    }

    private func sortMenu() -> NSMenu {
        let sub = NSMenu(title: "Sort By")
        let opts: [(String, String)] = [("Name", "name"), ("Kind", "kind"), ("Date Modified", "modified"),
                                        ("Date Created", "created"), ("Date Added", "added"), ("Size", "size")]
        for (t, k) in opts {
            let mi = menuItem(t, #selector(sortByMenu(_:)), k)
            if list.spec.column.rawValue == k { mi.state = .on }
            sub.addItem(mi)
        }
        sub.addItem(NSMenuItem.separator())
        let ff = NSMenuItem(title: "Keep Folders on Top", action: #selector(AppDelegate.toggleFoldersFirst(_:)), keyEquivalent: "")
        ff.target = NSApp.delegate
        ff.state = Prefs.foldersFirst ? .on : .off
        sub.addItem(ff)
        return sub
    }

    private func columnsMenu() -> NSMenu {
        let sub = NSMenu(title: "Show Columns")
        let opts: [(String, String)] = [("Date Modified", "modified"), ("Date Created", "created"), ("Date Added", "added"),
                                        ("Size", "size"), ("Kind", "kind")]
        for (t, k) in opts {
            let mi = menuItem(t, #selector(toggleColumnMenu(_:)), k)
            mi.state = Prefs.visibleColumns.contains(k) ? .on : .off
            sub.addItem(mi)
        }
        return sub
    }

    private func addSub(_ m: NSMenu, _ title: String, _ sub: NSMenu) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = sub
        m.addItem(mi)
    }

    func buildContextMenu() -> NSMenu {
        let m = NSMenu()
        let sel = selection
        if sel.isEmpty {
            m.addItem(menuItem("New Folder", #selector(newFolder(_:))))
            m.addItem(NSMenuItem.separator())
            m.addItem(menuItem("Get Info", #selector(getInfo(_:))))
            m.addItem(menuItem("Copy Info as Text", #selector(copyInfoAsText(_:))))
            m.addItem(NSMenuItem.separator())
            m.addItem(menuItem("Paste Items (Copy Here)", #selector(paste(_:))))
            m.addItem(menuItem("Move Items Here", #selector(moveHere(_:))))
            m.addItem(NSMenuItem.separator())
            addSub(m, "Sort By", sortMenu())
            addSub(m, "Show Columns", columnsMenu())
            let hid = NSMenuItem(title: "Show Hidden Files", action: #selector(AppDelegate.toggleHidden(_:)), keyEquivalent: "")
            hid.target = NSApp.delegate
            hid.state = Prefs.showHidden ? .on : .off
            m.addItem(hid)
            m.addItem(NSMenuItem.separator())
            m.addItem(menuItem("Search in This Folder\u{2026}", #selector(searchHere(_:))))
            m.addItem(menuItem("Copy Path of This Folder", #selector(copyPath(_:))))
            m.addItem(menuItem("Open in Terminal", #selector(openInTerminal(_:))))
            m.addItem(menuItem("Show This Folder in Finder", #selector(revealInFinder(_:))))
            m.addItem(menuItem("Add This Folder to Sidebar", #selector(addToSidebar(_:))))
            m.addItem(menuItem("Open This Folder in New Window", #selector(openSelectedInNewWindow(_:))))
            m.addItem(NSMenuItem.separator())
            m.addItem(menuItem("Refresh", #selector(refresh(_:))))
            return m
        }

        let one = sel.count == 1 ? sel[0] : nil
        // Short labels: long file names made the menu hard to read. Several items show the count only.
        let quoted = one == nil ? "\(sel.count) Items" : ""
        let hasFolders = sel.contains(where: { isPlainFolder($0) })

        m.addItem(menuItem("Open", #selector(openSelected(_:))))
        if hasFolders {
            m.addItem(menuItem("Open in Contact Sheet", #selector(openInContactSheet(_:))))
        } else if let f = one, f.kind == .file {
            m.addItem(menuItem("Open Enclosing Folder in Contact Sheet", #selector(openInContactSheet(_:))))
        }
        if hasFolders {
            m.addItem(menuItem("Open in New Tab", #selector(openSelectedInNewTab(_:))))
            m.addItem(menuItem("Open in New Pane", #selector(openSelectedInNewPane(_:))))
            m.addItem(menuItem("Open in New Window", #selector(openSelectedInNewWindow(_:))))
        }
        if let first = sel.first, !isPlainFolder(first) {
            let sub = NSMenu()
            let apps = applicationsFor(first.path)
            for (i, app) in apps.prefix(20).enumerated() {
                let name = Paths.baseName(Paths.lastComponent(app)) + (i == 0 ? " (default)" : "")
                let mi = menuItem(name, #selector(openWithApp(_:)), app)
                mi.image = IconCache.shared.icon(forPath: app)
                sub.addItem(mi)
                if i == 0 && apps.count > 1 { sub.addItem(NSMenuItem.separator()) }
            }
            if !apps.isEmpty { sub.addItem(NSMenuItem.separator()) }
            sub.addItem(menuItem("Other\u{2026}", #selector(openWithOther(_:))))
            addSub(m, "Open With", sub)
        }
        if let e = one, isPackageLike(e) {
            m.addItem(menuItem("Show Package Contents", #selector(showPackageContents(_:))))
        }
        if list.resultsMode {
            m.addItem(menuItem("Show in Enclosing Folder", #selector(showInEnclosingFolder(_:))))
        }
        m.addItem(NSMenuItem.separator())
        m.addItem(menuItem("Move to Trash", #selector(trashSelected(_:))))
        let di = menuItem("Delete Immediately\u{2026}", #selector(deleteImmediatelySelected(_:)))
        di.isAlternate = true                  // shown instead of Move to Trash while Option is held (Finder)
        di.keyEquivalentModifierMask = [.option]
        m.addItem(di)
        m.addItem(NSMenuItem.separator())
        m.addItem(menuItem("Get Info", #selector(getInfo(_:))))
        if one != nil {
            m.addItem(menuItem("Rename\u{2026}", #selector(renameSelected(_:))))
        } else if sel.count > 1 {
            m.addItem(menuItem("Rename \(sel.count) Items\u{2026}", #selector(renameSelected(_:))))
        }
        if !list.resultsMode || subfoldersOn {
            m.addItem(menuItem("Find and Replace\u{2026}", #selector(findAndReplace(_:))))
        }
        m.addItem(menuItem(("Compress " + quoted).trimmingCharacters(in: .whitespaces), #selector(compressSelected(_:))))
        m.addItem(menuItem("Duplicate", #selector(duplicateSelected(_:))))
        m.addItem(menuItem("Make Alias", #selector(makeAliasOfSelected(_:))))
        m.addItem(menuItem("Preview", #selector(fastPreview(_:))))
        m.addItem(menuItem("Quick Look", #selector(quickLook(_:))))
        let pics = sel.filter { $0.kind == .file && PhotoFormats.isImage($0.name) }.count
        if pics >= 2 && pics <= 4 { m.addItem(menuItem("Compare \(pics) Pictures", #selector(compareSelected(_:)))) }
        if !list.resultsMode {
            m.addItem(menuItem("New Folder with Selection (\(sel.count) Item\(sel.count == 1 ? "" : "s"))", #selector(newFolderWithSelection(_:))))
        }
        m.addItem(NSMenuItem.separator())
        m.addItem(menuItem(("Copy " + quoted).trimmingCharacters(in: .whitespaces), #selector(copy(_:))))
        if hasPartner {
            m.addItem(menuItem("Copy to Other Pane (F5)", #selector(copyToOtherPane(_:))))
            m.addItem(menuItem("Move to Other Pane (F6)", #selector(moveToOtherPane(_:))))
        }
        m.addItem(menuItem("Copy Path", #selector(copyPath(_:))))
        m.addItem(menuItem("Copy Info as Text", #selector(copyInfoAsText(_:))))
        m.addItem(menuItem("Copy Name", #selector(copyName(_:))))
        m.addItem(NSMenuItem.separator())
        m.addItem(colorLabelItem(sel))
        m.addItem(NSMenuItem.separator())
        if let e = one, e.kind != .directory, !e.ext.isEmpty {
            m.addItem(menuItem("Select All .\(e.ext) Files", #selector(selectAllOfKind(_:))))
        }
        if hasFolders {
            m.addItem(menuItem("Search in This Folder\u{2026}", #selector(searchHere(_:))))
            m.addItem(menuItem("Add to Sidebar", #selector(addToSidebar(_:))))
        }
        m.addItem(menuItem("Open in Terminal", #selector(openInTerminal(_:))))
        m.addItem(menuItem("Show in Finder", #selector(revealInFinder(_:))))
        return m
    }
}

/// Cancel button for the progress sheet: sets a flag the background work checks between items.
final class SheetCancelButton: NSButton {
    var flag: AtomicInt?

    @objc func pressed(_ sender: Any?) {
        flag?.value = 1
        title = "Stopping\u{2026}"
        isEnabled = false
    }
}
