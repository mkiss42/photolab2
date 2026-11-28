// FTPSelfTest.swift  (PhotoLab)
// --ftptest host:port - the kept-open FTP connection against a real FTP server (CI starts a local
// pyftpdlib server with a writable anonymous account). Lists, makes a folder, uploads with curl,
// checks the size, renames, deletes; then breaks the connection and checks that the next command
// logs in again by itself. Leaves nothing on the server.

import Foundation

final class FTPSelfTest {
    let files: AppFiles
    private let report = Report(title: "PhotoLab FTP Self-Test")
    private(set) var passed = 0
    private(set) var failed = 0

    init(files: AppFiles) { self.files = files }

    private func check(_ code: String, _ what: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; report.add("PASS \(code) \(what)") } else {
            failed += 1
            report.add("FAIL \(code) \(what)" + (detail.isEmpty ? "" : " -- \(detail)"))
        }
    }

    func run(server address: String, appVersion: String) -> String {
        report.add("App version: \(appVersion)")
        let client = FTPClient(server: FTPServer(host: address, user: "", password: nil))
        var lines: [String] = []
        client.traffic = { lines.append($0) }
        let dir = "pltest-\(Ascii.fileStamp())"
        let l0 = client.list([])
        check("T-FTP-1", "list the top folder through the kept-open connection", l0.value != nil, l0.failure?.text ?? "")
        check("T-FTP-2", "made a folder", client.makeFolderOnServer([], name: dir) == nil)
        let local = Paths.join(files.cachesDir, "ftptest-\(Ascii.fileStamp()).txt")
        _ = files.writeText(String(repeating: "PhotoLab FTP test\n", count: 500), to: local)
        let size = Int64(500 * 18)
        let up = client.upload(FTPUploadItem(local: local, remoteDir: [dir], name: "a.txt", size: size))
        check("T-FTP-3", "uploaded (curl) and the size checked through the session", up == nil, up?.text ?? "")
        check("T-FTP-4", "SIZE through the session", client.size([dir, "a.txt"]) == size)
        let rn = client.renameFile([dir, "a.txt"], isDir: false, to: "b.txt")
        check("T-FTP-5", "renamed (RNFR/RNTO), confirmed by listing", rn == nil, rn?.text ?? "")
        // The connection breaks (as a server idle timeout would): the next command logs in again.
        client.session.dropConnectionForTest()
        let l1 = client.list([dir])
        check("T-FTP-6", "after a broken connection: logged in again by itself", l1.value?.contains { $0.name == "b.txt" } == true,
              l1.failure?.text ?? "")
        let logins = lines.filter { $0.hasPrefix("* Logged in (home") }.count
        check("T-FTP-7", "one login for everything before the break, one after (not one per command)", logins == 2, "\(logins) logins")
        let del = client.deleteFolder([dir])
        check("T-FTP-8", "test folder deleted (DELE, RMD)", del.failure == nil, del.failure?.text ?? "")
        check("T-FTP-9", "the password never appears in the traffic", !lines.contains { $0.hasPrefix("> PASS") && !$0.hasSuffix("****") })
        client.session.quit()
        _ = files.removeOwned(local)
        report.addSummary("App \(appVersion)")
        report.addSummary(failed == 0 ? "RESULT ALL PASSED" : "RESULT FAILURES PRESENT")
        report.addSummary("PASSED \(passed) FAILED \(failed)")
        for l in lines.suffix(60) { report.add("TRAFFIC " + l) }
        return report.render()
    }
}
