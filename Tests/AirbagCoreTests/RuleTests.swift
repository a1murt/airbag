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

    /// rules.json plus the red-team cases (docs/research/07-breaker-redteam.md), which share its context.
    static let shared: RuleFixture = {
        let url = Bundle.module.url(forResource: "rules", withExtension: "json", subdirectory: "Fixtures")!
        let base = try! JSONDecoder().decode(RuleFixture.self, from: Data(contentsOf: url))
        let extraURL = Bundle.module.url(forResource: "rules-redteam", withExtension: "json", subdirectory: "Fixtures")!
        let extra = try! JSONDecoder().decode(Extra.self, from: Data(contentsOf: extraURL))
        return RuleFixture(version: base.version, context: base.context, cases: base.cases + extra.cases)
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
}
