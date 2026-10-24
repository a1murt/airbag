import AirbagCore
import AppKit
import SwiftUI

/// The restore confirmation is a separate window rather than a sheet (sheets in agent-style apps lost input on 14.0).
/// It asks once, in the verb that opened it, shows exactly which files come back, then reports the result in place with
/// Undo Restore, so the moment that matters most never depends on a message that times out.
struct RestoreWindow: View {
    /// What the window shows. `running` and `undoing` ignore new requests until they finish.
    enum Phase {
        case confirm
        case running
        case done(RestoreReport)
        case undoing(RestoreReport)
        case undone
        case failed(String)
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Preview rendering: show this phase for the current request instead of asking.
    var preview: Phase? = nil

    /// The request on screen. It changes only between runs, never while files are being written.
    @State private var active: RestoreRequest?
    @State private var phase: Phase = .confirm
    @State private var groups: RestoreGroups?
    @State private var planMissing = false
    /// The `hookTick` the plan was computed at (agent commands after it may have changed the files).
    @State private var planTick = 0
    @State private var undoError: String?
    @State private var presence = Presence()

    /// The plan is known and changes nothing (or the snapshot is gone): the window only informs.
    private var nothingToDo: Bool { groups?.isEmpty == true || planMissing }

    private var busy: Bool {
        switch phase {
        case .running, .undoing: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if let r = active {
                switch phase {
                case .confirm, .running: confirmation(r)
                case .done(let rep), .undoing(let rep): result(r, rep)
                case .undone: undone
                case .failed(let why): failure(r, why)
                }
            } else {
                nothing
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(Text((active ?? model.restoreRequest).map { Self.actionTitle($0.intent) } ?? "Restore"))
        .task(id: model.restoreRequest?.id) { await adopt() }
        // An agent that keeps working changes what a restore would do: keep the list true while the window asks.
        .task(id: model.hookTick) { await reloadPlan() }
        .onAppear { presence.visible = true }
        .onDisappear { presence.visible = false }
    }

    // MARK: confirmation

    private func confirmation(_ r: RestoreRequest) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: r.intent == .undo ? "arrow.uturn.backward.circle" : "clock.arrow.circlepath")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        title(r).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            .help(Text(verbatim: [r.command, RelativeTime.precise(ms: r.snapshotTime)].compactMap { $0 }.joined(separator: "\n")))
                        if let s = subtitle(r) { s.font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                    notes(r)
                    plan
                    if !nothingToDo {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Airbag saves the current state first, so you can undo this.")
                            if r.paths.isEmpty {
                                Text("Folders Airbag does not snapshot (node_modules, build output, files over 100 MB) are left as they are.")
                                    .font(.caption)
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                if busy { progress }
                Spacer()
                if nothingToDo {
                    // Nothing to ask: one button, Return and Esc both close.
                    Button("Done") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .background { EscapeKey(action: finish) }
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(busy)
                    Button { start(r) } label: { Text(Self.actionTitle(r.intent)) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || groups == nil)
                }
            }
        }
    }

    /// Warnings first (they change whether to go ahead), then what Git users need to know.
    @ViewBuilder
    private func notes(_ r: RestoreRequest) -> some View {
        let partial = groups.map { !$0.complete } ?? false
        let git = r.command.map(Self.touchesGitHistory) ?? false
        if r.liveAgents > 0 || partial || git {
            VStack(alignment: .leading, spacing: 8) {
                if r.liveAgents > 0 {
                    Callout(.warning, "An agent is still working here and may overwrite these files. Pause it first.")
                }
                if partial {
                    Callout(.warning, "This snapshot is partial: only the files it captured are restored.")
                }
                if git {
                    Callout(.info, "Your files come back; Git history (commits, branches) is not changed.")
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var plan: some View {
        if planMissing {
            Callout(.danger, verbatim: model.describe(SnapshotError.notFound(active?.snapshotID ?? ""))).font(.callout)
        } else if let g = groups {
            if g.isEmpty {
                Callout(.success, "Nothing to do: these files already match the snapshot.").font(.callout)
            } else {
                PlanCard(groups: g, root: active?.root ?? "")
            }
        } else {
            DelayedSpinner()
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Restoring…").foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    // MARK: result

    private func result(_ r: RestoreRequest, _ rep: RestoreReport) -> some View {
        let total = rep.restored.count + rep.movedAside.count
        let clean = rep.conflicts.isEmpty && rep.failed.isEmpty
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                if !clean { ResultSymbol(name: "exclamationmark.triangle.fill", color: Theme.warning) }
                else if total > 0 { ResultSymbol(name: "checkmark.circle.fill", color: Theme.ok) }
                else { ResultSymbol(name: "checkmark.circle", color: .secondary) }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: Self.headline(rep, root: r.root))
                            .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if total > 0, clean, let cmd = r.command, r.intent == .undo {
                            Text.withCommand(String(localized: "Changes from \(Text.commandMarker) are undone."), Self.short(cmd))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        } else if total == 0, clean {
                            // The files changed back on their own between the question and the click.
                            Text("Nothing to do: these files already match the snapshot.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !rep.movedAside.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !rep.restored.isEmpty { Text(verbatim: Self.setAsideText(rep)).foregroundStyle(.secondary) }
                            if let aside = rep.asideDirectory {
                                Button("Show Set-Aside Files") { model.revealInFinder(aside) }.buttonStyle(.link)
                            }
                        }
                        .font(.callout)
                    }
                    if !rep.conflicts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Callout(.warning, "\(rep.conflicts.count) skipped because they changed during the restore.")
                            FileList(paths: rep.conflicts, root: r.root, maxHeight: 90).padding(.leading, 22)
                        }
                        .font(.callout)
                    }
                    if !rep.failed.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Callout(.danger, "\(rep.failed.count) failed.")
                            FileList(paths: rep.failed, root: r.root, maxHeight: 90).padding(.leading, 22)
                        }
                        .font(.callout)
                    }
                    if let undoError { Callout(.danger, verbatim: undoError).font(.callout) }
                }
            }
            HStack(spacing: 8) {
                if let undo = rep.undoSnapshotId {
                    Button("Undo Restore") { undoRestore(r, to: undo, rep) }
                        .keyboardShortcut("z", modifiers: .command)
                        .help(Text("Put the files back as they were before this restore"))
                }
                if !rep.restored.isEmpty {
                    Button("Show in Finder") { model.revealFiles(root: r.root, paths: rep.restored) }
                }
                if busy { progress.padding(.leading, 4) }
                Spacer()
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
        }
        .background { EscapeKey { if !busy { finish() } } }
    }

    private var undone: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ResultSymbol(name: "arrow.uturn.backward.circle.fill", color: Theme.ok)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restore undone").font(.title3.weight(.semibold))
                    Text("The files are back as they were before the restore.").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Done") { finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .background { EscapeKey(action: finish) }
    }

    private func failure(_ r: RestoreRequest, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: r.intent == .undo ? "arrow.uturn.backward.circle" : "clock.arrow.circlepath")
                    .font(.system(size: 32, weight: .regular)).foregroundStyle(.secondary).frame(width: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        title(r).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if let s = subtitle(r) { s.font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                    Callout(.danger, verbatim: why).font(.callout)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Try Again") { Task { await adopt(force: true) } }
                Button("Close") { finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .background { EscapeKey(action: finish) }
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nothing to restore.").font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Spacer()
                Button("Open Timeline") { model.windowRequest = .main(.timeline); dismiss() }
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .background { EscapeKey { dismiss() } }
    }

    // MARK: words

    /// What happened, counted the way the user sees it: files that came back, and newer files moved out of the way.
    static func headline(_ rep: RestoreReport, root: String) -> String {
        if !rep.restored.isEmpty { return String(localized: "Restored \(rep.restored.count) files in \((root as NSString).lastPathComponent)") }
        if !rep.movedAside.isEmpty { return setAsideText(rep) }
        return String(localized: "Nothing was restored")
    }

    static func setAsideText(_ rep: RestoreReport) -> String {
        String(localized: "\(rep.movedAside.count) newer files set aside, not deleted")
    }

    static func actionTitle(_ intent: RestoreRequest.Intent) -> LocalizedStringKey {
        switch intent {
        case .undo: return "Undo Changes"
        case .restore: return "Restore"
        }
    }

    /// The question in the verb that opened the window: undo names the command, restore names the moment.
    private func title(_ r: RestoreRequest) -> Text {
        let time = Self.timeText(r.snapshotTime)
        let file = r.paths.count == 1 ? (r.paths[0] as NSString).lastPathComponent : nil
        switch r.intent {
        case .undo:
            if let file { return Text("Undo the change to \(file)?") }
            if let cmd = r.command { return Text.withCommand(String(localized: "Undo changes from \(Text.commandMarker)?"), Self.short(cmd)) }
            return Text("Undo these file changes?")
        case .restore:
            if r.paths.count > 1 { return Text("Restore \(r.paths.count) files to \(time)?") }
            return Text("Restore \(file ?? (r.root as NSString).lastPathComponent) to \(time)?")
        }
    }

    /// Where and which moment, in one quiet line: the project, then the command, file or time the title leaves out.
    private func subtitle(_ r: RestoreRequest) -> Text? {
        let project = (r.root as NSString).lastPathComponent
        let detail: Text?
        switch r.intent {
        case .undo:
            if r.paths.count == 1, let cmd = r.command { detail = Text(verbatim: Self.short(cmd)).monospaced() }
            else if r.command != nil || r.title == nil { detail = Text(verbatim: Self.timeText(r.snapshotTime)) }
            else { detail = r.title.map(Self.momentText) }
        case .restore:
            if r.paths.count == 1 {
                // The title names the file; the folder it is in tells which one.
                detail = r.paths[0].contains("/") ? Text(verbatim: r.paths[0]).monospaced() : nil
            }
            else if let t = r.title { detail = Self.momentText(t) }
            else { detail = r.command.map { Text(verbatim: Self.short($0)).monospaced() } }
            if r.paths.isEmpty { return detail }
        }
        guard let detail else { return Text(verbatim: project) }
        return Text(verbatim: project + " · ") + detail
    }

    /// A command short enough for a title: its first line, at most about 60 characters (the full one is in the tooltip).
    static func short(_ command: String) -> String {
        let lines = command.split(whereSeparator: \.isNewline)
        let first = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? command
        if first.count > 60 { return first.prefix(58).trimmingCharacters(in: .whitespaces) + "…" }
        return lines.count > 1 ? first + " …" : first
    }

    /// "5:34 PM, 12 min ago": the moment on the clock and how long ago it was.
    static func timeText(_ ms: Int64) -> String {
        String(localized: "\(RelativeTime.clock(ms: ms)), \(RelativeTime.short(ms: ms))", comment: "Time of a snapshot, then how long ago")
    }

    /// A Timeline moment name ("After `rm -rf src/legacy`") with the command set in monospace instead of backticks.
    static func momentText(_ name: String) -> Text {
        let parts = name.components(separatedBy: "`")
        guard parts.count >= 3 else { return Text(verbatim: name) }
        return parts.enumerated().reduce(Text(verbatim: "")) { text, part in
            part.offset % 2 == 1 ? text + Text(verbatim: part.element).monospaced() : text + Text(verbatim: part.element)
        }
    }

    /// Git commands that move history: a file snapshot puts the files back, but commits, branches and HEAD stay.
    static func touchesGitHistory(_ command: String) -> Bool {
        let history: Set<String> = ["reset", "checkout", "switch", "rebase", "restore", "clean", "stash"]
        for segment in command.components(separatedBy: CharacterSet(charactersIn: ";&|\n")) {
            var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)[...]
            while let w = words.first, w.contains("="), !w.hasPrefix("-") { words = words.dropFirst() } // FOO=1 git …
            guard let first = words.first, first == "git" || first.hasSuffix("/git") else { continue }
            words = words.dropFirst()
            while let w = words.first, w.hasPrefix("-") { // git -C dir -c key=value reset
                words = words.dropFirst()
                if ["-C", "-c", "--git-dir", "--work-tree"].contains(w) { words = words.dropFirst() }
            }
            if let sub = words.first, history.contains(sub) { return true }
        }
        return false
    }

    // MARK: actions

    /// Takes the model's current request unless a run is in flight (that one finishes first; Done then shows the new one).
    private func adopt(force: Bool = false) async {
        guard !busy, let r = model.restoreRequest else { return }
        guard force || r.id != active?.id else { return }
        active = r
        groups = nil
        planMissing = false
        undoError = nil
        phase = .confirm
        planTick = model.hookTick
        switch preview {
        case .done, .undoing, .undone, .failed: phase = preview ?? .confirm; return
        default: break
        }
        let loaded = await loadPlan(r)
        guard active?.id == r.id else { return }
        if let loaded { groups = loaded } else { planMissing = true }
        if case .running = preview { phase = .running }
    }

    private func reloadPlan() async {
        guard case .confirm = phase, let r = active, groups != nil, model.hookTick != planTick else { return }
        // Agents run commands in bursts: one plan after the burst, not one per command (each walks the project).
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !Task.isCancelled else { return }
        planTick = model.hookTick
        guard let loaded = await loadPlan(r), active?.id == r.id, case .confirm = phase, loaded != groups else { return }
        withAnimation(.snappy) { groups = loaded }
    }

    private func loadPlan(_ r: RestoreRequest) async -> RestoreGroups? {
        guard let plan = await model.planRestore(root: r.root, snapshot: r.snapshotID, scope: r.scope) else { return nil }
        let root = r.root
        return await Task.detached(priority: .userInitiated) { RestoreGroups(plan, root: root) }.value
    }

    private func start(_ r: RestoreRequest) {
        guard !busy, groups?.isEmpty == false else { return }
        withAnimation(.snappy) { phase = .running }
        let presence = self.presence
        Task {
            // The window reports the result (with Undo Restore); the menu still offers it through `lastRestore`.
            let result = await model.restore(root: r.root, snapshot: r.snapshotID, scope: r.scope, announce: false)
            switch result {
            case .success(let rep):
                withAnimation(.snappy) { phase = .done(rep) }
                let summary = Self.headline(rep, root: r.root)
                if presence.visible { AccessibilityNotification.Announcement(summary).post() }
                else { announce(summary, rep, r) }
            case .failure(let e):
                withAnimation(.snappy) { phase = .failed(model.describe(e)) }
                if !presence.visible { model.show(model.describe(e), style: .failure) }
            }
        }
    }

    /// The window was closed while files were being written: the result goes to the usual message instead.
    private func announce(_ summary: String, _ rep: RestoreReport, _ r: RestoreRequest) {
        let style: Toast.Style = rep.failed.isEmpty ? .success : .warning
        guard let undo = rep.undoSnapshotId else { model.show(summary, style: style); return }
        model.show(summary, style: style, action: (String(localized: "Undo"), { [model] in
            Task { await model.revertRestore(root: r.root, to: undo, scope: r.scope) }
        }))
    }

    private func undoRestore(_ r: RestoreRequest, to undo: String, _ rep: RestoreReport) {
        guard !busy else { return }
        undoError = nil
        withAnimation(.snappy) { phase = .undoing(rep) }
        Task {
            if await model.revertRestore(root: r.root, to: undo, scope: r.scope) {
                withAnimation(.snappy) { phase = .undone }
                AccessibilityNotification.Announcement(String(localized: "Restore undone")).post()
            } else {
                // revertRestore reports why in its message; the window repeats it where the user is looking.
                let why = model.toast?.style == .failure ? model.toast?.text : nil
                withAnimation(.snappy) {
                    undoError = why ?? String(localized: "Couldn't undo the restore.")
                    phase = .done(rep)
                }
            }
        }
    }

    /// Done closes the window, unless another restore was asked for while this one ran: then that one is shown.
    private func finish() {
        if let next = model.restoreRequest, next.id != active?.id {
            Task { await adopt() }
        } else {
            dismiss()
        }
    }
}

/// Lets a finished restore know whether its window is still open (a closed window cannot report the result).
@MainActor
private final class Presence {
    var visible = false
}

/// The plan in the window's words, split by what happens to each file.
struct RestoreGroups: Equatable, Sendable {
    /// Missing now: put back.
    var bringBack: [String] = []
    /// There now, with other content: replaced with the version from the snapshot.
    var revert: [String] = []
    /// Created after the snapshot: moved into Airbag's store, never deleted.
    var setAside: [String] = []
    var complete = true
    var isEmpty: Bool { bringBack.isEmpty && revert.isEmpty && setAside.isEmpty }

    init(_ plan: RestorePlan, root: String) {
        for p in plan.write {
            // attributesOfItem does not follow symlinks: a link that is there counts as there.
            if (try? FileManager.default.attributesOfItem(atPath: (root as NSString).appendingPathComponent(p))) != nil { revert.append(p) }
            else { bringBack.append(p) }
        }
        setAside = plan.moveAside
        complete = plan.complete
        // Finder order: file2 before file10.
        for list in [\Self.bringBack, \Self.revert, \Self.setAside] {
            self[keyPath: list].sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}

/// Bring back, Revert and Set aside in one card, each with its count and files.
private struct PlanCard: View {
    let groups: RestoreGroups
    let root: String

    var body: some View {
        let sections = [!groups.bringBack.isEmpty, !groups.revert.isEmpty, !groups.setAside.isEmpty].filter { $0 }.count
        // A half-visible last row shows that the list scrolls (rows are about 16 pt).
        let listHeight: CGFloat = sections > 1 ? 104 : 152
        VStack(alignment: .leading, spacing: 0) {
            if !groups.bringBack.isEmpty {
                section(symbol: "arrow.uturn.backward", color: Theme.ok, title: Text("Bring back"), hint: nil,
                        paths: groups.bringBack, listHeight: listHeight)
            }
            if !groups.revert.isEmpty {
                if !groups.bringBack.isEmpty { Divider() }
                section(symbol: "arrow.counterclockwise", color: Theme.warning, title: Text("Revert"),
                        hint: Text("changed since then; replaced with the earlier version"), paths: groups.revert, listHeight: listHeight)
            }
            if !groups.setAside.isEmpty {
                if !groups.bringBack.isEmpty || !groups.revert.isEmpty { Divider() }
                section(symbol: "tray.and.arrow.down", color: .secondary, title: Text("Set aside"),
                        hint: Text("created later; moved to Airbag's store, not deleted"), paths: groups.setAside, listHeight: listHeight)
            }
        }
        .card()
    }

    private func section(symbol: String, color: Color, title: Text, hint: Text?, paths: [String], listHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 16).accessibilityHidden(true)
                title.font(.callout.weight(.semibold))
                if let hint { hint.font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                Text(paths.count, format: .number).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            FileList(paths: paths, root: root, maxHeight: listHeight).padding(.leading, 22)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// Paths as Finder would read them (folder dimmed, name in full), as tall as their content up to `maxHeight`, then scrolling.
private struct FileList: View {
    let paths: [String]
    let root: String
    let maxHeight: CGFloat
    private let limit = 200

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(paths.prefix(limit), id: \.self) { p in row(p) }
                if paths.count > limit {
                    let hiddenCount = paths.count - limit
                    Text("\(hiddenCount) more…").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ p: String) -> some View {
        let dir = (p as NSString).deletingLastPathComponent
        let name = (p as NSString).lastPathComponent
        return (Text(verbatim: dir.isEmpty ? "" : dir + "/").foregroundStyle(.secondary) + Text(verbatim: name))
            .font(.subheadline.monospaced())
            .lineLimit(1).truncationMode(.middle)
            .help(Text(verbatim: p))
            .contextMenu {
                Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string) }
                let url = URL(fileURLWithPath: root).appendingPathComponent(p)
                if FileManager.default.fileExists(atPath: url.path) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
    }
}

/// Esc in a state without a Cancel button: a button the size of nothing that keeps its shortcut.
private struct EscapeKey: View {
    let action: () -> Void
    var body: some View {
        Button("Close", action: action)
            .keyboardShortcut(.cancelAction)
            .focusable(false)
            .frame(width: 0, height: 0).opacity(0)
            .accessibilityHidden(true)
    }
}

/// The result symbol bounces once when it appears (static under Reduce Motion).
private struct ResultSymbol: View {
    let name: String
    let color: Color
    @State private var bounce = 0

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 32, weight: .regular))
            .foregroundStyle(color)
            .symbolEffect(.bounce, value: bounce)
            .frame(width: 38)
            .accessibilityHidden(true)
            .task(id: name) { bounce += 1 }
    }
}

/// A plan usually arrives within milliseconds: the spinner appears only when it does not.
private struct DelayedSpinner: View {
    @State private var visible = false
    var body: some View {
        ProgressView().controlSize(.small)
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, minHeight: 28)
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation(.easeIn(duration: 0.2)) { visible = true }
            }
    }
}
