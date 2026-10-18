import Foundation

/// Locations of everything Airbag stores. `AIRBAG_HOME` overrides the root (tests, development).
public struct AirbagPaths: Sendable, Equatable {
    public let home: URL

    public init(home: URL) { self.home = home.standardizedFileURL }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> AirbagPaths {
        if let override = environment["AIRBAG_HOME"], !override.isEmpty {
            return AirbagPaths(home: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Airbag", isDirectory: true)
        return AirbagPaths(home: base)
    }

    public var registry: URL { home.appendingPathComponent("registry.sqlite") }
    /// Unix socket paths are limited to 104 bytes; a long home (AIRBAG_HOME, long user names) falls back to the per-user
    /// temporary directory, which is private to the user.
    public var socket: URL {
        let primary = home.appendingPathComponent("airbag.sock")
        if primary.path.utf8.count < 100 { return primary }
        let tag = String(Hashing.hex(Hashing.sha256(home.path)).prefix(12))
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("airbag-\(tag).sock")
    }
    public var spool: URL { home.appendingPathComponent("spool", isDirectory: true) }
    public var rules: URL { home.appendingPathComponent("rules", isDirectory: true) }
    public var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var backups: URL { home.appendingPathComponent("backups", isDirectory: true) }
    public var stores: URL { home.appendingPathComponent("stores.noindex", isDirectory: true) }

    /// Creates the directory tree with owner-only permissions and re-applies 0700 to existing directories.
    public func prepare() throws {
        for dir in [home, spool, rules, logs, backups, stores] {
            try FileSystem.ensureDirectory(dir.path, mode: 0o700)
        }
        FileSystem.excludeFromBackup(stores)
    }
}
