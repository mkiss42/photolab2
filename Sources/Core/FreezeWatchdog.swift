// FreezeWatchdog.swift
// Logs every main-thread stall longer than 0.25 s as
//   "FREEZE 1.4 s while: list: going to /Volumes/Share/Job"
// so a slow spot can be found from the log. Activity.set() names what the app is doing.

import Foundation

enum Activity {
    private static let lock = NSLock()
    private static var current = "idle"

    static func set(_ text: String) {
        lock.lock(); current = text; lock.unlock()
    }

    static var text: String {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

enum FreezeWatchdog {
    static let threshold: Double = 0.25
    private static var started = false

    static func start() {
        if started { return }
        started = true
        let t = Thread {
            let sem = DispatchSemaphore(value: 0)
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                // Ask the main run loop in all common modes (menus, scrolling, sheets), not just the
                // default mode, so menu tracking is not mistaken for a freeze.
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { sem.signal() }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                if sem.wait(timeout: .now() + threshold) == .timedOut {
                    let t0 = Date()
                    let what = Activity.text
                    sem.wait()
                    let secs = Date().timeIntervalSince(t0) + threshold
                    Stats.noteFreeze(secs, during: what)
                    Log.warn(String(format: "FREEZE %.2f s while: ", secs) + what)
                }
            }
        }
        t.name = "photolab.freeze-watchdog"
        t.qualityOfService = .utility
        t.start()
    }
}
