// Stats.swift
// Session numbers for the Short Report: listing times by volume kind, freezes, warning/error codes,
// last self-test. Holds no paths or file names, so the report can be retyped from an air-gapped Mac
// without redacting anything.

import Foundation

enum Stats {
    private static let lock = NSLock()
    private static var listings: [Bool: [(ms: Double, bulk: Bool)]] = [true: [], false: []]
    private static var freezes: [Double] = []
    private static var codes: [String: Int] = [:]
    private static var selfTest: [SelfTestResult] = []
    static let started = Date()

    static func noteListing(network: Bool, ms: Double, method: String) {
        lock.lock(); defer { lock.unlock() }
        var a = listings[network] ?? []
        a.append((ms: ms, bulk: method.hasPrefix("bulk")))
        if a.count > 1000 { a.removeFirst(a.count - 1000) }
        listings[network] = a
    }

    static func noteFreeze(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        freezes.append(seconds)
    }

    /// Called by Log for every warning/error line: counts a leading code like "W-LIST-2".
    static func noteLogLine(_ text: String) {
        guard let first = text.split(separator: " ", maxSplits: 1).first else { return }
        let token = String(first)
        let parts = token.split(separator: "-")
        guard parts.count == 3, parts[0] == "W" || parts[0] == "E", Int(parts[2]) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        codes[token, default: 0] += 1
    }

    static func noteSelfTest(_ results: [SelfTestResult]) {
        lock.lock(); defer { lock.unlock() }
        selfTest = results
    }

    private static func line(_ label: String, _ a: [(ms: Double, bulk: Bool)]) -> String {
        if a.isEmpty { return "\(label) none" }
        let ms = a.map { $0.ms }.sorted()
        let median = ms[ms.count / 2]
        let bulk = a.filter { $0.bulk }.count
        return String(format: "%@ n=%ld median %.0f ms, slowest %.0f ms, bulk %ld/%ld",
                      label, a.count, median, ms.last ?? 0, bulk, a.count)
    }

    /// About ten lines, no paths or names.
    static func shortReport(version: String, brain: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let minutes = Int(Date().timeIntervalSince(started) / 60)
        var out = ["PhotoLab \(version) | \(SystemInfo.summary) | up \(minutes) min"]
        if selfTest.isEmpty {
            out.append("SELFTEST not run (Help > Run Self-Test)")
        } else {
            let okN = selfTest.filter { $0.status == .ok }.count
            let failed = selfTest.filter { $0.status == .fail }.map { $0.name }
            let warned = selfTest.filter { $0.status == .warn }.map { $0.name }
            var s = "SELFTEST \(okN) ok, \(failed.count) fail, \(warned.count) warn"
            if !failed.isEmpty { s += " | FAIL: " + failed.joined(separator: ", ") }
            if !warned.isEmpty { s += " | WARN: " + warned.joined(separator: ", ") }
            out.append(s)
        }
        out.append(line("LIST local", listings[false] ?? []))
        out.append(line("LIST share", listings[true] ?? []))
        if freezes.isEmpty {
            out.append("FREEZE none")
        } else {
            out.append(String(format: "FREEZE %ld (longest %.2f s)", freezes.count, freezes.max() ?? 0))
        }
        out.append(codes.isEmpty ? "CODES none"
                   : "CODES " + codes.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
        out.append(brain.replacingOccurrences(of: "Brain: ", with: "BRAIN "))
        return out.joined(separator: "\n")
    }
}
