import Foundation
import Testing
@testable import AirbagCore

/// Isolated environment for hook pipeline tests: a project, an Airbag home and a fake user home.
struct HookSandbox {
    let sb: Sandbox
    let userHome: String
    var paths: AirbagPaths { sb.paths }
    var root: String { sb.root }

    init() {
        sb = Sandbox("hook")
        userHome = sb.tmp.sub("user")
        try! FileManager.default.createDirectory(atPath: userHome, withIntermediateDirectories: true)
        sb.seedProject()
        _ = sh("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init", cwd: root)
    }

    func bridge(_ env: [String: String] = [:]) -> HookBridge {
        var c = HookBridgeConfig(paths: paths, environment: env)
        c.spawnBackground = false
        c.home = userHome
        return HookBridge(config: c)
    }

    func run(_ agent: AgentKind, _ payload: [String: Any], hint: String? = nil, env: [String: String] = [:]) -> HookOutcome {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return bridge(env).handle(payload: data, declared: agent, eventHint: hint)
    }

    func registry() -> Registry { try! Registry(paths: paths, role: .app) }
    func cleanup() { sb.cleanup() }

    func claudePre(_ command: String, id: String = ULID.make(), session: String = "sess-1", mode: String = "default") -> [String: Any] {
        ["session_id": session, "transcript_path": "/tmp/t.jsonl", "cwd": root, "permission_mode": mode, "hook_event_name": "PreToolUse",
         "tool_name": "Bash", "tool_input": ["command": command, "description": "x"], "tool_use_id": id]
    }
}

func decode(_ s: String?) -> [String: Any] {
    guard let s, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

@Suite(.serialized) struct HookPipelineTests {
    @Test func claudeAllowsProjectDeletionAfterSnapshot() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let out = h.run(.claudeCode, h.claudePre("rm -rf src/legacy"))
        #expect(out.output == "{}")
        #expect(out.finalDecision == "allow")
        let snap = try #require(out.snapshot)
        #expect(snap.trigger == .initial || snap.trigger == .preCommand)
        let reg = h.registry()
        #expect(try reg.db.scalarInt("SELECT count(*) FROM sessions WHERE agent = 'claude-code' AND agent_session_id = 'sess-1'") == 1)
        #expect(try reg.db.scalarText("SELECT snapshot_id FROM events WHERE kind = 'pre_shell'") == snap.id)
        #expect(try reg.db.scalarText("SELECT rule_id FROM guard_log") == "fs.rm.project")
        // The agent deletes; the snapshot brings the files back.
        sh("rm -rf src/legacy", cwd: h.root)
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        _ = try store.restore(to: snap.id, scope: .paths(["src/legacy"]))
        #expect(h.sb.read("src/legacy/deep/nested.ts") == "export const deep = 1;\n")
    }

    @Test func claudeDeniesHomeDeletionWithoutSnapshot() {
        let h = HookSandbox(); defer { h.cleanup() }
        let out = h.run(.claudeCode, h.claudePre("rm -rf ~"))
        let o = decode(out.output)["hookSpecificOutput"] as? [String: Any]
        #expect(o?["permissionDecision"] as? String == "deny")
        #expect((o?["permissionDecisionReason"] as? String)?.contains("home directory") == true)
        #expect(out.snapshot == nil)
        #expect(out.finalDecision == "deny")
        #expect(try! h.registry().db.scalarText("SELECT decision FROM guard_log") == "deny")
    }

    @Test func claudeNativeAskAndBypassFallback() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let ask = decode(h.run(.claudeCode, h.claudePre("git push --force")).output)["hookSpecificOutput"] as? [String: Any]
        #expect(ask?["permissionDecision"] as? String == "ask")
        // Bypass permissions: by default the command runs after a snapshot and is recorded (ADR-030).
        let recorded = h.run(.claudeCode, h.claudePre("git push --force", mode: "bypassPermissions"))
        #expect(recorded.output == "{}")
        #expect(recorded.finalDecision == "allow_fallback")
        #expect(recorded.snapshot != nil)
        #expect(try h.registry().db.scalarText("SELECT decision FROM guard_log ORDER BY rowid DESC LIMIT 1") == "allow_fallback")
        // "Stop the agent until I approve".
        try h.registry().setSetting("hook.recordInsteadOfAsking", false)
        let bypass = h.run(.claudeCode, h.claudePre("git push --force", mode: "bypassPermissions"))
        #expect((decode(bypass.output)["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "deny")
        #expect(bypass.finalDecision == "deny_fallback")
    }

    @Test func recordingNeverRunsWhatIsBlockedOrWhatCouldNotBeSnapshotted() {
        let h = HookSandbox(); defer { h.cleanup() }
        let blocked = h.run(.claudeCode, h.claudePre("rm -rf ~", mode: "bypassPermissions"))
        #expect(blocked.finalDecision == "deny")
        // An agent may not approve its own command.
        let selfApproval = h.run(.claudeCode, h.claudePre("airbag allow 01ABC", mode: "bypassPermissions"))
        #expect(selfApproval.finalDecision == "deny")
    }

    @Test func switchingProtectionOffIsNeverJustRecorded() {
        let h = HookSandbox(); defer { h.cleanup() }
        // Under bypass permissions other risky commands run and are recorded; removing a hook config stops the agent.
        let config = h.run(.claudeCode, h.claudePre("rm \(h.userHome)/.claude/settings.json", mode: "bypassPermissions"))
        #expect(config.finalDecision == "deny_fallback")
        #expect(config.verdict?.findings.contains { $0.ruleId == "self.hooks" } == true)
        let codex = h.run(.codex, ["session_id": "thread-9", "turn_id": "t1", "cwd": h.root, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                   "tool_input": ["command": "airbag hooks uninstall --all"], "tool_use_id": "c1"], hint: "pre-bash")
        #expect(codex.finalDecision == "deny_fallback")
        let copilot = h.run(.claudeCode, h.claudePre("rm \(h.userHome)/.copilot/hooks/airbag.json", mode: "bypassPermissions"))
        #expect(copilot.finalDecision == "deny_fallback")
        let repointed = h.run(.claudeCode, h.claudePre("airbag hooks install --all --command /usr/bin/true", mode: "bypassPermissions"))
        #expect(repointed.finalDecision == "deny_fallback")
        let preview = h.run(.claudeCode, h.claudePre("airbag hooks uninstall --dry-run", mode: "bypassPermissions"))
        #expect(preview.finalDecision == "allow")
    }

    @Test func codexAskIsRecordedByDefault() {
        let h = HookSandbox(); defer { h.cleanup() }
        let out = h.run(.codex, ["session_id": "thread-9", "turn_id": "t1", "cwd": h.root, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                 "tool_input": ["command": "git push --force origin main"], "tool_use_id": "c1"], hint: "pre-bash")
        #expect(out.output == nil) // Codex: silence means proceed
        #expect(out.finalDecision == "allow_fallback")
    }

    @Test func codexAskBecomesDenyThenAllowOnce() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        try h.registry().setSetting("hook.recordInsteadOfAsking", false)
        func payload(_ id: String) -> [String: Any] {
            ["session_id": "thread-9", "turn_id": "t1", "cwd": h.root, "hook_event_name": "PreToolUse", "tool_name": "Bash",
             "tool_input": ["command": "git push --force origin main"], "tool_use_id": id, "model": "gpt-6"]
        }
        let first = h.run(.codex, payload("call-1"), hint: "pre-bash")
        let o = decode(first.output)["hookSpecificOutput"] as? [String: Any]
        #expect(o?["permissionDecision"] as? String == "deny")
        #expect((o?["permissionDecisionReason"] as? String)?.contains("Allow once") == true)
        let reg = h.registry()
        let guardID = try #require(try reg.db.scalarText("SELECT id FROM guard_log WHERE decision = 'deny_fallback'"))
        #expect(try reg.allowOnce(guardID: guardID))
        let second = h.run(.codex, payload("call-2"), hint: "pre-bash")
        #expect(second.output == nil) // Codex: silence means proceed
        #expect(second.finalDecision == "allow_once")
        // The allowance is single use.
        let third = h.run(.codex, payload("call-3"), hint: "pre-bash")
        #expect(third.finalDecision == "deny_fallback")
    }

    @Test func codexAllowPrintsNothing() {
        let h = HookSandbox(); defer { h.cleanup() }
        let out = h.run(.codex, ["session_id": "th", "cwd": h.root, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                 "tool_input": ["command": "npm test"], "tool_use_id": "c1"], hint: "pre-bash")
        #expect(out.output == nil)
        #expect(out.finalDecision == "allow")
    }

    @Test func cursorNativeAskAndDeny() {
        let h = HookSandbox(); defer { h.cleanup() }
        let base: [String: Any] = ["conversation_id": "conv", "generation_id": "gen", "hook_event_name": "beforeShellExecution",
                                   "cursor_version": "2.6", "workspace_roots": [h.root], "cwd": h.root, "sandbox": false]
        var p = base; p["command"] = "terraform destroy"
        let ask = decode(h.run(.cursor, p).output)
        #expect(ask["permission"] as? String == "ask")
        #expect(ask["agent_message"] as? String != nil)
        p["command"] = "rm -rf ~/Documents"; p["generation_id"] = "gen2"
        #expect(decode(h.run(.cursor, p).output)["permission"] as? String == "deny")
        p["command"] = "ls"; p["generation_id"] = "gen3"
        #expect(decode(h.run(.cursor, p).output)["permission"] as? String == "allow")
    }

    @Test func geminiDenyFormatAndRelativeDir() {
        let h = HookSandbox(); defer { h.cleanup() }
        let out = h.run(.gemini, ["session_id": "g1", "cwd": h.root, "hook_event_name": "BeforeTool", "tool_name": "run_shell_command",
                                  "tool_input": ["command": "rm -rf ../..", "dir_path": "src"], "timestamp": "2026-10-18T10:00:00Z"])
        let o = decode(out.output)
        #expect(o["decision"] as? String == "deny")
        #expect(o["systemMessage"] as? String != nil)
        #expect(out.envelope?.cwd == h.root + "/src")
    }

    @Test func copilotToolArgsAsJSONString() {
        let h = HookSandbox(); defer { h.cleanup() }
        let out = h.run(.copilot, ["sessionId": "cp1", "timestamp": 1_760_000_000_000, "cwd": h.root, "toolName": "bash",
                                   "toolArgs": "{\"command\":\"rm -rf /\",\"description\":\"x\"}"], hint: "preToolUse")
        #expect(out.envelope?.command == "rm -rf /")
        #expect(decode(out.output)["permissionDecision"] as? String == "deny")
    }

    @Test func sessionLifecycle() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        _ = h.run(.claudeCode, ["session_id": "life", "cwd": h.root, "hook_event_name": "SessionStart", "source": "startup"])
        let reg = h.registry()
        #expect(try reg.db.scalarInt("SELECT count(*) FROM sessions WHERE agent_session_id = 'life' AND ended_at IS NULL") == 1)
        #expect(try reg.db.scalarText("SELECT kind FROM projects") == "git")
        _ = h.run(.claudeCode, ["session_id": "life", "cwd": h.root, "hook_event_name": "SessionEnd", "reason": "prompt_input_exit"])
        #expect(try reg.db.scalarText("SELECT end_reason FROM sessions WHERE agent_session_id = 'life'") == "hook:prompt_input_exit")
    }

    @Test func duplicateRouteIsProcessedOnce() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let p = h.claudePre("rm -rf src/legacy", id: "toolu_same")
        let a = h.run(.claudeCode, p)
        let b = h.run(.claudeCode, p)
        #expect(a.finalDecision == "allow" && b.finalDecision == "allow")
        #expect(a.snapshot != nil && b.snapshot == nil) // the second route replays the first decision
        #expect(try h.registry().db.scalarInt("SELECT count(*) FROM events WHERE kind = 'pre_shell'") == 1)
    }

    @Test func registryOutageSpoolsAndStillDecides() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        try h.paths.prepare()
        try FileManager.default.createDirectory(atPath: h.paths.registry.path, withIntermediateDirectories: true) // unusable
        let out = h.run(.claudeCode, h.claudePre("rm -rf ~"))
        #expect(out.finalDecision == "deny")
        let spooled = try FileManager.default.contentsOfDirectory(atPath: h.paths.spool.path)
        #expect(spooled.count == 1)
        try FileManager.default.removeItem(atPath: h.paths.registry.path)
        let reg = h.registry()
        #expect(reg.ingestSpool() == 1)
        #expect(try reg.db.scalarText("SELECT decision FROM guard_log") == "deny")
    }

    @Test func busyStoreEscalatesDestructiveCommandToAsk() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        _ = store.snapshot(SnapshotRequest(trigger: .initial))
        #expect(store.lock.acquire(waitMs: 0))
        defer { store.lock.release() }
        var cfg = HookBridgeConfig(paths: h.paths, environment: [:])
        cfg.spawnBackground = false; cfg.home = h.userHome; cfg.lockWaitMs = 50
        let data = try JSONSerialization.data(withJSONObject: h.claudePre("git reset --hard"))
        let out = HookBridge(config: cfg).handle(payload: data, declared: .claudeCode, eventHint: nil)
        #expect(out.snapshotSkipped == "busy")
        #expect((decode(out.output)["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "ask")
        #expect(out.verdict?.findings.contains { $0.ruleId == "snapshot.unavailable" } == true)
    }

    @Test func writingTheFirstFileInAnEmptyFolderIsAllowed() throws {
        // An empty folder has nothing to snapshot; that used to read as "snapshot unavailable" and block the first
        // file an agent wrote into a new project.
        let h = HookSandbox(); defer { h.cleanup() }
        let fresh = h.sb.tmp.sub("fresh")
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        var payload = h.claudePre("cat > notes.md <<'EOF'\nhello\nEOF")
        payload["cwd"] = fresh
        let out = h.run(.claudeCode, payload)
        #expect(out.finalDecision == "allow")
        #expect(out.snapshotSkipped == "empty")
    }

    @Test func aFolderWithOnlyFilesTooLargeToSnapshotIsNotEmpty() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let fresh = h.sb.tmp.sub("media")
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fresh + "/big.sqlite", contents: nil)
        let f = try #require(FileHandle(forWritingAtPath: fresh + "/big.sqlite"))
        try f.truncate(atOffset: 150 << 20) // sparse, over the 100 MiB per-file cap
        try f.close()
        var payload = h.claudePre("rm -rf ./*")
        payload["cwd"] = fresh
        let out = h.run(.claudeCode, payload)
        #expect(out.finalDecision == "ask")
        #expect(out.verdict?.findings.contains { $0.ruleId == "snapshot.unavailable" } == true)
    }

    @Test func anEmptyFolderDoesNotCoverTheLaunchFolder() throws {
        // The agent was started in the project and works in an empty nested repository: deleting a project file from
        // there is not covered by the empty folder's "snapshot", so the project gets one of its own.
        let h = HookSandbox(); defer { h.cleanup() }
        let sub = h.root + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        _ = sh("git init -q", cwd: sub)
        var payload = h.claudePre("rm ../src/index.ts")
        payload["cwd"] = sub
        let out = h.run(.claudeCode, payload, env: ["CLAUDE_PROJECT_DIR": h.root])
        #expect(out.finalDecision == "allow")
        #expect(out.snapshotSkipped == nil)
        let snap = try #require(out.snapshot)
        #expect(try h.registry().db.scalarText("SELECT snapshot_id FROM events WHERE kind = 'pre_shell'") == snap.id)
        sh("rm src/index.ts", cwd: h.root)
        _ = try SnapshotStore.open(root: h.root, paths: h.paths).restore(to: snap.id, scope: .paths(["src/index.ts"]))
        #expect(h.sb.exists("src/index.ts"))
    }

    @Test func aSnapshotOfTheSessionFolderDoesNotCoverTheLaunchFolder() throws {
        // A nested repository with files of its own: its snapshot succeeds, but the file the command deletes is in the
        // launch folder, which needs its own snapshot before the command runs.
        let h = HookSandbox(); defer { h.cleanup() }
        h.sb.write("important.txt", "keep me\n")
        h.sb.write("sub/notes.md", "nested\n")
        let sub = h.root + "/sub"
        _ = sh("git init -q", cwd: sub)
        var payload = h.claudePre("rm ../important.txt")
        payload["cwd"] = sub
        let out = h.run(.claudeCode, payload, env: ["CLAUDE_PROJECT_DIR": h.root])
        #expect(out.finalDecision == "allow")
        #expect(out.snapshotSkipped == nil)
        #expect(out.verdict?.findings.first { $0.ruleId == "fs.rm.project" }?.roots == [h.root])
        #expect(SnapshotStore.storeExists(root: sub, paths: h.paths))
        // The agent deletes the file; the launch folder's snapshot brings it back.
        sh("rm important.txt", cwd: h.root)
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        let before = try #require(try store.latest())
        _ = try store.restore(to: before.id, scope: .paths(["important.txt"]))
        #expect(h.sb.read("important.txt") == "keep me\n")
    }

    @Test func theLaunchFolderIsSnapshottedOnlyForACommandThatTargetsIt() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        h.sb.write("sub/notes.md", "nested\n")
        let sub = h.root + "/sub"
        _ = sh("git init -q", cwd: sub)
        var payload = h.claudePre("rm notes.md")
        payload["cwd"] = sub
        let out = h.run(.claudeCode, payload, env: ["CLAUDE_PROJECT_DIR": h.root])
        #expect(out.finalDecision == "allow")
        #expect(out.snapshot != nil)
        #expect(!SnapshotStore.storeExists(root: h.root, paths: h.paths))
        // An empty nested folder: writing its first file needs no snapshot of the launch folder either.
        let empty = h.root + "/fresh"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        _ = sh("git init -q", cwd: empty)
        payload = h.claudePre("echo hi > first.md")
        payload["cwd"] = empty
        let first = h.run(.claudeCode, payload, env: ["CLAUDE_PROJECT_DIR": h.root])
        #expect(first.finalDecision == "allow")
        #expect(first.snapshotSkipped == "empty")
        #expect(!SnapshotStore.storeExists(root: h.root, paths: h.paths))
    }

    @Test func aBusyLaunchFolderEscalatesEvenWhenTheSessionFolderWasSnapshotted() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        h.sb.write("important.txt", "keep me\n")
        h.sb.write("sub/notes.md", "nested\n")
        let sub = h.root + "/sub"
        _ = sh("git init -q", cwd: sub)
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        _ = store.snapshot(SnapshotRequest(trigger: .initial))
        #expect(store.lock.acquire(waitMs: 0))
        defer { store.lock.release() }
        var cfg = HookBridgeConfig(paths: h.paths, environment: ["CLAUDE_PROJECT_DIR": h.root])
        cfg.spawnBackground = false; cfg.home = h.userHome; cfg.lockWaitMs = 50
        var payload = h.claudePre("rm ../important.txt", mode: "bypassPermissions")
        payload["cwd"] = sub
        let out = HookBridge(config: cfg).handle(payload: try JSONSerialization.data(withJSONObject: payload), declared: .claudeCode, eventHint: nil)
        #expect(out.snapshot != nil) // the nested repository's
        #expect(out.snapshotSkipped == "busy")
        #expect(out.finalDecision == "deny_fallback")
        #expect(out.verdict?.findings.contains { $0.ruleId == "snapshot.unavailable" } == true)
    }

    @Test func failedSnapshotStopsAnAskEvenWhereAsksAreRecorded() throws {
        // `rm -rf .` asks and needs a snapshot. Under bypass permissions asks are only recorded, but not when the
        // snapshot could not be taken.
        let h = HookSandbox(); defer { h.cleanup() }
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        _ = store.snapshot(SnapshotRequest(trigger: .initial))
        #expect(store.lock.acquire(waitMs: 0))
        defer { store.lock.release() }
        var cfg = HookBridgeConfig(paths: h.paths, environment: [:])
        cfg.spawnBackground = false; cfg.home = h.userHome; cfg.lockWaitMs = 50
        let data = try JSONSerialization.data(withJSONObject: h.claudePre("rm -rf .", mode: "bypassPermissions"))
        let out = HookBridge(config: cfg).handle(payload: data, declared: .claudeCode, eventHint: nil)
        #expect(out.snapshotSkipped == "busy")
        #expect(out.finalDecision == "deny_fallback")
    }

    @Test func postCommandSnapshotRecordsWhatChanged() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let pre = h.run(.claudeCode, h.claudePre("sed -i '' s/42/43/ src/index.ts", id: "toolu_x"))
        sh("sed -i '' s/42/43/ src/index.ts", cwd: h.root)
        var post = h.claudePre("sed -i '' s/42/43/ src/index.ts", id: "toolu_x")
        post["hook_event_name"] = "PostToolUse"
        post["tool_response"] = ["stdout": "", "stderr": "", "interrupted": false]
        let out = h.run(.claudeCode, post)
        let snap = try #require(out.snapshot)
        #expect(snap.trigger == .postCommand)
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        #expect(try store.changes(in: snap.id).map(\.path) == ["src/index.ts"])
        #expect(pre.snapshot != nil)
    }

    @Test func redactorHidesSecrets() {
        let s = Redactor.redact("curl -H 'Authorization: Bearer abc.def.ghi' https://u:p4ss@x.dev?token=123 && export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz && gh auth login --with-token ghp_abcdefghijklmnopqrstuvwxyz0123")
        #expect(!s.contains("p4ss"))
        #expect(!s.contains("abcdefghijklmnopqrstuvwxyz0123"))
        #expect(!s.contains("sk-proj-abcdefghijklmnopqrstuvwxyz"))
        #expect(!s.contains("123 "))
        #expect(Redactor.redact("find . -print -prune") == "find . -print -prune")
    }
}

@Suite struct HookInstallerTests {
    func setup() -> (TempDir, HookInstaller) {
        let t = TempDir("inst")
        return (t, HookInstaller(home: t.path, command: "/Applications/Airbag.app/Contents/Helpers/airbag"))
    }

    @Test func claudeMergePreservesForeignHooksAndOrder() throws {
        let (t, inst) = setup(); defer { t.cleanup() }
        let original = """
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "npx cc-safety-net --claude-code"
                  }
                ]
              }
            ],
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say done"
                  }
                ]
              }
            ]
          },
          "permissions": {
            "allow": [
              "Bash(npm test)"
            ]
          }
        }

        """
        t.write(".claude/settings.json", original, mode: 0o600)
        let change = try inst.install(.claudeCode, backupDirectory: t.sub("backups"))
        #expect(change.changed)
        let after = try #require(t.read(".claude/settings.json"))
        let json = try OrderedJSON.parse(after)
        guard case .object(let top) = json else { Issue.record("not an object"); return }
        #expect(top.map(\.0) == ["model", "hooks", "permissions"])
        let pre = json["hooks"]?["PreToolUse"]?.arrayValue ?? []
        #expect(pre.count == 2)
        #expect(pre.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue == "npx cc-safety-net --claude-code")
        #expect(after.contains("\"args\": [\n"))
        #expect(inst.status(.claudeCode).current)
        var st = stat(); stat(t.sub(".claude/settings.json"), &st)
        #expect(st.st_mode & 0o777 == 0o600)
        // Idempotent.
        #expect(!(try inst.install(.claudeCode, backupDirectory: nil)).changed)
        // Uninstall restores the original bytes.
        _ = try inst.uninstall(.claudeCode, backupDirectory: nil)
        #expect(t.read(".claude/settings.json") == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.sub("backups")).count == 1)
    }

    @Test func strictModeAndStaleCommandDetection() throws {
        let (t, inst) = setup(); defer { t.cleanup() }
        _ = try inst.install(.claudeCode, strict: true, backupDirectory: nil)
        #expect(t.read(".claude/settings.json")?.contains("\"onFailure\": \"block\"") == true)
        let moved = HookInstaller(home: t.path, command: "/opt/homebrew/bin/airbag")
        let st = moved.status(.claudeCode)
        #expect(st.installed && st.staleCommand && !st.current)
        _ = try moved.install(.claudeCode, backupDirectory: nil)
        let text = try #require(t.read(".claude/settings.json"))
        #expect(!text.contains("/Applications/Airbag.app"))
        #expect(text.components(separatedBy: "\"hook\"").count - 1 == 4) // one handler per event, no duplicates
    }

    @Test(arguments: [AgentKind.codex, .cursor, .gemini, .copilot])
    func installUninstallRoundTrip(_ agent: AgentKind) throws {
        let (t, inst) = setup(); defer { t.cleanup() }
        let path = inst.configPath(agent)
        let foreign: String? = agent == .copilot ? nil : (agent == .cursor
            ? "{\n  \"version\": 1,\n  \"hooks\": {\n    \"beforeShellExecution\": [\n      {\n        \"command\": \"./mine.sh\"\n      }\n    ]\n  }\n}\n"
            : "{\n  \"theme\": \"dark\"\n}\n")
        if let foreign { t.write((path as NSString).replacingOccurrences(of: t.path + "/", with: ""), foreign) }
        _ = try inst.install(agent, backupDirectory: nil)
        #expect(inst.isInstalled(agent))
        #expect(inst.status(agent).current)
        let text = try #require(FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) })
        #expect(text.contains("hook \(agent.rawValue)") || text.contains("\"\(agent.rawValue)\""))
        if agent == .cursor { #expect(text.contains("./mine.sh")) }
        _ = try inst.uninstall(agent, backupDirectory: nil)
        #expect(!inst.isInstalled(agent))
        let back = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
        #expect(back == foreign)
    }

    @Test func codexCommandStringIsQuotedWhenNeeded() throws {
        let t = TempDir("inst"); defer { t.cleanup() }
        let inst = HookInstaller(home: t.path, command: "/Users/x/My Apps/Airbag.app/Contents/Helpers/airbag")
        _ = try inst.install(.codex, backupDirectory: nil)
        let text = try #require(t.read(".codex/hooks.json"))
        #expect(text.contains("\"'/Users/x/My Apps/Airbag.app/Contents/Helpers/airbag' hook codex pre-bash\""))
        #expect(inst.isInstalled(.codex))
        _ = try inst.uninstall(.codex, backupDirectory: nil)
        #expect(!inst.isInstalled(.codex))
    }

    @Test func orderedJSONRoundTrip() throws {
        let src = "{\n  \"b\": 1.50,\n  \"a\": [\n    true,\n    null,\n    \"x\\ny\\u00e9\"\n  ],\n  \"c\": {}\n}\n"
        #expect(try OrderedJSON.parse(src).serialized() == src.replacingOccurrences(of: "\\u00e9", with: "é"))
        #expect(throws: OrderedJSON.ParseError.self) { _ = try OrderedJSON.parse("{\"a\": }") }
        #expect(try OrderedJSON.parse("// c\n{\"a\": 1, /* x */ \"b\": [1,2,],}")["b"]?.arrayValue?.count == 2)
    }
}

@Suite struct AdapterTests {
    @Test func claudeEnvelope() {
        let j = JSONObject(["session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": "/p",
                            "tool_input": ["command": "ls", "run_in_background": true], "tool_use_id": "t"])
        let e = AgentAdapter.parse(j, declared: .claudeCode, eventHint: nil, environment: ["CLAUDE_PROJECT_DIR": "/p"])
        #expect(e.kind == .preShell && e.command == "ls" && e.background && e.launchRoot == "/p" && e.dedupeKey == "claude-code:t:pre_shell")
    }

    @Test func cursorPayloadThroughClaudeConfigRepliesInClaudeFormat() {
        let j = JSONObject(["conversation_id": "c", "generation_id": "g", "hook_event_name": "preToolUse", "cursor_version": "2.6",
                            "workspace_roots": ["/p"], "tool_name": "Shell", "tool_input": ["command": "rm -rf ~", "working_directory": "/p/src"]])
        let e = AgentAdapter.parse(j, declared: .claudeCode, eventHint: nil, environment: [:])
        #expect(e.agent == .cursor && e.replyAs == .claudeCode && e.kind == .preShell && e.cwd == "/p/src")
        let out = AgentAdapter.encode(.deny(agentReason: "r", userMessage: "u"), as: e.replyAs, event: e)
        #expect(out?.contains("permissionDecision") == true)
    }

    @Test func codexPermissionRequestDenyShape() {
        let e = HookEnvelope(agent: .codex, replyAs: .codex, kind: .permissionRequest, rawEvent: "PermissionRequest")
        let out = decode(AgentAdapter.encode(.deny(agentReason: "no", userMessage: "u"), as: .codex, event: e))
        let d = (out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(d?["behavior"] as? String == "deny" && d?["message"] as? String == "no")
    }
}
