// BulkLister.swift
// Fast folder listing with getattrlistbulk (macOS 10.10+): names, sizes, dates, Date Added, flags and
// ids for many entries per request. On a network share that is one round trip for hundreds of items,
// instead of one lstat (and one Date Added lookup) per item. Read-only: the folder is opened O_RDONLY.
//
// Safety: every record is bounds-checked and validated. If anything looks wrong the folder is listed
// again the classic way (readdir + lstat). Fast listing is switched off only for that VOLUME, and only
// after 3 folders failed there (PhotoLab 2 0.1.x lesson: one session-wide switch-off made every share
// slow after the first odd record).
// Record layout (from the lab's SMB servers, PhotoLab 2): the fixed part is 108 bytes; the 8-byte
// file size follows only for files - smbfs and HFS+ leave it out for folders even with
// FSOPT_PACK_INVAL_ATTRS. Find 0.18 required 116 bytes and so rejected every folder on a share.
// The Photo Metadata Self-Test compares both ways on real folders at every build.

import Foundation
import Darwin

enum BulkLister {
    // Attribute bits (sys/attr.h), spelled out so they are the same with every SDK.
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
    private static let packInvalAttrs: UInt64 = 0x0000_0008     // FSOPT_PACK_INVAL_ATTRS: fixed layout

    /// Volumes (device ids) where 3 folders had a record that didn't validate: classic listing there.
    private static var failures: [UInt64: Int] = [:]
    private static let lock = NSLock()

    static func install() {
        DirectoryReader.bulkLister = { dir, cancelled, emit in
            return BulkLister.list(dir, isCancelled: cancelled, emit: emit)
        }
    }

    static func list(_ dir: String, isCancelled: () -> Bool, emit: (BulkItem) -> Void,
                     bufferSize: Int = 256 * 1024) -> BulkOutcome {
        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        if fd < 0 { return BulkOutcome(ok: false, error: errno, emitted: 0) }
        defer { close(fd) }
        var st = stat()
        let dev: UInt64 = fstat(fd, &st) == 0 ? UInt64(UInt32(bitPattern: st.st_dev)) : 0
        lock.lock()
        let off = (failures[dev] ?? 0) >= 3
        lock.unlock()
        if off { return BulkOutcome(ok: false, error: ENOTSUP, emitted: 0) }

        var al = attrlist()
        al.bitmapcount = 5
        al.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnDevID | cmnObjType | cmnCrTime | cmnModTime
            | cmnAccessMask | cmnFlags | cmnFileID | cmnAddedTime
        al.fileattr = fileDataLength
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buf.deallocate() }
        // The whole folder is collected and checked first, then handed over: a record that doesn't
        // validate means the classic reader lists the folder from scratch (never a half listing).
        var all: [BulkItem] = []
        while true {
            if isCancelled() { return BulkOutcome(ok: true, error: 0, emitted: 0) }
            let n = withUnsafeMutablePointer(to: &al) { p -> Int32 in
                return getattrlistbulk(fd, UnsafeMutableRawPointer(p), buf, bufferSize, packInvalAttrs)
            }
            if n < 0 { return BulkOutcome(ok: false, error: errno, emitted: 0) }
            if n == 0 { break }
            var entryStart = 0
            for _ in 0..<Int(n) {
                guard let rec = parse(buf, at: entryStart, limit: bufferSize, dir: dir) else {
                    giveUp(dir, dev, "record \(all.count) did not validate")
                    return BulkOutcome(ok: false, error: EIO, emitted: 0)
                }
                entryStart += rec.length
                if let it = rec.item { all.append(it) }
            }
        }
        for it in all { emit(it) }
        return BulkOutcome(ok: true, error: 0, emitted: all.count)
    }

    private static func giveUp(_ dir: String, _ dev: UInt64, _ why: String) {
        lock.lock()
        failures[dev, default: 0] += 1
        let n = failures[dev] ?? 0
        lock.unlock()
        if n >= 3 {
            Log.shared?.warn("W-LIST-2 fast folder listing switched off for this volume after 3 folders (\(why) in \(dir)); using readdir + lstat there")
        } else {
            Log.shared?.warn("W-LIST-1 fast listing not used for one folder (\(why) in \(dir)); listed with readdir + lstat")
        }
    }

    private static func u32(_ b: UnsafeMutableRawPointer, _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        memcpy(&v, b + o, 4)
        return v
    }

    private static func i32(_ b: UnsafeMutableRawPointer, _ o: Int) -> Int32 {
        var v: Int32 = 0
        memcpy(&v, b + o, 4)
        return v
    }

    private static func u64(_ b: UnsafeMutableRawPointer, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        memcpy(&v, b + o, 8)
        return v
    }

    private static func ts(_ b: UnsafeMutableRawPointer, _ o: Int) -> (sec: Int64, nsec: Int64) {
        var s: Int64 = 0, ns: Int64 = 0
        memcpy(&s, b + o, 8)
        memcpy(&ns, b + o + 8, 8)
        return (s, ns)
    }

    /// One record. `item` is nil for "." / ".." or an entry that vanished; the whole result is nil when
    /// the record doesn't validate.
    private static func parse(_ buf: UnsafeMutableRawPointer, at start: Int, limit: Int, dir: String) -> (length: Int, item: BulkItem?)? {
        guard start + 4 <= limit else { return nil }
        let len = Int(u32(buf, start))
        // Fixed layout: length 4, returned attrs 20, error 4, name ref 8, devid 4, objtype 4, crtime 16,
        // modtime 16, accessmask 4, flags 4, fileid 8, addedtime 16 = 108; then datalength 8 for files
        // only (folders on smbfs/HFS+ have none: 108 + name).
        guard len >= 108, len <= 64 * 1024, start + len <= limit else { return nil }
        let rec = buf + start
        var o = 4
        let retCommon = u32(rec, o)
        let retFile = u32(rec, o + 12)
        o += 20
        let entryError = u32(rec, o); o += 4
        let nameOff = Int(i32(rec, o))
        let nameLen = Int(u32(rec, o + 4))
        let nameBase = o
        o += 8
        guard nameLen >= 1, nameLen <= 1024, nameBase + nameOff >= 0, nameBase + nameOff + nameLen <= len else { return nil }
        let namePtr = (rec + nameBase + nameOff).assumingMemoryBound(to: CChar.self)
        guard namePtr[nameLen - 1] == 0, let name = String(validatingUTF8: namePtr), !name.isEmpty, !name.contains("/") else { return nil }
        if name == "." || name == ".." { return (len, nil) }

        if entryError != 0 || (retCommon & cmnObjType) == 0 {
            // macOS couldn't give this entry's details in bulk: ask for it on its own.
            var e: Int32 = 0
            let path = Paths.join(dir, name)
            guard let info = Sys.lstatInfo(path, &e) else { return (len, nil) }
            return (len, BulkItem(name: name, info: info, added: 0))
        }

        let dev = i32(rec, o); o += 4
        let objType = u32(rec, o); o += 4
        let cr = ts(rec, o); o += 16
        let mod = ts(rec, o); o += 16
        let access = u32(rec, o); o += 4
        let flags = u32(rec, o); o += 4
        let fileID = u64(rec, o); o += 8
        let added = ts(rec, o); o += 16
        var dataLen: Int64 = 0
        if (retFile & fileDataLength) != 0 {
            guard o + 8 <= len else { return nil }
            dataLen = Int64(bitPattern: u64(rec, o)); o += 8
        }
        guard o <= len else { return nil }

        var typeBits: UInt32
        switch objType {
        case 1: typeBits = 0o100000      // VREG
        case 2: typeBits = 0o040000      // VDIR
        case 5: typeBits = 0o120000      // VLNK
        case 3: typeBits = 0o060000      // VBLK
        case 4: typeBits = 0o020000      // VCHR
        case 6: typeBits = 0o140000      // VSOCK
        case 7: typeBits = 0o010000      // VFIFO
        default: typeBits = 0
        }
        if typeBits == 0 { return nil }
        let size: Int64 = (retFile & fileDataLength) != 0 ? dataLen : 0
        guard size >= 0 else { return nil }
        let info = StatInfo(mode: typeBits | (access & 0o7777),
                            size: size,
                            modified: Double(mod.sec) + Double(mod.nsec) / 1e9,
                            created: (retCommon & cmnCrTime) != 0 ? Double(cr.sec) : 0,
                            flags: (retCommon & cmnFlags) != 0 ? flags : 0,
                            device: UInt64(UInt32(bitPattern: dev)),
                            inode: fileID,
                            changed: 0)
        let addedTime = (retCommon & cmnAddedTime) != 0 && added.sec > 0 ? Double(added.sec) + Double(added.nsec) / 1e9 : 0
        return (len, BulkItem(name: name, info: info, added: addedTime))
    }

    // MARK: Self-test support

    /// Records captured from the lab's SMB servers (PhotoLab 2 0.1.1): folders without the size
    /// field, 112 bytes, name at offset 108. They must parse as folders, never as broken.
    static let capturedRecords: [(hex: String, name: String, perm: UInt32, inode: UInt64)] = [
        ("70000000 0b0606a2 00000000 00000000 00000000 00000000 00000000 50000000 04000000 03000036 02000000 06110166 00000000 00000000 00000000 7e5b1268 00000000 00000000 00000000 c0410000 00800000 ffffd4ba fad1e783 00000000 00000000 00000000 00000000 2e393900",
         ".99", 0o700, 0x83e7_d1fa_bad4_ffff),
        ("70000000 0b0606a2 00000000 00000000 00000000 00000000 00000000 50000000 04000000 02000036 02000000 a0772c64 00000000 00000000 00000000 b44afa6a 00000000 00000000 00000000 c0410000 00000000 6c1a82e3 d6d22d84 00000000 00000000 00000000 00000000 64656c00",
         "del", 0o700, 0x842d_d2d6_e382_1a6c),
        ("70000000 0b0606a2 00000000 00000000 00000000 00000000 00000000 50000000 04000000 04000036 02000000 e3bdf059 00000000 00000000 00000000 c8350f5a 00000000 00000000 00000000 ed410000 00800000 b89c7de3 d0d22b84 00000000 00000000 00000000 00000000 62696e00",
         "bin", 0o755, 0x842b_d2d0_e37d_9cb8),
    ]

    /// Parse the captured records; returns problems as text (empty = all parsed as expected folders).
    static func checkCapturedRecords() -> [String] {
        var problems: [String] = []
        for r in capturedRecords {
            let digits = Array(r.hex.replacingOccurrences(of: " ", with: ""))
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < digits.count { bytes.append(UInt8(String(digits[i...i + 1]), radix: 16) ?? 0); i += 2 }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
            defer { buf.deallocate() }
            buf.copyMemory(from: bytes, byteCount: bytes.count)
            guard let rec = parse(buf, at: 0, limit: bytes.count, dir: "/Volumes/Share"), let it = rec.item else {
                problems.append("\(r.name): did not parse"); continue
            }
            let isDir = it.info.mode & 0o170000 == 0o040000
            if it.name != r.name || !isDir || it.info.mode & 0o7777 != r.perm || it.info.inode != r.inode || rec.length != bytes.count {
                problems.append("\(r.name): parsed wrong (\(it.name), mode \(String(it.info.mode, radix: 8)), inode \(it.info.inode))")
            }
        }
        return problems
    }

    /// List a folder both ways (for the self-test). Returns differences as text lines (empty = identical).
    static func compareWithClassic(_ dir: String, bufferSize: Int = 256 * 1024) -> [String] {
        var bulk: [String: BulkItem] = [:]
        let out = list(dir, isCancelled: { false }, emit: { bulk[$0.name] = $0 }, bufferSize: bufferSize)
        if !out.ok { return ["bulk listing failed: error \(out.error) after \(out.emitted) entries"] }
        let saved = DirectoryReader.bulkLister
        DirectoryReader.bulkLister = nil
        let classic = DirectoryReader.read(dir, includeHidden: true)
        DirectoryReader.bulkLister = saved
        var diffs: [String] = []
        let cNames = Set(classic.entries.map { $0.name }), bNames = Set(bulk.keys)
        for n in cNames.subtracting(bNames).sorted().prefix(10) { diffs.append("missing in fast listing: \(n)") }
        for n in bNames.subtracting(cNames).sorted().prefix(10) { diffs.append("extra in fast listing: \(n)") }
        for c in classic.entries {
            guard let b = bulk[c.name] else { continue }
            let be = FileEntry.make(name: b.name, path: c.path, info: b.info)
            var why: [String] = []
            if be.kind != c.kind { why.append("kind") }
            if be.size != c.size { why.append("size \(be.size) vs \(c.size)") }
            if abs(be.modified - c.modified) > 0.000_01 { why.append("modified \(be.modified) vs \(c.modified)") }
            if be.created != c.created { why.append("created \(be.created) vs \(c.created)") }
            if be.isHidden != c.isHidden { why.append("hidden") }
            if be.device != c.device { why.append("device \(be.device) vs \(c.device)") }
            if be.inode != c.inode { why.append("inode \(be.inode) vs \(c.inode)") }
            if be.permissions != c.permissions { why.append("permissions \(String(be.permissions, radix: 8)) vs \(String(c.permissions, radix: 8))") }
            if !why.isEmpty && diffs.count < 20 { diffs.append("\(c.name): " + why.joined(separator: ", ")) }
        }
        return diffs
    }
}
