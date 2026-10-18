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
    let onSettled: (String) -> Void
    private var stream: FSEventStreamRef?
    private var pending: [String: (first: Date, last: Date)] = [:]
    private var timer: DispatchSourceTimer?

    public init(roots: [String], exclusions: Exclusions = .standard, quietSeconds: TimeInterval = 3, maxSeconds: TimeInterval = 30,
                queue: DispatchQueue, onSettled: @escaping (String) -> Void) {
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
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            me.received(Array(arr.prefix(count)))
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
    }

    /// Called on `queue`.
    func received(_ paths: [String]) {
        let now = Date()
        for p in paths {
            guard let root = roots.first(where: { p == $0 || p.hasPrefix($0 + "/") }) else { continue }
            let rel = p == root ? "" : String(p.dropFirst(root.count + 1))
            if !rel.isEmpty && (exclusions.isExcluded(relativePath: rel + "/x") || rel.contains("/.airbag-") || rel.hasPrefix(".airbag-")) { continue }
            if let cur = pending[root] { pending[root] = (cur.first, now) } else { pending[root] = (now, now) }
        }
    }

    func tick() {
        let now = Date()
        for (root, t) in pending where now.timeIntervalSince(t.last) >= quiet || now.timeIntervalSince(t.first) >= maxWait {
            pending.removeValue(forKey: root)
            onSettled(root)
        }
    }
}
