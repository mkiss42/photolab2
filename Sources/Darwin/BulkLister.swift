// BulkLister.swift
// Fast folder listing with getattrlistbulk (macOS 10.10+): names, sizes, dates, Date Added, flags and
// ids for many entries per request. On a network share that is one round trip for hundreds of items,
// instead of one lstat (and one Date Added lookup) per item. Read-only: the folder is opened O_RDONLY.
//
// Safety: every record is bounds-checked and validated. If anything looks wrong the folder is listed
// again the classic way (readdir + lstat), and fast listing is switched off for the rest of the session.
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

    /// Switched off for the session after a record that didn't validate.
    private static var disabled = false
    private static let lock = NSLock()

    static func install() {
        DirectoryReader.bulkLister = { dir, cancelled, emit in
            return BulkLister.list(dir, isCancelled: cancelled, emit: emit)
        }
    }

    static func list(_ dir: String, isCancelled: () -> Bool, emit: (BulkItem) -> Void,
                     bufferSize: Int = 256 * 1024) -> BulkOutcome {
        lock.lock()
        let off = disabled
        lock.unlock()
        if off { return BulkOutcome(ok: false, error: ENOTSUP, emitted: 0) }

        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        if fd < 0 { return BulkOutcome(ok: false, error: errno, emitted: 0) }
        defer { close(fd) }

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
                    giveUp(dir, "record \(all.count) did not validate")
                    return BulkOutcome(ok: false, error: EIO, emitted: 0)
                }
                entryStart += rec.length
                if let it = rec.item { all.append(it) }
            }
        }
        for it in all { emit(it) }
        return BulkOutcome(ok: true, error: 0, emitted: all.count)
    }

    private static func giveUp(_ dir: String, _ why: String) {
        lock.lock()
        disabled = true
        lock.unlock()
        Log.shared?.warn("Fast folder listing switched off for this session (\(why) in \(dir)); using readdir + lstat")
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
        // modtime 16, accessmask 4, flags 4, fileid 8, addedtime 16, datalength 8 = 116.
        guard len >= 116, len <= 64 * 1024, start + len <= limit else { return nil }
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
        let dataLen = Int64(bitPattern: u64(rec, o)); o += 8
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
