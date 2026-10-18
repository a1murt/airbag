import AirbagCore
import Foundation

enum CLI {
    static func run(_ args: [String]) -> Int32 {
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
        default:
            FileHandle.standardError.write(Data("airbag: unknown command '\(command)'\n".utf8))
            printUsage()
            return 64
        }
    }

    static func printUsage() {
        print("""
        usage: airbag <command> [options]

        commands:
          version        print version
          help           show this help
        """)
    }
}
