import AirbagCore
import AppKit
import SwiftUI

/// The menu bar dropdown (docs/design/13-product-spec.md §6.3).
struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let msg = model.toast?.text {
                        HStack(alignment: .top) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                            Text(msg).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button { model.dismissToast() } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain)
                                .accessibilityLabel(Text("Dismiss"))
                        }
                        .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !model.attentionGuards.isEmpty || !model.orphans.isEmpty { attention }
                    projectsSection
                }
                .padding(14)
            }
            .frame(maxHeight: 440)
            Divider()
            navigation
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { model.popoverVisible = true; model.refreshAll() }
        .onDisappear { model.popoverVisible = false }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: model.iconState.symbol).foregroundStyle(model.iconState == .needsYou ? Theme.warning : Theme.accent)
                Text(verbatim: "Airbag").font(.headline)
                if let until = model.pausedUntil {
                    Pill(text: "Paused until \(until.formatted(date: .omitted, time: .shortened))", color: Theme.warning)
                }
                Spacer()
                Button { model.windowRequest = .settings } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(Text("Settings")).accessibilityLabel(Text("Settings"))
                    .keyboardShortcut(",", modifiers: .command)
            }
            Text(model.summaryLine).font(.callout).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if model.iconState == .degraded {
                Label(model.hookStatuses.contains { $0.installed && $0.brokenCommand }
                      ? "An agent hook points at a missing Airbag copy — open Settings and repair it."
                      : "Agents found, but no hooks installed — snapshots happen only on file changes.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    var attention: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Needs attention", count: model.attentionGuards.count + model.orphans.count)
            ForEach(model.attentionGuards.prefix(4)) { g in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: g.decision == "deny" ? "hand.raised.fill" : "questionmark.circle.fill").foregroundStyle(g.decision == "deny" ? Theme.danger : Theme.warning)
                        Text(g.decision == "deny" ? "Blocked" : "Waiting for approval").font(.callout.weight(.semibold))
                        Spacer()
                        Text(RelativeTime.short(ms: g.ts)).font(.caption).foregroundStyle(.secondary)
                    }
                    CommandText(command: g.command)
                    Text(projectAndSession(g)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        if g.canAllowOnce { Button("Allow once") { model.allowOnce(g) }.controlSize(.small) }
                        Button("Dismiss") { model.dismiss(g) }.controlSize(.small)
                        Button("Show") { open(.guardLog) }.controlSize(.small).buttonStyle(.link)
                    }
                }
            }
            let bySession = Dictionary(grouping: model.orphans) { $0.attribution?.agentSessionID ?? "-" }
            ForEach(bySession.keys.sorted(), id: \.self) { sid in
                let procs = bySession[sid] ?? []
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("Session ended — stop its \(procs.count) servers?").font(.callout.weight(.semibold))
                    }
                    Text(verbatim: ([procs.first?.attribution?.agent?.displayName, procs.first?.attribution?.sessionTitle].compactMap { $0 } + procs.map { "\($0.name) \($0.portsText)" }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Button("Stop \(procs.count)") { Task { for p in procs { _ = await model.stopProcess(p, force: false) } } }.controlSize(.small)
                        Button("Keep") { procs.forEach(model.keep) }.controlSize(.small)
                        Button("Show") { open(.radar) }.controlSize(.small).buttonStyle(.link)
                    }
                }
            }
        }
    }

    func projectAndSession(_ g: GuardEntry) -> String {
        [g.projectRoot.map { ($0 as NSString).lastPathComponent }, g.agent?.displayName, g.sessionTitle].compactMap { $0 }.joined(separator: " · ")
    }

    var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Projects")
            if model.projects.isEmpty {
                Text("No protected projects yet. Install agent hooks in Settings, or add a folder.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.projects.prefix(8)) { p in
                Button { model.selectedRoot = p.root; open(.timeline) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(p.liveSessions > 0 ? Theme.ok : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            .accessibilityLabel(Text(p.liveSessions > 0 ? "live session" : "idle"))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(verbatim: p.name).font(.callout.weight(.medium))
                                if p.isWorktree { Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary) }
                                if !p.rootExists { Pill(text: "folder missing", color: Theme.danger) }
                            }
                            Text(projectDetail(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !p.ports.isEmpty { Text(verbatim: p.ports.prefix(3).map { ":\($0)" }.joined(separator: " ")).font(Theme.monoSmall).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Snapshot now") { model.snapshotNow(p.root) }
                    Button("Reveal in Finder") { model.revealInFinder(p.root) }
                }
            }
            Button { addProject() } label: { Label("Add project…", systemImage: "plus") }.buttonStyle(.link).font(.callout)
        }
    }

    func projectDetail(_ p: ProjectRow) -> String {
        var parts: [String] = []
        if p.liveSessions > 0 { parts.append(String(localized: "\(p.liveSessions) live")) }
        if let t = p.lastSnapshotAt { parts.append(String(localized: "snapshot \(RelativeTime.short(ms: t))")) }
        if p.pinnedCount > 0 { parts.append(String(localized: "\(p.pinnedCount) pinned")) }
        return parts.joined(separator: " · ")
    }

    var navigation: some View {
        HStack(spacing: 8) {
            ForEach([MainTab.timeline, .radar, .guardLog]) { tab in
                Button { open(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.body)
                        Text(tab.title).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
    }

    var footer: some View {
        HStack {
            if model.pausedUntil == nil {
                Menu("Pause") {
                    Button("For 15 minutes") { model.pause(minutes: 15) }
                    Button("For 1 hour") { model.pause(minutes: 60) }
                    Button("Until tomorrow morning") { model.pauseUntilTomorrowMorning() }
                }
                .menuStyle(.borderlessButton).fixedSize()
            } else {
                Button("Resume") { model.pause(minutes: nil) }.buttonStyle(.link)
            }
            Spacer()
            Button("Snapshot all now") { model.snapshotAll() }.buttonStyle(.link)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link).keyboardShortcut("q")
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    func open(_ tab: MainTab) {
        model.selectedTab = tab
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Protect")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { model.addProject(url) }
    }
}
