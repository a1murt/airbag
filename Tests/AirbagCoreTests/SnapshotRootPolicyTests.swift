import Foundation
import Testing
@testable import AirbagCore

/// Which folders become snapshot roots, how large a non-project folder may be, and how many snapshots a root keeps
/// (ADR-032). Regressions from a read-only diagnostics session on 2026-10-21 that cloned ~/Library/Caches, an app
/// bundle and ~/.ssh.
@Suite struct SnapshotRootPolicyTests {
    let home = "/Users/u"

    @Test(arguments: ["/Users/u", "/Users/u/Library", "/Users/u/Library/Caches", "/Users/u/Library/Caches/CloudKit",
                      "/Users/u/Library/Containers/com.apple.Safari/Data", "/Users/u/Library/Group Containers/group.x",
                      "/Users/u/Library/Safari", "/Users/u/Library/Logs/DiagnosticReports", "/Users/u/Library/Application Support",
                      "/Users/u/Library/Application Support/AddressBook/Sources", "/Users/u/.ssh", "/Users/u/.ssh/keys",
                      "/Users/u/.gnupg", "/Users/u/.aws", "/Users/u/.Trash/old", "/Users/u/Applications/Tool.app",
                      "/Applications/Safari.app", "/Applications/SafeConnect.app/Contents/MacOS", "/Library/Logs/DiagnosticReports",
                      "/private/var/folders", "/private/var/folders/j7/abc/T", "/private/var/folders/j7/abc/T/tmp.123",
                      "/Users/u/Desktop", "/Users/u/Documents", "/Users/u/Downloads", "/usr/local/src/x", "/opt/homebrew/Library/Taps/a/b"])
    func neverAProject(_ path: String) {
        #expect(SnapshotStore.isSystemOrHomeFolder(path, home: home))
    }

    @Test(arguments: ["/Users/u/Work/app", "/Users/u/Documents/thesis", "/Users/u/Downloads/zhurekai", "/Users/u/Desktop/demo",
                      "/Users/u/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
                      "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/site", "/Users/u/Library/CloudStorage/Dropbox/app",
                      "/Users/u/.config/nvim", "/private/tmp/claude-501/sidebar-test", "/Volumes/External/project", "/opt/project"])
    func projectsBelowStandardFolders(_ path: String) {
        #expect(!SnapshotStore.isSystemOrHomeFolder(path, home: home))
    }

    @Test func realDeniedFoldersAreRefused() {
        let sb = Sandbox(); defer { sb.cleanup() }
        let tmp = FileSystem.canonicalPath(NSTemporaryDirectory())!
        for p in [tmp, NSHomeDirectory() + "/Library/Caches", "/Library/Logs", "/Applications/Utilities", "/usr/bin"]
        where FileManager.default.fileExists(atPath: p) {
            #expect(throws: SnapshotError.self, "\(p)") { _ = try SnapshotStore.validateRoot(p, paths: sb.paths) }
        }
    }

    @Test func gitCheckoutInsideADeniedTreeIsNotAProject() throws {
        let tmp = TempDir("policy"); defer { tmp.cleanup() }
        let fakeHome = tmp.sub("home")
        try FileManager.default.createDirectory(atPath: fakeHome + "/.ssh/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fakeHome + "/.ssh/sub", withIntermediateDirectories: true)
        let root = RootResolver.resolve(cwd: fakeHome + "/.ssh/sub", home: fakeHome)
        #expect(root == fakeHome + "/.ssh/sub") // the .git above is not taken
        #expect(SnapshotStore.isSystemOrHomeFolder(root, home: fakeHome))
    }
}

@Suite struct SnapshotLimitsTests {
    func fill(_ sb: Sandbox, files: Int, bytes: Int = 10) {
        for i in 0..<files { sb.write("f\(i).txt", String(repeating: "x", count: bytes)) }
    }

    @Test func boundedWalkDetectsLargeFolders() {
        let sb = Sandbox("limits"); defer { sb.cleanup() }
        fill(sb, files: 12)
        #expect(SnapshotStore.exceeds(SnapshotLimits(maxFiles: 10, maxBytes: 1 << 30), root: sb.root))
        #expect(!SnapshotStore.exceeds(SnapshotLimits(maxFiles: 12, maxBytes: 1 << 30), root: sb.root))
        sb.write("big.bin", String(repeating: "y", count: 4_000))
        #expect(SnapshotStore.exceeds(SnapshotLimits(maxFiles: 100, maxBytes: 3_000), root: sb.root))
    }

    @Test func cappedStoreCapturesNothingWhenOverItsLimits() throws {
        let sb = Sandbox("limits"); defer { sb.cleanup() }
        fill(sb, files: 5)
        let limits = SnapshotLimits(maxFiles: 8, maxBytes: 1 << 30)
        let store = try SnapshotStore.open(root: sb.root, paths: sb.paths, limits: limits)
        _ = created(store.snapshot(SnapshotRequest(trigger: .initial)))
        // The cap is stored with the store: a later opener (the app, a background snapshot) honours it without being told.
        let reopened = try SnapshotStore.open(root: sb.root, paths: sb.paths)
        #expect(reopened.limits == limits)
        fill(sb, files: 9)
        guard case .tooLarge = reopened.snapshot(SnapshotRequest(trigger: .manual)) else { Issue.record("expected tooLarge"); return }
        #expect(try reopened.list().count == 1)
        // A restore still takes its undo snapshot, cap or not.
        let first = try #require(try reopened.list().last)
        let report = try reopened.restore(to: first.id, scope: .root)
        #expect(report.undoSnapshotId != nil)
        // Once the folder is a git checkout it is a project: no cap.
        try FileManager.default.createDirectory(atPath: sb.root + "/.git", withIntermediateDirectories: true)
        sb.write("g.txt", "g")
        _ = created(reopened.snapshot(SnapshotRequest(trigger: .manual)))
        // Removing the cap is stored too.
        try reopened.setLimits(nil)
        #expect(try SnapshotStore.open(root: sb.root, paths: sb.paths).limits == nil)
    }

    @Test func uncappedStoresAreUnchanged() throws {
        let sb = Sandbox("limits"); defer { sb.cleanup() }
        fill(sb, files: 30)
        let store = try sb.store()
        #expect(store.limits == nil)
        _ = created(store.snapshot(SnapshotRequest(trigger: .initial)))
    }
}

@Suite struct RetentionCapTests {
    @Test func atMostMaxSnapshotsPerRootHoweverRecent() throws {
        let sb = Sandbox("ret"); defer { sb.cleanup() }
        let store = try sb.store()
        var snaps: [SnapshotInfo] = []
        for i in 0..<30 {
            sb.write("a.txt", "v\(i)")
            snaps.append(created(store.snapshot(SnapshotRequest(trigger: .manual))))
        }
        try store.pin(snaps[2].id)
        _ = try store.prune(policy: RetentionPolicy(maxAgeDays: 7, keepNewest: 5, maxSnapshots: 10))
        let kept = try store.list(limit: 100)
        #expect(kept.count == 11) // the 10 newest and the pinned one
        #expect(kept.contains { $0.id == snaps[2].id })
        #expect(kept.first?.id == snaps.last?.id)
        // Every kept snapshot still restores.
        for s in kept { #expect(try store.state(atSeq: s.seq)["a.txt"] != nil) }
    }

    @Test func oldSnapshotsGoDownToKeepNewest() throws {
        let sb = Sandbox("ret"); defer { sb.cleanup() }
        let store = try sb.store()
        for i in 0..<12 {
            sb.write("a.txt", "v\(i)")
            _ = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        }
        _ = try store.prune(policy: RetentionPolicy(maxAgeDays: 7, keepNewest: 3), nowMs: Clock.nowMsInt() + 8 * 86_400_000)
        #expect(try store.list(limit: 100).count == 3)
    }
}

@Suite(.serialized) struct HookSnapshotRootTests {
    func plainFolder(_ h: HookSandbox, files: Int) -> String {
        let dir = h.sb.tmp.sub("plain")
        for i in 0..<files { h.sb.tmp.write("plain/f\(i).txt", "x") }
        return FileSystem.canonicalPath(dir)!
    }

    func pre(_ command: String, cwd: String) -> [String: Any] {
        ["session_id": "sess-roots", "cwd": cwd, "permission_mode": "default", "hook_event_name": "PreToolUse",
         "tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": ULID.make()]
    }

    func run(_ h: HookSandbox, _ payload: [String: Any], env: [String: String] = [:], limits: SnapshotLimits = .folder) -> HookOutcome {
        var c = HookBridgeConfig(paths: h.paths, environment: env)
        c.spawnBackground = false
        c.home = h.userHome
        c.folderLimits = limits
        return HookBridge(config: c).handle(payload: try! JSONSerialization.data(withJSONObject: payload), declared: .claudeCode, eventHint: nil)
    }

    @Test func readOnlyCommandsTakeNoSnapshot() {
        let h = HookSandbox(); defer { h.cleanup() }
        for cmd in ["du -sh . && ls -la && stat -f %z package.json", "cat package.json | grep name; ps -ax | head -3",
                    "sqlite3 -readonly x.db 'SELECT 1'", "csrutil status; fdesetup status; nvram -p"] {
            let out = run(h, pre(cmd, cwd: h.root))
            #expect(out.finalDecision == "allow", "\(cmd)")
            #expect(out.snapshot == nil && out.snapshotSkipped == nil, "\(cmd)")
        }
        #expect(!SnapshotStore.storeExists(root: h.root, paths: h.paths))
    }

    @Test func deniedFoldersNeverGetAStore() {
        let h = HookSandbox(); defer { h.cleanup() }
        let tmp = FileSystem.canonicalPath(NSTemporaryDirectory())!
        // The session's cwd is a per-user temporary folder, and the command `cd`s into another denied tree.
        let out = run(h, pre("cd /Library/Logs && mkdir -p probe", cwd: tmp))
        #expect(out.snapshot == nil)
        #expect(out.snapshotSkipped == "no_root")
        #expect(SnapshotStore.allStores(paths: h.paths).isEmpty)
    }

    @Test func largeNonProjectFolderIsNotSnapshotted() {
        let h = HookSandbox(); defer { h.cleanup() }
        let dir = plainFolder(h, files: 30)
        let limits = SnapshotLimits(maxFiles: 10, maxBytes: 1 << 30)
        let out = run(h, pre("touch new.txt", cwd: dir), limits: limits)
        #expect(out.snapshotSkipped == "too_large")
        #expect(!SnapshotStore.storeExists(root: dir, paths: h.paths))
        // A destructive command there cannot be undone, so it is not allowed silently.
        let rm = run(h, pre("rm -rf f1.txt", cwd: dir), limits: limits)
        #expect(rm.finalDecision != "allow")
        // The same folder as the agent's own launch folder is a project: snapshotted whatever its size.
        let own = run(h, pre("touch new.txt", cwd: dir), env: ["CLAUDE_PROJECT_DIR": dir], limits: limits)
        #expect(own.snapshot != nil)
        #expect(try! SnapshotStore.open(root: dir, paths: h.paths).limits == nil)
    }

    @Test func smallNonProjectFolderGetsACappedStore() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let dir = plainFolder(h, files: 3)
        let limits = SnapshotLimits(maxFiles: 10, maxBytes: 1 << 30)
        let out = run(h, pre("touch new.txt", cwd: dir), limits: limits)
        #expect(out.snapshot != nil)
        #expect(try SnapshotStore.open(root: dir, paths: h.paths).limits == limits)
        // A git checkout the command `cd`s into is a project: no cap even when large.
        _ = sh("git init -q", cwd: h.root)
        let visited = run(h, pre("cd \(h.root) && touch x", cwd: dir), limits: SnapshotLimits(maxFiles: 1, maxBytes: 1 << 30))
        #expect(visited.snapshot != nil)
        #expect(try SnapshotStore.open(root: h.root, paths: h.paths).limits == nil)
    }
}
