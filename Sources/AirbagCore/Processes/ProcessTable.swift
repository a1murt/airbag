import Darwin
import Foundation

/// One row of the kernel process table (`sysctl KERN_PROC_ALL`): every process, every user, including zombies.
public struct ProcEntry: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32
    public let uid: UInt32
    public let startUs: Int64
    public let comm: String
    public let zombie: Bool
    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startUs: startUs) }
}

public struct ProcessTable: Sendable {
    public let entries: [Int32: ProcEntry]
    public let capturedAtMs: Int64

    public init(entries: [Int32: ProcEntry], capturedAtMs: Int64 = Clock.nowMsInt()) {
        self.entries = entries
        self.capturedAtMs = capturedAtMs
    }

    public static func capture() -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return ProcessTable(entries: [:]) }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buf.count * stride
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return ProcessTable(entries: [:]) }
        var out: [Int32: ProcEntry] = [:]
        out.reserveCapacity(size / stride)
        for i in 0..<(size / stride) {
            var k = buf[i]
            let st = k.kp_proc.p_un.__p_starttime
            let comm = withUnsafePointer(to: &k.kp_proc.p_comm) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            let e = ProcEntry(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid, uid: k.kp_eproc.e_ucred.cr_uid,
                              startUs: Int64(st.tv_sec) * 1_000_000 + Int64(st.tv_usec), comm: comm, zombie: k.kp_proc.p_stat == 5)
            out[e.pid] = e
        }
        return ProcessTable(entries: out)
    }

    public subscript(pid: Int32) -> ProcEntry? { entries[pid] }

    public func isAlive(_ id: ProcessIdentity) -> Bool {
        guard let e = entries[id.pid] else { return false }
        return !e.zombie && e.startUs == id.startUs
    }

    /// Ancestors nearest first, within this table.
    public func ancestors(of pid: Int32, limit: Int = 32) -> [ProcEntry] {
        var out: [ProcEntry] = []
        var cur = entries[pid]?.ppid ?? 0
        while cur > 1, out.count < limit, let e = entries[cur] {
            out.append(e)
            cur = e.ppid
        }
        return out
    }

    /// All descendants of `pid` (breadth-first), restricted to this table.
    public func descendants(of pid: Int32) -> [ProcEntry] {
        var children: [Int32: [ProcEntry]] = [:]
        for e in entries.values { children[e.ppid, default: []].append(e) }
        var out: [ProcEntry] = []
        var queue = children[pid] ?? []
        while let e = queue.first {
            queue.removeFirst()
            out.append(e)
            queue += children[e.pid] ?? []
        }
        return out
    }
}

/// A listening TCP socket.
public struct Listener: Sendable, Equatable, Hashable, Codable {
    public enum Scope: String, Sendable, Codable { case loopback, any, specific }
    public let port: Int
    public let family: String   // ipv4 | ipv6
    public let address: String
    public let scope: Scope
    public init(port: Int, family: String, address: String, scope: Scope) { self.port = port; self.family = family; self.address = address; self.scope = scope }
}

public enum ListenerScanner {
    /// Listening TCP sockets of same-uid processes (libproc; ~1 ms for a few hundred processes).
    public static func scan(pids: [Int32]) -> [Int32: [Listener]] {
        var out: [Int32: [Listener]] = [:]
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 8)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            guard got > 0 else { continue }
            var set = Set<Listener>()
            for i in 0..<(Int(got) / fdSize) where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var si = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
                guard r == Int32(MemoryLayout<socket_fdinfo>.size), si.psi.soi_kind == SOCKINFO_TCP,
                      si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let ini = si.psi.soi_proto.pri_tcp.tcpsi_ini
                let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                let isV6 = (ini.insi_vflag & UInt8(INI_IPV6)) != 0
                var address: String
                if isV6 {
                    var a = ini.insi_laddr.ina_6
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
                    address = String(cString: buf)
                } else {
                    var a = ini.insi_laddr.ina_46.i46a_addr4
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
                    address = String(cString: buf)
                }
                let scope: Listener.Scope = ["127.0.0.1", "::1"].contains(address) ? .loopback : (["0.0.0.0", "::"].contains(address) ? .any : .specific)
                if address == "::" { address = "*" }
                if address == "0.0.0.0" { address = "*" }
                set.insert(Listener(port: port, family: isV6 ? "ipv6" : "ipv4", address: address, scope: scope))
            }
            if !set.isEmpty {
                // A dual-stack "any" socket and its IPv4 twin show once.
                var list = Array(set).sorted { ($0.port, $0.family) < ($1.port, $1.family) }
                list = list.reduce(into: [Listener]()) { acc, l in
                    if !acc.contains(where: { $0.port == l.port && $0.scope == l.scope && $0.address == l.address }) { acc.append(l) }
                }
                out[pid] = list
            }
        }
        return out
    }
}

/// Memory and CPU of one process (same uid).
public struct ProcUsage: Sendable, Equatable {
    public let footprintBytes: Int64
    public let cpuTimeNs: UInt64

    static let timebase: (numer: UInt32, denom: UInt32) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (tb.numer, tb.denom)
    }()

    public static func read(_ pid: Int32) -> ProcUsage? {
        var ri = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard rc == 0 else { return nil }
        let ticks = ri.ri_user_time + ri.ri_system_time
        let ns = ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
        return ProcUsage(footprintBytes: Int64(ri.ri_phys_footprint), cpuTimeNs: ns)
    }
}
