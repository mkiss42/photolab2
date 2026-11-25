// BrainClient.swift
// Starts the Python brain (Contents/Resources/python-<arch>/bin/python3 running
// Contents/Resources/brain/run_brain.py) and talks to it over a Unix socket.
//
// Phase 0: one request at a time on a private serial queue. Phase 3 replaces this with a
// multiplexed reader (several requests in flight + pushed events).
// The app never waits on the brain: callers get their answer on the main queue, or nil
// after the timeout.

import Foundation
import Darwin

final class BrainClient {
    enum State {
        case notStarted
        case starting
        case connected(python: String)
        case unavailable(reason: String)

        var text: String {
            switch self {
            case .notStarted: return "Brain: not started"
            case .starting: return "Brain: starting..."
            case .connected(let py): return "Brain: connected (Python \(py))"
            case .unavailable(let why): return "Brain: not available - \(why)"
            }
        }
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "photolab.brain")
    private var process: Process?
    private var fd: Int32 = -1
    private var nextID = 1
    private var buffer = LineBuffer()

    /// Main queue.
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .notStarted

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: Locating the runtime

    static var archName: String { return SystemInfo.archName }

    /// PHOTOLAB_PYTHON (CI, development) or the bundled runtime for this architecture.
    static func pythonPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["PHOTOLAB_PYTHON"],
            FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let p = (Bundle.main.resourcePath ?? "") + "/python-\(archName)/bin/python3"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static func brainScript() -> String? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let p = res + "/brain/run_brain.py"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    // MARK: Lifecycle

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.sync {
            if fd >= 0 {
                _ = sendRequestOnQueue(method: "shutdown", params: [:], timeout: 1.0)
                close(fd)
                fd = -1
            }
            if let p = process, p.isRunning { p.terminate() }
            process = nil
        }
    }

    private func setState(_ s: State) {
        state = s
        Log.info(s.text)
        DispatchQueue.main.async { self.onStateChange?(s) }
    }

    private func startOnQueue() {
        setState(.starting)
        guard let py = BrainClient.pythonPath() else {
            setState(.unavailable(reason: "no Python runtime in the app (E-BRAIN-10)"))
            return
        }
        guard let script = BrainClient.brainScript() else {
            setState(.unavailable(reason: "brain files missing from the app (E-BRAIN-11)"))
            return
        }
        let p = Process()
        p.launchPath = py
        // -B: never write .pyc into the app bundle; -s/-E: ignore user site and env.
        p.arguments = ["-B", "-s", "-E", script, "--socket", socketPath,
                       "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
                Log.info("brain: " + line)
            }
        }
        p.terminationHandler = { [weak self] proc in
            Log.warn("brain exited with status \(proc.terminationStatus)")
            self?.queue.async {
                guard let s = self else { return }
                if s.fd >= 0 { close(s.fd); s.fd = -1 }
                s.setState(.unavailable(reason: "brain stopped (status \(proc.terminationStatus))"))
            }
        }
        p.launch()
        process = p
        Log.info("brain launched: \(py) \(script)")

        // Wait up to 15 s for the socket.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let s = BrainClient.connectUnix(socketPath)
            if s >= 0 { fd = s; break }
            if !p.isRunning { break }
            usleep(100_000)
        }
        guard fd >= 0 else {
            setState(.unavailable(reason: "brain did not open its socket (E-BRAIN-12)"))
            return
        }
        guard let reply = sendRequestOnQueue(method: "ping", params: [:], timeout: 5.0),
            case let .response(_, result, code, message) = reply else {
            setState(.unavailable(reason: "no answer to ping (E-BRAIN-13)"))
            return
        }
        if let code = code {
            setState(.unavailable(reason: "\(code) \(message ?? "")"))
            return
        }
        let python = result?["python"] as? String ?? "?"
        setState(.connected(python: python))
    }

    // MARK: Requests

    /// Send a request; `done` runs on the main queue with the reply, or nil on timeout/failure.
    func request(_ method: String, params: [String: Any] = [:], timeout: Double = 2.0,
                 done: @escaping (BrainProtocol.Message?) -> Void) {
        queue.async {
            let r = self.sendRequestOnQueue(method: method, params: params, timeout: timeout)
            DispatchQueue.main.async { done(r) }
        }
    }

    /// Blocking variant for the self-test (never call on the main thread).
    func requestSync(_ method: String, params: [String: Any] = [:], timeout: Double = 2.0) -> BrainProtocol.Message? {
        return queue.sync { sendRequestOnQueue(method: method, params: params, timeout: timeout) }
    }

    private func sendRequestOnQueue(method: String, params: [String: Any], timeout: Double) -> BrainProtocol.Message? {
        guard fd >= 0 else { return nil }
        let id = nextID
        nextID += 1
        guard let data = BrainProtocol.encodeRequest(id: id, method: method, params: params) else { return nil }
        let sent = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var off = 0
            while off < raw.count {
                let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if !sent { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                Log.warn("brain request \(method) timed out after \(timeout) s")
                return nil
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(remaining * 1000))
            if pr < 0 && errno == EINTR { continue }
            if pr <= 0 { continue }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            for line in buffer.feed(Data(chunk[0..<n])) {
                let m = BrainProtocol.decode(line)
                if case let .response(rid, _, _, _) = m, rid == id { return m }
                // Events and stale replies are ignored in Phase 0.
            }
        }
    }

    // MARK: Socket

    static func connectUnix(_ path: String) -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if bytes.count >= capacity { close(s); return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { ptr -> Int32 in
            return ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        if r != 0 { close(s); return -1 }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return s
    }
}
