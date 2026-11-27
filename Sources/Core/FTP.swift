// FTP.swift
// 0.15: Find's own FTP connection (plain FTP, no encryption), through the curl program that is part of
// macOS (/usr/bin/curl) - nothing to install. What it does, and only this:
//   - list folders (machine-readable MLSD when the server has it, else the classic LIST in Unix or
//     Windows style);
//   - upload files (and folders, whose subfolders are created as needed) - never over an existing name:
//     the folder is listed first and a name clash asks Keep Both or Skip; after each upload the size on
//     the server is checked against the file on this Mac;
//   - delete FILES on the server (DELE), after asking - FTP has no Trash, so this is permanent. Folders
//     are never deleted or renamed (no RMD, no RNFR/RNTO is ever sent);
//   - download files into Find's own temporary folder (the app then copies them into place with the
//     usual checked copy, never overwriting).
// The server's permissions decide the rest: what it refuses is reported, nothing is retried around it.
// Passwords go to curl through its standard input (never on the command line, where other programs
// could see them). Pure Foundation: tested on Linux against a real FTP server.

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

struct FTPEntry: Equatable, Codable {
    var name: String
    var isDir: Bool
    var isLink: Bool = false
    var size: Int64? = nil
    var modified: Date? = nil

    init(name: String, isDir: Bool, isLink: Bool = false, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.isDir = isDir
        self.isLink = isLink
        self.size = size
        self.modified = modified
    }

    static func == (a: FTPEntry, b: FTPEntry) -> Bool {
        return a.name == b.name && a.isDir == b.isDir && a.isLink == b.isLink && a.size == b.size && a.modified == b.modified
    }
}

struct FTPFailure: Error, Equatable {
    /// FTP-xx codes, for the log and reports.
    let code: String
    let text: String

    static func == (a: FTPFailure, b: FTPFailure) -> Bool { return a.code == b.code && a.text == b.text }
}

enum FTPResult<T> {
    case ok(T)
    case failed(FTPFailure)

    var value: T? { if case .ok(let v) = self { return v }; return nil }
    var failure: FTPFailure? { if case .failed(let f) = self { return f }; return nil }
}

/// A server, as saved in the sidebar: host (with :port if not 21), account and password.
struct FTPServer {
    var host: String
    var user: String
    var password: String?
}

// MARK: - Listings

enum FTPList {
    private static let utc: TimeZone = TimeZone(identifier: "UTC")!

    /// MLSD lines: "type=file;size=123;modify=20261121193000; name". nil when the text isn't MLSD.
    static func parseMLSD(_ text: String) -> [FTPEntry]? {
        var out: [FTPEntry] = []
        var sawFacts = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { continue }
            guard let sp = line.range(of: "; ") ?? (line.hasPrefix(" ") ? line.range(of: " ") : nil) else { return nil }
            let facts = line[line.startIndex..<sp.lowerBound]
            let name = String(line[sp.upperBound...])
            var f: [String: String] = [:]
            for part in facts.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { f[kv[0].lowercased()] = kv[1] }
            }
            guard let type = f["type"]?.lowercased() else { return nil }
            sawFacts = true
            if type == "cdir" || type == "pdir" || name == "." || name == ".." || name.isEmpty { continue }
            var e = FTPEntry(name: name, isDir: type == "dir")
            e.isLink = type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink")
            if let s = f["size"], let n = Int64(s) { e.size = n }
            if let m = f["modify"] { e.modified = mlsdDate(m) }
            out.append(e)
        }
        return sawFacts || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : nil
    }

    static func mlsdDate(_ s: String) -> Date? {
        let digits = String(s.prefix(14))
        guard digits.count == 14 else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = utc
        df.dateFormat = "yyyyMMddHHmmss"
        return df.date(from: digits)
    }

    /// Classic LIST: Unix style ("drwxr-xr-x 2 user group 4096 Nov 21 19:30 name") or Windows/IIS
    /// style ("11-21-26  07:30PM       <DIR>          name"). Lines it can't read are skipped.
    static func parseLIST(_ text: String, now: Date = Date()) -> [FTPEntry] {
        var out: [FTPEntry] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty || line.hasPrefix("total ") { continue }
            if let e = parseUnix(line, now: now) ?? parseDOS(line) {
                if e.name == "." || e.name == ".." { continue }
                out.append(e)
            }
        }
        return out
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// Split off `count` whitespace-separated fields; the rest of the line (spaces kept) is returned last.
    private static func fields(_ line: String, _ count: Int) -> ([String], String)? {
        var parts: [String] = []
        var i = line.startIndex
        while parts.count < count {
            while i < line.endIndex && line[i] == " " { i = line.index(after: i) }
            guard i < line.endIndex else { return nil }
            var j = i
            while j < line.endIndex && line[j] != " " { j = line.index(after: j) }
            parts.append(String(line[i..<j]))
            i = j
        }
        // exactly one separating space before the name (names may start with spaces)
        if i < line.endIndex { i = line.index(after: i) }
        return (parts, String(line[i...]))
    }

    private static func parseUnix(_ line: String, now: Date) -> FTPEntry? {
        guard let first = line.first, "-dlbcps".contains(first) else { return nil }
        guard let (f, rest) = fields(line, 8), f[0].count >= 10 else { return nil }
        guard let size = Int64(f[4]), let mon = months[f[5].lowercased()], let day = Int(f[6]) else { return nil }
        var name = rest
        let isLink = first == "l"
        if isLink, let arrow = name.range(of: " -> ") { name = String(name[name.startIndex..<arrow.lowerBound]) }
        if name.isEmpty { return nil }
        var comps = DateComponents()
        comps.month = mon
        comps.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        if f[7].contains(":") {
            let hm = f[7].split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2 else { return nil }
            comps.hour = hm[0]
            comps.minute = hm[1]
            // No year: this year, or last year if that would be in the future.
            let y = cal.component(.year, from: now)
            comps.year = y
            if let d = cal.date(from: comps), d > now.addingTimeInterval(86400 * 2) { comps.year = y - 1 }
        } else {
            comps.year = Int(f[7])
        }
        return FTPEntry(name: name, isDir: first == "d", isLink: isLink, size: first == "d" ? nil : size, modified: cal.date(from: comps))
    }

    private static func parseDOS(_ line: String) -> FTPEntry? {
        guard let (f, rawName) = fields(line, 3) else { return nil }
        // Windows pads the size column: the name starts after the run of spaces.
        let name = String(rawName.drop(while: { $0 == " " }))
        if name.isEmpty { return nil }
        let date = f[0].split(separator: "-").compactMap { Int($0) }
        guard date.count == 3 else { return nil }
        let isDir = f[2].uppercased() == "<DIR>"
        let size = isDir ? nil : Int64(f[2])
        if !isDir && size == nil { return nil }
        var comps = DateComponents()
        comps.month = date[0]
        comps.day = date[1]
        comps.year = date[2] < 100 ? (date[2] < 70 ? 2000 + date[2] : 1900 + date[2]) : date[2]
        let t = f[1].uppercased()
        let pm = t.hasSuffix("PM"), am = t.hasSuffix("AM")
        let hm = t.replacingOccurrences(of: "AM", with: "").replacingOccurrences(of: "PM", with: "").split(separator: ":").compactMap { Int($0) }
        if hm.count == 2 {
            var h = hm[0]
            if pm && h < 12 { h += 12 }
            if am && h == 12 { h = 0 }
            comps.hour = h
            comps.minute = hm[1]
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return FTPEntry(name: name, isDir: isDir, size: size, modified: cal.date(from: comps))
    }
}

// MARK: - Names and upload plans

enum FTPNames {
    /// A name FTP commands can carry safely (no line breaks, no "/", not "." or "..").
    static func isSafe(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        return !name.contains("/") && !name.contains("\r") && !name.contains("\n") && !name.unicodeScalars.contains(where: { $0.value == 0 })
    }

    /// "name 2.ext", "name 3.ext", ... first one not in `existing` (compared without letter case, as many
    /// servers are case-insensitive).
    static func unique(_ name: String, existing: Set<String>) -> String {
        let lower = Set(existing.map { $0.lowercased() })
        if !lower.contains(name.lowercased()) { return name }
        let ext = Paths.fileExtension(name)
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let extPart = ext.isEmpty ? "" : "." + ext
        var n = 2
        while lower.contains("\(base) \(n)\(extPart)".lowercased()) { n += 1 }
        return "\(base) \(n)\(extPart)"
    }

    /// Files never uploaded from a Mac folder: Finder's .DS_Store and AppleDouble "._" files.
    static func isMacClutter(_ name: String) -> Bool {
        return name == ".DS_Store" || name.hasPrefix("._")
    }
}

struct FTPUploadItem: Equatable {
    let local: String
    /// Folder on the server (path below the login folder), and the name to give it there.
    let remoteDir: [String]
    let name: String
    let size: Int64

    static func == (a: FTPUploadItem, b: FTPUploadItem) -> Bool {
        return a.local == b.local && a.remoteDir == b.remoteDir && a.name == b.name && a.size == b.size
    }
}

struct FTPUploadPlan {
    var items: [FTPUploadItem] = []
    var skipped: [String] = []          // "name: reason"
    var cancelled = false

    /// What to upload for `locals` dropped into server folder `dir`, whose current names are `existing`.
    /// A clash at the top asks `choose` (keep both / skip / cancel); a folder's contents go into the
    /// new (or renamed) folder. Links, unreadable items and Mac clutter files are left out and listed.
    static func make(_ locals: [String], into dir: [String], existing: [String],
                     choose: (String) -> ConflictChoice) -> FTPUploadPlan {
        var plan = FTPUploadPlan()
        var taken = Set(existing)
        let fm = FileManager.default
        for local in locals {
            let name = Paths.lastComponent(local)
            guard FTPNames.isSafe(name) else { plan.skipped.append("\(name): the name can't be sent to an FTP server"); continue }
            var attrs: [FileAttributeKey: Any]
            do { attrs = try fm.attributesOfItem(atPath: local) } catch { plan.skipped.append("\(name): can't be read on this Mac"); continue }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { plan.skipped.append("\(name): a link (links are not uploaded)"); continue }
            var target = name
            if Set(taken.map { $0.lowercased() }).contains(name.lowercased()) {
                switch choose(name) {
                case .keepBoth: target = FTPNames.unique(name, existing: taken)
                case .cancel: plan.cancelled = true; return plan
                default: plan.skipped.append("\(name): already on the server (nothing overwritten)"); continue
                }
            }
            taken.insert(target)
            if type == .typeDirectory {
                addFolder(local, remote: dir + [target], plan: &plan)
            } else if type == .typeRegular {
                plan.items.append(FTPUploadItem(local: local, remoteDir: dir, name: target, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0))
            } else {
                plan.skipped.append("\(name): not a file or folder")
            }
        }
        return plan
    }

    private static func addFolder(_ local: String, remote: [String], plan: inout FTPUploadPlan) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: local) else {
            plan.skipped.append("\(Paths.lastComponent(local)): folder can't be read on this Mac")
            return
        }
        var any = false
        for n in names.sorted() {
            if FTPNames.isMacClutter(n) { continue }
            let p = Paths.join(local, n)
            guard FTPNames.isSafe(n) else { plan.skipped.append("\(n): the name can't be sent to an FTP server"); continue }
            guard let attrs = try? fm.attributesOfItem(atPath: p) else { plan.skipped.append("\(n): can't be read on this Mac"); continue }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { plan.skipped.append("\(n): a link (links are not uploaded)"); continue }
            if type == .typeDirectory {
                let before = plan.items.count
                addFolder(p, remote: remote + [n], plan: &plan)
                if plan.items.count > before { any = true }
            } else if type == .typeRegular {
                plan.items.append(FTPUploadItem(local: p, remoteDir: remote, name: n, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0))
                any = true
            }
        }
        if !any { plan.skipped.append("\(remote.last ?? ""): no files inside (empty folders are not created)") }
    }
}

// MARK: - The connection (curl)

final class FTPClient {
    let server: FTPServer
    var curl = "/usr/bin/curl"
    var connectTimeout = 15
    /// Seconds without any data before a transfer is given up.
    var stallSeconds = 60

    init(server: FTPServer) {
        self.server = server
    }

    private static var pathChars: CharacterSet {
        var c = CharacterSet.urlPathAllowed
        c.remove(charactersIn: "/;?#%")
        return c
    }

    /// ftp://host/a/b (or .../ for a folder). Paths are below the folder the account logs in to.
    func url(_ path: [String], dir: Bool) -> String {
        var u = "ftp://" + server.host + "/"
        u += path.map { $0.addingPercentEncoding(withAllowedCharacters: FTPClient.pathChars) ?? $0 }.joined(separator: "/")
        if dir && !path.isEmpty { u += "/" }
        return u
    }

    /// curl's config text: the account and password (read from standard input).
    func configText() -> String {
        func q(_ s: String) -> String {
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        if server.user.isEmpty { return "" }
        return "user = " + q(server.user + ":" + (server.password ?? "")) + "\n"
    }

    struct Run {
        let status: Int32
        let out: Data
        let err: String
    }

    /// The last "12.3%" in curl's progress bar output, as 0...1.
    static func lastPercent(_ text: String) -> Double? {
        guard let pct = text.range(of: "%", options: .backwards) else { return nil }
        var start = pct.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            let c = text[prev]
            if c.isASCIIDigitOrDot { start = prev } else { break }
        }
        guard let v = Double(text[start..<pct.lowerBound].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return max(0, min(1, v / 100))
    }

    /// Bytes read from one of curl's outputs, shared safely between the reading thread and the caller.
    private final class Sink {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Read `fd` to its end with plain read() calls. (0.17.1: FileHandle's reads raise an Objective-C
    /// exception on a read error, which Swift can't catch - that ended Find.)
    private static func drain(_ fd: Int32, into sink: Sink, onChunk: ((Data) -> Void)? = nil) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 65536) }
            if n > 0 {
                let d = Data(buf[0..<n])
                sink.append(d)
                onChunk?(d)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break   // end (curl finished) or an error: stop reading, never crash
            }
        }
    }

    /// Start a program; a failure to start is an error, not an exception that ends Find.
    private static func start(_ p: Process) throws {
        #if os(Linux)
        p.launch()   // tests only
        #else
        if #available(OSX 10.13, *) { try p.run() } else { p.launch() }
        #endif
    }

    /// Run curl with `args`, its config on standard input. Waits at most `timeout` seconds.
    /// `onProgress` (0.17): curl's progress bar is read as it goes and passed on as 0...1.
    /// 0.17.1: nothing here can end Find any more - curl not starting, a broken pipe or a read error
    /// all come back as a failed Run (code FTP-00 / FTP-xx) instead.
    func run(_ args: [String], timeout: Double, onProgress: ((Double) -> Void)? = nil) -> Run {
        let t0 = Date()
        let r = runCurl(args, timeout: timeout, onProgress: onProgress)
        if let log = IOLog.network { FTPClient.logIO(log, args: args, run: r, seconds: Date().timeIntervalSince(t0)) }
        return r
    }

    /// 0.18: each curl command as a line of the network I/O log (what, bytes, time, FTP error code).
    private static func logIO(_ log: IOLog, args: [String], run r: Run, seconds: Double) {
        func after(_ flag: String) -> String? {
            guard let i = args.index(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func fileSize(_ p: String) -> Int64 {
            return ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? -1
        }
        let url = args.reversed().first(where: { $0.hasPrefix("ftp://") }) ?? ""
        var what = "FTP-LIST"
        var inBytes = Int64(r.out.count), outBytes: Int64 = 0
        if let q = after("-Q") {
            what = "FTP-" + (q.split(separator: " ").first.map(String.init) ?? "COMMAND")
        } else if let local = after("-T") {
            what = "FTP-UPLOAD"
            outBytes = r.status == 0 ? fileSize(local) : -1
            inBytes = 0
        } else if let local = after("-o") {
            what = "FTP-DOWNLOAD"
            inBytes = fileSize(local)
        } else if args.contains("-I") {
            what = "FTP-SIZE"
        } else if let x = after("-X") {
            what = "FTP-" + x
        }
        let code: String? = r.status == 0 ? nil : FTPClient.failure(r, doing: "log").code
        log.record(what, read: inBytes, written: outBytes, seconds: seconds, detail: url.removingPercentEncoding ?? url, error: code)
    }

    private func runCurl(_ args: [String], timeout: Double, onProgress: ((Double) -> Void)? = nil) -> Run {
        guard FileManager.default.isExecutableFile(atPath: curl) else {
            return Run(status: -1, out: Data(), err: "curl not found at \(curl)")
        }
        let p = Process()
        p.launchPath = curl
        // A clean environment: no proxy settings or library paths from elsewhere change what curl does.
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C"]
        // --globoff: [ ] { } in a file or folder name are just characters (curl would otherwise treat
        // them as a pattern for several files - .app bundles have such names).
        p.arguments = ["-K", "-", "--globoff"] + (onProgress == nil ? ["-s", "-S"] : ["-#", "-S"]) + ["--connect-timeout", "\(connectTimeout)",
                       "--speed-limit", "1", "--speed-time", "\(stallSeconds)"] + args
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try FTPClient.start(p)
        } catch {
            inPipe.fileHandleForWriting.closeFile()
            outPipe.fileHandleForReading.closeFile()
            errPipe.fileHandleForReading.closeFile()
            return Run(status: -1, out: Data(), err: "curl could not be started: \(error)")
        }
        // The account goes in with plain write() calls: if curl is already gone, the write just fails
        // (Find ignores SIGPIPE) instead of ending Find.
        let cfg = Array(configText().utf8)
        let wfd = inPipe.fileHandleForWriting.fileDescriptor
        var off = 0
        while off < cfg.count {
            let n = cfg.withUnsafeBytes { write(wfd, $0.baseAddress! + off, cfg.count - off) }
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
        inPipe.fileHandleForWriting.closeFile()
        let out = Sink(), err = Sink()
        let readers = DispatchGroup()
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        readers.enter()
        DispatchQueue.global().async { FTPClient.drain(outFD, into: out); readers.leave() }
        readers.enter()
        DispatchQueue.global().async {
            if let report = onProgress {
                // The progress bar rewrites one line with carriage returns: report its last percentage.
                var tail = ""
                FTPClient.drain(errFD, into: err, onChunk: { d in
                    tail = String((tail + (String(data: d, encoding: .utf8) ?? "")).suffix(200))
                    if let f = FTPClient.lastPercent(tail) { report(f) }
                })
            } else {
                FTPClient.drain(errFD, into: err)
            }
            readers.leave()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        // curl has ended, so its outputs end too. The read ends are closed only once nothing reads them.
        if readers.wait(timeout: .now() + 30) == .success {
            outPipe.fileHandleForReading.closeFile()
            errPipe.fileHandleForReading.closeFile()
        }
        if timedOut {
            return Run(status: 28, out: out.value, err: "gave up after \(Int(timeout)) seconds")
        }
        var errText = String(data: err.value, encoding: .utf8) ?? ""
        if onProgress != nil {
            // Only curl's own messages, not the progress bar.
            errText = errText.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { $0.contains("curl:") }.joined(separator: "\n")
        }
        // The end of curl can be reported a moment before the process counts as finished; asking for
        // its exit status before then raises an exception that ends Find (possibly the 0.16/0.17.0
        // crash). Wait for it properly (at most 5 s).
        var waited = 0
        while p.isRunning && waited < 500 { usleep(10_000); waited += 1 }
        if p.isRunning { return Run(status: 28, out: out.value, err: "curl did not finish") }
        return Run(status: p.terminationStatus, out: out.value, err: errText)
    }

    /// curl's exit status as a plain explanation with an FTP-xx code.
    static func failure(_ r: Run, doing what: String) -> FTPFailure {
        let detail = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "curl: ", with: "")
        let tail = detail.isEmpty ? "" : " (\(detail))"
        switch r.status {
        case 6: return FTPFailure(code: "FTP-06", text: "The server's name could not be found\(tail).")
        case 7: return FTPFailure(code: "FTP-07", text: "The server can't be reached\(tail).")
        case 9: return FTPFailure(code: "FTP-09", text: "The server doesn't allow you to \(what)\(tail).")
        case 67: return FTPFailure(code: "FTP-67", text: "The server refused the account name or password\(tail).")
        case 78: return FTPFailure(code: "FTP-78", text: "It isn't on the server (any more)\(tail).")
        case 28: return FTPFailure(code: "FTP-28", text: "The server stopped answering\(tail).")
        case 25: return FTPFailure(code: "FTP-25", text: "The server refused the upload\(tail).")
        case 21: return FTPFailure(code: "FTP-21", text: "The server refused to \(what)\(tail).")
        case 19: return FTPFailure(code: "FTP-19", text: "The server refused to send it\(tail).")
        case 55, 56: return FTPFailure(code: "FTP-56", text: "The connection broke off\(tail).")
        case -1: return FTPFailure(code: "FTP-00", text: "curl (part of macOS) could not be started\(tail).")
        default: return FTPFailure(code: "FTP-\(r.status)", text: "Could not \(what) (curl error \(r.status))\(tail).")
        }
    }

    // MARK: Listing

    func list(_ dir: [String]) -> FTPResult<[FTPEntry]> {
        let u = url(dir, dir: true)
        let m = run(["-X", "MLSD", u], timeout: 120)
        if m.status == 0, let text = String(data: m.out, encoding: .utf8) ?? String(data: m.out, encoding: .isoLatin1),
            let entries = FTPList.parseMLSD(text) {
            return .ok(entries)
        }
        if m.status == 67 || m.status == 6 || m.status == 7 || m.status == 9 || m.status == 28 {
            return .failed(FTPClient.failure(m, doing: "open this folder"))
        }
        // The server may not know MLSD: the classic listing.
        let l = run([u], timeout: 120)
        guard l.status == 0 else { return .failed(FTPClient.failure(l, doing: "open this folder")) }
        let text = String(data: l.out, encoding: .utf8) ?? String(data: l.out, encoding: .isoLatin1) ?? ""
        return .ok(FTPList.parseLIST(text))
    }

    /// The size the server reports for a file (SIZE), or from its folder listing.
    func size(_ file: [String]) -> Int64? {
        let r = run(["-I", url(file, dir: false)], timeout: 60)
        if r.status == 0, let text = String(data: r.out, encoding: .utf8) {
            for line in text.components(separatedBy: "\n") where line.lowercased().hasPrefix("content-length:") {
                let v = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if let n = Int64(v) { return n }
            }
        }
        guard let name = file.last, let entries = list(Array(file.dropLast())).value else { return nil }
        return entries.first(where: { $0.name == name && !$0.isDir })?.size
    }

    // MARK: Upload

    /// Upload one file to `dir/name` (folders below are created if missing). The caller has checked the
    /// name is free. Afterwards the size on the server must equal the file's size here.
    func upload(_ item: FTPUploadItem, progress: ((Double) -> Void)? = nil) -> FTPFailure? {
        guard FTPNames.isSafe(item.name), item.remoteDir.allSatisfyCompat({ FTPNames.isSafe($0) }) else {
            return FTPFailure(code: "FTP-NAME", text: "The name can't be sent to an FTP server.")
        }
        let target = item.remoteDir + [item.name]
        let r = run(["--ftp-create-dirs", "-T", item.local, url(target, dir: false)], timeout: 60 * 60 * 6, onProgress: progress)
        if r.status != 0 {
            var f = FTPClient.failure(r, doing: "upload here")
            if r.status == 9 || r.status == 25 {
                f = FTPFailure(code: f.code, text: "The server refused the upload into \(item.remoteDir.isEmpty ? "the top folder" : item.remoteDir.joined(separator: "/")) - you may not have permission there.")
            }
            return f
        }
        guard let got = size(target) else {
            return FTPFailure(code: "FTP-SIZE", text: "Uploaded, but the server would not say its size, so the upload could not be checked. Check it on the server.")
        }
        if got != item.size {
            return FTPFailure(code: "FTP-SIZE", text: "Incomplete on the server: \(got) of \(item.size) bytes. Upload it again (the incomplete copy is on the server).")
        }
        return nil
    }

    // MARK: Delete (files only)

    /// Delete one FILE on the server. `isDir` must come from the listing: folders are refused here.
    /// Afterwards the folder is listed again to confirm it is gone.
    func deleteFile(_ file: [String], isDir: Bool) -> FTPFailure? {
        guard !isDir else { return FTPFailure(code: "FTP-DIR", text: "Folders are never deleted on an FTP server by Find.") }
        guard let name = file.last, file.allSatisfyCompat({ FTPNames.isSafe($0) }) else {
            return FTPFailure(code: "FTP-NAME", text: "The name can't be sent to an FTP server.")
        }
        let dir = Array(file.dropLast())
        // DELE with the path from the login folder, sent right after logging in (before curl changes
        // folder and lists it). Nothing else is sent.
        let r = run(["-Q", "DELE " + file.joined(separator: "/"), url(dir, dir: true), "-o", "/dev/null"], timeout: 120)
        if r.status != 0 {
            if r.status == 21 || r.status == 9 {
                return FTPFailure(code: "FTP-DELE", text: "The server refused to delete it - you may not have permission in this folder.")
            }
            return FTPClient.failure(r, doing: "delete it")
        }
        guard let after = list(dir).value else {
            return FTPFailure(code: "FTP-CHECK", text: "Deleted, but the folder could not be listed again to confirm.")
        }
        if after.contains(where: { $0.name == name }) {
            return FTPFailure(code: "FTP-DELE", text: "The server answered but the file is still there.")
        }
        return nil
    }

    // MARK: Rename (files only, 0.16)

    /// Rename one FILE in its folder. The folder is listed first: an existing name (any letter case)
    /// is refused, so nothing is ever replaced. Afterwards the folder is listed again to confirm.
    func renameFile(_ file: [String], isDir: Bool, to newName: String) -> FTPFailure? {
        // 0.17: folders too (the server decides where that is allowed).
        guard let old = file.last, FTPNames.isSafe(newName), file.allSatisfyCompat({ FTPNames.isSafe($0) }) else {
            return FTPFailure(code: "FTP-NAME", text: "The name can't be sent to an FTP server.")
        }
        if old == newName { return nil }
        let dir = Array(file.dropLast())
        guard let before = list(dir).value else {
            return FTPFailure(code: "FTP-CHECK", text: "The folder could not be listed first, so nothing was renamed.")
        }
        if before.contains(where: { $0.name.lowercased() == newName.lowercased() && $0.name != old }) {
            return FTPFailure(code: "FTP-EXISTS", text: "\u{201C}\(newName)\u{201D} is already in this folder. Nothing was renamed.")
        }
        let from = file.joined(separator: "/"), to = (dir + [newName]).joined(separator: "/")
        let r = run(["-Q", "RNFR " + from, "-Q", "RNTO " + to, url(dir, dir: true), "-o", "/dev/null"], timeout: 120)
        if r.status != 0 {
            if r.status == 21 || r.status == 9 {
                return FTPFailure(code: "FTP-RENAME", text: "The server refused to rename it - you may not have permission in this folder.")
            }
            return FTPClient.failure(r, doing: "rename it")
        }
        guard let after = list(dir).value else {
            return FTPFailure(code: "FTP-CHECK", text: "Renamed, but the folder could not be listed again to confirm.")
        }
        if !after.contains(where: { $0.name == newName }) {
            return FTPFailure(code: "FTP-RENAME", text: "The server answered but the new name isn't there.")
        }
        return nil
    }

    /// 0.17.1: move a file or folder into another folder on the same server (RNFR/RNTO), where the server
    /// allows it. Never over an existing name; never into itself. Confirmed by listing both folders.
    func moveOnServer(_ item: [String], into destDir: [String]) -> FTPFailure? {
        guard let name = item.last, item.allSatisfyCompat({ FTPNames.isSafe($0) }), destDir.allSatisfyCompat({ FTPNames.isSafe($0) }) else {
            return FTPFailure(code: "FTP-NAME", text: "The name can't be sent to an FTP server.")
        }
        let fromDir = Array(item.dropLast())
        if fromDir == destDir { return nil }
        if destDir.count >= item.count && Array(destDir.prefix(item.count)) == item {
            return FTPFailure(code: "FTP-MOVE", text: "A folder can't be put inside itself.")
        }
        guard let there = list(destDir).value else {
            return FTPFailure(code: "FTP-CHECK", text: "The destination folder could not be listed first, so nothing was moved.")
        }
        if there.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            return FTPFailure(code: "FTP-EXISTS", text: "\u{201C}\(name)\u{201D} is already in \(destDir.last ?? "the top folder"). Nothing was moved or replaced.")
        }
        let r = run(["-Q", "RNFR " + item.joined(separator: "/"), "-Q", "RNTO " + (destDir + [name]).joined(separator: "/"),
                     url(fromDir, dir: true), "-o", "/dev/null"], timeout: 120)
        if r.status != 0 {
            if r.status == 21 || r.status == 9 {
                return FTPFailure(code: "FTP-MOVE", text: "The server refused to move it - you may not have permission there.")
            }
            return FTPClient.failure(r, doing: "move it")
        }
        guard let after = list(destDir).value, after.contains(where: { $0.name == name }) else {
            return FTPFailure(code: "FTP-CHECK", text: "The server answered, but \u{201C}\(name)\u{201D} could not be found in the destination to confirm.")
        }
        return nil
    }

    /// 0.17.1: make a new empty folder `name` in `dir` (MKD). Refused if the name is there already.
    func makeFolderOnServer(_ dir: [String], name: String) -> FTPFailure? {
        guard FTPNames.isSafe(name), dir.allSatisfyCompat({ FTPNames.isSafe($0) }) else {
            return FTPFailure(code: "FTP-NAME", text: "The name can't be sent to an FTP server.")
        }
        guard let before = list(dir).value else {
            return FTPFailure(code: "FTP-CHECK", text: "The folder could not be listed first, so nothing was made.")
        }
        if before.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            return FTPFailure(code: "FTP-EXISTS", text: "\u{201C}\(name)\u{201D} is already in this folder.")
        }
        let r = run(["-Q", "MKD " + (dir + [name]).joined(separator: "/"), url(dir, dir: true), "-o", "/dev/null"], timeout: 120)
        if r.status != 0 {
            if r.status == 21 || r.status == 9 {
                return FTPFailure(code: "FTP-MKD", text: "The server refused to make a folder here - you may not have permission in this folder.")
            }
            return FTPClient.failure(r, doing: "make a folder here")
        }
        guard let after = list(dir).value, after.contains(where: { $0.name == name && $0.isDir }) else {
            return FTPFailure(code: "FTP-CHECK", text: "The server answered, but the new folder could not be found to confirm.")
        }
        return nil
    }

    /// 0.17: delete a FOLDER and everything in it, where the server allows it (in practice: inside your
    /// own folder). The whole content is listed first; files are deleted, then the folders from the
    /// deepest up (RMD), then the folder itself. The first thing the server refuses stops it: what was
    /// already deleted stays deleted (FTP has no Trash), the rest is left exactly as it was.
    /// `onItem` is told each name as it goes (for the progress window).
    func deleteFolder(_ dir: [String], isCancelled: () -> Bool = { false },
                      onItem: (String) -> Void = { _ in }) -> (files: Int, folders: Int, failure: FTPFailure?) {
        guard !dir.isEmpty, dir.allSatisfyCompat({ FTPNames.isSafe($0) }) else {
            return (0, 0, FTPFailure(code: "FTP-NAME", text: "The name can't be sent to an FTP server."))
        }
        let inside: [([String], FTPEntry)]
        switch walk(dir, limit: 50_000, isCancelled: isCancelled) {
        case .failed(let f): return (0, 0, f)
        case .ok(let w): inside = w
        }
        if inside.count >= 50_000 {
            return (0, 0, FTPFailure(code: "FTP-BIG", text: "The folder holds more than 50,000 items; nothing was deleted."))
        }
        var files = 0, folders = 0
        for (p, e) in inside where !e.isDir {
            if isCancelled() { return (files, folders, FTPFailure(code: "FTP-STOP", text: "Stopped. Deleted so far: \(files) files.")) }
            onItem(p.joined(separator: "/"))
            if let f = deleteFile(p, isDir: false) { return (files, folders, f) }
            files += 1
        }
        // Folders deepest first, then the folder itself.
        let dirs = inside.filter { $0.1.isDir }.map { $0.0 }.sorted { $0.count > $1.count } + [dir]
        for d in dirs {
            if isCancelled() { return (files, folders, FTPFailure(code: "FTP-STOP", text: "Stopped. Deleted so far: \(files) files, \(folders) folders.")) }
            onItem(d.joined(separator: "/") + "/")
            let r = run(["-Q", "RMD " + d.joined(separator: "/"), url(Array(d.dropLast()), dir: true), "-o", "/dev/null"], timeout: 120)
            if r.status != 0 {
                return (files, folders, FTPFailure(code: "FTP-RMD", text: "The server refused to remove the folder \(d.last ?? "") - you may not have permission there."))
            }
            folders += 1
        }
        guard let parent = list(Array(dir.dropLast())).value else {
            return (files, folders, FTPFailure(code: "FTP-CHECK", text: "Deleted, but the folder above could not be listed again to confirm."))
        }
        if parent.contains(where: { $0.name == dir.last }) {
            return (files, folders, FTPFailure(code: "FTP-RMD", text: "The server answered but the folder is still there."))
        }
        return (files, folders, nil)
    }

    /// Everything inside a server folder, for downloading a folder: (path, entry) for files and folders,
    /// parents first. Stops at `limit` items.
    func walk(_ dir: [String], limit: Int = 20_000, isCancelled: () -> Bool = { false }) -> FTPResult<[([String], FTPEntry)]> {
        var out: [([String], FTPEntry)] = []
        var queue: [[String]] = [dir]
        while !queue.isEmpty {
            if isCancelled() { break }
            let d = queue.removeFirst()
            switch list(d) {
            case .failed(let f): return .failed(f)
            case .ok(let entries):
                for e in entries where !e.isLink {
                    out.append((d + [e.name], e))
                    if e.isDir { queue.append(d + [e.name]) }
                    if out.count >= limit { return .ok(out) }
                }
            }
        }
        return .ok(out)
    }

    // MARK: Download

    /// Download one file to `local` (a path in Find's own temporary folder). Checked against `expected`.
    func download(_ file: [String], to local: String, expected: Int64?, progress: ((Double) -> Void)? = nil) -> FTPFailure? {
        let r = run(["-o", local, url(file, dir: false)], timeout: 60 * 60 * 6, onProgress: progress)
        if r.status != 0 { return FTPClient.failure(r, doing: "download it") }
        let got = ((try? FileManager.default.attributesOfItem(atPath: local))?[.size] as? NSNumber)?.int64Value
        if let e = expected, got != e {
            return FTPFailure(code: "FTP-SIZE", text: "Download incomplete: \(got ?? 0) of \(e) bytes.")
        }
        return nil
    }
}


extension Character {
    var isASCIIDigitOrDot: Bool { return ("0"..."9").contains(self) || self == "." || self == "," }
}


/// 0.17: the last listing of each FTP folder, shown at once on the next visit (also after Find was
/// quit) while the server is read again quietly. Kept per server and account; at most `capacity`
/// folders (the oldest are forgotten first).
final class FTPListingMemory: Codable {
    static let capacity = 3000
    private var listings: [String: [FTPEntry]] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    private enum CodingKeys: String, CodingKey { case listings, order }

    init() {}

    static func key(_ server: String, _ path: [String]) -> String {
        return server + "|/" + path.joined(separator: "/")
    }

    func get(_ server: String, _ path: [String]) -> [FTPEntry]? {
        lock.lock(); defer { lock.unlock() }
        return listings[FTPListingMemory.key(server, path)]
    }

    func put(_ server: String, _ path: [String], _ entries: [FTPEntry]) {
        lock.lock(); defer { lock.unlock() }
        let k = FTPListingMemory.key(server, path)
        listings[k] = entries
        order = order.filter { $0 != k }
        order.append(k)
        while order.count > FTPListingMemory.capacity {
            listings[order.removeFirst()] = nil
        }
    }

    /// Forget a folder (and everything below it) - after something there was changed.
    func forget(_ server: String, _ path: [String]) {
        lock.lock(); defer { lock.unlock() }
        let k = FTPListingMemory.key(server, path)
        for x in listings.keys where x == k || x.hasPrefix(k + "/") { listings[x] = nil }
        order = order.filter { listings[$0] != nil }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return listings.count
    }

    func encode() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? JSONEncoder().encode(self)
    }

    static func decode(_ d: Data) -> FTPListingMemory? {
        return try? JSONDecoder().decode(FTPListingMemory.self, from: d)
    }
}
