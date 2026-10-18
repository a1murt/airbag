import AirbagCore
import Foundation

enum RadarCommands {
    /// airbag ports [--all] [--json] — listening dev servers with the agent session that started them.
    static func ports(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: [])
        let registry = try? Registry(paths: .resolve(), role: .cli)
        let snap = ProcessRadar().scan(registry: registry)
        let rows = a.has("all") ? snap.processes.filter { !$0.listeners.isEmpty } : snap.servers
        if a.has("json") { Out.encodable(rows); return 0 }
        if rows.isEmpty { print("no dev servers listening"); return 0 }
        for p in rows {
            let ports = p.listeners.map { "\($0.scope == .loopback ? "localhost" : $0.address):\($0.port)" }.joined(separator: ", ")
            let who: String
            if let at = p.attribution, let agent = at.agent {
                let sid = at.agentSessionID.map { String($0.prefix(8)) } ?? "?"
                who = "\(agent.displayName) \(at.sessionTitle.map { "“\($0)” " } ?? "")\(sid)"
            } else { who = "—" }
            let state: String
            switch p.linkState {
            case .attached: state = "live"
            case .detached: state = "live (earlier run)"
            case .orphan: state = "ORPHAN"
            case .unknown: state = p.attribution?.projectRoot != nil ? "project" : "—"
            }
            let mem = p.footprintBytes.map { Out.bytes($0) } ?? "?"
            print("\(String(p.identity.pid).leftPad(6))  \(ports.padding(toLength: 24, withPad: " ", startingAt: 0)) \(p.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(state.padding(toLength: 18, withPad: " ", startingAt: 0)) \(who)  \(mem)")
            if let root = p.attribution?.projectRoot ?? p.cwd { print("        \(root)") }
        }
        print("\(rows.count) server(s), \(snap.orphans.count) orphan(s); scan \(snap.durationMs) ms")
        return 0
    }

    /// airbag stop <pid> [--force]
    static func stop(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: [])
        guard let s = a.positionals.first, let pid = Int32(s) else { throw CLIError.usage("usage: airbag stop <pid> [--force]") }
        let registry = try? Registry(paths: .resolve(), role: .cli)
        let snap = ProcessRadar().scan(registry: registry, includeAll: true)
        guard let p = snap.processes.first(where: { $0.identity.pid == pid }) else { throw CLIError.failed("no such process of yours: \(pid)") }
        let protected = Dictionary(snap.processes.compactMap { q in q.protection.map { (q.identity.pid, $0) } }, uniquingKeysWith: { a, _ in a })
        switch ProcessStopper.plan(p.identity, table: ProcessTable.capture(), isProtected: { protected[$0] }) {
        case .failure(let why): throw CLIError.failed("not stopped — \(why)")
        case .success(let plan):
            let result = ProcessStopper.execute(plan, force: a.has("force"))
            switch result {
            case .terminated: print("stopped \(p.name) (pid \(pid))\(plan.victims.count > 1 ? " and \(plan.victims.count - 1) child process(es)" : "")")
            case .stillRunning(let alive): print("still running after SIGTERM: \(alive.map(String.init).joined(separator: ", ")) — run again with --force to send SIGKILL"); return 1
            }
        }
        return 0
    }
}
