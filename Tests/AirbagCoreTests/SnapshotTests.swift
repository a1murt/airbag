import Foundation
import Testing
@testable import AirbagCore

/// A project directory plus an isolated Airbag home.
struct Sandbox {
    let tmp: TempDir
    let paths: AirbagPaths
    let root: String

    init(_ label: String = "snap") {
        tmp = TempDir(label)
        paths = AirbagPaths(home: tmp.url.appendingPathComponent("home"))
        try! FileManager.default.createDirectory(atPath: tmp.sub("proj"), withIntermediateDirectories: true)
        root = tmp.sub("proj")
    }

    func store() throws -> SnapshotStore { try SnapshotStore.open(root: root, paths: paths) }
    @discardableResult func write(_ rel: String, _ s: String, mode: mode_t = 0o644) -> String { tmp.write("proj/" + rel, s, mode: mode) }
    func read(_ rel: String) -> String? { tmp.read("proj/" + rel) }
    func exists(_ rel: String) -> Bool { tmp.exists("proj/" + rel) }
    func run(_ cmd: String) -> (Int32, String) { sh(cmd, cwd: root) }
    func cleanup() { tmp.cleanup() }

    /// relpath → "f:<mode>:<sha>" | "l:<target>" for every file and symlink, skipping the given directory names.
    func digest(skipping: Set<String> = [".git", "node_modules"]) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return out }
        while let rel = en.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            let abs = root + "/" + rel
            var st = stat()
            guard lstat(abs, &st) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            if type == S_IFDIR {
                if skipping.contains(name) { en.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            if type == S_IFLNK {
                out[rel] = "l:" + (Walker.readLink(abs) ?? "?")
            } else if type == S_IFREG {
                out[rel] = "f:\(String(st.st_mode & 0o777, radix: 8)):" + Hashing.hex(Hashing.sha256(fileAtPath: abs) ?? Data())
            }
        }
        return out
    }

    /// A small but realistic project.
    func seedProject() {
        write("package.json", #"{"name":"demo","scripts":{"dev":"next dev"}}"#)
        write(".env", "DATABASE_URL=postgres://localhost/demo\nSECRET=s3cr3t\n", mode: 0o600)
        write(".gitignore", ".env\nnode_modules/\ndist/\n")
        write("src/index.ts", "export const answer = 42;\n")
        write("src/lib/util.ts", "export function add(a: number, b: number) { return a + b; }\n")
        write("src/legacy/old.ts", "// legacy\nexport const old = true;\n")
        write("src/legacy/deep/nested.ts", "export const deep = 1;\n")
        write("scripts/run.sh", "#!/bin/sh\necho hi\n", mode: 0o755)
        write("docs/Заметки и пробелы.md", "# Привет\nunicode name with spaces\n")
        write("node_modules/left-pad/index.js", "module.exports = 1;\n")
        write("dist/bundle.js", "built();\n")
        symlink("src/index.ts", root + "/entry.ts")
    }
}

func created(_ o: SnapshotOutcome, sourceLocation: SourceLocation = #_sourceLocation) -> SnapshotInfo {
    if case .created(let s, _) = o { return s }
    Issue.record("expected a created snapshot, got \(o)", sourceLocation: sourceLocation)
    return SnapshotInfo(id: "", seq: 0, createdAt: 0, trigger: .manual, label: nil, sessionKey: nil, fileCount: 0,
                        changedCount: 0, bytesAdded: 0, pinned: false, complete: false)
}

@Suite struct SnapshotEngineTests {
    @Test func initialUnchangedAndModified() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        let store = try sb.store()
        let first = created(store.snapshot(SnapshotRequest(trigger: .initial)))
        #expect(first.fileCount == 10) // node_modules and dist excluded; symlink and .env included
        #expect(first.complete)

        if case .unchanged(let latest, _) = store.snapshot(SnapshotRequest(trigger: .manual)) {
            #expect(latest?.id == first.id)
        } else { Issue.record("expected unchanged") }

        // Touch without content change → deduplicated, still unchanged.
        sh("touch \(sb.root)/src/index.ts")
        guard case .unchanged(_, let stats) = store.snapshot(SnapshotRequest(trigger: .manual)) else { Issue.record("touch should not create a snapshot"); return }
        #expect(stats.deduplicated == 1)

        sb.write("src/index.ts", "export const answer = 43;\n")
        sb.write("src/new.ts", "new\n")
        try FileManager.default.removeItem(atPath: sb.root + "/src/lib/util.ts")
        let second = created(store.snapshot(SnapshotRequest(trigger: .preCommand, label: "Before `rm`")))
        let changes = try store.changes(in: second.id)
        #expect(changes.map(\.path) == ["src/index.ts", "src/lib/util.ts", "src/new.ts"])
        #expect(changes.map(\.status) == [.modified, .deleted, .added])
        #expect(try store.list().map(\.id) == [second.id, first.id])
    }

    @Test func gitignoredSecretsAreCapturedAndExcludedDirsAreNot() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        let store = try sb.store()
        let s = created(store.snapshot(SnapshotRequest(trigger: .initial)))
        let state = try store.state(atSeq: s.seq)
        #expect(state[".env"] != nil)
        #expect(state["node_modules/left-pad/index.js"] == nil)
        #expect(state["dist/bundle.js"] == nil)
        #expect(state["entry.ts"]?.kind == 1)
        // The store and its object tree are private to the user.
        var st = stat()
        #expect(FileManager.default.fileExists(atPath: store.objectPath(state[".env"]!.id)))
        for d in [store.directory, store.objectsDir, (store.objectPath(state[".env"]!.id) as NSString).deletingLastPathComponent] {
            lstat(d, &st)
            #expect(st.st_mode & 0o777 == 0o700, "\(d)")
        }
    }

    @Test func restoreAfterRmRf() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        let store = try sb.store()
        let before = sb.digest()
        let snap = created(store.snapshot(SnapshotRequest(trigger: .preCommand, label: "Before `rm -rf src`")))
        sb.run("rm -rf src")
        let report = try store.restore(to: snap.id, scope: .paths(["src"]))
        #expect(report.conflicts.isEmpty && report.failed.isEmpty)
        #expect(sb.digest() == before)
        #expect(report.undoSnapshotId != nil)
    }

    @Test func restoreAfterMvAndSedAcrossTree() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        for i in 0..<200 { sb.write("src/gen/file\(i).ts", "export const v\(i) = \(i);\n") }
        let store = try sb.store()
        let before = sb.digest()
        let snap = created(store.snapshot(SnapshotRequest(trigger: .preCommand)))
        sb.run("find src -name '*.ts' -exec sed -i '' 's/export/EXPORT/' {} +")
        sb.run("mv docs \(sb.tmp.path)/moved-docs && mv scripts/run.sh scripts/renamed.sh && chmod 644 scripts/renamed.sh")
        #expect(sb.digest() != before)
        let report = try store.restore(to: snap.id, scope: .root)
        #expect(report.conflicts.isEmpty && report.failed.isEmpty)
        #expect(sb.digest() == before)
        #expect(!sb.exists("scripts/renamed.sh")) // created after the snapshot, moved aside
        #expect(report.movedAside.contains("scripts/renamed.sh"))
        let aside = try #require(report.asideDirectory)
        #expect(FileManager.default.fileExists(atPath: aside + "/scripts/renamed.sh"))
    }

    @Test(arguments: ["git checkout -- .", "git reset --hard", "git clean -fdx", "git stash -u"])
    func restoreAfterGitCommand(_ command: String) throws {
        guard FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
                || FileManager.default.fileExists(atPath: "/Applications/Xcode.app") else { return }
        let sb = Sandbox("git"); defer { sb.cleanup() }
        sb.seedProject()
        let (status, out) = sb.run("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init")
        #expect(status == 0, "\(out)")
        // Uncommitted work an agent is about to destroy:
        sb.write("src/index.ts", "export const answer = 99; // uncommitted\n")
        sb.write("src/untracked.ts", "export const fresh = true;\n")
        sb.write("data/local.db", "sqlite-ish bytes")
        let store = try sb.store()
        // dist/ and node_modules/ are regenerable and excluded by design, so `git clean -fdx` may remove them for good.
        let skip: Set<String> = [".git", "node_modules", "dist"]
        let before = sb.digest(skipping: skip)
        let snap = created(store.snapshot(SnapshotRequest(trigger: .preCommand, label: "Before `\(command)`")))
        sb.run(command)
        #expect(sb.digest(skipping: skip) != before, "\(command) did not change anything")
        let report = try store.restore(to: snap.id, scope: .root)
        #expect(report.conflicts.isEmpty && report.failed.isEmpty)
        #expect(sb.digest(skipping: skip) == before)
        #expect(sb.read(".env")?.contains("SECRET") == true)
    }

    @Test func typeSwapSymlinkAndModeChanges() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        let store = try sb.store()
        let before = sb.digest()
        let snap = created(store.snapshot(SnapshotRequest(trigger: .preCommand)))
        // file → directory, directory → file, symlink retarget, exec bit flip
        sb.run("rm src/index.ts && mkdir -p src/index.ts/inner && echo x > src/index.ts/inner/y.txt")
        sb.run("rm -rf src/legacy && echo 'not a dir' > src/legacy")
        sb.run("rm entry.ts && ln -s src/lib/util.ts entry.ts && chmod 600 scripts/run.sh")
        let report = try store.restore(to: snap.id, scope: .root)
        #expect(report.failed.isEmpty && report.conflicts.isEmpty, "\(report)")
        #expect(sb.digest() == before)
        // The directory that stood in the way was moved aside with its content, not deleted.
        let aside = try #require(report.asideDirectory)
        #expect(FileManager.default.fileExists(atPath: aside + "/src/index.ts/inner/y.txt"))
    }

    @Test func undoRestoreReturnsToPostCommandState() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        let store = try sb.store()
        let snap = created(store.snapshot(SnapshotRequest(trigger: .preCommand)))
        sb.write("src/index.ts", "agent version\n")
        sb.write("src/agent-added.ts", "added by agent\n")
        let agentState = sb.digest()
        let report = try store.restore(to: snap.id, scope: .root)
        #expect(sb.read("src/index.ts") == "export const answer = 42;\n")
        let undo = try #require(report.undoSnapshotId)
        let report2 = try store.restore(to: undo, scope: .root)
        #expect(report2.failed.isEmpty)
        #expect(sb.digest() == agentState)
    }

    @Test func rootRestoreLeavesExcludedAndUncapturedFilesAlone() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        var ex = Exclusions.standard
        ex.maxFileBytes = 1024
        let store = try SnapshotStore.open(root: sb.root, paths: sb.paths, exclusions: ex)
        let snap = created(store.snapshot(SnapshotRequest(trigger: .preCommand)))
        sb.write("node_modules/new-dep/index.js", "dep\n")
        sb.write("big.bin", String(repeating: "x", count: 4096))
        _ = try store.restore(to: snap.id, scope: .root)
        #expect(sb.exists("node_modules/new-dep/index.js"))
        #expect(sb.exists("node_modules/left-pad/index.js"))
        #expect(sb.exists("big.bin"))
        #expect(sb.exists("dist/bundle.js"))
    }

    @Test func restoreRefusesToTouchConcurrentlyModifiedFile() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        let store = try sb.store()
        let snap = created(store.snapshot(SnapshotRequest(trigger: .preCommand)))
        sb.write("src/index.ts", "changed by agent\n")
        sb.write("src/lib/util.ts", "also changed\n")
        // An agent keeps writing while the restore runs: after the pre-restore snapshot, before the replacement.
        store.beforeApplyHook = { path in
            if path == "src/index.ts" { sb.write("src/index.ts", "written during restore\n") }
        }
        let report = try store.restore(to: snap.id, scope: .root)
        #expect(report.conflicts == ["src/index.ts"])
        #expect(sb.read("src/index.ts") == "written during restore\n") // never clobbered
        #expect(sb.read("src/lib/util.ts") == "export function add(a: number, b: number) { return a + b; }\n")
    }

    @Test func fileDiffShowsLineChanges() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.write("a.txt", "one\ntwo\nthree\nfour\n")
        let store = try sb.store()
        let s1 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        sb.write("a.txt", "one\n2\nthree\nfour\nfive\n")
        let s2 = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        let d = try store.fileDiff(path: "a.txt", from: s1.id, to: s2.id)
        #expect(d.summary == .text)
        #expect(d.addedLines == 2 && d.removedLines == 1)
        #expect(d.unified.contains("-two\n+2\n"))
        let live = try store.diff(from: s1.id, to: nil)
        #expect(live == [FileChange(path: "a.txt", status: .modified, oldSize: 19, newSize: 22)])
    }

    @Test func unsafeRootsAreRefused() {
        let sb = Sandbox(); defer { sb.cleanup() }
        for p in ["/", NSHomeDirectory(), "/Users", sb.paths.home.path] {
            try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            #expect(throws: SnapshotError.self) { _ = try SnapshotStore.validateRoot(p, paths: sb.paths) }
        }
    }

    @Test func busyWhenLocked() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.write("a.txt", "a")
        let s1 = try sb.store()
        let s2 = try sb.store()
        #expect(s1.lock.acquire(waitMs: 0))
        if case .busy = s2.snapshot(SnapshotRequest(trigger: .manual, lockWaitMs: 30)) {} else { Issue.record("expected busy") }
        s1.lock.release()
        _ = created(s2.snapshot(SnapshotRequest(trigger: .manual)))
    }

    @Test func exportMaterialisesSnapshot() throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        sb.seedProject()
        let store = try sb.store()
        let snap = created(store.snapshot(SnapshotRequest(trigger: .manual)))
        let dest = sb.tmp.sub("export")
        let n = try store.export(snap.id, to: dest, prefixes: ["src"])
        #expect(n == 4)
        #expect(sb.tmp.read("export/src/legacy/deep/nested.ts") == "export const deep = 1;\n")
    }
}

@Suite struct RetentionTests {
    /// Random histories, random deletions: every retained snapshot must reconstruct exactly as before.
    @Test(arguments: 1...6)
    func pruningPreservesRetainedStates(seed: Int) throws {
        let sb = Sandbox("ret"); defer { sb.cleanup() }
        var rng = SplitMix(seed: UInt64(seed))
        let store = try sb.store()
        var snaps: [SnapshotInfo] = []
        for step in 0..<40 {
            for _ in 0..<(1 + Int(rng.next() % 4)) {
                let f = "f\(rng.next() % 12).txt"
                switch rng.next() % 4 {
                case 0: try? FileManager.default.removeItem(atPath: sb.root + "/" + f)
                default: sb.write(f, "step \(step) \(rng.next() % 3)\n")
                }
            }
            if case .created(let s, _) = store.snapshot(SnapshotRequest(trigger: .manual)) { snaps.append(s) }
        }
        for s in snaps where rng.next() % 5 == 0 { try store.pin(s.id) }
        var before: [Int64: [String: Int64]] = [:]
        for s in snaps { before[s.seq] = try store.state(atSeq: s.seq).mapValues(\.id) }
        let report = try store.prune(policy: RetentionPolicy(maxAgeDays: 0, keepNewest: 3), nowMs: Clock.nowMsInt() + 1000)
        let kept = try store.list(limit: 1000)
        #expect(report.deletedSnapshots == snaps.count - kept.count)
        #expect(kept.count >= 3)
        for s in kept {
            #expect(try store.state(atSeq: s.seq).mapValues(\.id) == before[s.seq], "state of seq \(s.seq) changed")
            for (_, item) in try store.state(atSeq: s.seq) where item.kind == 0 {
                #expect(FileManager.default.fileExists(atPath: store.objectPath(item.id)))
            }
        }
        // Restoring the oldest retained snapshot still works byte-for-byte.
        if let oldest = kept.last {
            _ = try store.restore(to: oldest.id, scope: .root)
            let state = try store.state(atSeq: oldest.seq)
            for (p, item) in state where item.kind == 0 {
                #expect(Hashing.sha256(fileAtPath: sb.root + "/" + p) == item.hash)
            }
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
