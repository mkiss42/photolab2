// FTPSession.swift  (PhotoLab, after PhotoLab 1's FtpSession)
// One FTP control connection per server, kept open: logging in happens once, and every listing,
// size check, rename, new folder or delete reuses it (Find started a new curl - a new connection and
// login - for every command). Transfers (upload / download) still use curl, on their own connections,
// so a long copy never holds up browsing.
//   - Plain FTP, passive mode (EPSV, then PASV), binary.
//   - Paths are relative to the folder the account logs in to (as curl's ftp://host/a/b): the session
//     asks PWD once and sends full paths.
//   - A dropped connection (server idle timeout, 421, a broken socket) is logged in again
//     automatically, at most 3 times for one command (PhotoLab 1's reconnect budget).
//   - One command at a time (a lock); every line goes to `traffic` (the console). PASS is never shown.
// POSIX sockets only (no Network.framework: macOS 10.13).

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

final class FTPSession {
    let server: FTPServer
    var traffic: ((String) -> Void)?
    var timeout: Double = 30
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var buffer = [UInt8]()
    private var home = "/"
    static let reconnectBudget = 3

    init(server: FTPServer) { self.server = server }
    deinit { close() }

    // MARK: Socket basics

    private func say(_ s: String) { traffic?(s) }

    private static func hostPort(_ h: String) -> (String, Int) {
        // "host:2121" or "[::1]:2121"
        if h.hasPrefix("["), let close = h.range(of: "]") {
            let host = String(h[h.index(after: h.startIndex)..<close.lowerBound])
            let rest = h[close.upperBound...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { return (host, p) }
            return (host, 21)
        }
        let parts = h.split(separator: ":")
        if parts.count == 2, let p = Int(parts[1]) { return (String(parts[0]), p) }
        return (h, 21)
    }

    /// A connected TCP socket, or -1 (with a reason).
    static func connectTCP(_ host: String, _ port: Int, timeout: Double) -> (fd: Int32, error: String?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { return (-1, "the server's name could not be found") }
        defer { freeaddrinfo(res) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        var last = "the server can't be reached"
        while let a = p {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                #if !os(Linux)
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                let flags = fcntl(s, F_GETFL, 0)
                _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
                let c = Darwin_connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen)
                var ok = c == 0
                if !ok && errno == EINPROGRESS {
                    var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, Int32(timeout * 1000)) > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                        ok = err == 0
                        if !ok { last = "the server can't be reached (" + String(cString: strerror(err)) + ")" }
                    } else {
                        last = "the server did not answer"
                    }
                }
                if ok {
                    _ = fcntl(s, F_SETFL, flags & ~O_NONBLOCK)
                    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    return (s, nil)
                }
                _ = Darwin_close(s)
            }
            p = a.pointee.ai_next
        }
        return (-1, last)
    }

    private func close() {
        if fd >= 0 { _ = Darwin_close(fd); fd = -1 }
        buffer.removeAll()
    }

    private func sendLine(_ line: String) -> Bool {
        guard fd >= 0 else { return false }
        say("> " + (line.uppercased().hasPrefix("PASS") ? "PASS ****" : line))
        let bytes = Array((line + "\r\n").utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin_send(fd, $0.baseAddress! + off, bytes.count - off) }
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    private func readLine() -> String? {
        while true {
            if let i = buffer.index(of: 10) {
                var line = Array(buffer[0..<i])
                buffer.removeFirst(i + 1)
                if line.last == 13 { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { Darwin_recv(fd, $0.baseAddress, 4096) }
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) } else if n < 0 && errno == EINTR { continue } else { return nil }
        }
    }

    /// One reply (multi-line replies "123-..." up to "123 ..."). nil: the connection is gone.
    private func reply() -> (code: Int, text: String)? {
        guard let first = readLine() else { return nil }
        say("< " + first)
        let code = Int(first.prefix(3)) ?? 0
        var text = first
        if first.count > 3 && Array(first)[3] == "-" {
            let end = String(first.prefix(3)) + " "
            while let l = readLine() {
                say("< " + l)
                text += "\n" + l
                if l.hasPrefix(end) { break }
            }
        }
        return (code, text)
    }

    private func command(_ line: String) -> (code: Int, text: String)? {
        guard sendLine(line) else { return nil }
        return reply()
    }

    // MARK: Login

    private func login() -> FTPFailure? {
        close()
        let (h, p) = FTPSession.hostPort(server.host)
        say("* Connecting to \(h) port \(p)")
        let c = FTPSession.connectTCP(h, p, timeout: timeout)
        guard c.fd >= 0 else { return FTPFailure(code: "FTP-07", text: "The server can't be reached (\(c.error ?? "")).") }
        fd = c.fd
        guard let hello = reply(), hello.code == 220 else { close(); return FTPFailure(code: "FTP-07", text: "The server did not greet as an FTP server.") }
        let user = server.user.isEmpty ? "anonymous" : server.user
        guard var r = command("USER " + user) else { close(); return lost() }
        if r.code == 331 {
            guard let r2 = command("PASS " + (server.password ?? (server.user.isEmpty ? "photolab@" : ""))) else { close(); return lost() }
            r = r2
        }
        guard r.code == 230 || r.code == 202 else {
            close()
            return FTPFailure(code: "FTP-67", text: "The server refused the account name or password (\(r.text)).")
        }
        _ = command("TYPE I")
        if let pwd = command("PWD"), pwd.code == 257, let a = pwd.text.range(of: "\""), let b = pwd.text.range(of: "\"", range: a.upperBound..<pwd.text.endIndex) {
            home = String(pwd.text[a.upperBound..<b.lowerBound])
        } else {
            home = "/"
        }
        say("* Logged in (home folder \(home)); the connection stays open")
        return nil
    }

    private func lost() -> FTPFailure { return FTPFailure(code: "FTP-56", text: "The connection broke off.") }

    /// The full server path for a path below the login folder.
    func absolute(_ path: [String]) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return base + "/" + path.joined(separator: "/")
    }

    /// Run `body` with a logged-in connection; if the connection turns out to be gone (nil from
    /// `body`), log in again and retry - at most `reconnectBudget` times.
    private func withConnection<T>(_ body: () -> T?) -> FTPResult<T> {
        lock.lock(); defer { lock.unlock() }
        var tries = 0
        while true {
            if fd < 0, let f = login() { return .failed(f) }
            if let v = body() { return .ok(v) }
            tries += 1
            say("* The connection was lost; logging in again (\(tries) of \(FTPSession.reconnectBudget))")
            close()
            if tries >= FTPSession.reconnectBudget { return .failed(lost()) }
        }
    }

    // MARK: Passive data connection

    /// Open a data connection (EPSV, else PASV). nil: the control connection is gone; fd -1: refused.
    private func openData() -> (fd: Int32, error: String)? {
        let (h, _) = FTPSession.hostPort(server.host)
        if let r = command("EPSV") {
            if r.code == 229, let open = r.text.range(of: "(|||"), let close = r.text.range(of: "|)"),
                let port = Int(r.text[open.upperBound..<close.lowerBound]) {
                let c = FTPSession.connectTCP(h, port, timeout: timeout)
                return (c.fd, c.error ?? "")
            }
        } else { return nil }
        guard let r = command("PASV") else { return nil }
        guard r.code == 227, let o = r.text.range(of: "("), let c = r.text.range(of: ")", range: o.upperBound..<r.text.endIndex) else {
            return (-1, "the server refused a data connection (\(r.text))")
        }
        let nums = r.text[o.upperBound..<c.lowerBound].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 6 else { return (-1, "the server's PASV answer could not be read") }
        // The address in the answer is often a private one behind NAT: the server's own name is used.
        let conn = FTPSession.connectTCP(h, nums[4] * 256 + nums[5], timeout: timeout)
        return (conn.fd, conn.error ?? "")
    }

    private func readAll(_ dfd: Int32) -> Data {
        var d = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin_recv(dfd, $0.baseAddress, 65536) }
            if n > 0 { d.append(contentsOf: chunk[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
        }
        _ = Darwin_close(dfd)
        return d
    }

    // MARK: Operations

    enum Outcome { case ok(String), refused(Int, String) }

    /// A listing (MLSD, else LIST).
    func list(_ dir: [String]) -> FTPResult<[FTPEntry]> {
        let path = absolute(dir)
        let r: FTPResult<FTPResult<[FTPEntry]>> = withConnection {
            for verb in ["MLSD", "LIST"] {
                guard let data = openData() else { return nil }
                if data.fd < 0 { return .failed(FTPFailure(code: "FTP-DATA", text: "No data connection: \(data.error).")) }
                guard let start = command(verb + " " + path) else { _ = Darwin_close(data.fd); return nil }
                if start.code == 500 || start.code == 502 || (start.code == 550 && verb == "MLSD" && start.text.lowercased().contains("command")) {
                    _ = Darwin_close(data.fd)
                    continue   // the server doesn't know MLSD
                }
                guard start.code == 150 || start.code == 125 else {
                    _ = Darwin_close(data.fd)
                    return .failed(FTPFailure(code: "FTP-19", text: "The server refused to list this folder (\(start.text))."))
                }
                let bytes = readAll(data.fd)
                guard let done = reply() else { return nil }
                guard done.code == 226 || done.code == 250 else {
                    return .failed(FTPFailure(code: "FTP-56", text: "The listing broke off (\(done.text))."))
                }
                let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
                if verb == "MLSD", let e = FTPList.parseMLSD(text) {
                    say("* \(e.count) items")
                    return .ok(e)
                }
                if verb == "LIST" {
                    let e = FTPList.parseLIST(text)
                    say("* \(e.count) items")
                    return .ok(e)
                }
            }
            return .failed(FTPFailure(code: "FTP-19", text: "The server could not list this folder."))
        }
        switch r {
        case .ok(let inner): return inner
        case .failed(let f): return .failed(f)
        }
    }

    /// SIZE of a file (binary), nil if the server won't say.
    func size(_ file: [String]) -> Int64? {
        let path = absolute(file)
        let r: FTPResult<Int64?> = withConnection {
            guard let x = command("SIZE " + path) else { return nil }
            if x.code == 213 { return .some(Int64(x.text.dropFirst(4).trimmingCharacters(in: .whitespaces))) }
            return .some(nil)
        }
        return r.value ?? nil
    }

    /// One command on a path (DELE, RMD, MKD) - its reply code and text.
    func simple(_ verb: String, _ path: [String]) -> FTPResult<Outcome> {
        let p = absolute(path)
        return withConnection {
            guard let x = command(verb + " " + p) else { return nil }
            return (200..<300).contains(x.code) ? .ok(x.text) : .refused(x.code, x.text)
        }
    }

    /// RNFR + RNTO.
    func renameOnServer(_ from: [String], _ to: [String]) -> FTPResult<Outcome> {
        let a = absolute(from), b = absolute(to)
        return withConnection {
            guard let x = command("RNFR " + a) else { return nil }
            guard x.code == 350 else { return .refused(x.code, x.text) }
            guard let y = command("RNTO " + b) else { return nil }
            return (200..<300).contains(y.code) ? .ok(y.text) : .refused(y.code, y.text)
        }
    }

    /// Self-test only: the connection breaks without a goodbye (as a server timeout does).
    func dropConnectionForTest() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { _ = shutdown(fd, Int32(SHUT_RDWR)) }
    }

    /// Say goodbye (when the pane closes).
    func quit() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { _ = command("QUIT"); close() }
    }
}

// Names that clash with methods above.
@inline(__always) private func Darwin_connect(_ s: Int32, _ a: UnsafePointer<sockaddr>!, _ l: socklen_t) -> Int32 { return connect(s, a, l) }
@inline(__always) private func Darwin_close(_ s: Int32) -> Int32 { return close(s) }
@inline(__always) private func Darwin_send(_ s: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
    #if os(Linux)
    return send(s, p, n, Int32(MSG_NOSIGNAL))
    #else
    return send(s, p, n, 0)
    #endif
}
@inline(__always) private func Darwin_recv(_ s: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { return recv(s, p, n, 0) }
