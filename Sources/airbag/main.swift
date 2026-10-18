import AirbagCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let code = CLI.run(arguments)
exit(code)
