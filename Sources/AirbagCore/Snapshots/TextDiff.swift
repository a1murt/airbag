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

    /// Edit script via Myers' algorithm, returned as (kind, oldIndex, newIndex).
    static func script(_ a: [Substring], _ b: [Substring]) -> [(Kind, Int, Int)] {
        let n = a.count, m = b.count
        let max = n + m
        if max == 0 { return [] }
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        outer: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max]) { x = v[k + 1 + max] } else { x = v[k - 1 + max] + 1 }
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[k + max] = x
                if x >= n && y >= m { trace.append(v); break outer }
            }
        }
        // Backtrack.
        var x = n, y = m
        var edits: [(Kind, Int, Int)] = []
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let vv = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && vv[k - 1 + max] < vv[k + 1 + max])) ? k + 1 : k - 1
            let prevX = vv[prevK + max]
            let prevY = prevX - prevK
            while x > prevX && y > prevY { x -= 1; y -= 1; edits.append((.same, x, y)) }
            if d > 0 {
                if x == prevX { y -= 1; edits.append((.added, x, y)) } else { x -= 1; edits.append((.removed, x, y)) }
            }
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
