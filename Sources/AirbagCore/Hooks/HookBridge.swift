import Darwin
import Foundation

public enum AskMode: String, Sendable, Codable {
    /// Show the agent's own approval prompt.
    case native
    /// Deny with an explanation; the user can approve once in Airbag and the agent retries.
    case denyWithAllowance = "deny_with_allowance"
    /// Snapshot and allow (zero interruptions).
    case allowSnapshot = "allow_snapshot"
}

public struct HookBridgeConfig: Sendable {
    public var paths: AirbagPaths
    public var environment: [String: String]
    public var snapshotDeadlineMs = 1500
    public var lockWaitMs = 800
    public var askFallback: [AgentKind: AskMode] = [.claudeCode: .native, .codex: .denyWithAllowance, .cursor: .native,
                                                    .gemini: .denyWithAllowance, .copilot: .native]
    public var askUnderBypass: AskMode = .denyWithAllowance
    /// Spawn a detached `airbag snapshot` to finish cold or incomplete snapshots (off in tests).
    public var spawnBackground = true
    public var home: String = NSHomeDirectory()

    public init(paths: AirbagPaths = .resolve(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.environment = environment
    }
}

/// Result of processing one hook invocation (the CLI prints `output`).
public struct HookOutcome: Sendable {
    public var output: String?
    public var envelope: HookEnvelope?
    public var verdict: GuardVerdict?
    public var snapshot: SnapshotInfo?
    public var snapshotSkipped: String?
    public var finalDecision: String?
    public var record: HookRecord?
}

/// Thread-safe holder for the one reply a hook may print (shared with the watchdog).
public final class OutputSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var decided: String?
    private var printed = false
    public init(initial: String?) { decided = initial }

    public func setDecided(_ s: String?) { lock.lock(); decided = s; lock.unlock() }

    /// Prints the decided reply once. Returns false if a reply was already printed.
    @discardableResult
    public func printDecided() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return emit(decided)
    }

    /// Prints `text` once (nil prints nothing but still claims the slot).
    @discardableResult
    public func printFinal(_ text: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return emit(text)
    }

    private func emit(_ text: String?) -> Bool {
        guard !printed else { return false }
        printed = true
        if let text { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        return true
    }
}

public struct HookBridge {
    public let config: HookBridgeConfig
    public init(config: HookBridgeConfig) { self.config = config }

    public func handle(payload: Data, declared: AgentKind, eventHint: String?, slot: OutputSlot? = nil) -> HookOutcome {
        let t0 = Clock.monotonicNs()
        var outcome = HookOutcome()
        var timing: [String: Int] = [:]
        guard let json = JSONObject.parse(payload) else {
            Log.shared.warn("hook \(declared.rawValue): unparseable payload (\(payload.count) bytes)")
            outcome.output = AgentAdapter.encode(.neutral, as: declared, event: HookEnvelope(agent: declared, replyAs: declared, kind: .other, rawEvent: ""))
            return outcome
        }
        let env = AgentAdapter.parse(json, declared: declared, eventHint: eventHint, environment: config.environment)
        outcome.envelope = env
        timing["parse"] = Clock.elapsedMs(since: t0)

        // Cursor runs hooks it imported from ~/.claude/settings.json; when Airbag's native Cursor hook is installed it
        // handles the command, so this route stays out of the way.
        if env.agent == .cursor && declared == .claudeCode && HookInstaller(home: config.home, command: "").isInstalled(.cursor) {
            outcome.output = AgentAdapter.encode(.neutral, as: declared, event: env)
            return outcome
        }

        // Where are we?
        let rawCwd = env.cwd ?? env.launchRoot ?? FileManager.default.currentDirectoryPath
        let cwd = FileSystem.canonicalPath(rawCwd) ?? FileSystem.resolvedPath(rawCwd)
        let launch = env.launchRoot.flatMap { FileSystem.canonicalPath($0) }
        let root = RootResolver.resolve(cwd: cwd, registeredRoots: launch.map { [$0] } ?? [])
        let snapshotRoot = try? SnapshotStore.validateRoot(root, paths: config.paths)
        let layout = GitLayout.inspect(root: root, home: config.home)
        var roots = [root]
        if layout.projectRoot != root { roots.append(layout.projectRoot) }
        if let l = launch, !roots.contains(l), (try? SnapshotStore.validateRoot(l, paths: config.paths)) != nil { roots.append(l) }
        roots = roots.filter { (try? SnapshotStore.validateRoot($0, paths: config.paths)) != nil }

        let registry = try? Registry(paths: config.paths, role: .cli)
        timing["db_open"] = Clock.elapsedMs(since: t0)
        let readSetting = { (key: String) -> String? in registry.flatMap { $0.setting(key, as: String.self) } }

        var record = HookRecord(agent: env.agent.rawValue, kind: env.kind.rawValue)
        record.agentSessionID = env.sessionID
        record.cwd = cwd
        record.launchRoot = launch
        record.transcriptPath = env.transcriptPath
        record.permissionMode = env.permissionMode
        record.model = env.model
        record.title = env.title
        record.toolUseID = env.toolUseID
        record.dedupeKey = env.dedupeKey
        record.background = env.background
        record.endReason = env.reason
        if snapshotRoot != nil || layout.commonDir != nil {
            record.project = .init(root: layout.projectRoot, commonDir: layout.commonDir, kind: layout.commonDir == nil ? "plain" : "git",
                                   worktreePath: layout.root, worktreeKind: layout.worktreeKind, worktreeName: layout.worktreeName)
        }
        if let cmd = env.command {
            record.command = Redactor.redact(cmd)
            record.commandHash = Hashing.sha256Hex(cmd)
        }
        if let loc = AgentLocator.locate(env.agent, environment: config.environment) {
            record.surface = loc.surface
            record.agentProcess = .init(pid: loc.process.pid, startUs: loc.process.startUs, exe: loc.exe, ppid: loc.process.ppid,
                                        pgid: loc.process.pgid, hostPid: loc.host?.pid, hostStartUs: loc.host?.startUs,
                                        terminalApp: loc.hostApp, tty: nil)
        }
        timing["locate"] = Clock.elapsedMs(since: t0)
        let sessionKey = env.sessionID.map { "\(env.agent.rawValue):\($0)" }
        let duplicate = env.dedupeKey.flatMap { k in registry?.existingDecision(dedupeKey: k) } != nil

        func takeSnapshot(_ trigger: SnapshotTrigger, label: String?) -> (SnapshotInfo?, String?) {
            guard let r = snapshotRoot else { return (nil, "no_root") }
            if duplicate { return (nil, "duplicate_route") }
            let exists = SnapshotStore.storeExists(root: r, paths: config.paths)
            guard let store = try? SnapshotStore.open(root: r, paths: config.paths) else { return (nil, "store_error") }
            let deadline = Clock.monotonicNs() + UInt64(config.snapshotDeadlineMs) * 1_000_000
            let outcome = store.snapshot(SnapshotRequest(trigger: exists ? trigger : .initial, label: label, sessionKey: sessionKey,
                                                         deadlineNs: deadline, lockWaitMs: config.lockWaitMs))
            switch outcome {
            case .created(let s, let st):
                timing["snapshot_files"] = st.walked
                if !s.complete { spawnBackgroundSnapshot(r) }
                record.snapshot = .init(id: s.id, rootID: store.rootID, rootPath: r, seq: s.seq, trigger: s.trigger.rawValue,
                                        fileCount: s.fileCount, changedCount: s.changedCount, bytesAdded: s.bytesAdded,
                                        durationMs: st.durationMs, complete: s.complete, label: s.label)
                return (s, s.complete ? nil : "incomplete")
            case .unchanged(let latest, let st):
                if let l = latest, !l.complete { spawnBackgroundSnapshot(r) }
                if let l = latest {
                    // Nothing changed since `l`: the event points at it (restoring it = state right before this command).
                    record.snapshot = .init(id: l.id, rootID: store.rootID, rootPath: r, seq: l.seq, trigger: l.trigger.rawValue,
                                            fileCount: l.fileCount, changedCount: l.changedCount, bytesAdded: l.bytesAdded,
                                            durationMs: st.durationMs, complete: l.complete, label: l.label)
                }
                return (latest, latest?.complete == false ? "incomplete" : nil)
            case .busy: return (nil, "busy")
            case .lowDisk: return (nil, "low_disk")
            case .failed(let m): Log.shared.error("snapshot failed: \(m)"); return (nil, "failed")
            }
        }

        var reply: HookReply = .neutral
        switch env.kind {
        case .preShell, .permissionRequest:
            guard let command = env.command, !command.isEmpty else { reply = .allow; break }
            let context = GuardContext(cwd: cwd, home: config.home, roots: roots, environment: config.environment,
                                       airbagHome: FileSystem.canonicalPath(config.paths.home.path) ?? config.paths.home.path)
            var verdict = RuleEngine().evaluate(command, context: context)
            timing["rules"] = Clock.elapsedMs(since: t0)
            let primary = verdict.primary
            func guardRef(_ decision: String) -> HookRecord.GuardRef? {
                guard let p = primary else { return nil }
                return .init(ruleId: p.ruleId, severity: verdict.decision == .block ? "block" : (verdict.decision == .ask ? "ask" : "warn"),
                             decision: decision, matched: Redactor.redact(p.matched), reason: p.reason)
            }
            if verdict.decision == .block {
                let msg = verdict.agentMessage(command: command)
                reply = .deny(agentReason: msg, userMessage: userMessage(verdict, command: command, blocked: true))
                slot?.setDecided(AgentAdapter.encode(reply, as: declared, event: env))
                record.decision = "deny"
                record.guardEntry = guardRef("deny")
                break
            }
            // Snapshot before anything that may run (allow, or ask that the user may approve).
            var snap: SnapshotInfo?
            var skipped: String?
            if verdict.snapshot != .none || verdict.decision == .ask {
                let label = "Before `\(String(Redactor.redact(command).prefix(80)))`"
                (snap, skipped) = takeSnapshot(.preCommand, label: label)
                outcome.snapshot = snap
                outcome.snapshotSkipped = skipped
                record.snapshotSkipped = skipped
                timing["snapshot"] = Clock.elapsedMs(since: t0)
            }
            // A destructive-but-recoverable command needs a usable snapshot; without one, escalate to ask.
            if verdict.decision == .allow && verdict.snapshot == .required && (skipped != nil || snap == nil) && skipped != "duplicate_route" {
                let why = skipped ?? "unknown"
                let finding = GuardFinding(ruleId: "snapshot.unavailable", decision: .ask, snapshot: .required,
                                           reason: "it is destructive and Airbag could not take a complete snapshot first (\(why.replacingOccurrences(of: "_", with: " "))).",
                                           matched: primary?.matched ?? command)
                verdict = GuardVerdict(decision: .ask, snapshot: .required, findings: verdict.findings + [finding])
            }
            if verdict.decision == .ask {
                let bypass = env.permissionMode == "bypassPermissions"
                let mode: AskMode = bypass ? config.askUnderBypass
                    : (readSetting("hook.askFallback.\(env.agent.rawValue)").flatMap(AskMode.init(rawValue:)) ?? config.askFallback[env.agent] ?? .denyWithAllowance)
                let canNative = AgentAdapter.supportsNativeAsk(declared, kind: env.kind, permissionMode: env.permissionMode)
                    && !(env.agent == .cursor && declared == .claudeCode) // Cursor's preToolUse does not enforce ask
                if let reg = registry, let sid = env.sessionID, let hash = record.commandHash,
                   reg.consumeAllowToken(agent: env.agent.rawValue, agentSessionID: sid, commandHash: hash) {
                    reply = .allow
                    record.decision = "allow_once"
                    record.guardEntry = guardRef("allow_once")
                } else if mode == .native && canNative {
                    reply = .ask(agentReason: verdict.agentMessage(command: command, snapshotId: snap?.id),
                                 userMessage: userMessage(verdict, command: command, blocked: false))
                    record.decision = "ask"
                    record.guardEntry = guardRef("ask")
                } else if mode == .allowSnapshot && snap != nil {
                    reply = .allow
                    record.decision = "allow_fallback"
                    record.guardEntry = guardRef("allow_fallback")
                } else {
                    let msg = verdict.agentMessage(command: command, snapshotId: snap?.id)
                        + " The user can approve it once in Airbag (menu bar → Guard → Allow once); after that, run exactly the same command again."
                    reply = .deny(agentReason: msg, userMessage: userMessage(verdict, command: command, blocked: false))
                    record.decision = "deny_fallback"
                    record.guardEntry = guardRef("deny_fallback")
                }
            } else {
                reply = .allow
                record.decision = "allow"
                if verdict.snapshot == .required, let p = primary, p.decision == .allow {
                    record.guardEntry = .init(ruleId: p.ruleId, severity: "warn", decision: "allow", matched: Redactor.redact(p.matched), reason: p.reason)
                }
            }
            outcome.verdict = verdict
        case .postShell, .shellFailed:
            if let command = env.command {
                let context = GuardContext(cwd: cwd, home: config.home, roots: roots, airbagHome: config.paths.home.path)
                if RuleEngine().evaluate(command, context: context).snapshot != .none {
                    let (snap, skipped) = takeSnapshot(.postCommand, label: "After `\(String(Redactor.redact(command).prefix(80)))`")
                    outcome.snapshot = snap; outcome.snapshotSkipped = skipped; record.snapshotSkipped = skipped
                }
            }
            reply = .neutral
        case .preEdit:
            let (snap, skipped) = takeSnapshot(.preCommand, label: "Before file edit")
            outcome.snapshot = snap; outcome.snapshotSkipped = skipped
            reply = .neutral
        case .sessionStart:
            if let r = snapshotRoot, !SnapshotStore.storeExists(root: r, paths: config.paths) { spawnBackgroundSnapshot(r) }
            reply = .neutral
        default:
            reply = .neutral
        }
        outcome.finalDecision = record.decision
        outcome.output = AgentAdapter.encode(reply, as: declared, event: env)
        timing["total"] = Clock.elapsedMs(since: t0)
        record.timing = timing

        // Persist (never blocks the decision).
        if !duplicate {
            if let reg = registry {
                do {
                    try reg.record(record)
                    reg.ingestSpool(limit: 20)
                    reg.checkpointIfLarge(thresholdBytes: 16 << 20)
                } catch {
                    Log.shared.warn("registry write failed (\(error)); spooling")
                    Registry.spool(record, paths: config.paths)
                }
            } else {
                Registry.spool(record, paths: config.paths)
            }
            WakeSocket.notify(paths: config.paths, message: ["op": "hook", "kind": env.kind.rawValue, "agent": env.agent.rawValue,
                                                             "decision": record.decision ?? ""])
        }
        outcome.record = record
        Log.shared.info("hook \(env.agent.rawValue)/\(env.rawEvent) session=\(env.sessionID?.prefix(8) ?? "-") decision=\(record.decision ?? "-") snapshot=\(outcome.snapshot?.id ?? outcome.snapshotSkipped ?? "-") total=\(timing["total"] ?? 0)ms")
        return outcome
    }

    func userMessage(_ v: GuardVerdict, command: String, blocked: Bool) -> String {
        let cmd = command.count > 80 ? String(command.prefix(77)) + "…" : command
        let reason = v.primary?.reason ?? ""
        return blocked ? "Airbag blocked `\(cmd)`: \(reason)" : "Airbag: `\(cmd)` needs your approval — \(reason)"
    }

    func spawnBackgroundSnapshot(_ root: String) {
        guard config.spawnBackground else { return }
        let marker = SnapshotStore.storeDirectory(forCanonicalRoot: root, paths: config.paths) + "/background.pid"
        if let s = try? String(contentsOfFile: marker, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 { return }
        let exe = ProcInfo.currentExecutablePath()
        BackgroundSpawner.spawnDetached(exe, ["snapshot", "--root", root, "--initial", "--background-marker", marker],
                                        environment: ["AIRBAG_HOME": config.paths.home.path])
    }
}

public enum BackgroundSpawner {
    /// Starts a process in its own session with stdio on /dev/null; does not wait for it.
    @discardableResult
    public static func spawnDetached(_ exe: String, _ args: [String], environment extra: [String: String] = [:]) -> Int32? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0)=\($1)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        return rc == 0 ? pid : nil
    }
}
