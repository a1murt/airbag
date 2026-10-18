import Foundation

public enum Retention {
    /// Applies the per-store policy to every store, then a global byte budget split across stores in proportion to
    /// their size. Stores whose project folder is gone are pruned too (their snapshots can still restore it).
    @discardableResult
    public static func run(paths: AirbagPaths = .resolve(), policy: RetentionPolicy = RetentionPolicy(),
                           globalBudgetBytes: Int64 = 5 << 30, nowMs: Int64 = Clock.nowMsInt()) -> PruneReport {
        var total = PruneReport()
        var stores: [SnapshotStore] = []
        for loc in SnapshotStore.allStores(paths: paths) {
            guard let s = try? SnapshotStore.openLocation(loc, paths: paths) else { continue }
            stores.append(s)
            if let r = try? s.prune(policy: policy, nowMs: nowMs) { total.merge(r) }
        }
        let usage = stores.map { (try? $0.usage().objectBytes) ?? 0 }
        let sum = usage.reduce(0, +)
        if sum > globalBudgetBytes {
            for (s, u) in zip(stores, usage) where u > 0 {
                var p = policy
                p.maxBytes = max(1, Int64(Double(globalBudgetBytes) * Double(u) / Double(sum)))
                if let r = try? s.prune(policy: p, nowMs: nowMs) { total.merge(r) }
            }
        }
        return total
    }
}

extension PruneReport {
    mutating func merge(_ r: PruneReport) {
        deletedSnapshots += r.deletedSnapshots; deletedChanges += r.deletedChanges
        deletedObjects += r.deletedObjects; freedBytes += r.freedBytes
    }
}

extension SnapshotStore {
    /// Opens a store from its location, also when the project folder no longer exists (for pruning and for
    /// restoring a deleted project, which recreates the folder).
    public static func openLocation(_ loc: StoreLocation, paths: AirbagPaths = .resolve()) throws -> SnapshotStore {
        try open(root: loc.root, paths: paths, create: false, recreateMissingRoot: !loc.rootExists)
    }
}
