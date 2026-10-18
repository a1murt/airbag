import Foundation

/// Line-based diff (Myers O(ND)) with unified-diff hunks.
public struct TextDiff: Sendable, Equatable {
    public enum Kind: String, Sendable { case same, added, removed }
    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?
    }
    public struct Hunk: Sendable, Equatable {
        public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        public let lines: [Line]
        public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
    }
    public enum Summary: Sendable, Equatable {
        case text
        case identical
        case binary(oldSize: Int?, newSize: Int?)
        case tooLarge(oldSize: Int?, newSize: Int?)
    }

    public static let maxBytes: Int64 = 2 << 20
    public let summary: Summary
    public let hunks: [Hunk]
    public var addedLines: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var removedLines: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    public static func compute(old: Data?, new: Data?, context: Int = 3) -> TextDiff {
        if old == new { return TextDiff(summary: .identical, hunks: []) }
        let oldSize = old?.count, newSize = new?.count
        if (old?.count ?? 0) > Int(maxBytes) || (new?.count ?? 0) > Int(maxBytes) {
            return TextDiff(summary: .tooLarge(oldSize: oldSize, newSize: newSize), hunks: [])
        }
        func decode(_ d: Data?) -> String?? {
            guard let d else { return .some(nil) }
            if d.contains(0) { return nil }
            guard let s = String(data: d, encoding: .utf8) else { return nil }
            return .some(s)
        }
        guard let o = decode(old), let n = decode(new) else {
            return TextDiff(summary: .binary(oldSize: oldSize, newSize: newSize), hunks: [])
        }
        return TextDiff(summary: .text, hunks: hunks(old: lines(o ?? ""), new: lines(n ?? ""), context: context))
    }

    static func lines(_ s: String) -> [Substring] {
        if s.isEmpty { return [] }
        var out = s.split(separator: "\n", omittingEmptySubsequences: false)
        if out.last == "" { out.removeLast() }
        return out
    }

    /// Largest edit distance computed exactly; beyond it the changed middle is shown as one replaced block.
    static let maxEditDistance = 1500

    /// Edit script, returned as (kind, oldIndex, newIndex). Common prefix and suffix are matched first; the middle uses
    /// Myers' O(ND) algorithm with a trace of only the diagonals each step touched (O(D²) memory, not O(D·(N+M))).
    static func script(_ a: [Substring], _ b: [Substring]) -> [(Kind, Int, Int)] {
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var out: [(Kind, Int, Int)] = (0..<prefix).map { (.same, $0, $0) }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])
        let middle = myers(midA, midB) ?? (midA.indices.map { (Kind.removed, $0, 0) } + midB.indices.map { (Kind.added, midA.count, $0) })
        out += middle.map { ($0.0, $0.1 + prefix, $0.2 + prefix) }
        out += (0..<suffix).map { (.same, a.count - suffix + $0, b.count - suffix + $0) }
        return out
    }

    static func myers(_ a: [Substring], _ b: [Substring]) -> [(Kind, Int, Int)]? {
        let n = a.count, m = b.count
        if n == 0 && m == 0 { return [] }
        let limit = min(n + m, maxEditDistance)
        // v[k + off] = furthest x on diagonal k; trace[d] keeps v for diagonals -d…d only.
        let off = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var found = false
        for d in 0...limit {
            var snapshot = [Int](repeating: 0, count: 2 * d + 1)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[k - 1 + off] < v[k + 1 + off]) { x = v[k + 1 + off] } else { x = v[k - 1 + off] + 1 }
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[k + off] = x
                if x >= n && y >= m { found = true }
            }
            for k in stride(from: -d, through: d, by: 1) { snapshot[k + d] = v[k + off] }
            trace.append(snapshot)
            if found { break }
        }
        guard found else { return nil }
        var x = n, y = m
        var edits: [(Kind, Int, Int)] = []
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let k = x - y
            if d == 0 {
                while x > 0 && y > 0 { x -= 1; y -= 1; edits.append((.same, x, y)) }
                break
            }
            let prev = trace[d - 1] // diagonals -(d-1)…(d-1)
            func pv(_ kk: Int) -> Int { prev[kk + d - 1] }
            let down = k == -d || (k != d && pv(k - 1) < pv(k + 1))
            let prevK = down ? k + 1 : k - 1
            let prevX = pv(prevK)
            let prevY = prevX - prevK
            while x > prevX && y > prevY { x -= 1; y -= 1; edits.append((.same, x, y)) }
            if down { y -= 1; edits.append((.added, x, y)) } else { x -= 1; edits.append((.removed, x, y)) }
        }
        return edits.reversed()
    }

    static func hunks(old a: [Substring], new b: [Substring], context: Int) -> [Hunk] {
        let edits = script(a, b)
        guard edits.contains(where: { $0.0 != .same }) else { return [] }
        var hunks: [Hunk] = []
        var i = 0
        while i < edits.count {
            guard let firstChange = edits[i...].firstIndex(where: { $0.0 != .same }) else { break }
            let start = Swift.max(0, firstChange - context)
            var end = firstChange
            var lastChange = firstChange
            while end < edits.count {
                if edits[end].0 != .same { lastChange = end }
                if end - lastChange > 2 * context { break }
                end += 1
            }
            let stop = Swift.min(edits.count, lastChange + context + 1)
            var lines: [Line] = []
            var oldStart = 0, newStart = 0, oldCount = 0, newCount = 0
            for (idx, e) in edits[start..<stop].enumerated() {
                let (kind, x, y) = e
                if idx == 0 { oldStart = x + 1; newStart = y + 1 }
                switch kind {
                case .same: lines.append(Line(kind: .same, text: String(a[x]), oldNumber: x + 1, newNumber: y + 1)); oldCount += 1; newCount += 1
                case .removed: lines.append(Line(kind: .removed, text: String(a[x]), oldNumber: x + 1, newNumber: nil)); oldCount += 1
                case .added: lines.append(Line(kind: .added, text: String(b[y]), oldNumber: nil, newNumber: y + 1)); newCount += 1
                }
            }
            hunks.append(Hunk(oldStart: oldCount == 0 ? oldStart - 1 : oldStart, oldCount: oldCount,
                              newStart: newCount == 0 ? newStart - 1 : newStart, newCount: newCount, lines: lines))
            i = stop
        }
        return hunks
    }

    /// Unified diff text (without file headers).
    public var unified: String {
        switch summary {
        case .identical: return ""
        case .binary(let o, let n): return "Binary file changed (\(o.map(String.init) ?? "absent") → \(n.map(String.init) ?? "absent") bytes)\n"
        case .tooLarge(let o, let n): return "File too large to diff (\(o.map(String.init) ?? "absent") → \(n.map(String.init) ?? "absent") bytes)\n"
        case .text:
            var out = ""
            for h in hunks {
                out += h.header + "\n"
                for l in h.lines {
                    out += (l.kind == .same ? " " : l.kind == .added ? "+" : "-") + l.text + "\n"
                }
            }
            return out
        }
    }
}
