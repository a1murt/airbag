import AirbagCore
import AppKit
import SwiftUI

struct RadarScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var showAll = false
    @State private var messages: [ProcessIdentity: String] = [:]
    @State private var triedStop: Set<ProcessIdentity> = []

    var rows: [RadarProcess] { showAll ? model.allListening : model.servers }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.servers.count) servers").font(.callout)
                if !model.orphans.isEmpty { Pill(text: "\(model.orphans.count) orphans", color: Theme.warning) }
                Spacer()
                Toggle("Show all listening processes", isOn: $showAll).toggleStyle(.checkbox)
                Button { model.scanRadar() } label: { Image(systemName: "arrow.clockwise") }.help(Text("Rescan")).accessibilityLabel(Text("Rescan"))
            }
            .padding(12)
            Divider()
            if rows.isEmpty {
                EmptyState(symbol: "dot.radiowaves.left.and.right", title: "No dev servers running",
                           message: "Servers your agents start appear here with the session that started them.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        ForEach(rows) { p in row(p); Divider() }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .navigationTitle(Text("Radar"))
    }

    var header: some View {
        HStack(spacing: 10) {
            Text("Port").frame(width: 90, alignment: .leading)
            Text("Process").frame(width: 150, alignment: .leading)
            Text("Project · agent session").frame(maxWidth: .infinity, alignment: .leading)
            Text("RAM").frame(width: 70, alignment: .trailing)
            Text("Uptime").frame(width: 70, alignment: .trailing)
            Text("Status").frame(width: 90, alignment: .leading)
            Text("").frame(width: 150)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }

    func row(_ p: RadarProcess) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: p.portsText).font(Theme.mono).frame(width: 90, alignment: .leading).lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: p.name).font(.callout.weight(.medium))
                Text(verbatim: "pid \(p.identity.pid)").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: projectName(p)).font(.callout).lineLimit(1)
                HStack(spacing: 4) {
                    if let a = p.attribution, a.agent != nil {
                        AgentBadge(agent: a.agent)
                        if let t = a.sessionTitle { Text(verbatim: "“\(t)”").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    } else {
                        Text("agent unknown").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .help(Text(attributionHelp(p)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: p.memoryText).font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
            Text(verbatim: p.uptimeText).font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
            status(p).frame(width: 90, alignment: .leading)
            HStack(spacing: 6) {
                if let why = p.protection {
                    Image(systemName: "lock.fill").foregroundStyle(.tertiary).help(Text(verbatim: why))
                        .accessibilityLabel(Text("Protected: \(why)"))
                } else {
                    Button("Stop") { Task { let m = await model.stopProcess(p, force: false); messages[p.identity] = m; triedStop.insert(p.identity) } }
                    if triedStop.contains(p.identity) && !(messages[p.identity] ?? "").isEmpty {
                        Button("Force stop") { Task { messages[p.identity] = await model.stopProcess(p, force: true) } }
                            .help(Text("Ends the process immediately; unsaved state in it is lost."))
                    }
                }
                Menu {
                    if let port = p.listeners.first?.port {
                        Button("Open http://localhost:\(port)") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
                    }
                    if let cwd = p.cwd { Button("Reveal folder") { model.revealInFinder(cwd) } }
                    Button("Copy pid") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(p.identity.pid)", forType: .string) }
                    if p.linkState == .orphan { Button("Keep running") { model.keep(p) } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(Text("More actions"))
            }
            .controlSize(.small)
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottomLeading) {
            if let m = messages[p.identity], !m.isEmpty { Text(verbatim: m).font(.caption2).foregroundStyle(Theme.danger).offset(y: 6) }
        }
    }

    func projectName(_ p: RadarProcess) -> String {
        if let root = p.attribution?.projectRoot { return (root as NSString).lastPathComponent }
        if let cwd = p.cwd, cwd != "/" { return (cwd as NSString).abbreviatingWithTildeInPath }
        return "—"
    }

    func attributionHelp(_ p: RadarProcess) -> String {
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

    @ViewBuilder func status(_ p: RadarProcess) -> some View {
        switch p.linkState {
        case .attached: Pill(text: "live", color: Theme.ok)
        case .detached: Pill(text: "live", color: Theme.ok).help(Text("Started by an earlier run of a session that is running again"))
        case .orphan: Pill(text: "orphan", color: Theme.warning)
        case .unknown: Pill(text: p.processClass == .system ? "system" : "unknown", color: .secondary)
        }
    }
}

struct GuardScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Commands Airbag blocked or asked about").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Strict mode", isOn: Binding(get: { model.strictMode }, set: { model.setStrict($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help(Text("If Airbag's hook crashes or times out, block the command (Claude Code 2.1.295+, Cursor)."))
            }
            .padding(12)
            Divider()
            if model.guardEntries.isEmpty {
                EmptyState(symbol: "exclamationmark.shield", title: "Nothing blocked so far",
                           message: "Destructive commands outside your project are blocked or need your approval. Inside the project, Airbag takes a snapshot instead.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.guardEntries) { g in card(g) }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle(Text("Guard"))
    }

    func card(_ g: GuardEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                decisionPill(g)
                Text(verbatim: RelativeTime.clock(ms: g.ts)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                AgentBadge(agent: g.agent)
                if let t = g.sessionTitle { Text(verbatim: "“\(t)”").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let root = g.projectRoot { Text(verbatim: (root as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(verbatim: g.ruleID).font(Theme.monoSmall).foregroundStyle(.tertiary)
            }
            CommandText(command: g.command, lines: expanded == g.id ? 6 : 1)
            if expanded == g.id {
                Text(verbatim: g.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Rule \(g.ruleID) enabled", isOn: Binding(get: { !model.disabledRules.contains(g.ruleID) }, set: { model.setRule(g.ruleID, enabled: $0) }))
                    .toggleStyle(.checkbox).font(.caption)
            }
            HStack {
                if g.canAllowOnce { Button("Allow once") { model.allowOnce(g) } }
                if g.resolution == nil { Button("Dismiss") { model.dismiss(g) } }
                if let r = g.resolution { Text(resolutionText(r)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(expanded == g.id ? "Less" : "Explain") { expanded = expanded == g.id ? nil : g.id }.buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    @ViewBuilder func decisionPill(_ g: GuardEntry) -> some View {
        switch g.decision {
        case "deny": Pill(text: "blocked", color: Theme.danger)
        case "deny_fallback": Pill(text: "needs approval", color: Theme.warning)
        case "ask": Pill(text: "asked", color: Theme.warning)
        case "allow_once": Pill(text: "allowed once", color: Theme.ok)
        case "allow_fallback": Pill(text: "allowed with snapshot", color: Theme.ok)
        default: Pill(text: LocalizedStringKey(g.decision), color: .secondary)
        }
    }

    func resolutionText(_ r: String) -> LocalizedStringKey {
        switch r {
        case "user_allowed": return "Allowed once — waiting for the agent to retry"
        case "token_used": return "Allowed once — used"
        case "user_denied": return "Dismissed"
        default: return LocalizedStringKey(r)
        }
    }
}
