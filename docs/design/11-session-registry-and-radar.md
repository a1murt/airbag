# 11 — Session registry, hook bridge and process/port radar

Status: design, 2026-10-17 (second pass the same day: machine re-probed, Swift surface completed, reconciled with spec 13 and doc 06). Implements the "hook bridge + session registry" and "server/port radar" rows of the build order in the market report (doc 00 §"Порядок сборки"). Inputs: research docs 01 (Claude Code hooks), 02 (Codex), 03 (Cursor/Gemini/Copilot), 04 (macOS platform), 06 (git snapshot mechanics), 05 (competitors, for the stop protocol and the Baa precedent), plus probes run on this Mac today (macOS 15.7.9, Claude Desktop 2.31226.1 hosting Claude Code 2.1.295, uid 501, no root, no Full Disk Access). Every number and path below is tagged: [verified] = primary source or local probe today, [likely] = strong inference or secondary source, [unverified] = assumption that needs a probe.

Companion designs this document depends on but does not define: the snapshot engine (git object store under `~/Library/Application Support/Airbag/stores/`, orphan commits, refs, retention — doc 06 gives the mechanics) and the circuit-breaker rule engine. Their interfaces as consumed here are pinned in §10.5.

## 0. Decisions

1. One SQLite file, `~/Library/Application Support/Airbag/registry.sqlite`, WAL mode, is the contract between the `airbag` CLI (hook) and `Airbag.app`. The app is never required for protection: the hook evaluates rules, snapshots and writes the registry on its own; when the registry is unavailable it still decides and spools the row to disk.
2. Unix-domain socket `~/Library/Application Support/Airbag/airbag.sock` is a wake-up channel only (one JSON line per hook event, fire-and-forget, 20 ms connect budget). No decision ever waits on the app. `PRAGMA data_version` polling is the fallback when the socket is absent.
3. Session identity is `(agent, agent_session_id)`; a session has one or more *incarnations* `(pid, proc_start)`. Resume, `/clear` and crash are modelled as incarnation changes, not new sessions, because the real orphan on this machine (`next-server` pid 70386) carries a session id whose original `claude` pid is dead while the same session id is live again under a new pid [verified].
4. Process identity everywhere is `(pid, proc_start_us)`; every signal re-validates it. "ppid == 1" is never used as an orphan signal on its own: 255–264 of 299–308 same-uid processes on this machine had ppid 1 in two probes today [verified].
5. Attribution ladder, in order: live ancestry → environment markers via `sysctl KERN_PROCARGS2` (29 µs median per pid, EINVAL for other uids, empty for Apple platform binaries) → remembered ancestry / process group → cwd under a project or worktree → argv match against recorded background commands. Confidence is recorded per process; the UI shows it.
6. Radar cadence: 1 s while the popover is open, 2 s with live sessions, 5 s with tracked listeners only, 10 s idle, 30 s when the display is asleep; plus event-triggered rescans at +0.3 s, +2 s, +10 s after shell events. Full poll budget 3 ms median; env and cwd reads only for candidate pids, cached by process identity.
7. Hook reply budget: typical 60–160 ms (snapshot dominates); soft snapshot deadline 1500 ms; hard watchdog 4000 ms for pre-shell, 800 ms for session-end, 2000 ms otherwise. On deadline the hook prints the already-decided non-deny answer and abandons the snapshot. A deny is decided before any I/O (§4.1 step 4) and never waits on the snapshot or the app; its registry write is bounded by `busy_timeout` 300 ms plus two short retries, then spooled.
8. Fail policy: rules and deny decisions depend only on the binary and a cached rules file; registry/snapshot/app failures degrade to allow + spool + log. The only decision input that lives in the registry is the one-shot allowance for `ask` rules; without the registry, `ask` resolves per its fallback (native prompt or deny-with-explanation), never silently to allow. Strict mode (opt-in) flips the agent-side default (`onFailure: block`, `failClosed: true`) for the pre-shell hook only.
9. `ask` is native on Claude Code (except under `bypassPermissions`, where behaviour is undocumented), Cursor `beforeShellExecution` and Copilot interactive; everywhere else, and under Claude bypass by default, `ask` degrades to deny-with-allowance: the deny reason tells the model the user can approve in Airbag; the app writes an `allow_tokens` row keyed by `(session, sha256(command))`; the retried command is allowed once.
10. Stop semantics: SIGTERM to the process (and its descendants, children first), poll 100 ms for 5 s, then offer SIGKILL as a separate action. Process groups are signalled only when the group leader is the target or already dead and the group contains no protected pid. Agents, their hosts (Claude.app, Cursor.app, Codex.app, Terminal, IDEs), Airbag itself, and anything under `/System` are never signalled.
11. Privacy: never persist stdout/stderr/`tool_response`/`output`; persist command text only after redaction (default: token patterns), with `hash_only` and `off` modes; environment is reduced to an allowlist of marker keys; DB and socket directory are 0700/0600; no network.
12. Worktrees: project identity is the git common dir; worktrees are rows; detection parses `<common>/worktrees/*/{gitdir,HEAD,locked}` directly (no git spawn) and classifies by path (`.claude/worktrees/`, `$CODEX_HOME/worktrees/`, `~/.cursor/worktrees/`), with Codex owner thread read from `codex-thread.json`.

## 1. Scope, components and data flow

```
 agent process (claude | codex | Cursor Helper | gemini | copilot)
   │ spawns hook per event, JSON on stdin, waits for stdout (sync events)
   ▼
 airbag hook <agent>            (AirbagCore: HookBridge + Registry + Rules + SnapshotEngine)
   ├─ parse stdin → HookEnvelope
   ├─ locate agent pid (env, ppid walk)  ──────────────┐
   ├─ open registry.sqlite (WAL, BEGIN IMMEDIATE)       │ writes: projects, worktrees, sessions,
   ├─ rules → decision (never blocks on I/O)            │ session_pids, events, guard_log, snapshots
   ├─ snapshot (git store, flock, deadline)             ▼
   ├─ reply on stdout ◄──────────────────── registry.sqlite ◄──── Airbag.app (Registry, ProcessRadar,
   └─ airbag.sock: {"op":"hook",...} ───────────────────────────►   FSEvents watcher, UI, retention,
                                                                    WAL checkpoints, orphan prompts)
 spool/*.json  (CLI → app, only when the DB write failed)
```

Binaries and targets (from doc 04 §6.2): `AirbagCore` library with sub-modules `AirbagRegistry`, `AirbagHookBridge`, `AirbagProcessRadar`, `AirbagIPC` (plus `AirbagRules`, `AirbagSnapshots` from their own designs); `airbag` executable (`Airbag.app/Contents/Helpers/airbag`, symlinked by the cask as `/opt/homebrew/bin/airbag`); `AirbagApp` executable. All logic lives in `AirbagCore` so Swift Testing can cover it (XCTest is absent on the CLT toolchain [verified, doc 04]).

Filesystem layout under `~/Library/Application Support/Airbag/` (directory 0700, created by whichever binary runs first):

| Path | Owner | Notes |
| --- | --- | --- |
| `registry.sqlite`, `-wal`, `-shm` | both | 0600; §3 |
| `airbag.sock` | app | POSIX listener, 0600, unlinked on start if stale; §5 |
| `app.pid` | app | `{"pid":…,"start_us":…}` of the running app; stale-socket check (§5), `airbag doctor` |
| `spool/<ulid>.json` | CLI writes, both ingest | registry writes that failed; §3.6 |
| `rules/` | app writes, CLI reads | compiled user rules cache (rule-engine design) |
| `stores/<project_id>/` | both | bare git snapshot stores (doc 06 §3; spec 13 §4 uses the same path) |
| `logs/hook.log`, `logs/app.log` | CLI / app | 5 × 1 MB rotation; §4.8 |

## 2. Identity model

| Entity | Natural key | Why |
| --- | --- | --- |
| Project | realpath of the git common dir (`.git` of the main checkout); for non-git folders the realpath of the folder | A worktree, a subdirectory cwd and the main checkout all resolve to one project; `git rev-parse --path-format=absolute --git-common-dir` from a worktree subdirectory returns the main `.git` [verified today]. |
| Worktree | realpath of the worktree root | One snapshot root and one FSEvents stream per worktree; `kind` says who created it. |
| Session | `(agent, agent_session_id)` | Claude `session_id` (changes on `/clear`, stable across `--resume` [verified: pid 99094 runs `--resume=1a2b3c4d…` and `sessions/99094.json` carries the same `sessionId`]); Codex `session_id` = thread id; Cursor `conversation_id`; Gemini `session_id`; Copilot `sessionId`. |
| Incarnation | `(pid, proc_start_us)` of the agent process | Resume creates a new pid for the same session; crash leaves none. |
| Process | `(pid, proc_start_us)` | `pbi_start_tvsec/usec` from `PROC_PIDTBSDINFO`, or `kp_proc.p_starttime` from `KERN_PROC_ALL` [verified, doc 04 §1.5]. Claude Code's own `sessions/<pid>.json` stores `startedAt` (epoch ms, equals `ps lstart` in local time) and `procStart` (the same instant rendered in UTC ctime format: `startedAt=1792208372825` ↔ local `2026-10-16 23:39:32` ↔ `procStart "Sat Oct 17 03:39:32 2026"`) [verified today]; compare `startedAt` to the kernel start time with ±5 s tolerance, never parse `procStart`. |
| Listener | `(process, port, family, address)` | Dual-stack servers bind two sockets (`0.0.0.0:7000` and `:::7000` for ControlCenter) [verified]; the UI groups by `(process, port)`. |

ULIDs (26-char Crockford) are the surrogate ids for projects, worktrees, sessions, snapshots, events and guard rows; they sort by time and are generated by both binaries without coordination.

## 3. Registry: SQLite schema

### 3.1 File, pragmas, connection discipline

System SQLite 3.43.2 (`THREADSAFE=2`, FTS5, JSON functions built in, `STRICT` tables, `RETURNING`, generated columns, `unixepoch()` all work) [verified today]. `import SQLite3`, no third-party dependency.

Open: `sqlite3_open_v2(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE)`; one connection per actor; prepared statements cached per connection.

Per connection, in this order:

```sql
PRAGMA journal_mode = WAL;           -- persistent in the file; first opener sets it
PRAGMA synchronous = NORMAL;         -- commits are not fsynced; durable except power loss (sqlite.org/wal.html)
PRAGMA busy_timeout = 300;           -- CLI; the app uses 5000
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
PRAGMA wal_autocheckpoint = 0;       -- CLI only: the app is the checkpointer (doc 04 §8)
PRAGMA application_id = 0x41524247;  -- 'ARBG', set by migration 1
```

Writes are always `BEGIN IMMEDIATE … COMMIT` (a read transaction that upgrades to a write is refused with `SQLITE_BUSY` immediately, bypassing the busy handler [verified, sqlite.org busy_handler]). Measured on this machine: two processes × 2000 single-row transactions with `busy_timeout=5000` saw zero `SQLITE_BUSY` and a 27 ms worst wait; CLI open + one insert + close ≈ 3 ms [verified, doc 04 §8].

Checkpointing: the app runs `PRAGMA wal_checkpoint(PASSIVE)` every 60 s when the WAL exceeds 4 MB and `wal_checkpoint(TRUNCATE)` once per hour while idle. The CLI `stat`s `registry.sqlite-wal` (free) at the end of every hook and runs `PASSIVE` when it exceeds 16 MB, whether or not the app is running (concurrent PASSIVE checkpoints are safe and restartable), so the WAL cannot grow without bound. PASSIVE never invokes the busy handler and never blocks the hook [verified, sqlite.org pragma page].

### 3.2 DDL (migration 1)

All tables are `STRICT`. Timestamps are `INTEGER` milliseconds since the Unix epoch (`unixepoch('subsec')*1000` or `Date()` from Swift); `proc_start` columns are microseconds. JSON columns are `TEXT` with `json_valid` checks. Booleans are `INTEGER` 0/1.

```sql
CREATE TABLE schema_migrations (
  version     INTEGER PRIMARY KEY,
  applied_at  INTEGER NOT NULL,
  applied_by  TEXT    NOT NULL                 -- 'cli 0.1.0+12' | 'app 0.1.0+12'
) STRICT;

CREATE TABLE settings (                        -- §3.7 lists keys and defaults
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL CHECK (json_valid(value)),
  updated_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE agents (
  kind              TEXT PRIMARY KEY CHECK (kind IN ('claude-code','codex','cursor','gemini','copilot')),
  display_name      TEXT NOT NULL,
  detected          INTEGER NOT NULL DEFAULT 0 CHECK (detected IN (0,1)),
  binary_path       TEXT,
  version           TEXT,
  hooks_state       TEXT NOT NULL DEFAULT 'not_installed'   -- names shared with spec 13 §7.4; 'healthy' is a UI label (installed + recent event)
                    CHECK (hooks_state IN ('not_installed','installed','untrusted','modified','drifted',
                                           'duplicate_route','managed_only','invalid_file','binary_moved')),
  hooks_config_path TEXT,
  hooks_fingerprint TEXT,                      -- sha256 of the Airbag handler entries as written
  hooks_detail      TEXT CHECK (hooks_detail IS NULL OR json_valid(hooks_detail)),
  last_checked_at   INTEGER
) STRICT;

CREATE TABLE projects (
  id            TEXT PRIMARY KEY,              -- ULID
  root_path     TEXT NOT NULL UNIQUE,          -- realpath of main checkout, or of the plain folder
  common_dir    TEXT UNIQUE,                   -- realpath of the git common dir; NULL for 'plain'
  kind          TEXT NOT NULL CHECK (kind IN ('git','plain')),
  display_name  TEXT NOT NULL,
  protected     INTEGER NOT NULL DEFAULT 1 CHECK (protected IN (0,1)),   -- snapshots + breaker apply
  store_path    TEXT,                          -- snapshot store; NULL until the engine creates it
  options       TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(options)),  -- per-project overrides
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL,
  archived_at   INTEGER
) STRICT;

CREATE TABLE worktrees (
  id                     TEXT PRIMARY KEY,
  project_id             TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  path                   TEXT NOT NULL UNIQUE,  -- realpath of the worktree root ('main' row = project root)
  kind                   TEXT NOT NULL CHECK (kind IN ('main','claude','codex','cursor','manual','unknown')),
  name                   TEXT,                 -- basename of <common>/worktrees/<name>
  branch                 TEXT,                 -- from HEAD 'ref: refs/heads/x'; NULL when detached (Codex)
  head_oid               TEXT,
  owner_agent_session_id TEXT,                 -- Codex codex-thread.json ownerThreadId; else NULL
  locked_reason          TEXT,                 -- contents of <common>/worktrees/<name>/locked, '' if empty
  created_at             INTEGER NOT NULL,
  last_seen_at           INTEGER NOT NULL,
  removed_at             INTEGER
) STRICT;

CREATE TABLE sessions (
  id               TEXT PRIMARY KEY,
  agent            TEXT NOT NULL REFERENCES agents(kind),
  agent_session_id TEXT NOT NULL,
  project_id       TEXT REFERENCES projects(id)  ON DELETE SET NULL,
  worktree_id      TEXT REFERENCES worktrees(id) ON DELETE SET NULL,
  cwd              TEXT,                        -- last cwd seen in a hook payload
  launch_root      TEXT,                        -- CLAUDE_PROJECT_DIR / CURSOR_PROJECT_DIR / GEMINI_PROJECT_DIR
  surface          TEXT NOT NULL DEFAULT 'unknown' CHECK (surface IN ('cli','desktop','ide','exec','sdk','unknown')),
  host_session_id  TEXT,                        -- CLAUDE_CODE_HOST_SESSION_ID
  transcript_path  TEXT,
  title            TEXT,
  model            TEXT,
  permission_mode  TEXT,
  discovered_via   TEXT NOT NULL CHECK (discovered_via IN ('hook','env','claude_sessions_file','manual')),
  started_at       INTEGER NOT NULL,
  last_seen_at     INTEGER NOT NULL,
  last_event_kind  TEXT,
  ended_at         INTEGER,
  end_reason       TEXT,                        -- 'hook:<reason>'|'pid_gone'|'stale'|'superseded'|'discovered_dead'
  flags            TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(flags)),   -- {"background":1,"sandbox":1,"subagent_parent":"…"}
  UNIQUE (agent, agent_session_id)
) STRICT;

CREATE TABLE session_pids (                     -- incarnations of the agent process
  id            INTEGER PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  pid           INTEGER NOT NULL,
  proc_start    INTEGER NOT NULL,               -- µs since epoch
  exe_path      TEXT,
  argv0         TEXT,
  ppid          INTEGER,
  pgid          INTEGER,
  host_pid      INTEGER,                        -- Claude.app / Cursor.app / Codex.app main process
  host_start    INTEGER,
  terminal_pid  INTEGER,                        -- first GUI-app ancestor (Terminal, iTerm2, Code, Claude…)
  terminal_app  TEXT,
  tty           TEXT,                           -- 'ttys003' or NULL (desktop chains have none)
  first_seen_at INTEGER NOT NULL,
  last_alive_at INTEGER NOT NULL,
  ended_at      INTEGER,
  UNIQUE (session_id, pid, proc_start)
) STRICT;

CREATE TABLE processes (                        -- only processes the radar decided to track (§6.6)
  id              INTEGER PRIMARY KEY,
  pid             INTEGER NOT NULL,
  proc_start      INTEGER NOT NULL,             -- µs since epoch
  ppid            INTEGER NOT NULL,
  pgid            INTEGER NOT NULL,
  uid             INTEGER NOT NULL,
  exe_path        TEXT,
  name            TEXT NOT NULL,                -- pbi_name / p_comm
  argv            TEXT CHECK (argv IS NULL OR json_valid(argv)),   -- redacted, ≤ 2 KB
  cwd             TEXT,
  class           TEXT NOT NULL CHECK (class IN ('dev','agent','agent_helper','terminal','system','other')),
  ancestry        TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(ancestry)),  -- [[pid,start_us],…] nearest first, at first sight
  env_markers     TEXT CHECK (env_markers IS NULL OR json_valid(env_markers)),  -- allowlisted keys only (§9)
  session_id      TEXT REFERENCES sessions(id)  ON DELETE SET NULL,
  project_id      TEXT REFERENCES projects(id)  ON DELETE SET NULL,
  worktree_id     TEXT REFERENCES worktrees(id) ON DELETE SET NULL,
  attr_method     TEXT CHECK (attr_method IN ('live_ancestry','remembered_ancestry','env_session','env_agent_pid',
                                              'process_group','cwd','argv_match','manual')),
  attr_confidence TEXT CHECK (attr_confidence IN ('high','medium','low')),
  link_state      TEXT NOT NULL DEFAULT 'unknown' CHECK (link_state IN ('attached','detached','orphan','unknown')),
  kept_at         INTEGER,                      -- user said "keep": suppress orphan prompts
  first_seen_at   INTEGER NOT NULL,
  last_seen_at    INTEGER NOT NULL,
  ended_at        INTEGER,
  UNIQUE (pid, proc_start)
) STRICT;

CREATE TABLE listeners (
  id            INTEGER PRIMARY KEY,
  process_id    INTEGER NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
  port          INTEGER NOT NULL CHECK (port BETWEEN 0 AND 65535),
  family        TEXT NOT NULL CHECK (family IN ('ipv4','ipv6')),
  address       TEXT NOT NULL,                  -- '127.0.0.1', '0.0.0.0', '::', '::1', 'fe80::…'
  scope         TEXT NOT NULL CHECK (scope IN ('loopback','any','specific')),
  first_seen_at INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL,
  closed_at     INTEGER,
  UNIQUE (process_id, port, family, address)
) STRICT;

CREATE TABLE snapshots (                        -- index over refs/airbag/snapshots/<id> in the store (doc 06 §5)
  id            TEXT PRIMARY KEY,               -- ULID; equals the ref suffix
  project_id    TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  worktree_id   TEXT REFERENCES worktrees(id) ON DELETE SET NULL,
  session_id    TEXT REFERENCES sessions(id)  ON DELETE SET NULL,
  event_id      TEXT,                           -- the pre_shell event that triggered it
  trigger       TEXT NOT NULL CHECK (trigger IN ('pre_command','post_command','fsevents','manual','pre_restore','startup')),
  commit_oid    TEXT NOT NULL,
  tree_oid      TEXT NOT NULL,
  file_count    INTEGER,
  changed_count INTEGER,                        -- vs previous snapshot of the same worktree
  duration_ms   INTEGER,
  label         TEXT,                           -- e.g. 'Before `npm run db:reset`' (redacted command)
  pinned        INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
  created_at    INTEGER NOT NULL,
  deleted_at    INTEGER
) STRICT;

CREATE TABLE events (
  id            TEXT PRIMARY KEY,               -- ULID
  ts            INTEGER NOT NULL,
  kind          TEXT NOT NULL,                  -- see list below
  agent         TEXT,
  session_id    TEXT REFERENCES sessions(id)   ON DELETE SET NULL,
  project_id    TEXT REFERENCES projects(id)   ON DELETE SET NULL,
  worktree_id   TEXT REFERENCES worktrees(id)  ON DELETE SET NULL,
  process_id    INTEGER REFERENCES processes(id) ON DELETE SET NULL,
  tool_use_id   TEXT,
  dedupe_key    TEXT UNIQUE,                    -- §4.9
  cwd           TEXT,
  command       TEXT,                           -- redacted command text; NEVER output
  command_hash  TEXT,                           -- sha256 hex of the unredacted command
  background    INTEGER CHECK (background IN (0,1)),
  decision      TEXT CHECK (decision IN ('allow','ask','deny','allow_once','allow_fallback','deny_fallback')),
  snapshot_id   TEXT REFERENCES snapshots(id) ON DELETE SET NULL,
  duration_ms   INTEGER,
  payload       TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload))
) STRICT;

CREATE TABLE guard_log (
  id            TEXT PRIMARY KEY,
  ts            INTEGER NOT NULL,
  event_id      TEXT REFERENCES events(id)   ON DELETE SET NULL,
  session_id    TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  project_id    TEXT REFERENCES projects(id) ON DELETE SET NULL,
  agent         TEXT NOT NULL,
  rule_id       TEXT NOT NULL,
  rule_source   TEXT NOT NULL CHECK (rule_source IN ('builtin','user','project')),
  severity      TEXT NOT NULL CHECK (severity IN ('block','ask','warn')),
  decision      TEXT NOT NULL CHECK (decision IN ('deny','ask','allow','allow_once','deny_fallback','allow_fallback')),
  command       TEXT NOT NULL,                  -- redacted
  command_hash  TEXT NOT NULL,
  matched_span  TEXT,                           -- the substring the rule matched (redacted)
  cwd           TEXT,
  reason        TEXT NOT NULL,                  -- the English agent-facing text that was emitted
  snapshot_id   TEXT REFERENCES snapshots(id) ON DELETE SET NULL,
  token_id      TEXT,
  resolved_at   INTEGER,
  resolution    TEXT CHECK (resolution IN ('user_allowed','user_denied','token_used','expired'))
) STRICT;

CREATE TABLE allow_tokens (                     -- one-shot allowances for the ask→deny fallback (§4.6)
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  command_hash  TEXT NOT NULL,
  rule_id       TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,
  used_at       INTEGER,
  UNIQUE (session_id, command_hash, rule_id)
) STRICT;
```

`events.kind` values: `session_start`, `prompt`, `pre_shell`, `post_shell`, `shell_failed`, `pre_edit`, `permission_request`, `stop`, `interrupt`, `subagent_start`, `subagent_stop`, `cwd_changed`, `session_end`, `session_ended_by_sweep`, `session_discovered`, `process_seen`, `process_gone`, `listener_open`, `listener_close`, `attribution_changed`, `orphan_detected`, `stop_requested`, `stop_result`, `snapshot_taken`, `snapshot_skipped`, `snapshot_timeout`, `hook_error`, `registry_degraded`, `worktree_seen`, `worktree_removed`, `app_start`, `app_stop`, `retention_run`. Unknown kinds are rejected by the Swift enum, not by SQL, so a newer CLI can add kinds without a migration.

### 3.3 Indexes

```sql
CREATE INDEX sessions_live        ON sessions(agent, last_seen_at) WHERE ended_at IS NULL;
CREATE INDEX sessions_project     ON sessions(project_id, started_at);
CREATE INDEX session_pids_pid     ON session_pids(pid, proc_start);
CREATE INDEX session_pids_live    ON session_pids(session_id) WHERE ended_at IS NULL;
CREATE INDEX processes_live       ON processes(last_seen_at) WHERE ended_at IS NULL;
CREATE INDEX processes_session    ON processes(session_id) WHERE ended_at IS NULL;
CREATE INDEX processes_project    ON processes(project_id, worktree_id) WHERE ended_at IS NULL;
CREATE INDEX listeners_open       ON listeners(port) WHERE closed_at IS NULL;
CREATE INDEX listeners_process    ON listeners(process_id);
CREATE INDEX events_ts            ON events(ts);
CREATE INDEX events_session_ts    ON events(session_id, ts);
CREATE INDEX events_project_ts    ON events(project_id, ts);
CREATE INDEX events_tool_use      ON events(agent, tool_use_id);
CREATE INDEX guard_ts             ON guard_log(ts);
CREATE INDEX guard_open           ON guard_log(session_id) WHERE resolved_at IS NULL;
CREATE INDEX snapshots_project_ts ON snapshots(project_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX worktrees_project    ON worktrees(project_id) WHERE removed_at IS NULL;
CREATE INDEX allow_tokens_lookup  ON allow_tokens(session_id, command_hash) WHERE used_at IS NULL;
```

### 3.4 Retention (app only, hourly, inside one `BEGIN IMMEDIATE`, batches of 2 000 rows, re-scheduled if `SQLITE_BUSY`)

| Table | Rule | Default |
| --- | --- | --- |
| `events` | delete where `ts < now - retention.eventsDays`; then keep at most `retention.maxEvents` newest | 30 days / 200 000 rows |
| `guard_log` | `ts < now - retention.guardDays` | 90 days |
| `allow_tokens` | `expires_at < now` or `used_at IS NOT NULL` older than 1 day | 10 min lifetime |
| `processes` + `listeners` | `ended_at < now - retention.processesDays`; rows with `ended_at IS NULL` are never deleted here (the sweep closes them) | 7 days |
| `session_pids` | with the session | — |
| `sessions` | `ended_at < now - retention.sessionsDays` and no `snapshots` row references it | 90 days |
| `worktrees` | `removed_at < now - 30 days` | 30 days |
| `snapshots` | rows mirror refs: deleted when the engine deletes the ref (`deleted_at` set), purged 30 days later; a reconciliation pass lists `refs/airbag/snapshots/` and repairs drift in either direction | — |
| `projects` | never automatically; `archived_at` hides them | — |

Never `VACUUM` automatically; offer "Compact database" in Settings (`VACUUM` needs 2× space and an exclusive lock).

### 3.5 Migrations

- `PRAGMA user_version` holds the schema version; `schema_migrations` is the audit trail. `AirbagRegistry.Migrations.all: [Migration]` is an ordered array of `(version, up: (Connection) throws -> Void)`; SQL-only migrations are plain strings.
- Open sequence (both binaries): read `user_version` outside a transaction → if `< latest`: `BEGIN IMMEDIATE`, re-read `user_version` (another process may have migrated meanwhile), apply pending migrations in order, `PRAGMA user_version = N`, insert into `schema_migrations`, `COMMIT`. Migration time is bounded (ms) because the file is small; the CLI may do it because both binaries ship in the same bundle and are always the same version.
- If `user_version > latest known`: open read-only, mark the registry `degraded(.schemaNewer)`; the hook still decides and spools; the UI shows "update Airbag". This happens only when a user runs an old CLI against a DB migrated by a newer app (Homebrew upgrade with a hook path pointing at an old copy).
- If `application_id != 0x41524247` and the file is non-empty: refuse, rename to `registry.sqlite.foreign-<ts>`, create a fresh file, log `registry_degraded`.
- Rules for writing migrations: additive first (`ALTER TABLE … ADD COLUMN` with defaults, new tables, new indexes); destructive changes rebuild the table (`CREATE TABLE new … ; INSERT … SELECT …; DROP; ALTER … RENAME`) inside the same transaction; never change `STRICT` column types in place; `CHECK` lists (enums) are widened by table rebuild, which is why most enums are also enforced in Swift.
- Corruption (`SQLITE_CORRUPT`, `SQLITE_NOTADB`): rename the file aside (`registry.sqlite.corrupt-<ts>`), recreate, log; snapshot refs in the stores remain the source of truth for snapshots and are re-indexed by the reconciliation pass.

### 3.6 Two writers, busy policy, spool

- CLI: `busy_timeout = 300` ms (hook budget), retry `BEGIN IMMEDIATE` twice with 20–60 ms jitter; on persistent `SQLITE_BUSY`/`SQLITE_LOCKED`/degraded registry the hook writes the pending rows as one JSON document to `spool/<ulid>.json` (write to `spool/.tmp-<ulid>` then `rename(2)`), logs, and proceeds. The decision was already made; only persistence is deferred.
- App: `busy_timeout = 5000` ms; all radar writes are batched per poll into one transaction (`observe(RadarDelta)`), so the hook's writes queue for at most one short transaction.
- Spool ingestion: the app ingests on start, on `{"op":"spool"}` and every 60 s; the CLI ingests up to 20 files at the end of a hook when it has a healthy connection and > 50 ms budget left, so the registry converges without the app. Ingestion is idempotent through `events.dedupe_key` and `UNIQUE` constraints (`INSERT OR IGNORE` for events; `INSERT … ON CONFLICT DO UPDATE` for sessions/pids).
- Readers (UI) use a separate connection and `PRAGMA data_version` (value changes when another connection committed; comparable only on the same connection [verified, sqlite.org]) polled every 1 s while visible to decide when to re-query.

### 3.7 Settings keys (JSON values; defaults applied when the key is absent)

| Key | Default | Used by |
| --- | --- | --- |
| `hook.snapshotDeadlineMs` | `1500` (UI range 500–10 000; spec 13 §7.4 currently shows "3 s default" — reconcile, §12 item 16) | CLI |
| `hook.hardDeadlineMs` | `{"preShell":4000,"sessionEnd":800,"other":2000}`; effective `preShell = max(4000, snapshotDeadlineMs + 1500)` | CLI |
| `hook.busyTimeoutMs` | `300` | CLI |
| `hook.strictMode` | `false` (installer writes `onFailure:"block"` / `failClosed:true` when `true`) | installer |
| `hook.askFallback` | `{"claude-code":"native","codex":"deny_with_allowance","cursor":"native","gemini":"deny_with_allowance","copilot":"native"}` | CLI |
| `hook.askUnderBypass` | `"deny_with_allowance"` (Claude `permission_mode == bypassPermissions`; `ask` there is undocumented [unverified]) | CLI |
| `redaction.mode` | `"tokens"` (`"hash_only"`, `"off"`) | CLI, app |
| `redaction.extraPatterns` | `[]` (regexes added to the built-in list, §9) | CLI |
| `radar.enabled` | `true` | app |
| `radar.intervalsMs` | `{"popover":1000,"active":2000,"semi":5000,"idle":10000,"asleep":30000}` | app |
| `radar.showSystem` | `false` | app |
| `radar.extraDevNames`, `radar.ignoreNames` | `[]`, `[]` | app |
| `radar.orphanPrompt` | `true` | app |
| `radar.orphanGraceSec` | `20` | app |
| `radar.autoStopOrphansAfterMin` | `0` (off; reserved key, read but not exposed in the v1 UI — spec 13 §7.2 offers no auto-stop) | app |
| `projects.options.onSessionEnd` (per project, inside `projects.options`) | `"ask"` (`"silent"` lists orphans without prompting; spec 13 §7.4 "On session end") | app |
| `radar.protectedAppPrefixes` | list in §6.7 | app |
| `session.endGraceSec` | `15` | app |
| `session.staleHoursSharedHost` | `2` (Codex app-server, Cursor IDE: §8) | app |
| `retention.*` | §3.4 | app |
| `ipc.socketEnabled` | `true` | both |
| `log.level` | `"info"` | both |
| `locale` | `"auto"` | both |

## 4. Hook bridge

### 4.1 Entry point and pipeline

`airbag hook <agent> [<event-hint>]` — `<agent>` ∈ `claude-code | codex | cursor | gemini | copilot` is the *declared* source (what the installer wrote); `<event-hint>` is optional and only used by Codex configs that register one command per event (doc 02 §10). Payload shape wins over the declaration when they disagree (Cursor imports `~/.claude/settings.json` hooks and would call the Claude entry with a Cursor payload, doc 03 §3.6): the mismatch is logged, the shape-detected adapter is used.

```
 0. arm watchdog (deadline by event kind, §4.2); pre-compose the "safe response" for the declared agent
 1. read stdin to EOF, cap 1 MiB (larger → treat as unknown event → safe response)
 2. parse JSON; adapter = AgentAdapter.detect(payload) ?? declared; envelope = adapter.parse(payload)
 3. resolve project/worktree from envelope.cwd by filesystem walk (§7.4): no git spawn, no DB
 4. preShell / permissionRequest only: verdict = rules.evaluate(request, agent, project, worktree, permissionMode)
    (pure, in-memory: built-in rules + the `rules/` cache the app compiles). The verdict is final before any I/O below.
 5. locate the agent process: env first (CLAUDE_PID), then bounded ppid walk (§4.3) → AgentLocation
 6. open registry (role .cli, busy_timeout 300 ms); on failure → degraded, continue
 7. BEGIN IMMEDIATE (≤ 2 retries, 20–60 ms jitter): upsert project, worktree, session, incarnation; append event
    (dedupe hit → reply with the stored decision, skip 8); verdict == ask → consumeAllowance; COMMIT.
    SQLITE_BUSY / degraded → SpoolBatch on disk, continue with the same verdict.
 8. switch event:
      preShell          → deny          → guard row (DB or spool), reply deny (no snapshot)
                          ask           → resolve per §4.6: native ask | allowance consumed → allow_once | deny_with_allowance
                          allow/allow_once → snapshot(deadline) → reply
      permissionRequest → deny → reply deny (Codex only); otherwise print nothing
      postShell/shellFailed → update the paired pre_shell event (duration, interrupted, spilled)
      sessionStart/prompt/stop/cwdChanged/subagent* → registry only
      sessionEnd        → end session (reason 'hook:<reason>'); no snapshot
 9. ingest ≤ 20 spool files if healthy and > 50 ms budget left
10. airbag.sock: send {"op":"hook",…} (non-blocking, 20 ms)
11. print exactly one JSON object (or nothing where the agent requires it) and exit
```

A deny therefore depends on steps 1–4 only (≈ 2 ms). Its persistence (step 7) costs 3–5 ms normally and at most `busy_timeout` + retries ≈ 420 ms under contention before the spool takes over; it is never skipped, because the guard log is the audit trail the UI shows.

Exec form everywhere a shell is not needed (`"command": "/…/airbag", "args": ["hook","claude-code"]` for Claude, `exec`/`args` for Copilot): no `sh -c`, no quoting problems with `Application Support`, ~2.5 ms less per call [verified, doc 01 §12]. Codex, Cursor and Gemini take a command string; the installer writes the absolute path quoted.

### 4.2 Budgets and deadlines

| Step | Typical | Source |
| --- | --- | --- |
| agent spawns hook (exec form) | 1.4 ms (3.8 ms shell form) | doc 01 §12 [verified] |
| stdin + JSON parse | < 1 ms | Foundation `JSONSerialization` on ≤ 10 KB payloads |
| locate agent (≤ 6 `proc_pidinfo` hops) | < 0.5 ms | `PROC_PIDTBSDINFO` all pids 0.17–0.24 ms [verified, doc 04] |
| registry open + one transaction | 3–5 ms | doc 04 §8 [verified] |
| rules | < 1 ms | in-memory |
| snapshot, warm, 20k files, no change | ~140 ms end-to-end (walker 22–26, `update-index` 43–47, `write-tree` 10, `commit-tree`+`update-ref` 19–22, 4 git spawns ≈ 8 ms each) | doc 06 §9 [verified] |
| snapshot, 2 000 changed files | ~850 ms | doc 06 §9 [verified] |
| snapshot, cold (first ever, 20k files) | 6–8 s → never inside a hook; the app primes the store at project registration; the hook skips with `snapshot_skipped(cold)` | doc 06 §3 [verified] |
| socket notify | < 0.1 ms | doc 04 §7 [verified] |

Targets: pre-shell p50 < 300 ms, p95 < 2 s on a 50k-file repo (same numbers doc 03 §8.5 set as the budget). Deadlines: `hook.snapshotDeadlineMs` (1500) bounds the snapshot step; the watchdog thread fires at `hook.hardDeadlineMs` (pre-shell 4000, session-end 800 because Claude Code's SessionEnd budget is 1.5 s and Codex's is 1 s default / 3 s max [verified, docs 01 §5.3, 02 §2.2], other 2000). On fire: kill the git child's process group, atomically claim the output slot, write the safe response (the already-decided allow/ask shape, or the deny if one was decided), `_exit(0)`. The main path claims the same slot before printing, so there is never a double print. Agent-side timeouts the installer writes are deliberately above the watchdog: Claude 30 s (`PreToolUse`), 5 s (`SessionStart`), 1 s (`SessionEnd`); Codex 30 / 5 / 2 s; Cursor 20 / 5 / 5 s; Gemini 20 000 / 5 000 ms; Copilot 20 / 5 s (docs 01 §6.1, 02 §10, 03 §3.10/§4.8/§5.8).

### 4.3 Finding the agent process

Primary signal: environment. Claude Code sets `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` in hook processes (verified capture, doc 01 §7; also present in this Bash tool shell today), and `CLAUDE_CODE_EXECPATH` names the running binary, which must equal `proc_pidpath(CLAUDE_PID)` for the env hit to count. Gemini sets `GEMINI_SESSION_ID` for hooks [verified, hookRunner.ts]. Codex sets nothing hook-specific; Cursor sets `CURSOR_PROJECT_DIR`/`CURSOR_VERSION` but no pid; Copilot `COPILOT_CLI=1` [likely]. When a pid is given, verify it is alive and is an ancestor (or, under Codex's future exec-server, at least alive and matching the agent pattern); otherwise fall back to the walk.

Walk: `pid = getppid()`; loop ≤ 32 hops: `proc_pidinfo(pid, PROC_PIDTBSDINFO)` → `(pid, start, ppid, pgid, e_tdev)`, `proc_pidpath(pid)`; stop at `ppid <= 1`, `EPERM`, `ESRCH`. For `node`/`sh`/`bash`/`zsh` hops read argv with `KERN_PROCARGS2` (same uid, 29 µs [verified today]) to disambiguate. Never match on the shell: `/bin/sh` re-execs as `/bin/bash` and `sh -c "<one command>"` exec-optimises the shell away [verified, doc 04 §2].

| Agent | Match the agent pid when | Surface / host | Verified chain |
| --- | --- | --- | --- |
| Claude Code | `proc_pidpath` ends with `/claude.app/Contents/MacOS/claude` (desktop bundle under `~/Library/Application Support/Claude/claude-code/<ver>/…`), or basename `claude` (native npm/brew binary), or `node` whose argv[1] ends with `/claude` or contains `@anthropic-ai/claude-code` [likely for the node form] | parent `…/Claude.app/Contents/Helpers/disclaimer` + grandparent `/Applications/Claude.app/Contents/MacOS/Claude` → `desktop`, `host_pid` = Claude.app; `CLAUDE_CODE_ENTRYPOINT=claude-desktop` corroborates; ancestor inside `Visual Studio Code.app`/`Cursor.app`/JetBrains → `ide` [likely]; tty present and ancestor Terminal/iTerm2/… → `cli` | `airbag ← claude ← disclaimer --pgroup ← Claude ← launchd` (exec form; a `zsh` hop appears for Bash tool children, not hooks) [verified today, pids 800→11328→11327→94586→1]. The `sh → node` tail named in the brief does not exist in the desktop chain [verified]. |
| Codex | basename `codex`, `codex-aarch64-apple-darwin`, `codex-x86_64-apple-darwin`; argv contains `app-server` (app/IDE), `exec` (headless) or `mcp-server` | ancestor inside `Codex.app` or `ChatGPT.app` (bundle `com.openai.codex`) → `desktop`; `exec` → `exec`; else `cli` | hook is `$SHELL -lc "<cmd>"` spawned with `POSIX_SPAWN_SETSID` directly by the Codex process: hook's parent is the login shell (or Codex itself if the shell exec'd), grandparent Codex [verified from source, doc 02 §2.6]; a TODO moves hooks to an exec server, so the walk is bounded and argv-matched, not fixed-depth. |
| Cursor IDE | ancestor `Cursor Helper (Plugin)` with argv containing `extension-host`, then `/Applications/Cursor.app/Contents/MacOS/Cursor` | `ide`; `host_pid` = Cursor | forum/staff-confirmed chain for agent shells [verified: staff reply, doc 03 §3.8]; hook chain [likely] identical. |
| Cursor CLI | basename `cursor-agent` under `~/.local/share/cursor-agent/versions/<ver>/`, or `node` from the same directory | `cli` | [likely, doc 03 §3.7]. |
| Gemini | `node` whose argv contains `gemini` (`@google/gemini-cli` or Homebrew `gemini-cli` path) | `cli` | hook is `bash -c` child of the node process [verified, hookRunner.ts]. |
| Copilot | basename `copilot` (Rust engine, log says "Rust JSON-RPC engine") or `node` with argv containing `@github/copilot` | `cli` | [likely, doc 03 §5.7]. |

Record per incarnation: agent `(pid, start)`, `exe_path`, `argv0`, `ppid`, `pgid`, `host_pid/host_start` (Electron main), `terminal_pid/terminal_app` (first ancestor whose path matches `/Applications/*.app/Contents/MacOS/*` or `/System/Applications/Utilities/Terminal.app/…`), `tty` (`devname(e_tdev, S_IFCHR)` when `e_tdev != 0xFFFFFFFF`; desktop chains have none [verified, doc 04 §2]). No match within 32 hops → no `session_pids` row is written (the session row is still upserted and the event carries `payload.locate = "none"`); the radar later attributes through env markers.

### 4.4 Per-agent I/O contract

| | Claude Code | Codex | Cursor | Gemini | Copilot |
| --- | --- | --- | --- | --- | --- |
| Events registered | `SessionStart`, `UserPromptSubmit`, `PreToolUse` + `PostToolUse` + `PostToolUseFailure` matcher `Bash\|PowerShell\|Monitor`, `Stop`, `CwdChanged`, `SessionEnd` | `SessionStart`, `UserPromptSubmit`, `PreToolUse ^Bash$`, `PreToolUse ^apply_patch$` (pre-edit snapshot), `PermissionRequest ^Bash$`, `PostToolUse ^Bash$` (`async`), `Stop`, `Interrupt`, `SessionEnd` | `sessionStart`, `sessionEnd`, `beforeShellExecution`, `afterShellExecution`, `beforeSubmitPrompt`, `stop` | `SessionStart`, `SessionEnd`, `BeforeTool run_shell_command`, `AfterTool run_shell_command`, `BeforeAgent` | `sessionStart`, `sessionEnd`, `preToolUse bash\|powershell`, `postToolUse bash\|powershell`, `userPromptSubmitted` |
| Session id | `session_id` | `session_id` (thread) | `conversation_id` | `session_id` | `sessionId` / `session_id` |
| Command | `tool_input.command` | `tool_input.command` | `command` | `tool_input.command` | `toolArgs.command` (object **or** JSON string) |
| cwd | `cwd` | `cwd` | `cwd`, else `workspace_roots[0]` | `tool_input.dir_path` resolved against `cwd`, else `cwd` | `cwd` |
| Background flag | `tool_input.run_in_background` | — | — | `tool_input.is_background` | — |
| Allow | `{}` or `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}` — use `{}`: it never collides with deny/ask rules and is not even needed to proceed | print **nothing**, exit 0 (`allow` without `updatedInput` is marked Failed [verified, doc 02 §2.5]) | `{"permission":"allow"}` | `{}` | `{}` |
| Ask | `permissionDecision:"ask"` + `permissionDecisionReason` | unsupported → fallback | `{"permission":"ask","user_message":…,"agent_message":…}` (only on `beforeShellExecution`) | `{"decision":"ask"}` exists in source but is undocumented → fallback by default, opt-in `native` | `{"permissionDecision":"ask",…}` (autopilot/cloud turn it into deny — the fallback path still works) |
| Deny | `permissionDecision:"deny"` + reason, exit 0 | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…non-empty…"}}`, exit 0 | `{"permission":"deny","user_message":…,"agent_message":…}` | `{"decision":"deny","reason":"…","systemMessage":"…"}`, exit 0 | `{"permissionDecision":"deny","permissionDecisionReason":"…"}` |
| PermissionRequest deny | not registered | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"…"}}}` | — | — | — |
| stderr | never (exit 0 hides it anyway) | never | never | **never**: empty stdout makes Gemini parse stderr [verified, doc 03 §4.5] | never |
| Agent-side default on hook crash / timeout | open / open; `onFailure:"block"` flips (strict) | open / open | open unless `failClosed` (strict); invalid JSON blocks regardless | open (exit 1) but exit ≥ 2 with non-JSON text = deny | **crash = deny**, timeout = open |

Localization split (doc 03 §8.11): user-facing fields (`user_message`, `systemMessage`, Airbag UI) follow `locale`; agent-facing fields (`permissionDecisionReason`, `agent_message`, `reason`) are always English and end with the recovery instruction: `Airbag blocked \`git reset --hard\`: 14 uncommitted files would be lost. Snapshot 01JC… was taken. Ask the user to approve this command in Airbag, then run it again.`

### 4.5 Session upsert semantics

- Key `(agent, agent_session_id)`. First sight of a key creates the row with `discovered_via='hook'`, `started_at = now` (or the agent's own timestamp when the payload has one: Copilot `timestamp`, Gemini `timestamp`), `surface`, `launch_root`, `transcript_path`, `title` (Claude `session_title`, Codex none, Cursor none).
- Every event updates `last_seen_at`, `last_event_kind`, `cwd`; when `cwd` changes, project/worktree are re-resolved (worktree entry moves `cwd` to the worktree root [verified, doc 01 §8]).
- Incarnation: when the located agent `(pid, start)` is not the live incarnation, close the previous one (`ended_at = now`) and insert the new one. Covers `--resume`, desktop re-launch, Codex app-server restart.
- Claude `SessionStart` with `source: clear` under the same pid: the previous session row (same pid, different id) gets `ended_at`, `end_reason = 'superseded'`.
- `SessionStart` with `source: resume|compact|fork` never ends anything. Codex `SessionStart` is "first turn of a thread" [verified, doc 02 §2.4], so `UserPromptSubmit` is the dependable "alive" signal there.
- Subagent events (`agent_id`/`agent_type` present): stay on the parent session; the event row carries `payload.agent_id`. No session rows for subagents in v1.
- Cursor `is_background_agent`, `sandbox`; Codex `permission_mode`, `model`: stored in `flags`/columns, never used for decisions except `sandbox` (rule engine relaxes "rm outside project" when sandboxed, doc 03 §8.10).
- Session end via hook: `ended_at = now`, `end_reason = 'hook:<reason>'` (`clear|resume|logout|prompt_input_exit|other|completed|aborted|window_close|user_close|exit|complete|error|abort|timeout|user_exit`). Copilot `-p` fires `sessionEnd` per completed turn with `reason: complete` [verified, doc 03 §5.3]: treat `complete` from Copilot as *turn end* (update `last_seen_at`) unless the pid is gone.

### 4.6 Decision, snapshot ordering, ask fallback, allowances

Order inside `preShell`: (1) rules; (2) if `deny`, reply at once (no files change on a deny, so no snapshot; `guard_log` row with `decision='deny'`); (3) otherwise snapshot with the deadline; (4) reply `allow`, or `ask` resolved per agent.

Ask resolution (`hook.askFallback[agent]`, and `hook.askUnderBypass` when Claude reports `permission_mode == "bypassPermissions"` — observed today on a desktop session, pid 99094 [verified]):

- `native`: emit the agent's ask shape (Claude, Cursor `beforeShellExecution`, Copilot interactive; Claude's `ask` is honoured in `auto` mode since 2.1.211 and becomes a deny in `dontAsk`/unattended `-p` [verified, doc 01 §4.3]).
- `deny_with_allowance`: emit deny; `guard_log.decision='ask'`→ stored as `deny_fallback`; the app shows the guard entry with "Allow once"/"Deny"; "Allow once" inserts `allow_tokens(session_id, sha256(command), rule_id, expires_at = now + 10 min)` and resolves the guard row. On the retried command the hook finds an unused, unexpired token for the same session and command hash, marks `used_at`, logs `allow_once`, snapshots, and replies allow. No token string travels through the model; the hash binds the allowance to the exact command text. When the registry is degraded the allowance cannot be looked up, so `ask` resolves as if no token existed (native ask, or the same deny-with-explanation) — never as a silent allow.
- `allow_snapshot`: snapshot and allow (for users who want zero interruptions on Codex/Gemini); the guard row is still written with `decision='allow_fallback'`.

Snapshot pairing: `pre_shell` event id → `snapshots.event_id`; `post_shell`/`shell_failed` with the same `tool_use_id` (Claude, Codex, Copilot) or `generation_id + command_hash` (Cursor) or `session + command_hash + 60 s` (Gemini) updates `duration_ms`, `payload.interrupted`, `payload.spilled` and lets the UI label "Before `cmd` → changed N files".

### 4.7 Fail-open / fail-closed matrix (Airbag's side)

| Failure | Decision | Snapshot | Persistence | Reply |
| --- | --- | --- | --- | --- |
| Registry busy / locked / read-only / corrupt | unaffected (rules + `rules/` cache); one-shot allowances cannot be consumed, so `ask` resolves per fallback | attempted (store needs no DB) | spool file | normal |
| Snapshot store missing/cold/locked | unaffected | skipped (`snapshot_skipped` with reason) | DB | normal; UI banner |
| Snapshot exceeds deadline | unaffected | abandoned, git pgid killed, `snapshot_timeout` | DB | watchdog prints the decided answer |
| Agent process not found | unaffected | normal | session without incarnation | normal |
| Payload unparseable / unknown event | no decision | none | `hook_error` (spool if needed) | safe response for the declared agent |
| stdin > 1 MiB | no decision | none | `hook_error` | safe response |
| Swift runtime trap | — | — | — | agent default applies (Copilot: deny). Mitigation: no force unwraps on payload data, fuzz tests (§11), `strictMode` is opt-in |

Strict mode only touches the pre-shell handlers: Claude `onFailure:"block"` (2.1.295+), Cursor `failClosed:true`; Codex, Gemini and Copilot have no fail-closed switch (Copilot already denies on error).

### 4.8 Logging

- stdout is the protocol channel; stderr is never written except as the reason text with exit 2 — and exit 2 is not used by Airbag (JSON deny is used everywhere, so stderr stays empty for Gemini's parser).
- `logs/hook.log`: one line per invocation, `ts level pid agent event session_short cwd_short decision snapshot_ms total_ms [note]`, no command text at `info`, redacted command at `debug`; rotation 5 × 1 MB; `AIRBAG_HOOK_DEBUG=1` or `log.level=debug` raises verbosity. `os_log` subsystem `dev.airbag.hook` mirrors `error`/`fault` for Console.app.
- `events.payload.timing = {parse, locate, db, rules, snapshot, total}` on every pre-shell event so the UI can show "hook overhead p50/p95 per project" and the test-suite can assert budgets.

### 4.9 Dedupe (Cursor's Claude-hooks import, Copilot's `.claude/settings.json` import)

`events.dedupe_key`:
- Claude/Codex/Copilot: `"<agent>:<tool_use_id>:<kind>"` when `tool_use_id` exists.
- Cursor: `"cursor:<conversation_id>:<generation_id>:<sha256(command)>:<kind>"`.
- Gemini: `"gemini:<session_id>:<sha256(command)>:<floor(ts/3s)>:<kind>"`.
- Lifecycle events: `"<agent>:<session>:<kind>:<floor(ts/1s)>"`.

A second route for the same shell command (Cursor native `beforeShellExecution` plus imported Claude `preToolUse`) hits the `UNIQUE` on `dedupe_key`: the second invocation sees the existing event, skips rules and snapshot, and replies with the first decision stored in `events.decision`. The installer additionally refuses to write Claude-format hooks for Cursor and reports duplicate routes in `airbag doctor` (doc 03 §8.2).

### 4.10 Hook configuration summary

Full JSON blocks: Claude doc 01 §6.1, Codex doc 02 §10, Cursor doc 03 §3.10, Gemini §4.8, Copilot §5.8. Airbag's deltas: register the event lists from §4.4; exec form for Claude and Copilot; `async: true` on Codex `PostToolUse`; one absolute path per machine chosen at install (`/Applications/Airbag.app/Contents/Helpers/airbag` or the cask symlink `/opt/homebrew/bin/airbag`) and never changed afterwards (Codex hashes the command string for trust [verified, doc 02 §2.7]); user scope only, never project files.

## 5. IPC CLI ↔ app

Decision: SQLite is the contract; a Unix-domain socket is the wake-up. Measured on this machine: POSIX socket round trip 4 µs, `LOCAL_PEERPID`/`LOCAL_PEERCRED` give the hook's pid and uid for free; `NWListener` creates the socket file 0755 (so POSIX is used server-side); XPC would need a launchd `MachServices` job and `SMAppService.agent` [verified, doc 04 §7]. `DistributedNotificationCenter` has no sender identity and no delivery guarantee; not used. Doc 04 §7 and spec 13 §4 sketch an optional ≤ 50 ms wait for a `{"snapshot":"ok"}` acknowledgement; this design drops it: the hook owns the snapshot (protection must hold with the app closed), so there is nothing for the app to acknowledge, and a wait would only add latency when the app is busy. The app learns everything from the registry; the socket exists so the UI updates within ~1 ms of a hook instead of on the next `data_version` poll.

Protocol: newline-delimited UTF-8 JSON, one frame per connection from the CLI (connect → write → close; the app never needs to answer), ≤ 64 KB per frame.

```json
{"v":1,"op":"hook","ts":1792281782889,"agent":"claude-code","event":"pre_shell","session":"01JC…","agent_session_id":"65cff7d1-…","project":"01JB…","worktree":"01JB…","event_id":"01JC…","background":false,"decision":"allow","snapshot":"01JC…","cwd":"/Users/…/qost"}
{"v":1,"op":"spool","ts":…,"count":3}
{"v":1,"op":"ping","ts":…}
```

Ops: `hook` (any event; the app uses `event`/`background`/`decision` to schedule radar pokes at +0.3/+2/+10 s and to refresh the timeline), `spool`, `ping` (the app answers `{"ok":true,"app_pid":…}` only to `ping`; used by `airbag doctor`), `session_end` is just `hook` with `event: "session_end"`.

CLI side: `socket(AF_UNIX, SOCK_STREAM)`, `O_NONBLOCK`, `connect` → `EINPROGRESS` → `poll` 20 ms; `ENOENT`/`ECONNREFUSED`/timeout → skip silently (app not running). Write with `MSG_NOSIGNAL` equivalent (`SO_NOSIGPIPE`). Total cost < 0.2 ms.

App side: `umask(077)`, unlink stale socket after checking no live app owns it (the app writes `app.pid` next to it and checks `(pid, start)`), `bind`, `listen(16)`, `DispatchSource.makeReadSource`; on accept read `LOCAL_PEERCRED` and drop connections whose `uid != getuid()`; parse one line; close. Directory 0700 so the 0600 socket cannot be reached by other users.

Fallback with no socket: the app polls `PRAGMA data_version` every 1 s while the popover is open, 5 s otherwise, and re-queries on change.

App → CLI direction: none. Settings, allowances and project registration flow through the registry; the CLI reads them in the same transaction it writes.

## 6. Radar

### 6.1 Cadence and budgets

| State | Condition | Interval | Work per tick |
| --- | --- | --- | --- |
| popover | radar UI visible | 1 s | A + B + D for displayed rows |
| active | ≥ 1 live session (§8) | 2 s | A + B + C/D for candidates |
| semi | no live session, ≥ 1 tracked listener or orphan | 5 s | A + B |
| idle | nothing tracked | 10 s | A + B |
| asleep | `NSWorkspace.screensDidSleepNotification` / session resigned active | 30 s | A only |

Tiers: **A** `sysctl KERN_PROC_ALL` → `[kinfo_proc]` for every process incl. zombies (`p_stat == 5`), 0.07–0.08 ms [verified, doc 04]; this is the only source of ppid/pgid/start for the tree and of liveness (`ESRCH` from `proc_pidinfo` = gone; `kill(pid,0)==0` means nothing [verified]). **B** `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` over same-uid pids (0.8–1.4 ms for 275–377 visible pids; `insi_lport` is network byte order; `INI_IPV6` selects the address union) [verified, doc 04 §1.3–1.4]. **C** `proc_pidpath` (exe) and `KERN_PROCARGS2` (argv + env markers) for *candidate* pids only, cached by `(pid, start)`: a full sweep of 311 same-uid pids cost 12.5 ms from Python (29 µs median, 67 µs p95, 292 µs max per pid), other-uid → `EINVAL`, Apple platform binaries such as `rapportd`/`ControlCenter` return `argc=1` and zero environment [verified today]. **D** `PROC_PIDVNODEPATHINFO` (cwd) for candidates; `proc_pid_rusage` (`ri_phys_footprint`) and `PROC_PIDTASKINFO` (CPU ticks, Mach units × timebase) for displayed/tracked rows.

Candidate = same-uid pid that is new since the previous tick, or has a listener, or is a descendant of a live agent incarnation, or has a remembered attribution. Pids whose exe path (first sight only) is under `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/Library/Apple/` are classed `system` immediately and get no env/cwd reads.

Event pokes: `pre_shell` with `background=true`, `post_shell`, `stop`, `session_end`, `session_start` → B at +300 ms (debounced), then +2 s and +10 s (servers bind late). Budget: ≤ 3 ms median per tick at 500 pids, ≤ 50 ms on the first tick (exe + env for all same-uid pids), < 0.2 % of one core at 2 s. Memory: process cache capped at 4 096 `(pid,start)` entries, LRU; the app's measured idle footprint is 14 MB [verified, doc 04 §5.3].

### 6.2 Per-process record

`RadarProcess` (persisted as `processes` + `listeners` only for tracked classes `dev`, `agent`, `agent_helper`, and anything attributed): `key (pid, start_us)`, `ppid`, `pgid`, `uid`, `exe_path`, `name`, `argv` (redacted, ≤ 2 KB, first 32 args), `cwd`, `startedAt`, `rss_bytes` (`ri_phys_footprint`, the Activity Monitor number [verified]), `cpu_pct` (delta of user+system ticks / wall between ticks), `cpu_time_ns`, `listeners [port, family, address, scope]`, `ancestry` (chain of `(pid,start)` at first sight, nearest first, up to 32), `env_markers` (allowlist §9), `attribution`, `link_state`, `class`, `protection`, `kept_at`. `rss_bytes`, `cpu_pct` and `cpu_time_ns` are live-only and never persisted; the `processes` row holds identity, classification and attribution only.

### 6.3 Attribution ladder

Evaluated per candidate on every tick in this order; the first rule that yields a session wins for `session_id`; project/worktree are filled by the first rule that yields them (a later rule may add a project to an env-only hit).

1. **live_ancestry** (HIGH): some ancestor `(pid,start)` in the tick's tree equals a live incarnation in `session_pids`. Direct children of the agent are classified `agent_helper` (MCP servers via `npm exec …`, the Bash tool `zsh -c source ~/.claude/shell-snapshots/…`, `sandbox-exec` wrappers) [verified today: the only `node` children of the `claude` pids are MCP servers]; their descendants are `dev` if they listen or match §6.6.
2. **env_session** (HIGH when the session exists; MEDIUM when it had to be *discovered*): `CLAUDE_CODE_SESSION_ID` → `sessions(agent='claude-code', agent_session_id)`; `CODEX_THREAD_ID` (always injected into shell-tool children, even under `include_only` policies) then `CODEX_SESSION_ID` → `codex`; `CLAUDE_PID` → `session_pids(pid, start ≤ process start)` (**env_agent_pid**). Discovery: a marker whose session is unknown creates `sessions(discovered_via='env', started_at = process start, ended_at = NULL if the pid in CLAUDE_PID is alive and is a Claude process, else 'discovered_dead')` with `cwd = PWD` from the same environment, so processes started before Airbag was installed still group correctly. Today's example: `next-server` pid 70386 carries `CLAUDE_CODE_SESSION_ID=1a2b3c4d-…`, `CLAUDE_PID=62758` (dead), `PWD=/Users/…/qost/web`, `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, and a transcript `~/.claude/projects/-Users-me-myproject/1a2b3c4d-….jsonl` exists [verified]. Agent-only markers (`CURSOR_AGENT`, `COMPOSER_NO_INTERACTION`, `CURSOR_SANDBOX`, `GEMINI_CLI=1`, `COPILOT_CLI=1`, `CODEX_SANDBOX`) set `agent` but not the session (MEDIUM, combined with cwd). Marker absence is not evidence: Apple-restricted binaries hide their environment, and Docker/VM processes never carry it.
3. **remembered_ancestry** (HIGH, flagged historical): the process row already has `session_id` from rule 1 or 2 at an earlier tick; keep it after reparenting to launchd. **process_group** (MEDIUM): the process's `pgid` equals the pgid of a remembered `agent_helper` shell of a session (the Bash tool shell is its own group leader and children inherit it [verified, doc 04 §2]).
4. **cwd** (project/worktree HIGH; session LOW): `cwd` (or `PWD` marker) is under a registered worktree or project root, longest prefix wins; session = the single live session bound to that worktree, if exactly one; otherwise none. Today: `limactl`, `ssh -L`, `next-server` all have cwd under `~/qost` [verified].
5. **argv_match** (MEDIUM): normalised argv equals a command recorded by a `pre_shell` with `background=1`, by Claude's `Stop.background_tasks[].command`, or by Codex/Cursor post-shell within the last 24 h for a session in the same project.
6. none → `attribution = .none`; shown only if `class == dev`.

`attribution_changed` events are written when method or target changes; manual overrides (`manual`, user drags a process onto a session or project in the UI) are never overwritten by rules 3–5, only by 1–2 with a different session.

**Reading other processes' environment — evaluation of option (d).** `sysctl({CTL_KERN, KERN_PROCARGS2, pid})` returns `argc` (4 bytes), the exec path, NUL padding, argv, then `KEY=VALUE` strings, for any same-uid process without root or Full Disk Access; other uids fail with `EINVAL`; Apple platform binaries (`rapportd`, `ControlCenter`, `/bin/sleep`) return `argc=1` and no environment; the buffer may be up to `kern.argmax` = 1 048 576 bytes [verified today]. Cost: 29 µs median / 67 µs p95 / 292 µs max per pid, 12.5 ms for a 311-pid sweep [verified], so the radar reads it only for candidates and caches by `(pid, start)` (the environment is fixed at exec). Coverage: everything a shell tool forks inherits the markers — `npm run dev` → `node` → `next-server` chains and reparented orphans alike; misses: processes started with a scrubbed environment (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, `env -i`), services inside Docker/Lima VMs (the host-side proxy carries the markers, the service does not), Apple binaries, and anything Codex spawns from a *hook* (hooks do not receive `CODEX_THREAD_ID`, doc 02 §2.6). Privacy: the same buffer holds `CLAUDE_CODE_MESSAGING_TOKEN`, OAuth material and arbitrary user secrets, so only allowlisted keys (§9) are copied out and the buffer is zeroed. Verdict: use it as rule 2 — the strongest post-mortem signal there is (it is what identifies today's orphan `next-server`), never as the only one, and never as proof of absence.

### 6.4 Link state, orphan definition, prompt policy

| `link_state` | Meaning |
| --- | --- |
| `attached` | a live incarnation of the attributed session is an ancestor right now |
| `detached` | attributed session is live, but no live incarnation is an ancestor (started by an earlier run; the session was resumed under a new pid — the `next-server` case whose session `1a2b3c4d` is live again as pid 99094 [verified]) |
| `orphan` | attributed session has `ended_at` set, or all incarnations are dead and the §8 grace expired; the process is alive; it listens, or it is `dev` class |
| `unknown` | no session attribution |

Orphan prompt ("session ended — stop its servers?"): when a session transitions to ended (hook or sweep), schedule a check at `+radar.orphanGraceSec` (20 s). If the session is live again (resume) → cancel. Else collect its processes with `link_state ∈ {detached, orphan}`, `attr_confidence ≥ medium` (cwd-only matches never prompt — spec 13 §7.2), at least one open listener (setting to include non-listening `dev` processes) and `kept_at IS NULL`. If the project's `options.onSessionEnd` is `"silent"`, only the popover attention row is shown; otherwise post one `UNUserNotificationCenter` notification per session (via `OrphanNotifier`, §10.6): title "Claude Code session ended · qost", body "2 servers still listening: node :3999, node :5173", actions **Stop all** (SIGTERM path, §6.7), **Keep** (`kept_at = now` on each), default click opens the radar grouped on that session. Never auto-kill in v1 (spec 13 §7.2: the agent shell cannot know user intent, neither can Airbag); `radar.autoStopOrphansAfterMin` is a reserved key so a future opt-in needs no migration. Repeat prompts for the same session only when a new listener appears. Processes already orphaned when Airbag starts (discovered via env) are shown with an "orphan" badge but prompt only once per app launch, as one aggregated notification.

### 6.5 Grouping

`RadarSnapshot.groups: [ProjectGroup]` → `worktrees: [WorktreeGroup]` (main first; kind + branch + locked badge) → `sessions: [SessionGroup]` (agent, title, live/ended, surface) → `processes` sorted by first listener port; per worktree an `unattributed` bucket (cwd match only); top-level `otherDev` (dev-class, no project) and `system` (hidden unless `radar.showSystem`). Counts per level drive the menu-bar badge: number of orphan listeners. The Radar "Status" column of spec 13 §7.2 is derived, not stored: `system` when `class == system` (or `other` while hidden); `live` when `link_state ∈ {attached, detached}` (the detail text says "attached" or "started by an earlier run"); `orphan` when `link_state == orphan`; `unknown` otherwise (cwd-only or no attribution).

### 6.6 Ignore and dev-ish classification

Class is decided at first sight and re-evaluated when a listener appears.

- `system` (hidden by default; never stoppable): `uid != getuid()`; exe under `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/usr/bin/` (except interpreters listed below), `/Library/Apple/`, `/System/Library/CoreServices/`; Apple bundle ids via `proc_pidpath` inside `/System/Applications/`; zero-environment processes whose exe is not under a user-writable prefix. Baseline on this machine that must be hidden: `rapportd *:56257`, `ControlCenter *:5000` + `*:7000` (AirPlay Receiver), `Spotify 127.0.0.1:7768` + `*:57621` + `*:64770`, `Raycast 127.0.0.1:7265` [verified today]. Shown but badged "managed": colima's `limactl hostagent` (`*:53`, `127.0.0.1:60856`) and its `ssh … colima/ssh.sock [mux]` with seven forwarded ports (1883, 3000, 4840, 5432, 6379, 8000, 8100), all ppid 1 with cwd `~/qost` because colima was started there — the cwd rule alone would file them under the project, which is why cwd-only attribution is LOW and never prompts [verified today].
- `terminal`/IDE hosts and `agent`: by the §4.3 matchers and the protected-app prefix list.
- `dev` when any of: exe basename ∈ {`node`, `bun`, `deno`, `python`, `python3`, `python3.*`, `uvicorn`, `gunicorn`, `hypercorn`, `flask`, `ruby`, `puma`, `rails`, `go`, `java`, `kotlin`, `gradle`, `cargo`, `rustc`, `php`, `php-fpm`, `dotnet`, `beam.smp`, `erl`, `elixir`, `mix`, `deno`, `caddy`, `nginx`, `httpd`, `postgres`, `redis-server`, `mysqld`, `mongod`, `next-server`, `vite`, `esbuild`, `webpack`, `tsc`, `ngrok`, `cloudflared`, `ssh` (forwards), `limactl`, `colima`, `docker-proxy`, `com.docker.backend`, `vpnkit`, `qemu-system-*`, `containerd`} ∪ `radar.extraDevNames`; exe under `/opt/homebrew/`, `/usr/local/`, `~/.nvm/`, `~/.volta/`, `~/.asdf/`, `~/.local/share/`, `~/.cargo/`, `~/go/bin/`, `~/.bun/`, `~/.rbenv/`, `~/.pyenv/`, any path containing `/node_modules/.bin/`, `/.venv/`, `/target/debug/`, `/target/release/`, `/.build/`; cwd under a registered project; any agent env marker; or a listener on 1024–65535 bound to loopback or any whose owner is neither `system` nor an application bundle (exe path contains `.app/Contents/`: Spotify, Raycast, Electron helpers). Bundles reach `dev` only through the name/path/cwd/marker rules (Docker's `com.docker.backend` does; Spotify does not).
- Docker/Lima: `com.docker.backend`, `docker-proxy`, `limactl`, `colima` are shown as dev with a "managed by Docker/Lima" badge and **stop disabled** (killing the proxy does not stop the container; the UI offers to copy `docker ps`).
- `other`: everything else, including non-dev application bundles that listen (Spotify, Raycast); hidden unless `radar.showSystem` (the UI's "Show all"); re-classified on any tick where a dev signal appears (new cwd under a project, new marker, user adds the name to `radar.extraDevNames`).

Listener scope: `127.0.0.1`/`::1` → `loopback`; `0.0.0.0`/`::` → `any`; else `specific`. IPv6 any-sockets accept IPv4 too unless `IPV6_V6ONLY` [verified, `limactl :::53`], so scope `any` is shown once per `(pid, port)`.

### 6.7 Stop semantics

Protected (never signalled; the UI shows a lock and the reason): pid ≤ 1; Airbag app and CLI; every live `session_pids` pid and its ancestors up to launchd (`disclaimer`, `Claude.app`, `Codex.app`, `ChatGPT.app`, `Cursor.app`, `Terminal`, `iTerm2`, `Code`, `WezTerm`, `kitty`, `Ghostty`, `Alacritty`, `Warp`, `Zed`, `Xcode`, JetBrains IDEs — `radar.protectedAppPrefixes`, matched on `proc_pidpath` prefix); any `system` class; `agent_helper` processes while their session is live (MCP servers, tool shells) unless the user confirms "this belongs to a running agent session".

Algorithm (`ProcessRadar.stop(_:force:)`; steps 1–3 are the pure `StopPlanner.plan`, §10.6, so they are unit-testable on synthetic trees):

1. Take a fresh tree snapshot (tier A). Require `snapshot[target.pid].start == target.start`, else `.refused(.goneOrReused)`; names in the managed list (`limactl`, `colima`, `docker-proxy`, `com.docker.backend`, `vpnkit`) → `.refused(.managed(by:))`.
2. `victims = [target] + descendants(target)` restricted to same uid; if any victim is protected → `.refused(.protectedDescendant)`.
3. Group mode when `target.pgid == target.pid`, or the group leader is dead, **and** every live member of the group is in `victims`, **and** none is protected: `kill(-pgid, sig)`; this takes `npm run dev` wrappers and their `next-server` children together. Otherwise signal `victims` individually, children first.
4. `sig = SIGTERM`; poll every 100 ms up to 5 s: alive = `proc_pidinfo` succeeds and `p_stat != SZOMB` (zombies belong to their parent; show "exited") [verified, doc 04 §10]. Result `.terminated` / `.stillRunning(alive)`.
5. `force == true` (separate button "Force stop", shown only after `.stillRunning`): same with `SIGKILL`, poll 2 s. Never automatic.
6. Write `stop_requested` and `stop_result` events (pid, start, signal, outcome, who: `user|auto_orphan`).

Compared with Baa (SIGTERM tree then SIGKILL after 4 s automatically, no pid/start identity, `kill(pid,0)` as liveness [verified, doc 05 §2.3]) and LeftOpen (SIGTERM first, SIGKILL separate [doc 05 §3.3]), Airbag follows LeftOpen's two-step and adds identity re-validation and protected sets.

## 7. Worktree detection

### 7.1 Facts the detector relies on

- A linked worktree's `.git` is a file `gitdir: <common>/worktrees/<name>`; that directory holds `HEAD`, `ORIG_HEAD`, `commondir`, `gitdir` (absolute path of the worktree's `.git` file), `index`, `logs/`, and `locked` while locked (contents = reason; `git worktree remove` refuses while it exists; `git worktree list --porcelain` prints `locked <reason>`) [verified today in a scratch repo, git 2.39.5]. `git rev-parse --path-format=absolute --git-common-dir` from any subdirectory of a worktree returns the main `.git` (≈12 ms per spawn) [verified today].
- Claude Code: `--worktree <name>` → `<repo>/.claude/worktrees/<name>/` on branch `worktree-<name>`; generated names like `bright-running-fox`; PR worktrees `.claude/worktrees/pr-<number>`; `EnterWorktree` creates under the same directory; subagent (`isolation: worktree`) and background-session worktrees are "temporary worktrees" under `.claude/worktrees/` whose naming the docs do not state (`agent-<id>` is [unverified]); Claude Code "writes a marker into the git metadata of every worktree it creates with git" (key not documented [unverified]) and holds `git worktree lock` while an agent runs; the sweep releases locks of dead sessions; `~/.claude/worktrees/<name>` is the documented location for hook-created (non-git) worktrees; the desktop app's location is configurable in Settings › Claude Code [verified, worktrees.md fetched today; doc 01 §8]. `cwd` in hook payloads follows the worktree, `CLAUDE_PROJECT_DIR` does not [verified].
- Codex: `$CODEX_HOME/worktrees/<4 hex>/<repo name>` (or `[desktop] git-worktree-root`), detached HEAD, owner recorded in `<common>/worktrees/<name>/codex-thread.json` = `{"version":1,"ownerThreadId":"<thread uuid>"}` — the file lives in the *source repo's* `.git`, so `glob(<common>/worktrees/*/codex-thread.json)` enumerates Codex worktrees of a project [verified: source + local probe, doc 02 §6].
- Cursor: fixed `~/.cursor/worktrees/` (staff, non-configurable), layout `~/.cursor/worktrees/<repo>/<name>` [likely], agent branches like `cursor/23283375` [unverified], capped at `cursor.worktreeMaxCount` (25) and pruned on a timer [verified, doc 03 §3.9].

### 7.2 Scanner (app)

`WorktreeScanner` runs per git project every 60 s, on FSEvents under `<common>/worktrees` (a dedicated low-latency stream, 2 s latency, separate from the snapshot watcher which excludes `.git`), and after any hook event whose `cwd` is not inside a known worktree:

1. List `<common>/worktrees/*/`; for each read `gitdir` → worktree root = `dirname(contents)`; `HEAD` → branch or detached oid; `locked` → reason (empty string if the file is empty); `codex-thread.json` → owner.
2. Verify the root exists and its `.git` file points back; otherwise mark `removed_at` (prunable worktree).
3. Classify: root under `<project.root_path>/.claude/worktrees/` → `claude`; under `$CODEX_HOME/worktrees/` or the configured Codex root, or `codex-thread.json` present → `codex`; under `~/.cursor/worktrees/` → `cursor`; else `manual`.
4. Upsert `worktrees`; emit `worktree_seen`/`worktree_removed`; bind `owner_agent_session_id` (Codex) or, for Claude/Cursor, the session whose `cwd` is inside the root (set in §4.5).
5. Fallback to `git worktree list --porcelain` when parsing fails (unexpected layout), cached 60 s.

Discovery of projects from worktrees: a hook `cwd` under `~/.cursor/worktrees/...` or `~/.codex/worktrees/...` resolves (§7.4) to a common dir outside those trees; that common dir's main checkout becomes/stays the project; the worktree row is created with the right kind. `~/.claude/worktrees/<name>` without git metadata is treated as a `plain` project root only if the user registers it; sessions there still get rows with `project_id NULL`.

### 7.3 Snapshot and FSEvents consequences (for the other designs)

One snapshot store per project (keyed by common dir) with the worktree path recorded per snapshot; one FSEvents stream per worktree root (8 exclusion paths each [verified, doc 04 §3]); Cursor's cleanup and Claude's sweep give no hook, so a `worktree_removed` observation triggers nothing retroactively — the last snapshot before removal is whatever FSEvents produced.

### 7.4 Project resolution without spawning git (CLI hot path)

```
resolve(cwd):
  dir = realpath(cwd); depth = 0
  while depth < 64:
    g = dir + "/.git"
    if isDirectory(g):            return (common: realpath(g), toplevel: dir, worktree: .main)
    if isFile(g):                 // "gitdir: <path>\n"
      gd = resolveRelative(parse(g), base: dir)
      if gd contains "/.git/modules/": dir = parent(dir); depth += 1; continue   // submodule: belongs to the superproject
      common = exists(gd + "/commondir") ? normalize(gd + "/" + read(gd + "/commondir")) : gd
      return (common: realpath(common), toplevel: dir, worktree: .linked(name: basename(gd)))
    if dir == "/" or dir == HOME:  break
    dir = parent(dir); depth += 1
  return (common: nil, toplevel: nil)   // plain folder: match registered plain projects by longest prefix
```

Auto-registration policy: git repositories whose common dir is under `$HOME` and not under `~/Library/`, `~/.Trash/`, `$TMPDIR`, `/private/tmp` are registered automatically with `protected = 1` on the first hook event (the desktop scratch workspaces under `~/Library/Application Support/Claude/scratch-workspaces/` observed as session cwds today are therefore not projects) [verified cwds]. Plain folders are registered only by the user. A hook outside any project still records the session and events (`project_id NULL`) and takes no snapshot.

## 8. Session end detection

Ground truth is the agent process, not the hook:

1. **Hook**: `SessionEnd`/`sessionEnd` sets `ended_at` (§4.5). Not sufficient: Claude's SessionEnd has a 1.5 s budget and never fires on crash/kill; Gemini's is not awaited; Cursor CLI's is unconfirmed; Codex's fires after 30 min idle [verified, docs 01–03].
2. **Liveness sweep** (app, every tick, from the tier-A table; CLI, at most once per 60 s when the app socket is absent, using `proc_pidinfo` per live incarnation): an incarnation whose `(pid, start)` is gone → `ended_at = now`, `last_alive_at` kept. A session with no live incarnation enters a grace period `session.endGraceSec` (15 s) to absorb resume/restart (Claude desktop re-launches the binary with `--resume=<session_id>` [verified]); after grace → `ended_at = now`, `end_reason = 'pid_gone'`, `session_ended_by_sweep` event, orphan flow (§6.4).
3. **Claude's own registry**: `~/.claude/sessions/<pid>.json` (directory 0700, files 0644; removed on clean exit, crash leftovers cleared on next launch [verified, doc 01 §11.1]). Fields observed today on three live desktop sessions: `pid`, `sessionId`, `cwd`, `startedAt` (epoch ms), `procStart` (UTC ctime string), `version`, `peerProtocol`, `peerFeatures[]`, `kind` (`interactive`), `entrypoint` (`claude-desktop`), `hostSessionId`, `pidDomain` (`darwin`), `messagingSocketPath` (`/tmp/cc-socks/<pid>.sock`), `name`, `nameSource` (`user`; absent when auto-named), `nameSince`, `status` (`idle|busy`), `updatedAt`, `statusUpdatedAt`, `bridgeSessionId`; there is no `peerToken` key — the secret lives in the sibling `<pid>.<sha256>.key` (108 bytes, 0600), which Airbag never opens [verified today]. The app `stat`s the directory every 2 s and re-reads files whose mtime changed (`updatedAt` moves on status flips), decoding only the keys listed in `ClaudeSessionFileEntry` (§10.3); a file counts when its `pid` is alive and `startedAt` matches the kernel start time ±5 s. It supplies `name`/`nameSource`, `status`, `entrypoint`, `hostSessionId`, `cwd` for enrichment and can *discover* a live Claude session that has no hooks yet (`discovered_via='claude_sessions_file'`, which also drives the "hooks not installed for this session" banner). A file whose pid is dead or reused is ignored. The CLI never reads this directory.
4. **Shared-host agents** (Codex `app-server`, Cursor IDE extension host, Cursor CLI daemon, Codex `/daemon`): one process hosts many threads, so pid liveness cannot end a thread. For these surfaces a session is live while the host pid lives **and** (`last_seen_at` or `transcript_path` mtime) is younger than `session.staleHoursSharedHost` (2 h); otherwise `end_reason = 'stale'`. Codex's `SessionEnd` at 30 min idle usually arrives first.
5. `last_seen_at` alone never ends a single-process session: a Claude terminal session can sit idle for days with its pid alive and must remain "live" (its servers are attached, not orphans).

## 9. Privacy

- Never persisted: `tool_response`, `tool_output`, `output`, `stdout`, `stderr`, `last_assistant_message`, `prompt` text, `user_email` (Cursor), transcript contents. The PostToolUse/afterShell adapters drop these fields before the envelope is built; only `interrupted`, `duration_ms`, `exit_code` (when present), `spilled` (output persisted to a file by the agent) survive as booleans/numbers.
- Command text: stored in `events.command`, `guard_log.command`, `snapshots.label`, `processes.argv` only after redaction. Built-in patterns (applied in order, replacement `‹redacted›`): `(?i)(authorization:\s*bearer\s+)\S+`; `(?i)\b(token|secret|password|passwd|pwd|api[_-]?key|access[_-]?key|private[_-]?key)\s*[=:]\s*\S+`; `(?i)(--?(password|passwd|token|secret|api-key|key)[= ])\S+`; `\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b`; `\bsk-[A-Za-z0-9_-]{16,}\b`; `\bAKIA[0-9A-Z]{16}\b`; `\bxox[baprs]-[A-Za-z0-9-]{10,}\b`; `://[^/\s:@]+:[^@\s]+@` (URL credentials); `\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b` (JWT); `\b[A-Fa-f0-9]{40,}\b` and `\b[A-Za-z0-9+/]{48,}={0,2}\b` (long hex/base64); `-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`; `(?i)\b(PG|MYSQL|DATABASE|REDIS)_?(PASSWORD|URL)=\S+`. Plus `redaction.extraPatterns`. `command_hash` is computed over the unredacted text (needed for allowances and dedupe) and reveals nothing by itself. `redaction.mode = hash_only` stores no command text at all (timeline labels fall back to "Before shell command"); `off` disables redaction (explicit opt-in with a warning).
- Environment: only these keys are ever copied out of `KERN_PROCARGS2` buffers: `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_HOST_SESSION_ID`, `CLAUDECODE`, `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, `CODEX_TOOL_CALL_ID`, `CODEX_SANDBOX`, `CURSOR_AGENT`, `CURSOR_SANDBOX`, `COMPOSER_NO_INTERACTION`, `GEMINI_CLI`, `GEMINI_SESSION_ID`, `COPILOT_CLI`, `PWD`. The buffer is zeroed after parsing; `CLAUDE_CODE_MESSAGING_TOKEN` and `CLAUDE_CODE_OAUTH_*` are present in agent children and must never be read into Swift strings (parse by key prefix match on the raw bytes, skip everything else).
- Claude's session registry: only `~/.claude/sessions/<pid>.json` is read, with the key allowlist of §10.3; the sibling `<pid>.<sha256>.key` (0600; inbox-socket auth material [likely]) is never opened, and `messagingSocketPath`, `bridgeSessionId`, `peerFeatures` are never decoded or stored.
- Hook environment: `HookEnv` copies only the marker allowlist above plus `CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_EXECPATH`, `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `GEMINI_PROJECT_DIR`, `COPILOT_HOME`, `SHELL`, `HOME`. `CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN`, `CLAUDE_CODE_OAUTH_*` and `CLAUDE_ENV_FILE` are present in hook environments (doc 01 §7) and are never read into Swift strings or logged.
- Files: `~/Library/Application Support/Airbag/` 0700; `registry.sqlite*`, spool, logs 0600; socket 0600 inside the 0700 directory. Logs never contain command text above `debug`.
- No network, no telemetry, no crash reporter upload (product rule). "Export diagnostics" produces a zip the user inspects; it applies the same redaction and excludes `processes.argv` by default.
- Transcript paths are stored (they are needed to open the session's transcript in Claude Code and to use mtime as an activity signal); transcript contents are never read except, read-only and on explicit user action, the first `session_meta` line of a Codex rollout for enrichment (doc 02 §5).

## 10. Swift API surface

Swift 6 language mode, `platforms: [.macOS(.v14)]`, no third-party packages. All public types are `Sendable`; storage lives behind actors. Signatures are normative; bodies are not shown.

### 10.1 `AirbagRegistry`

```swift
import Foundation

public struct ULID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public init()                                   // monotonic within a process
    public init?(string: String)
    public var description: String { get }          // 26 chars, Crockford base32
}

public struct ProjectID: Hashable, Sendable, Codable { public let raw: ULID }
public struct WorktreeID: Hashable, Sendable, Codable { public let raw: ULID }
public struct SessionID: Hashable, Sendable, Codable { public let raw: ULID }
public struct SnapshotID: Hashable, Sendable, Codable { public let raw: ULID }
public struct EventID: Hashable, Sendable, Codable { public let raw: ULID }
public struct ProcessRowID: Hashable, Sendable, Codable { public let raw: Int64 }

public enum AgentKind: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code", codex, cursor, gemini, copilot
}
public enum Surface: String, Sendable, Codable { case cli, desktop, ide, exec, sdk, unknown }
public enum ProjectKind: String, Sendable, Codable { case git, plain }
public enum WorktreeKind: String, Sendable, Codable { case main, claude, codex, cursor, manual, unknown }
public enum ProcessClass: String, Sendable, Codable { case dev, agent, agentHelper = "agent_helper", terminal, system, other }
public enum AttributionMethod: String, Sendable, Codable {
    case liveAncestry = "live_ancestry", rememberedAncestry = "remembered_ancestry",
         envSession = "env_session", envAgentPid = "env_agent_pid", processGroup = "process_group",
         cwd, argvMatch = "argv_match", manual
}
public enum Confidence: String, Sendable, Codable, Comparable { case low, medium, high }
public enum LinkState: String, Sendable, Codable { case attached, detached, orphan, unknown }
public enum Decision: String, Sendable, Codable {
    case allow, ask, deny, allowOnce = "allow_once", allowFallback = "allow_fallback", denyFallback = "deny_fallback"
}
public enum SnapshotTrigger: String, Sendable, Codable {
    case preCommand = "pre_command", postCommand = "post_command", fsevents, manual, preRestore = "pre_restore", startup
}
public enum EventKind: String, Sendable, Codable { /* the list in §3.2 */ }

/// Process identity: pid plus kernel start time in microseconds since the epoch.
public struct ProcKey: Hashable, Sendable, Codable {
    public let pid: pid_t
    public let startUS: Int64
    public init(pid: pid_t, startUS: Int64)
}

public struct Project: Sendable, Codable, Identifiable {
    public let id: ProjectID
    public var rootPath: String, commonDir: String?, kind: ProjectKind, displayName: String
    public var protected: Bool, storePath: String?, options: JSONObject
    public var createdAt: Date, lastSeenAt: Date, archivedAt: Date?
}
public struct Worktree: Sendable, Codable, Identifiable {
    public let id: WorktreeID
    public var projectID: ProjectID, path: String, kind: WorktreeKind
    public var name: String?, branch: String?, headOID: String?, ownerAgentSessionID: String?, lockedReason: String?
    public var createdAt: Date, lastSeenAt: Date, removedAt: Date?
}
public struct Session: Sendable, Codable, Identifiable {
    public let id: SessionID
    public var agent: AgentKind, agentSessionID: String
    public var projectID: ProjectID?, worktreeID: WorktreeID?
    public var cwd: String?, launchRoot: String?, surface: Surface, hostSessionID: String?
    public var transcriptPath: String?, title: String?, model: String?, permissionMode: String?
    public var discoveredVia: DiscoveredVia
    public var startedAt: Date, lastSeenAt: Date, lastEventKind: EventKind?, endedAt: Date?, endReason: String?
    public var flags: JSONObject
    public var isLive: Bool { endedAt == nil }
    public enum DiscoveredVia: String, Sendable, Codable { case hook, env, claudeSessionsFile = "claude_sessions_file", manual }
}
public struct SessionIncarnation: Sendable, Codable {
    public var sessionID: SessionID, key: ProcKey
    public var exePath: String?, argv0: String?, ppid: pid_t?, pgid: pid_t?
    public var host: ProcKey?, terminal: ProcKey?, terminalApp: String?, tty: String?
    public var firstSeenAt: Date, lastAliveAt: Date, endedAt: Date?
}
public struct Attribution: Sendable, Codable, Equatable {
    public var sessionID: SessionID?, projectID: ProjectID?, worktreeID: WorktreeID?
    public var method: AttributionMethod?, confidence: Confidence?
    public static let none = Attribution()
}
public struct ProcessRecord: Sendable, Codable {
    public var rowID: ProcessRowID?
    public var key: ProcKey, ppid: pid_t, pgid: pid_t, uid: uid_t
    public var exePath: String?, name: String, argv: [String]?, cwd: String?
    public var klass: ProcessClass, ancestry: [ProcKey], envMarkers: [String: String]?
    public var attribution: Attribution, linkState: LinkState, keptAt: Date?
    public var firstSeenAt: Date, lastSeenAt: Date, endedAt: Date?
}
public struct ListenerRecord: Sendable, Codable, Hashable {
    public enum Family: String, Sendable, Codable { case ipv4, ipv6 }
    public enum Scope: String, Sendable, Codable { case loopback, any, specific }
    public var port: UInt16, family: Family, address: String, scope: Scope
    public var firstSeenAt: Date, lastSeenAt: Date, closedAt: Date?
}
public struct SnapshotRecord: Sendable, Codable, Identifiable {
    public let id: SnapshotID
    public var projectID: ProjectID, worktreeID: WorktreeID?, sessionID: SessionID?, eventID: EventID?
    public var trigger: SnapshotTrigger, commitOID: String, treeOID: String
    public var fileCount: Int?, changedCount: Int?, durationMS: Int?, label: String?, pinned: Bool
    public var createdAt: Date, deletedAt: Date?
}
public struct EventDraft: Sendable {
    public var kind: EventKind, ts: Date, agent: AgentKind?
    public var sessionID: SessionID?, projectID: ProjectID?, worktreeID: WorktreeID?, processRowID: ProcessRowID?
    public var toolUseID: String?, dedupeKey: String?, cwd: String?
    public var command: RedactedCommand?            // carries redacted text + hash; never the raw text
    public var background: Bool?, decision: Decision?, snapshotID: SnapshotID?, durationMS: Int?
    public var payload: JSONObject
}
public struct GuardEntry: Sendable, Codable, Identifiable { /* full definition in §10.6 */ public let id: ULID }
public struct Allowance: Sendable, Codable { public let id: ULID; public var sessionID: SessionID, commandHash: String, ruleID: String, expiresAt: Date, usedAt: Date? }

public struct RedactedCommand: Sendable, Codable, Hashable {
    public let text: String?          // nil in hash_only mode
    public let hash: String           // sha256 hex of the original
    public let redactedSpans: Int
    public init(raw: String, policy: RedactionPolicy)
}
public struct RedactionPolicy: Sendable, Codable {
    public enum Mode: String, Sendable, Codable { case tokens, hashOnly = "hash_only", off }
    public var mode: Mode
    public var extraPatterns: [String]
    public static let `default`: RedactionPolicy
}

public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String, defaultValue: Value
    public init(_ name: String, default: Value)
}
public enum Settings {                              // the keys of §3.7 as typed constants
    public static let snapshotDeadlineMS = SettingKey<Int>("hook.snapshotDeadlineMs", default: 1500)
    public static let radarIntervalsMS   = SettingKey<[String: Int]>("radar.intervalsMs", default: ["popover": 1000, "active": 2000, "semi": 5000, "idle": 10000, "asleep": 30000])
    /* … */
}

public enum RegistryRole: Sendable { case cli, app, readOnly }
public struct RegistryOptions: Sendable {
    public var path: URL                              // default: …/Airbag/registry.sqlite
    public var role: RegistryRole
    public var busyTimeout: Duration                  // cli .milliseconds(300), app .seconds(5)
    public var allowMigrations: Bool                  // true for cli and app
    public static func cli() -> RegistryOptions
    public static func app() -> RegistryOptions
}
public enum RegistryHealth: Sendable, Equatable {
    case healthy
    case degraded(DegradedReason)
    public enum DegradedReason: Sendable, Equatable { case busy, schemaNewer(db: Int, binary: Int), readOnly, corrupt, ioError(code: Int32, message: String), foreignFile }
}
public enum RegistryError: Error, Sendable {
    case busy, degraded(RegistryHealth.DegradedReason), constraint(String), notFound, sql(code: Int32, message: String)
}

/// One connection per instance; safe to call from any task.
public actor Registry {
    public static let schemaVersion: Int             // == Migrations.all.last!.version
    public init(options: RegistryOptions) throws    // opens, sets pragmas, migrates if allowed
    public var health: RegistryHealth { get }
    public nonisolated let options: RegistryOptions

    // Transactions: every mutating call below runs in its own BEGIN IMMEDIATE unless called inside `transaction`.
    public func transaction<T: Sendable>(_ body: @Sendable (isolated Registry) throws -> T) throws -> T

    // Projects and worktrees
    public func resolveProject(forCWD cwd: String, autoRegister: Bool) throws -> ProjectResolution
    public func upsertProject(rootPath: String, commonDir: String?, kind: ProjectKind, displayName: String) throws -> Project
    public func project(id: ProjectID) throws -> Project?
    public func projects(includeArchived: Bool) throws -> [Project]
    public func upsertWorktree(projectID: ProjectID, path: String, kind: WorktreeKind, name: String?, branch: String?, headOID: String?, ownerAgentSessionID: String?, lockedReason: String?) throws -> Worktree
    public func markWorktreeRemoved(id: WorktreeID, at: Date) throws
    public func worktrees(projectID: ProjectID, includeRemoved: Bool) throws -> [Worktree]

    // Sessions and incarnations
    public func upsertSession(_ u: SessionUpsert) throws -> Session
    public func recordIncarnation(sessionID: SessionID, _ inc: SessionIncarnation) throws
    public func endIncarnation(sessionID: SessionID, key: ProcKey, at: Date) throws
    public func endSession(id: SessionID, at: Date, reason: String) throws
    public func supersedeSessions(agent: AgentKind, pid: pid_t, except: SessionID, at: Date) throws   // Claude /clear
    public func session(agent: AgentKind, agentSessionID: String) throws -> Session?
    public func session(id: SessionID) throws -> Session?
    public func liveSessions() throws -> [Session]
    public func liveIncarnations() throws -> [SessionIncarnation]
    public func incarnations(sessionID: SessionID) throws -> [SessionIncarnation]
    public func sessions(projectID: ProjectID?, since: Date?, limit: Int) throws -> [Session]

    // Events, guard, allowances
    @discardableResult public func append(_ e: EventDraft) throws -> AppendResult   // .inserted(id) | .duplicate(existing: EventID, decision: Decision?)
    public func update(eventID: EventID, durationMS: Int?, decision: Decision?, snapshotID: SnapshotID?, payloadMerge: JSONObject) throws
    public func event(agent: AgentKind, toolUseID: String, kind: EventKind) throws -> EventRecord?
    public func events(sessionID: SessionID?, projectID: ProjectID?, kinds: Set<EventKind>?, since: Date?, limit: Int) throws -> [EventRecord]
    public func logGuard(_ g: GuardDraft) throws -> GuardEntry
    public func resolveGuard(id: ULID, resolution: GuardEntry.Resolution, at: Date) throws
    public func openGuards(sessionID: SessionID?) throws -> [GuardEntry]
    public func grantAllowance(sessionID: SessionID, commandHash: String, ruleID: String, ttl: Duration) throws -> Allowance
    public func consumeAllowance(sessionID: SessionID, commandHash: String, ruleID: String, now: Date) throws -> Allowance?

    // Radar
    public func observe(_ delta: RadarDelta) throws          // one transaction per tick
    public func trackedProcesses(includeEnded: Bool) throws -> [ProcessRecord]
    public func listeners(processRowID: ProcessRowID, includeClosed: Bool) throws -> [ListenerRecord]
    public func setKept(processRowID: ProcessRowID, at: Date?) throws
    public func setManualAttribution(processRowID: ProcessRowID, _ a: Attribution?) throws

    // Snapshots index
    public func recordSnapshot(_ s: SnapshotRecord) throws
    public func markSnapshotDeleted(id: SnapshotID, at: Date) throws
    public func snapshots(projectID: ProjectID, worktreeID: WorktreeID?, before: Date?, limit: Int) throws -> [SnapshotRecord]
    public func reconcileSnapshots(projectID: ProjectID, liveRefs: [SnapshotRecord]) throws -> ReconcileReport

    // Agents and settings
    public func upsertAgent(_ a: AgentStatus) throws
    public func agents() throws -> [AgentStatus]
    public func value<V>(_ key: SettingKey<V>) throws -> V
    public func set<V>(_ key: SettingKey<V>, _ value: V) throws

    // Maintenance
    public func runRetention(now: Date, policy: RetentionPolicy) throws -> RetentionReport
    public func checkpoint(_ mode: CheckpointMode) throws          // .passive | .truncate
    public func dataVersion() throws -> Int                        // PRAGMA data_version
    public func walSizeBytes() -> Int64                            // stat of -wal, no SQL
}

public struct SessionUpsert: Sendable {
    public var agent: AgentKind, agentSessionID: String
    public var cwd: String?, launchRoot: String?, surface: Surface?, hostSessionID: String?
    public var transcriptPath: String?, title: String?, model: String?, permissionMode: String?
    public var projectID: ProjectID?, worktreeID: WorktreeID?
    public var discoveredVia: Session.DiscoveredVia, seenAt: Date, eventKind: EventKind?
    public var flagsMerge: JSONObject
    public var startedAtIfNew: Date?
}
public struct ProjectResolution: Sendable {
    public var project: Project?, worktree: Worktree?
    public var commonDir: String?, toplevel: String?
    public var isInsideGit: Bool
}
public struct RadarDelta: Sendable {                   // produced by ProcessRadar, consumed by Registry.observe
    public var seenAt: Date
    public var upserts: [ProcessRecord]                // tracked processes with current attribution/link state
    public var listeners: [(ProcKey, [ListenerRecord])]
    public var gone: [ProcKey]                         // tracked processes that disappeared this tick
    public var events: [EventDraft]                    // process_seen/gone, listener_open/close, attribution_changed, orphan_detected
}

/// Spool used when the registry is unavailable; both binaries can ingest.
public struct RegistrySpool: Sendable {
    public init(directory: URL)
    public func write(_ batch: SpoolBatch) throws      // atomic temp+rename
    public func ingest(into registry: Registry, maxFiles: Int, deadline: ContinuousClock.Instant) async throws -> Int
}
public struct SpoolBatch: Codable, Sendable {
    public var session: SessionUpsert?, incarnation: SessionIncarnation?, events: [EventDraft], guards: [GuardDraft], snapshots: [SnapshotRecord]
}

public enum Migrations {
    public struct Migration: Sendable { public let version: Int; public let name: String; public let up: @Sendable (SQLiteConnection) throws -> Void }
    public static let all: [Migration]
}
```

`JSONObject` is `[String: JSONValue]` with a `Codable` `JSONValue` enum (no `Any`). `SQLiteConnection` is the thin internal wrapper (prepare/step/bind/column, `exec`, `lastInsertRowID`, `changes`, `errorMessage`), exposed as `public` only for migrations and tests.

### 10.2 `AirbagHookBridge`

```swift
public struct ShellRequest: Sendable, Equatable {
    public var command: String                 // raw; only RedactedCommand leaves this module
    public var cwd: String
    public var workingDirectoryOverride: String?
    public var background: Bool
    public var timeoutMS: Int?
    public var sandboxed: Bool?
}
public struct ShellResult: Sendable, Equatable {
    public var durationMS: Int?, interrupted: Bool?, exitCode: Int32?, outputSpilled: Bool?
}
public enum HookEvent: Sendable, Equatable {
    case sessionStart(source: String?)
    case prompt(title: String?)
    case preShell(ShellRequest)
    case postShell(ShellResult)
    case shellFailed(ShellResult)
    case preEdit(paths: [String])
    case permissionRequest(ShellRequest)
    case stop(backgroundCommands: [String])     // Claude Stop.background_tasks[].command (shell only)
    case interrupt
    case subagentStart(agentID: String, agentType: String?)
    case subagentStop(agentID: String)
    case cwdChanged(old: String, new: String)
    case sessionEnd(reason: String)
    case unknown(name: String)
}
public struct HookEnvelope: Sendable {
    public var agent: AgentKind
    public var declaredAgent: AgentKind?
    public var event: HookEvent
    public var agentSessionID: String
    public var cwd: String
    public var workspaceRoots: [String]
    public var transcriptPath: String?
    public var toolUseID: String?, turnID: String?, promptID: String?, generationID: String?
    public var model: String?, permissionMode: String?
    public var flags: [String: Bool]           // background_agent, sandbox, …
    public var hookEnvironment: HookEnv        // CLAUDE_PID, CLAUDE_PROJECT_DIR, GEMINI_SESSION_ID, … (allowlisted)
    public var rawEventName: String
}
public struct HookEnv: Sendable { public init(environment: [String: String]); public subscript(_ key: String) -> String? }

public enum HookDecision: Sendable, Equatable {
    case allow
    case ask(reasonAgent: String, reasonUser: String)
    case deny(reasonAgent: String, reasonUser: String)
}
public struct HookResponse: Sendable, Equatable {
    public var stdout: Data          // exactly one JSON object, or empty where the agent requires silence
    public var exitCode: Int32       // always 0 in v1
    public static func safe(for agent: AgentKind, event: HookEvent) -> HookResponse
}

/// One adapter per agent. Pure functions; no I/O.
public protocol AgentAdapter: Sendable {
    static var kind: AgentKind { get }
    /// Shape detection, independent of the declared agent (Cursor import case).
    static func matches(_ payload: JSONObject, env: HookEnv) -> Bool
    func parse(_ payload: JSONObject, env: HookEnv) throws -> HookEnvelope
    func encode(_ decision: HookDecision, for envelope: HookEnvelope, locale: Locale) -> HookResponse
    var askSupport: AskSupport { get }                // .native | .unsupported | .undocumented
    var processMatcher: ProcessMatcher { get }
    var deadlines: HookDeadlines { get }              // per event kind, §4.2
    func dedupeKey(for envelope: HookEnvelope, kind: EventKind) -> String?
}
public struct ClaudeCodeAdapter: AgentAdapter {}
public struct CodexAdapter: AgentAdapter {}
public struct CursorAdapter: AgentAdapter {}
public struct GeminiAdapter: AgentAdapter {}
public struct CopilotAdapter: AgentAdapter {}
public enum AgentAdapters {
    public static let all: [any AgentAdapter.Type]
    public static func detect(_ payload: JSONObject, env: HookEnv, declared: AgentKind?) -> any AgentAdapter
}

public struct AgentProcessPattern: Sendable {
    public var exePathSuffixes: [String]      // "/claude.app/Contents/MacOS/claude"
    public var basenames: [String]            // "claude", "codex", "codex-aarch64-apple-darwin", "cursor-agent", "copilot"
    public var argvContains: [String]         // "app-server", "@google/gemini-cli", "@github/copilot"
    public var hostBundles: [String]          // "/Applications/Claude.app/", "/Applications/Cursor.app/", …
    public var surface: (AgentProcessMatch) -> Surface
}
public struct ProcessMatcher: Sendable {
    public var patterns: [AgentProcessPattern]
    public var maxDepth: Int                  // 32
    public func locateAgent(from pid: pid_t, env: HookEnv, table: any ProcessTableSource) -> AgentLocation?
}
public struct AgentLocation: Sendable, Equatable {
    public var agent: ProcKey, exePath: String, argv0: String, ppid: pid_t, pgid: pid_t
    public var surface: Surface, host: ProcKey?, terminal: ProcKey?, terminalApp: String?, tty: String?
    public var chain: [ProcKey]               // hook → … → agent
    public var viaEnvironment: Bool
}

public struct HookDeadlines: Sendable { public var soft: Duration, hard: Duration }

/// The whole `airbag hook` pipeline. Injected dependencies make it testable without a real agent.
public struct HookRunner: Sendable {
    public struct Dependencies: Sendable {
        public var openRegistry: @Sendable () throws -> Registry
        public var spool: RegistrySpool
        public var rules: any RuleEngine
        public var snapshots: any SnapshotEngine
        public var appLink: any AppLinkClient
        public var processTable: any ProcessTableSource
        public var clock: any Clock<Duration>
        public var now: @Sendable () -> Date
        public var locale: Locale
        public var log: HookLogger
    }
    public init(dependencies: Dependencies)
    /// Reads nothing from the real stdin; the executable passes the bytes in.
    public func run(stdin: Data, declaredAgent: AgentKind?, eventHint: String?, environment: [String: String], parentPID: pid_t) async -> HookResponse
}
/// Prints the safe response and `_exit(0)`s when the main path overruns; used by the executable, not by tests.
public final class HookWatchdog: @unchecked Sendable {
    public init(deadline: Duration, safeResponse: HookResponse, onFire: @Sendable () -> Void)
    public func claimOutput() -> Bool          // true for exactly one caller
    public func cancel()
}
public struct HookLogger: Sendable { public init(fileURL: URL, level: LogLevel, subsystem: String); public func log(_ level: LogLevel, _ message: @autoclosure () -> String) }
```

### 10.3 `AirbagProcessRadar`

```swift
public struct KinfoEntry: Sendable, Equatable {        // one row of sysctl KERN_PROC_ALL
    public var key: ProcKey, ppid: pid_t, pgid: pid_t, uid: uid_t, status: ProcStatus, comm: String, hasTTY: Bool
    public enum ProcStatus: Int32, Sendable { case idle = 1, run = 2, sleep = 3, stop = 4, zombie = 5 }
}
public struct ProcessTableSnapshot: Sendable {
    public let takenAt: Date
    public let entries: [pid_t: KinfoEntry]
    public func ancestry(of pid: pid_t, maxDepth: Int) -> [ProcKey]      // nearest first, stops at pid 1
    public func descendants(of pid: pid_t) -> [ProcKey]                  // breadth-first from the direct children; StopPlanner reverses it (deepest first) for signalling
    public func members(ofGroup pgid: pid_t) -> [ProcKey]
    public func isAlive(_ key: ProcKey) -> Bool                          // present and not zombie
}
public struct ListenerInfo: Sendable, Equatable { public var port: UInt16, family: ListenerRecord.Family, address: String }
public struct ProcessResources: Sendable, Equatable { public var physFootprint: UInt64, userNS: UInt64, systemNS: UInt64, threads: Int32 }
public struct EnvMarkers: Sendable, Equatable { public var values: [String: String]   /* allowlist only */ ; public var argv: [String] }

/// Everything the radar reads from the kernel, behind a protocol so tests can inject tables.
public protocol ProcessTableSource: Sendable {
    func snapshot() throws -> ProcessTableSnapshot                       // KERN_PROC_ALL
    func bsdInfo(_ pid: pid_t) -> (key: ProcKey, ppid: pid_t, pgid: pid_t, tdev: UInt32, name: String)?   // PROC_PIDTBSDINFO (hook path)
    func exePath(_ pid: pid_t) -> String?                                // proc_pidpath
    func cwd(_ pid: pid_t) -> String?                                    // PROC_PIDVNODEPATHINFO, same uid only
    func listeners(_ pid: pid_t) -> [ListenerInfo]                       // PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO
    func resources(_ pid: pid_t) -> ProcessResources?                    // proc_pid_rusage + PROC_PIDTASKINFO
    func envMarkers(_ pid: pid_t, allowlist: Set<String>) -> EnvMarkers? // KERN_PROCARGS2; nil on EINVAL/ESRCH
    func isAlive(_ key: ProcKey) -> Bool
    func kill(_ pid: pid_t, _ signal: Int32) -> Int32                    // returns errno or 0
    func killGroup(_ pgid: pid_t, _ signal: Int32) -> Int32
}
public struct LibprocSource: ProcessTableSource { public init() }

public struct RadarPolicy: Sendable {
    public var intervals: [RadarState: Duration]
    public var pokeDelays: [Duration]                   // [.milliseconds(300), .seconds(2), .seconds(10)]
    public var systemPathPrefixes: [String]
    public var protectedAppPrefixes: [String]
    public var devBasenames: Set<String>, devPathFragments: [String], ignoreNames: Set<String>
    public var showSystem: Bool
    public var envAllowlist: Set<String>
    public var orphanGrace: Duration, autoStopAfter: Duration?
    public var maxCachedProcesses: Int                  // 4096
    public var redaction: RedactionPolicy
    public static let `default`: RadarPolicy
}
public enum RadarState: String, Sendable { case popover, active, semi, idle, asleep }
public enum RadarPoke: Sendable { case hookEvent(EventKind, background: Bool), sessionEnded(SessionID), popoverOpened, popoverClosed, displayAsleep, displayAwake, manualRefresh }

public struct RadarListener: Sendable, Identifiable, Hashable { public var id: String { "\(port)/\(family.rawValue)/\(address)" }; public var port: UInt16, family: ListenerRecord.Family, address: String, scope: ListenerRecord.Scope }
public enum Protection: Sendable, Equatable { case killable, protected(reason: ProtectedReason), managed(by: String) ; public enum ProtectedReason: String, Sendable { case agent, agentHost, terminal, ide, system, airbag, agentHelperLive, launchd } }
public struct RadarProcess: Sendable, Identifiable, Hashable {
    public var id: ProcKey { key }
    public var key: ProcKey, ppid: pid_t, pgid: pid_t
    public var exePath: String?, name: String, argvSummary: String, cwd: String?, startedAt: Date
    public var rssBytes: UInt64?, cpuPercent: Double?
    public var listeners: [RadarListener]
    public var attribution: Attribution, linkState: LinkState, klass: ProcessClass, protection: Protection, keptAt: Date?
}
public struct SessionGroup: Sendable, Identifiable { public var id: SessionID; public var session: Session; public var processes: [RadarProcess] }
public struct WorktreeGroup: Sendable, Identifiable { public var id: WorktreeID?; public var worktree: Worktree?; public var sessions: [SessionGroup]; public var unattributed: [RadarProcess] }
public struct ProjectGroup: Sendable, Identifiable { public var id: ProjectID; public var project: Project; public var worktrees: [WorktreeGroup] }
public struct RadarSnapshot: Sendable {
    public var takenAt: Date, state: RadarState, tickDurationMS: Double
    public var groups: [ProjectGroup], otherDev: [RadarProcess], system: [RadarProcess]
    public var orphanListenerCount: Int, liveSessionCount: Int
}

public actor ProcessRadar {
    public init(source: any ProcessTableSource, registry: Registry, policy: RadarPolicy, notifier: any OrphanNotifier, clock: any Clock<Duration>, now: @escaping @Sendable () -> Date)
    public func start()
    public func stopPolling()
    public func poke(_ poke: RadarPoke)
    public func updatePolicy(_ policy: RadarPolicy)
    public var updates: AsyncStream<RadarSnapshot> { get }
    public func current() -> RadarSnapshot
    public func tick() async throws -> RadarSnapshot            // one poll; tests call this directly
    public func stop(_ key: ProcKey, force: Bool) async -> StopOutcome
    public func stopAll(sessionID: SessionID, force: Bool) async -> [StopOutcome]
    public func keep(_ key: ProcKey, kept: Bool) async throws
    public func attributeManually(_ key: ProcKey, to: Attribution?) async throws
}
public enum StopOutcome: Sendable, Equatable {
    case terminated(ProcKey, after: Duration)
    case stillRunning(ProcKey, alive: [ProcKey])
    case refused(ProcKey, StopRefusal)                 // includes .goneOrReused and .managed, §10.6
    case error(ProcKey, errno: Int32)
}

/// Pure attribution logic, testable with synthetic tables.
public struct Attributor: Sendable {
    public init(policy: RadarPolicy)
    public func classify(exePath: String?, name: String, cwd: String?, markers: EnvMarkers?, hasListener: Bool, uid: uid_t, isAgentChild: Bool) -> ProcessClass
    public func attribute(process: ProcessRecord, table: ProcessTableSnapshot, context: AttributionContext) -> (Attribution, LinkState)
}
public struct AttributionContext: Sendable {
    public var liveIncarnations: [ProcKey: SessionID]
    public var sessionsByAgentID: [AgentKind: [String: Session]]
    public var helperGroups: [pid_t: SessionID]                  // pgid of remembered agent_helper shells
    public var roots: [(path: String, projectID: ProjectID, worktreeID: WorktreeID?)]   // longest prefix match
    public var recentBackgroundCommands: [(normalizedArgv: String, sessionID: SessionID, projectID: ProjectID?)]
    public var singleLiveSessionByWorktree: [WorktreeID: SessionID]
}

public struct WorktreeScanner: Sendable {
    public init(registry: Registry, codexHome: URL, cursorWorktreeRoot: URL, gitPath: URL?)
    public func scan(project: Project) async throws -> [Worktree]       // §7.2
}
public struct ClaudeSessionsFileReader: Sendable {                         // §8.3
    public init(directory: URL)   // ~/.claude/sessions
    public func liveEntries(table: ProcessTableSnapshot) throws -> [ClaudeSessionFileEntry]
}
/// Decoded from `~/.claude/sessions/<pid>.json` with a lenient decoder (unknown keys ignored). Only these keys are read;
/// `messagingSocketPath`, `bridgeSessionId`, `peerFeatures` are never decoded and the sibling `<pid>.<sha256>.key` is never opened (§9).
public struct ClaudeSessionFileEntry: Sendable, Codable {
    public var pid: pid_t, sessionId: String, cwd: String, startedAt: Int64            // startedAt = epoch ms; compare to kernel start ±5 s
    public var version: String?, kind: String?, entrypoint: String?, hostSessionId: String?
    public var name: String?, nameSource: String?, status: String?, updatedAt: Int64?, statusUpdatedAt: Int64?
}
public struct SessionLivenessSweeper: Sendable {                            // §8.2, §8.4
    public init(registry: Registry, grace: Duration, staleSharedHost: Duration, now: @escaping @Sendable () -> Date)
    public func sweep(table: ProcessTableSnapshot) async throws -> SweepReport   // ends incarnations/sessions, returns newly ended sessions for the orphan flow
}
```

### 10.4 `AirbagIPC`

```swift
public enum IPCMessage: Codable, Sendable {
    case hook(HookNotice)
    case spool(count: Int)
    case ping
    public struct HookNotice: Codable, Sendable {
        public var agent: AgentKind, event: EventKind, sessionID: SessionID?, agentSessionID: String
        public var projectID: ProjectID?, worktreeID: WorktreeID?, eventID: EventID?
        public var background: Bool, decision: Decision?, snapshotID: SnapshotID?, cwd: String?, ts: Date
    }
}
public protocol AppLinkClient: Sendable {
    /// Non-blocking; returns false when the app is not listening. Never throws, never waits beyond `budget`.
    func send(_ message: IPCMessage, budget: Duration) async -> Bool
    func ping(budget: Duration) async -> PingReply?
}
public struct PingReply: Codable, Sendable { public var ok: Bool, appPID: pid_t, appVersion: String }
public struct UnixSocketAppLink: AppLinkClient { public init(socketPath: URL); public static let defaultPath: URL }
public final class AppLinkServer: @unchecked Sendable {
    public init(socketPath: URL, pidFile: URL, handler: @escaping @Sendable (IPCMessage, _ peer: (pid: pid_t, uid: uid_t)) -> IPCMessage?)
    public func start() throws         // umask 077, stale-socket check via pidFile (pid,start), bind, listen, dispatch source
    public func stop()
}
```

### 10.5 Interfaces consumed from other modules (pinned here, defined in their own designs)

```swift
public protocol RuleEngine: Sendable {
    /// Pure, microseconds, no I/O. `allowances` lets the engine honour one-shot allowances for `ask` rules.
    func evaluate(_ request: ShellRequest, agent: AgentKind, project: Project?, worktree: Worktree?, permissionMode: String?) -> RuleVerdict
}
public struct RuleVerdict: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case allow, ask, deny }
    public var outcome: Outcome, ruleID: String?, ruleSource: GuardEntry.RuleSource?, severity: GuardEntry.Severity?
    public var matchedSpan: String?, reasonAgent: String?, reasonUserKey: String?   // localized by the bridge
}
public protocol SnapshotEngine: Sendable {
    /// Must return by `deadline`; returns `.skipped(.timeout)` otherwise and leaves the store consistent.
    func snapshot(project: Project, worktree: Worktree?, trigger: SnapshotTrigger, context: SnapshotContext, deadline: ContinuousClock.Instant) async -> SnapshotOutcome
}
public struct SnapshotContext: Sendable { public var sessionID: SessionID?, eventID: EventID?, agent: AgentKind?, command: RedactedCommand?, cwd: String }
public enum SnapshotOutcome: Sendable { case taken(SnapshotRecord), deduplicated(SnapshotID), skipped(SnapshotSkipReason) ; }
public enum SnapshotSkipReason: String, Sendable { case cold, storeMissing, storeLocked, timeout, gitMissing, unprotected, outsideProject, error }
```

### 10.6 Supporting types referenced above

```swift
// AirbagRegistry
public enum JSONValue: Sendable, Codable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
}
public typealias JSONObject = [String: JSONValue]

public enum HooksState: String, Sendable, Codable {           // == agents.hooks_state
    case notInstalled = "not_installed", installed, untrusted, modified, drifted,
         duplicateRoute = "duplicate_route", managedOnly = "managed_only", invalidFile = "invalid_file", binaryMoved = "binary_moved"
}
public struct AgentStatus: Sendable, Codable, Identifiable {
    public var id: AgentKind { kind }
    public var kind: AgentKind, displayName: String, detected: Bool
    public var binaryPath: String?, version: String?
    public var hooksState: HooksState, hooksConfigPath: String?, hooksFingerprint: String?, hooksDetail: JSONObject?
    public var lastCheckedAt: Date?
}

public struct EventRecord: Sendable, Codable, Identifiable {
    public let id: EventID
    public var ts: Date, kind: EventKind, agent: AgentKind?
    public var sessionID: SessionID?, projectID: ProjectID?, worktreeID: WorktreeID?, processRowID: ProcessRowID?
    public var toolUseID: String?, dedupeKey: String?, cwd: String?
    public var command: String?, commandHash: String?           // command = redacted text (nil in hash_only mode)
    public var background: Bool?, decision: Decision?, snapshotID: SnapshotID?, durationMS: Int?
    public var payload: JSONObject
}
public enum AppendResult: Sendable, Equatable {
    case inserted(EventID)
    case duplicate(existing: EventID, decision: Decision?)      // dedupe_key hit; the caller replies with `decision`
}

public struct GuardEntry: Sendable, Codable, Identifiable {
    public enum RuleSource: String, Sendable, Codable { case builtin, user, project }
    public enum Severity: String, Sendable, Codable { case block, ask, warn }
    public enum Resolution: String, Sendable, Codable { case userAllowed = "user_allowed", userDenied = "user_denied", tokenUsed = "token_used", expired }
    public let id: ULID
    public var ts: Date, eventID: EventID?, sessionID: SessionID?, projectID: ProjectID?, agent: AgentKind
    public var ruleID: String, ruleSource: RuleSource, severity: Severity, decision: Decision
    public var command: String, commandHash: String, matchedSpan: String?, cwd: String?, reason: String
    public var snapshotID: SnapshotID?, tokenID: ULID?, resolvedAt: Date?, resolution: Resolution?
}
public struct GuardDraft: Sendable, Codable {
    public var ts: Date, eventID: EventID?, sessionID: SessionID?, projectID: ProjectID?, agent: AgentKind
    public var ruleID: String, ruleSource: GuardEntry.RuleSource, severity: GuardEntry.Severity, decision: Decision
    public var command: RedactedCommand, matchedSpan: String?, cwd: String?, reason: String, snapshotID: SnapshotID?
}

public struct RetentionPolicy: Sendable, Codable {               // defaults = §3.4
    public var eventsDays = 30, maxEvents = 200_000, guardDays = 90
    public var processesDays = 7, sessionsDays = 90, worktreesRemovedDays = 30, snapshotsDeletedDays = 30
    public var allowanceTTL: Duration = .seconds(600), batchSize = 2_000
    public static let `default` = RetentionPolicy()
}
public struct RetentionReport: Sendable, Equatable { public var deleted: [String: Int]; public var durationMS: Int; public var rescheduled: Bool }
public struct ReconcileReport: Sendable, Equatable { public var indexed: Int, markedDeleted: Int, repaired: Int }
public enum CheckpointMode: Sendable { case passive, truncate }

/// Thin wrapper over `sqlite3*`; public only for migrations and tests. Not thread-safe: owned by one actor.
public final class SQLiteConnection: @unchecked Sendable {
    public func exec(_ sql: String) throws
    public func prepare(_ sql: String) throws -> Statement       // cached by SQL text
    public var lastInsertRowID: Int64 { get }
    public var changes: Int { get }
    public var errorMessage: String { get }
    public final class Statement {
        public func bind(_ values: [JSONValue?]) throws           // 1-based positional binding
        public func step() throws -> Bool                         // true = row
        public func column(_ index: Int) -> JSONValue
        public func reset()
    }
}

// AirbagHookBridge
public enum LogLevel: Int, Sendable, Comparable { case debug, info, warn, error, fault }
public enum AskSupport: Sendable { case native, unsupported, undocumented }
public struct AgentProcessMatch: Sendable {
    public struct Hop: Sendable { public var key: ProcKey, exePath: String?, argv0: String? }
    public var agent: ProcKey, exePath: String, argv: [String]
    public var chain: [Hop]                                       // hook → … → agent
    public var hostBundlePath: String?, tty: String?
}

// AirbagProcessRadar
public struct SweepReport: Sendable, Equatable {
    public var endedIncarnations: [ProcKey], endedSessions: [SessionID], staleSessions: [SessionID], inGrace: [SessionID]
}
public struct StopPlan: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case group(pgid: pid_t), individual }
    public var target: ProcKey
    public var victims: [ProcKey]                                 // target + live same-uid descendants, deepest first
    public var mode: Mode
}
public enum StopRefusal: Sendable, Equatable {
    case goneOrReused
    case protectedTarget(Protection.ProtectedReason)
    case protectedDescendant(ProcKey, Protection.ProtectedReason)
    case managed(by: String)                                      // Docker / Lima proxies: stop disabled, hint shown
}
/// Pure; §6.7 steps 1–3. `exePaths` is the radar's cache for the pids in `table`.
public struct StopPlanner: Sendable {
    public init(policy: RadarPolicy)
    public func protection(of key: ProcKey, table: ProcessTableSnapshot, context: AttributionContext, exePath: String?) -> Protection
    public func plan(target: ProcKey, table: ProcessTableSnapshot, context: AttributionContext, exePaths: [pid_t: String]) -> Result<StopPlan, StopRefusal>
}
public struct OrphanPrompt: Sendable, Identifiable, Equatable {
    public var id: SessionID { sessionID }
    public var sessionID: SessionID, session: Session, project: Project?
    public var processes: [RadarProcess]                          // link_state ∈ {detached, orphan}, confidence ≥ medium, listening
    public var aggregated: Bool                                   // true for the once-per-launch "already orphaned" summary
}
public protocol OrphanNotifier: Sendable {                        // UNUserNotificationCenter in the app; a recorder in tests
    func post(_ prompt: OrphanPrompt) async
    func withdraw(sessionID: SessionID) async                     // session resumed within grace → cancel
}
```

## 11. Test plan

Toolchain: Swift Testing only (`@Test`, `#expect`, `@Suite`, parameterised tests); XCTest is unavailable with CLT [verified, doc 04 §11]. Tests run from `swift test` on the dev machine and under Xcode in CI.

### 11.1 Unit tests (no processes spawned)

- **Adapters**: for each agent, fixture payloads taken verbatim from the research docs (Claude PreToolUse/PostToolUse/SessionStart/SessionEnd/Stop captures, doc 01 §2; Codex schema-required fields, doc 02 §2.4; Cursor `beforeShellExecution`/`preToolUse`/`sessionEnd`, doc 03 §3.4; Gemini `BeforeTool` with `dir_path`; Copilot camelCase with `toolArgs` as object **and** as JSON string). Assert the envelope, the dedupe key, and the exact bytes of allow/ask/deny responses (Codex allow = empty stdout; Gemini allow = `{}`; Cursor allow = `{"permission":"allow"}`). Shape detection: a Cursor payload handed to `airbag hook claude-code` is parsed by `CursorAdapter`.
- **Fuzz/robustness**: empty stdin, `{}`, truncated JSON, 2 MiB payload, unknown event names, non-UTF-8 bytes, `tool_input` as a string → always `HookResponse.safe`, never a trap (run under `-sanitize=address` in CI).
- **Redaction**: table of commands → expected redacted text and span count; hash stability; `hash_only` mode yields `text == nil`.
- **Project resolution** (§7.4): temp directory trees with `.git` dir, `.git` file + `commondir`, submodule `.git/modules`, symlinked paths, depth > 64, HOME boundary.
- **Attributor**: synthetic `ProcessTableSnapshot`s covering every ladder rule and link state, including the real orphan shape (ppid 1, env session id of a live session with a different pid → `detached`), pid reuse (same pid, different start → no attribution carry-over), Apple binary (no env, system path → `system`), application bundle with a listener (`/Applications/Spotify.app/Contents/MacOS/Spotify`, `*:57621` → `other`, hidden), dual-stack listeners grouped, `limactl` managed badge, and the colima shape (`ssh` mux with seven forwards, ppid 1, cwd under a project → project HIGH, session LOW, no `OrphanPrompt`).
- **Session semantics**: `/clear` supersede, resume = new incarnation, Copilot `-p` `complete` as turn end, grace period, shared-host staleness.
- **Registry**: migrations from an empty file and from a frozen v1 fixture; `user_version` ahead → read-only degraded; `application_id` mismatch → rename; `dedupe_key` collisions return the first decision; retention counts; `observe(RadarDelta)` idempotency; allowances (grant → consume once → second consume nil → expiry).
- **Stop planner**: `StopPlanner.plan` (§10.6) over synthetic trees: protected descendant refuses the whole plan; group mode only when all live members are victims; managed names refuse with `.managed`; a start-time mismatch refuses with `.goneOrReused`; victims come out deepest first.

### 11.2 Integration tests with a fake agent tree

Test-only executable target `airbag-fakeagent` (no network, no third-party deps):

- `airbag-fakeagent agent --agent <kind> --session <id> --child "<argv>" [--hooks-dir <dir>]`: re-execs itself through a symlink in a temp `bin/` named like the real binary (`claude`, `codex`, `cursor-agent`, `gemini` → `node` symlink with argv containing `gemini`, `copilot`) so `exePath`/basename matching is exercised; exports the agent's env markers (`CLAUDE_PID=$$`, `CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID`, `CURSOR_AGENT`, `GEMINI_CLI=1`, `COPILOT_CLI=1`); spawns `/bin/zsh -c "<child>"` as its own process group (the tool-shell shape); reports pids and the child's listening port on a control pipe; reacts to `SIGUSR1` (exit immediately without reaping → children reparent to launchd), `SIGUSR2` (re-exec with the same session id = resume), `SIGTERM` (clean exit).
- `airbag-fakeagent server --port 0 [--ignore-term] [--setsid]`: binds `127.0.0.1:0` (and optionally `::`), prints `PORT=<n>`, serves nothing.
- `airbag-fakeagent hook-invoke --agent <kind> --payload <file> --parent <pid>`: runs the real `airbag hook` binary **as a descendant of the fake agent** (so `getppid()` walks land on it), captures stdout/exit code/wall time.

Scenarios (each asserts registry rows, radar snapshot after `tick()`, stdout bytes, and timing):

1. Attach: live agent → `pre_shell` with `run_in_background` → server appears → `attached`, `live_ancestry`, HIGH; listener row with the reported port.
2. Crash: `SIGUSR1` → next tick: incarnation ended; after grace session `pid_gone`; server `orphan` via `remembered_ancestry` **and** `env_session`; an `OrphanPrompt` with the server reaches the recording `OrphanNotifier` exactly once; a second tick does not repeat it.
3. Resume: `SIGUSR2` → new incarnation, same session; old server becomes `detached`, new child `attached`.
4. `/clear`: Claude `SessionStart source=clear` with a new session id from the same pid → previous row `superseded`.
5. Discovery: start the server tree **before** Airbag ever saw the session (no hooks) → first tick creates `discovered_via='env'` session with `cwd = PWD`, process `MEDIUM`.
6. Stop: `stop(key)` → `.terminated` within 5 s; with `--ignore-term` → `.stillRunning`, then `stop(force: true)` → `.terminated`; attempting to stop the fake agent itself → `.refused(.protectedTarget(.agent))`; a `limactl`-named fake → `.refused(.managed(by: "Lima"))`; stopping an `npm run dev`-style wrapper (zsh → server) in group mode kills both.
7. Hook contention: a helper holds `BEGIN IMMEDIATE` for 2 s → `airbag hook` still answers within `hook.hardDeadlineMs`, writes a spool file; the next hook (or the app) ingests it and the event exists exactly once.
8. Schema ahead: bump `user_version` to 999 → hook answers normally, registry health `schemaNewer`, spool used.
9. Deadline: `SnapshotEngine` stub sleeps 10 s → watchdog prints the allow shape at `hardDeadline` and the git stub's process group receives SIGKILL (stub spawns a real `sleep` in its own pgid to verify).
10. Cursor double route: the same command delivered as native `beforeShellExecution` and as imported Claude `preToolUse` → one event, one snapshot call, second response equals first decision.
11. Deny path: rule stub returns deny → no snapshot call, guard row, response bytes per agent; Codex deny carries a non-empty reason; `deny_with_allowance` + `grantAllowance` → retried command returns allow, `allow_once` logged, token `used_at` set.
12. Environment edge cases on the real kernel: `envMarkers(1)` is nil (EINVAL), `envMarkers(<rapportd pid>)` returns empty values, own pid returns markers.

### 11.3 Performance tests (release build, skipped under sanitizers)

- `tick()` on the real table: median < 3 ms over 50 ticks with ≥ 400 pids (fail at > 6 ms); first tick < 50 ms.
- `envMarkers` sweep over all same-uid pids < 20 ms (Python measured 12.5 ms for 311 pids today).
- `airbag hook claude-code` end-to-end with a warm 1 000-file temp project and the real git engine: p50 < 150 ms, p95 < 400 ms over 30 runs; `session_end` < 100 ms.
- Registry: 10 000 `append` in one transaction < 100 ms; `events(sessionID:)` with 200k rows < 10 ms (indexes).

### 11.4 Manual QA matrix (before each release)

Claude Code desktop (`auto` and `bypassPermissions`), Claude Code terminal, `claude -p`; Codex CLI, Codex app (trust flow via `/hooks` → `t`), `codex exec`; Cursor IDE, Cursor CLI; Gemini CLI; Copilot CLI interactive and `-p`. For each: hooks fire (events table), session end detected within grace after `kill -9` of the agent, orphan notification appears once, stop works, no stderr pollution (Gemini shows no `systemMessage`), hook overhead p50 shown in the UI under 300 ms.

## 12. Risks and open questions

1. **Codex moves command hooks to an exec server** (source TODO) — `getppid()` would no longer reach the Codex pid; mitigated by the bounded argv-matching walk and by env attribution in the radar, but the hook-time incarnation record may be lost for Codex. [verified comment, timing unknown]
2. **Claude `ask` under `bypassPermissions`** is undocumented; a desktop session on this machine runs in that mode today. Default `deny_with_allowance` is safe but noisier; needs one interactive probe. [unverified]
3. **Hook crash = deny on Copilot**, and `onFailure:block`/`failClosed` in strict mode: a Swift runtime trap in the hook would block every shell command. Mitigation: no force-unwraps on payload data, fuzz tests, sanitizer CI; a fork-based supervisor (parent prints the safe response if the child dies, +1.4 ms) is the fallback if field crashes appear.
4. **Environment is invisible for Apple platform binaries and anything that scrubs env** (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, Docker containers): those processes rely on cwd/ancestry only. [verified]
5. **PID reuse**: handled by `(pid, start)` everywhere, but `~/.claude/sessions/<pid>.json` leftovers and `CLAUDE_PID` in old environments can point at a reused pid; the ±5 s `startedAt` check and "start time must precede the child's" rule cover it. [design]
6. **WAL growth without the app**: the CLI's 16 MB PASSIVE checkpoint bounds it; a hook that is killed mid-checkpoint is harmless (checkpoints are restartable). [verified semantics]
7. **Cold snapshot cost** (6–8 s for 20k files) cannot fit a hook; the app must prime stores at registration, and a user who never runs the app gets `snapshot_skipped(cold)` until the first run — the UI/`airbag doctor` must say so. [verified cost]
8. **Shared-host agents** (Codex app-server, Cursor IDE): liveness by staleness is a heuristic (2 h) and can mark a long-idle thread ended early; consequence is only an orphan prompt the user can dismiss. [design]
9. **Cursor worktree layout and `sessionEnd` in the CLI** are forum-level facts; the scanner tolerates unknown layouts by classifying `manual`. [likely/unverified]
10. **`proc_listallpids` return semantics on macOS 14.x** (count vs bytes) — code counts non-zero entries; needs a 14.x machine. [open, doc 04]
11. **TCC prompts** for projects under `~/Desktop`, `~/Documents`, `~/Downloads` when the app watches them; the radar itself needs no TCC (libproc/sysctl only). [verified for libproc; FSEvents behaviour open]
12. **`KERN_PROCARGS2` buffers** can be up to `kern.argmax` = 1 MiB; one reusable buffer per actor, zeroed after parse, never retained. [verified size]
13. **Multi-user Macs**: other users' agents are invisible to libproc (EPERM/EINVAL) and are out of scope; the UI must say "this user only". [verified]
14. **Claude Code's worktree marker** key is undocumented; detection relies on the `.claude/worktrees/` path. [unverified]
15. **`sessions/<pid>.json` coverage** for `-p`, VS Code and JetBrains entrypoints is unknown; only `claude-desktop` was observed. [open, doc 01 §14]
16. **Cross-document reconciliation needed**: spec 13 §7.4 lists "Hook snapshot cap (3 s default, 1–10)" while this design sets `hook.snapshotDeadlineMs = 1500` (derived from the p95 < 2 s budget of doc 03 §8.5) with a 500–10 000 ms range; doc 06 §12 names the registry `airbag.sqlite` while spec 13 §4 and this design use `registry.sqlite`; spec 13 §7.2 polls 5 s/2 s where this design adds 1 s (popover), 10 s (idle) and 30 s (asleep) tiers. Proposal: docs 06/13 adopt the names and tiers here; the deadline default is decided after the §11.3 end-to-end measurement on a 50k-file repo. [design]
17. **Application-bundle hiding** (`.app/Contents/` listeners classed `other`) could hide a legitimate dev server launched from inside an IDE bundle; the cwd, marker and name rules re-promote it and "Show all" exposes everything, but VS Code's and JetBrains' debug launchers need a manual-QA row. [design]
18. **Managed proxies** (colima/Lima `ssh` mux, `docker-proxy`) carry project cwds and dev-like ports; they are shown as managed with stop disabled, which some users will read as "Airbag cannot stop my port 3000". The row must say what owns the port and offer the copyable `colima stop` / `docker ps` hint. [verified shape today]

## Sources

Research notes (this repository): `docs/research/01-claude-code-hooks.md`, `02-codex-hooks.md`, `03-cursor-gemini-copilot-hooks.md`, `04-macos-platform.md`, `05-competitors.md`, `06-git-snapshot-mechanics.md`, `00-source-market-report-ru.md`.

Primary sources fetched 2026-10-17: Claude Code worktrees — https://code.claude.com/docs/en/worktrees.md ; SQLite pragmas (`data_version`, `application_id`, `user_version`, `wal_checkpoint`, `busy_timeout`) — https://www.sqlite.org/pragma.html ; SQLite WAL and busy handler (via doc 04) — https://www.sqlite.org/wal.html , https://www.sqlite.org/c3ref/busy_handler.html.

Second-pass probes, 2026-10-17 (uid 501, no root): own ancestor chain from this Bash tool (`zsh 27575 → claude 11328 → disclaimer 11327 → Claude 94586 → launchd`, with `disclaimer --responsible -- /usr/bin/ssh` siblings for desktop SSH sessions, none of them agents); all three `~/.claude/sessions/*.json` decoded with the secret-bearing keys masked (field list in §8.3; `.key` siblings 0600) plus directory modes; `lsof -nP -iTCP -sTCP:LISTEN` baseline (ControlCenter 5000/7000, rapportd 56257, Spotify 7768/57621/64770, Raycast 7265, limactl 53/60856, colima `ssh` mux 1883/3000/4840/5432/6379/8000/8100, `next-server` 70386 on 3999) with cwd and ancestry of each; process counts 490 total / 299 same-uid / 255 same-uid with ppid 1; `kern.argmax` = 1 048 576; macOS 15.7.9, SQLite 3.43.2, git 2.39.5, Swift 6.1.2 (CLT); `~/.codex`, `~/.gemini`, `~/.copilot`, `~/.claude/worktrees` exist, `~/.codex/worktrees` and `~/.cursor` do not.

First-pass local probes run 2026-10-17 on this Mac (uid 501, no root): `ps -axo pid,ppid,pgid,…` of the desktop chain (`zsh 800 → claude 11328 → disclaimer 11327 → Claude 94586 → launchd`); children of the three `claude` pids (only MCP servers via `npm exec`); environment of this Bash tool shell (`CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_HOST_SESSION_ID`, …); `~/.claude/sessions/{10716,11328,99094}.json` (fields, `startedAt` vs `procStart` vs `ps lstart`); `lsof -nP -iTCP -sTCP:LISTEN` baseline plus cwd/ppid of each listener; the orphan `next-server` pid 70386 (ppid 1, pgid 70382, started 2026-10-06, cwd `~/qost/web/.next/standalone`) and its environment via a ctypes `sysctl(CTL_KERN, KERN_PROCARGS2)` probe (26 `CLAUDE_*` variables, dead `CLAUDE_PID=62758`, live session id `1a2b3c4d-…`, transcript present); `KERN_PROCARGS2` layout, per-pid cost (29 µs median / 67 µs p95 / 292 µs max, 12.5 ms for 311 pids), `EINVAL` for pid 1, zero environment for `rapportd` and `ControlCenter`; process-table sizing (498 pids, 308 same-uid, 264 same-uid with ppid 1); SQLite 3.43.2 feature check (STRICT, RETURNING, JSON, generated columns, `unixepoch`, compile options); git 2.39.5 worktree metadata (`.git/worktrees/<name>/{HEAD,ORIG_HEAD,commondir,gitdir,index,locked,logs}`, `locked` reason, porcelain `locked`, `rev-parse --path-format=absolute --git-common-dir` from a worktree subdirectory, remove refusal while locked, ~12 ms per `rev-parse`).
