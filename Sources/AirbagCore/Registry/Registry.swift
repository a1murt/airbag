import Foundation
import SQLite3

public enum RegistryError: Error, CustomStringConvertible {
    case schemaNewer(found: Int, supported: Int)
    case foreignFile(String)
    case notAllowable(String)
    public var description: String {
        switch self {
        case .schemaNewer(let f, let s): return "registry schema \(f) is newer than this build supports (\(s)); update Airbag"
        case .foreignFile(let p): return "\(p) is not an Airbag registry"
        case .notAllowable(let d): return d == "deny"
            ? "this command was blocked by a hard rule; allowing it once is not possible (turn the rule off in Guard if you really need it)"
            : "this entry cannot be allowed once (decision: \(d)); the agent's own prompt handles it"
        }
    }
}

/// Connection to `registry.sqlite`, shared by the CLI (short-lived) and the app (long-lived).
public final class Registry {
    public enum Role: String, Sendable { case cli, app }

    public let db: SQLiteConnection
    public let role: Role
    public let paths: AirbagPaths

    public init(paths: AirbagPaths, role: Role, busyTimeoutMs: Int32? = nil) throws {
        try paths.prepare()
        self.paths = paths
        self.role = role
        let path = paths.registry.path
        let timeout = busyTimeoutMs ?? (role == .cli ? 300 : 5000)
        do {
            db = try Registry.openChecked(path: path, busyTimeoutMs: timeout)
        } catch let e as SQLiteError where e.isCorrupt {
            Registry.moveAside(path, suffix: "corrupt")
            db = try Registry.openChecked(path: path, busyTimeoutMs: timeout)
        } catch RegistryError.foreignFile {
            Registry.moveAside(path, suffix: "foreign")
            db = try Registry.openChecked(path: path, busyTimeoutMs: timeout)
        }
        try configure()
        try migrate()
        _ = chmod(path, 0o600)
    }

    /// Earlier versions registered the home folder as a project when it holds a dotfiles repository; such rows only
    /// mislead the radar and the timeline. Missing roots (an unmounted volume) are left alone.
    public func archiveSystemOrHomeProjects(nowMs: Int64 = Clock.nowMsInt()) {
        let rows = (try? db.all("SELECT id, root_path FROM projects WHERE archived_at IS NULL") { ($0.text(0), $0.text(1)) }) ?? []
        for (id, root) in rows where SnapshotStore.isSystemOrHomeFolder(root) {
            try? db.run("UPDATE projects SET archived_at = ? WHERE id = ?", [nowMs, id])
        }
    }

    private static func openChecked(path: String, busyTimeoutMs: Int32) throws -> SQLiteConnection {
        let conn = try SQLiteConnection(path: path, busyTimeoutMs: busyTimeoutMs)
        let appID = try conn.scalarInt("PRAGMA application_id") ?? 0
        let version = try conn.scalarInt("PRAGMA user_version") ?? 0
        let tables = try conn.scalarInt("SELECT count(*) FROM sqlite_master") ?? 0
        if appID != Int64(RegistrySchema.applicationID) && (version != 0 || tables != 0) {
            throw RegistryError.foreignFile(path)
        }
        return conn
    }

    private static func moveAside(_ path: String, suffix: String) {
        let stamp = Clock.nowMs()
        for ext in ["", "-wal", "-shm"] {
            _ = rename(path + ext, "\(path).\(suffix)-\(stamp)\(ext)")
        }
        Log.shared.error("registry \(path) moved aside (\(suffix))")
    }

    private func configure() throws {
        try db.execute("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        PRAGMA temp_store = MEMORY;
        """)
        if role == .cli { try db.execute("PRAGMA wal_autocheckpoint = 0;") }
    }

    public var schemaVersion: Int { Int((try? db.scalarInt("PRAGMA user_version")) ?? 0) }

    private func migrate() throws {
        let latest = RegistrySchema.latestVersion
        let current = schemaVersion
        if current > latest { throw RegistryError.schemaNewer(found: current, supported: latest) }
        guard current < latest else { return }
        try db.transaction(.immediate) {
            let now = schemaVersion // another process may have migrated meanwhile
            if now > latest { throw RegistryError.schemaNewer(found: now, supported: latest) }
            for m in RegistrySchema.migrations where m.version > now {
                try db.execute(m.sql)
                try db.execute("PRAGMA user_version = \(m.version)")
                try db.run("INSERT INTO schema_migrations(version, applied_at, applied_by) VALUES (?,?,?)",
                           [m.version, Clock.nowMsInt(), "\(role.rawValue) \(AirbagVersion.marketing)"])
            }
            try db.execute("PRAGMA application_id = \(RegistrySchema.applicationID)")
        }
    }

    /// Passive WAL checkpoint when the WAL file exceeds `thresholdBytes`. Never blocks writers.
    public func checkpointIfLarge(thresholdBytes: Int64) {
        var st = stat()
        guard stat(paths.registry.path + "-wal", &st) == 0, st.st_size > thresholdBytes else { return }
        try? db.execute("PRAGMA wal_checkpoint(PASSIVE)")
    }

    // MARK: settings (JSON values)

    public func setting<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let text = try? db.scalarText("SELECT value FROM settings WHERE key = ?", [key]),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func setting<T: Decodable>(_ key: String, default value: T) -> T { setting(key, as: T.self) ?? value }

    public func setSetting<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try db.run("""
        INSERT INTO settings(key, value, updated_at) VALUES (?,?,?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        """, [key, String(decoding: data, as: UTF8.self), Clock.nowMsInt()])
    }
}
