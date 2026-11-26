// Favorites.swift
// The sidebar's Favorites (also shown by the menu bar icon): an ordered list of folders the user
// edits by dragging folders in, dragging to reorder and "Remove from Sidebar". Kept in
// UserDefaults. Pure list logic here (self-tested); the views live in the App layer.

import Foundation

struct Favorite: Equatable {
    let title: String
    let path: String
}

extension Notification.Name {
    static let favoritesChanged = Notification.Name("PhotoLabFavoritesChanged")
}

enum Favorites {
    private static let key = "sidebarFavorites"

    static var defaults: [Favorite] {
        let home = NSHomeDirectory()
        return [Favorite(title: NSUserName(), path: home)]
            + ["Desktop", "Documents", "Downloads", "Pictures"].map { Favorite(title: $0, path: home + "/" + $0) }
    }

    static var all: [Favorite] {
        get {
            guard let raw = UserDefaults.standard.array(forKey: key) as? [[String]] else { return defaults }
            return raw.compactMap { $0.count == 2 ? Favorite(title: $0[0], path: $0[1]) : nil }
        }
        set {
            UserDefaults.standard.set(newValue.map { [$0.title, $0.path] }, forKey: key)
            NotificationCenter.default.post(name: .favoritesChanged, object: nil)
        }
    }

    /// Folders added at `index` (clamped); ones already in the list move there instead.
    static func inserting(_ paths: [String], at index: Int, into list: [Favorite]) -> [Favorite] {
        var out = list.filter { f in !paths.contains(f.path) }
        let removedBefore = list.prefix(max(0, min(index, list.count))).filter { paths.contains($0.path) }.count
        let at = max(0, min(index - removedBefore, out.count))
        let added = paths.map { p in list.first(where: { $0.path == p }) ?? Favorite(title: Paths.name(p).isEmpty ? p : Paths.name(p), path: p) }
        out.insert(contentsOf: added, at: at)
        return out
    }

    static func removing(_ path: String, from list: [Favorite]) -> [Favorite] {
        return list.filter { $0.path != path }
    }
}
