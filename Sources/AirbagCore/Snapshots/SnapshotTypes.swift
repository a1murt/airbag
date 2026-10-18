import Foundation

public enum SnapshotTrigger: String, Sendable, Codable, CaseIterable {
    case preCommand = "pre_command"
    case postCommand = "post_command"
    case fsevents
    case manual
    case preRestore = "pre_restore"
    case postRestore = "post_restore"
    case initial
}

public struct SnapshotRequest: Sendable {
    public var trigger: SnapshotTrigger
    public var label: String?
    public var sessionKey: String?
    /// Monotonic deadline (`Clock.monotonicNs()` based). When reached, the walk stops and the snapshot is
    /// committed as incomplete.
    public var deadlineNs: UInt64?
    /// How long to wait for the store lock before giving up with `.busy`.
    public var lockWaitMs: Int
    /// Create a snapshot even when nothing changed.
    public var force: Bool
    /// Restores take their undo snapshot even when the disk is nearly full (refused only below 100 MB).
    public var ignoreLowDiskFloor = false

    public init(trigger: SnapshotTrigger, label: String? = nil, sessionKey: String? = nil,
                deadlineNs: UInt64? = nil, lockWaitMs: Int = 1000, force: Bool = false) {
        self.trigger = trigger; self.label = label; self.sessionKey = sessionKey
        self.deadlineNs = deadlineNs; self.lockWaitMs = lockWaitMs; self.force = force
    }
}

public struct SnapshotInfo: Sendable, Identifiable, Equatable, Codable {
    public let id: String
    public let seq: Int64
    public let createdAt: Int64
    public let trigger: SnapshotTrigger
    public let label: String?
    public let sessionKey: String?
    public let fileCount: Int
    public let changedCount: Int
    public let bytesAdded: Int64
    public let pinned: Bool
    public let complete: Bool
}

public struct SnapshotStats: Sendable, Equatable, Codable {
    public init() {}
    public var walked = 0
    public var captured = 0          // new objects written
    public var deduplicated = 0      // changed stat, identical content
    public var tombstones = 0
    public var skippedLarge = 0
    public var errors = 0
    public var durationMs = 0
}

public enum SnapshotOutcome: Sendable {
    case created(SnapshotInfo, SnapshotStats)
    case unchanged(latest: SnapshotInfo?, SnapshotStats)
    case busy
    case lowDisk(availableBytes: Int64)
    case failed(String)

    public var snapshot: SnapshotInfo? {
        switch self {
        case .created(let s, _): return s
        case .unchanged(let s, _): return s
        default: return nil
        }
    }
}

public enum ChangeStatus: String, Sendable, Codable { case added, modified, deleted, typeChanged = "type_changed" }

public struct FileChange: Sendable, Equatable, Codable {
    public let path: String
    public let status: ChangeStatus
    public let oldSize: Int64?
    public let newSize: Int64?
}

public enum RestoreScope: Sendable, Equatable {
    case root
    case paths([String])
}

public struct RestoreReport: Sendable, Codable {
    public init() {}
    public var restored: [String] = []
    public var movedAside: [String] = []
    public var conflicts: [String] = []
    public var failed: [String] = []
    /// Snapshot taken right before the restore: restoring to it undoes the restore.
    public var undoSnapshotId: String?
    public var postSnapshotId: String?
    public var asideDirectory: String?
}

public struct RetentionPolicy: Sendable {
    public var maxAgeMs: Int64
    public var keepNewest: Int
    /// Optional per-store byte budget on captured object bytes; oldest unpinned snapshots beyond `keepNewest`
    /// are deleted until under budget.
    public var maxBytes: Int64?

    public init(maxAgeDays: Int = 7, keepNewest: Int = 20, maxBytes: Int64? = nil) {
        self.maxAgeMs = Int64(maxAgeDays) * 86_400_000
        self.keepNewest = keepNewest
        self.maxBytes = maxBytes
    }
}

public struct PruneReport: Sendable, Codable {
    public init() {}
    public var deletedSnapshots = 0
    public var deletedChanges = 0
    public var deletedObjects = 0
    public var freedBytes: Int64 = 0
}

public struct StoreUsage: Sendable, Codable {
    public init() {}
    public var snapshots = 0
    public var objects = 0
    public var objectBytes: Int64 = 0
    public var trackedFiles = 0
}

public enum SnapshotError: Error, CustomStringConvertible, Sendable {
    case unsafeRoot(String)
    case rootMissing(String)
    case notFound(String)
    case busy
    case io(String)

    public var description: String {
        switch self {
        case .unsafeRoot(let p): return "refusing to snapshot \(p): too broad (home, system or Airbag's own directory)"
        case .rootMissing(let p): return "root \(p) does not exist or is not a directory"
        case .notFound(let id): return "snapshot \(id) not found"
        case .busy: return "the snapshot store is busy (another snapshot or restore is running)"
        case .io(let m): return m
        }
    }
}

public struct StoreLocation: Sendable, Equatable, Codable {
    public let directory: String
    public let root: String
    public let rootExists: Bool
}

/// What a restore would do, computed against the live tree without changing anything.
public struct RestorePlan: Sendable, Equatable {
    public var write: [String] = []      // files that will be put back or overwritten
    public var moveAside: [String] = []  // files created after the snapshot (moved into the store, not deleted)
    public var complete = true           // the target snapshot is complete (otherwise nothing is moved aside)
    public init() {}
    public var isEmpty: Bool { write.isEmpty && moveAside.isEmpty }
}
