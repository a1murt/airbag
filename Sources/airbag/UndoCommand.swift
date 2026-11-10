import AirbagCore
import Foundation

enum UndoCommand {
    static let usage = "usage: airbag undo [<snapshot-id>] [--root DIR] [--list] [--dry-run] [--json]"

    /// airbag undo — puts back what the newest change in this project did (the popover's top Undo), or the change of
    /// the given snapshot. Never deletes: files created since are moved aside, and the restore can itself be undone.
    static func undo(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: ["root", "limit"], flags: ["list", "dry-run", "json"])
        guard a.positionals.count <= 1 else { throw CLIError.usage(usage) }
        let root = SnapshotCommands.root(a)
        let missing = FileSystem.canonicalPath(root) == nil
        var store = try SnapshotStore.open(root: root, create: false, allowMissingRoot: missing)
        let registry = try? Registry(paths: .resolve(), role: .cli)
        let entries = registry?.timeline(store: store, limit: 80)
            ?? ((try? store.list(limit: 80)) ?? []).map { TimelineEntry(snapshot: $0, commands: []) }
        let changes = RecentChange.list(root: store.root, entries: entries)

        if a.has("list") {
            let rows = Array(changes.prefix(a.int("limit") ?? 10))
            if a.has("json") { Out.json(rows.map(describe)); return 0 }
            if rows.isEmpty { print("nothing to undo in \(store.root)") }
            for c in rows { print("\(c.snapshotID)  \(Out.date(c.at))  \(String(c.changedCount).leftPad(4)) changed  \(title(c))") }
            return 0
        }

        let change: RecentChange?
        let plan: UndoPlan
        if let id = a.positionals.first {
            let matches = changes.filter { $0.snapshotID == id || $0.snapshotID.hasPrefix(id) }
            guard matches.count <= 1 else { throw CLIError.failed("\(id) matches \(matches.count) changes; give more of the id") }
            change = matches.first
            plan = try change?.undoPlan(in: store) ?? UndoPlan.moment(id, in: store)
        } else {
            guard let newest = changes.first else {
                if a.has("json") { Out.json(["undone": NSNull(), "restored": [String]()]) } else { print("nothing to undo in \(store.root)") }
                return 0
            }
            change = newest
            plan = try newest.undoPlan(in: store)
        }
        let what = change.map(title) ?? "snapshot \(a.positionals.first ?? "")"

        if a.has("dry-run") {
            let p = try store.planRestore(to: plan.target, scope: plan.scope)
            if a.has("json") {
                Out.json(["wouldUndo": change.map(describe) ?? [:], "restore": p.write, "moveAside": p.moveAside])
                return 0
            }
            print("would undo \(what): \(p.write.count) file(s) put back, \(p.moveAside.count) moved aside")
            list(p.write, prefix: "  ")
            list(p.moveAside, prefix: "  aside: ")
            return 0
        }

        // A deleted project folder is recreated only now, when files are about to come back.
        if missing { store = try SnapshotStore.open(root: root, create: false, recreateMissingRoot: true) }
        let report = try store.restore(to: plan.target, scope: plan.scope)
        WakeSocket.notify(paths: .resolve(), message: ["op": "snapshot", "root": store.root])
        if a.has("json") {
            var out: [String: Any] = ["undone": change.map(describe) ?? ["snapshot": a.positionals.first ?? ""], "restored": report.restored,
                                      "movedAside": report.movedAside, "conflicts": report.conflicts, "failed": report.failed]
            if let u = report.undoSnapshotId { out["undoSnapshot"] = u }
            Out.json(out)
            return report.failed.isEmpty ? 0 : 1
        }
        if report.restored.isEmpty && report.movedAside.isEmpty && report.conflicts.isEmpty && report.failed.isEmpty {
            print("nothing to put back: the files are already as they were before \(what)")
            return 0
        }
        print("undid \(what): \(report.restored.count) file(s) put back, \(report.movedAside.count) moved aside, conflicts \(report.conflicts.count), failed \(report.failed.count)")
        list(report.restored, prefix: "  ")
        for c in report.conflicts { print("  conflict (changed during the undo, left untouched): \(c)") }
        for f in report.failed { print("  failed: \(f)") }
        if let aside = report.asideDirectory { print("moved-aside items: \(aside)") }
        if let undo = report.undoSnapshotId { print("undo this with: airbag restore \(undo) --root \"\(store.root)\"") }
        return report.failed.isEmpty ? 0 : 1
    }

    /// "`rm -rf src/legacy` (Claude Code, 2026-11-10 12:01:07)" or "file changes of 2026-11-10 12:01:07".
    static func title(_ c: RecentChange) -> String {
        guard let command = c.command else { return "file changes of \(Out.date(c.at))" }
        let short = command.count > 80 ? String(command.prefix(80)) + "…" : command
        return "`\(short)` (\([c.agent?.displayName, Out.date(c.at)].compactMap { $0 }.joined(separator: ", ")))"
    }

    static func describe(_ c: RecentChange) -> [String: Any] {
        var d: [String: Any] = ["snapshot": c.snapshotID, "at": c.at, "changed": c.changedCount, "trigger": c.trigger.rawValue]
        if let command = c.command { d["command"] = command }
        if let agent = c.agent { d["agent"] = agent.rawValue }
        if let session = c.sessionTitle { d["session"] = session }
        if let base = c.base { d["base"] = base }
        return d
    }

    static func list(_ paths: [String], prefix: String, limit: Int = 20) {
        for p in paths.prefix(limit) { print(prefix + p) }
        if paths.count > limit { print("\(prefix)… and \(paths.count - limit) more") }
    }
}
