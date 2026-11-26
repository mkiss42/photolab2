// Stats.swift
// Session numbers for the Short Report: listing times by volume kind, freezes, warning/error codes,
// last self-test. Holds no paths or file names, so the report can be retyped from an air-gapped Mac
// without redacting anything.

import Foundation

enum Stats {
    private static let lock = NSLock()
    private static var listings: [Bool: [(ms: Double, bulk: Bool, entries: Int)]] = [true: [], false: []]
    private static var freezes: [Double] = []
    private static var freezeWhat: [String: Int] = [:]
    private static var cacheHits = 0
    private static var watchEvents = 0
    private static var watchGone = 0
    private static var slowIcons: [Double] = []
    private static var codes: [String: Int] = [:]
    private static var selfTest: [SelfTestResult] = []
    private static var transfers: [Bool: (jobs: Int, files: Int, bytes: Int64, seconds: Double)] = [:]
    private static var transferFailures = 0
    static let started = Date()
    /// > 0 while the self-test runs: its deliberate warnings (simulated stops, permanent delete
    /// of its own fixture) must not show up in CODES as if they were the user's.
    private static var selfTestDepth = 0

    static func selfTestRunning(_ running: Bool) {
        lock.lock(); selfTestDepth += running ? 1 : -1; lock.unlock()
    }

    static func noteListing(network: Bool, ms: Double, method: String, entries: Int) {
        lock.lock(); defer { lock.unlock() }
        var a = listings[network] ?? []
        a.append((ms: ms, bulk: method.hasPrefix("bulk"), entries: entries))
        if a.count > 1000 { a.removeFirst(a.count - 1000) }
        listings[network] = a
    }

    /// `during` is the Activity text; only its kind ("list", "show", "launch"...) is kept, no path.
    static func noteFreeze(_ seconds: Double, during: String = "") {
        let kind = during.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "?"
        lock.lock(); defer { lock.unlock() }
        freezes.append(seconds)
        freezeWhat[kind, default: 0] += 1
    }

    static func noteTransfer(files: Int, bytes: Int64, seconds: Double, network: Bool, failed: Int) {
        lock.lock(); defer { lock.unlock() }
        var t = transfers[network] ?? (0, 0, 0, 0)
        t.jobs += 1; t.files += files; t.bytes += bytes; t.seconds += seconds
        transfers[network] = t
        transferFailures += failed
    }

    static func noteCacheHit() { lock.lock(); cacheHits += 1; lock.unlock() }
    static func noteWatch(gone: Bool) { lock.lock(); watchEvents += 1; if gone { watchGone += 1 }; lock.unlock() }
    static func noteSlowIcon(_ ms: Double) { lock.lock(); slowIcons.append(ms); lock.unlock() }

    /// Called by Log for every warning/error line: counts a leading code like "W-LIST-2".
    static func noteLogLine(_ text: String) {
        guard let first = text.split(separator: " ", maxSplits: 1).first else { return }
        let token = String(first)
        let parts = token.split(separator: "-")
        guard parts.count == 3, parts[0] == "W" || parts[0] == "E", Int(parts[2]) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        if selfTestDepth > 0 { return }
        codes[token, default: 0] += 1
    }

    static func noteSelfTest(_ results: [SelfTestResult]) {
        lock.lock(); defer { lock.unlock() }
        selfTest = results
    }

    private static func line(_ label: String, _ a: [(ms: Double, bulk: Bool, entries: Int)]) -> String {
        if a.isEmpty { return "\(label) none" }
        let ms = a.map { $0.ms }.sorted()
        let median = ms[ms.count / 2]
        let bulk = a.filter { $0.bulk }.count
        let slowest = a.max { $0.ms < $1.ms }!
        let empty = a.filter { $0.entries == 0 }.count
        return String(format: "%@ n=%ld median %.0f ms, slowest %.0f ms (%ld items), bulk %ld/%ld, empty %ld",
                      label, a.count, median, slowest.ms, slowest.entries, bulk, a.count, empty)
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
            let what = freezeWhat.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
            out.append(String(format: "FREEZE %ld (longest %.2f s) during: %@", freezes.count, freezes.max() ?? 0, what))
        }
        let total = (listings[false]?.count ?? 0) + (listings[true]?.count ?? 0)
        out.append("CACHE \(cacheHits) folder(s) from memory, \(total) read from disk")
        out.append("WATCH \(watchEvents) change event(s), \(watchGone) folder(s) gone")
        out.append(slowIcons.isEmpty ? "ICONS no slow loads"
                   : String(format: "ICONS %ld slow load(s), longest %.0f ms", slowIcons.count, slowIcons.max() ?? 0))
        let methods = Dictionary(grouping: (listings[false] ?? []) + (listings[true] ?? []), by: { $0.bulk ? "bulk" : "readdir" })
            .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
        out.append("METHOD " + (methods.isEmpty ? "none" : methods))
        if transfers.isEmpty {
            out.append("COPY none")
        } else {
            let parts = [(false, "local"), (true, "share")].compactMap { (net, label) -> String? in
                guard let t = transfers[net] else { return nil }
                let mb = Double(t.bytes) / 1_000_000
                return String(format: "%@ %ld job(s) %ld file(s) %.0f MB %.0f MB/s", label, t.jobs, t.files, mb,
                              t.seconds > 0 ? mb / t.seconds : 0)
            }
            out.append("COPY " + parts.joined(separator: " | ") + " | \(transferFailures) failed")
        }
        out.append(codes.isEmpty ? "CODES none"
                   : "CODES " + codes.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
        out.append(brain.replacingOccurrences(of: "Brain: ", with: "BRAIN "))
        return out.joined(separator: "\n")
    }
}
