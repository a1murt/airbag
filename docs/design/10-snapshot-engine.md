# 10 — Snapshot engine (final)

Status: authoritative. Date: 2026-10-18. Supersedes the git-store proposal in research 06 §"recommended sequence" as
the *primary* engine and simplifies proposal 10B (APFS clone farm). Inputs: research 04 (platform), 06 (git mechanics,
measured), 05 (competitors), proposal 10B (measured clone costs), design 11 (registry, hook budgets).

## 0. Decision

A snapshot is the set of files that changed since the previous snapshot of the same root, each captured as an
immutable APFS clone (`copyfile(…, COPYFILE_CLONE)`, which silently falls back to a byte copy when cloning is
impossible), plus rows in a per-root SQLite manifest. History is a **log of per-path changes**; the state of any
snapshot is "for every path, the latest change with `seq ≤ S`". No checkpoints, no git dependency.

Why not the external git store (research 06): it needs a real git binary (on a Mac without Command Line Tools
`/usr/bin/git` pops the CLT install dialog; our semi-technical persona often has no CLT), costs a process spawn per
step (~140 ms no-change snapshot per 20k files, 7 s first snapshot), leaves loose objects at 4 KiB each until repack,
and its restore path (`checkout`/`restore`, force=1) deletes whole directories on file/dir type conflicts. Measured
clone costs (10B §6.1) beat it on every hot-path number: no-change 74–79 ms at 50k files and 9–22 ms at 5k,
100 changed files 85–91 ms / 17 ms, restore of 100 files 19–24 ms, and large binaries cost zero bytes.

Accepted costs (and their mitigations): no delta compression (budget-based retention), clones pin disk blocks
(free-space floor + emergency prune), the manifest is the only path→object map (WAL, transactional, daily
`VACUUM INTO` backup, objects carry an xattr breadcrumb with their path), store not inspectable with stock tools
(`airbag snapshots|diff|export` subcommands).

## 1. Units and identity

- **Root**: a directory tree we snapshot independently — a plain project folder, a git main worktree, or any git
  worktree (agent worktrees included). Projects in the registry (11 §2) group roots by git common dir.
- `root_id` = first 16 bytes of SHA-256 of the canonical root path (`F_GETPATH` on an fd of the root), hex.
- One **store** per root: `~/Library/Application Support/Airbag/stores.noindex/<root_id>/`.

## 2. On-disk layout

```
~/Library/Application Support/Airbag/            0700
└── stores.noindex/                              0700  (.noindex → Spotlight skips; isExcludedFromBackup = true)
    └── <root_id>/                               0700
        ├── store.json                           0600  {schema:1, root, dev, ino, created_at, mode:"clone"|"copy"}
        ├── lock                                 0600  flock(2): one writer (snapshot / restore / prune) at a time
        ├── manifest.sqlite (+wal,+shm)          0600  §3
        ├── objects/<hh>/<object_id>             clones keep the source mode; buckets 0700; 256-way fan-out by id
        ├── aside/<restore_id>/<relpath>         0700  things a restore moved out of the way (never deleted by restore)
        └── tmp/                                 0700  in-flight clones; emptied at every lock acquisition
```

Object ids are random 64-bit integers rendered as 16 hex chars (the SQLite `items.id`). Captures are cloned
straight into `objects/` (no temp + rename: the rename cost 24 % of a first snapshot in profiling); an object
without an `items` row after a crash is swept by prune. Mode bits live in the manifest.

Each object gets the xattr `dev.airbag.path` = relative path at capture time (breadcrumb for disaster recovery).

## 3. Manifest schema (per store)

```sql
PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF; PRAGMA application_id=0x41425347;
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;           -- schema, root, created_at
CREATE TABLE snapshots (
  seq           INTEGER PRIMARY KEY,         -- strictly increasing per store
  id            TEXT NOT NULL UNIQUE,        -- ULID, same id as registry.snapshots.id
  created_at    INTEGER NOT NULL,            -- ms since epoch
  trigger       TEXT NOT NULL,               -- pre_command|post_command|fsevents|manual|pre_restore|post_restore|initial
  label         TEXT,                        -- 'Before `rm -rf src/legacy`' (redacted)
  session_key   TEXT,                        -- '<agent>:<agent_session_id>' or NULL
  file_count    INTEGER NOT NULL,            -- files present in this snapshot's state
  changed_count INTEGER NOT NULL,            -- rows in `changes` with this seq
  bytes_added   INTEGER NOT NULL,            -- logical bytes of new objects
  pinned        INTEGER NOT NULL DEFAULT 0,  -- user "last known good" / keep
  complete      INTEGER NOT NULL DEFAULT 1   -- 0 when the walk hit its deadline (§4.6)
) STRICT;
CREATE TABLE items (
  id        INTEGER PRIMARY KEY,             -- object id (also file name)
  kind      INTEGER NOT NULL,                -- 0 regular file, 1 symlink
  size      INTEGER NOT NULL,
  mode      INTEGER NOT NULL,                -- st_mode & 07777 (setuid/setgid stripped)
  hash      BLOB,                            -- SHA-256 for files ≤ 8 MiB, NULL above (or lazily filled)
  target    TEXT                             -- symlink target (kind 1); no object file
) STRICT;
CREATE INDEX items_hash ON items(hash, size) WHERE hash IS NOT NULL;
CREATE TABLE changes (                       -- the history log
  path  TEXT NOT NULL,                       -- root-relative, '/'-separated, NFC as returned by the FS
  seq   INTEGER NOT NULL,
  item  INTEGER,                             -- NULL = path absent from this snapshot on (tombstone)
  PRIMARY KEY (path, seq)
) STRICT, WITHOUT ROWID;
CREATE INDEX changes_seq  ON changes(seq);
CREATE INDEX changes_item ON changes(item) WHERE item IS NOT NULL;
CREATE TABLE current (                       -- live-state cache = state of the latest snapshot + stat keys
  path TEXT PRIMARY KEY, item INTEGER NOT NULL,
  size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, ctime_ns INTEGER NOT NULL, ino INTEGER NOT NULL, mode INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
```

Queries:
- state of path P at S: `SELECT item FROM changes WHERE path=? AND seq<=? ORDER BY seq DESC LIMIT 1`.
- full state at S: `SELECT path, item FROM changes c WHERE seq=(SELECT max(seq) FROM changes WHERE path=c.path AND seq<=?1) AND item IS NOT NULL` (correlated PK seek per path).
- paths touched in (A, B]: `SELECT DISTINCT path FROM changes WHERE seq>?A AND seq<=?B` then state at A and B for each.

## 4. Snapshot algorithm

Inputs: root, trigger, label, session_key, deadline (hook: soft 1500 ms), force flag.

1. **Lock.** `flock(lock, LOCK_EX|LOCK_NB)` retried every 10 ms until the deadline; on timeout return `.busy` (the
   caller logs `snapshot_skipped`). Empty `tmp/`.
2. **Free-space guard.** `statfs` on the store volume. Below `max(2 GiB, 2 %)` free: run emergency prune (§7) and skip
   files > 1 MiB; below 1 GiB free: return `.lowDisk` without snapshotting.
3. **Walk** the root with `fts(3)` (`FTS_PHYSICAL|FTS_NOCHDIR|FTS_XDEV`), pruning excluded directory names (§5) and
   collecting `(relpath, lstat)` for regular files and symlinks. Files above the size cap are recorded as
   `skipped_large` (never tombstoned). Other types (fifo, socket, device) are ignored.
4. **Compare** each entry with `current` on `(size, mtime_ns, ctime_ns, ino, mode)`. Equal → unchanged.
5. **Capture** each candidate: `clonefile(src, objects/<hh>/<id>, CLONE_NOFOLLOW|CLONE_NOOWNERCOPY)` when root and
   store share a volume, else `copyfile(COPYFILE_DATA|COPYFILE_STAT)`; `lstat` the result. Hash the *captured
   object* (stable bytes) when ≤ 8 MiB — except in the `initial` snapshot, which skips hashing (halves its cost);
   when a later snapshot sees a changed stat key on an unhashed item of equal size, it hashes the old object then
   and backfills `items.hash`, so `touch`-style no-op rewrites still deduplicate. If `hash` and `mode` equal the current item → content unchanged: update the stat keys in
   `current`, delete the temp object. Otherwise look up `items_hash` for dedup (identical content captured earlier →
   reuse that item, unlink the new clone), else keep it and set the breadcrumb xattr.
   Symlinks become `kind=1` items with `target`.
6. **Tombstones.** For every path in `current` not seen in the walk: `lstat` it. `ENOENT`/`ENOTDIR` → tombstone.
   Exists (now excluded, over the cap, or a type we ignore) → drop it from `current` silently, no tombstone.
7. **Commit** in one `BEGIN IMMEDIATE` transaction: insert `snapshots` row, `changes` rows, `items`, update `current`.
   If there are zero changes and `force` is false: do not create a snapshot; return `.unchanged(latestId)`.
8. Unlock. Return `SnapshotResult {id, seq, changed, filesTotal, bytesAdded, durationMs, complete}`.

Crash safety: objects reach `objects/` before the transaction commits; an object without an `items` row is garbage
swept at the next prune. A crash before commit loses only that snapshot.

### 4.6 Deadlines and the first snapshot

The first snapshot of a 50k-file root takes ~5 s (10B §6.1), longer than the hook budget. Rule: the hook never runs
an initial snapshot inline. When the store is missing, the hook spawns `airbag snapshot --initial <root>` detached
(`posix_spawn` + `setsid`), returns immediately, and subsequent hooks that fail to get the lock skip (`.busy`).
The app also runs initial snapshots when a project is added. If a non-initial walk exceeds its deadline, the
snapshot is committed with `complete=0` covering the files captured so far; whole-root restore to an incomplete
snapshot never removes files (§6).

## 5. What is captured

- Excluded directory names anywhere in the tree (built-in, user-extendable per project): `.git`, `.hg`, `.svn`,
  `node_modules`, `.next`, `.nuxt`, `.svelte-kit`, `.turbo`, `.parcel-cache`, `.vite`, `dist`, `build`, `out`,
  `target`, `.build`, `DerivedData`, `Pods`, `.gradle`, `.venv`, `venv`, `__pycache__`, `.pytest_cache`,
  `.mypy_cache`, `.ruff_cache`, `.tox`, `.cache`, `coverage`, `.nyc_output`, `.terraform`, `.serverless`,
  `.vercel`, `.netlify`, `.expo`, `.dart_tool`, `.idea/caches`, `.claude/worktrees` (each worktree is its own root).
- Excluded file names: `.DS_Store` only (editor swap files are short-lived and cheap to capture).
- The project's `.gitignore` is deliberately **not** honoured: `.env`, local databases and other ignored-but-precious
  files are exactly what agents destroy.
- Size cap: 100 MiB per file in clone mode, 20 MiB in copy mode.
- Nested git repositories: their `.git` is excluded like any `.git`; their working files are captured as ordinary
  files (the git-gitlink problem from research 06 does not exist here).
- Roots that are never snapshotted (ADR-032): the home folder and its standard top-level folders themselves, and
  everything inside app bundles (`/Applications`, `~/Applications`), `/Library`, `/usr`, `/private/var` (per-user
  temporary folders included), `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.Trash` and the data folders of `~/Library`
  (Caches, Containers, Group Containers, Mail, Messages, Safari, Logs, Preferences, Developer, …).
- A root that is neither a git checkout nor the agent's launch folder is snapshotted only while it holds at most
  5,000 files and 500 MB (`SnapshotLimits.folder`): a larger one never gets a store, and a store created under the cap
  keeps it (stored in `meta`), so the app and background snapshots stop when the folder outgrows it. Restores ignore
  the cap.

## 6. Restore

`restore(snapshot S, scope)` with scope = `.paths([relpath])` (file or folder prefixes) or `.root`.

1. Take a `pre_restore` snapshot (forced) — it is the undo point. Hold the lock for the whole restore.
2. Compute the target set: for `.paths`, every path at or under the given prefixes that exists in S or in the
   pre-restore state; for `.root`, every path present in S or in the pre-restore state.
3. For each path whose S-state differs from the pre-restore state:
   - **S has an item**: ensure parent directories exist; a non-directory standing where a parent directory must be is
     moved to `aside/`. If a *directory* stands at the target path, it is moved to `aside/` (never removed — this is
     the git `remove_subtree` hazard from research 06). Materialise: `copyfile(object, <dir>/.airbag-tmp-<id>,
     COPYFILE_CLONE)`, `chmod` to the recorded mode, `rename` over the target (atomic).
   - **S has no item** (path did not exist at S): only if the current file is the one captured by the pre-restore
     snapshot (stat keys equal `current`) — and S is `complete` — move it to `aside/<restore_id>/`. Anything Airbag
     never captured (excluded, oversized, ignored types) is never touched.
   - **Concurrent writer**: if a file's stat keys changed between the pre-restore snapshot and the moment we replace
     it, skip it and report `conflict` (the agent is still writing — the UI tells the user to stop the agent).
4. Take a `post_restore` snapshot labelled "Restored to <label>". Return `RestoreReport {restored, movedAside,
   conflicts, skipped, undoSnapshotId}`.

Restore of a deleted folder = `.paths(["src/legacy"])` against the snapshot before the deleting command.

## 7. Retention

Defaults: keep every snapshot younger than 7 days but at most the newest 200 unpinned ones per root, the newest 20
per root whatever their age, and all pinned ones; global budget
5 GiB of object bytes across stores (logical size; clone-shared blocks make this an upper bound). Over budget, the
oldest unpinned snapshots beyond the newest 20 go first, across all stores. Prune runs in the app hourly and in the
CLI after every 50th snapshot.

Deleting a set D of snapshots, with K = retained seqs:
```sql
-- a change in a deleted snapshot is redundant if the same path changes again before the next retained snapshot
DELETE FROM changes AS c WHERE c.seq IN (SELECT seq FROM del) AND EXISTS (
  SELECT 1 FROM changes c2 WHERE c2.path=c.path AND c2.seq>c.seq
    AND c2.seq <= (SELECT min(seq) FROM keep WHERE seq > c.seq));
DELETE FROM snapshots WHERE seq IN (SELECT seq FROM del);
DELETE FROM items WHERE id NOT IN (SELECT item FROM changes WHERE item IS NOT NULL)
                    AND id NOT IN (SELECT item FROM current);
```
then unlink object files whose ids are no longer in `items`, sweep `objects/` for files without rows, and
`VACUUM INTO manifest.sqlite.bak` once a day. Surviving changes of deleted snapshots keep their seq; queries use
`seq ≤ S` so retained states are unchanged (proved by the retention property test).

## 8. Diff

- File list between snapshots A < B, or between snapshot A and the live tree (live = a dry-run walk compared with
  the state at A, no capture): statuses `added`, `modified`, `deleted`, `typeChanged`.
- Text diff of one file: unified diff computed in Swift (Myers, line-based) for files ≤ 2 MiB that decode as UTF-8;
  otherwise "binary file changed (old size → new size)".

## 9. Public API (module `AirbagCore`, namespace `Snapshots`)

```swift
public struct SnapshotRoot: Hashable, Sendable { public let path: String; public let id: String }
public enum SnapshotTrigger: String, Sendable { case preCommand = "pre_command", postCommand = "post_command",
  fsevents, manual, preRestore = "pre_restore", postRestore = "post_restore", initial }
public struct SnapshotRequest: Sendable { root, trigger, label: String?, sessionKey: String?, deadline: Duration?, force: Bool }
public enum SnapshotOutcome: Sendable { case created(SnapshotInfo), unchanged(latest: SnapshotInfo?), busy, lowDisk, failed(String) }
public struct SnapshotInfo: Sendable, Identifiable { id, seq, createdAt, trigger, label, sessionKey, fileCount, changedCount, bytesAdded, pinned, complete }
public enum ChangeStatus: String, Sendable { case added, modified, deleted, typeChanged }
public struct FileChange: Sendable { path, status, oldSize: Int64?, newSize: Int64? }
public enum RestoreScope: Sendable { case paths([String]), root }
public struct RestoreReport: Sendable { restored, movedAside, conflicts, skipped: [String]; undoSnapshotId: String?; asideDir: String? }
public final class SnapshotStore {               // one per root; not thread-safe, cross-process safe via flock
  public static func open(root: String, storesDir: URL = Paths.stores) throws -> SnapshotStore
  public func snapshot(_ r: SnapshotRequest) -> SnapshotOutcome
  public func list(limit: Int, before: Int64?) throws -> [SnapshotInfo]
  public func changes(in snapshotId: String) throws -> [FileChange]          // vs previous snapshot
  public func diff(from: String, to: String?) throws -> [FileChange]          // to=nil → live tree
  public func fileDiff(path: String, from: String, to: String?) throws -> TextDiff
  public func restore(to snapshotId: String, scope: RestoreScope) throws -> RestoreReport
  public func pin(_ id: String, _ on: Bool) throws
  public func prune(policy: RetentionPolicy, now: Date) throws -> PruneReport
  public func usage() throws -> StoreUsage                                    // objects, bytes, snapshots
}
```

## 10. Test matrix (Swift Testing, synthetic roots under the test's temp dir)

Unit: walker exclusions and caps; compare keys; dedup by hash; tombstone vs dropped; retention SQL property test
(random histories, random deletions, every retained state identical before/after); diff statuses; Myers diff.
Integration ("destructive agent" scripts from the market report, each followed by restore and a byte-for-byte tree
compare against a reference copy): `rm -rf src`, `mv src /tmp/x`, `sed -i '' s/a/b/ **/*.ts`, `git checkout -- .`,
`git reset --hard`, `git clean -fdx` (restores `.env` and untracked files), file↔directory type swap, symlink
retarget, exec bit flip, unicode and space names, concurrent writer during restore (conflict reported), restore
undo via `undoSnapshotId`. Performance (release build): 5k-file no-change snapshot < 50 ms, 100 changed < 80 ms.

## 11. Measured (release build, M4 Mac, 2026-10-18)

| Operation | 5k files (48 MB) | 50k files (388 MB) |
|---|---|---|
| First snapshot (detached, not on the hook path) | 0.74 s | 9.3 s |
| No-change snapshot | 9–11 ms | 116–184 ms |
| 100 changed files | 47 ms | 164 ms |
| `touch` on 100 files (dedup, no snapshot) | 57 ms | 184 ms |
| Restore 100 files incl. pre/post snapshots and process start | 60 ms | 410 ms |
