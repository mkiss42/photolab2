// Platform.swift
// macOS primitives that change user files. One of the three source files allowed to change
// anything on disk (tools/check_mutations.sh).

import Foundation
import Darwin

enum Platform {
    /// Rename that never replaces an existing item. Returns 0 or an errno.
    /// - Same item under another case ("IMG.jpg" -> "img.jpg" on a case-insensitive volume): allowed.
    /// - Volumes without exclusive rename (some SMB servers): the target was checked free just
    ///   before; a plain rename is used.
    static func renameExclusive(_ from: String, _ to: String) -> Int32 {
        var a = stat(), b = stat()
        if lstat(from, &a) != 0 { return errno }
        if lstat(to, &b) == 0 {
            if a.st_dev == b.st_dev && a.st_ino == b.st_ino {
                return rename(from, to) == 0 ? 0 : errno
            }
            return EEXIST
        }
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let e = errno
        if e == ENOTSUP || e == EINVAL {
            if lstat(to, &b) == 0 { return EEXIST }
            return rename(from, to) == 0 ? 0 : errno
        }
        return e
    }

    /// New empty folder; fails with EEXIST rather than touching an existing one.
    static func makeFolder(_ path: String) -> Int32 {
        return mkdir(path, 0o777) == 0 ? 0 : errno
    }

    /// Move to the Trash of the item's volume. Returns the item's path inside the Trash.
    static func moveToTrash(_ path: String) -> (trashed: String?, error: String?) {
        var out: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
            return (out?.path, nil)
        } catch {
            return (nil, (error as NSError).localizedDescription)
        }
    }
}
