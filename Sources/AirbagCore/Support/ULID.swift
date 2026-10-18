import Foundation

/// Lexicographically sortable unique identifiers (https://github.com/ulid/spec), monotonic within a process.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMs: UInt64 = 0
    nonisolated(unsafe) private static var lastHigh: UInt16 = 0
    nonisolated(unsafe) private static var lastLow: UInt64 = 0

    /// A new ULID string (26 Crockford base32 characters).
    public static func make(nowMs: UInt64 = Clock.nowMs()) -> String {
        lock.lock()
        defer { lock.unlock() }
        var high: UInt16
        var low: UInt64
        var ms = nowMs
        if ms <= lastMs {
            // Same (or earlier) millisecond: increment the previous randomness to stay monotonic.
            ms = lastMs
            low = lastLow &+ 1
            high = lastHigh &+ (low == 0 ? 1 : 0)
        } else {
            var rng = SystemRandomNumberGenerator()
            high = UInt16.random(in: 0...UInt16.max, using: &rng)
            low = UInt64.random(in: 0...UInt64.max, using: &rng)
        }
        lastMs = ms; lastHigh = high; lastLow = low
        return encode(ms: ms, high: high, low: low)
    }

    static func encode(ms: UInt64, high: UInt16, low: UInt64) -> String {
        var out = [UInt8](repeating: 0, count: 26)
        // 48-bit time → 10 chars
        var t = ms & 0xFFFF_FFFF_FFFF
        for i in stride(from: 9, through: 0, by: -1) {
            out[i] = alphabet[Int(t & 31)]
            t >>= 5
        }
        // 80-bit randomness (16 high + 64 low) → 16 chars
        var lo = low
        var hi = UInt64(high)
        for i in stride(from: 25, through: 10, by: -1) {
            out[i] = alphabet[Int(lo & 31)]
            lo = (lo >> 5) | ((hi & 31) << 59)
            hi >>= 5
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Millisecond timestamp encoded in a ULID, or nil if malformed.
    public static func timestampMs(_ ulid: String) -> UInt64? {
        let chars = Array(ulid.uppercased().utf8)
        guard chars.count == 26 else { return nil }
        var t: UInt64 = 0
        for c in chars[0..<10] {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            t = (t << 5) | UInt64(v)
        }
        return t
    }
}

/// Wall-clock helpers. All persisted timestamps are milliseconds since the Unix epoch.
public enum Clock {
    public static func nowMs() -> UInt64 { UInt64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
    public static func nowMsInt() -> Int64 { Int64(nowMs()) }
    /// Monotonic nanoseconds for measuring durations.
    public static func monotonicNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    public static func elapsedMs(since startNs: UInt64) -> Int { Int((monotonicNs() &- startNs) / 1_000_000) }
}
