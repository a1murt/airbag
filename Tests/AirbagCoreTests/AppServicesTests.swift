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
        let fired = Box<[String]>([])
        let q = DispatchQueue(label: "test.watch")
        let w = FileWatcher(roots: [sb.root], quietSeconds: 0.5, maxSeconds: 5, queue: q) { root in fired.with { $0.append(root) } }
        w.start()
        defer { q.sync { w.stop() } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        fired.with { $0.removeAll() } // events from writes just before the stream started may still arrive
        sb.write("node_modules/x/index.js", "ignored")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(fired.with { $0 }.isEmpty, "changes inside node_modules must not trigger a snapshot")
        sb.write("src/a.ts", "changed")
        for _ in 0..<40 where fired.with({ $0 }).isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(fired.with { $0 } == [sb.root])
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
