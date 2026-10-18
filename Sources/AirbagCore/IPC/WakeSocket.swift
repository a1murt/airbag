import Darwin
import Foundation

/// Fire-and-forget wake-up from the CLI to the app over a Unix-domain socket (doc 11 §5). Never blocks long.
public enum WakeSocket {
    public static func notify(paths: AirbagPaths, message: [String: Any], timeoutMs: Int32 = 20) {
        let path = paths.socket.path
        guard path.utf8.count < 104 else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMs) == 1 else { return }
        }
        let line = JSONOutput.string(message) + "\n"
        _ = line.withCString { send(fd, $0, strlen($0), 0) }
    }
}

/// Server side used by the app: accepts connections and delivers each received line to `handler`.
public final class WakeSocketServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let path: String
    private let queue = DispatchQueue(label: "dev.airbag.wake")
    private let handler: @Sendable ([String: Any]) -> Void

    public init(paths: AirbagPaths, handler: @escaping @Sendable ([String: Any]) -> Void) {
        self.path = paths.socket.path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FileSystemError.posix(op: "socket", path: path, errno: errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let old = umask(0o177)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0, listen(fd, 16) == 0 else { throw FileSystemError.posix(op: "bind", path: path, errno: errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let listenFD = fd
        let handler = self.handler
        src.setEventHandler {
            while true {
                let c = accept(listenFD, nil, nil)
                if c < 0 { break }
                // Only accept peers running as the same user.
                var uid: uid_t = 0, gid: gid_t = 0
                if getpeereid(c, &uid, &gid) != 0 || uid != getuid() { close(c); continue }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                var tv = timeval(tv_sec: 0, tv_usec: 50_000)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                while data.count < 65536 {
                    let n = recv(c, &buf, buf.count, 0)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                close(c)
                for line in data.split(separator: UInt8(ascii: "\n")) {
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { handler(obj) }
                }
            }
        }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }
}
