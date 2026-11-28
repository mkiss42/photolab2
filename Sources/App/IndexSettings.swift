// IndexSettings.swift
// Settings > Search Index: choose folders to index, build/rebuild, exclude sub-folders, remove, switch off.

import AppKit

final class IndexSettingsController: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))
    private let enabledCheck = NSButton(checkboxWithTitle: "Use search indexes (searches still re-read any folder that changed)", target: nil, action: nil)
    private let rows = NSStackView()
    private let totalLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Stop Building", target: nil, action: nil)
    private var building: SearchEngine?
    /// Folders still to build after the current one (Delete and Rebuild Indexes).
    private var rebuildQueue: [String] = []

    /// Build every indexed folder again, one after another. Folders that can't be reached now
    /// (e.g. a share that isn't mounted) are skipped and named; their indexes are built later with Build.
    func rebuildAll() {
        var e: Int32 = 0
        let all = App.indexes.roots.map { $0.root }
        let reachable = all.filter { r in
            VolumeRegistry.shared.treatAsNetwork(r) ? VolumeRegistry.shared.isMounted(VolumeRegistry.volumeRoot(r)) : Sys.statInfo(r, &e) != nil
        }
        let skipped = all.filter { !reachable.contains($0) }
        for r in skipped { App.log.warn("Index rebuild skipped (not reachable now): \(r)") }
        rebuildQueue = reachable
        if let first = rebuildQueue.first {
            rebuildQueue.removeFirst()
            startBuild(first)
        }
        if !skipped.isEmpty {
            message("Some indexes were not rebuilt", "These folders can't be reached right now (not mounted or not connected). Use Build when they are back:\n" + skipped.joined(separator: "\n"))
        }
    }
    private var buildButtons: [NSButton] = []

    override init() {
        super.init()
        enabledCheck.target = self
        enabledCheck.action = #selector(enabledChanged(_:))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        let add = NSButton(title: "Add Folder", target: self, action: #selector(addFolder(_:)))
        let deleteAll = NSButton(title: "Delete All Index Files", target: self, action: #selector(deleteAll(_:)))
        buildButtons = [add, deleteAll]
        cancelButton.target = self
        cancelButton.action = #selector(stopBuilding(_:))
        cancelButton.isHidden = true
        progressLabel.textColor = NSColor.secondaryLabelColor
        totalLabel.textColor = NSColor.secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: "Index only folders you search often and that live on this Mac's drives. An index stores names, sizes and dates only, never file contents. PhotoLab checks every indexed folder for changes at search time and re-reads changed folders, so results always match the disk. Searches with size or date conditions, network locations, and searches with Use index unticked always read folders directly.")
        note.textColor = NSColor.secondaryLabelColor
        let buttons = NSStackView(views: [add, deleteAll, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [enabledCheck, rows, buttons, progressLabel, totalLabel, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            note.widthAnchor.constraint(equalToConstant: 530),
        ])
        refresh()
    }

    private func dateText(_ t: Double) -> String {
        if t <= 0 { return "--" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    func refresh() {
        enabledCheck.state = App.indexes.enabled ? .on : .off
        for v in rows.arrangedSubviews {
            rows.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let roots = App.indexes.roots
        if roots.isEmpty {
            let l = NSTextField(labelWithString: "No folders are indexed. Searches read folders directly.")
            l.textColor = NSColor.secondaryLabelColor
            rows.addArrangedSubview(l)
        }
        for r in roots {
            let st = App.indexes.status(r.root)
            let title = NSTextField(labelWithString: r.root)
            title.font = NSFont.boldSystemFont(ofSize: 12)
            title.lineBreakMode = .byTruncatingMiddle
            title.translatesAutoresizingMaskIntoConstraints = false
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
            var info = st.valid
                ? "\(st.reason): \(st.items) items in \(st.folders) folders, \(Listing.sizeText(st.bytesOnDisk)) on disk, built \(dateText(st.builtAt))"
                : st.reason
            if !st.excluded.isEmpty { info += "\nExcluded: " + st.excluded.map { Paths.lastComponent($0) }.joined(separator: ", ") }
            let infoLabel = NSTextField(wrappingLabelWithString: info)
            infoLabel.textColor = st.valid ? NSColor.secondaryLabelColor : NSColor.systemOrange
            infoLabel.translatesAutoresizingMaskIntoConstraints = false
            infoLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
            let rebuild = NSButton(title: st.exists ? "Rebuild" : "Build", target: self, action: #selector(rebuild(_:)))
            rebuild.identifier = itemID(r.root)
            let exclude = NSButton(title: "Exclude Folder", target: self, action: #selector(exclude(_:)))
            exclude.identifier = itemID(r.root)
            let clear = NSButton(title: "Clear Exclusions", target: self, action: #selector(clearExclusions(_:)))
            clear.identifier = itemID(r.root)
            clear.isHidden = r.excluded.isEmpty
            let remove = NSButton(title: "Remove", target: self, action: #selector(remove(_:)))
            remove.identifier = itemID(r.root)
            for b in [rebuild, exclude, clear, remove] { b.isEnabled = building == nil }
            let buttons = NSStackView(views: [rebuild, exclude, clear, remove])
            buttons.orientation = .horizontal
            buttons.spacing = 6
            let block = NSStackView(views: [title, infoLabel, buttons])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 4
            rows.addArrangedSubview(block)
        }
        totalLabel.stringValue = "Index files use \(Listing.sizeText(App.indexes.totalBytesOnDisk)) in ~/Library/Application Support/PhotoLab/Indexes"
        for b in buildButtons { b.isEnabled = building == nil }
    }

    private func message(_ title: String, _ text: String) {
        let a = ThemedAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        App.indexes.enabled = sender.state == .on
        App.log.info("Search indexes \(App.indexes.enabled ? "on" : "off")")
    }

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Index This Folder"
        panel.message = "Choose a folder you search often (on this Mac's drives, not a network location)."
        guard panel.runModal() == .OK, let p = panel.url?.path else { return }
        let vroot = Sys.volumeRoot(of: p)
        if let v = Volumes.mounted().first(where: { $0.path == vroot }), !v.isLocal {
            message("Network locations can't be indexed", "Changes made on the server by other computers can't be detected reliably, so network searches always read folders directly.")
            return
        }
        if let why = App.indexes.addRoot(p) {
            message("That folder can't be added", why)
            return
        }
        App.log.info("Index folder added: \(p)")
        startBuild(p)
    }

    @objc private func rebuild(_ sender: NSButton) {
        guard let root = sender.identifier?.rawValue else { return }
        startBuild(root)
    }

    private func startBuild(_ root: String) {
        progressLabel.stringValue = "Building index for \(Paths.lastComponent(root))\u{2026}"
        cancelButton.isHidden = false
        App.log.info("Index build started: \(root)")
        let started = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let summary = App.indexes.build(root, onProgress: { p in
                DispatchQueue.main.async {
                    self?.progressLabel.stringValue = "Building index for \(Paths.lastComponent(root)): \(p.foldersSearched) folders read\u{2026}"
                }
            }, cancel: { engine in
                DispatchQueue.main.async {
                    self?.building = engine
                    self?.refresh()
                }
            })
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.building = nil
                s.cancelButton.isHidden = true
                let secs = String(format: "%.1f s", Date().timeIntervalSince(started))
                if let sm = summary {
                    if sm.cancelled {
                        s.progressLabel.stringValue = "Building stopped. The old index (if any) is unchanged."
                    } else {
                        let probs = sm.failed.count + sm.entryProblems.count
                        s.progressLabel.stringValue = "Index built in \(secs): \(sm.foldersSearched) folders, \(sm.itemsExamined) items." +
                            (probs > 0 ? " \(probs) location(s) could not be read; searches read them directly." : "")
                    }
                    for l in sm.reportLines() { App.log.info("Index build: \(l)") }
                } else {
                    s.progressLabel.stringValue = "The folder could not be opened."
                }
                s.refresh()
                if let next = s.rebuildQueue.first, summary?.cancelled != true {
                    s.rebuildQueue.removeFirst()
                    s.startBuild(next)
                } else {
                    s.rebuildQueue = []
                }
            }
        }
    }

    @objc private func stopBuilding(_ sender: Any?) {
        building?.cancel()
    }

    @objc private func exclude(_ sender: NSButton) {
        guard let root = sender.identifier?.rawValue else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.prompt = "Exclude"
        panel.message = "Choose a folder inside \(Paths.lastComponent(root)) to leave out of the index (it is still searched, directly)."
        guard panel.runModal() == .OK, let p = panel.url?.path else { return }
        guard Paths.isInside(p, root: root), p != root else {
            message("Choose a folder inside the indexed folder", root)
            return
        }
        var ex = App.indexes.roots.first(where: { $0.root == root })?.excluded ?? []
        if !ex.contains(p) { ex.append(p) }
        App.indexes.setExcluded(root, ex)
        refresh()
    }

    @objc private func clearExclusions(_ sender: NSButton) {
        guard let root = sender.identifier?.rawValue else { return }
        App.indexes.setExcluded(root, [])
        refresh()
    }

    @objc private func remove(_ sender: NSButton) {
        guard let root = sender.identifier?.rawValue else { return }
        let a = ThemedAlert()
        a.messageText = "Stop indexing \"\(Paths.lastComponent(root))\"?"
        a.informativeText = "Its index file is deleted. The folder itself is not touched."
        a.addButton(withTitle: "Remove Index")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        App.indexes.removeRoot(root)
        App.log.info("Index folder removed: \(root)")
        refresh()
    }

    @objc private func deleteAll(_ sender: Any?) {
        let a = ThemedAlert()
        a.messageText = "Delete all index files?"
        a.informativeText = "The list of indexed folders is kept; use Build to make the indexes again. Your folders are not touched."
        a.addButton(withTitle: "Delete Index Files")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        App.indexes.deleteAllIndexFiles()
        App.log.info("All index files deleted")
        refresh()
    }
}
