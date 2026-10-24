@preconcurrency import AirbagCore
import AppKit
import Combine
import Foundation
import os
import ServiceManagement
import UserNotifications

/// The views of the main window. Settings is its own window (⌘,).
enum MainTab: String, CaseIterable, Identifiable {
    case timeline, radar, guardLog = "guard"
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .timeline: return "Timeline"
        case .radar: return "Radar"
        case .guardLog: return "Guard"
        }
    }
    var symbol: String {
        switch self {
        case .timeline: return "clock.arrow.circlepath"
        case .radar: return "dot.radiowaves.left.and.right"
        case .guardLog: return "exclamationmark.shield"
        }
    }
}

/// Menu bar glyph states, one meaning each (precedence: needsYou > paused > degraded > protected > idle; while paused
/// nothing is snapshotted anyway, so the pause is the state that matters). Something
/// new to look at (a blocked command, a server left running) adds a dot instead of another glyph.
enum IconState: Equatable {
    case idle, protected, paused, needsYou, degraded
    var symbol: String {
        switch self {
        case .idle: return "shield"
        case .protected: return "shield.fill"
        case .paused: return "shield.slash"
        case .needsYou: return "exclamationmark.shield.fill"
        case .degraded: return "shield.lefthalf.filled"
        }
    }
}

struct ProjectRow: Identifiable, Equatable {
    var id: String { root }
    let root: String
    let name: String
    let isWorktree: Bool
    let rootExists: Bool
    var snapshotCount: Int
    var lastSnapshotAt: Int64?
    var pinnedCount: Int
    var liveSessions: Int
    var ports: [Int]
    var bytes: Int64
}

/// A short message with an optional action, e.g. "Restored 2 files in shop-app · Undo".
struct Toast: Identifiable {
    enum Style { case info, success, warning, failure }
    let id = UUID()
    let text: String
    let style: Style
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
}

/// A moment that changed files, as the popover lists it: what changed it and whether it can be undone.
struct RecentChange: Identifiable, Equatable {
    var id: String { snapshotID }
    let root: String
    let snapshotID: String
    let at: Int64
    let trigger: SnapshotTrigger
    var changedCount: Int
    /// The shell command that made the changes (after-command snapshots only).
    let command: String?
    let agent: AgentKind?
    let sessionTitle: String?
    /// For a command that ran long enough for a file-change snapshot to land in the middle: the snapshot taken before
    /// it. Its Undo then reverts everything between that snapshot and this one (as the Timeline row does).
    var base: String?
    var projectName: String { (root as NSString).lastPathComponent }

    /// Recent changes of one project from its timeline (newest first). A command's after snapshot absorbs file-change
    /// snapshots taken while it ran (back to the snapshot its before event points at), so Undo puts back all it did.
    static func list(root: String, entries: [TimelineEntry]) -> [RecentChange] {
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
    init?(root: String, entry: TimelineEntry, hasPrevious: Bool) {
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
}

/// Windows the model can ask for (from a notification, a shortcut or the popover).
enum WindowRequest: Equatable {
    case main(MainTab)
    case settings
    case restore
    case welcome
}

/// An item a window should scroll to and briefly highlight ("Show" in the popover, a notification click).
enum FocusTarget: Equatable {
    case guardEntry(String)
    case snapshot(root: String, id: String)
    case process(ProcessIdentity)
}

/// What the confirmation window shows. Undo puts back what one moment changed (its files, as in the snapshot before
/// it); Restore makes the project or the given files match a chosen snapshot. The window repeats the verb that opened it.
struct RestoreRequest: Equatable, Identifiable {
    enum Intent: Equatable { case undo, restore }
    var id: String { "\(root)|\(snapshotID)|\(paths.joined(separator: ","))|\(created)" }
    let created = Date()
    let root: String
    /// The snapshot whose state is written back.
    let snapshotID: String
    let snapshotTime: Int64
    /// Empty: the whole project.
    let paths: [String]
    let intent: Intent
    /// The agent command the moment is named after, shown in monospace (nil for file changes, manual snapshots…).
    let command: String?
    /// A readable name for a moment without a command ("File changes", "Manual snapshot").
    let title: String?
    let liveAgents: Int
    var scope: RestoreScope { paths.isEmpty ? .root : .paths(paths) }
}

/// Something that stops Airbag from protecting, shown as the popover headline with one fix.
enum ProtectionIssue: Equatable, Identifiable {
    case databaseUnavailable
    case lowDisk(free: Int64)
    case brokenHooks([AgentKind])
    case noAgentConnected
    var id: String { fixTitle }
    var text: String {
        switch self {
        case .databaseUnavailable: return String(localized: "Airbag's database is unavailable")
        case .lowDisk(let free):
            let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return String(localized: "Snapshots paused: only \(freeText) free")
        case .brokenHooks(let agents):
            return String(localized: "\(ListFormatter.localizedString(byJoining: agents.map(\.displayName)))'s connection is broken")
        case .noAgentConnected: return String(localized: "No agents connected. Only file saves are snapshotted.")
        }
    }
    var fixTitle: String {
        switch self {
        case .databaseUnavailable: return String(localized: "Show Log")
        case .lowDisk: return String(localized: "Free Up Space…")
        case .brokenHooks: return String(localized: "Repair")
        case .noAgentConnected: return String(localized: "Connect…")
        }
    }
}

/// Result of a manual snapshot, shown on the button that asked for it.
enum ManualSnapshotResult: Equatable {
    case created(changed: Int)
    case unchanged
    case failed(String)
}

enum LoginItemState { case on, off, needsApproval }

/// Everything the UI shows, refreshed from the registry, the stores and the radar.
@MainActor
final class AppModel: ObservableObject {
    let paths: AirbagPaths
    let demo: Bool
    /// Preview rendering: keep injected data (no radar scans or hook refreshes).
    var frozen = false
    /// Main-thread connection (UI reads and user actions).
    private(set) var registry: Registry?
    /// Connection used only on `work` (SQLite connections must not be shared across threads).
    nonisolated(unsafe) private var workRegistry: Registry?
    let radar: ProcessRadar
    private let work = DispatchQueue(label: "dev.airbag.work", qos: .utility)
    private let snapshotQueue = DispatchQueue(label: "dev.airbag.snapshot", qos: .utility)
    private var watcher: FileWatcher?
    private var wakeServer: WakeSocketServer?
    private var radarTimer: Timer?
    private var hourly: Timer?
    private var seenOrphans = Set<ProcessIdentity>()
    private var notifiedSessions = Set<String>()
    private var notifiedOrphans = Set<ProcessIdentity>()
    /// Guard entries already known (only newer ones are notified; nil until the first load).
    private var knownGuardIDs: Set<String>?

    @Published var selectedTab: MainTab = .timeline { didSet { if selectedTab != oldValue { scheduleRadar() } } }
    @Published var selectedRoot: String?
    @Published var projects: [ProjectRow] = [] {
        didSet { if oldValue.contains(where: { $0.liveSessions > 0 }) != projects.contains(where: { $0.liveSessions > 0 }) { scheduleRadar() } }
    }
    @Published var servers: [RadarProcess] = [] { didSet { if oldValue.isEmpty != servers.isEmpty { scheduleRadar() } } }
    @Published var allListening: [RadarProcess] = []
    @Published var guardEntries: [GuardEntry] = []
    @Published var hookStatuses: [HookInstaller.AgentStatus] = []
    /// When each agent last called Airbag (proof that its hook works).
    @Published var lastHookAt: [AgentKind: Int64] = [:]
    @Published var pausedUntil: Date?
    /// Agent commands that ran without a snapshot during the current or last pause.
    @Published var unprotectedDuringPause = 0
    private var pausedSince: Date?
    @Published var snapshotting = false
    /// Projects with a manual snapshot in flight (their buttons show progress).
    @Published var snapshottingRoots: Set<String> = []
    /// Something new to look at since the popover was last opened (the dot on the menu bar icon).
    @Published var badge = false
    /// Briefly true after a snapshot was taken: the menu bar shows a check for a moment.
    @Published private(set) var tick = false
    private var lastTick = Date.distantPast
    /// The short message shown at the top of the popover and the bottom of the main window.
    @Published private(set) var toast: Toast?
    private var toastTimer: Timer?
    /// Change-bearing snapshots of all projects, newest first (the popover's "Recent changes").
    @Published var recentChanges: [RecentChange] = []
    /// Agent shell commands Airbag checked since midnight (proof that protection is working).
    @Published var commandsToday = 0
    /// Increases on every hook call, so open views reload even when a command changed nothing.
    @Published private(set) var hookTick = 0
    /// A window the app wants opened; `MenuBarLabel` (always alive) performs it with SwiftUI's window actions.
    @Published var windowRequest: WindowRequest?
    /// "Add Project…" was chosen (menu ⌘O, an empty state): the main window shows the folder panel once it is open.
    @Published var addProjectRequested = false
    /// The row a window should scroll to and highlight; the screen clears it once shown.
    @Published var focus: FocusTarget?
    @Published var popoverVisible = false { didSet { if popoverVisible { badge = false; markSeen() }; scheduleRadar() } }
    @Published var mainWindowVisible = false { didSet { if mainWindowVisible { badge = false }; scheduleRadar() } }
    /// When each orphan was first seen; notifications wait for a grace period (the session may resume).
    private var orphanSince: [ProcessIdentity: Date] = [:]
    /// Servers the user chose to keep running (stored in the registry, so they stay quiet after a relaunch).
    @Published private(set) var keptProcesses = Set<ProcessIdentity>()
    @Published var restoreRequest: RestoreRequest?
    /// The last restore, for "Undo Restore" (⌥⇧⌘Z) after its message is gone. It expires once newer work lands in that
    /// project (a newer snapshot than the one the restore left) or after 10 minutes, so it never silently discards
    /// later work.
    @Published private(set) var lastRestore: (root: String, undoSnapshot: String, scope: RestoreScope, latestAfter: String?, at: Date)?
    /// Moments undone this session (their snapshot id → the snapshot the undo took first), so the popover keeps their
    /// check and ⌥⌘Z moves on to the next one instead of undoing the same moment twice.
    @Published private(set) var undoneMoments: [String: (root: String, at: Int64, undoSnapshot: String)] = [:]
    /// The outcome of the first snapshot of a folder added in this session (onboarding and Add Project show it).
    @Published private(set) var firstSnapshotResults: [String: ManualSnapshotResult] = [:]
    private var radarInterval: TimeInterval = 0
    private var radarWasWatched = false
    private var radarPokes: [DispatchWorkItem] = []
    private var projectsRefreshRunning = false
    private var projectsRefreshAgain = false
    private var pauseTimer: Timer?
    @Published var retentionDays: Int = 7
    @Published var budgetGB: Int = 5
    @Published var disabledRules: Set<String> = []
    @Published var strictMode = false
    @Published var recordInsteadOfAsking = true
    /// Free bytes when the last snapshot was refused for low disk; cleared by the next snapshot that works.
    @Published private(set) var lowDiskFree: Int64?
    /// Newest Guard entry the user has looked at (persisted, so "Since you last looked" survives a relaunch).
    @Published private(set) var guardReviewedThrough: Int64 = 0
    @Published private(set) var loginItem: LoginItemState = .off

    /// Servers whose agent session has ended (shown in Radar, with the kept ones marked).
    var orphans: [RadarProcess] { servers.filter { $0.linkState == .orphan } }
    /// Ended-session servers the user has not chosen to keep: the ones Airbag asks about.
    var leftRunning: [RadarProcess] { orphans.filter { !keptProcesses.contains($0.identity) } }
    /// Commands an agent is waiting on: Airbag stopped it until the user approves (spec §6.2). Native asks are
    /// answered in the agent's own prompt and never listed here.
    var needsApproval: [GuardEntry] {
        guardEntries.filter { g in
            g.resolution == nil && g.decision == "deny_fallback" && Date(timeIntervalSince1970: Double(g.ts) / 1000) > Date().addingTimeInterval(-6 * 3600)
        }
    }
    /// Blocked and ran-without-asking commands of the last day that the user has not looked at yet.
    var unseenGuards: [GuardEntry] {
        let dayAgo = Int64(Date().addingTimeInterval(-86400).timeIntervalSince1970 * 1000)
        return guardEntries.filter { ($0.decision == "deny" || $0.decision == "allow_fallback") && $0.ts > max(guardReviewedThrough, dayAgo) }
    }
    /// Kept for the views written against the first popover: the approvals only.
    var attentionGuards: [GuardEntry] { needsApproval }

    var protectionIssues: [ProtectionIssue] {
        var out: [ProtectionIssue] = []
        if registry == nil && !demo && !frozen { out.append(.databaseUnavailable) }
        if let free = lowDiskFree { out.append(.lowDisk(free: free)) }
        let broken = hookStatuses.filter { $0.installed && $0.brokenCommand }.map(\.agent)
        if !broken.isEmpty { out.append(.brokenHooks(broken)) }
        if hookStatuses.contains(where: { $0.detected }) && !hookStatuses.contains(where: { $0.installed }) {
            out.append(.noAgentConnected)
        }
        return out
    }

    var iconState: IconState {
        if !needsApproval.isEmpty { return .needsYou }
        if pausedUntil != nil { return .paused }
        if !protectionIssues.isEmpty { return .degraded }
        if projects.isEmpty { return .idle }
        return .protected
    }

    /// Why hooks cannot be installed from where the app runs now (a hook must point at a binary that stays put).
    var installLocationProblem: String? {
        guard runsFromTemporaryLocation else { return nil }
        if stableHomebrewCLI != nil { return nil }
        return String(localized: "Move Airbag to the Applications folder first: it runs from a disk image or a temporary location, and hooks would break when that goes away.")
    }

    /// The app runs from a mounted disk image or Gatekeeper's translocation folder.
    var runsFromTemporaryLocation: Bool {
        let path = Bundle.main.bundleURL.path
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    private var stableHomebrewCLI: String? {
        ["/opt/homebrew/bin/airbag", "/usr/local/bin/airbag"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The path written into agent configs: the copy inside an installed app, else the Homebrew link, else this bundle.
    var cliPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/airbag").path
        let inApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/") || Bundle.main.bundleURL.path.hasPrefix(NSHomeDirectory() + "/Applications/")
        if inApplications && FileManager.default.fileExists(atPath: bundled) { return bundled }
        if let brew = stableHomebrewCLI { return brew }
        return FileManager.default.fileExists(atPath: bundled) ? bundled : "/Applications/Airbag.app/Contents/Helpers/airbag"
    }

    var installer: HookInstaller { HookInstaller(command: cliPath) }

    init(paths: AirbagPaths = .resolve(), demo: Bool = false) {
        self.paths = paths
        self.demo = demo
        self.radar = ProcessRadar(paths: paths)
        if !demo {
            try? paths.prepare()
            Log.shared.configure(file: paths.logs.appendingPathComponent("app.log"), category: "app")
            do {
                registry = try Registry(paths: paths, role: .app)
                workRegistry = try Registry(paths: paths, role: .app)
            } catch { Log.shared.warn("registry: \(error)") }
            loadSettings()
        }
        refreshLoginItem()
    }

    // MARK: lifecycle

    func start() {
        guard !demo else { return }
        refreshAll()
        startWatching()
        do {
            let server = WakeSocketServer(paths: paths) { [weak self] msg in
                Task { @MainActor in self?.hookEvent(msg) }
            }
            try server.start()
            wakeServer = server
        } catch { Log.shared.warn("wake socket: \(error)") }
        hourly = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.runRetention() } }
        // Stores created while the app was busy (CLI, another user session) show up within a minute.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshProjects(); self?.refreshGuard() } }
        work.asyncAfter(deadline: .now() + 30) { [weak self] in Task { @MainActor in self?.runRetention() } }
        // The login item can be approved in System Settings while Airbag runs.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLoginItem() }
        }
        scheduleRadar()
    }

    func stop() {
        watcher?.stop()
        wakeServer?.stop()
        radarTimer?.invalidate()
        radarInterval = 0
    }

    private func hookEvent(_ msg: [String: Any]) {
        hookTick += 1
        if let agent = (msg["agent"] as? String).flatMap(AgentKind.init(rawValue:)) { lastHookAt[agent] = Clock.nowMsInt() }
        if (msg["skipped"] as? String) == "low_disk", lowDiskFree == nil { lowDiskFree = FileSystem.availableBytes(at: paths.home.path) ?? 0 }
        refreshGuard()
        refreshProjects()
        // Servers bind a moment after the command that starts them; a burst of commands gives one series of scans.
        radarPokes.forEach { $0.cancel() }
        radarPokes = [0.3, 2.0, 10.0].map { delay in
            let item = DispatchWorkItem { [weak self] in self?.scanRadar() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
        // Blocked, waiting for approval, or run without asking: the user should look (the popover lists all three).
        if let d = msg["decision"] as? String, ["deny", "deny_fallback", "allow_fallback"].contains(d), !popoverVisible { badge = true }
    }

    func refreshAll() {
        guard !frozen else { return }
        refreshProjects()
        refreshGuard()
        refreshHooks()
        scanRadar()
    }

    /// `open -a Airbag` or a double-click while Airbag already runs: show the main window instead of nothing.
    func reopen() {
        windowRequest = needsOnboarding ? .welcome : .main(selectedTab)
    }

    // MARK: projects and stores

    /// At most one refresh runs, and at most one more follows (agents in auto mode send a hook call per command).
    func refreshProjects() {
        guard !demo else { return }
        if projectsRefreshRunning { projectsRefreshAgain = true; return }
        projectsRefreshRunning = true
        let paths = self.paths
        let reg = registry
        let workReg = workRegistry
        let pauseStart = pausedSince.map { Int64($0.timeIntervalSince1970 * 1000) }
        work.async {
            var rows: [ProjectRow] = []
            var recent: [RecentChange] = []
            var latestIDs: [String: String] = [:]
            for loc in SnapshotStore.allStores(paths: paths) {
                guard let store = try? SnapshotStore.openLocation(loc, paths: paths) else { continue }
                let latest = try? store.latest()
                latestIDs[loc.root] = latest?.id
                let usage = try? store.usage()
                let pinned = (try? store.pinnedCount()) ?? 0
                let layout = GitLayout.inspect(root: loc.root)
                rows.append(ProjectRow(root: loc.root, name: (loc.root as NSString).lastPathComponent, isWorktree: layout.isWorktree,
                                       rootExists: loc.rootExists, snapshotCount: usage?.snapshots ?? 0, lastSnapshotAt: latest?.createdAt,
                                       pinnedCount: pinned, liveSessions: 0, ports: [], bytes: usage?.objectBytes ?? 0))
                if loc.rootExists, let workReg {
                    recent += RecentChange.list(root: loc.root, entries: workReg.timeline(store: store, limit: 12))
                }
            }
            let today = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
            let counts = workReg?.commandCounts(since: today) ?? (checked: 0, unprotected: 0)
            let paused = pauseStart.flatMap { workReg?.commandCounts(since: $0).unprotected } ?? 0
            recent.sort { $0.at > $1.at }
            Task { @MainActor in
                if self.commandsToday != counts.checked { self.commandsToday = counts.checked }
                if self.unprotectedDuringPause != paused { self.unprotectedDuringPause = paused }
                let top = Array(recent.prefix(5))
                if top != self.recentChanges { self.recentChanges = top }
                let live = reg?.liveSessionCounts() ?? [:]
                var withLive = rows.map { r -> ProjectRow in var r = r; r.liveSessions = live[r.root] ?? 0; return r }
                for (i, r) in withLive.enumerated() { withLive[i].ports = self.ports(for: r.root) }
                let sorted = withLive.sorted { ($0.lastSnapshotAt ?? 0) > ($1.lastSnapshotAt ?? 0) }
                if sorted != self.projects { self.projects = sorted }
                // Keep a selection that is still being added (its store appears after the first snapshot).
                if let sel = self.selectedRoot {
                    let known = self.projects.contains { $0.root == sel } || self.snapshottingRoots.contains(sel)
                        || SnapshotStore.storeExists(root: sel, paths: self.paths)
                    if !known { self.selectedRoot = self.projects.first?.root }
                } else {
                    self.selectedRoot = self.projects.first?.root
                }
                // Undo Restore expires once newer work landed in that project.
                if let r = self.lastRestore, latestIDs[r.root] != r.latestAfter || Date().timeIntervalSince(r.at) > 600 { self.lastRestore = nil }
                self.restartWatcherIfNeeded()
                self.projectsRefreshRunning = false
                if self.projectsRefreshAgain { self.projectsRefreshAgain = false; self.refreshProjects() }
            }
        }
    }

    /// Ports of the servers inside a project, each once (forked workers and dual-stack sockets share a port).
    private func ports(for root: String) -> [Int] {
        Array(Set(servers.filter { s in (s.attribution?.projectRoot ?? s.cwd).map { $0 == root || $0.hasPrefix(root + "/") } ?? false }
            .flatMap { $0.listeners.map(\.port) })).sorted()
    }

    /// The project rows' ports follow the radar (a stopped server's link goes away with the next scan).
    private func refreshProjectPorts() {
        let updated = projects.map { p -> ProjectRow in var p = p; p.ports = ports(for: p.root); return p }
        if updated != projects { projects = updated }
    }

    private var watchedRoots: [String] = []

    private func restartWatcherIfNeeded() {
        let roots = projects.filter(\.rootExists).map(\.root).sorted()
        guard roots != watchedRoots else { return }
        watchedRoots = roots
        startWatching()
    }

    private func startWatching() {
        watcher?.stop()
        guard !watchedRoots.isEmpty, pausedUntil == nil else { watcher = nil; return }
        let w = FileWatcher(roots: watchedRoots, quietSeconds: 3, maxSeconds: 30, queue: snapshotQueue) { [weak self] root, _ in
            _ = self?.snapshotSync(root: root, trigger: .fsevents, label: nil)
        }
        w.start()
        watcher = w
    }

    /// Runs on `snapshotQueue`.
    nonisolated private func snapshotSync(root: String, trigger: SnapshotTrigger, label: String?) -> SnapshotOutcome? {
        Task { @MainActor in self.snapshotting = true }
        let outcome: SnapshotOutcome?
        do {
            outcome = try SnapshotStore.open(root: root, paths: paths).snapshot(SnapshotRequest(trigger: trigger, label: label, lockWaitMs: 5000))
        } catch {
            outcome = .failed(String(describing: error))
        }
        Task { @MainActor in
            self.snapshotting = false
            switch outcome {
            case .created:
                self.lowDiskFree = nil
                self.showTick()
                self.refreshProjects()
            case .unchanged: self.lowDiskFree = nil
            case .lowDisk(let avail): self.lowDiskFree = avail
            case .failed(let why) where trigger != .fsevents: Log.shared.warn("snapshot \(root): \(why)")
            default: break
            }
        }
        return outcome
    }

    /// A check mark on the menu bar icon for a moment: Airbag just saved a snapshot. At most every 10 s.
    private func showTick() {
        guard Date().timeIntervalSince(lastTick) > 10 else { return }
        lastTick = Date()
        tick = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.tick = false }
    }

    /// Takes a snapshot now; the result is shown on the button that asked (progress, then a check or the reason).
    @discardableResult
    func snapshotNow(_ root: String) async -> ManualSnapshotResult {
        snapshottingRoots.insert(root)
        defer { snapshottingRoots.remove(root) }
        let outcome: SnapshotOutcome? = await withCheckedContinuation { cont in
            snapshotQueue.async { [weak self] in
                cont.resume(returning: self?.snapshotSync(root: root, trigger: .manual, label: String(localized: "Manual snapshot")))
            }
        }
        return Self.manualResult(outcome)
    }

    /// What a snapshot outcome means for the person who asked for it.
    static func manualResult(_ outcome: SnapshotOutcome?) -> ManualSnapshotResult {
        switch outcome {
        case .created(let info, _): return .created(changed: info.changedCount)
        case .unchanged: return .unchanged
        case .busy: return .failed(String(localized: "Another snapshot or restore is running; try again in a moment."))
        case .lowDisk(let avail):
            let freeText = ByteCountFormatter.string(fromByteCount: avail, countStyle: .file)
            return .failed(String(localized: "Snapshots paused: only \(freeText) free"))
        case .tooLarge(let fileCount, _): return .failed(String(localized: "This folder is too large to snapshot (\(fileCount) files)."))
        case .failed(let why): return .failed(why)
        case nil: return .failed(String(localized: "The folder could not be read."))
        }
    }

    /// Menu variant (⌘S, context menus): the result comes back as a message, since no button shows it.
    func snapshotNow(_ root: String) {
        Task {
            switch await snapshotNow(root) {
            case .created: show(String(localized: "Snapshot taken"), style: .success)
            case .unchanged: show(String(localized: "No changes since the last snapshot"))
            case .failed(let why): show(why, style: .failure)
            }
        }
    }

    func snapshotAll() {
        Task {
            var createdCount = 0
            var failure: String?
            for p in projects where p.rootExists {
                switch await snapshotNow(p.root) {
                case .created: createdCount += 1
                case .unchanged: break
                case .failed(let why): failure = failure ?? why
                }
            }
            if let failure { show(failure, style: .failure) }
            else if createdCount > 0 { show(String(localized: "Snapshot taken of \(createdCount) projects"), style: .success) }
            else { show(String(localized: "No changes since the last snapshot")) }
        }
    }

    /// Starts protecting a folder; returns why it cannot be protected, or nil.
    @discardableResult
    func addProject(_ url: URL, announce: Bool = true) -> String? {
        let path = FileSystem.canonicalPath(url.path) ?? url.path
        do {
            _ = try SnapshotStore.validateRoot(path, paths: paths)
            try? IgnoredRoots.set(path, ignored: false, paths: paths)
            // Adding a folder that is already protected takes an ordinary snapshot (edits since the last one stay undoable).
            let existing = SnapshotStore.storeExists(root: path, paths: paths)
            snapshottingRoots.insert(path)
            firstSnapshotResults[path] = nil
            snapshotQueue.async { [weak self] in
                let outcome = self?.snapshotSync(root: path, trigger: existing ? .manual : .initial,
                                                 label: existing ? String(localized: "Manual snapshot") : String(localized: "Project added"))
                Task { @MainActor in
                    if !existing { self?.firstSnapshotResults[path] = Self.manualResult(outcome) }
                    self?.snapshottingRoots.remove(path)
                    self?.refreshProjects()
                }
            }
            if announce {
                show(existing ? String(localized: "\(url.lastPathComponent) is already protected") : String(localized: "Protecting \(url.lastPathComponent)…"),
                     style: .success)
            }
            return nil
        } catch {
            let message = describe(error)
            if announce { show(message, style: .failure) }
            return message
        }
    }

    /// "Stop Protecting…": deletes the project's snapshots and stops taking new ones there (Guard rules still apply).
    /// Adding the folder again protects it again.
    func removeProject(root: String) {
        guard !snapshottingRoots.contains(root) else {
            show(String(localized: "Another snapshot or restore is running; try again in a moment."), style: .failure); return
        }
        let paths = self.paths
        let name = (root as NSString).lastPathComponent
        snapshotQueue.async { [weak self] in
            let result: String? = {
                do { try IgnoredRoots.set(root, ignored: true, paths: paths); try SnapshotStore.removeStore(root: root, paths: paths); return nil }
                catch { return String(describing: error) }
            }()
            Task { @MainActor in
                guard let self else { return }
                if let result { self.show(result, style: .failure) } else { self.show(String(localized: "Stopped protecting \(name)")) }
                self.undoneMoments = self.undoneMoments.filter { $0.value.root != root }
                if self.lastRestore?.root == root { self.lastRestore = nil }
                if self.selectedRoot == root { self.selectedRoot = nil }
                self.refreshProjects()
            }
        }
    }

    func revealInFinder(_ path: String) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }

    /// Selects files in Finder (at most ten), or their folder.
    func revealFiles(root: String, paths rel: [String]) {
        let urls = rel.prefix(10).map { URL(fileURLWithPath: root).appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { revealInFinder(root) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: timeline

    func store(for root: String) -> SnapshotStore? {
        guard let loc = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }) else { return nil }
        return try? SnapshotStore.openLocation(loc, paths: paths)
    }

    /// The newest 200 moments of a project, and whether the store holds older ones (the oldest listed moment has no
    /// "before" when it is the first snapshot left after cleanup, so it cannot be undone).
    func timeline(root: String) async -> (entries: [TimelineEntry], hasOlder: Bool) {
        let reg = workRegistry
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                guard let loc = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }),
                      let store = try? SnapshotStore.openLocation(loc, paths: paths) else { cont.resume(returning: ([], false)); return }
                let entries = reg.map { $0.timeline(store: store) }
                    ?? ((try? store.list(limit: 200)) ?? []).map { TimelineEntry(snapshot: $0, commands: []) }
                let hasOlder = entries.last.map { (try? store.list(limit: 1, beforeSeq: $0.snapshot.seq))?.first != nil } ?? false
                cont.resume(returning: (entries, hasOlder))
            }
        }
    }

    /// Files a snapshot recorded as changed. Nil when the caller was cancelled before its turn on the queue (a row that
    /// scrolled away), so a long scroll does not queue work for every row.
    func changes(root: String, snapshot: String) async -> [FileChange]? {
        let paths = self.paths
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                work.async {
                    if cancelled.withLock({ $0 }) { cont.resume(returning: nil); return }
                    let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
                    cont.resume(returning: (try? s?.changes(in: snapshot)) ?? [])
                }
            }
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    /// Files that differ between two snapshots (what a command changed when its effect spans several snapshots).
    func changes(root: String, from base: String, to effect: String) async -> [FileChange]? {
        let paths = self.paths
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                work.async {
                    if cancelled.withLock({ $0 }) { cont.resume(returning: nil); return }
                    let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
                    cont.resume(returning: (try? s?.diff(from: base, to: effect)) ?? [])
                }
            }
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    /// Snapshots of a project whose changes touch a path containing `text` (Timeline search by file name).
    func snapshots(root: String, touching text: String) async -> Set<String> {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
                cont.resume(returning: (try? s?.snapshotIDs(touchingPathContaining: text)) ?? [])
            }
        }
    }

    /// A file as it changed in a snapshot (against the snapshot before it), or between two snapshots.
    func fileDiff(root: String, snapshot: String, path: String, from base: String? = nil) async -> TextDiff? {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                guard let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap({ try? SnapshotStore.openLocation($0, paths: paths) }),
                      let info = try? s.info(snapshot) else { cont.resume(returning: nil); return }
                if let base { cont.resume(returning: try? s.fileDiff(path: path, from: base, to: snapshot)); return }
                // Diff against the previous snapshot: what this snapshot recorded as changed.
                let prev = (try? s.list(limit: 1, beforeSeq: info.seq))?.first
                if let prev { cont.resume(returning: try? s.fileDiff(path: path, from: prev.id, to: snapshot)) }
                else { cont.resume(returning: try? s.fileDiff(path: path, from: snapshot, to: snapshot)) }
            }
        }
    }

    /// The snapshot right before `snapshot` in its store (what "Undo" on it goes back to).
    func previousSnapshot(root: String, of snapshot: String) async -> SnapshotInfo? {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
                guard let s, let info = try? s.info(snapshot) else { cont.resume(returning: nil); return }
                cont.resume(returning: (try? s.list(limit: 1, beforeSeq: info.seq))?.first)
            }
        }
    }

    func planRestore(root: String, snapshot: String, scope: RestoreScope) async -> RestorePlan? {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            snapshotQueue.async {
                let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
                cont.resume(returning: try? s?.planRestore(to: snapshot, scope: scope))
            }
        }
    }

    /// Opens the confirmation window for restoring a project or some of its files to a snapshot.
    func requestRestore(root: String, snapshot: String, time: Int64, paths: [String] = [], intent: RestoreRequest.Intent = .restore,
                        command: String? = nil, title: String? = nil) {
        restoreRequest = RestoreRequest(root: root, snapshotID: snapshot, snapshotTime: time, paths: paths, intent: intent, command: command,
                                        title: title, liveAgents: projects.first { $0.root == root }?.liveSessions ?? 0)
        windowRequest = .restore
    }

    /// Restores on the snapshot queue. `paths` resolves the scope once the store is open (an undo's changed files).
    private func performRestore(root: String, scope resolve: @escaping @Sendable (SnapshotStore) throws -> (target: String, scope: RestoreScope))
        async -> Result<(report: RestoreReport, scope: RestoreScope, latestAfter: String?), Error> {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            snapshotQueue.async {
                do {
                    guard let loc = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }) else { throw SnapshotError.notFound(root) }
                    let s = try SnapshotStore.openLocation(loc, paths: paths)
                    let (target, scope) = try resolve(s)
                    let report = try s.restore(to: target, scope: scope)
                    cont.resume(returning: .success((report, scope, try? s.latest()?.id)))
                } catch { cont.resume(returning: .failure(error)) }
            }
        }
    }

    private func remember(_ report: RestoreReport, root: String, scope: RestoreScope, latestAfter: String?) {
        guard let undo = report.undoSnapshotId else { lastRestore = nil; return }
        lastRestore = (root, undo, scope, latestAfter, Date())
    }

    /// Restores and reports the result as a message with Undo; the Restore window shows its own success state too.
    func restore(root: String, snapshot: String, scope: RestoreScope, announce: Bool = true) async -> Result<RestoreReport, Error> {
        let result = await performRestore(root: root) { _ in (snapshot, scope) }
        refreshProjects()
        switch result {
        case .success(let r):
            remember(r.report, root: root, scope: scope, latestAfter: r.latestAfter)
            // A whole restore can bring back what an undone moment removed, so those checks no longer hold.
            undoneMoments = undoneMoments.filter { $0.value.root != root }
            if announce { announceRestore(r.report, root: root, scope: scope) }
            return .success(r.report)
        case .failure(let e): return .failure(e)
        }
    }

    /// "Undo" on a moment: puts back the files that snapshot recorded as changed (or the given ones), as they were in the
    /// snapshot before it. Runs without a confirmation because it is reversible: the restore snapshots first and the
    /// message offers Undo. The target is always found in the store, never from what a filtered list shows.
    @discardableResult
    func undoChanges(root: String, snapshot: String, paths only: [String]? = nil) async -> RestoreReport? {
        await undo(root: root, moment: snapshot, paths: only) { s in
            guard let info = try s.info(snapshot), let previous = try s.list(limit: 1, beforeSeq: info.seq).first else {
                throw SnapshotError.notFound(snapshot)
            }
            return (previous.id, .paths(try only ?? s.changes(in: snapshot).map(\.path)), info.createdAt)
        }
    }

    /// Undo of a command whose effect spans several snapshots (a file-change snapshot taken while it ran): the files that
    /// differ between `base` (before the command) and `effect` (after it) go back to `base`.
    @discardableResult
    func undoChanges(root: String, from base: String, to effect: String, paths only: [String]? = nil) async -> RestoreReport? {
        await undo(root: root, moment: effect, paths: only) { s in
            guard let info = try s.info(effect), try s.info(base) != nil else { throw SnapshotError.notFound(effect) }
            return (base, .paths(try only ?? s.diff(from: base, to: effect).map(\.path)), info.createdAt)
        }
    }

    private func undo(root: String, moment: String, paths only: [String]?,
                      _ plan: @escaping @Sendable (SnapshotStore) throws -> (target: String, scope: RestoreScope, at: Int64)) async -> RestoreReport? {
        let at = OSAllocatedUnfairLock(initialState: Int64(0))
        let result = await performRestore(root: root) { s in
            let p = try plan(s)
            at.withLock { $0 = p.at }
            return (p.target, p.scope)
        }
        refreshProjects()
        switch result {
        case .success(let r):
            remember(r.report, root: root, scope: r.scope, latestAfter: r.latestAfter)
            if only == nil, let undo = r.report.undoSnapshotId {
                let when = at.withLock { $0 }
                // Undoing this moment can bring back what older undone moments of this project removed.
                undoneMoments = undoneMoments.filter { $0.value.root != root || $0.value.at > when }
                undoneMoments[moment] = (root, when, undo)
            }
            announceRestore(r.report, root: root, scope: r.scope)
            return r.report
        case .failure(let e):
            show(describe(e), style: .failure)
            return nil
        }
    }

    /// ⌥⌘Z and the popover's ⌘Z: the newest change anywhere that has not been undone yet (the popover's top row).
    var latestUndoable: RecentChange? {
        recentChanges.first { undoneMoments[$0.snapshotID] == nil }
    }

    func undoLatest() {
        guard let c = latestUndoable else { return }
        Task { await undo(c) }
    }

    /// Undo of a popover row: a command that spans several snapshots goes back to the snapshot before it.
    @discardableResult
    func undo(_ change: RecentChange) async -> RestoreReport? {
        if let base = change.base { return await undoChanges(root: change.root, from: base, to: change.snapshotID) }
        return await undoChanges(root: change.root, snapshot: change.snapshotID)
    }

    /// The result of a restore as a message with Undo (back to the snapshot the restore took first).
    private func announceRestore(_ r: RestoreReport, root: String, scope: RestoreScope) {
        var text = RestoreWindow.headline(r, root: root)
        if !r.conflicts.isEmpty { text += " · " + String(localized: "\(r.conflicts.count) skipped because they changed during the restore.") }
        if !r.failed.isEmpty { text += " · " + String(localized: "\(r.failed.count) failed.") }
        let style: Toast.Style = r.conflicts.isEmpty && r.failed.isEmpty ? .success : .warning
        guard let undo = r.undoSnapshotId else { show(text, style: style); return }
        show(text, style: style, action: (String(localized: "Undo"), { [weak self] in
            Task { await self?.revertRestore(root: root, to: undo, scope: scope) }
        }))
    }

    /// Undoes the last restore (back to the snapshot it took first), while no newer work exists.
    func undoLastRestore() {
        guard let r = lastRestore else { return }
        Task { await revertRestore(root: r.root, to: r.undoSnapshot, scope: r.scope) }
    }

    /// Puts files back as they were right before a restore. Reversible too: its message offers Undo again.
    @discardableResult
    func revertRestore(root: String, to snapshot: String, scope: RestoreScope) async -> RestoreReport? {
        let result = await performRestore(root: root) { _ in (snapshot, scope) }
        refreshProjects()
        switch result {
        case .success(let r):
            remember(r.report, root: root, scope: scope, latestAfter: r.latestAfter)
            undoneMoments = undoneMoments.filter { $0.value.undoSnapshot != snapshot }
            var text = String(localized: "Restore undone")
            if !r.report.conflicts.isEmpty { text += " · " + String(localized: "\(r.report.conflicts.count) skipped because they changed during the restore.") }
            if !r.report.failed.isEmpty { text += " · " + String(localized: "\(r.report.failed.count) failed.") }
            let style: Toast.Style = r.report.conflicts.isEmpty && r.report.failed.isEmpty ? .success : .warning
            if let again = r.report.undoSnapshotId {
                show(text, style: style, action: (String(localized: "Undo"), { [weak self] in
                    Task { await self?.revertRestore(root: root, to: again, scope: scope) }
                }))
            } else {
                show(text, style: style)
            }
            return r.report
        case .failure(let e):
            show(describe(e), style: .failure)
            return nil
        }
    }

    func setPinned(root: String, snapshot: String, _ on: Bool) {
        work.async { [paths] in
            let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
            try? s?.pin(snapshot, on)
            Task { @MainActor in self.refreshProjects() }
        }
    }

    // MARK: messages

    /// Shows a message. Its timer starts once a window or the popover shows it, and it waits while the pointer is on it.
    /// A message nobody sees within a couple of minutes is dropped, so an old one never shows up hours later.
    func show(_ text: String, style: Toast.Style = .info, action: (String, @MainActor () -> Void)? = nil) {
        toast = Toast(text: text, style: style, actionTitle: action?.0, action: action?.1)
        scheduleToastEnd(unseen: !(popoverVisible || mainWindowVisible))
    }

    func dismissToast() {
        toastTimer?.invalidate()
        toast = nil
    }

    /// Called by the view that shows the message (start the timer) and on hover (hold it).
    func holdToast(_ hold: Bool) {
        if hold { toastTimer?.invalidate() } else { scheduleToastEnd() }
    }

    private func scheduleToastEnd(unseen: Bool = false) {
        toastTimer?.invalidate()
        guard let t = toast else { return }
        let problem = t.style == .failure || t.style == .warning
        let seconds: TimeInterval = unseen ? (problem && t.action == nil ? 600 : 120) : (t.action != nil ? 30 : (problem ? 15 : 6))
        toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in if self?.toast?.id == t.id { self?.toast = nil } }
        }
    }

    /// Runs the message's action and clears it.
    func performToastAction() {
        let action = toast?.action
        dismissToast()
        action?()
    }

    /// Opens the window that shows an item, scrolled to it.
    func reveal(_ target: FocusTarget) {
        switch target {
        case .guardEntry: selectedTab = .guardLog
        case .snapshot(let root, _): selectedRoot = root; selectedTab = .timeline
        case .process: selectedTab = .radar
        }
        focus = target
        windowRequest = .main(selectedTab)
    }

    // MARK: radar

    nonisolated static func sameIgnoringUsage(_ a: [RadarProcess], _ b: [RadarProcess]) -> Bool {
        func strip(_ p: RadarProcess) -> RadarProcess { var p = p; p.footprintBytes = nil; p.cpuTimeNs = nil; return p }
        return a.count == b.count && zip(a, b).allSatisfy { strip($0) == strip($1) }
    }

    /// Someone looks at the servers: the popover is open or the Radar is the main window's view.
    private var radarWatched: Bool { popoverVisible || (mainWindowVisible && selectedTab == .radar) }

    /// The scan cadence follows what is going on (re-evaluated when visibility, the tab, live sessions or the server
    /// list change); the timer is replaced only when the cadence changes.
    func scheduleRadar() {
        let watching = radarWatched
        let live = projects.contains { $0.liveSessions > 0 }
        let interval: TimeInterval = watching ? 1.5 : (live ? 2 : (servers.isEmpty ? 10 : 5))
        if watching && !radarWasWatched { scanRadar() } // fresh numbers as soon as the radar becomes visible
        radarWasWatched = watching
        guard interval != radarInterval else { return }
        radarInterval = interval
        radarTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.scanRadar() } }
        t.tolerance = interval * 0.2
        radarTimer = t
    }

    func scanRadar() {
        guard !demo, !frozen else { return }
        let radar = self.radar
        let reg = workRegistry
        work.async {
            let snap = radar.scan(registry: reg)
            if let reg { try? radar.persist(snap, registry: reg) }
            let all = snap.processes.filter { !$0.listeners.isEmpty }
            let kept = Set((try? reg?.db.all("SELECT pid, proc_start FROM processes WHERE kept_at IS NOT NULL AND ended_at IS NULL") {
                ProcessIdentity(pid: Int32($0.int(0)), startUs: $0.int(1))
            }) ?? [])
            Task { @MainActor in
                // Memory and CPU time change on every scan. They are re-published only while someone looks at the radar,
                // so an idle menu bar app does not re-render its views every couple of seconds.
                // Memory and CPU are shown only in the Radar view; elsewhere only membership changes are published.
                let watching = self.mainWindowVisible && self.selectedTab == .radar
                if snap.servers != self.servers, watching || !Self.sameIgnoringUsage(snap.servers, self.servers) {
                    self.servers = snap.servers
                    self.refreshProjectPorts()
                }
                if all != self.allListening, watching || !Self.sameIgnoringUsage(all, self.allListening) { self.allListening = all }
                if kept != self.keptProcesses { self.keptProcesses = kept }
                // Orphans are announced after 20 s (doc 11 §6.4): a resumed session takes them back first.
                let now = Date()
                let current = Set(self.leftRunning.map(\.identity))
                self.orphanSince = self.orphanSince.filter { current.contains($0.key) }
                for o in self.leftRunning where self.orphanSince[o.identity] == nil { self.orphanSince[o.identity] = now }
                let due = self.leftRunning.filter { o in
                    !self.seenOrphans.contains(o.identity) && !self.notifiedOrphans.contains(o.identity)
                        && now.timeIntervalSince(self.orphanSince[o.identity] ?? now) >= 20
                }
                if !due.isEmpty {
                    self.notifiedOrphans.formUnion(due.map(\.identity))
                    if !self.popoverVisible { self.badge = true }
                    self.notifyOrphans(due)
                }
            }
        }
    }

    /// Stops a process; returns why it did not stop, or "" when it is gone (already gone counts as stopped).
    func stopProcess(_ p: RadarProcess, force: Bool) async -> String {
        let protectedMap = Dictionary(allListening.compactMap { q in q.protection.map { (q.identity.pid, $0) } }, uniquingKeysWith: { a, _ in a })
        let message: String = await withCheckedContinuation { cont in
            work.async {
                switch ProcessStopper.plan(p.identity, table: ProcessTable.capture(), isProtected: { protectedMap[$0] }) {
                case .failure(let why): cont.resume(returning: why == .goneOrReused ? "" : Self.describeStop(why))
                case .success(let plan):
                    switch ProcessStopper.execute(plan, force: force) {
                    case .terminated: cont.resume(returning: "")
                    case .stillRunning: cont.resume(returning: String(localized: "Didn't stop after 5 s"))
                    }
                }
            }
        }
        if message.isEmpty, let sid = p.attribution?.agentSessionID, !leftRunning.contains(where: { $0.attribution?.agentSessionID == sid && $0.identity != p.identity }) {
            Notifier.shared.remove(.orphans, id: sid)
        }
        scanRadar()
        return message
    }

    nonisolated static func describeStop(_ why: StopRefusal) -> String {
        switch why {
        case .goneOrReused: return ""
        case .notPermitted: return String(localized: "macOS didn't let Airbag stop this process.")
        case .protected(let r), .protectedDescendant(let r): return RadarScreen.refusal(r)
        }
    }

    /// "Keep Running": the server stays, and Airbag stops asking about it (also after a relaunch).
    func keep(_ p: RadarProcess) {
        seenOrphans.insert(p.identity)
        keptProcesses.insert(p.identity)
        try? registry?.db.run("UPDATE processes SET kept_at = ? WHERE pid = ? AND proc_start = ?", [Clock.nowMsInt(), p.identity.pid, p.identity.startUs])
        if let sid = p.attribution?.agentSessionID, !leftRunning.contains(where: { $0.attribution?.agentSessionID == sid }) {
            Notifier.shared.remove(.orphans, id: sid)
        }
    }

    private func notifyOrphans(_ list: [RadarProcess]) {
        let bySession = Dictionary(grouping: list) { $0.attribution?.agentSessionID ?? "?" }
        for (sid, procs) in bySession where !notifiedSessions.contains(sid) {
            notifiedSessions.insert(sid)
            let agent = procs.first?.attribution?.agent?.displayName
            let shown = procs.distinctServers
            let servers = ListFormatter.localizedString(byJoining: shown.map { "\($0.name) :\($0.portSet.min() ?? 0)" })
            Notifier.shared.post(.orphans, id: sid,
                                 title: agent.map { name in String(localized: "\(name) session ended") } ?? String(localized: "An agent session ended"),
                                 body: String(localized: "It left \(shown.count) servers running: \(servers)"),
                                 info: ["session": sid], thread: procs.first?.attribution?.projectRoot)
        }
    }

    /// A notification or one of its buttons was clicked.
    func handleNotification(action: String, info: [String: String]) {
        switch Notifier.Kind(rawValue: info["kind"] ?? "") {
        case .orphans:
            let procs = leftRunning.filter { ($0.attribution?.agentSessionID ?? "?") == info["session"] }
            switch action {
            case "stop":
                let sid = info["session"] ?? "?"
                Task {
                    var failed: [String] = []
                    for p in procs {
                        let why = await stopProcess(p, force: false)
                        if !why.isEmpty { failed.append("\(p.name) :\(p.listeners.first?.port ?? 0) — \(why)") }
                    }
                    guard !failed.isEmpty else { return }
                    // The system removed the notification when its button was used: say so again, with Stop / Keep Running.
                    if !popoverVisible { badge = true }
                    Notifier.shared.post(.orphans, id: sid, title: String(localized: "Some servers didn't stop"), body: failed.joined(separator: "\n"),
                                         info: ["session": sid], thread: procs.first?.attribution?.projectRoot)
                }
            case "keep": procs.forEach(keep)
            default: if let p = procs.first { reveal(.process(p.identity)) } else { windowRequest = .main(.radar) }
            }
        case .approval:
            guard let id = info["guard"] else { windowRequest = .main(.guardLog); return }
            if action == "allow", let g = guardEntries.first(where: { $0.id == id }) { allowOnce(g) } else { reveal(.guardEntry(id)) }
        case .guardEntry:
            if let id = info["guard"] { reveal(.guardEntry(id)) } else { windowRequest = .main(.guardLog) }
        case nil: windowRequest = .main(.timeline)
        }
    }

    // MARK: guard

    func refreshGuard() {
        guard let reg = registry else { return }
        let entries = reg.guardEntries(limit: 200)
        if entries != guardEntries { guardEntries = entries }
        if let known = knownGuardIDs {
            for g in entries.reversed() where !known.contains(g.id) { notifyGuard(g) }
        }
        knownGuardIDs = Set(entries.map(\.id))
    }

    /// Notification policy (quiet by default): an agent waiting for approval rings; a block and a command that ran
    /// without asking land quietly in Notification Center. Nothing while the popover already shows them.
    private func notifyGuard(_ g: GuardEntry) {
        let project = g.projectRoot.map { ($0 as NSString).lastPathComponent }
        let agent = g.agent?.displayName ?? String(localized: "An agent")
        let place = project.map { " · \($0)" } ?? ""
        switch g.decision {
        case "deny_fallback" where g.canAllowOnce:
            Notifier.shared.post(.approval, id: g.id, title: String(localized: "\(agent) is waiting for you"), body: g.command + place,
                                 info: ["guard": g.id], thread: g.projectRoot)
        case "deny":
            Notifier.shared.post(.guardEntry, id: g.id, title: String(localized: "Blocked a command from \(agent)"), body: g.command + place,
                                 info: ["guard": g.id], passive: true, thread: g.projectRoot)
        case "allow_fallback":
            // One notification per session that updates in place, not one per command.
            Notifier.shared.post(.guardEntry, id: "ran-\(g.agentSessionID ?? g.id)", title: String(localized: "\(agent) ran a command a snapshot can't undo"),
                                 body: g.command + place, info: ["guard": g.id], passive: true, thread: g.projectRoot)
        default: break
        }
    }

    func allowOnce(_ g: GuardEntry) {
        do {
            try registry?.allowOnce(guardID: g.id)
            show(String(localized: "Allowed once — the agent can run the same command again within 10 minutes"), style: .success)
        } catch { show(String(describing: error), style: .failure) }
        Notifier.shared.remove(.approval, id: g.id)
        refreshGuard()
    }

    func dismiss(_ g: GuardEntry) {
        try? registry?.dismissGuard(g.id)
        Notifier.shared.remove(.approval, id: g.id)
        refreshGuard()
    }

    /// Marks every Guard entry so far as looked at ("Got it" in the popover, or opening the Guard view).
    func markGuardsReviewed() {
        if pausedUntil == nil, pausedSince != nil {
            pausedSince = nil
            unprotectedDuringPause = 0
            try? registry?.db.run("DELETE FROM settings WHERE key = 'pause.sinceTs'")
        }
        markGuardEntriesReviewed()
    }

    /// Opening the Guard view: its entries are looked at (the pause notice stays until "Got it" in the popover).
    func markGuardEntriesReviewed() {
        guard let newest = guardEntries.map(\.ts).max(), newest > guardReviewedThrough else { return }
        guardReviewedThrough = newest
        try? registry?.setSetting("guard.reviewedThroughTs", newest)
    }

    private func markSeen() {
        seenOrphans.formUnion(leftRunning.map(\.identity))
    }

    func setRule(_ id: String, enabled: Bool) {
        if enabled { disabledRules.remove(id) } else { disabledRules.insert(id) }
        try? registry?.setSetting("rules.disabled", Array(disabledRules).sorted())
    }

    // MARK: hooks

    func refreshHooks() {
        guard !frozen else { return }
        let inst = installer
        let reg = workRegistry
        work.async {
            let rows = AgentKind.allCases.map(inst.status)
            let last = reg?.lastHookEvents() ?? [:]
            Task { @MainActor in
                if rows != self.hookStatuses { self.hookStatuses = rows }
                if last != self.lastHookAt { self.lastHookAt = last }
            }
        }
    }

    /// Connects an agent (adds Airbag's hook to its settings); returns why it failed, or nil. The caller shows it.
    @discardableResult
    func connect(_ agent: AgentKind) -> String? {
        defer { refreshHooks() }
        if let problem = installLocationProblem { return problem }
        do { _ = try installer.install(agent, strict: strictMode, backupDirectory: paths.backups.path); return nil }
        catch { return describe(error) }
    }

    /// Removes Airbag's hook from an agent's settings; returns why it failed, or nil.
    @discardableResult
    func disconnect(_ agent: AgentKind) -> String? {
        defer { refreshHooks() }
        do { _ = try installer.uninstall(agent, backupDirectory: paths.backups.path); return nil }
        catch { return describe(error) }
    }

    /// Connect with a message (popover and menu actions, where no row shows the result).
    func installHooks(_ agent: AgentKind) {
        if let error = connect(agent) { show(error, style: .failure) }
        else { show(String(localized: "\(agent.displayName) connected"), style: .success) }
    }

    func uninstallHooks(_ agent: AgentKind) {
        if let error = disconnect(agent) { show(error, style: .failure) }
        else { show(String(localized: "\(agent.displayName) disconnected")) }
    }

    /// Runs the exact Airbag binary the agents call on a command it must block. Proves the binary at the configured path
    /// starts and the rules work, without touching anything (the command is only analysed).
    func testProtection() async -> (ok: Bool, detail: String) {
        let cli = cliPath
        return await withCheckedContinuation { cont in
            work.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: cli)
                p.arguments = ["check", "rm -rf ~/", "--json"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                do {
                    try p.run()
                    p.waitUntilExit()
                    _ = out.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: p.terminationStatus == 3
                                ? (true, String(localized: "Blocked as expected"))
                                : (false, String(localized: "Airbag at \(cli) did not block the test command.")))
                } catch {
                    cont.resume(returning: (false, String(localized: "Airbag at \(cli) could not start: \(error.localizedDescription)")))
                }
            }
        }
    }

    /// Fixes a protection issue from the popover headline.
    func fix(_ issue: ProtectionIssue) {
        switch issue {
        case .brokenHooks(let agents): agents.forEach(installHooks)
        case .noAgentConnected: openSettings(tab: "agents")
        case .lowDisk: openSettings(tab: "snapshots")
        case .databaseUnavailable: revealInFinder(paths.logs.path)
        }
    }

    func setRecordInsteadOfAsking(_ on: Bool) {
        recordInsteadOfAsking = on
        try? registry?.setSetting("hook.recordInsteadOfAsking", on)
    }

    /// Rewrites each connected agent's hook for the new mode; returns the agents that could not be updated.
    @discardableResult
    func setStrict(_ on: Bool) -> [(agent: AgentKind, error: String)] {
        strictMode = on
        try? registry?.setSetting("hook.strictMode", on)
        return hookStatuses.filter(\.installed).compactMap { s in connect(s.agent).map { (s.agent, $0) } }
    }

    // MARK: pause, retention, settings

    func pause(minutes: Int?) {
        pause(until: minutes.map { Date().addingTimeInterval(Double($0) * 60) })
    }

    /// The next 8:00 (today when it is still before 8, else tomorrow).
    var nextMorning: Date {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 8, minute: 0), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(8 * 3600)
    }

    func pauseUntilTomorrowMorning() { pause(until: nextMorning) }

    func pause(until: Date?) {
        try? registry?.pause(untilMs: until.map { Int64($0.timeIntervalSince1970 * 1000) })
        if until != nil, pausedUntil == nil {
            let now = Date()
            pausedSince = now
            unprotectedDuringPause = 0
            try? registry?.setSetting("pause.sinceTs", Int64(now.timeIntervalSince1970 * 1000))
        }
        pausedUntil = until
        schedulePauseEnd()
        startWatching()
        refreshProjects()
    }

    /// One timer for the end of the pause; replaces any earlier one (also after a relaunch).
    private func schedulePauseEnd() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard let until = pausedUntil else { return }
        if until <= Date() { pausedUntil = nil; startWatching(); return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow + 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pausedUntil = nil
                self.startWatching()
            }
        }
    }

    func runRetention() {
        let policy = RetentionPolicy(maxAgeDays: retentionDays, keepNewest: 20)
        let budget = Int64(budgetGB) << 30
        let paths = self.paths
        snapshotQueue.async {
            let reg = try? Registry(paths: paths, role: .app)
            let r = Retention.run(paths: paths, policy: policy, globalBudgetBytes: budget, registry: reg)
            Log.shared.info("retention: deleted \(r.deletedSnapshots) snapshots, freed \(r.freedBytes) bytes")
            Task { @MainActor in self.refreshProjects() }
        }
        if let reg = registry { try? reg.db.execute("PRAGMA wal_checkpoint(PASSIVE)"); reg.ingestSpool(limit: 500) }
    }

    func setRetention(days: Int, budgetGB: Int) {
        retentionDays = days
        self.budgetGB = budgetGB
        try? registry?.setSetting("retention.snapshotDays", days)
        try? registry?.setSetting("retention.budgetGB", budgetGB)
    }

    private func loadSettings() {
        guard let reg = registry else { return }
        retentionDays = reg.setting("retention.snapshotDays", default: 7)
        budgetGB = reg.setting("retention.budgetGB", default: 5)
        disabledRules = Set(reg.setting("rules.disabled", default: [String]()))
        strictMode = reg.setting("hook.strictMode", default: false)
        recordInsteadOfAsking = reg.setting("hook.recordInsteadOfAsking", default: true)
        guardReviewedThrough = reg.setting("guard.reviewedThroughTs", default: Int64(0))
        pausedUntil = reg.pausedUntilMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        // Kept after the pause ends, so the popover can still say how many commands ran without snapshots.
        pausedSince = reg.setting("pause.sinceTs", as: Int64.self).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        schedulePauseEnd()
    }

    // MARK: language

    /// Interface languages shipped in the bundle; English is the source language and the fallback.
    static let languages = ["en", "de", "es", "fr", "it", "nl", "pl", "pt-BR", "tr", "uk", "ru", "kk", "hi", "id", "vi", "ja", "ko",
                            "zh-Hans", "zh-Hant"]

    /// The language chosen in Settings, or nil to follow the system (per-app `AppleLanguages`, read at launch).
    var languageOverride: String? {
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first }
        set {
            if let code = newValue { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            objectWillChange.send()
        }
    }

    /// The language's own name ("Deutsch", "日本語").
    static func languageName(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Starts a fresh copy of the app once this one has quit (a second instance would not get the wake socket).
    func relaunch(at bundlePath: String = Bundle.main.bundlePath) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Copies the app from a disk image into /Applications (or ~/Applications) and starts that copy. Returns why it
    /// failed, or nil (the app is quitting).
    func moveToApplications() -> String? {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let target = URL(fileURLWithPath: dir).appendingPathComponent(source.lastPathComponent)
            let temporary = URL(fileURLWithPath: dir).appendingPathComponent(".Airbag-new.app")
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? fm.removeItem(at: temporary)
                // Copy under a temporary name first, so a failed copy never costs the existing app.
                try fm.copyItem(at: source, to: temporary)
                // A copied app keeps the download's quarantine flag, and Gatekeeper would translocate it again.
                let strip = Process()
                strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                strip.arguments = ["-dr", "com.apple.quarantine", temporary.path]
                try? strip.run(); strip.waitUntilExit()
                if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
                else { try fm.moveItem(at: temporary, to: target) }
                relaunch(at: target.path)
                return nil
            } catch { try? fm.removeItem(at: temporary); continue }
        }
        return String(localized: "Airbag could not copy itself to Applications. Drag it there from the disk image.")
    }

    /// Launch at login. On by default after setup; macOS may ask for approval in Login Items.
    var launchAtLogin: Bool {
        get { loginItem == .on }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { show(String(localized: "Could not change the login item: \(error.localizedDescription)"), style: .failure) }
            refreshLoginItem()
        }
    }

    /// Turns the login item on or off; returns why it failed, or nil (the Settings row shows it in place).
    func setLaunchAtLogin(_ on: Bool) -> String? {
        defer { refreshLoginItem() }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; return nil }
        catch { return String(localized: "Could not change the login item: \(error.localizedDescription)") }
    }

    /// Opens Settings on a tab ("general", "agents", "projects", "snapshots", "about").
    func openSettings(tab: String) {
        UserDefaults.standard.set(tab, forKey: "settings.tab")
        windowRequest = .settings
    }

    func refreshLoginItem() {
        let state: LoginItemState
        switch SMAppService.mainApp.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        default: state = .off
        }
        if state != loginItem { loginItem = state }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// User-facing text for an error from the core.
    func describe(_ error: Error) -> String {
        switch error {
        case SnapshotError.busy: return String(localized: "Another snapshot or restore is running; try again in a moment.")
        case SnapshotError.notFound: return String(localized: "That snapshot no longer exists (it was removed by cleanup).")
        case SnapshotError.unsafeRoot(let p): return String(localized: "Airbag does not protect \(p): it is too broad (home or a system folder).")
        case SnapshotError.rootMissing(let p): return String(localized: "The folder \(p) does not exist.")
        case let e as StopRefusal: return Self.describeStop(e)
        case HookInstallError.hasComments(let f):
            return String(localized: "\((f as NSString).abbreviatingWithTildeInPath) has comments Airbag would remove. Add Airbag's line by hand.")
        case HookInstallError.readOnly(let f):
            return String(localized: "\((f as NSString).abbreviatingWithTildeInPath) is read-only. Add the line in your dotfiles instead.")
        case HookInstallError.unreadable(let f, _): return String(localized: "Airbag can't read \((f as NSString).abbreviatingWithTildeInPath).")
        case HookInstallError.unexpectedShape(let f, _):
            return String(localized: "\((f as NSString).abbreviatingWithTildeInPath) has an unexpected format. Airbag did not change it.")
        default: return String(describing: error)
        }
    }

    // MARK: onboarding

    var needsOnboarding: Bool {
        guard !demo, !frozen, let reg = registry else { return false }
        return !reg.setting("onboarding.done", default: false)
    }

    func finishOnboarding() {
        try? registry?.setSetting("onboarding.done", true)
        refreshAll()
    }

    /// Project roots from recent Claude Code and Codex transcripts (their `cwd`), newest first, with when they were used.
    func suggestedProjectsWithDates() async -> [(path: String, usedAt: Date)] {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                let fm = FileManager.default
                let home = NSHomeDirectory()
                var found: [(String, Date)] = []
                func scan(_ dir: String, depth: Int) {
                    guard depth >= 0, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
                    for n in names {
                        // Claude Code keeps sessions on remote machines under ssh-<id>: their cwd is a remote path.
                        if n.hasPrefix("ssh-") { continue }
                        let p = dir + "/" + n
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                        if isDir.boolValue { scan(p, depth: depth - 1); continue }
                        guard n.hasSuffix(".jsonl"), let attrs = try? fm.attributesOfItem(atPath: p), let m = attrs[.modificationDate] as? Date,
                              m > Date().addingTimeInterval(-30 * 86400) else { continue }
                        guard let h = FileHandle(forReadingAtPath: p) else { continue }
                        let head = String(decoding: h.readData(ofLength: 64 * 1024), as: UTF8.self)
                        try? h.close()
                        if let r = head.range(of: #""cwd"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                            let match = String(head[r])
                            if let q = match.range(of: #":\s*""#, options: .regularExpression) {
                                let cwd = String(match[q.upperBound...].dropLast())
                                found.append((cwd, m))
                            }
                        }
                    }
                }
                scan(home + "/.claude/projects", depth: 1)
                scan(home + "/.codex/sessions", depth: 3)
                var seen = IgnoredRoots.load(paths: paths)
                var out: [(path: String, usedAt: Date)] = []
                for (cwd, date) in found.sorted(by: { $0.1 > $1.1 }) {
                    guard fm.fileExists(atPath: cwd) else { continue }
                    let root = RootResolver.resolve(cwd: cwd)
                    guard (try? SnapshotStore.validateRoot(root, paths: paths)) != nil, !root.contains("/.claude/worktrees/"),
                          !root.contains("/.codex/worktrees/"), !root.contains("/scratch-workspaces/"), seen.insert(root).inserted else { continue }
                    out.append((root, date))
                    if out.count >= 12 { break }
                }
                cont.resume(returning: out)
            }
        }
    }

    func suggestedProjects() async -> [String] { await suggestedProjectsWithDates().map(\.path) }

    // MARK: summary

    /// The popover's first line: the state that matters most right now.
    var headline: String {
        if let g = needsApproval.first { return String(localized: "\(g.agent?.displayName ?? String(localized: "An agent")) is waiting for you") }
        if let until = pausedUntil { return String(localized: "Paused until \(RelativeTime.moment(until))") }
        if let issue = protectionIssues.first { return issue.text }
        let n = projects.filter(\.rootExists).count
        return n == 0 ? String(localized: "Nothing protected yet") : String(localized: "Protecting \(n) projects")
    }

    /// The popover's second line: what Airbag has done (proof it works).
    var subline: String {
        var parts: [String] = []
        if pausedUntil != nil {
            if unprotectedDuringPause > 0 { parts.append(String(localized: "\(unprotectedDuringPause) commands ran without snapshots")) }
            parts.append(String(localized: "blocks still on"))
            return parts.joined(separator: " · ")
        }
        if commandsToday > 0 { parts.append(String(localized: "\(commandsToday) commands checked today")) }
        if snapshotting { parts.append(String(localized: "snapshot in progress…")) }
        else if let last = projects.compactMap(\.lastSnapshotAt).max() { parts.append(String(localized: "snapshot \(RelativeTime.short(ms: last))")) }
        return parts.joined(separator: " · ")
    }

    /// Kept for views written against the first popover.
    var summaryLine: String { subline }
}

enum RelativeTime {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func short(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        if abs(date.timeIntervalSinceNow) < 5 { return String(localized: "just now") }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// "2 min ago" within the last hour, else the time of day (with the date when not today).
    static func age(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return -date.timeIntervalSinceNow < 3600 ? short(ms: ms) : clock(ms: ms)
    }

    /// Time of day in the user's own format (12 or 24 hours), with the date when it is not today.
    static func clock(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// A moment in the future or past, said the short way: "8:00 AM" today, "Fri 8:00 AM" on another day.
    static func moment(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Full date and time with seconds, for a tooltip or a detail line.
    static func precise(ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .standard)
    }

    /// Section title for a day: "Today", "Yesterday", then "Monday, 20 October" (all in the system language).
    static func day(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInYesterday(date) {
            let f = RelativeDateTimeFormatter()
            f.dateTimeStyle = .named
            let text = f.localizedString(from: DateComponents(day: cal.isDateInToday(date) ? 0 : -1))
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        let text = sameYear ? date.formatted(.dateTime.weekday(.wide).day().month(.wide)) : date.formatted(date: .complete, time: .omitted)
        return text.prefix(1).uppercased() + text.dropFirst() // a heading, also in languages that write weekdays in lower case
    }

    /// Start of the day of a timestamp, for grouping.
    static func dayKey(ms: Int64) -> Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
