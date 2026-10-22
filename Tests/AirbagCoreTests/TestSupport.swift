import Foundation
@testable import AirbagCore

/// A unique temporary directory, canonicalised (so /tmp → /private/tmp), removed by `cleanup()`. Not in the per-user
/// temporary folder: Airbag never snapshots anything below /private/var (ADR-032).
struct TempDir {
    let path: String
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    static let base = URL(fileURLWithPath: "/private/tmp/airbag-tests-\(getuid())", isDirectory: true)

    init(_ label: String = "t") {
        let base = TempDir.base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dir = base.appendingPathComponent("\(label)-\(ULID.make())", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = FileSystem.canonicalPath(dir.path)!
    }

    func sub(_ rel: String) -> String { (path as NSString).appendingPathComponent(rel) }

    @discardableResult
    func write(_ rel: String, _ content: String, mode: mode_t = 0o644) -> String {
        let p = sub(rel)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: URL(fileURLWithPath: p))
        chmod(p, mode)
        return p
    }

    func read(_ rel: String) -> String? { try? String(contentsOfFile: sub(rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { var st = stat(); return lstat(sub(rel), &st) == 0 }
    func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}

/// Runs a shell command synchronously; returns (status, stdout+stderr).
@discardableResult
func sh(_ command: String, cwd: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
