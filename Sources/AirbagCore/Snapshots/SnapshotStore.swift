import Darwin
import Foundation

/// One snapshot store per root (doc 10). Not thread-safe; cross-process safe through the store lock.
public final class SnapshotStore {
    public let root: String
    public let rootID: String
    public let directory: String
    public var exclusions: Exclusions
    /// Root and store live on the same volume, so captures are APFS clones rather than copies.
    public let cloneCapable: Bool

    let db: SQLiteConnection
    let lock: StoreLock
    /// Test seam: called right before a path is replaced or moved during a restore.
    var beforeApplyHook: ((String) -> Void)?
    static let hashLimit: Int64 = 8 << 20
    static let breadcrumbXattr = "dev.airbag.path"

    var objectsDir: String { directory + "/objects" }
    var tmpDir: String { directory + "/tmp" }
    var asideDir: String { directory + "/aside" }

    // MARK: opening

    /// Stable store key for a canonical root path.
    public static func rootID(for canonicalRoot: String) -> String {
        String(Hashing.hex(Hashing.sha256(canonicalRoot)).prefix(32))
    }

    /// Canonicalises `path` and refuses roots that are too broad to snapshot.
    public static func validateRoot(_ path: String, paths: AirbagPaths = .resolve()) throws -> String {
        guard let canonical = FileSystem.canonicalPath(path) else { throw SnapshotError.rootMissing(path) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDir), isDir.boolValue else {
            throw SnapshotError.rootMissing(path)
        }
        let home = FileSystem.canonicalPath(NSHomeDirectory()) ?? NSHomeDirectory()
        let forbidden: Set<String> = ["/", "/Users", "/System", "/Library", "/Applications", "/private", "/Volumes",
                                      "/usr", "/bin", "/sbin", "/opt", "/private/var", "/private/tmp", "/private/etc",
                                      home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads"]
        if forbidden.contains(canonical) { throw SnapshotError.unsafeRoot(canonical) }
        let airbagHome = FileSystem.canonicalPath(paths.home.path) ?? paths.home.path
        if airbagHome == canonical || airbagHome.hasPrefix(canonical + "/") || canonical.hasPrefix(airbagHome + "/") {
            throw SnapshotError.unsafeRoot(canonical)
        }
        return canonical
    }

    public static func storeDirectory(forCanonicalRoot root: String, paths: AirbagPaths = .resolve()) -> String {
        paths.stores.appendingPathComponent(rootID(for: root)).path
    }

    public static func storeExists(root: String, paths: AirbagPaths = .resolve()) -> Bool {
        guard let canonical = FileSystem.canonicalPath(root) else { return false }
        return FileManager.default.fileExists(atPath: storeDirectory(forCanonicalRoot: canonical, paths: paths) + "/manifest.sqlite")
    }

    public static func open(root: String, paths: AirbagPaths = .resolve(), exclusions: Exclusions? = nil,
                            create: Bool = true, recreateMissingRoot: Bool = false, allowMissingRoot: Bool = false,
                            busyTimeoutMs: Int32 = 5000) throws -> SnapshotStore {
        let canonical: String
        if FileSystem.canonicalPath(root) == nil, allowMissingRoot, !recreateMissingRoot {
            // The project folder is gone; open its store as it is (for listing, pruning, diffs). Nothing is created.
            let resolved = FileSystem.resolvedPath(root)
            let dir = storeDirectory(forCanonicalRoot: resolved, paths: paths)
            guard FileManager.default.fileExists(atPath: dir + "/manifest.sqlite") else { throw SnapshotError.rootMissing(root) }
            return try SnapshotStore(root: resolved, directory: dir, exclusions: exclusions ?? .standard, busyTimeoutMs: busyTimeoutMs)
        }
        if FileSystem.canonicalPath(root) == nil, recreateMissingRoot {
            // The whole project directory is gone (e.g. `rm -rf project`). If we hold a store for it, recreate the
            // directory so it can be restored.
            let resolved = FileSystem.resolvedPath(root)
            guard FileManager.default.fileExists(atPath: storeDirectory(forCanonicalRoot: resolved, paths: paths) + "/manifest.sqlite") else {
                throw SnapshotError.rootMissing(root)
            }
            try FileSystem.ensureDirectory(resolved, mode: 0o755)
            canonical = try validateRoot(resolved, paths: paths)
        } else {
            canonical = try validateRoot(root, paths: paths)
        }
        try paths.prepare()
        let dir = storeDirectory(forCanonicalRoot: canonical, paths: paths)
        let manifest = dir + "/manifest.sqlite"
        if !create && !FileManager.default.fileExists(atPath: manifest) { throw SnapshotError.notFound("store for \(canonical)") }
        for d in [dir, dir + "/objects", dir + "/tmp", dir + "/aside"] { try FileSystem.ensureDirectory(d, mode: 0o700) }
        return try SnapshotStore(root: canonical, directory: dir, exclusions: exclusions ?? .standard, busyTimeoutMs: busyTimeoutMs)
    }

    /// Every store on disk with the root it belongs to (read from store.json).
    public static func allStores(paths: AirbagPaths = .resolve()) -> [StoreLocation] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.stores.path) else { return [] }
        return names.sorted().compactMap { name in
            let dir = paths.stores.appendingPathComponent(name).path
            guard let data = fm.contents(atPath: dir + "/store.json"), let obj = JSONObject.parse(data),
                  let root = obj.string("root") else { return nil }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
            return StoreLocation(directory: dir, root: root, rootExists: exists)
        }
    }

    private init(root: String, directory: String, exclusions: Exclusions, busyTimeoutMs: Int32 = 5000) throws {
        self.root = root
        self.rootID = SnapshotStore.rootID(for: root)
        self.directory = directory
        let same = FileSystem.deviceID(root) == FileSystem.deviceID(directory)
        self.cloneCapable = same
        var ex = exclusions
        if !same { ex.maxFileBytes = min(ex.maxFileBytes, 20 << 20) }
        self.exclusions = ex
        self.lock = StoreLock(path: directory + "/lock")
        self.db = try SQLiteConnection(path: directory + "/manifest.sqlite", busyTimeoutMs: busyTimeoutMs)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
        try db.execute(Manifest.ddl)
        if (try db.scalarInt("PRAGMA application_id")) != Int64(Manifest.applicationID) {
            try db.execute("PRAGMA application_id = \(Manifest.applicationID); PRAGMA user_version = \(Manifest.schemaVersion);")
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('root', ?), ('created_at', ?)", [root, String(Clock.nowMs())])
            let meta: [String: Any] = ["schema": 1, "root": root, "created_at": Clock.nowMs(), "mode": same ? "clone" : "copy"]
            try FileSystem.writeAtomically(Data(JSONOutput.string(meta, pretty: true).utf8), to: directory + "/store.json", mode: 0o600)
        }
        for f in ["/manifest.sqlite", "/manifest.sqlite-wal", "/manifest.sqlite-shm"] { _ = chmod(directory + f, 0o600) }
    }

    func absolute(_ rel: String) -> String { root + "/" + rel }

    func objectPath(_ id: Int64) -> String {
        let hex = String(format: "%016llx", UInt64(bitPattern: id))
        return "\(objectsDir)/\(hex.prefix(2))/\(hex)"
    }

    // MARK: queries

    static func info(from r: SQLRow) -> SnapshotInfo {
        SnapshotInfo(id: r.text(1), seq: r.int(0), createdAt: r.int(2),
                     trigger: SnapshotTrigger(rawValue: r.text(3)) ?? .manual, label: r.textOrNil(4),
                     sessionKey: r.textOrNil(5), fileCount: Int(r.int(6)), changedCount: Int(r.int(7)),
                     bytesAdded: r.int(8), pinned: r.bool(9), complete: r.bool(10))
    }

    static let infoColumns = "seq, id, created_at, trigger, label, session_key, file_count, changed_count, bytes_added, pinned, complete"

    public func list(limit: Int = 100, beforeSeq: Int64? = nil) throws -> [SnapshotInfo] {
        try db.all("SELECT \(Self.infoColumns) FROM snapshots WHERE seq < ? ORDER BY seq DESC LIMIT ?",
                   [beforeSeq ?? Int64.max, limit], Self.info)
    }

    public func info(_ id: String) throws -> SnapshotInfo? {
        try db.first("SELECT \(Self.infoColumns) FROM snapshots WHERE id = ?", [id], Self.info)
    }

    public func latest() throws -> SnapshotInfo? {
        try db.first("SELECT \(Self.infoColumns) FROM snapshots ORDER BY seq DESC LIMIT 1", [], Self.info)
    }

    func requireInfo(_ id: String) throws -> SnapshotInfo {
        guard let s = try info(id) else { throw SnapshotError.notFound(id) }
        return s
    }

    static func item(from r: SQLRow, offset i: Int32) -> ItemRow {
        ItemRow(id: r.int(i), kind: r.int(i + 1), size: r.int(i + 2), mode: r.int(i + 3), hash: r.blob(i + 4), target: r.textOrNil(i + 5))
    }

    func loadCurrent() throws -> [String: CurrentRow] {
        try loadCurrentWithStrays().rows
    }

    /// `current` keyed by NFC path, plus raw rows stored under another normalisation form (older stores, or a rename
    /// between forms) that must be dropped from the table.
    func loadCurrentWithStrays() throws -> (rows: [String: CurrentRow], strays: [String]) {
        var out: [String: CurrentRow] = [:]
        var strays: [String] = []
        try db.query("""
        SELECT c.path, c.size, c.mtime_ns, c.ctime_ns, c.ino, c.mode, i.id, i.kind, i.size, i.mode, i.hash, i.target
        FROM current c JOIN items i ON i.id = c.item
        """) { r in
            let raw = r.text(0)
            let path = raw.precomposedStringWithCanonicalMapping
            if Array(raw.utf8) != Array(path.utf8) { strays.append(raw) }
            let key = StatKey(size: r.int(1), mtimeNs: r.int(2), ctimeNs: r.int(3), ino: r.int(4), mode: r.int(5))
            out[path] = CurrentRow(item: Self.item(from: r, offset: 6), key: key)
        }
        return (out, strays)
    }

    /// Full state at a snapshot: path → item.
    func state(atSeq seq: Int64) throws -> [String: ItemRow] {
        var out: [String: ItemRow] = [:]
        try db.query("""
        SELECT c.path, i.id, i.kind, i.size, i.mode, i.hash, i.target
        FROM changes c JOIN items i ON i.id = c.item
        WHERE c.seq = (SELECT max(seq) FROM changes WHERE path = c.path AND seq <= ?1)
        """, [seq]) { r in out[r.text(0).precomposedStringWithCanonicalMapping] = Self.item(from: r, offset: 1) }
        return out
    }

    /// State of one path at a snapshot (nil = absent).
    func state(of path: String, atSeq seq: Int64) throws -> ItemRow? {
        let row = try db.first("""
        SELECT c.item, i.id, i.kind, i.size, i.mode, i.hash, i.target
        FROM changes c LEFT JOIN items i ON i.id = c.item
        WHERE c.path = ? AND c.seq <= ? ORDER BY c.seq DESC LIMIT 1
        """, [path, seq]) { r -> ItemRow? in r.isNull(0) ? nil : Self.item(from: r, offset: 1) }
        return row ?? nil
    }

    func lookupItem(hash: Data, size: Int64, mode: Int64) throws -> Int64? {
        try db.scalarInt("SELECT id FROM items WHERE hash = ? AND size = ? AND mode = ? AND kind = 0 LIMIT 1", [hash, size, mode])
    }

    public func usage() throws -> StoreUsage {
        var u = StoreUsage()
        u.snapshots = Int(try db.scalarInt("SELECT count(*) FROM snapshots") ?? 0)
        u.objects = Int(try db.scalarInt("SELECT count(*) FROM items WHERE kind = 0") ?? 0)
        u.objectBytes = try db.scalarInt("SELECT coalesce(sum(size), 0) FROM items WHERE kind = 0") ?? 0
        u.trackedFiles = Int(try db.scalarInt("SELECT count(*) FROM current") ?? 0)
        return u
    }

    public func pin(_ id: String, _ on: Bool = true) throws {
        _ = try requireInfo(id)
        try db.run("UPDATE snapshots SET pinned = ? WHERE id = ?", [on, id])
    }

    // MARK: snapshot

    struct Hint { let item: ItemRow; let key: StatKey }

    public func snapshot(_ request: SnapshotRequest) -> SnapshotOutcome {
        guard lock.acquire(waitMs: request.lockWaitMs) else { return .busy }
        defer { lock.release() }
        do {
            return try snapshotLocked(request, hints: [:])
        } catch {
            Log.shared.error("snapshot \(root): \(error)")
            return .failed(String(describing: error))
        }
    }

    func cleanTmp() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) else { return }
        for n in names { unlink(tmpDir + "/" + n) }
    }

    func snapshotLocked(_ request: SnapshotRequest, hints: [String: Hint]) throws -> SnapshotOutcome {
        let start = Clock.monotonicNs()
        cleanTmp()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return .failed("project folder \(root) is missing")
        }
        var ex = exclusions
        if let avail = FileSystem.availableBytes(at: directory) {
            let floor: Int64 = request.ignoreLowDiskFloor ? 100 << 20 : 1 << 30
            if avail < floor { return .lowDisk(availableBytes: avail) }
            let total = FileSystem.totalBytes(at: directory) ?? 0
            if avail < max(2 << 30, total / 50) {
                ex.maxFileBytes = min(ex.maxFileBytes, 1 << 20)
                Log.shared.warn("low disk (\(avail) bytes free): capturing only files ≤ 1 MiB")
            }
        }
        var stats = SnapshotStats()
        var (current, strayRows) = try loadCurrentWithStrays()
        let walk = Walker.walk(root: root, exclusions: ex, deadlineNs: request.deadlineNs)
        // Paths that exist but were not captured this time: never recorded as deleted.
        var uncaptured = Set(walk.skippedLarge + walk.unreadableFiles)
        let unreadablePrefixes = walk.unreadableDirs.map { $0 + "/" }
        stats.walked = walk.entries.count
        stats.skippedLarge = walk.skippedLarge.count
        stats.errors = walk.errors

        var newItems: [ItemRow] = []
        var changeRows: [(String, Int64?)] = []
        var upserts: [(String, Int64, StatKey)] = []
        var bytesAdded: Int64 = 0
        var hashBackfills: [(Int64, Data)] = []
        var seen = Set<String>()
        seen.reserveCapacity(walk.entries.count)
        var reachedDeadline = !walk.complete

        for (index, entry) in walk.entries.enumerated() {
            if index & 63 == 0, let d = request.deadlineNs, Clock.monotonicNs() >= d {
                reachedDeadline = true
                break
            }
            let path = entry.relativePath
            seen.insert(path)
            let cur = current[path]
            if let cur, cur.key == entry.key { continue }
            if let hint = hints[path], hint.key == entry.key {
                if cur?.item.id != hint.item.id { changeRows.append((path, hint.item.id)) }
                upserts.append((path, hint.item.id, entry.key))
                current[path] = CurrentRow(item: hint.item, key: entry.key)
                continue
            }
            let abs = absolute(path)
            let perm = entry.key.permissionBits & 0o777
            if entry.key.isSymlink {
                guard let target = Walker.readLink(abs) else { seen.remove(path); stats.errors += 1; continue }
                let item: ItemRow
                if let cur, cur.item.kind == 1, cur.item.target == target {
                    item = cur.item
                } else {
                    item = ItemRow(id: newObjectID(), kind: 1, size: Int64(target.utf8.count), mode: perm, hash: nil, target: target)
                    newItems.append(item)
                    changeRows.append((path, item.id))
                }
                upserts.append((path, item.id, entry.key))
                current[path] = CurrentRow(item: item, key: entry.key)
                continue
            }
            // Regular file: clone (or copy) straight into the object store, then hash the captured bytes, which
            // cannot change under us. A crash before commit leaves an object without a row; prune sweeps it.
            var id = newObjectID()
            var dest = objectPath(id)
            var captured = false
            var captureErrno: Int32 = 0
            for _ in 0..<4 {
                let bucket = (dest as NSString).deletingLastPathComponent
                if !knownBuckets.contains(bucket) {
                    if mkdir(bucket, 0o700) != 0 && errno != EEXIST { captureErrno = errno; break }
                    knownBuckets.insert(bucket)
                }
                if capture(abs, to: dest) { captured = true; break }
                captureErrno = errno
                if captureErrno == EEXIST { id = newObjectID(); dest = objectPath(id); continue } // never touch an existing object
                unlink(dest)
                break
            }
            if !captured {
                if captureErrno == ENOENT || captureErrno == ENOTDIR { seen.remove(path) } else { stats.errors += 1; uncaptured.insert(path) }
                continue
            }
            var st = stat()
            guard lstat(dest, &st) == 0 else { unlink(dest); stats.errors += 1; continue }
            let size = Int64(st.st_size)
            // The first snapshot skips hashing (no previous version to compare with); hashes are filled lazily.
            let hash = (request.trigger != .initial && size <= Self.hashLimit) ? Hashing.sha256(fileAtPath: dest) : nil
            // Lazily backfill the previous version's hash (first snapshots skip hashing) when it could match.
            var curHash = cur?.item.hash
            if let cur, cur.item.kind == 0, curHash == nil, hash != nil, cur.item.size == size {
                curHash = Hashing.sha256(fileAtPath: objectPath(cur.item.id))
                if let ch = curHash { hashBackfills.append((cur.item.id, ch)) }
            }
            if let cur, cur.item.kind == 0, let h = hash, curHash == h, cur.item.mode == perm {
                unlink(dest)
                stats.deduplicated += 1
                upserts.append((path, cur.item.id, entry.key))
                current[path] = CurrentRow(item: cur.item, key: entry.key)
                continue
            }
            let item: ItemRow
            if let h = hash, let existing = try lookupItem(hash: h, size: size, mode: perm) {
                unlink(dest)
                stats.deduplicated += 1
                item = ItemRow(id: existing, kind: 0, size: size, mode: perm, hash: h, target: nil)
            } else {
                _ = path.withCString { p in setxattr(dest, Self.breadcrumbXattr, p, strlen(p), 0, XATTR_NOFOLLOW) }
                item = ItemRow(id: id, kind: 0, size: size, mode: perm, hash: hash, target: nil)
                newItems.append(item)
                stats.captured += 1
                bytesAdded += size
            }
            if cur?.item.id != item.id { changeRows.append((path, item.id)) }
            upserts.append((path, item.id, entry.key))
            current[path] = CurrentRow(item: item, key: entry.key)
        }

        let walkComplete = !reachedDeadline && walk.complete
        var deletes: [String] = []
        if walkComplete {
            for path in current.keys where !seen.contains(path) {
                // Present but unreadable, over the size cap or not capturable: unknown, not deleted.
                if uncaptured.contains(path) || unreadablePrefixes.contains(where: { path.hasPrefix($0) }) { continue }
                deletes.append(path)
                changeRows.append((path, nil))
            }
            stats.tombstones = deletes.count
        }
        for p in deletes { current.removeValue(forKey: p) }
        // A snapshot that missed something cannot be used to decide which files did not exist at that moment.
        let complete = walkComplete && walk.unreadableDirs.isEmpty && !uncaptured.contains(where: { p in !walk.skippedLarge.contains(p) })

        // Rows stored under another normalisation form are rewritten under their NFC key.
        if !strayRows.isEmpty {
            let upserted = Set(upserts.map(\.0))
            for raw in strayRows {
                let nfc = raw.precomposedStringWithCanonicalMapping
                if !upserted.contains(nfc), let cur = current[nfc] { upserts.append((nfc, cur.item.id, cur.key)) }
            }
        }
        let hasChanges = !changeRows.isEmpty
        let createdID = ULID.make()
        var created: SnapshotInfo?
        try db.transaction(.immediate) {
            for (id, h) in hashBackfills { try db.run("UPDATE items SET hash = ? WHERE id = ?", [h, id]) }
            for item in newItems {
                try db.run("INSERT INTO items(id, kind, size, mode, hash, target) VALUES (?,?,?,?,?,?)",
                           [item.id, item.kind, item.size, item.mode, item.hash, item.target])
            }
            for (path, itemID, key) in upserts {
                try db.run("""
                INSERT INTO current(path, item, size, mtime_ns, ctime_ns, ino, mode) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET item=excluded.item, size=excluded.size, mtime_ns=excluded.mtime_ns,
                  ctime_ns=excluded.ctime_ns, ino=excluded.ino, mode=excluded.mode
                """, [path, itemID, key.size, key.mtimeNs, key.ctimeNs, key.ino, key.mode])
            }
            for p in deletes { try db.run("DELETE FROM current WHERE path = ?", [p]) }
            for raw in strayRows { try db.run("DELETE FROM current WHERE path = ?", [raw]) }
            guard hasChanges || request.force else { return }
            let seq = (try db.scalarInt("SELECT max(seq) FROM snapshots") ?? 0) + 1
            let now = Clock.nowMsInt()
            try db.run("""
            INSERT INTO snapshots(seq, id, created_at, trigger, label, session_key, file_count, changed_count, bytes_added, pinned, complete)
            VALUES (?,?,?,?,?,?,?,?,?,0,?)
            """, [seq, createdID, now, request.trigger.rawValue, request.label, request.sessionKey,
                  current.count, changeRows.count, bytesAdded, complete])
            for (path, itemID) in changeRows {
                try db.run("INSERT INTO changes(path, seq, item) VALUES (?,?,?)", [path, seq, itemID])
            }
            created = SnapshotInfo(id: createdID, seq: seq, createdAt: now, trigger: request.trigger, label: request.label,
                                   sessionKey: request.sessionKey, fileCount: current.count, changedCount: changeRows.count,
                                   bytesAdded: bytesAdded, pinned: false, complete: complete)
        }
        stats.durationMs = Clock.elapsedMs(since: start)
        if let created { return .created(created, stats) }
        return .unchanged(latest: try latest(), stats)
    }

    func newObjectID() -> Int64 { Int64.random(in: 1...Int64.max) }

    private var knownBuckets = Set<String>()

    /// Captures one file: an APFS clone when root and store share a volume (one metadata operation, no data
    /// copied), otherwise a byte copy. Returns false with errno set on failure.
    func capture(_ source: String, to dest: String) -> Bool {
        if cloneCapable {
            if clonefile(source, dest, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 { return true }
            if errno == ENOENT || errno == ENOTDIR { return false }
        }
        return copyfile(source, dest, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)) == 0
    }

    // MARK: diff

    func status(old: ItemRow?, new: ItemRow?) -> ChangeStatus? {
        switch (old, new) {
        case (nil, nil): return nil
        case (nil, .some): return .added
        case (.some, nil): return .deleted
        case (.some(let a), .some(let b)):
            if a.sameContent(as: b) { return nil }
            return a.kind != b.kind ? .typeChanged : .modified
        }
    }

    /// Files changed by the given snapshot, compared with the previous retained snapshot.
    public func changes(in id: String) throws -> [FileChange] {
        let s = try requireInfo(id)
        let prev = try db.scalarInt("SELECT max(seq) FROM snapshots WHERE seq < ?", [s.seq]) ?? 0
        return try diff(fromSeq: prev, toSeq: s.seq)
    }

    func diff(fromSeq a: Int64, toSeq b: Int64) throws -> [FileChange] {
        let paths = try db.all("SELECT DISTINCT path FROM changes WHERE seq > ? AND seq <= ? ORDER BY path", [a, b]) { $0.text(0) }
        var out: [FileChange] = []
        for p in paths {
            let old = a > 0 ? try state(of: p, atSeq: a) : nil
            let new = try state(of: p, atSeq: b)
            if let st = status(old: old, new: new) { out.append(FileChange(path: p, status: st, oldSize: old?.size, newSize: new?.size)) }
        }
        return out
    }

    /// Changes between two snapshots, or between a snapshot and the live tree (`to == nil`).
    public func diff(from: String, to: String?) throws -> [FileChange] {
        let a = try requireInfo(from)
        if let to {
            let b = try requireInfo(to)
            return a.seq <= b.seq ? try diff(fromSeq: a.seq, toSeq: b.seq) : try diff(fromSeq: b.seq, toSeq: a.seq)
        }
        let stateA = try state(atSeq: a.seq)
        let current = try loadCurrent()
        let walk = Walker.walk(root: root, exclusions: exclusions)
        var out: [FileChange] = []
        var live = Set<String>()
        for e in walk.entries {
            live.insert(e.relativePath)
            let old = stateA[e.relativePath]
            let newItem: ItemRow
            if let cur = current[e.relativePath], cur.key == e.key {
                newItem = cur.item
            } else if e.key.isSymlink {
                newItem = ItemRow(id: -1, kind: 1, size: e.key.size, mode: e.key.permissionBits & 0o777, hash: nil,
                                  target: Walker.readLink(absolute(e.relativePath)))
            } else {
                let h = e.key.size <= Self.hashLimit ? Hashing.sha256(fileAtPath: absolute(e.relativePath)) : nil
                newItem = ItemRow(id: -1, kind: 0, size: e.key.size, mode: e.key.permissionBits & 0o777, hash: h, target: nil)
            }
            if let st = status(old: old, new: newItem) {
                out.append(FileChange(path: e.relativePath, status: st, oldSize: old?.size, newSize: newItem.size))
            }
        }
        for (p, old) in stateA where !live.contains(p) {
            out.append(FileChange(path: p, status: .deleted, oldSize: old.size, newSize: nil))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Line diff of one file between two snapshots (or snapshot → live file).
    public func fileDiff(path rawPath: String, from: String, to: String?) throws -> TextDiff {
        let path = rawPath.precomposedStringWithCanonicalMapping
        let a = try requireInfo(from)
        let oldItem = try state(of: path, atSeq: a.seq)
        let oldData = oldItem.flatMap { readItem($0) }
        let newData: Data?
        if let to {
            let b = try requireInfo(to)
            newData = try state(of: path, atSeq: b.seq).flatMap { readItem($0) }
        } else {
            newData = FileManager.default.contents(atPath: absolute(path))
        }
        return TextDiff.compute(old: oldData, new: newData)
    }

    func readItem(_ item: ItemRow) -> Data? {
        if item.kind == 1 { return item.target.map { Data($0.utf8) } }
        guard item.size <= TextDiff.maxBytes else { return Data(count: Int(TextDiff.maxBytes) + 1) }
        return FileManager.default.contents(atPath: objectPath(item.id))
    }

    /// Writes the full state of a snapshot (or of the given path prefixes) into an empty directory.
    public func export(_ id: String, to destination: String, prefixes: [String] = []) throws -> Int {
        let s = try requireInfo(id)
        let state = try state(atSeq: s.seq)
        try FileSystem.ensureDirectory(destination, mode: 0o755)
        var n = 0
        for (path, item) in state where prefixes.isEmpty || prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            let dest = destination + "/" + path
            try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try materialize(item, at: dest)
            n += 1
        }
        return n
    }

    // MARK: restore

    /// Puts one item at `dest` atomically (temp in the same directory + rename). mtime is set to now so build
    /// tools notice the change.
    func materialize(_ item: ItemRow, at dest: String) throws {
        let dir = (dest as NSString).deletingLastPathComponent
        let tmp = "\(dir)/.airbag-tmp-\(ULID.make())"
        if item.kind == 1 {
            guard let target = item.target, symlink(target, tmp) == 0 else {
                throw SnapshotError.io("symlink \(dest): \(String(cString: strerror(errno)))")
            }
        } else {
            guard copyfile(objectPath(item.id), tmp, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                let e = errno
                unlink(tmp)
                throw SnapshotError.io("copy object for \(dest): \(String(cString: strerror(e)))")
            }
            _ = chmod(tmp, mode_t(item.mode))
            _ = removexattr(tmp, Self.breadcrumbXattr, XATTR_NOFOLLOW)
            _ = utimes(tmp, nil)
        }
        if rename(tmp, dest) != 0 {
            let e = errno
            unlink(tmp)
            throw SnapshotError.io("rename into \(dest): \(String(cString: strerror(e)))")
        }
    }

    func isInScope(_ path: String, _ scope: RestoreScope) -> Bool {
        switch scope {
        case .root: return true
        case .paths(let prefixes):
            return prefixes.contains { p in
                let clean = p.hasSuffix("/") ? String(p.dropLast()) : p
                return clean.isEmpty || path == clean || path.hasPrefix(clean + "/")
            }
        }
    }

    /// Restores the given scope to the state of snapshot `id`. Never deletes: anything in the way is moved into
    /// the store's aside directory. A forced pre-restore snapshot is the undo point. Never follows a symlink out of
    /// the root. For an incomplete snapshot only the files it captured are written and nothing is moved aside.
    public func restore(to id: String, scope requested: RestoreScope, lockWaitMs: Int = 5000) throws -> RestoreReport {
        guard lock.acquire(waitMs: lockWaitMs) else { throw SnapshotError.busy }
        defer { lock.release() }
        let target = try requireInfo(id)
        let scope = normalized(requested)
        var report = RestoreReport()
        // A deleted project folder is recreated so it can be filled again.
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root, isDirectory: &isDir) { try FileSystem.ensureDirectory(root, mode: 0o755) }
        let label = "Before restoring to \(target.label ?? target.id)"
        var preRequest = SnapshotRequest(trigger: .preRestore, label: label, force: true)
        preRequest.ignoreLowDiskFloor = true
        let pre = try snapshotLocked(preRequest, hints: [:])
        if case .lowDisk(let avail) = pre { throw SnapshotError.io("only \(avail / 1_000_000) MB free: free some disk space first; nothing was changed") }
        guard let preInfo = pre.snapshot, preInfo.complete else {
            throw SnapshotError.io("could not take a complete pre-restore snapshot (some files are unreadable); nothing was changed")
        }
        report.undoSnapshotId = preInfo.id
        let current = try loadCurrent()
        let stateS = try state(atSeq: target.seq)
        // Files an incomplete snapshot actually captured (changed at its seq); others keep their current version.
        let capturedAtTarget: Set<String>? = target.complete ? nil
            : Set(try db.all("SELECT path FROM changes WHERE seq = ?", [target.seq]) { $0.text(0).precomposedStringWithCanonicalMapping })
        let restoreID = ULID.make()
        let aside = "\(asideDir)/\(restoreID)"

        var removals: [String] = []
        var writes: [String] = []
        for (p, cur) in current where isInScope(p, scope) {
            if let s = stateS[p] {
                if !s.sameContent(as: cur.item), capturedAtTarget?.contains(p) ?? true { writes.append(p) }
            } else if target.complete {
                removals.append(p)
            }
        }
        for p in stateS.keys where current[p] == nil && isInScope(p, scope) && (capturedAtTarget?.contains(p) ?? true) { writes.append(p) }

        /// Every component above `rel` is a real directory inside the root (no symlink, no file).
        func realParents(_ rel: String) -> Bool {
            var prefix = ""
            for c in rel.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(c) : prefix + "/" + c
                var st = stat()
                guard lstat(absolute(prefix), &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
            }
            return true
        }

        func moveAside(_ rel: String) throws {
            guard realParents(rel) else { throw SnapshotError.io("\(rel): a parent folder is a symlink; left untouched") }
            var dest = "\(aside)/\(rel)"
            while FileManager.default.fileExists(atPath: dest) { dest += "~" }
            try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if rename(absolute(rel), dest) != 0 {
                guard errno == EXDEV else { throw SnapshotError.io("move aside \(rel): \(String(cString: strerror(errno)))") }
                guard copyfile(absolute(rel), dest, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)) == 0 else {
                    throw SnapshotError.io("copy aside \(rel): \(String(cString: strerror(errno)))")
                }
                try FileManager.default.removeItem(atPath: absolute(rel))
            }
            report.movedAside.append(rel)
            report.asideDirectory = aside
        }

        /// Makes every parent of `rel` a real directory, moving aside a file or symlink that stands in the way.
        func ensureParents(_ rel: String) throws {
            var prefix = ""
            for c in rel.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(c) : prefix + "/" + c
                let abs = absolute(prefix)
                var st = stat()
                if lstat(abs, &st) == 0 {
                    if (st.st_mode & S_IFMT) == S_IFDIR { continue }
                    try moveAside(prefix) // a file or a symlink stands where a directory must be: never write through it
                }
                if mkdir(abs, 0o755) != 0 && errno != EEXIST {
                    throw SnapshotError.io("mkdir \(prefix): \(String(cString: strerror(errno)))")
                }
            }
        }

        func pruneEmptyParents(_ rel: String) {
            var comps = rel.split(separator: "/").dropLast()
            while !comps.isEmpty {
                if rmdir(absolute(comps.joined(separator: "/"))) != 0 { return }
                comps = comps.dropLast()
            }
        }

        for p in removals.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            beforeApplyHook?(p)
            guard realParents(p), let cur = current[p], Walker.lstatKey(absolute(p)).map({ $0.sameFile(cur.key) }) == true else {
                report.conflicts.append(p); continue
            }
            do { try moveAside(p); pruneEmptyParents(p) } catch { report.failed.append(p) }
        }

        var hints: [String: Hint] = [:]
        for p in writes.sorted() {
            guard let item = stateS[p] else { continue }
            beforeApplyHook?(p)
            do {
                if let cur = current[p] {
                    // Changed since the pre-restore snapshot (an agent is still writing), or reached through a symlink.
                    guard realParents(p), Walker.lstatKey(absolute(p)).map({ $0.sameFile(cur.key) }) == true else {
                        report.conflicts.append(p); continue
                    }
                } else {
                    try ensureParents(p)
                    if Walker.lstatKey(absolute(p)) != nil { try moveAside(p) } // untracked file or directory in the way
                }
                try ensureParents(p)
                if let k = Walker.lstatKey(absolute(p)), (k.mode & Int64(S_IFMT)) == Int64(S_IFDIR) { try moveAside(p) }
                try materialize(item, at: absolute(p))
                if let k = Walker.lstatKey(absolute(p)) { hints[p] = Hint(item: item, key: k) }
                report.restored.append(p)
            } catch {
                Log.shared.error("restore \(p): \(error)")
                report.failed.append(p)
            }
        }

        var postRequest = SnapshotRequest(trigger: .postRestore, label: "Restored to \(target.label ?? target.id)", force: true)
        postRequest.ignoreLowDiskFloor = true
        let post = try snapshotLocked(postRequest, hints: hints)
        report.postSnapshotId = post.snapshot?.id
        return report
    }

    func normalized(_ scope: RestoreScope) -> RestoreScope {
        if case .paths(let p) = scope { return .paths(p.map { $0.precomposedStringWithCanonicalMapping }) }
        return scope
    }

    /// Preview of `restore(to:scope:)` for the confirmation window.
    public func planRestore(to id: String, scope requested: RestoreScope) throws -> RestorePlan {
        let target = try requireInfo(id)
        let scope = normalized(requested)
        var plan = RestorePlan()
        plan.complete = target.complete
        let captured: Set<String>? = target.complete ? nil
            : Set(try db.all("SELECT path FROM changes WHERE seq = ?", [target.seq]) { $0.text(0).precomposedStringWithCanonicalMapping })
        for c in try diff(from: id, to: nil) where isInScope(c.path, scope) {
            switch c.status {
            case .added: if target.complete { plan.moveAside.append(c.path) }
            case .modified, .deleted, .typeChanged: if captured?.contains(c.path) ?? true { plan.write.append(c.path) }
            }
        }
        return plan
    }

    // MARK: retention

    public func prune(policy: RetentionPolicy, nowMs: Int64 = Clock.nowMsInt(), dryRun: Bool = false, lockWaitMs: Int = 5000) throws -> PruneReport {
        guard lock.acquire(waitMs: lockWaitMs) else { throw SnapshotError.busy }
        defer { lock.release() }
        var report = PruneReport()
        let all = try db.all("SELECT seq, created_at, pinned FROM snapshots ORDER BY seq") { (seq: $0.int(0), created: $0.int(1), pinned: $0.bool(2)) }
        guard !all.isEmpty else { return report }
        let newest = Set(all.suffix(max(1, policy.keepNewest)).map(\.seq))
        var keep = Set(all.filter { $0.pinned || newest.contains($0.seq) || $0.created >= nowMs - policy.maxAgeMs }.map(\.seq))
        var del = all.map(\.seq).filter { !keep.contains($0) }
        if dryRun { report.deletedSnapshots = del.count; return report }
        if !del.isEmpty { try deleteSnapshots(del, keep: keep, report: &report) }
        // Byte budget: deduplication lets new snapshots keep old objects alive, so the effect of deleting a snapshot is
        // only known after compaction. Delete the oldest eligible snapshots in batches and measure.
        if let budget = policy.maxBytes {
            while try usage().objectBytes > budget {
                let candidates = all.filter { keep.contains($0.seq) && !$0.pinned && !newest.contains($0.seq) }.map(\.seq)
                guard !candidates.isEmpty else { break }
                let batch = Array(candidates.prefix(max(1, candidates.count / 8)))
                keep.subtract(batch)
                del = batch
                try deleteSnapshots(del, keep: keep, report: &report)
            }
        }
        sweepOrphanObjects()
        pruneAside(olderThanMs: nowMs - policy.maxAgeMs)
        return report
    }

    /// Removes moved-aside items of restores older than the retention window (their names are restore ULIDs).
    func pruneAside(olderThanMs cutoff: Int64) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: asideDir) else { return }
        for n in names {
            guard let ts = ULID.timestampMs(n), Int64(ts) < cutoff else { continue }
            try? FileManager.default.removeItem(atPath: "\(asideDir)/\(n)")
        }
    }

    /// Deletes snapshots `del` while keeping every state in `keep` reconstructible (doc 10 §7).
    func deleteSnapshots(_ del: [Int64], keep: Set<Int64>, report: inout PruneReport) throws {
        var deadObjects: [(Int64, Int64, Int64)] = []
        try db.transaction(.immediate) {
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS prune_del(seq INTEGER PRIMARY KEY); CREATE TEMP TABLE IF NOT EXISTS prune_keep(seq INTEGER PRIMARY KEY); DELETE FROM prune_del; DELETE FROM prune_keep;")
            for s in del { try db.run("INSERT INTO prune_del VALUES (?)", [s]) }
            for s in keep { try db.run("INSERT INTO prune_keep VALUES (?)", [s]) }
            try db.run("""
            DELETE FROM changes AS c WHERE c.seq IN (SELECT seq FROM prune_del) AND EXISTS (
              SELECT 1 FROM changes c2 WHERE c2.path = c.path AND c2.seq > c.seq
                AND c2.seq <= (SELECT min(seq) FROM prune_keep WHERE seq > c.seq))
            """, cached: false)
            report.deletedChanges += db.changes
            // A tombstone that is the oldest remaining row of its path, below every retained snapshot, says nothing.
            try db.run("""
            DELETE FROM changes AS c WHERE c.item IS NULL AND c.seq < (SELECT min(seq) FROM prune_keep)
              AND NOT EXISTS (SELECT 1 FROM changes c2 WHERE c2.path = c.path AND c2.seq < c.seq)
            """, cached: false)
            report.deletedChanges += db.changes
            try db.run("DELETE FROM snapshots WHERE seq IN (SELECT seq FROM prune_del)", cached: false)
            report.deletedSnapshots += db.changes
            deadObjects = try db.all("""
            SELECT id, kind, size FROM items WHERE id NOT IN (SELECT item FROM changes WHERE item IS NOT NULL)
              AND id NOT IN (SELECT item FROM current)
            """) { ($0.int(0), $0.int(1), $0.int(2)) }
            for (id, _, _) in deadObjects { try db.run("DELETE FROM items WHERE id = ?", [id]) }
        }
        for (id, kind, size) in deadObjects where kind == 0 {
            if unlink(objectPath(id)) == 0 { report.deletedObjects += 1; report.freedBytes += size }
        }
    }

    /// Removes object files that have no item row (left behind by a crash between capture and commit).
    func sweepOrphanObjects() {
        guard let known = try? Set(db.all("SELECT id FROM items WHERE kind = 0") { $0.int(0) }) else { return }
        let fm = FileManager.default
        guard let buckets = try? fm.contentsOfDirectory(atPath: objectsDir) else { return }
        for b in buckets {
            guard let names = try? fm.contentsOfDirectory(atPath: "\(objectsDir)/\(b)") else { continue }
            for n in names {
                guard let v = UInt64(n, radix: 16) else { continue }
                if !known.contains(Int64(bitPattern: v)) { unlink("\(objectsDir)/\(b)/\(n)") }
            }
        }
    }
}
