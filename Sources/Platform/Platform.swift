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

    // MARK: Copy primitives (used by FileOperations' transfer engine)

    /// Copy a regular file's bytes into a NEW file (O_EXCL: never an existing one), in 8 MB
    /// chunks. `progress(n)` runs after each chunk; returning false stops the copy. On any error or
    /// stop the new file is removed. Returns 0, an errno, or ECANCELED when stopped.
    /// close() is checked: SMB reports some write errors only there.
    static func copyData(_ from: String, _ to: String, progress: (Int64) -> Bool) -> Int32 {
        let src = open(from, O_RDONLY)
        if src < 0 { return errno }
        defer { close(src) }
        let dst = open(to, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
        if dst < 0 { return errno }
        let chunk = 8 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        var err: Int32 = 0
        copying: while true {
            let n = read(src, buf, chunk)
            if n < 0 { if errno == EINTR { continue }; err = errno; break }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = write(dst, buf.advanced(by: off), n - off)
                if w < 0 { if errno == EINTR { continue }; err = errno; break copying }
                off += w
            }
            if !progress(Int64(n)) { err = ECANCELED; break }
        }
        if close(dst) != 0 && err == 0 { err = errno }
        if err != 0 { _ = unlink(to) }
        return err
    }

    /// Same-volume copy as an APFS clone (instant, no data read). Fails (ENOTSUP...) on volumes
    /// that can't clone; the caller then copies the bytes. Never replaces an existing file.
    static func cloneFile(_ from: String, _ to: String) -> Int32 {
        return copyfile(from, to, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 ? 0 : errno
    }

    /// Extended attributes (Finder tags and labels, quarantine...), mode, flags and dates of
    /// `from` onto the existing `to`. One call: every extra call is a round trip on a share.
    static func copyMetadata(_ from: String, _ to: String) -> Int32 {
        return copyfile(from, to, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_STAT)) == 0 ? 0 : errno
    }

    /// Creation and modification dates (copyfile does not carry the creation date).
    static func setDates(_ path: String, created: Double, modified: Double) -> Int32 {
        func ts(_ t: Double) -> timespec {
            let s = floor(t)
            return timespec(tv_sec: Int(s), tv_nsec: Int((t - s) * 1_000_000_000))
        }
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        var buf: [timespec]
        if created > 0 {
            al.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
            buf = [ts(created), ts(modified)]
        } else {
            al.commonattr = attrgroup_t(ATTR_CMN_MODTIME)
            buf = [ts(modified)]
        }
        let r = buf.withUnsafeMutableBytes { p -> Int32 in
            return setattrlist(path, &al, p.baseAddress, p.count, numericCast(FSOPT_NOFOLLOW))
        }
        return r == 0 ? 0 : errno
    }

    /// A new symbolic link at `to` pointing where the link `from` points.
    static func copySymlink(_ from: String, _ to: String) -> Int32 {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(from, &buf, buf.count - 1)
        if n < 0 { return errno }
        buf[n] = 0
        return symlink(buf, to) == 0 ? 0 : errno
    }

    /// Remove one file. Only for a moved file whose verified copy is in place, or a partial copy
    /// PhotoLab itself made.
    static func removeFile(_ path: String) -> Int32 {
        return unlink(path) == 0 ? 0 : errno
    }

    /// Remove a folder only if it is empty (ENOTEMPTY otherwise: something new is in it).
    static func removeEmptyFolder(_ path: String) -> Int32 {
        return rmdir(path) == 0 ? 0 : errno
    }

    /// Set (or, with empty data, remove) one extended attribute of one item, not following links.
    static func setAttribute(_ path: String, _ name: String, _ data: Data) -> Int32 {
        if data.isEmpty {
            let r = removexattr(path, name, XATTR_NOFOLLOW)
            return r == 0 || errno == ENOATTR ? 0 : errno
        }
        let r = data.withUnsafeBytes { p in setxattr(path, name, p.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        return r == 0 ? 0 : errno
    }
}
