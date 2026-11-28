// PhotoFactsStore.swift
// Reads rating, label, camera and lens for the pictures in the current folder (photography mode),
// in the background: macOS first, ExifTool in batches for files macOS can't read, then the XMP
// sidecar's rating and label on top. Results are remembered per file (size + modified date + sidecar
// date), so a folder is read once. Read-only.

import Foundation

final class PhotoFactsStore {
    static let shared = PhotoFactsStore()

    private struct Stamp: Equatable {
        let size: Int64
        let modified: Double
        let sidecar: Double
        static func == (a: Stamp, b: Stamp) -> Bool { return a.size == b.size && a.modified == b.modified && a.sidecar == b.sidecar }
    }
    private var memo: [String: (Stamp, PhotoFacts)] = [:]
    private let lock = NSLock()
    private var running = AtomicInt()

    /// Load facts for `entries`. `onBatch` gets newly known facts (main thread), `onDone` when finished.
    /// Starting a new load cancels the previous one.
    func load(_ entries: [FileEntry], onBatch: @escaping ([String: PhotoFacts], Int, Int) -> Void, onDone: @escaping () -> Void) {
        running.value += 1
        let token = running.value
        let flag = running
        let photos = entries.filter { $0.kind == .file && PhotoFormats.isImage($0.name) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let s = self else { return }
            let total = photos.count
            var done = 0
            var batch: [String: PhotoFacts] = [:]
            var forExifTool: [(FileEntry, Stamp, PhotoFacts)] = []
            let started = Date()
            func flush(force: Bool) {
                if batch.isEmpty && !force { return }
                let b = batch, d = done
                batch = [:]
                DispatchQueue.main.async { if flag.value == token { onBatch(b, d, total) } }
            }
            for e in photos {
                if flag.value != token { return }
                let sc = Sidecars.find(for: e.path)
                var scStamp = -1.0
                if let sc = sc {
                    var err: Int32 = 0
                    scStamp = Sys.lstatInfo(sc, &err)?.modified ?? -1
                }
                let stamp = Stamp(size: e.size, modified: e.modified, sidecar: scStamp)
                s.lock.lock()
                let known = s.memo[e.path]
                s.lock.unlock()
                if let k = known, k.0 == stamp {
                    batch[e.path] = k.1
                    done += 1
                } else {
                    var (f, readable) = PhotoFactsReader.readNative(path: e.path)
                    // 0.18: the newer set wins whole - the sidecar's if it was changed after the picture.
                    // PhotoLab S6: metadata dates first when both sides have one (the sidecar is small: read once).
                    if let sc = sc, let x = XMPReader.read(path: sc),
                        MetaPlan.current(imageModified: e.modified, sidecarModified: scStamp,
                                         imageMetadataDate: f.metadataDate, sidecarMetadataDate: x.metadataDate) == .sidecar {
                        f.use(sidecar: x)
                    }
                    if readable || ExifTool.command == nil {
                        s.remember(e.path, stamp, f)
                        batch[e.path] = f
                        done += 1
                    } else {
                        forExifTool.append((e, stamp, f))
                    }
                }
                if batch.count >= 40 { flush(force: false) }
            }
            flush(force: false)
            // Files macOS couldn't read: ExifTool, 50 at a time.
            var i = 0
            while i < forExifTool.count {
                if flag.value != token { return }
                let chunk = Array(forExifTool[i..<min(i + 50, forExifTool.count)])
                let got = PhotoFactsReader.readBatchExifTool(chunk.map { $0.0.path })
                for (e, stamp, native) in chunk {
                    var f = got[e.path] ?? native
                    if stamp.sidecar >= 0, MetaPlan.current(imageModified: e.modified, sidecarModified: stamp.sidecar) == .sidecar,
                        let sc = Sidecars.find(for: e.path), let x = XMPReader.read(path: sc) { f.use(sidecar: x) }
                    if got[e.path] != nil { s.remember(e.path, stamp, f) }
                    batch[e.path] = f
                    done += 1
                }
                flush(force: true)
                i += 50
            }
            flush(force: true)
            Log.shared?.info(String(format: "Photo details read for %d pictures (%d via ExifTool) in %.1f s",
                                    total, forExifTool.count, Date().timeIntervalSince(started)))
            DispatchQueue.main.async { if flag.value == token { onDone() } }
        }
    }

    func cancel() { running.value += 1 }

    /// Clear All Disposable Caches: forget remembered ratings/labels (read again when needed).
    func clearMemory() {
        lock.lock()
        memo.removeAll()
        lock.unlock()
    }

    var memoryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return memo.count
    }

    private func remember(_ path: String, _ stamp: Stamp, _ f: PhotoFacts) {
        lock.lock()
        memo[path] = (stamp, f)
        if memo.count > 50_000 { memo.removeAll() }
        lock.unlock()
    }
}
