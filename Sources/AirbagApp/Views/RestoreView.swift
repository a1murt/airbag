import AirbagCore
import AppKit
import SwiftUI

/// The restore confirmation is a separate window rather than a sheet (sheets in agent-style apps lost input on 14.0).
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
                Text(verbatim: r.command ?? r.title ?? "").font(Theme.mono).foregroundStyle(.secondary).lineLimit(2)
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
