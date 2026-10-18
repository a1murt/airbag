import Darwin
import Foundation

public enum ProcessClass: String, Sendable, Codable { case dev, agent, agentHelper = "agent_helper", terminal, system, other }
public enum LinkState: String, Sendable, Codable { case attached, detached, orphan, unknown }
public enum AttributionMethod: String, Sendable, Codable {
    case liveAncestry = "live_ancestry", envSession = "env_session", envAgentPid = "env_agent_pid", rememberedAncestry = "remembered_ancestry"
    case cwd, manual
}
public enum Confidence: String, Sendable, Codable, Comparable {
    case low, medium, high
    var rank: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    public static func < (a: Confidence, b: Confidence) -> Bool { a.rank < b.rank }
}

public struct Attribution: Sendable, Codable, Equatable {
    public var method: AttributionMethod
    public var confidence: Confidence
    public var agent: AgentKind?
    public var agentSessionID: String?
    public var sessionTitle: String?
    public var sessionLive: Bool
    public var projectRoot: String?
}

public struct RadarProcess: Sendable, Codable, Identifiable, Equatable {
    public var id: ProcessIdentity { identity }
    public let identity: ProcessIdentity
    public let ppid: Int32
    public let pgid: Int32
    public let name: String
    public let exe: String?
    public let argv: [String]
    public let cwd: String?
    public let startedAtMs: Int64
    public var footprintBytes: Int64?
    public var cpuTimeNs: UInt64?
    public let listeners: [Listener]
    public let processClass: ProcessClass
    public var attribution: Attribution?
    public var linkState: LinkState
    /// Why this process must not be stopped, or nil when stoppable.
    public var protection: String?
    public var commandLine: String { argv.isEmpty ? name : argv.joined(separator: " ") }
}

public struct RadarSnapshot: Sendable, Codable {
    public let capturedAtMs: Int64
    public let durationMs: Int
    public let processes: [RadarProcess]
    /// Processes listening on a port, attributed or dev-class (what the Radar shows by default).
    public var servers: [RadarProcess] { processes.filter { !$0.listeners.isEmpty && ($0.processClass == .dev || $0.attribution != nil) } }
    public var orphans: [RadarProcess] { processes.filter { $0.linkState == .orphan && !$0.listeners.isEmpty } }
}

/// A live agent process Airbag knows about (from hooks or from the agent's own session files).
public struct LiveAgent: Sendable, Equatable {
    public let agent: AgentKind
    public let agentSessionID: String
    public let pid: Int32
    public let startUs: Int64?
    public let title: String?
    public let cwd: String?
}

public final class ProcessRadar {
    public let home: String
    public let paths: AirbagPaths
    /// Per-(pid,start) cache of things fixed at exec: exe, argv, environment markers.
    private var cache: [ProcessIdentity: (exe: String?, argv: [String], markers: [String: String])] = [:]
    private let myUID = getuid()

    static let markerKeys: Set<String> = ["CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "CODEX_THREAD_ID",
                                          "CODEX_SESSION_ID", "CURSOR_AGENT", "CURSOR_SANDBOX", "GEMINI_CLI", "COPILOT_CLI", "PWD"]
    static let devNames: Set<String> = ["node", "bun", "deno", "python", "python3", "uvicorn", "gunicorn", "hypercorn", "flask", "ruby",
                                        "puma", "rails", "go", "java", "kotlin", "gradle", "cargo", "php", "php-fpm", "dotnet", "beam.smp",
                                        "erl", "elixir", "mix", "caddy", "nginx", "httpd", "postgres", "redis-server", "mysqld", "mongod",
                                        "next-server", "vite", "esbuild", "webpack", "tsc", "ngrok", "cloudflared", "ssh", "limactl", "colima",
                                        "docker-proxy", "com.docker.backend", "vpnkit", "containerd", "air", "nodemon", "turbo", "wrangler",
                                        "workerd", "miniflare", "hugo", "jekyll", "streamlit", "jupyter", "jupyter-lab", "ollama", "supabase"]
    static let managedNames: Set<String> = ["limactl", "colima", "docker-proxy", "com.docker.backend", "vpnkit", "containerd"]
    static let hostAppNames: [String] = ["/Claude.app/", "/Codex.app/", "/ChatGPT.app/", "/Cursor.app/", "/Terminal.app/", "/iTerm.app/",
                                         "/Visual Studio Code.app/", "/Code.app/", "/WezTerm.app/", "/kitty.app/", "/Ghostty.app/",
                                         "/Alacritty.app/", "/Warp.app/", "/Zed.app/", "/Xcode.app/", "/Airbag.app/", "/Windsurf.app/",
                                         "IntelliJ", "PyCharm", "WebStorm", "GoLand", "RubyMine", "Android Studio"]

    public init(home: String = NSHomeDirectory(), paths: AirbagPaths = .resolve()) {
        self.home = home
        self.paths = paths
    }

    // MARK: live sessions

    /// Live Claude Code sessions from `~/.claude/sessions/<pid>.json` (written by Claude Code itself).
    public func claudeSessionFiles(table: ProcessTable) -> [LiveAgent] {
        let dir = home + "/.claude/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [LiveAgent] = []
        for n in names where n.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + n), let o = JSONObject.parse(data),
                  let pid = o.int("pid"), let sid = o.string("sessionId") else { continue }
            guard let e = table[Int32(pid)], !e.zombie else { continue }
            out.append(LiveAgent(agent: .claudeCode, agentSessionID: sid, pid: Int32(pid), startUs: e.startUs, title: o.string("name"), cwd: o.string("cwd")))
        }
        return out
    }

    /// Live agents: registry incarnations whose process still runs, plus Claude's own session files.
    public func liveAgents(table: ProcessTable, registry: Registry?) -> [LiveAgent] {
        var out = claudeSessionFiles(table: table)
        if let reg = registry {
            let rows = (try? reg.db.all("""
            SELECT s.agent, s.agent_session_id, sp.pid, sp.proc_start, s.title, s.cwd FROM session_pids sp JOIN sessions s ON s.id = sp.session_id
            WHERE sp.ended_at IS NULL AND s.ended_at IS NULL
            """) { r in (r.text(0), r.text(1), Int32(r.int(2)), r.int(3), r.textOrNil(4), r.textOrNil(5)) }) ?? []
            for (agent, sid, pid, start, title, cwd) in rows {
                guard let kind = AgentKind(rawValue: agent), table.isAlive(ProcessIdentity(pid: pid, startUs: start)) else { continue }
                if !out.contains(where: { $0.agentSessionID == sid && $0.pid == pid }) {
                    out.append(LiveAgent(agent: kind, agentSessionID: sid, pid: pid, startUs: start, title: title, cwd: cwd))
                }
            }
        }
        return out
    }

    // MARK: scan

    public func scan(registry: Registry?, includeAll: Bool = false) -> RadarSnapshot {
        let t0 = Clock.monotonicNs()
        let table = ProcessTable.capture()
        let mine = table.entries.values.filter { $0.uid == myUID && $0.pid > 1 && !$0.zombie }
        let listeners = ListenerScanner.scan(pids: mine.map(\.pid))
        let live = liveAgents(table: table, registry: registry)
        let livePids = Dictionary(live.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let liveSessions = Set(live.map { "\($0.agent.rawValue):\($0.agentSessionID)" })
        let roots = registeredRoots(registry)
        let remembered = rememberedAttributions(registry)
        let titles = sessionTitles(registry, live: live)
        let myAncestors = Set(table.ancestors(of: getpid()).map(\.pid) + [getpid()])
        let protectedAgentChain: Set<Int32> = Set(live.flatMap { a in [a.pid] + table.ancestors(of: a.pid).map(\.pid) })

        var out: [RadarProcess] = []
        // Drop cache entries for processes that are gone.
        cache = cache.filter { table.isAlive($0.key) }
        for e in mine {
            let hasListener = listeners[e.pid] != nil
            let underAgent = table.ancestors(of: e.pid).contains { livePids[$0.pid] != nil }
            let candidate = includeAll || hasListener || underAgent || remembered[e.identity] != nil
            guard candidate else { continue }
            let info = enrich(e)
            let cwd = ProcInfo.cwd(e.pid)
            let cls = classify(e, exe: info.exe, markers: info.markers, cwd: cwd, hasListener: hasListener, roots: roots,
                               isAgentChild: livePids[e.ppid] != nil, isLiveAgent: livePids[e.pid] != nil)
            if !includeAll && !hasListener && cls != .dev && remembered[e.identity] == nil { continue }
            var attribution: Attribution?
            var link: LinkState = .unknown
            // 1. live ancestry
            if let a = table.ancestors(of: e.pid).first(where: { livePids[$0.pid] != nil }), let agent = livePids[a.pid] {
                attribution = Attribution(method: .liveAncestry, confidence: .high, agent: agent.agent, agentSessionID: agent.agentSessionID,
                                          sessionTitle: agent.title, sessionLive: true, projectRoot: nil)
                link = .attached
            }
            // 2. environment markers (survive reparenting to launchd)
            if attribution == nil {
                if let sid = info.markers["CLAUDE_CODE_SESSION_ID"] {
                    let isLive = liveSessions.contains("claude-code:\(sid)")
                        || (info.markers["CLAUDE_PID"].flatMap(Int32.init).map { p in livePids[p] != nil } ?? false)
                    attribution = Attribution(method: .envSession, confidence: .high, agent: .claudeCode, agentSessionID: sid,
                                              sessionTitle: titles["claude-code:\(sid)"], sessionLive: isLive, projectRoot: nil)
                } else if let sid = info.markers["CODEX_THREAD_ID"] ?? info.markers["CODEX_SESSION_ID"] {
                    attribution = Attribution(method: .envSession, confidence: .high, agent: .codex, agentSessionID: sid,
                                              sessionTitle: titles["codex:\(sid)"], sessionLive: liveSessions.contains("codex:\(sid)"), projectRoot: nil)
                } else if info.markers["CURSOR_AGENT"] != nil || info.markers["GEMINI_CLI"] != nil || info.markers["COPILOT_CLI"] != nil {
                    let agent: AgentKind = info.markers["CURSOR_AGENT"] != nil ? .cursor : (info.markers["GEMINI_CLI"] != nil ? .gemini : .copilot)
                    attribution = Attribution(method: .envSession, confidence: .medium, agent: agent, agentSessionID: nil, sessionTitle: nil,
                                              sessionLive: live.contains { $0.agent == agent }, projectRoot: nil)
                }
                if let a = attribution { link = a.sessionLive ? .detached : (a.agentSessionID != nil ? .orphan : .unknown) }
            }
            // 3. remembered from an earlier tick (stored by the app)
            if attribution == nil, let r = remembered[e.identity], let kind = AgentKind(rawValue: r.agent) {
                let isLive = liveSessions.contains("\(r.agent):\(r.sid)")
                attribution = Attribution(method: .rememberedAncestry, confidence: .high, agent: kind, agentSessionID: r.sid,
                                          sessionTitle: titles["\(r.agent):\(r.sid)"], sessionLive: isLive, projectRoot: nil)
                link = isLive ? .detached : (r.ended ? .orphan : .detached)
            }
            // 4. project by cwd (or the PWD marker)
            let where_ = cwd ?? info.markers["PWD"]
            let project = where_.flatMap { c in roots.filter { c == $0 || c.hasPrefix($0 + "/") }.max(by: { $0.count < $1.count }) }
            if var a = attribution { a.projectRoot = project ?? a.projectRoot; attribution = a }
            else if let project {
                attribution = Attribution(method: .cwd, confidence: .low, agent: nil, agentSessionID: nil, sessionTitle: nil, sessionLive: false, projectRoot: project)
            }
            var protection: String?
            if e.pid <= 1 { protection = "system process" }
            else if myAncestors.contains(e.pid) { protection = "Airbag or its parent" }
            else if livePids[e.pid] != nil || protectedAgentChain.contains(e.pid) { protection = "running agent session" }
            else if cls == .system { protection = "system process" }
            else if cls == .terminal || cls == .agent { protection = "agent, editor or terminal" }
            else if ProcessRadar.managedNames.contains(e.comm) || ProcessRadar.managedNames.contains((info.exe as NSString?)?.lastPathComponent ?? "") {
                protection = "managed by Docker or Lima (stop the container instead)"
            } else if cls == .agentHelper && (attribution?.sessionLive ?? false) { protection = "helper of a running agent session" }
            let usage = ProcUsage.read(e.pid)
            out.append(RadarProcess(identity: e.identity, ppid: e.ppid, pgid: e.pgid, name: e.comm, exe: info.exe,
                                    argv: info.argv.map { Redactor.redact($0) }, cwd: cwd, startedAtMs: e.startUs / 1000,
                                    footprintBytes: usage?.footprintBytes, cpuTimeNs: usage?.cpuTimeNs, listeners: listeners[e.pid] ?? [],
                                    processClass: cls, attribution: attribution, linkState: link, protection: protection))
        }
        out.sort { ($0.listeners.first?.port ?? 99999, $0.identity.pid) < ($1.listeners.first?.port ?? 99999, $1.identity.pid) }
        return RadarSnapshot(capturedAtMs: table.capturedAtMs, durationMs: Clock.elapsedMs(since: t0), processes: out)
    }

    func enrich(_ e: ProcEntry) -> (exe: String?, argv: [String], markers: [String: String]) {
        if let c = cache[e.identity] { return c }
        let exe = ProcInfo.path(e.pid)
        var argv: [String] = []
        var markers: [String: String] = [:]
        let systemExe = exe.map { $0.hasPrefix("/System/") || $0.hasPrefix("/usr/libexec/") || $0.hasPrefix("/usr/sbin/") || $0.hasPrefix("/Library/Apple/") } ?? false
        if !systemExe, let args = ProcInfo.arguments(e.pid) {
            argv = Array(args.argv.prefix(32)).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
            for (k, v) in args.env where ProcessRadar.markerKeys.contains(k) { markers[k] = v }
        }
        let r = (exe, argv, markers)
        if cache.count > 4096 { cache.removeAll() }
        cache[e.identity] = r
        return r
    }

    func classify(_ e: ProcEntry, exe: String?, markers: [String: String], cwd: String?, hasListener: Bool, roots: [String],
                  isAgentChild: Bool, isLiveAgent: Bool) -> ProcessClass {
        if e.uid != myUID { return .system }
        let path = exe ?? ""
        let base = (path as NSString).lastPathComponent.isEmpty ? e.comm : (path as NSString).lastPathComponent
        if isLiveAgent { return .agent }
        // Agent binaries (a `node` process is never classed as an agent by name alone: dev servers are node too).
        if base != "node", AgentKind.allCases.contains(where: { AgentLocator.matches($0, exe: exe, pid: e.pid) }) { return .agent }
        if ProcessRadar.hostAppNames.contains(where: { path.contains($0) }) { return .terminal }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/Library/Apple/") { return .system }
        if path.hasPrefix("/usr/bin/") && !["python3", "ruby", "perl", "php", "ssh", "nc", "java"].contains(base) { return .system }
        let devSignal = ProcessRadar.devNames.contains(base) || ProcessRadar.devNames.contains(e.comm) || base.hasPrefix("python3.") || base.hasPrefix("qemu-system")
            || ["/opt/homebrew/", "/usr/local/", home + "/.nvm/", home + "/.volta/", home + "/.asdf/", home + "/.local/share/", home + "/.cargo/",
                home + "/go/bin/", home + "/.bun/", home + "/.rbenv/", home + "/.pyenv/", home + "/.local/bin/"].contains(where: { path.hasPrefix($0) })
            || ["/node_modules/.bin/", "/.venv/", "/target/debug/", "/target/release/", "/.build/"].contains(where: { path.contains($0) })
            || markers.keys.contains(where: { $0 != "PWD" })
            || (cwd.map { c in roots.contains { c == $0 || c.hasPrefix($0 + "/") } } ?? false)
        if isAgentChild && !hasListener { return .agentHelper }
        if devSignal { return .dev }
        if hasListener && !path.contains(".app/Contents/") { return .dev }
        return .other
    }

    func registeredRoots(_ registry: Registry?) -> [String] {
        guard let reg = registry else { return [] }
        let p = (try? reg.db.all("SELECT root_path FROM projects WHERE archived_at IS NULL") { $0.text(0) }) ?? []
        let w = (try? reg.db.all("SELECT path FROM worktrees WHERE removed_at IS NULL") { $0.text(0) }) ?? []
        return Array(Set(p + w))
    }

    func rememberedAttributions(_ registry: Registry?) -> [ProcessIdentity: (agent: String, sid: String, ended: Bool)] {
        guard let reg = registry else { return [:] }
        let rows = (try? reg.db.all("""
        SELECT pr.pid, pr.proc_start, s.agent, s.agent_session_id, s.ended_at IS NOT NULL FROM processes pr JOIN sessions s ON s.id = pr.session_id
        WHERE pr.ended_at IS NULL
        """) { r in (ProcessIdentity(pid: Int32(r.int(0)), startUs: r.int(1)), r.text(2), r.text(3), r.bool(4)) }) ?? []
        return Dictionary(rows.map { ($0.0, (agent: $0.1, sid: $0.2, ended: $0.3)) }, uniquingKeysWith: { a, _ in a })
    }

    func sessionTitles(_ registry: Registry?, live: [LiveAgent]) -> [String: String] {
        var out: [String: String] = [:]
        if let reg = registry {
            let rows = (try? reg.db.all("SELECT agent, agent_session_id, title FROM sessions WHERE title IS NOT NULL") { ($0.text(0), $0.text(1), $0.text(2)) }) ?? []
            for (a, s, t) in rows { out["\(a):\(s)"] = t }
        }
        for l in live { if let t = l.title { out["\(l.agent.rawValue):\(l.agentSessionID)"] = t } }
        return out
    }

    // MARK: persistence (app)

    /// Stores attributed and dev processes so attribution survives agent exit (remembered ancestry), marks gone
    /// processes ended, and ends sessions whose agent process died (doc 11 §8).
    public func persist(_ snap: RadarSnapshot, registry: Registry, sessionGraceMs: Int64 = 15_000) throws {
        let now = Clock.nowMsInt()
        try registry.db.transaction(.immediate) {
            var seen = Set<Int64>()
            for p in snap.processes where p.processClass == .dev || p.attribution?.agentSessionID != nil {
                var sessionRow: String?
                if let a = p.attribution, let agent = a.agent, let sid = a.agentSessionID {
                    try registry.db.run("INSERT OR IGNORE INTO agents(kind, display_name) VALUES (?,?)", [agent.rawValue, agent.displayName])
                    sessionRow = try registry.db.scalarText("SELECT id FROM sessions WHERE agent = ? AND agent_session_id = ?", [agent.rawValue, sid])
                    if sessionRow == nil {
                        let id = ULID.make()
                        try registry.db.run("""
                        INSERT INTO sessions(id, agent, agent_session_id, cwd, discovered_via, started_at, last_seen_at, ended_at, end_reason)
                        VALUES (?,?,?,?,'env',?,?,?,?)
                        """, [id, agent.rawValue, sid, p.cwd, p.startedAtMs, now, a.sessionLive ? nil : now, a.sessionLive ? nil : "discovered_dead"])
                        sessionRow = id
                    }
                }
                let projectID = try p.attribution?.projectRoot.flatMap { try registry.db.scalarText("SELECT id FROM projects WHERE root_path = ?", [$0]) }
                try registry.db.run("""
                INSERT INTO processes(pid, proc_start, ppid, pgid, uid, exe_path, name, argv, cwd, class, session_id, project_id, attr_method,
                  attr_confidence, link_state, first_seen_at, last_seen_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(pid, proc_start) DO UPDATE SET ppid = excluded.ppid, cwd = excluded.cwd, class = excluded.class,
                  session_id = coalesce(excluded.session_id, processes.session_id), project_id = coalesce(excluded.project_id, processes.project_id),
                  attr_method = coalesce(excluded.attr_method, processes.attr_method), attr_confidence = coalesce(excluded.attr_confidence, processes.attr_confidence),
                  link_state = excluded.link_state, last_seen_at = excluded.last_seen_at, ended_at = NULL
                """, [p.identity.pid, p.identity.startUs, p.ppid, p.pgid, Int64(getuid()), p.exe, p.name, JSONOutput.string(Array(p.argv.prefix(16))),
                      p.cwd, p.processClass.rawValue, sessionRow, projectID, p.attribution?.method.rawValue, p.attribution?.confidence.rawValue,
                      p.linkState.rawValue, p.startedAtMs, now])
                guard let rowID = try registry.db.scalarInt("SELECT id FROM processes WHERE pid = ? AND proc_start = ?", [p.identity.pid, p.identity.startUs]) else { continue }
                seen.insert(rowID)
                try registry.db.run("UPDATE listeners SET closed_at = ? WHERE process_id = ? AND closed_at IS NULL", [now, rowID])
                for l in p.listeners {
                    try registry.db.run("""
                    INSERT INTO listeners(process_id, port, family, address, scope, first_seen_at, last_seen_at) VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(process_id, port, family, address) DO UPDATE SET last_seen_at = excluded.last_seen_at, closed_at = NULL
                    """, [rowID, l.port, l.family, l.address, l.scope.rawValue, now, now])
                }
            }
            // Processes that disappeared.
            let open = try registry.db.all("SELECT id, pid, proc_start FROM processes WHERE ended_at IS NULL") { ($0.int(0), Int32($0.int(1)), $0.int(2)) }
            let table = ProcessTable.capture()
            for (id, pid, start) in open where !seen.contains(id) && !table.isAlive(ProcessIdentity(pid: pid, startUs: start)) {
                try registry.db.run("UPDATE processes SET ended_at = ? WHERE id = ?", [now, id])
                try registry.db.run("UPDATE listeners SET closed_at = ? WHERE process_id = ? AND closed_at IS NULL", [now, id])
            }
            // Sessions whose agent process is gone (SessionEnd never came: crash, kill, closed window).
            let incarnations = try registry.db.all("SELECT id, session_id, pid, proc_start FROM session_pids WHERE ended_at IS NULL") {
                ($0.int(0), $0.text(1), Int32($0.int(2)), $0.int(3))
            }
            for (id, _, pid, start) in incarnations where !table.isAlive(ProcessIdentity(pid: pid, startUs: start)) {
                try registry.db.run("UPDATE session_pids SET ended_at = ? WHERE id = ?", [now, id])
            }
            try registry.db.run("""
            UPDATE sessions SET ended_at = ?, end_reason = 'pid_gone'
            WHERE ended_at IS NULL AND last_seen_at < ? AND EXISTS (SELECT 1 FROM session_pids sp WHERE sp.session_id = sessions.id)
              AND NOT EXISTS (SELECT 1 FROM session_pids sp WHERE sp.session_id = sessions.id AND sp.ended_at IS NULL)
            """, [now, now - sessionGraceMs])
        }
    }
}

// MARK: - Stopping

public enum StopRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case goneOrReused
    case protected(String)
    case protectedDescendant(String)
    case notPermitted

    public var description: String {
        switch self {
        case .goneOrReused: return "the process has already exited (or its pid was reused)"
        case .protected(let why): return "protected: \(why)"
        case .protectedDescendant(let why): return "a child process is protected: \(why)"
        case .notPermitted: return "permission denied"
        }
    }
}

public struct StopPlan: Sendable, Equatable {
    public enum Mode: Equatable, Sendable { case group(Int32), individual }
    public let target: ProcessIdentity
    public let mode: Mode
    /// Children first, target last.
    public let victims: [ProcessIdentity]
}

public enum StopResult: Sendable, Equatable {
    case terminated
    case stillRunning([Int32])
}

public enum ProcessStopper {
    /// Pure planning on a process table (unit-testable). `isProtected` returns a reason for pids that must survive.
    public static func plan(_ target: ProcessIdentity, table: ProcessTable, isProtected: (Int32) -> String?) -> Result<StopPlan, StopRefusal> {
        guard let t = table[target.pid], t.startUs == target.startUs, !t.zombie else { return .failure(.goneOrReused) }
        if let why = isProtected(t.pid) { return .failure(.protected(why)) }
        let desc = table.descendants(of: t.pid).filter { $0.uid == t.uid && !$0.zombie }
        if let p = desc.first(where: { isProtected($0.pid) != nil }) { return .failure(.protectedDescendant(isProtected(p.pid)!)) }
        let victimSet = Set([t.pid] + desc.map(\.pid))
        let groupMembers = table.entries.values.filter { $0.pgid == t.pgid && !$0.zombie }
        let leaderDead = table[t.pgid] == nil
        let canGroup = (t.pgid == t.pid || leaderDead) && t.pgid > 1 && groupMembers.allSatisfy { victimSet.contains($0.pid) }
        // children first: deeper processes first
        let depth: (Int32) -> Int = { pid in table.ancestors(of: pid).count }
        let ordered = (desc.map(\.identity) + [t.identity]).sorted { depth($0.pid) > depth($1.pid) }
        return .success(StopPlan(target: target, mode: canGroup ? .group(t.pgid) : .individual, victims: ordered))
    }

    /// Sends SIGTERM (or SIGKILL with `force`) and waits up to `timeoutMs` for every victim to exit.
    public static func execute(_ plan: StopPlan, force: Bool, timeoutMs: Int = 5000) -> StopResult {
        let sig = force ? SIGKILL : SIGTERM
        switch plan.mode {
        case .group(let pgid): kill(-pgid, sig)
        case .individual: for v in plan.victims { kill(v.pid, sig) }
        }
        let deadline = Clock.monotonicNs() + UInt64(timeoutMs) * 1_000_000
        while true {
            let table = ProcessTable.capture()
            let alive = plan.victims.filter { table.isAlive($0) }.map(\.pid)
            if alive.isEmpty { return .terminated }
            if Clock.monotonicNs() >= deadline { return .stillRunning(alive) }
            usleep(100_000)
        }
    }
}
