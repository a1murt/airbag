import Foundation

public enum AgentKind: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case gemini
    case copilot

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .copilot: return "GitHub Copilot CLI"
        }
    }
}

public enum HookEventKind: String, Sendable, Codable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case preShell = "pre_shell"
    case postShell = "post_shell"
    case shellFailed = "shell_failed"
    case preEdit = "pre_edit"
    case permissionRequest = "permission_request"
    case prompt
    case stop
    case cwdChanged = "cwd_changed"
    case other
}

/// An agent hook invocation, normalised across agents.
public struct HookEnvelope: Sendable {
    /// Agent whose payload shape this is.
    public var agent: AgentKind
    /// Agent whose config invoked us (decides the reply format; differs when Cursor runs Claude-format hooks).
    public var replyAs: AgentKind
    public var kind: HookEventKind
    public var rawEvent: String
    public var sessionID: String?
    public var cwd: String?
    public var launchRoot: String?
    public var workspaceRoots: [String] = []
    public var command: String?
    public var toolName: String?
    public var toolUseID: String?
    public var turnID: String?
    public var background = false
    public var sandboxed = false
    public var transcriptPath: String?
    public var permissionMode: String?
    public var model: String?
    public var reason: String?
    public var source: String?
    public var title: String?
    public var interrupted = false
    public var exitCode: Int?

    public init(agent: AgentKind, replyAs: AgentKind, kind: HookEventKind, rawEvent: String) {
        self.agent = agent; self.replyAs = replyAs; self.kind = kind; self.rawEvent = rawEvent
    }

    /// Stable key so the same shell command seen through two hook routes is processed once (doc 11 §4.9).
    public var dedupeKey: String? {
        switch kind {
        case .preShell, .postShell, .shellFailed, .permissionRequest, .preEdit:
            // Only a real per-call id identifies "the same call through another route"; command text is not unique
            // (an agent may run the same command twice in one turn, and each run needs its own snapshot).
            guard let t = toolUseID, !t.isEmpty else { return nil }
            return "\(agent.rawValue):\(t):\(kind.rawValue)"
        default:
            guard let s = sessionID else { return nil }
            return "\(agent.rawValue):\(s):\(kind.rawValue):\(Clock.nowMs() / 1000)"
        }
    }
}

/// Reply the hook prints, before encoding into an agent's format.
public enum HookReply: Equatable, Sendable {
    case allow
    case ask(agentReason: String, userMessage: String)
    case deny(agentReason: String, userMessage: String)
    /// Print nothing / an empty object: used for lifecycle events.
    case neutral
}

public enum AgentAdapter {
    /// Parses a payload. `declared` is the agent named in the hook command; the payload shape wins when it is
    /// unmistakably another agent's (Cursor invoking hooks it imported from `~/.claude/settings.json`).
    public static func parse(_ json: JSONObject, declared: AgentKind, eventHint: String?, environment: [String: String]) -> HookEnvelope {
        var agent = declared
        if json["cursor_version"] != nil || json["conversation_id"] != nil && json["workspace_roots"] != nil { agent = .cursor }
        let event = json.string("hook_event_name") ?? json.string("hookEventName") ?? eventHint ?? ""
        var e = HookEnvelope(agent: agent, replyAs: declared, kind: .other, rawEvent: event)
        e.cwd = json.string("cwd")
        e.transcriptPath = json.string("transcript_path")
        e.permissionMode = json.string("permission_mode")
        e.model = json.string("model")
        e.reason = json.string("reason")
        e.source = json.string("source")
        e.toolUseID = json.string("tool_use_id")
        e.turnID = json.string("turn_id") ?? json.string("generation_id") ?? json.string("prompt_id")

        switch agent {
        case .claudeCode:
            e.sessionID = json.string("session_id") ?? environment["CLAUDE_CODE_SESSION_ID"]
            e.launchRoot = environment["CLAUDE_PROJECT_DIR"]
            e.title = json.string("session_title")
            e.toolName = json.string("tool_name")
            let input = json.object("tool_input")
            e.command = input?.string("command")
            e.background = input?.bool("run_in_background") ?? false
            e.kind = claudeKind(event, tool: e.toolName)
            if e.kind == .postShell, let resp = json.object("tool_response") { e.interrupted = resp.bool("interrupted") ?? false }
        case .codex:
            e.sessionID = json.string("session_id")
            e.toolName = json.string("tool_name")
            e.command = json.object("tool_input")?.string("command") ?? json.object("tool_input")?.strings("command").joined(separator: " ")
            if e.command == "" { e.command = nil }
            e.kind = claudeKind(event, tool: e.toolName)
            if e.toolName == "apply_patch" && e.kind == .preShell { e.kind = .preEdit }
            if event == "PermissionRequest" { e.kind = .permissionRequest }
            if event == "Interrupt" { e.kind = .stop }
            if e.kind == .other, let hint = eventHint { e.kind = hintKind(hint) }
        case .cursor:
            e.sessionID = json.string("conversation_id") ?? json.string("session_id")
            e.workspaceRoots = json.strings("workspace_roots")
            e.launchRoot = environment["CURSOR_PROJECT_DIR"] ?? e.workspaceRoots.first
            e.sandboxed = json.bool("sandbox") ?? false
            e.toolName = json.string("tool_name")
            switch event {
            case "beforeShellExecution": e.kind = .preShell; e.command = json.string("command")
            case "afterShellExecution": e.kind = .postShell; e.command = json.string("command")
            case "preToolUse", "PreToolUse":
                if e.toolName == "Shell" || e.toolName == "Bash" {
                    e.kind = .preShell
                    let input = json.object("tool_input")
                    e.command = input?.string("command")
                    if let wd = input?.string("working_directory") { e.cwd = wd }
                }
            case "postToolUse", "PostToolUse": if e.toolName == "Shell" || e.toolName == "Bash" { e.kind = .postShell; e.command = json.object("tool_input")?.string("command") }
            case "sessionStart", "SessionStart": e.kind = .sessionStart; e.sessionID = json.string("conversation_id") ?? json.string("session_id")
            case "sessionEnd", "SessionEnd": e.kind = .sessionEnd
            case "beforeSubmitPrompt", "UserPromptSubmit": e.kind = .prompt
            case "stop", "Stop": e.kind = .stop
            default: break
            }
            if e.cwd == nil { e.cwd = e.workspaceRoots.first }
        case .gemini:
            e.sessionID = json.string("session_id") ?? environment["GEMINI_SESSION_ID"]
            e.launchRoot = environment["GEMINI_PROJECT_DIR"]
            e.toolName = json.string("tool_name")
            let input = json.object("tool_input")
            switch event {
            case "BeforeTool": if e.toolName == "run_shell_command" { e.kind = .preShell }
            case "AfterTool": if e.toolName == "run_shell_command" { e.kind = .postShell }
            case "SessionStart": e.kind = .sessionStart
            case "SessionEnd": e.kind = .sessionEnd
            case "BeforeAgent": e.kind = .prompt
            default: break
            }
            if e.kind == .preShell || e.kind == .postShell {
                e.command = input?.string("command")
                e.background = input?.bool("is_background") ?? false
                if let dir = input?.string("dir_path"), !dir.isEmpty {
                    e.cwd = dir.hasPrefix("/") ? dir : ((e.cwd ?? e.launchRoot ?? "") as NSString).appendingPathComponent(dir)
                }
            }
        case .copilot:
            e.sessionID = json.string("sessionId") ?? json.string("session_id")
            e.toolName = json.string("toolName") ?? json.string("tool_name")
            let args = json.object("toolArgs") ?? json.object("tool_input")
            let ev = event.isEmpty ? (eventHint ?? "") : event
            switch ev {
            case "preToolUse", "PreToolUse": if ["bash", "powershell", "Bash"].contains(e.toolName ?? "") { e.kind = .preShell }
            case "postToolUse", "PostToolUse": if ["bash", "powershell", "Bash"].contains(e.toolName ?? "") { e.kind = .postShell }
            case "sessionStart", "SessionStart": e.kind = .sessionStart
            case "sessionEnd", "SessionEnd": e.kind = .sessionEnd
            case "userPromptSubmitted", "UserPromptSubmit": e.kind = .prompt
            default: break
            }
            e.rawEvent = ev
            e.command = args?.string("command")
        }
        if e.kind == .other, e.rawEvent.isEmpty, let hint = eventHint { e.kind = hintKind(hint) }
        return e
    }

    static func claudeKind(_ event: String, tool: String?) -> HookEventKind {
        let shellTools: Set<String> = ["Bash", "PowerShell", "Monitor", "Shell", "shell", "exec_command", "local_shell"]
        switch event {
        case "SessionStart": return .sessionStart
        case "SessionEnd": return .sessionEnd
        case "PreToolUse": return shellTools.contains(tool ?? "") ? .preShell : (tool == "apply_patch" || tool == "Edit" || tool == "Write" ? .preEdit : .other)
        case "PostToolUse": return shellTools.contains(tool ?? "") ? .postShell : .other
        case "PostToolUseFailure": return shellTools.contains(tool ?? "") ? .shellFailed : .other
        case "UserPromptSubmit": return .prompt
        case "Stop", "SubagentStop": return .stop
        case "CwdChanged": return .cwdChanged
        case "PermissionRequest": return .permissionRequest
        default: return .other
        }
    }

    static func hintKind(_ hint: String) -> HookEventKind {
        switch hint {
        case "session-start", "sessionStart": return .sessionStart
        case "session-end", "sessionEnd": return .sessionEnd
        case "pre-bash", "pre-shell", "preToolUse": return .preShell
        case "post-bash", "post-shell", "postToolUse": return .postShell
        case "pre-edit": return .preEdit
        case "permission": return .permissionRequest
        case "prompt", "userPromptSubmitted": return .prompt
        case "stop": return .stop
        default: return .other
        }
    }

    /// Whether `agent` can show the user a native approval prompt for this event.
    public static func supportsNativeAsk(_ agent: AgentKind, kind: HookEventKind, permissionMode: String?) -> Bool {
        switch agent {
        case .claudeCode: return permissionMode != "bypassPermissions" && permissionMode != "dontAsk"
        case .cursor: return true
        case .copilot: return true
        case .codex, .gemini: return false
        }
    }

    /// Encodes a reply in the format the invoking agent expects. Returns nil when nothing must be printed.
    public static func encode(_ reply: HookReply, as agent: AgentKind, event: HookEnvelope) -> String? {
        func json(_ v: [String: Any]) -> String { JSONOutput.string(v) }
        switch agent {
        case .claudeCode:
            switch reply {
            case .allow, .neutral: return "{}"
            case .ask(let r, _), .deny(let r, _):
                let decision = { if case .ask = reply { return "ask" }; return "deny" }()
                let eventName = event.kind == .permissionRequest ? "PermissionRequest" : "PreToolUse"
                return json(["hookSpecificOutput": ["hookEventName": eventName, "permissionDecision": decision, "permissionDecisionReason": r]])
            }
        case .codex:
            switch reply {
            case .allow, .neutral: return nil // Codex treats `allow` without updatedInput as a failure; silence = proceed
            case .ask(let r, _), .deny(let r, _):
                if event.kind == .permissionRequest {
                    return json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "deny", "message": r]]])
                }
                return json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r]])
            }
        case .cursor:
            switch reply {
            case .neutral: return "{}"
            case .allow: return event.kind == .preShell ? json(["permission": "allow"]) : "{}"
            case .ask(let r, let u): return json(["permission": "ask", "user_message": u, "agent_message": r])
            case .deny(let r, let u): return json(["permission": "deny", "user_message": u, "agent_message": r])
            }
        case .gemini:
            switch reply {
            case .allow, .neutral: return "{}"
            case .ask(let r, let u), .deny(let r, let u): return json(["decision": "deny", "reason": r, "systemMessage": u])
            }
        case .copilot:
            switch reply {
            case .allow, .neutral: return "{}"
            case .ask(let r, _): return json(["permissionDecision": "ask", "permissionDecisionReason": r])
            case .deny(let r, _): return json(["permissionDecision": "deny", "permissionDecisionReason": r])
            }
        }
    }
}
