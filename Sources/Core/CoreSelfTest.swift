// CoreSelfTest.swift
// Self-tests for platform-independent logic. Output: "SELFTEST <name> OK|FAIL|SKIP <detail>".

import Foundation

struct SelfTestResult {
    enum Status: String { case ok = "OK", fail = "FAIL", skip = "SKIP", warn = "WARN" }
    let name: String
    let status: Status
    let detail: String

    var line: String { return "SELFTEST \(name) \(status.rawValue)" + (detail.isEmpty ? "" : " \(detail)") }
}

enum CoreSelfTest {
    static func run() -> [SelfTestResult] {
        return [protocolRoundTrip(), protocolErrorAndEvent(), lineBufferSplits(), asciiClean()]
    }

    static func protocolRoundTrip() -> SelfTestResult {
        let name = "protocol-request"
        guard let d = BrainProtocol.encodeRequest(id: 7, method: "ping", params: ["x": 1]) else {
            return SelfTestResult(name: name, status: .fail, detail: "encode failed")
        }
        guard d.last == 10 else { return SelfTestResult(name: name, status: .fail, detail: "no newline") }
        let body = d.subdata(in: d.startIndex..<(d.endIndex - 1))
        guard let obj = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any],
            (obj["id"] as? NSNumber)?.intValue == 7, obj["method"] as? String == "ping" else {
            return SelfTestResult(name: name, status: .fail, detail: "fields wrong")
        }
        return SelfTestResult(name: name, status: .ok, detail: "")
    }

    static func protocolErrorAndEvent() -> SelfTestResult {
        let name = "protocol-decode"
        let err = BrainProtocol.decode(Data("{\"id\":3,\"error\":{\"code\":\"E-BRAIN-1\",\"message\":\"x\"}}".utf8))
        guard case let .response(id, _, code, _) = err, id == 3, code == "E-BRAIN-1" else {
            return SelfTestResult(name: name, status: .fail, detail: "error response")
        }
        let ev = BrainProtocol.decode(Data("{\"event\":\"cache.updated\",\"params\":{\"a\":1}}".utf8))
        guard case let .event(evName, params) = ev, evName == "cache.updated", params["a"] != nil else {
            return SelfTestResult(name: name, status: .fail, detail: "event")
        }
        guard case .invalid = BrainProtocol.decode(Data("[1,2]".utf8)) else {
            return SelfTestResult(name: name, status: .fail, detail: "array accepted")
        }
        return SelfTestResult(name: name, status: .ok, detail: "")
    }

    static func lineBufferSplits() -> SelfTestResult {
        let name = "line-buffer"
        var b = LineBuffer()
        var lines = b.feed(Data("ab".utf8))
        lines += b.feed(Data("c\nde\n\nf".utf8))
        guard lines.count == 2,
            String(data: lines[0], encoding: .utf8) == "abc",
            String(data: lines[1], encoding: .utf8) == "de" else {
            return SelfTestResult(name: name, status: .fail, detail: "got \(lines.count) lines")
        }
        lines = b.feed(Data("\n".utf8))
        guard lines.count == 1, String(data: lines[0], encoding: .utf8) == "f" else {
            return SelfTestResult(name: name, status: .fail, detail: "tail")
        }
        return SelfTestResult(name: name, status: .ok, detail: "")
    }

    static func asciiClean() -> SelfTestResult {
        let name = "ascii-clean"
        let got = Ascii.clean("Caf\u{00E9}\nok")
        return got == "Caf? ok"
            ? SelfTestResult(name: name, status: .ok, detail: "")
            : SelfTestResult(name: name, status: .fail, detail: "got '\(got)'")
    }
}
