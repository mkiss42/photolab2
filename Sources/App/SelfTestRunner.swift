// SelfTestRunner.swift
// Runs every self-test: core logic plus a live brain round trip (skipped when the app has no
// Python runtime and PHOTOLAB_PYTHON is not set). Used by --self-test (CI, build.sh) and
// Help > Run Self-Test.

import Foundation

enum SelfTestRunner {
    /// Never call on the main thread when the brain test is included.
    static func runAll() -> [SelfTestResult] {
        var results = CoreSelfTest.run()
        results.append(brainPing())
        results.append(architecture())
        return results
    }

    static func architecture() -> SelfTestResult {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let detail = "\(BrainClient.archName) macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return SelfTestResult(name: "architecture", status: .ok, detail: detail)
    }

    static func brainPing() -> SelfTestResult {
        let name = "brain-ping"
        if BrainClient.pythonPath() == nil {
            return SelfTestResult(name: name, status: .skip, detail: "no Python runtime (set PHOTOLAB_PYTHON)")
        }
        let sock = NSTemporaryDirectory() + "plb-\(ProcessInfo.processInfo.processIdentifier).sock"
        let client = BrainClient(socketPath: sock)
        let ready = DispatchSemaphore(value: 0)
        var final: BrainClient.State = .notStarted
        client.onStateChange = { s in
            switch s {
            case .connected, .unavailable:
                final = s
                ready.signal()
            default:
                break
            }
        }
        client.start()
        // onStateChange is delivered on the main queue, so it cannot be awaited from the main
        // thread; the CLI path runs this on a background thread while main spins its run loop.
        if ready.wait(timeout: .now() + 20) == .timedOut {
            client.stop()
            return SelfTestResult(name: name, status: .fail, detail: "no state after 20 s")
        }
        defer { client.stop() }
        switch final {
        case .connected(let py):
            guard let reply = client.requestSync("ping", timeout: 2.0),
                case let .response(_, result, code, _) = reply, code == nil,
                (result?["protocol"] as? NSNumber)?.intValue == BrainProtocol.version else {
                return SelfTestResult(name: name, status: .fail, detail: "second ping or protocol mismatch")
            }
            return SelfTestResult(name: name, status: .ok, detail: "python \(py)")
        case .unavailable(let why):
            return SelfTestResult(name: name, status: .fail, detail: why)
        default:
            return SelfTestResult(name: name, status: .fail, detail: "unexpected state")
        }
    }
}
