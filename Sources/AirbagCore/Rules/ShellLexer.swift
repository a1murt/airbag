import Foundation

/// One shell word after quote removal and expansion of the variables we know.
public struct ShellWord: Sendable, Equatable {
    public var text: String
    /// Contains an expansion we could not resolve (`$VAR`, `$(...)`, backticks, arithmetic).
    public var opaque: Bool
    /// Contains unquoted glob characters (`*`, `?`, `[`).
    public var hasGlob: Bool
    /// Some part of the word was quoted (so keywords are not special).
    public var quoted: Bool
    /// `NAME` when the word starts with an unquoted `NAME=` (a variable assignment in command position).
    public var assignmentName: String?
    /// The body of a here-document when this word is its delimiter (`<<EOF`).
    public var heredoc: String?

    public init(_ text: String, opaque: Bool = false, hasGlob: Bool = false, quoted: Bool = false, assignmentName: String? = nil,
                heredoc: String? = nil) {
        self.text = text; self.opaque = opaque; self.hasGlob = hasGlob; self.quoted = quoted; self.assignmentName = assignmentName
        self.heredoc = heredoc
    }
}

public struct ShellRedirect: Sendable, Equatable {
    public let op: String          // ">", ">>", ">|", "<", "&>", "2>", "<<", "<<<", ...
    public let target: ShellWord
}

public enum ShellConnector: String, Sendable { case start, sequence, and, or, pipe, background }

public struct ShellCommand: Sendable, Equatable {
    public var words: [ShellWord] = []
    public var assignments: [(String, ShellWord)] = []
    public var redirects: [ShellRedirect] = []
    /// How this command is joined to the previous one.
    public var connector: ShellConnector = .start
    /// Nesting depth: 0 top level, > 0 inside a substitution or `sh -c` string.
    public var depth = 0

    public var argv: [String] { words.map(\.text) }

    public static func == (a: ShellCommand, b: ShellCommand) -> Bool {
        a.words == b.words && a.redirects == b.redirects && a.connector == b.connector && a.depth == b.depth
            && a.assignments.map(\.0) == b.assignments.map(\.0) && a.assignments.map(\.1) == b.assignments.map(\.1)
    }
}

/// A conservative POSIX-ish shell tokenizer. It never executes anything; anything it cannot resolve is marked
/// opaque so the analyzer can treat it as unknown.
public struct ShellLexer {
    public var environment: [String: String]
    public var home: String
    /// Commands found inside `$(...)`, backticks and `<(...)`; they run too, so the analyzer inspects them.
    public private(set) var substitutions: [String] = []
    /// A quote, substitution or backtick was never closed: the shell would refuse the line, so if it runs anyway the
    /// lexer read it differently from the shell and its analysis cannot be trusted.
    public private(set) var unterminated = false

    public init(environment: [String: String], home: String) {
        self.environment = environment
        self.home = home
    }

    enum Token: Equatable {
        case word(ShellWord)
        case op(String)
    }

    // MARK: tokenizer

    mutating func tokenize(_ input: String) -> [Token] {
        let c = Array(input)
        var i = 0
        var tokens: [Token] = []
        var pendingHeredocs: [(delimiter: String, stripTabs: Bool, quoted: Bool, token: Int)] = []
        // Words of the current simple command, for `NAME=value; … $NAME` (redirect targets are not part of it).
        var segment: [ShellWord] = []
        var afterRedirect = false

        func peek(_ k: Int = 0) -> Character? { i + k < c.count ? c[i + k] : nil }

        while i < c.count {
            let ch = c[i]
            if ch == " " || ch == "\t" { i += 1; continue }
            if ch == "\\" && peek(1) == "\n" { i += 2; continue }
            if ch == "\n" || ch == "\r" {
                applyAssignments(segment)
                segment.removeAll()
                tokens.append(.op(";"))
                i += 1
                // Here-document bodies are data for the command (kept on the delimiter word for shells and
                // interpreters that run them); with an unquoted delimiter their substitutions run too.
                for h in pendingHeredocs {
                    var body: [String] = []
                    while i < c.count {
                        var j = i
                        while j < c.count && c[j] != "\n" { j += 1 }
                        var line = String(c[i..<j])
                        if h.stripTabs { line = String(line.drop(while: { $0 == "\t" })) }
                        i = min(c.count, j + 1)
                        if line == h.delimiter { break }
                        body.append(line)
                    }
                    let text = body.joined(separator: "\n")
                    tokens[h.token] = .word(ShellWord(h.delimiter, quoted: true, heredoc: text))
                    if !h.quoted { scanExpansions(text) }
                }
                pendingHeredocs.removeAll()
                continue
            }
            if ch == "#" { // comment to end of line
                while i < c.count && c[i] != "\n" { i += 1 }
                continue
            }
            // Operators
            if let op = matchOperator(c, i) {
                i += op.count
                if op == "<<" || op == "<<-" {
                    // delimiter word follows
                    while i < c.count && (c[i] == " " || c[i] == "\t") { i += 1 }
                    let (word, next, _) = readWord(c, i)
                    i = next
                    tokens.append(.op(op))
                    pendingHeredocs.append((word.text, op == "<<-", word.quoted, tokens.count))
                    tokens.append(.word(ShellWord(word.text, quoted: true)))
                    continue
                }
                tokens.append(.op(op))
                if ShellLexer.redirectOps.contains(op) {
                    afterRedirect = true
                } else {
                    if [";", "&&", "||"].contains(op) { applyAssignments(segment) } // `|`, `&` and `( )` run in subshells
                    segment.removeAll()
                }
                continue
            }
            // fd-prefixed redirection such as 2> or 2>>
            if ch.isNumber {
                var j = i
                while j < c.count && c[j].isNumber { j += 1 }
                if j < c.count, c[j] == ">" || c[j] == "<", let op = matchOperator(c, j) {
                    tokens.append(.op(String(c[i..<j]) + op))
                    i = j + op.count
                    afterRedirect = true
                    continue
                }
            }
            // Process substitution <( ... ) / >( ... )
            if (ch == "<" || ch == ">") && peek(1) == "(" {
                let (inner, next) = readBalanced(c, i + 2, open: "(", close: ")")
                substitutions.append(inner)
                i = next
                tokens.append(.word(ShellWord("<(…)", opaque: true)))
                continue
            }
            let (word, next, marks) = readWord(c, i)
            i = next
            let op: String? = { if afterRedirect, case .op(let o)? = tokens.last { return o }; return nil }()
            let words = op == "<<<" ? [word] : ShellLexer.expandBraces(word, marks) // a here-string is not brace-expanded
            if afterRedirect {
                // `> {a,b}`: zsh writes to both files (bash refuses the line), so each is a redirect target.
                for (k, w) in words.enumerated() {
                    if k > 0, let op { tokens.append(.op(op)) }
                    tokens.append(.word(w))
                }
                afterRedirect = false
            } else {
                for w in words { tokens.append(.word(w)); segment.append(w) }
            }
        }
        return tokens
    }

    /// `NAME=value` as a command of its own (or after `export`) sets the variable for the rest of the line, as the shell
    /// does; a value Airbag cannot resolve makes later uses unresolved too.
    mutating func applyAssignments(_ words: [ShellWord]) {
        var ws = words[...]
        if let f = ws.first, !f.quoted, ["export", "local", "readonly", "declare", "typeset"].contains(f.text) { ws = ws.dropFirst() }
        guard !ws.isEmpty, ws.allSatisfy({ $0.assignmentName != nil }) else { return }
        for w in ws {
            guard let name = w.assignmentName else { continue }
            if w.opaque || w.hasGlob { environment.removeValue(forKey: name); shadowed.insert(name) }
            else { environment[name] = String(w.text.dropFirst(name.count + 1)); shadowed.remove(name) }
        }
    }

    func matchOperator(_ c: [Character], _ i: Int) -> String? {
        // zsh: `>!`, `>>!`, `&>!`, `>&!` clobber like `>|`; `>>&` and `&>>` append stdout and stderr.
        let ops = ["&>>!", ">>&!", "&>>", ">>&", "&>!", ">&!", ">>!", "<<<", "<<-", "&&", "||", ";;", "|&", ">>", ">|", ">!", "<<",
                   "<>", ">&", "<&", "&>", ";", "&", "|", "(", ")", "<", ">"]
        for op in ops {
            let chars = Array(op)
            if i + chars.count <= c.count && Array(c[i..<(i + chars.count)]) == chars {
                if op == "<" || op == ">", i + 1 < c.count, c[i + 1] == "(" { return nil } // process substitution
                return op
            }
        }
        return nil
    }

    func isWordBreak(_ ch: Character) -> Bool {
        " \t\n\r;&|()<>".contains(ch)
    }

    /// Reads one word starting at `i`, applying quoting rules and expansions. `marks` are the unquoted `{`, `,`, `}` and
    /// glob characters of the result, by position, for brace expansion.
    mutating func readWord(_ c: [Character], _ start: Int) -> (ShellWord, Int, marks: [Int: Character]) {
        var i = start
        var out = ""
        var opaque = false, glob = false, quoted = false
        var assignmentName: String?
        var marks: [Int: Character] = [:]
        let atStart = { (pos: Int) in pos == start }
        while i < c.count {
            let ch = c[i]
            if isWordBreak(ch) { break }
            switch ch {
            case "\\":
                if i + 1 < c.count {
                    if c[i + 1] != "\n" { out.append(c[i + 1]) }
                    quoted = true
                    i += 2
                } else { i += 1 }
            case "'":
                quoted = true
                i += 1
                while i < c.count && c[i] != "'" { out.append(c[i]); i += 1 }
                if i >= c.count { unterminated = true }
                i += 1
            case "\"":
                quoted = true
                i += 1
                while i < c.count && c[i] != "\"" {
                    if c[i] == "\\", i + 1 < c.count, "$`\"\\\n".contains(c[i + 1]) {
                        if c[i + 1] != "\n" { out.append(c[i + 1]) }
                        i += 2
                    } else if c[i] == "$" {
                        let (text, op, next) = readDollar(c, i)
                        out += text; opaque = opaque || op; i = next
                    } else if c[i] == "`" {
                        let (inner, next) = readUntil(c, i + 1, "`")
                        substitutions.append(inner); opaque = true; out += "`…`"; i = next
                    } else {
                        out.append(c[i]); i += 1
                    }
                }
                if i >= c.count { unterminated = true }
                i += 1
            case "$":
                if i + 1 < c.count, c[i + 1] == "'" {
                    // ANSI-C quoting
                    quoted = true
                    i += 2
                    while i < c.count && c[i] != "'" {
                        if c[i] == "\\", i + 1 < c.count {
                            let (decoded, used) = ShellLexer.ansiEscape(c, i + 1)
                            out += decoded
                            i += 1 + used
                        } else { out.append(c[i]); i += 1 }
                    }
                    if i >= c.count { unterminated = true }
                    i += 1
                } else {
                    let (text, op, next) = readDollar(c, i)
                    out += text; opaque = opaque || op; i = next
                }
            case "`":
                let (inner, next) = readUntil(c, i + 1, "`")
                if inner.trimmingCharacters(in: .whitespaces) == "pwd", let pwd = environment["PWD"] { out += pwd; i = next; continue }
                substitutions.append(inner); opaque = true; out += "`…`"; i = next
            case "~" where atStart(i) || (assignmentName != nil && !quoted && (out.hasSuffix("=") || out.hasSuffix(":"))):
                // Also after `NAME=` and `:` in an assignment (`D=~/x`, `PATH=~/bin:~/y`), as the shell expands it.
                // Tilde expansion: ~ or ~/... (or ~user)
                var j = i + 1
                var user = ""
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "-" || c[j] == "." { user.append(c[j]); j += 1 }
                let terminated = j >= c.count || isWordBreak(c[j]) || c[j] == "/" || c[j] == ":" || c[j] == "\\"
                if !terminated { out.append("~"); i += 1; break }
                out += user.isEmpty ? home : "/Users/" + user
                i = j
            case "*", "?", "[":
                glob = true
                marks[out.count] = ch
                out.append(ch); i += 1
            case "=" where assignmentName == nil && !quoted && !opaque && !out.isEmpty
                && out.first.map({ $0.isLetter || $0 == "_" }) == true
                && out.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }):
                assignmentName = out
                out.append(ch); i += 1
            case "{", ",", "}":
                marks[out.count] = ch
                out.append(ch); i += 1
            default:
                out.append(ch); i += 1
            }
        }
        return (ShellWord(out, opaque: opaque, hasGlob: glob, quoted: quoted, assignmentName: assignmentName), i, marks)
    }

    /// Brace expansion, which bash and zsh apply to unquoted braces before anything else: `x/{a,b}` is `x/a x/b`, `{1..3}`
    /// is `1 2 3` (also `{01..10..2}`, `{a..e}`). A brace without a comma or a sequence (`{}`, `@{u}`) stays as it is; an
    /// assignment is not expanded. More than 256 words make the word opaque.
    static func expandBraces(_ word: ShellWord, _ marks: [Int: Character]) -> [ShellWord] {
        guard word.assignmentName == nil, marks.values.contains("{"), marks.values.contains("}") else { return [word] }
        enum Part: Equatable { case char(Character), open, comma, close, glob(Character) }
        let parts: [Part] = word.text.enumerated().map { k, ch in
            switch marks[k] {
            case "{"?: return .open
            case ","?: return .comma
            case "}"?: return .close
            case let g?: return .glob(g)
            case nil: return .char(ch)
            }
        }
        let limit = 256
        var results: [[Part]] = []
        var overflow = false
        /// The words of a sequence body (`1..5`, `a..e`, with an optional `..step`); nil when it is not one.
        func sequence(_ body: [Part]) -> [String]? {
            guard body.allSatisfy({ if case .char = $0 { return true }; return false }) else { return nil }
            let text = String(body.map { if case .char(let ch) = $0 { return ch }; return " " })
            let ends = text.components(separatedBy: "..")
            guard ends.count == 2 || ends.count == 3 else { return nil }
            let step = ends.count == 3 ? Int(ends[2]).map(abs) : 1
            guard let step, step > 0 else { return nil }
            if let a = Int(ends[0]), let b = Int(ends[1]) {
                guard abs(b - a) / step < limit else { overflow = true; return [] }
                let width = ends[0...1].contains { $0.hasPrefix("0") && $0.count > 1 || $0.hasPrefix("-0") } ? max(ends[0].count, ends[1].count) : 0
                return stride(from: a, through: b, by: a <= b ? step : -step).map { n in
                    let digits = String(abs(n))
                    let padded = String(repeating: "0", count: max(0, width - digits.count - (n < 0 ? 1 : 0))) + digits
                    return (n < 0 ? "-" : "") + padded
                }
            }
            guard let a = ends[0].unicodeScalars.first, let b = ends[1].unicodeScalars.first, ends[0].count == 1, ends[1].count == 1,
                  a.isASCII, b.isASCII, CharacterSet.letters.contains(a), CharacterSet.letters.contains(b) else { return nil }
            return stride(from: Int(a.value), through: Int(b.value), by: a.value <= b.value ? step : -step)
                .compactMap { Unicode.Scalar(UInt32($0)).map { String(Character($0)) } }
        }
        func expand(_ p: [Part]) {
            guard !overflow else { return }
            var i = 0
            while i < p.count {
                if p[i] == .open {
                    var depth = 0, commas: [Int] = [], close: Int?
                    scan: for k in i..<p.count {
                        switch p[k] {
                        case .open: depth += 1
                        case .close:
                            depth -= 1
                            if depth == 0 { close = k; break scan }
                        case .comma where depth == 1: commas.append(k)
                        default: break
                        }
                    }
                    if let close {
                        var alternatives: [[Part]]?
                        if !commas.isEmpty {
                            var start = i + 1
                            alternatives = (commas + [close]).map { c in defer { start = c + 1 }; return Array(p[start..<c]) }
                        } else if let seq = sequence(Array(p[(i + 1)..<close])) {
                            alternatives = seq.map { $0.map { Part.char($0) } }
                        }
                        if let alternatives {
                            for a in alternatives { expand(Array(p[..<i]) + a + Array(p[(close + 1)...])) }
                            return
                        }
                    }
                }
                i += 1
            }
            if results.count >= limit { overflow = true; return }
            results.append(p)
        }
        expand(parts)
        if overflow { var w = word; w.opaque = true; return [w] }
        return results.map { p in
            var w = word
            w.text = String(p.map { part -> Character in
                switch part {
                case .char(let ch), .glob(let ch): return ch
                case .open: return "{"
                case .comma: return ","
                case .close: return "}"
                }
            })
            w.hasGlob = p.contains { if case .glob = $0 { return true }; return false }
            return w
        }
    }

    /// Handles `$NAME`, `${...}`, `$(...)`, `$((...))` and special parameters at `c[i] == "$"`.
    mutating func readDollar(_ c: [Character], _ i: Int) -> (String, Bool, Int) {
        guard i + 1 < c.count else { return ("$", false, i + 1) }
        let n = c[i + 1]
        if n == "(" {
            if i + 2 < c.count, c[i + 2] == "(" {
                let (_, next) = readBalanced(c, i + 3, open: "(", close: ")")
                let end = next < c.count && c[next] == ")" ? next + 1 : next
                return ("$((…))", true, end)
            }
            let (inner, next) = readBalanced(c, i + 2, open: "(", close: ")")
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            if (trimmed == "pwd" || trimmed == "pwd -P" || trimmed == "pwd -L"), let pwd = environment["PWD"] { return (pwd, false, next) }
            // `$(brew shellenv)` keeps its text, so `eval` can tell environment setup from arbitrary output.
            if Analyzer.isEnvironmentSetup(trimmed), !trimmed.contains("$("), !trimmed.contains("`") {
                substitutions.append(inner)
                return ("$(\(trimmed))", true, next)
            }
            // `$(mktemp -d)`: a fresh path in the temporary directory, whatever its random name.
            if trimmed == "mktemp" || trimmed.hasPrefix("mktemp "), !trimmed.contains("/"), !trimmed.contains("$") {
                var tmp = environment["TMPDIR"] ?? "/tmp"
                while tmp.count > 1 && tmp.hasSuffix("/") { tmp.removeLast() }
                return (tmp + "/airbag-mktemp", false, next)
            }
            substitutions.append(inner)
            return ("$(…)", true, next)
        }
        if n == "{" {
            let (inner, next) = readBalanced(c, i + 2, open: "{", close: "}")
            let name = String(inner.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if name.count == inner.count, let v = lookup(name) { return (v, false, next) }
            return ("${\(inner)}", true, next)
        }
        if n.isLetter || n == "_" {
            var j = i + 1
            var name = ""
            while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { name.append(c[j]); j += 1 }
            if let v = lookup(name) { return (v, false, j) }
            return ("$" + name, true, j)
        }
        if n.isNumber || "@*#?$!-".contains(n) { return ("$" + String(n), true, i + 2) }
        return ("$", false, i + 1)
    }

    /// Decodes one ANSI-C escape (`$'…'`) starting after the backslash; returns the text and characters consumed.
    static func ansiEscape(_ c: [Character], _ i: Int) -> (String, Int) {
        let e = c[i]
        func hexValue(_ start: Int, max: Int) -> (UInt32, Int) {
            var v: UInt32 = 0, n = 0
            while n < max, start + n < c.count, let d = c[start + n].hexDigitValue { v = v * 16 + UInt32(d); n += 1 }
            return (v, n)
        }
        func scalar(_ v: UInt32) -> String { Unicode.Scalar(v).map { String(Character($0)) } ?? "" }
        switch e {
        case "n": return ("\n", 1)
        case "t": return ("\t", 1)
        case "r": return ("\r", 1)
        case "a": return ("\u{07}", 1)
        case "b": return ("\u{08}", 1)
        case "e", "E": return ("\u{1B}", 1)
        case "f": return ("\u{0C}", 1)
        case "v": return ("\u{0B}", 1)
        case "\\": return ("\\", 1)
        case "'": return ("'", 1)
        case "\"": return ("\"", 1)
        case "?": return ("?", 1)
        case "x":
            let (v, n) = hexValue(i + 1, max: 2)
            return n == 0 ? ("\\x", 1) : (scalar(v), 1 + n)
        case "u", "U":
            let (v, n) = hexValue(i + 1, max: e == "u" ? 4 : 8)
            return n == 0 ? ("\\" + String(e), 1) : (scalar(v), 1 + n)
        case "c":
            guard i + 1 < c.count, let a = c[i + 1].asciiValue else { return ("", 1) }
            return (scalar(UInt32(a & 0x1F)), 2)
        default:
            if let first = e.wholeNumberValue, first < 8 {
                var v = UInt32(first), n = 1
                while n < 3, i + n < c.count, let d = c[i + n].wholeNumberValue, d < 8 { v = v * 8 + UInt32(d); n += 1 }
                return (scalar(v), n)
            }
            return ("\\" + String(e), 1)
        }
    }

    /// Variables reassigned on this line to something Airbag cannot resolve.
    var shadowed: Set<String> = []

    func lookup(_ name: String) -> String? {
        if shadowed.contains(name) { return nil }
        if name == "HOME" { return environment["HOME"] ?? home }
        return environment[name]
    }

    mutating func readUntil(_ c: [Character], _ start: Int, _ end: Character) -> (String, Int) {
        var i = start
        var s = ""
        while i < c.count && c[i] != end {
            if c[i] == "\\", i + 1 < c.count { s.append(c[i + 1]); i += 2; continue }
            s.append(c[i]); i += 1
        }
        if i >= c.count { unterminated = true }
        return (s, min(c.count, i + 1))
    }

    /// `$(...)`, `${...}` and backticks in a here-document with an unquoted delimiter are expanded, so they run.
    mutating func scanExpansions(_ text: String) {
        let c = Array(text)
        var i = 0
        while i < c.count {
            switch c[i] {
            case "\\": i += 2
            case "$": let (_, _, next) = readDollar(c, i); i = max(next, i + 1)
            case "`": let (inner, next) = readUntil(c, i + 1, "`"); substitutions.append(inner); i = next
            default: i += 1
            }
        }
    }

    /// Reads up to the matching close bracket, honouring nesting, quotes and here-documents. Returns the inner text.
    mutating func readBalanced(_ c: [Character], _ start: Int, open: Character, close: Character) -> (String, Int) {
        var i = start
        var depth = 1
        var s = ""
        var heredocs: [(delimiter: String, stripTabs: Bool)] = []
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count { s.append(ch); s.append(c[i + 1]); i += 2; continue }
            // `$(cat <<'EOF' … EOF)`: the body is copied verbatim, so an apostrophe in a commit message is not a quote.
            if ch == "\n", !heredocs.isEmpty {
                s.append(ch); i += 1
                for h in heredocs {
                    while i < c.count {
                        var j = i
                        while j < c.count && c[j] != "\n" { j += 1 }
                        let line = String(c[i..<j])
                        s += line
                        if j < c.count { s.append("\n") }
                        i = min(c.count, j + 1)
                        if (h.stripTabs ? String(line.drop(while: { $0 == "\t" })) : line) == h.delimiter { break }
                    }
                }
                heredocs.removeAll()
                continue
            }
            if ch == "<", i + 1 < c.count, c[i + 1] == "<", !(i + 2 < c.count && c[i + 2] == "<") {
                let stripTabs = i + 2 < c.count && c[i + 2] == "-"
                var j = i + (stripTabs ? 3 : 2)
                s += String(c[i..<j])
                while j < c.count && (c[j] == " " || c[j] == "\t") { s.append(c[j]); j += 1 }
                var delimiter = ""
                while j < c.count, !" \t\n;|&()<>".contains(c[j]) {
                    if !"'\"\\".contains(c[j]) { delimiter.append(c[j]) }
                    s.append(c[j]); j += 1
                }
                if !delimiter.isEmpty { heredocs.append((delimiter, stripTabs)) }
                i = j
                continue
            }
            if ch == "'" {
                s.append(ch); i += 1
                while i < c.count && c[i] != "'" { s.append(c[i]); i += 1 }
                if i < c.count { s.append(c[i]); i += 1 }
                continue
            }
            if ch == "\"" {
                s.append(ch); i += 1
                while i < c.count && c[i] != "\"" {
                    if c[i] == "\\", i + 1 < c.count { s.append(c[i]); s.append(c[i + 1]); i += 2; continue }
                    s.append(c[i]); i += 1
                }
                if i < c.count { s.append(c[i]); i += 1 }
                continue
            }
            if ch == open { depth += 1 }
            if ch == close {
                depth -= 1
                if depth == 0 { return (s, i + 1) }
            }
            s.append(ch)
            i += 1
        }
        unterminated = true
        return (s, i)
    }

    // MARK: grouping

    static let controlKeywords: Set<String> = ["if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "{", "}", "in", "esac", "select"]
    static let redirectOps: Set<String> = [">", ">>", ">|", "<", "<>", "&>", "&>>", ">&", "<&", "<<", "<<-", "<<<",
                                           ">!", ">>!", "&>!", ">&!", "&>>!", ">>&", ">>&!"]

    /// Splits a command line into simple commands.
    public mutating func parse(_ input: String, depth: Int = 0) -> [ShellCommand] {
        let tokens = tokenize(input)
        var commands: [ShellCommand] = []
        var cur = ShellCommand()
        cur.depth = depth
        var nextConnector: ShellConnector = .start
        var pendingRedirect: String?
        // Inside a `case` pattern (after `in` or `;;`, up to its `)`): `a|b` there is alternation, not a pipeline, and
        // the patterns are not commands.
        var casePattern = false

        /// Ends the current command; true when it was a `case WORD in …` header.
        @discardableResult
        func flush() -> Bool {
            // Drop leading control keywords (`if`, `then`, `do`, `{`, ...).
            while let first = cur.words.first, !first.quoted, ShellLexer.controlKeywords.contains(first.text) { cur.words.removeFirst() }
            let caseHeader = cur.words.first.map { !$0.quoted && $0.text == "case" } ?? false
            if let first = cur.words.first, !first.quoted, ["for", "case", "function"].contains(first.text) { cur.words.removeAll() }
            if !cur.words.isEmpty || !cur.redirects.isEmpty || !cur.assignments.isEmpty {
                cur.connector = nextConnector
                commands.append(cur)
            }
            cur = ShellCommand()
            cur.depth = depth
            return caseHeader
        }

        for t in tokens {
            switch t {
            case .op(let op):
                if casePattern {
                    if op == ")" { casePattern = false; nextConnector = .sequence }
                    continue // `|` between alternatives, an optional `(`, newlines before the pattern
                }
                if ShellLexer.redirectOps.contains(op) || op.first?.isNumber == true {
                    pendingRedirect = op
                    continue
                }
                // `case x in a|b)`: the header's last word is the first pattern unless `)` closes it right away.
                if flush() && op != ")" { casePattern = true; continue }
                if op == ";;" { casePattern = true }
                switch op {
                case "&&": nextConnector = .and
                case "||": nextConnector = .or
                case "|", "|&": nextConnector = .pipe
                case "&": nextConnector = .background
                default: nextConnector = .sequence
                }
            case .word(let w):
                if casePattern {
                    if !w.quoted && w.text == "esac" { casePattern = false }
                    continue
                }
                if let r = pendingRedirect {
                    cur.redirects.append(ShellRedirect(op: r, target: w))
                    pendingRedirect = nil
                    continue
                }
                // Also right after `do`, `then`, `{`…: `for f in *; do n=$(wc -l < $f); …` assigns, it runs nothing.
                if cur.words.allSatisfy({ !$0.quoted && ShellLexer.controlKeywords.contains($0.text) }), let name = w.assignmentName {
                    var value = w
                    value.text = String(w.text.dropFirst(name.count + 1))
                    value.assignmentName = nil
                    cur.assignments.append((name, value))
                    continue
                }
                cur.words.append(w)
            }
        }
        flush()
        if casePattern { unterminated = true } // a pattern never closed: the shell would refuse the line
        return commands
    }
}
