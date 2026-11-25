// SystemInfo.swift
// The real macOS version. ProcessInfo.operatingSystemVersion reports "10.16" to binaries whose
// deployment target is older than 11.0 (Apple's compatibility shim); kern.osproductversion
// tells the truth (10.13.4 and later; older systems fall back to ProcessInfo).

import Foundation
import Darwin

enum SystemInfo {
    static let osVersion: String = {
        let v = productVersion()
        if !v.hasPrefix("10.16") { return v }
        // Compatibility answer: derive the real version from the Darwin kernel version.
        // Darwin 20-24 = macOS 11-15, Darwin 25 = macOS 26 (Apple renumbered), later +1 per year.
        let parts = sysctlString("kern.osrelease").split(separator: ".").compactMap { Int($0) }
        guard let d = parts.first, d >= 20 else { return v }
        let major = d >= 25 ? d + 1 : d - 9
        let minor = parts.count > 1 ? parts[1] : 0
        return "\(major).\(minor)"
    }()

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    private static func productVersion() -> String {
        var size = 0
        if sysctlbyname("kern.osproductversion", nil, &size, nil, 0) == 0, size > 1 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0 {
                return String(cString: buf)
            }
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var archName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// True when this x86_64 process runs under Rosetta on Apple Silicon.
    static let isTranslated: Bool = {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0) != 0 { return false }
        return ret == 1
    }()

    static var summary: String {
        return "\(archName)\(isTranslated ? " (Rosetta)" : "") macOS \(osVersion)"
    }
}
