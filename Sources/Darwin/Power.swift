// Power.swift
// 0.16: for the copy queue.
// - keepAwake / release: while a queued copy runs, the Mac doesn't go to sleep by itself (a standard
//   power assertion; the screen may still sleep). Released as soon as the copy ends or pauses.
// - scheduleWake: asks macOS to wake the Mac shortly before a scheduled copy ("pmset schedule wake"),
//   which needs an administrator password - macOS asks for it itself, once per scheduled copy.
//   The command holds only the date (digits, slashes, colons, a space): nothing else can get in.

import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#endif

enum Power {
    static func keepAwake(_ reason: String) -> UInt32? {
        #if os(macOS)
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return r == kIOReturnSuccess ? id : nil
        #else
        return nil
        #endif
    }

    static func release(_ id: UInt32?) {
        #if os(macOS)
        if let i = id { IOPMAssertionRelease(i) }
        #endif
    }

    /// Ask macOS (with an administrator password) to wake the Mac at `pmsetDate` ("MM/dd/yy HH:mm:ss").
    /// Returns nil, or why not. Call on the main thread.
    static func scheduleWake(_ pmsetDate: String) -> String? {
        let allowed = CharacterSet(charactersIn: "0123456789/: ")
        guard !pmsetDate.isEmpty, pmsetDate.unicodeScalars.allSatisfyCompat({ allowed.contains($0) }) else {
            return "Not a valid date for the wake-up."
        }
        #if os(macOS)
        let src = "do shell script \"/usr/bin/pmset schedule wake '\(pmsetDate)'\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { return "The wake-up could not be set up." }
        _ = script.executeAndReturnError(&err)
        if let e = err {
            let n = (e["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
            if n == -128 { return "Cancelled (no password given), so the Mac won't wake for it - it runs when the Mac is awake." }
            return "macOS refused the wake-up (\(e["NSAppleScriptErrorMessage"] as? String ?? "error \(n)"))."
        }
        return nil
        #else
        return "Not on this system."
        #endif
    }
}

extension String.UnicodeScalarView {
    func allSatisfyCompat(_ test: (Unicode.Scalar) -> Bool) -> Bool {
        for u in self where !test(u) { return false }
        return true
    }
}
