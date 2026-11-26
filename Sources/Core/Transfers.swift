// Transfers.swift
// Copy / move jobs: the model the engine (FileOperations, the only place that changes files)
// fills in and the progress panel reads, plus the pure rules (drop operation, "keep both" names,
// folder-into-itself). Nothing here touches the disk.

import Foundation

enum TransferKind: String { case copy, move }

/// What to do when a name is already taken in the destination. There is no "replace":
/// PhotoLab never overwrites (CLAUDE.md rule 3).
enum ClashChoice: String { case keepBoth, skip }

/// One top-level item of a job. Items of one set share `group`: they are skipped or renamed
/// ("IMG_1 2.CR3" + "IMG_1 2.JPG") together, so a set stays a set.
struct TransferItem {
    let source: String
    let group: Int
    let isFolder: Bool
    let crossDevice: Bool
}

final class TransferJob {
    enum State: String { case waiting, scanning, running, done, stopped, failed }

    struct Progress {
        var state: State = .waiting
        var totalFiles = 0
        var doneFiles = 0
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var current = ""
        var failures: [String] = []      // "name: reason", for the user
        var notes: [String] = []         // things the user should know that are not failures
        var skipped = 0
        var started: Date?
        var finished: Date?
    }

    let id: String
    let kind: TransferKind
    let destination: String
    let items: [TransferItem]
    let clash: ClashChoice
    /// Copy into the folder the items are in: names become "name copy", "name copy 2".
    let duplicate: Bool

    // Results, written by the engine and read on the main thread after it finished.
    var created: [String] = []               // final top-level paths of new copies
    var moved: [(String, String)] = []       // same-volume moves (renames), for undo
    var removedOriginals = 0                 // cross-volume moves: originals removed after verify

    /// Self-test only: runs after the scan, before anything is written.
    var testHookAfterScan: ((TransferJob) -> Void)?

    private let lock = NSLock()
    private var p = Progress()
    private var cancelled = false

    init(kind: TransferKind, destination: String, items: [TransferItem], clash: ClashChoice, duplicate: Bool) {
        self.id = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        self.kind = kind
        self.destination = destination
        self.items = items
        self.clash = clash
        self.duplicate = duplicate
    }

    var progress: Progress { lock.lock(); defer { lock.unlock() }; return p }
    func update(_ change: (inout Progress) -> Void) { lock.lock(); change(&p); lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    var isFinished: Bool {
        let s = progress.state
        return s == .done || s == .stopped || s == .failed
    }

    /// "Copying 3 items to "Selects"".
    var title: String {
        let verb = duplicate ? "Duplicating" : (kind == .copy ? "Copying" : "Moving")
        let n = items.count
        let what = n == 1 ? "\"\(Paths.name(items[0].source))\"" : "\(n) items"
        return duplicate ? "\(verb) \(what)" : "\(verb) \(what) to \"\(Paths.name(destination))\""
    }
}

enum Transfers {
    /// Prefix of the hidden name a copy has until it is complete and verified. An interrupted copy
    /// is never visible under its real name; launch recovery removes these (journaled).
    static let partialPrefix = ".photolab-partial-"

    /// Drag and drop, like Finder: Option copies, Command moves, otherwise move on the same
    /// volume and copy to another one.
    static func dropOperation(sameVolume: Bool, option: Bool, command: Bool) -> TransferKind {
        if option { return .copy }
        if command { return .move }
        return sameVolume ? .move : .copy
    }

    /// Same volume by the mount table (memory only: safe on the main thread).
    static func sameVolume(_ a: String, _ b: String) -> Bool {
        return Volumes.volume(for: a)?.mountPoint == Volumes.volume(for: b)?.mountPoint
    }

    /// "IMG_1.CR3" -> "IMG_1 2.CR3" (keep both) or "IMG_1 copy.CR3", "IMG_1 copy 2.CR3"
    /// (duplicate). Folders keep dots in their names.
    static func numberedName(_ name: String, _ n: Int, duplicate: Bool, isFolder: Bool) -> String {
        let parts: (stem: String, ext: String) = isFolder ? (name, "") : FileOperations.split(name)
        let suffix = duplicate ? (n <= 1 ? " copy" : " copy \(n)") : " \(n)"
        return parts.stem + suffix + (parts.ext.isEmpty ? "" : "." + parts.ext)
    }

    /// A folder copied or moved into itself or its own subfolder would never end. Paths must be
    /// resolved (no symlinks) by the caller.
    static func intoItself(source: String, destination: String) -> Bool {
        return destination == source || destination.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }
}
