import Darwin
import Foundation

/// Cross-process exclusive lock on a store (flock on `<store>/lock`). Released on `release()` or process exit.
final class StoreLock {
    private let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }
    deinit { release() }

    var isHeld: Bool { fd >= 0 }

    /// Tries to take the lock, polling every 10 ms for up to `waitMs`.
    func acquire(waitMs: Int) -> Bool {
        if fd >= 0 { return true }
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard f >= 0 else { return false }
        let deadline = Clock.monotonicNs() + UInt64(max(0, waitMs)) * 1_000_000
        while true {
            if flock(f, LOCK_EX | LOCK_NB) == 0 {
                fd = f
                return true
            }
            if errno != EWOULDBLOCK && errno != EINTR { close(f); return false }
            if Clock.monotonicNs() >= deadline { close(f); return false }
            usleep(10_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
