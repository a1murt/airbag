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
    /// Rule ids the user turned off: their asks are skipped, their blocks always apply.
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
        // Turning a rule off relaxes what it asks about; what it blocks (wiping home, a disk, Airbag itself) stays blocked.
        var findings = analyzer.findings.filter { $0.decision == .block || !context.disabledRules.contains($0.ruleId) }
        // Read-only detection: when nothing matched and every command is known read-only, no snapshot is needed.
        if findings.isEmpty {
            findings = []
        }
        let decision = findings.map(\.decision).max() ?? .allow
        var snapshot = findings.map(\.snapshot).max() ?? .none
        if snapshot == .none && !analyzer.readOnly { snapshot = .recommended }
        return GuardVerdict(decision: decision, snapshot: snapshot, findings: findings)
    }

    /// Directories the command `cd`s or `pushd`es into, in order. A hook adds their projects to the protected roots, so
    /// `cd ../other && rm -rf build` is judged (and snapshotted) as work in that project.
    public func visitedDirectories(_ command: String, context: GuardContext) -> [String] {
        var analyzer = Analyzer(context: context)
        analyzer.analyze(command, depth: 0)
        var seen = Set<String>()
        return analyzer.visited.filter { seen.insert($0).inserted }
    }

    /// The parts of the command that may change files, which is why it gets a snapshot (empty for a read-only command).
    public func writers(_ command: String, context: GuardContext) -> [String] {
        var analyzer = Analyzer(context: context)
        analyzer.analyze(command, depth: 0)
        return analyzer.writers
    }
}

// MARK: - Analyzer

struct Analyzer {
    let context: GuardContext
    var findings: [GuardFinding] = []
    /// Commands seen so far that may modify files; empty while every command is known not to.
    var writers: [String] = []
    var readOnly: Bool { writers.isEmpty }
    /// Name of the command being analysed (what `mayWrite()` records).
    var current = ""
    var cwd: String?
    var visited: [String] = []

    init(context: GuardContext) {
        self.context = context
        self.cwd = context.cwd
    }

    mutating func mayWrite(_ what: String? = nil) {
        let w = what ?? current
        if !writers.contains(w) { writers.append(w) }
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
        // Only the text the agent wrote: nested analyses re-join words after quote removal (xargs), where a literal quote
        // is data, not syntax.
        if lexer.unterminated && depth == 0 {
            add("shell.unparsed", .ask, .recommended, "it has a quote, substitution or case pattern that is never closed, so Airbag cannot tell which commands it runs.", line)
        }
        for sub in lexer.substitutions { analyze(sub, depth: depth + 1) }
        var previous: ShellCommand?
        for cmd in commands {
            analyzeCommand(cmd, previous: previous, depth: depth)
            previous = cmd
        }
    }

    /// `brew shellenv`, `pyenv init -` and friends print shell environment setup for `eval`.
    static func isEnvironmentSetup(_ text: String) -> Bool {
        let w = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let tool = w.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
        let sub = w.count > 1 ? w[1] : ""
        switch tool {
        case "brew": return sub == "shellenv"
        case "pyenv", "rbenv", "nodenv", "goenv", "jenv", "plenv", "zoxide", "starship": return sub == "init" || sub == "virtualenv-init"
        case "direnv": return sub == "hook" || sub == "export"
        case "fnm", "opam": return sub == "env"
        case "mise", "rtx": return sub == "activate" || sub == "env"
        case "conda", "micromamba": return sub.hasPrefix("shell.") || sub == "shell"
        case "ssh-agent": return true
        default: return false
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
        for root in context.roots.sorted(by: { $0.count > $1.count }) {
            if p == root { return r.contents ? .insideProject(root) : .projectRoot(root) } // `*` skips dotfiles such as .git
            if p.hasPrefix(root + "/") {
                let comps = p.dropFirst(root.count + 1).split(separator: "/").map(String.init)
                if comps.first == ".git" { return .gitInternals(root) }
                if comps.contains(where: { Analyzer.excludedNames.contains($0) }) { return .regenerable }
                return .insideProject(root)
            }
        }
        let home = context.home
        for c in [home + "/.cache", home + "/Library/Caches", home + "/.npm/_cacache", home + "/Library/Developer/Xcode/DerivedData",
                  home + "/.cargo/registry/cache", home + "/.gradle/caches", home + "/.pnpm-store", home + "/Library/pnpm/store"]
            where p == c || p.hasPrefix(c + "/") { return .regenerable }
        for t in ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", context.environment["TMPDIR"] ?? ""] where !t.isEmpty {
            let tt = t.hasSuffix("/") ? String(t.dropLast()) : t
            if p.hasPrefix(tt + "/") { return .temporary }
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
        "nm", "lipo", "spctl", "defaults", "mdfind", "mdls", "column", "fold", "fmt", "nl", "rev", "seq",
        "yes", "clear", "tput", "stty", "tty", "locale", "command", "hash", "wait", "jobs", "fg", "bg", "read", "exit", "return",
        "diskutil", "tmutil", "pmset", "system_profiler", "ioreg", "crontab", "networksetup", "scutil", "dig", "nslookup",
        "ping", "host", "whois", "traceroute", "nc", "tldr", "bat", "exa", "eza", "fzf", "gh",
        "[[", ":", "local", "declare", "typeset", "readonly", "shift", "getopts", "trap", "let", "ulimit", "umask", "setopt",
        "unsetopt", "whence", "where", "rehash", "dirs", "shopt", "break", "continue", "times",
        "cksum", "sum", "b2sum", "sha1sum", "sha224sum", "sha384sum", "sha512sum", "od", "look", "join", "paste", "comm",
        "expand", "unexpand", "tac", "zcat", "gzcat", "bzcat", "xzcat", "zgrep", "zegrep", "zfgrep", "dwarfdump", "size",
        "objdump", "uuidgen", "cal", "expr", "w", "who", "last", "users", "groups", "getconf", "kextstat", "vmmap", "heap",
        "leaks", "footprint", "iostat", "memory_pressure", "zprint", "lsbom", "GetFileInfo", "pagesize", "col", "colrm",
    ]

    /// Whether this invocation only reads files, so it needs no snapshot. Most tools read or write by name alone
    /// (`readOnlyCommands`); the ones below do either depending on their arguments, and only their reading forms count.
    func readsOnly(_ name: String, _ args: [ShellWord], input: String? = nil) -> Bool {
        let argv = args.map(\.text)
        let (flags, long, operands) = splitOptions(args)
        switch name {
        case "sed":
            return !Analyzer.sedEditsInPlace(args) && !Analyzer.sedScriptWrites(argv)
        case "sqlite3":
            return Analyzer.sqliteReadsOnly(argv, input: input)
        case "launchctl":
            return ["list", "print", "print-cache", "print-disabled", "blame", "help", "version", "managerpid", "manageruid",
                    "managername", "dumpstate", "dumpjpcategory", "procinfo", "hostinfo", "resolveport", "examine", "error",
                    "variant", "getenv", "plist"].contains(argv.first ?? "")
        case "log":
            return argv.isEmpty || ["show", "stream", "stats", "help"].contains(argv[0]) // `log collect` writes an archive, `log erase` and `log config` change the system
        case "csrutil", "fdesetup", "nvram", "bless":
            return Analyzer.readsSecurityStatus(name, argv)
        case "ssh-keygen":
            // -l fingerprints, -y prints a public key, -F finds a host, -L shows a certificate, -e/-i convert to stdout;
            // generating a key, -p/-c (change passphrase or comment), -R/-H (rewrite known_hosts) and signing write files.
            let ((f, _, _), values) = splitOptionValues(args, valued: ["-f", "-E", "-F", "-P", "-N", "-C", "-t", "-b", "-s", "-I", "-n", "-O",
                                                                        "-V", "-z", "-Y", "-D", "-m", "-a", "-r", "-S", "-w", "-M", "-G", "-T", "-J", "-j", "-Z"])
            if let op = values["-Y"]?.text { return ["verify", "check-novalidate", "find-principals", "match-principals"].contains(op) }
            if !f.isDisjoint(with: ["R", "p", "c", "s", "k", "A", "u", "K"]) || (f.contains("H") && !f.contains("F")) { return false }
            return !f.isDisjoint(with: ["l", "y", "F", "L", "B", "Q", "e", "i", "D"])
        case "security":
            guard let sub = argv.first else { return true }
            switch sub {
            case "list-keychains", "default-keychain", "login-keychain": return !argv.contains("-s")
            case "authorizationdb": return argv.dropFirst().first == "read"
            case "cms": return argv.contains("-D") && !argv.contains("-o")
            default:
                return ["find-generic-password", "find-internet-password", "find-key", "find-certificate", "find-identity",
                        "show-keychain-info", "dump-keychain", "dump-trust-settings", "verify-cert", "error", "help"].contains(sub)
            }
        case "xattr":
            return flags.isDisjoint(with: ["w", "d", "c"])
        case "plutil":
            // -p, -lint and -type print; the editing verbs rewrite the file unless the result goes to stdout (`-o -`).
            guard argv.contains(where: { ["-convert", "-insert", "-replace", "-remove", "-extract", "-create"].contains($0) }) else { return true }
            guard let o = argv.firstIndex(of: "-o"), o + 1 < argv.count else { return false }
            return ["-", "/dev/stdout"].contains(argv[o + 1])
        case "codesign":
            return !flags.contains("s") && !long.contains("--sign") && !long.contains("--remove-signature")
        case "curl":
            let ((f, l, _), values) = splitOptionValues(args, valued: Analyzer.curlValued)
            let toFile = ["-o", "--output", "-D", "--dump-header", "-c", "--cookie-jar", "--stderr"].compactMap { values[$0] }
                .contains { !["-", "/dev/null", "/dev/stdout", "/dev/stderr"].contains($0.text) }
            let namesFiles = !f.isDisjoint(with: ["O", "J"]) || values["-K"] != nil || values["--config"] != nil
                || !l.isDisjoint(with: ["--remote-name", "--remote-name-all", "--remote-header-name", "--output-dir", "--create-dirs",
                                        "--etag-save", "--libcurl", "--trace", "--trace-ascii", "--hsts", "--alt-svc"])
            return !toFile && !namesFiles
        case "ifconfig":
            return operands.count <= 1 // `ifconfig`, `ifconfig -a`, `ifconfig en0`; anything after the interface configures it
        case "mount":
            return operands.isEmpty && flags.isSubset(of: ["v"])
        case "mdutil":
            return !flags.isEmpty && flags.isSubset(of: ["s", "t", "L", "v", "a"]) && !flags.isDisjoint(with: ["s", "t", "L"])
        case "pkgutil":
            let reads: Set<String> = ["--pkgs", "--pkgs-plist", "--files", "--pkg-info", "--pkg-info-plist", "--file-info", "--file-info-plist",
                                      "--pkg-groups", "--groups", "--groups-plist", "--group-pkgs", "--export-plist", "--payload-files",
                                      "--check-signature", "--regexp", "--volume", "--only-files", "--only-dirs", "--help"]
            let names = long.filter { !$0.contains("=") }
            return !names.isEmpty && names.isSubset(of: reads)
        case "xmllint":
            return !long.contains("--output")
        case "ipconfig":
            return ["getifaddr", "getsummary", "getoption", "getpacket", "getv6packet", "getra", "ifcount"].contains(argv.first ?? "")
        case "dscl":
            return argv.contains { ["list", "-list", "read", "-read", "readall", "-readall", "search", "-search", "cat"].contains($0) }
                && !argv.contains { ["create", "-create", "delete", "-delete", "append", "-append", "merge", "-merge", "passwd", "-passwd",
                                     "change", "-change", "createpl", "-createpl", "deletepl", "-deletepl"].contains($0) }
        case "systemextensionsctl":
            return argv.first == "list"
        case "kmutil":
            return ["showloaded", "inspect"].contains(argv.first ?? "")
        case "socketfilterfw":
            return !long.isEmpty && long.allSatisfy { $0.hasPrefix("--get") || $0 == "--listapps" }
        case "xcode-select":
            return !argv.isEmpty && argv.allSatisfy { ["-p", "--print-path", "-v", "--version", "-h", "--help"].contains($0) }
        default:
            return Analyzer.readOnlyCommands.contains(name)
        }
    }

    static let curlValued: Set<String> = [
        "-o", "--output", "-D", "--dump-header", "-c", "--cookie-jar", "-K", "--config", "--stderr", "-H", "--header", "-d", "--data",
        "--data-raw", "--data-binary", "--data-urlencode", "-X", "--request", "-u", "--user", "-A", "--user-agent", "-e", "--referer",
        "-m", "--max-time", "-w", "--write-out", "-x", "--proxy", "-F", "--form", "-b", "--cookie", "-r", "--range", "-T",
        "--upload-file", "-E", "--cert", "--connect-timeout", "--retry", "-C", "--continue-at", "-Y", "-y", "-z", "-t", "-U", "-Q", "-P",
    ]

    /// The command after `perl -e 'alarm N; exec @ARGV'` (or `'alarm shift; exec @ARGV' N`), nil for any other perl code.
    static func perlTimeoutCommand(_ args: [ShellWord]) -> [ShellWord]? {
        guard args.count >= 3, ["-e", "-E"].contains(args[0].text), !args[1].opaque,
              let m = args[1].text.range(of: #"^\s*alarm\s+(shift|\d+)\s*;\s*exec\s*\(?\s*@ARGV\s*\)?\s*;?\s*$"#, options: .regularExpression)
        else { return nil }
        var rest = Array(args[2...])
        if args[1].text[m].contains("shift") {
            guard let secs = rest.first, !secs.text.isEmpty, secs.text.allSatisfy(\.isNumber) else { return nil }
            rest.removeFirst()
        }
        return rest.isEmpty ? nil : rest
    }

    /// `-i`, `-i.bak`, `-Ei`, `--in-place[=SUF]` (GNU) and `-I` (BSD) edit the files in place.
    static func sedEditsInPlace(_ args: [ShellWord]) -> Bool {
        args.contains { a in
            let t = a.text
            return t == "--in-place" || t.hasPrefix("--in-place=") || (t.hasPrefix("-") && !t.hasPrefix("--") && (t.contains("i") || t.contains("I")))
        }
    }

    /// A sed script whose `w`/`W` command or `w` flag writes a file, or whose `e` runs a command. Scripts read from a
    /// file (`-f`) cannot be inspected. Errs towards "writes": a false alarm only costs a snapshot.
    static func sedScriptWrites(_ argv: [String]) -> Bool {
        var scripts: [String] = []
        var i = 0
        var sawExpression = false
        while i < argv.count {
            let a = argv[i]
            if a == "-f" || a.hasPrefix("--file") || (a.hasPrefix("-") && !a.hasPrefix("--") && a.contains("f")) { return true }
            if a == "-e" || a == "--expression", i + 1 < argv.count { scripts.append(argv[i + 1]); sawExpression = true; i += 2; continue }
            if a.hasPrefix("--expression=") { scripts.append(String(a.dropFirst("--expression=".count))); sawExpression = true }
            else if !a.hasPrefix("-") && !sawExpression { scripts.append(a); sawExpression = true } // the first operand is the script
            i += 1
        }
        let command = #"(^|[;\n{}!\s0-9$/])[gpIimMe0-9]*[wWe](\s|$|;|\})"#
        return scripts.contains { $0.range(of: command, options: .regularExpression) != nil }
    }

    /// sqlite3 with SQL that only reads (SELECT, EXPLAIN, PRAGMA queries and display dot-commands). The SQL comes from
    /// `-cmd` and the arguments after the database; without the latter sqlite3 reads stdin, which is known only for a
    /// here-document or here-string (`input`), not for a pipe or a file.
    static func sqliteReadsOnly(_ argv: [String], input: String?) -> Bool {
        let valued: Set<String> = ["separator", "cmd", "init", "nullvalue", "newline", "mmap", "vfs", "lookaside", "maxsize", "heap",
                                   "pagecache", "escape", "nonce"]
        var sql: [String] = []
        var trailing: [String] = []
        var database: String?
        var i = 0
        while i < argv.count {
            let a = argv[i]
            i += 1
            if a.hasPrefix("-") {
                let opt = String(a.drop(while: { $0 == "-" }))
                if ["A", "archive", "init", "append"].contains(opt) { return false } // archive mode writes; -init runs a file
                if valued.contains(opt), i < argv.count {
                    if opt == "cmd" { sql.append(argv[i]) }
                    i += 1
                }
                continue
            }
            if database == nil { database = a } else { trailing.append(a) }
        }
        if trailing.isEmpty {
            guard let input else { return false }
            trailing = [input]
        }
        sql += trailing
        let readDot: Set<String> = ["tables", "table", "schema", "indexes", "indices", "databases", "dbinfo", "headers", "header", "mode",
                                    "width", "show", "help", "stats", "timer", "eqp", "nullvalue", "separator", "print", "quit", "exit",
                                    "bail", "echo", "changes", "fullschema", "dump", "sha3sum", "explain", "prompt", "scanstats",
                                    "version", "recover"]
        var statements: [String] = []
        for text in sql {
            for line in text.split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(".") {
                    let dot = t.dropFirst().split(separator: " ").first.map(String.init) ?? ""
                    if !readDot.contains(dot) { return false }
                } else {
                    statements.append(t)
                }
            }
        }
        let upper = statements.joined(separator: "\n").uppercased()
        let writes = [#"\b(INSERT|UPDATE|DELETE|REPLACE|UPSERT|CREATE|DROP|ALTER|VACUUM|REINDEX|ATTACH|DETACH|ANALYZE|TRUNCATE)\b"#,
                      #"\bPRAGMA\s+[A-Z0-9_.]+\s*="#, #"\b(WAL_CHECKPOINT|INCREMENTAL_VACUUM|OPTIMIZE|WRITEFILE|EDIT|LOAD_EXTENSION)\b"#]
        return !writes.contains { upper.range(of: $0, options: .regularExpression) != nil }
    }

    /// Status queries of the low-level security tools. Everything else they do (turn SIP or FileVault off, change boot
    /// settings, write NVRAM) stays blocked, and so does any form Airbag does not know.
    static func readsSecurityStatus(_ name: String, _ argv: [String]) -> Bool {
        switch name {
        case "csrutil":
            // `csrutil status`, `csrutil authenticated-root status`, `csrutil netboot list`; bare `csrutil` prints usage.
            return argv.isEmpty || argv == ["status"] || argv == ["authenticated-root", "status"] || argv == ["netboot", "list"]
        case "fdesetup":
            guard let verb = argv.first else { return true }
            return ["status", "isactive", "list", "haspersonalrecoverykey", "hasinstitutionalrecoverykey", "usingrecoverykey",
                    "supportsauthrestart", "showdeferralinfo", "validaterecovery", "version", "help", "-help"].contains(verb)
        case "nvram":
            // `nvram -p`, `nvram -xp`, `nvram NAME` print; `NAME=VALUE`, -d, -c and -f change NVRAM.
            return argv.allSatisfy { a in
                a.hasPrefix("-") ? a.count > 1 && a.dropFirst().allSatisfy { "px".contains($0) } : !a.contains("=")
            }
        case "bless":
            // `bless --info [folder]` and `bless --getBoot` report; every other option sets something.
            let options = argv.filter { $0.hasPrefix("-") }.map { String($0.drop(while: { $0 == "-" })) }
            return !options.isEmpty && options.allSatisfy { ["info", "getBoot", "verbose", "plist", "quiet", "version", "help"].contains($0) }
                && options.contains { ["info", "getBoot", "version", "help"].contains($0) }
        default:
            return false
        }
    }

    /// `>`, `2>`, `>>`, `&>`, `>&file`, zsh's `>!` family and `N<>file` (read-write on an output descriptor, which
    /// overwrites the file in place) open a file for writing. `2>&1`, `>&2` and `2>&-` only duplicate or close a
    /// descriptor; `<&`, `<` and a bare `<>` (stdin) do not write.
    static func opensFileForWriting(_ r: ShellRedirect) -> Bool {
        let fd = r.op.prefix { $0.isNumber }
        var op = String(r.op.dropFirst(fd.count))
        if op.count > 1, op.hasSuffix("!") { op.removeLast() }
        if op == "<>" { return !fd.isEmpty && fd.contains { $0 != "0" } }
        if op == ">&" {
            let t = r.target
            let descriptor = !t.opaque && (t.text == "-" || (!t.text.isEmpty && t.text.allSatisfy { $0.isNumber }))
            return !descriptor
        }
        return [">", ">|", ">>", "&>", "&>>", ">>&"].contains(op)
    }

    mutating func analyzeCommand(_ cmdIn: ShellCommand, previous: ShellCommand?, depth: Int) {
        var cmd = cmdIn
        // Redirections that write.
        for r in cmd.redirects where Analyzer.opensFileForWriting(r) {
            let truncates = !r.op.contains(">>")
            if let rp = resolve(r.target), hookConfigFiles.contains(rp.path) {
                add("self.hooks", .ask, .none, "it rewrites an agent's hook configuration, which can switch Airbag's protection off.", r.target.text)
                mayWrite("\(r.op) \(r.target.text)")
                continue
            }
            let cls = classify(resolve(r.target))
            if cls != .temporary { mayWrite("\(r.op) \(r.target.text)") }
            if case .device = cls { add("fs.device.write", .block, .none, "it writes directly to a device, which can destroy a disk.", r.target.text) }
            switch cls {
            case .catastrophic: add("fs.redirect.catastrophic", .block, .none, "it overwrites \(r.target.text), which is not a regular project file.", r.target.text)
            case .airbag: add("self.airbag", .block, .none, "it modifies Airbag's own data, which protects this project.", r.target.text)
            case .outside where truncates && replacesOrUnknown(resolve(r.target)?.path):
                add("fs.truncate.outside", .ask, .recommended, "it overwrites \(r.target.text) outside the protected project, where no snapshot can restore it.", r.target.text)
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
        // busybox/toybox applets: `busybox rm -rf x` is `rm -rf x`.
        while let f = words.first, ["busybox", "toybox", "box"].contains((f.text as NSString).lastPathComponent), words.count > 1 {
            words.removeFirst()
        }
        cmd.words = words
        guard let first = words.first else { return }
        var name = (first.text as NSString).lastPathComponent
        // Homebrew GNU coreutils/findutils install `grm`, `gmv`, `gfind`, ….
        let gnuTools: Set<String> = ["rm", "mv", "cp", "ln", "dd", "chmod", "chown", "chgrp", "truncate", "find", "xargs", "install",
                                     "tee", "shred", "rmdir", "unlink", "touch", "tar", "sed"]
        if name.count > 1, name.hasPrefix("g"), gnuTools.contains(String(name.dropFirst())) { name = String(name.dropFirst()) }
        current = name
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

        // Here-strings feed literal code to shells and interpreters: analyse it like `-c`. A here-document fed to a shell
        // is shell code and is analysed the same way; one fed to an interpreter is a whole script, treated like a script
        // file (snapshot, no text heuristics: on real agent scripts they mostly flag string data).
        let hereString = cmd.redirects.first(where: { $0.op == "<<<" })?.target
        let hereDocument = cmd.redirects.first(where: { ($0.op == "<<" || $0.op == "<<-") && $0.target.heredoc != nil })?.target.heredoc
        if Analyzer.shells.contains(name) || Analyzer.shells.contains(first.text), let code = hereString ?? hereDocument.map({ ShellWord($0) }) {
            if code.opaque { add("shell.opaque", .ask, .recommended, "it feeds a shell text built from unresolved variables.", whole) }
            analyze(code.text, depth: depth + 1)
            return
        }
        if let code = hereString, ["python", "python3", "node", "ruby", "perl", "php", "deno", "bun"].contains(name) {
            analyzeInterpreter(name, [ShellWord("-c"), code], whole: whole, depth: depth)
            return
        }
        // `perl -e 'alarm 30; exec @ARGV' cmd …` is the usual stand-in for timeout(1) on macOS: judge the command it runs.
        if name == "perl", let innerWords = Analyzer.perlTimeoutCommand(args) {
            var inner = cmd
            inner.words = innerWords
            inner.redirects = [] // already checked above
            analyzeCommand(inner, previous: previous, depth: depth)
            return
        }
        // Nested shells: sh -c "…", bash -lc "…", eval "…"
        if Analyzer.shells.contains(first.text) || Analyzer.shells.contains(name) {
            if let ci = argv.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }), ci + 1 < args.count {
                if args[ci + 1].opaque { add("shell.opaque", .ask, .recommended, "it runs a shell command built from unresolved variables.", whole) }
                analyze(args[ci + 1].text, depth: depth + 1)
            } else {
                mayWrite(name) // runs a script file we cannot inspect
            }
            return
        }
        if name == "eval" {
            // `eval "$(brew shellenv)"` and friends evaluate environment setup printed by a known tool.
            let setupOnly = args.allSatisfy { w in
                guard w.opaque else { return true }
                guard w.text.hasPrefix("$("), w.text.hasSuffix(")") else { return false }
                return Analyzer.isEnvironmentSetup(String(w.text.dropFirst(2).dropLast()))
            }
            if args.contains(where: \.opaque) && !setupOnly { add("shell.opaque", .ask, .recommended, "it evaluates text built from unresolved variables.", whole) }
            analyze(argv.joined(separator: " "), depth: depth + 1)
            return
        }
        if name == "xargs" || name == "parallel" {
            analyzeXargs(args, previous: previous, whole: whole, depth: depth)
            return
        }
        if name == "cd" || name == "pushd" {
            if let target = args.first(where: { !$0.text.hasPrefix("-") }) {
                cwd = resolve(target)?.path
            } else {
                cwd = context.home
            }
            if let c = cwd { visited.append(c) }
            return
        }
        if name == "find" { analyzeFind(args, whole: whole); return }

        if name != "git" && name != "brew" && !readsOnly(name, args, input: (hereString ?? hereDocument.map { ShellWord($0) })?.text) {
            mayWrite(name)
        }
        switch name {
        case "rm", "unlink", "rmdir", "srm", "shred", "rimraf", "del", "del-cli", "trash-put": analyzeRemove(name, args, whole: whole)
        case "npx", "pnpx", "bunx", "npm", "pnpm", "yarn", "bun":
            analyzePackageRunner(name, args, whole: whole, depth: depth)
        case "ssh":
            analyzeRemote(args, whole: whole)
        case "mv": analyzeMove(args, whole: whole)
        case "cp", "rsync", "ditto": analyzeCopy(name, args, whole: whole)
        case "truncate": analyzeTruncate(args, whole: whole)
        case "tar", "bsdtar":
            if argv.contains("--remove-files") {
                var operands: [ShellWord] = []
                var i = 0
                while i < args.count {
                    let t = args[i].text
                    if t == "-f" || t == "--file" || t == "-C" || t == "--directory" || t == "-T" || t == "--exclude" { i += 2; continue }
                    if t.hasPrefix("-") { i += 1; continue }
                    operands.append(args[i]); i += 1
                }
                // In bundled short options (`-czf a.tgz`), the archive name follows the bundle: skip the first operand then.
                if args.contains(where: { !$0.text.hasPrefix("--") && $0.text.hasPrefix("-") && $0.text.contains("f") && $0.text != "-f" }), !operands.isEmpty {
                    operands.removeFirst()
                }
                classifyDeletion(operands, recursive: true, verb: "archive and then delete", whole: whole)
            }
        case "zip":
            if args.contains(where: { $0.text == "-m" || $0.text == "--move" || ($0.text.hasPrefix("-") && !$0.text.hasPrefix("--") && $0.text.contains("m")) }) {
                let operands = args.filter { !$0.text.hasPrefix("-") }
                classifyDeletion(Array(operands.dropFirst()), recursive: true, verb: "zip and then delete", whole: whole)
            }
        case "sponge":
            for t in args where !t.text.hasPrefix("-") { writeCheck(t, truncates: !args.contains { $0.text == "-a" }, whole: whole) }
        case "install":
            if !args.contains(where: { $0.text == "-d" }), let last = args.last(where: { !$0.text.hasPrefix("-") }), args.filter({ !$0.text.hasPrefix("-") }).count >= 2 {
                writeCheck(last, truncates: true, whole: whole)
            }
        case "ln":
            let operands = args.filter { !$0.text.hasPrefix("-") }
            if operands.count >= 2, let last = operands.last { writeCheck(last, truncates: args.contains { $0.text.hasPrefix("-") && $0.text.contains("f") }, whole: whole) }
        case "script":
            // script [-q] [-c 'cmd'] file   (util-linux)   or   script [-q] file cmd args…   (BSD/macOS)
            if let ci = argv.firstIndex(of: "-c"), ci + 1 < args.count { analyze(args[ci + 1].text, depth: depth + 1) }
            else {
                let operands = args.drop(while: { $0.text.hasPrefix("-") })
                if operands.count > 1 { analyze(operands.dropFirst().map(\.text).joined(separator: " "), depth: depth + 1) }
            }
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
            if let sub = argv.first, ["submit", "asuser", "bsexec"].contains(sub) {
                if let dd = argv.firstIndex(of: "--"), dd + 1 < args.count {
                    analyze(args[(dd + 1)...].map { $0.text.contains(" ") ? "'\($0.text)'" : $0.text }.joined(separator: " "), depth: depth + 1)
                } else {
                    add("sys.launchctl.run", .ask, .recommended, "it starts a program through launchd, outside the agent's view.", whole)
                }
            }
        case "crontab": if argv.contains("-r") { add("sys.crontab.remove", .block, .none, "it deletes every cron job of the user without confirmation.", whole) }
        case "csrutil", "nvram", "bless", "fdesetup":
            if !Analyzer.readsSecurityStatus(name, argv) {
                add("sys.security", .block, .none, "it changes low-level system security or boot settings.", whole)
            }
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
        case "python" where args.first.map({ ($0.text as NSString).lastPathComponent == "manage.py" }) == true,
             "python3" where args.first.map({ ($0.text as NSString).lastPathComponent == "manage.py" }) == true:
            analyzeMigrationTool("manage.py", Array(argv.dropFirst()), whole: whole)
        case "python", "python2", "python3", "node", "perl", "ruby", "php", "deno", "lua", "Rscript", "swift":
            if name == "perl", args.contains(where: { $0.text.hasPrefix("-") && $0.text.contains("i") && !$0.text.hasPrefix("--") }) {
                for t in args.filter({ !$0.text.hasPrefix("-") }).dropFirst() { writeCheck(t, truncates: true, whole: whole) }
            }
            analyzeInterpreter(name, args, whole: whole, depth: depth)
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
            if argv.first == "allow" {
                add("self.allow", .block, .none, "only the user can approve a command Airbag stopped (menu bar → Guard → Allow once); an agent approving its own command makes the question meaningless.", whole)
            }
        case "brew":
            if !["list", "info", "search", "--version", "config", "doctor", "outdated", "deps", "leaves"].contains(argv.first ?? "") { mayWrite() }
        default:
            break
        }
    }

    // MARK: rule groups

    mutating func classifyDeletion(_ targets: [ShellWord], recursive: Bool, verb: String, whole: String) {
        for t in targets {
            if let r = resolve(t), hookConfigFiles.contains(r.path) {
                add("self.hooks", .ask, .none, "it removes an agent's hook configuration, which switches Airbag's protection off.", t.text)
                continue
            }
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

    func gitTopLevel(_ path: String) -> String? {
        var dir = path
        while !dir.isEmpty {
            var st = stat()
            if lstat(dir + "/.git", &st) == 0 { return dir }
            if dir == "/" { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
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

    /// Options anywhere on the line (GNU tools and rsync accept them after operands). `valued` options take the next
    /// word as their value, so it is not mistaken for a source or destination; their values are returned by name.
    func splitOptions(_ args: [ShellWord], valued: Set<String> = []) -> (flags: Set<Character>, long: Set<String>, operands: [ShellWord]) {
        splitOptionValues(args, valued: valued).0
    }

    func splitOptionValues(_ args: [ShellWord], valued: Set<String>) -> ((flags: Set<Character>, long: Set<String>, operands: [ShellWord]), [String: ShellWord]) {
        var flags = Set<Character>(), long = Set<String>(), operands: [ShellWord] = []
        var values: [String: ShellWord] = [:]
        var endOfOptions = false
        var i = 0
        while i < args.count {
            let a = args[i]
            i += 1
            if !endOfOptions && a.text == "--" { endOfOptions = true; continue }
            if !endOfOptions && a.text.hasPrefix("--") {
                if let eq = a.text.firstIndex(of: "=") {
                    let name = String(a.text[..<eq])
                    long.insert(name); long.insert(a.text)
                    if valued.contains(name) { var v = a; v.text = String(a.text[a.text.index(after: eq)...]); values[name] = v }
                } else {
                    long.insert(a.text)
                    if valued.contains(a.text), i < args.count { values[a.text] = args[i]; i += 1 }
                }
                continue
            }
            if !endOfOptions && a.text.hasPrefix("-") && a.text.count > 1 && !a.quoted {
                let cluster = Array(a.text.dropFirst())
                for (k, ch) in cluster.enumerated() {
                    flags.insert(ch)
                    if valued.contains("-" + String(ch)) {
                        let rest = String(cluster[(k + 1)...])
                        if !rest.isEmpty { var v = a; v.text = rest; values["-" + String(ch)] = v }
                        else if i < args.count { values["-" + String(ch)] = args[i]; i += 1 }
                        break
                    }
                }
                continue
            }
            operands.append(a)
        }
        return ((flags, long, operands), values)
    }

    static let rsyncValued: Set<String> = [
        "--exclude", "--include", "--exclude-from", "--include-from", "--filter", "--files-from", "--chmod", "--chown", "--rsh",
        "--backup-dir", "--suffix", "--compare-dest", "--copy-dest", "--link-dest", "--partial-dir", "--temp-dir", "--max-size",
        "--min-size", "--bwlimit", "--timeout", "--contimeout", "--port", "--log-file", "--log-file-format", "--out-format",
        "--password-file", "--rsync-path", "--modify-window", "--max-delete", "--block-size", "--iconv", "--usermap", "--groupmap",
        "--sockopts", "--address", "--skip-compress", "--remote-option", "--info", "--debug", "--write-batch", "--read-batch",
        "-e", "-f", "-T", "-B", "-M",
    ]
    /// Options of cp and mv whose value is a separate word (`--backup` and friends take theirs only after `=`).
    static let cpMvValued: Set<String> = ["-t", "--target-directory", "-S", "--suffix"]

    mutating func analyzeRemove(_ name: String, _ args: [ShellWord], whole: String) {
        let (flags, long, operands) = splitOptions(args)
        let recursive = name == "rimraf" || name == "del" || name == "del-cli" || flags.contains("r") || flags.contains("R") || long.contains("--recursive")
        if name == "trash-put" { return } // goes to the Trash
        if operands.isEmpty { return }
        classifyDeletion(operands, recursive: recursive || name == "rmdir", verb: "delete", whole: whole)
    }

    mutating func analyzeFind(_ args: [ShellWord], whole: String) {
        let argv = args.map(\.text)
        // -exec and -ok run a command per match (up to `;` or `+`): the find reads only when that command does.
        var execs: [[ShellWord]] = []
        var i = 0
        while i < args.count {
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(args[i].text) {
                var j = i + 1
                while j < args.count, ![";", "+"].contains(args[j].text) { j += 1 }
                if j > i + 1 { execs.append(Array(args[(i + 1)..<j])) }
                i = j
            }
            i += 1
        }
        let deletes = argv.contains("-delete") || execs.contains { w in
            let t = (w[0].text as NSString).lastPathComponent
            return Analyzer.shells.contains(t) || !readsOnly(t, Array(w.dropFirst()))
        }
        guard deletes else { return } // read-only
        mayWrite("find")
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
        guard ["rm", "unlink", "rmdir", "shred", "mv", "chmod", "chown"].contains(innerName) else {
            analyze(inner.map(\.text).joined(separator: " "), depth: depth + 1) // records whether the inner command writes
            return
        }
        mayWrite(innerName)
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
        let ((_, _, operands), values) = splitOptionValues(args, valued: Analyzer.cpMvValued)
        let target = values["-t"] ?? values["--target-directory"]
        guard operands.count >= (target == nil ? 2 : 1) else { return }
        let sources = target == nil ? Array(operands.dropLast()) : operands
        let dest = target ?? operands.last!
        if dest.text == "/dev/null" { classifyDeletion(sources, recursive: true, verb: "delete", whole: whole); return }
        defer { destinationCheck("mv", sources, dest, truncates: false, intoDirectory: target != nil, whole: whole) }
        for s in sources {
            if let r = resolve(s), hookConfigFiles.contains(r.path) {
                add("self.hooks", .ask, .none, "it moves an agent's hook configuration away, which switches Airbag's protection off.", s.text)
                continue
            }
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

    /// cp, mv and rsync put their sources *inside* an existing directory, so a system or home folder named as the
    /// destination is not itself overwritten: what gets written is `dest/<source name>`. When the names written are not
    /// known (`src/`, globs, ditto, which copies a directory's contents) the copy can still clobber files there: ask.
    /// A move replaces an existing file at the destination, which is outside every snapshot when the file is.
    /// `relative` (rsync -R, cp --parents) recreates each source's path below the destination; `intoDirectory` is `-t DIR`.
    mutating func destinationCheck(_ tool: String, _ sources: [ShellWord], _ dest: ShellWord, truncates: Bool, relative: Bool = false,
                                   intoDirectory: Bool = false, whole: String) {
        guard let resolvedDest = resolve(dest) else { writeCheck(dest, truncates: truncates, whole: whole); return }
        let cls = classify(resolvedDest)
        var critical: String?
        if case .catastrophic(let p) = cls { critical = p }
        let existingDirectory = context.useFileSystem && isDirectory(resolvedDest.path)
        guard intoDirectory || relative || critical != nil || (existingDirectory && cls == .outside) else {
            writeCheck(dest, truncates: truncates || replacesExistingFile(resolvedDest.path), whole: whole)
            return
        }
        let names: [String?] = sources.map { s in
            let t = s.text
            if tool == "ditto" || s.opaque || s.hasGlob || t.hasSuffix("/") || t.hasSuffix("/.") || t.hasSuffix("/..") || [".", ".."].contains(t) { return nil }
            if relative {
                var rel = t
                if let marker = rel.range(of: "/./") { rel = String(rel[marker.upperBound...]) }
                while rel.hasPrefix("./") { rel.removeFirst(2) }
                while rel.hasPrefix("/") { rel.removeFirst() }
                return rel.isEmpty || rel.split(separator: "/").contains("..") ? nil : rel
            }
            let name = (t as NSString).lastPathComponent
            return name.isEmpty || name == "/" ? nil : name
        }
        guard !names.isEmpty, names.allSatisfy({ $0 != nil }) else {
            if let p = critical {
                add("fs.write.into.catastrophic", .ask, .none, "it copies files into \(describe(p)), where they can overwrite files no snapshot covers.", dest.text)
            } else {
                writeCheck(dest, truncates: true, whole: whole)
            }
            return
        }
        let dir = resolvedDest.path == "/" ? "" : resolvedDest.path
        for case let name? in names {
            let written = dir + "/" + name
            writeCheck(ShellWord(written), truncates: truncates || replacesExistingFile(written), whole: whole)
        }
    }

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Writing a new file outside the project destroys nothing. Without the real file system (fixtures), assume it exists.
    func replacesOrUnknown(_ path: String?) -> Bool {
        guard context.useFileSystem, let path else { return true }
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Only with the real file system: fixtures describe commands, not a disk.
    func replacesExistingFile(_ path: String) -> Bool {
        guard context.useFileSystem else { return false }
        var st = stat()
        return lstat(path, &st) == 0
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
        let ((flags, long, operands), values) = splitOptionValues(args, valued: name == "rsync" ? Analyzer.rsyncValued : Analyzer.cpMvValued)
        let target = name == "rsync" ? nil : (values["-t"] ?? values["--target-directory"])
        guard operands.count >= (target == nil ? 2 : 1) else { return }
        let sources = target == nil ? Array(operands.dropLast()) : operands
        let dest = target ?? operands.last!
        // `--del` is rsync's alias for --delete-during.
        if name == "rsync", long.contains(where: { $0 == "--del" || $0.hasPrefix("--delete") }) {
            if dest.text.contains(":") && !dest.text.hasPrefix("/") {
                add("fs.rsync.delete.remote", .ask, .none, "it deletes files on a remote machine that are missing locally.", whole)
            } else {
                classifyDeletion([dest], recursive: true, verb: "delete files not present in the source from", whole: whole)
            }
        }
        if long.contains("--remove-source-files") || long.contains("--move") {
            // The *sources* are deleted after copying.
            classifyDeletion(sources, recursive: true, verb: "copy and then delete", whole: whole)
        }
        if sources.first?.text == "/dev/null" || sources.first?.text == "/dev/zero" {
            // cp /dev/null file → truncation
            analyzeTruncateTargets([dest], whole: whole)
        }
        let relative = name == "rsync" ? (flags.contains("R") || long.contains("--relative")) : long.contains("--parents")
        destinationCheck(name, sources, dest, truncates: true, relative: relative, intoDirectory: target != nil, whole: whole)
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
        case .outside where truncates && replacesOrUnknown(resolved?.path):
            add("fs.write.outside", .ask, .recommended, "it overwrites \(target.text) outside the protected project, where no snapshot can restore it.", target.text)
        case .gitInternals: add("git.internals.write", .ask, .recommended, "it overwrites a file inside .git, which snapshots do not cover.", target.text)
        case .insideProject, .projectRoot: add("fs.write.project", .allow, .recommended, "it edits project files (a snapshot is taken first).", target.text)
        default: break
        }
    }

    mutating func analyzeTruncateTargets(_ targets: [ShellWord], whole: String) {
        for t in targets {
            if let r = resolve(t), hookConfigFiles.contains(r.path) {
                add("self.hooks", .ask, .none, "it empties an agent's hook configuration, which switches Airbag's protection off.", t.text)
                continue
            }
            switch classify(resolve(t)) {
            case .catastrophic(let p): add("fs.redirect.catastrophic", .block, .none, "it empties \(describe(p)).", t.text)
            case .airbag: add("self.airbag", .block, .none, "it empties Airbag's own data.", t.text)
            case .outside where replacesOrUnknown(resolve(t)?.path): add("fs.truncate.outside", .ask, .recommended, "it empties \(t.text) outside the protected project.", t.text)
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
        if name == "xattr", flags.isDisjoint(with: ["w", "d", "c"]) { return } // lists or prints attributes
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
        // Global options: git -C dir, -c k=v, --git-dir=…, --work-tree=…. -C and --work-tree move the working tree.
        var a = argv[...]
        var workTree: String?
        var gitCwd = cwd
        while let f = a.first, f.hasPrefix("-") {
            a = a.dropFirst()
            if f == "-C", let v = a.first { gitCwd = resolve(ShellWord(v))?.path; a = a.dropFirst(); continue }
            if f == "--work-tree", let v = a.first { workTree = v; a = a.dropFirst(); continue }
            if f.hasPrefix("--work-tree=") { workTree = String(f.dropFirst("--work-tree=".count)); continue }
            if (f == "-c" || f == "--git-dir" || f == "--namespace"), !a.isEmpty { a = a.dropFirst() }
        }
        var effectiveTree = gitCwd
        if let wt = workTree {
            let saved = cwd
            cwd = gitCwd
            effectiveTree = resolve(ShellWord(wt.hasPrefix("~") ? context.home + wt.dropFirst() : wt))?.path
            cwd = saved
        }
        let treeClass = classify(effectiveTree.map { Resolved(path: $0, contents: false) })
        var treeProtected: Bool = { if case .insideProject = treeClass { return true }; if case .projectRoot = treeClass { return true }; return false }()
        // A folder without its own .git inside a larger repository (a dotfiles repository in the home folder): git acts on
        // the whole repository, most of which lies outside the protected root.
        if treeProtected, workTree == nil, context.useFileSystem, let tree = effectiveTree, let top = gitTopLevel(tree),
           !context.roots.contains(where: { top == $0 || top.hasPrefix($0 + "/") }) {
            treeProtected = false
        }
        guard let sub = a.first else { return }
        let rest = Array(a.dropFirst())
        // Subcommands that never change working-tree files (.git itself is not snapshotted, so no snapshot is needed).
        let noWorktreeChange: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "config", "rev-parse", "ls-files", "blame",
                                             "describe", "shortlog", "grep", "fetch", "tag", "reflog", "help", "version", "--version", "cat-file",
                                             "ls-tree", "for-each-ref", "name-rev", "check-ignore", "add", "commit", "push", "notes", "count-objects",
                                             "fsck", "rev-list", "ls-remote", "whatchanged", "verify-commit", "bisect", "gc", "prune", "update-ref", "init", "clone", "stage"]
        var mutatesWorktree = !noWorktreeChange.contains(sub)
        defer { if mutatesWorktree { mayWrite("git \(sub)") } }
        let has = { (x: String) in rest.contains(x) }
        let hasPrefix = { (x: String) in rest.contains { $0.hasPrefix(x) } }
        switch sub {
        case "reset":
            if !has("--hard") && !has("--merge") && !has("--keep") { mutatesWorktree = false }
            if has("--hard") || has("--merge") || has("--keep") { mayWrite("git \(sub)"); addGit(treeProtected, effectiveTree, "git.reset.hard", .allow, .required, "it discards uncommitted changes (restorable from the snapshot taken first).", whole) }
        case "clean":
            if rest.contains(where: { $0 == "-n" || $0 == "--dry-run" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n")) }) { mutatesWorktree = false; return }
            addGit(treeProtected, effectiveTree, "git.clean", .allow, .required, "it deletes untracked\(rest.contains { $0.contains("x") } ? " and ignored" : "") files (restorable from the snapshot taken first, except dependency and build folders).", whole)
        case "checkout":
            if has("--") || has(".") || has("-f") || has("--force") || has("-p") || has("--theirs") || has("--ours") {
                addGit(treeProtected, effectiveTree, "git.checkout.discard", .allow, .required, "it overwrites working-tree files (restorable from the snapshot taken first).", whole)
            } else { add("git.checkout", .allow, .recommended, "it switches files in the working tree.", whole) }
        case "restore":
            if (has("--staged") || has("-S")) && !has("--worktree") && !has("-W") { mutatesWorktree = false; return }
            do {
                addGit(treeProtected, effectiveTree, "git.checkout.discard", .allow, .required, "it overwrites working-tree files (restorable from the snapshot taken first).", whole)
            }
        case "switch":
            if has("-f") || has("--force") || has("--discard-changes") { addGit(treeProtected, effectiveTree, "git.checkout.discard", .allow, .required, "it discards local changes (restorable from the snapshot taken first).", whole) }
        case "stash":
            if rest.first.map({ ["list", "show"].contains($0) }) == true { return }
            mayWrite("git \(sub)")
            if has("drop") || has("clear") { add("git.stash.drop", .ask, .recommended, "it permanently drops stashed changes, which are not in the working tree and not in snapshots.", whole) }
            else if rest.isEmpty || has("push") || has("save") || has("-u") || has("--include-untracked") || has("--all") {
                addGit(treeProtected, effectiveTree, "git.stash", .allow, .required, "it removes local changes from the working tree into a stash (also covered by the snapshot taken first).", whole)
            }
        case "branch":
            if has("-D") || (has("-d") && has("--force")) || has("--delete") && has("--force") { mayWrite("git \(sub)"); add("git.branch.force-delete", .ask, .recommended, "it force-deletes a branch that may hold unmerged commits.", whole) }
            else if has("-d") || has("--delete") || has("-m") || has("-M") { mayWrite("git \(sub)") }
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
            if has("remove") && (has("--force") || has("-f")) { mayWrite("git \(sub)"); add("git.worktree.remove", .ask, .recommended, "it force-removes a worktree including uncommitted changes.", whole) }
            else if has("remove") || has("prune") { mayWrite("git \(sub)") }
        case "rm":
            if has("--cached") { mutatesWorktree = false; return }
            addGit(treeProtected, effectiveTree, "git.rm", .allow, .required, "it deletes tracked files (restorable from the snapshot taken first).", whole)
        case "submodule":
            if has("deinit") && (has("-f") || has("--force")) { add("git.submodule.deinit", .ask, .recommended, "it force-removes submodule working trees.", whole) }
        default: break
        }
    }

    /// Destructive git subcommands are recoverable only when the working tree is a protected root.
    mutating func addGit(_ treeProtected: Bool, _ tree: String?, _ id: String, _ decision: GuardDecision, _ snapshot: SnapshotNeed, _ reason: String, _ matched: String) {
        if treeProtected { add(id, decision, snapshot, reason, matched); return }
        let whereText = tree.map { describe($0) } ?? "a directory Airbag cannot resolve"
        add("git.outside-root", .ask, .recommended, "it runs a destructive git command (\(id.replacingOccurrences(of: "git.", with: ""))) in \(whereText), outside the protected project, so no snapshot covers it.", matched)
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

    mutating func analyzeInterpreter(_ name: String, _ args: [ShellWord], whole: String, depth: Int = 0) {
        let inline: Set<String> = ["-c", "-e", "-E", "--eval", "-p", "--print", "eval", "-x", "-r"]
        guard let i = args.firstIndex(where: { inline.contains($0.text) }), i + 1 < args.count else { return }
        let code = args[i + 1].text
        let lowered = code.lowercased()
        // Code that runs shell commands: analyse the string literals it passes as commands.
        let runsCommands = ["os.system", "subprocess", "child_process", "execsync", "spawnsync", "exec(", "system(", "popen", "`", "%x(",
                            "deno.command", "deno.run", "bun.spawn", "shell_exec", "passthru", "proc_open", "runtime.exec"].contains { lowered.contains($0) }
        if runsCommands {
            let literals = stringLiterals(code)
            for lit in literals { analyze(lit, depth: depth + 1) }
            if literals.count > 1 { analyze(literals.joined(separator: " "), depth: depth + 1) }
        }
        let deleting = ["rmtree", "os.remove", "os.unlink", "os.rmdir", "removedirs", "unlink(", "unlink ", "rmdir(", "rmdir ", "rmsync",
                        "rmdirsync", "unlinksync", "fs.rm(", ".rm(", "rimraf", "file::delete", "file.delete", ".delete(", "fileutils.rm",
                        "rm_rf", "rm_r", "shutil.move", "send2trash", "truncate(", "deletesync", "fs.promises.rm", "removesync",
                        "deno.remove", "remove_dir_all", "fs::remove", "os.removeall", "dir.delete", "unlink_missing", ".unlink(", "pathlib"]
        guard deleting.contains(where: { lowered.contains($0) }) else { return }
        let classes = extractPaths(code).map { classify(resolve(ShellWord($0))) }
        if let bad = classes.first(where: { if case .catastrophic = $0 { return true }; return false }), case .catastrophic(let p) = bad {
            add("interp.delete.catastrophic", .block, .none, "its inline \(name) code deletes \(describe(p)).", whole)
            return
        }
        if !classes.isEmpty, classes.allSatisfy({ if case .insideProject = $0 { return true }; if case .regenerable = $0 { return true }; if case .temporary = $0 { return true }; return false }) {
            add("interp.delete.project", .allow, .required, "it deletes files from inline \(name) code inside the project (snapshot taken first).", whole)
        } else {
            add("interp.delete", .ask, .recommended, "it deletes files from inline \(name) code that Airbag cannot fully analyze.", whole)
        }
    }

    /// Single- and double-quoted string literals in source code.
    func stringLiterals(_ code: String) -> [String] {
        var out: [String] = []
        let c = Array(code)
        var i = 0
        while i < c.count {
            let q = c[i]
            if q == "'" || q == "\"" || q == "`" {
                var j = i + 1
                var lit = ""
                while j < c.count && c[j] != q {
                    if c[j] == "\\", j + 1 < c.count { lit.append(c[j + 1]); j += 2; continue }
                    lit.append(c[j]); j += 1
                }
                if !lit.trimmingCharacters(in: .whitespaces).isEmpty { out.append(lit) }
                i = j + 1
                continue
            }
            i += 1
        }
        return out
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
        if let runIdx = argv.firstIndex(where: { $0 == "run" || $0 == "exec" }) {
            analyzeContainerRun(Array(argv[(runIdx + 1)...]), whole: whole)
        }
    }

    /// `docker run [opts] image cmd…`: deleting inside a container through a host mount bypasses host-side checks.
    mutating func analyzeContainerRun(_ argv: [String], whole: String) {
        let valueOpts: Set<String> = ["-v", "--volume", "--mount", "-e", "--env", "-w", "--workdir", "--name", "-p", "--publish", "--entrypoint",
                                      "--network", "--net", "-u", "--user", "--env-file", "-l", "--label", "--platform", "--hostname", "-h",
                                      "--add-host", "--cpus", "-m", "--memory", "--restart", "--pull", "--gpus", "--device", "--cap-add", "--cap-drop"]
        var mounts: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { i += 1; break }
            if a.hasPrefix("-") {
                if a == "-v" || a == "--volume", i + 1 < argv.count { mounts.append(argv[i + 1]) }
                else if a.hasPrefix("--volume=") { mounts.append(String(a.dropFirst(9))) }
                else if a == "--mount", i + 1 < argv.count, let src = argv[i + 1].split(separator: ",").first(where: { $0.hasPrefix("source=") || $0.hasPrefix("src=") }) {
                    mounts.append(String(src.split(separator: "=", maxSplits: 1).last ?? "") + ":/m")
                }
                i += valueOpts.contains(a) ? 2 : 1
                continue
            }
            break // image
        }
        let command = argv.count > i + 1 ? Array(argv[(i + 1)...]) : []
        guard !mounts.isEmpty, !command.isEmpty else { return }
        let text = command.joined(separator: " ")
        let destructive = text.range(of: #"(^|[\s;&|'"])(rm|shred|truncate|dd|mv|unlink|rmdir)\s|-delete\b|(^|\s)>\s?\S|rimraf|rmtree"#, options: .regularExpression) != nil
        guard destructive else { return }
        for m in mounts {
            let parts = m.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0].hasPrefix("/") || parts[0].hasPrefix("~") || parts[0].hasPrefix(".") else { continue } // named volume
            if parts.count >= 3, parts[2].split(separator: ",").contains("ro") { continue }
            let host = parts[0].hasPrefix("~") ? context.home + parts[0].dropFirst() : parts[0]
            switch classify(resolve(ShellWord(host))) {
            case .insideProject, .regenerable, .temporary:
                add("docker.mount.delete.project", .allow, .required, "it deletes files in a project folder mounted into a container (snapshot taken first).", whole)
            default:
                add("docker.mount.delete", .ask, .recommended, "it mounts \(parts[0]) into a container and deletes files there, bypassing host-side checks.", whole)
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
        mayWrite(name)
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
        mayWrite("ssh")
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
