import Foundation
import Testing
@testable import AirbagCore

/// Regressions for findings of the independent review (2026-10-18).
@Suite struct SnapshotReviewRegressions {
    func writeRaw(_ path: String, _ text: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    @Test func renameBetweenNFCandNFDDoesNotCorruptHistoryOrRestore() throws {
        let sb = Sandbox("nfc"); defer { sb.cleanup() }
        let nfc = sb.root + "/caf\u{E9}.txt", nfd = sb.root + "/cafe\u{301}.txt"
        writeRaw(nfc, "v1")
        let store = try sb.store()
        let s1 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        #expect(rename(nfc, nfd) == 0)
        _ = store.snapshot(SnapshotRequest(trigger: .manual))
        #expect(try store.db.scalarInt("SELECT count(*) FROM current") == 1)
        writeRaw(nfd, "v2")
        _ = store.snapshot(SnapshotRequest(trigger: .manual))
        for _ in 0..<3 {
            if case .created(let s, _) = store.snapshot(SnapshotRequest(trigger: .manual)) { Issue.record("phantom change in \(s.id)") }
        }
        writeRaw(nfd, "CORRUPTED")
        let r = try store.restore(to: s1.id, scope: .root)
        #expect(r.restored.count == 1)
        #expect(try String(contentsOfFile: nfc, encoding: .utf8) == "v1")
    }

    @Test func pathRestoreNeverWritesOrMovesThroughASymlinkedParent() throws {
        let sb = Sandbox("link"); defer { sb.cleanup() }
        try FileManager.default.createDirectory(atPath: sb.tmp.sub("outside"), withIntermediateDirectories: true)
        sb.tmp.write("outside/x.txt", "OUTSIDE-PRECIOUS")
        sb.write("a/x.txt", "v1")
        let store = try sb.store()
        let s1 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        sb.run("rm -rf a && ln -s ../outside a")
        _ = store.snapshot(SnapshotRequest(trigger: .manual))
        _ = try store.restore(to: s1.id, scope: .paths(["a/x.txt"]))
        #expect(sb.tmp.read("outside/x.txt") == "OUTSIDE-PRECIOUS")
        #expect(sb.read("a/x.txt") == "v1")
        var st = stat(); lstat(sb.root + "/a", &st)
        #expect((st.st_mode & S_IFMT) == S_IFDIR)
    }

    @Test func oversizedUnreadableAndUncapturableFilesAreNotRecordedAsDeleted() throws {
        let sb = Sandbox("unk"); defer { sb.cleanup() }
        sb.write("a.txt", "a"); sb.write("big.bin", String(repeating: "x", count: 4000)); sb.write("d/secret.txt", "s")
        let store = try sb.store()
        let s1 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        // (a) a captured file goes over the cap (e.g. low-disk mode)
        store.exclusions.maxFileBytes = 1000
        sb.write("a.txt", "a2")
        let s2 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        #expect(try store.changes(in: s2.id).map(\.path) == ["a.txt"])
        store.exclusions.maxFileBytes = 100 << 20
        // (b) an unreadable directory
        chmod(sb.root + "/d", 0o000)
        sb.write("a.txt", "a3")
        let s3 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        chmod(sb.root + "/d", 0o755)
        #expect(!(try store.changes(in: s3.id)).contains { $0.path == "d/secret.txt" })
        #expect(!s3.complete)
        // (c) a new file that cannot be read
        sb.write("n.txt", "n"); chmod(sb.root + "/n.txt", 0o000)
        sb.write("a.txt", "a4")
        let s4 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        chmod(sb.root + "/n.txt", 0o644)
        #expect(!s4.complete)
        // Restoring to the incomplete snapshot never moves away files it could not see.
        let r = try store.restore(to: s4.id, scope: .root)
        #expect(r.movedAside.isEmpty)
        #expect(sb.exists("n.txt") && sb.exists("big.bin") && sb.exists("d/secret.txt"))
        _ = s1
    }

    @Test func openingTheStoreOfADeletedProjectDoesNotRecreateIt() throws {
        let sb = Sandbox("gone"); defer { sb.cleanup() }
        sb.write("src/a.ts", "a")
        let store = try sb.store()
        let s1 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        try FileManager.default.removeItem(atPath: sb.root)
        let loc = try #require(SnapshotStore.allStores(paths: sb.paths).first)
        #expect(!loc.rootExists)
        let reopened = try SnapshotStore.openLocation(loc, paths: sb.paths)
        Retention.run(paths: sb.paths)
        #expect(!FileManager.default.fileExists(atPath: sb.root))
        if case .failed = reopened.snapshot(SnapshotRequest(trigger: .manual)) {} else { Issue.record("snapshot of a missing folder must fail") }
        // Restoring brings the whole project back.
        _ = try reopened.restore(to: s1.id, scope: .root)
        #expect(sb.read("src/a.ts") == "a")
    }

    @Test func diffOfAFullRewriteIsBoundedInTimeAndMemory() {
        let old = (0..<30_000).map { "line \($0)" }.joined(separator: "\n")
        let new = (0..<30_000).map { "changed \($0)" }.joined(separator: "\n")
        let start = Clock.monotonicNs()
        let d = TextDiff.compute(old: Data(old.utf8), new: Data(new.utf8))
        #expect(Clock.elapsedMs(since: start) < 3000)
        #expect(d.addedLines == 30_000 && d.removedLines == 30_000)
        let small = TextDiff.compute(old: Data("a\nb\nc\nd\n".utf8), new: Data("a\nB\nc\nd\ne\n".utf8))
        #expect(small.unified.contains("-b\n+B\n") && small.addedLines == 2 && small.removedLines == 1)
    }

    @Test func restoringHardLinkedFilesRestoresBoth() throws {
        let sb = Sandbox("hl"); defer { sb.cleanup() }
        sb.write("a.txt", "v1")
        link(sb.root + "/a.txt", sb.root + "/b.txt")
        let store = try sb.store()
        let s1 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        sb.write("a.txt", "v2") // writes through the shared inode
        let r = try store.restore(to: s1.id, scope: .root)
        #expect(r.conflicts.isEmpty)
        #expect(sb.read("a.txt") == "v1" && sb.read("b.txt") == "v1")
    }
}

@Suite(.serialized) struct HookReviewRegressions {
    @Test func watchdogWouldAnswerConservativelyWhileTheSnapshotRuns() async throws {
        let h = HookSandbox(); defer { h.cleanup() }
        let store = try SnapshotStore.open(root: h.root, paths: h.paths)
        _ = store.snapshot(SnapshotRequest(trigger: .initial))
        #expect(store.lock.acquire(waitMs: 0))
        defer { store.lock.release() }
        let printed = Box<[String]>([])
        let slot = OutputSlot(initial: "{}") { s in printed.with { $0.append(s) } }
        var cfg = HookBridgeConfig(paths: h.paths, environment: [:])
        cfg.spawnBackground = false; cfg.home = h.userHome; cfg.lockWaitMs = 1500
        let data = try JSONSerialization.data(withJSONObject: h.claudePre("git reset --hard"))
        let bridge = HookBridge(config: cfg)
        let done = Box(false)
        DispatchQueue.global().async { _ = bridge.handle(payload: data, declared: .claudeCode, eventHint: nil, slot: slot); done.with { $0 = true } }
        try await Task.sleep(nanoseconds: 600_000_000) // the snapshot is waiting for the lock
        #expect(slot.decidedText?.contains("\"ask\"") == true, "watchdog fallback was \(slot.decidedText ?? "nil")")
        while !done.with({ $0 }) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(printed.with { $0 }.count == 1)
    }

    @Test func sameCommandTwiceInOneCursorGenerationGetsTwoSnapshots() {
        let h = HookSandbox(); defer { h.cleanup() }
        var p: [String: Any] = ["conversation_id": "c", "generation_id": "g", "hook_event_name": "beforeShellExecution", "cursor_version": "2.6",
                                "workspace_roots": [h.root], "cwd": h.root, "command": "git checkout -- ."]
        let first = h.run(.cursor, p)
        sh("echo changed > src/index.ts", cwd: h.root)
        p["sandbox"] = false
        let second = h.run(.cursor, p)
        #expect(first.snapshot != nil && second.snapshot != nil)
        #expect(first.snapshot?.id != second.snapshot?.id)
    }

    @Test func codexPermissionRequestLeavesTheQuestionToCodexButKeepsHardBlocks() {
        let h = HookSandbox(); defer { h.cleanup() }
        func perm(_ cmd: String) -> [String: Any] {
            ["session_id": "t", "cwd": h.root, "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": cmd], "tool_use_id": ULID.make()]
        }
        #expect(h.run(.codex, perm("git push --force"), hint: "permission").output == nil)
        let blocked = decode(h.run(.codex, perm("rm -rf ~"), hint: "permission").output)
        #expect(((blocked["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String == "deny")
    }

    @Test func allowOnceRefusesHardBlocks() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        _ = h.run(.claudeCode, h.claudePre("rm -rf ~"))
        let reg = h.registry()
        let id = try #require(try reg.db.scalarText("SELECT id FROM guard_log WHERE decision = 'deny'"))
        #expect(throws: RegistryError.self) { try reg.allowOnce(guardID: id) }
    }
}

@Suite struct InstallerReviewRegressions {
    let cmd = "/Applications/Airbag.app/Contents/Helpers/airbag"

    @Test func reinstallKeepsGroupPositionsForCodexTrust() throws {
        let t = TempDir("inst"); defer { t.cleanup() }
        let inst = HookInstaller(home: t.path, command: cmd)
        _ = try inst.install(.codex, backupDirectory: nil)
        // The user adds their own group after Airbag's.
        var json = try OrderedJSON.parse(t.read(".codex/hooks.json")!)
        var pre = json["hooks"]?["PreToolUse"]?.arrayValue ?? []
        pre.append(.object([("matcher", .string("^Bash$")), ("hooks", .array([.object([("type", .string("command")), ("command", .string("mine.sh"))])]))]))
        var hooks = json["hooks"]!; hooks["PreToolUse"] = .array(pre); json["hooks"] = hooks
        t.write(".codex/hooks.json", json.serialized())
        let before = t.read(".codex/hooks.json")
        #expect(inst.status(.codex).current)
        #expect(!(try inst.install(.codex, backupDirectory: nil)).changed)
        #expect(t.read(".codex/hooks.json") == before)
        // A moved binary rewrites Airbag's entries where they are.
        let moved = HookInstaller(home: t.path, command: "/opt/homebrew/bin/airbag")
        _ = try moved.install(.codex, backupDirectory: nil)
        let after = try OrderedJSON.parse(t.read(".codex/hooks.json")!)
        let groups = after["hooks"]?["PreToolUse"]?.arrayValue ?? []
        #expect(groups.last?["hooks"]?.arrayValue?.first?["command"]?.stringValue == "mine.sh")
        #expect(groups.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue?.hasPrefix("/opt/homebrew/bin/airbag hook codex") == true)
    }

    @Test func installWritesThroughSymlinksAndRefusesReadOnlyOrCommentedFiles() throws {
        let t = TempDir("inst"); defer { t.cleanup() }
        let inst = HookInstaller(home: t.path, command: cmd)
        let real = t.write("dotfiles/claude-settings.json", "{\n  \"model\": \"opus\"\n}\n", mode: 0o600)
        try FileManager.default.createDirectory(atPath: t.sub(".claude"), withIntermediateDirectories: true)
        symlink(real, t.sub(".claude/settings.json"))
        _ = try inst.install(.claudeCode, backupDirectory: nil)
        var st = stat(); lstat(t.sub(".claude/settings.json"), &st)
        #expect((st.st_mode & S_IFMT) == S_IFLNK)
        #expect(t.read("dotfiles/claude-settings.json")?.contains("\"hook\"") == true)
        stat(real, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        // Read-only target
        chmod(real, 0o400)
        #expect(throws: HookInstallError.self) { _ = try inst.uninstall(.claudeCode, backupDirectory: nil) }
        chmod(real, 0o600)
        // Comments (allowed in Gemini settings) are not silently dropped.
        t.write(".gemini/settings.json", "{\n  // my theme\n  \"theme\": \"dark\"\n}\n")
        #expect(throws: HookInstallError.self) { _ = try inst.install(.gemini, backupDirectory: nil) }
        // A BOM is fine; a non-object `hooks` is refused, not overwritten.
        t.write(".cursor/hooks.json", "\u{FEFF}{\"version\": 1}")
        _ = try inst.install(.cursor, backupDirectory: nil)
        #expect(inst.isInstalled(.cursor))
        t.write(".codex/hooks.json", "{\"hooks\": []}")
        #expect(throws: HookInstallError.self) { _ = try inst.install(.codex, backupDirectory: nil) }
        #expect(t.read(".codex/hooks.json") == "{\"hooks\": []}")
    }

    @Test func shellFormCommandIsQuotedForAnySpecialCharacter() {
        #expect(HookInstaller(home: "/tmp", command: "/Users/a$b/airbag").shellCommand == "'/Users/a$b/airbag'")
        #expect(HookInstaller(home: "/tmp", command: "/opt/homebrew/bin/airbag").shellCommand == "/opt/homebrew/bin/airbag")
    }
}

@Suite(.serialized) struct RadarReviewRegressions {
    func spawn(_ script: String, env: [String: String] = [:], args: [String] = []) throws -> (Process, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", script] + args
        var e = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("CODEX") }
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(); p.standardOutput = out
        try p.run()
        return (p, out)
    }

    func readLine(_ pipe: Pipe) -> String {
        var data = Data()
        while !data.contains(UInt8(ascii: "\n")) { let d = pipe.fileHandleForReading.availableData; if d.isEmpty { break }; data.append(d) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func procargsKeepsEmptyArgumentsAndDecodesOnlyAllowlistedEnvironment() throws {
        let (p, out) = try spawn("import os,time; print(os.getpid(), flush=True); time.sleep(30)",
                                 env: ["MY_APP_SECRET": "hunter2", "CLAUDE_CODE_SESSION_ID": "sess-x"], args: ["", "after-empty"])
        defer { p.terminate() }
        // python may be a child of the /usr/bin/python3 shim: the printed pid is the real interpreter.
        let pid = try #require(Int32(readLine(out)))
        let a = try #require(ProcInfo.arguments(pid, envKeys: ProcessRadar.markerKeys))
        #expect(a.argv.contains("") && a.argv.last == "after-empty")
        #expect(a.env["CLAUDE_CODE_SESSION_ID"] == "sess-x")
        #expect(a.env["MY_APP_SECRET"] == nil)
        #expect(!a.argv.contains { $0.contains("hunter2") })
    }

    @Test func laterActivityRevivesAnEndedSession() throws {
        let h = HookSandbox(); defer { h.cleanup() }
        _ = h.run(.claudeCode, ["session_id": "s1", "cwd": h.root, "hook_event_name": "SessionEnd", "reason": "other"])
        _ = h.run(.claudeCode, h.claudePre("ls", session: "s1"))
        #expect(try h.registry().db.scalarInt("SELECT count(*) FROM sessions WHERE agent_session_id = 's1' AND ended_at IS NULL") == 1)
    }

    @Test func stopReachesDescendantsInTheirOwnSession() throws {
        let (parent, out) = try spawn("""
        import os,subprocess,sys,time
        c = subprocess.Popen([sys.executable, '-c', 'import os,time; print(os.getpid(), flush=True); time.sleep(60)'], start_new_session=True, stdout=subprocess.PIPE)
        child = c.stdout.readline().decode().strip()
        print(os.getpid(), child, flush=True)
        time.sleep(60)
        """)
        defer { parent.terminate() }
        let ids = readLine(out).split(separator: " ").compactMap { Int32($0) }
        try #require(ids.count == 2)
        let table = ProcessTable.capture()
        let target = try #require(table[ids[0]]?.identity)
        guard case .success(let plan) = ProcessStopper.plan(target, table: table, isProtected: { _ in nil }) else { Issue.record("refused"); return }
        #expect(plan.victims.contains { $0.pid == ids[1] })
        #expect(ProcessStopper.execute(plan, force: false, timeoutMs: 3000) == .terminated)
        #expect(ProcessTable.capture()[ids[1]] == nil || ProcessTable.capture()[ids[1]]?.zombie == true)
    }

    @Test func staleClaudeSessionFileDoesNotMakeAnotherProgramAnAgent() throws {
        let t = TempDir("sess"); defer { t.cleanup() }
        let me = getpid() // this test runner is not Claude Code
        t.write(".claude/sessions/\(me).json", "{\"pid\": \(me), \"sessionId\": \"stale\", \"cwd\": \"/\"}")
        t.write(".claude/sessions/huge.json", "{\"pid\": 99999999999, \"sessionId\": \"bad\"}")
        let radar = ProcessRadar(home: t.path, paths: AirbagPaths(home: t.url.appendingPathComponent("home")))
        #expect(radar.claudeSessionFiles(table: ProcessTable.capture()).isEmpty)
    }

    @Test func wakeSocketDeliversMessages() async throws {
        let t = TempDir("sock"); defer { t.cleanup() }
        let paths = AirbagPaths(home: URL(fileURLWithPath: "/tmp/ab-\(getpid())-\(Int.random(in: 0..<99999))"))
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let got = Box<[String]>([])
        let server = WakeSocketServer(paths: paths) { msg in got.with { $0.append(msg["op"] as? String ?? "?") } }
        try server.start()
        defer { server.stop() }
        #expect(throws: (any Error).self) { try WakeSocketServer(paths: paths) { _ in }.start() } // second instance refused
        for i in 0..<5 { WakeSocket.notify(paths: paths, message: ["op": "hook\(i)"]) }
        for _ in 0..<40 where got.with({ $0.count }) < 5 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(got.with { $0.count } == 5)
    }
}
