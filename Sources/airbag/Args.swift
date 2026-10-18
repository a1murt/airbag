import Foundation

/// Tiny argument parser: `--name value`, `--name=value`, repeated options, boolean flags, positionals.
struct Args {
    var positionals: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ argv: [String], valueOptions: Set<String>) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { positionals.append(contentsOf: argv[(i + 1)...]); break }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq]), default: []].append(String(body[body.index(after: eq)...]))
                } else if valueOptions.contains(body) {
                    guard i + 1 < argv.count else { throw CLIError.usage("--\(body) needs a value") }
                    options[body, default: []].append(argv[i + 1])
                    i += 1
                } else {
                    flags.insert(body)
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    func value(_ name: String) -> String? { options[name]?.last }
    func values(_ name: String) -> [String] { options[name] ?? [] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func int(_ name: String) -> Int? { value(name).flatMap { Int($0) } }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)
    var description: String {
        switch self {
        case .usage(let m): return m
        case .failed(let m): return m
        }
    }
}

enum Out {
    static func json(_ value: Any) { print(JSONOutputBridge.string(value)) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8)) }

    static func encodable<T: Encodable>(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(value) { print(String(decoding: d, as: UTF8.self)) }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func date(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
