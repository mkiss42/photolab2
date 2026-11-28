// ExifToolServer.swift
// 0.18.6: ExifTool kept running ("-stay_open True -@ -") instead of starting a new ExifTool (Perl, ~0.3-1 s
// on the iMac) for every command. Each server is one ExifTool process that reads its commands from
// a pipe: the arguments one per line, then "-execute<N>"; it answers on stdout up to "{ready<N>}" and,
// because of "-echo4 {done<N>}", marks the end of that command's error output too. Up to 4 servers run
// side by side (one per core); they start when first needed and stop after 5 minutes of no work.
// If a server can't be started, hangs past its time limit or dies, it is stopped and the command
// goes to a one-time ExifTool as before - nothing is ever left half-sent.

import Foundation

final class ExifToolServer {
    private let lock = NSLock()               // one command at a time per server
    private let cond = NSCondition()          // guards the buffers below
    private var proc: Process?
    private var input: FileHandle?
    private var out = Data()
    private var err = Data()
    private var alive = false
    private var counter = 0
    private var gen = 0                       // which process the reader threads belong to
    private var idleTimer: DispatchWorkItem?
    private let name: String

    init(name: String) { self.name = name }

    func tryLock() -> Bool { return lock.try() }
    func lockWait() { lock.lock() }
    func unlock() { lock.unlock() }

    /// The argument as one argfile line. Line breaks, tabs, backslashes and spaces at either end are
    /// written as a C string ("#[CSTR]"), so a caption with several lines arrives exactly as typed.
    static func argLine(_ a: String) -> String {
        let needs = a.contains("\n") || a.contains("\r") || a.contains("\t") || a.hasPrefix(" ") || a.hasSuffix(" ") || a.hasPrefix("#")
        if !needs { return a }
        var s = ""
        for ch in a.unicodeScalars {
            switch ch {
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            case "\"": s += "\\\""
            default: s.unicodeScalars.append(ch)
            }
        }
        return "#[CSTR]" + s
    }

    private func start() -> Bool {
        guard let (program, lead) = ExifTool.command else { return false }
        let p = Process()
        p.launchPath = program
        p.arguments = lead + ["-config", "", "-stay_open", "True", "-@", "-"]
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP
        p.standardOutput = outP
        p.standardError = errP
        let termGen = gen + 1
        p.terminationHandler = { [weak self] _ in
            guard let s = self else { return }
            s.cond.lock(); if s.gen == termGen { s.alive = false }; s.cond.broadcast(); s.cond.unlock()
        }
        #if os(Linux)
        p.launch()
        #else
        if #available(OSX 10.13, *) {
            do { try p.run() } catch { return false }
        } else {
            p.launch()
        }
        #endif
        // Plain read() loops (FileHandle reads can raise exceptions Swift can't catch).
        let outFD = outP.fileHandleForReading.fileDescriptor, errFD = errP.fileHandleForReading.fileDescriptor
        cond.lock(); gen += 1; let myGen = gen; cond.unlock()
        Thread.detachNewThread { [weak self] in ExifToolServer.drain(outFD) { d in
            guard let s = self else { return false }
            s.cond.lock()
            if s.gen != myGen { s.cond.unlock(); return false }   // a stopped ExifTool's last words
            if d.isEmpty { s.alive = false } else { s.out.append(d) }
            s.cond.broadcast(); s.cond.unlock()
            return true
        } }
        Thread.detachNewThread { [weak self] in ExifToolServer.drain(errFD) { d in
            guard let s = self else { return false }
            s.cond.lock()
            if s.gen != myGen { s.cond.unlock(); return false }
            if !d.isEmpty { s.err.append(d) }
            s.cond.broadcast(); s.cond.unlock()
            return true
        } }
        proc = p
        input = inP.fileHandleForWriting
        cond.lock(); alive = true; out = Data(); err = Data(); cond.unlock()
        Log.shared?.info("ExifTool \(name): started (stay-open, pid \(p.processIdentifier))")
        return true
    }

    /// Reads `fd` until its end; `chunk` gets each piece and finally an empty one (the end).
    private static func drain(_ fd: Int32, _ chunk: (Data) -> Bool) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 65536) }
            if n > 0 {
                if !chunk(Data(buf[0..<n])) { return }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                _ = chunk(Data())
                return
            }
        }
    }

    /// Stop this server (e.g. after a hang). The caller holds the lock.
    private func stopLocked(_ why: String) {
        if let p = proc {
            if p.isRunning {
                // Ask nicely, then make sure.
                if let i = input { writeSafely(i, "-stay_open\nFalse\n") }
                let deadline = Date().addingTimeInterval(1.5)
                while p.isRunning && Date() < deadline { usleep(50_000) }
                if p.isRunning { p.terminate() }
            }
            Log.shared?.info("ExifTool \(name): stopped (\(why))")
        }
        proc = nil
        input = nil
        cond.lock(); alive = false; cond.unlock()
    }

    /// Writing into a pipe whose reader is gone must not kill Find (SIGPIPE is ignored app-wide).
    private func writeSafely(_ h: FileHandle, _ s: String) {
        let bytes = Array(s.utf8)
        let fd = h.fileDescriptor
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n <= 0 { return }
            off += n
        }
    }

    /// Runs one command; the caller holds the lock. nil = the server can't be used (caller falls back).
    func executeLocked(_ args: [String], timeout: Double) -> (data: Data?, error: String?)? {
        idleTimer?.cancel()
        if proc == nil || !(proc?.isRunning ?? false) || !alive {
            stopLocked("restart")
            if !start() { return nil }
        }
        guard let inH = input else { return nil }
        counter += 1
        let n = counter
        let ready = Array("{ready\(n)}".utf8)
        let done = Array("{done\(n)}".utf8)
        cond.lock(); out = Data(); err = Data(); cond.unlock()
        var text = args.map { ExifToolServer.argLine($0) }.joined(separator: "\n")
        text += "\n-echo4\n{done\(n)}\n-execute\(n)\n"
        writeSafely(inH, text)
        let deadline = Date().addingTimeInterval(timeout)
        var outData = Data(), errData = Data()
        var finished = false
        cond.lock()
        while true {
            if let r = out.range(of: Data(ready)), err.range(of: Data(done)) != nil {
                outData = out.subdata(in: 0..<r.lowerBound)
                let e = err.range(of: Data(done))!
                errData = err.subdata(in: 0..<e.lowerBound)
                finished = true
                break
            }
            if !alive || Date() >= deadline || !(proc?.isRunning ?? false) { break }
            _ = cond.wait(until: min(deadline, Date().addingTimeInterval(1)))
        }
        cond.unlock()
        if !finished {
            let why = alive ? "no answer within \(Int(timeout)) s" : "ExifTool ended"
            stopLocked(why)
            return (nil, "ExifTool: \(why)")
        }
        scheduleIdleStop()
        let e = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Warnings are normal; only "Error" lines count as an error (the result is checked anyway).
        let errors = e.split(separator: "\n").filter { $0.contains("Error") }.joined(separator: " / ")
        return (outData, errors.isEmpty ? nil : errors)
    }

    private func scheduleIdleStop() {
        idleTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let s = self, s.lock.try() else { return }   // busy: it will be rescheduled after the command
            if ExifToolPool.shared.isHeld {
                s.lock.unlock()                                  // kept ready (Settings > ExifTool Behavior)
                return
            }
            s.stopLocked("idle \(Int(ExifToolPool.idleSeconds / 60)) min")
            s.lock.unlock()
        }
        idleTimer = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ExifToolPool.idleSeconds, execute: w)
    }

    /// Started and ready (Settings > ExifTool Behavior). Waits while a command runs.
    func ensureStarted() {
        lock.lock()
        defer { lock.unlock() }
        if proc == nil || !(proc?.isRunning ?? false) || !alive {
            stopLocked("restart")
            if start() {
                // A first small command, so ExifTool has loaded what it needs before real work arrives.
                _ = executeLocked(["-ver"], timeout: 30)
            }
        }
    }

    /// Stop now if not busy (the last Photography pane closed, etc.).
    func stopIfIdle(_ why: String) {
        guard lock.try() else { return }
        idleTimer?.cancel()
        if proc != nil { stopLocked(why) }
        lock.unlock()
    }

    func shutdown() {
        lock.lock()
        idleTimer?.cancel()
        stopLocked("PhotoLab quits")
        lock.unlock()
    }
}

/// The ExifTools Find keeps running (Settings > ExifTool Behavior).
final class ExifToolPool {
    /// When they run (set at start from Settings, before first use).
    enum Mode: Int {
        case always = 0          // started with Find, kept until Find quits
        case photoPanes = 1      // started when a pane enters Photography Mode, kept while one is open
        case onDemand = 2        // started when needed, stopped after the idle time
    }
    static var mode: Mode = .photoPanes
    /// How many run side by side (1-4; set before first use - a change applies at the next start of Find).
    static var count = 4
    /// Idle time before stopping, when nothing keeps them (seconds).
    static var idleSeconds: Double = 300
    static let shared = ExifToolPool()
    /// Off = one ExifTool per command (as before 0.18.6), e.g. to compare.
    static var enabled = true

    private var holders = Set<String>()
    private let holdLock = NSLock()
    var isHeld: Bool { holdLock.lock(); defer { holdLock.unlock() }; return !holders.isEmpty }

    /// Something wants them ready (Find itself, a Photography pane): started now in the background.
    func hold(_ who: String) {
        holdLock.lock()
        let first = holders.isEmpty
        holders.insert(who)
        holdLock.unlock()
        if first { prime() }
    }

    /// No longer needed by `who`; when nothing holds them any more they stop (if idle) right away.
    func release(_ who: String) {
        holdLock.lock()
        let had = holders.remove(who) != nil
        let empty = holders.isEmpty
        holdLock.unlock()
        if had && empty {
            DispatchQueue.global(qos: .utility).async { for s in self.servers { s.stopIfIdle("not needed any more") } }
        }
    }

    /// Start every server (in the background) so the first metadata job doesn't wait.
    func prime() {
        guard ExifToolPool.enabled else { return }
        for s in servers { DispatchQueue.global(qos: .utility).async { s.ensureStarted() } }
    }
    let servers: [ExifToolServer]
    /// Commands answered by a kept-running ExifTool (self-test, logs).
    private(set) var served = 0
    private var next = 0
    private let pick = NSLock()

    private init() {
        let n = max(1, min(ExifToolPool.count, 4, ProcessInfo.processInfo.activeProcessorCount))
        servers = (0..<n).map { ExifToolServer(name: "#\($0 + 1)") }
    }

    /// Runs a command on a free server (or waits for one); nil = use a one-time ExifTool instead.
    func run(_ args: [String], timeout: Double) -> (data: Data?, error: String?)? {
        guard ExifToolPool.enabled else { return nil }
        var chosen: ExifToolServer?
        for s in servers where s.tryLock() { chosen = s; break }
        if chosen == nil {
            pick.lock(); let s = servers[next % servers.count]; next += 1; pick.unlock()
            s.lockWait()
            chosen = s
        }
        let s = chosen!
        defer { s.unlock() }
        let r = s.executeLocked(args, timeout: timeout)
        if r?.data != nil { pick.lock(); served += 1; pick.unlock() }
        return r
    }

    func shutdown() { for s in servers { s.shutdown() } }
}
