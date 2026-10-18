import Foundation

/// Per-store SQLite manifest (doc 10 §3).
enum Manifest {
    static let applicationID: Int32 = 0x41425347 // 'ABSG'
    static let schemaVersion = 1

    static let ddl = """
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
    CREATE TABLE IF NOT EXISTS snapshots (
      seq           INTEGER PRIMARY KEY,
      id            TEXT NOT NULL UNIQUE,
      created_at    INTEGER NOT NULL,
      trigger       TEXT NOT NULL,
      label         TEXT,
      session_key   TEXT,
      file_count    INTEGER NOT NULL,
      changed_count INTEGER NOT NULL,
      bytes_added   INTEGER NOT NULL,
      pinned        INTEGER NOT NULL DEFAULT 0,
      complete      INTEGER NOT NULL DEFAULT 1
    ) STRICT;
    CREATE TABLE IF NOT EXISTS items (
      id     INTEGER PRIMARY KEY,
      kind   INTEGER NOT NULL,
      size   INTEGER NOT NULL,
      mode   INTEGER NOT NULL,
      hash   BLOB,
      target TEXT
    ) STRICT;
    CREATE INDEX IF NOT EXISTS items_hash ON items(hash, size) WHERE hash IS NOT NULL;
    CREATE TABLE IF NOT EXISTS changes (
      path TEXT NOT NULL,
      seq  INTEGER NOT NULL,
      item INTEGER,
      PRIMARY KEY (path, seq)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS changes_seq ON changes(seq);
    CREATE INDEX IF NOT EXISTS changes_item ON changes(item) WHERE item IS NOT NULL;
    CREATE TABLE IF NOT EXISTS current (
      path     TEXT PRIMARY KEY,
      item     INTEGER NOT NULL,
      size     INTEGER NOT NULL,
      mtime_ns INTEGER NOT NULL,
      ctime_ns INTEGER NOT NULL,
      ino      INTEGER NOT NULL,
      mode     INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID;
    """
}

/// An item row: one captured version of a file or symlink.
struct ItemRow: Equatable, Sendable {
    let id: Int64
    let kind: Int64      // 0 file, 1 symlink
    let size: Int64
    let mode: Int64      // permission bits
    let hash: Data?
    let target: String?

    /// Same content and mode (ids may differ when hashes are unknown).
    func sameContent(as other: ItemRow) -> Bool {
        if id == other.id { return true }
        guard kind == other.kind, mode == other.mode, size == other.size else { return false }
        if kind == 1 { return target == other.target }
        if let a = hash, let b = other.hash { return a == b }
        return false
    }
}

struct CurrentRow: Sendable {
    let item: ItemRow
    let key: StatKey
}
