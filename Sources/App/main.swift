// main.swift
// `PhotoLab --self-test` runs every self-test, prints one line per test and exits
// (0 = no failures). Otherwise starts the app.

import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print(AppDelegate.appVersion)
    exit(0)
}

if arguments.contains("--self-test") {
    Log.echo = true
    AppFiles.ensureDirectories()
    DispatchQueue.global(qos: .userInitiated).async {
        let results = SelfTestRunner.runAll()
        for r in results { print(r.line) }
        let failed = results.filter { $0.status == .fail }.count
        print("SELFTEST-SUMMARY \(results.count) run, \(failed) failed")
        Log.flush()
        exit(failed == 0 ? 0 : 1)
    }
    dispatchMain()   // keeps the main queue serving callbacks
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
