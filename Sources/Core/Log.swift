// Log.swift
// Logs and reports that survive being retyped by AutoType:
//  - plain ASCII only (anything else becomes <U+XXXX>)
//  - one fact per line, no tabs, no tables, no indentation
//  - every line numbered L0001, L0002, ... and the file ends with a total-lines line
//  - failures use fixed codes (E-..., T-...)

import Foundation

enum Ascii {
    /// Replace anything that isn't printable ASCII. Newlines inside a message become " | ".
    static func clean(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            let v = u.value
            if v == 10 || v == 13 {
                out += " | "
            } else if v == 9 {
                out += " "
            } else if v >= 32 && v < 127 {
                out.unicodeScalars.append(u)
            } else {
                out += "<U+" + String(format: "%04X", v) + ">"
            }
        }
        return out
    }

    static func timestamp(_ d: Date = Date(), withDate: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = withDate ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss"
        return f.string(from: d)
    }

    static func fileStamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }
}

/// Builds a numbered, ASCII-only report: summary first, then details, then the total line.
final class Report {
    private var summary: [String] = []
    private var lines: [String] = []
    let title: String

    init(title: String) { self.title = title }

    func addSummary(_ s: String) { summary.append(Ascii.clean(s)) }
    func add(_ s: String) { lines.append(Ascii.clean(s)) }

    /// The finished text.
    func render() -> String {
        var raw: [String] = []
        raw.append("FIND REPORT: " + Ascii.clean(title))
        raw.append("CREATED: " + Ascii.timestamp())
        raw.append("SUMMARY START")
        raw.append(contentsOf: summary)
        raw.append("SUMMARY END")
        raw.append("DETAILS START")
        raw.append(contentsOf: lines)
        raw.append("DETAILS END")
        var out = ""
        var n = 0
        for l in raw {
            n += 1
            out += String(format: "L%04d ", n) + l + "\n"
        }
        n += 1
        out += String(format: "L%04d ", n) + "END OF REPORT total-lines=\(n)\n"
        return out
    }
}

/// The running log for one launch of Find: ~/Library/Logs/Find/find-YYYYMMDD-HHMMSS.log
final class Log {
    static var shared: Log?

    let path: String
    private var counter = 0
    private let queue = DispatchQueue(label: "find.log")
    private let files: AppFiles

    init(files: AppFiles) {
        self.files = files
        path = Paths.join(files.logsDir, "find-\(Ascii.fileStamp()).log")
        // Keep the 10 most recent logs.
        let logs = files.list(files.logsDir).filter { $0.hasPrefix("find-") && $0.hasSuffix(".log") }
        if logs.count > 9 {
            for old in logs.prefix(logs.count - 9) { files.removeOwned(Paths.join(files.logsDir, old)) }
        }
    }

    private func write(_ level: String, _ msg: String) {
        let stamp = Ascii.timestamp(withDate: false)
        queue.async {
            self.counter += 1
            let line = String(format: "L%05d ", self.counter) + stamp + " " + level + " " + Ascii.clean(msg) + "\n"
            self.files.appendText(line, to: self.path)
        }
    }

    func info(_ msg: String) { write("INFO", msg) }
    /// Extra detail, written only when Settings > Advanced > Debug logging is on.
    static var debugEnabled = false
    func debug(_ msg: String) { if Log.debugEnabled { write("DEBUG", msg) } }
    func warn(_ msg: String) { write("WARN", msg) }
    func error(_ msg: String) { write("ERROR", msg) }

    /// Wait until queued lines are on disk.
    func flush() { queue.sync {} }

    private func currentCount() -> Int {
        var n = 0
        queue.sync {
            n = self.counter
        }
        return n
    }

    /// The log so far, with a closing total-lines line (for copying to the clipboard / AutoType).
    func snapshot() -> String {
        flush()
        let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let n = currentCount()
        return body + String(format: "L%05d ", n + 1) + "END OF LOG SNAPSHOT total-lines=\(n + 1)\n"
    }

    /// Final line written when Find quits.
    func close() {
        write("INFO", "END OF LOG")
        flush()
        let n = currentCount()
        files.appendText(String(format: "L%05d ", n + 1) + "total-lines=\(n + 1)\n", to: path)
    }
}
