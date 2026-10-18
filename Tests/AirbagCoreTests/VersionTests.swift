import Testing
@testable import AirbagCore

@Test func versionLineMentionsHookProtocol() {
    #expect(AirbagVersion.line.contains("hook protocol \(AirbagVersion.hookProtocol)"))
}
