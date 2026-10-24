import AirbagCore
import AppKit
import SwiftUI

/// The menu bar popover (docs/design/13-product-spec.md §6.3). The header answers "am I protected"; below it, each only
/// when it has something: what needs you, what happened since you last looked, recent changes with Undo, the projects.
struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    /// Height of the scrolling content: the popover hugs it and scrolls only past `maxScrollHeight`.
    @State private var contentHeight: CGFloat = 0
    /// Bumped when something new needs the user: the header symbol bounces once, where the user can see it.
    @State private var bounce = 0
    /// How much needed the user when they last saw the popover (things that arrive while it is closed bounce on open).
    @State private var shownAttention = 0
    /// Sessions whose servers are being stopped, and why a stop failed (the row stays and says so).
    @State private var stopping: Set<String> = []
    @State private var stopErrors: [String: String] = [:]
    /// How many unprotected pause commands "Got it" acknowledged (reset when the next pause starts).
    @State private var reviewedPauseCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let toast = model.toast {
                ToastView(toast: toast).padding(.horizontal, 6).padding(.bottom, 10)
            }
            Divider()
            ScrollView {
                content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), maxScrollHeight))
            Divider()
            footer
        }
        .frame(width: 380)
        .background { shortcuts }
        .animation(.snappy, value: model.toast?.id)
        .onChange(of: attentionCount) { _, new in
            guard model.popoverVisible else { return }
            if new > shownAttention { bounce += 1 }
            shownAttention = new
        }
        .onChange(of: model.pausedUntil == nil) { _, running in if !running { reviewedPauseCount = 0 } }
        .onAppear {
            model.popoverVisible = true
            model.refreshAll()
            if attentionCount > shownAttention {
                // After the popover has opened, or the bounce plays unseen.
                Task { try? await Task.sleep(for: .milliseconds(250)); bounce += 1 }
            }
            shownAttention = attentionCount
        }
        .onDisappear { model.popoverVisible = false }
    }

    /// The whole popover stays under about 560 pt; the content scrolls beyond that.
    private var maxScrollHeight: CGFloat { model.toast == nil ? 450 : 396 }

    private var attentionCount: Int { model.needsApproval.count + model.leftRunning.count + model.unseenGuards.count }

    // MARK: header

    var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: model.iconState.symbol)
                .font(.system(size: 22))
                .foregroundStyle(stateColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.headline).font(.body.weight(.semibold)).lineLimit(2)
                if !model.subline.isEmpty {
                    Text(verbatim: subline).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            if model.pausedUntil != nil {
                Button("Resume") { model.pause(until: nil) }.controlSize(.small)
            } else if let issue = headerIssue {
                Button(issue.fixTitle) { model.fix(issue) }.controlSize(.small)
            }
            moreMenu
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .animation(.snappy, value: model.headline)
    }

    /// The model's subline starts a line here, so it starts with a capital ("Blocks still on"); when it wraps, the
    /// " · " separator stays at the end of the first line.
    private var subline: String {
        let text = model.subline.replacingOccurrences(of: " · ", with: "\u{00A0}· ")
        return text.prefix(1).localizedUppercase + text.dropFirst()
    }

    private var stateColor: Color {
        switch model.iconState {
        case .needsYou, .degraded: return Theme.warning
        case .protected: return Theme.ok
        case .paused, .idle: return .secondary
        }
    }

    /// The issue the headline shows (it wins over everything but a pause and a waiting agent); its fix sits next to it.
    private var headerIssue: ProtectionIssue? {
        model.pausedUntil == nil && model.needsApproval.isEmpty ? model.protectionIssues.first : nil
    }

    /// An issue the headline cannot show right now (paused, or an agent is waiting): it gets its own row instead.
    private var hiddenIssue: ProtectionIssue? {
        headerIssue == nil ? model.protectionIssues.first : nil
    }

    var moreMenu: some View {
        Menu {
            Button("Take Snapshot of All Projects") { model.snapshotAll() }
                .disabled(!model.projects.contains(where: \.rootExists) || !model.snapshottingRoots.isEmpty)
            Button("Add Project…") { addProject() }
            Divider()
            Button("Settings…") { model.windowRequest = .settings }.keyboardShortcut(",", modifiers: .command)
            Button("Quit Airbag") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("More actions"))
        .accessibilityLabel(Text("More actions"))
    }

    // MARK: content

    var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let issue = hiddenIssue { issueRow(issue) }
            if !model.needsApproval.isEmpty || !model.leftRunning.isEmpty { needsYou }
            if !model.unseenGuards.isEmpty || unprotectedAfterPause { sinceLastLook }
            if !model.recentChanges.isEmpty { recentChanges }
            if model.projects.isEmpty { emptyCard } else { projects }
        }
        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: layoutKey)
    }

    /// Changes whenever a row comes or goes, so insertions and removals animate.
    private var layoutKey: [String] {
        var key: [String] = model.needsApproval.map(\.id)
        key += model.leftRunning.map { String($0.identity.pid) }
        key += model.unseenGuards.map(\.id)
        key += model.recentChanges.map(\.id)
        key += model.projects.map(\.root)
        key += stopErrors.keys.sorted()
        key += [unprotectedAfterPause ? "paused" : "", hiddenIssue?.id ?? ""]
        return key
    }

    func issueRow(_ issue: ProtectionIssue) -> some View {
        HStack(spacing: 8) {
            Callout(.warning, verbatim: issue.text).font(.callout)
            Spacer(minLength: 6)
            Button(issue.fixTitle) { model.fix(issue) }.controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .card(cornerRadius: 8)
    }

    // MARK: needs you

    var needsYou: some View {
        PopoverSection(Text("Needs you")) {
            VStack(spacing: 6) {
                ForEach(model.needsApproval) { approvalCard($0) }
                ForEach(leftRunningSessions, id: \.id) { leftRunningCard(session: $0.id, procs: $0.procs) }
            }
        }
    }

    func approvalCard(_ g: GuardEntry) -> some View {
        let style = GuardStyle(g.decision)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: style.symbol).foregroundStyle(style.color).frame(width: 18).accessibilityLabel(Text(style.title))
                VStack(alignment: .leading, spacing: 2) {
                    CommandText(command: g.command, lines: 2)
                    Text(verbatim: [g.projectRoot.map { ($0 as NSString).lastPathComponent }, g.agent?.displayName,
                                    RelativeTime.age(ms: g.ts)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        .help(Text(RelativeTime.precise(ms: g.ts)))
                }
            }
            HStack(spacing: 6) {
                if g.canAllowOnce { Button("Allow Once") { model.allowOnce(g) } }
                Button("Dismiss") { model.dismiss(g) }
                Spacer()
                showButton { model.reveal(.guardEntry(g.id)) }
            }
            .controlSize(.small)
            .padding(.leading, 26)
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 8)
    }

    /// Servers left running, one group per ended agent session.
    private var leftRunningSessions: [(id: String, procs: [RadarProcess])] {
        Dictionary(grouping: model.leftRunning) { $0.attribution?.agentSessionID ?? "-" }
            .map { (id: $0.key, procs: $0.value.sorted { $0.startedAtMs < $1.startedAtMs }) }
            .sorted { $0.id < $1.id }
    }

    func leftRunningCard(session sid: String, procs: [RadarProcess]) -> some View {
        let first = procs[0]
        let busy = stopping.contains(sid)
        let attribution = first.attribution
        let project = (attribution?.projectRoot ?? first.cwd).map { ($0 as NSString).lastPathComponent }
        let ports = Set(procs.flatMap { $0.listeners.map(\.port) }).sorted().map { ":\($0)" }.joined(separator: " ")
        let caption = [attribution?.agent?.displayName, attribution?.sessionTitle ?? project, ports.isEmpty ? nil : ports]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.warning).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session ended — stop its \(procs.count) servers?").font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: caption).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        .help(Text(verbatim: procs.map { "\($0.name) \($0.portsText)" }.joined(separator: ", ")))
                }
            }
            if let error = stopErrors[sid] {
                Callout(.warning, verbatim: error).font(.subheadline).padding(.leading, 26)
            }
            HStack(spacing: 6) {
                Button { stop(session: sid, procs) } label: {
                    ZStack {
                        Text("Stop").opacity(busy ? 0 : 1)
                        if busy { ProgressView().controlSize(.mini) }
                    }
                }
                .disabled(busy)
                Button("Keep Running") { stopErrors[sid] = nil; procs.forEach(model.keep) }.disabled(busy)
                Spacer()
                showButton { model.reveal(.process(first.identity)) }
            }
            .controlSize(.small)
            .padding(.leading, 26)
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 8)
    }

    /// Stops every server of a session; a refusal keeps the row with the reason. Stopped servers leave with the next
    /// radar scan, so the progress stays until then instead of flashing "Stop" again.
    func stop(session sid: String, _ procs: [RadarProcess]) {
        stopping.insert(sid)
        stopErrors[sid] = nil
        Task {
            var failure: String?
            for p in procs {
                let message = await model.stopProcess(p, force: false)
                if !message.isEmpty, failure == nil { failure = message }
            }
            if let failure { stopErrors[sid] = failure } else { try? await Task.sleep(for: .seconds(3)) }
            stopping.remove(sid)
        }
    }

    /// "Show ›": opens the window that has the item, scrolled to it. Secondary, so it never reads as a web link.
    func showButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text("Show")
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    // MARK: since you last looked

    /// Agent commands ran without snapshots during a pause that has ended (and "Got it" has not acknowledged them).
    private var unprotectedAfterPause: Bool { model.pausedUntil == nil && model.unprotectedDuringPause > reviewedPauseCount }

    var sinceLastLook: some View {
        let unseen = model.unseenGuards
        return PopoverSection(Text("Since you last looked")) {
            Button("Got it") {
                model.markGuardsReviewed()
                reviewedPauseCount = model.unprotectedDuringPause
            }
            .controlSize(.small)
        } content: {
            let shown = Self.shownCount(unseen.count, limit: 4)
            ForEach(unseen.prefix(shown)) { unseenRow($0) }
            if unseen.count > shown { moreRow(unseen.count - shown, inset: 26) { model.windowRequest = .main(.guardLog) } }
            if unprotectedAfterPause {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary).frame(width: 18)
                    Text("\(model.unprotectedDuringPause) commands ran without snapshots").font(.callout).lineLimit(2)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
        }
    }

    func unseenRow(_ g: GuardEntry) -> some View {
        let style = GuardStyle(g.decision)
        let project = g.projectRoot.map { ($0 as NSString).lastPathComponent }
        return Button { model.reveal(.guardEntry(g.id)) } label: {
            HStack(spacing: 8) {
                Image(systemName: style.symbol).foregroundStyle(style.color).frame(width: 18).accessibilityLabel(Text(style.title))
                RowCommand(command: g.command).frame(minWidth: 110, alignment: .leading)
                Spacer(minLength: 8)
                Text(verbatim: [project, RelativeTime.age(ms: g.ts)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .help(Text(style.title) + Text(verbatim: " · " + [g.agent?.displayName, RelativeTime.precise(ms: g.ts)].compactMap { $0 }.joined(separator: " · ")))
    }

    // MARK: recent changes

    var recentChanges: some View {
        PopoverSection(Text("Recent changes")) {
            ForEach(Array(model.recentChanges.prefix(3).enumerated()), id: \.element.id) { index, change in
                RecentChangeRow(change: change, isNewest: index == 0)
            }
        }
    }

    // MARK: projects

    var projects: some View {
        PopoverSection(Text("Projects")) {
            let shown = Self.shownCount(model.projects.count, limit: 6)
            ForEach(model.projects.prefix(shown)) { PopoverProjectRow(project: $0) }
            if model.projects.count > shown { moreRow(model.projects.count - shown, inset: 15) { model.windowRequest = .main(.timeline) } }
        }
    }

    /// No projects yet: the two ways to get protected, right here. The shield and title appear only when the header
    /// says something else (e.g. paused); otherwise they would repeat the header right above.
    var emptyCard: some View {
        VStack(spacing: 6) {
            if model.headline != String(localized: "Nothing protected yet") {
                Image(systemName: "shield").font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 2)
                Text("Nothing protected yet").font(.body.weight(.semibold))
            }
            Text("Projects your agents work in are protected automatically.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Connect Agents…") { model.openSettings(tab: "agents") }
                Button("Add Project…") { addProject() }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12).padding(.vertical, 16)
        .card(cornerRadius: 10)
    }

    /// Rows to list before "N more…": one hidden row would take the same space as its "1 more…", so it is shown.
    static func shownCount(_ count: Int, limit: Int) -> Int { count <= limit + 1 ? count : limit }

    /// "3 more…": opens the window that lists everything.
    func moreRow(_ remainingCount: Int, inset: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(remainingCount) more…").font(.callout).foregroundStyle(.secondary).padding(.leading, inset)
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: footer

    var footer: some View {
        HStack {
            Menu {
                Button("For 15 Minutes") { model.pause(minutes: 15) }
                Button("For 1 Hour") { model.pause(minutes: 60) }
                Button("Until \(RelativeTime.moment(model.nextMorning))") { model.pauseUntilTomorrowMorning() }
            } label: {
                Text("Pause")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button("Open Airbag") { model.windowRequest = .main(model.selectedTab) }
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Shortcuts without a visible control: ⌘1–3 open the views; ⌘, and ⌘Q also work while the ⋯ menu is closed.
    var shortcuts: some View {
        ZStack {
            ForEach(Array(MainTab.allCases.enumerated()), id: \.element) { index, tab in
                Button { model.windowRequest = .main(tab) } label: { EmptyView() }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button { model.windowRequest = .settings } label: { EmptyView() }.keyboardShortcut(",", modifiers: .command)
            Button { NSApp.terminate(nil) } label: { EmptyView() }.keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: actions

    /// The folder panel; several folders can be added at once, and one message reports them all.
    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Protect")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var added: [String] = []
        var failure: String?
        for url in panel.urls {
            if let error = model.addProject(url, announce: false) { failure = failure ?? error } else { added.append(url.lastPathComponent) }
        }
        if let failure { model.show(failure, style: .failure) }
        else if !added.isEmpty {
            let names = ListFormatter.localizedString(byJoining: added)
            model.show(String(localized: "Protecting \(names)…"), style: .success)
        }
    }
}

/// A popover section: a small header (with an optional control on the right) over its rows.
private struct PopoverSection<Accessory: View, Content: View>: View {
    let title: Text
    let accessory: Accessory
    let content: Content

    init(_ title: Text, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                title.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                Spacer()
                accessory
            }
            .frame(minHeight: 20)
            .padding(.horizontal, 8).padding(.bottom, 2)
            content
        }
        .transition(.opacity)
    }
}

extension PopoverSection where Accessory == EmptyView {
    init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A command in a clickable row: like `CommandText`, but not selectable, so a click anywhere opens the row.
private struct RowCommand: View {
    let command: String
    var body: some View {
        Text(verbatim: command).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).help(Text(verbatim: command))
    }
}

/// One recent change: what it did (loaded once per snapshot), and Undo right there. A click opens it in the Timeline.
private struct RecentChangeRow: View {
    @EnvironmentObject var model: AppModel
    let change: RecentChange
    /// The newest change takes ⌘Z.
    let isNewest: Bool
    @State private var files: [FileChange]?
    @State private var undoing = false
    /// The snapshot the undo took first. While it is still the last restore, the row shows a check instead of Undo
    /// (Undo on the message, or Undo Restore, brings the button back).
    @State private var undoneBy: String?
    @State private var accessoryWidth: CGFloat = 0

    var body: some View {
        Button { model.reveal(.snapshot(root: change.root, id: change.snapshotID)) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol.0).foregroundStyle(symbol.1).frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    if let command = change.command { RowCommand(command: command) } else { Text("File changes").font(.callout) }
                    caption.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        .help(Text(RelativeTime.precise(ms: change.at)))
                }
                Spacer(minLength: 8)
            }
            .padding(.trailing, accessoryWidth)
        }
        .buttonStyle(MenuRowButtonStyle())
        .overlay(alignment: .trailing) {
            accessory
                .padding(.trailing, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { accessoryWidth = $0 }
        }
        .task(id: change.snapshotID) {
            guard files == nil else { return }
            files = await model.changes(root: change.root, snapshot: change.snapshotID)
        }
    }

    private var isUndone: Bool { undoneBy != nil && model.lastRestore?.undoSnapshot == undoneBy }

    @ViewBuilder var accessory: some View {
        if isUndone {
            Image(systemName: "checkmark.circle.fill").font(.body).foregroundStyle(Theme.ok)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(Text("Done"))
        } else {
            undoButton.transition(.opacity)
        }
    }

    /// Immediate: Undo is itself undoable (Airbag snapshots first, and the message offers Undo).
    var undoButton: some View {
        Button {
            undoing = true
            let before = model.lastRestore?.undoSnapshot
            Task {
                await model.undoChanges(root: change.root, snapshot: change.snapshotID)
                let after = model.lastRestore?.undoSnapshot
                withAnimation(.snappy) {
                    if let after, after != before { undoneBy = after }
                    undoing = false
                }
            }
        } label: {
            ZStack {
                Text("Undo").opacity(undoing ? 0 : 1)
                if undoing { ProgressView().controlSize(.mini) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(undoing)
        .keyboardShortcut(isNewest ? KeyboardShortcut("z", modifiers: .command) : nil)
    }

    var symbol: (String, Color) {
        guard let files, !files.isEmpty else { return ("doc", .secondary) }
        return ChangeCounts.symbol(files)
    }

    /// "shop-app · Claude Code · 2 deleted · 2 min ago".
    var caption: Text {
        var parts = [Text(verbatim: change.projectName)]
        if let agent = change.agent { parts.append(Text(verbatim: agent.displayName)) }
        parts += counts
        parts.append(Text(verbatim: RelativeTime.age(ms: change.at)))
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
    }

    var counts: [Text] {
        guard let files, !files.isEmpty else { return [Text("\(change.changedCount) files")] }
        let deletedCount = files.filter { $0.status == .deleted }.count
        let changedCount = files.filter { $0.status == .modified || $0.status == .typeChanged }.count
        let addedCount = files.filter { $0.status == .added }.count
        var out: [Text] = []
        if deletedCount > 0 { out.append(Text("\(deletedCount) deleted")) }
        if changedCount > 0 { out.append(Text("\(changedCount) changed")) }
        if addedCount > 0 { out.append(Text("\(addedCount) added")) }
        return out
    }
}

/// A project on one line: live dot, name, where it stands; ports open the server. A click opens its Timeline.
private struct PopoverProjectRow: View {
    @EnvironmentObject var model: AppModel
    let project: ProjectRow
    @State private var accessoryWidth: CGFloat = 0

    var body: some View {
        let live = project.liveSessions > 0
        Button { model.selectedRoot = project.root; model.windowRequest = .main(.timeline) } label: {
            HStack(spacing: 6) {
                Circle().fill(live ? Theme.ok : Color.secondary.opacity(0.35)).frame(width: 7, height: 7).padding(.trailing, 2)
                    .accessibilityLabel(Text(live ? "live session" : "idle"))
                name
                if !project.rootExists { Pill(text: "Folder missing", color: Theme.danger) }
                Spacer(minLength: 8)
            }
            .padding(.trailing, accessoryWidth)
        }
        .buttonStyle(MenuRowButtonStyle())
        .overlay(alignment: .trailing) {
            HStack(spacing: 8) {
                if model.snapshottingRoots.contains(project.root) { ProgressView().controlSize(.mini).allowsHitTesting(false) }
                ForEach(project.ports.prefix(3), id: \.self) { PortLink(port: $0, font: .subheadline) }
                if let t = project.lastSnapshotAt {
                    Text(verbatim: RelativeTime.age(ms: t)).font(.subheadline).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .padding(.trailing, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { accessoryWidth = $0 }
        }
        .help(help)
        .contextMenu {
            Button("Take Snapshot") { model.snapshotNow(project.root) }.disabled(!project.rootExists)
            Button("Show in Finder") { model.revealInFinder(project.root) }
        }
    }

    /// Where the project is (two worktrees can share a name) and the exact time of its last snapshot.
    var help: Text {
        let path = Text(verbatim: (project.root as NSString).abbreviatingWithTildeInPath)
        guard let t = project.lastSnapshotAt else { return path }
        let timeText = RelativeTime.precise(ms: t)
        return path + Text(verbatim: "\n") + Text("snapshot \(timeText)")
    }

    var name: some View {
        HStack(spacing: 4) {
            Text(verbatim: project.name).lineLimit(1).truncationMode(.middle)
            if project.isWorktree { Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.isWorktree ? Text("\(project.name) (worktree)") : Text(verbatim: project.name))
    }
}
