import Foundation

/// A moment that changed files, as the popover and `airbag undo` list it: what changed it and whether it can be undone.
public struct RecentChange: Identifiable, Equatable, Sendable {
    public var id: String { snapshotID }
    public let root: String
    public let snapshotID: String
    public let at: Int64
    public let trigger: SnapshotTrigger
    public var changedCount: Int
    /// The shell command that made the changes (after-command snapshots only).
    public let command: String?
    public let agent: AgentKind?
    public let sessionTitle: String?
    /// For a command that ran long enough for a file-change snapshot to land in the middle: the snapshot taken before
    /// it. Its Undo then reverts everything between that snapshot and this one (as the Timeline row does).
    public var base: String?
    public var projectName: String { (root as NSString).lastPathComponent }

    /// Recent changes of one project from its timeline (newest first). A command's after snapshot absorbs file-change
    /// snapshots taken while it ran (back to the snapshot its before event points at), so Undo puts back all it did.
    public static func list(root: String, entries: [TimelineEntry]) -> [RecentChange] {
        var out: [RecentChange] = []
        var folded = Set<String>()
        for (i, e) in entries.enumerated() where !folded.contains(e.id) {
            guard var change = RecentChange(root: root, entry: e, hasPrevious: i + 1 < entries.count) else { continue }
            if e.snapshot.trigger == .postCommand, let post = e.commands.last(where: { $0.kind == "post_shell" }),
               let start = entries[(i + 1)...].firstIndex(where: { o in
                   o.commands.contains { $0.kind == "pre_shell" && $0.command == post.command && $0.agentSessionID == post.agentSessionID }
               }), start > i + 1 {
                let between = entries[(i + 1)..<start]
                if between.allSatisfy({ $0.snapshot.trigger == .fsevents && $0.commands.isEmpty }),
                   e.snapshot.createdAt - entries[start].snapshot.createdAt < 15 * 60_000 {
                    between.forEach { folded.insert($0.id) }
                    change.base = entries[start].snapshot.id
                    change.changedCount += between.map(\.snapshot.changedCount).reduce(0, +)
                }
            }
            out.append(change)
        }
        return out
    }

    /// Nil for moments that changed nothing, cannot be undone (no earlier snapshot) or are Airbag's own (restores).
    public init?(root: String, entry: TimelineEntry, hasPrevious: Bool) {
        let s = entry.snapshot
        guard hasPrevious, s.changedCount > 0, [.postCommand, .preCommand, .fsevents].contains(s.trigger) else { return nil }
        self.root = root
        snapshotID = s.id
        at = s.createdAt
        trigger = s.trigger
        changedCount = s.changedCount
        let post = entry.commands.last { $0.kind == "post_shell" }
        command = s.trigger == .postCommand ? (post ?? entry.commands.last)?.command : nil
        let by = s.trigger == .fsevents ? nil : (post ?? entry.commands.last)
        agent = by?.agent
        sessionTitle = by?.sessionTitle
    }

    /// What undoing this change restores: a command that spans several snapshots goes back to the snapshot before it.
    public func undoPlan(in store: SnapshotStore, paths only: [String]? = nil) throws -> UndoPlan {
        if let base { return try .span(from: base, to: snapshotID, in: store, paths: only) }
        return try .moment(snapshotID, in: store, paths: only)
    }
}

/// What an Undo restores (ADR-033): the snapshot to go back to and the files, always found in the store.
public struct UndoPlan: Sendable, Equatable {
    public let target: String
    public let scope: RestoreScope
    /// When the undone moment happened.
    public let at: Int64

    /// Undo of one moment: the files that snapshot recorded as changed (or the given ones), as they were in the snapshot
    /// before it.
    public static func moment(_ snapshot: String, in store: SnapshotStore, paths only: [String]? = nil) throws -> UndoPlan {
        guard let info = try store.info(snapshot), let previous = try store.list(limit: 1, beforeSeq: info.seq).first else {
            throw SnapshotError.notFound(snapshot)
        }
        return UndoPlan(target: previous.id, scope: .paths(try only ?? store.changes(in: snapshot).map(\.path)), at: info.createdAt)
    }

    /// Undo of a command whose effect spans several snapshots (a file-change snapshot taken while it ran): the files that
    /// differ between `base` (before the command) and `effect` (after it) go back to `base`.
    public static func span(from base: String, to effect: String, in store: SnapshotStore, paths only: [String]? = nil) throws -> UndoPlan {
        guard let info = try store.info(effect), try store.info(base) != nil else { throw SnapshotError.notFound(effect) }
        return UndoPlan(target: base, scope: .paths(try only ?? store.diff(from: base, to: effect).map(\.path)), at: info.createdAt)
    }
}
