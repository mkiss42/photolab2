// DirectoryReader.swift
// Lists one folder. Read-only: folders are opened O_RDONLY, nothing is ever written.
//
// Fast path: getattrlistbulk (macOS 10.10+) returns names, sizes, dates, flags and ids for many
// entries per call - on an SMB share one round trip for hundreds of items instead of one lstat
// each. Every record is bounds-checked; anything that does not validate makes us list the
// folder again the classic way (readdir + lstat) and switch the fast path off for the session.
// The self-test compares both methods on real folders.

import Foundation
import Darwin

struct FolderListing {
    var entries: [FileEntry] = []
    /// errno when the folder itself could not be read (0 = fine).
    var error: Int32 = 0
    /// Entries listed but not examinable (lstat failed), with errno.
    var problems: [(name: String, error: Int32)] = []
    var method = "bulk"
    var milliseconds = 0.0
    var cancelled = false

    var errorText: String { return error == 0 ? "" : String(cString: strerror(error)) }
}

enum DirectoryReader {
    private static let lock = NSLock()
    private static var bulkDisabled = false

    /// Self-test switch: force one method.
    enum Method { case auto, bulk, classic }

    static func read(_ dir: String, method: Method = .auto, isCancelled: () -> Bool = { false }) -> FolderListing {
        let t0 = Date()
        var result: FolderListing
        lock.lock(); let off = bulkDisabled; lock.unlock()
        if method != .classic && !off {
            switch BulkLister.list(dir, isCancelled: isCancelled) {
            case .ok(let entries):
                result = FolderListing(entries: entries, error: 0, problems: [], method: "bulk", milliseconds: 0, cancelled: false)
            case .cancelled:
                result = FolderListing(); result.cancelled = true
            case .failed(let err):
                // Folder-level errors (permission, gone, server down) are real answers.
                result = FolderListing(); result.error = err; result.method = "bulk"
            case .invalidRecord(let why):
                if method == .auto {
                    lock.lock(); bulkDisabled = true; lock.unlock()
                    Log.warn("W-LIST-1 fast listing switched off for this session (\(why) in \(dir)); using readdir + lstat")
                }
                result = classic(dir, isCancelled: isCancelled)
            }
        } else {
            result = classic(dir, isCancelled: isCancelled)
        }
        result.milliseconds = Date().timeIntervalSince(t0) * 1000
        return result
    }

    static func classic(_ dir: String, isCancelled: () -> Bool) -> FolderListing {
        var result = FolderListing()
        result.method = "readdir"
        guard let d = opendir(dir) else {
            result.error = errno
            return result
        }
        defer { closedir(d) }
        var names: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(d) else {
                if errno != 0 { result.error = errno }
                break
            }
            let name = withUnsafePointer(to: &ent.pointee.d_name) { p -> String in
                return p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        for name in names {
            if isCancelled() { result.cancelled = true; return result }
            var st = stat()
            let path = Paths.join(dir, name)
            if lstat(path, &st) != 0 {
                let e = errno
                if e != ENOENT { result.problems.append((name: name, error: e)) }   // ENOENT: gone meanwhile
                continue
            }
            result.entries.append(FileEntry.make(
                name: name, dir: dir, mode: UInt32(st.st_mode), size: Int64(st.st_size),
                modified: seconds(st.st_mtimespec), created: seconds(st.st_birthtimespec), added: 0,
                flags: st.st_flags, device: UInt64(UInt32(bitPattern: st.st_dev)), inode: UInt64(st.st_ino)))
        }
        return result
    }

    static func seconds(_ t: timespec) -> Double {
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }
}

enum BulkLister {
    enum Outcome {
        case ok([FileEntry])
        case cancelled
        case failed(Int32)
        case invalidRecord(String)
    }

    // sys/attr.h values, spelled out so every SDK agrees.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnCrTime: UInt32 = 0x0000_0200
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnAccessMask: UInt32 = 0x0002_0000
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnAddedTime: UInt32 = 0x1000_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileDataLength: UInt32 = 0x0000_0200
    private static let packInvalAttrs: UInt64 = 0x0000_0008

    /// Fixed record layout with FSOPT_PACK_INVAL_ATTRS (offsets from the record start):
    ///   0 length u32 | 4 returned attrs (5 x u32) | 24 error u32 | 28 name attrreference (i32 off, u32 len)
    ///  36 devid i32 | 40 objtype u32 | 44 crtime timespec | 60 modtime timespec | 76 accessmask u32
    ///  80 flags u32 | 84 fileid u64 | 92 addedtime timespec | 108 datalength u64 | 116 end
    static let fixedLength = 116

    static func list(_ dir: String, isCancelled: () -> Bool, bufferSize: Int = 256 * 1024) -> Outcome {
        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        if fd < 0 { return .failed(errno) }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = 5   // ATTR_BIT_MAP_COUNT
        al.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnDevID | cmnObjType | cmnCrTime
            | cmnModTime | cmnAccessMask | cmnFlags | cmnFileID | cmnAddedTime
        al.fileattr = fileDataLength

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buf.deallocate() }
        var out: [FileEntry] = []
        while true {
            if isCancelled() { return .cancelled }
            let n = getattrlistbulk(fd, &al, buf, bufferSize, packInvalAttrs)
            if n < 0 { return .failed(errno) }
            if n == 0 { break }
            var offset = 0
            for i in 0..<Int(n) {
                switch parse(buf, at: offset, limit: bufferSize, dir: dir) {
                case .bad(let why):
                    return .invalidRecord("record \(out.count + i): \(why)")
                case .record(let length, let entry):
                    offset += length
                    if let e = entry { out.append(e) }
                }
            }
        }
        return .ok(out)
    }

    private enum Parsed {
        case record(length: Int, entry: FileEntry?)
        case bad(String)
    }

    private static func u32(_ b: UnsafeMutableRawPointer, _ o: Int) -> UInt32 {
        var v: UInt32 = 0; memcpy(&v, b + o, 4); return v
    }
    private static func i32(_ b: UnsafeMutableRawPointer, _ o: Int) -> Int32 {
        var v: Int32 = 0; memcpy(&v, b + o, 4); return v
    }
    private static func u64(_ b: UnsafeMutableRawPointer, _ o: Int) -> UInt64 {
        var v: UInt64 = 0; memcpy(&v, b + o, 8); return v
    }
    private static func time(_ b: UnsafeMutableRawPointer, _ o: Int) -> Double {
        var s: Int64 = 0, ns: Int64 = 0
        memcpy(&s, b + o, 8); memcpy(&ns, b + o + 8, 8)
        return Double(s) + Double(ns) / 1e9
    }

    private static func parse(_ buf: UnsafeMutableRawPointer, at start: Int, limit: Int, dir: String) -> Parsed {
        guard start + 4 <= limit else { return .bad("record past buffer") }
        let len = Int(u32(buf, start))
        guard len >= fixedLength, len <= 64 * 1024, start + len <= limit else { return .bad("length \(len)") }
        let r = buf + start
        let retCommon = u32(r, 4)
        let retFile = u32(r, 16)
        let entryError = u32(r, 24)
        let nameOff = Int(i32(r, 28))
        let nameLen = Int(u32(r, 32))
        let nameStart = 28 + nameOff
        guard nameLen >= 2, nameLen <= 1024, nameStart >= 36, nameStart + nameLen <= len else {
            return .bad("name reference")
        }
        let namePtr = (r + nameStart).assumingMemoryBound(to: CChar.self)
        guard namePtr[nameLen - 1] == 0, let name = String(validatingUTF8: namePtr), !name.isEmpty,
            !name.contains("/") else { return .bad("name bytes") }
        if name == "." || name == ".." { return .record(length: len, entry: nil) }

        if entryError != 0 || (retCommon & cmnObjType) == 0 {
            // macOS could not give this one in bulk: ask for it on its own.
            var st = stat()
            if lstat(Paths.join(dir, name), &st) != 0 { return .record(length: len, entry: nil) }
            let e = FileEntry.make(name: name, dir: dir, mode: UInt32(st.st_mode), size: Int64(st.st_size),
                                   modified: DirectoryReader.seconds(st.st_mtimespec),
                                   created: DirectoryReader.seconds(st.st_birthtimespec), added: 0,
                                   flags: st.st_flags, device: UInt64(UInt32(bitPattern: st.st_dev)),
                                   inode: UInt64(st.st_ino))
            return .record(length: len, entry: e)
        }

        let typeBits: UInt32
        switch u32(r, 40) {
        case 1: typeBits = UInt32(S_IFREG)
        case 2: typeBits = UInt32(S_IFDIR)
        case 5: typeBits = UInt32(S_IFLNK)
        case 3: typeBits = UInt32(S_IFBLK)
        case 4: typeBits = UInt32(S_IFCHR)
        case 6: typeBits = UInt32(S_IFSOCK)
        case 7: typeBits = UInt32(S_IFIFO)
        default: return .bad("object type \(u32(r, 40))")
        }
        let size = (retFile & fileDataLength) != 0 ? Int64(bitPattern: u64(r, 108)) : 0
        guard size >= 0 else { return .bad("negative size") }
        let added = (retCommon & cmnAddedTime) != 0 ? time(r, 92) : 0
        let e = FileEntry.make(name: name, dir: dir, mode: typeBits | (u32(r, 76) & 0o7777), size: size,
                               modified: time(r, 60),
                               created: (retCommon & cmnCrTime) != 0 ? time(r, 44) : 0,
                               added: added > 0 ? added : 0,
                               flags: (retCommon & cmnFlags) != 0 ? u32(r, 80) : 0,
                               device: UInt64(UInt32(bitPattern: i32(r, 36))),
                               inode: u64(r, 84))
        return .record(length: len, entry: e)
    }
}
