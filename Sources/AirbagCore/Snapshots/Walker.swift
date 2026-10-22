import Darwin
import Foundation

/// Stat keys used to detect changes without reading file contents.
struct StatKey: Equatable, Sendable {
    var size: Int64
    var mtimeNs: Int64
    var ctimeNs: Int64
    var ino: Int64
    var mode: Int64 // st_mode including file type bits

    init(_ st: stat) {
        size = Int64(st.st_size)
        mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        ctimeNs = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
        ino = Int64(bitPattern: UInt64(st.st_ino))
        mode = Int64(st.st_mode)
    }

    init(size: Int64, mtimeNs: Int64, ctimeNs: Int64, ino: Int64, mode: Int64) {
        self.size = size; self.mtimeNs = mtimeNs; self.ctimeNs = ctimeNs; self.ino = ino; self.mode = mode
    }

    var isSymlink: Bool { (mode & Int64(S_IFMT)) == Int64(S_IFLNK) }

    /// Same file for restore-conflict purposes. ctime is ignored: it changes when another hard link to the inode is
    /// replaced, which a restore of the sibling link does.
    func sameFile(_ other: StatKey) -> Bool { size == other.size && mtimeNs == other.mtimeNs && ino == other.ino && mode == other.mode }
    var isRegular: Bool { (mode & Int64(S_IFMT)) == Int64(S_IFREG) }
    var permissionBits: Int64 { mode & 0o7777 }
}

struct WalkEntry: Sendable {
    let relativePath: String
    let key: StatKey
}

struct WalkResult: Sendable {
    var entries: [WalkEntry] = []
    var skippedLarge: [String] = []
    /// Directories the walk could not read: what is inside them is unknown, not deleted.
    var unreadableDirs: [String] = []
    /// Entries whose metadata could not be read.
    var unreadableFiles: [String] = []
    var errors = 0
    var complete = true
    /// More than `maxEntries` entries or `maxBytes` bytes: the walk stopped there.
    var tooLarge = false
    /// Sum of the sizes of the regular files collected.
    var bytes: Int64 = 0
}

enum Walker {
    /// Walks `root` physically (no symlink following, no crossing mount points), skipping excluded
    /// directories. Collects regular files and symlinks.
    static func walk(root: String, exclusions: Exclusions, deadlineNs: UInt64? = nil, maxEntries: Int = 400_000,
                     maxBytes: Int64 = .max) -> WalkResult {
        var result = WalkResult()
        let rootC = strdup(root)
        defer { free(rootC) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            result.errors += 1
            result.complete = false
            return result
        }
        defer { fts_close(fts) }
        let rootLen = strlen(root)
        var counter = 0
        while let ent = fts_read(fts) {
            counter += 1
            if counter & 255 == 0, let d = deadlineNs, Clock.monotonicNs() >= d {
                result.complete = false
                break
            }
            if result.entries.count > maxEntries || result.bytes > maxBytes {
                result.complete = false
                result.tooLarge = true
                break
            }
            let e = ent.pointee
            let level = Int(e.fts_level)
            if level == 0 { continue }
            let pathLen = Int(e.fts_pathlen)
            guard pathLen > rootLen + 1 else { continue }
            // Paths are keys in Swift dictionaries (canonical equivalence) and in SQLite (raw bytes): store them in NFC so
            // both agree. APFS and HFS+ resolve NFC and NFD spellings of a name to the same file.
            let rel = String(cString: e.fts_path + rootLen + 1).precomposedStringWithCanonicalMapping
            let nameLen = Int(e.fts_namelen)
            let name = String(cString: e.fts_path + (pathLen - nameLen)).precomposedStringWithCanonicalMapping
            switch Int32(e.fts_info) {
            case FTS_D:
                if exclusions.skipsDirectory(name: name, relativePath: rel) || name.hasPrefix(".airbag-") {
                    fts_set(fts, ent, FTS_SKIP)
                }
            case FTS_F:
                guard let st = e.fts_statp?.pointee else { result.errors += 1; continue }
                if exclusions.fileNames.contains(name) || name.hasPrefix(".airbag-tmp-") { continue }
                if Int64(st.st_size) > exclusions.maxFileBytes {
                    result.skippedLarge.append(rel)
                    continue
                }
                result.entries.append(WalkEntry(relativePath: rel, key: StatKey(st)))
                result.bytes += Int64(st.st_size)
            case FTS_SL, FTS_SLNONE:
                guard let st = e.fts_statp?.pointee else { result.errors += 1; continue }
                result.entries.append(WalkEntry(relativePath: rel, key: StatKey(st)))
            case FTS_DNR, FTS_ERR:
                result.errors += 1
                result.unreadableDirs.append(rel)
            case FTS_NS:
                result.errors += 1
                result.unreadableFiles.append(rel)
            default:
                break // FTS_DP (post-order), FTS_DC (cycle), FTS_DEFAULT (fifo, socket, device): ignored
            }
        }
        if result.entries.count > maxEntries || result.bytes > maxBytes { // the last entry crossed the limit
            result.complete = false
            result.tooLarge = true
        }
        return result
    }

    static func readLink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let n = readlink(path, &buf, Int(MAXPATHLEN))
        guard n >= 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    static func lstatKey(_ path: String) -> StatKey? {
        var st = stat()
        return lstat(path, &st) == 0 ? StatKey(st) : nil
    }
}
