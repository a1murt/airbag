import Foundation

/// Installs, removes and inspects Airbag's hooks in each agent's user-level configuration (ADR-020: never project
/// files). Edits keep every foreign key and handler and the original key order; a backup is written first.
public struct HookInstaller {
    public let home: String
    /// Absolute path of the `airbag` CLI written into configs. Keep it stable: Codex trusts hooks by command hash.
    public let command: String

    public init(home: String = NSHomeDirectory(), command: String) {
        self.home = home
        self.command = command
    }

    public struct AgentStatus: Codable, Sendable, Equatable {
        public let agent: AgentKind
        public let detected: Bool
        public let configPath: String
        public let installed: Bool
        /// Installed entries match what this build would write (same command path and events).
        public let current: Bool
        /// Airbag entries pointing at another binary (the app moved or an old version is referenced).
        public let staleCommand: Bool
        public let note: String?
    }

    public struct Change: Sendable {
        public let agent: AgentKind
        public let path: String
        public let before: String?
        public let after: String?
        public let backup: String?
        public var changed: Bool { before != after }
    }

    // MARK: locations and detection

    public func configPath(_ agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: return home + "/.claude/settings.json"
        case .codex: return home + "/.codex/hooks.json"
        case .cursor: return home + "/.cursor/hooks.json"
        case .gemini: return home + "/.gemini/settings.json"
        case .copilot: return home + "/.copilot/hooks/airbag.json"
        }
    }

    func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    func onPath(_ names: [String]) -> Bool {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin",
                    home + "/.volta/bin", home + "/.cargo/bin"]
        return dirs.contains { d in names.contains { exists(d + "/" + $0) } }
    }

    public func detect(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claudeCode: return exists(home + "/.claude") || onPath(["claude"]) || exists(home + "/Library/Application Support/Claude/claude-code")
        case .codex: return exists(home + "/.codex") || onPath(["codex"]) || exists("/Applications/Codex.app")
        case .cursor: return exists(home + "/.cursor") || exists("/Applications/Cursor.app") || onPath(["cursor-agent"])
        case .gemini: return exists(home + "/.gemini") || onPath(["gemini"])
        case .copilot: return exists(home + "/.copilot") || onPath(["copilot"])
        }
    }

    // MARK: desired entries

    var shellCommand: String {
        command.contains(" ") || command.contains("'") ? "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'" : command
    }

    func cmd(_ agent: AgentKind, _ event: String?) -> String {
        shellCommand + " hook " + agent.rawValue + (event.map { " " + $0 } ?? "")
    }

    typealias Entry = (event: String, group: OrderedJSON)

    func desired(_ agent: AgentKind, strict: Bool) -> [Entry] {
        func obj(_ kv: [(String, OrderedJSON)]) -> OrderedJSON { .object(kv) }
        func num(_ n: Int) -> OrderedJSON { .number(String(n)) }
        func s(_ v: String) -> OrderedJSON { .string(v) }
        switch agent {
        case .claudeCode:
            func handler(_ timeout: Int, extra: [(String, OrderedJSON)] = []) -> OrderedJSON {
                obj([("type", s("command")), ("command", s(command)), ("args", .array([s("hook"), s("claude-code")])), ("timeout", num(timeout))] + extra)
            }
            return [
                ("SessionStart", obj([("hooks", .array([handler(5)]))])),
                ("PreToolUse", obj([("matcher", s("Bash|Monitor")), ("hooks", .array([handler(30, extra: strict ? [("onFailure", s("block"))] : [])]))])),
                ("PostToolUse", obj([("matcher", s("Bash|Monitor")), ("hooks", .array([handler(30, extra: [("async", .bool(true))])]))])),
                ("SessionEnd", obj([("hooks", .array([handler(2)]))])),
            ]
        case .codex:
            func handler(_ ev: String, _ timeout: Int, status: String? = nil, async: Bool = false) -> OrderedJSON {
                var kv: [(String, OrderedJSON)] = [("type", s("command")), ("command", s(cmd(.codex, ev))), ("timeout", num(timeout))]
                if async { kv.append(("async", .bool(true))) }
                if let status { kv.append(("statusMessage", s(status))) }
                return obj(kv)
            }
            return [
                ("SessionStart", obj([("hooks", .array([handler("session-start", 5)]))])),
                ("UserPromptSubmit", obj([("hooks", .array([handler("prompt", 5)]))])),
                ("PreToolUse", obj([("matcher", s("^Bash$")), ("hooks", .array([handler("pre-bash", 30, status: "Airbag: snapshot and safety check")]))])),
                ("PreToolUse", obj([("matcher", s("^apply_patch$")), ("hooks", .array([handler("pre-edit", 10, status: "Airbag: snapshot")]))])),
                ("PermissionRequest", obj([("matcher", s("^Bash$")), ("hooks", .array([handler("permission", 10)]))])),
                ("PostToolUse", obj([("matcher", s("^Bash$")), ("hooks", .array([handler("post-bash", 20, async: true)]))])),
                ("SessionEnd", obj([("hooks", .array([handler("session-end", 2)]))])),
            ]
        case .cursor:
            func handler(_ timeout: Int, failClosed: Bool = false) -> OrderedJSON {
                var kv: [(String, OrderedJSON)] = [("command", s(cmd(.cursor, nil))), ("timeout", num(timeout))]
                if failClosed { kv.append(("failClosed", .bool(true))) }
                return obj(kv)
            }
            return [
                ("sessionStart", handler(5)),
                ("sessionEnd", handler(5)),
                ("beforeShellExecution", handler(20, failClosed: strict)),
                ("afterShellExecution", handler(5)),
            ]
        case .gemini:
            func group(_ matcher: String, _ timeoutMs: Int) -> OrderedJSON {
                obj([("matcher", s(matcher)), ("hooks", .array([obj([("name", s("airbag")), ("type", s("command")),
                                                                     ("command", s(cmd(.gemini, nil))), ("timeout", num(timeoutMs))])]))])
            }
            return [
                ("SessionStart", group("*", 5000)),
                ("SessionEnd", group("*", 5000)),
                ("BeforeTool", group("run_shell_command", 20000)),
                ("AfterTool", group("run_shell_command", 5000)),
            ]
        case .copilot:
            func handler(_ ev: String, _ timeout: Int, matcher: String? = nil) -> OrderedJSON {
                var kv: [(String, OrderedJSON)] = [("type", s("command"))]
                if let matcher { kv.append(("matcher", s(matcher))) }
                kv += [("exec", s(command)), ("args", .array([s("hook"), s("copilot"), s(ev)])), ("timeoutSec", num(timeout))]
                return obj(kv)
            }
            return [
                ("sessionStart", handler("sessionStart", 5)),
                ("sessionEnd", handler("sessionEnd", 5)),
                ("preToolUse", handler("preToolUse", 20, matcher: "bash|powershell")),
                ("postToolUse", handler("postToolUse", 5, matcher: "bash|powershell")),
            ]
        }
    }

    // MARK: recognising Airbag entries

    /// A handler written by any Airbag version: `airbag hook …` as a command string, or exec form with args[0] == "hook".
    static func isAirbagHandler(_ h: OrderedJSON) -> Bool {
        if let c = h["command"]?.stringValue ?? h["bash"]?.stringValue {
            if c.range(of: #"airbag['"]?\s+hook\b"#, options: .regularExpression) != nil { return true }
            if (c as NSString).lastPathComponent == "airbag", h["args"]?.arrayValue?.first?.stringValue == "hook" { return true }
        }
        if let e = h["exec"]?.stringValue, (e as NSString).lastPathComponent == "airbag", h["args"]?.arrayValue?.first?.stringValue == "hook" {
            return true
        }
        return false
    }

    static func handlerCommand(_ h: OrderedJSON) -> String? {
        if let e = h["exec"]?.stringValue { return e }
        guard let c = h["command"]?.stringValue else { return nil }
        if h["args"] != nil { return c }
        // "'/path with space/airbag' hook x" or "/path/airbag hook x"
        if c.hasPrefix("'"), let end = c.dropFirst().firstIndex(of: "'") { return String(c[c.index(after: c.startIndex)..<end]) }
        return c.components(separatedBy: " hook ").first
    }

    /// Nested layout used by Claude, Codex and Gemini: event → [group {matcher?, hooks: [handler]}].
    func usesNestedGroups(_ agent: AgentKind) -> Bool { agent == .claudeCode || agent == .codex || agent == .gemini }

    /// Removes every Airbag handler from a `hooks` object. Returns the cleaned object and the commands found.
    func strip(_ hooks: OrderedJSON, nestedGroups: Bool) -> (OrderedJSON, [String]) {
        guard case .object(let events) = hooks else { return (hooks, []) }
        var found: [String] = []
        var out: [(String, OrderedJSON)] = []
        for (event, value) in events {
            guard case .array(let items) = value else { out.append((event, value)); continue }
            var kept: [OrderedJSON] = []
            for item in items {
                if nestedGroups, case .array(let handlers)? = item["hooks"] {
                    let mine = handlers.filter(Self.isAirbagHandler)
                    found += mine.compactMap(Self.handlerCommand)
                    if mine.isEmpty { kept.append(item); continue }
                    let others = handlers.filter { !Self.isAirbagHandler($0) }
                    if !others.isEmpty { var g = item; g["hooks"] = .array(others); kept.append(g) }
                } else if Self.isAirbagHandler(item) {
                    found += Self.handlerCommand(item).map { [$0] } ?? []
                } else {
                    kept.append(item)
                }
            }
            if !kept.isEmpty { out.append((event, .array(kept))) }
        }
        return (.object(out), found)
    }

    // MARK: read / plan / write

    func load(_ path: String) throws -> (text: String?, json: OrderedJSON) {
        guard let data = FileManager.default.contents(atPath: path) else { return (nil, .object([])) }
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, .object([])) }
        let json = try OrderedJSON.parse(text)
        guard json.isObject else { throw SnapshotError.io("\(path) is not a JSON object") }
        return (text, json)
    }

    /// The file content after installing (or removing, with `install: false`) Airbag's hooks.
    public func plan(_ agent: AgentKind, install: Bool, strict: Bool = false) throws -> Change {
        let path = configPath(agent)
        if agent == .copilot {
            let before = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
            guard install else { return Change(agent: agent, path: path, before: before, after: nil, backup: nil) }
            var hooks: [(String, OrderedJSON)] = []
            for (event, h) in desired(agent, strict: strict) {
                if let i = hooks.firstIndex(where: { $0.0 == event }), case .array(var a) = hooks[i].1 { a.append(h); hooks[i].1 = .array(a) }
                else { hooks.append((event, .array([h]))) }
            }
            let after = OrderedJSON.object([("version", .number("1")), ("hooks", .object(hooks))]).serialized()
            return Change(agent: agent, path: path, before: before, after: after, backup: nil)
        }
        let loaded = try load(path)
        let before = loaded.text
        var json = loaded.json
        let nestedGroups = usesNestedGroups(agent)
        let (cleaned, _) = strip(json["hooks"] ?? .object([]), nestedGroups: nestedGroups)
        var hooks = cleaned
        if install {
            for (event, group) in desired(agent, strict: strict) {
                var arr = hooks[event]?.arrayValue ?? []
                arr.append(group)
                hooks[event] = .array(arr)
            }
        }
        if case .object(let kv) = hooks, kv.isEmpty { json["hooks"] = nil } else { json["hooks"] = hooks }
        if agent == .cursor && install && json["version"] == nil {
            if case .object(let kv) = json { json = .object([("version", .number("1"))] + kv) }
        }
        if before == nil && !install { return Change(agent: agent, path: path, before: nil, after: nil, backup: nil) }
        let after = json.serialized()
        if let b = before, (try? OrderedJSON.parse(b)) == json { return Change(agent: agent, path: path, before: b, after: b, backup: nil) }
        return Change(agent: agent, path: path, before: before, after: after, backup: nil)
    }

    @discardableResult
    public func install(_ agent: AgentKind, strict: Bool = false, backupDirectory: String?) throws -> Change {
        try apply(try plan(agent, install: true, strict: strict), backupDirectory: backupDirectory)
    }

    @discardableResult
    public func uninstall(_ agent: AgentKind, backupDirectory: String?) throws -> Change {
        let change = try plan(agent, install: false)
        if agent == .copilot {
            guard let before = change.before else { return change }
            let backup = try backupFile(change.path, content: before, agent: agent, backupDirectory: backupDirectory)
            try FileManager.default.removeItem(atPath: change.path)
            return Change(agent: agent, path: change.path, before: before, after: nil, backup: backup)
        }
        return try apply(change, backupDirectory: backupDirectory)
    }

    func backupFile(_ path: String, content: String, agent: AgentKind, backupDirectory: String?) throws -> String? {
        guard let dir = backupDirectory else { return nil }
        try FileSystem.ensureDirectory(dir, mode: 0o700)
        let dest = "\(dir)/\(agent.rawValue)-\((path as NSString).lastPathComponent)-\(Clock.nowMs())"
        try FileSystem.writeAtomically(Data(content.utf8), to: dest, mode: 0o600)
        return dest
    }

    func apply(_ change: Change, backupDirectory: String?) throws -> Change {
        guard change.changed, let after = change.after else { return change }
        var backup: String?
        if let before = change.before { backup = try backupFile(change.path, content: before, agent: change.agent, backupDirectory: backupDirectory) }
        let dir = (change.path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) { try FileSystem.ensureDirectory(dir, mode: 0o755) }
        try FileSystem.writeAtomically(Data(after.utf8), to: change.path, mode: change.before == nil ? 0o600 : nil)
        return Change(agent: change.agent, path: change.path, before: change.before, after: after, backup: backup)
    }

    // MARK: status

    public func isInstalled(_ agent: AgentKind) -> Bool {
        guard let (_, json) = try? load(configPath(agent)) else { return false }
        if agent == .copilot { return exists(configPath(agent)) }
        return !strip(json["hooks"] ?? .object([]), nestedGroups: usesNestedGroups(agent)).1.isEmpty
    }

    public func status(_ agent: AgentKind) -> AgentStatus {
        let path = configPath(agent)
        let detected = detect(agent)
        do {
            if agent == .copilot {
                guard exists(path) else { return AgentStatus(agent: agent, detected: detected, configPath: path, installed: false, current: false, staleCommand: false, note: nil) }
                let (text, json) = try load(path)
                let current = text.map { (try? OrderedJSON.parse($0)) == (try? OrderedJSON.parse(try plan(agent, install: true).after ?? "")) } ?? false
                let commands = strip(json["hooks"] ?? .object([]), nestedGroups: false).1
                return AgentStatus(agent: agent, detected: detected, configPath: path, installed: true, current: current,
                                   staleCommand: commands.contains { $0 != command }, note: nil)
            }
            let (_, json) = try load(path)
            let commands = strip(json["hooks"] ?? .object([]), nestedGroups: usesNestedGroups(agent)).1
            let installed = !commands.isEmpty
            let plannedStrict = try plan(agent, install: true, strict: true)
            let plannedNormal = try plan(agent, install: true, strict: false)
            let current = installed && (!plannedNormal.changed || !plannedStrict.changed)
            var note: String?
            if agent == .codex && installed { note = "Codex runs new hooks only after you trust them: open Codex, type /hooks and press t." }
            return AgentStatus(agent: agent, detected: detected, configPath: path, installed: installed, current: current,
                               staleCommand: commands.contains { $0 != command }, note: note)
        } catch {
            return AgentStatus(agent: agent, detected: detected, configPath: path, installed: false, current: false, staleCommand: false,
                               note: "cannot read \(path): \(error)")
        }
    }
}
