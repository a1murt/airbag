import Foundation

/// Project and worktree layout read from the file system (no git process is spawned on the hook path).
public struct GitLayout: Sendable, Equatable {
    public let root: String            // the directory that holds `.git` (worktree root or main checkout)
    public let projectRoot: String     // main checkout for worktrees, else `root`
    public let commonDir: String?      // <main>/.git
    public let isWorktree: Bool
    public let worktreeName: String?
    public let worktreeKind: String    // main | claude | codex | cursor | manual

    public static func inspect(root: String, home: String = NSHomeDirectory()) -> GitLayout {
        let dotgit = root + "/.git"
        var st = stat()
        guard lstat(dotgit, &st) == 0 else {
            return GitLayout(root: root, projectRoot: root, commonDir: nil, isWorktree: false, worktreeName: nil, worktreeKind: "main")
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            return GitLayout(root: root, projectRoot: root, commonDir: dotgit, isWorktree: false, worktreeName: nil, worktreeKind: "main")
        }
        // `.git` file: "gitdir: <common>/worktrees/<name>"
        guard let text = try? String(contentsOfFile: dotgit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else {
            return GitLayout(root: root, projectRoot: root, commonDir: nil, isWorktree: false, worktreeName: nil, worktreeKind: "unknown")
        }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = (root as NSString).appendingPathComponent(gitdir) }
        gitdir = FileSystem.canonicalPath(gitdir) ?? (gitdir as NSString).standardizingPath
        var common: String? = nil
        var name: String? = nil
        if let commondirFile = try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8) {
            let rel = commondirFile.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = rel.hasPrefix("/") ? rel : (gitdir as NSString).appendingPathComponent(rel)
            common = FileSystem.canonicalPath(c) ?? (c as NSString).standardizingPath
            name = (gitdir as NSString).lastPathComponent
        } else if (gitdir as NSString).deletingLastPathComponent.hasSuffix("/worktrees") {
            common = ((gitdir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            name = (gitdir as NSString).lastPathComponent
        }
        let project = common.map { c in (c as NSString).lastPathComponent == ".git" ? (c as NSString).deletingLastPathComponent : c } ?? root
        return GitLayout(root: root, projectRoot: project, commonDir: common, isWorktree: true, worktreeName: name,
                         worktreeKind: worktreeKind(path: root, home: home))
    }

    static func worktreeKind(path: String, home: String) -> String {
        if path.contains("/.claude/worktrees/") { return "claude" }
        if path.hasPrefix(home + "/.codex/worktrees/") || path.contains("/.codex/worktrees/") { return "codex" }
        if path.hasPrefix(home + "/.cursor/worktrees/") { return "cursor" }
        return "manual"
    }
}

/// The agent process that invoked a hook.
public struct AgentLocation: Sendable {
    public let process: ProcSnapshot
    public let exe: String?
    public let host: ProcSnapshot?
    public let hostApp: String?
    public let surface: String
}

public enum AgentLocator {
    /// Finds the agent from the hook process: environment first (Claude Code's `CLAUDE_PID`), then a bounded walk
    /// up the parent chain matching each agent's executable (doc 11 §4.3).
    public static func locate(_ agent: AgentKind, environment: [String: String], from pid: Int32 = getpid()) -> AgentLocation? {
        let chain = ProcInfo.ancestors(of: pid)
        var match: (Int, ProcSnapshot, String?)?
        if agent == .claudeCode, let s = environment["CLAUDE_PID"], let cp = Int32(s),
           let idx = chain.firstIndex(where: { $0.pid == cp }) {
            match = (idx, chain[idx], ProcInfo.path(cp))
        }
        if match == nil {
            for (i, p) in chain.enumerated() where i > 0 {
                let exe = ProcInfo.path(p.pid)
                if matches(agent, exe: exe, pid: p.pid) { match = (i, p, exe); break }
            }
        }
        guard let (idx, proc, exe) = match else { return nil }
        var host: ProcSnapshot?
        var hostApp: String?
        for p in chain.dropFirst(idx + 1) {
            if let path = ProcInfo.path(p.pid), let r = path.range(of: ".app/Contents/MacOS/") {
                host = p
                hostApp = String(path[..<r.lowerBound]).components(separatedBy: "/").last
                if hostApp != "disclaimer" { break }
            }
        }
        let surface: String
        switch environment["CLAUDE_CODE_ENTRYPOINT"] {
        case "claude-desktop"?: surface = "desktop"
        case "sdk-ts"?, "sdk-py"?, "sdk-cli"?: surface = "sdk"
        default:
            if let app = hostApp, ["Claude", "Codex", "ChatGPT", "Cursor"].contains(app) { surface = agent == .cursor ? "ide" : "desktop" }
            else if let app = hostApp, ["Code", "Visual Studio Code", "Windsurf", "Zed"].contains(app) || app.contains("IntelliJ") || app.contains("PyCharm") { surface = "ide" }
            else if proc.ttyDev != UInt32.max && proc.ttyDev != 0 { surface = "cli" }
            else { surface = "unknown" }
        }
        return AgentLocation(process: proc, exe: exe, host: host, hostApp: hostApp, surface: surface)
    }

    static func matches(_ agent: AgentKind, exe: String?, pid: Int32) -> Bool {
        guard let exe else { return false }
        let base = (exe as NSString).lastPathComponent
        func argvContains(_ needles: [String]) -> Bool {
            guard let a = ProcInfo.arguments(pid)?.argv else { return false }
            return a.prefix(4).contains { arg in needles.contains { arg.contains($0) } }
        }
        switch agent {
        case .claudeCode:
            return exe.hasSuffix("/claude.app/Contents/MacOS/claude") || base == "claude"
                || (base == "node" && argvContains(["/claude", "@anthropic-ai/claude-code"]))
        case .codex:
            return base == "codex" || base.hasPrefix("codex-") || (base == "node" && argvContains(["@openai/codex", "/codex"]))
        case .cursor:
            return base == "cursor-agent" || exe.contains("/cursor-agent/") || base.hasPrefix("Cursor Helper") || base == "Cursor"
        case .gemini:
            return base == "gemini" || (base == "node" && argvContains(["gemini"]))
        case .copilot:
            return base == "copilot" || (base == "node" && argvContains(["@github/copilot"]))
        }
    }
}
