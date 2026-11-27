// CopyQueue.swift
// 0.16: the copy queue. Copies wait in a list and run one after another, now or at a set time.
// - Every copy is Find's usual checked copy (FileOperations.copy: hidden temporary name, every file
//   checked, then renamed into place). Nothing is ever overwritten: a name already at the destination
//   is skipped or kept as "name 2", as chosen when the copy was queued - the queue never stops to ask,
//   so a copy that runs at night isn't held up by a question.
// - Pause stops the item being copied safely (its unfinished copy is removed the usual way) and the
//   queue waits; Resume starts that item again. Items already copied are not copied again.
// - The queue is kept in Find's support folder, so waiting and scheduled copies are still there after
//   Find is quit and opened again. A copy that was running when Find stopped restarts its item.
// Pure Foundation: the rules and the runner are tested on Linux with real files.

import Foundation

struct CopyJob: Codable, Equatable {
    enum Status: String, Codable {
        case waiting, scheduled, running, paused, done, failed, stopped
    }

    var id: String
    var sources: [String]
    var destination: String
    /// "skip" (default) or "keepBoth": what to do when a name is already at the destination.
    var clash: String
    var status: Status
    var createdAt: Double
    /// Start at this time (seconds since 1970); nil = as soon as it is its turn.
    var startAt: Double?
    /// The Mac was asked to wake for it (pmset).
    var wake: Bool
    /// Sources finished (copied, or skipped because already there).
    var finished: [String]
    var copiedCount: Int
    var skippedCount: Int
    var problems: [String]
    var startedAt: Double?
    var endedAt: Double?

    init(id: String, sources: [String], destination: String, clash: String, startAt: Double?, wake: Bool, now: Double) {
        self.id = id
        self.sources = sources
        self.destination = destination
        self.clash = clash == "keepBoth" ? "keepBoth" : "skip"
        self.status = startAt == nil ? .waiting : .scheduled
        self.createdAt = now
        self.startAt = startAt
        self.wake = wake
        self.finished = []
        self.copiedCount = 0
        self.skippedCount = 0
        self.problems = []
        self.startedAt = nil
        self.endedAt = nil
    }

    var remaining: [String] { return sources.filter { !finished.contains($0) } }

    var title: String {
        let n = sources.count
        let what = n == 1 ? Paths.lastComponent(sources[0]) : "\(n) items"
        return "\(what) \u{2192} \(Paths.lastComponent(destination))"
    }

    static func == (a: CopyJob, b: CopyJob) -> Bool {
        return a.id == b.id && a.status == b.status && a.finished == b.finished && a.startAt == b.startAt
    }
}

struct CopyQueueFile: Codable {
    var version = 1
    var jobs: [CopyJob]
}

final class CopyQueue {
    private(set) var jobs: [CopyJob] = []
    private let lock = NSLock()

    init(jobs: [CopyJob] = []) {
        self.jobs = jobs
        // A copy that was running when Find stopped: its item starts again (nothing half-done is kept).
        for i in self.jobs.indices where self.jobs[i].status == .running { self.jobs[i].status = .waiting }
    }

    func snapshot() -> [CopyJob] {
        lock.lock(); defer { lock.unlock() }
        return jobs
    }

    func add(_ j: CopyJob) {
        lock.lock(); defer { lock.unlock() }
        jobs.append(j)
    }

    func update(_ id: String, _ change: (inout CopyJob) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let i = jobs.index(where: { $0.id == id }) { change(&jobs[i]) }
    }

    /// Remove a job that isn't running. Returns false if it is running (pause it first).
    @discardableResult
    func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = jobs.index(where: { $0.id == id }), jobs[i].status != .running else { return false }
        jobs.remove(at: i)
        return true
    }

    func move(_ id: String, by d: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let i = jobs.index(where: { $0.id == id }) else { return }
        let j = i + d
        guard j >= 0 && j < jobs.count else { return }
        jobs.swapAt(i, j)
    }

    /// Finished copies (done, failed, stopped) are cleared from the list.
    func clearFinished() {
        lock.lock(); defer { lock.unlock() }
        jobs = jobs.filter { $0.status != .done && $0.status != .failed && $0.status != .stopped }
    }

    /// The next job to run now: the first waiting one in list order, or a scheduled one whose time has
    /// come (also when the Mac was asleep at that time: it runs as soon as Find sees it). nil if one is
    /// running already or none is due.
    func nextDue(now: Double) -> CopyJob? {
        lock.lock(); defer { lock.unlock() }
        if jobs.contains(where: { $0.status == .running }) { return nil }
        return jobs.first(where: { j in
            j.status == .waiting || (j.status == .scheduled && (j.startAt ?? 0) <= now)
        })
    }

    func encode() -> Data? {
        return try? JSONEncoder().encode(CopyQueueFile(version: 1, jobs: snapshot()))
    }

    static func decode(_ d: Data) -> [CopyJob]? {
        return (try? JSONDecoder().decode(CopyQueueFile.self, from: d))?.jobs
    }
}

enum CopyQueueRunner {
    /// Run one job, item by item, with Find's checked copy. `pauseRequested` is checked during each item
    /// (the item in progress is stopped safely) and between items. `progress` is called after each item.
    /// Returns the job as it ended (done, failed, paused).
    static func run(_ job: CopyJob, ops: FileOperations, now: () -> Double,
                    pauseRequested: @escaping () -> Bool,
                    transfer: TransferProgress? = nil,
                    progress: (CopyJob, String) -> Void) -> CopyJob {
        var j = job
        j.status = .running
        if j.startedAt == nil { j.startedAt = now() }
        if !Sys.exists(j.destination) {
            j.status = .failed
            j.problems.append("The destination folder isn't there: \(j.destination)")
            j.endedAt = now()
            return j
        }
        let choice: ConflictChoice = j.clash == "keepBoth" ? .keepBoth : .skip
        for src in j.remaining {
            if pauseRequested() { j.status = .paused; return j }
            if !Sys.exists(src) {
                j.problems.append("Not there any more (not copied): \(src)")
                j.finished.append(src)
                progress(j, src)
                continue
            }
            let r = ops.copy([src], into: j.destination, choose: { _ in choice }, isCancelled: pauseRequested, progress: transfer)
            if r.cancelled {
                // Paused during this item: the item starts again on Resume.
                j.status = .paused
                return j
            }
            j.copiedCount += r.done.count
            j.skippedCount += r.skipped.count
            for f in r.failed { j.problems.append("\(f.error.code): \(f.error.description)") }
            for n in r.notes { j.problems.append("Note: \(n)") }
            j.finished.append(src)
            progress(j, src)
        }
        j.endedAt = now()
        j.status = j.problems.contains(where: { !$0.hasPrefix("Note:") }) ? .failed : .done
        return j
    }

    /// A numbered plain-text report of a job (for AutoType).
    static func report(_ j: CopyJob, dateText: (Double) -> String) -> [String] {
        var out: [String] = []
        out.append("Copy: \(j.title)")
        out.append("Destination: \(j.destination)")
        out.append("Result: \(j.status.rawValue.uppercased())")
        out.append("Items: \(j.sources.count); finished: \(j.finished.count)")
        out.append("Copied: \(j.copiedCount); skipped (already there, nothing overwritten): \(j.skippedCount)")
        out.append("Name clashes: \(j.clash == "keepBoth" ? "keep both (numbered name)" : "skip (nothing overwritten)")")
        if let s = j.startAt { out.append("Scheduled for: \(dateText(s))\(j.wake ? " (Mac asked to wake)" : "")") }
        if let s = j.startedAt { out.append("Started: \(dateText(s))") }
        if let e = j.endedAt { out.append("Ended: \(dateText(e))") }
        out.append("Problems: \(j.problems.count)")
        for p in j.problems { out.append("PROBLEM " + p) }
        return out.enumerated().map { String(format: "Q%03d ", $0.offset + 1) + Ascii.clean($0.element) } + ["Total: \(out.count) lines"]
    }

    /// pmset's date for a wake-up one minute before `t`, in local time ("MM/dd/yy HH:mm:ss"). Only digits,
    /// slashes, colons and a space: safe to put in a command.
    static func wakeDate(_ t: Double, timeZone: TimeZone = TimeZone.current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MM/dd/yy HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t - 60))
    }
}
