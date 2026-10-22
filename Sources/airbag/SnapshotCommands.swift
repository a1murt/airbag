import AirbagCore
import Foundation

enum SnapshotCommands {
    static let valueOptions: Set<String> = ["root", "label", "trigger", "limit", "path", "keep", "days", "max", "session", "background-marker"]

    static func root(_ a: Args) -> String { a.value("root") ?? RootResolver.resolve(cwd: FileManager.default.currentDirectoryPath) }

    static func openStore(_ a: Args, recreate: Bool = false, limits: SnapshotLimits? = nil) throws -> SnapshotStore {
        try SnapshotStore.open(root: root(a), recreateMissingRoot: recreate, limits: limits)
    }

    static func snapshot(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        if let marker = a.value("background-marker") {
            try? FileSystem.writeAtomically(Data("\(getpid())".utf8), to: marker, mode: 0o600)
            atexit_b { unlink(marker) }
        }
        // --capped: a folder that is not a project gets a store only while it is small (the hook passes it, ADR-032).
        let limits: SnapshotLimits? = a.has("capped") ? .folder : nil
        if let limits, !SnapshotStore.storeExists(root: root(a)), SnapshotStore.exceeds(limits, root: root(a)) {
            print("not snapshotted: \(root(a)) is over the size cap for a folder that is not a project (\(limits.maxFiles) files or \(Out.bytes(limits.maxBytes)))")
            return 0
        }
        let store = try openStore(a, limits: limits)
        let trigger = a.has("initial") ? .initial : (a.value("trigger").flatMap(SnapshotTrigger.init(rawValue:)) ?? .manual)
        let outcome = store.snapshot(SnapshotRequest(trigger: trigger, label: a.value("label"), sessionKey: a.value("session"),
                                                     lockWaitMs: 10_000, force: a.has("force")))
        if case .created = outcome { WakeSocket.notify(paths: .resolve(), message: ["op": "snapshot", "root": store.root]) }
        switch outcome {
        case .created(let s, let stats):
            if a.has("json") { Out.encodable(["snapshot": AnyEncodable(s), "stats": AnyEncodable(stats)]) } else {
                print("snapshot \(s.id) · \(s.changedCount) changed · \(s.fileCount) files · +\(Out.bytes(s.bytesAdded)) · \(stats.durationMs) ms\(s.complete ? "" : " · INCOMPLETE")")
            }
            return 0
        case .unchanged(let latest, let stats):
            if a.has("json") { Out.encodable(["unchanged": AnyEncodable(latest?.id ?? ""), "stats": AnyEncodable(stats)]) } else {
                print("no changes since \(latest?.id ?? "—") (\(stats.walked) files checked in \(stats.durationMs) ms)")
            }
            return 0
        case .busy: throw CLIError.failed("store is busy")
        case .lowDisk(let avail): throw CLIError.failed("not enough free disk space (\(Out.bytes(avail)) available)")
        case .tooLarge:
            let l = store.limits ?? .folder
            throw CLIError.failed("\(store.root) has outgrown the size cap of its store (\(l.maxFiles) files or \(Out.bytes(l.maxBytes))); nothing captured")
        case .failed(let m): throw CLIError.failed(m)
        }
    }

    static func list(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        let store = try openStore(a)
        let items = try store.list(limit: a.int("limit") ?? 30)
        if a.has("json") { Out.encodable(items); return 0 }
        print("root \(store.root)")
        for s in items {
            let pin = s.pinned ? " 📌" : ""
            print("\(s.id)  \(Out.date(s.createdAt))  \(s.trigger.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(s.changedCount).leftPad(5)) changed  \(s.label ?? "")\(pin)")
        }
        return 0
    }

    static func changes(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        guard let id = a.positionals.first else { throw CLIError.usage("usage: airbag changes <snapshot-id>") }
        let store = try openStore(a)
        let list = try store.changes(in: id)
        if a.has("json") { Out.encodable(list); return 0 }
        for c in list { print("\(symbol(c.status)) \(c.path)") }
        return 0
    }

    static func diff(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        guard let from = a.positionals.first else { throw CLIError.usage("usage: airbag diff <from-id> [<to-id>] [--path FILE]") }
        let to = a.positionals.dropFirst().first
        let store = try openStore(a)
        if let path = a.value("path") {
            let d = try store.fileDiff(path: path, from: from, to: to)
            print("--- \(path) @ \(from)\n+++ \(path) @ \(to ?? "working tree")")
            print(d.unified, terminator: "")
            return 0
        }
        let list = try store.diff(from: from, to: to)
        if a.has("json") { Out.encodable(list); return 0 }
        for c in list { print("\(symbol(c.status)) \(c.path)") }
        return 0
    }

    static func restore(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        guard let id = a.positionals.first else { throw CLIError.usage("usage: airbag restore <snapshot-id> [--path P ...]") }
        let store = try openStore(a, recreate: true)
        let paths = a.values("path").map { p -> String in
            // Accept absolute paths inside the root as well as root-relative ones.
            let abs = FileSystem.resolvedPath(p)
            return abs.hasPrefix(store.root + "/") ? String(abs.dropFirst(store.root.count + 1)) : p
        }
        let report = try store.restore(to: id, scope: paths.isEmpty ? .root : .paths(paths))
        if a.has("json") { Out.encodable(report); return report.failed.isEmpty ? 0 : 1 }
        print("restored \(report.restored.count) file(s), moved aside \(report.movedAside.count), conflicts \(report.conflicts.count), failed \(report.failed.count)")
        for c in report.conflicts { print("  conflict (changed during restore, left untouched): \(c)") }
        for f in report.failed { print("  failed: \(f)") }
        if let aside = report.asideDirectory { print("moved-aside items: \(aside)") }
        if let undo = report.undoSnapshotId { print("undo with: airbag restore \(undo) --root \"\(store.root)\"") }
        return report.failed.isEmpty ? 0 : 1
    }

    static func pin(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        guard let id = a.positionals.first else { throw CLIError.usage("usage: airbag pin <snapshot-id> [--off]") }
        try openStore(a).pin(id, !a.has("off"))
        return 0
    }

    static func prune(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        let policy = RetentionPolicy(maxAgeDays: a.int("days") ?? 7, keepNewest: a.int("keep") ?? 20, maxSnapshots: a.int("max") ?? 200)
        let stores: [SnapshotStore]
        if a.has("all") {
            stores = SnapshotStore.allStores().filter(\.rootExists).compactMap { try? SnapshotStore.open(root: $0.root, create: false) }
        } else {
            stores = [try openStore(a)]
        }
        var total = PruneReport()
        let registry = try? Registry(paths: .resolve(), role: .cli)
        for s in stores {
            let r = try s.prune(policy: policy, dryRun: a.has("dry-run"))
            total.deletedSnapshots += r.deletedSnapshots; total.deletedObjects += r.deletedObjects; total.freedBytes += r.freedBytes
            if !a.has("dry-run") { registry?.reconcileSnapshots(rootID: s.rootID, existing: Set(((try? s.list(limit: 100_000)) ?? []).map(\.id))) }
        }
        if a.has("json") { Out.encodable(total); return 0 }
        print("\(a.has("dry-run") ? "would delete" : "deleted") \(total.deletedSnapshots) snapshot(s), \(total.deletedObjects) object(s), freed \(Out.bytes(total.freedBytes))")
        return 0
    }

    static func export(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        guard a.positionals.count == 2 else { throw CLIError.usage("usage: airbag export <snapshot-id> <dest-dir> [--path P ...]") }
        let dest = FileSystem.resolvedPath(a.positionals[1])
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dest), !items.isEmpty {
            throw CLIError.failed("\(dest) is not empty")
        }
        let n = try openStore(a).export(a.positionals[0], to: dest, prefixes: a.values("path"))
        print("exported \(n) file(s) to \(dest)")
        return 0
    }

    static func usage(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: valueOptions)
        var rows: [[String: Any]] = []
        for loc in SnapshotStore.allStores() {
            var refused = false
            if loc.rootExists { do { _ = try SnapshotStore.validateRoot(loc.root) } catch SnapshotError.unsafeRoot { refused = true } catch {} }
            if refused {
                // Made before the folder was refused (ADR-032): never opened, snapshotted or pruned again.
                rows.append(["root": loc.root, "rootExists": true, "refused": true, "store": loc.directory]); continue
            }
            guard loc.rootExists, let s = try? SnapshotStore.open(root: loc.root, create: false), let u = try? s.usage() else {
                rows.append(["root": loc.root, "rootExists": loc.rootExists]); continue
            }
            rows.append(["root": loc.root, "rootExists": true, "snapshots": u.snapshots, "objects": u.objects,
                         "objectBytes": u.objectBytes, "trackedFiles": u.trackedFiles])
        }
        if a.has("json") { Out.json(rows); return 0 }
        for r in rows {
            let root = r["root"] as? String ?? "?"
            if r["rootExists"] as? Bool == false { print("\(root)  (folder missing — restorable with `airbag restore <id> --root \"\(root)\"`)"); continue }
            if r["refused"] as? Bool == true { print("\(root)  (not a project folder; Airbag no longer snapshots it — its store can be deleted: \(r["store"] ?? ""))"); continue }
            print("\(root)  \(r["snapshots"] ?? 0) snapshots · \(r["trackedFiles"] ?? 0) files · \(Out.bytes(r["objectBytes"] as? Int64 ?? 0))")
        }
        return 0
    }

    static func symbol(_ s: ChangeStatus) -> String {
        switch s {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .typeChanged: return "T"
        }
    }
}

struct AnyEncodable: Encodable {
    let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { encodeFn = v.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
