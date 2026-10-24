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
    /// Agents whose settings file could not be rewritten for the last choice of the strict picker.
    @State private var strictErrors: [AgentKind: String] = [:]

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
                Picker("If Airbag doesn't respond in time", selection: Binding(get: { model.strictMode }, set: { setStrict($0) })) {
                    Text("Let the Command Run").tag(false)
                    Text("Block the Command").tag(true)
                }
                // The choice is saved either way; choosing it again retries the agents listed here.
                ForEach(AgentKind.allCases.filter { strictErrors[$0] != nil }, id: \.self) { agent in
                    Callout(.danger, verbatim: "\(agent.displayName): \(strictErrors[agent] ?? "")").font(.callout)
                }
            } footer: {
                Footer(Text("Blocking works in Claude Code and Cursor."))
            }
            if !model.disabledRules.isEmpty {
                Section {
                    ForEach(model.disabledRules.sorted(), id: \.self) { DisabledRuleRow(ruleID: $0) }
                } header: {
                    Text("Checks turned off")
                } footer: {
                    Footer(Text("Turned off in Guard. Commands these rules cover run without a check."))
                }
            }
        }
        .animation(.snappy, value: strictErrors)
        .animation(.snappy, value: model.disabledRules)
        .onAppear { model.refreshHooksUnlessFrozen() }
        // Back from the agent (e.g. after trusting the hook in Codex) or from editing its settings by hand.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshHooksUnlessFrozen()
            dropFixedStrictErrors()
        }
    }

    func setStrict(_ on: Bool) {
        strictErrors = Dictionary(model.setStrict(on).map { ($0.agent, $0.error) }, uniquingKeysWith: { first, _ in first })
    }

    /// A file the user fixed by hand meanwhile no longer needs its message.
    func dropFixedStrictErrors() {
        guard !strictErrors.isEmpty, !model.frozen else { return }
        strictErrors = strictErrors.filter { agent, _ in (try? model.installer.plan(agent, install: true, strict: model.strictMode))?.changed != false }
    }
}

/// A Guard rule switched off with "Check commands like this", with the way back (its Guard entries may be gone).
private struct DisabledRuleRow: View {
    @EnvironmentObject var model: AppModel
    let ruleID: String

    var body: some View {
        LabeledContent {
            Button("Turn On") { model.setRule(ruleID, enabled: true) }
        } label: {
            if let category = ruleCategory(ruleID) {
                Text(verbatim: category)
                Text(verbatim: ruleID).font(Theme.monoSmall).textSelection(.enabled)
            } else {
                Text(verbatim: ruleID).font(Theme.mono).textSelection(.enabled)
            }
        }
    }
}

/// What kind of harm a rule is about, from its id ("git.push.force" → Git history); the same words as the Guard view.
private func ruleCategory(_ ruleID: String) -> String? {
    switch ruleID.split(separator: ".").first.map(String.init) ?? "" {
    case "fs": return String(localized: "Files outside the project")
    case "git": return String(localized: "Git history")
    case "cloud": return String(localized: "Cloud resources")
    case "sys", "disk": return String(localized: "System")
    case "net": return String(localized: "Downloaded script")
    case "shell": return String(localized: "Unclear command")
    case "self": return String(localized: "Airbag's protection")
    case "db": return String(localized: "Databases")
    default: return nil
    }
}

/// What an agent's row says, from evidence: a connected agent turns green only once Airbag has seen it call.
private enum AgentHealth: Equatable {
    case connected(lastCall: Int64)
    case waiting
    case needsRepair(moved: Bool)
    /// The settings file has comments or cannot be read: Airbag will not rewrite it, the entries go in by hand.
    case cannotEdit
    case notConnected
    case notFound

    /// `editable`: Connect or Repair could rewrite the agent's settings file.
    init(_ s: HookInstaller.AgentStatus, lastCall: Int64?, editable: Bool) {
        let working = s.installed && s.current && !s.staleCommand && !s.brokenCommand
        if !working && (!editable || (!s.installed && s.note != nil)) { self = .cannotEdit }
        else if !s.installed { self = s.detected ? .notConnected : .notFound }
        else if s.staleCommand || s.brokenCommand { self = .needsRepair(moved: true) }
        else if !s.current { self = .needsRepair(moved: false) }
        else if let lastCall { self = .connected(lastCall: lastCall) }
        else { self = .waiting }
    }

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .waiting: "circle.dashed"
        case .needsRepair, .cannotEdit: "exclamationmark.triangle.fill"
        case .notConnected: "circle"
        case .notFound: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .connected: return Theme.ok
        case .needsRepair, .cannotEdit: return Theme.warning
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
        case .cannotEdit: return Text("Can't edit settings file")
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
    /// Why Airbag would not rewrite the settings file; read when the row appears and when the status changes, not on
    /// every model update.
    @State private var planError: Error?

    var health: AgentHealth { AgentHealth(status, lastCall: model.lastHookAt[status.agent], editable: planError == nil) }
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
            Button("Disconnect", role: .destructive) { disconnect() }
        } message: {
            Text("\(name) will run commands without snapshots or safety checks.")
        }
        .onAppear { checkFile(animated: false) }
        .onChange(of: status) { checkFile() }
        .onChange(of: model.strictMode) { checkFile() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkFile() }
    }

    func checkFile(animated: Bool = true) {
        var t = Transaction()
        t.disablesAnimations = !animated
        withTransaction(t) { planError = model.hookPlanError(status.agent) }
    }

    var helpText: Text {
        if case .connected(let t) = health { return Text(RelativeTime.precise(ms: t)) }
        return Text(verbatim: (status.configPath as NSString).abbreviatingWithTildeInPath)
    }

    @ViewBuilder var detail: some View {
        switch health {
        case .needsRepair(let moved):
            if moved { Text("Points to an Airbag copy that was moved") } else { Text("Set up by an older version of Airbag") }
        case .cannotEdit:
            if let planError { Text(verbatim: model.describe(planError)) }
        case .waiting where status.agent == .codex:
            Text("Codex asks you to trust new hooks once: open Codex, type /hooks and press t.")
        default: EmptyView()
        }
    }

    @ViewBuilder var buttons: some View {
        switch health {
        case .notFound:
            EmptyView()
        case .cannotEdit:
            // Connect, Repair and Disconnect would all fail on the same file; Show Changes gives the entries to add.
            showChangesButton
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

    /// A commented file that has Airbag's entries (added by hand) cannot be edited either: they come out by hand too.
    func disconnect() {
        error = model.disconnect(status.agent)
        if error != nil, let e = planError as? HookInstallError, case .hasComments(let file) = e {
            let fileText = (file as NSString).abbreviatingWithTildeInPath
            error = String(localized: "\(fileText) has comments Airbag would remove. Remove Airbag's entries by hand.")
        }
    }
}

/// "Show Changes…": what Connect or Repair would write into the agent's settings file, as a diff. For a file Airbag
/// will not rewrite (comments, unreadable), the entries to add by hand.
struct AgentChangesView: View {
    @EnvironmentObject var model: AppModel
    let agent: AgentKind
    /// Preview rendering passes the result instead of reading the real file.
    var preset: Result<(path: String, diff: TextDiff), Error>? = nil
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch preset ?? plan {
            case .success(let p):
                pathLine(p.path)
                box { DiffView(diff: p.diff) }
            case .failure:
                let snippet = model.installer.snippet(agent, strict: model.strictMode)
                let path = model.installer.configPath(agent)
                pathLine(path)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Add these entries to the file by hand.")
                    Spacer(minLength: 12)
                    Button("Show in Finder") {
                        model.revealFiles(root: (path as NSString).deletingLastPathComponent, paths: [(path as NSString).lastPathComponent])
                    }
                    Button { copy(snippet) } label: {
                        Label("Copy", systemImage: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                    }
                }
                box { Text(verbatim: snippet).font(Theme.monoSmall).textSelection(.enabled).fixedSize() }
            }
        }
        .padding(14)
    }

    func pathLine(_ path: String) -> some View {
        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
            .font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
    }

    func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal) { content().padding(8) }
        }
        .frame(width: 520, height: 300)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    var plan: Result<(path: String, diff: TextDiff), Error> {
        if model.frozen, let e = AppModel.previewPlanErrors[agent] { return .failure(e) }
        return Result {
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
    @State private var confirmStop = false
    /// Stop Protecting is running (deleting a large store takes a moment); the row goes away when it is done.
    @State private var stopping = false
    @State private var stopError: String?

    var busy: Bool { model.snapshottingRoots.contains(project.root) || stopping }

    /// What went wrong last: Stop Protecting, a Take Snapshot click, else the first snapshot of a folder added this session.
    var failure: String? {
        if let stopError { return stopError }
        if case .failed(let why) = result { return why }
        if result == nil, case .failed(let why) = model.firstSnapshotResults[project.root] { return why }
        return nil
    }

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
                Menu { menuItems(includeSnapshot: false) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(Text("More actions")).accessibilityLabel(Text("More actions"))
            }
            if let failure {
                Callout(.danger, verbatim: failure).font(.caption).labelStyle(InlineLabelStyle()).transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { menuItems(includeSnapshot: true) }
        .animation(.snappy, value: failure)
        .confirmationDialog(Text("Stop protecting \(project.name)?"), isPresented: $confirmStop) {
            Button("Stop Protecting", role: .destructive) { stop() }
        } message: {
            Text("Its snapshots are deleted. Add the folder again to protect it.")
        }
        // The model reports a failed Stop Protecting as a message; it is shown here instead (on success the row goes away).
        .onChange(of: model.toast?.id) {
            guard stopping, let toast = model.toast, toast.style == .failure else { return }
            stopping = false
            stopError = toast.text
        }
    }

    /// Also offered for a missing folder: it is the only way to remove that project.
    @ViewBuilder func menuItems(includeSnapshot: Bool) -> some View {
        if includeSnapshot {
            Button("Take Snapshot") { take() }.disabled(!project.rootExists || busy)
        }
        Button("Show in Finder") { model.revealInFinder(project.root) }.disabled(!project.rootExists)
        Divider()
        Button("Stop Protecting…", role: .destructive) { confirmStop = true }.disabled(busy)
    }

    func stop() {
        stopError = nil
        stopping = true
        model.removeProject(root: project.root)
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
        stopError = nil
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

    /// Why Connect would not rewrite the agent's settings file (comments, unreadable, unexpected format), or nil.
    /// Preview rendering reads no real file: it uses `previewPlanErrors`.
    func hookPlanError(_ agent: AgentKind) -> Error? {
        if frozen { return Self.previewPlanErrors[agent] }
        do { _ = try installer.plan(agent, install: true, strict: strictMode); return nil } catch { return error }
    }

    /// Set by preview rendering to show the "Can't edit settings file" state.
    static var previewPlanErrors: [AgentKind: Error] = [:]

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
