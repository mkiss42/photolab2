// OperationJournal.swift
// Notes about operations in progress that leave temporary items in the user's folders, so an interrupted
// operation (crash, power cut) can be cleaned up at the next launch:
// - "PARTIAL <path>": a hidden partial copy / save (".find-partial-..."). Recovery moves it to the Trash.
// - "RENAME <temp>\t<original>\t<intended new name>": an item under a batch-rename temporary name.
//   Recovery renames it back.
// Notes live in Find's own folder (Application Support/PhotoLab/Journals), one small file per operation, and
// are removed when the operation ends normally. Writing them never touches user files.

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

final class OperationJournal {
    let files: AppFiles
    private let lock = NSLock()
    private var counter = 0

    init(files: AppFiles) {
        self.files = files
    }

    /// Start a note; returns its token (pass to `end`). Lines as described above.
    func begin(_ lines: [String]) -> String {
        lock.lock()
        counter += 1
        let token = "\(Int(Date().timeIntervalSince1970))-\(getpid())-\(counter)"
        lock.unlock()
        _ = files.makeDir(files.journalsDir)
        _ = files.writeText(lines.joined(separator: "\n") + "\n", to: Paths.join(files.journalsDir, token + ".journal"))
        return token
    }

    func end(_ token: String) {
        _ = files.removeOwned(Paths.join(files.journalsDir, token + ".journal"))
    }

    struct Leftover {
        let token: String
        let partials: [String]
        let renames: [(temp: String, original: String, final: String?)]
        /// 0.18.8: files changed in place - their old length and the bytes to put back.
        var patches: [(path: String, length: Int64, saved: [(offset: Int64, data: Data)])]
    }

    /// "offset:hex,offset:hex" (a PATCH note line) back to bytes.
    static func decodeSaved(_ s: String) -> [(offset: Int64, data: Data)]? {
        if s.isEmpty { return [] }
        var out: [(offset: Int64, data: Data)] = []
        for part in s.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, let off = Int64(kv[0]), kv[1].count % 2 == 0 else { return nil }
            var d = Data()
            var i = kv[1].startIndex
            while i < kv[1].endIndex {
                let j = kv[1].index(i, offsetBy: 2)
                guard let byte = UInt8(kv[1][i..<j], radix: 16) else { return nil }
                d.append(byte)
                i = j
            }
            out.append((off, d))
        }
        return out
    }

    /// Notes left by operations that never finished (only call at launch, before any operation runs).
    func leftovers() -> [Leftover] {
        var out: [Leftover] = []
        for n in files.list(files.journalsDir) where n.hasSuffix(".journal") {
            let p = Paths.join(files.journalsDir, n)
            guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
            var partials: [String] = [], renames: [(String, String, String?)] = []
            var patches: [(path: String, length: Int64, saved: [(offset: Int64, data: Data)])] = []
            for line in text.split(separator: "\n").map(String.init) {
                if line.hasPrefix("PATCH ") {
                    let parts = line.dropFirst(6).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    if parts.count == 3, let len = Int64(parts[1]), let saved = OperationJournal.decodeSaved(parts[2]) {
                        patches.append((parts[0], len, saved))
                    }
                    continue
                }
                if line.hasPrefix("PARTIAL ") {
                    partials.append(String(line.dropFirst(8)))
                } else if line.hasPrefix("RENAME ") {
                    let parts = line.dropFirst(7).split(separator: "\t", maxSplits: 2).map(String.init)
                    if parts.count >= 2 { renames.append((parts[0], parts[1], parts.count == 3 ? parts[2] : nil)) }
                }
            }
            out.append(Leftover(token: String(n.dropLast(8)), partials: partials, renames: renames, patches: patches))
        }
        return out
    }

    /// A note written by another Find process that is still running (its operation may be in progress).
    func belongsToRunningProcess(_ token: String) -> Bool {
        let parts = token.split(separator: "-")
        guard parts.count >= 2, let pid = Int32(parts[1]) else { return false }
        if pid == getpid() { return false }
        return kill(pid, 0) == 0
    }

    var pendingCount: Int { return files.list(files.journalsDir).filter { $0.hasSuffix(".journal") }.count }
}
