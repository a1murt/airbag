import AirbagCore
import AppKit
import SwiftUI

/// First run (spec §5): what Airbag does → hooks for detected agents → projects → done. Target: under a minute.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var agents: Set<AgentKind> = []
    @State private var suggestions: [String] = []
    @State private var projects: Set<String> = []
    @State private var loadingSuggestions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shield.fill").font(.title).foregroundStyle(Theme.accent)
                Text(verbatim: "Airbag").font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(step + 1) of 4").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            Group {
                switch step {
                case 0: welcome
                case 1: agentsStep
                case 2: projectsStep
                default: doneStep
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if step > 0 && step < 3 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 3 {
                    Button(step == 0 ? "Get started" : "Continue") { advance() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { model.finishOnboarding(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .onAppear {
            agents = Set(model.hookStatuses.filter { $0.detected }.map(\.agent))
            Task {
                suggestions = await model.suggestedProjects()
                projects = Set(suggestions.prefix(5))
                loadingSuggestions = false
            }
        }
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A safety net for AI coding agents").font(.title3.weight(.semibold))
            bullet("camera", "Snapshots before every agent command", "Taken by Airbag itself, so even `rm -rf` or `git reset --hard` run through the shell can be undone in one click.")
            bullet("hand.raised", "Stops what a snapshot cannot undo", "Deleting your home folder, wiping a disk, force-pushing or dropping a database is blocked or needs your approval.")
            bullet("dot.radiowaves.left.and.right", "Finds servers agents leave running", "See every dev server with the session that started it, and stop the ones whose session has ended.")
            Text("Everything stays on this Mac. No account, no telemetry.").font(.callout).foregroundStyle(.secondary)
        }
    }

    func bullet(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var agentsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your agents").font(.title3.weight(.semibold))
            Text("Airbag adds one hook entry to each agent's user settings file. Your other settings and hooks stay as they are, a backup is kept, and Remove in Settings undoes it exactly.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.hookStatuses, id: \.agent) { s in
                Toggle(isOn: Binding(get: { agents.contains(s.agent) }, set: { if $0 { agents.insert(s.agent) } else { agents.remove(s.agent) } })) {
                    HStack {
                        AgentBadge(agent: s.agent)
                        Text(s.installed ? "already connected" : (s.detected ? "found" : "not found on this Mac")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!s.detected || s.installed)
            }
            if agents.contains(.codex) {
                Label("Codex asks you to trust new hooks once: open Codex, type /hooks and press t.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.hookStatuses.allSatisfy({ !$0.detected }) {
                Text("No agents found yet. You can connect them later in Settings; Airbag still snapshots your projects when files change.")
                    .font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var projectsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose projects to protect").font(.title3.weight(.semibold))
            Text("Suggested from your recent agent sessions. Projects where an agent works later are protected automatically.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loadingSuggestions { ProgressView().controlSize(.small) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(suggestions, id: \.self) { p in
                        Toggle(isOn: Binding(get: { projects.contains(p) }, set: { if $0 { projects.insert(p) } else { projects.remove(p) } })) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: (p as NSString).lastPathComponent).font(.callout.weight(.medium))
                                Text(verbatim: (p as NSString).abbreviatingWithTildeInPath).font(Theme.monoSmall).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Button("Add another folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    let path = FileSystem.canonicalPath(url.path) ?? url.path
                    if !suggestions.contains(path) { suggestions.append(path) }
                    projects.insert(path)
                }
            }
        }
    }

    var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're protected").font(.title3.weight(.semibold))
            Text("Airbag lives in the menu bar. The shield turns into an exclamation mark when it blocks a command, and a dot appears when a session leaves servers running.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("First snapshots are being taken in the background; large projects can take a minute.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Open Airbag at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
        }
    }

    func advance() {
        if step == 1 { for a in agents { model.installHooks(a) } }
        if step == 2 { for p in projects { model.addProject(URL(fileURLWithPath: p)) } }
        step += 1
    }
}
