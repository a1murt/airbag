import AirbagCore
import AppKit
import SwiftUI

/// `Airbag --render-previews <dir>`: renders the main screens with realistic data into PNG files so the UI can be
/// reviewed without driving the screen. Uses a throwaway Airbag home and project; nothing on the Mac is touched.
@MainActor
enum PreviewRenderer {
    static func renderAll(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Not the per-user temporary folder: it can never be a protected root (ADR-032), so the demo would be empty.
        let work = "/private/tmp/airbag-preview-" + ULID.make()
        let home = AirbagPaths(home: URL(fileURLWithPath: work + "/home"))
        let proj = work + "/shop-app"
        seed(project: proj)
        let root = FileSystem.canonicalPath(proj) ?? proj
        var cfg = HookBridgeConfig(paths: home, environment: [:])
        cfg.spawnBackground = false
        let bridge = HookBridge(config: cfg)
        func run(_ cmd: String, _ id: String, event: String = "PreToolUse", session: String = "c8f1a2b4", agent: AgentKind = .claudeCode) {
            let payload: [String: Any] = ["session_id": session, "cwd": root, "hook_event_name": event, "tool_name": "Bash",
                                          "tool_input": ["command": cmd], "tool_use_id": id, "permission_mode": "default", "session_title": "Checkout page refactor"]
            _ = bridge.handle(payload: try! JSONSerialization.data(withJSONObject: payload), declared: agent, eventHint: nil)
        }
        run("npm test", "t0")
        run("rm -rf src/legacy", "t1"); sh("rm -rf src/legacy", root); run("rm -rf src/legacy", "t1", event: "PostToolUse")
        run("sed -i '' 's/v1/v2/' src/api/client.ts", "t2"); sh("sed -i '' 's/v1/v2/' src/api/client.ts", root); run("sed -i '' 's/v1/v2/' src/api/client.ts", "t2", event: "PostToolUse")
        run("git push --force origin main", "t3")
        run("rm -rf ~/Documents/old-backups", "t4")
        run("terraform destroy", "c1", session: "019a2f", agent: .codex)

        let model = AppModel(paths: home, demo: false)
        model.refreshProjects(); model.refreshGuard()
        let deadline = Date().addingTimeInterval(5)
        while model.projects.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        model.selectedRoot = root
        model.frozen = true
        let now = Clock.nowMsInt()
        model.servers = [
            RadarProcess(identity: ProcessIdentity(pid: 48211, startUs: (now - 3_600_000) * 1000), ppid: 1, pgid: 48190, name: "next-server", exe: nil,
                         argv: ["next-server"], cwd: root, startedAtMs: now - 3_600_000, footprintBytes: 412 << 20, cpuTimeNs: nil,
                         listeners: [Listener(port: 3000, family: "ipv6", address: "*", scope: .any)], processClass: .dev,
                         attribution: Attribution(method: .envSession, confidence: .high, agent: .claudeCode, agentSessionID: "c8f1a2b4",
                                                  sessionTitle: "Checkout page refactor", sessionLive: true, projectRoot: root),
                         linkState: .detached, protection: nil),
            RadarProcess(identity: ProcessIdentity(pid: 51102, startUs: (now - 900_000) * 1000), ppid: 1, pgid: 51090, name: "node", exe: nil,
                         argv: ["node", "prisma", "studio"], cwd: root, startedAtMs: now - 900_000, footprintBytes: 96 << 20, cpuTimeNs: nil,
                         listeners: [Listener(port: 5555, family: "ipv4", address: "127.0.0.1", scope: .loopback)], processClass: .dev,
                         attribution: Attribution(method: .envSession, confidence: .high, agent: .codex, agentSessionID: "019a2f",
                                                  sessionTitle: nil, sessionLive: false, projectRoot: root),
                         linkState: .orphan, protection: nil),
        ]
        model.allListening = model.servers
        model.hookStatuses = AgentKind.allCases.map { a in
            HookInstaller.AgentStatus(agent: a, detected: a != .gemini, configPath: HookInstaller(command: "").configPath(a),
                                      installed: a == .claudeCode || a == .codex, current: true, staleCommand: false,
                                      note: a == .codex ? "Codex runs new hooks only after you trust them: open Codex, type /hooks and press t." : nil)
        }
        model.projects = model.projects.map { var p = $0; p.ports = [3000, 5555]; p.liveSessions = 1; return p }

        render(PopoverView().environmentObject(model), size: NSSize(width: 380, height: 640), to: dir + "/popover.png")
        for tab in [MainTab.timeline, .radar, .guardLog, .settings] {
            model.selectedTab = tab
            render(MainWindow().environmentObject(model), size: NSSize(width: 1040, height: 680), to: dir + "/main-\(tab.rawValue).png", settle: 1.5)
        }
        do {
            model.restoreRequest = RestoreRequest(root: root, snapshotID: (try? SnapshotStore.open(root: root, paths: home).list(limit: 10).last?.id) ?? "",
                                                    snapshotLabel: "Before `rm -rf src/legacy`", snapshotTime: now - 600_000, paths: [], liveAgents: 1)
            render(RestoreWindow().environmentObject(model), size: NSSize(width: 520, height: 520), to: dir + "/restore.png", settle: 1.5)
        }
        render(OnboardingView().environmentObject(model), size: NSSize(width: 560, height: 480), to: dir + "/welcome.png", settle: 1.5)
        try? FileManager.default.removeItem(atPath: work)
        print("rendered previews into \(dir)")
    }

    static func seed(project: String) {
        let files: [String: String] = [
            "package.json": "{\"name\":\"shop-app\",\"scripts\":{\"dev\":\"next dev\"}}\n",
            ".env": "DATABASE_URL=postgres://localhost/shop\nSTRIPE_KEY=sk_test_123\n",
            "src/app/page.tsx": "export default function Page() { return <main>Shop</main> }\n",
            "src/api/client.ts": "export const API = '/api/v1';\nexport async function get(p: string) { return fetch(API + p) }\n",
            "src/legacy/cart.ts": "// old cart\nexport const cart = [];\n",
            "src/legacy/checkout.ts": "// old checkout\nexport function checkout() {}\n",
        ]
        for (rel, text) in files {
            let p = project + "/" + rel
            try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: p, atomically: true, encoding: .utf8)
        }
        sh("git init -q && git add -A && git -c user.email=p@p -c user.name=p commit -qm init", project)
    }

    static func sh(_ cmd: String, _ cwd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        try? p.run(); p.waitUntilExit()
    }

    static func render<V: View>(_ view: V, size: NSSize, to path: String, settle: TimeInterval = 0.8) {
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = NSAppearance(named: name)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
            let out = path.replacingOccurrences(of: ".png", with: "-\(suffix).png")
            if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: out)) }
            window.orderOut(nil)
        }
    }
}
