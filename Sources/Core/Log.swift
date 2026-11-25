// Log.swift
// Plain-ASCII log, one fact per line: "2026-11-25 10:23:01.123 INFO text".
// Writing to disk happens in AppFiles (one of the three files allowed to change files).

import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "photolab.log")
    /// Also print to stdout (self-test, CI).
    static var echo = false

    static func info(_ text: String) { write("INFO", text) }
    static func warn(_ text: String) { write("WARN", text) }
    static func error(_ text: String) { write("ERROR", text) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func write(_ level: String, _ text: String) {
        let stamp = stampFormatter.string(from: Date())   // DateFormatter is thread-safe since 10.9
        let line = "\(stamp) \(level) \(Ascii.clean(text))\n"
        if echo { print(line, terminator: "") }
        queue.async { AppFiles.appendLog(line) }
    }

    /// Wait until queued lines are on disk (before quitting or saving a report).
    static func flush() {
        queue.sync {}
    }
}

enum Ascii {
    /// Non-ASCII and control characters become "?", newlines become spaces.
    static func clean(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            if u == "\n" || u == "\r" || u == "\t" {
                out.append(" ")
            } else if u.value >= 0x20 && u.value < 0x7F {
                out.unicodeScalars.append(u)
            } else {
                out.append("?")
            }
        }
        return out
    }
}
