import AirbagCore
import AppKit
import SwiftUI

/// One line of the Timeline. It is command-centric: a command with what it changed (the snapshot before it and the one
/// after it are one row), files that changed between commands, or a moment of its own (first snapshot, manual, restore).
struct TimelineRow: Identifiable, Equatable {
    enum Kind: Equatable { case command, fileChanges, moment }
    let id: String
    let kind: Kind
    /// When it happened; a command counts from when it finished.
    let time: Int64
    /// The command the row is named after; for file changes, the command that ran right after them.
    let command: TimelineCommand?
    /// The Guard decision on the command, when it is one worth showing (blocked, asked, ran without asking…).
    let decision: String?
    /// The snapshot that holds the row's changes; Undo puts them back. Nil when nothing changed.
    let effect: SnapshotInfo?
    /// What "Restore Project to This Moment…" brings back (for a command: the state right before it) and what Pin keeps.
    let moment: SnapshotInfo?
    let trigger: SnapshotTrigger
    /// A command that finished on the snapshot it started on: it changed no files.
    var unchanged = false

    /// Undo means "put back what this changed": not for the first snapshot (nothing before it) or the snapshot taken
    /// before a restore (its changes are edits made before the restore, not the restore).
    var canUndo: Bool { (effect?.changedCount ?? 0) > 0 && trigger != .preRestore && trigger != .initial }
    var expandable: Bool {
        (effect != nil && !(kind == .moment && trigger == .initial)) || (kind == .command && command.map { Self.isLong($0.command) } == true)
    }
    /// A command that changed nothing: shown quietly.
    var quiet: Bool { kind == .command && effect == nil }

    var title: String {
        switch kind {
        case .command: return command?.command ?? String(localized: "After a command")
        case .fileChanges: return String(localized: "File changes")
        case .moment:
            switch trigger {
            case .initial: return String(localized: "First snapshot")
            case .manual: return String(localized: "Manual snapshot")
            case .preRestore: return String(localized: "Before restore")
            case .postRestore: return String(localized: "After restore")
            case .preCommand: return String(localized: "Before a command")
            case .postCommand: return String(localized: "After a command")
            case .fsevents: return String(localized: "File changes")
            }
        }
    }

    static func isLong(_ command: String) -> Bool { command.count > 80 || command.contains("\n") }
    static func oneLine(_ command: String) -> String { command.split(whereSeparator: \.isNewline).joined(separator: " ") }

    /// Decisions the Timeline names next to a command (plain allows say nothing).
    static let notable: Set<String> = ["deny", "deny_fallback", "ask", "allow_once", "allow_fallback"]

    /// Rows from the store's snapshots (newest first, each with the commands that point at it), newest first.
    ///
    /// A command's start points at the snapshot taken before it (or the latest one when nothing changed) and its finish
    /// at the after-command snapshot it created (or again the latest one). Start and finish are paired per session and
    /// command text; the after-command snapshot belongs to the first finish pointing at it.
    static func build(_ entries: [TimelineEntry]) -> [TimelineRow] {
        var events: [(command: TimelineCommand, snapshot: SnapshotInfo)] = []
        for e in entries { for c in e.commands { events.append((c, e.snapshot)) } }
        events.sort { $0.command.ts < $1.command.ts }
        struct Run { var start: (command: TimelineCommand, snapshot: SnapshotInfo)?; var finish: (command: TimelineCommand, snapshot: SnapshotInfo)? }
        var runs: [Run] = []
        var open: [String: [Int]] = [:]
        var creator: [String: String] = [:]
        for ev in events {
            let key = (ev.command.agentSessionID ?? "") + "\u{1}" + ev.command.command
            switch ev.command.kind {
            case "pre_shell":
                runs.append(Run(start: ev))
                open[key, default: []].append(runs.count - 1)
            case "post_shell", "shell_failed":
                if ev.snapshot.trigger == .postCommand, creator[ev.snapshot.id] == nil { creator[ev.snapshot.id] = ev.command.id }
                if var waiting = open[key], !waiting.isEmpty {
                    runs[waiting.removeFirst()].finish = ev
                    open[key] = waiting
                } else {
                    runs.append(Run(finish: ev))
                }
            default: break
            }
        }
        let index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var owned = Set<String>()
        var rows: [TimelineRow] = []
        for run in runs {
            guard let c = run.start?.command ?? run.finish?.command else { continue }
            var effect: SnapshotInfo?
            if let f = run.finish, creator[f.snapshot.id] == f.command.id, f.snapshot.id != run.start?.snapshot.id {
                effect = f.snapshot
                owned.insert(f.snapshot.id)
            }
            var moment = run.start?.snapshot
            if moment == nil, let e = effect, let i = index[e.id], i + 1 < entries.count { moment = entries[i + 1].snapshot }
            if moment == nil, effect == nil { moment = run.finish?.snapshot }
            let unchanged = run.finish != nil && run.finish?.snapshot.id == run.start?.snapshot.id
            rows.append(TimelineRow(id: "c" + c.id, kind: .command, time: run.finish?.command.ts ?? c.ts, command: c,
                                    decision: run.start?.command.decision.flatMap { notable.contains($0) ? $0 : nil },
                                    effect: effect, moment: moment, trigger: .postCommand, unchanged: unchanged))
        }
        for e in entries where !owned.contains(e.id) {
            let s = e.snapshot
            let before = e.commands.first { $0.kind == "pre_shell" }
            switch s.trigger {
            case .preCommand where s.changedCount == 0:
                continue // nothing of its own: the command row already restores to it
            case .preCommand, .fsevents:
                let time = s.trigger == .preCommand ? min(s.createdAt, before?.ts ?? s.createdAt) : s.createdAt
                rows.append(TimelineRow(id: "s" + s.id, kind: .fileChanges, time: time, command: s.trigger == .preCommand ? before : nil,
                                        decision: nil, effect: s, moment: s, trigger: s.trigger))
            case .initial:
                rows.append(TimelineRow(id: "s" + s.id, kind: .moment, time: min(s.createdAt, before?.ts ?? s.createdAt), command: before,
                                        decision: nil, effect: nil, moment: s, trigger: s.trigger))
            case .manual, .postCommand, .preRestore, .postRestore:
                rows.append(TimelineRow(id: "s" + s.id, kind: .moment, time: s.createdAt, command: nil, decision: nil,
                                        effect: s.changedCount > 0 ? s : nil, moment: s, trigger: s.trigger))
            }
        }
        return rows.sorted { a, b in a.time != b.time ? a.time > b.time : (a.kind == .command && b.kind != .command) }
    }

    /// The shared folder when every change is under one directory (e.g. `src/legacy` after `rm -rf src/legacy`).
    static func commonFolder(_ changes: [FileChange]) -> String? {
        let dirs = changes.map { ($0.path as NSString).deletingLastPathComponent }
        guard let first = dirs.first, !first.isEmpty else { return nil }
        var common = first.split(separator: "/").map(String.init)
        for d in dirs.dropFirst() {
            common = Array(zip(common, d.split(separator: "/").map(String.init)).prefix { $0 == $1 }.map(\.0))
            if common.isEmpty { return nil }
        }
        return common.joined(separator: "/")
    }

    /// Large change lists by folder: the level right below the shared folder, plus the files directly in the project.
    static func groups(_ changes: [FileChange]) -> (folders: [(String, [FileChange])], loose: [FileChange]) {
        let prefix = commonFolder(changes) ?? ""
        var order: [String] = []
        var byFolder: [String: [FileChange]] = [:]
        var loose: [FileChange] = []
        for c in changes {
            let rest = prefix.isEmpty ? c.path : String(c.path.dropFirst(prefix.count + 1))
            let parts = rest.split(separator: "/", maxSplits: 1)
            let folder: String
            if parts.count > 1 { folder = prefix.isEmpty ? String(parts[0]) : prefix + "/" + parts[0] }
            else if !prefix.isEmpty { folder = prefix }
            else { loose.append(c); continue }
            if byFolder[folder] == nil { order.append(folder) }
            byFolder[folder, default: []].append(c)
        }
        return (order.map { ($0, byFolder[$0] ?? []) }, loose)
    }
}

/// File lists already loaded, so rows that scroll back in or reappear after a search show their counts at once.
final class ChangeCache {
    var map: [String: [FileChange]] = [:]
}

struct TimelineScreen: View {
    @EnvironmentObject var model: AppModel
    /// Preview rendering: command rows that changed files start expanded, edits with their diff.
    var preview = false
    @State private var entries: [TimelineEntry] = []
    @State private var rows: [TimelineRow] = []
    @State private var loaded = false
    /// Newer entries waiting behind the "new" capsule while the user reads (a row open or the list scrolled down).
    @State private var held: [TimelineEntry]?
    @State private var heldCount = 0
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var pathHits: Set<String> = []
    /// The first search match: it opens with the matching file selected.
    @State private var autoRow: String?
    @State private var scrolledAway = false
    @State private var flashID: String?
    @State private var spaceTick = 0
    @State private var pinOverrides: [String: Bool] = [:]
    @State private var cache = ChangeCache()
    @FocusState private var listFocused: Bool

    var root: String? { model.selectedRoot }
    var project: ProjectRow? { model.projects.first { $0.root == model.selectedRoot } }
    var missing: Bool { project.map { !$0.rootExists } ?? false }

    var visibleRows: [TimelineRow] {
        guard !activeQuery.isEmpty else { return rows }
        let q = activeQuery.lowercased()
        return rows.filter { r in
            if r.kind == .command, let c = r.command, c.command.lowercased().contains(q) { return true }
            if let e = r.effect, pathHits.contains(e.id) { return true }
            if r.kind == .moment, let m = r.moment, pathHits.contains(m.id) { return true }
            return false
        }
    }

    struct Day: Identifiable {
        let id: Date
        let title: String
        var rows: [TimelineRow]
    }

    var days: [Day] {
        var out: [Day] = []
        for r in visibleRows {
            let key = RelativeTime.dayKey(ms: r.time)
            if out.last?.id == key { out[out.count - 1].rows.append(r) } else { out.append(Day(id: key, title: RelativeTime.day(ms: r.time), rows: [r])) }
        }
        return out
    }

    var titleText: Text {
        if let project { return Text(verbatim: project.name) }
        if let root { return Text(verbatim: (root as NSString).lastPathComponent) }
        return Text("Timeline")
    }

    var body: some View {
        content
            .navigationTitle(titleText)
            .navigationSubtitle(Text(verbatim: root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let root {
                        SnapshotToolbarButton(root: root).disabled(missing)
                        Button { model.revealInFinder(root) } label: { Label("Show in Finder", systemImage: "folder") }
                            .help(Text("Show in Finder"))
                            .disabled(missing)
                    }
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search commands and files"))
            .task(id: "\(root ?? "")|\(project?.lastSnapshotAt ?? 0)|\(model.hookTick)") { await load() }
            .task(id: query) { await runSearch() }
    }

    @ViewBuilder var content: some View {
        if let root {
            VStack(spacing: 0) {
                if missing, let project { missingBanner(project) }
                if !loaded {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    emptyState(root)
                } else if visibleRows.isEmpty {
                    ContentUnavailableView.search(text: activeQuery)
                } else {
                    list(root)
                }
            }
        } else {
            noProjects
        }
    }

    // MARK: states

    var noProjects: some View {
        let connected = model.hookStatuses.contains { $0.installed }
        return ContentUnavailableView {
            Label("Nothing protected yet", systemImage: "shield")
        } description: {
            Text("Airbag protects a project as soon as a connected agent works in it. You can also add one yourself.")
        } actions: {
            if connected {
                Button("Add Project…") { NotificationCenter.default.post(name: .airbagAddProject, object: nil) }.buttonStyle(.borderedProminent)
                Button("Connect Agents…") { model.openSettings(tab: "agents") }
            } else {
                Button("Connect Agents…") { model.openSettings(tab: "agents") }.buttonStyle(.borderedProminent)
                Button("Add Project…") { NotificationCenter.default.post(name: .airbagAddProject, object: nil) }
            }
        }
    }

    @ViewBuilder func emptyState(_ root: String) -> some View {
        if model.snapshottingRoots.contains(root) {
            ContentUnavailableView {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Taking the first snapshot…").font(.title2.weight(.semibold))
                }
            } description: {
                Text("First snapshots are being taken in the background; large projects can take a minute.")
            }
        } else {
            ContentUnavailableView {
                Label("No snapshots yet", systemImage: "clock")
            } description: {
                Text("Ask your agent to run any command — it will appear here.")
            } actions: {
                Button("Take Snapshot") { model.snapshotNow(root) }.disabled(missing)
            }
        }
    }

    func missingBanner(_ p: ProjectRow) -> some View {
        let newest = (held ?? entries).first { $0.snapshot.complete }?.snapshot
        return HStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark").font(.title2).foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.name) is missing from disk").font(.headline)
                if let newest {
                    let ageText = RelativeTime.age(ms: newest.createdAt)
                    Text("Bring it back from the snapshot taken \(ageText).").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Bring Back…") {
                guard let newest else { return }
                model.requestRestore(root: p.root, snapshot: newest.id, time: newest.createdAt, paths: [], intent: .restore)
            }
            .buttonStyle(.borderedProminent)
            .disabled(newest == nil)
        }
        .padding(12)
        .card()
        .padding(.horizontal, 16).padding(.top, 12)
    }

    // MARK: list

    func list(_ root: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.rows) { row in
                                TimelineRowView(root: root, row: row, expanded: expanded.contains(row.id), selected: selection == row.id,
                                                listFocused: listFocused, pinned: pinned(row), flash: flashID == row.id,
                                                highlight: activeQuery.isEmpty ? nil : activeQuery, autoSelectFile: autoRow == row.id,
                                                previewDiff: preview, spaceTick: spaceTick, isSpaceTarget: selection == row.id, cache: cache,
                                                onSelect: { selection = row.id; listFocused = true },
                                                onToggle: { toggle(row) },
                                                onPin: { pin(row, $0) })
                                    .padding(.horizontal, 16)
                                    .id(row.id)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        } header: {
                            Text(verbatim: day.title)
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
                                // A bar only once rows scroll under the pinned header; at the top it sits on the window.
                                .background(scrolledAway ? AnyShapeStyle(.bar) : AnyShapeStyle(Color.clear))
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .padding(.bottom, 16)
                .background(alignment: .top) {
                    // Scrolled away from the newest rows: new ones wait behind the capsule instead of pushing the list.
                    GeometryReader { g in
                        Color.clear.onChange(of: g.frame(in: .named("timeline")).minY < -24) { _, away in scrolledAway = away }
                    }
                }
            }
            .coordinateSpace(name: "timeline")
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space]) { handleKey($0, proxy) }
            .overlay(alignment: .top) {
                if heldCount > 0 {
                    Button { showHeld(proxy) } label: {
                        Label("\(heldCount) new", systemImage: "arrow.up").font(.callout.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.cardStroke))
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: model.focus, initial: true) { applyFocus(proxy) }
            .onChange(of: rows) { applyFocus(proxy) }
        }
    }

    func toggle(_ row: TimelineRow) {
        guard row.expandable else { return }
        withAnimation(.snappy) {
            if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
        }
    }

    func pinned(_ row: TimelineRow) -> Bool {
        guard let m = row.moment else { return false }
        return pinOverrides[m.id] ?? m.pinned
    }

    func pin(_ row: TimelineRow, _ on: Bool) {
        guard let root, let m = row.moment else { return }
        pinOverrides[m.id] = on
        model.setPinned(root: root, snapshot: m.id, on)
    }

    func handleKey(_ press: KeyPress, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let list = visibleRows
        guard !list.isEmpty else { return .ignored }
        let index = selection.flatMap { s in list.firstIndex { $0.id == s } }
        let current = index.map { list[$0] }
        switch press.key {
        case .downArrow, .upArrow:
            let next = press.key == .downArrow ? index.map { min($0 + 1, list.count - 1) } ?? 0 : index.map { max($0 - 1, 0) } ?? 0
            selection = list[next].id
            withAnimation(.snappy) { proxy.scrollTo(list[next].id) }
        case .rightArrow:
            guard let current, current.expandable else { return .ignored }
            withAnimation(.snappy) { _ = expanded.insert(current.id) }
        case .return:
            guard let current else { return .ignored }
            toggle(current)
        case .leftArrow:
            guard let current else { return .ignored }
            withAnimation(.snappy) { _ = expanded.remove(current.id) }
        case .space:
            guard let current, current.effect != nil, current.expandable else { return .ignored }
            if !expanded.contains(current.id) { withAnimation(.snappy) { _ = expanded.insert(current.id) } }
            spaceTick += 1
        default:
            return .ignored
        }
        return .handled
    }

    // MARK: loading

    func load() async {
        guard let root = model.selectedRoot else { return }
        let new = await model.timeline(root: root)
        // A newer load is on its way (another command ran meanwhile): only the latest result is shown.
        guard !Task.isCancelled, root == model.selectedRoot else { return }
        let newRows = TimelineRow.build(new)
        guard loaded else {
            apply(new, newRows, animated: false)
            loaded = true
            if preview { expanded = Set(newRows.filter { $0.kind == .command && $0.effect != nil }.map(\.id)) }
            return
        }
        let known = Set(rows.map(\.id))
        let addedCount = newRows.filter { !known.contains($0.id) }.count
        if addedCount > 0, !rows.isEmpty, !expanded.isEmpty || scrolledAway {
            held = new
            withAnimation(.snappy) { heldCount = addedCount }
        } else {
            apply(new, newRows, animated: true)
        }
    }

    func apply(_ new: [TimelineEntry], _ newRows: [TimelineRow], animated: Bool) {
        let change = {
            entries = new
            rows = newRows
            held = nil
            heldCount = 0
            pinOverrides = [:]
        }
        if animated { withAnimation(.snappy, change) } else { change() }
    }

    func showHeld(_ proxy: ScrollViewProxy) {
        guard let held else { return }
        let built = TimelineRow.build(held)
        apply(held, built, animated: true)
        if let first = built.first?.id { withAnimation(.snappy) { proxy.scrollTo(first, anchor: .top) } }
    }

    func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let root = model.selectedRoot else {
            activeQuery = ""; pathHits = []; autoRow = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let hits = await model.snapshots(root: root, touching: q)
        guard !Task.isCancelled else { return }
        pathHits = hits
        activeQuery = q
        if let first = visibleRows.first {
            autoRow = first.id
            selection = first.id
            withAnimation(.snappy) { expanded = first.expandable ? [first.id] : [] }
        } else {
            autoRow = nil
        }
    }

    /// "Show" in the popover or a notification: scroll to the moment, open it and highlight it once.
    func applyFocus(_ proxy: ScrollViewProxy) {
        guard loaded, case .snapshot(let focusRoot, let id)? = model.focus, focusRoot == model.selectedRoot else { return }
        let source = held ?? entries
        let all = TimelineRow.build(source)
        if held != nil { apply(source, all, animated: false) }
        let target = all.first { $0.effect?.id == id } ?? all.first { $0.id == "s" + id } ?? all.first { $0.kind == .command && $0.moment?.id == id }
        model.focus = nil
        guard let target else { return }
        query = ""
        activeQuery = ""
        if target.expandable { expanded.insert(target.id) }
        selection = target.id
        DispatchQueue.main.async {
            withAnimation(.snappy) { proxy.scrollTo(target.id, anchor: .center) }
            flashID = target.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if flashID == target.id { flashID = nil } }
    }
}

/// "Take Snapshot" in the toolbar: progress while it runs, then a check for a moment; a failure is shown as a message.
private struct SnapshotToolbarButton: View {
    @EnvironmentObject var model: AppModel
    let root: String
    @State private var done = false

    var body: some View {
        let busy = model.snapshottingRoots.contains(root)
        Button { Task { await take() } } label: {
            Label {
                Text("Take Snapshot")
            } icon: {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: done ? "checkmark" : "camera").contentTransition(.symbolEffect(.replace)) }
            }
        }
        .help(Text("Take Snapshot"))
        .disabled(busy)
    }

    func take() async {
        let result: ManualSnapshotResult = await model.snapshotNow(root)
        switch result {
        case .created: showDone()
        case .unchanged:
            showDone()
            model.show(String(localized: "No changes since the last snapshot"))
        case .failed(let why): model.show(why, style: .failure)
        }
    }

    func showDone() {
        withAnimation { done = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { done = false }
        }
    }
}

struct TimelineRowView: View {
    @EnvironmentObject var model: AppModel
    let root: String
    let row: TimelineRow
    let expanded: Bool
    let selected: Bool
    let listFocused: Bool
    let pinned: Bool
    let flash: Bool
    /// The search text: matching files are tinted.
    let highlight: String?
    /// The first search match: select the first matching file and show its diff.
    let autoSelectFile: Bool
    /// Preview rendering: show the diff of the first edited file.
    let previewDiff: Bool
    let spaceTick: Int
    let isSpaceTarget: Bool
    let cache: ChangeCache
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onPin: (Bool) -> Void

    enum UndoState: Equatable { case idle, running, done, failed(String) }

    @State private var changes: [FileChange]?
    @State private var selectedFile: String?
    @State private var diffVisible = false
    @State private var openFolders: Set<String> = []
    @State private var undo: UndoState = .idle
    @State private var hover = false

    /// Nil while loading (a placeholder shows, never a flash of "no changes").
    var loadedChanges: [FileChange]? { changes ?? row.effect.flatMap { cache.map[$0.id] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case .failed(let message) = undo {
                Callout(.danger, verbatim: message).font(.callout)
                    .padding(.leading, 42).padding(.trailing, 12).padding(.bottom, 10)
            }
            if expanded {
                Divider().padding(.horizontal, 12)
                details.transition(.opacity)
            }
        }
        .flash(flash)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .card()
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(listFocused ? 0.9 : 0.35), lineWidth: listFocused ? 2 : 1)
            }
        }
        .task(id: row.effect?.id) { await loadChanges() }
        .onChange(of: autoSelectFile, initial: true) { autoSelect() }
        .onChange(of: highlight) { autoSelect() }
        .onChange(of: spaceTick) { if isSpaceTarget { toggleDiff() } }
    }

    // MARK: header

    var header: some View {
        HStack(spacing: 10) {
            symbol
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                if hasEffectLine { effectLine }
            }
            .layoutPriority(1) // the text gets the room first; the spacer only what is left
            Spacer(minLength: 8)
            if row.canUndo { undoButton }
            // Right-aligned in a column of its own, so times line up whether or not a row offers Undo.
            Text(verbatim: RelativeTime.age(ms: row.time))
                .font(.caption).foregroundStyle(.secondary).fixedSize()
                .help(Text(verbatim: RelativeTime.precise(ms: row.time)))
            Menu { menuItems(includeUndo: false) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(Text("More actions")).accessibilityLabel(Text("More actions"))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
                .opacity(row.expandable ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hover ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(); onToggle() }
        .onHover { hover = $0 }
        .contextMenu { menuItems(includeUndo: true) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(); onToggle() }
    }

    var symbol: some View {
        let (name, color) = symbolInfo
        return Image(systemName: name).foregroundStyle(color).font(.body).frame(width: 20).accessibilityHidden(true)
    }

    var symbolInfo: (String, Color) {
        if row.kind == .moment {
            switch row.trigger {
            case .initial: return ("shield", .secondary)
            case .manual: return ("camera", .secondary)
            case .preRestore, .postRestore: return ("arrow.uturn.backward.circle", .secondary)
            default: break
            }
        }
        if row.effect != nil {
            if let c = loadedChanges { return ChangeCounts.symbol(c) }
            return (row.kind == .command ? "terminal" : "doc", .secondary)
        }
        if let d = row.decision { let g = GuardStyle(d); return (g.symbol, g.color) }
        return ChangeCounts.symbol([])
    }

    var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if row.kind == .command, let c = row.command {
                Text(verbatim: TimelineRow.oneLine(c.command))
                    .font(.body.monospaced().weight(.medium))
                    .foregroundStyle(row.quiet ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(Text(verbatim: c.command))
            } else {
                Text(verbatim: row.title).font(.body.weight(.medium)).lineLimit(1).fixedSize()
                if let c = row.command {
                    Text.withCommand(String(localized: "before \(Text.commandMarker)"), TimelineRow.oneLine(c.command))
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(Text(verbatim: c.command))
                }
            }
            if pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.accent)
                    .help(Text("Keep this snapshot forever")).accessibilityLabel(Text("Pin snapshot"))
            }
            if (row.effect ?? row.moment)?.complete == false {
                Pill(text: "Incomplete", color: .secondary).help(Text("Some files were not captured in time."))
            }
        }
    }

    var hasEffectLine: Bool {
        (row.kind == .moment && row.trigger == .initial) || row.effect != nil || row.decision != nil || row.unchanged || row.kind == .command
    }

    /// What the row did, then who did it. In a narrow window the session, then the agent, then the folder give way.
    var effectLine: some View {
        ViewThatFits(in: .horizontal) {
            effectItems(folder: true, agent: true, session: true)
            effectItems(folder: true, agent: true, session: false)
            effectItems(folder: true, agent: false, session: false)
            effectItems(folder: false, agent: false, session: false)
        }
        .font(.caption)
        .lineLimit(1)
    }

    func effectItems(folder showFolder: Bool, agent showAgent: Bool, session showSession: Bool) -> some View {
        HStack(spacing: 12) {
            if row.kind == .moment && row.trigger == .initial, let s = row.moment {
                Text("\(s.fileCount) files").foregroundStyle(.secondary)
            } else if let e = row.effect {
                if let c = loadedChanges {
                    ChangeCounts(changes: c).fixedSize()
                    if showFolder, let folder = TimelineRow.commonFolder(c) {
                        Label { Text(verbatim: folder).font(.caption.monospaced()).truncationMode(.middle) } icon: { Image(systemName: "folder") }
                            .labelStyle(TightLabelStyle())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 220, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                            .help(Text(verbatim: folder))
                    }
                } else {
                    Text(verbatim: "\(e.changedCount) changed · src").redacted(reason: .placeholder)
                }
            }
            if let d = row.decision {
                GuardStyle(d).label.labelStyle(TightLabelStyle()).foregroundStyle(.secondary).fixedSize()
            } else if row.unchanged {
                Text("No files changed").foregroundStyle(.secondary).fixedSize()
            }
            if showAgent, row.kind == .command, let c = row.command {
                AgentBadge(agent: c.agent).labelStyle(TightLabelStyle()).foregroundStyle(.secondary)
                if showSession, let t = c.sessionTitle {
                    Text(verbatim: t).foregroundStyle(.tertiary).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    var undoButton: some View {
        Button { runUndo() } label: {
            HStack(spacing: 4) {
                if undo == .running {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: undo == .done ? "checkmark" : "arrow.uturn.backward").contentTransition(.symbolEffect(.replace))
                }
                Text("Undo")
            }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(undo == .running)
        .help(Text("Put the changed files back as they were before"))
    }

    @ViewBuilder func menuItems(includeUndo: Bool) -> some View {
        if includeUndo && row.canUndo {
            Button("Undo") { runUndo() }
            Divider()
        }
        Button("Restore Project to This Moment…") { restoreMoment() }.disabled(row.moment == nil)
        if pinned {
            Button("Unpin Snapshot") { onPin(false) }
        } else {
            Button("Pin Snapshot") { onPin(true) }.help(Text("Keep this snapshot forever")).disabled(row.moment == nil)
        }
        if let c = row.command {
            Button("Copy Command") { copy(c.command) }
        }
        if let g = guardEntry {
            Divider()
            Button("Show in Guard") { model.reveal(.guardEntry(g.id)) }
        }
    }

    /// The Guard entry of the row's command, when Guard recorded it.
    var guardEntry: GuardEntry? {
        guard row.decision != nil, let c = row.command else { return nil }
        return model.guardEntries.first { $0.command == c.command && abs($0.ts - c.ts) < 10_000 }
    }

    // MARK: details

    var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.kind == .command, let c = row.command, TimelineRow.isLong(c.command) {
                CommandText(command: c.command, lines: 8, font: .callout).foregroundStyle(.secondary)
            }
            if row.effect != nil { files }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 36).padding(.trailing, 12).padding(.vertical, 10)
    }

    @ViewBuilder var files: some View {
        if let changes = loadedChanges {
            if changes.isEmpty {
                Text("No file changes recorded in this snapshot.").font(.caption).foregroundStyle(.secondary)
            } else if changes.count > 20 {
                let groups = TimelineRow.groups(changes)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(groups.folders, id: \.0) { folder, items in
                        FolderHeader(folder: folder, changes: items, expanded: openFolders.contains(folder), canUndo: row.canUndo,
                                     toggle: { withAnimation(.snappy) { if openFolders.contains(folder) { openFolders.remove(folder) } else { openFolders.insert(folder) } } },
                                     undo: { runUndo(items.map(\.path)) })
                        if openFolders.contains(folder) { fileRows(items).padding(.leading, 18) }
                    }
                    fileRows(groups.loose)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) { fileRows(changes) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<min(max(row.effect?.changedCount ?? 2, 1), 3), id: \.self) { _ in
                    HStack(spacing: 8) {
                        Text(verbatim: "M").font(Theme.monoSmall.weight(.bold))
                        Text(verbatim: "src/components/placeholder.tsx").font(Theme.monoSmall)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                }
            }
            .redacted(reason: .placeholder)
        }
    }

    @ViewBuilder func fileRows(_ items: [FileChange]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(items.prefix(300), id: \.path) { c in
                FileRow(change: c, selected: selectedFile == c.path && diffVisible, matched: matches(c), canUndo: row.canUndo,
                        onSelect: { select(c.path) }, onUndo: { runUndo([c.path]) })
                    .contextMenu { fileMenu(c) }
                if selectedFile == c.path && diffVisible, let e = row.effect {
                    DiffBlock(root: root, snapshot: e.id, path: c.path).padding(.vertical, 4)
                }
            }
            if items.count > 300 {
                Text("\(items.count - 300) more…").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 2)
            }
        }
    }

    @ViewBuilder func fileMenu(_ c: FileChange) -> some View {
        if row.canUndo { Button("Undo Change to This File") { runUndo([c.path]) } }
        if c.status != .deleted, row.effect != nil { Button("Restore This Version…") { restoreFile(c.path) } }
        Divider()
        Button("Show in Finder") { model.revealFiles(root: root, paths: [c.path]) }
        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(c.path)) }.disabled(c.status == .deleted)
        Button("Copy Path") { copy(c.path) }
    }

    func matches(_ c: FileChange) -> Bool {
        guard let q = highlight, !q.isEmpty else { return false }
        return c.path.localizedCaseInsensitiveContains(q)
    }

    // MARK: actions

    func loadChanges() async {
        guard let e = row.effect, loadedChanges == nil else { autoSelect(); return }
        let loaded = await model.changes(root: root, snapshot: e.id)
        cache.map[e.id] = loaded
        changes = loaded
        autoSelect()
    }

    func autoSelect() {
        guard let list = loadedChanges, !list.isEmpty else { return }
        var pick: FileChange?
        if autoSelectFile, let q = highlight { pick = list.first { $0.path.localizedCaseInsensitiveContains(q) } }
        if pick == nil, previewDiff, selectedFile == nil { pick = list.first { $0.status == .modified } }
        guard let pick else { return }
        if list.count > 20, let folder = TimelineRow.groups(list).folders.first(where: { $0.1.contains(pick) })?.0 { openFolders.insert(folder) }
        selectedFile = pick.path
        diffVisible = true
    }

    func select(_ path: String) {
        onSelect()
        withAnimation(.snappy) {
            if selectedFile == path { diffVisible.toggle() } else { selectedFile = path; diffVisible = true }
        }
    }

    func toggleDiff() {
        withAnimation(.snappy) {
            if selectedFile == nil, let first = loadedChanges?.first {
                if let list = loadedChanges, list.count > 20, let folder = TimelineRow.groups(list).folders.first?.0 { openFolders.insert(folder) }
                selectedFile = first.path
                diffVisible = true
            } else {
                diffVisible.toggle()
            }
        }
    }

    /// Undo is immediate: it is reversible (Airbag snapshots first and the message offers Undo). The outcome shows on
    /// the button (a check, or the reason under the row).
    func runUndo(_ paths: [String]? = nil) {
        guard let e = row.effect, undo != .running else { return }
        withAnimation(.snappy) { undo = .running }
        Task {
            await model.undoChanges(root: root, snapshot: e.id, paths: paths)
            if let t = model.toast, t.style == .failure {
                withAnimation(.snappy) { undo = .failed(t.text) }
            } else {
                withAnimation(.snappy) { undo = .done }
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.snappy) { if undo == .done { undo = .idle } }
            }
        }
    }

    func restoreMoment() {
        guard let m = row.moment else { return }
        model.requestRestore(root: root, snapshot: m.id, time: m.createdAt, paths: [], intent: .restore,
                             command: row.kind == .command ? row.command?.command : nil, title: row.kind == .command ? nil : row.title)
    }

    func restoreFile(_ path: String) {
        guard let e = row.effect else { return }
        model.requestRestore(root: root, snapshot: e.id, time: e.createdAt, paths: [path], intent: .restore,
                             command: row.kind == .command ? row.command?.command : nil, title: row.kind == .command ? nil : row.title)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Icon and title close together (metadata lines).
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

/// One changed file: click shows its diff; hovering offers Undo for just this file.
private struct FileRow: View {
    let change: FileChange
    let selected: Bool
    let matched: Bool
    let canUndo: Bool
    let onSelect: () -> Void
    let onUndo: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            ChangeRow(change: change)
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward").font(.caption) }
                .buttonStyle(.borderless)
                .help(Text("Undo Change to This File"))
                .accessibilityLabel(Text("Undo Change to This File"))
                .opacity(canUndo && hover ? 1 : 0)
                .allowsHitTesting(canUndo && hover)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(
            selected ? Theme.accent.opacity(0.16) : hover ? Color.primary.opacity(0.05) : matched ? Theme.accent.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
    }
}

/// A folder of a large change list; when everything in it was deleted, hovering offers Undo for the whole folder.
private struct FolderHeader: View {
    let folder: String
    let changes: [FileChange]
    let expanded: Bool
    let canUndo: Bool
    let toggle: () -> Void
    let undo: () -> Void
    @State private var hover = false

    var body: some View {
        let allDeleted = changes.allSatisfy { $0.status == .deleted }
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
            Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: folder + "/").font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
            ChangeCounts(changes: changes).fixedSize()
            Spacer(minLength: 4)
            if allDeleted && canUndo {
                Button("Undo", action: undo)
                    .controlSize(.small)
                    .help(Text("Put the changed files back as they were before"))
                    .opacity(hover ? 1 : 0)
                    .allowsHitTesting(hover)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
    }
}

/// A file's diff against the snapshot before: long lines scroll sideways, long diffs scroll inside a 320 pt box.
private struct DiffBlock: View {
    @EnvironmentObject var model: AppModel
    let root: String
    let snapshot: String
    let path: String
    @State private var diff: TextDiff?
    @State private var loaded = false
    /// The box's width: line backgrounds reach its right edge even when every line is short.
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if let diff {
                ViewThatFits(in: .vertical) {
                    lines(diff)
                    ScrollView(.vertical) { lines(diff) }
                }
                .frame(maxHeight: 320)
            } else if loaded {
                Text("No changes in this file").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w } })
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
        .task(id: path) {
            diff = await model.fileDiff(root: root, snapshot: snapshot, path: path)
            loaded = true
        }
    }

    func lines(_ diff: TextDiff) -> some View {
        ScrollView(.horizontal) {
            DiffView(diff: diff).padding(.vertical, 6).frame(minWidth: max(width - 16, 0), alignment: .leading).padding(.horizontal, 8)
        }
        .defaultScrollAnchor(.topLeading)
    }
}
