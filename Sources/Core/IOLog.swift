// IOLog.swift
// 0.18: two extra logs in Logs/Find, to see how hard Find works the network and the disks:
//   network-io-<date>.log  Find's own traffic with network volumes (shares) and FTP servers
//   disk-io-<date>.log     Find's own reading and writing on this Mac's disks
// Plain ASCII, numbered lines (N00001 / D00001), a line per operation (copy, FTP command, folder read
// on a share, metadata write), a MINUTE line for each minute with activity (totals, including the many
// small reads for thumbnails and previews that get no line of their own), and a SESSION TOTAL plus
// total-lines when Find quits. Failed operations carry their error code (ERR=...).
// The 10 most recent of each are kept.

import Foundation

final class IOLog {
    static var network: IOLog?
    static var disk: IOLog?

    /// Is this path on a network volume? (App: VolumeRegistry.treatAsNetwork.)
    static var isNetworkPath: (String) -> Bool = { VolumeRegistry.volumeRoot($0) != "/" }
    /// The whole Find process's disk bytes so far (read, written), when the system tells (macOS).
    static var processDiskBytes: (() -> (read: UInt64, written: UInt64)?)?
    /// PhotoLab: " reads/file=2.6 ..." for the MINUTE lines (shared readers, network or local), or "".
    static var readEconomy: ((Bool) -> String)?

    let path: String
    private let letter: String
    private let files: AppFiles
    private let queue = DispatchQueue(label: "find.iolog")
    private var counter = 0
    private var timer: DispatchSourceTimer?
    private var closed = false

    private struct Tally {
        var ops = 0
        var read: Int64 = 0
        var written: Int64 = 0
        var errors = 0
        var smallFiles = 0
        var smallBytes: Int64 = 0
        var seconds = 0.0
        var isEmpty: Bool { return ops == 0 && smallFiles == 0 && read == 0 && written == 0 }
    }
    private var minute = Tally()
    private var minuteStart = Date()
    private var session = Tally()
    private var lastProcess: (read: UInt64, written: UInt64)?
    private var processStart: (read: UInt64, written: UInt64)?

    init(files: AppFiles, network: Bool, appVersion: String, timerSeconds: Double = 60) {
        self.files = files
        letter = network ? "N" : "D"
        let prefix = network ? "network-io-" : "disk-io-"
        path = Paths.join(files.logsDir, prefix + Ascii.fileStamp() + ".log")
        let logs = files.list(files.logsDir).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".log") }.sorted()
        if logs.count > 9 {
            for old in logs.prefix(logs.count - 9) { files.removeOwned(Paths.join(files.logsDir, old)) }
        }
        line("START Find \(appVersion) " + (network
            ? "network I/O log: Find's own traffic with shared volumes and FTP servers (in = from the network, out = to it)"
            : "disk I/O log: Find's own reading and writing on this Mac's disks (read / written)"))
        line(network
            ? "INFO one line per copy, FTP command, folder read on a share and metadata write; MINUTE = totals of that minute; small-reads = thumbnails, previews, details, checksums (no line each)"
            : "INFO one line per copy and metadata write; MINUTE = totals of that minute; small-reads = thumbnails, previews, details, checksums (no line each), and 'process' = all disk I/O of Find counted by macOS")
        if !network, let p = IOLog.processDiskBytes?() { processStart = p; lastProcess = p }
        if timerSeconds > 0 {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + timerSeconds, repeating: timerSeconds)
            t.setEventHandler { [weak self] in self?.minuteLine() }
            t.resume()
            timer = t
        }
    }

    // MARK: Recording

    /// One operation: its own line, and counted in the minute and the session.
    /// `read` = bytes read / received, `written` = bytes written / sent; -1 = not known.
    func record(_ what: String, read: Int64 = 0, written: Int64 = 0, seconds: Double, detail: String, error: String? = nil) {
        let isNet = letter == "N"
        queue.async {
            if self.closed { return }
            for t in [0, 1] {
                var x = t == 0 ? self.minute : self.session
                x.ops += 1
                x.read += max(0, read)
                x.written += max(0, written)
                x.seconds += seconds
                if error != nil { x.errors += 1 }
                if t == 0 { self.minute = x } else { self.session = x }
            }
            var parts = [what]
            let r = isNet ? "in" : "read", w = isNet ? "out" : "written"
            if read != 0 { parts.append("\(r)=" + IOLog.bytes(read)) }
            if written != 0 { parts.append("\(w)=" + IOLog.bytes(written)) }
            parts.append(String(format: "time=%.2fs", seconds))
            let moved = max(0, read) + max(0, written)
            if moved > 0 && seconds >= 0.05 { parts.append("rate=" + IOLog.bytes(Int64(Double(moved) / seconds)) + "/s") }
            if let e = error { parts.append("ERR=" + e) }
            parts.append(detail)
            self.lineNow(parts.joined(separator: " "))
        }
    }

    /// Small reads (a thumbnail, a preview, a metadata header): counted, no line of their own.
    /// `bytes` -1 = the system read the file itself (size not known).
    func countSmallRead(bytes: Int64, newFile: Bool = true) {
        queue.async {
            if self.closed { return }
            if newFile {
                self.minute.smallFiles += 1
                self.session.smallFiles += 1
            }
            if bytes > 0 {
                self.minute.smallBytes += bytes
                self.session.smallBytes += bytes
            }
        }
    }

    // MARK: Convenience (classify by volume)

    /// A copy from `src` to `dst`: in the network log when either side is a share, in the disk log
    /// when either side is on this Mac.
    static func copy(_ what: String, src: String, dst: String, bytes: Int64, seconds: Double, error: String? = nil) {
        let sNet = isNetworkPath(src), dNet = isNetworkPath(dst)
        let detail = "\(src) -> \(dst)"
        if sNet || dNet {
            network?.record(what, read: sNet ? bytes : 0, written: dNet ? bytes : 0, seconds: seconds, detail: detail, error: error)
        }
        if !sNet || !dNet {
            disk?.record(what, read: sNet ? 0 : bytes, written: dNet ? 0 : bytes, seconds: seconds, detail: detail, error: error)
        }
    }

    /// A small read of a file (thumbnail, preview, header), counted in the log of its volume.
    static func smallRead(_ path: String, bytes: Int64) {
        (isNetworkPath(path) ? network : disk)?.countSmallRead(bytes: bytes)
    }

    /// More bytes of a file already counted by smallRead (PhotoLab's shared readers: one file, many reads).
    static func smallReadBytes(_ path: String, bytes: Int64) {
        (isNetworkPath(path) ? network : disk)?.countSmallRead(bytes: bytes, newFile: false)
    }

    /// An operation on one file (read and written in place), in the log of its volume.
    static func onFile(_ what: String, path: String, read: Int64, written: Int64, seconds: Double, error: String? = nil) {
        (isNetworkPath(path) ? network : disk)?.record(what, read: read, written: written, seconds: seconds, detail: path, error: error)
    }

    // MARK: Lines

    private func line(_ s: String) {
        queue.async { self.lineNow(s) }
    }

    /// On the queue.
    private func lineNow(_ s: String) {
        counter += 1
        let text = letter + String(format: "%05d ", counter) + Ascii.timestamp(withDate: false) + " " + Ascii.clean(s) + "\n"
        _ = files.appendText(text, to: path)
    }

    /// On the queue: the minute's totals (only when something happened).
    private func minuteLine() {
        if closed { return }
        let m = minute
        let start = minuteStart
        minute = Tally()
        minuteStart = Date()
        var procText = ""
        if letter == "D", let now = IOLog.processDiskBytes?() {
            if let last = lastProcess, now.read >= last.read, now.written >= last.written {
                let dr = Int64(now.read - last.read), dw = Int64(now.written - last.written)
                if dr > 0 || dw > 0 { procText = " process read=" + IOLog.bytes(dr) + " process written=" + IOLog.bytes(dw) }
            }
            lastProcess = now
        }
        if m.isEmpty && procText.isEmpty { return }
        let isNet = letter == "N"
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        var s = "MINUTE from \(f.string(from: start)) ops=\(m.ops) \(isNet ? "in" : "read")=\(IOLog.bytes(m.read)) \(isNet ? "out" : "written")=\(IOLog.bytes(m.written))"
        s += " small-reads=\(m.smallFiles) files"
        if m.smallBytes > 0 { s += " (" + IOLog.bytes(m.smallBytes) + " read)" }
        if m.smallFiles > 0 { s += IOLog.readEconomy?(isNet) ?? "" }
        s += " errors=\(m.errors)" + procText
        lineNow(s)
    }

    /// When Find quits: the last minute, the session total, and the total-lines line.
    func close() {
        queue.sync {
            if closed { return }
            timer?.cancel()
            timer = nil
            minuteLine()
            let isNet = letter == "N"
            let s = session
            var t = "SESSION TOTAL ops=\(s.ops) \(isNet ? "in" : "read")=\(IOLog.bytes(s.read)) \(isNet ? "out" : "written")=\(IOLog.bytes(s.written))"
            t += " small-reads=\(s.smallFiles) files"
            if s.smallBytes > 0 { t += " (" + IOLog.bytes(s.smallBytes) + " read)" }
            t += " errors=\(s.errors)"
            if letter == "D", let a = processStart, let b = IOLog.processDiskBytes?(), b.read >= a.read, b.written >= a.written {
                t += " process read=" + IOLog.bytes(Int64(b.read - a.read)) + " process written=" + IOLog.bytes(Int64(b.written - a.written))
            }
            lineNow(t)
            counter += 1
            _ = files.appendText(letter + String(format: "%05d ", counter) + "total-lines=\(counter)\n", to: path)
            closed = true
        }
    }

    /// For tests: wait until queued lines are written; and force a minute line now.
    func flush() { queue.sync {} }
    func minuteNow() { queue.sync { minuteLine() } }

    static func bytes(_ b: Int64) -> String {
        if b < 0 { return "?" }
        if b < 1024 { return "\(b) B" }
        if b < 1_048_576 { return String(format: "%.1f KB", Double(b) / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        return String(format: "%.2f GB", Double(b) / 1_073_741_824)
    }
}
