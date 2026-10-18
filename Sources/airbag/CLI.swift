import AirbagCore
import Foundation

enum CLI {
    static let commands: [(name: String, help: String, run: ([String]) throws -> Int32)] = [
        ("snapshot", "take a snapshot of the current project (--root, --label, --initial, --force)", SnapshotCommands.snapshot),
        ("snapshots", "list snapshots (--root, --limit)", SnapshotCommands.list),
        ("changes", "files changed by a snapshot", SnapshotCommands.changes),
        ("diff", "diff two snapshots or a snapshot and the working tree (--path for one file)", SnapshotCommands.diff),
        ("restore", "restore the project or --path entries to a snapshot (never deletes; undoable)", SnapshotCommands.restore),
        ("pin", "keep a snapshot forever (--off to unpin)", SnapshotCommands.pin),
        ("prune", "apply retention (--all, --days, --keep, --dry-run)", SnapshotCommands.prune),
        ("export", "write a snapshot's files into an empty directory", SnapshotCommands.export),
        ("usage", "disk usage of all snapshot stores", SnapshotCommands.usage),
        ("check", "show what the circuit breaker decides for a shell command (--cwd, --root)", GuardCommands.check),
        ("hooks", "manage agent hooks: status | install | uninstall [agents…|--all] [--dry-run] [--strict]", HookCommands.hooks),
        ("guard", "recent blocked, asked and risky commands", HookCommands.guardLog),
        ("allow", "approve one blocked or asked command once (id from `airbag guard`)", HookCommands.allow),
        ("sessions", "agent sessions Airbag has seen (--all includes ended ones)", HookCommands.sessions),
        ("log", "agent commands with their decision and the snapshot taken right before them", HookCommands.log),
        ("ports", "listening dev servers and the agent session that started them (--all)", RadarCommands.ports),
        ("stop", "stop a dev server and its children: SIGTERM, then --force for SIGKILL", RadarCommands.stop),
    ]

    static func run(_ args: [String]) -> Int32 {
        Log.shared.configure(file: nil, category: "cli")
        guard let command = args.first else {
            printUsage()
            return 64
        }
        switch command {
        case "version", "--version", "-v":
            print(AirbagVersion.line)
            return 0
        case "help", "--help", "-h":
            printUsage()
            return 0
        case "hook":
            return HookCommands.hook(Array(args.dropFirst()))
        default:
            guard let c = commands.first(where: { $0.name == command }) else {
                Out.err("airbag: unknown command '\(command)'")
                printUsage()
                return 64
            }
            do {
                return try c.run(Array(args.dropFirst()))
            } catch let e as CLIError {
                Out.err("airbag \(command): \(e)")
                if case .usage = e { return 64 }
                return 1
            } catch {
                Out.err("airbag \(command): \(error)")
                return 1
            }
        }
    }

    static func printUsage() {
        var s = "usage: airbag <command> [options]\n\ncommands:\n"
        for c in commands { s += "  \(c.name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(c.help)\n" }
        s += "  version     print version\n"
        print(s, terminator: "")
    }
}
