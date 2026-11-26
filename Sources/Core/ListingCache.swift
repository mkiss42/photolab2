// ListingCache.swift
// Short-lived memory of folder listings. Coming back to a folder within 2 minutes costs one stat
// of the folder ("did its contents change?") instead of a full listing. Adding, removing or
// renaming an item changes the folder's mtime; in-place edits of files are caught by the
// folder watcher and by Refresh. Memory only, 40 folders.

import Foundation
import Darwin

final class ListingCache {
    static let shared = ListingCache()

    struct Item {
        let listing: FolderListing
        let folderMtime: Double
        let storedAt: Date
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var order: [String] = []
    let maxFolders = 40
    let maxAge: TimeInterval = 120

    /// Folder mtime via stat (follows the folder itself only). nil when unreadable.
    static func folderMtime(_ path: String) -> Double? {
        var st = stat()
        if stat(path, &st) != 0 { return nil }
        return DirectoryReader.seconds(st.st_mtimespec)
    }

    /// A cached listing still valid for `path`, given the folder's current mtime.
    func lookup(_ path: String, currentMtime: Double?, now: Date = Date()) -> FolderListing? {
        lock.lock(); defer { lock.unlock() }
        guard let it = items[path] else { return nil }
        guard let m = currentMtime, m == it.folderMtime, now.timeIntervalSince(it.storedAt) < maxAge else {
            remove(path)
            return nil
        }
        return it.listing
    }

    func store(_ path: String, listing: FolderListing, folderMtime: Double?, now: Date = Date()) {
        // Empty listings are not kept: they are cheap to re-read and an empty answer from a busy
        // server must not stick.
        guard let m = folderMtime, listing.error == 0, !listing.cancelled, !listing.entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        remove(path)
        items[path] = Item(listing: listing, folderMtime: m, storedAt: now)
        order.append(path)
        while order.count > maxFolders {
            items.removeValue(forKey: order.removeFirst())
        }
    }

    func invalidate(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        remove(path)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll(); order.removeAll()
    }

    private func remove(_ path: String) {
        items.removeValue(forKey: path)
        if let i = order.firstIndex(of: path) { order.remove(at: i) }
    }
}
