# Delivery plan

Milestones are ordered by dependency and risk. Each ends with a commit, green `swift test`, and the acceptance
checks listed. Status markers: ☐ todo, ◐ in progress, ☑ done.

## M0 ☑ Skeleton that builds and runs
- `Package.swift` (AirbagCore, airbag, AirbagApp, AirbagCoreTests), `Makefile`, `Scripts/build-app.sh`.
- `airbag version`; a menu bar app showing a status item and a popover with a localized string (EN/RU).
- Own resource-bundle accessor that works inside `Airbag.app`.
- Accept: `make test` passes; `make app` produces `build/Airbag.app` with `Contents/Helpers/airbag`;
  `codesign --verify --strict` passes (ad-hoc); launching shows the icon; `defaults write … AppleLanguages (ru)`
  switches the popover text.

## M1 ☑ Foundations
- Paths and permission enforcement (0700/0600), ULID, SHA-256, JSON helpers, `Log`, SQLite wrapper (prepared
  statements, transactions, `BEGIN IMMEDIATE`, busy timeout), registry schema v1 + migrations, settings.
- Accept: unit tests for ULID ordering, SQLite wrapper, migrations idempotence, two-process write contention.

## M2 ☑ Snapshot engine (riskiest)
- Walker, store open/create, snapshot, list, changes, diff (incl. live), Myers text diff, restore (paths/root,
  aside, conflicts, undo), pin, prune (retention SQL), usage; CLI subcommands.
- Accept: every "destructive agent" scenario in doc 10 §10 restores byte-for-byte; retention property test;
  5k-file no-change snapshot < 50 ms in release.

## M3 ☑ Circuit breaker
- Shell lexer (quotes, escapes, `&& || ; |`, newlines, `$( )`, backticks, `sh -c`, wrappers, env prefixes), path
  resolution, rule catalog, verdicts, `airbag check`.
- `docs/design/12-circuit-breaker-rules.md` + `Tests/Fixtures/rules.json` (≥ 150 cases).
- Accept: fixture 100 % green; evaluation < 1 ms per command.

## M4 ☑ Hook bridge and installer
- Adapters (Claude Code, Codex, Cursor, Gemini, Copilot), reply encoders, pipeline with deadlines and watchdog,
  session upsert, events, guard log, allow tokens, spool, socket ping.
- Installer: merge/backup/uninstall/status for each agent's user config; `airbag hooks …`, `airbag doctor`.
- Accept: golden tests per agent payload → reply; pipeline test with a fake agent tree; install → uninstall
  leaves the config byte-identical; end-to-end run of the real Claude Code binary with `--settings` pointing at
  Airbag hooks in a temp project: a destructive command is snapshotted and restored, `rm -rf ~`-style command is
  denied.
- Status 2026-10-18: unit/pipeline/installer tests green; `Scripts/e2e-hooks.py` (simulated agent driving the real
  release binary over stdin/stdout) passes 13/13 with hook p50 14.6 ms. `Scripts/e2e-claude.sh` (real Claude Code)
  is ready but blocked: the Claude CLI on this Mac is not logged in (only the desktop app is); run it after
  `claude /login`.

## M5 ☑ Process radar
- libproc scanner, `KERN_PROCARGS2` reader, attribution ladder, orphan state, stopper, `airbag ports`, `airbag stop`.
- Accept: fake agent tree test (server spawned under a fake session, agent exits, server is reported orphan with
  the session); full poll < 3 ms; stop never touches protected processes.

## M6 ☑ Menu bar app
- Status item states and badge policy; popover summary; Timeline window (roots → snapshots → changes → diff →
  restore with confirmation); Radar view (stop/force stop/reveal); Guard view (log, allow once, deny); Settings
  (agents & hooks, projects & excludes, retention, launch at login, language); FSEvents snapshots; retention
  scheduler; socket listener.
- Accept: manual checklist in `docs/QA.md`; idle CPU < 1 %, RSS < 100 MB measured with `top`/`footprint`.

## M7 ☑ Onboarding, localization, polish
- First run: detect agents → preview + one-click hook install → protected projects → done (< 60 s).
- All user-facing strings EN/RU; app icon and menu bar glyph; VoiceOver labels; empty/error states.

## M8 ☑ Packaging and CI
- Universal build, ad-hoc and Developer ID signing paths, notarization script, zip + DMG, Homebrew cask draft,
  GitHub Actions (CI on PR, release on tag), README, SECURITY.md, CONTRIBUTING.md, LICENSE.
- Status 2026-10-18: all done and the universal zip/DMG build locally (ad-hoc signed). Remaining, needs the owner:
  a Developer ID Application certificate and notarization credentials (no signing identity on this Mac), a GitHub
  repository and a tap for the cask. The release workflow expects secrets `DEVELOPER_ID_P12_BASE64`,
  `DEVELOPER_ID_P12_PASSWORD`, `SIGN_IDENTITY`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_APP_PASSWORD`.

## M9 ☑ MVP acceptance (market report readiness criteria)
- Destructive scripts (`rm -rf` dir, `mv`, `sed -i`, `git checkout -- .`, `git reset --hard`, `git clean -fdx`)
  rolled back from the menu bar without a lost file.
- 3–5 parallel agent sessions in worktrees: every dev server attributed to its session, including survivors.
- Idle CPU < 1 %.
- Independent review pass (correctness + security) with fixes.
- Status 2026-10-18: destructive-script restores covered by tests and `Scripts/e2e-hooks.py`; 5 parallel sessions in
  worktrees attributed correctly incl. survivors (`Scripts/acceptance/parallel-sessions.py`); idle app 0 % CPU / 19 MB;
  independent review found 5 blockers, 22 major, 19 minor issues — all fixed with regression tests
  (`docs/research/08-independent-review.md`).

## Deliberately skipped in v1
Usage/limit counters, "agent is waiting" notifications, orchestration, OAuth, Agent SDK, telemetry, project-level
hook configs, per-volume stores for external disks (copy mode instead), disk cleaner, secret scanner,
keep-awake (v1.1/v2 per the product spec).

## Risk register
| Risk | Mitigation |
|---|---|
| Snapshot latency on huge roots | deadline + incomplete snapshots; skip roots > 150k captured entries in the hook, rely on FSEvents |
| Disk pressure from pinned clone blocks | free-space floor, emergency prune, budget |
| Agent hook formats change | adapters detect by payload shape; golden tests; doctor flags drift |
| Rule false positives annoy users | snapshot-first policy; ask instead of block inside roots; per-project overrides |
| Codex trust step forgotten | onboarding shows it; doctor reports `untrusted` |
| No Developer ID certificate yet | ad-hoc builds for local use; signing script ready for the certificate |
