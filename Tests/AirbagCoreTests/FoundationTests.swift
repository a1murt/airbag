import Foundation
import Testing
@testable import AirbagCore

@Suite struct ULIDTests {
    @Test func formatAndMonotonic() {
        var prev = ""
        for _ in 0..<5000 {
            let u = ULID.make()
            #expect(u.count == 26)
            #expect(u > prev)
            prev = u
        }
    }

    @Test func timestampRoundTrip() {
        let ms: UInt64 = 1_760_000_000_123
        let u = ULID.make(nowMs: ms + 10_000_000) // far future keeps this independent of other tests
        #expect(ULID.timestampMs(u) == ms + 10_000_000)
        #expect(ULID.encode(ms: 0, high: 0, low: 0) == "00000000000000000000000000")
        #expect(ULID.encode(ms: 0xFFFF_FFFF_FFFF, high: .max, low: .max) == "7ZZZZZZZZZZZZZZZZZZZZZZZZZ")
    }
}

@Suite struct HashingTests {
    @Test func knownVector() {
        #expect(Hashing.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func fileHashMatchesDataHash() throws {
        let dir = TempDir("hash"); defer { dir.cleanup() }
        let big = String(repeating: "airbag-", count: 400_000) // ~2.8 MB, crosses the 1 MiB read buffer
        let p = dir.write("f.txt", big)
        #expect(Hashing.sha256(fileAtPath: p) == Hashing.sha256(big))
        #expect(Hashing.sha256(fileAtPath: dir.sub("missing")) == nil)
    }
}

@Suite struct FileSystemTests {
    @Test func canonicalPathResolvesSymlinksAndTmp() throws {
        let dir = TempDir("fs"); defer { dir.cleanup() }
        try FileManager.default.createDirectory(atPath: dir.sub("real/inner"), withIntermediateDirectories: true)
        symlink(dir.sub("real"), dir.sub("link"))
        #expect(FileSystem.canonicalPath(dir.sub("link/inner")) == dir.sub("real/inner"))
        #expect(FileSystem.canonicalPath("/tmp") == "/private/tmp")
        #expect(FileSystem.canonicalPath(dir.sub("nope")) == nil)
    }

    @Test func atomicWriteKeepsMode() throws {
        let dir = TempDir("fs"); defer { dir.cleanup() }
        let p = dir.write("settings.json", "{}", mode: 0o600)
        try FileSystem.writeAtomically(Data("{\"a\":1}".utf8), to: p)
        var st = stat(); lstat(p, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(dir.read("settings.json") == "{\"a\":1}")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func ensureDirectoryAppliesMode() throws {
        let dir = TempDir("fs"); defer { dir.cleanup() }
        let p = dir.sub("a/b/c")
        try FileSystem.ensureDirectory(p, mode: 0o700)
        var st = stat(); stat(p, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        chmod(p, 0o755)
        try FileSystem.ensureDirectory(p, mode: 0o700)
        stat(p, &st)
        #expect(st.st_mode & 0o777 == 0o700)
    }
}

@Suite struct SQLiteTests {
    @Test func bindQueryAndTypes() throws {
        let dir = TempDir("sql"); defer { dir.cleanup() }
        let db = try SQLiteConnection(path: dir.sub("t.sqlite"))
        try db.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT) STRICT")
        try db.run("INSERT INTO t VALUES (?,?,?,?,?)", [Int64(42), 1.5, "héllo", Data([0, 1, 2]), String?.none])
        let row = try db.first("SELECT i, r, s, b, n FROM t") { r in
            (r.int(0), r.double(1), r.text(2), r.blob(3), r.textOrNil(4))
        }
        #expect(row?.0 == 42)
        #expect(row?.1 == 1.5)
        #expect(row?.2 == "héllo")
        #expect(row?.3 == Data([0, 1, 2]))
        #expect(row?.4 == nil)
        #expect(throws: SQLiteError.self) { try db.run("INSERT INTO t(i) VALUES (?)", []) }
    }

    @Test func transactionsAndSavepoints() throws {
        let dir = TempDir("sql"); defer { dir.cleanup() }
        let db = try SQLiteConnection(path: dir.sub("t.sqlite"))
        try db.execute("CREATE TABLE t (v INTEGER)")
        struct Boom: Error {}
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            _ = try? db.transaction { () throws -> Void in
                try db.run("INSERT INTO t VALUES (2)")
                throw Boom()
            }
            try db.run("INSERT INTO t VALUES (3)")
        }
        #expect(try db.all("SELECT v FROM t ORDER BY v") { $0.int(0) } == [1, 3])
        #expect(throws: Boom.self) {
            try db.transaction { try db.run("INSERT INTO t VALUES (4)"); throw Boom() }
        }
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 2)
        #expect(!db.isInTransaction)
    }

    @Test func concurrentWritersDoNotFail() throws {
        let dir = TempDir("sql"); defer { dir.cleanup() }
        let path = dir.sub("c.sqlite")
        let setup = try SQLiteConnection(path: path)
        try setup.execute("PRAGMA journal_mode=WAL; CREATE TABLE t (who INTEGER, n INTEGER)")
        let errors = Counter()
        DispatchQueue.concurrentPerform(iterations: 2) { who in
            guard let db = try? SQLiteConnection(path: path, busyTimeoutMs: 5000) else { errors.add(); return }
            for n in 0..<300 {
                do { try db.transaction { try db.run("INSERT INTO t VALUES (?,?)", [who, n]) } } catch { errors.add() }
            }
        }
        #expect(errors.value == 0)
        #expect(try setup.scalarInt("SELECT count(*) FROM t") == 600)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct RegistryTests {
    @Test func migratesOnceAndIsIdempotent() throws {
        let dir = TempDir("reg"); defer { dir.cleanup() }
        let paths = AirbagPaths(home: dir.url.appendingPathComponent("home"))
        do {
            let r = try Registry(paths: paths, role: .cli)
            #expect(r.schemaVersion == RegistrySchema.latestVersion)
            try r.setSetting("hook.snapshotDeadlineMs", 1500)
        }
        let r2 = try Registry(paths: paths, role: .app)
        #expect(try r2.db.scalarInt("SELECT count(*) FROM schema_migrations") == 1)
        #expect(r2.setting("hook.snapshotDeadlineMs", default: 0) == 1500)
        #expect(r2.setting("missing.key", default: "x") == "x")
        #expect(try r2.db.scalarText("PRAGMA journal_mode") == "wal")
        var st = stat(); stat(paths.home.path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        stat(paths.registry.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
    }

    @Test func foreignFileIsMovedAside() throws {
        let dir = TempDir("reg"); defer { dir.cleanup() }
        let paths = AirbagPaths(home: dir.url.appendingPathComponent("home"))
        try paths.prepare()
        let foreign = try SQLiteConnection(path: paths.registry.path)
        try foreign.execute("CREATE TABLE other (x)")
        foreign.close()
        let r = try Registry(paths: paths, role: .cli)
        #expect(r.schemaVersion == RegistrySchema.latestVersion)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.home.path)
        #expect(names.contains { $0.hasPrefix("registry.sqlite.foreign-") })
    }

    @Test func schemaHasExpectedTables() throws {
        let dir = TempDir("reg"); defer { dir.cleanup() }
        let r = try Registry(paths: AirbagPaths(home: dir.url), role: .cli)
        let tables = Set(try r.db.all("SELECT name FROM sqlite_master WHERE type='table'") { $0.text(0) })
        for t in ["sessions", "session_pids", "processes", "listeners", "snapshots", "events", "guard_log", "allow_tokens", "projects", "worktrees", "agents", "settings"] {
            #expect(tables.contains(t), "missing table \(t)")
        }
    }
}
