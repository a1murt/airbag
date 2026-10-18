import Foundation

/// Registry schema. Migration 1 is the DDL of design doc 11 §3.2–3.3 with the snapshot table adapted to the
/// APFS store of doc 10 (see docs/ARCHITECTURE.md §9). Never edit a shipped migration; append a new one.
enum RegistrySchema {
    static let applicationID: Int32 = 0x41524247 // 'ARBG'

    static let migrations: [(version: Int, sql: String)] = [
        (1, migration1),
    ]

    static var latestVersion: Int { migrations.last!.version }

    static let migration1 = #"""
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

CREATE TABLE snapshots (                        -- index of store snapshots (doc 10); the store manifest is the source of truth
  id            TEXT PRIMARY KEY,               -- ULID; equals the store's snapshots.id
  project_id    TEXT REFERENCES projects(id) ON DELETE CASCADE,
  worktree_id   TEXT REFERENCES worktrees(id) ON DELETE SET NULL,
  root_id       TEXT NOT NULL,                  -- store key (doc 10 §1)
  root_path     TEXT NOT NULL,
  seq           INTEGER NOT NULL,               -- store sequence number
  session_id    TEXT REFERENCES sessions(id)  ON DELETE SET NULL,
  event_id      TEXT,                           -- the pre_shell event that triggered it
  trigger       TEXT NOT NULL CHECK (trigger IN ('pre_command','post_command','fsevents','manual','pre_restore','post_restore','initial')),
  file_count    INTEGER,
  changed_count INTEGER,                        -- vs previous snapshot of the same root
  bytes_added   INTEGER,
  duration_ms   INTEGER,
  complete      INTEGER NOT NULL DEFAULT 1 CHECK (complete IN (0,1)),
  label         TEXT,                           -- e.g. 'Before `npm run db:reset`' (redacted command)
  pinned        INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
  created_at    INTEGER NOT NULL,
  deleted_at    INTEGER,
  UNIQUE (root_id, seq)
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
CREATE INDEX snapshots_root       ON snapshots(root_id, seq) WHERE deleted_at IS NULL;
"""#
}
