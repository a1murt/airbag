import Foundation
import Testing
@testable import AirbagCore

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

@Suite(.serialized) struct AppServicesTests {
    @Test func fileWatcherSettlesOnSourceChangesOnly() async throws {
        let sb = Sandbox("watch"); defer { sb.cleanup() }
        sb.write("src/a.ts", "a")
        let fired = Box<[[String]]>([])
        let q = DispatchQueue(label: "test.watch")
        let w = FileWatcher(roots: [sb.root], quietSeconds: 0.5, maxSeconds: 5, queue: q) { _, paths in fired.with { $0.append(paths) } }
        w.start()
        defer { q.sync { w.stop() } }
        // Writes inside an excluded folder never trigger, whatever the timing of earlier events.
        sb.write("node_modules/x/index.js", "ignored")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(!fired.with { $0 }.flatMap { $0 }.contains { $0.hasPrefix("node_modules") })
        sb.write("src/a.ts", "changed")
        for _ in 0..<60 where !fired.with({ $0 }).flatMap({ $0 }).contains("src/a.ts") { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(fired.with { $0 }.flatMap { $0 }.contains("src/a.ts"))
    }

    @Test func pauseKeepsBlocksButSkipsSnapshots() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        try h.registry().pause(untilMs: Clock.nowMsInt() + 60_000)
        let allowed = h.run(.claudeCode, h.claudePre("rm -rf src"))
        #expect(allowed.finalDecision == "allow" && allowed.snapshot == nil)
        #expect(allowed.record?.snapshotSkipped == "paused")
        let blocked = h.run(.claudeCode, h.claudePre("rm -rf ~"))
        #expect(blocked.finalDecision == "deny")
        try h.registry().pause(untilMs: nil)
        #expect(h.registry().pausedUntilMs == nil)
    }

    @Test func timelineLinksSnapshotsToCommands() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        _ = h.run(.claudeCode, h.claudePre("rm -rf src/legacy", id: "t-1"))
        sh("rm -rf src/legacy", cwd: h.root)
        var post = h.claudePre("rm -rf src/legacy", id: "t-1")
        post["hook_event_name"] = "PostToolUse"
        _ = h.run(.claudeCode, post)
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        let tl = h.registry().timeline(store: store)
        #expect(tl.count >= 2)
        #expect(tl.first?.snapshot.trigger == .postCommand)
        #expect(tl.first?.commands.first?.command == "rm -rf src/legacy")
        #expect(tl.contains { $0.commands.contains { $0.kind == "pre_shell" } })
        _ = h.run(.claudeCode, h.claudePre("git push --force", id: "t-2"))
        let g = h.registry().guardEntries()
        #expect(g.first?.ruleID == "git.push.force")
        #expect(g.first?.agent == .claudeCode)
    }

    @Test func evidenceAndCountsForTheUI() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let start = Clock.nowMsInt() - 1
        _ = h.run(.claudeCode, h.claudePre("ls", id: "e-1"))
        _ = h.run(.claudeCode, h.claudePre("git push --force", id: "e-2"))
        let reg = try h.registry()
        // The hook leaves evidence per agent (the app shows "last command 2 min ago" instead of trusting config files).
        #expect((reg.lastHookEvents()[.claudeCode] ?? 0) >= start)
        #expect(reg.lastHookEvents()[.codex] == nil)
        #expect(reg.commandCounts(since: start).checked >= 2)
        #expect(reg.commandCounts(since: start).unprotected == 0)
        try reg.pause(untilMs: Clock.nowMsInt() + 60_000)
        _ = h.run(.claudeCode, h.claudePre("touch a", id: "e-3"))
        #expect(reg.commandCounts(since: start).unprotected == 1)
        try reg.pause(untilMs: nil)
        // A guard entry points at the snapshot taken right before its command, when there was one.
        let g = reg.guardEntries().first { $0.ruleID == "git.push.force" }
        #expect(g != nil)
        if let sid = g?.snapshotID { #expect(try SnapshotStore.open(root: h.root, paths: h.paths).info(sid) != nil) }
    }

    @Test func searchFindsSnapshotsByFilePath() throws {
        let sb = Sandbox("touch"); defer { sb.cleanup() }
        let store = try sb.store()
        sb.write("src/legacy/cart.ts", "a")
        sb.write("src/app.ts", "a")
        _ = store.snapshot(SnapshotRequest(trigger: .manual))
        sb.write("src/legacy/cart.ts", "b")
        guard case .created(let second, _) = store.snapshot(SnapshotRequest(trigger: .manual)) else { Issue.record("no snapshot"); return }
        try FileManager.default.removeItem(atPath: sb.root + "/src/legacy/cart.ts")
        guard case .created(let third, _) = store.snapshot(SnapshotRequest(trigger: .manual)) else { Issue.record("no snapshot"); return }
        let hits = try store.snapshotIDs(touchingPathContaining: "CART")
        #expect(hits.contains(second.id) && hits.contains(third.id))
        #expect(try store.snapshotIDs(touchingPathContaining: "app.ts").count == 1)
        #expect(try store.snapshotIDs(touchingPathContaining: "%").isEmpty) // LIKE wildcards are literal
    }

    @Test func stopProtectingSkipsSnapshotsButKeepsRules() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        _ = h.run(.claudeCode, h.claudePre("touch a", id: "i-1"))
        #expect(SnapshotStore.storeExists(root: h.root, paths: h.paths))
        try IgnoredRoots.set(h.root, ignored: true, paths: h.paths)
        try SnapshotStore.removeStore(root: h.root, paths: h.paths)
        #expect(!SnapshotStore.storeExists(root: h.root, paths: h.paths))
        let after = h.run(.claudeCode, h.claudePre("rm -rf src", id: "i-2"))
        #expect(after.snapshot == nil && after.record?.snapshotSkipped == "not_protected")
        #expect(after.finalDecision == "allow") // no snapshot wanted here, so none is waited for
        #expect(!SnapshotStore.storeExists(root: h.root, paths: h.paths))
        // Guard rules still treat the folder as the project.
        #expect(h.run(.claudeCode, h.claudePre("rm -rf ~", id: "i-3")).finalDecision == "deny")
        try IgnoredRoots.set(h.root, ignored: false, paths: h.paths)
        _ = h.run(.claudeCode, h.claudePre("touch b", id: "i-4"))
        #expect(SnapshotStore.storeExists(root: h.root, paths: h.paths))
    }

    @Test func globalRetentionHonoursBudget() throws {
        let sb = Sandbox("ret"); defer { sb.cleanup() }
        let store = try sb.store()
        for i in 0..<30 {
            sb.write("big.bin", String(repeating: Character(UnicodeScalar(65 + i % 26)!), count: 200_000))
            _ = store.snapshot(SnapshotRequest(trigger: .manual))
        }
        let before = try store.usage().objectBytes
        #expect(before == 26 * 200_000) // 26 distinct contents; repeats are deduplicated
        Retention.run(paths: sb.paths, policy: RetentionPolicy(maxAgeDays: 7, keepNewest: 5), globalBudgetBytes: 2_000_000)
        let after = try store.usage()
        #expect(after.objectBytes <= 2_000_000, "\(after.objectBytes)")
        #expect(after.snapshots >= 5)
    }
}
