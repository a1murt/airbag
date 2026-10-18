import Darwin
import Foundation

/// Identity of a process that survives pid reuse: (pid, start time in µs).
public struct ProcessIdentity: Hashable, Sendable, Codable {
    public let pid: Int32
    public let startUs: Int64
    public init(pid: Int32, startUs: Int64) { self.pid = pid; self.startUs = startUs }
}

/// Basic facts about one process from libproc (same-uid processes give the full picture).
public struct ProcSnapshot: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32
    public let uid: UInt32
    public let startUs: Int64
    public let name: String
    public let ttyDev: UInt32
    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startUs: startUs) }
}

public enum ProcInfo {
    /// `PROC_PIDTBSDINFO` for one pid.
    public static func bsdInfo(_ pid: Int32) -> ProcSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafePointer(to: &info.pbi_name) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) { String(cString: $0) }
        }
        let comm = name.isEmpty ? withUnsafePointer(to: &info.pbi_comm) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        } : name
        return ProcSnapshot(pid: Int32(info.pbi_pid), ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid), uid: info.pbi_uid,
                            startUs: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec),
                            name: comm, ttyDev: info.e_tdev)
    }

    /// Executable path of a process.
    public static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Current working directory (same-uid only).
    public static func cwd(_ pid: Int32) -> String? {
        var vi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, size) == size else { return nil }
        let s = withUnsafePointer(to: &vi.pvi_cdir.vip_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return s.isEmpty ? nil : s
    }

    /// argv and environment via `sysctl KERN_PROCARGS2` (same uid; Apple platform binaries hide their env).
    public static func arguments(_ pid: Int32) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // skip exec path
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var strings: [String] = []
        var start = i
        while i < size {
            if buf[i] == 0 {
                if i > start { strings.append(String(decoding: buf[start..<i], as: UTF8.self)) } else if strings.count >= Int(argc) { break }
                start = i + 1
            }
            i += 1
        }
        let argv = Array(strings.prefix(Int(argc)))
        var env: [String: String] = [:]
        for kv in strings.dropFirst(Int(argc)) {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        return (argv, env)
    }

    /// Ancestors of `pid`, nearest first (stops at launchd or after `limit` hops).
    public static func ancestors(of pid: Int32, limit: Int = 32) -> [ProcSnapshot] {
        var out: [ProcSnapshot] = []
        var cur = pid
        for _ in 0..<limit {
            guard let p = bsdInfo(cur) else { break }
            out.append(p)
            if p.ppid <= 1 || p.ppid == cur { break }
            cur = p.ppid
        }
        return out
    }

    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let p = bsdInfo(identity.pid) else { return false }
        return p.startUs == identity.startUs
    }

    /// Path of the running executable (for spawning ourselves and for installing hooks).
    public static func currentExecutablePath() -> String {
        if let p = path(getpid()) { return p }
        return CommandLine.arguments.first ?? "airbag"
    }
}
