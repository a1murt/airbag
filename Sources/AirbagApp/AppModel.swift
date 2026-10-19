import AirbagCore
import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

enum MainTab: String, CaseIterable, Identifiable {
    case timeline, radar, guardLog = "guard", settings
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .timeline: return "Timeline"
        case .radar: return "Radar"
        case .guardLog: return "Guard"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .timeline: return "clock.arrow.circlepath"
        case .radar: return "dot.radiowaves.left.and.right"
        case .guardLog: return "exclamationmark.shield"
        case .settings: return "gearshape"
        }
    }
}

enum IconState: Equatable {
    case idle, protected, snapshotting, blocked, orphan, degraded
    var symbol: String {
        switch self {
        case .idle: return "shield"
        case .protected, .snapshotting, .orphan: return "shield.fill"
        case .blocked: return "exclamationmark.shield.fill"
        case .degraded: return "shield.slash"
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
    private var seenGuardIDs = Set<String>()
    private var seenOrphans = Set<ProcessIdentity>()
    private var notifiedSessions = Set<String>()
    private var notifiedOrphans = Set<ProcessIdentity>()

    @Published var selectedTab: MainTab = .timeline
    @Published var selectedRoot: String?
    @Published var projects: [ProjectRow] = []
    @Published var servers: [RadarProcess] = []
    @Published var allListening: [RadarProcess] = []
    @Published var guardEntries: [GuardEntry] = []
    @Published var hookStatuses: [HookInstaller.AgentStatus] = []
    @Published var pausedUntil: Date?
    @Published var snapshotting = false
    @Published var badge = false
    @Published var lastMessage: String?
    @Published var popoverVisible = false { didSet { if popoverVisible { badge = false; markSeen() }; scheduleRadar() } }
    @Published var mainWindowVisible = false { didSet { scheduleRadar() } }
    /// When each orphan was first seen; notifications wait for a grace period (the session may resume).
    private var orphanSince: [ProcessIdentity: Date] = [:]
    @Published var restoreRequest: RestoreRequest?
    private var pauseTimer: Timer?
    @Published var retentionDays: Int = 7
    @Published var budgetGB: Int = 5
    @Published var disabledRules: Set<String> = []
    @Published var strictMode = false
    @Published var recordInsteadOfAsking = true

    var orphans: [RadarProcess] { servers.filter { $0.linkState == .orphan } }
    /// Blocks and approvals that need Airbag (native asks are answered in the agent's own prompt, spec §6.2).
    var attentionGuards: [GuardEntry] {
        guardEntries.filter { g in
            g.resolution == nil && (g.decision == "deny" || g.decision == "deny_fallback")
                && Date(timeIntervalSince1970: Double(g.ts) / 1000) > Date().addingTimeInterval(-6 * 3600)
        }
    }

    var iconState: IconState {
        if !attentionGuards.filter({ !seenGuardIDs.contains($0.id) }).isEmpty { return .blocked }
        if orphans.contains(where: { !seenOrphans.contains($0.identity) }) { return .orphan }
        if snapshotting { return .snapshotting }
        if hookStatuses.contains(where: { $0.installed && $0.brokenCommand }) { return .degraded }
        if hookStatuses.contains(where: { $0.detected }) && !hookStatuses.contains(where: { $0.installed }) && !projects.isEmpty { return .degraded }
        if pausedUntil != nil || projects.isEmpty { return .idle }
        return .protected
    }

    /// Why hooks cannot be installed from where the app runs now (a hook must point at a binary that stays put).
    var installLocationProblem: String? {
        let path = Bundle.main.bundleURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            if stableHomebrewCLI != nil { return nil }
            return String(localized: "Move Airbag to the Applications folder first: it runs from a disk image or a temporary location, and hooks would break when that goes away.")
        }
        return nil
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
            } catch { lastMessage = String(localized: "Airbag's database is unavailable: \(String(describing: error))") }
            loadSettings()
        }
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
        scheduleRadar()
    }

    func stop() {
        watcher?.stop()
        wakeServer?.stop()
        radarTimer?.invalidate()
    }

    private func hookEvent(_ msg: [String: Any]) {
        refreshGuard()
        refreshProjects()
        // Servers bind a moment after the command that starts them.
        for delay in [0.3, 2.0, 10.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scanRadar() } }
        // Blocked, waiting for approval, or run without asking: the user should look.
        if let d = msg["decision"] as? String, ["deny", "deny_fallback", "allow_fallback"].contains(d) { badge = true }
    }

    func refreshAll() {
        guard !frozen else { return }
        refreshProjects()
        refreshGuard()
        refreshHooks()
        scanRadar()
    }

    // MARK: projects and stores

    func refreshProjects() {
        guard !demo else { return }
        let paths = self.paths
        let reg = registry
        work.async {
            var rows: [ProjectRow] = []
            for loc in SnapshotStore.allStores(paths: paths) {
                guard let store = try? SnapshotStore.openLocation(loc, paths: paths) else { continue }
                let latest = try? store.latest()
                let usage = try? store.usage()
                let pinned = (try? store.list(limit: 1000).filter(\.pinned).count) ?? 0
                let layout = GitLayout.inspect(root: loc.root)
                rows.append(ProjectRow(root: loc.root, name: (loc.root as NSString).lastPathComponent, isWorktree: layout.isWorktree,
                                       rootExists: loc.rootExists, snapshotCount: usage?.snapshots ?? 0, lastSnapshotAt: latest?.createdAt,
                                       pinnedCount: pinned, liveSessions: 0, ports: [], bytes: usage?.objectBytes ?? 0))
            }
            Task { @MainActor in
                let live = reg?.liveSessionCounts() ?? [:]
                var withLive = rows.map { r -> ProjectRow in var r = r; r.liveSessions = live[r.root] ?? 0; return r }
                for (i, r) in withLive.enumerated() {
                    withLive[i].ports = self.servers.filter { s in (s.attribution?.projectRoot ?? s.cwd).map { $0 == r.root || $0.hasPrefix(r.root + "/") } ?? false }
                        .flatMap { $0.listeners.map(\.port) }.sorted()
                }
                self.projects = withLive.sorted { ($0.lastSnapshotAt ?? 0) > ($1.lastSnapshotAt ?? 0) }
                if self.selectedRoot == nil || !self.projects.contains(where: { $0.root == self.selectedRoot }) { self.selectedRoot = self.projects.first?.root }
                self.restartWatcherIfNeeded()
            }
        }
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
            self?.snapshotSync(root: root, trigger: .fsevents, label: nil)
        }
        w.start()
        watcher = w
    }

    /// Runs on `snapshotQueue`.
    nonisolated private func snapshotSync(root: String, trigger: SnapshotTrigger, label: String?) {
        Task { @MainActor in self.snapshotting = true }
        let outcome = (try? SnapshotStore.open(root: root, paths: paths))?.snapshot(SnapshotRequest(trigger: trigger, label: label, lockWaitMs: 5000))
        Task { @MainActor in
            self.snapshotting = false
            if case .created = outcome { self.refreshProjects() }
            if case .lowDisk(let avail) = outcome {
                let free = ByteCountFormatter.string(fromByteCount: avail, countStyle: .file)
                self.lastMessage = String(localized: "Snapshots paused: only \(free) free")
            }
        }
    }

    func snapshotNow(_ root: String) {
        snapshotQueue.async { [weak self] in self?.snapshotSync(root: root, trigger: .manual, label: String(localized: "Manual snapshot")) }
    }

    func snapshotAll() { for p in projects where p.rootExists { snapshotNow(p.root) } }

    func addProject(_ url: URL) {
        let path = url.path
        do {
            _ = try SnapshotStore.validateRoot(path, paths: paths)
            snapshotQueue.async { [weak self] in self?.snapshotSync(root: path, trigger: .initial, label: String(localized: "Project added")) }
            lastMessage = String(localized: "Protecting \(url.lastPathComponent)…")
        } catch {
            lastMessage = describe(error)
        }
    }

    func revealInFinder(_ path: String) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }

    // MARK: timeline

    func store(for root: String) -> SnapshotStore? {
        guard let loc = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }) else { return nil }
        return try? SnapshotStore.openLocation(loc, paths: paths)
    }

    func timeline(root: String) async -> [TimelineEntry] {
        let reg = workRegistry
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                guard let loc = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }),
                      let store = try? SnapshotStore.openLocation(loc, paths: paths) else { cont.resume(returning: []); return }
                if let reg { cont.resume(returning: reg.timeline(store: store)) } else {
                    cont.resume(returning: ((try? store.list(limit: 200)) ?? []).map { TimelineEntry(snapshot: $0, commands: []) })
                }
            }
        }
    }

    func changes(root: String, snapshot: String) async -> [FileChange] {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
                cont.resume(returning: (try? s?.changes(in: snapshot)) ?? [])
            }
        }
    }

    func fileDiff(root: String, snapshot: String, path: String) async -> TextDiff? {
        let paths = self.paths
        return await withCheckedContinuation { cont in
            work.async {
                guard let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap({ try? SnapshotStore.openLocation($0, paths: paths) }),
                      let info = try? s.info(snapshot) else { cont.resume(returning: nil); return }
                // Diff against the previous snapshot: what this snapshot recorded as changed.
                let prev = (try? s.list(limit: 1, beforeSeq: info.seq))?.first
                if let prev { cont.resume(returning: try? s.fileDiff(path: path, from: prev.id, to: snapshot)) }
                else { cont.resume(returning: try? s.fileDiff(path: path, from: snapshot, to: snapshot)) }
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

    func restore(root: String, snapshot: String, scope: RestoreScope) async -> Result<RestoreReport, Error> {
        let paths = self.paths
        let result: Result<RestoreReport, Error> = await withCheckedContinuation { cont in
            snapshotQueue.async {
                guard let loc = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }) else {
                    cont.resume(returning: .failure(SnapshotError.notFound(root))); return
                }
                do {
                    let s = try SnapshotStore.openLocation(loc, paths: paths)
                    cont.resume(returning: .success(try s.restore(to: snapshot, scope: scope)))
                } catch { cont.resume(returning: .failure(error)) }
            }
        }
        if case .success(let r) = result {
            lastMessage = String(localized: "Restored \(r.restored.count) files in \((root as NSString).lastPathComponent)")
        }
        refreshProjects()
        return result
    }

    func setPinned(root: String, snapshot: String, _ on: Bool) {
        work.async { [paths] in
            let s = SnapshotStore.allStores(paths: paths).first(where: { $0.root == root }).flatMap { try? SnapshotStore.openLocation($0, paths: paths) }
            try? s?.pin(snapshot, on)
            Task { @MainActor in self.refreshProjects() }
        }
    }

    // MARK: radar

    nonisolated static func sameIgnoringUsage(_ a: [RadarProcess], _ b: [RadarProcess]) -> Bool {
        func strip(_ p: RadarProcess) -> RadarProcess { var p = p; p.footprintBytes = nil; p.cpuTimeNs = nil; return p }
        return a.count == b.count && zip(a, b).allSatisfy { strip($0) == strip($1) }
    }

    func scheduleRadar() {
        radarTimer?.invalidate()
        let live = projects.contains { $0.liveSessions > 0 }
        let watching = popoverVisible || (mainWindowVisible && selectedTab == .radar)
        let interval: TimeInterval = watching ? 1.5 : (live ? 2 : (servers.isEmpty ? 10 : 5))
        radarTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.scanRadar() } }
        if watching { scanRadar() } // fresh numbers as soon as the radar becomes visible
    }

    func scanRadar() {
        guard !demo, !frozen else { return }
        let radar = self.radar
        let reg = workRegistry
        work.async {
            let snap = radar.scan(registry: reg)
            if let reg { try? radar.persist(snap, registry: reg) }
            let all = snap.processes.filter { !$0.listeners.isEmpty }
            Task { @MainActor in
                // Memory and CPU time change on every scan. They are re-published only while someone looks at the radar,
                // so an idle menu bar app does not re-render its views every couple of seconds.
                let watching = self.popoverVisible || self.mainWindowVisible
                if snap.servers != self.servers, watching || !Self.sameIgnoringUsage(snap.servers, self.servers) { self.servers = snap.servers }
                if all != self.allListening, watching || !Self.sameIgnoringUsage(all, self.allListening) { self.allListening = all }
                // Orphans are announced after 20 s (doc 11 §6.4): a resumed session takes them back first.
                let now = Date()
                let current = Set(self.orphans.map(\.identity))
                self.orphanSince = self.orphanSince.filter { current.contains($0.key) }
                for o in self.orphans where self.orphanSince[o.identity] == nil { self.orphanSince[o.identity] = now }
                let due = self.orphans.filter { o in
                    !self.seenOrphans.contains(o.identity) && !self.notifiedOrphans.contains(o.identity)
                        && now.timeIntervalSince(self.orphanSince[o.identity] ?? now) >= 20
                }
                if !due.isEmpty {
                    self.notifiedOrphans.formUnion(due.map(\.identity))
                    self.badge = true
                    self.notifyOrphans(due)
                }
            }
        }
    }

    func stopProcess(_ p: RadarProcess, force: Bool) async -> String {
        let protectedMap = Dictionary(allListening.compactMap { q in q.protection.map { (q.identity.pid, $0) } }, uniquingKeysWith: { a, _ in a })
        let message: String = await withCheckedContinuation { cont in
            work.async {
                switch ProcessStopper.plan(p.identity, table: ProcessTable.capture(), isProtected: { protectedMap[$0] }) {
                case .failure(let why): cont.resume(returning: String(describing: why))
                case .success(let plan):
                    switch ProcessStopper.execute(plan, force: force) {
                    case .terminated: cont.resume(returning: "")
                    case .stillRunning: cont.resume(returning: String(localized: "Didn't stop after 5 s"))
                    }
                }
            }
        }
        scanRadar()
        return message
    }

    func keep(_ p: RadarProcess) {
        seenOrphans.insert(p.identity)
        try? registry?.db.run("UPDATE processes SET kept_at = ? WHERE pid = ? AND proc_start = ?", [Clock.nowMsInt(), p.identity.pid, p.identity.startUs])
        objectWillChange.send()
    }

    private func notifyOrphans(_ list: [RadarProcess]) {
        // Ask for permission at the first event that warrants a notification, not at launch (spec §8).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let bySession = Dictionary(grouping: list) { $0.attribution?.agentSessionID ?? "?" }
        for (sid, procs) in bySession where !notifiedSessions.contains(sid) {
            notifiedSessions.insert(sid)
            let content = UNMutableNotificationContent()
            let agent = procs.first?.attribution?.agent?.displayName ?? "Agent"
            content.title = String(localized: "\(agent) session ended")
            content.body = String(localized: "\(procs.count) server(s) still listening: ") + procs.map { "\($0.name) :\($0.listeners.first?.port ?? 0)" }.joined(separator: ", ")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "orphan-\(sid)", content: content, trigger: nil))
        }
    }

    // MARK: guard

    func refreshGuard() {
        guard let reg = registry else { return }
        let entries = reg.guardEntries(limit: 200)
        if entries != guardEntries { guardEntries = entries }
    }

    func allowOnce(_ g: GuardEntry) {
        do {
            try registry?.allowOnce(guardID: g.id)
            lastMessage = String(localized: "Allowed once — the agent can run the same command again within 10 minutes")
        } catch { lastMessage = String(describing: error) }
        refreshGuard()
    }

    func dismiss(_ g: GuardEntry) {
        try? registry?.dismissGuard(g.id)
        refreshGuard()
    }

    private func markSeen() {
        seenGuardIDs.formUnion(attentionGuards.map(\.id))
        seenOrphans.formUnion(orphans.map(\.identity))
    }

    func setRule(_ id: String, enabled: Bool) {
        if enabled { disabledRules.remove(id) } else { disabledRules.insert(id) }
        try? registry?.setSetting("rules.disabled", Array(disabledRules).sorted())
    }

    // MARK: hooks

    func refreshHooks() {
        let inst = installer
        work.async {
            let rows = AgentKind.allCases.map(inst.status)
            Task { @MainActor in self.hookStatuses = rows }
        }
    }

    func installHooks(_ agent: AgentKind) {
        if let problem = installLocationProblem { lastMessage = problem; return }
        do {
            let c = try installer.install(agent, strict: strictMode, backupDirectory: paths.backups.path)
            lastMessage = c.changed ? String(localized: "Hooks installed for \(agent.displayName)") : String(localized: "\(agent.displayName) is already protected")
        } catch { lastMessage = String(describing: error) }
        refreshHooks()
    }

    func uninstallHooks(_ agent: AgentKind) {
        do { _ = try installer.uninstall(agent, backupDirectory: paths.backups.path); lastMessage = String(localized: "Hooks removed for \(agent.displayName)") }
        catch { lastMessage = String(describing: error) }
        refreshHooks()
    }

    func setRecordInsteadOfAsking(_ on: Bool) {
        recordInsteadOfAsking = on
        try? registry?.setSetting("hook.recordInsteadOfAsking", on)
    }

    func setStrict(_ on: Bool) {
        strictMode = on
        try? registry?.setSetting("hook.strictMode", on)
        for s in hookStatuses where s.installed { installHooks(s.agent) }
    }

    // MARK: pause, retention, settings

    func pause(minutes: Int?) {
        pause(until: minutes.map { Date().addingTimeInterval(Double($0) * 60) })
    }

    func pauseUntilTomorrowMorning() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
        pause(until: cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow))
    }

    func pause(until: Date?) {
        try? registry?.pause(untilMs: until.map { Int64($0.timeIntervalSince1970 * 1000) })
        pausedUntil = until
        schedulePauseEnd()
        startWatching()
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
                self.lastMessage = String(localized: "Protection resumed")
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
        pausedUntil = reg.pausedUntilMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        schedulePauseEnd()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { lastMessage = String(localized: "Could not change the login item: \(error.localizedDescription)") }
            if SMAppService.mainApp.status == .requiresApproval {
                lastMessage = String(localized: "Allow Airbag in System Settings → General → Login Items to open it at login.")
                SMAppService.openSystemSettingsLoginItems()
            }
            objectWillChange.send()
        }
    }

    /// User-facing text for an error from the core.
    func describe(_ error: Error) -> String {
        switch error {
        case SnapshotError.busy: return String(localized: "Another snapshot or restore is running; try again in a moment.")
        case SnapshotError.notFound: return String(localized: "That snapshot no longer exists (it was removed by cleanup).")
        case SnapshotError.unsafeRoot(let p): return String(localized: "Airbag does not protect \(p): it is too broad (home or a system folder).")
        case SnapshotError.rootMissing(let p): return String(localized: "The folder \(p) does not exist.")
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

    /// Project roots from recent Claude Code and Codex transcripts (their `cwd`), newest first.
    func suggestedProjects() async -> [String] {
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
                var seen = Set<String>()
                var out: [String] = []
                for (cwd, _) in found.sorted(by: { $0.1 > $1.1 }) {
                    guard fm.fileExists(atPath: cwd) else { continue }
                    let root = RootResolver.resolve(cwd: cwd)
                    guard (try? SnapshotStore.validateRoot(root, paths: paths)) != nil, !root.contains("/.claude/worktrees/"),
                          !root.contains("/.codex/worktrees/"), !root.contains("/scratch-workspaces/"), seen.insert(root).inserted else { continue }
                    out.append(root)
                    if out.count >= 12 { break }
                }
                cont.resume(returning: out)
            }
        }
    }

    // MARK: summary

    var summaryLine: String {
        var parts: [String] = []
        let n = projects.filter(\.rootExists).count
        parts.append(String(localized: "\(n) projects protected"))
        if n > 0 {
            if snapshotting { parts.append(String(localized: "snapshot in progress…")) }
            else if let last = projects.compactMap(\.lastSnapshotAt).max() {
                parts.append(String(localized: "snapshot \(RelativeTime.short(ms: last))"))
            } else { parts.append(String(localized: "no snapshots yet")) }
        }
        if !servers.isEmpty || !orphans.isEmpty { parts.append(String(localized: "\(servers.count) servers")) }
        if !orphans.isEmpty { parts.append(String(localized: "\(orphans.count) orphans")) }
        return parts.joined(separator: " · ")
    }
}

enum RelativeTime {
    static func short(ms: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        if abs(date.timeIntervalSinceNow) < 5 { return String(localized: "just now") }
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func clock(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "d MMM HH:mm"
        return f.string(from: date)
    }
}
