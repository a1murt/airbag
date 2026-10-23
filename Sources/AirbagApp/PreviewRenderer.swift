import AirbagCore
import AppKit
import SwiftUI

/// `Airbag --render-previews <dir>`: renders the main screens with realistic data into PNG files so the UI can be
/// reviewed without driving the screen. Uses a throwaway Airbag home and project; nothing on the Mac is touched.
@MainActor
enum PreviewRenderer {
    /// `--render-demo <dir>`: the screens of the README video. The agent runs one `rm -rf src/legacy`; the timeline opens
    /// on that command's card and the restore window lists the two files it deleted.
    static func renderDemo(to dir: String) { renderAll(to: dir, demo: true) }

    static func renderAll(to dir: String, demo: Bool = false) {
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
        if !demo {
            run("sed -i '' 's/v1/v2/' src/api/client.ts", "t2"); sh("sed -i '' 's/v1/v2/' src/api/client.ts", root); run("sed -i '' 's/v1/v2/' src/api/client.ts", "t2", event: "PostToolUse")
            run("git push --force origin main", "t3")
            run("rm -rf ~/Documents/old-backups", "t4")
            run("terraform destroy", "c1", session: "019a2f", agent: .codex)
        }

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
        if demo { model.servers = [] }
        model.allListening = model.servers
        model.hookStatuses = AgentKind.allCases.map { a in
            HookInstaller.AgentStatus(agent: a, detected: a != .gemini, configPath: HookInstaller(command: "").configPath(a),
                                      installed: a == .claudeCode || a == .codex, current: true, staleCommand: false,
                                      note: a == .codex ? "Codex runs new hooks only after you trust them: open Codex, type /hooks and press t." : nil)
        }
        model.projects = model.projects.map { var p = $0; p.ports = [3000, 5555]; p.liveSessions = 1; return p }

        if demo {
            model.projects = model.projects.map { var p = $0; p.ports = []; return p }
            render(PopoverView().environmentObject(model), size: NSSize(width: 380, height: 520), to: dir + "/popover.png")
            model.selectedTab = .timeline
            render(MainWindow().environmentObject(model), size: NSSize(width: 1040, height: 680), to: dir + "/main-timeline.png", settle: 1.5, chrome: true)
            let snaps = (try? SnapshotStore.open(root: root, paths: home).list(limit: 10)) ?? []
            if let before = snaps.first(where: { $0.label?.hasPrefix("Before `rm -rf") == true }) ?? snaps.last {
                model.restoreRequest = RestoreRequest(root: root, snapshotID: before.id, snapshotTime: before.createdAt,
                                                      paths: ["src/legacy/cart.ts", "src/legacy/checkout.ts"], intent: .undo,
                                                      command: "rm -rf src/legacy", title: nil, liveAgents: 0)
                render(RestoreWindow().environmentObject(model), size: NSSize(width: 520, height: 420), to: dir + "/restore.png", settle: 1.5)
            }
            try? FileManager.default.removeItem(atPath: work)
            print("rendered demo screens into \(dir)")
            return
        }
        render(PopoverView().environmentObject(model), size: NSSize(width: 380, height: 640), to: dir + "/popover.png")
        for tab in MainTab.allCases {
            model.selectedTab = tab
            render(MainWindow().environmentObject(model), size: NSSize(width: 1040, height: 680), to: dir + "/main-\(tab.rawValue).png", settle: 1.5, chrome: true)
        }
        render(SettingsScreen().environmentObject(model), size: NSSize(width: 640, height: 720), to: dir + "/settings.png", settle: 1.5)
        do {
            model.restoreRequest = RestoreRequest(root: root, snapshotID: (try? SnapshotStore.open(root: root, paths: home).list(limit: 10).last?.id) ?? "",
                                                    snapshotTime: now - 600_000, paths: [], intent: .restore, command: "rm -rf src/legacy",
                                                    title: nil, liveAgents: 1)
            render(RestoreWindow().environmentObject(model), size: NSSize(width: 520, height: 520), to: dir + "/restore.png", settle: 1.5)
        }
        render(OnboardingView().environmentObject(model), size: NSSize(width: 560, height: 480), to: dir + "/welcome.png", settle: 1.5)
        renderMenuBarIcons(to: dir + "/menubar.png")
        try? FileManager.default.removeItem(atPath: work)
        print("rendered previews into \(dir)")
    }

    /// Every menu bar glyph state, with and without the dot, at 6x on a light and a dark menu bar (for review only).
    static func renderMenuBarIcons(to path: String) {
        let states: [IconState] = [.idle, .protected, .paused, .needsYou, .degraded]
        let scale: CGFloat = 6, cell = NSSize(width: 30 * scale, height: 24 * scale)
        let size = NSSize(width: cell.width * CGFloat(states.count + 1), height: cell.height * 4)
        let img = NSImage(size: size, flipped: true) { _ in
            for (row, (bg, ink)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
                bg.setFill()
                NSRect(x: 0, y: CGFloat(row) * cell.height * 2, width: size.width, height: cell.height * 2).fill()
                for badge in [false, true] {
                    let items: [(IconState, Bool)] = states.map { ($0, false) } + [(.protected, true)]
                    for (col, (state, tick)) in items.enumerated() {
                        let icon = MenuBarIcon.image(state, badge: badge, tick: tick)
                        let tinted = NSImage(size: icon.size, flipped: false) { r in
                            icon.draw(in: r); ink.set(); r.fill(using: .sourceAtop); return true
                        }
                        let w = icon.size.width * scale, h = icon.size.height * scale
                        let y = CGFloat(row) * cell.height * 2 + (badge ? cell.height : 0) + (cell.height - h) / 2
                        tinted.draw(in: NSRect(x: CGFloat(col) * cell.width + (cell.width - w) / 2, y: y, width: w, height: h))
                    }
                }
            }
            return true
        }
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
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

    /// Renders a view into `<path>-light.png` and `<path>-dark.png`. With `chrome`, the view sits in a real titled window
    /// whose toolbar and title come from SwiftUI (scene bridging), and the whole window frame is captured.
    static func render<V: View>(_ view: V, size: NSSize, to path: String, settle: TimeInterval = 0.8, chrome: Bool = false, title: String = "Airbag") {
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = NSAppearance(named: name)
            let window: NSWindow
            let target: NSView
            if chrome {
                let controller = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
                controller.sceneBridgingOptions = .all
                window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
                window.contentViewController = controller
                window.title = title
                window.toolbarStyle = .unified
                window.setContentSize(size)
                target = window.contentView?.superview ?? controller.view
            } else {
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: size)
                window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                target = host
            }
            window.appearance = appearance
            window.backgroundColor = .windowBackgroundColor
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            target.layoutSubtreeIfNeeded()
            guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { continue }
            appearance?.performAsCurrentDrawingAppearance { target.cacheDisplay(in: target.bounds, to: rep) }
            let out = path.replacingOccurrences(of: ".png", with: "-\(suffix).png")
            if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: out)) }
            window.orderOut(nil)
        }
    }
}
