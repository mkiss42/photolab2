// main.swift
// Find: a fast, careful file browser for macOS 10.13 and later.
//
// Command-line options (used by build.sh to test the finished app on this Mac):
//   --version     print the version and exit
//   --selfcheck   run the Safety Self-Check without opening windows, print the report, exit (0 = all passed)
//   --searchtest  run the Search Self-Test the same way
//   --indextest   run the Index Self-Test the same way
//   --phototest   run the Photo Metadata Self-Test (exit 0 passed, 1 warnings, 2 a file changed)

import AppKit

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("PhotoLab \(App.version)")
    exit(0)
}
if arguments.contains("--selfcheck") {
    App.start()
    let check = SafetySelfCheck(ops: App.ops, files: App.files)
    let text = check.run(appVersion: App.version, systemInfo: App.systemInfo)
    let path = Paths.join(App.files.logsDir, "selfcheck-\(Ascii.fileStamp()).txt")
    App.files.writeText(text, to: path)
    App.log.info("Command-line self-check: passed \(check.passed), failed \(check.failed)")
    App.log.flush()
    print(text, terminator: "")
    exit(check.failed == 0 ? 0 : 1)
}

if arguments.contains("--searchtest") {
    App.start()
    let t = SearchSelfTest(files: App.files, isPackage: { p, ext in KindCache.shared.isPackage(path: p, ext: ext) })
    let text = t.run(appVersion: App.version, systemInfo: App.systemInfo)
    App.files.writeText(text, to: Paths.join(App.files.logsDir, "searchtest-\(Ascii.fileStamp()).txt"))
    App.log.info("Command-line search self-test: passed \(t.passed), failed \(t.failed)")
    App.log.flush()
    print(text, terminator: "")
    exit(t.failed == 0 ? 0 : 1)
}

if arguments.contains("--indextest") {
    App.start()
    let t = IndexSelfTest(files: App.files, isPackage: { p, ext in KindCache.shared.isPackage(path: p, ext: ext) })
    let text = t.run(appVersion: App.version, systemInfo: App.systemInfo)
    App.files.writeText(text, to: Paths.join(App.files.logsDir, "indextest-\(Ascii.fileStamp()).txt"))
    App.log.info("Command-line index self-test: passed \(t.passed), failed \(t.failed)")
    App.log.flush()
    print(text, terminator: "")
    exit(t.failed == 0 ? 0 : 1)
}

if arguments.contains("--phototest") {
    App.start()
    let t = PhotoSelfTest(files: App.files)
    let text = t.run(appVersion: App.version, systemInfo: App.systemInfo)
    App.files.writeText(text, to: Paths.join(App.files.logsDir, "phototest-\(Ascii.fileStamp()).txt"))
    App.log.info("Command-line photo metadata self-test: passed \(t.passed), failed \(t.failed), skipped \(t.skipped)")
    App.log.flush()
    print(text, terminator: "")
    exit(t.exitCode)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
