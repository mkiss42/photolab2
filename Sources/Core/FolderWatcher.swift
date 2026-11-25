// FolderWatcher.swift
// Watches the folder a window is showing. Read-only.
//  - kqueue (DispatchSource) on the folder: instant on local disks.
//  - On network volumes kqueue is unreliable (missed events, and "deleted"/"renamed" for a folder
//    that is still there), so we also poll the folder's mtime every few seconds - one stat,
//    only for the folder on screen.
//  - Every event is only a hint. Before the window leaves a folder, the folder must be missing
//    twice, half a second apart.
// Callbacks arrive on the main queue, debounced.

import Foundation
import Darwin

final class FolderWatcher {
    enum Change { case contents, gone }

    let path: String
    private let onChange: (Change) -> Void
    private let queue = DispatchQueue(label: "photolab.watch")
    private var source: DispatchSourceFileSystemObject?
    private var poll: DispatchSourceTimer?
    private var lastMtime: Double?
    private var pending: DispatchWorkItem?
    private var stopped = false

    static let pollInterval: Double = 4.0
    static let debounce: Double = 0.3

    init(path: String, onChange: @escaping (Change) -> Void) {
        self.path = path
        self.onChange = onChange
        queue.async { self.start() }
    }

    deinit {
        source?.cancel()
        poll?.cancel()
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.pending?.cancel()
            self.source?.cancel(); self.source = nil
            self.poll?.cancel(); self.poll = nil
        }
    }

    private func start() {
        lastMtime = ListingCache.folderMtime(path)
        let fd = open(path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                              eventMask: [.write, .delete, .rename, .link, .revoke],
                                                              queue: queue)
            s.setEventHandler { [weak self] in
                guard let me = self, let src = me.source else { return }
                let ev = src.data
                if ev.contains(.delete) || ev.contains(.rename) || ev.contains(.revoke) {
                    me.verifyStillThere()
                } else {
                    me.schedule(.contents)
                }
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        }
        if Volumes.isNetwork(path) {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + FolderWatcher.pollInterval, repeating: FolderWatcher.pollInterval,
                       leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.pollOnce() }
            t.resume()
            poll = t
        }
    }

    private func pollOnce() {
        let m = ListingCache.folderMtime(path)
        if m == nil {
            verifyStillThere()
        } else if m != lastMtime {
            lastMtime = m
            schedule(.contents)
        }
    }

    /// "Gone" only after two failed looks 0.5 s apart; otherwise it was a contents change.
    private func verifyStillThere() {
        var st = stat()
        if stat(path, &st) == 0 { schedule(.contents); return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let me = self, !me.stopped else { return }
            var st2 = stat()
            if stat(me.path, &st2) == 0 {
                me.schedule(.contents)
            } else if errno == ENOENT || errno == ENOTDIR {
                me.schedule(.gone)
            } else {
                // Share unreachable, permission...: stay, the listing will show the problem.
                me.schedule(.contents)
            }
        }
    }

    private func schedule(_ c: Change) {
        if stopped { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let me = self, !me.stopped else { return }
            me.lastMtime = ListingCache.folderMtime(me.path)
            DispatchQueue.main.async { me.onChange(c) }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + FolderWatcher.debounce, execute: item)
    }
}
