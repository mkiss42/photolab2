// Fuzzy.swift
// "Name is similar to": finds near matches while staying sensible.
//
// Rules:
//  - Case, accents (é = e) and separators (space _ - .) are ignored.
//  - The search text is split into words; every word must appear somewhere in the name, in any order.
//  - Each word may contain a few mistakes, scaled to its length:
//        1-3 letters: no mistakes (must appear exactly)    4-6: 1    7-10: 2    11+: 3
//    A mistake is a wrong, missing or extra letter, or two neighbouring letters swapped.
//  - The match score is the total number of mistakes (0 = exact), used for the Match column.

import Foundation

enum Fuzzy {
    struct Pattern {
        let words: [[UInt32]]
        let allowed: [Int]
        var isEmpty: Bool { return words.isEmpty }
    }

    static func allowedEdits(_ length: Int) -> Int {
        if length <= 3 { return 0 }
        if length <= 6 { return 1 }
        if length <= 10 { return 2 }
        return 3
    }

    private static func isSeparator(_ v: UInt32) -> Bool {
        return v == 32 || v == 95 || v == 45 || v == 46 || v == 9
    }

    private static func isCombiningMark(_ v: UInt32) -> Bool {
        return (v >= 0x0300 && v <= 0x036F) || (v >= 0x1AB0 && v <= 0x1AFF) ||
            (v >= 0x1DC0 && v <= 0x1DFF) || (v >= 0x20D0 && v <= 0x20FF) || (v >= 0xFE20 && v <= 0xFE2F)
    }

    /// Lower-case, accents removed, separators turned into single spaces, trimmed.
    static func fold(_ s: String) -> [UInt32] {
        let decomposed = NameNorm.isASCII(s) ? s.lowercased() : s.decomposedStringWithCanonicalMapping.lowercased()
        var out: [UInt32] = []
        out.reserveCapacity(decomposed.unicodeScalars.count)
        var lastWasSpace = true
        for u in decomposed.unicodeScalars {
            let v = u.value
            if isCombiningMark(v) { continue }
            if isSeparator(v) {
                if !lastWasSpace { out.append(32) }
                lastWasSpace = true
            } else {
                out.append(v)
                lastWasSpace = false
            }
        }
        if out.last == 32 { out.removeLast() }
        return out
    }

    static func prepare(_ query: String) -> Pattern {
        let f = fold(query)
        var words: [[UInt32]] = []
        var cur: [UInt32] = []
        for v in f {
            if v == 32 {
                if !cur.isEmpty { words.append(cur) }
                cur = []
            } else {
                cur.append(v)
            }
        }
        if !cur.isEmpty { words.append(cur) }
        if words.count > 8 { words = Array(words.prefix(8)) }
        words = words.map { $0.count > 64 ? Array($0.prefix(64)) : $0 }
        return Pattern(words: words, allowed: words.map { allowedEdits($0.count) })
    }

    /// Lowest number of mistakes needed to find `p` somewhere inside `t` (edits + swaps of neighbours),
    /// or nil if it needs more than `k`.
    static func bestSubstringDistance(_ p: [UInt32], _ t: [UInt32], _ k: Int) -> Int? {
        let m = p.count
        if m == 0 { return 0 }
        if m - k > t.count { return nil }
        if k == 0 {
            // exact substring
            if m > t.count { return nil }
            var i = 0
            while i <= t.count - m {
                var j = 0
                while j < m && t[i + j] == p[j] { j += 1 }
                if j == m { return 0 }
                i += 1
            }
            return nil
        }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = [Int](repeating: 0, count: m + 1)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 0...m { prev[i] = i }
        var best = prev[m]
        for j in 1...max(1, t.count) where t.count > 0 {
            let tc = t[j - 1]
            cur[0] = 0 // a match may start anywhere in the name
            for i in 1...m {
                let pc = p[i - 1]
                var v = prev[i - 1] + (pc == tc ? 0 : 1)
                let del = prev[i] + 1
                if del < v { v = del }
                let ins = cur[i - 1] + 1
                if ins < v { v = ins }
                if i > 1 && j > 1 && pc == t[j - 2] && p[i - 2] == tc {
                    let tr = prev2[i - 2] + 1
                    if tr < v { v = tr }
                }
                cur[i] = v
            }
            if cur[m] < best { best = cur[m] }
            if best == 0 { return 0 }
            let tmp = prev2
            prev2 = prev
            prev = cur
            cur = tmp
        }
        return best <= k ? best : nil
    }

    /// Total mistakes for the whole pattern against a name, or nil if any word is too far off.
    static func distance(_ pat: Pattern, name: String) -> Int? {
        if pat.isEmpty { return 0 }
        let t = fold(name)
        var total = 0
        for (i, w) in pat.words.enumerated() {
            guard let d = bestSubstringDistance(w, t, pat.allowed[i]) else { return nil }
            total += d
        }
        return total
    }
}
