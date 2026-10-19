import AirbagCore
import AppKit
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedTab }, set: { if let t = $0 { model.selectedTab = t; model.scheduleRadar() } })) {
                ForEach(MainTab.allCases) { tab in
                    // `.tag` must be the outermost modifier: after `.badge` the list no longer sees it, no row is
                    // selectable and clicks in the sidebar do nothing.
                    Label(String(localized: tab.title), systemImage: tab.symbol)
                        .badge(tab == .guardLog ? model.attentionGuards.count : (tab == .radar ? model.orphans.count : 0))
                        .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.selectedTab {
            case .timeline: TimelineScreen(expandFirst: model.frozen)
            case .radar: RadarScreen()
            case .guardLog: GuardScreen()
            case .settings: SettingsScreen()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { model.mainWindowVisible = true; model.refreshAll() }
        .onDisappear { model.mainWindowVisible = false }
    }
}

struct TimelineScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var entries: [TimelineEntry] = []
    @State private var expanded: String?
    /// Preview rendering: expand the first card and select its first file.
    var expandFirst = false
    @State private var loading = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Project", selection: Binding(get: { model.selectedRoot ?? "" }, set: { model.selectedRoot = $0 })) {
                    ForEach(model.projects) { p in (p.isWorktree ? Text("\(p.name) (worktree)") : Text(verbatim: p.name)).tag(p.root) }
                }
                .frame(maxWidth: 320)
                TextField("Search commands and files", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                if let root = model.selectedRoot {
                    Button { model.snapshotNow(root) } label: { Label("Snapshot now", systemImage: "camera") }
                    Button { model.revealInFinder(root) } label: { Image(systemName: "folder") }.help(Text("Reveal in Finder"))
                }
            }
            .padding(12)
            Divider()
            if model.projects.isEmpty {
                EmptyState(symbol: "shield", title: "Nothing protected yet",
                           message: "Install hooks for your agents in Settings, or add a project folder. Airbag snapshots it before every agent command.")
            } else if entries.isEmpty && !loading {
                EmptyState(symbol: "clock", title: "No snapshots yet", message: "The first snapshot appears when an agent runs a command or a file changes.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, e in
                            TimelineCard(root: model.selectedRoot ?? "", entry: e, previous: index + 1 < filtered.count ? filtered[index + 1] : nil,
                                         expanded: expanded == e.id, selectFirstFile: expandFirst) {
                                expanded = expanded == e.id ? nil : e.id
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle(Text("Timeline"))
        .task(id: "\(model.selectedRoot ?? "")|\(model.projects.first(where: { $0.root == model.selectedRoot })?.lastSnapshotAt ?? 0)") { await load() }
    }

    var filtered: [TimelineEntry] {
        guard !query.isEmpty else { return entries }
        let q = query.lowercased()
        return entries.filter { e in (e.snapshot.label ?? "").lowercased().contains(q) || e.commands.contains { $0.command.lowercased().contains(q) } }
    }

    func load() async {
        guard let root = model.selectedRoot else { entries = []; return }
        loading = true
        entries = await model.timeline(root: root)
        loading = false
        if expandFirst { expanded = entries.first(where: { $0.snapshot.changedCount > 0 && $0.snapshot.trigger == .postCommand })?.id }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct TimelineCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let root: String
    let entry: TimelineEntry
    /// The snapshot before this one: "undo these changes" restores to it.
    let previous: TimelineEntry?
    let expanded: Bool
    var selectFirstFile = false
    let toggle: () -> Void
    @State private var changes: [FileChange] = []
    @State private var selectedFile: String?
    @State private var diff: TextDiff?

    /// The command that names this moment (and whose agent and session the card shows).
    var titleCommand: TimelineCommand? {
        entry.snapshot.trigger == .postCommand
            ? entry.commands.last(where: { $0.kind == "post_shell" }) ?? entry.commands.last
            : entry.commands.last(where: { $0.kind == "pre_shell" }) ?? entry.commands.last
    }

    var title: String {
        // Several commands can point at one snapshot (nothing changed between them): the newest one names the moment.
        if let c = entry.commands.last(where: { $0.kind == "pre_shell" }), entry.snapshot.trigger != .postCommand {
            return String(localized: "Before `\(String(c.command.prefix(80)))`")
        }
        if let c = entry.commands.last(where: { $0.kind == "post_shell" }) { return String(localized: "After `\(String(c.command.prefix(80)))`") }
        if let label = entry.snapshot.label { return label }
        switch entry.snapshot.trigger {
        case .fsevents: return String(localized: "File changes")
        case .manual: return String(localized: "Manual snapshot")
        case .initial: return String(localized: "First snapshot")
        case .preRestore: return String(localized: "Before restore")
        case .postRestore: return String(localized: "After restore")
        case .preCommand: return String(localized: "Before a command")
        case .postCommand: return String(localized: "After a command")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon).foregroundStyle(iconColor).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: RelativeTime.clock(ms: entry.snapshot.createdAt)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text(verbatim: title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            if let c = titleCommand {
                                AgentBadge(agent: c.agent)
                                if let t = c.sessionTitle { Text(verbatim: "“\(t)”").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            if entry.commands.count > 1 { Text("+\(entry.commands.count - 1) more commands").font(.caption).foregroundStyle(.tertiary) }
                            if !entry.snapshot.complete { Pill(text: "partial", color: Theme.warning) }
                        }
                    }
                    Spacer()
                    Text("\(entry.snapshot.changedCount) files").font(.caption).foregroundStyle(.secondary)
                    Button { model.setPinned(root: root, snapshot: entry.snapshot.id, !entry.snapshot.pinned) } label: {
                        Image(systemName: entry.snapshot.pinned ? "pin.fill" : "pin").foregroundStyle(entry.snapshot.pinned ? Theme.accent : Color.secondary)
                    }
                    .buttonStyle(.plain).help(Text("Keep this snapshot forever"))
                    .accessibilityLabel(Text(entry.snapshot.pinned ? "Unpin snapshot" : "Pin snapshot"))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider()
                if changes.isEmpty {
                    Text("No file changes recorded in this snapshot.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(changes.prefix(300), id: \.path) { c in
                        Button { selectedFile = c.path } label: {
                            ChangeRow(change: c).padding(.vertical, 1).background(selectedFile == c.path ? Theme.accent.opacity(0.12) : .clear)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let prev = previous { Button("Restore the version from before this change") { openRestore(.paths([c.path]), to: prev) } }
                            if c.status != .deleted { Button("Restore this version") { openRestore(.paths([c.path]), to: entry) } }
                            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.path, forType: .string) }
                        }
                    }
                    if changes.count > 300 { Text("\(changes.count - 300) more…").font(.caption).foregroundStyle(.secondary) }
                }
                if let diff, let file = selectedFile {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(verbatim: file).font(Theme.monoSmall.weight(.semibold))
                            Spacer()
                            if let prev = previous { Button("Restore previous version") { openRestore(.paths([file]), to: prev) }.controlSize(.small) }
                            if changes.first(where: { $0.path == file })?.status != .deleted {
                                Button("Restore this version") { openRestore(.paths([file]), to: entry) }.controlSize(.small)
                            }
                        }
                        ScrollView([.horizontal, .vertical]) { DiffView(diff: diff).padding(6) }
                            .frame(maxHeight: 320)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !entry.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.commands.reversed()) { c in
                            HStack(spacing: 6) {
                                Text(verbatim: RelativeTime.clock(ms: c.ts)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Text(c.kind == "post_shell" ? "after" : "before").font(.caption2).foregroundStyle(.tertiary)
                                Text(verbatim: c.command).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                }
                HStack {
                    if let prev = previous, !changes.isEmpty {
                        Button { openRestore(.paths(changes.map(\.path)), to: prev) } label: { Label("Undo these changes…", systemImage: "arrow.uturn.backward") }
                            .help(Text("Put the listed files back as they were before this snapshot"))
                    }
                    Button { openRestore(.root, to: entry) } label: { Label("Restore project to this moment…", systemImage: "clock.arrow.circlepath") }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .task(id: expanded) {
            if expanded {
                changes = await model.changes(root: root, snapshot: entry.snapshot.id)
                if selectFirstFile, selectedFile == nil { selectedFile = changes.first(where: { $0.status == .modified })?.path ?? changes.first?.path }
            }
        }
        .task(id: selectedFile) {
            if let f = selectedFile { diff = await model.fileDiff(root: root, snapshot: entry.snapshot.id, path: f) }
        }
    }

    var icon: String {
        switch entry.snapshot.trigger {
        case .preCommand: return "terminal"
        case .postCommand: return "checkmark.circle"
        case .fsevents: return "doc.badge.ellipsis"
        case .manual: return "camera"
        case .initial: return "shield"
        case .preRestore, .postRestore: return "arrow.uturn.backward.circle"
        }
    }
    var iconColor: Color { entry.commands.contains { $0.decision == "deny" } ? Theme.danger : .secondary }

    /// The shared top folder when every change is under one directory (e.g. `src/legacy` after `rm -rf src/legacy`).
    var commonFolder: String? {
        let dirs = changes.map { ($0.path as NSString).deletingLastPathComponent }
        guard let first = dirs.first, !first.isEmpty else { return nil }
        var common = first.split(separator: "/").map(String.init)
        for d in dirs.dropFirst() {
            let comps = d.split(separator: "/").map(String.init)
            common = Array(zip(common, comps).prefix { $0 == $1 }.map(\.0))
            if common.isEmpty { return nil }
        }
        return common.joined(separator: "/")
    }

    func openRestore(_ scope: RestoreScope, to target: TimelineEntry) {
        let paths: [String]
        if case .paths(let p) = scope { paths = p } else { paths = [] }
        let label = target.id == entry.id ? title : (TimelineCard(root: root, entry: target, previous: nil, expanded: false, toggle: {}).title)
        model.restoreRequest = RestoreRequest(root: root, snapshotID: target.snapshot.id, snapshotLabel: label,
                                              snapshotTime: target.snapshot.createdAt, paths: paths,
                                              liveAgents: model.projects.first { $0.root == root }?.liveSessions ?? 0)
        openWindow(id: "restore")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The restore confirmation is a separate window rather than a sheet (sheets in agent-style apps lost input on 14.0).
struct RestoreRequest: Equatable, Identifiable {
    var id: String { "\(root)|\(snapshotID)|\(paths.joined(separator: ","))|\(created)" }
    let created = Date()
    let root: String
    let snapshotID: String
    let snapshotLabel: String
    let snapshotTime: Int64
    let paths: [String]
    let liveAgents: Int
    var scope: RestoreScope { paths.isEmpty ? .root : .paths(paths) }
}

struct RestoreWindow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var request: RestoreRequest? { model.restoreRequest }
    @State private var plan: RestorePlan?
    @State private var running = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = request {
                Text(title(r)).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: r.snapshotLabel).font(Theme.mono).foregroundStyle(.secondary).lineLimit(2)
                if let plan {
                    if !plan.complete {
                    Label("This snapshot is partial (taken under a time limit): only the files it captured are restored, and nothing is moved aside.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                if plan.isEmpty {
                        Label("Nothing to do: these files already match the snapshot.", systemImage: "checkmark.circle").foregroundStyle(Theme.ok)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(plan.write.count) files will be restored").font(.callout.weight(.medium))
                            if !plan.moveAside.isEmpty {
                                Text("\(plan.moveAside.count) files created later will be moved into Airbag's store (not deleted)").font(.callout)
                            }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(plan.write.prefix(200), id: \.self) { Text(verbatim: "↺ " + $0).font(Theme.monoSmall) }
                                    ForEach(plan.moveAside.prefix(100), id: \.self) { Text(verbatim: "→ " + $0).font(Theme.monoSmall).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Label("Airbag takes a snapshot of the current state first. You can undo this restore from the Timeline.", systemImage: "camera")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Folders Airbag does not snapshot (node_modules, build output, files over 100 MB) are left as they are.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if r.liveAgents > 0 {
                    Label("An agent session is still running here and may overwrite restored files. Pause it first if you can.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                if let result { Text(result).font(.callout).foregroundStyle(failed ? Theme.danger : Theme.ok).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button(result == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    if result == nil {
                        Button("Restore") { Task { await run(r) } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(running || plan == nil || plan?.isEmpty == true)
                    }
                }
            } else {
                Text("Nothing to restore.")
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: request?.id) {
            // A new request (the window is reused) starts from a clean state.
            plan = nil; result = nil; failed = false; running = false
            if let r = request { plan = await model.planRestore(root: r.root, snapshot: r.snapshotID, scope: r.scope) }
        }
    }

    func title(_ r: RestoreRequest) -> String {
        let time = RelativeTime.clock(ms: r.snapshotTime)
        let name = (r.root as NSString).lastPathComponent
        if r.paths.isEmpty { return String(localized: "Restore \(name) to \(time)?") }
        if r.paths.count == 1 { return String(localized: "Restore \(r.paths[0]) to \(time)?") }
        return String(localized: "Restore \(r.paths.count) items to \(time)?")
    }

    func run(_ r: RestoreRequest) async {
        running = true
        switch await model.restore(root: r.root, snapshot: r.snapshotID, scope: r.scope) {
        case .success(let rep):
            var s = String(localized: "Restored \(rep.restored.count) files.")
            if !rep.movedAside.isEmpty { s += " " + String(localized: "\(rep.movedAside.count) moved aside.") }
            if !rep.conflicts.isEmpty { s += " " + String(localized: "\(rep.conflicts.count) skipped because they changed during the restore.") }
            if !rep.failed.isEmpty { s += " " + String(localized: "\(rep.failed.count) failed."); failed = true }
            result = s
        case .failure(let e):
            result = model.describe(e)
            failed = true
        }
        running = false
    }
}
