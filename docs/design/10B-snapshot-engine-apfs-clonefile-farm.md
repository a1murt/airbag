# 10B — Snapshot engine, option B: APFS clone farm with a SQLite manifest

Date: 2026-10-17. Author role: advocate for the APFS copy-on-write design, honest about its limits. Status: design proposal for review against 10A (external git store) and 10C (content-addressed store). Inputs: research notes 04 (macOS platform), 05 (competitors), 06 (git snapshot mechanics), design docs 11 (registry/hook bridge, whose `SnapshotEngine` protocol this document implements) and 13 (product spec), plus the measurements in §6 and §11, taken today on macOS 15.7.9 (24G830) / Apple M4 / 16 GB / APFS Data volume (4 KiB blocks, SSD, case-insensitive) with C and Swift 6.1.2 probes built with Command Line Tools only. Other subagents were benchmarking on the same machine at the time; where two runs disagree both numbers are given. Tags: [verified] = primary source read or measured today; [likely] = strong inference or secondary source; [unverified] = not confirmed; [estimate] = derived number.

## 0. Thesis and decisions

A snapshot is not a copy and not a commit: it is a set of `clonefile(2)` clones of the files that changed since the previous snapshot, plus rows in a per-project SQLite manifest that say which clone stands for which path. APFS clones share data blocks with the live file until either side is modified, so a clone costs ~90–100 µs of metadata and zero bytes of data regardless of file size (512 MiB cloned in 0.155 ms [verified]); the manifest's stat cache makes a no-change snapshot of 50,004 files / 1.98 GB cost 74–79 ms end-to-end, 100 changed files 85–91 ms, the *first* snapshot 5.2 s file-by-file or 0.5–1.2 s as one directory clone — numbers git cannot reach because git must hash, zlib and write one loose object per file (06 §3: 6.5–7.5 s per 20k files). Restores are clones in the other direction (170–250 µs per file, 100 files in 24 ms). Diffs come from the manifest (1–40 ms between any two snapshots, 60–130 ms live vs snapshot at 50k files). Nothing in the design needs a git binary, a Command Line Tools install, or a third-party dependency; everything is `import Darwin`, `import SQLite3`, `import CryptoKit`.

Decisions this document makes (details in the numbered sections):

1. One store per project (git common dir or plain folder, per 11 §2), located **on the same volume as the project** because `clonefile` returns `EXDEV` across volumes [verified]. Boot volume: `~/Library/Application Support/Airbag/stores.noindex/<project-id>/`; other APFS volumes: `<mount>/.airbag/<uid>/stores.noindex/<project-id>/`; non-APFS volumes: copy mode (same code path, `copyfile` instead of `clonefile`, flagged in the UI).
2. Items (file versions) are immutable clones named by a per-store sequence id, never by path; unchanged files are represented by manifest rows that point at the same item — zero syscalls. **Hard links are not used**: on this machine `link(2)` costs 223 µs versus 89 µs for `clonefile` and 0 µs for a manifest row [verified], and a hard link between the farm and the live tree would let in-place writes corrupt history.
3. Per-file SHA-256 is computed inline for changed files ≤ 4 MiB and lazily (app, background) for larger ones; a `UNIQUE(hash,size)` index dedupes identical content across snapshots, paths and worktrees, so a formatter that rewrites 500 files with identical bytes produces zero new items and an empty changeset.
4. Snapshots are stored as **changesets** against the previous snapshot of the same worktree plus a `current` table (the live state as of the last snapshot) and periodic full **checkpoints**; a week of heavy use (1,400 snapshots × 100 changes) is 27 MiB of manifest and diffs stay in single-digit milliseconds [verified, §4].
5. Restore = clone item to `<path>.airbag-restore-<ulid>` + atomic `rename`; whole-project restore follows a pre-restore snapshot and never removes a path that the pre-restore snapshot did not capture; anything that would be removed but was not captured is moved aside into the store, not deleted.
6. Retention = delete snapshot rows older than 7 days / beyond 5 GiB of *private* bytes (`ATTR_CMNEXT_PRIVATESIZE`, the bytes a deletion would actually free [verified]), always keeping the newest 20 per project and pinned snapshots; unreferenced items are unlinked (37 µs each). Retention boundaries are checkpoints, so every retained snapshot stays reconstructible.
7. Cold path: when a hook meets a project with no store, it clones the whole project directory in one syscall (0.47–1.09 s for 55k entries incl. `node_modules` [verified]) and lets the app convert the tree into items later. No other design can take a usable first snapshot inside a hook deadline.
8. Honest limits accepted: no delta compression (text churn costs full old versions: ~0.8 GB/day worst case on the 50k project [estimate]); `du`/Finder double-count the store; clones pin blocks so a full disk hurts the agent's `fsync` (reproduced [verified]), which forces a free-space floor; the manifest is the only path→item map (mitigated with xattr breadcrumbs and daily backups); same-volume only.

## 1. On-disk layout

### 1.1 Where the store lives

```
~/Library/Application Support/Airbag/                     drwx------   (umask 077; re-chmod 0700 at every launch)
├── registry.sqlite (+ -wal, -shm)                        -rw-------   global registry (11 §3): projects, sessions, events, snapshot headers
├── airbag.sock                                           srw-------   wake-up socket (11 §5)
└── stores.noindex/                                       drwx------   Time Machine sticky exclusion + Spotlight .noindex (§7)
    └── <project-id>/                                     drwx------   one store per project (ULID from the registry, not a path hash)
        ├── store.json                                    0600  schema, canonical project path, (st_dev, st_ino) of the root, volume UUID, mode (clone|copy), created
        ├── lock                                          0600  flock(2) for writers (snapshot, restore, retention, conversion)
        ├── manifest.sqlite (+ -wal, -shm)                0600  per-project manifest (§1.3); WAL; `application_id` 'ABSN'
        ├── manifest.sqlite.bak                           0600  daily `VACUUM INTO` copy (§8.2)
        ├── items/<hh>/<16 hex id>                        mode copied from the source file; dirs 0700; immutable clones, 256-way fan-out
        ├── trees/<ulid>/                                 0700  whole-directory clones: cold-path snapshots awaiting conversion, optional `.git` safety clones (§2.9)
        ├── aside/<restore-ulid>/<relative path>          0700  files/dirs moved out of the way by a restore (§3.3), subject to retention
        └── views/<ulid>/                                 0700  temporary materialised snapshot trees (clones), deleted on close/launch (§4.4)
```

Facts behind the layout:

- `clonefile(2)`: "src and dst must be on the same filesystem" (`EXDEV` otherwise) and "Not all volumes support clonefile()" — check `VOL_CAP_INT_CLONE` in `ATTR_VOL_CAPABILITIES` [verified: man page; probe: Data volume and a temporary APFS image both report `VOL_CAP_INT_CLONE=1`, a clone from the Data volume into the image failed with `errno=18 EXDEV`]. Therefore the store root is chosen per volume: `statfs(project).f_fsid`/`st_dev` equal to the boot Data volume → the `~/Library` root above; another APFS volume with the clone capability → `<mountpoint>/.airbag/<uid>/stores.noindex/` created 0700 (the volume root is writable for the owner on user-formatted volumes; if not, copy mode on the boot volume); no clone capability (HFS+, exFAT, SMB) → copy mode on the boot volume, where `fclonefileat` is replaced by `copyfile(COPYFILE_DATA|COPYFILE_STAT|COPYFILE_XATTR|COPYFILE_NOFOLLOW_SRC)` and everything else is unchanged. `store.json.mode` records it; the UI shows "copy mode (slower, uses real disk space)" per project.
- `~/Library/Application Support` is outside the Desktop/Documents/Downloads consent prompts and outside iCloud Drive's inclusion set (iCloud syncs the iCloud Drive folder and, optionally, Desktop & Documents) [verified for TCC: 06 §12; iCloud model [likely]: Apple support "Add your Desktop and Documents files to iCloud Drive", not re-fetched today]. It is inside Time Machine's default set, hence the sticky exclusion in §7.
- The `.noindex` directory suffix keeps Spotlight from indexing the subtree [likely: eclecticlight 2025-06-16 lists the dot-prefix and `.noindex` as the two methods that still work and says the empty `.metadata_never_index` file "no longer works in recent macOS"; the tokens `.metadata_never_index` and `.metadata_never_index_unless_rootfs` are nevertheless still present as strings in `/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds` on 15.7.9 [verified], so the marker file is written too as belt and braces]. Items carry no extension, so no text importer would match them even if indexed [likely].
- Items keep the source file's mode (`clonefile` gives the clone "its own copy of attributes and extended attributes" identical to the source, except that "setuid and setgid bits are turned off" [verified: man page; probe: mode 0640, mtime with nanoseconds and a custom xattr survived cloning]). A 0644 item is still unreachable by other users because every ancestor is 0700.
- The store is self-describing enough to survive a lost registry (`store.json` + `manifest.sqlite`), and the registry is enough to find stores (`projects.store_path`, 11 §3.2). A lost *manifest* is the weak point; §8.2 covers it.

### 1.2 Project identity

Identity is the registry's: project = canonical path of the git common dir (or the folder) via `fcntl(F_GETPATH)` on an open directory fd, which resolves symlinks, `/tmp` → `/private/tmp`, firmlinks and on-disk letter case (06 §12 [verified]; re-confirmed today: `open("…/P5K/SCRIPTS")` + `F_GETPATH` → `…/p5k/scripts`). The store directory is named by the project's ULID, so a project rename or move within the volume changes nothing in the store (items never contain paths; `store.json` keeps the last canonical path for `airbag doctor`). Worktrees of one repository share one store (11 §7.3): `current`, `snapshots` and `changes` rows carry a `worktree_id`, items are shared and deduplicated by hash across worktrees, which is where worktrees pay off (a new worktree's first snapshot clones everything, then background hashing collapses identical items — §2.5).

### 1.3 Manifest schema (SQLite, WAL, one file per store)

```sql
PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=300 /* CLI */ | 5000 /* app */; PRAGMA foreign_keys=ON;

CREATE TABLE meta(key TEXT PRIMARY KEY, value) WITHOUT ROWID;           -- schema=1, next_item_id, project_path, volume_uuid, mode

CREATE TABLE items(                                                      -- one row per stored file version (or symlink target)
  id          INTEGER PRIMARY KEY,                                       -- also the file name under items/<id & 0xff>/<%016x>
  kind        INTEGER NOT NULL,                                          -- 0 file, 1 symlink (no farm file; target in link_target), 2 encrypted secret (§7)
  size        INTEGER NOT NULL,
  hash        BLOB,                                                      -- SHA-256; NULL until hashed (inline ≤ 4 MiB, else background)
  link_target BLOB,
  created_at  INTEGER NOT NULL,                                          -- unix ms
  flags       INTEGER NOT NULL DEFAULT 0                                 -- 1 racy (stat key unreliable, re-examine), 2 missing (file lost, §8.2)
);
CREATE UNIQUE INDEX items_hash ON items(hash, size) WHERE hash IS NOT NULL;

CREATE TABLE snapshots(
  seq           INTEGER PRIMARY KEY,                                     -- store-wide monotonic
  id            TEXT NOT NULL UNIQUE,                                    -- ULID, mirrored into registry.snapshots.id (11 §3.2)
  worktree_id   TEXT NOT NULL,
  prev_seq      INTEGER,                                                 -- previous snapshot of the same worktree
  created_at    INTEGER NOT NULL,
  trigger       TEXT NOT NULL,                                           -- pre_command|post_command|fsevents|manual|pre_restore|post_restore|project_added|cold
  session_id    TEXT, event_id TEXT, label TEXT,                         -- redacted command (11 §9)
  file_count    INTEGER NOT NULL, byte_count INTEGER NOT NULL,
  added INTEGER NOT NULL, modified INTEGER NOT NULL, deleted INTEGER NOT NULL, retyped INTEGER NOT NULL,
  skipped       TEXT,                                                    -- JSON: [{path, reason: size|unreadable|dataless|special, size}]
  pinned        INTEGER NOT NULL DEFAULT 0,
  is_checkpoint INTEGER NOT NULL DEFAULT 0,                              -- full state present in `checkpoints`
  private_bytes INTEGER                                                  -- cached PRIVATESIZE sum of items first referenced here (§1.4)
);
CREATE INDEX snapshots_wt ON snapshots(worktree_id, seq);

CREATE TABLE changes(                                                    -- the snapshot's delta against prev_seq
  seq       INTEGER NOT NULL REFERENCES snapshots(seq) ON DELETE CASCADE,
  path      BLOB NOT NULL,                                               -- bytes as found on disk (NFC/NFD preserved), relative to the worktree root
  op        INTEGER NOT NULL,                                            -- 0 A added, 1 M modified, 2 D deleted, 3 T type changed (file<->symlink)
  item      INTEGER REFERENCES items(id),                                -- NULL for D
  prev_item INTEGER REFERENCES items(id),                                -- NULL for A; the item at prev_seq (makes A..B diffs O(changes))
  mode      INTEGER, size INTEGER, mtime_ns INTEGER,
  PRIMARY KEY(seq, path)
) WITHOUT ROWID;
CREATE INDEX changes_path ON changes(path, seq);
CREATE INDEX changes_item ON changes(item); CREATE INDEX changes_prev ON changes(prev_item);

CREATE TABLE current(                                                    -- live state as of the latest snapshot = the stat cache
  worktree_id TEXT NOT NULL, path BLOB NOT NULL,
  item INTEGER NOT NULL REFERENCES items(id),
  mode INTEGER NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, ctime_ns INTEGER NOT NULL, ino INTEGER NOT NULL,
  PRIMARY KEY(worktree_id, path)
) WITHOUT ROWID;

CREATE TABLE checkpoints(                                                -- full state of a snapshot; every K-th snapshot, every retention boundary, every pinned snapshot
  seq INTEGER NOT NULL REFERENCES snapshots(seq) ON DELETE CASCADE,
  path BLOB NOT NULL, item INTEGER NOT NULL REFERENCES items(id), mode INTEGER NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
  PRIMARY KEY(seq, path)
) WITHOUT ROWID;
CREATE INDEX checkpoints_item ON checkpoints(item);

CREATE TABLE restores(                                                   -- journal (§3.5)
  id TEXT PRIMARY KEY, worktree_id TEXT NOT NULL, scope TEXT NOT NULL, prefix BLOB,
  target_seq INTEGER NOT NULL, pre_seq INTEGER, post_seq INTEGER,
  state TEXT NOT NULL,                                                   -- planned|applying|verifying|done|failed|abandoned
  plan BLOB NOT NULL,                                                    -- JSON: writes[], removes[], asides[], untouched_count
  started_at INTEGER, finished_at INTEGER, error TEXT
) WITHOUT ROWID;
```

Why these shapes: `WITHOUT ROWID` tables are "likely to be helpful for tables that have non-integer or composite (multi-column) PRIMARY KEYs and that do not store large strings or BLOBs" and rows should stay under "about 200 bytes each for 4KiB page size" [verified: sqlite.org/withoutrowid]; a `changes` row is ~100 bytes (measured 203 bytes per change including its `items` row, §6). The system SQLite is 3.43.2 with `THREADSAFE=2`, FTS5, JSON, `STRICT`, `RETURNING` (04 §8, 11 §3.1 [verified]). Paths are `BLOB` so byte-exact names round-trip (APFS "preserves both case and normalization of the filename on disk" and is "normalization-insensitive" [verified: APFS Guide FAQ]).

Registry coupling (11 §3.2): `registry.snapshots` keeps one header row per snapshot (`id`, `project_id`, `worktree_id`, `trigger`, `event_id`, counts, `pinned`, `deleted_at`); the 11 §10.5 `SnapshotRecord.commitOID`/`treeOID` become `storeSeq` and an optional `rootHash` (computed only for pinned snapshots and exports; a Merkle root of 50k entries costs 30 ms, §6), which is the one interface tweak this design asks of 11.

### 1.4 Size accounting

- `du`, Finder and most disk tools count a clone's shared blocks again: the 50k-item farm reports **2.1 GB in `du`** while creating it moved free space by **11.67 MB** [verified]. Every number Airbag shows must therefore come from one of two sources: (a) `statfs` free-space deltas around an operation (cheap, noisy on a live machine — a concurrent download made one delta negative today), or (b) `getattrlist(ATTR_CMNEXT_PRIVATESIZE)` per item: "the number of bytes that are not trapped inside a clone or snapshot and which would be freed immediately if the file were deleted" [verified: getattrlist(2)]. A sweep of 51,194 items took 706 ms and reported 39.16 MB private (= the ~1,190 files the probes had rewritten), 10,204 items in 116 ms [verified]. Semantics probed on a 64 MiB file: right after cloning both files report `privsize=0`, `refcnt=2`, `extflags=0x41` (`EF_MAY_SHARE_BLOCKS|EF_SHARES_ALL_BLOCKS`); after a 1 MiB in-place write to the original both report `privsize=1,048,576` and the original gets a new `cloneid`; after a full rewrite both report 64 MiB [verified].
- The app runs the sweep per store once an hour at utility QoS (and after retention), caches `items.private_bytes` by item, and writes `snapshots.private_bytes` = Σ over items first referenced by that snapshot. The UI shows per project: *private* bytes ("what deleting all snapshots would free"), *logical* bytes (Σ sizes), item count, snapshot count, oldest snapshot, bytes skipped by cap; globally: private total vs the 5 GiB budget, with the sentence `settings.storage.du_note` ("Finder and du count shared blocks twice; this number is what you would actually get back").
- Metadata cost per clone: 233–445 B of allocated metadata per item (11.67 MB / 50,004; 2.13 MB / 5,004 [verified: free-space deltas]), plus ~100 B per `changes` row and ~100 B per `items` row.

## 2. Snapshot algorithm

### 2.1 Triggers (who runs it, with what budget)

| Trigger | Runner | Input | Budget | Notes |
|---|---|---|---|---|
| `pre_command` | `airbag` hook (CLI) | full walk vs `current` | `hook.snapshotDeadlineMs` 1500 (11 §4.2); typical 75 ms at 50k files | runs after rules decided non-deny; result feeds the reply |
| `post_command` | hook, async (Claude `PostToolUse`, Codex async, Cursor `afterShellExecution`) | full walk | 2000 | its changeset *is* "what the command changed" (13 §7.1 pairing) |
| `fsevents` | app | dirty set from FSEvents, 2 s quiet (13 §7.4; 1 s default proposed here since a dirty-set snapshot is ~15 ms) | none | `stat` only dirty paths; full walk every 10 min and on `MustScanSubDirs`/`*Dropped`/UUID mismatch (04 §3) |
| `manual` | app | full walk | none | "Snapshot now" |
| `pre_restore` / `post_restore` | app (or CLI `airbag restore`) | full walk | none | mandatory around every restore (§3) |
| `project_added` | app, background, lowest QoS | full walk, file-by-file clones | none | 5.2 s per 50k files; progress in onboarding (13 §5.5) |
| `cold` | hook, when no store exists | whole-directory clone | watchdog prints the decision at the deadline regardless | §2.8 |

### 2.2 The hot path (hook and app share it; `SnapshotEngine.snapshot(project:worktree:trigger:context:deadline:)`, 11 §10.5)

1. Resolve the worktree root (11 §7.4), open the store, `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)` so that nothing below triggers an iCloud download ("Disables materialization of dataless files by the current thread or process" [verified: getiopolicy_np(3)]; constants present in the SDK's `sys/resource.h` [verified]).
2. `flock(lock, LOCK_EX|LOCK_NB)`; on `EWOULDBLOCK` wait up to `min(deadline − 300 ms, 1 s)` in 20 ms steps, then return `.skipped(.storeLocked)`. The app's FSEvents snapshotter uses `LOCK_NB` and backs off 100 ms so hooks win.
3. Load `current` for the worktree into a hash map keyed by path (50k rows: 5 ms warm, 35 ms cold [verified]).
4. Walk with `fts_open(FTS_PHYSICAL|FTS_NOCHDIR|FTS_XDEV)` (85–96 ms for 50k entries incl. `lstat`, 6.5 ms for 5k [verified]). Rules: prune directories whose *name* is on the deny list at any depth (§2.3); skip anything that is not `S_ISREG` or `S_ISLNK` (FIFOs, sockets, devices → `skipped.special`); skip `st_flags & SF_DATALESS` (→ `skipped.dataless`; header `sys/stat.h` defines `SF_DATALESS 0x40000000` [verified]); skip `st_size > cap` (→ `skipped.size`); keep path bytes verbatim; never descend through a symlink (`FTS_PHYSICAL`); `FTS_XDEV` stops at mount points (a volume mounted inside the project is not the project).
5. Compare each entry with `current` by the stat key `(ino, size, mtime_ns, ctime_ns, mode)`. Equal → reuse the item id, no syscall. Different or new → §2.4. Present in `current` but absent from the walk → `D`.
6. If the changeset is empty: unlock, return `.deduplicated(lastSnapshotID)` — the registry still gets the event ("Before `npm test` — no file changes", 13 §4) but no snapshot row exists.
7. Otherwise one `BEGIN IMMEDIATE`: insert `snapshots`, insert `changes`, upsert/delete `current` rows, bump `meta.next_item_id`, `COMMIT` (100 rows ≈ 3 ms; 1,400 snapshots × 100 changes averaged 2.87 ms per snapshot [verified]). Then the registry header row (separate database, 3–5 ms, 11 §3.1), then unlock, then the socket ping (11 §5).
8. Every `K = 64` snapshots per worktree, or when Σ `changes` rows since the last checkpoint exceeds 2 × `file_count`, the *app* (never the hook) writes a checkpoint: copy `current` into `checkpoints` for that seq (50k rows ≈ 50 ms, ~5 MB).

Deadline handling: the walk and the clone loop check the deadline every 256 entries; on expiry the engine returns `.skipped(.timeout)` without writing any row. Items already cloned become orphans and are collected by the sweep (§5.3). The watchdog in 11 §4.2 remains the hard stop.

### 2.3 Exclusion rules

Built-in deny list (directory *names*, matched at any depth, in the walker and, for the heaviest eight, as FSEvents stream exclusions, 04 §3.1): `.git`, `node_modules`, `.next`, `.nuxt`, `.turbo`, `.cache`, `.parcel-cache`, `dist`, `build`, `out`, `target`, `DerivedData`, `.build`, `.venv`, `venv`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.tox`, `coverage`, `.gradle`, `.terraform`, `Pods`, `.DS_Store` (file), `*.airbag-restore-*` (own temp files). File rules: `*.log` larger than 8 MiB skipped (smaller logs are kept but flagged `noise` so the timeline can hide them); per-file cap **1 GiB** by default (configurable 50 MiB–8 GiB) — far above git's 50 MiB because a clone is O(1) in size; the cost of a large file is only paid when the agent rewrites it wholesale (§6.4). Every skip is recorded in `snapshots.skipped` and surfaced ("never stops silently", 05 §5.7).

The project's `.gitignore` is deliberately **not** honoured: `.env`, `.env.*`, local SQLite databases, `*.pem`, generated-but-valuable files are exactly what the agent destroys and what `/rewind`, takeback, claude-time-machine and keelyard cannot restore (05 §2.1, §6). Users override with per-project excludes in Settings (gitignore-style patterns: `dir/`, `*.ext`, `**/name`; stored in the registry `projects.excludes` and copied into `store.json`) and with the global "Include secrets files" toggle (§7). Changing excludes does not rewrite history; the next snapshot simply drops or adds the paths.

### 2.4 Changed-file processing (the only per-file work)

```
fd = open(path, O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)       -- EACCES/ENOENT → skipped.unreadable / vanished
fstat(fd) → key                                                   -- key is read from the fd that will be cloned
if S_ISLNK (from lstat): target = readlink; item = items(kind=1, link_target); no farm file
elif size ≤ inlineHashCap (4 MiB):
    hash = SHA256(read all)                                       -- CryptoKit 2.6 GB/s in memory; 0.33 GB/s end-to-end on 40 KB files
    if (hash,size) exists in items → item = existing id            -- dedupe: formatter no-ops, reverted edits, worktree twins
    else id = next_item_id++; fclonefileat(fd, itemsDirFd, name(id), 0); insert items(id, 0, size, hash)
else:
    id = next_item_id++; fclonefileat(fd, itemsDirFd, name(id), 0); insert items(id, 0, size, NULL)   -- hashed later by the app
fstat(fd) again; if key changed → items.flags |= racy, current.mtime_ns = 0   -- forces re-examination next time
```

Facts: `fclonefileat` clones from an open descriptor, so there is no path race between stat and clone [verified: clonefile(2) synopsis]; the clone "shares its data blocks with the src file" and later writes are private to the written side [verified: man page; probe: in-place `pwrite` to the original left the clone's content intact, and 256 random 4 KiB page writes into a cloned 512 MiB file cost 4.11 MB — 16 KiB per write, i.e. one Apple-silicon VM page (`hw.pagesize` = 16384 [verified]) rather than one 4 KiB block]. The clone sees the page cache, not only what is on disk: a file written and not yet `fsync`ed cloned with its unsynced bytes [verified], so no flush is needed before snapshotting. Under continuous 4 KiB appends from another thread 60 of 60 clones had a 4 KiB-aligned size and a consistent tail (avg 250 µs per clone) [verified]; the man page states the calls "are expected to be atomic" [verified]. Symlinks are stored as rows only (`clonefile` with `CLONE_NOFOLLOW` can clone a link, verified, but a row is cheaper and restores with `symlink(2)`).

Costs per changed file [verified]: clone 89–102 µs (micro 20k files: 88.8 µs; 50k-file project: 101.6 µs), inline hash ≈ size / 0.33 GB/s (100 files × 25 KB ≈ 8 ms), two SQLite rows ≈ 20 µs. 100 changed files added 10–18 ms to the 50k no-change figure; 990 changed files 100 ms.

### 2.5 Dedup of identical consecutive snapshots and identical content

- Consecutive snapshots: an empty changeset is not stored (§2.2 step 6). Because `current` is the state of the last *stored* snapshot, a "no change" verdict is exact.
- Content: `items_hash` makes identical bytes one item regardless of path, snapshot or worktree. For unhashed large items the app's background hasher (`items WHERE hash IS NULL ORDER BY size`, utility QoS, ≤ 64 MB/s to protect the disk) fills `hash` and, on collision, repoints `changes`/`current`/`checkpoints` rows to the surviving item and unlinks the duplicate — all inside one transaction per item.
- Stat-only ambiguity: a file whose stat key changed but whose hash matched produces no `changes` row and only a `current` key refresh — git's racy-git problem (06 §3.2) handled by content, not by timestamps.

### 2.6 Nested git repositories, submodules, symlinks, special files

- Nested repositories and submodules: their working files are ordinary files to the walker; every `.git` directory *and* `.git` file (worktree/submodule pointer) is skipped by name, so nested working trees are captured and restorable while repository internals are not (same policy as 06 §4 approach D). Optional `.git` safety clones are §2.9.
- Symlinks: rows with the target bytes; never followed; absolute targets preserved; `link-to-dir` is a row, nothing under it is traversed (FTS_PHYSICAL) [verified in the synthetic projects].
- Hard-linked project files (pnpm's `node_modules/.pnpm` is excluded anyway): each path is an independent entry; a clone of one link does not affect the other; restore writes one path at a time. `st_nlink > 1` is recorded so the UI can say "shared with N other paths" [design].
- Case-only renames: the walker sees the new name bytes; the item is reused by hash → `D old` + `A new` collapsed into `R` by the diff presenter (§4.2).
- Empty directories: not tracked (as in git); recorded as a known limitation in the restore plan ("empty folders are left as they are").

### 2.7 Concurrency: CLI and app snapshotting the same store

One `flock` per store serialises writers; SQLite WAL with `BEGIN IMMEDIATE` and `busy_timeout` protects the manifest from the rare case where a reader (the UI listing a timeline) overlaps a writer (04 §8 measured zero `SQLITE_BUSY` under two writers with `busy_timeout=5000`). Items are write-once: a name is taken from `meta.next_item_id` inside the writer's transaction, and the clone is created with `EEXIST` semantics ("The named file dst must not exist for the call to be successful" [verified: man page; probe: second clone onto the same name → `errno=17`]), so two processes can never write the same item. A hook that finds the lock busy for longer than its budget returns `.skipped(.storeLocked)`; the state it would have captured is at most one in-flight snapshot behind, which the UI labels honestly (the event row says "snapshot in progress by Airbag.app"). Readers (timeline, diff, restore planning) never take the flock.

### 2.8 Cold path: a usable first snapshot inside a hook

When the hook meets a protected project whose store has no snapshot yet (fresh install, project auto-registered on first contact per 11 §7.4, or a store deleted by the user), it must not run a 5 s file-by-file snapshot (the hook watchdog prints the decision at 4 s). Instead:

1. `clonefile(<worktree root>, <store>/trees/cold-<ulid>, CLONE_NOFOLLOW)`: one syscall clones the whole hierarchy "as if each item was cloned individually" [verified: man page]. Measured: 55,005 entries incl. `node_modules` and `.git` in 468 ms and, in a second run under heavier machine load, 1,087 ms, allocating 17.28 MB of metadata; 10,005 entries in 131–233 ms [verified].
2. Write `trees/cold-<ulid>/.airbag-cold.json` (worktree id, time, trigger, session, command) and a `snapshots` row with `trigger='cold'`, `file_count=NULL`; return `.taken` with that id.
3. The app (or the next hook with ≥ 1 s of budget to spare) converts: prune excluded directories inside the clone (`node_modules` + `.git` of the 55k-entry clone: 158 ms), walk the clone, `rename(2)` each file into `items/` (74 µs per rename [verified]; 50k files ≈ 3.7 s in the background) while inserting rows, then remove the empty tree. Until conversion, file and folder restores clone straight out of the tree; project restore waits for conversion.

The man page says "Cloning directories with these functions is strongly discouraged" and points to `copyfile(3)` [verified]; `copyfile(COPYFILE_CLONE|COPYFILE_RECURSIVE)` on the same tree took 5,424 ms (a user-space walk) [verified]. The discouragement is about hierarchy-level atomicity and permissions handling; for a safety-net snapshot a tree that is per-file atomic is exactly what is wanted, and the conversion step walks it anyway. The kill-mid-syscall case (watchdog `_exit`) leaves either no tree or a complete one; a tree without a `.airbag-cold.json` is deleted by the next doctor pass.

### 2.9 Optional: `.git` safety clones (v1.1, app only)

The same directory clone makes the one thing no competitor protects affordable: `rm -rf .git`, `git reflog expire --expire=now` + `gc --prune=now`, or a corrupted index. The app clones `<project>/.git` into `trees/git-<ulid>` at session start and whenever `.git/HEAD`, `.git/refs/`, `.git/packed-refs` or `.git/index` change (dedicated FSEvents stream, 30 s debounce), keeps the newest three, and offers "Restore .git from <time>" with a `git fsck --connectivity-only` check afterwards. Cost is metadata only (objects are immutable, so clones share everything; ~20 µs per entry [estimate from 55k entries in 1.1 s]). Caveats: a clone taken during a `git gc` can be torn (the man page's atomicity caveat); the restore UI must say "verify with git fsck" and the feature is off by default until tested on real repositories [unverified end-to-end].

## 3. Restore algorithm

### 3.1 Invariants

1. **A restore is itself preceded by a snapshot**: `pre_restore` is a full snapshot of the worktree (75 ms at 50k files), so "undo the restore" is one more restore. A `post_restore` snapshot follows every restore so the timeline shows exactly what the restore changed.
2. **Restore never deletes anything Airbag did not snapshot**: a path is removed only if it exists in the `pre_restore` snapshot's state (hence recoverable) and is absent from the target; a path on disk that the pre-restore snapshot does *not* contain (excluded directory, capped file, dataless placeholder, unreadable file, FIFO, empty directory) is never touched. Where such a path stands in the way of a restored file, it is **moved aside** into `<store>/aside/<restore-ulid>/<path>` (same volume by construction, so `rename(2)` is atomic), listed in the restore card, and kept under retention — never unlinked.
3. **Nothing is partially new**: each written path appears atomically (clone to a temp name, then `rename`): "The rename() system call guarantees that an instance of new will always exist, even if the system should crash in the middle of the operation" [verified: rename(2)]. The project's own `.git` is never read or written.

### 3.2 Plan (computed before the confirmation window, 13 §7.1)

Inputs: target snapshot `T` (seq), scope (file path / folder prefix / project), the live state. Steps:

1. Take `pre_restore` → `P` (its `current` is now the live state). If the walk finds the worktree root missing or on another volume, abort with `restore.error.root`.
2. Build `state(T, prefix)` = nearest checkpoint ≤ T + replay of `changes` in `(checkpoint, T]` restricted to the prefix (replay of 50 changesets ≈ 0.4 ms; flattening 50k paths ≈ 24 ms, §6). `state(P, prefix)` = `current` under the prefix.
3. For each path in `state(T)`: not in `state(P)` → *write (add)*; in both with a different item/mode/kind → *write (replace)*; same item and mode → *unchanged*. For each path in `state(P)` not in `state(T)` → *remove*. Then check the disk for each write: a directory where a file/symlink must go → *aside* the directory (its captured files are in P; its uncaptured contents go aside with it); a file where a directory must be created → it is in P (captured) → *remove*, else *aside*; an `EACCES` parent → *conflict* (plan refused with the path).
4. Skipped-in-T paths (size cap, dataless, unreadable at snapshot time) are listed as "not covered" so the user knows the restored state is incomplete for them.
5. The plan is persisted in `restores` with `state='planned'` and shown: N written, M removed, K unchanged, A moved aside, U not covered, plus `restore.note.live_session` if a session is attached (13 §7.1) and, new here, `restore.note.open_files` when the radar finds processes with open descriptors under the prefix (`PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`, 04 §1): "next-server (pid 70386) has 3 files open here; restored content will not reach a process that keeps the old file open".

### 3.3 Apply

```
state := applying
for each write (ordered: directories created first, parents before children):
    tmp = "<dst>.airbag-restore-<ulid>"
    kind symlink: symlink(target, tmp)
    kind file:    clonefileat(itemsDirFd, itemName, AT_FDCWD, tmp, 0)        -- 170–250 µs; copy mode: copyfile()
                  if manifest.mode != item file mode: fchmodat(tmp, mode & 07777)   -- items are shared by hash across paths with different modes
                  futimens(tmp, now)                                           -- default: new mtime so build tools rebuild (option: keep the snapshot's mtime)
    if an aside is planned for dst: renameatx_np(dst → aside/<id>/<path>, RENAME_EXCL)
    renamex_np(tmp, dst, 0)                                                   -- atomic replace of a file or symlink
for each remove: if lstat key still equals state(P) → unlink / rmdir-if-empty; else (changed since P) → aside instead
state := verifying
for each write: lstat(dst) key == key of the clone just made (ino/size/mtime)? else record "overwritten during restore"
                for files ≤ 4 MiB additionally compare SHA-256 with items.hash
post_restore snapshot; state := done; registry event; FSEvents OwnEvent suppresses self-triggered fsevents snapshots (MarkSelf, 04 §3)
```

Measured [verified]: 100 files restored in 18.8–24.4 ms (188–244 µs per file incl. `mkdir -p`, clone, `chmod`, `rename`), 5,004 files in 880 ms, 50,004 files in 8.4 s into an empty tree and 9.8 s over an existing tree (single thread; four worker threads over disjoint subtrees would bring the 50k case to ~3 s [estimate]). `renamex_np(RENAME_SWAP)` works on this volume (`VOL_CAP_INT_RENAME_SWAP=1`; probe swapped live and temp atomically) and `RENAME_EXCL` returns `EEXIST` as documented [verified]; plain `rename` is used for replacement because the displaced inode is not needed (it is in P), and `RENAME_EXCL` for asides so an aside can never clobber.

Exec bits and symlinks: the clone carries the item's mode; the manifest's mode wins when they differ; symlinks are recreated with their exact target bytes. Fidelity beyond git: nanosecond mtimes and xattrs of the snapshotted version are available (clone preserves them [verified]) and can be restored on request; setuid/setgid bits are stripped by `clonefile` [verified: man page] and ACLs are not copied without `CLONE_ACL` — both recorded in the "not covered" list when the manifest shows such a file (rare in projects).

### 3.4 Concurrent writer (the agent is still running)

Per-path atomic replacement means the agent either sees the old file or the restored file, never a torn one. A process that holds an open descriptor keeps writing to the displaced inode (unlinked or moved aside); its later `open(path)` calls hit the restored file. Verification (step "verifying") catches paths the agent rewrote between apply and verify and lists them; the user can retry for those paths. For SQLite databases in use by a dev server the UI warns via the open-files note; restoring under a live writer is allowed but labelled.

### 3.5 Journal and resumability

`restores.state` drives recovery at app launch or `airbag doctor`: `planned` → discard; `applying` → re-run the plan idempotently (a write whose destination already has the clone's key is skipped; asides already done are detected by `aside/<id>/<path>` existing), then verify; `verifying` → verify only. Temp names carry the restore ULID so stray `*.airbag-restore-<ulid>` files from a crash are recognised and removed. This mirrors agentundo's interrupted-restore memory (05 §2.1) with the extra guarantee that nothing was deleted before being captured.

## 4. Diff and timeline

### 4.1 Between two snapshots A < B of one worktree (target < 200 ms at 50k files; measured 1–39 ms)

```sql
SELECT path,
       first_value(prev_item) OVER w AS item_at_A, first_value(op) OVER w AS first_op,
       last_value(item)  OVER w AS item_at_B,  last_value(op) OVER w AS last_op,
       last_value(mode) OVER w AS mode_B
FROM changes WHERE seq > :A AND seq <= :B AND path GLOB :prefix
WINDOW w AS (PARTITION BY path ORDER BY seq ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
```

collapsed per path: `item_at_A == item_at_B` (and same mode) → dropped (modified and reverted); `NULL → x` → A; `x → NULL` → D; `x → y` → M (or T when kinds differ). Measured on a synthetic week (1,400 snapshots × 100 changes): 50 consecutive snapshots → 4,988 paths in 1.1 ms; all 1,400 → 130,691 paths in 38.9 ms [verified]. The work is O(changes between A and B), independent of project size — the same property `git diff-tree` has (06 §6), without spawning a process.

### 4.2 Presentation

Status letters A/M/D/T as in 13 §7.1; **R** (rename) is derived without similarity scoring: a `D` and an `A` in the same collapsed set whose items are equal (same hash) → `R old → new`; copies show as `A` with "same content as <path>" when the item is referenced elsewhere in `state(B)`. Each row carries sizes before/after (`items.size`), so "Binary file · 1.2 MB → 0 B" needs no file access. Counts for cards come from `snapshots.added/modified/deleted/retyped` (written at snapshot time), so the timeline list never touches the file system.

### 4.3 Live tree versus a snapshot

"What changed since snapshot A" = walk + compare against `current` (= state of the latest snapshot L; 50k files: 85–96 ms walk + 5–35 ms load + 7–9 ms compare = 100–140 ms [verified components]) ∪ `changes(A..L)` (§4.1). For the common case A = L it is the walk alone. The app's FSEvents dirty set gives the same answer for free between full walks: dirty paths are `stat`ed against `current` (100 paths ≈ 0.2 ms).

### 4.4 Per-file textual diff and snapshot browsing

- Both versions are items (or the live file): read them (`mmap` for > 1 MiB), split into lines, run Swift's `CollectionDifference` (Myers): 2,000 lines / 52 edits in 0.8 ms, 20,000 lines / 202 edits in 4.4 ms [verified]. Identical hashes short-circuit; binary detection = NUL in the first 8 KiB; images via `NSImage` thumbnails; diffs > 1 MB truncated with "Save patch…" (13 §7.1).
- "Open snapshot in Finder" / export: materialise `views/<ulid>/` by cloning items into a tree (50k files ≈ 4.5 s [estimate: 90 µs per clone], 5k ≈ 0.45 s), optionally only the requested subfolder; views are deleted when the window closes and at launch. Zip export uses the view. A hard-link view was measured at 241 µs per link (12 s for 50k) [verified] and is not used.
- Grouping by session and command is the registry's job (11 §3.2 `events` → `snapshots.event_id`; 13 §7.1 project → session → event); the manifest contributes `label`, counts and the changeset.

## 5. Retention and pruning

### 5.1 Policy (defaults from 13 §7.4)

Keep a snapshot if any holds: age ≤ 7 days; it is among the newest 20 of its worktree; `pinned`; it is the retention-boundary checkpoint. Delete oldest-first until both the age rule and the global budget (5 GiB of *private* bytes across all stores, computed per §1.4) are satisfied. The per-project share of the budget is proportional to recent activity, never less than 256 MiB [design]. Pinning a snapshot writes a checkpoint for it immediately (nearest checkpoint + replay → `checkpoints` rows, ~100 ms at 50k) so it survives the deletion of everything before it.

### 5.2 Algorithm (app, hourly and after every 200 snapshots; CLI only in the emergency path of §8.1)

1. Under the store flock, pick the cut: the newest checkpoint `C` whose `created_at` ≤ the age cut-off (or the budget cut), excluding pinned snapshots, per worktree. Snapshots with `seq < C` and not pinned are doomed. If the doomed set is empty but the budget is exceeded, advance `C` to the next checkpoint (making the oldest retained era shorter) until it fits or only the newest-20/pinned remain.
2. One transaction: `DELETE FROM snapshots WHERE seq IN doomed` (cascades to `changes` and `checkpoints`); pinned snapshots older than `C` keep their checkpoint rows, so they remain reconstructible without the deleted changesets. Mark the registry rows `deleted_at`.
3. Unreferenced items: `items.id NOT IN (SELECT item FROM current UNION SELECT item FROM checkpoints UNION SELECT item FROM changes UNION SELECT prev_item FROM changes)` → delete rows in the same transaction, then unlink the files after `COMMIT` (36.8 µs per unlink [verified]; 10k items ≈ 0.4 s). Asides of restores older than the age cut-off are removed the same way.
4. Re-run the private-size sweep for the UI.

Cost: for a store with 140k `changes` rows the selection queries run in tens of milliseconds [estimate from the 39 ms full-range diff]; the unlink loop dominates and runs at utility QoS. Compared with git this is "delete refs + unlink", with no `gc --prune=now` (7 s per 40k objects, 06 §8) and no repack.

### 5.3 Crash safety and consistency

- Metadata is transactional (WAL, `synchronous=NORMAL`: durable except power loss; a power loss can lose the last transactions, never corrupt — sqlite.org/wal.html via 04 §8 [verified]). Item files are created *before* their rows are committed and unlinked *after* their rows are deleted, so a crash can only leave **orphan files**, never dangling rows. The daily doctor pass (`fts` over `items/`, 85 ms per 50k entries) deletes files without rows older than one hour and flags rows without files (`items.flags |= missing`; affected snapshots show "1 file unavailable" for that path).
- `trees/cold-*` without a `.airbag-cold.json`, `views/*` and `*.airbag-restore-*` temp files are removed by the same pass.
- `PRAGMA quick_check` daily; `VACUUM INTO manifest.sqlite.bak` daily (27 MiB week-of-heavy-use manifest ≈ 100 ms [estimate]).

## 6. Performance model

Machine and corpora: Apple M4, macOS 15.7.9, APFS Data volume, other benchmarks running concurrently. `p50k` = 50,004 captured entries (50,000 generated `.ts` files of 1–64 KiB in 500 directories, 200 random `.bin` assets of 9.8 MiB each under `assets/`, `.env` 0600, an executable script, a symlink to a file and to a directory, an empty directory) = 1,979.7 MB, plus 5,000 files under `node_modules/` and a `.git/` that the walker prunes (55,005 entries on disk). `p5k` = 5,004 entries / 53.4 MB plus 5,000 `node_modules` files. Probes: `cfprobe.c` (fts walker, binary stat-cache manifest, `fclonefileat` farm, restore, hard-link view, directory clone, SHA-256), `micro.c`, `conc.c`, `extra.c` (SQLite changeset model, PRIVATESIZE sweep, cold path, rename, EXDEV, volume capabilities), `cfswift` (Swift 6.1 Merkle/SQLite prototype, `CollectionDifference`, CryptoKit), all under the session scratch directory; raw lines in §11.

### 6.1 Measured latencies

| Operation | p50k (50,004 files, 1.98 GB) | p5k (5,004 files, 53 MB) | Tag |
|---|---|---|---|
| Walk only (`fts` + `lstat`, deny list applied) | 85–96 ms | 6.5–6.8 ms warm, 42 ms cold | [verified] |
| First snapshot, file-by-file clones | **5,178 ms** (clone loop 5,079 ms = 101.6 µs/file; 11.67 MB of metadata); 6,339 ms in a second run under load | **520 ms** (2.13 MB) | [verified] |
| First snapshot, directory clone (cold path, incl. `node_modules`/`.git`) | 468 ms / 1,087 ms (two runs) + 158 ms to prune the clone | 131 ms / 233 ms + 173 ms | [verified] |
| No-change snapshot (load `current` + walk + compare + write) | **74–79 ms** (5–6 + 45–49 + 7–9 + 11–15) | **9–22 ms** | [verified] |
| 100 changed files (atomic rewrite / in-place) | **85 / 91 ms** (2.4 MB cloned; +0.09 / +0.05 MB on disk) | **17 / 17 ms** | [verified] |
| 990 changed files | 176 ms (35 MB cloned; +1.21 MB on disk) | — | [verified] |
| Inline SHA-256 of the changed set (added to the above) | 100 × 40 KB ≈ 12 ms; 990 × 36 KB ≈ 110 ms at 0.33 GB/s | 100 × 11 KB ≈ 10 ms | [estimate from measured throughput] |
| FSEvents dirty-set snapshot (app; 100 dirty paths) | ≈ 15 ms (0.2 ms stat + 10 ms clones + 3 ms SQLite) | ≈ 15 ms | [estimate from measured parts] |
| Restore 100 files | 24 ms | 19 ms | [verified] |
| Restore whole project (single thread) | 8.4 s empty tree / 9.8 s over existing | 0.88 s | [verified] |
| Diff A..B (manifest) | 1.1 ms (50 snapshots apart) … 39 ms (1,400 apart) | same | [verified, synthetic week] |
| Diff live vs latest | 100–140 ms | 15–60 ms | [verified components] |
| Full tree listing of a snapshot (checkpoint + replay) | 24 ms flatten + 0.4 ms replay | 1.7 ms | [verified, prototype] |
| Materialised view (clones) | ≈ 4.5 s | ≈ 0.45 s | [estimate: 90 µs/clone] |
| Hash everything (not on the hot path) | 6.2 s (0.33 GB/s, I/O + 50k opens) | 0.49 s | [verified] |
| Private-size sweep (hourly, app) | 706 ms / 51k items | 116 ms / 10k items | [verified] |

Hook end-to-end budget (replacing the 11 §4.2 row set): spawn 1.4–3.8 ms + parse + rules + registry 5 ms + snapshot 75 ms + ping → **≈ 85 ms p50 at 50k files, ≈ 20 ms at 5k**, versus ~140 ms per 20k files for the git design (06 §9; the 10A prototype measured 300–560 ms per 5k-file snapshot under today's load). 10,000 changed files ≈ 1.1 s (clones) + hashing — the one case that approaches the 1.5 s deadline, and it is also the case where the hook may return `.skipped(.timeout)` while the app finishes via FSEvents.

### 6.2 Memory and CPU

- Hook: the C probe peaked at 12.6 MB RSS on p5k and 113 MB on p50k, but the probe stores two arrays of fixed 1 KiB-path records; with ~100 B per entry (path bytes + 40 B key) the 50k map is ≈ 6 MB, so the hook stays under 20 MB [estimate]. The app caches one `current` map per active project (≈ 6 MB per 50k files) and releases it after 10 min idle; FSEvents dirty sets are small. Within the ~100 MB app budget for five 50k projects.
- Idle CPU: no polling; FSEvents callbacks; the hourly private-size sweep is 0.7 s of mostly kernel time per 50k-item store (≈ 0.02 % of an hour). The background hasher is bounded at 64 MB/s and only runs while items have `hash IS NULL`.

### 6.3 Disk overhead per day under heavy agent activity [estimate]

Scenario: 200 pre/post snapshot pairs per day (one Bash call every ~2.5 min for 8 h), 100 files changed per command, agents rewrite files wholesale (editor-style atomic replace), average file 40 KB (p50k) / 11 KB (p5k).

| Component | p50k | p5k |
|---|---|---|
| Data pinned by old versions (full divergence per rewrite) | 200 × 100 × 40 KB ≈ **0.8 GB/day** | 200 × 100 × 11 KB ≈ 0.21 GB/day |
| Same with in-place edits (one 16 KiB page per file) | 200 × 100 × 16 KiB ≈ 0.3 GB/day | 0.3 GB/day |
| Item metadata (233–445 B per clone) | ≈ 5–9 MB/day | ≈ 5–9 MB/day |
| Manifest rows (203 B per change incl. item row; measured 27.1 MiB for 140k changes) | ≈ 4 MB/day | ≈ 4 MB/day |
| Checkpoints (every 64 snapshots, ~100 B/row) | 3 × 5 MB ≈ 15 MB/day | 1.5 MB/day |
| Dedup credit (formatter/checkout no-ops, reverted edits) | − 10–30 % of the data line | same |

Seven days of the p50k scenario reach ≈ 5.6 GB, so the 5 GiB budget — not the 7-day rule — becomes binding at that intensity and retention keeps ~6 days; p5k keeps the full week at ≈ 1.5 GB. For comparison, git (06 §8) stores the same churn as loose objects at ≥ 4 KiB each (80 MB/day minimum before content) but repacks text with deltas and zlib to a fraction of the raw size (25:1 on the synthetic corpus, worse on real code). On text-heavy churn git's *packed* store is smaller than a clone farm by an order of magnitude [estimate]; on binaries, databases and large assets the clone farm is smaller by orders of magnitude because an unchanged or partially changed large file costs 0 bytes or only its changed pages. A compactor that re-encodes items older than 24 h and ≤ 1 MiB with LZFSE (`compression_encode_buffer`, in the OS) is the v1.1 answer to text churn (expected 3–5× on source [estimate]); it costs the block sharing with the live file, which an old item has usually already lost.

### 6.4 Where the model breaks

- 10k+ changed files per command (`npm install` inside a non-excluded directory, a generated `src/` tree): ~1 s of clones; still within the hook deadline, but the walk itself at 250k+ entries exceeds 400 ms per command, so above 150k captured entries the hook stops snapshotting and relies on FSEvents (§8.6).
- A large file rewritten wholesale every command (video render, `dump.sql`): each snapshot pins a full old copy. The cap (1 GiB) bounds a single item; the budget bounds the total; the timeline shows the per-snapshot `private_bytes` so the user sees which command costs disk.

## 7. Secrets

The store deliberately holds `.env`, `.env.*`, `*.pem`, `*.key`, `.npmrc`, `.netrc`, kubeconfigs, service-account JSON — because "the agent deleted/edited `.env`" is a documented loss case the git-ignore-honouring tools cannot undo (05 §2.1, §6). Threat model: containment to this user on this Mac (no backups, sync, search indexes, other users); FileVault covers disk theft; a same-uid process (including the agent) can read the originals anyway.

| Vector | Measure | Status |
|---|---|---|
| Other local users | `umask 077` at every entry point; store, `items/`, `trees/`, `aside/`, `views/` 0700; manifest, `store.json`, lock 0600; `airbag doctor` re-asserts modes at launch | design; modes [verified] in probes |
| Time Machine | Sticky exclusion on `stores.noindex/` (and per-volume store roots): `CSBackupSetItemExcluded(url, true, excludeByPath=false)` — `BackupCore.h`: "false to make the exclusion bit 'sticky', i.e. follow the item" [verified: SDK header]; equivalently `tmutil addexclusion` (man page: "a location-independent ('sticky') exclusion that follows a file or directory" [verified]). Probe today: directory and a file inside reported `[Excluded]`, the mark survived `mv`, `removeexclusion` cleared it, xattr `com.apple.metadata:com_apple_backup_excludeItem` [verified] | [verified] |
| Spotlight | `.noindex` suffix on the store root + `.metadata_never_index` marker; items have no extension; the only plain-text files are `store.json`, the manifest and the restore journal, none of which contain file contents | [likely] (§1.1) |
| iCloud Drive / Desktop & Documents sync | Store under `~/Library/Application Support` or a volume-root `.airbag/` dir, never inside the project; Airbag refuses to create a store under any path containing `/Mobile Documents/` and warns when a *project* is under a synced folder (its files may be dataless, §8.5) | design; [likely] for the inclusion model |
| Command text | Redacted before storage by the bridge (11 §9 patterns); the manifest stores only the redacted `label` | design (11) |
| Shared blocks | A `.env` item shares blocks with the live `.env`; the item is readable only through the 0700 store; when the user deletes the secret from the project the item keeps the bytes until retention — the **"Forget this file's history"** action unlinks every item referenced only by that path and rewrites the affected `changes` rows to `op=D` with `item=NULL` (a few ms; git would need a history rewrite plus `gc`) | design |
| Optional encryption at rest (v1.1, default off) | Files matching the secret patterns are stored as `items.kind=2`: AES-256-GCM (CryptoKit) of the plaintext with a 16-byte header `ABSN-ENC-1`, nonce derived from `SHA-256(key ‖ plaintext hash)` so dedup still works; key in the login keychain (generic password, ACL naming the app and the bundled CLI) or, if the ACL prompts between two executables prove unworkable, a 0600 key file next to the registry (then it only protects against sync/backup leakage — the UI says which). Such items lose block sharing (they are ciphertext written by Airbag), which is irrelevant at `.env` sizes. Diff view decrypts both sides in memory; restore decrypts to the temp file | design |
| Settings | `projects.include_env` (default on, 13 §5.5): off makes the walker skip the secret patterns (unrestorable, stated at the toggle); `storage.encrypt_secrets` (v1.1); `storage.exclude_from_time_machine` (default on) | design |

## 8. Failure modes and recovery

### 8.1 Disk full

Two distinct problems. (a) Airbag's own writes: `clonefile` "might not allocate new storage for data blocks" but needs metadata and fails with `ENOSPC` when none is left [verified: man page]; the engine treats `ENOSPC` on a clone or on the manifest as `.skipped(.error)` and raises the degraded icon state ("snapshots paused: disk full", 13 §6.1). (b) The subtler one: a clone pins the live file's blocks, so when the agent later overwrites the file in place APFS must allocate new blocks — the man page warns that such an overwrite "can fail with ENOSPC" [verified]. Reproduced today on a 200 MB APFS image: with a clone of a 120 MB file present and 5 MB free, 200 in-place 4 KiB writes were accepted into the page cache and `fsync` then failed with `errno=28 ENOSPC`; after deleting the clone the same writes and `fsync` succeeded [verified]. Policy: a **free-space floor** (default max(10 GiB, 5 % of the volume)): below it the engine stops creating clones *and* runs emergency retention (newest-20 rule relaxed to newest-5) until above the floor; the CLI may run this emergency path when the app is absent; the UI explains that Airbag freed space by dropping old snapshots.

### 8.2 Corrupted or lost manifest

The manifest is the only path → item map; items are opaque by design. Defences, in order: WAL + `quick_check` daily; `manifest.sqlite.bak` daily (`VACUUM INTO`); every item carries an xattr breadcrumb `dev.airbag.src` = `<worktree-id>\0<relative path>\0<mtime_ns>` written at clone time (≈ 20 µs; xattrs are cheap on APFS [likely]) so `airbag doctor --rebuild` can reconstruct a "latest version per path" manifest from the farm alone (one `listxattr`/`getxattr` per item: 51k items ≈ 1–2 s [estimate]); the registry keeps snapshot headers for the timeline skeleton. What cannot be rebuilt from breadcrumbs: which *older* versions belonged to which snapshot — they survive as "orphan versions of <path>" that the UI lists by time. `SQLITE_CORRUPT`/`SQLITE_NOTADB` → rename aside, restore `.bak`, replay nothing (the `.bak` is at most a day old), rebuild the rest from breadcrumbs, and show "history rebuilt from store; the last N hours may be incomplete".

### 8.3 Project moved or renamed

Same volume: nothing in the store depends on the path; the app re-links via FSEvents `RootChanged` + `F_GETPATH`, the hook via `(st_dev, st_ino)` of the root (10A §1.2 argument applies unchanged; 11 owns the registry row). Other volume: the next clone fails with `EXDEV` → the engine marks the store `mode=copy` for new items (byte copies onto the old store's volume) or, if the new volume is APFS with the clone capability, starts a new store there and keeps the old one read-only for restores (restores across volumes are byte copies, which work). The UI offers "Move history to the new volume" (copy items; 2 GB ≈ 10 s on SSD [estimate]).

### 8.4 External volumes, network volumes, case sensitivity

- External APFS volume: store at `<mount>/.airbag/<uid>/stores.noindex/`; FSEvents persistence keyed by device UUID (04 §3); unmounting pauses the project; `tmutil` exclusion applies to the volume-root dir. External HFS+/exFAT/SMB: copy mode, warned (`projects.guard.volume`, 13 §5.5); SMB additionally lacks reliable `ctime`/`ino`, so the stat key degrades to `(size, mtime)` plus inline hashing of every changed candidate [design].
- Case-sensitive APFS project volume (tested on an image: `VOL_CAP_FMT_CASE_SENSITIVE=1`): fully supported, paths are bytes. Restoring a snapshot taken on a case-sensitive volume into a case-insensitive one collides on names that differ only by case: the second clone returns `EEXIST` [verified today with `A.txt`/`a.txt`]; the planner detects collisions with `VOL_CAP_FMT_CASE_SENSITIVE` of the destination and lists them as conflicts before anything is written. Normalization: APFS resolves NFC/NFD to the same file, so no collision arises from normalization alone [verified: APFS FAQ].

### 8.5 iCloud Drive placeholders (dataless files)

Projects under `~/Desktop`/`~/Documents` with Desktop & Documents sync and "Optimize Mac Storage" may contain evicted files. The engine sets the process I/O policy to not materialise (§2.2 step 1), skips entries with `SF_DATALESS` and records them as `skipped.dataless`; if a dataless file is reached anyway, `clonefile` returns `EDEADLK` ("The src pathname refers to a 'dataless' file that must be materialized before being cloned" [verified: man page]) and the entry is skipped. Restore never writes over a dataless placeholder without listing it as an aside first. The project row shows "N files are in iCloud only and cannot be protected".

### 8.6 Very large projects — when to refuse

Guards at registration and re-evaluated after each full walk: > 100,000 captured entries or > 2 GB after excludes → "large folder" confirmation (13 §5.5); > 150,000 entries → hook snapshots off for this project (the walk alone would exceed ~300 ms per command), FSEvents dirty-set snapshots only, explained in the project row; > 250,000 entries or > 50 GB → refused for hook protection, offered as FSEvents-only with a warning that the first snapshot takes `entries × 100 µs` (25 s) in the background; `~`, volume roots and `~/Library` always refused. Non-git folders above 5,000 files / 500 MB get takeback's "are you sure" (05 §5.2).

### 8.7 Other

- Project's `.git` or nested `.git` deleted by the agent: not covered by file snapshots; covered by §2.9 if enabled; the breaker's `rm -rf .git` rule is the primary defence.
- Permissions changed by the agent (`chmod -R 000`): walker records `skipped.unreadable`; restore of those paths is "not covered"; the mode bits themselves are in the manifest and a "restore permissions" action can `chmod` back [design].
- APFS snapshot or Time Machine local snapshot holding the same blocks: irrelevant to correctness; `PRIVATESIZE` already accounts for "trapped inside a clone or snapshot".
- Volume with `VOL_CAP_INT_CLONE` but clones failing (`ENOTSUP` on some sparse-bundle images [unverified]): per-file fallback to `copyfile`, store flips to copy mode after three consecutive failures.

## 9. Implementation plan (Swift 6.1, SwiftPM, CLT only)

### 9.1 Targets (inside `AirbagCore`, 11 §1)

| Target | Contents | Notes |
|---|---|---|
| `CAirbagFS` (C) | thin shims: `fts(3)` iteration (variadic/macros unfriendly to Swift), packed `getattrlist` result structs for `ATTR_CMNEXT_*` and `ATTR_VOL_CAPABILITIES`, `renamex_np`, `setiopolicy_np` | `clonefile`/`fclonefileat` are callable from `import Darwin` directly [verified: Swift probe compiled and ran] |
| `AirbagSnapshots` | `StoreLocator` (volume capability probe, per-volume roots, copy mode), `Walker` (fts, deny list, pattern matcher), `StatKey`, `ItemStore` (clone/copy, inline hash, dedupe, breadcrumbs), `Manifest` (SQLite schema v1, migrations, prepared statements, changeset queries), `SnapshotEngine` actor (implements 11 §10.5 `SnapshotEngine`; flock, deadline, cold path), `ColdPathConverter`, `DirtySet` (FSEvents adapter, app only), `RestorePlanner` + `RestoreExecutor` + `RestoreJournal`, `DiffService` (changeset collapse, rename derivation, text diff), `Retention` + `SizeAccounting` (PRIVATESIZE sweep), `Compactor` (v1.1), `Doctor` (consistency pass, rebuild from breadcrumbs), `Exporter` (views, zip) | strict concurrency; one actor per store; no `Process` spawns anywhere |
| Tests `AirbagSnapshotsTests` | Swift Testing (works on CLT, 04 §11) | see 9.3 |
| Bench `airbag-bench` (executable, not shipped) | generator for the 5k/50k corpora, mutation driver, timing harness emitting JSON for CI trend lines | ports `cfprobe.c` |

Dependencies: none beyond the OS (`Darwin`, `SQLite3`, `CryptoKit`, `CoreServices` for `CSBackupSetItemExcluded`, `Compression` in v1.1). No git, no libgit2, no BLAKE3 package.

### 9.2 Interfaces (binding to 11)

- `SnapshotEngine.snapshot(project:worktree:trigger:context:deadline:) async -> SnapshotOutcome` as pinned in 11 §10.5; `SnapshotRecord` gains `storeSeq: Int64`, `added/modified/deleted: Int`, `privateBytes: Int64?`, `rootHash: Data?` (optional); `SnapshotSkipReason` gains `.diskFull`, `.volumeUnsupported`, `.projectTooLarge`.
- New: `RestoreService.plan(target:scope:) async throws -> RestorePlan`, `apply(_:) async throws -> RestoreResult`, `resumeIncomplete()`; `DiffService.changes(from:to:prefix:)`, `liveChanges(worktree:)`, `textDiff(path:from:to:)`; `RetentionService.run(budget:ageDays:) async`; `StoreDoctor.check(_:) / rebuild(_:)`.
- Registry rows written by the engine: `snapshots` header, `events(kind='snapshot_taken'|'snapshot_skipped'|'retention_run')`, `projects.store_path/store_mode/store_private_bytes` (11 §3.2 column additions).

### 9.3 Test strategy

1. Unit (no file system): deny-list/pattern matcher (gitignore subset, byte paths, NFD names), stat-key equality, changeset collapse incl. revert-to-same-item and rename derivation, retention cut selection with pins and checkpoints, restore plan rules (the "never remove uncaptured" invariant as a property over random states).
2. Integration on a temp directory on the Data volume (skipped when `VOL_CAP_INT_CLONE` is absent): snapshot → mutate (write, in-place write, delete, rename, chmod, symlink retarget, file↔dir swap, case-only rename, NFD/NFC names, FIFO, unreadable file, 1 GiB sparse file, dataless-flag emulation not possible without iCloud → skipped) → snapshot → diff equals the mutation log → restore to each snapshot → tree byte-equal incl. modes and link targets; `.git` untouched (checksum); excluded dirs untouched; asides created for uncaptured conflicts.
3. Property test: 200 random mutation/snapshot/restore sequences per run against an in-memory model of the tree.
4. Crash tests: `kill -9` the engine process at injected points (after clone / before commit / after commit before unlink in retention / mid-restore) → `Doctor.check` reports consistent, `resumeIncomplete` finishes the restore, no dangling rows.
5. Concurrency: two processes (CLI + app simulators) snapshotting the same store under a writer thread; assert no `EEXIST` on items, no lost snapshots, lock wait ≤ budget.
6. Volume tests with `hdiutil` images (as run today): case-sensitive source, `EXDEV`, `ENOSPC` floor behaviour, copy-mode fallback on an HFS+ image.
7. Performance (release build, `AIRBAG_BENCH=1`): the §6.1 table as assertions with 50 % headroom (no-change ≤ 120 ms at 50k, 100 changed ≤ 150 ms, restore 100 ≤ 50 ms, diff ≤ 60 ms) and a 24-hour soak measuring app `phys_footprint` and idle CPU.
8. Manual QA: the 13 §3.1 destructive-agent scripts (`rm -rf dir`, `mv`, `sed -i`, `git checkout -- .`, `git reset --hard`, `git clean -fdx`) fully reverted from the UI with zero lost files; Finder/du explanation visible in Settings.

### 9.4 Effort [estimate]

| Work package | Days |
|---|---|
| `CAirbagFS` shims, `StoreLocator`, volume probes, copy mode | 1.5 |
| `Walker` + matcher + `StatKey` | 1.5 |
| `ItemStore` (clone, hash, dedupe, breadcrumbs, background hasher) | 2 |
| `Manifest` schema, migrations, queries, checkpoints | 2 |
| `SnapshotEngine` (lock, deadline, outcomes, registry rows) + cold path + converter | 2.5 |
| `DirtySet` FSEvents adapter (app) | 1 |
| Restore planner/executor/journal/verify + asides | 3 |
| `DiffService` (changesets, renames, text diff, binary/image) | 1.5 |
| Retention + size accounting + free-space floor | 2 |
| Doctor (consistency, rebuild), TM/Spotlight marks, "forget history" | 1.5 |
| Tests (unit, integration, property, crash, volumes), bench harness | 3.5 |
| **Total v1** | **≈ 22 engineer-days**; `.git` safety clones, compactor, encryption: +4 in v1.1 |

## 10. Honest weaknesses and what would make this lose

1. **Same-volume constraint.** `EXDEV` is structural: the store must sit on the project's volume, which means a second store root scheme for external volumes, a copy-mode fallback for non-APFS media, and a migration step when a project changes volume. The git and CAS designs put every store under `~/Library` and never think about it. If a meaningful share of users keep projects on external or network volumes, this design loses on simplicity.
2. **No delta or compression.** Text churn pins whole old versions (~0.8 GB/day worst case on a 50k-file project, §6.3); git's packed deltas are an order of magnitude smaller on source code. The budget rule makes this safe but shortens effective retention under heavy churn; a compactor is extra work and gives up the "zero-copy" story for old items.
3. **Accounting is counter-intuitive.** `du`, Finder "Get Info", DaisyDisk-style tools and the cask's users will report "Airbag uses 2 GB per project" when it uses 12 MB. The UI can show `PRIVATESIZE`, but the first GitHub issue is predictable.
4. **Clones couple Airbag to the agent's disk-full failures.** Reproduced: with free space exhausted, the agent's in-place overwrite of a cloned file fails at `fsync` with `ENOSPC` until the clone is deleted. The free-space floor and emergency retention are mandatory, not optional, and they are a policy a user can misunderstand ("Airbag deleted my snapshots").
5. **The manifest is a single point of failure for history.** Items are opaque; breadcrumbs and daily backups reduce the blast radius to "which version belonged to which snapshot", but a git store degrades more gracefully (`git fsck`, `for-each-ref`, every object self-describing) and a CAS with per-blob metadata likewise.
6. **Not inspectable with stock tools.** No `git log` on the store; users and contributors must trust `airbag` commands (`airbag snapshots`, `airbag export`). For an MIT project that wants outside contributors this is a real cost.
7. **Fidelity gaps.** setuid/setgid stripped by `clonefile` [verified], ACLs not copied without `CLONE_ACL`, BSD flags not restored, empty directories not tracked, hard-link identity not preserved on restore. None matter for typical agent projects; all are limits.
8. **Dependence on platform specifics.** Behaviour verified today on 15.7.9 (page-cache visibility of clones, atomicity under appends, `PRIVATESIZE` semantics, `.noindex`) is partly undocumented; a future APFS change could alter costs without notice. macOS 14 was not tested (only 15.7.9 available), though every API used exists since 10.12/10.13 [verified: headers].
9. **Linear cost in changed files remains.** 10k changed files ≈ 1 s of clones plus hashing — in the same band as git's `update-index` (06 §9: 2,000 changed ≈ 0.8 s). The decisive wins are the first snapshot, large files, restores and the absence of a git dependency; steady-state small changes are "merely" 2–4× faster.

What would make me recommend an alternative: (a) evidence that > 20 % of target users keep projects on non-APFS or external volumes — take 10C (CAS) for volume independence; (b) a product decision that the store must be readable by stock tools and contributors — take 10A (git); (c) measurements on real repositories showing that text churn exhausts the 5 GiB budget in under three days for typical users — take 10A for its packing, or ship this design only with the compactor. The strongest version of 10C is, in effect, this design with hash-named items whose blob write is a `clonefile` when source and store share a volume and a copy otherwise; I would accept that merge, keeping the changeset manifest, the restore invariants, the cold path and the `PRIVATESIZE` accounting from this document.

## 11. Measurement log (raw, 2026-10-17, 23:30–23:45 EDT)

```
walk(fts+lstat) p50k: 50004 entries, 1979.7 MB: 96.2 / 85.4 / 84.9 ms;  p5k: 5004 entries, 53.4 MB: 42.5 (cold) / 6.8 / 6.5 ms
p50k initial snapshot: walk 90.0 compare+clone 5079.4 (changed=50004, 1979.7 MB cloned) manifest 8.3 total 5177.7 ms free_delta 11.67 MB
p50k no-change ×3: total 79.3 / 73.6 / 75.9 ms (prevload 5.2–6.2, walk 44.8–48.9, compare 6.7–9.3, manifest 11.0–14.6)
p50k 100 atomic rewrites: total 84.7 ms (compare+clone 18.1; cloned 2.4 MB; free_delta 0.09 MB);  100 in-place pwrite: 90.8 ms (19.7; 0.05 MB)
p50k 1000 atomic rewrites (990 distinct): total 175.7 ms (compare+clone 108.8; 35.0 MB; free_delta 1.21 MB)
p50k restore 100 files: 24.4 ms (243.7 µs/file);  all 50004: 8389.6 ms (167.8 µs/file) fresh dir;  9758.0 ms (195.1 µs/file) over existing
p50k hardlink view: 50004 links 12061.4 ms (241.2 µs/link); rmtree 1725.6 ms;  sha256 all: 1979.8 MB in 6243.4 ms (0.33 GB/s)
p50k clonefile(dir) incl node_modules+.git (55005 entries): 467.7 ms, free_delta 17.28 MB; second run (extra.c cold path): 1087.3 ms + prune 157.9 ms
p50k copyfile(CLONE|RECURSIVE): 5424.2 ms;  rmtree of a 55005-entry clone: 1760–1825 ms
farm50: du 2.1G (2170532 KiB) for 51192 files vs 11.67 MB real; manifest.bin 4.4 MB
p5k initial: 520.0 ms (clone 512.1; 2.13 MB);  no-change ×3: 17.6 / 22.0 / 8.9 ms;  100 atomic 16.8 ms; 100 in-place 16.6 ms
p5k restore 100: 18.8 ms; all 5004: 880.0 ms;  hardlink view 1135.5 ms;  sha256 all 487.3 ms (0.11 GB/s);  clonefile(dir) 131.4 ms (233 + prune 173 in the second run)
micro (20000 × 3000 B): create 49.4 µs; link 222.9 µs; clonefile 88.8 µs; symlink 34.8 µs; 2nd link 217.8 µs; unlink clone 36.8 µs; unlink link 43.1 µs
PRIVATESIZE (64 MiB): before clone privsize=67108864 refcnt=1; after clone both privsize=0 cloneid equal refcnt=2 extflags=0x41; after 1 MiB in-place write both privsize=1048576, orig new cloneid, refcnt=1, extflags=0x1; after full rewrite both privsize=67108864
conc: 60 clones under continuous 4 KiB appends: ok=60 torn=0 inconsistent=0, avg 250 µs; clone of an open unsynced file contains the unsynced bytes; renamex_np RENAME_SWAP rc=0 (contents swapped); RENAME_EXCL onto existing → EEXIST
attrs: clone keeps mode 0640, mtime 1577836800.123456000, xattr dev.airbag.test; symlink clone with CLONE_NOFOLLOW → symlink with same target; in-place write to orig leaves clone intact; clone onto existing → EEXIST
bigfile: 512 MiB clone 0.155 ms, free delta 0.00 MB; 256 random 4 KiB in-place writes → 4.11 MB (hw.pagesize 16384); unlink clone 0.867 ms
cfswift (Swift 6.1.2 release, Merkle/SQLite variant) p50k: manifest load 10.0 ms; tree build 46.0; hash 534 dirs 30.2; store 534 trees / 50537 entries 49.1 ms; 100 changed → 112 new trees / 9392 entries 9.0 ms; dirty-only rehash 7.59 ms; diff A..B 100 changes / 224 queries 4.3 ms (4.8 after reopen); flatten 50004 paths 23.8 ms; db 5216 KiB for 2 snapshots
cfswift p5k: load 0.9; build 4.6; hash 3.1; store 3.5 ms; B 3.7 ms; diff 2.2 ms; flatten 1.7 ms; db 848 KiB
CollectionDifference: 2000 lines/52 edits 0.8 ms; 5000/52 0.9 ms; 20000/202 4.4 ms;  CryptoKit SHA256 256 MiB: 97–103 ms (2.6–2.78 GB/s)
extra: VOL_CAP_INT_CLONE=1 CASE_SENSITIVE=0 RENAME_SWAP=1 RENAME_EXCL=1 on /, /System/Volumes/Data, $HOME; APFS image (case-sensitive): CLONE=1 CASE_SENSITIVE=1
extra: clonefile Data → image: errno=18 EXDEV;  within image rc=0;  CS source a.txt/A.txt → CI destination: second clone errno=17 EEXIST
extra: ENOSPC: 120 MB file + clone on a 200 MB image, filler to 5 MB free: 200 in-place 4 KiB pwrites ok, fsync errno=28; after rm clone: fsync ok
extra: privsize sweep farm50: 51194 items, private 39.16 MB, 706.4 ms;  farm5: 10204 items, 2.27 MB, 115.8 ms
extra: sqlite full scan of 59929 entry rows: 34.8 ms cold / 5.0 ms warm
extra: changeset model 1400 snapshots × 100 changes: 4020.8 ms total (2.87 ms/snapshot); db 27.1 MiB (203 B per change incl. item row); diff over 50 snapshots 4988 paths 1.1 ms; over 1400: 130691 paths 38.9 ms; replay 50 changesets 0.4 ms
extra: rename 20000 files across dirs 74.0 µs/op; lstat 2.2 µs/op
RSS: cfprobe snap p5k 12.6 MB peak; p50k 113 MB peak (probe artefact: two arrays of 1 KiB fixed-path records; the run also re-cloned all 50004 files because an earlier restore step had rewritten the manifest keys: 6338.7 ms, 15.87 MB)
tmutil: addexclusion → isexcluded [Excluded] for dir and child; xattr com.apple.metadata:com_apple_backup_excludeItem; still [Excluded] after mv; removeexclusion clears
```

Caveats: `sync()` calls inside the probe inflate wall time for back-to-back runs (20 no-change p5k runs took 1.37 s of wall clock while in-process totals were 9–22 ms); free-space deltas are perturbed by concurrent processes; the machine was shared with other benchmarking subagents, which explains the 468 vs 1,087 ms spread for the directory clone.

## 12. Sources (accessed 2026-10-17)

- clonefile(2) man page (Xcode man page mirror): https://keith.github.io/xcode-man-pages/clonefile.2.html — block sharing, directory cloning "strongly discouraged", atomicity, `EXDEV`, `EEXIST`, `ENOSPC` on later overwrite, `EDEADLK` for dataless, setuid/setgid stripped, `VOL_CAP_INT_CLONE`
- getattrlist(2) man page: https://keith.github.io/xcode-man-pages/getattrlist.2.html — `ATTR_CMNEXT_PRIVATESIZE`, `ATTR_CMNEXT_CLONEID`, `ATTR_CMNEXT_CLONE_REFCNT`, `EF_MAY_SHARE_BLOCKS`, `EF_SHARES_ALL_BLOCKS`, `VOL_CAP_INT_CLONE`, `VOL_CAP_FMT_CASE_SENSITIVE`
- rename(2) man page: https://keith.github.io/xcode-man-pages/rename.2.html — `renamex_np`, `RENAME_SWAP`, `RENAME_EXCL`, crash guarantee
- copyfile(3) man page: https://keith.github.io/xcode-man-pages/copyfile.3.html — `COPYFILE_CLONE` best-effort fallback, `COPYFILE_CLONE_FORCE`, `COPYFILE_RECURSIVE`
- getiopolicy_np(3) man page: https://keith.github.io/xcode-man-pages/getiopolicy_np.3.html — `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`
- SDK headers (CLT 16.4, MacOSX.sdk): `sys/clonefile.h` (flags, availability 10.12), `sys/attr.h` (`ATTR_CMNEXT_*`, `VOL_CAP_*`), `sys/stat.h` (`SF_DATALESS 0x40000000`), `sys/resource.h` (`IOPOL_*`), `sys/stdio.h` (`RENAME_*`), `sys/fcntl.h` (`F_GETPATH`, `F_GETPATH_NOFIRMLINK`), `copyfile.h`, `CoreServices/CarbonCore/BackupCore.h` (`CSBackupSetItemExcluded`, sticky semantics)
- Apple File System Reference (PDF, 2020-06-22), text extracted locally with PDFKit: https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf — `INODE_WAS_CLONED`, `INODE_WAS_EVER_CLONED` ("the blocks on disk that store this inode might also be in use with another inode … check reference counts before deallocating storage"), physical extent `refcnt` ("The extent can be deleted when its reference count reaches zero"), sibling links for hard links
- Apple File System Guide, FAQ (retired archive doc): https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html — case/normalization preservation and insensitivity, no directory hard links
- Apple File System Guide, Features (retired): https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/Features/Features.html — copy-on-write metadata, fast directory sizing
- SQLite WITHOUT ROWID: https://www.sqlite.org/withoutrowid.html ; WAL and busy-handler facts via research note 04 §8 (https://www.sqlite.org/wal.html)
- tmutil(8) local man page (addexclusion "sticky", isexcluded) and local probe
- Spotlight exclusion: The Eclectic Light Company, "Spotlight search can be blocked by extended attributes", 2025-06-16: https://eclecticlight.co/2025/06/16/spotlight-search-can-be-blocked-by-extended-attributes/ [secondary]; `strings` of `…/Metadata.framework/Versions/A/Support/mds` on 15.7.9 (tokens `.metadata_never_index`, `.metadata_never_index_unless_rootfs`)
- Time Machine on APFS backup volumes (snapshots, no directory hard links): The Eclectic Light Company 2020-06-29 https://eclecticlight.co/2020/06/29/apfs-changes-in-big-sur-how-time-machine-backs-up-to-apfs-and-more/ and Macworld https://www.macworld.com/article/675951/time-machine-finally-gets-support-for-apfs-in-macos-big-sur.html [secondary]
- Claude Code checkpointing limits (Bash changes not tracked, ~30-day sweep, symlinks/hard links skipped on restore): https://code.claude.com/docs/en/checkpointing
- Project documents: research 04 (FSEvents, SQLite, TCC), 05 (competitor storage layouts and pitfalls), 06 (git mechanics and measurements used for comparison); design 11 (registry, hook budgets, `SnapshotEngine` protocol), 13 (product spec, settings defaults)
- Local probes (session scratch directory, deleted after use): `cfprobe/cfprobe.c`, `cfprobe/micro.c`, `cfprobe/conc.c`, `cfprobe/extra.c`, `cfprobe/ci.c`, `cfprobe/ow.c`, `cfswift/` (SwiftPM package), `apfsref/x.swift` (PDF text extraction)
