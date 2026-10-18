import Foundation
import Testing
@testable import AirbagCore

/// Starts `python3` listening on a random loopback port with the given environment; returns (process, port).
func startServer(env: [String: String], cwd: String) throws -> (Process, Int) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-c", "import socket,time,sys; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1], flush=True); time.sleep(120)"]
    var e = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("CODEX") }
    for (k, v) in env { e[k] = v }
    p.environment = e
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    var line = Data()
    while !line.contains(UInt8(ascii: "\n")) {
        let d = out.fileHandleForReading.availableData
        if d.isEmpty { break }
        line.append(d)
    }
    guard let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
        p.terminate(); throw SnapshotError.io("server did not report a port")
    }
    return (p, port)
}

/// The actual listening process (python may be a child of the /usr/bin/python3 shim).
func listeningPid(_ snap: RadarSnapshot, port: Int) -> RadarProcess? {
    snap.processes.first { $0.listeners.contains { $0.port == port } }
}

@Suite(.serialized) struct RadarTests {
    @Test func orphanServerFromDeadClaudeSessionIsAttributedByEnvironment() throws {
        let sb = Sandbox("radar"); defer { sb.cleanup() }
        let (server, port) = try startServer(env: ["CLAUDE_CODE_SESSION_ID": "dead-session-1", "CLAUDE_PID": "1"], cwd: sb.root)
        defer { server.terminate() }
        let reg = try Registry(paths: sb.paths, role: .app)
        let radar = ProcessRadar(home: sb.tmp.sub("nohome"), paths: sb.paths)
        let snap = radar.scan(registry: reg)
        let p = try #require(listeningPid(snap, port: port))
        #expect(p.attribution?.method == .envSession)
        #expect(p.attribution?.agent == .claudeCode)
        #expect(p.attribution?.agentSessionID == "dead-session-1")
        #expect(p.linkState == .orphan)
        #expect(snap.orphans.contains { $0.identity == p.identity })
        #expect(p.protection == nil)
        // Persisting discovers the session from the environment and remembers the process.
        try radar.persist(snap, registry: reg)
        #expect(try reg.db.scalarText("SELECT end_reason FROM sessions WHERE agent_session_id = 'dead-session-1'") == "discovered_dead")
        #expect(try reg.db.scalarInt("SELECT count(*) FROM listeners WHERE port = ? AND closed_at IS NULL", [port]) == 1)
        #expect(snap.durationMs < 200)
    }

    @Test func serverUnderLiveAgentIsAttached() throws {
        let sb = Sandbox("radar"); defer { sb.cleanup() }
        let reg = try Registry(paths: sb.paths, role: .app)
        // Register this test process as a live agent incarnation; servers it spawns are its descendants.
        let me = try #require(ProcInfo.bsdInfo(getpid()))
        var rec = HookRecord(agent: "codex", kind: "session_start")
        rec.agentSessionID = "live-thread"
        rec.agentProcess = .init(pid: me.pid, startUs: me.startUs, exe: nil, ppid: me.ppid, pgid: me.pgid)
        try reg.record(rec)
        let (server, port) = try startServer(env: [:], cwd: sb.root)
        defer { server.terminate() }
        let snap = ProcessRadar(home: sb.tmp.sub("nohome"), paths: sb.paths).scan(registry: reg)
        let p = try #require(listeningPid(snap, port: port))
        #expect(p.attribution?.method == .liveAncestry)
        #expect(p.attribution?.agentSessionID == "live-thread")
        #expect(p.linkState == .attached)
    }

    @Test func stopTerminatesServerAndRefusesProtectedProcesses() throws {
        let sb = Sandbox("radar"); defer { sb.cleanup() }
        let (server, port) = try startServer(env: [:], cwd: sb.root)
        defer { if server.isRunning { server.terminate() } }
        let snap = ProcessRadar(home: sb.tmp.sub("nohome"), paths: sb.paths).scan(registry: nil, includeAll: true)
        let p = try #require(listeningPid(snap, port: port))
        let protected = Dictionary(snap.processes.compactMap { q in q.protection.map { (q.identity.pid, $0) } }, uniquingKeysWith: { a, _ in a })
        // Our own process (an ancestor of everything we spawn) is protected.
        let me = try #require(ProcInfo.bsdInfo(getpid()))
        if case .success = ProcessStopper.plan(me.identity, table: ProcessTable.capture(), isProtected: { protected[$0] ?? ($0 == getpid() ? "self" : nil) }) {
            Issue.record("stopping ourselves must be refused")
        }
        // A stale identity (same pid, different start) is refused.
        let stale = ProcessIdentity(pid: p.identity.pid, startUs: p.identity.startUs - 5)
        #expect(ProcessStopper.plan(stale, table: ProcessTable.capture(), isProtected: { _ in nil }) == .failure(.goneOrReused))
        guard case .success(let plan) = ProcessStopper.plan(p.identity, table: ProcessTable.capture(), isProtected: { protected[$0] }) else {
            Issue.record("plan refused"); return
        }
        #expect(ProcessStopper.execute(plan, force: false, timeoutMs: 3000) == .terminated)
        let after = ProcessRadar(home: sb.tmp.sub("nohome"), paths: sb.paths).scan(registry: nil)
        #expect(listeningPid(after, port: port) == nil)
    }

    @Test func stopPlannerPrefersProcessGroupAndOrdersChildrenFirst() {
        let t = ProcessTable(entries: [
            100: ProcEntry(pid: 100, ppid: 1, pgid: 100, uid: 501, startUs: 1, comm: "npm", zombie: false),
            101: ProcEntry(pid: 101, ppid: 100, pgid: 100, uid: 501, startUs: 2, comm: "node", zombie: false),
            102: ProcEntry(pid: 102, ppid: 101, pgid: 100, uid: 501, startUs: 3, comm: "next-server", zombie: false),
            200: ProcEntry(pid: 200, ppid: 1, pgid: 200, uid: 501, startUs: 4, comm: "claude", zombie: false),
        ])
        guard case .success(let plan) = ProcessStopper.plan(ProcessIdentity(pid: 100, startUs: 1), table: t, isProtected: { $0 == 200 ? "agent" : nil }) else {
            Issue.record("refused"); return
        }
        #expect(plan.mode == .group(100))
        #expect(plan.victims.map(\.pid) == [102, 101, 100])
        // A protected descendant blocks the stop.
        let t2 = ProcessTable(entries: t.entries.merging([103: ProcEntry(pid: 103, ppid: 102, pgid: 100, uid: 501, startUs: 5, comm: "claude", zombie: false)]) { a, _ in a })
        #expect(ProcessStopper.plan(ProcessIdentity(pid: 100, startUs: 1), table: t2, isProtected: { $0 == 103 ? "agent" : nil }) == .failure(.protectedDescendant("agent")))
    }

    @Test func sessionEndsWhenAgentProcessIsGone() throws {
        let sb = Sandbox("radar"); defer { sb.cleanup() }
        let reg = try Registry(paths: sb.paths, role: .app)
        var rec = HookRecord(agent: "claude-code", kind: "session_start")
        rec.agentSessionID = "crashed"
        rec.ts = Clock.nowMsInt() - 60_000
        rec.agentProcess = .init(pid: 999_999, startUs: 42, exe: nil, ppid: 1, pgid: 999_999)
        try reg.record(rec)
        let radar = ProcessRadar(home: sb.tmp.sub("nohome"), paths: sb.paths)
        try radar.persist(radar.scan(registry: reg), registry: reg)
        #expect(try reg.db.scalarText("SELECT end_reason FROM sessions WHERE agent_session_id = 'crashed'") == "pid_gone")
    }

    @Test func fullScanIsCheap() {
        let radar = ProcessRadar()
        _ = radar.scan(registry: nil) // warm the cache
        let start = Clock.monotonicNs()
        for _ in 0..<10 { _ = radar.scan(registry: nil) }
        let perScanMs = Double(Clock.monotonicNs() - start) / 10 / 1_000_000
        #expect(perScanMs < 30, "\(perScanMs) ms per scan")
    }
}
