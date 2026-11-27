// DarwinPlatform.swift
// macOS primitives for FileOperations: atomic no-overwrite rename, Trash, copy.
// Foundation + Darwin only (no AppKit).

import Darwin
import Foundation
#if os(macOS)
import NetFS
import Security
#endif

final class DarwinPlatform: FilePlatform {
    var log: ((String) -> Void)?

    /// renamex_np with RENAME_EXCL (0x4): the kernel refuses atomically if `dst` exists.
    func exclusiveRename(_ src: String, _ dst: String) throws {
        if renamex_np(src, dst, UInt32(0x4)) == 0 { return }
        let e = errno
        if e == EEXIST { throw FileOpError.targetExists(dst) }
        if e == ENOENT && !Sys.exists(src) { throw FileOpError.notFound(src) }
        if e == ENOTSUP || e == EINVAL {
            // Some network filesystems don't support RENAME_EXCL. Check, then rename.
            // There is a tiny window between the check and the rename; this is logged.
            if Sys.exists(dst) { throw FileOpError.targetExists(dst) }
            log?("NOTE exclusive rename not supported here; used checked rename: \(src) -> \(dst)")
            if Darwin.rename(src, dst) == 0 { return }
            let e2 = errno
            throw FileOpError.system("Rename", e2, src)
        }
        throw FileOpError.system("Rename", e, src)
    }

    /// 0.18.14: see FilePlatform. rename(2) replaces the target in one step (also on SMB 2/3).
    func replaceWithVerified(_ temp: String, _ target: String) throws {
        guard replaceAllowed(temp, target) else { throw FileOpError.refused("E-GUARD-3 refused to replace \(target) with \(temp)") }
        if Darwin.rename(temp, target) != 0 { throw FileOpError.system("Rename", errno, temp) }
    }

    /// Self-tests only (0.18): a scratch folder used instead of the real Trash, so test files never
    /// end up in the user's Trash. nil (always, in normal use) = the macOS Trash.
    var trashOverride: String?

    func moveToTrash(_ path: String) throws -> String {
        if let t = trashOverride {
            _ = try? FileManager.default.createDirectory(atPath: t, withIntermediateDirectories: true, attributes: nil)
            let dst = Paths.join(t, FileOperations.uniqueName(for: Paths.lastComponent(path), in: t))
            try exclusiveRename(path, dst)
            return dst
        }
        var resulting: NSURL? = nil
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        } catch {
            let ns = error as NSError
            throw FileOpError.trashUnavailable(path, ns.localizedDescription)
        }
        if let r = resulting, let p = r.path {
            return p
        }
        // Trashed, but macOS didn't say where. It can still be found in the Trash by name.
        return ""
    }

    func copyItem(_ src: String, _ dst: String, onFile: ((String, String, Int64) -> Bool)?) throws {
        if Sys.exists(dst) { throw FileOpError.targetExists(dst) }
        // 0.17.1: a FileManager of its own with a watcher, told before each item is copied.
        let fm = FileManager()
        let watcher = CopyWatcher(onFile)
        #if os(macOS)
        fm.delegate = watcher
        #endif
        do {
            try withExtendedLifetime(watcher) { try fm.copyItem(atPath: src, toPath: dst) }
        } catch {
            if watcher.stopped { throw FileOpError.cancelled }
            if let f = watcher.failure { throw FileOpError.refused(f) }
            // A single big file Find copied itself: FileManager may count "skipped" as not done. The copy
            // is there; FileOperations checks it against the original next anyway.
            if watcher.copiedOurselves.contains(src) && Sys.exists(dst) { return }
            let ns = error as NSError
            throw FileOpError.refused("Copy of \"\(Paths.lastComponent(src))\" failed: \(ns.localizedDescription)")
        }
        if watcher.stopped { throw FileOpError.cancelled }
        if let f = watcher.failure { throw FileOpError.refused(f) }
    }

    /// Free space where `path` is (statfs; quick, also on shares).
    func freeBytes(_ path: String) -> Int64? {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let n = a[.systemFreeSize] as? NSNumber else { return nil }
        return n.int64Value
    }
}

/// Told by FileManager before each item of a copy. Once Stop is asked, every remaining item is skipped
/// (the copy ends quickly, incomplete) and the caller throws "cancelled" - the unfinished copy is then
/// moved to the Trash by FileOperations, as always.
private final class CopyWatcher: NSObject {
    let onFile: ((String, String, Int64) -> Bool)?
    private(set) var stopped = false

    init(_ onFile: ((String, String, Int64) -> Bool)?) {
        self.onFile = onFile
    }

    /// A copy of a big file that Find did itself failed (e.g. the disk is full): the whole copy fails.
    private(set) var failure: String?
    /// Files Find copied itself (FileManager was told to skip them).
    private(set) var copiedOurselves = Set<String>()

    func fileManager(_ fileManager: FileManager, shouldCopyItemAtPath srcPath: String, toPath dstPath: String) -> Bool {
        if stopped || failure != nil { return false }
        guard let f = onFile else { return true }
        var e: Int32 = 0
        let info = Sys.lstatInfo(srcPath, &e)
        if info?.isDirectory == true { return true }
        if !f(srcPath, dstPath, info?.size ?? 0) { stopped = true; return false }
        // 0.17.3: a big file is copied by Find itself, so Stop can end it in the middle (the half copy
        // goes to the Trash with the rest). FileManager then skips it (it's done already).
        if let i = info, i.isRegular, i.size >= BigFileCopy.threshold, BigFileCopy.available {
            switch BigFileCopy.copy(srcPath, dstPath, stop: { !f(srcPath, dstPath, -1) }) {   // size -1: "go on?"
            case .done:
                copiedOurselves.insert(srcPath)
                return false
            case .stopped: stopped = true; return false
            case .failed(let why): failure = "Copy of \"\(Paths.lastComponent(srcPath))\" failed: \(why)"; return false
            }
        }
        return true
    }
}

/// 0.17.3: copying one big file with macOS's copyfile() - the same copy (contents, dates, tags,
/// permissions, extended attributes) - but asking "stop?" while the data is being written, so Stop
/// ends it within a moment instead of after the whole file. Looked up while running.
enum BigFileCopy {
    static let threshold: Int64 = 32 * 1024 * 1024

    enum Outcome { case done, stopped, failed(String) }

    private typealias CopyFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, UInt32) -> Int32
    private typealias AllocFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias SetFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeRawPointer?) -> Int32
    typealias Callback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32

    private static let fns: (CopyFn, AllocFn, FreeFn, SetFn)? = {
        guard let h = dlopen(nil, RTLD_NOW),
            let c = dlsym(h, "copyfile"), let a = dlsym(h, "copyfile_state_alloc"),
            let f = dlsym(h, "copyfile_state_free"), let st = dlsym(h, "copyfile_state_set") else { return nil }
        return (unsafeBitCast(c, to: CopyFn.self), unsafeBitCast(a, to: AllocFn.self), unsafeBitCast(f, to: FreeFn.self), unsafeBitCast(st, to: SetFn.self))
    }()

    static var available: Bool { return fns != nil }

    private final class Box {
        let stop: () -> Bool
        var stopped = false
        var lastAsk = Date.distantPast
        init(_ stop: @escaping () -> Bool) { self.stop = stop }
    }

    // copyfile.h values (stable since 10.5)
    private static let COPYFILE_ALL: UInt32 = 0xF            // ACL | STAT | XATTR | DATA
    private static let COPYFILE_EXCL: UInt32 = 1 << 17
    private static let COPYFILE_NOFOLLOW_SRC: UInt32 = 1 << 18
    private static let STATE_STATUS_CB: UInt32 = 6
    private static let STATE_STATUS_CTX: UInt32 = 7

    private static let callback: Callback = { what, stage, _, _, _, ctx in
        // what 4 = copying data, stage 4 = progress: ask whether to go on (at most 10 times a second).
        guard what == 4, stage == 4, let c = ctx else { return 0 }   // 0 = continue
        let box = Unmanaged<Box>.fromOpaque(c).takeUnretainedValue()
        let now = Date()
        if now.timeIntervalSince(box.lastAsk) < 0.1 { return 0 }
        box.lastAsk = now
        if box.stop() { box.stopped = true; return 2 }               // 2 = quit
        return 0
    }

    /// 0.18.5: extended attributes (Finder tags, labels, comments) and ACL of `src` onto the existing `dst`;
    /// not its data, not its dates.
    static func copyAttributes(_ src: String, _ dst: String) {
        guard let fn = fns else { return }
        let COPYFILE_ACL: UInt32 = 1 << 0, COPYFILE_XATTR: UInt32 = 1 << 2
        _ = fn.0(src, dst, nil, COPYFILE_ACL | COPYFILE_XATTR)
    }

    static func copy(_ src: String, _ dst: String, stop: @escaping () -> Bool) -> Outcome {
        guard let fn = fns, let state = fn.1() else { return .failed("copyfile is not available") }
        let cp = fn.0, release = fn.2, set = fn.3
        defer { _ = release(state) }
        let box = Box(stop)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<Box>.fromOpaque(ctx).release() }
        _ = set(state, STATE_STATUS_CB, unsafeBitCast(callback, to: UnsafeRawPointer.self))
        _ = set(state, STATE_STATUS_CTX, UnsafeRawPointer(ctx))
        let r = cp(src, dst, state, COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
        if box.stopped { return .stopped }
        if r != 0 {
            let e = errno
            return .failed(String(cString: strerror(e)) + (e == ENOSPC ? " - there isn't enough free space at the destination" : "") + " (code \(e))")
        }
        return .done
    }
}

#if os(macOS)
extension CopyWatcher: FileManagerDelegate {}
#endif

extension DarwinPlatform {
    /// A Finder alias (bookmark file) at `path` pointing to `target`. `path` must not exist yet.
    func makeAlias(target: String, at path: String) throws {
        if Sys.exists(path) { throw FileOpError.targetExists(path) }
        do {
            let data = try URL(fileURLWithPath: target).bookmarkData(options: .suitableForBookmarkFile,
                                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: URL(fileURLWithPath: path))
        } catch {
            throw FileOpError.refused("The alias could not be made: \(error)")
        }
    }

    /// The only permanent removal (FilePlatform docs): the previous version of a file whose metadata was
    /// rewritten and verified. Refuses anything not named with Find's temporary prefix, and folders.
    /// 0.18.5: the new version of a file (written beside it by ExifTool) gets the original's Finder tags,
    /// labels, comments and other extended attributes, its ACL, permissions and creation date. Never
    /// its modification date (the new version is a change).
    func carryAttributes(from: String, to: String) {
        BigFileCopy.copyAttributes(from, to)
        if let a = try? FileManager.default.attributesOfItem(atPath: from) {
            var keep: [FileAttributeKey: Any] = [:]
            if let c = a[.creationDate] { keep[.creationDate] = c }
            if let p = a[.posixPermissions] { keep[.posixPermissions] = p }
            if !keep.isEmpty { _ = try? FileManager.default.setAttributes(keep, ofItemAtPath: to) }
        }
    }

    /// 0.18.8: in-place metadata writes (see FilePlatform.patchFile).
    func patchFile(_ path: String, writes: [(offset: Int64, data: Data)]) throws {
        var e: Int32 = 0
        guard path.hasPrefix("/"), let st = Sys.lstatInfo(path, &e), st.isRegular else {
            throw FileOpError.refused("in-place change refused: \(path) is not a plain file")
        }
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { throw FileOpError.system("Open", errno, path) }
        defer { close(fd) }
        for w in writes {
            guard w.offset >= 0 else { throw FileOpError.refused("in-place change refused: negative offset") }
            let ok = w.data.withUnsafeBytes { (p: UnsafePointer<UInt8>) -> Bool in
                var done = 0
                while done < w.data.count {
                    let n = pwrite(fd, p + done, w.data.count - done, off_t(w.offset) + off_t(done))
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }
                    done += n
                }
                return true
            }
            if !ok { throw FileOpError.system("Write", errno, path) }
        }
        // On the disk before anything else happens (a share may not support the full flush; then fsync).
        // 0.18.11: the full flush (F_FULLFSYNC) or the normal one, as Settings say.
        // 0.18.14: or none at all (Settings: fastest, as ExifTool and most apps do).
        switch MetaPlan.flush {
        case .none: break
        case .normal: _ = fsync(fd)
        case .full:
            #if os(macOS)
            if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
            #else
            _ = fsync(fd)
            #endif
        }
    }

    func truncateFile(_ path: String, to length: Int64) throws {
        var e: Int32 = 0
        guard path.hasPrefix("/"), let st = Sys.lstatInfo(path, &e), st.isRegular, length >= 0, length <= st.size else {
            throw FileOpError.refused("truncate refused: \(path)")
        }
        if truncate(path, off_t(length)) != 0 { throw FileOpError.system("Truncate", errno, path) }
    }

    /// 0.18.4: Delete Immediately (only after your confirmation; FileOperations checks the path first).
    func deletePermanently(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            let ns = error as NSError
            // A folder may be partly deleted when something inside it can't be removed (as in Finder).
            throw FileOpError.refused("\"\(Paths.lastComponent(path))\" could not be deleted completely: \(ns.localizedDescription)")
        }
    }

    func removeReplacedOriginal(_ path: String) throws {
        guard Paths.lastComponent(path).hasPrefix(".find-rename-") else {
            throw FileOpError.refused("E-GUARD-2 refused to remove \(path): not one of Find's temporary names")
        }
        var e: Int32 = 0
        guard let info = Sys.lstatInfo(path, &e), info.isRegular else {
            throw FileOpError.refused("E-GUARD-2 refused to remove \(path): not a plain file")
        }
        if unlink(path) != 0 { throw FileOpError.system("Remove previous version", errno, path) }
    }
}

extension DarwinPlatform {
    func tagNames(_ path: String) -> [String] {
        return FinderTags.read(path).map { $0.name }
    }

    /// Finder tags via the documented NSURL tag key (metadata only; the file's contents are not touched).
    func setTagNames(_ path: String, _ names: [String]) throws {
        if !Sys.exists(path) { throw FileOpError.notFound(path) }
        do {
            try NSURL(fileURLWithPath: path).setResourceValue(names, forKey: URLResourceKey.tagNamesKey)
        } catch {
            throw FileOpError.refused("Labels could not be changed on \"\(Paths.lastComponent(path))\": \(error)")
        }
    }
}

/// Reads Finder tags (name + colour number) from the item's metadata. Read-only.
enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    static func read(_ path: String) -> [(name: String, color: Int)] {
        let size = getxattr(path, attribute, nil, 0, 0, 0x0001) // XATTR_NOFOLLOW
        if size <= 0 { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        let n = getxattr(path, attribute, &buf, size, 0, 0x0001)
        if n <= 0 { return [] }
        let data = Data(bytes: buf[0..<n])
        guard let list = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String] else { return [] }
        return list.map { s -> (name: String, color: Int) in
            let parts = s.components(separatedBy: "\n")
            let color = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            return (parts[0], color)
        }
    }

    /// Colour indexes (into ColorLabel.names) for display, in tag order.
    static func colorIndexes(_ path: String) -> [Int] {
        var out: [Int] = []
        for t in read(path) {
            var idx = ColorLabel.index(ofFinderNumber: t.color)
            if idx == nil { idx = ColorLabel.names.index(of: t.name) }
            if let i = idx, !out.contains(i) { out.append(i) }
        }
        return out
    }
}

/// "Date Added" (when an item was put in its folder). Read-only.
enum DateAdded {
    static func get(_ path: String) -> Double {
        let u = URL(fileURLWithPath: path)
        if let v = try? u.resourceValues(forKeys: [.addedToDirectoryDateKey]), let d = v.addedToDirectoryDate {
            return d.timeIntervalSince1970
        }
        return 0
    }
}

/// Mounted volumes and free space (read-only).
struct VolumeInfo {
    let name: String
    let path: String
    let isLocal: Bool
    let isRoot: Bool
    let isRemovable: Bool
}

enum Volumes {
    // Phase 6: the volume list never blocks the main thread. Asking macOS for a network volume's details
    // can wait for a server that stopped answering, so:
    // - VolumeRegistry holds the last known list (instant to read);
    // - at start it is filled from the mount table without waiting (getmntinfo MNT_NOWAIT);
    // - full details (names, local/network, how to reconnect a share) are read on a background thread
    //   whenever volumes change (mount/unmount notifications - no polling).

    /// Last known mounted volumes. Never waits.
    static func mounted() -> [VolumeInfo] {
        if !VolumeRegistry.shared.isFilled { VolumeRegistry.shared.set(quickScan()) }
        return VolumeRegistry.shared.volumes.map {
            VolumeInfo(name: $0.name, path: $0.path, isLocal: $0.isLocal, isRoot: $0.isRoot, isRemovable: $0.isRemovable)
        }
    }

    private static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "ftp", "cifs"]

    /// The mount table, without waiting for any server (no names from servers, no reconnect addresses).
    static func quickScan() -> [VolumeRecord] {
        var out: [VolumeRecord] = []
        #if os(macOS)
        var buf: UnsafeMutablePointer<statfs>? = nil
        let n = Int(getmntinfo(&buf, MNT_NOWAIT))
        guard n > 0, let mounts = buf else { return out }
        for i in 0..<n {
            var m = mounts[i]
            let path = withUnsafePointer(to: &m.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let type = withUnsafePointer(to: &m.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let from = withUnsafePointer(to: &m.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if path != "/" && !(path.hasPrefix("/Volumes/") && Paths.parent(path) == "/Volumes") { continue }
            let leaf = Paths.lastComponent(path)
            if path != "/" && (leaf.hasPrefix(".") || leaf.hasPrefix("com.apple.")) { continue }
            let network = networkTypes.contains(type) || (m.f_flags & UInt32(MNT_LOCAL)) == 0
            // Hidden volumes (Time Machine local snapshots, system helpers), as Finder hides them.
            // 0.14: a network share is kept even if marked hidden (some servers' shares are mounted
            // that way and Finder still lets you browse them).
            if !network && (m.f_flags & UInt32(MNT_DONTBROWSE)) != 0 { continue }
            out.append(VolumeRecord(name: path == "/" ? "Macintosh HD" : Paths.lastComponent(path), path: path,
                                    isLocal: !network, isRoot: path == "/", isRemovable: false, remountURL: nil,
                                    source: network ? from : nil))
        }
        #endif
        return out
    }

    /// Read full details in the background, store them, then call `done` on the main thread.
    static func refresh(done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey,
                                          .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeURLForRemountingKey]
            var out: [VolumeRecord] = []
            let quick = quickScan()
            if let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
                for u in urls {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    let q = quick.first(where: { $0.path == u.path })
                    // A share is network even if macOS's details say otherwise when the mount table knows it is.
                    let local = (q?.isLocal == false) ? false : (v?.volumeIsLocal ?? q?.isLocal ?? true)
                    out.append(VolumeRecord(name: v?.volumeName ?? Paths.lastComponent(u.path), path: u.path,
                                            isLocal: local,
                                            isRoot: v?.volumeIsRootFileSystem ?? (u.path == "/"),
                                            isRemovable: (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false),
                                            remountURL: v?.volumeURLForRemounting?.absoluteString, source: q?.source))
                }
                // Shares in the mount table that macOS's list leaves out (marked hidden): kept (0.14).
                for q in quick where !q.isLocal && !out.contains(where: { $0.path == q.path }) {
                    out.append(q)
                }
            } else {
                out = quick
            }
            VolumeRegistry.shared.set(out)
            DispatchQueue.main.async { done?() }
        }
    }

    /// Connect a network share (or a server: macOS then asks which share). Runs in the background;
    /// `done` on the main thread with nil (mounted, or it was already mounted) or a message.
    /// macOS asks for a name and password itself when the server needs them (keychain first).
    /// `user`/`password`: from the server's saved entry (nil: macOS uses its keychain or asks).
    /// `silent`: never show a dialog (start-up auto-connect) - fails instead.
    static func mount(_ urlString: String, user: String? = nil, password: String? = nil, silent: Bool = false,
                      done: @escaping (String?) -> Void) {
        mountShare(urlString, user: user, password: password, silent: silent) { err, _ in done(err) }
    }

    /// The same, also giving the folder macOS mounted it at (from macOS itself, 0.14; nil if it was
    /// already connected and macOS didn't say where).
    static func mountShare(_ urlString: String, user: String? = nil, password: String? = nil, silent: Bool = false,
                           done: @escaping (String?, String?) -> Void) {
        guard let u = URL(string: urlString), let scheme = u.scheme?.lowercased(),
            ["smb", "afp", "nfs", "cifs", "ftp"].contains(scheme) else {
            done("Find can't connect to this kind of address (\(urlString)).", nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var mountedAt: String? = nil
            #if os(macOS)
            let open = NSMutableDictionary()
            if silent { open["UIOption"] = "NoUI" }   // kNAUIOptionKey / kNAUIOptionNoUI
            let u2: CFString? = (user?.isEmpty == false) ? user! as CFString : nil
            let p2: CFString? = (password?.isEmpty == false) ? password! as CFString : nil
            var points: Unmanaged<CFArray>? = nil
            let status = NetFSMountURLSync(u as CFURL, nil, u2, p2, open as CFMutableDictionary, nil, &points)
            if let arr = points?.takeRetainedValue() as? [String], let first = arr.first, !first.isEmpty { mountedAt = first }
            #else
            let status: Int32 = -1
            #endif
            let where_ = mountedAt
            DispatchQueue.main.async {
                if status == 0 || status == EEXIST {
                    done(nil, where_)
                } else if status == ECANCELED || status == -128 {
                    done("Connecting was cancelled.", nil)
                } else if status == 80 /* EAUTH on macOS */ || status == EACCES || status == EPERM {
                    done("The server refused the name or password (error \(status)).", nil)
                } else if status == ENOENT {
                    done(scheme == "ftp" ? "The FTP server was not found or refused the connection (error \(status))." :
                        "The server has no shared folder with that name (error \(status)).", nil)
                } else if status == EHOSTUNREACH || status == ETIMEDOUT || status == ENETUNREACH || status == EHOSTDOWN || status == ECONNREFUSED {
                    done("The server can't be reached (error \(status)). Check the address and the network.", nil)
                } else {
                    done("The server did not accept the connection (error \(status)). Check the address and the network, or try Finder's Go > Connect to Server.", nil)
                }
            }
        }
    }

    /// Reconnect a share at the address macOS gave for it (Reconnect button).
    static func remount(_ urlString: String, done: @escaping (String?) -> Void) {
        mount(urlString, done: done)
    }

    /// Volumes that can be ejected: anything mounted under /Volumes (never the startup disk).
    static func isEjectable(_ path: String) -> Bool {
        return path.hasPrefix("/Volumes/") && Paths.parent(path) == "/Volumes"
    }

    /// Eject (unmount, and eject the disk if it is removable). macOS refuses if the volume is in use;
    /// nothing on it is changed either way. `done` runs on the main thread with nil or an error message.
    static func eject(_ path: String, done: @escaping (String?) -> Void) {
        guard isEjectable(path) else {
            done("\(path) is not an ejectable volume.")
            return
        }
        FileManager.default.unmountVolume(at: URL(fileURLWithPath: path), options: [.allPartitionsAndEjectDisk]) { error in
            let msg: String?
            if let e = error as NSError? {
                msg = e.localizedDescription + (e.code == 16 || e.localizedDescription.lowercased().contains("busy") || e.localizedDescription.lowercased().contains("in use")
                    ? " Another app may be using it (an open file, a copy in progress)." : "")
            } else {
                msg = nil
            }
            DispatchQueue.main.async { done(msg) }
        }
    }

    /// Free space in bytes, or nil.
    static func freeSpace(_ path: String) -> Int64? {
        let u = URL(fileURLWithPath: path)
        if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey]), let c = v.volumeAvailableCapacity {
            return Int64(c)
        }
        return nil
    }
}

/// Resource monitor (Settings > Advanced): Find's own memory and processor use. Read-only.
enum ProcessStats {
    /// Memory Find occupies right now (resident), in bytes; 0 if unknown.
    static func residentBytes() -> UInt64 {
        #if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        #else
        return 0
        #endif
    }

    /// Processor time Find has used since it started (user + system), in seconds.
    static func cpuSeconds() -> Double {
        #if os(macOS)
        var u = rusage()
        if getrusage(RUSAGE_SELF, &u) != 0 { return 0 }
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        #else
        return 0
        #endif
    }
}


/// Passwords of saved servers, in the macOS Keychain (Internet passwords - the same kind Finder saves
/// for servers, so either app can use them). Find never writes a password to its own files.
enum ServerKeychain {
    private static func proto(_ scheme: String) -> CFString {
        #if os(macOS)
        return scheme == "afp" ? kSecAttrProtocolAFP : (scheme == "ftp" ? kSecAttrProtocolFTP : kSecAttrProtocolSMB)
        #else
        return "smb" as CFString
        #endif
    }

    private static func query(host: String, user: String, scheme: String) -> [String: Any] {
        #if os(macOS)
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        return [kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: bare,
                kSecAttrAccount as String: user,
                kSecAttrProtocol as String: proto(scheme)]
        #else
        return [:]
        #endif
    }

    /// The saved password, or nil. (macOS may ask once whether Find may use it, e.g. after a rebuild.)
    static func password(host: String, user: String, scheme: String) -> String? {
        #if os(macOS)
        if user.isEmpty { return nil }
        var q = query(host: host, user: user, scheme: scheme)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
        #else
        return nil
        #endif
    }

    #if os(macOS)
    /// 0.16: who may read the entry without asking: Find, and macOS's own connection helper
    /// (NetAuthAgent / NetAuthSysAgent), which reads it while connecting a share. Without the helper
    /// in the list, macOS asked "NetAuthSysAgent wants to use..." once for every server entry.
    private static func access(label: String) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let m = me { apps.append(m) }
        for p in ["/System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthSysAgent",
                  "/System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthAgent"] where FileManager.default.fileExists(atPath: p) {
            var a: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(p, &a) == errSecSuccess, let x = a { apps.append(x) }
        }
        var acc: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &acc) == errSecSuccess else { return nil }
        return acc
    }
    #endif

    /// Save (or replace) a password. Returns nil, or a message. The entry is made fresh each time so it
    /// carries the access list above (an old entry is kept if the new one can't be made).
    static func save(_ password: String, host: String, user: String, scheme: String) -> String? {
        #if os(macOS)
        if user.isEmpty { return "A password needs an account name." }
        let q = query(host: host, user: user, scheme: scheme)
        let data = password.data(using: .utf8) ?? Data()
        let old = self.password(host: host, user: user, scheme: scheme)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = bareHost(host)
        if let a = access(label: bareHost(host)) { add[kSecAttrAccess as String] = a }
        if old != nil { _ = SecItemDelete(q as CFDictionary) }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // Without the access list (as before 0.16), so the password is never lost.
            add[kSecAttrAccess as String] = nil
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
        }
        if status != errSecSuccess, let o = old, let od = o.data(using: .utf8) {
            var back = q
            back[kSecValueData as String] = od
            back[kSecAttrLabel as String] = bareHost(host)
            _ = SecItemAdd(back as CFDictionary, nil)
        }
        return status == errSecSuccess ? nil : "The Keychain did not accept the password (error \(status))."
        #else
        return "No keychain here"
        #endif
    }

    /// Settings > Network > Repair Keychain Access: make the saved servers' entries again with the
    /// access list (same passwords). Returns (repaired, not found, failed).
    static func repair(_ servers: [SavedServer]) -> (Int, Int, Int) {
        var ok = 0, missing = 0, bad = 0
        for s in servers where !s.user.isEmpty {
            guard let a = s.parsed else { continue }
            guard let pw = password(host: a.host, user: s.user, scheme: a.scheme) else { missing += 1; continue }
            if save(pw, host: a.host, user: s.user, scheme: a.scheme) == nil { ok += 1 } else { bad += 1 }
        }
        return (ok, missing, bad)
    }

    static func delete(host: String, user: String, scheme: String) {
        #if os(macOS)
        if user.isEmpty { return }
        _ = SecItemDelete(query(host: host, user: user, scheme: scheme) as CFDictionary)
        #endif
    }

    private static func bareHost(_ h: String) -> String { return h.split(separator: ":").first.map(String.init) ?? h }
}


// MARK: - Crash capture (0.17.1)

/// If Find ever ends unexpectedly, what happened (the reason and where in the program) and what it was
/// doing is written to Logs/Find/crash-pending.txt at that moment; the next start turns it into a
/// numbered crash report and offers it (Copy Report). Writing uses only plain write() calls, the
/// only thing that is safe at that moment. The file is emptied at every start.
enum CrashCapture {
    fileprivate static var fd: Int32 = -1
    fileprivate static var header: [UInt8] = []
    /// What Find was doing (set by long-running work such as FTP transfers), kept in a fixed buffer.
    fileprivate static let crumb = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    fileprivate static var crumbLength = 0

    // backtrace() and backtrace_symbols_fd() are not visible to Swift in the 10.13 SDK: looked up by name.
    fileprivate typealias BacktraceFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32) -> Int32
    fileprivate typealias SymbolsFn = @convention(c) (UnsafePointer<UnsafeMutableRawPointer?>?, Int32, Int32) -> Void
    fileprivate static var backtraceFn: BacktraceFn?
    fileprivate static var symbolsFn: SymbolsFn?

    static func install(path: String, version: String) {
        if let h = dlopen(nil, RTLD_NOW) {
            if let f = dlsym(h, "backtrace") { backtraceFn = unsafeBitCast(f, to: BacktraceFn.self) }
            if let f = dlsym(h, "backtrace_symbols_fd") { symbolsFn = unsafeBitCast(f, to: SymbolsFn.self) }
        }
        // A program Find talks to (curl) closing its end early must not end Find: the write just fails.
        signal(SIGPIPE, SIG_IGN)
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        header = Array("FIND STOPPED UNEXPECTEDLY - Find \(version)\n".utf8)
        crumbLength = 0
        NSSetUncaughtExceptionHandler { e in
            CrashCapture.put(String(decoding: CrashCapture.header, as: UTF8.self))
            CrashCapture.put("Reason: Objective-C exception \(e.name.rawValue): \(e.reason ?? "")\n")
            for (i, f) in e.callStackSymbols.prefix(40).enumerated() { CrashCapture.put("Frame \(i): \(f)\n") }
            CrashCapture.writeCrumb()
        }
        for s in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] { signal(s, crashSignalHandler) }
    }

    /// Remember what Find is doing now (kept to 1000 bytes).
    static func note(_ text: String) {
        let b = Array(text.utf8.prefix(1000))
        crumbLength = 0
        for (i, c) in b.enumerated() { crumb[i] = c }
        crumbLength = b.count
    }

    fileprivate static func put(_ s: String) {
        guard fd >= 0 else { return }
        let b = Array(s.utf8)
        _ = b.withUnsafeBytes { write(fd, $0.baseAddress, b.count) }
    }

    fileprivate static func writeCrumb() {
        guard fd >= 0 else { return }
        let w = "Doing: "
        _ = w.withCString { write(fd, $0, strlen($0)) }
        _ = write(fd, crumb, crumbLength)
        let nl: [UInt8] = [10]
        _ = nl.withUnsafeBytes { write(fd, $0.baseAddress, 1) }
        _ = fsync(fd)
    }
}

/// Called by macOS when Find crashes: write the signal, the call stack and what Find was doing, then
/// let the crash go on as usual (macOS's own crash report is made too).
private func crashSignalHandler(_ sig: Int32) {
    let fd = CrashCapture.fd
    if fd >= 0 {
        _ = CrashCapture.header.withUnsafeBytes { write(fd, $0.baseAddress, CrashCapture.header.count) }
        var digits: [UInt8] = Array("Reason: signal ".utf8)
        var n = Int(sig)
        var rev: [UInt8] = []
        repeat { rev.append(UInt8(48 + n % 10)); n /= 10 } while n > 0
        digits += rev.reversed()
        digits.append(10)
        _ = digits.withUnsafeBytes { write(fd, $0.baseAddress, digits.count) }
        if let bt = CrashCapture.backtraceFn, let sym = CrashCapture.symbolsFn {
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let count = bt(&frames, 64)
            sym(&frames, count, fd)
        }
        CrashCapture.writeCrumb()
    }
    signal(sig, SIG_DFL)
    raise(sig)
}


/// 0.18: Find's whole-process disk I/O as macOS counts it (proc_pid_rusage, RUSAGE_INFO_V2:
/// ri_diskio_bytesread / ri_diskio_byteswritten). Looked up at run time (not in the 10.13 Swift
/// overlay). nil when it can't be read.
enum ProcessDiskIO {
    private typealias RusageFn = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32
    private static let fn: RusageFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let f = dlsym(h, "proc_pid_rusage") else { return nil }
        return unsafeBitCast(f, to: RusageFn.self)
    }()

    static func bytes() -> (read: UInt64, written: UInt64)? {
        guard let f = fn else { return nil }
        // rusage_info_v2 = 16-byte uuid + 18 UInt64 fields; the last two are the disk bytes. Room to spare.
        var buf = [UInt64](repeating: 0, count: 64)
        let rc = buf.withUnsafeMutableBytes { f(getpid(), 2, $0.baseAddress) }
        if rc != 0 { return nil }
        return (buf[18], buf[19])
    }
}
