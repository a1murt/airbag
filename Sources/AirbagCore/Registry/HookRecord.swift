import Foundation

/// Everything one hook invocation wants persisted. Applied in one transaction, or spooled to disk and applied
/// later when the registry is busy (doc 11 §3.6). Ingestion is idempotent through `dedupeKey` and UNIQUE keys.
public struct HookRecord: Codable, Sendable {
    public struct ProjectRef: Codable, Sendable {
        public var root: String          // project root (main checkout or plain folder)
        public var commonDir: String?    // git common dir
        public var kind: String          // git | plain
        public var worktreePath: String? // worktree root when the session works in one
        public var worktreeKind: String? // main | claude | codex | cursor | manual | unknown
        public var worktreeName: String?
    }
    public struct AgentProcessRef: Codable, Sendable {
        public var pid: Int32
        public var startUs: Int64
        public var exe: String?
        public var ppid: Int32
        public var pgid: Int32
        public var hostPid: Int32?
        public var hostStartUs: Int64?
        public var terminalApp: String?
        public var tty: String?
    }
    public struct GuardRef: Codable, Sendable {
        public var ruleId: String
        public var severity: String      // block | ask | warn
        public var decision: String      // deny | ask | allow | allow_once | deny_fallback | allow_fallback
        public var matched: String?
        public var reason: String
    }
    public struct SnapshotRef: Codable, Sendable {
        public var id: String
        public var rootID: String
        public var rootPath: String
        public var seq: Int64
        public var trigger: String
        public var fileCount: Int
        public var changedCount: Int
        public var bytesAdded: Int64
        public var durationMs: Int
        public var complete: Bool
        public var label: String?
    }

    public var eventID: String = ULID.make()
    public var ts: Int64 = Clock.nowMsInt()
    public var agent: String
    public var kind: String
    public var agentSessionID: String?
    public var cwd: String?
    public var launchRoot: String?
    public var transcriptPath: String?
    public var permissionMode: String?
    public var model: String?
    public var title: String?
    public var surface: String = "unknown"
    public var project: ProjectRef?
    public var agentProcess: AgentProcessRef?
    public var command: String?
    public var commandHash: String?
    public var toolUseID: String?
    public var dedupeKey: String?
    public var background = false
    public var decision: String?
    /// Agent-facing reason of a deny or ask (replayed when the same call arrives through a second route).
    public var reason: String?
    public var guardEntry: GuardRef?
    public var snapshot: SnapshotRef?
    public var snapshotSkipped: String?
    public var endReason: String?
    public var timing: [String: Int] = [:]

    public init(agent: String, kind: String) { self.agent = agent; self.kind = kind }
}

extension Registry {
    /// Decision already stored for a dedupe key (another route of the same command was processed first).
    public func existingDecision(dedupeKey: String) -> String? {
        try? db.scalarText("SELECT decision FROM events WHERE dedupe_key = ?", [dedupeKey])
    }

    public struct PriorEvent: Sendable { public let decision: String?; public let reason: String? }

    public func existingEvent(dedupeKey: String) -> PriorEvent? {
        (try? db.first("SELECT decision, json_extract(payload, '$.reason') FROM events WHERE dedupe_key = ?", [dedupeKey]) {
            PriorEvent(decision: $0.textOrNil(0), reason: $0.textOrNil(1))
        }) ?? nil
    }

    /// Consumes an unused, unexpired one-shot allowance for this exact command in this session.
    public func consumeAllowToken(agent: String, agentSessionID: String, commandHash: String, now: Int64 = Clock.nowMsInt()) -> Bool {
        do {
            return try db.transaction(.immediate) {
                guard let sid = try db.scalarText("SELECT id FROM sessions WHERE agent = ? AND agent_session_id = ?", [agent, agentSessionID]),
                      let token = try db.scalarText("""
                      SELECT id FROM allow_tokens WHERE session_id = ? AND command_hash = ? AND used_at IS NULL AND expires_at > ?
                      ORDER BY created_at LIMIT 1
                      """, [sid, commandHash, now]) else { return false }
                try db.run("UPDATE allow_tokens SET used_at = ? WHERE id = ?", [now, token])
                try db.run("UPDATE guard_log SET resolved_at = coalesce(resolved_at, ?), resolution = coalesce(resolution, 'token_used') WHERE token_id = ?", [now, token])
                return true
            }
        } catch { return false }
    }

    /// Grants a one-shot allowance for the command of a guard entry (used by the app and `airbag allow`).
    @discardableResult
    public func allowOnce(guardID: String, ttlMs: Int64 = 600_000) throws -> Bool {
        try db.transaction(.immediate) {
            guard let row = try db.first("SELECT session_id, command_hash, rule_id, decision FROM guard_log WHERE id = ?", [guardID], {
                ($0.textOrNil(0), $0.text(1), $0.text(2), $0.text(3))
            }), let sid = row.0 else { return false }
            // Hard blocks are not overridable; a native ask is answered in the agent's own prompt.
            guard row.3 == "deny_fallback" else { throw RegistryError.notAllowable(row.3) }
            let now = Clock.nowMsInt()
            let token = ULID.make()
            try db.run("""
            INSERT INTO allow_tokens(id, session_id, command_hash, rule_id, created_at, expires_at) VALUES (?,?,?,?,?,?)
            ON CONFLICT(session_id, command_hash, rule_id) DO UPDATE SET id = excluded.id, created_at = excluded.created_at,
              expires_at = excluded.expires_at, used_at = NULL
            """, [token, sid, row.1, row.2, now, now + ttlMs])
            try db.run("UPDATE guard_log SET token_id = ?, resolved_at = ?, resolution = 'user_allowed' WHERE id = ?", [token, now, guardID])
            return true
        }
    }

    /// Applies a hook record. Returns false when the event was a duplicate (dedupe key already present).
    @discardableResult
    public func record(_ r: HookRecord) throws -> Bool {
        try db.transaction(.immediate) {
            let now = r.ts
            try db.run("INSERT OR IGNORE INTO agents(kind, display_name) VALUES (?, ?)",
                       [r.agent, AgentKind(rawValue: r.agent)?.displayName ?? r.agent])
            var projectID: String?
            var worktreeID: String?
            if let p = r.project {
                projectID = try upsertProject(p, now: now)
                if let wt = p.worktreePath, let pid = projectID { worktreeID = try upsertWorktree(project: pid, p, path: wt, now: now) }
            }
            var sessionID: String?
            if let asid = r.agentSessionID {
                sessionID = try upsertSession(r, agentSessionID: asid, projectID: projectID, worktreeID: worktreeID, now: now)
                if let proc = r.agentProcess, let sid = sessionID { try upsertIncarnation(session: sid, proc, now: now) }
                if r.kind == HookEventKind.sessionEnd.rawValue, let sid = sessionID {
                    try db.run("UPDATE sessions SET ended_at = ?, end_reason = ? WHERE id = ? AND ended_at IS NULL", [now, "hook:\(r.endReason ?? "other")", sid])
                    try db.run("UPDATE session_pids SET ended_at = ? WHERE session_id = ? AND ended_at IS NULL", [now, sid])
                }
            }
            if let s = r.snapshot {
                try db.run("""
                INSERT OR IGNORE INTO snapshots(id, project_id, worktree_id, root_id, root_path, seq, session_id, event_id, trigger,
                  file_count, changed_count, bytes_added, duration_ms, complete, label, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [s.id, projectID, worktreeID, s.rootID, s.rootPath, s.seq, sessionID, r.eventID, s.trigger, s.fileCount,
                      s.changedCount, s.bytesAdded, s.durationMs, s.complete, s.label, now])
            }
            var payload: [String: Any] = ["timing": r.timing]
            if let reason = r.reason { payload["reason"] = reason }
            if let skipped = r.snapshotSkipped { payload["snapshot_skipped"] = skipped }
            if let a = r.agentProcess { payload["agent_pid"] = a.pid }
            try db.run("""
            INSERT OR IGNORE INTO events(id, ts, kind, agent, session_id, project_id, worktree_id, tool_use_id, dedupe_key, cwd,
              command, command_hash, background, decision, snapshot_id, payload)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [r.eventID, now, r.kind, r.agent, sessionID, projectID, worktreeID, r.toolUseID, r.dedupeKey, r.cwd, r.command,
                  r.commandHash, r.background, r.decision, r.snapshot?.id, JSONOutput.string(payload)])
            guard db.changes > 0 else { return false }
            if let g = r.guardEntry {
                try db.run("""
                INSERT INTO guard_log(id, ts, event_id, session_id, project_id, agent, rule_id, rule_source, severity, decision, command,
                  command_hash, matched_span, cwd, reason, snapshot_id)
                VALUES (?,?,?,?,?,?,?,'builtin',?,?,?,?,?,?,?,?)
                """, [ULID.make(), now, r.eventID, sessionID, projectID, r.agent, g.ruleId, g.severity, g.decision, r.command ?? "",
                      r.commandHash ?? "", g.matched, r.cwd, g.reason, r.snapshot?.id])
            }
            return true
        }
    }

    private func upsertProject(_ p: HookRecord.ProjectRef, now: Int64) throws -> String {
        if let id = try db.scalarText("SELECT id FROM projects WHERE root_path = ?", [p.root]) {
            try db.run("UPDATE projects SET last_seen_at = ? WHERE id = ?", [now, id])
            return id
        }
        if let common = p.commonDir, let id = try db.scalarText("SELECT id FROM projects WHERE common_dir = ?", [common]) {
            try db.run("UPDATE projects SET last_seen_at = ? WHERE id = ?", [now, id])
            return id
        }
        let id = ULID.make()
        try db.run("""
        INSERT INTO projects(id, root_path, common_dir, kind, display_name, protected, created_at, last_seen_at) VALUES (?,?,?,?,?,1,?,?)
        """, [id, p.root, p.commonDir, p.kind, (p.root as NSString).lastPathComponent, now, now])
        return id
    }

    private func upsertWorktree(project: String, _ p: HookRecord.ProjectRef, path: String, now: Int64) throws -> String {
        if let id = try db.scalarText("SELECT id FROM worktrees WHERE path = ?", [path]) {
            try db.run("UPDATE worktrees SET last_seen_at = ?, removed_at = NULL WHERE id = ?", [now, id])
            return id
        }
        let id = ULID.make()
        try db.run("INSERT INTO worktrees(id, project_id, path, kind, name, created_at, last_seen_at) VALUES (?,?,?,?,?,?,?)",
                   [id, project, path, p.worktreeKind ?? "unknown", p.worktreeName, now, now])
        return id
    }

    private func upsertSession(_ r: HookRecord, agentSessionID: String, projectID: String?, worktreeID: String?, now: Int64) throws -> String {
        if let id = try db.scalarText("SELECT id FROM sessions WHERE agent = ? AND agent_session_id = ?", [r.agent, agentSessionID]) {
            try db.run("""
            UPDATE sessions SET last_seen_at = ?, last_event_kind = ?, cwd = coalesce(?, cwd), project_id = coalesce(?, project_id),
              worktree_id = coalesce(?, worktree_id), permission_mode = coalesce(?, permission_mode), model = coalesce(?, model),
              title = coalesce(?, title),
              ended_at = CASE WHEN ? = 'session_end' THEN ended_at ELSE NULL END,
              end_reason = CASE WHEN ? = 'session_end' THEN end_reason ELSE NULL END
            WHERE id = ?
            """, [now, r.kind, r.cwd, projectID, worktreeID, r.permissionMode, r.model, r.title, r.kind, r.kind, id])
            return id
        }
        let id = ULID.make()
        try db.run("""
        INSERT INTO sessions(id, agent, agent_session_id, project_id, worktree_id, cwd, launch_root, surface, transcript_path, title, model,
          permission_mode, discovered_via, started_at, last_seen_at, last_event_kind)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'hook',?,?,?)
        """, [id, r.agent, agentSessionID, projectID, worktreeID, r.cwd, r.launchRoot, r.surface, r.transcriptPath, r.title, r.model,
              r.permissionMode, now, now, r.kind])
        return id
    }

    private func upsertIncarnation(session: String, _ a: HookRecord.AgentProcessRef, now: Int64) throws {
        let live = try db.first("SELECT id, pid, proc_start FROM session_pids WHERE session_id = ? AND ended_at IS NULL ORDER BY id DESC LIMIT 1",
                                [session]) { ($0.int(0), Int32($0.int(1)), $0.int(2)) }
        if let live, live.1 == a.pid, live.2 == a.startUs {
            try db.run("UPDATE session_pids SET last_alive_at = ? WHERE id = ?", [now, live.0])
            return
        }
        if let live { try db.run("UPDATE session_pids SET ended_at = ? WHERE id = ?", [now, live.0]) }
        try db.run("""
        INSERT OR IGNORE INTO session_pids(session_id, pid, proc_start, exe_path, ppid, pgid, host_pid, host_start, terminal_app, tty,
          first_seen_at, last_alive_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, [session, a.pid, a.startUs, a.exe, a.ppid, a.pgid, a.hostPid, a.hostStartUs, a.terminalApp, a.tty, now, now])
    }

    // MARK: spool

    /// Writes a record that could not be committed; `ingestSpool` applies it later.
    public static func spool(_ r: HookRecord, paths: AirbagPaths) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        try? paths.prepare()
        let dest = paths.spool.appendingPathComponent("\(r.eventID).json").path
        try? FileSystem.writeAtomically(data, to: dest, mode: 0o600)
    }

    /// Applies up to `limit` spooled records, oldest first. Returns how many were applied.
    @discardableResult
    public func ingestSpool(limit: Int = 100) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.spool.path) else { return 0 }
        var n = 0
        for name in names.filter({ $0.hasSuffix(".json") }).sorted().prefix(limit) {
            let path = paths.spool.appendingPathComponent(name).path
            guard let data = fm.contents(atPath: path), let r = try? JSONDecoder().decode(HookRecord.self, from: data) else {
                try? fm.removeItem(atPath: path); continue
            }
            do { try record(r); try? fm.removeItem(atPath: path); n += 1 } catch { break }
        }
        return n
    }
}

/// Removes secrets from command text before it is stored (doc 11 §9).
public enum Redactor {
    static let patterns: [NSRegularExpression] = [
        #"(?i)((?:api[_-]?key|access[_-]?key|secret|token|password|passwd|pwd|auth|bearer|session[_-]?key)[A-Za-z0-9_]*\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)"#,
        #"(?i)(authorization:\s*(?:bearer|basic|token)\s+)\S+"#,
        #"(?i)(--(?:password|token|api-key|secret|auth)[= ])\S+"#,
        #"(://[^/\s:@]+:)[^@\s/]+(@)"#,
        #"\b(sk-(?:ant-|proj-)?[A-Za-z0-9_-]{8})[A-Za-z0-9_-]{8,}"#,
        #"\b(gh[pousr]_)[A-Za-z0-9]{20,}"#,
        #"\b(github_pat_)[A-Za-z0-9_]{20,}"#,
        #"\b(xox[abposr]-)[A-Za-z0-9-]{10,}"#,
        #"\b(AKIA)[0-9A-Z]{16}\b"#,
        #"\b(eyJ[A-Za-z0-9_-]{6})[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
        #"\b(AIza)[0-9A-Za-z_-]{35}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        var s = text
        for re in patterns {
            let range = NSRange(s.startIndex..., in: s)
            let template: String
            switch re.numberOfCaptureGroups {
            case 2: template = re.pattern.hasPrefix("(://") ? "$1***$2" : "$1***"
            default: template = "$1***"
            }
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
        }
        return s.count > 4000 ? String(s.prefix(4000)) + "…" : s
    }
}
