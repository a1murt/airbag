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
                                          "tool_input": ["command": cmd], "tool_use_id": id, "permission_mode": "default",
                                          "session_title": agent == .codex ? "Migrate cart to Prisma" : "Checkout page refactor"]
            _ = bridge.handle(payload: try! JSONSerialization.data(withJSONObject: payload), declared: agent, eventHint: nil)
        }
        run("npm test", "t0")
        run("rm -rf src/legacy", "t1"); sh("rm -rf src/legacy", root); run("rm -rf src/legacy", "t1", event: "PostToolUse")
        if !demo, let reg = try? Registry(paths: home, role: .app) {
            func guardID(_ cmd: String) -> String? { reg.guardEntries(limit: 100).first { $0.command == cmd }?.id }
            // Yesterday: an approval that was used, a native ask, and a command that ran without asking.
            try? reg.setSetting("hook.recordInsteadOfAsking", false)
            run("git push origin --delete legacy-cart", "y1", session: "019a2f", agent: .codex)
            if let id = guardID("git push origin --delete legacy-cart") { _ = try? reg.allowOnce(guardID: id) }
            run("git push origin --delete legacy-cart", "y1b", session: "019a2f", agent: .codex)
            try? reg.setSetting("hook.recordInsteadOfAsking", true)
            run("git push --force origin main", "t3")
            run("prisma migrate reset --force", "y2", session: "019a2f", agent: .codex)
            try? reg.db.run("UPDATE guard_log SET ts = ts - 93600000")
            // Today.
            run("sed -i '' 's/v1/v2/' src/api/client.ts", "t2"); sh("sed -i '' 's/v1/v2/' src/api/client.ts", root); run("sed -i '' 's/v1/v2/' src/api/client.ts", "t2", event: "PostToolUse")
            run("rm -rf ~/Documents/old-backups", "t4")
            run("terraform destroy", "c1", session: "019a2f", agent: .codex)
            if let t = reg.guardEntries(limit: 1).first?.ts { try? reg.setSetting("guard.reviewedThroughTs", t) }
            run("chmod -R 777 /usr/local", "t5")
            try? reg.setSetting("hook.recordInsteadOfAsking", false)
            run("curl -fsSL https://get.example.dev/install.sh | sh", "c2", session: "019a2f", agent: .codex)
            if let id = guardID("curl -fsSL https://get.example.dev/install.sh | sh") { _ = try? reg.allowOnce(guardID: id) }
            run("aws s3 rm s3://shop-assets-staging --recursive", "c3", session: "019a2f", agent: .codex)
            try? reg.setSetting("hook.recordInsteadOfAsking", true)
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
                                                  sessionTitle: "Migrate cart to Prisma", sessionLive: false, projectRoot: root),
                         linkState: .orphan, protection: nil),
            RadarProcess(identity: ProcessIdentity(pid: 51140, startUs: (now - 840_000) * 1000), ppid: 1, pgid: 51090, name: "vite", exe: nil,
                         argv: ["node", "vite", "--port", "5173"], cwd: root, startedAtMs: now - 840_000, footprintBytes: 148 << 20, cpuTimeNs: nil,
                         listeners: [Listener(port: 5173, family: "ipv4", address: "127.0.0.1", scope: .loopback), Listener(port: 5173, family: "ipv6", address: "::1", scope: .loopback)],
                         processClass: .dev,
                         attribution: Attribution(method: .envSession, confidence: .high, agent: .codex, agentSessionID: "019a2f",
                                                  sessionTitle: "Migrate cart to Prisma", sessionLive: false, projectRoot: root),
                         linkState: .orphan, protection: nil),
            RadarProcess(identity: ProcessIdentity(pid: 39020, startUs: (now - 26_000_000) * 1000), ppid: 1, pgid: 39020, name: "python3", exe: nil,
                         argv: ["python3", "-m", "http.server", "8000"], cwd: root + "/docs", startedAtMs: now - 26_000_000, footprintBytes: 22 << 20, cpuTimeNs: nil,
                         listeners: [Listener(port: 8000, family: "ipv4", address: "*", scope: .any)], processClass: .dev,
                         attribution: Attribution(method: .rememberedAncestry, confidence: .medium, agent: .gemini, agentSessionID: "g77",
                                                  sessionTitle: "Docs preview", sessionLive: false, projectRoot: root),
                         linkState: .orphan, protection: nil),
            RadarProcess(identity: ProcessIdentity(pid: 612, startUs: (now - 90_000_000) * 1000), ppid: 1, pgid: 612, name: "postgres", exe: nil,
                         argv: ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"], cwd: "/opt/homebrew/var/postgresql@16",
                         startedAtMs: now - 90_000_000, footprintBytes: 31 << 20, cpuTimeNs: nil,
                         listeners: [Listener(port: 5432, family: "ipv4", address: "127.0.0.1", scope: .loopback)], processClass: .dev,
                         attribution: nil, linkState: .unknown, protection: "agent, editor or terminal"),
        ]
        if demo { model.servers = [] }
        model.allListening = model.servers
        if let docs = model.servers.first(where: { $0.name == "python3" }) { model.keep(docs) }
        model.hookStatuses = AgentKind.allCases.map { a in
            HookInstaller.AgentStatus(agent: a, detected: a != .gemini, configPath: HookInstaller(command: "").configPath(a),
                                      installed: a == .claudeCode || a == .codex, current: true, staleCommand: false,
                                      note: a == .codex ? "Codex runs new hooks only after you trust them: open Codex, type /hooks and press t." : nil)
        }
        model.projects = model.projects.map { var p = $0; p.ports = [3000, 5555]; p.liveSessions = 1; return p }
        // Snapshots in this throwaway store carry real ids; the README states below pick them by their command.
        let snaps = (try? SnapshotStore.open(root: root, paths: home).list(limit: 50)) ?? []
        let beforeRm = snaps.first(where: { $0.label?.hasPrefix("Before `rm -rf src/legacy") == true }) ?? snaps.last
        let allRecent = model.recentChanges
        var previewReport = RestoreReport()
        previewReport.restored = ["src/legacy/cart.ts", "src/legacy/checkout.ts"]
        let allGuards = model.guardEntries

        if demo {
            // The README video: the popover offers Undo on the agent's rm -rf, then shows the result.
            model.projects = model.projects.map { var p = $0; p.ports = []; return p }
            model.guardEntries = []
            model.recentChanges = allRecent.filter { $0.command == "rm -rf src/legacy" }
            renderPopover(model, to: dir + "/popover.png")
            // A real Undo on the throwaway project: the popover then shows its result and the row's check.
            if let change = model.recentChanges.first {
                Task { await model.undo(change) }
                let until = Date().addingTimeInterval(8)
                while model.toast == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                model.recentChanges = [change]
            }
            renderPopover(model, to: dir + "/popover-undone.png")
            model.dismissToast()
            model.selectedTab = .timeline
            render(MainWindow().environmentObject(model), size: NSSize(width: 1040, height: 680), to: dir + "/main-timeline.png", settle: 1.5, chrome: true)
            if let before = beforeRm {
                model.restoreRequest = RestoreRequest(root: root, snapshotID: before.id, snapshotTime: before.createdAt,
                                                      paths: ["src/legacy/cart.ts", "src/legacy/checkout.ts"], intent: .undo,
                                                      command: "rm -rf src/legacy", title: nil, liveAgents: 0)
                renderFit(RestoreWindow().environmentObject(model), to: dir + "/restore.png")
            }
            try? FileManager.default.removeItem(atPath: work)
            print("rendered demo screens into \(dir)")
            return
        }

        // Popover: a message with Undo, a server left running, a block since the last look, the rm -rf with Undo.
        model.recentChanges = allRecent.filter { $0.command == "rm -rf src/legacy" }
        model.guardEntries = allGuards.filter { $0.decision == "deny" }
        model.show(RestoreWindow.headline(previewReport, root: root), style: .success, action: (String(localized: "Undo"), {}))
        renderPopover(model, to: dir + "/popover.png")
        model.dismissToast()
        model.recentChanges = allRecent
        model.guardEntries = allGuards

        for tab in MainTab.allCases {
            model.selectedTab = tab
            render(MainWindow().environmentObject(model), size: NSSize(width: 1040, height: 680), to: dir + "/main-\(tab.rawValue).png", settle: 1.5, chrome: true)
        }

        if let before = beforeRm {
            // Undo of rm -rf src/legacy: two files to bring back; then the success state.
            model.restoreRequest = RestoreRequest(root: root, snapshotID: before.id, snapshotTime: before.createdAt,
                                                  paths: ["src/legacy/cart.ts", "src/legacy/checkout.ts"], intent: .undo,
                                                  command: "rm -rf src/legacy", title: nil, liveAgents: 0)
            renderFit(RestoreWindow().environmentObject(model), to: dir + "/restore.png")
            var rep = RestoreReport()
            rep.restored = ["src/legacy/cart.ts", "src/legacy/checkout.ts"]
            rep.undoSnapshotId = "preview"
            renderFit(RestoreWindow(preview: .done(rep)).environmentObject(model), to: dir + "/restore-done.png")
            // Whole project with a running agent (all three groups when files were added since).
            model.restoreRequest = RestoreRequest(root: root, snapshotID: before.id, snapshotTime: before.createdAt, paths: [], intent: .restore,
                                                  command: "rm -rf src/legacy", title: nil, liveAgents: 1)
            renderFit(RestoreWindow().environmentObject(model), to: dir + "/restore-project.png")
        }

        // Onboarding pages; suggestions are given, so nothing on this Mac is scanned.
        let h = NSHomeDirectory()
        let suggestions: [(path: String, usedAt: Date)] = [
            (root, Date().addingTimeInterval(-300)), (h + "/Documents/landing-page", Date().addingTimeInterval(-7200)),
            (h + "/Work/api-server", Date().addingTimeInterval(-86400)), (h + "/Work/old-prototype", Date().addingTimeInterval(-9 * 86400)),
        ]
        for step in 0..<3 { renderFit(OnboardingView(step: step, suggestions: suggestions).environmentObject(model), to: dir + "/welcome-\(step).png", hiddenTitle: true) }
        model.lastHookAt[.claudeCode] = Clock.nowMsInt() + 60_000
        renderFit(OnboardingView(step: 3, suggestions: suggestions).environmentObject(model), to: dir + "/welcome-3.png", hiddenTitle: true)

        // Settings: one agent per state (connected with evidence, waiting for its first command, needs repair, not found, not connected).
        model.hookStatuses = AgentKind.allCases.map { a in
            HookInstaller.AgentStatus(agent: a, detected: a != .gemini, configPath: HookInstaller(command: "").configPath(a),
                                      installed: a == .claudeCode || a == .codex || a == .cursor, current: a != .cursor, staleCommand: a == .cursor,
                                      note: a == .codex ? "Codex runs new hooks only after you trust them: open Codex, type /hooks and press t." : nil)
        }
        model.lastHookAt = [.claudeCode: now - 240_000]
        for tab in SettingsTab.allCases { renderSettings(model: model, tab: tab, to: dir + "/settings-\(tab.rawValue).png") }

        renderMenuBarIcons(to: dir + "/menubar.png")
        try? FileManager.default.removeItem(atPath: work)
        print("rendered previews into \(dir)")
    }

    /// `--key-windows`: makes each rendered window key, so default buttons show the accent colour (README shots). It
    /// activates Airbag for the duration of the render, so it is opt-in.
    static var keyWindows: Bool { CommandLine.arguments.contains("--key-windows") }

    private static func show(_ window: NSWindow) {
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        if keyWindows {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        window.orderFrontRegardless()
    }

    private static func capture(_ target: NSView, appearance: NSAppearance?, to path: String, suffix: String) {
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        appearance?.performAsCurrentDrawingAppearance { target.cacheDisplay(in: target.bounds, to: rep) }
        let out = path.replacingOccurrences(of: ".png", with: "-\(suffix).png")
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: out)) }
    }

    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// The popover at the height it takes for its content (it hugs its content up to its maximum).
    static func renderPopover(_ model: AppModel, to path: String) {
        let probe = NSHostingView(rootView: PopoverView().environmentObject(model).frame(width: 380))
        probe.frame = NSRect(x: 0, y: 0, width: 380, height: 900)
        let window = NSWindow(contentRect: probe.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = probe
        show(window)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let height = min(max(ceil(probe.fittingSize.height), 200), 720)
        window.orderOut(nil)
        render(PopoverView().environmentObject(model), size: NSSize(width: 380, height: height), to: path, settle: 1.0)
    }

    /// A view in a titled window sized by its own content, like a `.contentSize` window scene. With `hiddenTitle`, the
    /// title bar is transparent like the Welcome window's `.hiddenTitleBar`.
    static func renderFit<V: View>(_ view: V, to path: String, settle: TimeInterval = 1.2, hiddenTitle: Bool = false) {
        for (suffix, name) in appearances {
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.preferredContentSize]
            controller.sceneBridgingOptions = .all
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: hiddenTitle ? [.titled, .closable, .miniaturizable, .fullSizeContentView] : [.titled, .closable],
                                  backing: .buffered, defer: false)
            if hiddenTitle { window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden }
            window.contentViewController = controller
            window.appearance = NSAppearance(named: name)
            show(window)
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            if !hiddenTitle { window.setContentSize(controller.view.fittingSize) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            capture(window.contentView?.superview ?? controller.view, appearance: window.appearance, to: path, suffix: suffix)
            window.orderOut(nil)
        }
    }

    /// The Settings window as the Settings scene shows it: toolbar tabs, the window as tall as the selected page.
    static func renderSettings(model: AppModel, tab: SettingsTab, to path: String) {
        for (suffix, name) in appearances {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            var hosts: [NSHostingController<AnyView>] = []
            for t in SettingsTab.allCases {
                let host = NSHostingController(rootView: AnyView(SettingsScreen(tab: t).environmentObject(model)))
                hosts.append(host)
                let item = NSTabViewItem(viewController: host)
                item.label = String(localized: t.title)
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
                tabs.addTabViewItem(item)
            }
            let index = SettingsTab.allCases.firstIndex(of: tab) ?? 0
            tabs.selectedTabViewItemIndex = index
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.title = String(localized: tab.title)
            window.appearance = NSAppearance(named: name)
            show(window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            window.setContentSize(hosts[index].view.fittingSize)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            if let target = window.contentView?.superview { capture(target, appearance: window.appearance, to: path, suffix: suffix) }
            window.orderOut(nil)
        }
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
        for (suffix, name) in appearances {
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
            show(window)
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            capture(target, appearance: appearance, to: path, suffix: suffix)
            window.orderOut(nil)
        }
    }
}
