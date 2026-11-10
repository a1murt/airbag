import Foundation
import Testing
@testable import AirbagCore

@Test func versionLineMentionsHookProtocol() {
    #expect(AirbagVersion.line.contains("hook protocol \(AirbagVersion.hookProtocol)"))
}

/// The Claude Code plugin pins its users to the version in its plugin.json: it moves with every release.
@Test func thePluginVersionIsTheAppVersion() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: repo.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["version"] as? String == AirbagVersion.marketing)
}
