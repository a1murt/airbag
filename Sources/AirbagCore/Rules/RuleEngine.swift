import Foundation

public enum GuardDecision: String, Sendable, Codable, Comparable {
    case allow, ask, block
    var rank: Int { self == .allow ? 0 : self == .ask ? 1 : 2 }
    public static func < (a: GuardDecision, b: GuardDecision) -> Bool { a.rank < b.rank }
}

/// Whether a snapshot should precede the command.
public enum SnapshotNeed: String, Sendable, Codable, Comparable {
    /// Read-only command: skip the snapshot.
    case none
    /// Mutating command: take a snapshot if possible.
    case recommended
    /// Destructive but recoverable: allowed only when the snapshot succeeds; otherwise escalate to `ask`.
    case required
    var rank: Int { self == .none ? 0 : self == .recommended ? 1 : 2 }
    public static func < (a: SnapshotNeed, b: SnapshotNeed) -> Bool { a.rank < b.rank }
}

public struct GuardFinding: Sendable, Codable, Equatable {
    public let ruleId: String
    public let decision: GuardDecision
    public let snapshot: SnapshotNeed
    /// English, agent-facing explanation of what the command would do.
    public let reason: String
    /// The part of the command the rule matched.
    public let matched: String
}

public struct GuardVerdict: Sendable, Codable, Equatable {
    public let decision: GuardDecision
    public let snapshot: SnapshotNeed
    public let findings: [GuardFinding]

    /// The finding that decided the verdict (highest severity first).
    public var primary: GuardFinding? {
        findings.max { a, b in a.decision != b.decision ? a.decision < b.decision : a.snapshot < b.snapshot }
    }

    /// Agent-facing message for a block or ask, with the recovery instruction.
    public func agentMessage(command: String, snapshotId: String? = nil) -> String {
        guard let p = primary, decision != .allow else { return "" }
        let cmd = command.count > 120 ? String(command.prefix(117)) + "…" : command
        var s: String
        if decision == .block {
            s = "Airbag blocked `\(cmd)`: \(p.reason) Do not retry this command or work around it with another tool; choose a safer, narrower command or ask the user."
        } else {
            s = "Airbag needs the user's approval for `\(cmd)`: \(p.reason)"
        }
        if let snapshotId { s += " A snapshot (\(snapshotId)) of the project was taken first." }
        return s
    }
}

/// Everything the analyzer needs to know about where a command runs.
public struct GuardContext: Sendable {
    public var cwd: String
    public var home: String
    /// Protected project roots (canonical). The session's own root is always included by the caller.
    public var roots: [String]
    public var environment: [String: String]
    /// Airbag's own data directory (agents must not disable the safety net).
    public var airbagHome: String?
    /// Rule ids the user turned off.
    public var disabledRules: Set<String>
    /// Look at the real file system (symlink resolution). Off in fixture tests.
    public var useFileSystem: Bool

    public init(cwd: String, home: String = NSHomeDirectory(), roots: [String], environment: [String: String] = [:],
                airbagHome: String? = nil, disabledRules: Set<String> = [], useFileSystem: Bool = true) {
        self.cwd = cwd; self.home = home; self.roots = roots; self.environment = environment
        self.airbagHome = airbagHome; self.disabledRules = disabledRules; self.useFileSystem = useFileSystem
    }
}

/// Where a path points, from the point of view of data safety.
enum PathClass: Equatable {
    case catastrophic(String)   // home, system, user data folders, or a parent of a protected root
    case airbag                 // Airbag's own data
    case gitInternals(String)   // .git of a protected root (history is not in snapshots)
    case projectRoot(String)    // a protected root itself
    case insideProject(String)  // inside a protected root
    case regenerable            // inside an excluded directory (node_modules, dist, …) of a protected root
    case temporary
    case device
    case outside
    case unknown                // opaque: unresolved variable or substitution
}

public struct RuleEngine: Sendable {
    public init() {}

    public func evaluate(_ command: String, context: GuardContext) -> GuardVerdict {
        var analyzer = Analyzer(context: context)
        analyzer.analyze(command, depth: 0)
        var findings = analyzer.findings.filter { !context.disabledRules.contains($0.ruleId) }
        // Read-only detection: when nothing matched and every command is known read-only, no snapshot is needed.
        if findings.isEmpty {
            findings = []
        }
        let decision = findings.map(\.decision).max() ?? .allow
        var snapshot = findings.map(\.snapshot).max() ?? .none
        if snapshot == .none && !analyzer.readOnly { snapshot = .recommended }
        return GuardVerdict(decision: decision, snapshot: snapshot, findings: findings)
    }
}

// MARK: - Analyzer

struct Analyzer {
    let context: GuardContext
    var findings: [GuardFinding] = []
    /// Every command seen so far is known not to modify files.
    var readOnly = true
    var cwd: String?

    init(context: GuardContext) {
        self.context = context
        self.cwd = context.cwd
    }

    mutating func add(_ id: String, _ decision: GuardDecision, _ snapshot: SnapshotNeed = .recommended, _ reason: String, _ matched: String) {
        if findings.contains(where: { $0.ruleId == id && $0.matched == matched }) { return }
        findings.append(GuardFinding(ruleId: id, decision: decision, snapshot: snapshot, reason: reason, matched: matched))
    }

    mutating func analyze(_ line: String, depth: Int) {
        guard depth < 6 else { add("shell.too-deep", .ask, .recommended, "it nests shells too deeply to analyze.", line); return }
        var env = context.environment
        if let cwd { env["PWD"] = cwd }
        var lexer = ShellLexer(environment: env, home: context.home)
        let commands = lexer.parse(line, depth: depth)
        for sub in lexer.substitutions { analyze(sub, depth: depth + 1) }
        var previous: ShellCommand?
        for cmd in commands {
            analyzeCommand(cmd, previous: previous, depth: depth)
            previous = cmd
        }
    }

    // MARK: path handling

    func normalize(_ path: String) -> String {
        var comps: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !comps.isEmpty { comps.removeLast() }; continue }
            comps.append(part)
        }
        return "/" + comps.joined(separator: "/")
    }

    /// A resolved path; `contents` means "the entries inside this directory" (a glob like `dir/*`).
    struct Resolved: Equatable { let path: String; let contents: Bool }

    /// Resolves a word to an absolute path, or nil when it depends on something we cannot know.
    func resolve(_ word: ShellWord) -> Resolved? {
        if word.opaque { return nil }
        var text = word.text
        var contents = false
        if word.hasGlob, let firstGlob = text.firstIndex(where: { "*?[".contains($0) }) {
            let prefix = text[..<firstGlob]
            let dir = prefix.lastIndex(of: "/").map { String(prefix[...$0]) } ?? ""
            text = dir.isEmpty ? "." : dir
            contents = true
        }
        let base: String
        if text.hasPrefix("/") { base = text } else {
            guard let cwd else { return nil }
            base = cwd + "/" + text
        }
        var p = normalize(base)
        if context.useFileSystem {
            if contents || word.text.hasSuffix("/") {
                // `dir/` and `dir/*` act on the directory a symlink points to.
                if let real = FileSystem.canonicalPath(p) { p = real }
            } else {
                // Without a trailing slash, rm/mv act on the link itself: resolve only the parent.
                let parent = (p as NSString).deletingLastPathComponent
                if p != "/", let realParent = FileSystem.canonicalPath(parent) {
                    p = (realParent == "/" ? "" : realParent) + "/" + (p as NSString).lastPathComponent
                }
            }
        }
        return Resolved(path: p, contents: contents)
    }

    static let excludedNames = Exclusions.defaultDirectoryNames.subtracting([".git", ".hg", ".svn", ".jj"])

    var criticalPaths: Set<String> {
        let home = context.home
        return ["/", "/Users", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private",
                "/private/etc", "/private/var", "/var", "/opt", "/opt/homebrew", "/Volumes", "/cores", "/Network", "/usr/local",
                home, home + "/Library", home + "/Documents", home + "/Desktop", home + "/Downloads",
                home + "/Pictures", home + "/Music", home + "/Movies", home + "/Public", home + "/Applications",
                home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/.config", home + "/.kube", home + "/.docker",
                home + "/.claude", home + "/.codex", home + "/.cursor", home + "/.gemini", home + "/.copilot",
                home + "/Library/Mobile Documents", home + "/Library/Keychains", home + "/Library/Application Support",
                home + "/Library/CloudStorage", home + "/Library/Containers", home + "/Library/Mail", home + "/Library/Messages"]
    }

    /// Agent hook configuration files: editing them can switch Airbag off.
    var hookConfigFiles: Set<String> {
        let h = context.home
        return [h + "/.claude/settings.json", h + "/.claude/settings.local.json", h + "/.codex/hooks.json", h + "/.codex/config.toml",
                h + "/.cursor/hooks.json", h + "/.gemini/settings.json"]
    }

    func classify(_ resolved: Resolved?) -> PathClass {
        guard let r = resolved else { return .unknown }
        let p = r.path
        if p.hasPrefix("/dev/") {
            return ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"].contains(p) || p.hasPrefix("/dev/fd/") ? .temporary : .device
        }
        if let ab = context.airbagHome {
            if p == ab || p.hasPrefix(ab + "/") { return .airbag }
            if ab.hasPrefix(p + "/") { return .catastrophic(p) }
        }
        if criticalPaths.contains(p) { return .catastrophic(p) }
        for root in context.roots where root.hasPrefix(p + "/") { return .catastrophic(p) } // a parent of a protected root
        let home = context.home
        for c in [home + "/.cache", home + "/Library/Caches", home + "/.npm/_cacache", home + "/Library/Developer/Xcode/DerivedData",
                  home + "/.cargo/registry/cache", home + "/.gradle/caches", home + "/.pnpm-store", home + "/Library/pnpm/store"]
            where p == c || p.hasPrefix(c + "/") { return p == c && !r.contents ? .regenerable : .regenerable }
        for t in ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", context.environment["TMPDIR"] ?? ""] where !t.isEmpty {
            let tt = t.hasSuffix("/") ? String(t.dropLast()) : t
            if p.hasPrefix(tt + "/") { return .temporary }
        }
        for root in context.roots.sorted(by: { $0.count > $1.count }) {
            if p == root { return r.contents ? .insideProject(root) : .projectRoot(root) } // `*` skips dotfiles such as .git
            if p.hasPrefix(root + "/") {
                let comps = p.dropFirst(root.count + 1).split(separator: "/").map(String.init)
                if comps.first == ".git" { return .gitInternals(root) }
                if comps.contains(where: { Analyzer.excludedNames.contains($0) }) { return .regenerable }
                return .insideProject(root)
            }
        }
        return .outside
    }

    // MARK: per-command analysis

    static let wrappers: Set<String> = ["sudo", "doas", "nohup", "time", "nice", "exec", "command", "builtin", "caffeinate",
                                        "stdbuf", "chronic", "unbuffer", "noglob", "arch", "env", "timeout", "gtimeout", "watch", "then", "do"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "/bin/sh", "/bin/bash", "/bin/zsh"]
    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "less", "more", "head", "tail", "grep", "egrep", "fgrep", "rg", "ag", "fd", "tree", "pwd", "echo", "printf",
        "which", "whereis", "type", "file", "stat", "wc", "du", "df", "diff", "cmp", "sort", "uniq", "cut", "tr", "jq", "yq",
        "awk", "basename", "dirname", "realpath", "readlink", "date", "whoami", "id", "uname", "env", "printenv", "hostname",
        "sw_vers", "ps", "top", "lsof", "netstat", "uptime", "history", "true", "false", "test", "[", "sleep", "cd", "pushd",
        "popd", "export", "set", "unset", "alias", "source", ".", "man", "help", "open", "pbcopy", "pbpaste", "say", "nproc",
        "sysctl", "vm_stat", "pgrep", "md5", "shasum", "sha256sum", "md5sum", "base64", "xxd", "hexdump", "strings", "otool",
        "nm", "lipo", "codesign", "spctl", "plutil", "defaults", "mdfind", "mdls", "column", "fold", "fmt", "nl", "rev", "seq",
        "yes", "clear", "tput", "stty", "tty", "locale", "command", "hash", "wait", "jobs", "fg", "bg", "read", "exit", "return",
        "diskutil", "tmutil", "pmset", "system_profiler", "ioreg", "log", "launchctl", "crontab", "networksetup", "scutil", "dig", "nslookup",
        "ping", "host", "whois", "traceroute", "nc", "tldr", "bat", "exa", "eza", "fzf", "gh",
    ]

    mutating func analyzeCommand(_ cmdIn: ShellCommand, previous: ShellCommand?, depth: Int) {
        var cmd = cmdIn
        // Redirections that write.
        for r in cmd.redirects where [">", ">|", "&>", ">>", "&>>"].contains(r.op) || (r.op.first?.isNumber == true && r.op.contains(">")) {
            let truncates = !r.op.contains(">>")
            if let rp = resolve(r.target), hookConfigFiles.contains(rp.path) {
                add("self.hooks", .ask, .none, "it rewrites an agent's hook configuration, which can switch Airbag's protection off.", r.target.text)
                readOnly = false
                continue
            }
            let cls = classify(resolve(r.target))
            readOnly = readOnly && cls == .temporary
            if case .device = cls { add("fs.device.write", .block, .none, "it writes directly to a device, which can destroy a disk.", r.target.text) }
            switch cls {
            case .catastrophic: add("fs.redirect.catastrophic", .block, .none, "it overwrites \(r.target.text), which is not a regular project file.", r.target.text)
            case .airbag: add("self.airbag", .block, .none, "it modifies Airbag's own data, which protects this project.", r.target.text)
            case .outside where truncates: add("fs.truncate.outside", .ask, .recommended, "it overwrites \(r.target.text) outside the protected project, where no snapshot can restore it.", r.target.text)
            case .unknown where truncates: add("fs.truncate.opaque", .ask, .recommended, "it overwrites a file whose path depends on an unresolved variable.", r.target.text)
            case .gitInternals where truncates: add("git.internals.write", .ask, .recommended, "it overwrites a file inside .git, which snapshots do not cover.", r.target.text)
            case .insideProject, .projectRoot: if truncates { add("fs.truncate.project", .allow, .required, "it overwrites a project file (a snapshot is taken first).", r.target.text) }
            default: break
            }
        }
        // Unwrap wrappers and environment prefixes.
        var words = cmd.words
        var sudo = false
        let valueOptions: [String: Set<String>] = [
            "sudo": ["-u", "-g", "-p", "-C", "-h", "-U", "-r", "-t", "-T", "-D"], "doas": ["-u", "-C"], "nice": ["-n"],
            "timeout": ["-s", "-k", "--signal", "--kill-after"], "gtimeout": ["-s", "-k", "--signal", "--kill-after"],
            "env": ["-u", "-C", "-P", "--unset", "--chdir"], "watch": ["-n", "-d", "--interval"], "stdbuf": ["-i", "-o", "-e"],
            "caffeinate": ["-t", "-w"], "arch": ["-arch"],
        ]
        while let first = words.first, Analyzer.wrappers.contains((first.text as NSString).lastPathComponent) {
            let name = (first.text as NSString).lastPathComponent
            if name == "sudo" || name == "doas" { sudo = true }
            if name == "command", words.count > 1, ["-v", "-V"].contains(words[1].text) { return } // lookup only
            words.removeFirst()
            while let w = words.first {
                if w.text == "--" { words.removeFirst(); break }
                if w.text.hasPrefix("-") && w.text.count > 1 && !w.quoted {
                    words.removeFirst()
                    if valueOptions[name]?.contains(w.text) == true, !words.isEmpty {
                        if name == "env", w.text == "-C" || w.text == "--chdir" { cwd = resolve(words[0])?.path }
                        words.removeFirst()
                    }
                    continue
                }
                if name == "timeout" || name == "gtimeout", w.text.first?.isNumber == true { words.removeFirst(); continue }
                if name == "env", w.assignmentName != nil { words.removeFirst(); continue }
                break
            }
        }
        cmd.words = words
        guard let first = words.first else { return }
        let name = (first.text as NSString).lastPathComponent
        let args = Array(words.dropFirst())
        let argv = args.map(\.text)
        let whole = words.map(\.text).joined(separator: " ")

        if sudo { add("sys.sudo", .ask, .recommended, "it runs with root privileges, outside what Airbag can snapshot or undo.", whole) }
        // A pipe into a shell or interpreter runs downloaded or generated code.
        if cmdIn.connector == .pipe, Analyzer.shells.contains(name) || ["python", "python3", "node", "ruby", "perl"].contains(name), args.allSatisfy({ $0.text.hasPrefix("-") }) {
            if let prev = previous, ["curl", "wget", "http", "xh", "fetch"].contains(((prev.words.first?.text ?? "") as NSString).lastPathComponent) {
                add("net.pipe.shell", .ask, .recommended, "it pipes a downloaded script straight into \(name).", prev.argv.joined(separator: " ") + " | " + whole)
            }
        }

        // Nested shells: sh -c "…", bash -lc "…", eval "…"
        if Analyzer.shells.contains(first.text) || Analyzer.shells.contains(name) {
            if let ci = argv.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }), ci + 1 < args.count {
                if args[ci + 1].opaque { add("shell.opaque", .ask, .recommended, "it runs a shell command built from unresolved variables.", whole) }
                analyze(args[ci + 1].text, depth: depth + 1)
            } else {
                readOnly = false // runs a script file we cannot inspect
            }
            return
        }
        if name == "eval" {
            if args.contains(where: \.opaque) { add("shell.opaque", .ask, .recommended, "it evaluates text built from unresolved variables.", whole) }
            analyze(argv.joined(separator: " "), depth: depth + 1)
            return
        }
        if name == "xargs" {
            analyzeXargs(args, previous: previous, whole: whole, depth: depth)
            return
        }
        if name == "cd" || name == "pushd" {
            if let target = args.first(where: { !$0.text.hasPrefix("-") }) {
                cwd = resolve(target)?.path
            } else {
                cwd = context.home
            }
            return
        }
        if name == "find" { analyzeFind(args, whole: whole); return }

        if !Analyzer.readOnlyCommands.contains(name) && name != "git" && name != "brew" { readOnly = false }
        switch name {
        case "rm", "unlink", "rmdir", "srm", "shred", "rimraf", "del", "del-cli", "trash-put": analyzeRemove(name, args, whole: whole)
        case "npx", "pnpx", "bunx", "npm", "pnpm", "yarn", "bun":
            analyzePackageRunner(name, args, whole: whole, depth: depth)
        case "ssh":
            analyzeRemote(args, whole: whole)
        case "mv": analyzeMove(args, whole: whole)
        case "cp", "rsync", "ditto": analyzeCopy(name, args, whole: whole)
        case "truncate": analyzeTruncate(args, whole: whole)
        case "sed", "gsed":
            if args.contains(where: { $0.text == "-i" || $0.text.hasPrefix("-i") || $0.text == "--in-place" || ($0.text.hasPrefix("-") && !$0.text.hasPrefix("--") && $0.text.contains("i")) }) {
                // Operands after the script are files edited in place.
                var operands = args.filter { !$0.text.hasPrefix("-") }
                if !args.contains(where: { $0.text == "-e" || $0.text == "-f" }), !operands.isEmpty { operands.removeFirst() } // the script
                if let ix = args.firstIndex(where: { $0.text == "-i" }), ix + 1 < args.count, args[ix + 1].text.isEmpty || args[ix + 1].text.hasPrefix(".") {
                    operands.removeAll { $0 == args[ix + 1] }
                }
                for t in operands { writeCheck(t, truncates: true, whole: whole) }
            }
        case "tee":
            let append = args.contains { $0.text == "-a" || $0.text == "--append" }
            for t in args where !t.text.hasPrefix("-") { writeCheck(t, truncates: !append, whole: whole) }
        case "dd": analyzeDD(argv, whole: whole)
        case "chmod", "chown", "chgrp", "chflags", "xattr": analyzePermissions(name, args, whole: whole)
        case "git": analyzeGit(argv, whole: whole)
        case "gh": analyzeGH(argv, whole: whole)
        case let n where n.hasPrefix("mkfs") || n.hasPrefix("newfs"):
            add("sys.disk.erase", .block, .none, "it formats a disk or partition.", whole)
        case "diskutil", "fdisk", "gpt", "asr":
            if name != "diskutil" || argv.contains(where: { ["eraseDisk", "eraseVolume", "partitionDisk", "zeroDisk", "randomDisk", "secureErase", "reformat", "deleteContainer", "deleteVolume", "eraseVolume", "erase"].contains($0) }) {
                add("sys.disk.erase", .block, .none, "it can erase or repartition a disk.", whole)
            }
        case "shutdown", "reboot", "halt", "poweroff":
            add("sys.power", .block, .none, "it shuts down or restarts the Mac and every running session.", whole)
        case "launchctl":
            if argv.contains(where: { $0.hasPrefix("system") || $0.contains("/System/") }) && argv.contains(where: { ["bootout", "unload", "remove", "disable"].contains($0) }) {
                add("sys.launchctl.system", .block, .none, "it stops or removes system services.", whole)
            }
        case "crontab": if argv.contains("-r") { add("sys.crontab.remove", .block, .none, "it deletes every cron job of the user without confirmation.", whole) }
        case "csrutil", "nvram", "bless", "fdesetup":
            add("sys.security", .block, .none, "it changes low-level system security or boot settings.", whole)
        case "spctl": if argv.contains(where: { $0.contains("disable") }) { add("sys.security", .block, .none, "it disables Gatekeeper.", whole) }
        case "tmutil":
            if argv.contains(where: { ["delete", "deletelocalsnapshots", "disable", "thinlocalsnapshots", "deleteinprogress"].contains($0) }) {
                add("sys.tmutil", .block, .none, "it deletes Time Machine backups or disables them.", whole)
            }
        case "defaults": if argv.first == "delete" { add("sys.defaults.delete", .ask, .recommended, "it deletes application preferences.", whole) }
        case "kill": analyzeKill(argv, whole: whole)
        case "killall", "pkill": analyzeKillAll(name, argv, whole: whole)
        case "osascript":
            let text = argv.joined(separator: " ").lowercased()
            if text.contains("empty trash") || text.contains("empty the trash") { add("fs.trash.empty", .block, .none, "it empties the Trash permanently.", whole) }
            else if text.contains("delete") || text.contains("do shell script") { add("sys.osascript", .ask, .recommended, "it runs an AppleScript that can delete or run commands outside the project.", whole) }
        case "php" where args.first?.text == "artisan":
            analyzeMigrationTool("artisan", Array(argv.dropFirst()), whole: whole)
        case "python", "python3" where args.first.map({ ($0.text as NSString).lastPathComponent == "manage.py" }) == true:
            analyzeMigrationTool("manage.py", Array(argv.dropFirst()), whole: whole)
        case "python", "python2", "python3", "node", "perl", "ruby", "php", "deno", "lua", "Rscript", "swift":
            if name == "perl", args.contains(where: { $0.text.hasPrefix("-") && $0.text.contains("i") && !$0.text.hasPrefix("--") }) {
                for t in args.filter({ !$0.text.hasPrefix("-") }).dropFirst() { writeCheck(t, truncates: true, whole: whole) }
            }
            analyzeInterpreter(name, args, whole: whole)
        case "psql", "mysql", "mariadb", "sqlcmd", "clickhouse-client", "cockroach", "mongosh", "mongo", "redis-cli", "sqlite3", "duckdb", "pgcli", "mycli", "litecli":
            analyzeDatabase(name, args, whole: whole)
        case "prisma", "drizzle-kit", "supabase", "rails", "rake", "knex", "sequelize", "typeorm", "artisan", "manage.py", "alembic", "dbmate", "goose", "flyway", "liquibase", "atlas":
            analyzeMigrationTool(name, argv, whole: whole)
        case "terraform", "tofu", "pulumi", "cdk", "cdktf", "sst", "serverless", "sls":
            if argv.contains("destroy") || (argv.contains("apply") && argv.contains("-destroy")) || argv.contains("remove") && (name == "serverless" || name == "sls") {
                add("cloud.iac.destroy", .ask, .none, "it destroys cloud infrastructure, which no local snapshot can bring back.", whole)
            }
        case "kubectl", "oc":
            if argv.first == "delete" || argv.contains("delete") { add("cloud.k8s.delete", .ask, .none, "it deletes Kubernetes resources on a cluster.", whole) }
        case "helm": if argv.contains("uninstall") || argv.contains("delete") { add("cloud.k8s.delete", .ask, .none, "it uninstalls a Helm release from a cluster.", whole) }
        case "aws": analyzeAWS(argv, whole: whole)
        case "gcloud", "gsutil", "az", "doctl", "linode-cli", "hcloud":
            if argv.contains(where: { ["delete", "rm", "destroy", "rb", "purge"].contains($0) }) || (name == "gsutil" && argv.contains("-r") && argv.contains("rm")) {
                add("cloud.delete", .ask, .none, "it deletes cloud resources, which no local snapshot can bring back.", whole)
            }
        case "vercel", "vc", "netlify", "fly", "flyctl", "heroku", "railway", "render", "firebase", "wrangler", "amplify", "eas":
            analyzePaaS(name, argv, whole: whole)
        case "docker", "docker-compose", "podman", "podman-compose", "nerdctl", "colima", "orb", "orbctl": analyzeContainers(name, argv, whole: whole)
        case "curl", "wget", "http", "xh": analyzeDownload(cmdIn: cmd, previousConnector: cmdIn.connector, whole: whole)
        case "airbag":
            if argv.contains("uninstall") || (argv.first == "hooks" && argv.contains("uninstall")) {
                add("self.airbag", .ask, .none, "it removes Airbag's protection; only the user should do that.", whole)
            }
        case "brew":
            readOnly = readOnly && ["list", "info", "search", "--version", "config", "doctor", "outdated", "deps", "leaves"].contains(argv.first ?? "")
        default:
            break
        }
    }

    // MARK: rule groups

    mutating func classifyDeletion(_ targets: [ShellWord], recursive: Bool, verb: String, whole: String) {
        for t in targets {
            let cls = classify(resolve(t))
            switch cls {
            case .catastrophic(let p):
                if recursive || t.hasGlob { add("fs.rm.catastrophic", .block, .none, "it would \(verb) \(describe(p)), which no snapshot covers.", t.text) }
                else { add("fs.rm.outside", .ask, .none, "it would \(verb) \(t.text) outside the protected project.", t.text) }
            case .airbag: add("self.airbag", .block, .none, "it would \(verb) Airbag's own data, which protects this project.", t.text)
            case .gitInternals: add("git.internals.delete", .ask, .recommended, "it would \(verb) git internals (.git), and git history is not part of Airbag snapshots.", t.text)
            case .projectRoot(let r):
                if hasGitDirectory(r) {
                    add("fs.rm.project-root", .ask, .required, "it would \(verb) the whole project including its git history, which snapshots do not cover.", t.text)
                } else {
                    add("fs.rm.project-root", .allow, .required, "it deletes the whole project folder (restorable from the snapshot taken first).", t.text)
                }
            case .insideProject: add("fs.rm.project", .allow, .required, "it deletes project files (restorable from the snapshot taken first).", t.text)
            case .regenerable: break
            case .temporary: break
            case .device: add("fs.device.write", .block, .none, "it targets a device.", t.text)
            case .outside: add("fs.rm.outside", .ask, .none, "it would \(verb) \(t.text) outside the protected project, where no snapshot can restore it.", t.text)
            case .unknown: add("fs.rm.opaque", .ask, .recommended, "it would \(verb) a path built from an unresolved variable or command substitution (an empty value can turn it into a much wider path).", t.text)
            }
        }
    }

    func hasGitDirectory(_ root: String) -> Bool {
        guard context.useFileSystem else { return true }
        var st = stat()
        return lstat(root + "/.git", &st) == 0
    }

    func describe(_ p: String) -> String {
        if p == context.home { return "your home directory" }
        if p == "/" { return "the entire disk" }
        if p.hasPrefix(context.home + "/") { return "~/" + p.dropFirst(context.home.count + 1) }
        return p
    }

    func splitOptions(_ args: [ShellWord]) -> (flags: Set<Character>, long: Set<String>, operands: [ShellWord]) {
        var flags = Set<Character>(), long = Set<String>(), operands: [ShellWord] = []
        var endOfOptions = false
        for a in args {
            if !endOfOptions && a.text == "--" { endOfOptions = true; continue }
            if !endOfOptions && a.text.hasPrefix("--") { long.insert(a.text); continue }
            if !endOfOptions && a.text.hasPrefix("-") && a.text.count > 1 && !a.quoted { for ch in a.text.dropFirst() { flags.insert(ch) }; continue }
            operands.append(a)
        }
        return (flags, long, operands)
    }

    mutating func analyzeRemove(_ name: String, _ args: [ShellWord], whole: String) {
        let (flags, long, operands) = splitOptions(args)
        let recursive = name == "rimraf" || name == "del" || name == "del-cli" || flags.contains("r") || flags.contains("R") || long.contains("--recursive")
        if name == "trash-put" { return } // goes to the Trash
        if operands.isEmpty { return }
        classifyDeletion(operands, recursive: recursive || name == "rmdir", verb: "delete", whole: whole)
    }

    mutating func analyzeFind(_ args: [ShellWord], whole: String) {
        let argv = args.map(\.text)
        let deletes = argv.contains("-delete") || zip(argv, argv.dropFirst()).contains { ($0 == "-exec" || $0 == "-execdir" || $0 == "-ok") && ["rm", "/bin/rm", "unlink", "shred"].contains($1) }
        guard deletes else { return } // read-only
        readOnly = false
        var bases = args.prefix(while: { !$0.text.hasPrefix("-") && $0.text != "(" && $0.text != "!" })
        if bases.isEmpty { bases = [ShellWord(".")] }
        let filtered = argv.contains(where: { ["-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-newer", "-mtime", "-mmin", "-size", "-type", "-empty", "-user", "-perm"].contains($0) })
        deletionUnderBases(Array(bases), filtered: filtered, whole: whole)
    }

    /// `find BASE … -delete` and `find BASE | xargs rm`: deletes matching entries under each base.
    mutating func deletionUnderBases(_ bases: [ShellWord], filtered: Bool, whole: String) {
        for b in bases {
            let cls = classify(resolve(b))
            switch cls {
            case .catastrophic(let p):
                if filtered { add("fs.find.delete.broad", .ask, .none, "it deletes matching files anywhere under \(describe(p)), outside what snapshots cover.", b.text) }
                else { add("fs.rm.catastrophic", .block, .none, "it would delete everything under \(describe(p)).", b.text) }
            case .projectRoot:
                if filtered { add("fs.find.delete.project", .allow, .required, "it deletes matching project files (restorable from the snapshot taken first).", b.text) }
                else { classifyDeletion([b], recursive: true, verb: "delete everything in", whole: whole) }
            default:
                classifyDeletion([b], recursive: true, verb: "delete files under", whole: whole)
            }
        }
    }

    mutating func analyzeXargs(_ args: [ShellWord], previous: ShellCommand?, whole: String, depth: Int) {
        // xargs [options] cmd args… — the targets come from stdin.
        var i = 0
        let optsWithValue: Set<String> = ["-n", "-I", "-J", "-L", "-P", "-s", "-E", "-d", "-a"]
        while i < args.count, args[i].text.hasPrefix("-") { i += optsWithValue.contains(args[i].text) ? 2 : 1 }
        guard i < args.count else { return }
        let inner = Array(args[i...])
        let innerName = (inner[0].text as NSString).lastPathComponent
        readOnly = readOnly && Analyzer.readOnlyCommands.contains(innerName)
        guard ["rm", "unlink", "rmdir", "shred", "mv", "chmod", "chown"].contains(innerName) else {
            analyze(inner.map(\.text).joined(separator: " "), depth: depth + 1)
            return
        }
        if let prev = previous, prev.words.first.map({ ($0.text as NSString).lastPathComponent }) == "find" {
            let findArgs = Array(prev.words.dropFirst())
            let bases = findArgs.prefix(while: { !$0.text.hasPrefix("-") && $0.text != "(" && $0.text != "!" })
            let filtered = findArgs.contains(where: { ["-name", "-iname", "-path", "-ipath", "-regex", "-newer", "-mtime", "-mmin", "-size", "-type", "-empty"].contains($0.text) })
            deletionUnderBases(bases.isEmpty ? [ShellWord(".")] : Array(bases), filtered: filtered, whole: whole)
        } else {
            add("fs.rm.opaque", .ask, .recommended, "it deletes or changes files whose names come from another command's output, which Airbag cannot check.", whole)
        }
    }

    mutating func analyzeMove(_ args: [ShellWord], whole: String) {
        let (_, _, operands) = splitOptions(args)
        guard operands.count >= 2 else { return }
        let sources = operands.dropLast()
        let dest = operands.last!
        if dest.text == "/dev/null" { classifyDeletion(Array(sources), recursive: true, verb: "delete", whole: whole); return }
        defer { writeCheck(dest, truncates: false, whole: whole) }
        for s in sources {
            switch classify(resolve(s)) {
            case .catastrophic(let p): add("fs.mv.catastrophic", .block, .none, "it would move \(describe(p)) away, breaking the system or your files.", s.text)
            case .airbag: add("self.airbag", .block, .none, "it would move Airbag's own data.", s.text)
            case .outside: add("fs.mv.outside", .ask, .none, "it moves \(s.text), which is outside the protected project.", s.text)
            case .unknown: add("fs.mv.opaque", .ask, .recommended, "it moves a path built from an unresolved variable.", s.text)
            case .gitInternals: add("git.internals.delete", .ask, .recommended, "it moves git internals (.git), which snapshots do not cover.", s.text)
            case .projectRoot, .insideProject: add("fs.mv.project", .allow, .required, "it moves project files (restorable from the snapshot taken first).", s.text)
            default: break
            }
        }
    }

    mutating func overwriteCheck(_ dest: ShellWord, whole: String, verb: String) {
        switch classify(resolve(dest)) {
        case .catastrophic(let p): add("fs.overwrite.catastrophic", .block, .none, "it would \(verb) \(describe(p)).", dest.text)
        case .airbag: add("self.airbag", .block, .none, "it would \(verb) Airbag's own data.", dest.text)
        case .device: add("fs.device.write", .block, .none, "it writes to a device.", dest.text)
        default: break
        }
    }

    mutating func analyzeCopy(_ name: String, _ args: [ShellWord], whole: String) {
        let (_, long, operands) = splitOptions(args)
        guard let dest = operands.last, operands.count >= 2 else { return }
        if name == "rsync", long.contains(where: { $0.hasPrefix("--delete") || $0 == "--remove-source-files" }) {
            if dest.text.contains(":") && !dest.text.hasPrefix("/") {
                add("fs.rsync.delete.remote", .ask, .none, "it deletes files on a remote machine that are missing locally.", whole)
            } else {
                classifyDeletion([dest], recursive: true, verb: "delete files not present in the source from", whole: whole)
            }
        }
        if operands.first?.text == "/dev/null" || operands.first?.text == "/dev/zero" {
            // cp /dev/null file → truncation
            analyzeTruncateTargets([dest], whole: whole)
        }
        writeCheck(dest, truncates: true, whole: whole)
    }

    mutating func analyzeTruncate(_ args: [ShellWord], whole: String) {
        var targets: [ShellWord] = []
        var i = 0
        while i < args.count {
            let t = args[i].text
            if t == "-s" || t == "--size" || t == "-r" || t == "--reference" { i += 2; continue }
            if t.hasPrefix("-") { i += 1; continue }
            targets.append(args[i]); i += 1
        }
        analyzeTruncateTargets(targets, whole: whole)
    }

    /// A command writes to `target` (sed -i, tee, cp/mv destination, perl -pi).
    mutating func writeCheck(_ target: ShellWord, truncates: Bool, whole: String) {
        let resolved = resolve(target)
        if let r = resolved, hookConfigFiles.contains(r.path) {
            add("self.hooks", .ask, .none, "it edits an agent's hook configuration, which can switch Airbag's protection off.", target.text)
            return
        }
        switch classify(resolved) {
        case .catastrophic(let p): add("fs.overwrite.catastrophic", .block, .none, "it would overwrite \(describe(p)).", target.text)
        case .airbag: add("self.airbag", .block, .none, "it modifies Airbag's own data, which protects this project.", target.text)
        case .device: add("fs.device.write", .block, .none, "it writes to a device.", target.text)
        case .outside where truncates: add("fs.write.outside", .ask, .recommended, "it overwrites \(target.text) outside the protected project, where no snapshot can restore it.", target.text)
        case .gitInternals: add("git.internals.write", .ask, .recommended, "it overwrites a file inside .git, which snapshots do not cover.", target.text)
        case .insideProject, .projectRoot: add("fs.write.project", .allow, .recommended, "it edits project files (a snapshot is taken first).", target.text)
        default: break
        }
    }

    mutating func analyzeTruncateTargets(_ targets: [ShellWord], whole: String) {
        for t in targets {
            switch classify(resolve(t)) {
            case .catastrophic(let p): add("fs.redirect.catastrophic", .block, .none, "it empties \(describe(p)).", t.text)
            case .airbag: add("self.airbag", .block, .none, "it empties Airbag's own data.", t.text)
            case .outside: add("fs.truncate.outside", .ask, .recommended, "it empties \(t.text) outside the protected project.", t.text)
            case .unknown: add("fs.truncate.opaque", .ask, .recommended, "it empties a file whose path depends on an unresolved variable.", t.text)
            case .insideProject, .projectRoot: add("fs.truncate.project", .allow, .required, "it empties a project file (a snapshot is taken first).", t.text)
            case .device: add("fs.device.write", .block, .none, "it writes to a device.", t.text)
            default: break
            }
        }
    }

    mutating func analyzeDD(_ argv: [String], whole: String) {
        for a in argv where a.hasPrefix("of=") {
            let target = String(a.dropFirst(3))
            if target.hasPrefix("/dev/") && !["/dev/null", "/dev/stdout", "/dev/stderr"].contains(target) {
                add("fs.device.write", .block, .none, "it writes raw data to \(target), which can destroy a disk.", a)
            } else {
                analyzeTruncateTargets([ShellWord(target)], whole: whole)
            }
        }
    }

    mutating func analyzePermissions(_ name: String, _ args: [ShellWord], whole: String) {
        let (flags, _, operands) = splitOptions(args)
        let recursive = flags.contains("R")
        let targets = (name == "xattr") ? operands : Array(operands.dropFirst())
        for t in targets {
            switch classify(resolve(t)) {
            case .catastrophic(let p):
                add("fs.perm.catastrophic", recursive ? .block : .ask, .none, "it changes \(name == "xattr" ? "attributes" : "ownership or permissions") of \(describe(p))\(recursive ? " recursively" : "").", t.text)
            case .airbag: add("self.airbag", .block, .none, "it changes Airbag's own data.", t.text)
            case .outside where recursive: add("fs.perm.outside", .ask, .none, "it recursively changes permissions outside the protected project.", t.text)
            case .unknown where recursive: add("fs.perm.opaque", .ask, .recommended, "it recursively changes permissions of a path built from an unresolved variable.", t.text)
            default: break
            }
        }
    }

    mutating func analyzeGit(_ argv: [String], whole: String) {
        // Skip global options: git -C dir, -c k=v, --git-dir=…, --work-tree=…
        var a = argv[...]
        while let f = a.first, f.hasPrefix("-") {
            a = a.dropFirst()
            if (f == "-C" || f == "-c" || f == "--git-dir" || f == "--work-tree" || f == "--namespace"), !a.isEmpty { a = a.dropFirst() }
        }
        guard let sub = a.first else { return }
        let rest = Array(a.dropFirst())
        // Subcommands that never change working-tree files (.git itself is not snapshotted, so no snapshot is needed).
        let noWorktreeChange: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "config", "rev-parse", "ls-files", "blame",
                                             "describe", "shortlog", "grep", "fetch", "tag", "reflog", "help", "version", "--version", "cat-file",
                                             "ls-tree", "for-each-ref", "name-rev", "check-ignore", "add", "commit", "push", "notes", "count-objects",
                                             "fsck", "rev-list", "ls-remote", "whatchanged", "verify-commit", "bisect", "gc", "prune", "update-ref", "init", "clone", "stage"]
        var mutatesWorktree = !noWorktreeChange.contains(sub)
        defer { if mutatesWorktree { readOnly = false } }
        let has = { (x: String) in rest.contains(x) }
        let hasPrefix = { (x: String) in rest.contains { $0.hasPrefix(x) } }
        switch sub {
        case "reset":
            if has("--hard") || has("--merge") || has("--keep") { readOnly = false; add("git.reset.hard", .allow, .required, "it discards uncommitted changes (restorable from the snapshot taken first).", whole) }
        case "clean":
            if rest.contains(where: { $0 == "-n" || $0 == "--dry-run" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n")) }) { mutatesWorktree = false; return }
            add("git.clean", .allow, .required, "it deletes untracked\(rest.contains { $0.contains("x") } ? " and ignored" : "") files (restorable from the snapshot taken first, except dependency and build folders).", whole)
        case "checkout":
            if has("--") || has(".") || has("-f") || has("--force") || has("-p") || has("--theirs") || has("--ours") {
                add("git.checkout.discard", .allow, .required, "it overwrites working-tree files (restorable from the snapshot taken first).", whole)
            } else { add("git.checkout", .allow, .recommended, "it switches files in the working tree.", whole) }
        case "restore":
            if (has("--staged") || has("-S")) && !has("--worktree") && !has("-W") { mutatesWorktree = false; return }
            do {
                add("git.checkout.discard", .allow, .required, "it overwrites working-tree files (restorable from the snapshot taken first).", whole)
            }
        case "switch":
            if has("-f") || has("--force") || has("--discard-changes") { add("git.checkout.discard", .allow, .required, "it discards local changes (restorable from the snapshot taken first).", whole) }
        case "stash":
            readOnly = false
            if has("drop") || has("clear") { add("git.stash.drop", .ask, .recommended, "it permanently drops stashed changes, which are not in the working tree and not in snapshots.", whole) }
            else if rest.isEmpty || has("push") || has("save") || has("-u") || has("--include-untracked") || has("--all") {
                add("git.stash", .allow, .required, "it removes local changes from the working tree into a stash (also covered by the snapshot taken first).", whole)
            }
        case "branch":
            if has("-D") || (has("-d") && has("--force")) || has("--delete") && has("--force") { readOnly = false; add("git.branch.force-delete", .ask, .recommended, "it force-deletes a branch that may hold unmerged commits.", whole) }
            else if has("-d") || has("--delete") || has("-m") || has("-M") { readOnly = false }
        case "push":
            if has("--force") || has("-f") || hasPrefix("--force-with-lease") || has("--force-if-includes") || rest.contains(where: { $0.hasPrefix("+") && !$0.hasPrefix("++") }) || rest.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f") }) {
                add("git.push.force", .ask, .none, "it rewrites history on the remote, which cannot be undone from this machine.", whole)
            } else if has("--delete") || has("-d") || rest.contains(where: { $0.hasPrefix(":") && $0.count > 1 }) {
                add("git.push.delete", .ask, .none, "it deletes a branch or tag on the remote.", whole)
            } else if has("--mirror") || has("--prune") {
                add("git.push.mirror", .ask, .none, "it can delete remote branches that do not exist locally.", whole)
            }
        case "filter-branch", "filter-repo":
            add("git.history.rewrite", .ask, .recommended, "it rewrites the entire repository history.", whole)
        case "reflog":
            if has("expire") || has("delete") { add("git.reflog.expire", .ask, .recommended, "it deletes the reflog, git's own safety net for lost commits.", whole) }
        case "gc", "prune":
            if hasPrefix("--prune=now") || sub == "prune" { add("git.gc.prune", .ask, .recommended, "it permanently removes unreachable commits that could otherwise be recovered.", whole) }
        case "update-ref":
            if has("-d") { add("git.update-ref.delete", .ask, .recommended, "it deletes a git ref directly.", whole) }
        case "worktree":
            if has("remove") && (has("--force") || has("-f")) { readOnly = false; add("git.worktree.remove", .ask, .recommended, "it force-removes a worktree including uncommitted changes.", whole) }
            else if has("remove") || has("prune") { readOnly = false }
        case "rm":
            add("git.rm", .allow, .required, "it deletes tracked files (restorable from the snapshot taken first).", whole)
        case "submodule":
            if has("deinit") && (has("-f") || has("--force")) { add("git.submodule.deinit", .ask, .recommended, "it force-removes submodule working trees.", whole) }
        default: break
        }
    }

    mutating func analyzeGH(_ argv: [String], whole: String) {
        let s = argv.joined(separator: " ")
        if s.hasPrefix("repo delete") { add("gh.repo.delete", .block, .none, "it deletes a GitHub repository with all its issues and history.", whole) }
        else if s.hasPrefix("repo archive") || s.hasPrefix("release delete") || s.hasPrefix("secret delete") || s.hasPrefix("variable delete") || s.hasPrefix("run delete") || s.contains("cache delete") {
            add("gh.delete", .ask, .none, "it deletes data on GitHub.", whole)
        } else if argv.first == "api", argv.contains(where: { $0 == "DELETE" || $0 == "-XDELETE" || $0 == "--method=DELETE" }) {
            add("gh.api.delete", .ask, .none, "it sends a DELETE request to the GitHub API.", whole)
        }
    }

    mutating func analyzeKill(_ argv: [String], whole: String) {
        if argv.contains("-1") && (argv.contains("-9") || argv.contains("-KILL") || argv.count == 1 || argv.contains("-s")) || argv.last == "-1" {
            add("sys.kill.all", .block, .none, "it kills every process of the user, including the agent and all open apps.", whole)
        }
    }

    mutating func analyzeKillAll(_ name: String, _ argv: [String], whole: String) {
        let broad: Set<String> = ["node", "python", "python3", "ruby", "java", "Electron", "claude", "codex", "cursor", "Cursor", "Code", "Terminal", "iTerm2", "Finder", "Dock", "WindowServer", "loginwindow", "zsh", "bash", "sh", "Airbag", "airbag", "launchd"]
        let operands = argv.filter { !$0.hasPrefix("-") }
        if operands.contains(where: { broad.contains($0) }) || argv.contains("-u") || (name == "killall" && argv.contains("-m")) {
            add("sys.kill.broad", .ask, .none, "it kills every process matching a broad name, possibly including the agent itself, editors or other projects' servers.", whole)
        }
    }

    mutating func analyzeInterpreter(_ name: String, _ args: [ShellWord], whole: String) {
        let inline: Set<String> = ["-c", "-e", "-E", "--eval", "-p", "--print", "eval", "-x"]
        guard let i = args.firstIndex(where: { inline.contains($0.text) }), i + 1 < args.count else { return }
        let code = args[i + 1].text
        let lowered = code.lowercased()
        let deleting = ["rmtree", "os.remove", "os.unlink", "os.rmdir", "removedirs", "unlink(", "rmsync", "rmdirsync", "unlinksync", "fs.rm(", ".rm(", "rimraf",
                        "file::delete", "fileutils.rm", "rm_rf", "rm_r", "shutil.move", "send2trash", "truncate(", "os.system", "subprocess", "child_process", "execsync",
                        "spawnsync", "system(", "exec(", "`rm ", "deletesync", "fs.promises.rm", "pathlib", "unlink_missing", "dropdatabase", "drop table", "drop database"]
        if deleting.contains(where: { lowered.contains($0) }) {
            // Paths written literally inside project roots are fine; anything else needs a look.
            let literalOutside = extractPaths(code).map { classify(resolve(ShellWord($0))) }
            if let bad = literalOutside.first(where: { if case .catastrophic = $0 { return true }; return false }), case .catastrophic(let p) = bad {
                add("interp.delete.catastrophic", .block, .none, "its inline \(name) code deletes or runs commands against \(describe(p)).", whole)
                return
            }
            if !literalOutside.isEmpty, literalOutside.allSatisfy({ if case .insideProject = $0 { return true }; if case .regenerable = $0 { return true }; if case .temporary = $0 { return true }; return false }) {
                add("interp.delete.project", .allow, .required, "it deletes files from inline \(name) code inside the project (snapshot taken first).", whole)
            } else {
                add("interp.delete", .ask, .recommended, "it deletes files or runs commands from inline \(name) code that Airbag cannot analyze.", whole)
            }
        }
    }

    func extractPaths(_ code: String) -> [String] {
        var out: [String] = []
        for q in ["'", "\""] {
            let parts = code.components(separatedBy: q)
            for (i, p) in parts.enumerated() where i % 2 == 1 {
                if p.hasPrefix("/") || p.hasPrefix("./") || p.hasPrefix("../") || p.hasPrefix("~") || (!p.contains(" ") && p.contains("/")) || (!p.contains(" ") && !p.isEmpty && p.count < 80 && p.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }) {
                    out.append(p.hasPrefix("~") ? context.home + p.dropFirst() : p)
                }
            }
        }
        return out
    }

    mutating func analyzeDatabase(_ name: String, _ args: [ShellWord], whole: String) {
        let text = args.map(\.text).joined(separator: " ").uppercased()
        let destructive = ["DROP DATABASE", "DROP SCHEMA", "DROP TABLE", "TRUNCATE", "DROPDATABASE", "FLUSHALL", "FLUSHDB", "DELETE FROM", "DROP INDEX", "DROP COLLECTION", ".DROP(", "DROPTABLE"]
        guard destructive.contains(where: { text.contains($0) }) else { return }
        if name == "sqlite3" || name == "duckdb" || name == "litecli" {
            if let dbFile = args.first(where: { !$0.text.hasPrefix("-") }) {
                switch classify(resolve(dbFile)) {
                case .insideProject, .projectRoot, .regenerable:
                    add("db.local.destructive", .allow, .required, "it deletes data in a local database file inside the project (snapshot taken first).", whole); return
                case .temporary: return
                default: break
                }
            }
        }
        if text.contains("DELETE FROM") && text.contains("WHERE") && !text.contains("DROP") && !text.contains("TRUNCATE") { return }
        add("db.destructive", .ask, .none, "it drops or wipes database data, which file snapshots cannot restore.", whole)
    }

    mutating func analyzeMigrationTool(_ name: String, _ argv: [String], whole: String) {
        let s = argv.joined(separator: " ")
        let hits = ["migrate reset", "db push --force-reset", "--accept-data-loss", "db reset", "db:drop", "db:reset", "db:schema:load", "db:purge",
                    "migrate:fresh", "migrate:reset", "db:wipe", "migrate:rollback --all", "flush", "reset_db", "schema:drop", "drop", "downgrade base", "clean"]
        if hits.contains(where: { s.contains($0) }) || (name == "drizzle-kit" && s.contains("push") && s.contains("--force")) {
            if name == "supabase", s.contains("db reset"), !s.contains("--linked"), !s.contains("--db-url") {
                add("db.reset.local", .ask, .none, "it wipes and re-creates the local Supabase database (its data is not in file snapshots).", whole)
            } else {
                add("db.reset", .ask, .none, "it wipes or drops database data, which file snapshots cannot restore.", whole)
            }
        }
    }

    mutating func analyzeAWS(_ argv: [String], whole: String) {
        let s = argv.joined(separator: " ")
        if (s.hasPrefix("s3 rm") && argv.contains("--recursive")) || s.hasPrefix("s3 rb") || (s.hasPrefix("s3 sync") && argv.contains("--delete"))
            || argv.contains(where: { $0.hasPrefix("delete-") || $0 == "terminate-instances" || $0.hasPrefix("remove-") || $0 == "deregister-task-definition" }) {
            add("cloud.delete", .ask, .none, "it deletes cloud resources or data, which no local snapshot can bring back.", whole)
        }
    }

    mutating func analyzePaaS(_ name: String, _ argv: [String], whole: String) {
        let s = argv.joined(separator: " ")
        let destructive = ["rm", "remove", "destroy", "apps:destroy", "apps destroy", "pg:reset", "delete", "sites:delete", "projects:delete",
                           "firestore:delete", "database:remove", "hosting:disable", "down", "volumes destroy", "d1 delete", "kv namespace delete", "r2 bucket delete"]
        if destructive.contains(where: { s.hasPrefix($0) || s.contains(" " + $0) }) || (name == "railway" && argv.first == "down") {
            add("cloud.paas.destroy", .ask, .none, "it deletes a deployed app, database or data on \(name), which no local snapshot can bring back.", whole)
        }
    }

    mutating func analyzeContainers(_ name: String, _ argv: [String], whole: String) {
        let s = argv.joined(separator: " ")
        let compose = name.hasSuffix("-compose") || argv.first == "compose"
        if s.hasPrefix("system prune") || s.hasPrefix("volume rm") || s.hasPrefix("volume prune") || (compose && argv.contains("down") && (argv.contains("-v") || argv.contains("--volumes")))
            || s.hasPrefix("image prune -a") || (name == "colima" && argv.first == "delete") || (["orb", "orbctl"].contains(name) && argv.first == "delete") {
            add("docker.destructive", .ask, .none, "it deletes container volumes or images, which can hold local databases that file snapshots do not cover.", whole)
        }
        if argv.contains(where: { $0 == "-v" || $0.hasPrefix("--volume") || $0.hasPrefix("--mount") }) && (s.hasPrefix("run") || s.contains(" run ")) {
            if s.contains(":/") && (s.contains(" rm ") || s.contains("rm -")) {
                add("docker.mount.delete", .ask, .recommended, "it mounts host folders into a container and deletes files there, bypassing host-side checks.", whole)
            }
        }
    }

    mutating func analyzeDownload(cmdIn: ShellCommand, previousConnector: ShellConnector, whole: String) {
        // Writing the download over an existing file is covered by redirect/-o checks; piping is checked by the caller.
        let argv = cmdIn.argv
        if let i = argv.firstIndex(where: { $0 == "-o" || $0 == "--output" || $0 == "-O" }), i + 1 < cmdIn.words.count, argv[i] != "-O" {
            writeCheck(cmdIn.words[i + 1], truncates: true, whole: whole)
        }
    }

    static let packageManagerBuiltins: Set<String> = ["install", "i", "add", "remove", "rm", "uninstall", "un", "update", "up", "upgrade",
                                                       "ci", "init", "create", "publish", "pack", "link", "unlink", "list", "ls", "outdated", "audit",
                                                       "why", "info", "view", "config", "set", "cache", "store", "prune", "dedupe", "login", "logout",
                                                       "whoami", "version", "--version", "-v", "help", "test", "t", "start", "build", "dev", "lint",
                                                       "format", "fmt", "workspaces", "workspace", "install-test", "exec", "x", "dlx", "run", "run-script", "patch", "import"]

    /// npx/pnpm/yarn/bun: unwrap the binary they run and check script names that sound like a database wipe.
    mutating func analyzePackageRunner(_ name: String, _ args: [ShellWord], whole: String, depth: Int) {
        readOnly = false
        var rest = args.drop(while: { $0.text.hasPrefix("-") })
        guard let first = rest.first else { return }
        var inner: [ShellWord] = []
        var scriptName: String?
        switch name {
        case "npx", "pnpx", "bunx":
            inner = Array(rest)
        default:
            if ["exec", "x", "dlx"].contains(first.text) {
                rest = rest.dropFirst().drop(while: { $0.text.hasPrefix("-") })
                inner = Array(rest)
            } else if ["run", "run-script"].contains(first.text) {
                scriptName = rest.dropFirst().first(where: { !$0.text.hasPrefix("-") })?.text
            } else if !Analyzer.packageManagerBuiltins.contains(first.text) {
                // `yarn prisma …`, `pnpm db:reset`: a package binary or a script.
                scriptName = first.text
                inner = Array(rest)
            }
        }
        if let script = scriptName?.lowercased() {
            let dbWords = ["db", "database", "prisma", "drizzle", "supabase", "migrate", "migration", "schema", "seed"]
            let wipeWords = ["reset", "drop", "wipe", "fresh", "nuke", "truncate", "purge", "destroy", "flush"]
            if dbWords.contains(where: { script.contains($0) }) && wipeWords.contains(where: { script.contains($0) }) {
                add("db.reset.script", .ask, .none, "the package script `\(scriptName!)` looks like it wipes a database, which file snapshots cannot restore.", whole)
            }
        }
        if let tool = inner.first, ["rimraf", "del-cli", "rm", "trash"].contains(tool.text) {
            analyzeRemove(tool.text == "rm" ? "rm" : "rimraf", Array(inner.dropFirst()), whole: whole)
        } else if !inner.isEmpty {
            let text = inner.map { w in w.text.contains(" ") ? "'" + w.text + "'" : w.text }.joined(separator: " ")
            analyze(text, depth: depth + 1)
        }
    }

    /// ssh host 'command': paths are remote, so only obviously destructive commands are flagged.
    mutating func analyzeRemote(_ args: [ShellWord], whole: String) {
        readOnly = false
        let valueOpts: Set<String> = ["-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-W", "-b", "-c", "-E", "-m", "-S", "-w", "-B", "-e", "-I", "-O", "-Q"]
        var i = 0
        while i < args.count, args[i].text.hasPrefix("-") { i += valueOpts.contains(args[i].text) ? 2 : 1 }
        guard i + 1 < args.count else { return } // interactive login
        let remote = args[(i + 1)...].map(\.text).joined(separator: " ")
        let lowered = remote.lowercased()
        let patterns = ["rm -rf", "rm -fr", "rm -r ", "mkfs", "dd if=", "drop database", "drop table", "truncate ", "shutdown", "reboot",
                        "git push --force", "git reset --hard", "flushall", "docker system prune", "db:drop", "migrate reset", "> /dev/sd"]
        if patterns.contains(where: { lowered.contains($0) }) {
            add("remote.destructive", .ask, .none, "it runs a destructive command on a remote machine, outside anything Airbag can snapshot.", whole)
        }
    }
}
