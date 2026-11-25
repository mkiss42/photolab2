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
