import AirbagCore
import Foundation

enum HookCommands {
    /// `airbag hook <agent> [event-hint]` — the entry point agents call. Always exits 0 and prints at most one reply.
    static func hook(_ argv: [String]) -> Int32 {
        guard let name = argv.first, let agent = AgentKind(rawValue: name) else {
            print("{}")
            return 0
        }
        let hint = argv.dropFirst().first
        let paths = AirbagPaths.resolve()
        try? paths.prepare()
        Log.shared.configure(file: paths.logs.appendingPathComponent("hook.log"), category: "hook",
                             level: ProcessInfo.processInfo.environment["AIRBAG_HOOK_DEBUG"] == "1" ? .debug : .info)
        let probe = HookEnvelope(agent: agent, replyAs: agent, kind: .preShell, rawEvent: "")
        let slot = OutputSlot(initial: AgentAdapter.encode(.allow, as: agent, event: probe))
        let hardMs = (hint == "session-end" || hint == "sessionEnd") ? 800 : 4000
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(hardMs)) {
            if slot.printDecided() {
                Log.shared.warn("hook \(agent.rawValue): hard deadline \(hardMs) ms reached, replied with the decided answer")
                exit(0)
            }
        }
        var payload = Data()
        let stdin = FileHandle.standardInput
        while payload.count <= 1 << 20 {
            let chunk = stdin.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            payload.append(chunk)
        }
        if payload.count > 1 << 20 {
            Log.shared.warn("hook \(agent.rawValue): payload over 1 MiB ignored")
            slot.printDecided()
            return 0
        }
        let outcome = HookBridge(config: HookBridgeConfig(paths: paths)).handle(payload: payload, declared: agent, eventHint: hint, slot: slot)
        slot.printFinal(outcome.output)
        return 0
    }

    static func defaultCommandPath() -> String {
        let me = ProcInfo.currentExecutablePath()
        if FileManager.default.fileExists(atPath: "/Applications/Airbag.app/Contents/Helpers/airbag"), !me.contains("/Airbag.app/") {
            return "/Applications/Airbag.app/Contents/Helpers/airbag"
        }
        return me
    }

    static func agents(from a: Args, installer: HookInstaller, removing: Bool = false) throws -> [AgentKind] {
        if a.has("all") { return AgentKind.allCases.filter { removing ? installer.isInstalled($0) : installer.detect($0) } }
        let list = try a.positionals.map { n -> AgentKind in
            guard let k = AgentKind(rawValue: n) else { throw CLIError.usage("unknown agent '\(n)' (use: \(AgentKind.allCases.map(\.rawValue).joined(separator: ", ")))") }
            return k
        }
        if list.isEmpty { throw CLIError.usage("name agents (claude-code codex cursor gemini copilot) or pass --all") }
        return list
    }

    /// airbag hooks status|install|uninstall [agents…|--all] [--strict] [--dry-run] [--command PATH] [--json]
    static func hooks(_ argv: [String]) throws -> Int32 {
        guard let sub = argv.first else { throw CLIError.usage("usage: airbag hooks status|install|uninstall [agents…|--all]") }
        let a = try Args(Array(argv.dropFirst()), valueOptions: ["command", "home"])
        let home = a.value("home") ?? NSHomeDirectory()
        let installer = HookInstaller(home: home, command: a.value("command") ?? defaultCommandPath())
        let paths = AirbagPaths.resolve()
        switch sub {
        case "status":
            let rows = AgentKind.allCases.map(installer.status)
            if a.has("json") { Out.encodable(rows); return 0 }
            print("hook command: \(installer.command)")
            for r in rows {
                let state = !r.installed ? "not installed" : (r.current ? "installed" : (r.staleCommand ? "installed (points at another airbag binary — reinstall)" : "installed (outdated — reinstall)"))
                let name = r.agent.displayName.padding(toLength: 20, withPad: " ", startingAt: 0)
                let found = (r.detected ? "detected" : "not found").padding(toLength: 10, withPad: " ", startingAt: 0)
                print("\(name) \(found)  \(state)  \(r.configPath)")
                if let n = r.note { print("    \(n)") }
            }
            return 0
        case "install", "uninstall":
            if installer.command.contains("/.build/") && !a.has("command") {
                Out.err("warning: hooks will point at a development build (\(installer.command)); pass --command to choose another path")
            }
            for agent in try agents(from: a, installer: installer, removing: sub == "uninstall") {
                if a.has("dry-run") {
                    let change = try installer.plan(agent, install: sub == "install", strict: a.has("strict"))
                    print("== \(agent.displayName): \(change.path) \(change.changed ? "would change" : "unchanged")")
                    if change.changed { print(change.after ?? "(file removed)") }
                    continue
                }
                let change = sub == "install"
                    ? try installer.install(agent, strict: a.has("strict"), backupDirectory: paths.backups.path)
                    : try installer.uninstall(agent, backupDirectory: paths.backups.path)
                print("\(agent.displayName): \(change.changed ? (sub == "install" ? "installed" : "removed") : "already \(sub == "install" ? "installed" : "absent")") — \(change.path)\(change.backup.map { " (backup: \($0))" } ?? "")")
                if sub == "install", agent == .codex, change.changed { print("    Codex: open Codex, type /hooks and trust the Airbag entries (press t).") }
            }
            return 0
        default:
            throw CLIError.usage("usage: airbag hooks status|install|uninstall [agents…|--all]")
        }
    }

    /// airbag allow <guard-id> — approve one blocked/asked command once for its session.
    static func allow(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: [])
        guard let id = a.positionals.first else { throw CLIError.usage("usage: airbag allow <guard-entry-id>   (see `airbag guard`)") }
        let reg = try Registry(paths: .resolve(), role: .cli)
        guard try reg.allowOnce(guardID: id) else { throw CLIError.failed("no guard entry \(id) with a session") }
        print("allowed once: the agent may now run the same command again within 10 minutes")
        return 0
    }

    /// airbag guard [--limit N] [--json]
    static func guardLog(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: ["limit"])
        let reg = try Registry(paths: .resolve(), role: .cli)
        let rows = try reg.db.all("""
        SELECT id, ts, agent, rule_id, decision, command, coalesce(resolution, ''), reason FROM guard_log ORDER BY ts DESC LIMIT ?
        """, [a.int("limit") ?? 20]) { r -> [String: Any] in
            ["id": r.text(0), "ts": r.int(1), "agent": r.text(2), "rule": r.text(3), "decision": r.text(4), "command": r.text(5),
             "resolution": r.text(6), "reason": r.text(7)]
        }
        if a.has("json") { Out.json(rows); return 0 }
        for r in rows {
            print("\(r["id"]!)  \(Out.date(r["ts"] as! Int64))  \(r["agent"]!)  \(r["decision"]!)  [\(r["rule"]!)]  \(r["command"]!)\((r["resolution"] as! String).isEmpty ? "" : "  → \(r["resolution"]!)")")
        }
        return 0
    }

    /// airbag log [--limit N] [--json] — agent commands with their decision and the snapshot taken before them.
    static func log(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: ["limit"])
        let reg = try Registry(paths: .resolve(), role: .cli)
        let rows = try reg.db.all("""
        SELECT e.id, e.ts, e.agent, e.kind, coalesce(e.command, ''), coalesce(e.decision, ''),
               CASE WHEN sn.deleted_at IS NULL THEN coalesce(e.snapshot_id, '') ELSE '' END,
               coalesce(sn.root_path, p.root_path, e.cwd, '')
        FROM events e LEFT JOIN snapshots sn ON sn.id = e.snapshot_id LEFT JOIN projects p ON p.id = e.project_id
        WHERE e.kind IN ('pre_shell', 'permission_request', 'pre_edit') ORDER BY e.ts DESC, e.id DESC LIMIT ?
        """, [a.int("limit") ?? 30]) { r -> [String: Any] in
            ["id": r.text(0), "ts": r.int(1), "agent": r.text(2), "kind": r.text(3), "command": r.text(4), "decision": r.text(5),
             "snapshot": r.text(6), "root": r.text(7)]
        }
        if a.has("json") { Out.json(rows); return 0 }
        for r in rows {
            let snap = (r["snapshot"] as! String).isEmpty ? "no snapshot" : "snapshot \(r["snapshot"]!)"
            print("\(Out.date(r["ts"] as! Int64))  \(r["agent"]!)  \((r["decision"] as! String).padding(toLength: 13, withPad: " ", startingAt: 0)) \(r["command"]!)   [\(snap)]")
        }
        return 0
    }

    /// airbag sessions [--all] [--json]
    static func sessions(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: ["limit"])
        let reg = try Registry(paths: .resolve(), role: .cli)
        let rows = try reg.db.all("""
        SELECT s.agent, s.agent_session_id, s.surface, coalesce(p.display_name, ''), coalesce(w.path, s.cwd, ''), s.started_at, s.last_seen_at,
               s.ended_at, (SELECT pid FROM session_pids sp WHERE sp.session_id = s.id ORDER BY sp.id DESC LIMIT 1)
        FROM sessions s LEFT JOIN projects p ON p.id = s.project_id LEFT JOIN worktrees w ON w.id = s.worktree_id
        WHERE ? OR s.ended_at IS NULL ORDER BY s.last_seen_at DESC LIMIT ?
        """, [a.has("all"), a.int("limit") ?? 50]) { r -> [String: Any] in
            ["agent": r.text(0), "session": r.text(1), "surface": r.text(2), "project": r.text(3), "path": r.text(4),
             "started": r.int(5), "lastSeen": r.int(6), "ended": r.intOrNil(7) ?? 0, "pid": r.intOrNil(8) ?? 0]
        }
        if a.has("json") { Out.json(rows); return 0 }
        for r in rows {
            let ended = (r["ended"] as! Int64) > 0 ? "ended" : "live"
            print("\(r["agent"]!)  \(String((r["session"] as! String).prefix(8)))  \(ended)  pid \(r["pid"]!)  \(r["surface"]!)  \(r["project"]!)  \(r["path"]!)")
        }
        return 0
    }
}
