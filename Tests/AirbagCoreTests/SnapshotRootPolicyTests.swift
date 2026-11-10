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
                      "/Users/u/Desktop", "/Users/u/Documents", "/Users/u/Downloads", "/usr/local/src/x", "/opt/homebrew/Library/Taps/a/b",
                      // Claude Code's temporary folder and its per-project, per-session and per-purpose folders (ADR-036).
                      "/private/tmp/claude-501", "/private/tmp/claude-501/-Users-u-Work-app",
                      "/private/tmp/claude-501/-Users-u-Work-app/3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b",
                      "/private/tmp/claude-501/-Users-u-Work-app/3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b/scratchpad",
                      "/private/tmp/claude-501/-Users-u-Work-app/3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b/tasks",
                      "/private/tmp/claude-501/bundled-skills/3f2a/9c1e/dataviz"])
    func neverAProject(_ path: String) {
        #expect(SnapshotStore.isSystemOrHomeFolder(path, home: home))
    }

    @Test(arguments: ["/Users/u/Work/app", "/Users/u/Documents/thesis", "/Users/u/Downloads/zhurekai", "/Users/u/Desktop/demo",
                      "/Users/u/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
                      "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/site", "/Users/u/Library/CloudStorage/Dropbox/app",
                      "/Users/u/.config/nvim", "/private/tmp/claude-501/sidebar-test", "/Volumes/External/project", "/opt/project",
                      "/private/tmp/claude-501/-Users-u-Work-app/3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b/scratchpad/repo",
                      "/private/tmp/claudette/app", "/private/tmp/claude-x/app"])
    func projectsBelowStandardFolders(_ path: String) {
        #expect(!SnapshotStore.isSystemOrHomeFolder(path, home: home))
    }

    /// A refused folder's old store is not opened, listed or pruned once the folder is gone (macOS empties /tmp on restart).
    @Test func refusedFolderStaysRefusedWhenItIsGone() {
        let sb = Sandbox(); defer { sb.cleanup() }
        let gone = "/private/tmp/claude-\(getuid())/-Users-u-Work-app/\(ULID.make())"
        do {
            _ = try SnapshotStore.open(root: gone, paths: sb.paths, create: false, allowMissingRoot: true)
            Issue.record("opened a store for \(gone)")
        } catch SnapshotError.unsafeRoot {
        } catch { Issue.record("\(error)") }
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

/// Stores that outlive their folder (ADR-040): kept for a grace period, then deleted by retention.
@Suite(.serialized) struct StoreCleanupTests {
    let day: Int64 = 86_400_000
    let t0: Int64 = 1_800_000_000_000

    /// A sandbox with one snapshot, and the location of its store.
    func seeded(_ label: String) throws -> (Sandbox, StoreLocation) {
        let sb = Sandbox(label)
        sb.write("a.txt", "v1")
        _ = try sb.store().snapshot(SnapshotRequest(trigger: .manual))
        return (sb, try #require(SnapshotStore.allStores(paths: sb.paths).first))
    }

    /// Makes a store belong to another folder, as if it had been made for it.
    func retarget(_ loc: StoreLocation, to root: String) throws {
        var meta = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: loc.directory + "/store.json"))) as? [String: Any])
        meta["root"] = root
        try JSONSerialization.data(withJSONObject: meta).write(to: URL(fileURLWithPath: loc.directory + "/store.json"))
    }

    @Test func whereFoldersComeAndGo() {
        let home = "/Users/u"
        for p in ["/private/tmp/claude-501/x/scratchpad/repo", "/tmp/build", "/private/var/folders/ab/T/x",
                  "/Users/u/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
                  "/Users/u/Work/app/.claude/worktrees/agent-1", "/Users/u/.codex/worktrees/3f9a/app/.codex/worktrees/x"] {
            #expect(StoreCleanup.isEphemeral(p, home: home), "\(p)")
        }
        for p in ["/Users/u/Work/app", "/Users/u/Documents/thesis", "/Volumes/External/project", "/Users/u/Work/tmp/app"] {
            #expect(!StoreCleanup.isEphemeral(p, home: home), "\(p)")
        }
    }

    @Test func aStoreOutlivesATemporaryFolderByThreeDays() throws {
        let (sb, _) = try seeded("gone"); defer { sb.cleanup() }
        // While the folder exists nothing is noted or deleted.
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0).stores == 0)
        #expect(StoreCleanup.candidates(paths: sb.paths, nowMs: t0).isEmpty)
        try FileManager.default.removeItem(atPath: sb.root)
        // First seen missing: noted and kept, since its snapshots can still bring the folder back.
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0).stores == 0)
        let c = try #require(StoreCleanup.candidates(paths: sb.paths, nowMs: t0 + 2 * day).first)
        #expect(c.reason == .missing && c.missingSince == t0 && !c.due)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 2 * day).stores == 0)
        // The folder comes back, then goes again: the count starts over.
        try FileManager.default.createDirectory(atPath: sb.root, withIntermediateDirectories: true)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 2 * day).stores == 0)
        try FileManager.default.removeItem(atPath: sb.root)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 4 * day).stores == 0)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 6 * day).stores == 0)
        let swept = StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 7 * day + 1)
        #expect(swept.stores == 1 && swept.bytes > 0)
        #expect(SnapshotStore.allStores(paths: sb.paths).isEmpty)
    }

    @Test func aProjectFolderGetsThirtyDaysAndRetentionDoesTheSweep() throws {
        let (sb, loc) = try seeded("gone"); defer { sb.cleanup() }
        try retarget(loc, to: "/Users/airbag-test-nobody/Work/app-\(ULID.make())")
        #expect(Retention.run(paths: sb.paths, nowMs: t0).deletedStores == 0)
        #expect(Retention.run(paths: sb.paths, nowMs: t0 + 29 * day).deletedStores == 0)
        #expect(SnapshotStore.allStores(paths: sb.paths).count == 1)
        let report = Retention.run(paths: sb.paths, nowMs: t0 + 30 * day)
        #expect(report.deletedStores == 1 && report.freedBytes > 0)
        #expect(SnapshotStore.allStores(paths: sb.paths).isEmpty)
    }

    @Test func aPinnedSnapshotKeepsItsStoreForGood() throws {
        let (sb, _) = try seeded("gone"); defer { sb.cleanup() }
        let store = try sb.store()
        try store.pin(try #require(try store.latest()).id)
        try FileManager.default.removeItem(atPath: sb.root)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0).stores == 0)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 400 * day).stores == 0)
        let c = try #require(StoreCleanup.candidates(paths: sb.paths, nowMs: t0 + 400 * day).first)
        #expect(c.pinned == 1 && !c.due)
    }

    @Test func anUnpluggedVolumeIsNotAMissingFolder() throws {
        let (sb, loc) = try seeded("gone"); defer { sb.cleanup() }
        try retarget(loc, to: "/Volumes/AirbagNoSuchVolume-\(ULID.make())/project")
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0).stores == 0)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 400 * day).stores == 0)
        #expect(StoreCleanup.candidates(paths: sb.paths, nowMs: t0 + 400 * day).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: loc.directory + "/missing-since"))
    }

    @Test func aRefusedFoldersOldStoreWaitsForCleanup() throws {
        let (sb, loc) = try seeded("gone"); defer { sb.cleanup() }
        // A folder that exists and is never a root (ADR-032): its store was made by an older version.
        let refused = try #require(FileSystem.canonicalPath(NSTemporaryDirectory()))
        try retarget(loc, to: refused)
        #expect(StoreCleanup.sweep(paths: sb.paths, nowMs: t0 + 400 * day).stores == 0)
        let c = try #require(StoreCleanup.candidates(paths: sb.paths, nowMs: t0).first)
        #expect(c.reason == .refused && !c.due)
        let home = sb.paths.home.path
        // A preview deletes nothing; a misspelled option runs nothing.
        let preview = airbagCLI(["cleanup", "--dry-run"], home: home)
        #expect(preview.status == 0 && preview.output.contains("would delete 1 store(s)") && preview.output.contains("no longer snapshotted"), "\(preview)")
        #expect(airbagCLI(["cleanup", "--dryrun"], home: home).status == 64)
        #expect(SnapshotStore.allStores(paths: sb.paths).count == 1)
        let done = airbagCLI(["cleanup"], home: home)
        #expect(done.status == 0 && done.output.contains("deleted 1 store(s)"), "\(done)")
        #expect(SnapshotStore.allStores(paths: sb.paths).isEmpty)
    }

    @Test func cleanupKeepsAFolderGoneOnlyRecentlyUnlessAsked() throws {
        let (sb, _) = try seeded("gone"); defer { sb.cleanup() }
        try FileManager.default.removeItem(atPath: sb.root)
        let home = sb.paths.home.path
        let kept = airbagCLI(["cleanup"], home: home)
        #expect(kept.status == 0 && kept.output.contains("deleted 0 store(s)") && kept.output.contains("kept 1 store(s)"), "\(kept)")
        #expect(SnapshotStore.allStores(paths: sb.paths).count == 1)
        let done = airbagCLI(["cleanup", "--missing", "--json"], home: home)
        #expect(done.status == 0 && (decode(done.output)["deleted"] as? [[String: Any]])?.first?["reason"] as? String == "missing", "\(done)")
        #expect(SnapshotStore.allStores(paths: sb.paths).isEmpty)
    }
}
