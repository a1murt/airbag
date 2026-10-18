import AirbagCore
import AppKit
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var preview: (AgentKind, String)?

    var body: some View {
        Form {
            Section("Agents and hooks") {
                Text("Airbag adds a small hook to each agent's own settings file. It runs before every shell command, takes a snapshot and stops only what a snapshot cannot undo. Other hooks in those files are left untouched; a backup is kept.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(model.hookStatuses, id: \.agent) { s in
                    HStack(alignment: .firstTextBaseline) {
                        AgentBadge(agent: s.agent).frame(width: 170, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stateText(s)).font(.callout)
                            Text(verbatim: (s.configPath as NSString).abbreviatingWithTildeInPath).font(Theme.monoSmall).foregroundStyle(.tertiary)
                            if let note = s.note, s.installed { Text(verbatim: note).font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer()
                        if s.installed {
                            if !s.current { Button("Repair") { model.installHooks(s.agent) } }
                            Button("Remove") { model.uninstallHooks(s.agent) }
                        } else {
                            Button("Preview") { preview = (s.agent, (try? model.installer.plan(s.agent, install: true, strict: model.strictMode).after) ?? "") }
                            Button("Install") { model.installHooks(s.agent) }.buttonStyle(.borderedProminent).disabled(!s.detected)
                        }
                    }
                }
                if let (agent, text) = preview {
                    VStack(alignment: .leading) {
                        HStack { Text("\(agent.displayName) settings after install").font(.caption.weight(.semibold)); Spacer(); Button("Close") { preview = nil }.controlSize(.small) }
                        ScrollView { Text(verbatim: text).font(Theme.monoSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 180).background(Color(nsColor: .textBackgroundColor))
                    }
                }
            }
            Section("Projects") {
                ForEach(model.projects) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: p.name).font(.callout.weight(.medium))
                            Text(verbatim: (p.root as NSString).abbreviatingWithTildeInPath).font(Theme.monoSmall).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("\(p.snapshotCount) snapshots").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        Button("Snapshot now") { model.snapshotNow(p.root) }.disabled(!p.rootExists)
                        Button { model.revealInFinder(p.root) } label: { Image(systemName: "folder") }.disabled(!p.rootExists)
                    }
                }
                Button("Add project folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { model.addProject(url) }
                }
                Text("Snapshots include .env and other git-ignored files. Dependency and build folders (node_modules, dist, .next, build, target, .venv…) are skipped because they can be regenerated.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Snapshots") {
                Picker("Keep snapshots for", selection: Binding(get: { model.retentionDays }, set: { model.setRetention(days: $0, budgetGB: model.budgetGB) })) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Disk budget for all projects", selection: Binding(get: { model.budgetGB }, set: { model.setRetention(days: model.retentionDays, budgetGB: $0) })) {
                    ForEach([2, 5, 10, 20], id: \.self) { Text(verbatim: "\($0) GB").tag($0) }
                }
                Text("The newest 20 snapshots of every project and every pinned snapshot are always kept. Snapshots are APFS clones: unchanged data is shared with your files and takes almost no space.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Clean up now") { model.runRetention() }
                    Button("Show storage folder") { model.revealInFinder(model.paths.stores.path) }
                }
            }
            Section("General") {
                Toggle("Open Airbag at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Strict mode: block commands if Airbag's hook fails", isOn: Binding(get: { model.strictMode }, set: { model.setStrict($0) }))
            }
            Section("About") {
                Text(verbatim: AirbagVersion.line).font(Theme.monoSmall)
                Text("Airbag works entirely on this Mac: no account, no telemetry, no network. Snapshots and the activity log stay in ~/Library/Application Support/Airbag, readable only by you. Command output is never stored; secrets in command lines are masked.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("MIT License").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Settings"))
        .onAppear { model.refreshHooks() }
    }

    func stateText(_ s: HookInstaller.AgentStatus) -> LocalizedStringKey {
        if !s.detected && !s.installed { return "Not found on this Mac" }
        if !s.installed { return "Not protected" }
        if s.staleCommand { return "Installed, points at another Airbag copy — repair" }
        if !s.current { return "Installed, outdated — repair" }
        return "Protected"
    }
}
