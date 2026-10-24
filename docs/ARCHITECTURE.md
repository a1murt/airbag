# Airbag architecture

Status: authoritative overview, 2026-10-18. Detailed specs: snapshot engine `design/10-snapshot-engine.md`,
registry / hook bridge / radar / IPC `design/11-session-registry-and-radar.md`, product & UX
`design/13-product-spec.md`, rules `design/12-circuit-breaker-rules.md`. Where an older doc disagrees with this
file or with doc 10, this file and doc 10 win (see "Overrides" at the end).

## 1. What runs where

```
 agent process (claude / codex / cursor / gemini / copilot)
   │ hook: exec /Applications/Airbag.app/Contents/Helpers/airbag hook <agent>
   ▼
┌────────────────────────────── airbag (CLI, short-lived, standalone) ─────────────────────────────┐
│ parse payload → resolve project/worktree (fs walk, no git) → RULES verdict (pure, ~1 ms)          │
│ → locate agent pid (env, ppid walk) → REGISTRY upsert + event (SQLite WAL, spool on failure)      │
│ → SNAPSHOT (APFS clones, deadline 1.5 s, watchdog 4 s) → reply JSON → wake app via unix socket    │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
        │ registry.sqlite (WAL)                     │ stores.noindex/<root_id>/ (clones + manifest)
        ▼                                           ▼
┌────────────────────────────── Airbag.app (menu bar, long-lived, optional) ───────────────────────┐
│ status item + popover summary │ Timeline (snapshots → changes → diff → restore)                  │
│ Radar (libproc poll, attribution, orphans, stop) │ Guard (log, allow-once tokens, rule toggles)  │
│ FSEvents watcher → snapshots between commands │ retention scheduler │ hooks installer/doctor     │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Protection never depends on the app: the CLI decides, snapshots and records on its own. The app adds
snapshots between agent commands (FSEvents), the UI, the radar, retention and hook management.

## 2. Code layout (SwiftPM, no dependencies)

| Target | Kind | Contents |
|---|---|---|
| `AirbagCore` | library | `Support/` (paths, permissions, ULID, JSON, SHA-256, logging, SQLite wrapper, clock), `Snapshots/` (walker, store, manifest, restore, retention, diff), `Rules/` (shell lexer, analyzer, catalog, engine), `Registry/` (schema, migrations, DAO, spool), `Hooks/` (agent adapters, reply encoders, bridge pipeline, installer), `Processes/` (libproc, sysctl env reader, radar, attribution, stopper), `IPC/` (unix socket client/server) |
| `airbag` | executable | CLI: `hook`, `snapshot`, `snapshots`, `changes`, `diff`, `restore`, `pin`, `prune`, `check`, `ports`, `stop`, `sessions`, `hooks install|uninstall|status`, `doctor`, `version` — JSON output with `--json` |
| `AirbagApp` | executable (product `Airbag`) | SwiftUI `MenuBarExtra(.window)` app, view models over `AirbagCore` |
| `AirbagCoreTests` | Swift Testing | unit + integration (synthetic roots, fake agent trees, rule fixture) |

Build: `Scripts/build-app.sh` assembles `Airbag.app` from `swift build -c release` (CLT only; arm64 + x86_64
via `--triple` + `lipo`), writes Info.plist (LSUIElement), copies `.lproj` resources (own bundle accessor, not
`Bundle.module`) and signs with the hardened runtime: ad-hoc by default, with a Developer ID when `SIGN_IDENTITY`
is set. `Scripts/package.sh` notarizes and staples only when given a Developer ID and a notary profile; the release
workflow passes them only when Developer ID secrets are configured. There is no Developer ID yet, so 0.1.x releases
are ad-hoc signed and not notarized (the cask removes the quarantine flag; the DMG asks once).

## 3. On-disk layout

```
~/Library/Application Support/Airbag/          0700, re-chmodded at every start
├── registry.sqlite (+wal,+shm)                0600  sessions, projects, worktrees, processes, listeners,
│                                                    snapshots index, events, guard_log, allow_tokens, settings
├── airbag.sock                                0600  wake-up only (app listens; CLI connects with 20 ms budget)
├── spool/<ulid>.json                          0600  registry writes that could not be committed
├── rules/compiled.json                        0600  user/project rule overrides compiled by the app (CLI reads)
├── logs/hook.log, logs/app.log                0600  rotated 5 × 1 MB, no command text at info level
├── backups/<agent>-settings-<ts>.json         0600  config files before every hook install/uninstall
└── stores.noindex/<root_id>/                  0700  one snapshot store per root (doc 10 §2)
```

## 4. Data flows

**Pre-command hook** (budget p50 < 300 ms, p95 < 2 s on 50k files): stdin (≤ 1 MiB) → adapter by payload shape
→ resolve root (walk up from `cwd` to the nearest `.git` file/dir or registered root) → rules verdict → if deny:
guard row + reply deny (no snapshot; nothing changes on deny) → else snapshot (`pre_command`, label = redacted
command) → event row linking the snapshot → reply (allow / native ask / deny-with-allowance / allow and record in
Guard, ADR-030) → socket ping.
The watchdog thread fires at the hard deadline, prints the already-decided answer and `_exit(0)`s; the
uncommitted snapshot transaction rolls back and the flock is released by process exit.

**Post-command hook** (async where the agent supports it): pair with the pre event by `tool_use_id`, take a
`post_command` snapshot so the Timeline shows exactly what the command changed.

**Session start/end**: upsert session + incarnation; session start on a root without a store spawns
`airbag snapshot --initial` detached; session end marks the session ended and lets the radar evaluate orphans.

**FSEvents (app)**: per protected root, `FileEvents|NoDefer|WatchRoot`, latency 0.5 s, debounce 3 s quiet / 30 s
max → `fsevents` snapshot. Events inside excluded directories are ignored before debouncing.

**Restore (app or CLI)**: lock store → forced `pre_restore` snapshot → apply (clone + atomic rename; directories
and uncaptured files are moved aside, never deleted) → `post_restore` snapshot → report with undo snapshot id.

**Radar poll (app)**: adaptive 1–30 s cadence (doc 11 §6.1). `proc_listallpids` + `PROC_PIDLISTFDS` +
`PROC_PIDFDSOCKETINFO` for TCP listeners (~1 ms full scan), `PROC_PIDTBSDINFO` for ppid/start, `KERN_PROCARGS2`
for argv and allowlisted env markers (`CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `CODEX_THREAD_ID`, `CURSOR_AGENT`,
`GEMINI_CLI`, `COPILOT_CLI`), `PROC_PIDVNODEPATHINFO` for cwd. Attribution ladder: live ancestry → env markers →
remembered ancestry/pgid → cwd under a root → argv match (doc 11 §6.3). Orphan = attributed session ended (or its
agent pid gone) while the process still listens. Prompt "Session ended — stop its N servers?" once per session.

**Stop**: re-validate `(pid, start)`, SIGTERM children first then the process, poll 100 ms up to 5 s, offer
SIGKILL as a separate action. Never signal agents, their host apps, terminals, IDEs, Airbag, or `/System`.

**Hook install**: per agent, read the user-scope config, back it up, merge Airbag entries identified by the exact
command path (idempotent; foreign entries untouched), write atomically (temp + rename, original mode preserved),
record a fingerprint; uninstall removes only Airbag entries. Codex hooks additionally need the user's trust in
`/hooks` — the app shows that step.

## 5. Failure policy

- Rules never depend on the registry, the store or the app. Registry trouble → spool; store trouble → snapshot
  skipped and logged; both → the hook still decides correctly.
- On the agent side, Claude Code, Codex and Cursor fail open by default (crash/timeout = command runs); Copilot CLI
  denies on a hook error (a timeout runs), Gemini CLI denies on a non-zero exit other than 1 that prints text (doc 11
  §4.4, §4.7). Strict mode (opt-in) sets `onFailure: block` (Claude ≥ 2.1.295) and `failClosed: true` (Cursor) on
  the pre-shell hook only.
- `ask` without a registry never becomes allow: native ask where supported, otherwise deny with explanation.
- A command whose verdict needs a snapshot (`snapshot: required`) and did not get a usable one becomes an ask
  (`snapshot.unavailable`), also when its verdict was already an ask; a `snapshot: recommended` command still runs.
  A folder with no files counts as captured only when the walk saw all of it, found no files, skipped none for size
  and hit no errors (`snapshot_skipped = "empty"`); a folder the user stopped protecting (`not_protected`) needs no
  snapshot either. A walk cut short is incomplete. All of this is per root: each root a `required` finding targets
  (the launch folder or a worktree's main checkout included) needs its own snapshot, which the hook takes only for a
  command that targets it.
- Where an ask is recorded instead of asked (ADR-030), `snapshot.unavailable` and every `self.*` finding still
  stop the agent until the user approves (ADR-035). While Airbag is paused nothing waits; blocks still apply.
- Restore never deletes: anything in its way goes to `aside/` inside the store, covered by retention.

## 6. Performance budgets

| Item | Budget |
|---|---|
| Hook overhead excluding snapshot | < 15 ms p50 |
| Snapshot, 5k files, no change / 100 changed | < 50 ms / < 80 ms |
| Snapshot, 50k files, no change | < 150 ms |
| Radar full poll | < 3 ms median |
| App idle CPU / RSS | < 1 % / < 100 MB |

Hook and snapshot measurements: `BENCHMARKS.md`. App idle CPU / RSS has not been measured against its budget yet.

## 7. Security and privacy

Everything runs as the user; no root helper, no Full Disk Access, no network except an opt-in update check
(GitHub Releases API) planned for later. Store and registry are 0700/0600, excluded from Time Machine and
Spotlight, and hold copies of `.env` files — documented in SECURITY.md. Command text is redacted (token-like
patterns) before it is stored; command output is never stored. The hook path is absolute inside the signed app
bundle (or the Homebrew symlink); the doctor flags configs that point elsewhere.

## 8. Conventions

Swift 6.1 toolchain, `swift-tools-version: 6.0`, Swift 5 language mode (C interop with libproc/SQLite/FSEvents
stays practical); UI types `@MainActor`; core types are value types or final classes confined to one thread;
errors are typed enums conforming to `LocalizedError`; logging through a small `Log` facade (file + `os.Logger`).
User-facing strings are English in code and translated in `Resources/<lang>.lproj/Localizable.{strings,stringsdict}`
(19 languages, list in `AppModel.languages`; Settings → Language overrides the system choice); agent-facing reasons are
English.

## 9. Overrides of older design documents

- Doc 11's references to git commits/refs in the snapshot store (`commit_oid`, `tree_oid`, git child process
  groups, "cold snapshot 6–8 s") are replaced by doc 10: `registry.snapshots` stores `root_id`, `seq`, counts and
  bytes; there is no git child to kill; the hook takes the first snapshot itself under its 1.5 s deadline and
  leaves an incomplete one to a detached `airbag snapshot` (doc 10 §4.6).
- Store keying: doc 10 keys stores by root (each worktree its own store); doc 11's project keying is kept for the
  registry only.
- Hook binary path: `Airbag.app/Contents/Helpers/airbag` (doc 11 §4.10).
