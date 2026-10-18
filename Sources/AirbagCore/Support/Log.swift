import Foundation
import os

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warn, error
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var tag: String { ["DEBUG", "INFO", "WARN", "ERROR"][rawValue] }
}

/// Minimal logger: appends lines to a rotated file (5 × 1 MB) and mirrors warnings/errors to os_log.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var fileURL: URL?
    private var osLog = Logger(subsystem: "dev.airbag", category: "general")
    public var level: LogLevel = .info
    private let maxBytes = 1_000_000
    private let keep = 5

    public func configure(file: URL?, category: String, level: LogLevel = .info) {
        lock.lock(); defer { lock.unlock() }
        fileURL = file
        osLog = Logger(subsystem: "dev.airbag", category: category)
        self.level = level
    }

    public func debug(_ message: @autoclosure () -> String) { write(.debug, message) }
    public func info(_ message: @autoclosure () -> String) { write(.info, message) }
    public func warn(_ message: @autoclosure () -> String) { write(.warn, message) }
    public func error(_ message: @autoclosure () -> String) { write(.error, message) }

    private func write(_ lvl: LogLevel, _ message: () -> String) {
        guard lvl >= level else { return }
        let text = message()
        if lvl >= .warn { osLog.log(level: lvl == .error ? .error : .default, "\(text, privacy: .public)") }
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL else { return }
        let line = "\(Log.timestamp()) \(lvl.tag) [\(getpid())] \(text)\n"
        rotateIfNeeded(url)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }

    private func rotateIfNeeded(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_size > maxBytes else { return }
        let fm = FileManager.default
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let from = url.path + ".\(i)", to = url.path + ".\(i + 1)"
            try? fm.removeItem(atPath: to)
            try? fm.moveItem(atPath: from, toPath: to)
        }
        try? fm.removeItem(atPath: url.path + ".1")
        try? fm.moveItem(atPath: url.path, toPath: url.path + ".1")
    }

    static func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var tm = tm()
        var t = tv.tv_sec
        localtime_r(&t, &tm)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec, Int(tv.tv_usec / 1000))
    }
}
