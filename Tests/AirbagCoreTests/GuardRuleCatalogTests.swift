import Foundation
import Testing

/// The app explains each Guard finding by its rule id in the user's language (`GuardRule.summaries` in the app). Every id
/// the rule engine or the hook can report needs a summary there, and a summary for an id nothing reports any more is
/// dead text to translate; check-l10n then makes every summary exist in every language.
@Suite struct GuardRuleCatalogTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func source(_ path: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) }

    static func ids(_ text: String, _ patterns: [String]) -> Set<String> {
        var out = Set<String>()
        for p in patterns {
            let re = try! NSRegularExpression(pattern: p)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { out.insert(String(text[r])) }
            }
        }
        return out
    }

    @Test func everyRuleTheEngineReportsHasASummaryAndNoMore() throws {
        let engine = try Self.source("Sources/AirbagCore/Rules/RuleEngine.swift") + Self.source("Sources/AirbagCore/Hooks/HookBridge.swift")
        let reported = Self.ids(engine, [#"add\("([a-z0-9.\-]+)",\s*\.(?:block|ask|allow)"#,
                                         #"addGit\([^,]+,\s*[^,]+,\s*"([a-z0-9.\-]+)","#,
                                         #"ruleId: "([a-z0-9.\-]+)""#])
        let app = try Self.source("Sources/AirbagApp/Views/GuardRule.swift")
        let catalog = try #require(app.range(of: "static let summaries"))
        let summarized = Self.ids(String(app[catalog.lowerBound...]), [#""([a-z0-9.\-]+)": "#])
        #expect(reported.count > 80, "the patterns no longer find the rule ids: \(reported.sorted())")
        #expect(reported.subtracting(summarized).sorted() == [], "rules without a summary in GuardRule.summaries")
        #expect(summarized.subtracting(reported).sorted() == [], "summaries of rules nothing reports")
    }
}
