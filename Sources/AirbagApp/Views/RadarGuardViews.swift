import AirbagCore
import AppKit
import SwiftUI

// MARK: Radar

struct RadarScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var showAll = false
    @State private var selection = Set<ProcessIdentity>()
    @State private var sortOrder = [KeyPathComparator(\RadarProcess.portSortKey)]
    /// Stops in flight, stops that failed (with the reason), and stops that worked: those rows leave at once instead of
    /// waiting for the next scan.
    @State private var stopping = Set<ProcessIdentity>()
    @State private var failures: [ProcessIdentity: String] = [:]
    @State private var stopped = Set<ProcessIdentity>()
    @State private var rescans = 0

    private var rows: [RadarProcess] {
        (showAll ? model.allListening : model.servers).filter { !stopped.contains($0.identity) }.sorted(using: sortOrder)
    }

    private var selected: [RadarProcess] { rows.filter { selection.contains($0.identity) } }

    /// Servers left running, grouped by the session that started them, in the order the radar lists them.
    private var endedSessions: [EndedSession] {
        var out: [EndedSession] = []
        for p in model.leftRunning where !stopped.contains(p.identity) {
            let id = p.attribution?.agentSessionID ?? "?"
            if let i = out.firstIndex(where: { $0.id == id }) { out[i].servers.append(p); continue }
            out.append(EndedSession(id: id, agent: p.attribution?.agent, title: p.attribution?.sessionTitle,
                                    project: p.attribution?.projectRoot.map { ($0 as NSString).lastPathComponent }, servers: [p]))
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !endedSessions.isEmpty {
                    endedBanner.transition(.move(edge: .top).combined(with: .opacity))
                }
                if rows.isEmpty { emptyState } else { table }
            }
            .animation(.snappy, value: endedSessions.map(\.id))
            .onChange(of: model.focus, initial: true) { _, target in show(target, proxy) }
        }
        .navigationTitle(Text("Radar"))
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onChange(of: model.allListening.map(\.identity) + model.servers.map(\.identity)) { _, ids in
            let present = Set(ids)
            stopped.formIntersection(present)
            failures = failures.filter { present.contains($0.key) }
            selection.formIntersection(present)
        }
    }

    private var subtitle: String {
        let serverCount = model.servers.count
        guard serverCount > 0 else { return "" }
        var parts = [String(localized: "\(serverCount) servers")]
        let leftCount = model.leftRunning.count
        if leftCount > 0 { parts.append(String(localized: "\(leftCount) left running")) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            let stoppable = selected.filter { $0.protection == nil }
            Button { stop(stoppable, force: false) } label: { Label("Stop", systemImage: "stop.circle") }
                .disabled(stoppable.isEmpty)
                .help(selected.isEmpty || !stoppable.isEmpty ? Text("Stop") : Text(Self.refusal(selected.first?.protection ?? "")))
            Toggle(isOn: $showAll.animation(.snappy)) {
                Label("Show All Listening Processes", systemImage: showAll ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help(Text("Show All Listening Processes"))
            Button { rescans += 1; model.scanRadar() } label: {
                Label("Rescan", systemImage: "arrow.clockwise").symbolEffect(.bounce, value: rescans)
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Rescan"))
        }
    }

    // MARK: left running

    private var endedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Left running by ended sessions")
            VStack(spacing: 0) {
                ForEach(Array(endedSessions.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().padding(.leading, 31) }
                    endedRow(s).transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .card()
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
    }

    private func endedRow(_ s: EndedSession) -> some View {
        let busy = s.servers.contains { stopping.contains($0.identity) }
        let failed = s.servers.filter { failures[$0.identity] != nil }
        return HStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Theme.warning).frame(width: 7, height: 7).padding(.top, 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        AgentBadge(agent: s.agent).font(.callout.weight(.medium))
                        if let t = s.title { Text(verbatim: "“\(t)”").lineLimit(1).truncationMode(.tail) }
                        if let project = s.project {
                            if s.agent != nil || s.title != nil { Text(verbatim: "·").foregroundStyle(.tertiary) }
                            Text(verbatim: project).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.callout)
                    HStack(spacing: 12) {
                        ForEach(s.servers) { p in
                            HStack(spacing: 3) {
                                Text(verbatim: p.name).foregroundStyle(.secondary)
                                ForEach(p.uniquePorts, id: \.self) { PortLink(port: $0) }
                            }
                        }
                    }
                    .font(.caption)
                    if let first = failed.first, let why = failures[first.identity] {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                            Text(verbatim: why).foregroundStyle(.secondary).lineLimit(1).help(Text(verbatim: why))
                            Button("Force Stop") { stop(failed, force: true) }
                                .controlSize(.mini)
                                .help(Text("Ends the process immediately; unsaved state in it is lost."))
                        }
                        .font(.caption)
                        .transition(.opacity)
                    }
                }
            }
            Spacer(minLength: 12)
            Button("Keep Running") { withAnimation(.snappy) { s.servers.forEach(model.keep) } }
                .disabled(busy)
            Button { stop(s.servers, force: false) } label: {
                Text("Stop").opacity(busy ? 0 : 1).overlay { if busy { ProgressView().controlSize(.mini) } }
            }
            .disabled(busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            if let cwd = s.servers.first?.cwd { Button("Show in Finder") { model.revealInFinder(cwd) } }
        }
    }

    // MARK: table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Port", value: \.portSortKey) { p in
                HStack(spacing: 6) { ForEach(p.uniquePorts, id: \.self) { PortLink(port: $0, font: .body) } }
            }
            .width(min: 50, ideal: 56, max: 80)
            TableColumn("Process", value: \.name) { p in
                HStack(spacing: 4) {
                    Text(verbatim: p.name).lineLimit(1)
                    if let why = p.protection {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                            .help(Text(Self.refusal(why)))
                            .accessibilityLabel(Text(Self.refusal(why)))
                    }
                }
                .help(Text(verbatim: "\(p.commandLine)\nPID \(p.identity.pid)"))
            }
            .width(min: 80, ideal: 100, max: 180)
            TableColumn("Project · Session") { p in projectCell(p) }
                .width(min: 120, ideal: 160)
            TableColumn("RAM", value: \.memorySortKey) { p in Text(verbatim: p.memoryText).monospacedDigit() }
                .width(min: 50, ideal: 60, max: 80)
                .alignment(.trailing)
            TableColumn("Uptime", value: \.uptimeSortKey) { p in Text(verbatim: p.uptimeText).monospacedDigit() }
                .width(min: 54, ideal: 64, max: 90)
                .alignment(.trailing)
            TableColumn("Status") { p in statusCell(p) }
                .width(min: 100, ideal: 140, max: 260)
        }
        .animation(.snappy, value: rows.map(\.id))
        .contextMenu(forSelectionType: ProcessIdentity.self) { ids in
            let procs = rows.filter { ids.contains($0.identity) }
            if !procs.isEmpty { menu(procs) }
        } primaryAction: { ids in
            for p in rows where ids.contains(p.identity) { if let port = p.uniquePorts.first { Self.open(port) } }
        }
    }

    /// The project, and under it the agent and session that started the server (when known).
    private func projectCell(_ p: RadarProcess) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: projectName(p)).lineLimit(1).truncationMode(.middle)
            if let a = p.attribution, a.agent != nil {
                HStack(spacing: 4) {
                    AgentBadge(agent: a.agent)
                    if let t = a.sessionTitle { Text(verbatim: "“\(t)”").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(Text(attributionHelp(p)))
    }

    @ViewBuilder private func statusCell(_ p: RadarProcess) -> some View {
        if stopping.contains(p.identity) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Stopping…").foregroundStyle(.secondary)
            }
        } else if let why = failures[p.identity] {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                Text(verbatim: why).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(Text(verbatim: why))
                if p.protection == nil {
                    Button("Force Stop") { stop([p], force: true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .layoutPriority(1)
                        .help(Text("Ends the process immediately; unsaved state in it is lost."))
                }
            }
        } else {
            switch p.linkState {
            case .attached: StatusDot(text: "Live", color: Theme.ok)
            case .detached: StatusDot(text: "Live", color: Theme.ok).help(Text("Started by an earlier run of a session that is running again"))
            case .orphan:
                if model.keptProcesses.contains(p.identity) { StatusDot(text: "Kept", color: .secondary) }
                else { StatusDot(text: "Session ended", color: Theme.warning) }
            case .unknown:
                if p.processClass == .system { StatusDot(text: "System", color: .secondary) }
                else { StatusDot(text: "Unknown", color: .secondary) }
            }
        }
    }

    @ViewBuilder private func menu(_ procs: [RadarProcess]) -> some View {
        let stoppable = procs.filter { $0.protection == nil }
        let refusal = stoppable.isEmpty ? Text(Self.refusal(procs.first?.protection ?? "")) : Text(verbatim: "")
        Button("Stop") { stop(stoppable, force: false) }.disabled(stoppable.isEmpty).help(refusal)
        Button("Force Stop") { stop(stoppable, force: true) }.disabled(stoppable.isEmpty).help(refusal)
        if procs.count == 1, let p = procs.first {
            Divider()
            ForEach(p.uniquePorts, id: \.self) { port in
                let portText = String(port)
                Button("Open localhost:\(portText) in Browser") { Self.open(port) }
            }
            if let cwd = p.cwd { Button("Show in Finder") { model.revealInFinder(cwd) } }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(p.identity.pid), forType: .string)
            }
        }
        let keepable = procs.filter { $0.linkState == .orphan && !model.keptProcesses.contains($0.identity) }
        if !keepable.isEmpty {
            Divider()
            Button("Keep Running") { withAnimation(.snappy) { keepable.forEach(model.keep) } }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No dev servers running", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Servers your agents start appear here with the session that started them.")
        } actions: {
            if !showAll && !model.allListening.isEmpty {
                Button("Show All Listening Processes") { withAnimation(.snappy) { showAll = true } }
            }
        }
    }

    // MARK: actions

    /// Stops processes one after the other; each row shows progress, then leaves, or shows why it did not stop.
    private func stop(_ procs: [RadarProcess], force: Bool) {
        let targets = procs.filter { $0.protection == nil && !stopping.contains($0.identity) }
        guard !targets.isEmpty else { return }
        withAnimation(.snappy) {
            for p in targets { stopping.insert(p.identity); failures[p.identity] = nil }
        }
        Task {
            for p in targets {
                let why = await model.stopProcess(p, force: force)
                withAnimation(.snappy) {
                    stopping.remove(p.identity)
                    if why.isEmpty { stopped.insert(p.identity); selection.remove(p.identity) } else { failures[p.identity] = why }
                }
            }
        }
    }

    /// "Show" from a notification or the popover: select the process and scroll to it.
    private func show(_ target: FocusTarget?, _ proxy: ScrollViewProxy) {
        guard case .process(let id)? = target else { return }
        model.focus = nil
        if !model.servers.contains(where: { $0.identity == id }) {
            guard model.allListening.contains(where: { $0.identity == id }) else { return }
            showAll = true
        }
        selection = [id]
        DispatchQueue.main.async { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
    }

    private static func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    private func projectName(_ p: RadarProcess) -> String {
        if let root = p.attribution?.projectRoot { return (root as NSString).lastPathComponent }
        if let cwd = p.cwd, cwd != "/" { return (cwd as NSString).abbreviatingWithTildeInPath }
        return "—"
    }

    private func attributionHelp(_ p: RadarProcess) -> String {
        guard let a = p.attribution else { return String(localized: "No agent evidence for this process.") }
        switch a.method {
        case .liveAncestry: return String(localized: "Started by a running agent process.")
        case .envSession, .envAgentPid:
            let sid = a.agentSessionID ?? "?"
            return String(localized: "The process environment names agent session \(sid).")
        case .rememberedAncestry: return String(localized: "Seen under this agent session earlier.")
        case .cwd: return String(localized: "Working directory is inside the project; agent unknown.")
        case .manual: return String(localized: "Assigned by you.")
        }
    }

    /// Why Airbag won't stop a process, in the user's language (the radar names the reason in English).
    nonisolated static func refusal(_ raw: String) -> String {
        let reason: String
        switch raw {
        case "system process": reason = String(localized: "it's a system process")
        case "Airbag or its parent": reason = String(localized: "it's Airbag or the app that started it")
        case "running agent session": reason = String(localized: "it belongs to a running agent session")
        case "agent, editor or terminal": reason = String(localized: "it's an agent, editor or terminal")
        case "helper of a running agent session": reason = String(localized: "it helps a running agent session")
        case let r where r.hasPrefix("managed by Docker"): reason = String(localized: "Docker or Lima manages it; stop the container instead")
        default: reason = raw
        }
        return String(localized: "Airbag won't stop this: \(reason)")
    }
}

/// The servers one ended agent session left running.
private struct EndedSession: Identifiable {
    let id: String
    let agent: AgentKind?
    let title: String?
    let project: String?
    var servers: [RadarProcess]
}

fileprivate extension RadarProcess {
    /// Each port once (a server often listens on IPv4 and IPv6), lowest first.
    var uniquePorts: [Int] { Array(Set(listeners.map(\.port))).sorted() }
    var portSortKey: Int { uniquePorts.first ?? .max }
    var memorySortKey: Int64 { footprintBytes ?? -1 }
    var uptimeSortKey: Int64 { -startedAtMs }
}

// MARK: Guard

struct GuardScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded = Set<String>()
    @State private var filter = GuardFilter.all
    @State private var flashID: String?
    /// What became of the allowances granted for entries (read from the registry when an entry becomes "allowed").
    @State private var allowances: [String: Allowance] = [:]

    private var filtered: [GuardEntry] { model.guardEntries.filter(filter.includes) }

    private var days: [GuardDay] {
        var out: [GuardDay] = []
        for g in filtered {
            let key = RelativeTime.dayKey(ms: g.ts)
            if out.last?.id == key { out[out.count - 1].entries.append(g) }
            else { out.append(GuardDay(id: key, title: RelativeTime.day(ms: g.ts), entries: [g])) }
        }
        return out
    }

    private var allowedIDs: [String] { model.guardEntries.filter { $0.resolution == "user_allowed" }.map(\.id) }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.guardEntries.isEmpty { emptyState }
                else if filtered.isEmpty { filteredEmptyState }
                else { log }
            }
            .onChange(of: model.focus, initial: true) { _, target in show(target, proxy) }
        }
        .navigationTitle(Text("Guard"))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Picker(selection: $filter.animation(.snappy)) {
                    Text("All Commands").tag(GuardFilter.all)
                    Text("Needs Approval").tag(GuardFilter.needsApproval)
                    Text("Blocked").tag(GuardFilter.blocked)
                    Text("Ran Without Asking").tag(GuardFilter.ranWithoutAsking)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.guardEntries.isEmpty)
                .help(Text("Filter"))
            }
        }
        // Opening the log (or a new entry arriving while it is open) counts as having looked; the dots then fade out.
        .task(id: model.guardEntries.first?.id) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !model.frozen else { return }
            withAnimation(.easeOut(duration: 0.6)) { model.markGuardsReviewed() }
        }
        // Also on every agent command: using an allowance does not change the entry, only its token.
        .task(id: "\(allowedIDs.joined(separator: ","))|\(model.hookTick)") { allowances = model.allowances(allowedIDs) }
        .onAppear {
            // Preview rendering: open the entry a user is most likely to come for.
            if model.frozen, expanded.isEmpty, let g = model.guardEntries.first(where: { $0.decision == "allow_fallback" }) { expanded = [g.id] }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        let waitingCount = model.needsApproval.count
        if waitingCount > 0 { parts.append(String(localized: "\(waitingCount) waiting for approval")) }
        let checkedCount = model.commandsToday
        if checkedCount > 0 { parts.append(String(localized: "\(checkedCount) commands checked today")) }
        return parts.joined(separator: " · ")
    }

    private var log: some View {
        let waitingIDs = Set(model.needsApproval.map(\.id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days) { day in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(Array(day.entries.enumerated()), id: \.element.id) { i, g in
                                if i > 0 { Divider().padding(.leading, GuardLogRow.indent) }
                                GuardLogRow(entry: g, expanded: expanded.contains(g.id), unread: g.ts > model.guardReviewedThrough,
                                            waiting: waitingIDs.contains(g.id), allowance: allowances[g.id]) {
                                    withAnimation(.snappy) { if expanded.remove(g.id) == nil { expanded.insert(g.id) } }
                                }
                                .flash(flashID == g.id)
                                .id(g.id)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .card()
                        .padding(.bottom, 10)
                    } header: {
                        Text(verbatim: day.title)
                            .font(.headline).foregroundStyle(.secondary)
                            .padding(.top, 14).padding(.bottom, 8).padding(.horizontal, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing blocked so far", systemImage: "exclamationmark.shield")
        } description: {
            let checkedCount = model.commandsToday
            if checkedCount > 0 {
                Text("\(checkedCount) commands checked today")
            } else {
                Text("Destructive commands outside your project are blocked or need your approval. Inside the project, Airbag takes a snapshot instead.")
            }
        }
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("No commands match this filter", systemImage: "line.3.horizontal.decrease.circle")
        } actions: {
            Button("Show All") { withAnimation(.snappy) { filter = .all } }
        }
    }

    /// "Show" from a notification or the popover: scroll to the entry, open it and highlight it briefly.
    private func show(_ target: FocusTarget?, _ proxy: ScrollViewProxy) {
        guard case .guardEntry(let id)? = target else { return }
        model.focus = nil
        guard let g = model.guardEntries.first(where: { $0.id == id }) else { return }
        if !filter.includes(g) { filter = .all }
        expanded.insert(id)
        flashID = nil
        DispatchQueue.main.async {
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            flashID = id
        }
    }
}

private enum GuardFilter: Hashable {
    case all, needsApproval, blocked, ranWithoutAsking
    func includes(_ g: GuardEntry) -> Bool {
        switch self {
        case .all: return true
        case .needsApproval: return g.decision == "deny_fallback"
        case .blocked: return g.decision == "deny"
        case .ranWithoutAsking: return g.decision == "allow_fallback"
        }
    }
}

private struct GuardDay: Identifiable {
    let id: Date
    let title: String
    var entries: [GuardEntry]
}

/// One Guard entry: a single line (decision, command, where and when), opened by a click for the reason and the actions.
/// Only an agent that waits for approval gets buttons on the line itself.
private struct GuardLogRow: View {
    @EnvironmentObject var model: AppModel
    let entry: GuardEntry
    let expanded: Bool
    let unread: Bool
    /// The agent is waiting for an answer (Allow Once / Dismiss).
    let waiting: Bool
    let allowance: Allowance?
    let toggle: () -> Void
    @State private var hover = false
    @State private var copied = false
    @State private var expired = false

    /// Where the command starts: the expanded part and the row dividers line up with it.
    static let indent: CGFloat = 50

    private var style: GuardStyle { GuardStyle(entry.decision) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { line }
                .buttonStyle(.plain)
            if entry.decision == "deny_fallback" { approvalLine.padding(.leading, Self.indent).padding(.trailing, 12).padding(.bottom, 9) }
            if expanded {
                details
                    .padding(.leading, Self.indent).padding(.trailing, 14).padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(hover ? Color.primary.opacity(0.035) : .clear)
        .onHover { hover = $0 }
        .task(id: allowance) {
            expired = false
            guard case .until(let expiry)? = allowance else { return }
            let wait = expiry.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { withAnimation(.snappy) { expired = true } }
        }
    }

    private var line: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
                .opacity(unread ? 1 : 0)
                .accessibilityHidden(true)
            Image(systemName: style.symbol).foregroundStyle(style.color)
                .frame(width: 18)
                .help(Text(style.title))
                .accessibilityLabel(Text(style.title))
            CommandCaptionLine {
                Text(verbatim: entry.command)
                    .font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                caption
            }
            .padding(.leading, 2)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 14)
                .accessibilityHidden(true)
        }
        .padding(.leading, 11).padding(.trailing, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(expanded ? [.isButton, .isSelected] : .isButton)
    }

    /// project · agent · “session” · 2 min ago; the session title gives way first when space is short.
    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            let project = entry.projectRoot.map { ($0 as NSString).lastPathComponent }
            if let project { Text(verbatim: project).lineLimit(1).layoutPriority(2) }
            if entry.agent != nil {
                if project != nil { dot }
                AgentBadge(agent: entry.agent).layoutPriority(3)
            }
            if let t = entry.sessionTitle {
                if project != nil || entry.agent != nil { dot }
                Text(verbatim: "“\(t)”").lineLimit(1).truncationMode(.tail)
            }
            if project != nil || entry.agent != nil || entry.sessionTitle != nil { dot }
            Text(verbatim: RelativeTime.age(ms: entry.ts)).fixedSize().layoutPriority(4)
                .help(Text(RelativeTime.precise(ms: entry.ts)))
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var dot: some View { Text(verbatim: "·").foregroundStyle(.tertiary).layoutPriority(3) }

    /// An agent waiting for approval, or what became of the approval.
    @ViewBuilder private var approvalLine: some View {
        if waiting {
            HStack(spacing: 8) {
                Button("Allow Once") { withAnimation(.snappy) { model.allowOnce(entry) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!entry.canAllowOnce)
                    .help(entry.canAllowOnce ? Text(verbatim: "")
                                             : Text("Airbag doesn't know which session asked. Run the command yourself if you want it."))
                Button("Dismiss") { withAnimation(.snappy) { model.dismiss(entry) } }
            }
            .controlSize(.small)
            .transition(.opacity)
        } else if let resolution = entry.resolution {
            Group {
                switch resolution {
                case "token_used": used
                case "user_allowed":
                    switch allowance {
                    case .used?: used
                    case .until(let expiry)? where !expired && expiry > Date():
                        Label { Text("Allowed once · expires in \(Text(timerInterval: min(Date(), expiry)...expiry, countsDown: true))") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                            .monospacedDigit()
                    case .until?:
                        Label { Text("Allowed once · expired") } icon: { Image(systemName: "clock").foregroundStyle(.secondary) }
                    case nil:
                        Label { Text("Allowed once") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                    }
                case "user_denied":
                    Label { Text("Dismissed") } icon: { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                default: EmptyView()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .transition(.opacity)
        }
    }

    private var used: some View {
        Label { Text("Allowed once — used") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.command.count > 70 || entry.command.contains("\n") {
                CommandText(command: entry.command, lines: 8, font: .callout)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Self.readable(entry.reason))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(style.title)
                    if let category = Self.category(entry.ruleID) {
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(verbatim: category)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if entry.decision == "allow_fallback" {
                if entry.snapshotID == nil {
                    Callout(.info, "No snapshot was taken before this command.").font(.caption)
                } else {
                    Callout(.info, "Restoring puts files back. Pushes and cloud changes can't be undone by Airbag.").font(.caption)
                }
            }
            HStack(spacing: 8) {
                if let snapshot = entry.snapshotID, let root = entry.projectRoot {
                    if entry.decision == "allow_fallback" {
                        Button {
                            model.requestRestore(root: root, snapshot: snapshot, time: entry.ts, intent: .restore, command: entry.command)
                        } label: { Label("Restore Project to Before This…", systemImage: "arrow.uturn.backward") }
                    }
                    Button { model.reveal(.snapshot(root: root, id: snapshot)) } label: { Label("Show in Timeline", systemImage: "clock") }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.command, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label("Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .controlSize(.small)
            HStack(alignment: .firstTextBaseline) {
                Toggle("Check commands like this", isOn: Binding(get: { !model.disabledRules.contains(entry.ruleID) },
                                                                set: { model.setRule(entry.ruleID, enabled: $0) }))
                    .toggleStyle(.checkbox)
                Spacer(minLength: 12)
                Text("Rule ID: \(entry.ruleID)").foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    /// The rule's reason is written for the agent ("it deletes …"); people read it as a sentence.
    static func readable(_ reason: String) -> String {
        var s = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("it ") { s = String(s.dropFirst(3)) }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// What kind of harm the rule is about, from its id ("fs.rm.outside" → files outside the project).
    static func category(_ ruleID: String) -> String? {
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
}

/// A command and its caption on one line, text baselines aligned. The command keeps its full width when both fit;
/// otherwise it gets at least 55% of the line and the caption (trailing) gives way.
private struct CommandCaptionLine: Layout {
    var spacing: CGFloat = 14

    private func widths(_ total: CGFloat, _ subviews: Subviews) -> (CGFloat, CGFloat) {
        let available = max(0, total - spacing)
        let command = subviews[0].sizeThatFits(.unspecified).width
        let caption = subviews[1].sizeThatFits(.unspecified).width
        if command + caption <= available { return (command, caption) }
        let first = min(command, max(available * 0.55, available - caption))
        return (first, max(0, available - first))
    }

    private func metrics(_ width: CGFloat, _ subviews: Subviews) -> (ProposedViewSize, ProposedViewSize, ViewDimensions, ViewDimensions, CGFloat) {
        let (a, b) = widths(width, subviews)
        let pa = ProposedViewSize(width: a, height: nil), pb = ProposedViewSize(width: b, height: nil)
        let da = subviews[0].dimensions(in: pa), db = subviews[1].dimensions(in: pb)
        return (pa, pb, da, db, max(da[.firstTextBaseline], db[.firstTextBaseline]))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let ideal = subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width
        let width = proposal.width.map { $0.isFinite ? $0 : ideal } ?? ideal
        let (_, _, da, db, base) = metrics(width, subviews)
        return CGSize(width: width, height: max(base + da.height - da[.firstTextBaseline], base + db.height - db[.firstTextBaseline]))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (pa, pb, da, db, base) = metrics(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + base - da[.firstTextBaseline]), anchor: .topLeading, proposal: pa)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + base - db[.firstTextBaseline]), anchor: .topTrailing, proposal: pb)
    }
}

/// A one-shot allowance granted in Airbag: still open until a moment, or used by the agent.
private enum Allowance: Equatable {
    case until(Date)
    case used
}

fileprivate extension AppModel {
    /// What became of the allowances granted for these Guard entries. The entry keeps the resolution "user_allowed"
    /// after the agent used it, so the token says. An allowance replaced by a newer one for the same command is unknown.
    func allowances(_ ids: [String]) -> [String: Allowance] {
        guard !ids.isEmpty, let db = registry?.db else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let rows = (try? db.all("SELECT g.id, t.expires_at, t.used_at FROM guard_log g JOIN allow_tokens t ON t.id = g.token_id WHERE g.id IN (\(marks))",
                                ids) { r -> (String, Allowance) in
            (r.text(0), r.intOrNil(2) != nil ? .used : .until(Date(timeIntervalSince1970: Double(r.int(1)) / 1000)))
        }) ?? []
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }
}
