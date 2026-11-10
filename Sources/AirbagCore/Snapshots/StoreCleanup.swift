import Foundation

/// Stores that outlive their folder (ADR-040). A project's snapshots are what brings a deleted folder back, so a
/// store is kept for a while after its root is gone: 30 days, or 3 for places where folders come and go (temporary
/// folders, agent worktrees, app data under ~/Library). A pinned snapshot keeps its store for good, and so does a root
/// on a volume that is not mounted. Stores of folders Airbag refuses as roots today, made before it refused them, are
/// never deleted on their own while the folder exists: `airbag cleanup` removes them.
public enum StoreCleanup {
    public static let graceMs: Int64 = 30 * 86_400_000
    public static let ephemeralGraceMs: Int64 = 3 * 86_400_000

    public struct Candidate: Sendable, Equatable {
        public enum Reason: String, Sendable {
            /// The folder is one Airbag never snapshots (ADR-032, ADR-036); its store was made before that.
            case refused
            /// The folder no longer exists.
            case missing
        }
        public let location: StoreLocation
        public let reason: Reason
        /// When the folder was first seen missing (nil until retention has run once since).
        public let missingSince: Int64?
        public let pinned: Int
        /// Retention deletes it on its own now: a missing folder whose grace period has passed, nothing pinned.
        public let due: Bool
    }

    /// Folders that come and go: a store left behind by one is worth keeping only briefly.
    public static func isEphemeral(_ root: String, home homeDirectory: String = NSHomeDirectory()) -> Bool {
        let home = FileSystem.canonicalPath(homeDirectory) ?? homeDirectory
        if ["/private/tmp/", "/tmp/", "/private/var/", home + "/Library/"].contains(where: root.hasPrefix) { return true }
        return Exclusions.worktreeFolders.contains { root.contains("/" + $0 + "/") }
    }

    /// The root is on a volume that is not mounted (an unplugged disk): its folder is not gone.
    static func isOffline(_ root: String) -> Bool {
        let parts = root.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1])
    }

    static func markerPath(_ loc: StoreLocation) -> String { loc.directory + "/missing-since" }

    static func missingSince(_ loc: StoreLocation) -> Int64? {
        (try? String(contentsOfFile: markerPath(loc), encoding: .utf8)).flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Pinned snapshots in a store, read from its manifest without opening the store (a refused root's cannot be opened).
    static func pinnedCount(_ loc: StoreLocation) -> Int {
        guard let db = try? SQLiteConnection(path: loc.directory + "/manifest.sqlite", readOnly: true) else { return 0 }
        return Int((try? db.scalarInt("SELECT count(*) FROM snapshots WHERE pinned = 1")) ?? 0)
    }

    /// Every store Airbag no longer uses, without changing anything.
    public static func candidates(paths: AirbagPaths = .resolve(), nowMs: Int64 = Clock.nowMsInt(), home: String = NSHomeDirectory()) -> [Candidate] {
        SnapshotStore.allStores(paths: paths).compactMap { loc in
            if loc.rootExists {
                do { _ = try SnapshotStore.validateRoot(loc.root, paths: paths); return nil } catch SnapshotError.unsafeRoot {} catch { return nil }
                return Candidate(location: loc, reason: .refused, missingSince: nil, pinned: pinnedCount(loc), due: false)
            }
            if isOffline(loc.root) { return nil }
            let since = missingSince(loc), pinned = pinnedCount(loc)
            let grace = isEphemeral(loc.root, home: home) ? ephemeralGraceMs : graceMs
            return Candidate(location: loc, reason: .missing, missingSince: since, pinned: pinned,
                             due: pinned == 0 && since.map { nowMs - $0 >= grace } == true)
        }
    }

    /// Run by retention: notes since when each missing folder has been gone, forgets that when a folder is back, and
    /// deletes the stores that are due. Returns how many it deleted and the bytes that freed.
    @discardableResult
    public static func sweep(paths: AirbagPaths = .resolve(), nowMs: Int64 = Clock.nowMsInt(), home: String = NSHomeDirectory(),
                             registry: Registry? = nil) -> (stores: Int, bytes: Int64) {
        var deleted = 0
        var bytes: Int64 = 0
        for loc in SnapshotStore.allStores(paths: paths) {
            let marker = markerPath(loc)
            if loc.rootExists || isOffline(loc.root) { unlink(marker); continue }
            if missingSince(loc) == nil { try? FileSystem.writeAtomically(Data(String(nowMs).utf8), to: marker, mode: 0o600) }
        }
        for c in candidates(paths: paths, nowMs: nowMs, home: home) where c.due {
            if let freed = try? delete(c.location, registry: registry) {
                deleted += 1
                bytes += freed
                Log.shared.info("store of \(c.location.root) deleted: the folder has been gone since \(c.missingSince ?? 0)")
            }
        }
        return (deleted, bytes)
    }

    /// Deletes one store, waiting for nothing: a store in use is left for the next run. Returns the bytes it took.
    @discardableResult
    public static func delete(_ loc: StoreLocation, registry: Registry? = nil) throws -> Int64 {
        let lock = StoreLock(path: loc.directory + "/lock")
        guard lock.acquire(waitMs: 0) else { throw SnapshotError.busy }
        defer { lock.release() }
        let bytes = directoryBytes(loc.directory)
        try FileManager.default.removeItem(atPath: loc.directory)
        registry?.reconcileSnapshots(rootID: SnapshotStore.rootID(for: loc.root), existing: [])
        return bytes
    }

    /// Bytes a directory takes on disk.
    public static func directoryBytes(_ path: String) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [key]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en { total += Int64((try? url.resourceValues(forKeys: [key]).totalFileAllocatedSize) ?? 0) }
        return total
    }
}
