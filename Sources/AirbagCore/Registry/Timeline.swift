import Foundation

/// A command an agent ran, linked to the snapshot taken right before (or after) it.
public struct TimelineCommand: Sendable, Identifiable, Equatable {
    public let id: String
    public let ts: Int64
    public let kind: String
    public let agent: AgentKind?
    public let agentSessionID: String?
    public let sessionTitle: String?
    public let command: String
    public let decision: String?
}

public struct TimelineEntry: Sendable, Identifiable, Equatable {
    public var id: String { snapshot.id }
    public let snapshot: SnapshotInfo
    public let commands: [TimelineCommand]
    public init(snapshot: SnapshotInfo, commands: [TimelineCommand]) { self.snapshot = snapshot; self.commands = commands }
}

public struct GuardEntry: Sendable, Identifiable, Equatable {
    public let id: String
    public let ts: Int64
    public let agent: AgentKind?
    public let agentSessionID: String?
    public let sessionTitle: String?
    public let projectRoot: String?
    public let ruleID: String
    public let decision: String
    public let command: String
    public let reason: String
    public let resolution: String?
    /// The agent may retry it after an approval (ask turned into deny, still unresolved).
    /// Only asks that were turned into a deny (agent without a native prompt) can be approved in Airbag; a native ask is
    /// answered in the agent's own prompt and a hard block is not overridable.
    public var canAllowOnce: Bool { decision == "deny_fallback" && resolution == nil && agentSessionID != nil }
    public var isBlock: Bool { decision == "deny" || decision == "deny_fallback" }
}

extension Registry {
    /// Snapshots of a store, newest first, each with the agent commands that point at it.
    public func timeline(store: SnapshotStore, limit: Int = 200) -> [TimelineEntry] {
        let snaps = (try? store.list(limit: limit)) ?? []
        guard !snaps.isEmpty else { return [] }
        var byID: [String: [TimelineCommand]] = [:]
        let placeholders = snaps.map { _ in "?" }.joined(separator: ",")
        let rows = (try? db.all("""
        SELECT e.id, e.ts, e.kind, e.agent, s.agent_session_id, s.title, coalesce(e.command, ''), e.decision, e.snapshot_id
        FROM events e LEFT JOIN sessions s ON s.id = e.session_id
        WHERE e.snapshot_id IN (\(placeholders)) ORDER BY e.ts
        """, snaps.map(\.id)) { r -> (String, TimelineCommand) in
            (r.text(8), TimelineCommand(id: r.text(0), ts: r.int(1), kind: r.text(2), agent: r.textOrNil(3).flatMap(AgentKind.init(rawValue:)),
                                        agentSessionID: r.textOrNil(4), sessionTitle: r.textOrNil(5), command: r.text(6), decision: r.textOrNil(7)))
        }) ?? []
        for (sid, c) in rows { byID[sid, default: []].append(c) }
        return snaps.map { TimelineEntry(snapshot: $0, commands: byID[$0.id] ?? []) }
    }

    public func guardEntries(limit: Int = 100, unresolvedOnly: Bool = false) -> [GuardEntry] {
        (try? db.all("""
        SELECT g.id, g.ts, g.agent, s.agent_session_id, s.title, p.root_path, g.rule_id, g.decision, g.command, g.reason, g.resolution
        FROM guard_log g LEFT JOIN sessions s ON s.id = g.session_id LEFT JOIN projects p ON p.id = g.project_id
        WHERE g.severity != 'warn' AND (? = 0 OR g.resolved_at IS NULL)
        ORDER BY g.ts DESC LIMIT ?
        """, [unresolvedOnly, limit]) { r in
            GuardEntry(id: r.text(0), ts: r.int(1), agent: AgentKind(rawValue: r.text(2)), agentSessionID: r.textOrNil(3), sessionTitle: r.textOrNil(4),
                       projectRoot: r.textOrNil(5), ruleID: r.text(6), decision: r.text(7), command: r.text(8), reason: r.text(9), resolution: r.textOrNil(10))
        }) ?? []
    }

    public func dismissGuard(_ id: String) throws {
        try db.run("UPDATE guard_log SET resolved_at = ?, resolution = coalesce(resolution, 'user_denied') WHERE id = ?", [Clock.nowMsInt(), id])
    }

    /// Live sessions per project root (for the popover's project rows).
    public func liveSessionCounts() -> [String: Int] {
        let rows = (try? db.all("""
        SELECT coalesce(w.path, p.root_path), count(*) FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
        LEFT JOIN worktrees w ON w.id = s.worktree_id WHERE s.ended_at IS NULL AND s.last_seen_at > ? GROUP BY 1
        """, [Clock.nowMsInt() - 6 * 3_600_000]) { ($0.textOrNil(0), Int($0.int(1))) }) ?? []
        return Dictionary(rows.compactMap { k, v in k.map { ($0, v) } }, uniquingKeysWith: +)
    }

    // MARK: pause

    public var pausedUntilMs: Int64? {
        guard let v: Int64 = setting("protection.pausedUntil"), v > Clock.nowMsInt() else { return nil }
        return v
    }

    public func pause(untilMs: Int64?) throws {
        if let u = untilMs { try setSetting("protection.pausedUntil", u) } else { try db.run("DELETE FROM settings WHERE key = 'protection.pausedUntil'") }
    }
}
