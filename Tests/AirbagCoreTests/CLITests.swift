import Foundation
import Testing
@testable import AirbagCore

/// Runs the `airbag` command built next to the test bundle, with Airbag's data in `home`.
func airbagCLI(_ args: [String], home: String) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("airbag")
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(["AIRBAG_HOME": home]) { _, new in new }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The CLI never runs a command it was asked to preview or explain, nor one with an option it does not know.
@Suite(.serialized) struct CLITests {
    @Test func unknownOrMisspelledOptionsAreRefusedBeforeAnythingRuns() throws {
        let sb = Sandbox("cli"); defer { sb.cleanup() }
        let home = sb.paths.home.path
        for i in 1...3 {
            sb.write("a.txt", "v\(i)")
            #expect(airbagCLI(["snapshot", "--root", sb.root, "--label", "s\(i)"], home: home).status == 0)
        }
        let count = { try sb.store().list(limit: 100).count }
        #expect(try count() == 3)
        let prune = ["prune", "--root", sb.root, "--keep", "1", "--days", "0", "--max", "1"]
        let typo = airbagCLI(prune + ["--dryrun"], home: home)
        #expect(typo.status == 64 && typo.output.contains("unknown option --dryrun"), "\(typo)")
        #expect(airbagCLI(prune + ["--dry-run=maybe"], home: home).status == 64)
        let preview = airbagCLI(prune + ["--dry-run=true"], home: home)
        #expect(preview.status == 0 && preview.output.contains("would delete"), "\(preview)")
        #expect(airbagCLI(["restore", "01NOTASNAPSHOT", "--dry-run"], home: home).status == 64) // restore has no preview
        #expect(try count() == 3)
    }

    @Test func helpAfterASubcommandOnlyPrintsHelp() throws {
        let sb = Sandbox("cli"); defer { sb.cleanup() }
        let home = sb.paths.home.path
        let agentHome = sb.tmp.sub("agent-home")
        try FileManager.default.createDirectory(atPath: agentHome + "/.claude", withIntermediateDirectories: true)
        // The hook command must end in `airbag`: that is how Airbag tells its own entries from others.
        let command = sb.tmp.sub("bin/airbag")
        #expect(airbagCLI(["hooks", "install", "claude-code", "--home", agentHome, "--command", command], home: home).status == 0)
        let settings = { try? String(contentsOfFile: agentHome + "/.claude/settings.json", encoding: .utf8) }
        let installed = settings()
        #expect(installed?.contains(command) == true)
        for help in ["--help", "-h"] {
            let r = airbagCLI(["hooks", "uninstall", "--all", "--home", agentHome, help], home: home)
            #expect(r.status == 0 && r.output.hasPrefix("usage: airbag hooks"), "\(r)")
        }
        #expect(settings() == installed)
        // After `--` it is an operand and the uninstall runs (the circuit breaker asks about that form).
        #expect(airbagCLI(["hooks", "uninstall", "--all", "--home", agentHome, "--", "--help"], home: home).status == 0)
        #expect(settings()?.contains(command) != true)
    }
}
