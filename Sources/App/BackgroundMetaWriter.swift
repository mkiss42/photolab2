// BackgroundMetaWriter.swift
// 0.18.10: every metadata write goes through ONE queue, so two writes never work on the same file at the
// same time. Ratings and colour classes don't wait: the stars show at once, the write happens behind
// (no progress sheet) and you go on to the next pictures; what you do quickly in a row is written in
// one go (the last value of each picture wins). A small line in the Photography bar says how many are
// still being written; Find waits for them before it quits. If a write fails, the pictures' real
// values are read again (the stars go back) and the report says why.

import AppKit

final class BackgroundMetaWriter {
    static let shared = BackgroundMetaWriter()
    /// The one queue for all metadata writes (background and with a progress sheet).
    let queue = DispatchQueue(label: "find.metadata.write")
    private let lock = NSLock()
    private var pending: [(items: [(image: String, change: MetaChange)], title: String, pane: BrowserPane?)] = []
    private var scheduled = false
    private(set) var busy = 0          // pictures queued or being written (main thread reads it)
    var onIdle: [() -> Void] = []      // run (main thread) when nothing is left - e.g. quitting

    func enqueue(_ items: [(image: String, change: MetaChange)], title: String, pane: BrowserPane) {
        lock.lock()
        pending.append((items, title, pane))
        busy += items.count
        let start = !scheduled
        scheduled = true
        lock.unlock()
        updateStatus(pane)
        pane.metadataWriting(items.count)
        if start { queue.async { self.drain() } }
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy > 0 }

    private func drain() {
        while true {
            lock.lock()
            let jobs = pending
            pending = []
            if jobs.isEmpty { scheduled = false; lock.unlock(); break }
            lock.unlock()
            let items = MetaChange.merged(jobs.map { $0.items })
            let started = Date()
            let r = App.ops.writeMetadata(items)
            let count = jobs.reduce(0) { $0 + $1.items.count }
            let panes = jobs.compactMap { $0.pane }
            let title = jobs.count == 1 ? jobs[0].title : "Ratings and colour classes"
            DispatchQueue.main.async {
                self.lock.lock(); self.busy = max(0, self.busy - count); let left = self.busy; self.lock.unlock()
                App.log.info(String(format: "\(title) (in the background): \(r.done.count) file(s) written and checked in %.1f s", Date().timeIntervalSince(started)))
                for n in r.notes { App.log.info("Note: " + n) }
                for j in jobs { j.pane?.metadataWriting(-j.items.count) }
                let written = jobs.flatMap { $0.items.map { $0.image } }
                PhotoFactsStore.shared.forget(written + r.done.flatMap { [$0.from, $0.to] })
                MetaPending.shared.remove(written)
                // Undo and the report on the pane the last change came from; the others just read again.
                var seen = Set<ObjectIdentifier>()
                for (k, p) in panes.reversed().enumerated() where !seen.contains(ObjectIdentifier(p)) {
                    seen.insert(ObjectIdentifier(p))
                    p.backgroundWriteFinished(r, title: title, owner: k == 0, stillWriting: left)
                }
                if left == 0 {
                    let w = self.onIdle
                    self.onIdle = []
                    for f in w { f() }
                }
            }
        }
    }

    private func updateStatus(_ p: BrowserPane) {
        p.photoBar.status.stringValue = "Writing \(busy) in the background\u{2026}"
    }
}

/// PhotoLab: the pictures with a metadata change still to be written (queued, or ExifTool / the share
/// still busy with it). Their thumbnails and rows show a spinner until it is done. Main thread.
final class MetaPending {
    static let shared = MetaPending()
    static let changed = Notification.Name("PhotoLabMetaPending")
    private var counts: [String: Int] = [:]

    func contains(_ path: String) -> Bool { return counts[path] != nil }
    var isEmpty: Bool { return counts.isEmpty }

    func add(_ paths: [String]) {
        for p in paths { counts[p, default: 0] += 1 }
        NotificationCenter.default.post(name: MetaPending.changed, object: nil, userInfo: ["paths": paths])
    }

    func remove(_ paths: [String]) {
        for p in paths {
            if let n = counts[p] { if n <= 1 { counts.removeValue(forKey: p) } else { counts[p] = n - 1 } }
        }
        NotificationCenter.default.post(name: MetaPending.changed, object: nil, userInfo: ["paths": paths])
    }
}
