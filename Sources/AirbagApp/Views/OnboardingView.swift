import AirbagCore
import AppKit
import SwiftUI

/// First run: what Airbag does → connect agents → choose projects → a live check that it works. Under a minute, and it
/// says "You're protected" only when an agent is connected and a project is added.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Int
    /// The edge the next page comes in from (Back reverses it).
    @State private var edge: Edge = .trailing
    @State private var moveError: String?

    @State private var selectedAgents: Set<AgentKind> = []
    /// Detection seeds the selection until the user changes it.
    @State private var agentsTouched = false
    @State private var connectResults: [AgentKind: ConnectPhase] = [:]
    @State private var connecting = false
    @State private var expandedAgent: AgentKind?
    @State private var changesText = ""

    @State private var suggestions: [Suggestion]?
    @State private var chosenRoots: Set<String> = []
    @State private var addedRoots: [String] = []
    @State private var addErrors: [String: String] = [:]
    @State private var dropTargeted = false

    /// A hook call after this moment proves that the agent's connection works.
    @State private var startedAt = Clock.nowMsInt()
    @State private var testResult: (ok: Bool, detail: String)?
    @State private var testing = false
    @State private var openAtLogin = true
    @State private var finished = false

    /// `step` and `suggestions` let the preview renderer show any page with demo data (nothing on the Mac is read).
    init(step: Int = 0, suggestions: [(path: String, usedAt: Date)]? = nil) {
        _step = State(initialValue: step)
        if let suggestions {
            _suggestions = State(initialValue: suggestions.map { Suggestion(path: $0.path, usedAt: $0.usedAt, picked: false) })
            _chosenRoots = State(initialValue: Set(suggestions.prefix(3).map(\.path)))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page.id(step).transition(reduceMotion ? .opacity : .push(from: edge))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        // The hidden title bar keeps its 28 pt safe area above this: the window is about 560 × 520.
        .frame(width: 560, height: 492)
        .task { await loadSuggestions() }
        .onChange(of: model.hookStatuses, initial: true) { _, statuses in
            guard !agentsTouched else { return }
            selectedAgents = Set(statuses.filter { canConnect($0) }.map(\.agent))
        }
        // Everything is set up by the last page: closing the window there counts as Done.
        .onDisappear { if step == 3 && !finished { applyChoices() } }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: welcome
        case 1: agentsStep
        case 2: projectsStep
        default: doneStep
        }
    }

    /// Changes the page; the leaving page needs the new direction before it is removed, hence the extra turn.
    private func go(to newStep: Int) {
        edge = newStep > step ? .trailing : .leading
        DispatchQueue.main.async { withAnimation(.snappy) { step = newStep } }
    }

    // MARK: chrome

    private func appIcon(_ size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func header(_ title: Text, _ subtitle: Text?) -> some View {
        VStack(spacing: 4) {
            appIcon(44).padding(.bottom, 4)
            title.font(.title2.weight(.semibold))
            if let subtitle {
                subtitle.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2).padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            PageDots(step: step)
            Spacer()
            footerButtons
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
    }

    @ViewBuilder private var footerButtons: some View {
        switch step {
        case 0:
            if model.installLocationProblem != nil {
                Button("Continue") { go(to: 1) }
                Button("Move to Applications") { withAnimation(.snappy) { moveError = model.moveToApplications() } }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Get Started") { go(to: 1) }.keyboardShortcut(.defaultAction)
            }
        case 1:
            Button("Back") { go(to: 0) }.disabled(connecting)
            if pendingAgents.isEmpty {
                Button("Continue") { go(to: 2) }.keyboardShortcut(.defaultAction).disabled(connecting)
            } else {
                Button("Connect") { connectSelected() }.keyboardShortcut(.defaultAction).disabled(connecting)
            }
        case 2:
            Button("Back") { go(to: 1) }
            Button("Continue") { addChosen() }.keyboardShortcut(.defaultAction)
        default:
            Button("Open Timeline") { finish(openTimeline: true) }
            Button("Done") { finish(openTimeline: false) }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            appIcon(72).padding(.top, 4).padding(.bottom, 10)
            Text("Welcome to Airbag").font(.largeTitle.weight(.semibold))
            Text("A safety net for AI coding agents").font(.title3).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 18) {
                feature("camera", Text("Snapshots before every agent command"),
                        Text.withCommand(String(localized: "Undo an agent's changes in one click, even after \(Text.commandMarker)."), "rm -rf"))
                feature("hand.raised", Text("Stops what a snapshot cannot undo"),
                        Text("Wiping your home folder is blocked; force pushes are flagged in Guard."))
                feature("dot.radiowaves.left.and.right", Text("Finds servers agents leave running"),
                        Text("See which session started each dev server; stop the ones left running."))
            }
            .frame(width: 470, alignment: .leading)
            .padding(.top, 28)
            Spacer(minLength: 12)
            if let problem = model.installLocationProblem {
                VStack(alignment: .leading, spacing: 8) {
                    Callout(.warning, verbatim: problem)
                    if let moveError { Callout(.danger, verbatim: moveError).transition(.opacity) }
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .padding(.bottom, 12)
            }
            Label("Everything stays on this Mac. No account, no telemetry.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 32)
    }

    private func feature(_ symbol: String, _ title: Text, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.headline)
                text.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: agents

    enum ConnectPhase: Equatable {
        case working, connected, failed(String)
    }

    /// Not connected yet, or connected with an entry that needs rewriting (outdated, or the binary it names is gone).
    private func canConnect(_ s: HookInstaller.AgentStatus) -> Bool {
        s.detected && (!s.installed || !s.current || s.brokenCommand)
    }

    /// Selected agents that have not been tried yet. A failed one is retried with its own Retry button, so after a
    /// failure the primary button becomes Continue and the user can go on without that agent.
    private var pendingAgents: [AgentKind] {
        guard model.installLocationProblem == nil else { return [] }
        return model.hookStatuses.map(\.agent).filter { selectedAgents.contains($0) && connectResults[$0] == nil }
    }

    private var agentsStep: some View {
        VStack(spacing: 0) {
            header(Text("Connect your agents"),
                   Text("Airbag adds one entry to each agent's settings file. A backup is kept, and Disconnect in Settings removes it exactly."))
            VStack(alignment: .leading, spacing: 10) {
                if let problem = model.installLocationProblem {
                    Callout(.warning, verbatim: problem).font(.callout)
                }
                if model.hookStatuses.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120).card()
                } else {
                    FittingScroll(target: expandedAgent.map(AnyHashable.init)) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.hookStatuses.enumerated()), id: \.element.agent) { i, s in
                                if i > 0 { Divider().padding(.leading, 40) }
                                agentRow(s)
                            }
                        }
                    }
                    .card()
                }
                if !model.hookStatuses.isEmpty && !model.hookStatuses.contains(where: \.detected) {
                    Callout(.info, "No agents found on this Mac yet. When you install one, Airbag will offer to connect it.").font(.callout)
                }
                if selectedAgents.contains(.codex) || isConnected(.codex) {
                    Callout(.info, "Codex asks you to trust new hooks once: open Codex, type /hooks and press t.").font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private func isConnected(_ agent: AgentKind) -> Bool {
        if let phase = connectResults[agent] { return phase == .connected }
        return model.hookStatuses.first { $0.agent == agent }.map { $0.installed && !canConnect($0) } ?? false
    }

    private func agentRow(_ s: HookInstaller.AgentStatus) -> some View {
        let phase = connectResults[s.agent]
        let locked = connecting || model.installLocationProblem != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if phase == .working {
                        ProgressView().controlSize(.small)
                    } else if isConnected(s.agent) || phase != nil {
                        Image(systemName: phase == .connected || phase == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.body)
                            .foregroundStyle(phase == .connected || phase == nil ? Theme.ok : Theme.warning)
                            .contentTransition(.symbolEffect(.replace))
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                            .accessibilityHidden(true)
                    } else {
                        Toggle(isOn: agentBinding(s.agent)) { Text(verbatim: s.agent.displayName) }
                            .toggleStyle(.checkbox).labelsHidden()
                            .disabled(!canConnect(s) || locked)
                    }
                }
                .frame(width: 18, height: 18)
                AgentBadge(agent: s.agent).font(.body)
                    .foregroundStyle(s.detected ? .primary : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard canConnect(s), !locked, phase == nil else { return }
                        agentBinding(s.agent).wrappedValue.toggle()
                    }
                agentStatus(s, phase)
                Spacer(minLength: 8)
                if canConnect(s) && phase != .connected {
                    Button { toggleChanges(s.agent) } label: {
                        HStack(spacing: 3) {
                            Text("Show Changes")
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(expandedAgent == s.agent ? 90 : 0))
                        }
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .accessibilityValue(expandedAgent == s.agent ? Text(verbatim: "1") : Text(verbatim: "0"))
                }
            }
            if case .failed(let message) = phase {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await connect([s.agent]) } }.controlSize(.small).disabled(connecting)
                }
                .padding(.leading, 28)
                .transition(.opacity)
            }
            if expandedAgent == s.agent {
                changesPreview(s).transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .id(s.agent)
    }

    @ViewBuilder private func agentStatus(_ s: HookInstaller.AgentStatus, _ phase: ConnectPhase?) -> some View {
        Group {
            switch phase {
            case .connected: Text("Connected")
            case .failed: Text("Not connected")
            case .working: Text(verbatim: "")
            case nil:
                if !s.detected { Text("Not found on this Mac").foregroundStyle(.tertiary) }
                else if s.installed && canConnect(s) { Text("Needs repair") }
                else if s.installed { Text("Already connected") }
                else { Text("Found") }
            }
        }
        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }

    private func agentBinding(_ agent: AgentKind) -> Binding<Bool> {
        Binding(get: { selectedAgents.contains(agent) }, set: { on in
            agentsTouched = true
            if on { selectedAgents.insert(agent) } else { selectedAgents.remove(agent) }
        })
    }

    private func toggleChanges(_ agent: AgentKind) {
        if expandedAgent != agent {
            do { changesText = try model.installer.plan(agent, install: true, strict: model.strictMode).after ?? "" }
            catch { changesText = model.describe(error) }
        }
        withAnimation(.snappy) { expandedAgent = expandedAgent == agent ? nil : agent }
    }

    private func changesPreview(_ s: HookInstaller.AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: (s.configPath as NSString).abbreviatingWithTildeInPath)
                .font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: changesText).font(Theme.monoSmall).textSelection(.enabled)
                    .fixedSize().padding(8)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
        }
        .padding(.leading, 28)
    }

    /// Connects every pending agent, flips each row to its result, then moves on when nothing failed.
    private func connectSelected() {
        agentsTouched = true
        let agents = pendingAgents
        Task {
            await connect(agents)
            guard agents.allSatisfy({ connectResults[$0] == .connected }) else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if step == 1 { go(to: 2) }
        }
    }

    private func connect(_ agents: [AgentKind]) async {
        connecting = true
        withAnimation(.snappy) { for a in agents { connectResults[a] = .working } }
        for a in agents {
            // A moment of progress per row, so the change of each row can be followed.
            try? await Task.sleep(for: .milliseconds(180))
            let error = model.connect(a)
            withAnimation(.snappy) { connectResults[a] = error.map { .failed($0) } ?? .connected }
        }
        connecting = false
    }

    // MARK: projects

    struct Suggestion: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let usedAt: Date?
        /// Chosen in the Open panel or dropped: macOS already has the user's consent for that folder.
        let picked: Bool
    }

    private func loadSuggestions() async {
        guard suggestions == nil else { return }
        let found = await model.suggestedProjectsWithDates()
        let list = found.map { Suggestion(path: $0.path, usedAt: $0.usedAt, picked: false) }
        withAnimation(.snappy) {
            suggestions = (suggestions ?? []) + list.filter { s in !(suggestions ?? []).contains { $0.path == s.path } }
            chosenRoots.formUnion(list.filter { !isProtected($0.path) }.prefix(3).map(\.path))
        }
    }

    private func isProtected(_ path: String) -> Bool {
        addedRoots.contains(path) || model.projects.contains { $0.root == path || $0.root == FileSystem.canonicalPath(path) }
    }

    private var projectsStep: some View {
        VStack(spacing: 0) {
            header(Text("Choose projects to protect"),
                   suggestions?.isEmpty == false
                       ? Text("Suggested from your recent agent sessions. Projects where an agent works later are protected automatically.") : nil)
            Group {
                if let suggestions, suggestions.isEmpty {
                    ContentUnavailableView {
                        Image(systemName: "folder.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                    } description: {
                        Text("Projects are added automatically the first time an agent runs a command there.")
                    } actions: {
                        Button("Add Project…") { chooseFolders() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                } else if let suggestions {
                    FittingScroll {
                        VStack(spacing: 0) {
                            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, s in
                                if i > 0 { Divider().padding(.leading, 40) }
                                projectRow(s)
                            }
                        }
                    }
                    .card()
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120).card()
                }
            }
            // Folders dragged from Finder are added like picked ones.
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 2).opacity(dropTargeted ? 1 : 0))
            .dropDestination(for: URL.self) { urls, _ in
                addFolders(urls)
            } isTargeted: { on in
                withAnimation(.snappy) { dropTargeted = on }
            }
            if suggestions?.isEmpty == false {
                HStack {
                    Button("Add Project…") { chooseFolders() }
                    Spacer()
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private func projectRow(_ s: Suggestion) -> some View {
        let protected = isProtected(s.path)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(isOn: projectBinding(s.path, protected: protected)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: (s.path as NSString).lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                        Text(verbatim: (s.path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(Text(verbatim: s.path))
                        if !s.picked && !protected && Self.asksForAccess(s.path) {
                            Text("macOS will ask once to allow access.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.checkbox)
                .disabled(protected)
                if protected {
                    Text("Protected").font(.callout).foregroundStyle(.secondary)
                } else if let usedAt = s.usedAt {
                    let ageText = RelativeTime.short(ms: Int64(usedAt.timeIntervalSince1970 * 1000))
                    Text("used \(ageText)").font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .help(Text(verbatim: RelativeTime.precise(ms: Int64(usedAt.timeIntervalSince1970 * 1000))))
                }
            }
            if let error = addErrors[s.path] {
                Label {
                    Text(verbatim: error).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                .font(.callout)
                .padding(.leading, 28)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func projectBinding(_ path: String, protected: Bool) -> Binding<Bool> {
        Binding(get: { protected || chosenRoots.contains(path) }, set: { on in
            withAnimation(.snappy) {
                if on { chosenRoots.insert(path) } else { chosenRoots.remove(path); addErrors[path] = nil }
            }
        })
    }

    /// Folders macOS guards per app: the first read asks the user once.
    static func asksForAccess(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return ["Desktop", "Documents", "Downloads"].contains { path == home + "/" + $0 || path.hasPrefix(home + "/" + $0 + "/") }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Protect")
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { _ = addFolders(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            _ = addFolders(panel.urls)
        }
    }

    /// Adds picked or dropped folders to the list, chosen, newest on top.
    @discardableResult
    private func addFolders(_ urls: [URL]) -> Bool {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !folders.isEmpty else { return false }
        withAnimation(.snappy) {
            var list = suggestions ?? []
            for url in folders.reversed() {
                let path = FileSystem.canonicalPath(url.path) ?? url.path
                if !list.contains(where: { $0.path == path }) { list.insert(Suggestion(path: path, usedAt: nil, picked: true), at: 0) }
                chosenRoots.insert(path)
            }
            suggestions = list
        }
        return true
    }

    /// Adds the chosen folders (their first snapshot starts now, while this window is in front, so a macOS access prompt
    /// appears in context). Moves on when none failed; a second Continue skips the ones that did.
    private func addChosen() {
        var errors = addErrors
        var failed = false
        for s in suggestions ?? [] where chosenRoots.contains(s.path) && !isProtected(s.path) && addErrors[s.path] == nil {
            if let error = model.addProject(URL(fileURLWithPath: s.path), announce: false) {
                errors[s.path] = error
                failed = true
            } else {
                addedRoots.append(FileSystem.canonicalPath(s.path) ?? s.path)
            }
        }
        withAnimation(.snappy) { addErrors = errors }
        if !failed { go(to: 3) }
    }

    // MARK: done

    /// Agents connected now or before (setup can run again).
    private var connectedAgents: [AgentKind] {
        AgentKind.allCases.filter { isConnected($0) }
    }

    /// The projects added in setup, else the ones Airbag already protects.
    private var doneRoots: [String] {
        addedRoots.isEmpty ? model.projects.filter(\.rootExists).prefix(3).map(\.root) : addedRoots
    }

    private var isFullyProtected: Bool { !connectedAgents.isEmpty && !doneRoots.isEmpty }

    private var doneStep: some View {
        VStack(spacing: 0) {
            if isFullyProtected {
                header(Text("You're protected"), Text("Run any command in a new agent session to check that Airbag sees it."))
            } else if !connectedAgents.isEmpty {
                header(Text("Airbag is ready"), Text("Projects are added automatically the first time an agent runs a command there."))
            } else {
                header(Text("Airbag is ready"), Text("Connect an agent any time in Settings."))
            }
            VStack(alignment: .leading, spacing: 14) {
                if !connectedAgents.isEmpty || !doneRoots.isEmpty {
                    FittingScroll {
                        VStack(spacing: 0) {
                            ForEach(Array(connectedAgents.enumerated()), id: \.element) { i, agent in
                                if i > 0 { Divider().padding(.leading, 40) }
                                AgentCheckRow(agent: agent, startedAt: startedAt)
                            }
                            ForEach(Array(doneRoots.enumerated()), id: \.element) { i, root in
                                if i > 0 || !connectedAgents.isEmpty { Divider().padding(.leading, 40) }
                                ProjectCheckRow(root: root)
                            }
                        }
                    }
                    .card()
                }
                testRow
                menuBarRow
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Open Airbag at login", isOn: $openAtLogin)
                    if model.loginItem == .needsApproval {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Callout(.warning, "Allow Airbag in System Settings → General → Login Items to open it at login.")
                            Spacer(minLength: 8)
                            Button("Open Login Items") { model.openLoginItemsSettings() }.controlSize(.small)
                        }
                        .font(.callout)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private var testRow: some View {
        HStack(spacing: 10) {
            Button("Test Protection") { runTest() }
                .disabled(testing)
                .help(Text("Checks a command Airbag must block, without running it."))
            Group {
                if testing {
                    ProgressView().controlSize(.small)
                } else if let testResult {
                    Label {
                        Text(verbatim: testResult.detail).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testResult.ok ? Theme.ok : Theme.warning)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .font(.callout)
                }
            }
            .transition(.opacity)
            Spacer(minLength: 0)
        }
    }

    private func runTest() {
        withAnimation(.snappy) { testing = true }
        Task {
            let result = await model.testProtection()
            withAnimation(.snappy) { testResult = result; testing = false }
        }
    }

    private var menuBarRow: some View {
        HStack(spacing: 12) {
            Image(nsImage: MenuBarIcon.image(.protected, badge: false))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Airbag lives in the menu bar.").font(.callout)
                Text("Can't see it? Open Airbag from Applications any time.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func finish(openTimeline: Bool) {
        applyChoices()
        dismiss()
        if openTimeline { model.windowRequest = .main(.timeline) }
    }

    private func applyChoices() {
        finished = true
        if openAtLogin != model.launchAtLogin { model.launchAtLogin = openAtLogin }
        model.finishOnboarding()
    }
}

/// Four dots for the four pages (the step is read out as "Step 2 of 4").
private struct PageDots: View {
    let step: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(Color.primary.opacity(i == step ? 0.75 : 0.18)).frame(width: 7, height: 7)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step + 1) of 4"))
    }
}

/// Shows the content as it is when it fits, else scrolls it (a ScrollView alone would always take the full height),
/// keeping `target` (a row that just expanded) in view.
private struct FittingScroll<Content: View>: View {
    var target: AnyHashable?
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollViewReader { proxy in
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
                    .onAppear { reveal(proxy) }
                    .onChange(of: target) { reveal(proxy) }
            }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let target else { return }
        DispatchQueue.main.async { withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) } }
    }
}

/// The leading status of a checklist row: progress while waiting, then a check that bounces once when it arrives.
private struct CheckSlot: View {
    let done: Bool
    var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0
    var body: some View {
        Group {
            if done || failed {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(failed ? Theme.warning : Theme.ok)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: bounce)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            } else {
                ProgressView().controlSize(.small).transition(.opacity)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .onChange(of: done) { _, now in if now { bounce += 1 } }
    }
}

/// "Waiting for the first command…" until the agent calls Airbag after setup started.
private struct AgentCheckRow: View {
    @EnvironmentObject var model: AppModel
    let agent: AgentKind
    let startedAt: Int64
    var body: some View {
        let seen = (model.lastHookAt[agent] ?? 0) > startedAt
        HStack(spacing: 10) {
            CheckSlot(done: seen)
            AgentBadge(agent: agent).font(.body)
            Spacer(minLength: 8)
            Group {
                if seen { Text("Saw a command just now") } else { Text("Waiting for the first command…") }
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .animation(.snappy, value: seen)
    }
}

/// A project added in setup: progress while its first snapshot runs, then a check (or why there is none).
private struct ProjectCheckRow: View {
    @EnvironmentObject var model: AppModel
    let root: String
    /// The project list refreshes a moment after the snapshot ends; only a row still missing after that is a failure.
    @State private var settled = false
    var body: some View {
        let row = model.projects.first { $0.root == root }
        let snapshotting = model.snapshottingRoots.contains(root)
        let working = snapshotting || (row == nil && !settled)
        let ok = !working && (row?.snapshotCount ?? 0) > 0
        HStack(spacing: 10) {
            CheckSlot(done: ok, failed: !working && !ok)
            Label { Text(verbatim: (root as NSString).lastPathComponent) } icon: { Image(systemName: "folder") }
                .font(.body).lineLimit(1)
                .help(Text(verbatim: (root as NSString).abbreviatingWithTildeInPath))
            Spacer(minLength: 8)
            Group {
                if working { Text("Taking the first snapshot…") } else if ok { Text("Protected") } else { Text("No snapshots yet") }
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .animation(.snappy, value: working)
        .task(id: snapshotting) {
            settled = false
            guard !snapshotting else { return }
            try? await Task.sleep(for: .seconds(3))
            settled = true
        }
    }
}
