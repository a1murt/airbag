import AirbagCore
import AppKit
import SwiftUI

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
        model.requestRestore(root: root, snapshot: target.snapshot.id, time: target.snapshot.createdAt, paths: paths,
                             intent: target.id == entry.id ? .restore : .undo, command: titleCommand?.command, title: title)
    }
}
