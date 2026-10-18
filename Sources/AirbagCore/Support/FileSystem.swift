import Darwin
import Foundation

public enum FileSystemError: Error, CustomStringConvertible, Sendable {
    case posix(op: String, path: String, errno: Int32)
    public var description: String {
        switch self {
        case .posix(let op, let path, let e): return "\(op) \(path): \(String(cString: strerror(e)))"
        }
    }
    public var errnoValue: Int32 { if case .posix(_, _, let e) = self { return e }; return 0 }
}

public enum FileSystem {
    /// mkdir -p with `mode` for every created component; chmods the leaf to `mode` if it already exists.
    public static func ensureDirectory(_ path: String, mode: mode_t) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw FileSystemError.posix(op: "mkdir", path: path, errno: ENOTDIR) }
            if chmod(path, mode) != 0 { throw FileSystemError.posix(op: "chmod", path: path, errno: errno) }
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, parent != path, !FileManager.default.fileExists(atPath: parent) {
            try ensureDirectory(parent, mode: mode)
        }
        if mkdir(path, mode) != 0 && errno != EEXIST {
            throw FileSystemError.posix(op: "mkdir", path: path, errno: errno)
        }
        _ = chmod(path, mode) // mkdir is subject to umask
    }

    /// The kernel's canonical path for an existing file or directory (resolves symlinks, /tmp → /private/tmp,
    /// firmlinks and on-disk letter case). Returns nil if the path cannot be opened.
    public static func canonicalPath(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { return nil }
        return String(cString: buf)
    }

    /// Canonical path for a path that may not exist: canonicalises the deepest existing ancestor and appends
    /// the remaining components.
    public static func resolvedPath(_ path: String) -> String {
        let absolute = (path as NSString).expandingTildeInPath
        let std = (absolute.hasPrefix("/") ? absolute : FileManager.default.currentDirectoryPath + "/" + absolute)
        var comps = (std as NSString).standardizingPath.split(separator: "/").map(String.init)
        var tail: [String] = []
        while !comps.isEmpty {
            let candidate = "/" + comps.joined(separator: "/")
            if let c = canonicalPath(candidate) {
                return tail.isEmpty ? c : c + "/" + tail.reversed().joined(separator: "/")
            }
            tail.append(comps.removeLast())
        }
        return "/" + tail.reversed().joined(separator: "/")
    }

    /// Writes data atomically: temp file in the same directory, fsync, rename. Keeps the mode of an existing
    /// destination unless `mode` is given.
    public static func writeAtomically(_ data: Data, to path: String, mode: mode_t? = nil) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".\((path as NSString).lastPathComponent).airbag-\(ULID.make())")
        var st = stat()
        let existingMode: mode_t? = lstat(path, &st) == 0 ? (st.st_mode & 0o7777) : nil
        let finalMode = mode ?? existingMode ?? 0o644
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, finalMode)
        guard fd >= 0 else { throw FileSystemError.posix(op: "open", path: tmp, errno: errno) }
        var ok = false
        defer {
            if !ok { unlink(tmp) }
        }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var off = 0
            while off < buf.count {
                let n = write(fd, base + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return -1 }
                off += n
            }
            return off
        }
        if written != data.count { let e = errno; close(fd); throw FileSystemError.posix(op: "write", path: tmp, errno: e) }
        _ = fchmod(fd, finalMode)
        _ = fsync(fd)
        close(fd)
        if rename(tmp, path) != 0 { throw FileSystemError.posix(op: "rename", path: path, errno: errno) }
        ok = true
    }

    public static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// Free bytes available to the user on the volume holding `path`.
    public static func availableBytes(at path: String) -> Int64? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    public static func totalBytes(at path: String) -> Int64? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return Int64(s.f_blocks) * Int64(s.f_bsize)
    }

    public static func deviceID(_ path: String) -> dev_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }
}
