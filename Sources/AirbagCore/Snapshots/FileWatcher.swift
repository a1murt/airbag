import CoreServices
import Foundation

/// FSEvents watcher over several roots with per-root debouncing: a root "settles" after `quietSeconds` without
/// events or after `maxSeconds` of continuous activity, then `onSettled(root)` runs on `queue`.
public final class FileWatcher {
    public let roots: [String]
    let exclusions: Exclusions
    let quiet: TimeInterval
    let maxWait: TimeInterval
    let queue: DispatchQueue
    let onSettled: (String, [String]) -> Void
    private var stream: FSEventStreamRef?
    public var isRunning: Bool { stream != nil }
    private var pending: [String: (first: Date, last: Date, paths: [String])] = [:]
    private var timer: DispatchSourceTimer?

    /// `onSettled(root, samplePaths)`: up to 20 root-relative paths that triggered it ("" = the root itself).
    public init(roots: [String], exclusions: Exclusions = .standard, quietSeconds: TimeInterval = 3, maxSeconds: TimeInterval = 30,
                queue: DispatchQueue, onSettled: @escaping (String, [String]) -> Void) {
        self.roots = roots.sorted { $0.count > $1.count } // longest prefix first
        self.exclusions = exclusions
        self.quiet = quietSeconds
        self.maxWait = maxSeconds
        self.queue = queue
        self.onSettled = onSettled
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        // No kFSEventStreamCreateFlagWatchRoot: it opens a descriptor for every folder on the way to every root, and with a
        // few dozen projects that passes the 256 a Mac app gets by default, so the stream is never created. A moved or
        // deleted root shows up on the next project refresh instead.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            me.received(Array(arr.prefix(count)), flags: (0..<count).map { flags[$0] })
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            FileWatcher.reopenStandardInputIfClosed()
            Log.shared.warn("FSEvents: could not watch \(roots.count) folders")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// When FSEventStreamCreate fails, its cleanup closes descriptor 0 (macOS 27). Put /dev/null back there, so the next
    /// descriptor something opens and guards can't land on 0 and be closed by a later failure (an EXC_GUARD crash).
    static func reopenStandardInputIfClosed() {
        guard fcntl(0, F_GETFD) == -1 else { return }
        let fd = open("/dev/null", O_RDONLY)
        if fd > 0 { dup2(fd, 0); close(fd) }
    }

    public func stop() {
        timer?.cancel(); timer = nil
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
    }

    /// Called on `queue`.
    func received(_ paths: [String], flags: [FSEventStreamEventFlags] = []) {
        let now = Date()
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for (i, raw) in paths.enumerated() {
            let p = raw.precomposedStringWithCanonicalMapping
            guard let root = roots.first(where: { p == $0 || p.hasPrefix($0 + "/") }) else { continue }
            let rel = p == root ? "" : String(p.dropFirst(root.count + 1))
            let f = i < flags.count ? flags[i] : 0
            // The root's own metadata (its mtime changes whenever an entry is added) is not a file change, unless
            // FSEvents says it dropped events and everything under it must be rescanned.
            if rel.isEmpty && (f & rescan) == 0 { continue }
            if !rel.isEmpty && (exclusions.isExcluded(relativePath: rel + "/x") || rel.contains("/.airbag-") || rel.hasPrefix(".airbag-")) { continue }
            if let cur = pending[root] {
                pending[root] = (cur.first, now, cur.paths.count < 20 ? cur.paths + [rel] : cur.paths)
            } else {
                pending[root] = (now, now, [rel])
            }
        }
    }

    func tick() {
        let now = Date()
        for (root, t) in pending where now.timeIntervalSince(t.last) >= quiet || now.timeIntervalSince(t.first) >= maxWait {
            pending.removeValue(forKey: root)
            onSettled(root, t.paths)
        }
    }
}
