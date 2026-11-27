// BrowserSearch.swift
// Running searches from a browser window: scope -> folders, engine, live results, completeness report.

import AppKit

extension BrowserPane {

    /// Cmd-F: show the search bar and put the cursor in the search field.
    @objc func focusSearch(_ sender: Any?) {
        search.show(true)
        window?.makeFirstResponder(search.field)
    }

    /// Context menu "Search in This Folder…": selected folders, or the current folder.
    @objc func searchHere(_ sender: Any?) {
        let folders = selection.filter { $0.isFolderLike }.map { $0.path }
        pendingSearchFolders = folders
        search.setScope(folders.isEmpty ? .thisFolderAndSubfolders : .selectedFolders)
        focusSearch(nil)
    }

    /// From the cached volume list: never asks a (possibly dead) server anything on the main thread.
    private func isNetwork(_ path: String) -> Bool {
        return VolumeRegistry.shared.treatAsNetwork(path)
    }

    /// The drive a path is on. Network shares by name (/Volumes/Share) - no request to the server.
    private func driveRoot(_ path: String) -> String {
        return isNetwork(path) ? VolumeRegistry.volumeRoot(path) : Sys.volumeRoot(of: path)
    }

    /// The folders a scope means right now, plus words for the status line. nil = can't search (user is told why).
    func searchRoots(_ scope: SearchScope) -> (roots: [String], words: String, network: Bool)? {
        let here = currentPath
        let vols = Volumes.mounted()
        switch scope {
        case .thisFolderOnly:
            return ([here], "\"\(Paths.lastComponent(here))\" (this level only)", isNetwork(here))
        case .thisFolderAndSubfolders:
            return ([here], "\"\(Paths.lastComponent(here))\" and its subfolders", isNetwork(here))
        case .selectedFolders:
            var folders = list.resultsMode ? [] : selection.filter { $0.isFolderLike }.map { $0.path }
            if folders.isEmpty { folders = pendingSearchFolders }
            if folders.isEmpty {
                showMessage("No folders selected", "Select one or more folders first, or choose another place to search.")
                return nil
            }
            pendingSearchFolders = folders
            let words = folders.count == 1 ? "\"\(Paths.lastComponent(folders[0]))\" and its subfolders" : "\(folders.count) selected folders"
            return (folders, words, folders.contains(where: { isNetwork($0) }))
        case .thisDrive:
            let r = driveRoot(here)
            let name = vols.first(where: { $0.path == r })?.name ?? r
            return ([r], "the drive \"\(name)\"", isNetwork(r))
        case .allLocalDrives:
            let local = vols.filter { $0.isLocal }
            return (local.map { $0.path }, "all \(local.count) local drive\(local.count == 1 ? "" : "s")", false)
        case .thisNetworkLocation:
            let r = driveRoot(here)
            if !isNetwork(r) {
                showMessage("This folder is not on a network location", "Open a folder on a network drive first, or choose another place to search.")
                return nil
            }
            let name = vols.first(where: { $0.path == r })?.name ?? r
            return ([r], "the network location \"\(name)\"", true)
        case .allLocations:
            return (vols.map { $0.path }, "all \(vols.count) mounted location\(vols.count == 1 ? "" : "s")", vols.contains(where: { !$0.isLocal }))
        }
    }

    func startSearch() {
        let q = search.query()
        let compiled: CompiledQuery
        do {
            compiled = try CompiledQuery(q)
        } catch {
            showMessage("Search can't start", "\(error)")
            return
        }
        if !compiled.hasConditions {
            showMessage("Nothing to search for", "Type part of a name, or open More and set a condition.")
            return
        }
        guard let scope = searchRoots(search.scope) else { return }
        stopSearch()
        // Index or direct: the index is only used where one exists, when it's switched on, and for name-type searches.
        var indexScanner: IndexScanner? = nil
        var directReason = ""
        if !search.useIndex {
            directReason = "Use index is off"
        } else if !q.indexCanAnswer {
            directReason = "size and date conditions are always checked on disk"
        } else if scope.network {
            directReason = "network locations are not indexed"
        } else if let sc = App.indexes.scanner(for: scope.roots) {
            indexScanner = sc
        } else {
            directReason = App.indexes.roots.isEmpty ? "no folders are indexed" : (App.indexes.enabled ? "no index covers these folders" : "indexes are switched off")
        }
        let engine: SearchEngine
        do {
            engine = try SearchEngine(query: q, roots: scope.roots, scanner: indexScanner ?? PosixScanner(),
                                      workers: scope.network ? Prefs.netSearchReaders : 4,
                                      isPackage: { p, ext in KindCache.shared.isPackage(path: p, ext: ext) })
        } catch {
            showMessage("Search can't start", "\(error)")
            return
        }
        engine.validateHits = indexScanner != nil
        list.showMatchColumn = q.mode == .similar
        saveTabState()
        lastSummary = nil
        // A search replaces an Include-subfolders view (its walk is stopped).
        recursiveToken += 1
        recursiveRoot = nil
        list.beginResults()
        search.show(true)
        search.running = true
        window?.title = "Search: \(q.text.isEmpty ? "conditions" : q.text)"
        let words = scope.words
        searchStatus = "Searching \(words)\u{2026}"
        updateStatus()
        overlay.isHidden = true
        App.log.info("Search started in \(words): \(q.describe). Roots: \(scope.roots.joined(separator: ", "))")
        engine.onResults = { [weak self] batch in
            DispatchQueue.main.async {
                guard let s = self, s.searchEngine === engine else { return }
                s.list.appendResults(batch)
                s.updateStatus()
            }
        }
        engine.onProgress = { [weak self] p in
            DispatchQueue.main.async {
                guard let s = self, s.searchEngine === engine else { return }
                s.searchStatus = "Searching \(words): \(p.foldersSearched) folders, \(p.matches) matches, " +
                    String(format: "%.1f s", p.seconds) + ". Now in \(p.currentFolder)"
                s.updateStatus()
            }
        }
        searchEngine = engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var summary = engine.run()
            if let sc = indexScanner {
                summary.method = "index (\(sc.foldersFromIndex) unchanged folders answered from the index, \(sc.foldersFromDisk) changed or new folders read from disk; every match re-checked on disk)"
                App.indexes.saveDirty()
            } else {
                summary.method = "direct (every folder read from disk; \(directReason))"
            }
            DispatchQueue.main.async {
                guard let s = self, s.searchEngine === engine else { return }
                s.searchEngine = nil
                s.search.running = false
                s.list.endResults()
                s.lastSummary = summary
                s.searchStatus = summary.statusLine
                s.updateStatus()
                for line in summary.reportLines() { App.log.info("Search: \(line)") }
            }
        }
    }

    func stopSearch() {
        if let e = searchEngine {
            e.cancel()
            App.log.info("Search stopped by user")
        }
    }

    /// Leave search: stop it, hide the bar, show the folder again.
    func endSearchUI(reload: Bool = true) {
        if let e = searchEngine {
            e.cancel()
            searchEngine = nil
        }
        search.running = false
        let wasResults = list.resultsMode
        search.show(false)
        search.field.stringValue = ""
        pendingSearchFolders = []
        if wasResults && reload {
            list.load(currentPath, selectPaths: tabs[active].selection, showHidden: Prefs.showHidden)
            updateTitle()
        }
    }

    func showSearchReport(_ s: SearchSummary) {
        let r = Report(title: "Find Search Report")
        r.addSummary("RESULT \(s.outcome.rawValue)")
        r.addSummary(s.statusLine)
        for f in s.failed.prefix(20) { r.addSummary("NOT SEARCHED: \(f.path) - \(f.reason)") }
        for l in s.reportLines() { r.add(l) }
        let text = r.render()
        App.lastReport = text
        let a = ThemedAlert()
        switch s.outcome {
        case .complete: a.messageText = "Search complete"
        case .stopped: a.messageText = "Search stopped (incomplete)"
        case .interrupted: a.messageText = "Search interrupted: the connection was lost (incomplete)"
        case .unavailable: a.messageText = "Search location unavailable"
        case .restricted: a.messageText = "Search incomplete: some folders could not be opened (permission)"
        case .partial: a.messageText = "Search incomplete"
        }
        var lines = s.reportLines()
        if lines.count > 30 { lines = Array(lines.prefix(30)) + ["\u{2026} (Copy Report for everything)"] }
        a.informativeText = lines.joined(separator: "\n")
        a.alertStyle = s.isComplete ? .informational : .warning
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Copy Report")
        if a.runModal() == .alertSecondButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }
}
