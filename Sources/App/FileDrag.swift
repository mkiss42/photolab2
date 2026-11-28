// FileDrag.swift
// Drag and drop of files: from the list, the thumbnail grid and Finder, onto folders in the list or
// grid, onto the empty part of any pane (= that pane's folder) and onto sidebar places.
//
// Finder rules: same drive = move, other drive = copy, Option = copy, Command = move.
// Every drop goes through BrowserPane.transfer, the same verified, never-overwriting copy / move as
// Paste (name clashes are asked about; cross-drive moves keep the copy, verify it, then Trash the
// original). Dropping a folder onto itself or into its own subfolder is refused before anything starts.

import AppKit

extension Notification.Name {
    /// userInfo["folders"]: [String] folders whose contents changed (panes showing them reload).
    static let findFoldersChanged = Notification.Name("FindFoldersChanged")
}

enum FileDrag {
    /// The older "list of file paths" form some apps still read (VLC and other long-lived apps; Finder
    /// puts it on every drag too). 0.17.3: added next to the file URLs. `paths` nil: taken from the URLs.
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func addFilenames(_ pb: NSPasteboard, _ paths: [String]?) {
        let list: [String]
        if let p = paths {
            list = p
        } else {
            let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            list = (pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?.map { $0.path } ?? []
        }
        guard !list.isEmpty else { return }
        _ = pb.addTypes([filenamesType], owner: nil)
        _ = pb.setPropertyList(list, forType: filenamesType)
    }

    static var types: [NSPasteboard.PasteboardType] { return [.fileURL, FTPDragPayload.type] }

    // NSDraggingInfo members are methods in the 10.13 SDK (Swift 4.1) and properties from Swift 4.2.
    static func pasteboard(_ info: NSDraggingInfo) -> NSPasteboard {
        #if swift(>=4.2)
        return info.draggingPasteboard
        #else
        return info.draggingPasteboard()
        #endif
    }

    static func sourceMask(_ info: NSDraggingInfo) -> NSDragOperation {
        #if swift(>=4.2)
        return info.draggingSourceOperationMask
        #else
        return info.draggingSourceOperationMask()
        #endif
    }

    static func location(_ info: NSDraggingInfo) -> NSPoint {
        #if swift(>=4.2)
        return info.draggingLocation
        #else
        return info.draggingLocation()
        #endif
    }

    /// The file paths being dragged (file URLs only).
    static func paths(_ info: NSDraggingInfo) -> [String] {
        let objs = pasteboard(info).readObjects(forClasses: [NSURL.self],
                                                options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) ?? []
        var out: [String] = []
        for o in objs {
            if let u = o as? URL, u.isFileURL { out.append(u.path) } else if let u = o as? NSURL, let p = u.path { out.append(p) }
        }
        // PhotoLab sets: the other files of dragged set rows (this drag only).
        if let x = setDragExtra, x.stamp == pasteboard(info).changeCount {
            for p in x.paths where !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// PhotoLab: the members of set rows in the current list drag (pasteboard change count, paths).
    static var setDragExtra: (stamp: Int, paths: [String])?

    /// FTP items being dragged (set while hovering; used when they are dropped).
    static var ftpDropPayload: FTPDragPayload?

    /// The files of a drag started in Photography mode (their XMP sidecars go along when dropped).
    static var photoDrag: Set<String>?
    /// NSPasteboard.general.changeCount right after a copy in Photography mode (-1: none).
    static var photoClipboardStamp = -1

    // Drive of each folder/item, remembered for one drag (hovering asks many times; network shares are slow).
    private static var cacheStamp = -1
    private static var devices: [String: UInt64] = [:]

    private static func device(_ path: String, follow: Bool) -> UInt64? {
        if let d = devices[path] { return d }
        var e: Int32 = 0
        guard let info = follow ? Sys.statInfo(path, &e) : Sys.lstatInfo(path, &e) else { return nil }
        devices[path] = info.device
        return info.device
    }

    /// What dropping `sources` into `dest` would do: .move, .copy, or [] (refused).
    static func operation(_ info: NSDraggingInfo, sources: [String], dest: String) -> NSDragOperation {
        let stamp = pasteboard(info).changeCount
        if stamp != cacheStamp {
            cacheStamp = stamp
            devices.removeAll()
        }
        if sources.isEmpty {
            // 0.16: files dragged out of an FTP pane: downloaded into a local folder (copy only).
            ftpDropPayload = FTPDragPayload.read(pasteboard(info))
            if ftpDropPayload != nil {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: dest, isDirectory: &isDir) && isDir.boolValue ? .copy : []
            }
            return []
        }
        ftpDropPayload = nil
        for s in sources {
            // Onto itself, or into its own subfolder.
            if s == dest || Paths.isInside(dest, root: s) { return [] }
        }
        // Already in that folder: nothing to do.
        if sources.allSatisfyCompat({ Paths.parent($0) == dest }) { return [] }
        let mask = sourceMask(info)
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let canMove = mask.contains(.move) || mask.contains(.generic)
        if flags.contains(.option) { return mask.contains(.copy) ? .copy : [] }
        if flags.contains(.command) && canMove { return .move }
        if mask == .generic { return .move }
        let same: Bool
        let reg = VolumeRegistry.shared
        if reg.treatAsNetwork(dest) || reg.treatAsNetwork(sources[0]) {
            // Network share at either end: compare the shares by name - no request to a server while hovering.
            same = VolumeRegistry.volumeRoot(dest) == VolumeRegistry.volumeRoot(sources[0])
        } else {
            guard let dd = device(dest, follow: true) else { return [] }
            same = device(sources[0], follow: false).map { $0 == dd } ?? false
        }
        if same && canMove { return .move }
        if mask.contains(.copy) { return .copy }
        if canMove { return .move }
        return []
    }

    /// A list or grid entry that can receive a drop (a folder or volume, not an app or other package).
    static func isDropFolder(_ e: FileEntry) -> Bool {
        if !e.isFolderLike { return false }
        if e.ext == "app" || KindCache.shared.isPackage(e) { return false }
        return true
    }
}

extension BrowserPane {
    /// The folder a drop on the empty part of this pane goes into (nil in search results).
    var dropFolder: String? {
        if list.resultsMode || currentPath.isEmpty { return nil }
        return currentPath
    }

    /// Perform a drop. Runs after the drag has finished (questions about name clashes may follow).
    func dropFiles(_ paths: [String], into dest: String, move: Bool) {
        if paths.isEmpty, let ftp = FileDrag.ftpDropPayload {
            FileDrag.ftpDropPayload = nil
            App.log.info("DROP \(ftp.items.count) FTP item(s) into \(dest): download")
            downloadFTP(ftp, into: dest)
            return
        }
        let sources = paths
        DispatchQueue.main.async { [weak self] in
            guard let s = self else { return }
            App.log.info("DROP \(move ? "move" : "copy") \(sources.count) item(s) into \(dest)")
            for p in sources { App.log.info("DROP item \(p)") }
            let folders = Array(Set(sources.map { Paths.parent($0) } + [dest]))
            let fromPhotoMode = FileDrag.photoDrag.map { $0 == Set(sources) } ?? false
            s.transfer(sources, into: dest, move: move, withSidecars: fromPhotoMode) { _ in
                NotificationCenter.default.post(name: .findFoldersChanged, object: s, userInfo: ["folders": folders])
            }
        }
    }
}
