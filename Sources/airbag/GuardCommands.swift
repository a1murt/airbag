import AirbagCore
import Foundation

enum GuardCommands {
    /// airbag check "<command>" [--cwd DIR] [--root DIR]... [--json]
    static func check(_ argv: [String]) throws -> Int32 {
        let a = try Args(argv, valueOptions: ["cwd", "root"])
        guard !a.positionals.isEmpty else { throw CLIError.usage("usage: airbag check \"<shell command>\" [--cwd DIR] [--root DIR] [--json]") }
        let command = a.positionals.joined(separator: " ")
        let cwd = FileSystem.resolvedPath(a.value("cwd") ?? FileManager.default.currentDirectoryPath)
        var roots = a.values("root").map { FileSystem.canonicalPath($0) ?? FileSystem.resolvedPath($0) }
        let paths = AirbagPaths.resolve()
        // Same as the hook: a folder Airbag cannot snapshot (home, system) is not a protected root.
        if roots.isEmpty { roots = [RootResolver.resolve(cwd: cwd)].filter { (try? SnapshotStore.validateRoot($0, paths: paths)) != nil } }
        var context = GuardContext(cwd: cwd, roots: roots, environment: ProcessInfo.processInfo.environment,
                                   airbagHome: FileSystem.canonicalPath(paths.home.path) ?? paths.home.path)
        context.roots += HookBridge.visitedRoots(command, context: context, paths: paths) // as the hook does
        let v = RuleEngine().evaluate(command, context: context)
        if a.has("json") {
            Out.encodable(v)
        } else {
            print("\(v.decision.rawValue.uppercased())  snapshot: \(v.snapshot.rawValue)")
            for f in v.findings { print("  [\(f.ruleId)] \(f.decision.rawValue): \(f.reason)  ← \(f.matched)") }
            if v.decision != .allow { print("\nagent sees: \(v.agentMessage(command: command))") }
        }
        return v.decision == .allow ? 0 : (v.decision == .ask ? 2 : 3)
    }
}
