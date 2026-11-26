// TransferController.swift
// Starts copy / move jobs (paste, drag and drop, duplicate): plans them in the background, asks
// once when names are taken (Keep Both / Skip / Stop - never Replace), queues them, and on the
// main thread afterwards registers undo, re-lists the folders and reports problems.
// Jobs to the same volume run one after another (parallel writes to one share only slow it down);
// jobs to different volumes run side by side.

import AppKit

final class TransferController {
    static let shared = TransferController()

    private let planQueue = DispatchQueue(label: "photolab.transfer.plan", qos: .userInitiated)
    private var queues: [String: DispatchQueue] = [:]
    /// Running, waiting and recently finished jobs (the panel shows them).
    private(set) var jobs: [TransferJob] = []

    func start(_ paths: [String], to dest: String, kind: TransferKind, from window: BrowserWindowController?) {
        guard !paths.isEmpty else { return }
        let sets = FileOperations.useSets
        planQueue.async { [weak self, weak window] in
            let plan = FileOperations.planTransfer(paths, to: dest, kind: kind, sets: sets)
            DispatchQueue.main.async {
                guard let me = self else { return }
                if let p = plan.problem {
                    window?.showProblem(kind == .copy ? "Not copied" : "Not moved", p)
                    return
                }
                if plan.items.isEmpty { return }                 // a move onto the folder it is in
                if plan.clashes.isEmpty || plan.duplicate {
                    me.enqueue(plan, kind: kind, dest: dest, clash: .keepBoth, window: window)
                    return
                }
                me.askAboutClashes(plan, kind: kind, dest: dest, window: window) { choice in
                    if let c = choice { me.enqueue(plan, kind: kind, dest: dest, clash: c, window: window) }
                    else { Log.info("\(kind.rawValue) to \(dest) stopped at the name question") }
                }
            }
        }
    }

    private func askAboutClashes(_ plan: FileOperations.TransferPlan, kind: TransferKind, dest: String,
                                 window: BrowserWindowController?, done: @escaping (ClashChoice?) -> Void) {
        let a = NSAlert()
        let n = plan.clashes.count
        let folder = Paths.name(dest)
        a.messageText = n == 1 ? "\"\(plan.clashes[0])\" already exists in \"\(folder)\"."
                               : "\(n) items with these names already exist in \"\(folder)\"."
        var names = plan.clashes.prefix(8).joined(separator: "\n")
        if n > 8 { names += "\n...and \(n - 8) more" }
        a.informativeText = (n == 1 ? "" : names + "\n\n")
            + "Keep Both gives the new \(n == 1 ? "item" : "items") a number (\"IMG_1 2.CR3\"); a set keeps one name. "
            + "Skip leaves \(n == 1 ? "it" : "them") out. Nothing is ever replaced."
        a.addButton(withTitle: "Keep Both")
        a.addButton(withTitle: "Skip")
        a.addButton(withTitle: "Stop")
        a.buttons[2].keyEquivalent = "\u{1b}"
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            switch r {
            case .alertFirstButtonReturn: done(.keepBoth)
            case .alertSecondButtonReturn: done(.skip)
            default: done(nil)
            }
        }
        if let w = window?.window { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }

    private func enqueue(_ plan: FileOperations.TransferPlan, kind: TransferKind, dest: String, clash: ClashChoice,
                         window: BrowserWindowController?) {
        let job = TransferJob(kind: kind, destination: dest, items: plan.items, clash: clash, duplicate: plan.duplicate)
        jobs.append(job)
        let key = Volumes.volume(for: dest)?.mountPoint ?? "/"
        let q = queues[key] ?? DispatchQueue(label: "photolab.transfer.\(queues.count)", qos: .userInitiated)
        queues[key] = q
        TransfersPanel.shared.jobAdded()
        q.async { [weak self, weak window] in
            FileOperations.runTransfer(job)
            DispatchQueue.main.async { self?.finished(job, window: window) }
        }
    }

    private func finished(_ job: TransferJob, window: BrowserWindowController?) {
        let p = job.progress
        var dirs = Set([job.destination])
        for it in job.items { dirs.insert(Paths.parent(it.source)) }
        let createdNames = job.created.map { Paths.name($0) } + job.moved.map { Paths.name($0.1) }
        for w in BrowserWindowController.open {
            let select = w === window && w.currentPath == job.destination && !createdNames.isEmpty ? createdNames : nil
            w.reloadAfterOp(dirs, select: select)
        }
        if let w = window {
            if !job.moved.isEmpty { w.registerUndoRename(job.moved, name: "Move") }
            if job.kind == .copy && !job.created.isEmpty { w.registerUndoCopy(job.created, name: job.duplicate ? "Duplicate" : "Copy") }
        }
        if !p.failures.isEmpty {
            var text = p.failures.prefix(10).joined(separator: "\n")
            if p.failures.count > 10 { text += "\n...and \(p.failures.count - 10) more (see the log)" }
            text += job.kind == .move ? "\n\nWhere a copy failed, the original was kept where it was." : "\n\nThe originals are untouched."
            let title = "\(p.failures.count) item\(p.failures.count == 1 ? " was" : "s were") not \(job.kind == .copy ? "copied" : "moved")"
            (window ?? BrowserWindowController.open.first)?.showProblem(title, text)
        } else if !p.notes.isEmpty {
            (window ?? BrowserWindowController.open.first)?.showProblem("Move finished", p.notes.joined(separator: "\n"))
        }
        TransfersPanel.shared.jobFinished()
    }

    /// The panel drops finished jobs it no longer shows.
    func forget(_ job: TransferJob) {
        jobs.removeAll { $0 === job }
    }
}
