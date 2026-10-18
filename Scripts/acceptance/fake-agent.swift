// A stand-in for an agent process: registers a session through the real `airbag hook`, starts a dev server in its
// working directory with the environment real agents give their children, then waits until it is killed.
// usage: <claude|codex> <airbag-binary> <session-id> <cwd>
import Foundation

let args = CommandLine.arguments
let me = (args[0] as NSString).lastPathComponent
let airbag = args[1], session = args[2], cwd = args[3]
var env = ProcessInfo.processInfo.environment
if me == "claude" { env["CLAUDE_CODE_SESSION_ID"] = session; env["CLAUDE_PID"] = "\(getpid())" } else { env["CODEX_THREAD_ID"] = session }

func hook(_ payload: [String: Any]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: airbag)
    p.arguments = ["hook", me == "claude" ? "claude-code" : "codex"] + (me == "codex" ? ["session-start"] : [])
    p.environment = env
    let input = Pipe(); p.standardInput = input; p.standardOutput = FileHandle.nullDevice
    try! p.run()
    input.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: payload)); try! input.fileHandleForWriting.close()
    p.waitUntilExit()
}
hook(["session_id": session, "cwd": cwd, "hook_event_name": "SessionStart", "source": "startup"])
let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
server.arguments = ["python3", "-c", "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1], flush=True); time.sleep(600)"]
server.environment = env
server.currentDirectoryURL = URL(fileURLWithPath: cwd)
let out = Pipe(); server.standardOutput = out
try! server.run()
let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
print("port \(line.trimmingCharacters(in: .whitespacesAndNewlines)) pid \(getpid())", terminator: "\n")
fflush(stdout)
signal(SIGTERM) { _ in
    // graceful exit: tell Airbag the session ended, leave the server running (that is what agents do)
    exit(0)
}
while true { sleep(60) }
