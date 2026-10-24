import Foundation
import Testing
@testable import AirbagCore

struct RuleCase: Decodable, CustomTestStringConvertible, Sendable {
    struct Expect: Decodable, Sendable { let decision: String; let snapshot: String? }
    let cmd: String
    let expect: Expect
    let rule: String?
    let cwd: String?
    let why: String?
    var testDescription: String { cmd.replacingOccurrences(of: "\n", with: "⏎") }
}

struct RuleFixture: Decodable {
    struct Context: Decodable { let cwd: String; let home: String; let roots: [String]; let airbagHome: String; let environment: [String: String] }
    let version: Int
    let context: Context
    let cases: [RuleCase]

    struct Extra: Decodable { let cases: [RuleCase] }

    /// rules.json plus the red-team cases (docs/research/07-breaker-redteam.md) and the read-only and security-status
    /// cases (ADR-032), which share its context.
    static let shared: RuleFixture = {
        let url = Bundle.module.url(forResource: "rules", withExtension: "json", subdirectory: "Fixtures")!
        let base = try! JSONDecoder().decode(RuleFixture.self, from: Data(contentsOf: url))
        let extra = ["rules-redteam", "rules-readonly"].flatMap { name -> [RuleCase] in
            let extraURL = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
            return try! JSONDecoder().decode(Extra.self, from: Data(contentsOf: extraURL)).cases
        }
        return RuleFixture(version: base.version, context: base.context, cases: base.cases + extra)
    }()
}

@Suite struct RuleFixtureTests {
    @Test(arguments: RuleFixture.shared.cases)
    func fixtureCase(_ c: RuleCase) {
        let ctx = RuleFixture.shared.context
        let context = GuardContext(cwd: c.cwd ?? ctx.cwd, home: ctx.home, roots: ctx.roots, environment: ctx.environment,
                                   airbagHome: ctx.airbagHome, useFileSystem: false)
        let v = RuleEngine().evaluate(c.cmd, context: context)
        let summary = "decision=\(v.decision.rawValue) snapshot=\(v.snapshot.rawValue) findings=\(v.findings.map { "\($0.ruleId):\($0.decision.rawValue):\($0.matched)" })"
        #expect(v.decision.rawValue == c.expect.decision, "\(summary)")
        if let s = c.expect.snapshot { #expect(v.snapshot.rawValue == s, "\(summary)") }
        if let r = c.rule { #expect(v.findings.contains { $0.ruleId == r }, "expected rule \(r); \(summary)") }
    }

    @Test func fixtureIsLargeEnough() { #expect(RuleFixture.shared.cases.count >= 150) }

    @Test func evaluationIsFast() {
        let ctx = RuleFixture.shared.context
        let context = GuardContext(cwd: ctx.cwd, home: ctx.home, roots: ctx.roots, environment: ctx.environment, airbagHome: ctx.airbagHome, useFileSystem: false)
        let engine = RuleEngine()
        let start = Clock.monotonicNs()
        var n = 0
        for _ in 0..<5 { for c in RuleFixture.shared.cases { _ = engine.evaluate(c.cmd, context: context); n += 1 } }
        let perCommandUs = Double(Clock.monotonicNs() - start) / Double(n) / 1000
        #expect(perCommandUs < 1000, "\(perCommandUs) µs per command")
    }

    @Test func turningARuleOffNeverLiftsABlock() {
        let ctx = RuleFixture.shared.context
        var context = GuardContext(cwd: ctx.cwd, home: ctx.home, roots: ctx.roots, airbagHome: ctx.airbagHome, useFileSystem: false)
        let engine = RuleEngine()
        let block = engine.evaluate("rm -rf ~", context: context)
        let ask = engine.evaluate("git push --force origin main", context: context)
        #expect(block.decision == .block && ask.decision == .ask)
        context.disabledRules = Set(block.findings.map(\.ruleId) + ask.findings.map(\.ruleId))
        #expect(engine.evaluate("rm -rf ~", context: context).decision == .block)
        #expect(engine.evaluate("git push --force origin main", context: context).decision == .allow)
    }

    @Test func findingsThatNeedASnapshotNameTheRootTheyTarget() {
        let context = GuardContext(cwd: "/p/sub", home: "/Users/u", roots: ["/p/sub", "/p"], useFileSystem: false)
        let engine = RuleEngine()
        let rm = engine.evaluate("rm notes.md ../important.txt", context: context).findings.filter { $0.ruleId == "fs.rm.project" }
        #expect(rm.map(\.roots) == [["/p/sub"], ["/p"]])
        // The same text in two projects is one finding that needs both snapshots.
        let siblings = GuardContext(cwd: "/p/a", home: "/Users/u", roots: ["/p/a", "/p/b"], useFileSystem: false)
        let clean = engine.evaluate("git clean -fd && cd ../b && git clean -fd", context: siblings).findings.filter { $0.ruleId == "git.clean" }
        #expect(clean.map(\.roots) == [["/p/a", "/p/b"]])
        // A dependency folder is in no root's snapshots.
        let deps = engine.evaluate("python3 -c \"import shutil; shutil.rmtree('node_modules')\"", context: context)
        #expect(deps.findings.map(\.ruleId) == ["interp.delete.project"] && deps.findings[0].roots.isEmpty)
    }

    @Test func agentMessageNamesTheRiskAndTheWayOut() {
        let ctx = RuleFixture.shared.context
        let context = GuardContext(cwd: ctx.cwd, home: ctx.home, roots: ctx.roots, airbagHome: ctx.airbagHome, useFileSystem: false)
        let v = RuleEngine().evaluate("rm -rf ~", context: context)
        let msg = v.agentMessage(command: "rm -rf ~")
        #expect(msg.contains("Airbag blocked"))
        #expect(msg.contains("home directory"))
    }
}

@Suite struct ShellLexerTests {
    func parse(_ s: String) -> [[String]] {
        var l = ShellLexer(environment: ["PWD": "/p"], home: "/Users/u")
        return l.parse(s).map(\.argv)
    }

    @Test func quotingAndOperators() {
        #expect(parse("a 'b c' \"d $HOME\" e\\ f") == [["a", "b c", "d /Users/u", "e f"]])
        #expect(parse("a && b || c; d | e & f") == [["a"], ["b"], ["c"], ["d"], ["e"], ["f"]])
        #expect(parse("echo $'x\\ty'") == [["echo", "x\ty"]])
        #expect(parse("FOO=1 BAR='a b' cmd x") == [["cmd", "x"]])
        #expect(parse("cat <<EOF\nrm -rf /\nEOF\nls") == [["cat"], ["ls"]])
        #expect(parse("ls 2>/dev/null >out.txt") == [["ls"]])
        #expect(parse("echo `pwd` $(pwd)") == [["echo", "/p", "/p"]])
    }

    @Test func assignmentsAfterKeywordsAndCasePatterns() {
        #expect(parse("for f in a b; do X=1 ls; done") == [["ls"]])
        #expect(parse("if true; then N=2; fi") == [["true"], []])
        #expect(parse("case $x in a|*.pub) echo one;; b) ls -l;; esac; pwd") == [["echo", "one"], ["ls", "-l"], ["pwd"]])
        #expect(parse("case $x in\n  a) echo one ;;\n  *) echo two ;;\nesac") == [["echo", "one"], ["echo", "two"]])
        var l = ShellLexer(environment: [:], home: "/Users/u")
        _ = l.parse("case $x in a; rm -rf ~")
        #expect(l.unterminated) // the pattern is never closed
    }
}

@Suite struct ReadOnlyDetectionTests {
    let context = GuardContext(cwd: "/Users/u/Work/proj", home: "/Users/u", roots: ["/Users/u/Work/proj"], useFileSystem: false)

    @Test func writersNameWhatNeedsTheSnapshot() {
        let engine = RuleEngine()
        #expect(engine.writers("du -sh ~/Library/Caches | sort -h; csrutil status; ls -la ~/.ssh", context: context).isEmpty)
        #expect(engine.writers("sed -i '' s/a/b/ f.txt; ls; python3 tool.py", context: context) == ["sed", "python3"])
        #expect(engine.writers("echo hi > notes.txt", context: context) == ["> notes.txt"])
        #expect(engine.writers("ls > /dev/null 2>&1", context: context).isEmpty)
    }

    @Test(arguments: ["csrutil status", "fdesetup status", "fdesetup isactive", "fdesetup list", "nvram -p", "bless --getBoot"])
    func securityStatusIsAllowedWithoutSnapshot(_ command: String) {
        let v = RuleEngine().evaluate(command, context: context)
        #expect(v.decision == .allow && v.snapshot == .none && v.findings.isEmpty, "\(v)")
    }

    @Test(arguments: ["csrutil disable", "csrutil status --then-disable", "fdesetup disable", "fdesetup remove -user u", "nvram boot-args=-v",
                      "nvram -d boot-args", "bless --setBoot --mount /", "bless --unbless /"])
    func securityChangesStayBlocked(_ command: String) {
        let v = RuleEngine().evaluate(command, context: context)
        #expect(v.decision == .block && v.primary?.ruleId == "sys.security", "\(v)")
    }
}
