import AirbagCore
import AppKit
import SwiftUI

/// The tabs of the Settings window, in toolbar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, agents, projects, snapshots, about
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .general: return "General"
        case .agents: return "Agents"
        case .projects: return "Projects"
        case .snapshots: return "Snapshots"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .agents: "terminal"
        case .projects: "folder"
        case .snapshots: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }
}

/// The Settings window (⌘,): toolbar tabs, each a grouped form as tall as its content.
struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settings.tab") private var selection: SettingsTab = .general
    /// nil: the window's tabs (the last one used is remembered). A tab: that page alone, for preview rendering.
    var tab: SettingsTab? = nil

    static let width: CGFloat = 600

    var body: some View {
        Group {
            if let tab {
                page(tab)
            } else {
                TabView(selection: $selection) {
                    ForEach(SettingsTab.allCases) { t in
                        page(t).tabItem { Label { Text(t.title) } icon: { Image(systemName: t.symbol) } }.tag(t)
                    }
                }
            }
        }
        .onAppear { model.refreshHooksUnlessFrozen() }
    }

    @ViewBuilder func page(_ tab: SettingsTab) -> some View {
        Group {
            switch tab {
            case .general: GeneralPane()
            case .agents: AgentsPane()
            case .projects: ProjectsPane()
            case .snapshots: SnapshotsPane()
            case .about: AboutPane()
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A section footer: one line of small secondary text under the group, leading-aligned (grouped forms put footer
/// content on the trailing side, where System Settings has its buttons).
private struct Footer: View {
    let text: Text
    init(_ text: Text) { self.text = text }
    var body: some View {
        text.font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
    }
}

/// Icon and text side by side. A form gives labels a wide icon column, which is too wide for a result shown next to
/// a button or under a status line.
private struct InlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) { configuration.icon; configuration.title }
    }
}

// MARK: General

private struct GeneralPane: View {
    @EnvironmentObject var model: AppModel
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                // On while macOS waits for approval too: the user asked for it, the row below says what is missing.
                Toggle("Open Airbag at login", isOn: Binding(get: { model.loginItem != .off }, set: { setLaunchAtLogin($0) }))
                if let loginError {
                    Callout(.danger, verbatim: loginError).font(.callout)
                }
                if model.loginItem == .needsApproval {
                    LabeledContent {
                        Button("Open Login Items") { model.openLoginItemsSettings() }
                    } label: {
                        Callout(.warning, "Waiting for approval in Login Items")
                    }
                }
            } footer: {
                Footer(Text("Hooks work even when Airbag is closed; the Radar, file-change snapshots and approvals need it running."))
            }
            Section {
                Picker("Language", selection: Binding(get: { model.languageOverride ?? "" }, set: { model.languageOverride = $0.isEmpty ? nil : $0 })) {
                    Text("System").tag("")
                    Divider()
                    ForEach(AppModel.languages, id: \.self) { code in Text(verbatim: AppModel.languageName(code)).tag(code) }
                }
                if (model.languageOverride ?? "") != (languageAtLaunch ?? "") {
                    LabeledContent {
                        Button("Restart Airbag") { model.relaunch() }
                    } label: {
                        Text("The new language is used after a restart.").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent {
                    Button("Run Setup Again…") { model.windowRequest = .welcome }
                } label: {
                    Text("Connect agents and choose projects step by step")
                }
            }
        }
        .animation(.snappy, value: model.loginItem)
        .animation(.snappy, value: model.languageOverride)
        .animation(.snappy, value: loginError)
    }

    /// The model reports a failed change as a message for the popover; this window shows it in place instead.
    func setLaunchAtLogin(_ on: Bool) {
        loginError = model.setLaunchAtLogin(on)
    }
}

/// The interface language this process started with (the override is read at launch, so a change needs a restart).
private let languageAtLaunch: String? =
    (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first

// MARK: Agents

private struct AgentsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var testing = false
    @State private var testResult: (ok: Bool, detail: String)?
    @State private var moveError: String?

    var body: some View {
        Form {
            Section {
                if let problem = model.installLocationProblem {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Callout(.warning, verbatim: problem)
                            Spacer(minLength: 8)
                            Button("Move to Applications") { moveError = model.moveToApplications() }
                        }
                        if let moveError { Callout(.danger, verbatim: moveError).font(.caption) }
                    }
                }
                if model.hookStatuses.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                ForEach(model.hookStatuses, id: \.agent) { AgentRow(status: $0) }
                HStack(spacing: 10) {
                    Button("Test Protection") {
                        testing = true
                        Task {
                            let result = await model.testProtection()
                            withAnimation(.snappy) { testResult = result; testing = false }
                        }
                    }
                    .disabled(testing)
                    if testing {
                        ProgressView().controlSize(.small)
                    } else if let r = testResult {
                        Callout(r.ok ? .success : .danger, verbatim: r.detail).font(.callout).labelStyle(InlineLabelStyle()).transition(.opacity)
                    } else {
                        Text("Checks that Airbag blocks a dangerous command. Nothing is run.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            } footer: {
                Footer(Text("Airbag adds one line to each agent's settings file. A backup is kept."))
            }
            Section {
                Picker("When a snapshot can't undo a command",
                       selection: Binding(get: { model.recordInsteadOfAsking }, set: { model.setRecordInsteadOfAsking($0) })) {
                    Text("Record and Keep Going").tag(true)
                    Text("Stop Until I Approve").tag(false)
                }
            } header: {
                Text("Safety")
            } footer: {
                Footer(Text("Like force pushes or edits outside the project. Wiping your home folder or a disk is always blocked."))
            }
            Section {
                Picker("If Airbag's hook fails", selection: Binding(get: { model.strictMode }, set: { model.setStrict($0) })) {
                    Text("Let the Command Run").tag(false)
                    Text("Block the Command").tag(true)
                }
            } footer: {
                Footer(Text("Blocking works in Claude Code and Cursor."))
            }
        }
        .onAppear { model.refreshHooksUnlessFrozen() }
        // Back from the agent (e.g. after trusting the hook in Codex) or from editing its settings by hand.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshHooksUnlessFrozen() }
    }
}

/// What an agent's row says, from evidence: a connected agent turns green only once Airbag has seen it call.
private enum AgentHealth: Equatable {
    case connected(lastCall: Int64)
    case waiting
    case needsRepair(moved: Bool)
    case notConnected
    case notFound

    init(_ s: HookInstaller.AgentStatus, lastCall: Int64?) {
        if !s.installed { self = s.detected ? .notConnected : .notFound }
        else if s.staleCommand || s.brokenCommand { self = .needsRepair(moved: true) }
        else if !s.current { self = .needsRepair(moved: false) }
        else if let lastCall { self = .connected(lastCall: lastCall) }
        else { self = .waiting }
    }

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .waiting: "circle.dashed"
        case .needsRepair: "exclamationmark.triangle.fill"
        case .notConnected: "circle"
        case .notFound: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .connected: return Theme.ok
        case .needsRepair: return Theme.warning
        case .waiting, .notConnected, .notFound: return .secondary
        }
    }

    var title: Text {
        switch self {
        case .connected(let t):
            let agoText = RelativeTime.short(ms: t)
            return Text("Connected · last command \(agoText)")
        case .waiting: return Text("Connected · no commands yet")
        case .needsRepair: return Text("Needs repair")
        case .notConnected: return Text("Not connected")
        case .notFound: return Text("Not found on this Mac")
        }
    }
}

private struct AgentRow: View {
    @EnvironmentObject var model: AppModel
    let status: HookInstaller.AgentStatus
    @State private var error: String?
    @State private var showChanges = false
    @State private var confirmDisconnect = false

    var health: AgentHealth { AgentHealth(status, lastCall: model.lastHookAt[status.agent]) }
    var name: String { status.agent.displayName }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                AgentName(agent: status.agent)
                HStack(spacing: 5) {
                    Image(systemName: health.symbol)
                        .foregroundStyle(health.color)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    health.title.foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.leading, AgentName.iconWidth + 6)
                .help(helpText)
                detail
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, AgentName.iconWidth + 6)
                if let error {
                    Callout(.danger, verbatim: error).font(.caption).labelStyle(InlineLabelStyle())
                        .padding(.leading, AgentName.iconWidth + 6)
                        .transition(.opacity)
                }
            }
            .opacity(health == .notFound ? 0.55 : 1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            buttons
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: health)
        .animation(.snappy, value: error)
        .confirmationDialog(Text("Disconnect \(name)?"), isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { error = model.disconnect(status.agent) }
        } message: {
            Text("\(name) will run commands without snapshots or safety checks.")
        }
    }

    var helpText: Text {
        if case .connected(let t) = health { return Text(RelativeTime.precise(ms: t)) }
        return Text(verbatim: (status.configPath as NSString).abbreviatingWithTildeInPath)
    }

    @ViewBuilder var detail: some View {
        switch health {
        case .needsRepair(let moved):
            if moved { Text("Points to an Airbag copy that was moved") } else { Text("Set up by an older version of Airbag") }
        case .waiting where status.agent == .codex:
            Text("Codex asks you to trust new hooks once: open Codex, type /hooks and press t.")
        default: EmptyView()
        }
    }

    @ViewBuilder var buttons: some View {
        switch health {
        case .notFound:
            EmptyView()
        case .notConnected:
            HStack(spacing: 8) {
                showChangesButton
                Button("Connect") { connect() }.buttonStyle(.borderedProminent)
            }
        case .needsRepair:
            HStack(spacing: 8) {
                showChangesButton
                Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                Button("Repair") { connect() }.buttonStyle(.borderedProminent)
            }
        case .connected, .waiting:
            Button("Disconnect", role: .destructive) { confirmDisconnect = true }
        }
    }

    var showChangesButton: some View {
        Button("Show Changes…") { showChanges = true }
            .popover(isPresented: $showChanges, arrowEdge: .bottom) {
                AgentChangesView(agent: status.agent)
            }
    }

    func connect() { error = model.connect(status.agent) }
}

/// An agent's name with its symbol in a fixed-width column, so the names of all rows line up.
/// "Show Changes…": what Connect or Repair would write into the agent's settings file, as a diff.
struct AgentChangesView: View {
    @EnvironmentObject var model: AppModel
    let agent: AgentKind
    /// Preview rendering passes the result instead of reading the real file.
    var preset: Result<(path: String, diff: TextDiff), Error>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch preset ?? plan {
            case .success(let p):
                Text(verbatim: (p.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView(.vertical) {
                    ScrollView(.horizontal) {
                        DiffView(diff: p.diff).padding(8)
                    }
                }
                .frame(width: 520, height: 300)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
            case .failure(let e):
                Callout(.danger, verbatim: model.describe(e)).frame(width: 360, alignment: .leading)
            }
        }
        .padding(14)
    }

    var plan: Result<(path: String, diff: TextDiff), Error> {
        Result {
            let change = try model.installer.plan(agent, install: true, strict: model.strictMode)
            return (change.path, TextDiff.compute(old: change.before.map { Data($0.utf8) }, new: change.after.map { Data($0.utf8) }))
        }
    }
}

// MARK: Projects

private struct ProjectsPane: View {
    @EnvironmentObject var model: AppModel
    /// Folders added here whose first snapshot is still running (they join `model.projects` when it is done).
    @State private var adding: [String] = []
    @State private var addErrors: [String] = []

    var pending: [String] { adding.filter { root in !model.projects.contains { $0.root == root } } }

    var body: some View {
        Form {
            Section {
                if model.projects.isEmpty && pending.isEmpty {
                    Text("Nothing protected yet").foregroundStyle(.secondary)
                }
                ForEach(model.projects) { ProjectSettingsRow(project: $0) }
                ForEach(pending, id: \.self) { root in
                    HStack(spacing: 10) {
                        ProjectName(name: (root as NSString).lastPathComponent, root: root, missing: false)
                        ProgressView().controlSize(.small)
                    }
                }
                ForEach(addErrors, id: \.self) { Callout(.danger, verbatim: $0).font(.callout) }
                HStack {
                    Spacer()
                    Button("Add Project…") { chooseFolders() }
                }
            } footer: {
                Footer(Text("Includes .env and other ignored files. Skips node_modules, build output and other rebuildable folders."))
            }
        }
        .animation(.snappy, value: model.projects)
        .animation(.snappy, value: adding)
        .animation(.snappy, value: addErrors)
        .onChange(of: model.snapshottingRoots) { _, now in
            // The project row appears once the store is read again; drop the placeholder a moment later.
            let finished = adding.filter { !now.contains($0) }
            guard !finished.isEmpty else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                adding.removeAll { finished.contains($0) }
            }
        }
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Protect")
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            addErrors = []
            for url in panel.urls {
                if let problem = model.addProject(url, announce: false) { addErrors.append(problem); continue }
                let root = FileSystem.canonicalPath(url.path) ?? url.path
                if !adding.contains(root) { adding.append(root) }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}

/// A project's name and folder; the folder is truncated in the middle and shown in full on hover.
private struct ProjectName: View {
    let name: String
    let root: String
    let missing: Bool
    var body: some View {
        let path = (root as NSString).abbreviatingWithTildeInPath
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: name).lineLimit(1)
                if missing { Pill(text: "folder missing", color: .secondary) }
            }
            Text(verbatim: path).font(Theme.monoSmall).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(Text(verbatim: path))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectSettingsRow: View {
    @EnvironmentObject var model: AppModel
    let project: ProjectRow
    @State private var result: ManualSnapshotResult?
    @State private var showsCheck = false

    var busy: Bool { model.snapshottingRoots.contains(project.root) }

    var body: some View {
        let sizeText = ByteCountFormatter.string(fromByteCount: project.bytes, countStyle: .file)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProjectName(name: project.name, root: project.root, missing: !project.rootExists)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(project.snapshotCount) snapshots")
                    Text(verbatim: sizeText)
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize()
                Button { take() } label: {
                    ZStack {
                        Text("Take Snapshot").opacity(busy || showsCheck ? 0 : 1)
                        if busy {
                            ProgressView().controlSize(.small)
                        } else if showsCheck {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.ok)
                                .transition(.symbolEffect(.appear))
                        }
                    }
                }
                .disabled(!project.rootExists || busy)
                .help(checkHelp)
                Button { model.revealInFinder(project.root) } label: { Image(systemName: "folder") }
                    .help(Text("Show in Finder"))
                    .accessibilityLabel(Text("Show in Finder"))
                    .disabled(!project.rootExists)
            }
            if case .failed(let why) = result {
                Callout(.danger, verbatim: why).font(.caption).labelStyle(InlineLabelStyle()).transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: result)
    }

    /// What the last click did (the check alone does not say whether anything had changed).
    var checkHelp: Text {
        switch result {
        case .created: return Text("Snapshot taken")
        case .unchanged: return Text("No changes since the last snapshot")
        default: return Text(verbatim: "")
        }
    }

    func take() {
        Task {
            let r = await model.snapshotNow(project.root)
            result = r
            if case .failed = r { return }
            withAnimation(.snappy) { showsCheck = true }
            AccessibilityNotification.Announcement(r == .unchanged ? String(localized: "No changes since the last snapshot") : String(localized: "Snapshot taken")).post()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.snappy) { showsCheck = false }
        }
    }
}

// MARK: Snapshots

private struct SnapshotsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var cleaning = false
    @State private var cleaned: PruneReport?

    var body: some View {
        let snapshotCount = model.projects.reduce(0) { $0 + $1.snapshotCount }
        let usedText = ByteCountFormatter.string(fromByteCount: model.projects.reduce(0) { $0 + $1.bytes }, countStyle: .file)
        Form {
            Section {
                Picker("Keep snapshots for", selection: Binding(get: { model.retentionDays }, set: { model.setRetention(days: $0, budgetGB: model.budgetGB) })) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Disk budget for all projects", selection: Binding(get: { model.budgetGB }, set: { model.setRetention(days: model.retentionDays, budgetGB: $0) })) {
                    ForEach([2, 5, 10, 20], id: \.self) { gb in
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(gb) << 30, countStyle: .memory)).tag(gb)
                    }
                }
            } footer: {
                Footer(Text("Pinned snapshots and the latest 20 per project are always kept. Unchanged files take no extra space."))
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Show Data Folder") { model.revealInFinder(model.paths.home.path) }
                        Button("Clean Up Now") { cleanUp() }.disabled(cleaning)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("\(snapshotCount) snapshots") + Text(verbatim: " · " + usedText)
                        if cleaning { ProgressView().controlSize(.small) }
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                if let r = cleaned, !cleaning {
                    if r.deletedSnapshots > 0 {
                        let removedCount = r.deletedSnapshots
                        let freedText = ByteCountFormatter.string(fromByteCount: r.freedBytes, countStyle: .file)
                        Callout(.success, "Removed \(removedCount) old snapshots · \(freedText) freed").transition(.opacity)
                    } else {
                        Callout(.success, "Nothing to clean up").transition(.opacity)
                    }
                }
            }
        }
        .animation(.snappy, value: cleaning)
    }

    func cleanUp() {
        cleaning = true
        Task {
            let r = await model.cleanUpNow()
            withAnimation(.snappy) { cleaned = r; cleaning = false }
        }
    }
}

// MARK: About

private struct AboutPane: View {
    var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? AirbagVersion.marketing
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(verbatim: "Airbag").font(.title2.weight(.semibold))
                    Text("Version \(versionText)")
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help(Text(verbatim: AirbagVersion.line))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                Label("Everything stays on this Mac: no account, no network, no telemetry. Secrets in commands are masked.", systemImage: "lock")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent {
                    Link("Airbag on GitHub", destination: URL(string: "https://github.com/a1murt/airbag")!)
                } label: {
                    Text("MIT License").foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: model helpers used only here

extension AppModel {
    /// Agent status is read from the real agent configs; preview rendering keeps the injected rows.
    func refreshHooksUnlessFrozen() {
        if !frozen { refreshHooks() }
    }

    /// "Clean Up Now": the hourly cleanup, run now, reporting what it removed.
    func cleanUpNow() async -> PruneReport {
        let policy = RetentionPolicy(maxAgeDays: retentionDays, keepNewest: 20)
        let budget = Int64(budgetGB) << 30
        let paths = self.paths
        let report = await Task.detached(priority: .utility) {
            Retention.run(paths: paths, policy: policy, globalBudgetBytes: budget, registry: try? Registry(paths: paths, role: .app))
        }.value
        refreshProjects()
        return report
    }
}
