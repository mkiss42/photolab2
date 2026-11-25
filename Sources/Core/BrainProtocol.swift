// BrainProtocol.swift
// App <-> brain messages: one JSON object per line (docs/PROTOCOL.md).

import Foundation

enum BrainProtocol {
    static let version = 1

    enum Message {
        case response(id: Int, result: [String: Any]?, errorCode: String?, errorMessage: String?)
        case event(name: String, params: [String: Any])
        case invalid(String)
    }

    /// One request as bytes, newline included.
    static func encodeRequest(id: Int, method: String, params: [String: Any]) -> Data? {
        let obj: [String: Any] = ["id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(obj),
            var d = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
        d.append(10)
        return d
    }

    /// Decode one line (without its newline).
    static func decode(_ line: Data) -> Message {
        guard let any = try? JSONSerialization.jsonObject(with: line, options: []),
            let obj = any as? [String: Any] else {
            return .invalid("not a JSON object")
        }
        if let name = obj["event"] as? String {
            return .event(name: name, params: obj["params"] as? [String: Any] ?? [:])
        }
        guard let idNum = obj["id"] as? NSNumber else { return .invalid("no id and no event") }
        let id = idNum.intValue
        if let err = obj["error"] as? [String: Any] {
            return .response(id: id, result: nil,
                             errorCode: err["code"] as? String ?? "E-BRAIN-?",
                             errorMessage: err["message"] as? String ?? "")
        }
        return .response(id: id, result: obj["result"] as? [String: Any] ?? [:], errorCode: nil, errorMessage: nil)
    }
}

/// Splits a byte stream into lines. Not thread-safe; one per connection.
struct LineBuffer {
    private var pending = Data()
    static let maxLine = 16 * 1024 * 1024

    /// Add bytes; returns the complete lines (without newlines). Throws away an over-long line.
    mutating func feed(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 10) {
            let line = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            if !line.isEmpty { lines.append(line) }
        }
        if pending.count > LineBuffer.maxLine {
            pending.removeAll()
        }
        return lines
    }
}
