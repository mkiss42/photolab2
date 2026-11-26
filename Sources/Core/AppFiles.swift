// AppFiles.swift
// PhotoLab's own files: logs, support files, caches. One of the three source files allowed to
// change anything on disk (see tools/check_mutations.sh). Everything here stays inside:
//   ~/Library/Logs/PhotoLab2
//   ~/Library/Application Support/PhotoLab2
//   ~/Library/Caches/PhotoLab2
// plus a report zip written where the user chose in a save panel.

import Foundation

enum AppFiles {
    static var home: String { return NSHomeDirectory() }
    static var logsDir: String { return home + "/Library/Logs/PhotoLab2" }
    static var supportDir: String { return home + "/Library/Application Support/PhotoLab2" }
    static var cachesDir: String { return home + "/Library/Caches/PhotoLab2" }

    /// Default socket for the brain. Unix socket paths are limited to 103 bytes.
    static var brainSocketPath: String { return supportDir + "/brain.sock" }

    static func ensureDirectories() {
        for d in [logsDir, supportDir, cachesDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: Log file (called on Log's queue only)

    private static var logHandle: FileHandle?
    private static var logDay = ""

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func appendLog(_ line: String) {
        let day = dayFormatter.string(from: Date())
        if logHandle == nil || day != logDay {
            logHandle?.closeFile()
            logHandle = nil
            ensureDirectories()
            let path = logsDir + "/photolab-\(day).log"
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
            }
            logHandle = FileHandle(forWritingAtPath: path)
            logHandle?.seekToEndOfFile()
            logDay = day
        }
        if let d = line.data(using: .utf8) {
            logHandle?.write(d)
        }
    }

    // MARK: Operation journal (support folder)

    static var journalPath: String { return supportDir + "/operation-journal.json" }

    /// Written before a multi-step operation, removed when it finishes (see FileOperations).
    static func writeJournal(op: String, pairs: [(String, String)]) {
        ensureDirectories()
        let obj: [String: Any] = ["op": op, "pairs": pairs.map { [$0.0, $0.1] }, "time": Date().timeIntervalSince1970]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }
        try? d.write(to: URL(fileURLWithPath: journalPath), options: .atomic)
    }

    static func readJournal() -> (op: String, pairs: [(String, String)])? {
        guard let d = FileManager.default.contents(atPath: journalPath),
            let obj = (try? JSONSerialization.jsonObject(with: d, options: [])) as? [String: Any],
            let op = obj["op"] as? String, let raw = obj["pairs"] as? [[String]] else { return nil }
        let pairs = raw.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        return (op, pairs)
    }

    static func clearJournal() {
        if FileManager.default.fileExists(atPath: journalPath) {
            try? FileManager.default.removeItem(atPath: journalPath)
        }
    }

    // MARK: Transfer journal (partial copies in progress)

    static var transferJournalPath: String { return supportDir + "/transfer-journal.json" }
    private static let transferLock = NSLock()

    /// Hidden partial copies being written right now. Kept on the local disk; written when an
    /// item starts and when it is finished (not per file), so it costs nothing on a share.
    static func readTransferJournal() -> [String] {
        guard let d = FileManager.default.contents(atPath: transferJournalPath),
            let obj = (try? JSONSerialization.jsonObject(with: d, options: [])) as? [String: Any],
            let temps = obj["partial"] as? [String] else { return [] }
        return temps
    }

    static func notePartial(_ path: String, active: Bool) {
        transferLock.lock(); defer { transferLock.unlock() }
        var temps = readTransferJournal()
        if active { if !temps.contains(path) { temps.append(path) } } else { temps.removeAll { $0 == path } }
        ensureDirectories()
        if temps.isEmpty {
            if FileManager.default.fileExists(atPath: transferJournalPath) {
                try? FileManager.default.removeItem(atPath: transferJournalPath)
            }
            return
        }
        let obj: [String: Any] = ["partial": temps, "time": Date().timeIntervalSince1970]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }
        try? d.write(to: URL(fileURLWithPath: transferJournalPath), options: .atomic)
    }

    // MARK: Self-test fixtures (inside the caches folder only)

    /// A fresh folder for the file-operation self-test:
    ///   IMG_1.CR3, IMG_1.JPG, IMG_1.xmp, IMG_1.psd (derivative: never part of the set), IMG_2.CR3
    static func makeOpsFixture() -> String? {
        let base = selfTestDir
        let dir = base + "/ops-\(ProcessInfo.processInfo.processIdentifier)"
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(atPath: base) {
            for n in old where n.hasPrefix("ops-") { try? fm.removeItem(atPath: base + "/" + n) }
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
            for name in ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp", "IMG_1.psd", "IMG_2.CR3"] {
                guard fm.createFile(atPath: dir + "/" + name, contents: Data(name.utf8), attributes: nil) else { return nil }
            }
        } catch {
            return nil
        }
        return dir
    }

    /// Self-test only: a file with `bytes` bytes and a known modification date, or a folder.
    static func makeTestFile(_ path: String, bytes: Int, modified: Double) -> Bool {
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: nil) else { return false }
        return (try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)],
                                                       ofItemAtPath: path)) != nil
    }

    static func makeTestFolder(_ path: String) -> Bool {
        return (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)) != nil
    }

    static func makeTestSymlink(_ path: String, to target: String) -> Bool {
        return (try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)) != nil
    }

    static func removeOpsFixture(_ dir: String) {
        guard dir.hasPrefix(selfTestDir + "/ops-") else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Self-test only: a journal describing a rename that was interrupted after its first step.
    static func writeTestJournal(from: String, to: String) {
        writeJournal(op: "rename", pairs: [(from, to)])
    }

    static var selfTestDir: String { return cachesDir + "/selftest" }

    /// A fresh folder with known contents for the listing self-test:
    ///   a.txt (5 bytes), .hidden (1 byte), Folder/ (with inner.txt), "IMG 10.JPG", "IMG 9.JPG", "caf\u{e9}.txt"
    /// Returns its path, or nil when it could not be made.
    static func makeListingFixture() -> String? {
        let base = selfTestDir
        let dir = base + "/listing-\(ProcessInfo.processInfo.processIdentifier)"
        let fm = FileManager.default
        // Only ever remove our own fixture folders.
        if let old = try? fm.contentsOfDirectory(atPath: base) {
            for n in old where n.hasPrefix("listing-") {
                try? fm.removeItem(atPath: base + "/" + n)
            }
        }
        do {
            try fm.createDirectory(atPath: dir + "/Folder", withIntermediateDirectories: true, attributes: nil)
            let files: [(String, String)] = [("a.txt", "hello"), (".hidden", "h"), ("Folder/inner.txt", "x"),
                                             ("IMG 10.JPG", "jpg10"), ("IMG 9.JPG", "jpg9"), ("caf\u{e9}.txt", "")]
            for (name, body) in files {
                guard fm.createFile(atPath: dir + "/" + name, contents: Data(body.utf8), attributes: nil) else { return nil }
            }
        } catch {
            return nil
        }
        return dir
    }

    static func removeListingFixture(_ dir: String) {
        guard dir.hasPrefix(selfTestDir + "/listing-") else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: Report

    /// Zip the logs folder to `dest` (a path the user picked). Returns an error text or nil.
    static func saveReport(to dest: String) -> String? {
        Log.flush()
        let p = Process()
        p.launchPath = "/usr/bin/ditto"
        p.arguments = ["-c", "-k", "--keepParent", logsDir, dest]
        p.launch()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : "ditto exited with status \(p.terminationStatus)"
    }
}
